#!/usr/bin/env bash
# End-to-end verification of the workload-identity-federation lab.
# Runs inside the `demo` container: docker compose run --rm demo
set -euo pipefail

VALIDATOR_URL="${VALIDATOR_URL:-http://validator:8080}"
AUD="${WIF_AUDIENCE:-wif-demo-validator}"
NS="wif-demo"

# k3s writes the kubeconfig with a loopback server address; rewrite it to the
# compose network name so kubectl works from this container.
KCFG=/tmp/kubeconfig
sed -e 's#https://127.0.0.1:6443#https://k3s-server:6443#' \
    -e 's#https://0.0.0.0:6443#https://k3s-server:6443#' \
    /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"

section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
pass()    { printf '\033[1;32mPASS: %s\033[0m\n' "$1"; }
fail()    { printf '\033[1;31mFAIL: %s\033[0m\n' "$1"; exit 1; }

decode_payload() {
    local part padding
    part=$(printf '%s' "$1" | cut -d. -f2)
    padding=$(( (4 - ${#part} % 4) % 4 ))
    part="${part}$(printf '%*s' "$padding" '' | tr ' ' '=')"
    printf '%s' "$part" | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
}

# $1 = bearer token -> echoes HTTP status, leaves body in /tmp/body
whoami_status() {
    curl -s -o /tmp/body -w '%{http_code}' \
        -H "Authorization: Bearer $1" "$VALIDATOR_URL/whoami"
}

section "0. issuer / OIDC discovery advertised by the cluster"
kubectl get --raw /.well-known/openid-configuration \
    | jq '{issuer, jwks_uri, id_token_signing_alg_values_supported}'

section "1. cluster JWKS  (exactly what the validator fetches over the network)"
kubectl get --raw /openid/v1/jwks | jq '.keys[] | {kid, kty, alg, use}'

section "2. mint an audience-bound token and decode its claims"
GOOD=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
decode_payload "$GOOD"

section "3. consumer POD  ->  external validator   (happy path)"
POD=$(kubectl -n "$NS" get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
echo "pod $POD  ->  http://validator.wif.local:8080/whoami   (token from projected volume)"
POD_STATUS=$(kubectl -n "$NS" exec "$POD" -- sh -c \
    'curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $(cat /var/run/secrets/tokens/sa-token)" http://validator.wif.local:8080/whoami' || true)
echo "HTTP $POD_STATUS"
[ "$POD_STATUS" = "200" ] && pass "pod token accepted (200)" || fail "expected 200 from the pod"
kubectl -n "$NS" exec "$POD" -- sh -c \
    'curl -s -H "Authorization: Bearer $(cat /var/run/secrets/tokens/sa-token)" http://validator.wif.local:8080/whoami' | jq .

section "4. negative: wrong audience  ->  rejected"
WRONG_AUD=$(kubectl -n "$NS" create token consumer --audience "not-this-service" --duration 10m)
STATUS=$(whoami_status "$WRONG_AUD"); echo "HTTP $STATUS"; jq . < /tmp/body
[ "$STATUS" = "401" ] && pass "wrong audience rejected (401)" || fail "expected 401 for wrong audience"

section "5. negative: tampered signature  ->  rejected"
TAMPERED="${GOOD%?}X"
STATUS=$(whoami_status "$TAMPERED"); echo "HTTP $STATUS"; jq . < /tmp/body
[ "$STATUS" = "401" ] && pass "tampered token rejected (401)" || fail "expected 401 for tampered token"

if [ "${DEMO_EXPIRY:-0}" = "1" ]; then
    section "6. negative: genuine expiry  (waits ~10 min — TokenRequest minimum TTL)"
    SHORT=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
    for i in $(seq 1 90); do
        STATUS=$(whoami_status "$SHORT")
        printf '  t+%3ds  HTTP %s\n' "$((i * 15))" "$STATUS"
        if [ "$STATUS" = "401" ]; then
            pass "expired token rejected (401)"
            break
        fi
        sleep 15
    done
    [ "$STATUS" = "401" ] || fail "token never expired within the polling window"
fi

section "result"
pass "all checks passed"
