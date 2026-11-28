#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42fa772b-6da6-47f5-83ad-19a13bc7eb1e
"""Run enrolled guest workloads against loopback service fixtures."""

from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from shutil import copy2, which
import stat
import subprocess
from tempfile import TemporaryDirectory
from threading import Thread
from time import monotonic
import unittest

POC = Path(__file__).resolve().parents[1]
ENTRY = POC / "test/ubuntu.server.24/ubuntu.server.24.amisad-core.{}.sh"
FIXTURES = POC / "test/fixtures"
LEGACY_CORE_USERS = FIXTURES / "core-users-before-rust.sh.fixture"
NODE = "127.0.0.71"
BIN_DIR = Path(os.environ.get("AMISAD_BIN_DIR", POC / "target/debug"))
BIN = Path(os.environ.get("AMISAD_PROVISION_BIN", BIN_DIR / "amisad-provision")).resolve()
SUPPORT_TOKEN = "synthetic-lab-support-token"
CONNECTOR_CREDENTIAL = "synthetic-lab-connector-credential"


class ScenarioContract(unittest.TestCase):
    def run_workload(self, failure=None, scenario="s001.fulfillment", native_failover=False, fetched=False):
        traffic = []
        scenario_name = scenario.split('.')[1]
        native_edge = native_failover or (fetched and scenario_name != "suppression")
        published = {"version": "2026-Q3", "aggregates": [
            {"category": "housewares", "region": "region-a", "demand": 6}]}
        with TemporaryDirectory(prefix="amisad-s001-") as home, ExitStack() as services:
            home = Path(home)
            poc = home / "amisad.dev/poc"
            tools = home / "tools"
            trace = home / "trace"
            tools.mkdir()
            (poc / "test").mkdir(parents=True)
            (poc / "target/release").mkdir(parents=True)
            runtime = poc / "target/release/amisad-provision"
            if fetched:
                copy2(BIN, runtime)
            else:
                runtime.symlink_to(BIN)

            class Handler(BaseHTTPRequestHandler):
                def send_json(self, value, code=200):
                    data = json.dumps(value).encode()
                    self.send_response(code)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

                def do_POST(self):
                    data = json.loads(self.rfile.read(int(self.headers["content-length"])))
                    traffic.append((self.server.server_port, "POST", self.path, data))
                    if failure == "offer" and self.path == "/v1/offers":
                        self.send_json({"error": "fixture offer denied"}, 409)
                    elif self.path == "/v1/outlooks":
                        self.send_json(published)
                    elif self.path == "/v1/campaigns":
                        self.send_json({"campaign_id": "campaign-1"})
                    elif self.path == "/v1/assets":
                        self.send_json({"asset_id": "asset-1"})
                    elif self.path == "/v1/campaigns/activate":
                        self.send_json({"state": "active"})
                    elif self.path == "/v1/tokens":
                        self.send_json({"token": SUPPORT_TOKEN})
                    elif self.path == "/v1/support/cases":
                        if failure == "secret-refused":
                            self.send_json({"echoed": data}, 403)
                        else:
                            self.send_json({"case_id": "case-8"})
                    elif self.path == "/v1/support/cases/refund":
                        self.send_json({"adjustment_entries": 4})
                    elif self.path == "/v1/incidents":
                        self.send_json({"case_id": "incident-8"})
                    elif self.path == "/v1/certify":
                        self.send_json({
                            **{key: {"ok": True, "violations": 0} for key in ("attestation", "residency", "consent", "settlement")},
                            "certified": True, "total_violations": 0,
                        })
                    elif self.path == "/v1/certify/tamper":
                        self.send_json({"detected": True, "tampered_index": 4 if failure == "wrong-index" else 5})
                    elif self.path == "/v1/partners":
                        self.send_json({"partner_id": "partner-7", "access": "sandbox"})
                    elif self.path == "/v1/partners/certify":
                        self.send_json({"certified": True})
                    elif self.path == "/v1/grants":
                        self.send_json({"credential": CONNECTOR_CREDENTIAL})
                    elif self.path == "/v1/sync/catalog":
                        if failure == "connector-refusal":
                            self.send_json({"echoed": data}, 403)
                        else:
                            self.send_json({"synced": 2})
                    elif self.path == "/v1/sync/inventory":
                        if data["offer_id"] == "erp-clock-02":
                            self.send_json({"status": "revoked"}, 401)
                        else:
                            self.send_json({"stock": 0})
                    elif self.path == "/v1/query":
                        if failure == "query-data":
                            self.send_json({"ok": "forbidden"}, 403)
                        else:
                            self.send_json({"refused": True}, 403)
                    elif self.path == "/v1/webhooks/replay":
                        self.send_json({"duplicate": True})
                    elif self.path == "/v1/grants/revoke":
                        self.send_json({"revoked": True})
                    elif self.path == "/v1/placements":
                        region = "region-a" if data["jurisdiction"] == "region-a" else "region-b"
                        self.send_json({"region": region})
                    elif self.path == "/v1/faults":
                        self.send_json({"armed": data["count"]})
                    elif self.path == "/v1/aggregation/cycle":
                        occurrence = sum(row[2] == self.path for row in traffic)
                        self.send_json({"contributions": [2, 0, 1][occurrence - 1]})
                    elif self.path == "/v1/offers/published":
                        self.send_json({"rematched": 0})
                    else:
                        self.send_json({"ok": True})

                def do_GET(self):
                    port = self.server.server_port
                    traffic.append((port, "GET", self.path, None))
                    if native_edge and self.path in (
                        "/log/handoff/amisad-edge-a.ip.txt", "/log/handoff/amisad-edge-b.ip.txt"
                    ):
                        data = (NODE if "edge-a" in self.path else "127.0.0.72").encode()
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(data)))
                        self.end_headers()
                        self.wfile.write(data)
                        return
                    if native_edge and port == 8080 and self.path == "/health":
                        self.send_json({"ok": True})
                        return
                    if fetched and scenario_name != "failover" and port == 8080:
                        port = 30085
                    routes = {
                        (30081, "/v1/settlements/match/m-1"): {
                            "confirmed": True, "total_cents": 11000, "value_cents": 11000,
                            "entries": [{"party": party} for party in ("network", "seller", "ads", "platform")],
                        },
                        (30083, "/v1/orders/match/m-1"): {
                            "state": "settled", "match_id": "m-1",
                            **({"buyer_label": "refused"} if failure == "buyer" else {}),
                        },
                        (30080, "/v1/orders/h-1"): {"status": "delivered"},
                        (30081, "/v1/attestations/env/e-1"): {
                            "entries": [{"lifecycle": name} for name in ("created", "destroyed", "attested", "executed")],
                        },
                        (30081, "/v1/verify"): {
                            "attestation_ok": True, "settlement_ok": True, "settlement_len": 4, "attestation_len": 4,
                        },
                        (30081, "/health"): {"ok": True},
                        (30083, "/health"): {"ok": True},
                        (30085, "/v1/egress"): {"label": "hidden subscriber" if failure == "egress" else "none"},
                        (30083, "/v1/demand-outlook/2026-Q3"): published,
                        (30087, "/v1/demand-view/2026-Q3"): published,
                        (30085, "/v1/outlooks/2026-Q3"): published,
                        (30085, "/v1/unmet-demand"): {"unmet": [{"category": "housewares", "region": "region-a"}]},
                    }
                    value = routes.get((port, self.path))
                    if (port, self.path) == (30085, "/v1/workbench"):
                        rows = list(published["aggregates"])
                        reads = sum(entry[2] == self.path for entry in traffic)
                        if failure == "below-threshold" or (failure == "leaky-readback" and reads > 1):
                            rows.append({"category": "housewares", "region": "region-b", "demand": 2})
                        value = {"threshold": 5, "aggregates": rows}
                    if scenario == "s002.fitting":
                        if self.path == "/v1/orders":
                            value = {"count": int(failure == "early-commitment")}
                        elif self.path == "/v1/orders/match/m-2":
                            value = {"state": "committed", "match_id": "m-2", "appointment": {"slot_id": "thu-1", "day": "thursday"}}
                        elif self.path == "/v1/settlements/match/m-2":
                            value = {"confirmed": True, "total_cents": 18000, "value_cents": 18000}
                    if scenario == "s005.attribution":
                        if self.path == "/v1/briefs":
                            value = {"briefs": [{"campaign_id": "campaign-1"}]}
                        elif self.path == "/v1/ingress":
                            value = {"entries": ["creative: other" if failure == "missing-creative" else "creative: summer-hero-01"]}
                        elif self.path == "/v1/campaigns/campaign-1":
                            value = {"spent_cents": 2000}
                        elif self.path == "/v1/attributions":
                            value = {"closed_matches": 1, "agency_cents_total": 1200, "creator_cents_total": 800,
                                     "attributions": [{"campaign_id": "campaign-1", "asset_id": "asset-1"}]}
                            if failure == "campaign-leak":
                                value["envelope"] = "forbidden"
                        elif self.path == "/v1/settlements/match/m-5":
                            value = {"confirmed": True, "total_cents": 13000, "value_cents": 13000,
                                     "entries": [{"party": "agency", "amount_cents": 1200},
                                                 {"party": "creator", "amount_cents": 800},
                                                 {"party": "seller", "amount_cents": 9900}]}
                    if scenario == "s008.mediation":
                        if self.path == "/v1/support/cases/case-8":
                            value = {"case_id": "case-8", "state": "open"}
                        elif self.path == "/v1/support/cases/case-8/disclosure":
                            if sum(row[2] == self.path for row in traffic) == 2:
                                self.send_json({"expired": True}, 410)
                                return
                            value = {"artifact": "delivery-photo-ref-77"}
                        elif self.path == "/v1/verify":
                            value = {"attestation_ok": True, "settlement_ok": True, "consent_ok": True}
                        elif self.path == "/v1/settlements/match/m-1" and any(row[2] == "/v1/support/cases/refund" for row in traffic):
                            value = {"total_cents": 0, "value_cents": 11000, "entries": [
                                {"amount_cents": 2750} for _ in range(4)] + [
                                {"entry_type": "adjustment", "case_id": "case-8", "amount_cents": -2750} for _ in range(4)]}
                    if scenario == "s010.certification":
                        if self.path == "/v1/consents":
                            value = {"entries": [
                                {"payload": {"action": "use", "grant_type": "participation", "match_id": "m-1"}},
                                {"payload": {"action": "use", "grant_type": "disclosure", "scope": "case-8"}},
                            ]}
                        elif self.path == "/v1/attestations":
                            value = {"entries": [{"payload": {"lifecycle": f"state-{index}"}} for index in range(8)]}
                        elif self.path == "/v1/access-log":
                            value = {"access": [{"method": "GET"}, {"method": "GET"},
                                                {"method": "POST" if failure == "audit-write" else "GET"}]}
                    if scenario == "s007.inventory":
                        if self.path == "/v1/offers/region/region-a":
                            ids = ["erp-clock-02"]
                            if not any(row[2] == "/v1/sync/inventory" for row in traffic):
                                ids.append("erp-lamp-01")
                            value = {"offers": [{"offer_id": offer} for offer in ids]}
                        elif self.path == "/v1/deltas":
                            delta = next(row[3] for row in traffic if row[2] == "/v1/sync/inventory")
                            value = {"deltas": [{"offer_id": "erp-lamp-01", "stock": 0, "delta_ts": delta["delta_ts"]}]}
                        elif self.path in ("/v1/erp/orders/m-7", "/v1/orders/match/m-7"):
                            value = {"state": "settled"}
                        elif self.path == "/v1/audit":
                            value = {"audit": [{"scope": "settlement", "event": "out-of-scope"}]}
                    if scenario == "s006.mandate":
                        if self.path == "/v1/orders":
                            count = 2 if "buyer approve h-6" in trace.read_text() else 1
                            if failure == "early-delegate" and sum(row[2] == self.path for row in traffic) == 2:
                                count += 1
                            value = {"count": count}
                        elif self.path == "/v1/verify":
                            value = {"attestation_ok": True, "settlement_ok": True, "consent_ok": True}
                    if scenario == "s004.failover":
                        if (port, self.path) == (30082, "/v1/incidents"):
                            value = {"incidents": [{"environment_id": env, "event": "aborted", "fault": "isolation", "region": "region-a"}
                                                   for env in ("abort-1", "abort-2")]}
                        elif self.path.startswith("/v1/attestations/env/"):
                            aborted = self.path.rsplit("/", 1)[-1].startswith("abort-")
                            states = ["created", "attested", "aborted" if aborted else "executed", "destroyed"]
                            rows = [{"lifecycle": state} for state in states]
                            if aborted:
                                rows[2]["fault"] = "isolation"
                            value = {"entries": rows}
                        elif self.path == "/v1/attestations":
                            value = {"entries": [{"payload": {"region": "region-a"}} for _ in range(11)] +
                                                [{"payload": {"region": "region-b" if failure == "wrong-region" else "region-a"}}]}
                        elif self.path == "/v1/incidents/incident-8":
                            value = {"environment_ids": ["abort-1", "abort-2"], "status": "open"}
                    if scenario == "s003.silence":
                        if self.path == "/v1/notifications/dress-3":
                            count = sum(row[2] == self.path for row in traffic)
                            value = {"notifications": [{"kind": "match"}] if count > 1 or failure == "paused-notified" else []}
                        elif self.path == "/v1/orders":
                            count = sum(row[2] == self.path for row in traffic)
                            value = {"count": count, "orders": [{"offer_id": "linen-wrap-09", "state": "committed"}]}
                        elif self.path == "/v1/consents":
                            value = {"entries": [{"payload": {"action": "use"}}, {"payload": {"action": "use"}}]}
                        elif self.path == "/v1/verify":
                            value = {"attestation_ok": True, "settlement_ok": True, "consent_ok": True, "consent_len": 8}
                    self.send_json(value or {"unhandled": True}, 200 if value else 404)

                def log_message(self, *_args):
                    pass

            bindings = [(NODE, port) for port in (8080, 30080, 30081, 30082, 30083, 30084, 30085, 30086, 30087, 30088, 30089)]
            if native_edge and scenario_name == "failover":
                bindings.append(("127.0.0.72", 8080))
            for address in bindings:
                service = services.enter_context(ThreadingHTTPServer(address, Handler))
                thread = Thread(target=service.serve_forever, kwargs={"poll_interval": 0.03}, daemon=True)
                thread.start()
                services.callback(thread.join, 2)
                services.callback(service.shutdown)

            def tool(path, body):
                path.write_text("#!/bin/bash\nset -eu\n" + body, encoding="utf-8")
                path.chmod(0o700)

            tool(tools / "hostname", f'printf "%s\\n" "{NODE} 127.0.0.1"\n')
            tool(tools / "sudo", r'''
echo "sudo $*" >> "$TRACE"
if [[ "$*" == *'FROM ledger.settlement_ledger'* ]]; then
    echo '4|4|1'
elif [[ "$*" == *'FROM ledger.attestation_ledger'* ]]; then
    case "$SCENARIO" in
        s004.failover) echo 12 ;;
        s003.silence)
            if [ "$(grep -c '^buyer resume$' "$TRACE")" -ge 2 ]; then echo 16; else echo 8; fi ;;
        *) echo 8 ;;
    esac
elif [[ "$*" == *"grant_type='mandate'"* ]]; then
    case "$*" in
        *'SELECT count(*)'*) echo 2 ;;
        *) printf '%s\n' delegate approval ;;
    esac
elif [[ "$*" == *'FROM ledger.consent_ledger'* ]]; then
    case "$*" in
        *'SELECT count(*) FROM ledger.consent_ledger') echo 8 ;;
        *'SELECT count(*)'*) echo 1 ;;
        *"= 'use'"*) echo case-8 ;;
        *) echo '{"scope":"case-8","expiry_ts":20,"ts":10,"action":"grant"}' ;;
    esac
else
    [[ "$*" == *"FROM seller.orders WHERE slot_id = 'thu-1' AND state = 'settled'" ]]
    if [ "$FAULT" = no-durable-appointment ]; then echo 0; else echo 1; fi
fi
''')
            tool(tools / "kubectl", r'printf "kubectl %s\n" "$*" >> "$TRACE"' + "\n")
            for name in ("curl", "python3"):
                tool(tools / name, f'echo "legacy {name}" >> "$TRACE"\nexit 42\n')
            tool(poc / "target/release/buyer-client", '''
echo "buyer $*" >> "$TRACE"
[[ "$COORDINATOR_URL" = "http://127.0.0.71:30080" && "$IDENTITY_URL" = "http://127.0.0.71:30084" ]]
case "$*" in
    submit)
        if [ "$SCENARIO" = s007.inventory ]; then
            echo '{"match_id":"m-7","offer":{"offer_id":"erp-clock-02"}}'
        else
            echo '{"handle":"h-1","match_id":"m-1","environment_id":"e-1","offer":{"price_cents":11000}}'
        fi ;;
    'wait h-1') echo delivered ;;
    shortlist)
        if [ "$FAULT" = excluded-offer ]; then
            echo '{"handle":"h-2","shortlist":[{"offer_id":"linen-midi-04"},{"offer_id":"dusty-blue-02"}]}'
        else
            echo '{"handle":"h-2","shortlist":[{"offer_id":"linen-midi-04"}]}'
        fi ;;
    'book h-2 linen-midi-04 thu-1') echo '{"match_id":"m-2","slot_id":"thu-1"}' ;;
    campaign) echo '{"handle":"h-5","shortlist":[{"offer_id":"serving-set-01","campaign":{"campaign_id":"campaign-1","asset_id":"asset-1","creator":"kai","creative":"summer-hero-01"}}]}' ;;
    'book h-5 serving-set-01') echo '{"match_id":"m-5","boosted":true}' ;;
    'disclose case-8 delivery-photo-ref-77 10') echo '{"scope":"case-8","expiry_ts":20}' ;;
    'disclose case-8 delivery-photo-ref-77 120'|pause|withdraw) echo '{}' ;;
    resume) printf '%s\n' '{}' '{"rematched":1}' ;;
    'open dress') echo '{"handle":"dress-3","status":"open"}' ;;
    'open decanter')
        if grep -q '^buyer pause$' "$TRACE"; then echo 'request refused (403)' >&2; exit 1; fi
        echo '{"handle":"decanter-3","status":"open"}' ;;
    consents)
        if [ "$FAULT" = 'consent-use-during-revocation' ]; then
            use='{"grant_type":"participation","action":"use","match_id":"m-1"},'
        else
            use=''
        fi
        printf '%s%s%s\n' '{"participation":"granted","contribution":"granted","history":[
            {"grant_type":"contribution","action":"grant"},
            {"grant_type":"participation","action":"grant"},
            {"grant_type":"participation","action":"revoke"},' "$use" '
            {"grant_type":"contribution","action":"revoke"},
            {"grant_type":"contribution","action":"grant"},
            {"grant_type":"participation","action":"grant"},
            {"grant_type":"participation","action":"use","match_id":"m-1"}]}' ;;
    'grant-mandate pat housewares 14000') echo '{"per_item_cents":14000,"principal":"actor-1","delegate":"actor-2"}' ;;
    'workspace pat')
        if grep -q '^buyer revoke-mandate ' "$TRACE"; then echo '{"principals":[]}'
        else echo '{"principals":[{"category":"housewares","per_item_cents":14000}]}' ; fi ;;
    'delegate-need pat housewares 12000')
        if grep -q '^buyer revoke-mandate ' "$TRACE"; then
            if [ "$FAULT" = 'revoked-delegate' ]; then echo "no valid mandate"; exit 0; fi
            echo "no valid mandate" >&2; exit 1
        else echo '{"status":"committed","via":"delegate"}'; fi ;;
    'delegate-need pat housewares 20000 premium') echo '{"status":"held-for-approval","handle":"h-6"}' ;;
    'delegate-need pat dresses 20000') echo 'out of mandate scope' >&2; exit 1 ;;
    'approve h-6') echo '{"status":"committed","via":"approval"}' ;;
    activity) echo '{"activity":[{"kind":"delegated-match","via":"delegate","mandate":true,"actor":"actor-2","principal":"actor-1"}]}' ;;
    'revoke-mandate pat') echo '{"revoked":true}' ;;
    'notifications h-2')
        if grep -q '^buyer book ' "$TRACE"; then
            echo '{"notifications":[{"kind":"shortlist"},{"kind":"booking-confirmed"}]}'
        else
            echo '{"notifications":[{"kind":"shortlist"}]}'
        fi ;;
    *) exit 51 ;;
esac
''')
            (poc / "test/amisad-scenario.sh").write_text(
                """amisad_start_slice_runtime() {
    printf 'slice %s %s\\n' "$1" "$2" >> "$TRACE"
    SLICE_EP=http://127.0.0.71:30085
}
amisad_edge_addr() {
    if [ "$1" = amisad-edge-a ]; then printf '127.0.0.71'; else printf '127.0.0.72'; fi
}
amisad_deliver_slice_runtime() {
    printf 'edge %s %s\\n' "$1" "$4" >> "$TRACE"
}
amisad_wait_slice_runtime() {
    printf 'ready %s\\n' "$1" >> "$TRACE"
}
""",
                encoding="utf-8",
            )
            env = os.environ | {"HOME": str(home), "USER": "", "SUDO_USER": "", "FAULT": failure or "", "SCENARIO": scenario,
                "TRACE": str(trace), "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                "YURUNA_STATUS_SERVICE_IP": NODE}
            if native_edge:
                env["YURUNA_STATUS_SERVICE_PORT"] = "30080"
                env["EDGE_HOST"] = ""
                tool(tools / "getent", "exit 1\n")
                tool(tools / "ssh", r'''
edge=a
if [[ "$*" == *amisad-edge-b-admin* ]]; then edge=b; fi
case "${@: -1}" in
    'cat '*)
        echo "discover $edge" >> "$TRACE"
        if [[ "$edge:$FAULT" = b:older-edge ]]; then echo 'ExecStart=/opt/older edge-report'
        else echo 'ExecStart="/usr/local/lib/yuruna/amisad-artifacts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/amisad-provision" edge-report'
        fi ;;
    *' --help') echo "capabilities $edge" >> "$TRACE"; echo 'slice-stop slice-start' ;;
    *' slice-stop') echo "stop $edge" >> "$TRACE" ;;
    *' slice-start '*)
        region=""
        case "$SCENARIO" in s004.failover|s010.certification) region="region-$edge";; esac
        [[ "${@: -1}" = *"'$region' 'http://127.0.0.71:30081' 'http://127.0.0.71:30082'" ]]
        IFS= read -r token
        [[ "$token" = fixture-token && "$*" != *fixture-token* ]]
        echo "start $edge" >> "$TRACE" ;;
    'hostname -I') echo "address $edge" >> "$TRACE"; echo '127.0.0.71' ;;
    *) exit 61 ;;
esac
''')
                tool(tools / "scp", r'''
edge=a
if [[ "${@: -1}" == *amisad-edge-b-admin* ]]; then edge=b; fi
echo "copy $edge" >> "$TRACE"
[[ "$edge:$FAULT" != b:second-copy ]]
''')
                tool(tools / "kubectl", r'''
if [[ "$*" == *' get secret amisad-ledger-write '* ]]; then
    printf 'Zml4dHVyZS10b2tlbg=='
else
    printf 'kubectl %s\n' "$*" >> "$TRACE"
fi
''')
            self.assertTrue(BIN.is_file(), str(BIN))
            if fetched:
                command = ["bash", str(ENTRY).format(scenario)]
            elif scenario_name in ("failover", "fulfillment"):
                command = ["bash", str(FIXTURES / f"{scenario_name}-before-rust.sh.fixture")]
            else:
                command = [BIN, f"scenario-{scenario_name}", NODE]
                if scenario_name != "suppression":
                    command.append("http://127.0.0.71:30085")
            run = subprocess.run(command, cwd=poc, env=env, capture_output=True, text=True, timeout=25)
            return run, traffic, trace.read_text(encoding="utf-8") if trace.exists() else ""

    def test_normal_entrypoint_registers_executes_and_checks_durable_restart(self):
        run, traffic, trace = self.run_workload()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s001.fulfillment HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 9)
        self.assertNotIn("legacy ", trace)
        self.assertIn("slice http://127.0.0.71:30081 http://127.0.0.71:30082", trace)
        self.assertEqual([line.split(" ", 1)[0] for line in trace.splitlines()],
                         ["slice", "buyer", "buyer", "sudo", "kubectl", "kubectl", "kubectl"])
        self.assertEqual([route for _, _, route, _ in traffic], [
            "/v1/edges", "/v1/offers", "/v1/offers", "/v1/orders/advance", "/v1/orders/advance",
            "/v1/settlements/match/m-1", "/v1/orders/match/m-1", "/v1/orders/h-1",
            "/v1/attestations/env/e-1", "/v1/verify", "/v1/egress",
            "/health", "/health", "/v1/verify", "/v1/orders/match/m-1",
        ])
        self.assertEqual(traffic[0][3], {"region": "region-a", "endpoint": f"http://{NODE}:30085"})
        self.assertEqual([traffic[i][3]["state"] for i in (3, 4)], ["provisioning", "fulfilled"])

    def test_failed_assertions_and_post_never_restart_or_replay(self):
        for fault, error in (("buyer", "seller order leaked buyer field"),
                             ("egress", "egress leaked: subscriber"),
                             ("offer", "fixture offer denied")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault)
                self.assertEqual(run.returncode, 1)
                self.assertIn(error, run.stderr)
                self.assertNotIn("HAPPY PATH PASSED", run.stdout)
                self.assertNotIn("kubectl ", trace)
                self.assertNotIn("sudo ", trace)
                self.assertNotIn("legacy ", trace)
                if fault == "offer":
                    self.assertEqual([entry[2] for entry in traffic], ["/v1/edges", "/v1/offers"])

    def test_suppression_preserves_seed_counts_and_downstream_checks(self):
        run, traffic, trace = self.run_workload(scenario="s009.suppression")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s009.suppression HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 5)
        self.assertEqual(trace, "")
        self.assertEqual([(row[3]["kind"], row[3]["region"]) for row in traffic[:10]],
                         [("need", "region-a")] * 6 + [("offer", "region-a"), ("need", "region-b")] * 2)
        self.assertEqual([row[2] for row in traffic[10:]], [
            "/v1/workbench", "/v1/outlooks", "/v1/demand-outlook/2026-Q3", "/v1/demand-view/2026-Q3",
            "/v1/outlooks/2026-Q3", "/v1/unmet-demand", "/v1/workbench", "/v1/unmet-demand",
        ])

    def test_suppression_refuses_publishing_and_later_downstream_leaks(self):
        for fault, error in (("below-threshold", "did not suppress below-threshold"),
                             ("leaky-readback", "below-threshold region leaked downstream")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault, "s009.suppression")
                self.assertEqual(run.returncode, 1)
                self.assertIn(error, run.stderr)
                self.assertNotIn("HAPPY PATH PASSED", run.stdout)
                self.assertEqual(trace, "")
                self.assertEqual(sum(row[2] == "/v1/outlooks" for row in traffic), int(fault == "leaky-readback"))

    def test_fitting_checks_shortlist_booking_notifications_and_durable_appointment(self):
        run, traffic, trace = self.run_workload(scenario="s002.fitting")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s002.fitting HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 7)
        self.assertNotIn("legacy ", trace)
        self.assertEqual([line for line in trace.splitlines() if line.startswith("buyer ")], [
            "buyer shortlist", "buyer notifications h-2", "buyer book h-2 linen-midi-04 thu-1", "buyer notifications h-2",
        ])
        self.assertEqual([row[3]["offer_id"] for row in traffic if row[2] == "/v1/offers"], [
            "linen-midi-04", "dusty-blue-02", "silk-slip-03", "wool-midi-07", "linen-wrap-08",
        ])
        self.assertEqual([row[3]["state"] for row in traffic if row[2] == "/v1/orders/advance"], ["provisioning", "fulfilled"])

    def test_fitting_refuses_wrong_shortlist_early_commitment_and_missing_rows(self):
        for fault, code, error in (("excluded-offer", 1, "dusty-blue-02 leaked"),
                                   ("early-commitment", 1, "A commitment exists before booking"),
                                   ("no-durable-appointment", 9, "no settled thu-1 order")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault, "s002.fitting")
                self.assertEqual(run.returncode, code, run.stderr)
                self.assertIn(error, run.stderr)
                self.assertNotIn("HAPPY PATH PASSED", run.stdout)
                self.assertNotIn("legacy ", trace)
                if code == 1:
                    self.assertNotIn("buyer book ", trace)
                    self.assertNotIn("/v1/orders/advance", [row[2] for row in traffic])

    def test_attribution_matches_campaign_creative_settlement_and_budget(self):
        run, traffic, trace = self.run_workload(scenario="s005.attribution")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s005.attribution HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 9)
        self.assertNotIn("legacy ", trace)
        self.assertIn("buyer book h-5 serving-set-01", trace)
        self.assertEqual([row[2] for row in traffic], [
            "/v1/edges", "/v1/offers", "/v1/campaigns", "/v1/briefs", "/v1/briefs", "/v1/assets",
            "/v1/campaigns/activate", "/v1/ingress", "/v1/orders/advance", "/v1/orders/advance",
            "/v1/settlements/match/m-5", "/v1/attributions", "/v1/campaigns/campaign-1", "/v1/attributions",
        ])

    def test_attribution_refuses_a_mismatched_creative_and_buyer_leak(self):
        for fault, error in (("missing-creative", "creative is missing from the ingress log"),
                             ("campaign-leak", "campaign side leaked: envelope")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault, "s005.attribution")
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertIn(error, run.stderr)
                self.assertNotIn("HAPPY PATH PASSED", run.stdout)
                self.assertNotIn("legacy ", trace)
                if fault == "missing-creative":
                    self.assertNotIn("buyer book ", trace)
                    self.assertEqual(traffic[-1][2], "/v1/ingress")

    def test_mediation_keeps_scoped_consent_and_compensating_entries_until_expiry(self):
        started = monotonic()
        run, traffic, trace = self.run_workload(scenario="s008.mediation")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s008.mediation HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 9)
        self.assertGreaterEqual(monotonic() - started, 14)
        authenticated = [row for row in traffic if row[1] == "POST" and row[2].startswith("/v1/support/")]
        self.assertEqual([row[2] for row in authenticated], ["/v1/support/cases", "/v1/support/cases/disclosure/request",
                         "/v1/support/cases/refund", "/v1/support/cases/resolve"])
        self.assertTrue(all(row[3]["token"] == SUPPORT_TOKEN for row in authenticated))
        self.assertNotIn(SUPPORT_TOKEN, run.stdout + run.stderr + trace)
        self.assertNotIn("legacy ", trace)
        self.assertEqual([line for line in trace.splitlines() if line.startswith("buyer ")],
                         ["buyer submit", "buyer disclose case-8 delivery-photo-ref-77 10"])

    def test_mediation_keeps_a_refused_request_body_and_authorization_off_diagnostics(self):
        run, traffic, trace = self.run_workload("secret-refused", "s008.mediation")
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertIn("/v1/support/cases: HTTP 403", run.stderr)
        self.assertNotIn(SUPPORT_TOKEN, run.stdout + run.stderr + trace)
        self.assertNotIn("legacy ", trace)
        self.assertNotIn("disclose", trace)
        self.assertEqual(traffic[-1][2], "/v1/support/cases")

    def test_certification_preserves_evidence_and_checks_only_the_mutated_copy(self):
        run, traffic, trace = self.run_workload(scenario="s010.certification")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s010.certification HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 5)
        mutation = next(row[3]["entries"] for row in traffic if row[2] == "/v1/certify/tamper")
        self.assertEqual([row["payload"]["lifecycle"] for row in mutation],
                         [f"state-{index}" if index != 5 else "tampered-lifecycle" for index in range(8)])
        self.assertEqual([row[2] for row in traffic if row[2].startswith("/v1/attestations")], ["/v1/attestations"])
        self.assertEqual([line for line in trace.splitlines() if line.startswith("buyer ")], [
            "buyer submit", "buyer submit", "buyer resume", "buyer pause",
            "buyer grant-mandate pat housewares 14000", "buyer disclose case-8 delivery-photo-ref-77 120",
        ])
        self.assertNotIn(SUPPORT_TOKEN, run.stdout + run.stderr + trace)
        self.assertNotIn("legacy ", trace)

    def test_certification_refuses_wrong_record_and_nonread_auditor_activity(self):
        for fault, error in (("wrong-index", "failed to localize the altered fixture record"),
                             ("audit-write", "lacks sufficient read-only evidence")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault, "s010.certification")
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertIn(error, run.stderr)
                self.assertNotIn("HAPPY PATH PASSED", run.stdout)
                self.assertNotIn("legacy ", trace)
                if fault == "wrong-index":
                    self.assertEqual(traffic[-1][2], "/v1/certify/tamper")

    def test_inventory_honors_zero_stock_scope_and_revoked_credential(self):
        run, traffic, trace = self.run_workload(scenario="s007.inventory")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s007.inventory HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 14)
        inventory = [row[3] for row in traffic if row[2] == "/v1/sync/inventory"]
        self.assertEqual([item["offer_id"] for item in inventory], ["erp-lamp-01", "erp-clock-02"])
        self.assertTrue(all(item["credential"] == CONNECTOR_CREDENTIAL for item in inventory))
        self.assertNotIn(CONNECTOR_CREDENTIAL, run.stdout + run.stderr + trace)
        self.assertNotIn("legacy ", trace)

    def test_inventory_refuses_catalog_and_out_of_scope_data_while_hiding_credentials(self):
        for fault, code, route, error in (("connector-refusal", 1, "/v1/sync/catalog", "HTTP 403"),
                                          ("query-data", 9, "/v1/query", "out-of-scope request returned data")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault, "s007.inventory")
                self.assertEqual(run.returncode, code, run.stderr)
                self.assertIn(error, run.stderr)
                self.assertNotIn(CONNECTOR_CREDENTIAL, run.stdout + run.stderr + trace)
                self.assertNotIn("legacy ", trace)
                self.assertEqual(traffic[-1][2], route)

    def test_mandate_checks_approval_scope_revocation_and_exact_consent_uses(self):
        run, traffic, trace = self.run_workload(scenario="s006.mandate")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s006.mandate HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 13)
        self.assertEqual([row[2] for row in traffic].count("/v1/orders"), 3)
        self.assertIn("buyer approve h-6", trace)
        self.assertIn("ORDER BY id", trace)
        self.assertNotIn("legacy ", trace)

    def test_mandate_refuses_early_commitment_and_post_revocation_success(self):
        for fault, error in (("early-delegate", "over-cap match committed before approval"),
                             ("revoked-delegate", "did not fail with no valid mandate")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault, "s006.mandate")
                self.assertEqual(run.returncode, 9, run.stderr)
                self.assertIn(error, run.stderr)
                self.assertNotIn("HAPPY PATH PASSED", run.stdout)
                self.assertNotIn("legacy ", trace)
                if fault == "early-delegate":
                    self.assertNotIn("buyer approve", trace)
                    self.assertEqual(traffic[-1][2], "/v1/orders")

    def test_failover_requires_both_edges_and_verifies_only_region_a_lifecycles(self):
        run, traffic, trace = self.run_workload(scenario="s004.failover")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s004.failover HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 12)
        self.assertEqual(trace.splitlines()[:4], [
            "edge amisad-edge-a-admin@127.0.0.71 region-a", "edge amisad-edge-b-admin@127.0.0.72 region-b",
            "ready http://127.0.0.71:8080", "ready http://127.0.0.72:8080",
        ])
        self.assertEqual(next(row[3] for row in traffic if row[2] == "/v1/faults"), {"mode": "isolation", "count": 2})
        self.assertNotIn("legacy ", trace)

    def test_failover_refuses_out_of_region_evidence_before_settlement(self):
        run, traffic, trace = self.run_workload("wrong-region", "s004.failover")
        self.assertEqual(run.returncode, 1, run.stderr)
        self.assertIn("only the twelve region-a lifecycle events", run.stderr)
        self.assertNotIn("HAPPY PATH PASSED", run.stdout)
        self.assertNotIn("legacy ", trace)
        self.assertEqual(traffic[-1][2], "/v1/attestations")

    def test_enrolled_failover_admits_both_edges_before_delivery_and_runs_the_scenario(self):
        run, traffic, trace = self.run_workload(scenario="s004.failover", fetched=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s004.failover HAPPY PATH PASSED", run.stdout)
        self.assertEqual(trace.splitlines()[:10], [
            "discover a", "capabilities a", "discover b", "capabilities b",
            "stop a", "copy a", "start a", "stop b", "copy b", "start b",
        ])
        self.assertNotIn("edge amisad", trace)
        self.assertNotIn("fixture-token", run.stdout + run.stderr + trace)
        self.assertEqual([row[2] for row in traffic[:4]], [
            "/log/handoff/amisad-edge-a.ip.txt", "/log/handoff/amisad-edge-b.ip.txt", "/health", "/health",
        ])

    def test_every_fetched_entry_uses_the_staged_runtime_and_only_its_required_edges(self):
        for scenario in ("s001.fulfillment", "s002.fitting", "s003.silence", "s005.attribution",
                         "s006.mandate", "s007.inventory", "s008.mediation", "s009.suppression",
                         "s010.certification"):
            with self.subTest(scenario=scenario):
                run, traffic, trace = self.run_workload(scenario=scenario, fetched=True)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertIn(f"{scenario} HAPPY PATH PASSED", run.stdout)
                self.assertNotIn("legacy ", trace)
                self.assertNotIn("fixture-token", run.stdout + run.stderr + trace)
                if scenario == "s009.suppression":
                    self.assertFalse(trace)
                    self.assertFalse(any("handoff" in row[2] for row in traffic))
                else:
                    self.assertEqual(trace.splitlines()[:6], [
                        "discover a", "capabilities a", "stop a", "copy a", "start a", "address a",
                    ])
                    self.assertEqual([row[2] for row in traffic[:2]], ["/log/handoff/amisad-edge-a.ip.txt", "/health"])

    def test_current_failover_refuses_an_older_edge_before_either_edge_is_stopped(self):
        run, traffic, trace = self.run_workload("older-edge", "s004.failover", fetched=True)
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertIn("has no enrolled slice provisioner", run.stderr)
        self.assertEqual(trace.splitlines(), ["discover a", "capabilities a", "discover b"])
        self.assertEqual([row[2] for row in traffic], [
            "/log/handoff/amisad-edge-a.ip.txt", "/log/handoff/amisad-edge-b.ip.txt",
        ])

    def test_failover_uses_legacy_only_before_any_edge_effect(self):
        run, _, trace = self.run_workload("older-edge", "s004.failover", native_failover=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(trace.splitlines()[:4], [
            "discover a", "capabilities a", "discover b", "edge amisad-edge-a-admin@127.0.0.71 region-a",
        ])
        self.assertNotIn("stop a", trace)
        run, _, trace = self.run_workload("second-copy", "s004.failover", native_failover=True)
        self.assertEqual(run.returncode, 7, run.stderr)
        self.assertIn("slice-runtime delivery to amisad-edge-b (127.0.0.72) failed", run.stderr)
        self.assertEqual(trace.splitlines()[-3:], ["start a", "stop b", "copy b"])
        self.assertNotIn("edge amisad", trace)

    def test_silence_waits_through_pause_and_checks_positive_resumption_and_consent(self):
        run, traffic, trace = self.run_workload(scenario="s003.silence")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("s003.silence HAPPY PATH PASSED", run.stdout)
        self.assertEqual(len([line for line in run.stdout.splitlines() if line.startswith("ASSERT ")]), 20)
        self.assertEqual([row[2] for row in traffic].count("/v1/aggregation/cycle"), 3)
        self.assertEqual([line for line in trace.splitlines() if line.startswith("buyer ")], [
            "buyer resume", "buyer submit", "buyer open dress", "buyer open decanter", "buyer pause",
            "buyer open decanter", "buyer withdraw", "buyer resume", "buyer consents",
        ])
        self.assertNotIn("legacy ", trace)

    def test_silence_refuses_paused_notifications_and_invalid_history(self):
        for fault, error in (("paused-notified", "paused buyer received a notification"),
                             ("consent-use-during-revocation", "falls in the revocation window")):
            with self.subTest(fault=fault):
                run, traffic, trace = self.run_workload(fault, "s003.silence")
                self.assertEqual(run.returncode, 1, run.stderr)
                self.assertIn(error, run.stderr)
                self.assertNotIn("HAPPY PATH PASSED", run.stdout)
                self.assertNotIn("legacy ", trace)
                if fault == "paused-notified":
                    self.assertEqual(traffic[-1][2], "/v1/notifications/dress-3")


@unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() != 0 and which("ssh-keygen"),
                     "needs unprivileged OpenSSH")
class CoreUsersContract(unittest.TestCase):
    def setUp(self):
        scratch = TemporaryDirectory(prefix="amisad-user-stage-")
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name) / "admin's home"
        self.home.mkdir()
        self.ssh = self.home / ".ssh"
        self.key = self.ssh / "amisad-demo-key"
        self.public = self.key.with_suffix(".pub")
        self.trace = self.home / "trace"
        self.provision = self.home / "amisad.dev/poc/target/release/amisad-provision"
        self.provision.parent.mkdir(parents=True)
        self.keygen = which("ssh-keygen")
        tools = self.home / "tools"
        tools.mkdir()
        self.env = dict(os.environ, PATH=f"{tools}{os.pathsep}{os.environ['PATH']}",
                        FIXTURE_LOGIN_HOME=str(self.home), FIXTURE_UID=str(os.geteuid()),
                        FIXTURE_GID=str(os.getegid()), FIXTURE_TRACE=str(self.trace),
                        FIXTURE_KEYGEN=self.keygen, HOME=str(self.home / "unrelated-home"),
                        FIXTURE_ADDED_USER=str(self.home / "maya"))
        self.env.pop("SUDO_USER", None)
        for name, script in {
            "getent": 'printf "demo-owner:x:%s:%s::%s:/bin/bash\\n" "$FIXTURE_UID" "$FIXTURE_GID" "$FIXTURE_LOGIN_HOME"',
            "id": '''
case "$*" in
    '-un') printf 'demo-owner\\n';;
    '-u maya') [ -f "$FIXTURE_ADDED_USER" ];;
    '-u '*) exit 0;;
    *) exit 99;;
esac''',
            "sudo": '''
printf 'sudo %s\\n' "$*" >> "$FIXTURE_TRACE"
[ "${1:-}" != -n ] || shift
[ "$#" -eq 5 ] && [ "$1" = adduser ] && [ "$2" = --disabled-password ] &&
    [ "$3" = --gecos ] && [ -z "$4" ] && [ "$5" = maya ] || exit 99
touch "$FIXTURE_ADDED_USER"''',
            "chown": '''
printf 'legacy ownership\\n' >> "$FIXTURE_TRACE"
[ "$1" = -R ] && [ "$2" = demo-owner:demo-owner ] && [ "$3" = "$FIXTURE_LOGIN_HOME/.ssh" ]''',
            "ssh-keygen": '''
printf 'key %s\\n' "$1" >> "$FIXTURE_TRACE"
if [ "${FIXTURE_GENERATION_FAIL:-}" = 1 ] && [ "$1" = -q ]; then
    exit 23
fi
exec "$FIXTURE_KEYGEN" "$@"''',
        }.items():
            tool = tools / name
            tool.write_text("#!/bin/sh\n" + script + "\n")
            tool.chmod(0o755)

    def stage(self, entry=None, **env):
        return subprocess.run(
            ["bash", str(entry or str(ENTRY).format("users"))], env=dict(self.env, **env),
            capture_output=True, text=True, timeout=20,
        )

    def assert_pair(self, run):
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("demo key fingerprint:", run.stdout)
        self.assertNotIn("OPENSSH PRIVATE KEY", run.stdout + run.stderr)
        expected = subprocess.check_output([self.keygen, "-y", "-P", "", "-f", self.key])
        self.assertEqual(self.public.read_bytes(), expected)
        self.assertTrue(expected.startswith(b"ssh-ed25519 "))
        self.assertEqual(stat.S_IMODE(self.ssh.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.key.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.public.stat().st_mode), 0o644)
        self.assertEqual(self.key.stat().st_uid, os.geteuid())
        self.assertFalse((self.home / "unrelated-home").exists())
        self.assertEqual(list(self.ssh.glob(".amisad-demo.*")), [])

    def test_enrolled_creation_and_retry_preserve_working_private_key(self):
        copy2(BIN, self.provision)
        self.assert_pair(self.stage())
        before = self.key.read_bytes()
        authorized = self.ssh / "authorized_keys"
        authorized.write_bytes(b"unrelated key\n")
        self.public.write_bytes(b"old public key\n")
        second = self.stage()
        self.assert_pair(second)
        self.assertIn("keeping the existing demo key", second.stdout)
        self.assertEqual(self.key.read_bytes(), before)
        self.assertEqual(authorized.read_bytes(), b"unrelated key\n")
        trace = self.trace.read_text().splitlines()
        self.assertEqual(trace.count("sudo -n adduser --disabled-password --gecos  maya"), 1)
        self.assertEqual(trace.count("key -q"), 1)
        self.assertNotIn("legacy ownership", trace)

    def test_failed_rotation_keeps_existing_bytes_without_shell_replay(self):
        copy2(BIN, self.provision)
        self.ssh.mkdir(mode=0o700)
        self.key.write_bytes(b"invalid private key\n")
        self.public.write_bytes(b"existing public key\n")
        failed = self.stage(FIXTURE_GENERATION_FAIL="1")
        self.assertEqual(failed.returncode, 23, failed.stderr)
        self.assertEqual(self.key.read_bytes(), b"invalid private key\n")
        self.assertEqual(self.public.read_bytes(), b"existing public key\n")
        self.assertEqual(list(self.ssh.glob(".amisad-demo.*")), [])
        self.assertEqual(self.trace.read_text().splitlines().count("key -q"), 1)
        self.assert_pair(self.stage())

    def test_refuses_a_linked_key_without_touching_the_destination(self):
        copy2(BIN, self.provision)
        self.ssh.mkdir(mode=0o700)
        outside = self.home / "outside-key"
        outside.write_bytes(b"unrelated material\n")
        self.public.symlink_to(outside)
        refused = self.stage()
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertIn("Could not reconcile the core demo SSH key", refused.stderr)
        self.assertEqual(outside.read_bytes(), b"unrelated material\n")
        self.assertTrue(self.public.is_symlink())
        self.assertFalse(self.key.exists())

    def test_older_artifact_uses_existing_users_entry_once(self):
        self.provision.write_text("#!/bin/sh\nprintf 'Usage: amisad-provision <core-ready|core-deploy>\\n'\n")
        self.provision.chmod(0o755)
        self.assert_pair(self.stage(LEGACY_CORE_USERS))
        self.assertEqual(self.trace.read_text().splitlines(), [
            "sudo adduser --disabled-password --gecos  maya", "key -q", "key -y", "legacy ownership", "key -lf",
        ])

    def test_current_entry_requires_native_users_before_changing_accounts_or_keys(self):
        missing = self.stage()
        self.assertEqual(missing.returncode, 1, missing.stderr)
        self.assertIn("core users provisioner is unavailable", missing.stderr)
        self.assertFalse(self.ssh.exists())
        self.assertFalse(self.trace.exists())

    def test_elevated_entry_starts_the_staged_binary_as_the_login(self):
        copy2(BIN, self.provision)
        shim = self.home / "tools/runuser"
        shim.write_text('''#!/bin/sh
[ "$1" = -u ] && [ "$2" = demo-owner ] && [ "$3" = -- ] &&
    [ "$4" = "$FIXTURE_LOGIN_HOME/amisad.dev/poc/target/release/amisad-provision" ] &&
    [ "$5" = core-users ] && [ "$#" -eq 5 ] || exit 99
printf 'drop privileges\\n' >> "$FIXTURE_TRACE"
shift 3
exec "$@"
''')
        shim.chmod(0o755)
        root_entry = self.home / "elevated-users.sh"
        root_entry.write_text(Path(str(ENTRY).format("users")).read_text().replace("$EUID", "0"))
        self.assert_pair(self.stage(root_entry, SUDO_USER="demo-owner"))
        self.assertEqual(self.trace.read_text().splitlines()[0], "drop privileges")
        self.assertNotIn("legacy ownership", self.trace.read_text())

    def test_native_login_uses_the_local_key_and_exact_noninteractive_host_policy(self):
        copy2(BIN, self.provision)
        self.assert_pair(self.stage())
        shim = self.home / "tools/ssh"
        shim.write_text('''#!/bin/sh
printf '%s\\n' "$@" > "$FIXTURE_TRACE.login"
exit "${FIXTURE_SSH_EXIT:-0}"
''')
        shim.chmod(0o755)
        command = [self.provision, "core-edge-login", "amisad-edge-a-admin"]
        trace = self.home / "trace.login"
        denied = subprocess.run([*command, "-oProxyCommand=bad"], env=self.env, capture_output=True, timeout=15)
        self.assertEqual(denied.returncode, 2)
        self.assertFalse(trace.exists())
        run = subprocess.run([*command, "::1"], env=self.env, capture_output=True, timeout=15)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(trace.read_text().splitlines(), [
            "-i", str(self.key), "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o",
            "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15", "--", "amisad-edge-a-admin@::1", "true",
        ])
        refused = subprocess.run([*command, "127.0.0.71"], env=dict(self.env, FIXTURE_SSH_EXIT="255"),
                                 capture_output=True, timeout=15)
        self.assertEqual(refused.returncode, 255)
        self.assertNotIn(b"OPENSSH PRIVATE KEY", refused.stdout + refused.stderr)


if __name__ == "__main__":
    unittest.main()
