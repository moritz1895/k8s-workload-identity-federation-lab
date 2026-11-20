#!/usr/bin/env bash
# One-shot cluster setup with the admin kubeconfig:
#   1. create the namespaces
#   2. hand the issuer Gateway its serving certificate (Secret) and the demo
#      workloads the internal CA (ConfigMap) — in a real cluster cert-manager or the
#      platform's PKI integration delivers these
#   3. wait for the Gateway API CRDs, apply the lab manifests (Traefik configuration,
#      admission policies, discovery pods, Gateway, workloads) and wait for them
set -euo pipefail

KCFG=/tmp/kubeconfig
sed -E 's#server: https://[^/]+:6443#server: https://k3s-server:6443#' /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"

echo "bootstrap: creating namespaces"
kubectl apply -f /manifests/00-namespace.yaml

echo "bootstrap: provisioning the issuer Gateway certificate and the internal CA"
kubectl -n wif-issuer-discovery create secret tls issuer-tls \
    --cert=/issuer-tls/tls.crt --key=/issuer-tls/tls.key \
    --dry-run=client -o yaml | kubectl apply --server-side -f -
kubectl -n wif-demo create configmap internal-ca \
    --from-file=ca.crt=/trust/ca.crt \
    --dry-run=client -o yaml | kubectl apply --server-side -f -

echo "bootstrap: waiting for the Gateway API CRDs (installed by k3s's traefik-crd chart)"
for crd in gateways httproutes; do
    until kubectl get crd "$crd.gateway.networking.k8s.io" > /dev/null 2>&1; do sleep 3; done
    kubectl wait --for=condition=Established "crd/$crd.gateway.networking.k8s.io" --timeout=120s
done

echo "bootstrap: applying lab manifests"
kubectl apply -f /manifests
kubectl -n wif-issuer-discovery rollout status deployment/issuer-discovery --timeout=180s
echo "bootstrap: waiting for the gateway controller"
until kubectl -n kube-system get deployment traefik > /dev/null 2>&1; do sleep 3; done
kubectl -n kube-system rollout status deployment/traefik --timeout=300s
kubectl -n wif-issuer-discovery wait gateway/issuer-discovery --for=condition=Programmed --timeout=120s
kubectl -n wif-demo rollout status deployment/consumer --timeout=180s
kubectl -n wif-demo rollout status deployment/reader --timeout=180s
kubectl -n wif-demo rollout status deployment/stranger --timeout=180s

echo "bootstrap: done — the discovery pods serve discovery document + JWKS at https://issuer.wif.local"
