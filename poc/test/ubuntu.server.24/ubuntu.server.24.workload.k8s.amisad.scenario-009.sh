#!/bin/bash
# AmisAd POC - SCENARIO-009 skeleton checks.
# Aggregate Insight Publication and the Demand-Planning Loop
# The sequence runs the shared deploy script first; this script only verifies.
set -euo pipefail

# Services this scenario traverses (plan/scenarios.md cross-refs).
SERVICES="insights-svc seller-svc ads-svc"

for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=300s
done

for svc in $SERVICES; do
    kubectl -n amisad run "check-${svc}-${RANDOM}" --rm -i --restart=Never \
        --image=curlimages/curl -- -sf "http://${svc}:8080/health"
    echo "OK ${svc}/health"
done

# TODO(SCENARIO-009): implement the real sequence from plan/scenarios.md:
#   - Seed region A above and region B below the anonymity threshold
#   - Environments emit aggregates only; the gate suppresses region B
#   - Dana publishes a versioned outlook into seller and ads views
#   - Elena stocks and Marcel scopes a campaign on identical figures
#   - Unmet-demand flag carries category and region only
#   - Assert: no below-threshold figure anywhere downstream

echo "SCENARIO-009 skeleton checks passed"