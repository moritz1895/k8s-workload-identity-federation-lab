#!/usr/bin/env bash
# One-shot cluster bootstrap:
#   1. apply the lab manifests
#   2. publish the cluster's OIDC discovery document + JWKS to the stand-alone
#      issuer endpoint (issuer-web), so the external validator never talks to the
#      API server directly — it only ever reads public metadata from a URL.
set -euo pipefail

KCFG=/tmp/kubeconfig
sed -e 's#https://127.0.0.1:6443#https://k3s-server:6443#' \
    -e 's#https://0.0.0.0:6443#https://k3s-server:6443#' \
    /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"

echo "bootstrap: applying lab manifests"
kubectl apply -f /manifests
kubectl -n wif-demo rollout status deployment/consumer --timeout=120s

echo "bootstrap: minting a self-signed serving certificate for issuer-web"
if [ ! -s /oidc/tls.crt ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /oidc/tls.key -out /oidc/tls.crt \
        -subj "/CN=issuer-web" -addext "subjectAltName=DNS:issuer-web"
fi

echo "bootstrap: publishing discovery document + JWKS"
# The API server is configured with service-account-issuer=https://issuer-web, so
# these documents already carry the right issuer and jwks_uri — copy them as-is.
kubectl get --raw /.well-known/openid-configuration > /oidc/openid-configuration.json
kubectl get --raw /openid/v1/jwks                   > /oidc/jwks.json

echo "bootstrap: done — discovery document now served at https://issuer-web/.well-known/openid-configuration"
cat /oidc/openid-configuration.json
