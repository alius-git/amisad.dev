#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 alius-git
# AmisAd POC - build all service images and deploy the skeleton charts (idempotent).
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true

POC="$REAL_HOME/git/yuruna/project/poc"

SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"

# Local distribution registry, as in the yuruna-project examples.
docker start registry 2>/dev/null || \
    docker run -d -p 5000:5000 --restart=always --name registry registry:2

cd "$POC"
for svc in $SERVICES; do
    docker build -f "components/services/${svc}/Dockerfile" \
        -t "localhost:5000/amisad/${svc}:latest" .
    docker push "localhost:5000/amisad/${svc}:latest"
    helm upgrade --install "$svc" "workloads/services/${svc}" \
        --namespace amisad --create-namespace \
        --set "image=localhost:5000/amisad/${svc}:latest"
done

kubectl -n amisad get deployments
echo "AmisAd POC skeletons deployed"