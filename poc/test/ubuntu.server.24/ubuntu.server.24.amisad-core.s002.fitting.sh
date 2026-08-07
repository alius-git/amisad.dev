#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s002.fitting run against the deployed amisad-core cluster:
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
# amisad-core cold-boots from its snapshot; kubectl does not retry a refused
# TCP dial, so poll a raw endpoint before waiting on the deployments.
for _ in $(seq 1 60); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then break; fi
    sleep 5
done
SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"
# The snapshot boots with deployment/pod status frozen at snapshot time, and
# kubelet restarts every container once shortly after boot. Waiting on the
# frozen "available" condition (or a single health probe) can pass against a
# pre-restart container that dies moments later, leaving the NodePort DNAT
# pointing at a dead veth: "No route to host". Gate on the live state instead:
# every amisad pod's running container must have started during this boot, and
# the rollouts must be complete against those fresh pods.
BOOT_EPOCH=$(date -d "$(uptime -s)" +%s)
EXPECTED_PODS=$(echo "$SERVICES" | wc -w)
PODS_FRESH=0
for _ in $(seq 1 60); do
    POD_TOTAL=0
    POD_FRESH=0
    while read -r STARTED_AT; do
        POD_TOTAL=$((POD_TOTAL + 1))
        [ -n "$STARTED_AT" ] || continue
        if [ "$(date -d "$STARTED_AT" +%s)" -ge "$BOOT_EPOCH" ]; then
            POD_FRESH=$((POD_FRESH + 1))
        fi
    done < <(kubectl -n amisad get pods \
        -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.running.startedAt}{"\n"}{end}' 2>/dev/null)
    if [ "$POD_TOTAL" -ge "$EXPECTED_PODS" ] && [ "$POD_FRESH" -eq "$POD_TOTAL" ]; then
        PODS_FRESH=1
        break
    fi
    sleep 5
done
if [ "$PODS_FRESH" -ne 1 ]; then
    echo "amisad pods did not all restart after the post-restore boot (fresh ${POD_FRESH}/${POD_TOTAL}, expected ${EXPECTED_PODS})" >&2
    exit 9
fi
for svc in $SERVICES; do
    kubectl -n amisad rollout status "deployment/${svc}" --timeout=600s
done

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"

echo "== wait for the NodePort services to actually answer (post-restore) =="
# The restored objects still carry available=True from before the snapshot, so
# the kubectl waits above can pass before pods and kube-proxy are really up.
# Every exposed NodePort must answer - each service recovers independently.
for port in 30080 30081 30082 30083 30084 30085 30086 30087 30088 30089; do
    for _ in $(seq 1 60); do
        if curl -sf "http://${NODE_IP}:${port}/health" >/dev/null 2>&1; then break; fi
        sleep 5
    done
    curl -sf "http://${NODE_IP}:${port}/health" >/dev/null || {
        echo "NodePort ${port} never answered - stale amisad-core snapshot? The deploy chain must be re-run (run-tests.ps1 rebuilds it)." >&2
        exit 8
    }
done
SELLER="http://${NODE_IP}:30083"

echo "== slice-runtime (edge amisad-edge-a) =="
# Resolve the edge from its boot-time IP report on the status service; an
# explicit EDGE_HOST env wins; unresolvable falls back to this VM.
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
SSH_OPTS=(-i "$REAL_HOME/.ssh/amisad-demo-key" -o StrictHostKeyChecking=accept-new)
if [ -z "${EDGE_HOST:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ]; then
    EDGE_IP=$(wget --no-proxy -qO- \
        "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/log/handoff/amisad-edge-a.ip.txt" 2>/dev/null || true)
    if [ -n "$EDGE_IP" ]; then EDGE_HOST="amisad-edge-a-admin@${EDGE_IP}"; fi
fi
if [ -n "${EDGE_HOST:-}" ]; then
    echo "edge: ${EDGE_HOST}"
    # Kill any running slice-runtime BEFORE the scp: overwriting an executing
    # binary fails with ETXTBSY (the edge stays up across scenarios - s001's
    # instance is still running when s002 delivers its copy).
    ssh "${SSH_OPTS[@]}" "$EDGE_HOST" "pkill -x slice-runtime 2>/dev/null || true"
    scp "${SSH_OPTS[@]}" target/release/slice-runtime "${EDGE_HOST}:/tmp/slice-runtime"
    ssh "${SSH_OPTS[@]}" "$EDGE_HOST" \
        "PORT=8080 LEDGER_URL=$LEDGER RESOURCE_URL=$RESOURCE nohup /tmp/slice-runtime >/tmp/slice-runtime.log 2>&1 & sleep 1; echo edge-started"
    EDGE_IP=$(ssh "${SSH_OPTS[@]}" "$EDGE_HOST" "hostname -I | awk '{print \$1}'")
    SLICE_EP="http://${EDGE_IP}:8080"
else
    echo "edge unresolved - slice-runtime on this VM (single-VM degraded fallback)"
    # pkill by process NAME: this script's own text contains "slice-runtime".
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

echo "== durable store: booked appointment persisted in PostgreSQL =="
BOOKED=$(sudo -u postgres psql -d amisad -tAc \
    "SELECT count(*) FROM seller.orders WHERE slot_id = 'thu-1' AND state = 'settled'")
if [ "$BOOKED" -lt 1 ]; then
    echo "no settled thu-1 order in PostgreSQL (got ${BOOKED})" >&2
    exit 9
fi
echo "ASSERT PostgreSQL appointment row OK"

echo "s002.fitting HAPPY PATH PASSED"
