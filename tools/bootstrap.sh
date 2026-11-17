#!/usr/bin/env bash
# One-shot cluster setup with the admin kubeconfig:
#   1. create the namespaces
#   2. hand the in-cluster JWKS publisher its mTLS client certificate (Secret)
#      and the internal CA (ConfigMap) — in a real cluster cert-manager or the
#      platform's PKI integration delivers these
#   3. apply the lab manifests and wait for the workloads
# Publishing the discovery document and JWKS is the publisher's job, not this one's.
set -euo pipefail

KCFG=/tmp/kubeconfig
sed -E 's#server: https://[^/]+:6443#server: https://k3s-server:6443#' /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"

echo "bootstrap: creating namespaces"
kubectl apply -f /manifests/00-namespace.yaml

echo "bootstrap: provisioning publisher client certificate and internal CA"
kubectl -n wif-publisher create secret tls jwks-publisher-mtls \
    --cert=/publisher-tls/tls.crt --key=/publisher-tls/tls.key \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl -n wif-publisher create configmap internal-ca \
    --from-file=ca.crt=/trust/ca.crt \
    --dry-run=client -o yaml | kubectl apply -f -

echo "bootstrap: applying lab manifests"
kubectl apply -f /manifests
kubectl -n wif-publisher rollout status deployment/jwks-publisher --timeout=180s
kubectl -n wif-demo rollout status deployment/consumer --timeout=180s

echo "bootstrap: done — jwks-publisher pushes discovery document + JWKS to issuer-web"
