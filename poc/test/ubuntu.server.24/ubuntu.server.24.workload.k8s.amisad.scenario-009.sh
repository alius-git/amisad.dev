#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 alius-git
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

# TODO(SCENARIO-009): implement the real steps and Target Verification Point from plan/scenarios.md (SCENARIO-009).

echo "SCENARIO-009 skeleton checks passed"