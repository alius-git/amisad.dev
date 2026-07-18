#!/bin/bash
# AmisAd POC - SCENARIO-007 skeleton checks.
# Enterprise Integration Onboarding and Inventory-Truth Matching
# The sequence runs the shared deploy script first; this script only verifies.
set -euo pipefail

# Services this scenario traverses (plan/scenarios.md cross-refs).
SERVICES="connect-svc seller-svc platform-svc identity-mock"

for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=300s
done

for svc in $SERVICES; do
    kubectl -n amisad run "check-${svc}-${RANDOM}" --rm -i --restart=Never \
        --image=curlimages/curl -- -sf "http://${svc}:8080/health"
    echo "OK ${svc}/health"
done

# TODO(SCENARIO-007): implement the real sequence from plan/scenarios.md:
#   - Alex verified; connector certified in the sandbox tenant
#   - Elena grants scoped tenant access; workload credentials issued
#   - Catalog sync; a counter sale zeroes the last unit within the window
#   - Zeroed item is unmatchable; the in-stock alternative closes
#   - Webhooks mirror order states into the ERP; replay is idempotent
#   - Out-of-scope call refused and logged; revocation kills credentials
#   - Assert: no match on stale inventory; zero buyer data in any payload

echo "SCENARIO-007 skeleton checks passed"