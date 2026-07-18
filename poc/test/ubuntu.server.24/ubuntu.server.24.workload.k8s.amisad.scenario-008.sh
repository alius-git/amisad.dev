#!/bin/bash
# AmisAd POC - SCENARIO-008 skeleton checks.
# Zero-Knowledge Dispute Mediation and Settlement Adjustment
# The sequence runs the shared deploy script first; this script only verifies.
set -euo pipefail

# Services this scenario traverses (plan/scenarios.md cross-refs).
SERVICES="platform-svc seller-svc ledger-svc"

for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=300s
done

for svc in $SERVICES; do
    kubectl -n amisad run "check-${svc}-${RANDOM}" --rm -i --restart=Never \
        --image=curlimages/curl -- -sf "http://${svc}:8080/health"
    echo "OK ${svc}/health"
done

# TODO(SCENARIO-008): implement the real sequence from plan/scenarios.md:
#   - Maya reports non-delivery on a settled order
#   - Sam mediates on metadata; buyer identity structurally absent
#   - Consented disclosure: request -> grant -> artifact -> expiry
#   - Refund posted as compensating entries referencing the case
#   - Recurring pattern escalates to Priya
#   - Assert: case identity-free end to end; post-expiry access fails

echo "SCENARIO-008 skeleton checks passed"