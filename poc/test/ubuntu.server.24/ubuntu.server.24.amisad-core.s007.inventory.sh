#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s007.inventory run on amisad-core: enterprise integration
# onboarding and inventory-truth matching. Alex registers + certifies a
# connector; Elena grants scoped credentials; the connector syncs the ERP
# catalog and an inventory delta that zeroes the last unit of one item; a
# buyer need then matches only the in-stock alternative; order-lifecycle
# events mirror to the ERP idempotently; an out-of-scope call is refused and
# logged; and revocation kills the credentials. EDGE_HOST (optional override).
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
CONNECT="http://${NODE_IP}:30088"

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
if [ -z "${EDGE_HOST:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ]; then
    EDGE_IP=$(wget --no-proxy -qO- \
        "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/log/handoff/amisad-edge-a.ip.txt" 2>/dev/null || true)
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
curl -sf -X POST "${RESOURCE}/v1/edges" -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"

echo "== Alex registers + certifies a connector (sandbox only) =="
PARTNER=$(curl -sf -X POST "${CONNECT}/v1/partners" -d '{"name":"alex-erp-connector"}')
PARTNER_ID=$(echo "$PARTNER" | python3 -c 'import sys,json;print(json.load(sys.stdin)["partner_id"])')
echo "$PARTNER" | python3 -c 'import sys,json;assert json.load(sys.stdin)["access"]=="sandbox";print("ASSERT sandbox access only OK")'
curl -sf -X POST "${CONNECT}/v1/partners/certify" -d "{\"partner_id\":\"${PARTNER_ID}\"}" | python3 -c 'import sys,json;assert json.load(sys.stdin)["certified"] is True;print("ASSERT connector certified OK")'

echo "== Elena grants scoped access (catalog, inventory, orders) =="
GRANT=$(curl -sf -X POST "${CONNECT}/v1/grants" \
    -d "{\"tenant\":\"elena-atelier\",\"partner_id\":\"${PARTNER_ID}\",\"scopes\":[\"catalog\",\"inventory\",\"orders\"]}")
CRED=$(echo "$GRANT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credential"])')
echo "ASSERT scoped credential issued OK"

echo "== connector syncs the ERP catalog (scope catalog) =="
# erp-lamp-01 is cheaper (would win on price) and is the unit that goes to
# zero; erp-clock-02 is the in-stock alternative.
curl -sf -X POST "${CONNECT}/v1/sync/catalog" -d "{\"credential\":\"${CRED}\",\"offers\":[
  {\"offer_id\":\"erp-lamp-01\",\"tenant\":\"elena-atelier\",\"title\":\"ERP table lamp\",\"category\":\"housewares\",\"region\":\"region-a\",\"price_cents\":8000,\"deliver_by_days\":5,\"auto_close\":true},
  {\"offer_id\":\"erp-clock-02\",\"tenant\":\"elena-atelier\",\"title\":\"ERP wall clock\",\"category\":\"housewares\",\"region\":\"region-a\",\"price_cents\":9000,\"deliver_by_days\":5,\"auto_close\":true}
]}" | python3 -c 'import sys,json;assert json.load(sys.stdin)["synced"]==2;print("ASSERT catalog synced OK")'
curl -sf "${SELLER}/v1/offers/region/region-a" | python3 -c "
import sys, json
ids = {o['offer_id'] for o in json.load(sys.stdin)['offers']}
assert {'erp-lamp-01','erp-clock-02'} <= ids, ids
print('ASSERT synced offers matchable OK')
"

echo "== an external sale zeroes the last unit of erp-lamp-01 (scope inventory) =="
DELTA_TS=$(date +%s)
curl -sf -X POST "${CONNECT}/v1/sync/inventory" \
    -d "{\"credential\":\"${CRED}\",\"offer_id\":\"erp-lamp-01\",\"stock\":0,\"delta_ts\":${DELTA_TS}}" \
    | python3 -c 'import sys,json;assert json.load(sys.stdin)["stock"]==0;print("ASSERT inventory delta applied OK")'
curl -sf "${SELLER}/v1/offers/region/region-a" | python3 -c "
import sys, json
ids = {o['offer_id'] for o in json.load(sys.stdin)['offers']}
assert 'erp-lamp-01' not in ids, ids  # zeroed -> not matchable
assert 'erp-clock-02' in ids, ids
print('ASSERT zeroed item left the catalog OK')
"

echo "== TVP: a buyer need matches only the in-stock alternative =="
RESULT=$(target/release/buyer-client submit)
MATCH_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')
echo "$RESULT" | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['offer']['offer_id'] == 'erp-clock-02', r  # NOT the cheaper zeroed lamp
print('ASSERT match went to the in-stock alternative OK')
"
# The delta zeroed erp-lamp-01 before the match; assert the delta is recorded
# with its timestamp and the match did not reference the zeroed item.
curl -sf "${CONNECT}/v1/deltas" | python3 -c "
import sys, json
d = json.load(sys.stdin)['deltas']
zeroed = [x for x in d if x['offer_id'] == 'erp-lamp-01' and x['stock'] == 0]
assert len(zeroed) == 1 and zeroed[0]['delta_ts'] <= ${DELTA_TS} + 5, d
print('ASSERT inventory delta timestamped OK')
"

echo "== the in-stock match closes; order states mirror to the ERP =="
curl -sf -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
curl -sf -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"
# The order-event webhooks are async (detached thread); wait for the ERP
# mirror to converge to the seller state.
for _ in $(seq 1 15); do
    ERP=$(curl -sf "${CONNECT}/v1/erp/orders/${MATCH_ID}" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)
    if [ "$ERP" = "settled" ]; then break; fi
    sleep 2
done
SELLER_STATE=$(curl -sf "${SELLER}/v1/orders/match/${MATCH_ID}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')
if [ "$ERP" != "settled" ] || [ "$SELLER_STATE" != "settled" ]; then
    echo "ERP mirror ($ERP) and seller ($SELLER_STATE) not both settled" >&2
    exit 9
fi
echo "ASSERT ERP mirror equals seller state at settlement OK"

echo "== TVP: an out-of-scope call is refused and logged, nothing returned =="
OOS_CODE=$(curl -s -o /tmp/oos.out -w '%{http_code}' -X POST "${CONNECT}/v1/query" \
    -d "{\"credential\":\"${CRED}\",\"resource\":\"settlement\"}")
if [ "$OOS_CODE" != "403" ]; then
    echo "out-of-scope call not refused (got ${OOS_CODE})" >&2
    exit 9
fi
if grep -q '"ok"' /tmp/oos.out; then
    echo "out-of-scope call returned data" >&2
    exit 9
fi
curl -sf "${CONNECT}/v1/audit" | python3 -c "
import sys, json
a = json.load(sys.stdin)['audit']
assert any(e['scope'] == 'settlement' and e['event'] == 'out-of-scope' for e in a), a
print('ASSERT out-of-scope refused and logged OK')
"

echo "== TVP: a replayed webhook delivery produces no duplicate effect =="
curl -sf -X POST "${CONNECT}/v1/webhooks/replay" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"settled\"}" \
    | python3 -c 'import sys,json;assert json.load(sys.stdin)["duplicate"] is True;print("ASSERT replay is idempotent OK")'

echo "== Elena revokes the integration grant -> credentials die =="
curl -sf -X POST "${CONNECT}/v1/grants/revoke" -d "{\"credential\":\"${CRED}\"}" \
    | python3 -c 'import sys,json;assert json.load(sys.stdin)["revoked"] is True'
REVOKED_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${CONNECT}/v1/sync/inventory" \
    -d "{\"credential\":\"${CRED}\",\"offer_id\":\"erp-clock-02\",\"stock\":0,\"delta_ts\":$(date +%s)}")
if [ "$REVOKED_CODE" != "401" ]; then
    echo "sync after revoke did not fail auth (got ${REVOKED_CODE})" >&2
    exit 9
fi
# The catalog remains intact and hand-editable (the clock is still there).
curl -sf "${SELLER}/v1/offers/region/region-a" | python3 -c "
import sys, json
ids = {o['offer_id'] for o in json.load(sys.stdin)['offers']}
assert 'erp-clock-02' in ids, ids
print('ASSERT credentials die on revoke; catalog intact OK')
"

echo "== TVP: no buyer identity or need content on the integration surface =="
for ep in audit deltas; do
    curl -sf "${CONNECT}/v1/${ep}" | python3 -c "
import sys, json
text = json.dumps(json.load(sys.stdin)).lower()
for marker in ['maya', 'wedding gift', 'budget_cents', 'deadline_days', 'envelope']:
    assert marker not in text, f'integration surface leaked: {marker}'
"
done
echo "ASSERT zero buyer signal on the integration surface OK"

echo "s007.inventory HAPPY PATH PASSED"
