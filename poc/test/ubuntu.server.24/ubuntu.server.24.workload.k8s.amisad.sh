#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42d0b04a-d061-440b-b09b-4a3303f612b8
# AmisAd POC - build all service images and deploy the skeleton charts (idempotent).
# --- REGION: Initialize environment
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true

POC="$REAL_HOME/git/yuruna/project/poc"

SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"

# Local distribution registry, as in the yuruna-project examples: one exact
# release, and the port published on the loopback address only, because the
# client that pushes and the node that pulls share this guest; open to the LAN,
# it would take pushes from any machine there. A container an earlier run
# published on every address is created again.
REGISTRY_IMAGE="registry:2.8.3"
if docker inspect registry >/dev/null 2>&1; then
    registry_bind=$(docker inspect -f '{{range (index .HostConfig.PortBindings "5000/tcp")}}{{.HostIp}} {{end}}' registry 2>/dev/null || true)
    if [ "$registry_bind" != "127.0.0.1 " ]; then
        echo "Re-creating the registry container to publish port 5000 on 127.0.0.1 only"
        docker rm -f registry >/dev/null 2>&1 || true
    fi
fi
docker start registry 2>/dev/null || \
    docker run -d -p 127.0.0.1:5000:5000 --restart=always --name registry "$REGISTRY_IMAGE"

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
