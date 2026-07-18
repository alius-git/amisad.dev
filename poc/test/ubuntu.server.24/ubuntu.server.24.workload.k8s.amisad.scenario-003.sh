#!/bin/bash
# AmisAd POC - SCENARIO-003 skeleton checks.
# Consent Revocation and the Right to Silence
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

# TODO(SCENARIO-003): implement the real sequence from plan/scenarios.md:
#   - Seed one in-flight order plus two open needs
#   - Pause participation; revocation timestamped in the consent ledger
#   - Matching refused at the consent check; no environments created
#   - A newly published fitting offer produces silence
#   - In-flight order settles; withdrawal ends aggregate contribution
#   - Resume; matching serves the open needs again
#   - Assert: zero match events in the paused window; immutable grant history

echo "SCENARIO-003 skeleton checks passed"