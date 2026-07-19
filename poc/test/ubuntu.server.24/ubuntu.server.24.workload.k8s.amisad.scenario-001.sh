#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 alius-git
# AmisAd POC - SCENARIO-001 skeleton checks.
# Intent-Driven Edge Match and Automated Fulfillment
# The sequence runs the shared deploy script first; this script only verifies.
set -euo pipefail

# Services this scenario traverses (plan/scenarios.md cross-refs).
SERVICES="seller-svc resource-svc fabric-coordinator ledger-svc identity-mock"

for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=300s
done

for svc in $SERVICES; do
    kubectl -n amisad run "check-${svc}-${RANDOM}" --rm -i --restart=Never \
        --image=curlimages/curl -- -sf "http://${svc}:8080/health"
    echo "OK ${svc}/health"
done

# TODO(SCENARIO-001): implement the real steps and Target Verification Point from plan/scenarios.md (SCENARIO-001).

echo "SCENARIO-001 skeleton checks passed"