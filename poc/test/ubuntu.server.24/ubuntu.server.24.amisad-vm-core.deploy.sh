#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - amisad-vm-core deploy step: download the prebuilt binaries from the
# stash service (produced by amisad-vm-build), build thin distroless images from
# them, and deploy the ten services to the in-VM Kubernetes cluster. This VM has
# the runtime stack (Docker+containerd+kubeadm K8s+Helm+PostgreSQL+NATS from the
# amisad-vm-core-k8s baseline) plus python3 - but NO Rust toolchain and no source build.
# STASH_HOST (default 192.168.7.222): the stash-service VM to pull binaries from.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "== runtime deps (python3 for the scenario asserts; curl for the stash) =="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y python3 curl >/dev/null

echo "== obtain project tree (helm charts + deploy layout; NOT the binaries) =="
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_HOST_IP:-}" ] || [ -z "${YURUNA_HOST_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status server" >&2
    exit 2
fi
rm -rf "$REAL_HOME/amisad.dev"
mkdir -p "$REAL_HOME/amisad.dev"
wget --no-proxy -qO /tmp/project-poc.tar.gz \
    "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-repo/project-poc.tar.gz?nocache=${RANDOM}"
tar -xzf /tmp/project-poc.tar.gz -C "$REAL_HOME/amisad.dev"
rm -f /tmp/project-poc.tar.gz

POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== download prebuilt binaries from the stash service =="
# --noproxy '*': the stash IP is not in the guest no_proxy list, so an HTTP GET
# would otherwise be sent through squid. Locate the artifact by the constant
# label amisad-vm-build uploaded under (username amisad-poc, filename amisad-binaries);
# /api/stashes returns newest-first, so limit=1 is the latest build.
STASH_HOST="${STASH_HOST:-192.168.7.222}"
STASH="http://${STASH_HOST}"
curl -fsS --noproxy '*' --connect-timeout 20 "${STASH}/healthz" >/dev/null || {
    echo "STASH UNREACHABLE at ${STASH} - is yuruna-stash-service running and reachable from this guest?" >&2
    exit 3
}
# `|| true`: grep exits 1 when the list is empty (no artifact yet), which under
# `set -o pipefail` would abort here BEFORE the guard below could explain why.
PERMALINK=$(curl -fsS --noproxy '*' \
    "${STASH}/api/stashes?username=amisad-poc&filename=amisad-binaries&limit=1" \
    | grep -o '"permalink":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)
if [ -z "$PERMALINK" ]; then
    echo "no stash artifact found for label amisad-poc/amisad-binaries - did amisad-vm-build run first?" >&2
    exit 3
fi
DOWNLOAD="${STASH}${PERMALINK/#\/s\//\/download\/}"
mkdir -p target/release
curl -fsS --noproxy '*' "$DOWNLOAD" -o /tmp/amisad-binaries.tgz
tar -xzf /tmp/amisad-binaries.tgz -C target/release
chmod +x target/release/*
echo "binaries retrieved from stash:"
ls -l target/release/

echo "== build thin images + deploy 10 services =="
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true
SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"
# Durable stores: ledger-svc and seller-svc reach the host PostgreSQL via the
# node IP, resolved by the POD at start ($(NODE_IP) is kubernetes env
# expansion from the downward API, NOT shell) - a snapshot restore with a new
# DHCP lease would make a deploy-time IP stale. Role/password: db step.
DATABASE_URL='postgres://amisad:amisadpoc2026@$(NODE_IP):5432/amisad'
NODE_IP=$(hostname -I | awk '{print $1}')
# docker.io is unreachable in this lab: distroless base from gcr.io, thin images
# from the prebuilt binaries, imported straight into the cluster's containerd
# (no registry), charts pinned pullPolicy=Never.
for svc in $SERVICES; do
    ctx="/tmp/ctx-${svc}"
    rm -rf "$ctx" && mkdir -p "$ctx"
    cp "target/release/${svc}" "$ctx/${svc}"
    printf 'FROM gcr.io/distroless/cc-debian12\nCOPY %s /usr/local/bin/%s\nENV PORT=8080\nEXPOSE 8080\nENTRYPOINT ["/usr/local/bin/%s"]\n' \
        "$svc" "$svc" "$svc" > "$ctx/Dockerfile"
    docker build -t "amisad/${svc}:poc" "$ctx"
    docker save "amisad/${svc}:poc" | sudo ctr -n k8s.io images import -
    rm -rf "$ctx"
    EXTRA=()
    case "$svc" in
        ledger-svc|seller-svc) EXTRA=(--set-string "databaseUrl=${DATABASE_URL}") ;;
    esac
    helm upgrade --install "$svc" "workloads/services/${svc}" \
        --namespace amisad --create-namespace \
        --set "image=amisad/${svc}:poc" --set "pullPolicy=Never" "${EXTRA[@]}"
done
for svc in $SERVICES; do
    kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=600s
done

echo "== expose NodePorts for host/edge access =="
declare -A NP=( [fabric-coordinator]=30080 [ledger-svc]=30081 [resource-svc]=30082 [seller-svc]=30083 [identity-mock]=30084 [insights-svc]=30085 )
for svc in "${!NP[@]}"; do
    kubectl -n amisad patch svc "$svc" -p \
        "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":8080,\"targetPort\":8080,\"nodePort\":${NP[$svc]}}]}}"
done

echo "amisad-vm-core DEPLOY PASSED"
