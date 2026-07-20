#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s002.fitting run against the deployed amisad.core cluster:
# start slice-runtime, seed Elena's dresses (one dusty blue) + a second seller's
# out-of-range/past-deadline offers + fitting slots, drive Maya's MANUAL-policy
# dress need, and assert the FULL Target Verification Point: shortlist honors
# every constraint incl. exclusions; nothing commits before the explicit
# booking; buyer and seller hold consistent identity-free appointment records;
# notification log length is exactly two.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== wait for the deployed services to recover (post-restore boot) =="
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true
# amisad.core cold-boots from its snapshot; kubectl does not retry a refused
# TCP dial, so poll a raw endpoint before waiting on the deployments.
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
SELLER="http://${NODE_IP}:30083"

echo "== slice-runtime (single-VM degraded mode) =="
# pkill by process NAME: this script's own text contains "slice-runtime".
pkill -x slice-runtime 2>/dev/null || true
PORT=8090 LEDGER_URL="$LEDGER" RESOURCE_URL="$RESOURCE" \
    nohup target/release/slice-runtime >/tmp/slice-runtime.log 2>&1 &
sleep 1
SLICE_EP="http://${NODE_IP}:8090"
curl -sf "${SLICE_EP}/health" >/dev/null
curl -sf -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"

echo "== seed: Elena's dresses (one dusty blue), a second seller's misfits, slots =="
# Qualifying: every required attribute, no exclusion, Thursday slot.
curl -sf -X POST "${SELLER}/v1/offers" -d '{"offer_id":"linen-midi-04","tenant":"elena-atelier","title":"Linen midi dress","category":"dresses","region":"region-a","price_cents":18000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"thu-1","day":"thursday","day_ordinal":4},{"slot_id":"sat-1","day":"saturday","day_ordinal":6}]}'
# Excluded color: qualifies on everything else - and is CHEAPER, so its absence
# proves the exclusion decided, not the price.
curl -sf -X POST "${SELLER}/v1/offers" -d '{"offer_id":"dusty-blue-02","tenant":"elena-atelier","title":"Dusty blue midi dress","category":"dresses","region":"region-a","price_cents":16000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeves","warm-fabric","dusty-blue"],"fitting_slots":[{"slot_id":"thu-2","day":"thursday","day_ordinal":4}]}'
# Missing required attributes (sleeveless, no warm fabric).
curl -sf -X POST "${SELLER}/v1/offers" -d '{"offer_id":"silk-slip-03","tenant":"elena-atelier","title":"Silk slip dress","category":"dresses","region":"region-a","price_cents":15000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeveless"],"fitting_slots":[{"slot_id":"thu-3","day":"thursday","day_ordinal":4}]}'
# Second seller: past the deadline (in region), and out of range (region-b).
curl -sf -X POST "${SELLER}/v1/offers" -d '{"offer_id":"wool-midi-07","tenant":"brisa-outlet","title":"Wool midi dress","category":"dresses","region":"region-a","price_cents":14000,"deliver_by_days":30,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"wed-7","day":"wednesday","day_ordinal":3}]}'
curl -sf -X POST "${SELLER}/v1/offers" -d '{"offer_id":"linen-wrap-08","tenant":"brisa-outlet","title":"Linen wrap dress","category":"dresses","region":"region-b","price_cents":13000,"deliver_by_days":2,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"thu-8","day":"thursday","day_ordinal":4}]}'

echo "== Maya's manual dress need -> shortlist (notification 1) =="
export COORDINATOR_URL="http://${NODE_IP}:30080"
export IDENTITY_URL="http://${NODE_IP}:30084"
SHORTLIST=$(target/release/buyer-client shortlist)
echo "shortlist: ${SHORTLIST}"
HANDLE=$(echo "$SHORTLIST" | python3 -c 'import sys,json;print(json.load(sys.stdin)["handle"])')

echo "== TVP assert 1: shortlist honors every constraint incl. exclusions =="
echo "$SHORTLIST" | python3 -c "
import sys, json
s = json.load(sys.stdin)
ids = [e['offer_id'] for e in s['shortlist']]
assert 'linen-midi-04' in ids, ids
for absent in ['dusty-blue-02', 'silk-slip-03', 'wool-midi-07', 'linen-wrap-08']:
    assert absent not in ids, f'{absent} leaked onto the shortlist: {ids}'
print('ASSERT shortlist constraint fidelity OK')
"

echo "== TVP assert 2: zero commitments before the buyer's explicit action =="
curl -sf "${SELLER}/v1/orders" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['count'] == 0, f'commitment exists before booking: {o}'
print('ASSERT zero pre-booking commitments OK')
"
target/release/buyer-client notifications "$HANDLE" | python3 -c "
import sys, json
n = json.load(sys.stdin)['notifications']
assert [e['kind'] for e in n] == ['shortlist'], n
print('ASSERT single shortlist notification OK')
"

echo "== Maya books the Thursday fitting (notification 2) =="
BOOKING=$(target/release/buyer-client book "$HANDLE" linen-midi-04 thu-1)
echo "booking: ${BOOKING}"
MATCH_ID=$(echo "$BOOKING" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')

echo "== TVP assert 3: consistent, identity-free appointment records =="
curl -sf "${SELLER}/v1/orders/match/${MATCH_ID}" | python3 -c "
import sys, json
booking = json.loads('''${BOOKING}''')
o = json.load(sys.stdin)
assert o['match_id'] == booking['match_id']
assert o['state'] == 'committed', o['state']
assert o['appointment']['slot_id'] == booking['slot_id'] == 'thu-1', (o, booking)
assert o['appointment']['day'] == 'thursday'
assert 'buyer' not in json.dumps(o).lower(), 'seller appointment leaked buyer field'
print('ASSERT appointment records OK')
"

echo "== Elena: fitting fulfilled, sale closed -> settled with split =="
curl -sf -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
curl -sf -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"
curl -sf "${LEDGER}/v1/settlements/match/${MATCH_ID}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['confirmed'] is True, 'settlement not confirmed'
assert s['total_cents'] == s['value_cents'] == 18000, (s['total_cents'], s['value_cents'])
print('ASSERT settlement split OK')
"

echo "== TVP assert 4: notification log length is exactly two =="
target/release/buyer-client notifications "$HANDLE" | python3 -c "
import sys, json
n = json.load(sys.stdin)['notifications']
assert [e['kind'] for e in n] == ['shortlist', 'booking-confirmed'], n
print('ASSERT exactly two notifications OK')
"

echo "s002.fitting HAPPY PATH PASSED"
