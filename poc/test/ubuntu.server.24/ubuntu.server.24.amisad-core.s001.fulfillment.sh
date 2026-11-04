#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42b8b2f9-c902-4881-88c3-d5db2e98205c
# See https://yuruna.link/42010605-00bb
# --- REGION: Initialize environment
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"
# --- REGION: Load scenario helpers
# shellcheck source=../amisad-scenario.sh
. "$POC/test/amisad-scenario.sh"

# --- REGION: Resolve service endpoints
NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"

echo "== slice-runtime (edge amisad-edge-a) =="
amisad_start_slice_runtime "$LEDGER" "$RESOURCE"

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
RESP=$(amisad_curl "http://${NODE_IP}:30081/v1/settlements/match/${MATCH_ID}")
echo "$RESP" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['confirmed'] is True, 'settlement not confirmed'
assert s['total_cents'] == s['value_cents'] == ${PRICE}, (s['total_cents'], s['value_cents'])
parties = sorted(e['party'] for e in s['entries'])
assert parties == ['ads', 'network', 'platform', 'seller'], parties
print('ASSERT settlement OK')
"

echo "== TVP assert 2: buyer Delivered + seller Settled, one match ID =="
RESP=$(amisad_curl "http://${NODE_IP}:30083/v1/orders/match/${MATCH_ID}")
echo "$RESP" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['state'] == 'settled', o['state']
assert o['match_id'] == '${MATCH_ID}'
assert 'buyer' not in json.dumps(o).lower(), 'seller order leaked buyer field'
print('ASSERT seller order OK')
"
RESP=$(amisad_curl "http://${NODE_IP}:30080/v1/orders/${HANDLE}")
echo "$RESP" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['status'] == 'delivered', s
print('ASSERT buyer status OK')
"

echo "== TVP assert 3: attestation chain complete for the environment =="
RESP=$(amisad_curl "http://${NODE_IP}:30081/v1/attestations/env/${ENV_ID}")
echo "$RESP" | python3 -c "
import sys, json
a = json.load(sys.stdin)
states = [e['lifecycle'] for e in a['entries']]
for want in ['created', 'attested', 'executed', 'destroyed']:
    assert want in states, f'missing {want} in {states}'
print('ASSERT attestation lifecycle OK')
"
RESP=$(amisad_curl "http://${NODE_IP}:30081/v1/verify")
echo "$RESP" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'], v
print('ASSERT hash chains OK')
"

echo "== TVP assert 4: zero need/identity egress from the environment =="
RESP=$(amisad_curl "${SLICE_EP}/v1/egress")
echo "$RESP" | python3 -c "
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
RESP=$(amisad_curl "${LEDGER}/v1/verify")
echo "$RESP" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'], v
assert v['settlement_len'] >= 4 and v['attestation_len'] >= 4, v
print('ASSERT ledgers reloaded after restart OK')
"
RESP=$(amisad_curl "http://${NODE_IP}:30083/v1/orders/match/${MATCH_ID}")
echo "$RESP" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['state'] == 'settled', o
print('ASSERT order survived restart OK')
"

echo "s001.fulfillment HAPPY PATH PASSED"
