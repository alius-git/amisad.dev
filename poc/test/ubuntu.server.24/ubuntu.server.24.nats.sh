#!/bin/bash
# AmisAd POC - deploy a single-node NATS JetStream into the cluster.
set -euo pipefail

kubectl create namespace amisad-infra --dry-run=client -o yaml | kubectl apply -f -
kubectl -n amisad-infra apply -f - <<'MANIFEST'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nats
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nats
  template:
    metadata:
      labels:
        app: nats
    spec:
      containers:
        - name: nats
          image: nats:2.10-alpine
          args: ["-js"]
          ports:
            - containerPort: 4222
---
apiVersion: v1
kind: Service
metadata:
  name: nats
spec:
  selector:
    app: nats
  ports:
    - port: 4222
      targetPort: 4222
MANIFEST
# 600s: first-pull latency through the LAN cache exceeded 300s once
# (cycle 246). On failure, dump pod state so the diagnostic says WHY.
if ! kubectl -n amisad-infra rollout status deployment/nats --timeout=600s; then
    echo "== nats rollout failed - diagnostics =="
    kubectl -n amisad-infra get pods -o wide || true
    kubectl -n amisad-infra describe deployment/nats | tail -20 || true
    kubectl -n amisad-infra get events --sort-by=.lastTimestamp | tail -15 || true
    exit 1
fi
echo "NATS JetStream deployed"