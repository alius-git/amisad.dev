#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s001.fulfillment run on amisad-core: start slice-runtime on
# the real edge (amisad-edge-a, resolved via its status-server IP report),
# seed Elena's offers, drive Maya's auto-close happy path, and assert the FULL
# Target Verification Point. The ten services are already deployed (amisad-core
# snapshot); the prebuilt binaries are on disk from the deploy step.
# EDGE_HOST (optional override): ssh target for slice-runtime; unset -> resolve
# amisad-edge-a; unresolvable -> single-VM degraded fallback on this VM.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"

echo "== slice-runtime (edge amisad-edge-a) =="
# Resolve the edge from its boot-time IP report on the status service; an
# explicit EDGE_HOST env wins. Core->edge auth uses the demo keypair the
# users step installed for the admin.
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
    # Kill any running slice-runtime BEFORE the scp: overwriting an executing
    # binary fails with ETXTBSY (the edge stays up across scenarios).
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
    # pkill matches the process NAME (comm), not -f full-cmdline: fetch-and-
    # execute runs this whole script via `bash -c "<text>"`, and the text
    # contains "slice-runtime", so `pkill -f slice-runtime` would SIGTERM this
    # very script (exit 143) before starting the server.
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

echo "== register edge + seed Elena's offers =="
amisad_curl -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
amisad_curl -X POST "http://${NODE_IP}:30083/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
amisad_curl -X POST "http://${NODE_IP}:30083/v1/offers" \
    -d '{"offer_id":"crystal-vase-02","tenant":"elena-atelier","title":"Crystal vase","category":"housewares","region":"region-a","price_cents":15000,"deliver_by_days":5,"auto_close":true}'

echo "== happy path: Maya's gift auto-closes =="
export COORDINATOR_URL="http://${NODE_IP}:30080"
export IDENTITY_URL="http://${NODE_IP}:30084"
RESULT=$(target/release/buyer-client submit)
echo "match: ${RESULT}"
HANDLE=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["handle"])')
MATCH_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')
ENV_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["environment_id"])')
PRICE=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["offer"]["price_cents"])')

echo "== Elena ships =="
amisad_curl -X POST "http://${NODE_IP}:30083/v1/orders/advance" \
    -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
amisad_curl -X POST "http://${NODE_IP}:30083/v1/orders/advance" \
    -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"
target/release/buyer-client wait "$HANDLE"

echo "== TVP assert 1: settlement splits sum to match value =="
amisad_curl "http://${NODE_IP}:30081/v1/settlements/match/${MATCH_ID}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['confirmed'] is True, 'settlement not confirmed'
assert s['total_cents'] == s['value_cents'] == ${PRICE}, (s['total_cents'], s['value_cents'])
parties = sorted(e['party'] for e in s['entries'])
assert parties == ['ads', 'network', 'platform', 'seller'], parties
print('ASSERT settlement OK')
"

echo "== TVP assert 2: buyer Delivered + seller Settled, one match ID =="
amisad_curl "http://${NODE_IP}:30083/v1/orders/match/${MATCH_ID}" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['state'] == 'settled', o['state']
assert o['match_id'] == '${MATCH_ID}'
assert 'buyer' not in json.dumps(o).lower(), 'seller order leaked buyer field'
print('ASSERT seller order OK')
"
amisad_curl "http://${NODE_IP}:30080/v1/orders/${HANDLE}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['status'] == 'delivered', s
print('ASSERT buyer status OK')
"

echo "== TVP assert 3: attestation chain complete for the environment =="
amisad_curl "http://${NODE_IP}:30081/v1/attestations/env/${ENV_ID}" | python3 -c "
import sys, json
a = json.load(sys.stdin)
states = [e['lifecycle'] for e in a['entries']]
for want in ['created', 'attested', 'executed', 'destroyed']:
    assert want in states, f'missing {want} in {states}'
print('ASSERT attestation lifecycle OK')
"
amisad_curl "http://${NODE_IP}:30081/v1/verify" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'], v
print('ASSERT hash chains OK')
"

echo "== TVP assert 4: zero need/identity egress from the environment =="
amisad_curl "${SLICE_EP}/v1/egress" | python3 -c "
import sys, json
text = json.dumps(json.load(sys.stdin)).lower()
for marker in ['maya', 'token', 'budget_cents', 'deadline_days', 'subscriber']:
    assert marker not in text, f'egress leaked: {marker}'
print('ASSERT zero egress OK')
"

echo "== durable store: rows in PostgreSQL, state survives a pod restart =="
ROWS=$(sudo -u postgres psql -d amisad -tAc \
    "SELECT (SELECT count(*) FROM ledger.settlement_ledger), (SELECT count(*) FROM ledger.attestation_ledger), (SELECT count(*) FROM seller.orders)")
echo "pg rows (settlement|attestation|orders): ${ROWS}"
python3 -c "
s, a, o = [int(x) for x in '${ROWS}'.split('|')]
assert s >= 4 and a >= 4 and o >= 1, (s, a, o)
print('ASSERT PostgreSQL write-through OK')
"
# The reload proof: fresh pods must rebuild verifying chains and the settled
# order from the database, not from lost process memory.
kubectl -n amisad rollout restart deployment/ledger-svc deployment/seller-svc
kubectl -n amisad rollout status deployment/ledger-svc --timeout=180s
kubectl -n amisad rollout status deployment/seller-svc --timeout=180s
for _ in $(seq 1 60); do
    if curl -sf "http://${NODE_IP}:30081/health" >/dev/null 2>&1 && \
       curl -sf "http://${NODE_IP}:30083/health" >/dev/null 2>&1; then break; fi
    sleep 2
done
curl -sf "http://${NODE_IP}:30081/health" >/dev/null || { echo "ledger-svc never came back after restart" >&2; exit 8; }
curl -sf "http://${NODE_IP}:30083/health" >/dev/null || { echo "seller-svc never came back after restart" >&2; exit 8; }
amisad_curl "${LEDGER}/v1/verify" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'], v
assert v['settlement_len'] >= 4 and v['attestation_len'] >= 4, v
print('ASSERT ledgers reloaded after restart OK')
"
amisad_curl "http://${NODE_IP}:30083/v1/orders/match/${MATCH_ID}" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['state'] == 'settled', o
print('ASSERT order survived restart OK')
"

echo "s001.fulfillment HAPPY PATH PASSED"
