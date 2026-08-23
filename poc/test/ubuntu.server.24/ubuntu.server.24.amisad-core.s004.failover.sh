#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s004.failover run on amisad-core: sovereign slice
# allocation, isolation fault, attested failover. Both edges run
# slice-runtime with their region identity; Tom's policy pins the restricted
# jurisdiction to region-a although region-b is roomier; two injected
# isolation faults abort two environments SAFELY (attested abort with reason,
# before the envelope is ever opened); the fabric's automatic retry completes
# the match with exactly one settlement; both incidents queue for Tom, and
# the systemic pattern escalates to Priya's cross-party platform case.
# This scenario REQUIRES both edges - there is no degraded fallback.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

NODE_IP=$(hostname -I | awk '{print $1}')
LEDGER="http://${NODE_IP}:30081"
RESOURCE="http://${NODE_IP}:30082"
SELLER="http://${NODE_IP}:30083"
PLATFORM="http://${NODE_IP}:30086"

echo "== slice-runtime on BOTH edges (region identity attested) =="
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_STATUS_SERVICE_IP:-}" ]; then
    echo "no host.env - cannot resolve the edges" >&2
    exit 2
fi
SSH_OPTS=(-i "$REAL_HOME/.ssh/amisad-demo-key" -o StrictHostKeyChecking=accept-new)
# --- REGION: https://yuruna.link/network#defining-the-guest-to-guest-rail
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

start_slice() { # <edge-hostname> <region>
    # Runs inside $( ) - errexit does NOT reach in here, so every step fails
    # loudly by hand; the exit code escapes through pipefail to the caller.
    local edge="$1" region="$2" ip host
    ip=$(amisad_edge_addr "$edge")
    if [ -z "$ip" ]; then
        echo "edge ${edge} IP report missing - s004 requires both edges live" >&2
        exit 7
    fi
    host="${edge}-admin@${ip}"
    ssh "${SSH_OPTS[@]}" "$host" "pkill -x slice-runtime 2>/dev/null || true" \
        || { echo "ssh to ${edge} (${ip}) failed" >&2; exit 7; }
    scp "${SSH_OPTS[@]}" target/release/slice-runtime "${host}:/tmp/slice-runtime" \
        || { echo "scp slice-runtime to ${edge} failed" >&2; exit 7; }
    ssh "${SSH_OPTS[@]}" "$host" \
        "PORT=8080 REGION=${region} LEDGER_URL=$LEDGER RESOURCE_URL=$RESOURCE nohup /tmp/slice-runtime >/tmp/slice-runtime.log 2>&1 & sleep 1; echo ${edge}-started" \
        || { echo "slice-runtime start on ${edge} failed" >&2; exit 7; }
    echo "$ip"
}
EDGE_A_IP=$(start_slice amisad-edge-a region-a | tail -n 1)
EDGE_B_IP=$(start_slice amisad-edge-b region-b | tail -n 1)
SLICE_A="http://${EDGE_A_IP}:8080"
SLICE_B="http://${EDGE_B_IP}:8080"
for ep in "$SLICE_A" "$SLICE_B"; do
    for _ in $(seq 1 15); do
        if curl -sf "${ep}/health" >/dev/null 2>&1; then break; fi
        sleep 2
    done
    curl -sf "${ep}/health" >/dev/null
done
echo "slices: region-a at ${SLICE_A}, region-b at ${SLICE_B}"

export COORDINATOR_URL="http://${NODE_IP}:30080" IDENTITY_URL="http://${NODE_IP}:30084"
PSQL() { sudo -u postgres psql -d amisad -tAc "$1"; }

echo "== Tom: allocation policy - two regions, region-b roomier, region-a sovereign =="
amisad_curl -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-a\",\"endpoint\":\"${SLICE_A}\",\"capacity\":2}"
amisad_curl -X POST "${RESOURCE}/v1/edges" \
    -d "{\"region\":\"region-b\",\"endpoint\":\"${SLICE_B}\",\"capacity\":10}"
amisad_curl -X POST "${RESOURCE}/v1/policies" \
    -d '{"jurisdiction":"region-a","regions":["region-a"]}'

echo "== TVP pre-assert: default placement is capacity-greedy; only the policy pins region-a =="
amisad_curl -X POST "${RESOURCE}/v1/placements" -d '{"jurisdiction":"region-unrestricted"}' | python3 -c "
import sys, json
p = json.load(sys.stdin)
assert p['region'] == 'region-b', p  # roomier region wins without a policy
print('ASSERT capacity-greedy default picks region-b OK')
"
amisad_curl -X POST "${RESOURCE}/v1/placements" -d '{"jurisdiction":"region-a"}' | python3 -c "
import sys, json
p = json.load(sys.stdin)
assert p['region'] == 'region-a', p  # sovereignty excludes the roomier region
print('ASSERT jurisdiction policy pins region-a OK')
"

echo "== seed Elena's offer =="
amisad_curl -X POST "${SELLER}/v1/offers" \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'

echo "== harness: arm TWO consecutive isolation faults on the compliant slice =="
amisad_curl -X POST "${SLICE_A}/v1/faults" -d '{"mode":"isolation","count":2}' | python3 -c "
import sys, json
assert json.load(sys.stdin)['armed'] == 2
print('ASSERT faults armed OK')
"

echo "== the match: abort, abort (systemic), then a clean completion =="
RESULT=$(target/release/buyer-client submit)
MATCH_ID=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["match_id"])')
ENV_OK=$(echo "$RESULT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["environment_id"])')
echo "completed match ${MATCH_ID} in environment ${ENV_OK}"

echo "== Tom's incident queue: both aborted slices, fault reason attached =="
INCIDENTS=$(amisad_curl "${RESOURCE}/v1/incidents")
ENV_ABORT_1=$(echo "$INCIDENTS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["incidents"][0]["environment_id"])')
ENV_ABORT_2=$(echo "$INCIDENTS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["incidents"][1]["environment_id"])')
echo "$INCIDENTS" | python3 -c "
import sys, json
i = json.load(sys.stdin)['incidents']
assert len(i) == 2, i
for entry in i:
    assert entry['event'] == 'aborted' and entry['fault'] == 'isolation', entry
    assert entry['region'] == 'region-a', entry
print('ASSERT two isolation incidents queued OK')
"

echo "== TVP: aborted lifecycles read created-attested-aborted-destroyed, no egress =="
for env in "$ENV_ABORT_1" "$ENV_ABORT_2"; do
    amisad_curl "${LEDGER}/v1/attestations/env/${env}" | python3 -c "
import sys, json
entries = json.load(sys.stdin)['entries']
states = [e['lifecycle'] for e in entries]
assert states == ['created', 'attested', 'aborted', 'destroyed'], states
aborted = [e for e in entries if e['lifecycle'] == 'aborted'][0]
assert aborted['fault'] == 'isolation', aborted
text = json.dumps(entries).lower()
for marker in ['maya', 'budget_cents', 'deadline_days', 'context', 'envelope', 'wish list']:
    assert marker not in text, f'aborted environment leaked: {marker}'
print('ASSERT aborted lifecycle + zero egress OK')
"
done
amisad_curl "${LEDGER}/v1/attestations/env/${ENV_OK}" | python3 -c "
import sys, json
states = [e['lifecycle'] for e in json.load(sys.stdin)['entries']]
assert states == ['created', 'attested', 'executed', 'destroyed'], states
print('ASSERT completed lifecycle OK')
"

echo "== TVP: zero out-of-region attestation entries =="
amisad_curl "${LEDGER}/v1/attestations" | python3 -c "
import sys, json
entries = json.load(sys.stdin)['entries']
assert len(entries) == 12, len(entries)  # 3 environments x 4 lifecycle events
for e in entries:
    assert e['payload']['region'] == 'region-a', e
print('ASSERT every allocation stayed in the compliant region OK')
"

echo "== the completed match settles; hosting revenue for it ONLY =="
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"provisioning\"}"
amisad_curl -X POST "${SELLER}/v1/orders/advance" -d "{\"match_id\":\"${MATCH_ID}\",\"state\":\"fulfilled\"}"
amisad_curl "${LEDGER}/v1/verify" | python3 -c "
import sys, json
v = json.load(sys.stdin)
assert v['attestation_ok'] and v['settlement_ok'], v
assert v['settlement_len'] == 4, v  # exactly one settled match (4 splits)
print('ASSERT exactly one settlement OK')
"
amisad_curl "${LEDGER}/v1/settlements/match/${MATCH_ID}" | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['confirmed'] is True and s['total_cents'] == s['value_cents'] == 11000, s
network = [e for e in s['entries'] if e['party'] == 'network']
assert len(network) == 1, s  # hosting revenue once - nothing for the aborts
print('ASSERT hosting revenue for the completed match only OK')
"

echo "== Tom escalates to Priya: cross-party case links both aborted lifecycles =="
CASE_ID=$(amisad_curl -X POST "${PLATFORM}/v1/incidents" \
    -d "{\"summary\":\"systemic isolation faults in region-a\",\"from\":\"resource-ops\",\"environment_ids\":[\"${ENV_ABORT_1}\",\"${ENV_ABORT_2}\"]}" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["case_id"])')
amisad_curl "${PLATFORM}/v1/incidents/${CASE_ID}" | python3 -c "
import sys, json
case = json.load(sys.stdin)
ids = case['environment_ids']
assert ids == ['${ENV_ABORT_1}', '${ENV_ABORT_2}'], ids
assert case['status'] == 'open', case
print('ASSERT platform case references both aborted lifecycles OK')
"

echo "== durable store: all twelve attestation rows in PostgreSQL =="
ROWS=$(PSQL "SELECT count(*) FROM ledger.attestation_ledger")
if [ "$ROWS" != "12" ]; then
    echo "attestation rows not persisted as expected (rows: ${ROWS})" >&2
    exit 9
fi
echo "ASSERT PostgreSQL attestation write-through OK"

echo "s004.failover HAPPY PATH PASSED"
