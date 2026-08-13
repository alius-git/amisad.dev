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

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"
SELLER="http://${NODE_IP}:30083"

echo "== slice-runtime (edge amisad-edge-a) =="
# Resolve the edge from its boot-time IP report on the status service; an
# explicit EDGE_HOST env wins; unresolvable falls back to this VM.
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
    # binary fails with ETXTBSY (the edge stays up across scenarios - s001's
    # instance is still running when s002 delivers its copy).
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
amisad_curl -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"

echo "== seed: Elena's dresses (one dusty blue), a second seller's misfits, slots =="
# Qualifying: every required attribute, no exclusion, Thursday slot.
amisad_curl -X POST "${SELLER}/v1/offers" -d '{"offer_id":"linen-midi-04","tenant":"elena-atelier","title":"Linen midi dress","category":"dresses","region":"region-a","price_cents":18000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"thu-1","day":"thursday","day_ordinal":4},{"slot_id":"sat-1","day":"saturday","day_ordinal":6}]}'
# Excluded color: qualifies on everything else - and is CHEAPER, so its absence
# proves the exclusion decided, not the price.
amisad_curl -X POST "${SELLER}/v1/offers" -d '{"offer_id":"dusty-blue-02","tenant":"elena-atelier","title":"Dusty blue midi dress","category":"dresses","region":"region-a","price_cents":16000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeves","warm-fabric","dusty-blue"],"fitting_slots":[{"slot_id":"thu-2","day":"thursday","day_ordinal":4}]}'
# Missing required attributes (sleeveless, no warm fabric).
amisad_curl -X POST "${SELLER}/v1/offers" -d '{"offer_id":"silk-slip-03","tenant":"elena-atelier","title":"Silk slip dress","category":"dresses","region":"region-a","price_cents":15000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeveless"],"fitting_slots":[{"slot_id":"thu-3","day":"thursday","day_ordinal":4}]}'
# Second seller: past the deadline (in region), and out of range (region-b).
amisad_curl -X POST "${SELLER}/v1/offers" -d '{"offer_id":"wool-midi-07","tenant":"brisa-outlet","title":"Wool midi dress","category":"dresses","region":"region-a","price_cents":14000,"deliver_by_days":30,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"wed-7","day":"wednesday","day_ordinal":3}]}'
amisad_curl -X POST "${SELLER}/v1/offers" -d '{"offer_id":"linen-wrap-08","tenant":"brisa-outlet","title":"Linen wrap dress","category":"dresses","region":"region-b","price_cents":13000,"deliver_by_days":2,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"thu-8","day":"thursday","day_ordinal":4}]}'

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
amisad_curl "${SELLER}/v1/orders" | python3 -c "
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
amisad_curl "${SELLER}/v1/orders/match/${MATCH_ID}" | python3 -c "
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
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"
amisad_curl "${LEDGER}/v1/settlements/match/${MATCH_ID}" | python3 -c "
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
