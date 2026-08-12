#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s010.certification run on amisad-core: independent certification
# of the full evidence trail. Because each scenario restores a fresh snapshot,
# this run SELF-SEEDS a representative corpus exercising all four audit
# dimensions - a completed match plus an injected abort (attestation +
# residency), consent grant/revoke and a mandate (consent, all grant types),
# and a disclosure grant + settlement adjustment (consent + settlement
# conservation) - then Ingrid's audit-svc independently re-verifies the hash
# chains, localizes a deliberate tamper, and proves it only ever read.
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
PLATFORM="http://${NODE_IP}:30086"
AUDIT="http://${NODE_IP}:30089"

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

echo "== slice-runtime on amisad-edge-a WITH region identity (for residency) =="
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
        "PORT=8080 REGION=region-a LEDGER_URL=$LEDGER RESOURCE_URL=$RESOURCE nohup /tmp/slice-runtime >/tmp/slice-runtime.log 2>&1 & sleep 1; echo edge-started"
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
    PORT=8090 REGION=region-a LEDGER_URL="$LEDGER" RESOURCE_URL="$RESOURCE" \
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

echo "== self-seed the evidence corpus =="
curl -sf -X POST "${RESOURCE}/v1/edges" -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
curl -sf -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'

# (1) a completed match, advanced to settled -> attestation + settlement.
RESULT=$(target/release/buyer-client submit)
MATCH_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')
ENV_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["environment_id"])')
curl -sf -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
curl -sf -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"

# (2) an injected abort: the fabric retries to a clean completion, so the
# attestation log carries an aborted lifecycle too (like s004.failover).
curl -sf -X POST "${SLICE_EP}/v1/faults" -d '{"mode":"isolation","count":1}' >/dev/null
target/release/buyer-client submit >/dev/null

# (3) consent grant + revoke, and (4) a mandate -> all three consent grant types.
target/release/buyer-client resume >/dev/null       # participation + contribution grants
target/release/buyer-client pause >/dev/null         # participation revoke
target/release/buyer-client grant-mandate pat housewares 14000 >/dev/null

# (5) a disclosure grant + a settlement adjustment referencing a support case.
CASE_ID=$(curl -sf -X POST "${PLATFORM}/v1/support/cases" \
    -d "{\"match_id\":\"${MATCH_ID}\",\"metadata\":{\"order_state\":\"settled\"}}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["case_id"])')
curl -sf -X POST "${PLATFORM}/v1/support/cases/disclosure/request" -d "{\"case_id\":\"${CASE_ID}\"}" >/dev/null
target/release/buyer-client disclose "${CASE_ID}" "delivery-photo-ref-77" 120 >/dev/null
curl -sf -X POST "${LEDGER}/v1/settlements/adjust" -d "{\"match_id\":\"${MATCH_ID}\",\"case_id\":\"${CASE_ID}\"}" >/dev/null
echo "corpus seeded"

echo "== Ingrid runs the certification: all four dimensions, zero violations =="
curl -sf -X POST "${AUDIT}/v1/certify" | python3 -c "
import sys, json
c = json.load(sys.stdin)
for dim in ['attestation','residency','consent','settlement']:
    assert c[dim]['ok'] is True and c[dim]['violations'] == 0, (dim, c[dim])
assert c['certified'] is True and c['total_violations'] == 0, c
print('ASSERT four-dimension certification clean OK')
"

echo "== TVP: a deliberate tamper is detected and localized to the exact record =="
curl -sf "${LEDGER}/v1/attestations" | python3 -c "
import sys, json
entries = json.load(sys.stdin)['entries']
# Modify one record's payload after the fact (index 5 of the corpus).
idx = 5
entries[idx]['payload']['lifecycle'] = 'tampered-lifecycle'
print(json.dumps({'entries': entries, 'expected': idx}))
" > /tmp/tamper.json
EXPECTED=$(python3 -c "import json;print(json.load(open('/tmp/tamper.json'))['expected'])")
python3 -c "import json;d=json.load(open('/tmp/tamper.json'));json.dump({'entries':d['entries']},open('/tmp/tamper-body.json','w'))"
curl -sf -X POST "${AUDIT}/v1/certify/tamper" --data-binary @/tmp/tamper-body.json | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['detected'] is True, r
assert r['tampered_index'] == ${EXPECTED}, (r, ${EXPECTED})
print('ASSERT tamper detected and localized OK')
"

echo "== Ingrid issues findings -> Priya receives them in the platform =="
curl -sf -X POST "${PLATFORM}/v1/incidents" \
    -d "{\"summary\":\"certification findings: corpus certified, tamper detected\",\"from\":\"audit\",\"environment_ids\":[\"${ENV_ID}\"]}" \
    | python3 -c 'import sys,json;assert json.load(sys.stdin)["case_id"];print("ASSERT findings delivered to the platform OK")'

echo "== TVP: the auditor only ever READ - no writes, no personal data =="
curl -sf "${AUDIT}/v1/access-log" | python3 -c "
import sys, json
a = json.load(sys.stdin)['access']
assert len(a) >= 3, a
assert all(e['method'] == 'GET' for e in a), a
text = json.dumps(a).lower()
for marker in ['maya', 'subject', 'need_context', 'envelope', 'password']:
    assert marker not in text, f'audit access log leaked: {marker}'
print('ASSERT audit access is read-only, no personal data OK')
"

echo "s010.certification HAPPY PATH PASSED"
