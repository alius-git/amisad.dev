#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - put the restored amisad-core in position for a scenario run: the
# apiserver answering, the CNI able to place a sandbox, CoreDNS and every amisad
# deployment restarted onto pods that exist now, and every NodePort answering.
# Runs as a component step, so a cluster that has not converged is replayed from
# the restore instead of failing the scenario that was about to use it.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "== restart the deployed services onto a known-live state (post-restore boot) =="
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true
# kubectl does not retry a refused TCP dial, and the snapshot's static-pod
# apiserver only starts answering seconds after shell login, so poll a raw
# endpoint before asking the cluster for anything.
for _ in $(seq 1 60); do
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then break; fi
    sleep 5
done
kubectl get --raw='/readyz' >/dev/null || {
    echo "the apiserver never answered /readyz after the restore" >&2
    exit 9
}
# /run is a tmpfs, so this file exists only once flannel has written it during
# THIS boot -- the point from which the CNI can place a sandbox. A pod created
# before it fails with a missing subnet.env and comes back at a new address.
for _ in $(seq 1 60); do
    if [ -s /run/flannel/subnet.env ]; then break; fi
    sleep 5
done
[ -s /run/flannel/subnet.env ] || {
    echo "flannel never wrote /run/flannel/subnet.env; the pod network cannot place new sandboxes" >&2
    exit 9
}
SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"
# The snapshot carries deployment and pod status frozen at snapshot time, so
# every readiness signal in it describes containers the reboot has already
# replaced. Waiting on that status can pass while the pod network is still
# moving, and a NodePort rule still pointing at a departed pod answers the next
# dial with "No route to host". Restarting first is what makes the wait mean
# something: rollout status then reports against a generation created after
# this restore, so it completes only once pods that exist NOW are ready and the
# endpoints behind those rules are theirs. Peers are addressed by cluster DNS
# name, so CoreDNS has to answer from live pods as well; both restarts are
# issued before either is awaited so the two roll in parallel.
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n amisad rollout restart deployment
kubectl -n kube-system rollout status deployment/coredns --timeout=600s
for svc in $SERVICES; do
    kubectl -n amisad rollout status "deployment/${svc}" --timeout=600s
done

NODE_IP=$(hostname -I | awk '{print $1}')

echo "== wait for the NodePort services to actually answer (post-restore) =="
for port in 30080 30081 30082 30083 30084 30085 30086 30087 30088 30089; do
    for _ in $(seq 1 60); do
        if curl -sf "http://${NODE_IP}:${port}/health" >/dev/null 2>&1; then break; fi
        sleep 5
    done
    curl -sf "http://${NODE_IP}:${port}/health" >/dev/null || {
        echo "NodePort ${port} never answered - stale amisad-core snapshot? The deploy chain must be re-run (run-tests.ps1 rebuilds it)." >&2
        exit 8
    }
done

echo "amisad-core is in position: deployments restarted, every NodePort answering."
