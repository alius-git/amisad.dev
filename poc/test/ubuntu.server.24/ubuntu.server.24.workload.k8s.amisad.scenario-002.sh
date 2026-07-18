#!/bin/bash
# AmisAd POC - SCENARIO-002 skeleton checks.
# Considered Purchase, Constraint Fidelity, and In-Person Booking
# The sequence runs the shared deploy script first; this script only verifies.
set -euo pipefail

# Services this scenario traverses (plan/scenarios.md cross-refs).
SERVICES="seller-svc fabric-coordinator ledger-svc"

for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=300s
done

for svc in $SERVICES; do
    kubectl -n amisad run "check-${svc}-${RANDOM}" --rm -i --restart=Never \
        --image=curlimages/curl -- -sf "http://${svc}:8080/health"
    echo "OK ${svc}/health"
done

# TODO(SCENARIO-002): implement the real sequence from plan/scenarios.md:
#   - Need with exclusions (not dusty blue) and fitting deadline, manual closing
#   - Shortlist contains only fully fitting offers
#   - No commitment exists before the explicit decision
#   - One-tap booking; seller sees requirements, never identity
#   - Fulfill and settle; exactly two notifications delivered
#   - Assert: excluded offers absent, notification count equals two

echo "SCENARIO-002 skeleton checks passed"