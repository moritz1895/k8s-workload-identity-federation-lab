#!/usr/bin/env bash
# One-shot: applies the lab manifests into the freshly started cluster.
# k3s owns server/manifests/ for its own bundled charts, so we apply ours
# explicitly instead of bind-mounting into that directory.
set -euo pipefail

KCFG=/tmp/kubeconfig
sed -e 's#https://127.0.0.1:6443#https://k3s-server:6443#' \
    -e 's#https://0.0.0.0:6443#https://k3s-server:6443#' \
    /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"

echo "bootstrap: applying lab manifests"
kubectl apply -f /manifests

echo "bootstrap: waiting for the consumer deployment to become available"
kubectl -n wif-demo rollout status deployment/consumer --timeout=120s

echo "bootstrap: done"
