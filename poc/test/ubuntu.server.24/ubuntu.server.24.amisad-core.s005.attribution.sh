#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s005.attribution run on amisad-core: campaign-boosted match,
# edge creative serving, and attribution credit. Marcel creates a campaign and
# brief; Kai produces an approved asset; Marcel activates it; Maya's need in
# the campaign category matches Elena's offer boosted with Kai's creative
# (rendered INSIDE the sealed environment); on accept the settlement carries
# non-zero agency + creator credit; the campaign budget decrements by the
# per-match commitment; and no buyer signal appears on the campaign side.
# EDGE_HOST (optional override): ssh target for slice-runtime.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"
SELLER="http://${NODE_IP}:30083"
ADS="http://${NODE_IP}:30087"

echo "== slice-runtime (edge amisad-edge-a) =="
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
SSH_OPTS=(-i "$REAL_HOME/.ssh/amisad-demo-key" -o StrictHostKeyChecking=accept-new)
# --- REGION: https://yuruna.link/network#defining-the-guest-to-guest-rail
# --- REGION: a failed service call must name the service and what it answered
# `curl -sf` prints nothing on a non-2xx and exits non-zero. On the LEFT of a
# pipe that is invisible: the parser downstream reads empty stdin and reports a
# syntax error at line 1, so a service that never answered is diagnosed as
# malformed data -- the run then ends on a traceback naming neither the URL nor
# the status. Takes the same arguments as `curl -sf` and, on success, writes the
# body to stdout unchanged, so callers can pipe it exactly like `curl -sf`.
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
    ssh "${SSH_OPTS[@]}" "$EDGE_HOST" "pkill -x slice-runtime 2>/dev/null || true"
    scp "${SSH_OPTS[@]}" target/release/slice-runtime "${EDGE_HOST}:/tmp/slice-runtime"
    ssh "${SSH_OPTS[@]}" "$EDGE_HOST" \
        "PORT=8080 LEDGER_URL=$LEDGER RESOURCE_URL=$RESOURCE nohup /tmp/slice-runtime >/tmp/slice-runtime.log 2>&1 & sleep 1; echo edge-started"
    EDGE_IP=$(ssh "${SSH_OPTS[@]}" "$EDGE_HOST" "hostname -I | awk '{print \$1}'")
    SLICE_EP="http://${EDGE_IP}:8080"
else
    # --- REGION: https://yuruna.link/network#why-the-single-vm-fallback-is-gated
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

echo "== register edge + seed Elena's summer offer =="
amisad_curl -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'

echo "== Marcel: campaign + brief; Kai: asset; Marcel: activate =="
CAMP=$(amisad_curl -X POST "${ADS}/v1/campaigns" \
    -d '{"tenant":"elena-atelier","region":"region-a","category":"housewares","ad_cents_per_match":2000,"budget_cents":10000}')
CAMPAIGN_ID=$(echo "$CAMP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["campaign_id"])')
amisad_curl -X POST "${ADS}/v1/briefs" -d "{\"campaign_id\":\"${CAMPAIGN_ID}\"}"
# Kai sees the brief in the demand queue, then produces the asset.
amisad_curl "${ADS}/v1/briefs" | python3 -c "
import sys, json
b = json.load(sys.stdin)['briefs']
assert any(x['campaign_id'] == '${CAMPAIGN_ID}' for x in b), b
print('ASSERT brief in creative queue OK')
"
ASSET=$(amisad_curl -X POST "${ADS}/v1/assets" \
    -d "{\"campaign_id\":\"${CAMPAIGN_ID}\",\"creator\":\"kai\",\"creative\":\"summer-hero-01\"}")
ASSET_ID=$(echo "$ASSET" | python3 -c 'import sys,json;print(json.load(sys.stdin)["asset_id"])')
amisad_curl -X POST "${ADS}/v1/campaigns/activate" \
    -d "{\"campaign_id\":\"${CAMPAIGN_ID}\",\"asset_id\":\"${ASSET_ID}\"}" | python3 -c "
import sys, json
assert json.load(sys.stdin)['state'] == 'active'
print('ASSERT campaign active OK')
"

echo "== Maya's need -> shortlist carries Elena's offer boosted with Kai's creative =="
SHORTLIST=$(target/release/buyer-client campaign)
HANDLE=$(echo "$SHORTLIST" | python3 -c 'import sys,json;print(json.load(sys.stdin)["handle"])')
echo "$SHORTLIST" | python3 -c "
import sys, json
s = json.load(sys.stdin)
entry = [e for e in s['shortlist'] if e['offer_id'] == 'serving-set-01']
assert len(entry) == 1, s
c = entry[0].get('campaign')
assert c and c['campaign_id'] == '${CAMPAIGN_ID}' and c['asset_id'] == '${ASSET_ID}', entry[0]
assert c['creator'] == 'kai' and c['creative'] == 'summer-hero-01', c
print('ASSERT offer boosted with the creative OK')
"

echo "== TVP: the creative appears in the environment ingress log =="
amisad_curl "${SLICE_EP}/v1/ingress" | python3 -c "
import sys, json
entries = json.load(sys.stdin)['entries']
assert any('summer-hero-01' in e for e in entries), entries
print('ASSERT creative in ingress log OK')
"

echo "== Maya accepts -> the boosted match closes =="
BOOK=$(target/release/buyer-client book "$HANDLE" serving-set-01)
MATCH_ID=$(echo "$BOOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')
echo "$BOOK" | python3 -c 'import sys,json;assert json.load(sys.stdin).get("boosted") is True;print("ASSERT booking is boosted OK")'
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"

echo "== TVP: settlement includes non-zero agency + creator credit =="
amisad_curl "${LEDGER}/v1/settlements/match/${MATCH_ID}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['confirmed'] is True, s
# value = price 11000 + ad commitment 2000 = 13000
assert s['total_cents'] == s['value_cents'] == 13000, (s['total_cents'], s['value_cents'])
parties = {e['party']: e['amount_cents'] for e in s['entries']}
assert parties['agency'] == 1200 and parties['creator'] == 800, parties
assert parties['seller'] == 9900, parties  # seller revenue unchanged from s001
print('ASSERT agency + creator credit in settlement OK')
"

echo "== TVP: aggregate dashboards match the ledger; budget decremented by the commitment =="
amisad_curl "${ADS}/v1/attributions" | python3 -c "
import sys, json
a = json.load(sys.stdin)
assert a['closed_matches'] == 1, a
assert a['agency_cents_total'] == 1200 and a['creator_cents_total'] == 800, a
attr = a['attributions'][0]
assert attr['campaign_id'] == '${CAMPAIGN_ID}' and attr['asset_id'] == '${ASSET_ID}', attr
print('ASSERT aggregate attribution consistent with ledger OK')
"
amisad_curl "${ADS}/v1/campaigns/${CAMPAIGN_ID}" | python3 -c "
import sys, json
c = json.load(sys.stdin)
assert c['spent_cents'] == 2000, c  # per-match commitment, not impressions
print('ASSERT campaign budget decrement OK')
"

echo "== TVP: no buyer signal on the campaign side =="
amisad_curl "${ADS}/v1/attributions" | python3 -c "
import sys, json
text = json.dumps(json.load(sys.stdin)).lower()
for marker in ['maya', 'budget_cents', 'deadline_days', 'summer entertaining', 'envelope']:
    assert marker not in text, f'campaign side leaked: {marker}'
print('ASSERT zero buyer signal on the campaign side OK')
"

echo "s005.attribution HAPPY PATH PASSED"
