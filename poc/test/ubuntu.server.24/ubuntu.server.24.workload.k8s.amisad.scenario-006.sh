#!/bin/bash
# AmisAd POC - SCENARIO-006 skeleton checks.
# Delegated Procurement Under a Scoped Mandate
# The sequence runs the shared deploy script first; this script only verifies.
set -euo pipefail

# Services this scenario traverses (plan/scenarios.md cross-refs).
SERVICES="identity-mock fabric-coordinator ledger-svc"

for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=300s
done

for svc in $SERVICES; do
    kubectl -n amisad run "check-${svc}-${RANDOM}" --rm -i --restart=Never \
        --image=curlimages/curl -- -sf "http://${svc}:8080/health"
    echo "OK ${svc}/health"
done

# TODO(SCENARIO-006): implement the real sequence from plan/scenarios.md:
#   - Maya grants Pat a scoped mandate (category, caps, expiry)
#   - In-scope need closes on the delegate authority with dual attribution
#   - Over-cap match routes an approval handoff to Maya
#   - Out-of-scope attempt is refused at submission
#   - Revocation removes delegated access instantly
#   - Assert: every delegated record references a then-valid mandate

echo "SCENARIO-006 skeleton checks passed"