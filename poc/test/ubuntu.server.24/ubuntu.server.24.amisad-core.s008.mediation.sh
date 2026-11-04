#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 427cceab-1eaa-416c-9330-cd55ed20a887
# See https://yuruna.link/42010605-00c2
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
PLATFORM="http://${NODE_IP}:30086"

echo "== slice-runtime (edge amisad-edge-a) =="
amisad_start_slice_runtime "$LEDGER" "$RESOURCE"

export COORDINATOR_URL="http://${NODE_IP}:30080" IDENTITY_URL="http://${NODE_IP}:30084"
# --- REGION: PSQL
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
RESP=$(amisad_curl "${PLATFORM}/v1/support/cases/${CASE_ID}")
echo "$RESP" | python3 -c "
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
RESP=$(amisad_curl "${PLATFORM}/v1/support/cases/${CASE_ID}/disclosure")
echo "$RESP" | python3 -c "
import sys, json
a = json.load(sys.stdin)
assert a['artifact'] == 'delivery-photo-ref-77', a
print('ASSERT artifact accessible while granted OK')
"

echo "== TVP: the consent ledger records the disclosure grant, scoped, with expiry =="
DISC_ROWS=$(PSQL "SELECT count(*) FROM ledger.consent_ledger WHERE grant_type='disclosure' AND payload::jsonb->>'action' = 'grant'")
if [ "$DISC_ROWS" != "1" ]; then echo "expected 1 disclosure grant row, got ${DISC_ROWS}" >&2; exit 9; fi
DISC_USE=$(PSQL "SELECT payload::jsonb->>'scope' FROM ledger.consent_ledger WHERE grant_type='disclosure' AND payload::jsonb->>'action' = 'use'")
if [ "$DISC_USE" != "$CASE_ID" ]; then echo "expected one disclosure use scoped to ${CASE_ID}, got '${DISC_USE}'" >&2; exit 9; fi
PSQL "SELECT payload FROM ledger.consent_ledger WHERE grant_type='disclosure' AND payload::jsonb->>'action' = 'grant'" | python3 -c "
import sys, json
p = json.loads(sys.stdin.read())
assert p['scope'] == '${CASE_ID}' and p['expiry_ts'] > p['ts'], p
assert p['action'] == 'grant', p
print('ASSERT disclosure grant scoped + time-boxed on the consent ledger OK')
"

echo "== refund posts as compensating entries; original history untouched =="
# Sam refunds through the support desk: platform-svc takes the match from the
# case and holds the token the ledger requires on appends.
amisad_curl -X POST "${PLATFORM}/v1/support/cases/refund" -d "{\"case_id\":\"${CASE_ID}\"}" \
    | python3 -c 'import sys,json;assert json.load(sys.stdin)["adjustment_entries"]==4;print("ASSERT compensating entries posted OK")'
RESP=$(amisad_curl "${LEDGER}/v1/settlements/match/${MATCH_ID}")
echo "$RESP" | python3 -c "
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
RESP=$(amisad_curl "${LEDGER}/v1/verify")
echo "$RESP" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'] and v['consent_ok'], v
print('ASSERT all chains verify OK')
"

echo "s008.mediation HAPPY PATH PASSED"
