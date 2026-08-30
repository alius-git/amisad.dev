#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s003.silence run on amisad-core: consent revocation and the
# right to silence. Seed one in-flight order and two open needs, pause
# participation (consent ledger revocation), prove a perfectly fitting new
# offer produces NOTHING (no environment, no match, no notification), settle
# the pre-revocation order normally, withdraw (aggregation loses her
# contribution), resume (open needs served again immediately), and assert the
# FULL Target Verification Point incl. the immutable grant-revoke-regrant
# history. EDGE_HOST (optional override): ssh target for slice-runtime.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"
SELLER="http://${NODE_IP}:30083"
INSIGHTS="http://${NODE_IP}:30085"

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
PSQL() { sudo -u postgres psql -d amisad -tAc "$1"; }

echo "== seed: edge, Elena's catalog, Maya's signup consents =="
amisad_curl -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_EP}\"}"
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"crystal-vase-02","tenant":"elena-atelier","title":"Crystal vase","category":"housewares","region":"region-a","price_cents":15000,"deliver_by_days":5,"auto_close":true}'
# Signup: explicit contribution + participation grants open the consent history.
target/release/buyer-client resume

echo "== seed: one order in flight (committed, NOT advanced) =="
RESULT=$(target/release/buyer-client submit)
MATCH_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')
echo "in-flight match: ${MATCH_ID}"

echo "== seed: two open needs (nothing fits them yet) =="
DRESS=$(target/release/buyer-client open dress)
DRESS_HANDLE=$(echo "$DRESS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["handle"])')
echo "$DRESS" | python3 -c 'import sys,json;assert json.load(sys.stdin)["status"]=="open";print("ASSERT dress need open OK")'
target/release/buyer-client open decanter | python3 -c 'import sys,json;assert json.load(sys.stdin)["status"]=="open";print("ASSERT decanter need open OK")'

echo "== baseline aggregation: both open needs contribute =="
RESP=$(amisad_curl -X POST "${INSIGHTS}/v1/aggregation/cycle")
echo "$RESP" | python3 -c "
import sys, json
c = json.load(sys.stdin)
assert c['contributions'] == 2, c
print('ASSERT baseline contributions == 2 OK')
"

echo "== Maya pauses participation (revocation on the consent ledger) =="
target/release/buyer-client pause
ATTEST_AT_PAUSE=$(PSQL "SELECT count(*) FROM ledger.attestation_ledger")
echo "attestation rows at pause: ${ATTEST_AT_PAUSE}"

echo "== silence: a perfectly fitting offer appears - and NOTHING happens =="
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"linen-wrap-09","tenant":"brisa-outlet","title":"Linen wrap dress","category":"dresses","region":"region-a","price_cents":13000,"deliver_by_days":2,"auto_close":true,"attributes":["midi","sleeves","warm-fabric"]}'
sleep 5   # the offer-published event is asynchronous; give the cycle time to (not) act
RESP=$(amisad_curl "${COORDINATOR_URL}/v1/notifications/${DRESS_HANDLE}")
echo "$RESP" | python3 -c "
import sys, json
n = json.load(sys.stdin)['notifications']
assert n == [], f'paused buyer was notified: {n}'
print('ASSERT zero notifications while paused OK')
"
RESP=$(amisad_curl "${SELLER}/v1/orders")
echo "$RESP" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['count'] == 1, o
print('ASSERT no new order while paused OK')
"

echo "== even an explicit cycle is a no-op at the consent gate =="
# Poke the cycle endpoint directly: this proves a cycle DEFINITELY ran while
# paused and matched nothing - independent of the seller's async event.
RESP=$(amisad_curl -X POST "${COORDINATOR_URL}/v1/offers/published")
echo "$RESP" | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['rematched'] == 0, r
print('ASSERT explicit cycle rematched nothing while paused OK')
"

echo "== a direct matching request is REFUSED at the consent gate =="
REFUSAL=$(target/release/buyer-client open decanter 2>&1 || true)
if ! echo "$REFUSAL" | grep -q "(403)"; then
    echo "matching was NOT refused with 403 while participation is revoked: ${REFUSAL}" >&2
    exit 9
fi
echo "ASSERT refusal while paused OK"

echo "== the in-flight order proceeds: pre-revocation commitments are honored =="
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"
RESP=$(amisad_curl "${LEDGER}/v1/settlements/match/${MATCH_ID}")
echo "$RESP" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['confirmed'] is True, 'settlement not confirmed'
assert s['total_cents'] == s['value_cents'] == 11000, (s['total_cents'], s['value_cents'])
print('ASSERT in-flight order settled normally OK')
"

echo "== Maya withdraws entirely: aggregation loses her contribution =="
target/release/buyer-client withdraw
RESP=$(amisad_curl -X POST "${INSIGHTS}/v1/aggregation/cycle")
echo "$RESP" | python3 -c "
import sys, json
c = json.load(sys.stdin)
assert c['contributions'] == 0, c
print('ASSERT zero contributions after withdrawal OK')
"

echo "== TVP: zero environments in the whole paused window =="
ATTEST_BEFORE_RESUME=$(PSQL "SELECT count(*) FROM ledger.attestation_ledger")
if [ "$ATTEST_BEFORE_RESUME" != "$ATTEST_AT_PAUSE" ]; then
    echo "environments were created while paused: ${ATTEST_AT_PAUSE} -> ${ATTEST_BEFORE_RESUME}" >&2
    exit 9
fi
echo "ASSERT zero environments while paused OK"

echo "== Maya resumes: the open needs are served again immediately =="
RESUME=$(target/release/buyer-client resume)
echo "$RESUME" | tail -n 1 | python3 -c "
import sys, json
r = json.load(sys.stdin)
assert r['rematched'] == 1, r
print('ASSERT resumption rematched the dress need OK')
"
RESP=$(amisad_curl "${COORDINATOR_URL}/v1/notifications/${DRESS_HANDLE}")
echo "$RESP" | python3 -c "
import sys, json
n = [e['kind'] for e in json.load(sys.stdin)['notifications']]
assert n == ['match'], n
print('ASSERT match notification after resume OK')
"
RESP=$(amisad_curl "${SELLER}/v1/orders")
echo "$RESP" | python3 -c "
import sys, json
o = json.load(sys.stdin)
assert o['count'] == 2, o
dress = [x for x in o['orders'] if x['offer_id'] == 'linen-wrap-09']
assert len(dress) == 1 and dress[0]['state'] == 'committed', o
print('ASSERT dress order committed after resume OK')
"
RESP=$(amisad_curl -X POST "${INSIGHTS}/v1/aggregation/cycle")
echo "$RESP" | python3 -c "
import sys, json
c = json.load(sys.stdin)
assert c['contributions'] == 1, c
print('ASSERT decanter need contributes again OK')
"

echo "== TVP: environments only AFTER resumption =="
ATTEST_FINAL=$(PSQL "SELECT count(*) FROM ledger.attestation_ledger")
python3 -c "
before, final = int('${ATTEST_BEFORE_RESUME}'), int('${ATTEST_FINAL}')
# The resume cycle attempts BOTH open needs: the dress match is one
# environment and the still-open decanter is one no-fit environment -
# each attests created/attested/executed/destroyed.
assert final == before + 8, (before, final)
print('ASSERT resumption environments (match + no-fit) OK')
"

echo "== event path proved end to end: a fitting offer now matches on its own =="
# With consent granted, publish -> detached notify -> cycle -> match must
# work WITHOUT any consent poke - this is the positive proof that the
# offer-published event path (silent during the pause by consent, not by
# breakage) actually functions.
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"crystal-decanter-10","tenant":"elena-atelier","title":"Crystal decanter","category":"housewares","region":"region-a","price_cents":8500,"deliver_by_days":7,"auto_close":true}'
for _ in $(seq 1 15); do
    RESP=$(amisad_curl "${SELLER}/v1/orders")
    COUNT=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')
    if [ "$COUNT" = "3" ]; then break; fi
    sleep 2
done
if [ "${COUNT}" != "3" ]; then
    echo "offer-published event did not produce the decanter match (orders: ${COUNT})" >&2
    exit 9
fi
echo "ASSERT offer-published event path OK"

echo "== TVP: immutable consent history, verified chain, no identity =="
CONSENTS=$(target/release/buyer-client consents)
echo "$CONSENTS" | python3 -c "
import sys, json
c = json.load(sys.stdin)
assert c['participation'] == 'granted' and c['contribution'] == 'granted', c
history = [(e['grant_type'], e['action']) for e in c['history']]
assert history == [
    ('contribution', 'grant'), ('participation', 'grant'),
    ('participation', 'revoke'), ('contribution', 'revoke'),
    ('contribution', 'grant'), ('participation', 'grant'),
], history
assert 'maya' not in json.dumps(c).lower(), 'consent history leaked identity'
print('ASSERT consent history grant-revoke-regrant OK')
"
RESP=$(amisad_curl "${LEDGER}/v1/verify")
echo "$RESP" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'] and v['consent_ok'], v
assert v['consent_len'] == 6, v
print('ASSERT all three chains verify OK')
"

echo "== durable store: the consent chain is rows in PostgreSQL =="
CONSENT_ROWS=$(PSQL "SELECT count(*) FROM ledger.consent_ledger")
if [ "$CONSENT_ROWS" != "6" ]; then
    echo "consent chain not persisted (rows: ${CONSENT_ROWS})" >&2
    exit 9
fi
echo "ASSERT PostgreSQL consent write-through OK"

echo "s003.silence HAPPY PATH PASSED"
