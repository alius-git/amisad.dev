#!/bin/bash
# AmisAd POC - SCENARIO-005 skeleton checks.
# Campaign-Boosted Match, Edge Creative Serving, and Attribution Credit
# The sequence runs the shared deploy script first; this script only verifies.
set -euo pipefail

# Services this scenario traverses (plan/scenarios.md cross-refs).
SERVICES="ads-svc insights-svc seller-svc fabric-coordinator ledger-svc"

for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=300s
done

for svc in $SERVICES; do
    kubectl -n amisad run "check-${svc}-${RANDOM}" --rm -i --restart=Never \
        --image=curlimages/curl -- -sf "http://${svc}:8080/health"
    echo "OK ${svc}/health"
done

# TODO(SCENARIO-005): implement the real sequence from plan/scenarios.md:
#   - Marcel creates a campaign from the aggregate demand view
#   - Brief to Kai; asset approved and placed
#   - Buyer need in campaign region; creative renders inside the environment
#   - Acceptance closes the match; attribution computed in the fabric
#   - Agency and creator credit on the ledger; budget decrements by outcome
#   - Assert: non-zero ad-partner credit, zero buyer signal campaign-side

echo "SCENARIO-005 skeleton checks passed"