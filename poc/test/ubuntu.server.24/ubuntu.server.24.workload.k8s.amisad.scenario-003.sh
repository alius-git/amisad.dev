#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 alius-git
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

# TODO(SCENARIO-003): implement the real steps and Target Verification Point from plan/scenarios.md (SCENARIO-003).

echo "SCENARIO-003 skeleton checks passed"