#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42cdfd5c-a9d4-4ceb-a836-84cddea65b5a
# See https://yuruna.link/42010605-00c0
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
SELLER="http://${NODE_IP}:30083"

echo "== slice-runtime (edge amisad-edge-a) =="
amisad_start_slice_runtime "$LEDGER" "$RESOURCE"

export COORDINATOR_URL="http://${NODE_IP}:30080" IDENTITY_URL="http://${NODE_IP}:30084"
# --- REGION: PSQL
PSQL() { sudo -u postgres psql -d amisad -tAc "$1"; }

echo "== register edge + seed Elena's household offers =="
amisad_curl -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
# Under-cap staple, and a premium item only a 'premium' need selects.
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":false}'
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"premium-vase-06","tenant":"elena-atelier","title":"Premium crystal vase","category":"housewares","region":"region-a","price_cents":18000,"deliver_by_days":10,"auto_close":false,"attributes":["premium"]}'

echo "== Maya grants Pat a household-goods mandate (per-item cap 14000) =="
target/release/buyer-client grant-mandate pat housewares 14000 | python3 -c "
import sys, json
m = json.load(sys.stdin)
assert m['per_item_cents'] == 14000 and m['principal'] != m['delegate'], m
assert 'pat' not in json.dumps(m).lower() and 'maya' not in json.dumps(m).lower(), m
print('ASSERT mandate recorded (pseudonymous) OK')
"

echo "== Pat's delegate workspace shows Maya as principal =="
target/release/buyer-client workspace pat | python3 -c "
import sys, json
p = json.load(sys.stdin)['principals']
assert len(p) == 1 and p[0]['category'] == 'housewares' and p[0]['per_item_cents'] == 14000, p
print('ASSERT delegate workspace shows the principal OK')
"

echo "== Pat closes an in-scope under-cap match on his own authority =="
target/release/buyer-client delegate-need pat housewares 12000 | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['status'] == 'committed' and r['via'] == 'delegate', r
print('ASSERT in-scope under-cap closes on delegate authority OK')
"
ATTEST_AFTER_UNDER=$(PSQL "SELECT count(*) FROM ledger.attestation_ledger")
RESP=$(amisad_curl "${SELLER}/v1/orders")
ORDERS_AFTER_UNDER=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')

echo "== TVP: Maya's activity trail carries dual attribution =="
target/release/buyer-client activity | python3 -c "
import sys, json
a = json.load(sys.stdin)['activity']
m = [e for e in a if e['kind'] == 'delegated-match' and e['via'] == 'delegate']
assert len(m) == 1, a
assert m[0]['mandate'] is True and m[0]['actor'] != m[0]['principal'], m[0]
assert 'pat' not in json.dumps(a).lower() and 'maya' not in json.dumps(a).lower(), a
print('ASSERT dual attribution on the activity trail OK')
"

echo "== Pat's over-cap match is HELD for Maya's approval =="
HELD=$(target/release/buyer-client delegate-need pat housewares 20000 premium)
echo "$HELD" | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['status'] == 'held-for-approval' and 'handle' in r, r
print('ASSERT over-cap held for approval OK')
"
HANDLE=$(echo "$HELD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["handle"])')
# TVP: the over-cap closing does NOT exist before the principal's approval.
RESP=$(amisad_curl "${SELLER}/v1/orders")
ORDERS_BEFORE_APPROVE=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
if [ "$ORDERS_BEFORE_APPROVE" != "$ORDERS_AFTER_UNDER" ]; then
    echo "over-cap match committed before approval (${ORDERS_AFTER_UNDER} -> ${ORDERS_BEFORE_APPROVE})" >&2
    exit 9
fi
echo "ASSERT no over-cap closing before approval OK"

echo "== Maya approves -> the over-cap closing completes via approval =="
target/release/buyer-client approve "$HANDLE" | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['status'] == 'committed' and r['via'] == 'approval', r
print('ASSERT over-cap closes via principal approval OK')
"
RESP=$(amisad_curl "${SELLER}/v1/orders")
ORDERS_AFTER_APPROVE=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
python3 -c "assert int('${ORDERS_AFTER_APPROVE}') == int('${ORDERS_AFTER_UNDER}') + 1; print('ASSERT approved closing added one order OK')"

echo "== TVP: an out-of-scope need is refused at submission (zero environments) =="
ATTEST_BEFORE_OOS=$(PSQL "SELECT count(*) FROM ledger.attestation_ledger")
OOS=$(target/release/buyer-client delegate-need pat dresses 20000 2>&1 || true)
if ! echo "$OOS" | grep -q "out of mandate scope"; then
    echo "out-of-scope need was NOT refused: ${OOS}" >&2
    exit 9
fi
ATTEST_AFTER_OOS=$(PSQL "SELECT count(*) FROM ledger.attestation_ledger")
if [ "$ATTEST_AFTER_OOS" != "$ATTEST_BEFORE_OOS" ]; then
    echo "out-of-scope attempt created environments (${ATTEST_BEFORE_OOS} -> ${ATTEST_AFTER_OOS})" >&2
    exit 9
fi
echo "ASSERT out-of-scope refused with zero environments OK"

echo "== Maya revokes the mandate -> delegated authority dies immediately =="
target/release/buyer-client revoke-mandate pat | python3 -c 'import sys,json;assert json.load(sys.stdin)["revoked"] is True;print("ASSERT mandate revoked OK")'
target/release/buyer-client workspace pat | python3 -c "
import sys, json
assert json.load(sys.stdin)['principals'] == [], 'workspace still shows a principal after revoke'
print('ASSERT delegate workspace cleared on revoke OK')
"
POST=$(target/release/buyer-client delegate-need pat housewares 12000 2>&1 || true)
if ! echo "$POST" | grep -q "no valid mandate"; then
    echo "delegated action succeeded after revocation: ${POST}" >&2
    exit 9
fi
echo "ASSERT no delegated action after revocation OK"

echo "== TVP: consent ledger holds the mandate grant + revoke; chains verify =="
MANDATE_ROWS=$(PSQL "SELECT count(*) FROM ledger.consent_ledger WHERE grant_type='mandate' AND payload::jsonb->>'action' IN ('grant','revoke')")
if [ "$MANDATE_ROWS" != "2" ]; then
    echo "expected 2 mandate consent rows (grant+revoke), got ${MANDATE_ROWS}" >&2
    exit 9
fi
# Each delegated commit records the mandate use it executed under; the
# refused attempts (out of scope, after revocation) record none.
MANDATE_USES=$(PSQL "SELECT payload::jsonb->>'via' FROM ledger.consent_ledger WHERE grant_type='mandate' AND payload::jsonb->>'action' = 'use' ORDER BY id" | paste -sd, -)
if [ "$MANDATE_USES" != "delegate,approval" ]; then
    echo "expected mandate uses delegate,approval, got '${MANDATE_USES}'" >&2
    exit 9
fi
RESP=$(amisad_curl "${LEDGER}/v1/verify")
echo "$RESP" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'] and v['consent_ok'], v
print('ASSERT all three chains verify OK')
"

echo "s006.mandate HAPPY PATH PASSED"
