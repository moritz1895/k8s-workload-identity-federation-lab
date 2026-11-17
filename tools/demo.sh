#!/usr/bin/env bash
# Verification harness of the workload-identity-federation lab.
# Runs inside the `demo` container:
#   docker compose run --rm demo                 all base checks
#   docker compose run --rm demo authz           authorization server (keycloak) + service R checks
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
REALM_ISSUER="${KC_REALM_ISSUER:-https://keycloak:8443/realms/domain-rst}"
TOKEN_ENDPOINT="$REALM_ISSUER/protocol/openid-connect/token"
SERVICE_R=http://service-r.wif.local:8080

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

pod_of() { kubectl -n "$NS" get pod -l app="$1" -o jsonpath='{.items[0].metadata.name}'; }

claims_of() { decode_part "$1" 2; }

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

# $1 = iss, $2 = kid, $3 = PEM signing key -> RS256 JWT shaped like a ServiceAccount
# token of wif-demo:consumer, addressed to the realm
forge_client_assertion() {
    local now header payload signature
    now=$(date +%s)
    header=$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "$2" | b64url)
    payload=$(printf '{"iss":"%s","sub":"system:serviceaccount:%s:consumer","aud":["%s"],"iat":%d,"nbf":%d,"exp":%d}' \
        "$1" "$NS" "$REALM_ISSUER" "$now" "$now" "$((now + 600))" | b64url)
    signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$3" -binary | b64url)
    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# Splits "<body>\n<status>" from $1 into /tmp/kc-body and echoes the status.
split_response() {
    sed '$d' "$1" > /tmp/kc-body
    tail -n 1 "$1"
}

# Token request from inside a pod with a projected token file as client assertion.
# $1 = pod, $2 = token file, $3 = scope -> echoes HTTP status, body in /tmp/kc-body
pod_token_request() {
    kubectl -n "$NS" exec "$1" -- sh -c \
        'curl -s --cacert /etc/internal-ca/ca.crt -w "\n%{http_code}" "$0" \
            --data-urlencode grant_type=client_credentials \
            --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
            --data-urlencode "client_assertion@$1" \
            --data-urlencode "scope=$2"' \
        "$TOKEN_ENDPOINT" "$2" "$3" > /tmp/kc-response || true
    split_response /tmp/kc-response
}

# Token request from the demo container with an arbitrary client assertion; the
# assertion travels on stdin, not in curl's arguments.
# $1 = assertion, $2 = scope -> echoes HTTP status, body in /tmp/kc-body
direct_token_request() {
    printf '%s' "$1" | curl -s --cacert "$CA" -w '\n%{http_code}' "$TOKEN_ENDPOINT" \
        --data-urlencode grant_type=client_credentials \
        --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
        --data-urlencode "client_assertion@-" \
        --data-urlencode "scope=$2" > /tmp/kc-response || true
    split_response /tmp/kc-response
}

# Request from inside a pod to the Keycloak name (= keycloak-gateway on workload-net).
# $1 = pod, $2 = method, $3 = path, further args go to curl -> echoes HTTP status
pod_keycloak_status() {
    local pod=$1 method=$2 path=$3
    shift 3
    kubectl -n "$NS" exec "$pod" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        --cacert /etc/internal-ca/ca.crt -X "$method" "$@" "https://keycloak:8443$path" || true
}

# Cached access token via the pod's own client script; its log line goes to stderr.
# $1 = pod, $2 = scope
pod_access_token() { kubectl -n "$NS" exec "$1" -- /opt/authz/access-token.sh "$2"; }

# Call of service R from inside a pod. The Authorization header travels on stdin
# (curl -H @-), so the token is neither in the exec request nor in curl's arguments.
# $1 = pod, $2 = bearer token, $3 = method, $4 = path -> echoes HTTP status, body in /tmp/r-body
call_service_r() {
    printf 'Authorization: Bearer %s\n' "$2" | kubectl -n "$NS" exec -i "$1" -- sh -c \
        'curl -s -D /tmp/r-headers -w "\n%{http_code}" -X "$1" -H @- "$0$2"; \
         grep -i "^www-authenticate" /tmp/r-headers >&2 || true' \
        "$SERVICE_R" "$3" "$4" > /tmp/r-response || true
    sed '$d' /tmp/r-response > /tmp/r-body
    tail -n 1 /tmp/r-response
}

expect_error() {
    local expected=$1 what=$2 actual
    actual=$(jq -r .error /tmp/kc-body 2>/dev/null || true)
    echo "error=$actual  $(jq -r '.error_description // empty' /tmp/kc-body 2>/dev/null || true)"
    [ "$actual" = "$expected" ] && pass "$what ($expected)" || fail "$what: expected error $expected, got '$actual'"
}

authz_checks() {
    CONSUMER=$(pod_of consumer)
    READER=$(pod_of reader)
    STRANGER=$(pod_of stranger)
    for pod in "$CONSUMER" "$READER" "$STRANGER"; do
        kubectl -n "$NS" exec "$pod" -- rm -rf /tmp/access-tokens /tmp/access-token.log
    done

    section "8. realm discovery of the domain authorization server (internal CA)"
    echo "GET $REALM_ISSUER/.well-known/openid-configuration"
    # Keycloak reports ready before its first-start bootstrap is done (503 until then).
    for i in $(seq 1 30); do
        DISCOVERY=$(curl -fsS --cacert "$CA" "$REALM_ISSUER/.well-known/openid-configuration" 2> /dev/null) && break
        printf '  t+%2ds  realm not served yet\n' "$((i * 2))"
        sleep 2
    done
    [ -n "${DISCOVERY:-}" ] || fail "realm discovery not served within 60s"
    jq '{issuer, token_endpoint, jwks_uri}' <<< "$DISCOVERY"
    [ "$(jq -r .issuer <<< "$DISCOVERY")" = "$REALM_ISSUER" ] \
        && pass "realm issuer is $REALM_ISSUER" || fail "unexpected realm issuer"

    section "9. consumer (workload-a) exchanges its ServiceAccount token for an access token"
    kubectl -n "$NS" exec "$CONSUMER" -- rm -rf /tmp/access-tokens /tmp/access-token.log
    echo "client assertion (kc-token) claims:"
    claims_of "$(kubectl -n "$NS" exec "$CONSUMER" -- cat /var/run/secrets/tokens/kc-token)" \
        | jq '{iss, sub, aud, exp}'
    CONSUMER_RW=$(pod_access_token "$CONSUMER" "r:orders:read r:orders:write")
    echo "access token claims:"
    claims_of "$CONSUMER_RW" | jq '{iss, aud, azp, scope, exp}'
    claims_of "$CONSUMER_RW" | jq -e --arg iss "$REALM_ISSUER" '
        .iss == $iss
        and (.aud | if type == "array" then . else [.] end) == ["service-r"]
        and .azp == "workload-a"
        and .typ == "Bearer"
        and (.scope | split(" ") | sort) == ["r:orders:read", "r:orders:write"]' > /dev/null \
        && pass "access token for workload-a, addressed to service-r alone, with the requested scopes" \
        || fail "access token claims of workload-a are not as expected"

    section "10. reader (workload-b) asks for a scope the realm does not assign to it"
    echo "scope=r:orders:read r:orders:write"
    expect_status 400 "$(pod_token_request "$READER" /var/run/secrets/tokens/kc-token "r:orders:read r:orders:write")" \
        "unassigned scope refused"
    expect_error invalid_scope "unassigned scope refused"
    echo "scope=r:orders:read"
    READER_R=$(pod_access_token "$READER" "r:orders:read")
    claims_of "$READER_R" | jq '{azp, scope}'
    [ "$(claims_of "$READER_R" | jq -r .scope)" = "r:orders:read" ] \
        && pass "workload-b gets exactly r:orders:read" || fail "workload-b got unexpected scopes"

    section "11. stranger: valid cluster identity, but no client in the realm"
    expect_status 401 "$(pod_token_request "$STRANGER" /var/run/secrets/tokens/kc-token "r:orders:read")" \
        "unregistered workload refused"
    expect_error invalid_client "unregistered workload refused"

    section "12. ServiceAccount token for another audience used as client assertion"
    echo "consumer presents sa-token (aud=$AUD) to the realm"
    expect_status 400 "$(pod_token_request "$CONSUMER" /var/run/secrets/tokens/sa-token "r:orders:read")" \
        "token for the validator refused by the realm"
    expect_error invalid_client "token for the validator refused by the realm"

    section "13. forged client assertions"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/foreign.key 2>/dev/null
    CLUSTER_KID=$(kid_of "$(kubectl -n "$NS" create token consumer --audience "$REALM_ISSUER" --duration 10m)")
    echo "iss=https://other-cluster, signed with a foreign key"
    expect_status 401 "$(direct_token_request "$(forge_client_assertion https://other-cluster foreign-kid /tmp/foreign.key)" r:orders:read)" \
        "assertion of an untrusted issuer refused"
    expect_error invalid_client "assertion of an untrusted issuer refused"
    echo "iss=$ISSUER, kid=$CLUSTER_KID, but signed with a foreign key"
    expect_status 401 "$(direct_token_request "$(forge_client_assertion "$ISSUER" "$CLUSTER_KID" /tmp/foreign.key)" r:orders:read)" \
        "assertion with a forged signature refused"
    expect_error invalid_client "assertion with a forged signature refused"

    section "14. consumer -> service R with its access token"
    expect_status 200 "$(call_service_r "$CONSUMER" "$CONSUMER_RW" GET /orders)" "GET /orders with r:orders:read"
    jq . /tmp/r-body
    [ "$(jq -r .clientId /tmp/r-body)" = "workload-a" ] && pass "R names the caller workload-a" \
        || fail "R did not name workload-a"
    expect_status 200 "$(call_service_r "$CONSUMER" "$CONSUMER_RW" POST /orders)" "POST /orders with r:orders:write"

    section "15. missing scope  ->  403"
    echo "reader: POST /orders with only r:orders:read"
    expect_status 403 "$(call_service_r "$READER" "$READER_R" POST /orders)" "write without r:orders:write refused"
    echo "consumer: DELETE /orders/1 without r:orders:admin"
    expect_status 403 "$(call_service_r "$CONSUMER" "$CONSUMER_RW" DELETE /orders/1)" "delete without r:orders:admin refused"

    section "16. access token for another service (aud=service-s)  ->  401"
    CONSUMER_S=$(pod_access_token "$CONSUMER" "s:inventory:read")
    claims_of "$CONSUMER_S" | jq '{aud, scope}'
    expect_status 401 "$(call_service_r "$CONSUMER" "$CONSUMER_S" GET /orders)" "token for service S refused by R"

    section "16b. access token addressed to R and S at once  ->  401  (S could replay it at R)"
    CONSUMER_RS=$(pod_access_token "$CONSUMER" "r:orders:read s:inventory:read")
    claims_of "$CONSUMER_RS" | jq '{aud, scope}'
    expect_status 401 "$(call_service_r "$CONSUMER" "$CONSUMER_RS" GET /orders)" \
        "token for several audiences refused by R"

    section "17. tampered access token  ->  401"
    expect_status 401 "$(call_service_r "$CONSUMER" "$(tamper_signature "$CONSUMER_RW")" GET /orders)" \
        "tampered access token refused"

    section "18. cluster ServiceAccount token presented directly to R  ->  401"
    KC_TOKEN=$(kubectl -n "$NS" exec "$CONSUMER" -- cat /var/run/secrets/tokens/kc-token)
    expect_status 401 "$(call_service_r "$CONSUMER" "$KC_TOKEN" GET /orders)" "ServiceAccount token refused by R"

    section "19. access token cache in the workload"
    kubectl -n "$NS" exec "$CONSUMER" -- rm -rf /tmp/access-tokens /tmp/access-token.log
    for i in 1 2 3; do
        echo "call $i:"
        pod_access_token "$CONSUMER" "r:orders:read" > /dev/null
    done
    REQUESTS=$(kubectl -n "$NS" exec "$CONSUMER" -- sh -c 'grep -c "requested new access token" /tmp/access-token.log')
    echo "token requests: $REQUESTS"
    [ "$REQUESTS" = "1" ] && pass "three calls, one token request" || fail "expected 1 token request, got $REQUESTS"

    section "20. admin surface is not reachable from workloads (keycloak-gateway)"
    echo "stranger: GET /admin/realms"
    expect_status 404 "$(pod_keycloak_status "$STRANGER" GET /admin/realms)" "admin REST API not exposed"
    echo "stranger: GET /admin/master/console/"
    expect_status 404 "$(pod_keycloak_status "$STRANGER" GET /admin/master/console/)" "admin console not exposed"
    echo "stranger: password grant against the master realm (admin-cli)"
    expect_status 404 "$(pod_keycloak_status "$STRANGER" POST /realms/master/protocol/openid-connect/token \
        --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
        --data-urlencode username=admin --data-urlencode password=wrong)" "master realm not exposed"
    echo "stranger: path traversal /realms/domain-rst/../master/..."
    TRAVERSAL=$(kubectl -n "$NS" exec "$STRANGER" -- curl -s --max-time 5 --path-as-is \
        --cacert /etc/internal-ca/ca.crt \
        "https://keycloak:8443/realms/domain-rst/../master/.well-known/openid-configuration" || true)
    grep -q '/realms/master' <<< "$TRAVERSAL" \
        && fail "path traversal reached the master realm" || pass "path traversal stays inside the domain realm"
    echo "stranger: Keycloak itself at 172.31.8.30:8443 and its management port 9000"
    for target in https://172.31.8.30:8443/ http://172.31.8.30:9000/health; do
        if kubectl -n "$NS" exec "$STRANGER" -- curl -sk -o /dev/null --max-time 4 "$target"; then
            fail "workload reaches $target"
        fi
        pass "workload cannot reach $target"
    done
    echo "stranger: realm discovery through the gateway still works"
    expect_status 200 "$(pod_keycloak_status "$STRANGER" GET /realms/domain-rst/.well-known/openid-configuration)" \
        "domain realm served through the gateway"

    if [ "${DEMO_EXPIRY:-0}" = "1" ]; then
        section "21. expired access token  (waits ~6 min — lifetime 300 s + 60 s clock skew)"
        expect_status 200 "$(pod_token_request "$CONSUMER" /var/run/secrets/tokens/kc-token "r:orders:read")" \
            "fresh access token issued"
        SHORT=$(jq -r .access_token /tmp/kc-body)
        for i in $(seq 1 40); do
            STATUS=$(call_service_r "$CONSUMER" "$SHORT" GET /orders 2> /dev/null)
            printf '  t+%3ds  HTTP %s\n' "$((i * 15))" "$STATUS"
            [ "$STATUS" = "401" ] && break
            sleep 15
        done
        [ "$STATUS" = "401" ] && pass "expired access token refused (401)" \
            || fail "access token never expired within the polling window"
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

    section "rotation: the realm accepts a client assertion signed with the rotated key"
    ROTATED=$(kubectl -n "$NS" create token consumer --audience "$REALM_ISSUER" --duration 10m)
    echo "client assertion kid: $(kid_of "$ROTATED")"
    expect_status 200 "$(direct_token_request "$ROTATED" r:orders:read)" \
        "access token issued for an assertion signed with the rotated key"
}

case "$PHASE" in
    all)           base_checks ;;
    authz)         authz_checks ;;
    pre-rotation)  pre_rotation ;;
    post-rotation) post_rotation ;;
    *)             fail "unknown phase '$PHASE' (all|authz|pre-rotation|post-rotation)" ;;
esac

section "result"
pass "phase '$PHASE': all checks passed"
