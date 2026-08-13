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
    curl -sf -X POST "${INSIGHTS}/v1/insights/record" -d '{"category":"housewares","region":"region-a","kind":"need"}' >/dev/null
done
for _ in $(seq 1 2); do
    curl -sf -X POST "${INSIGHTS}/v1/insights/record" -d '{"category":"housewares","region":"region-a","kind":"offer"}' >/dev/null
    curl -sf -X POST "${INSIGHTS}/v1/insights/record" -d '{"category":"housewares","region":"region-b","kind":"need"}' >/dev/null
done

echo "== Dana's workbench: high-volume region visible, below-threshold SUPPRESSED =="
curl -sf "${INSIGHTS}/v1/workbench" | python3 -c "
import sys, json
w = json.load(sys.stdin)
assert w['threshold'] == 5, w
cells = {(a['category'], a['region']): a['demand'] for a in w['aggregates']}
assert cells.get(('housewares','region-a')) == 6, w
assert ('housewares','region-b') not in cells, w  # suppressed, not zeroed
print('ASSERT below-threshold region suppressed from the workbench OK')
"

echo "== Dana publishes a versioned outlook =="
curl -sf -X POST "${INSIGHTS}/v1/outlooks" -d '{"version":"2026-Q3"}' | python3 -c "
import sys, json
o = json.load(sys.stdin)
regions = {a['region'] for a in o['aggregates']}
assert regions == {'region-a'}, o
print('ASSERT published outlook carries only above-threshold figures OK')
"

echo "== TVP: seller + ads views carry IDENTICAL published figures =="
SELLER_VIEW=$(curl -sf "${SELLER}/v1/demand-outlook/2026-Q3")
ADS_VIEW=$(curl -sf "${ADS}/v1/demand-view/2026-Q3")
INSIGHTS_VIEW=$(curl -sf "${INSIGHTS}/v1/outlooks/2026-Q3")
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
curl -sf "${INSIGHTS}/v1/unmet-demand" | python3 -c "
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
for view in "$SELLER_VIEW" "$ADS_VIEW" "$INSIGHTS_VIEW" "$(curl -sf ${INSIGHTS}/v1/workbench)" "$(curl -sf ${INSIGHTS}/v1/unmet-demand)"; do
    echo "$view" | python3 -c "
import sys
assert 'region-b' not in sys.stdin.read(), 'below-threshold region leaked downstream'
"
done
echo "ASSERT below-threshold region appears nowhere downstream OK"

echo "s009.suppression HAPPY PATH PASSED"
