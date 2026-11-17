#!/usr/bin/env bash
# Verification harness of the workload-identity-federation lab.
# Runs inside the `demo` container:
#   docker compose run --rm demo                 all base checks
#   docker compose run --rm demo pre-rotation    mint + store a token before a key rotation
#   docker compose run --rm demo post-rotation   check new and pre-rotation tokens after it
# tools/run-all-checks.sh drives the full sequence including the key rotation.
set -euo pipefail

PHASE="${1:-all}"
VALIDATOR_URL="${VALIDATOR_URL:-http://validator:8080}"
AUD="${WIF_AUDIENCE:-wif-demo-validator}"
NS="wif-demo"
ISSUER=https://issuer-web
UPLOAD_ADDR=172.31.7.20
CA=/trust/ca.crt
STATE=/state

KCFG=/tmp/kubeconfig
sed -E 's#server: https://[^/]+:6443#server: https://k3s-server:6443#' /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"

section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
pass()    { printf '\033[1;32mPASS: %s\033[0m\n' "$1"; }
fail()    { printf '\033[1;31mFAIL: %s\033[0m\n' "$1"; exit 1; }

expect_status() {
    local expected=$1 actual=$2 what=$3
    echo "HTTP $actual"
    [ "$actual" = "$expected" ] && pass "$what ($expected)" || fail "$what: expected $expected, got $actual"
}

decode_part() {
    local part padding
    part=$(printf '%s' "$1" | cut -d. -f"$2")
    padding=$(( (4 - ${#part} % 4) % 4 ))
    part="${part}$(printf '%*s' "$padding" '' | tr ' ' '=')"
    printf '%s' "$part" | tr '_-' '/+' | base64 -d 2>/dev/null
}

# Changes the first signature character: it carries six full bits, unlike the
# last one, whose low bits are base64url padding that decoders ignore.
tamper_signature() {
    local head=${1%.*} sig=${1##*.} replacement=A
    [ "${sig:0:1}" = "A" ] && replacement=B
    printf "%s.%s%s" "$head" "$replacement" "${sig:1}"
}

kid_of() { decode_part "$1" 1 | jq -r .kid; }

published_kids() { curl -fsS --cacert "$CA" "$ISSUER/openid/v1/jwks" | jq -r '.keys[].kid' | sort; }

# $1 = bearer token -> echoes HTTP status, leaves body in /tmp/body
whoami_status() {
    curl -s -o /tmp/body -w '%{http_code}' \
        -H "Authorization: Bearer $1" "$VALIDATOR_URL/whoami"
}

# PUT to the upload listener; extra curl args select the client identity.
upload_status() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve "issuer-web:8443:$UPLOAD_ADDR" --cacert "$CA" \
        -T /tmp/fake-jwks.json "$@" https://issuer-web:8443/openid/v1/jwks || true
}

base_checks() {
    section "0. OIDC discovery served by the stand-alone issuer endpoint (internal CA)"
    echo "GET $ISSUER/.well-known/openid-configuration"
    curl -fsS --cacert "$CA" "$ISSUER/.well-known/openid-configuration" \
        | jq '{issuer, jwks_uri, id_token_signing_alg_values_supported}'

    section "1. JWKS published by the in-cluster jwks-publisher"
    curl -fsS --cacert "$CA" "$ISSUER/openid/v1/jwks" | jq '.keys[] | {kid, kty, alg, use}'

    section "2. mint an audience-bound token and decode its claims"
    GOOD=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
    decode_part "$GOOD" 2 | jq .

    section "3. consumer POD  ->  external validator   (happy path)"
    POD=$(kubectl -n "$NS" get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
    echo "pod $POD  ->  http://validator.wif.local:8080/whoami   (token from projected volume)"
    POD_STATUS=$(kubectl -n "$NS" exec "$POD" -- sh -c \
        'curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $(cat /var/run/secrets/tokens/sa-token)" http://validator.wif.local:8080/whoami' || true)
    expect_status 200 "$POD_STATUS" "pod token accepted"
    kubectl -n "$NS" exec "$POD" -- sh -c \
        'curl -s -H "Authorization: Bearer $(cat /var/run/secrets/tokens/sa-token)" http://validator.wif.local:8080/whoami' | jq .

    section "4. negative: wrong audience  ->  rejected"
    WRONG_AUD=$(kubectl -n "$NS" create token consumer --audience "not-this-service" --duration 10m)
    expect_status 401 "$(whoami_status "$WRONG_AUD")" "wrong audience rejected"

    section "5. negative: tampered signature  ->  rejected"
    expect_status 401 "$(whoami_status "$(tamper_signature "$GOOD")")" "tampered token rejected"

    section "6. negative: JWKS upload without a valid publisher certificate  ->  rejected"
    echo '{"keys":[]}' > /tmp/fake-jwks.json
    echo "PUT https://issuer-web:8443/openid/v1/jwks  without client certificate"
    expect_status 400 "$(upload_status)" "upload without client certificate rejected"
    echo "PUT ... with a client certificate from a foreign CA"
    expect_status 400 "$(upload_status --cert /pki-demo/foreign-publisher.crt --key /pki-demo/foreign-publisher.key)" \
        "upload with foreign-CA certificate rejected"
    echo "PUT ... with an internal-CA certificate for CN=not-the-publisher"
    expect_status 403 "$(upload_status --cert /pki-demo/wrong-cn.crt --key /pki-demo/wrong-cn.key)" \
        "upload with wrong CN rejected"
    echo "PUT ... with an internal-CA certificate hiding CN=jwks-publisher in the O field"
    expect_status 403 "$(upload_status --cert /pki-demo/smuggled-cn.crt --key /pki-demo/smuggled-cn.key)" \
        "upload with smuggled CN rejected"
    echo "PUT $ISSUER/openid/v1/jwks  (public read listener)"
    expect_status 403 "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" -T /tmp/fake-jwks.json "$ISSUER/openid/v1/jwks")" \
        "write on the public listener rejected"
    [ "$(curl -fsS --cacert "$CA" "$ISSUER/openid/v1/jwks" | jq '.keys | length')" -gt 0 ] \
        && pass "published JWKS untouched" || fail "published JWKS was overwritten"

    if [ "${DEMO_EXPIRY:-0}" = "1" ]; then
        section "7. negative: genuine expiry  (waits ~10 min — TokenRequest minimum TTL)"
        SHORT=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
        for i in $(seq 1 90); do
            STATUS=$(whoami_status "$SHORT")
            printf '  t+%3ds  HTTP %s\n' "$((i * 15))" "$STATUS"
            [ "$STATUS" = "401" ] && break
            sleep 15
        done
        [ "$STATUS" = "401" ] && pass "expired token rejected (401)" || fail "token never expired within the polling window"
    fi
}

pre_rotation() {
    section "rotation 1/2: token and published keys before the rotation"
    kubectl -n "$NS" create token consumer --audience "$AUD" --duration 1h > "$STATE/pre-rotation-token"
    published_kids > "$STATE/pre-rotation-kids"
    echo "published kids:"; sed 's/^/  /' "$STATE/pre-rotation-kids"
    echo "token kid: $(kid_of "$(cat "$STATE/pre-rotation-token")")"
    expect_status 200 "$(whoami_status "$(cat "$STATE/pre-rotation-token")")" "pre-rotation token accepted"
}

post_rotation() {
    section "rotation 2/2: waiting for the publisher to push the rotated JWKS"
    [ -s "$STATE/pre-rotation-token" ] || fail "run the pre-rotation phase first"
    local new_kids=""
    for i in $(seq 1 24); do
        new_kids=$(published_kids | comm -13 "$STATE/pre-rotation-kids" - || true)
        [ -n "$new_kids" ] && break
        printf '  t+%3ds  no new kid published yet\n' "$((i * 5))"
        sleep 5
    done
    [ -n "$new_kids" ] || fail "no new kid was published within 120s"
    echo "published kids now:"; published_kids | sed 's/^/  /'
    pass "new kid published: $new_kids"

    NEW=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
    NEW_KID=$(kid_of "$NEW")
    echo "new token kid: $NEW_KID"
    grep -qx "$NEW_KID" <<< "$new_kids" || fail "new token is not signed with the rotated key"
    expect_status 200 "$(whoami_status "$NEW")" "token signed with the rotated key accepted"

    expect_status 200 "$(whoami_status "$(cat "$STATE/pre-rotation-token")")" \
        "pre-rotation token still accepted (previous key kept in the JWKS)"
}

case "$PHASE" in
    all)           base_checks ;;
    pre-rotation)  pre_rotation ;;
    post-rotation) post_rotation ;;
    *)             fail "unknown phase '$PHASE' (all|pre-rotation|post-rotation)" ;;
esac

section "result"
pass "phase '$PHASE': all checks passed"
