#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s006.mandate run on amisad-core: delegated procurement under a
# scoped mandate. Maya grants Pat a household-goods mandate with a per-item
# cap; Pat closes an in-scope under-cap match on his own authority (dual
# attribution on Maya's trail); an over-cap match is HELD until Maya approves;
# an out-of-scope need is refused at submission with zero environments and
# zero ledger entries; revocation removes delegated authority immediately.
# EDGE_HOST (optional override): ssh target for slice-runtime.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== wait for the deployed services to recover (post-restore boot) =="
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true
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
SELLER="http://${NODE_IP}:30083"

echo "== wait for the NodePort services to actually answer (post-restore) =="
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

echo "== register edge + seed Elena's household offers =="
curl -sf -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
# Under-cap staple, and a premium item only a 'premium' need selects.
curl -sf -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":false}'
curl -sf -X POST "${SELLER}/v1/offers" \
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
ORDERS_AFTER_UNDER=$(curl -sf "${SELLER}/v1/orders" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')

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
ORDERS_BEFORE_APPROVE=$(curl -sf "${SELLER}/v1/orders" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
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
ORDERS_AFTER_APPROVE=$(curl -sf "${SELLER}/v1/orders" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
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
MANDATE_ROWS=$(PSQL "SELECT count(*) FROM ledger.consent_ledger WHERE grant_type='mandate'")
if [ "$MANDATE_ROWS" != "2" ]; then
    echo "expected 2 mandate consent rows (grant+revoke), got ${MANDATE_ROWS}" >&2
    exit 9
fi
curl -sf "${LEDGER}/v1/verify" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'] and v['consent_ok'], v
print('ASSERT all three chains verify OK')
"

echo "s006.mandate HAPPY PATH PASSED"
