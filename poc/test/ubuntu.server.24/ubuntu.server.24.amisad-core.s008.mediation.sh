#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s008.mediation run on amisad-core: zero-knowledge dispute
# mediation and settlement adjustment. From a settled order, Maya reports
# non-delivery; a support case opens carrying operational metadata only (no
# buyer identity); Sam requests and Maya grants a scoped, time-boxed
# disclosure; the refund posts as compensating settlement entries referencing
# the case (original history untouched); and after the grant expires the
# disclosed artifact is no longer accessible. EDGE_HOST (optional override).
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"
SELLER="http://${NODE_IP}:30083"
PLATFORM="http://${NODE_IP}:30086"

echo "== slice-runtime (edge amisad-edge-a) =="
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
SSH_OPTS=(-i "$REAL_HOME/.ssh/amisad-demo-key" -o StrictHostKeyChecking=accept-new)
# --- REGION: https://yuruna.link/network#defining-the-guest-to-guest-rail
# Where a peer edge answers. The rail is tried first: on a host that has one,
# both guests hold a second address on a network the site DHCP server cannot
# move, and libvirt's resolver answers the peer's reserved name -- so there is
# nothing to publish and nothing to go stale. The answer is accepted only from
# the rail subnet, because these VM names also resolve on the LAN and that is
# precisely the answer that can be out of date.
#
# The published handoff file stays underneath, unchanged. Two of the three host
# types this workload runs on have no libvirt network at all, so the rail is an
# optimisation here and never a requirement.
# --- REGION: a failed service call must name the service and what it answered
# `amisad_curl` prints nothing on a non-2xx and exits non-zero. On the LEFT of a
# pipe that is invisible: the parser downstream reads empty stdin and reports a
# syntax error at line 1, so a service that never answered is diagnosed as
# malformed data -- the run then ends on a traceback naming neither the URL nor
# the status. Takes the same arguments as `amisad_curl` and, on success, writes the
# body to stdout unchanged, so callers pipe exactly as they did before.
amisad_curl() { # <same args as curl -sf>
    local out status body url='' arg
    for arg in "$@"; do
        case "$arg" in http://*|https://*) url="$arg" ;; esac
    done
    if ! out=$(curl -sS -w '\n%{http_code}' "$@"); then
        printf '\n!! SERVICE CALL FAILED\n!!   url:    %s\n!!   cause:  the request did not complete (curl reported it above)\n\n' \
            "${url:-<no url among the arguments>}" >&2
        return 1
    fi
    status=${out##*$'\n'}
    body=${out%$'\n'*}
    case "$status" in
        2[0-9][0-9]) ;;
        *)
            printf '\n!! SERVICE CALL FAILED\n!!   url:    %s\n!!   status: HTTP %s\n!!   body:   %s\n\n' \
                "${url:-<no url among the arguments>}" "$status" "$(printf '%.400s' "${body:-<empty>}")" >&2
            return 1
            ;;
    esac
    # A 2xx with no body is normal for a POST and fatal for a caller about to
    # parse it. Say so here rather than leave the parser to report a syntax
    # error at line 1 of nothing.
    if [ -z "$body" ]; then
        printf '!! note: %s answered HTTP %s with an empty body\n' "$url" "$status" >&2
    fi
    printf '%s' "$body"
}

amisad_edge_addr() { # <edge-vm-name>
    local edge="$1" ip
    ip=$(getent hosts "$edge" 2>/dev/null | awk '{print $1}' | grep -m1 '^192\.168\.122\.' || true)
    if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
    wget --no-proxy --timeout=10 --tries=2 -qO- \
        "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/log/handoff/${edge}.ip.txt" 2>/dev/null || true
}

if [ -z "${EDGE_HOST:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ]; then
    EDGE_IP=$(amisad_edge_addr amisad-edge-a)
    if [ -n "$EDGE_IP" ]; then EDGE_HOST="amisad-edge-a-admin@${EDGE_IP}"; fi
fi
if [ -n "${EDGE_HOST:-}" ]; then
    echo "edge: ${EDGE_HOST}"
    ssh "${SSH_OPTS[@]}" "$EDGE_HOST" "pkill -x slice-runtime 2>/dev/null || true"
    scp "${SSH_OPTS[@]}" target/release/slice-runtime "${EDGE_HOST}:/tmp/slice-runtime"
    ssh "${SSH_OPTS[@]}" "$EDGE_HOST" \
        "PORT=8080 LEDGER_URL=$LEDGER RESOURCE_URL=$RESOURCE nohup /tmp/slice-runtime >/tmp/slice-runtime.log 2>&1 & sleep 1; echo edge-started"
    EDGE_IP=$(ssh "${SSH_OPTS[@]}" "$EDGE_HOST" "hostname -I | awk '{print \$1}'")
    SLICE_EP="http://${EDGE_IP}:8080"
else
    # --- REGION: https://yuruna.link/network#why-the-single-vm-fallback-is-gated
    # Refuse rather than degrade. This branch runs the whole scenario against
    # this one VM and then asserts the full Target Verification Point over it,
    # printing PASSED -- so a cycle in which the edge was simply unreachable
    # reports the same result as one in which the distributed topology worked.
    # On a host whose address moves, an unreachable edge is a routine event, so
    # that is the difference between a green cycle that means something and one
    # that means the scenario quietly stopped testing what it exists to test.
    # Set AMISAD_ALLOW_SINGLE_VM=1 to run the degraded shape deliberately.
    if [ "${AMISAD_ALLOW_SINGLE_VM:-0}" != "1" ]; then
        echo "edge unresolved, and AMISAD_ALLOW_SINGLE_VM is not set: refusing to assert a distributed scenario against a single-VM topology." >&2
        exit 4
    fi
    echo "edge unresolved - slice-runtime on this VM (single-VM degraded fallback)"
    pkill -x slice-runtime 2>/dev/null || true
    PORT=8090 LEDGER_URL="$LEDGER" RESOURCE_URL="$RESOURCE" \
        nohup target/release/slice-runtime >/tmp/slice-runtime.log 2>&1 &
    sleep 1
    SLICE_EP="http://${NODE_IP}:8090"
fi
for _ in $(seq 1 15); do
    if curl -sf "${SLICE_EP}/health" >/dev/null 2>&1; then break; fi
    sleep 2
done
curl -sf "${SLICE_EP}/health" >/dev/null
echo "slice-runtime at ${SLICE_EP}"

export COORDINATOR_URL="http://${NODE_IP}:30080" IDENTITY_URL="http://${NODE_IP}:30084"
PSQL() { sudo -u postgres psql -d amisad -tAc "$1"; }

echo "== seed a settled order (like s001) to dispute =="
amisad_curl -X POST "${RESOURCE}/v1/edges" -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
RESULT=$(target/release/buyer-client submit)
MATCH_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')
ENV_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["environment_id"])')
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"

echo "== Maya reports non-delivery -> a support case opens with METADATA ONLY =="
SETTLEMENT=$(amisad_curl "${LEDGER}/v1/settlements/match/${MATCH_ID}")
CASE=$(amisad_curl -X POST "${PLATFORM}/v1/support/cases" \
    -d "{\"match_id\":\"${MATCH_ID}\",\"metadata\":{\"order_state\":\"settled\",\"carrier_confirmation\":\"delivered\",\"value_cents\":11000}}")
CASE_ID=$(echo "$CASE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["case_id"])')
echo "support case: ${CASE_ID}"
amisad_curl "${PLATFORM}/v1/support/cases/${CASE_ID}" | python3 -c "
import sys, json
c = json.load(sys.stdin)
text = json.dumps(c).lower()
for marker in ['maya', 'wedding gift', 'budget_cents', 'deadline_days', 'envelope', 'token']:
    assert marker not in text, f'support case leaked: {marker}'
print('ASSERT case carries metadata only, no buyer identity OK')
"

echo "== Sam requests, Maya grants a scoped time-boxed disclosure =="
amisad_curl -X POST "${PLATFORM}/v1/support/cases/disclosure/request" -d "{\"case_id\":\"${CASE_ID}\"}"
# TTL 10s: a generous window for the immediate read below, but well under the
# post-refund sleep that proves expiry - even on a heavily loaded box.
target/release/buyer-client disclose "${CASE_ID}" "delivery-photo-ref-77" 10 | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['scope'] == '${CASE_ID}' and r['expiry_ts'] > 0, r
print('ASSERT disclosure granted, scoped to the case OK')
"

echo "== Sam receives exactly the granted artifact, read-only =="
amisad_curl "${PLATFORM}/v1/support/cases/${CASE_ID}/disclosure" | python3 -c "
import sys, json
a = json.load(sys.stdin)
assert a['artifact'] == 'delivery-photo-ref-77', a
print('ASSERT artifact accessible while granted OK')
"

echo "== TVP: the consent ledger records the disclosure grant, scoped, with expiry =="
DISC_ROWS=$(PSQL "SELECT count(*) FROM ledger.consent_ledger WHERE grant_type='disclosure'")
if [ "$DISC_ROWS" != "1" ]; then echo "expected 1 disclosure grant row, got ${DISC_ROWS}" >&2; exit 9; fi
PSQL "SELECT payload FROM ledger.consent_ledger WHERE grant_type='disclosure'" | python3 -c "
import sys, json
p = json.loads(sys.stdin.read())
assert p['scope'] == '${CASE_ID}' and p['expiry_ts'] > p['ts'], p
assert p['action'] == 'grant', p
print('ASSERT disclosure grant scoped + time-boxed on the consent ledger OK')
"

echo "== refund posts as compensating entries; original history untouched =="
amisad_curl -X POST "${LEDGER}/v1/settlements/adjust" -d "{\"match_id\":\"${MATCH_ID}\",\"case_id\":\"${CASE_ID}\"}" \
    | python3 -c 'import sys,json;assert json.load(sys.stdin)["adjustment_entries"]==4;print("ASSERT compensating entries posted OK")'
amisad_curl "${LEDGER}/v1/settlements/match/${MATCH_ID}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
entries = s['entries']
originals = [e for e in entries if e.get('entry_type') != 'adjustment']
adjustments = [e for e in entries if e.get('entry_type') == 'adjustment']
assert len(originals) == 4 and len(adjustments) == 4, (len(originals), len(adjustments))
assert all(e['case_id'] == '${CASE_ID}' for e in adjustments), adjustments
# Original splits untouched (still positive, summing to value); the net is 0.
assert sum(e['amount_cents'] for e in originals) == 11000, originals
assert s['total_cents'] == 0 and s['value_cents'] == 11000, s
print('ASSERT refund as compensating entries, original untouched OK')
"

echo "== Sam resolves; recurring-pattern escalates to Priya =="
curl -sf -X POST "${PLATFORM}/v1/support/cases/resolve" -d "{\"case_id\":\"${CASE_ID}\"}" >/dev/null
amisad_curl -X POST "${PLATFORM}/v1/incidents" \
    -d "{\"summary\":\"recurring non-delivery pattern\",\"from\":\"support-desk\",\"environment_ids\":[\"${ENV_ID}\"]}" \
    | python3 -c 'import sys,json;assert json.load(sys.stdin)["case_id"];print("ASSERT recurring-pattern escalation OK")'

echo "== TVP: the disclosure grant expires -> the access path is gone =="
sleep 14
EXP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${PLATFORM}/v1/support/cases/${CASE_ID}/disclosure")
if [ "$EXP_CODE" != "410" ]; then
    echo "disclosed artifact still accessible after expiry (got ${EXP_CODE})" >&2
    exit 9
fi
echo "ASSERT post-expiry access fails OK"

echo "== TVP: all three chains verify (nothing edited) =="
amisad_curl "${LEDGER}/v1/verify" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'] and v['consent_ok'], v
print('ASSERT all chains verify OK')
"

echo "s008.mediation HAPPY PATH PASSED"
