#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s001.fulfillment run on amisad-vm-core: start slice-runtime on
# the real edge (amisad-vm-edge-a, resolved via its status-server IP report),
# seed Elena's offers, drive Maya's auto-close happy path, and assert the FULL
# Target Verification Point. The ten services are already deployed (amisad-vm-core
# snapshot); the prebuilt binaries are on disk from the deploy step.
# EDGE_HOST (optional override): ssh target for slice-runtime; unset -> resolve
# amisad-vm-edge-a; unresolvable -> single-VM degraded fallback on this VM.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== wait for the deployed services to recover (post-restore boot) =="
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true
# amisad-vm-core is a disk snapshot of a running cluster: loadDiskSnapshot cold-boots
# it, and kubelet's static-pod kube-apiserver only starts answering seconds after
# shell login. `kubectl wait` does NOT retry a refused TCP dial, so poll a raw
# endpoint first (up to 300s) before waiting on the deployments.
for _ in $(seq 1 60); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then break; fi
    sleep 5
done
SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"
for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=600s
done

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"

echo "== wait for the NodePort services to actually answer (post-restore) =="
# The restored objects still carry available=True from before the snapshot, so
# the kubectl waits above can pass before pods and kube-proxy are really up.
# Every exposed NodePort must answer - each service recovers independently.
for port in 30080 30081 30082 30083 30084; do
    for _ in $(seq 1 60); do
        if curl -sf "http://${NODE_IP}:${port}/health" >/dev/null 2>&1; then break; fi
        sleep 5
    done
    curl -sf "http://${NODE_IP}:${port}/health" >/dev/null
done

echo "== slice-runtime (edge amisad-vm-edge-a) =="
# Resolve the edge from its boot-time IP report on the status server; an
# explicit EDGE_HOST env wins. Core->edge auth uses the demo keypair the
# users step installed for the admin.
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
SSH_OPTS=(-i "$REAL_HOME/.ssh/amisad-demo-key" -o StrictHostKeyChecking=accept-new)
if [ -z "${EDGE_HOST:-}" ] && [ -n "${YURUNA_HOST_IP:-}" ]; then
    EDGE_IP=$(wget --no-proxy -qO- \
        "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/log/handoff/amisad-vm-edge-a.ip.txt" 2>/dev/null || true)
    if [ -n "$EDGE_IP" ]; then EDGE_HOST="amisad-vm-edge-a-admin@${EDGE_IP}"; fi
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
curl -sf -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
curl -sf -X POST "http://${NODE_IP}:30083/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
curl -sf -X POST "http://${NODE_IP}:30083/v1/offers" \
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
curl -sf -X POST "http://${NODE_IP}:30083/v1/orders/advance" \
    -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
curl -sf -X POST "http://${NODE_IP}:30083/v1/orders/advance" \
    -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"
target/release/buyer-client wait "$HANDLE"

echo "== TVP assert 1: settlement splits sum to match value =="
curl -sf "http://${NODE_IP}:30081/v1/settlements/match/${MATCH_ID}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['confirmed'] is True, 'settlement not confirmed'
assert s['total_cents'] == s['value_cents'] == ${PRICE}, (s['total_cents'], s['value_cents'])
parties = sorted(e['party'] for e in s['entries'])
assert parties == ['ads', 'network', 'platform', 'seller'], parties
print('ASSERT settlement OK')
"

echo "== TVP assert 2: buyer Delivered + seller Settled, one match ID =="
curl -sf "http://${NODE_IP}:30083/v1/orders/match/${MATCH_ID}" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['state'] == 'settled', o['state']
assert o['match_id'] == '${MATCH_ID}'
assert 'buyer' not in json.dumps(o).lower(), 'seller order leaked buyer field'
print('ASSERT seller order OK')
"
curl -sf "http://${NODE_IP}:30080/v1/orders/${HANDLE}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['status'] == 'delivered', s
print('ASSERT buyer status OK')
"

echo "== TVP assert 3: attestation chain complete for the environment =="
curl -sf "http://${NODE_IP}:30081/v1/attestations/env/${ENV_ID}" | python3 -c "
import sys, json
a = json.load(sys.stdin)
states = [e['lifecycle'] for e in a['entries']]
for want in ['created', 'attested', 'executed', 'destroyed']:
    assert want in states, f'missing {want} in {states}'
print('ASSERT attestation lifecycle OK')
"
curl -sf "http://${NODE_IP}:30081/v1/verify" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'], v
print('ASSERT hash chains OK')
"

echo "== TVP assert 4: zero need/identity egress from the environment =="
curl -sf "${SLICE_EP}/v1/egress" | python3 -c "
import sys, json
text = json.dumps(json.load(sys.stdin)).lower()
for marker in ['maya', 'token', 'budget_cents', 'deadline_days', 'subscriber']:
    assert marker not in text, f'egress leaked: {marker}'
print('ASSERT zero egress OK')
"

echo "s001.fulfillment HAPPY PATH PASSED"
