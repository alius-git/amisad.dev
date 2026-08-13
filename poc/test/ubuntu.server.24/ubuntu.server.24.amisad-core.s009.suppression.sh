#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - s009.suppression run on amisad-core: aggregate insight
# publication and the demand-planning loop. Seed demand across a high-volume
# region (above the anonymity threshold) and a below-threshold region; prove
# the below-threshold region is SUPPRESSED (absent, not zeroed) from Dana's
# workbench, the published versioned outlook, and Elena's seller +
# Marcel's ads views - which carry identical figures. No edge/matching.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

NODE_IP=$(hostname -I | awk '{print $1}')
SELLER="http://${NODE_IP}:30083"
INSIGHTS="http://${NODE_IP}:30085"
ADS="http://${NODE_IP}:30087"

echo "== seed demand: region-a housewares ABOVE threshold, region-b BELOW =="
# Anonymity threshold is 5. region-a housewares gets 6 needs (published);
# region-b housewares gets 2 needs (suppressed). region-a also gets 2 offers
# so needs outnumber offers -> an unmet-demand gap in the high-volume region.
for _ in $(seq 1 6); do
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

    curl -sf -X POST "${INSIGHTS}/v1/insights/record" -d '{"category":"housewares","region":"region-a","kind":"need"}' >/dev/null
done
for _ in $(seq 1 2); do
    curl -sf -X POST "${INSIGHTS}/v1/insights/record" -d '{"category":"housewares","region":"region-a","kind":"offer"}' >/dev/null
    curl -sf -X POST "${INSIGHTS}/v1/insights/record" -d '{"category":"housewares","region":"region-b","kind":"need"}' >/dev/null
done

echo "== Dana's workbench: high-volume region visible, below-threshold SUPPRESSED =="
amisad_curl "${INSIGHTS}/v1/workbench" | python3 -c "
import sys, json
w = json.load(sys.stdin)
assert w['threshold'] == 5, w
cells = {(a['category'], a['region']): a['demand'] for a in w['aggregates']}
assert cells.get(('housewares','region-a')) == 6, w
assert ('housewares','region-b') not in cells, w  # suppressed, not zeroed
print('ASSERT below-threshold region suppressed from the workbench OK')
"

echo "== Dana publishes a versioned outlook =="
amisad_curl -X POST "${INSIGHTS}/v1/outlooks" -d '{"version":"2026-Q3"}' | python3 -c "
import sys, json
o = json.load(sys.stdin)
regions = {a['region'] for a in o['aggregates']}
assert regions == {'region-a'}, o
print('ASSERT published outlook carries only above-threshold figures OK')
"

echo "== TVP: seller + ads views carry IDENTICAL published figures =="
SELLER_VIEW=$(amisad_curl "${SELLER}/v1/demand-outlook/2026-Q3")
ADS_VIEW=$(amisad_curl "${ADS}/v1/demand-view/2026-Q3")
INSIGHTS_VIEW=$(amisad_curl "${INSIGHTS}/v1/outlooks/2026-Q3")
python3 -c "
import json
s = json.loads('''${SELLER_VIEW}''')
a = json.loads('''${ADS_VIEW}''')
i = json.loads('''${INSIGHTS_VIEW}''')
assert s == a == i, (s, a, i)  # identical by construction (same version)
assert s['version'] == '2026-Q3'
print('ASSERT seller view == ads view == published outlook OK')
"

echo "== unmet-demand flags the seeded gap, category+region only =="
amisad_curl "${INSIGHTS}/v1/unmet-demand" | python3 -c "
import sys, json
u = json.load(sys.stdin)['unmet']
flags = {(f['category'], f['region']) for f in u}
assert ('housewares','region-a') in flags, u   # needs 6 > offers 2, above threshold
assert ('housewares','region-b') not in flags, u  # below threshold: never surfaces
for f in u:
    assert set(f.keys()) == {'category','region'}, f  # no figures
print('ASSERT unmet-demand flag (category+region only) OK')
"

echo "== TVP: no below-threshold (region-b) figure appears in ANY view =="
for view in "$SELLER_VIEW" "$ADS_VIEW" "$INSIGHTS_VIEW" "$(amisad_curl ${INSIGHTS}/v1/workbench)" "$(amisad_curl ${INSIGHTS}/v1/unmet-demand)"; do
    echo "$view" | python3 -c "
import sys
assert 'region-b' not in sys.stdin.read(), 'below-threshold region leaked downstream'
"
done
echo "ASSERT below-threshold region appears nowhere downstream OK"

echo "s009.suppression HAPPY PATH PASSED"
