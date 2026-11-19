#!/usr/bin/env bash
# One-shot cluster setup with the admin kubeconfig:
#   1. create the namespaces
#   2. hand the issuer ingress its serving certificate (Secret) and the demo
#      workloads the internal CA (ConfigMap) — in a real cluster cert-manager or the
#      platform's PKI integration delivers these
#   3. apply the lab manifests (Traefik configuration, admission policies, issuer
#      pod, workloads) and wait for them
set -euo pipefail

KCFG=/tmp/kubeconfig
sed -E 's#server: https://[^/]+:6443#server: https://k3s-server:6443#' /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"

echo "bootstrap: creating namespaces"
kubectl apply -f /manifests/00-namespace.yaml

echo "bootstrap: provisioning the issuer ingress certificate and the internal CA"
kubectl -n wif-issuer create secret tls issuer-tls \
    --cert=/issuer-tls/tls.crt --key=/issuer-tls/tls.key \
    --dry-run=client -o yaml | kubectl apply --server-side -f -
kubectl -n wif-demo create configmap internal-ca \
    --from-file=ca.crt=/trust/ca.crt \
    --dry-run=client -o yaml | kubectl apply --server-side -f -

echo "bootstrap: applying lab manifests"
kubectl apply -f /manifests
kubectl -n wif-issuer rollout status deployment/issuer --timeout=180s
echo "bootstrap: waiting for the ingress controller"
until kubectl -n kube-system get deployment traefik > /dev/null 2>&1; do sleep 3; done
kubectl -n kube-system rollout status deployment/traefik --timeout=300s
kubectl -n wif-demo rollout status deployment/consumer --timeout=180s
kubectl -n wif-demo rollout status deployment/reader --timeout=180s
kubectl -n wif-demo rollout status deployment/stranger --timeout=180s

echo "bootstrap: done — the issuer pod serves discovery document + JWKS at https://issuer.wif.local"
