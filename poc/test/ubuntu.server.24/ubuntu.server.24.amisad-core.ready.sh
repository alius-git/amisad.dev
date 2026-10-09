#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - put the restored amisad-core in position for a scenario run: the
# apiserver answering, the CNI able to place a sandbox, CoreDNS and every amisad
# deployment restarted onto pods that exist now, and every NodePort answering.
# Runs as a component step, so a cluster that has not converged is replayed from
# the restore instead of failing the scenario that was about to use it.
# --- REGION: Initialize environment
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# kubectl does not retry a refused TCP dial, and the snapshot's static-pod
# apiserver only starts answering seconds after shell login, so poll a raw
# endpoint before asking the cluster for anything. Bound the dial itself as
# well as retries; a black-holed API must not outlive the restore's budget.
amisad_wait_apiserver() {
    local budget="${1:-300}" remaining max_time last_rc=0 response='' last_error=''
    local deadline=$((SECONDS + budget))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining=$((deadline - SECONDS))
        max_time=2
        if [ "$remaining" -lt "$max_time" ]; then max_time="$remaining"; fi
        if response=$(kubectl --request-timeout="${max_time}s" get --raw='/readyz' 2>&1); then
            return 0
        else
            last_rc=$?
            last_error="${response:0:4096}"
        fi
        if [ "$SECONDS" -lt "$deadline" ]; then sleep 1; fi
    done
    echo "apiserver readiness budget (${budget}s) expired; last kubectl exit: ${last_rc}" >&2
    if [ -n "$last_error" ]; then printf '%s\n' "$last_error" >&2; fi
    return 1
}

# /run is a tmpfs, so this file exists only once flannel has written it during
# THIS boot -- the point from which the CNI can place a sandbox. A pod created
# before it fails with a missing subnet.env and comes back at a new address.
amisad_wait_flannel() {
    local budget="${1:-300}" deadline
    deadline=$((SECONDS + budget))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -s /run/flannel/subnet.env ]; then return 0; fi
        sleep 1
    done
    return 1
}

echo "== restart the deployed services onto a known-live state (post-restore boot) =="
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true
amisad_wait_apiserver 300 || {
    echo "the apiserver never answered /readyz after the restore" >&2
    exit 9
}
amisad_wait_flannel 300 || {
    echo "flannel never wrote /run/flannel/subnet.env; the pod network cannot place new sandboxes" >&2
    exit 9
}
SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"
# See https://yuruna.link/42010605-0007
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n amisad rollout restart deployment
kubectl -n kube-system rollout status deployment/coredns --timeout=600s
for svc in $SERVICES; do
    kubectl -n amisad rollout status "deployment/${svc}" --timeout=600s
done

# --- REGION: Resolve service endpoints
NODE_IP=$(hostname -I | awk '{print $1}')

# Each request and retry fits in the remaining readiness budget. A stale
# NodePort can otherwise spend over a minute in curl's default TCP timeout,
# even after its replacement pod is ready. These node-local checks must not
# follow a host or guest HTTP proxy.
amisad_wait_nodeport() {
    local node_ip="$1" port="$2" budget="${3:-300}" remaining max_time last_rc=0
    local deadline=$((SECONDS + budget))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining=$((deadline - SECONDS))
        max_time=2
        if [ "$remaining" -lt "$max_time" ]; then max_time="$remaining"; fi
        if curl --noproxy '*' --connect-timeout 1 --max-time "$max_time" \
            -sf "http://${node_ip}:${port}/health" >/dev/null 2>&1; then
            return 0
        else
            last_rc=$?
        fi
        if [ "$SECONDS" -lt "$deadline" ]; then sleep 1; fi
    done
    echo "NodePort ${port} health budget (${budget}s) expired; last curl exit: ${last_rc}" >&2
    return 1
}

echo "== wait for the NodePort services to actually answer (post-restore) =="
for port in 30080 30081 30082 30083 30084 30085 30086 30087 30088 30089; do
    amisad_wait_nodeport "$NODE_IP" "$port" || {
        echo "NodePort ${port} never answered - stale amisad-core snapshot? The deploy chain must be re-run (run-tests.ps1 rebuilds it)." >&2
        exit 8
    }
done

echo "amisad-core is in position: deployments restarted, every NodePort answering."
