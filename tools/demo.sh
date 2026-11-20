#!/usr/bin/env bash
# Verification harness of the workload-identity-federation lab.
# Runs inside the `demo` container:
#   docker compose run --rm demo                 all base checks
#   docker compose run --rm demo authz           authorization server (keycloak) + service R checks
#   docker compose run --rm demo hardening       protection of the issuer discovery namespace
#   docker compose run --rm demo resilience      discovery pod without API server / with an implausible state
#   docker compose run --rm demo pre-rotation    mint + store a token before a key change
#   docker compose run --rm demo staged          after phase 1 (sa-keys stage + API server restart)
#   docker compose run --rm demo post-rotation   after phase 2 (sa-keys activate + API server restart)
# tools/run-all-checks.sh drives the full sequence including the key change.
set -euo pipefail

PHASE="${1:-all}"
VALIDATOR_URL="${VALIDATOR_URL:-https://validator:8443}"
AUD="${WIF_AUDIENCE:-wif-demo-validator}"
NS="wif-demo"
DISCOVERY_NS="wif-issuer-discovery"
ISSUER_HOST=issuer.wif.local
ISSUER=https://$ISSUER_HOST
INGRESS_LB_ADDR=172.31.8.20
CA=/trust/ca.crt
STATE=/state
REALM_ISSUER="${KC_REALM_ISSUER:-https://keycloak:8443/realms/domain-rst}"
TOKEN_ENDPOINT="$REALM_ISSUER/protocol/openid-connect/token"
SERVICE_R=https://service-r.wif.local:8443

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
    printf 'Authorization: Bearer %s\n' "$1" | curl -s --cacert "$CA" -o /tmp/body -w '%{http_code}' \
        -H @- "$VALIDATOR_URL/whoami"
}

# A service outside the cluster speaks TLS only, with a certificate of the internal PKI.
# $1 = pod, $2 = host name, $3 = label
tls_only_checks() {
    local pod=$1 host=$2 label=$3 plain untrusted
    echo "$label: server certificate as seen by pod $pod"
    kubectl -n "$NS" exec "$pod" -- sh -c \
        'curl -sv --cacert /etc/internal-ca/ca.crt -o /dev/null "https://$0:8443/healthz" 2>&1' "$host" \
        | grep -E "subject:|issuer:|SSL connection using" | sed 's/^\* */  /'
    if kubectl -n "$NS" exec "$pod" -- curl -s -o /dev/null --max-time 4 "http://$host:8080/healthz" 2> /dev/null; then
        fail "$label answers plain HTTP on 8080"
    fi
    pass "$label: no plain-HTTP listener on 8080"
    plain=$(kubectl -n "$NS" exec "$pod" -- curl -s -o /dev/null -w '%{http_code}' --max-time 4 \
        "http://$host:8443/healthz" 2> /dev/null || true)
    echo "plain HTTP to the TLS port: HTTP $plain"
    [ "$plain" != "200" ] && pass "$label: plain HTTP on the TLS port is not served" \
        || fail "$label served plain HTTP on its TLS port"
    untrusted=$(kubectl -n "$NS" exec "$pod" -- sh -c \
        'curl -s -o /dev/null --max-time 4 "https://$0:8443/healthz"; echo $?' "$host" 2> /dev/null || true)
    echo "curl with the public CA bundle only: exit $untrusted (60 = certificate not trusted)"
    [ "$untrusted" = "60" ] && pass "$label: certificate trusted only via the internal CA" \
        || fail "$label: expected curl exit 60 without the internal CA, got $untrusted"
}

# Request to the ingress through ingress-lb; extra curl args shape the request.
# Echoes the HTTP status, or 000 when no HTTP exchange happened (e.g. TLS refused).
ingress_status() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert "$CA" "$@" || true
}

# $1 = label -> fails unless the issuer serves a non-empty JWKS
expect_jwks_served() {
    [ "$(curl -fsS --cacert "$CA" "$ISSUER/openid/v1/jwks" | jq '.keys | length')" -gt 0 ] \
        && pass "$1" || fail "$1: JWKS missing or empty"
}

discovery_pods() { kubectl -n "$DISCOVERY_NS" get pods -l app=issuer-discovery --sort-by=.metadata.creationTimestamp -o name; }

ready_discovery_pods() {
    kubectl -n "$DISCOVERY_NS" get pods -l app=issuer-discovery \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[?(@.name=="web")].ready}{"\n"}{end}' \
        | awk '$2 == "true" { print $1 }'
}

base_checks() {
    section "0. OIDC discovery served by the in-cluster discovery pod through the Gateway (internal CA)"
    echo "GET $ISSUER/.well-known/openid-configuration"
    curl -fsS --cacert "$CA" "$ISSUER/.well-known/openid-configuration" \
        | jq '{issuer, jwks_uri, id_token_signing_alg_values_supported}'

    section "1. JWKS served by the discovery pod (mirrored from the API server)"
    curl -fsS --cacert "$CA" "$ISSUER/openid/v1/jwks" | jq '.keys[] | {kid, kty, alg, use}'

    section "2. mint an audience-bound token and decode its claims"
    GOOD=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
    decode_part "$GOOD" 2 | jq .

    section "3. consumer POD  ->  external validator   (happy path)"
    POD=$(kubectl -n "$NS" get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
    echo "pod $POD  ->  https://validator.wif.local:8443/whoami   (token from projected volume)"
    # printf is a shell builtin: the token reaches curl on stdin, never in its arguments.
    POD_STATUS=$(kubectl -n "$NS" exec "$POD" -- sh -c \
        'printf "Authorization: Bearer %s\n" "$(cat /var/run/secrets/tokens/sa-token)" \
            | curl -s --cacert /etc/internal-ca/ca.crt -o /dev/null -w "%{http_code}" -H @- https://validator.wif.local:8443/whoami' || true)
    expect_status 200 "$POD_STATUS" "pod token accepted"
    kubectl -n "$NS" exec "$POD" -- sh -c \
        'printf "Authorization: Bearer %s\n" "$(cat /var/run/secrets/tokens/sa-token)" \
            | curl -s --cacert /etc/internal-ca/ca.crt -H @- https://validator.wif.local:8443/whoami' | jq .

    tls_only_checks "$POD" validator.wif.local "validator"

    section "4. negative: wrong audience  ->  rejected"
    WRONG_AUD=$(kubectl -n "$NS" create token consumer --audience "not-this-service" --duration 10m)
    expect_status 401 "$(whoami_status "$WRONG_AUD")" "wrong audience rejected"

    section "5. negative: tampered signature  ->  rejected"
    expect_status 401 "$(whoami_status "$(tamper_signature "$GOOD")")" "tampered token rejected"

    section "6. the issuer endpoint is read-only and serves only its own host"
    echo '{"keys":[]}' > /tmp/fake-jwks.json
    for method in PUT POST DELETE; do
        echo "$method $ISSUER/openid/v1/jwks"
        expect_status 404 "$(ingress_status -X "$method" -H 'Content-Type: application/json' \
            --data-binary @/tmp/fake-jwks.json "$ISSUER/openid/v1/jwks")" "$method on the JWKS not routed (the route matches GET only)"
    done
    echo "GET $ISSUER/  (a path the HTTPRoute does not match)"
    expect_status 404 "$(ingress_status "$ISSUER/")" "unrouted path not served"
    echo "GET https://other.wif.local/openid/v1/jwks  through ingress-lb (foreign host, SNI other.wif.local)"
    expect_status 000 "$(ingress_status --resolve "other.wif.local:443:$INGRESS_LB_ADDR" -k \
        https://other.wif.local/openid/v1/jwks)" "TLS handshake for a foreign host refused (strict SNI)"
    echo "GET https://kubernetes.default.svc/version  through ingress-lb (API server name)"
    expect_status 000 "$(ingress_status --resolve "kubernetes.default.svc:443:$INGRESS_LB_ADDR" -k \
        https://kubernetes.default.svc/version)" "no way to the API server through the Gateway"
    echo "GET $ISSUER/openid/v1/jwks  with SNI $ISSUER_HOST but Host: other.wif.local"
    MISROUTED=$(ingress_status -H 'Host: other.wif.local' "$ISSUER/openid/v1/jwks")
    echo "HTTP $MISROUTED"
    [ "$MISROUTED" = "404" ] || [ "$MISROUTED" = "421" ] \
        && pass "foreign Host header not routed ($MISROUTED)" || fail "foreign Host header got $MISROUTED"
    expect_jwks_served "published JWKS untouched"

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
        'curl -s --cacert /etc/internal-ca/ca.crt -D /tmp/r-headers -w "\n%{http_code}" -X "$1" -H @- "$0$2"; \
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

    section "14b. R speaks TLS only, with a certificate of the internal PKI"
    tls_only_checks "$CONSUMER" service-r.wif.local "service-r"

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

# kubectl dry-run against the API server, so admission policies are evaluated but
# nothing is stored. $1 = what, manifest on stdin -> fails unless denied
expect_denied() {
    local output
    if output=$(kubectl apply --dry-run=server -f - 2>&1); then
        echo "$output"
        fail "$1: admitted"
    fi
    echo "$output" | sed 's/^/  /'
    grep -q "ValidatingAdmissionPolicy" <<< "$output" || fail "$1: rejected, but not by an admission policy"
    pass "$1: denied"
}

expect_admitted() {
    local output
    output=$(kubectl apply --dry-run=server -f - 2>&1) || { echo "$output"; fail "$1: denied"; }
    pass "$1: admitted"
}

# $1 = namespace, $2 = listener hostname (empty: listener without a hostname)
gateway_manifest() {
    local hostname_line=""
    [ -n "$2" ] && hostname_line="hostname: \"$2\""
    cat <<MANIFEST
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: probe
  namespace: $1
spec:
  gatewayClassName: traefik
  listeners:
    - name: probe
      protocol: HTTP
      port: 8000
      $hostname_line
MANIFEST
}

# $1 = namespace, $2 = route hostname (empty: none), $3 = parent namespace, $4 = parent name
route_manifest() {
    local hostnames_line=""
    [ -n "$2" ] && hostnames_line="hostnames: [\"$2\"]"
    cat <<MANIFEST
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: probe
  namespace: $1
spec:
  parentRefs:
    - namespace: $3
      name: $4
  $hostnames_line
  rules:
    - matches:
        - path:
            type: Exact
            value: /openid/v1/jwks
      backendRefs:
        - name: probe
          port: 80
MANIFEST
}


# $1 = image
issuer_deployment_manifest() {
    cat <<MANIFEST
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe
  namespace: $DISCOVERY_NS
spec:
  selector:
    matchLabels: {app: probe}
  template:
    metadata:
      labels: {app: probe}
    spec:
      containers:
        - name: probe
          image: $1
MANIFEST
}

# $1 = ServiceAccount (namespace:name), $2.. = kubectl auth can-i arguments -> echoes yes/no
can_i() {
    local account=$1
    shift
    kubectl auth can-i --as="system:serviceaccount:$account" "$@" 2> /dev/null || true
}

hardening_checks() {
    section "H1. the issuer host belongs to the issuer's own Gateway"
    local condition
    condition=$(kubectl -n "$DISCOVERY_NS" get gateway issuer-discovery \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
    [ "$condition" = "True" ] && pass "the issuer's Gateway is programmed by Traefik" \
        || fail "the issuer's Gateway is not programmed ($condition)"
    gateway_manifest "$NS" "$ISSUER_HOST" | expect_denied "Gateway listener for $ISSUER_HOST in $NS"
    gateway_manifest "$NS" "*.wif.local" | expect_denied "Gateway listener for *.wif.local in $NS"
    gateway_manifest "$NS" "*.local" | expect_denied "Gateway listener for *.local in $NS"
    gateway_manifest "$NS" "" | expect_denied "Gateway listener without a hostname in $NS (accepts every host)"
    route_manifest "$NS" "$ISSUER_HOST" "$NS" probe | expect_denied "HTTPRoute for $ISSUER_HOST in $NS"
    route_manifest "$NS" "*.wif.local" "$NS" probe | expect_denied "HTTPRoute for *.wif.local in $NS"
    gateway_manifest "$NS" "other.wif.local" | expect_admitted "Gateway listener for another host in $NS"

    echo "a route in $NS tries to attach to the issuer's Gateway (created for real, then removed)"
    trap 'kubectl -n "$NS" delete httproute probe --ignore-not-found > /dev/null' EXIT
    route_manifest "$NS" "" "$DISCOVERY_NS" issuer-discovery | kubectl apply -f - > /dev/null
    condition=""
    for i in $(seq 1 30); do
        condition=$(kubectl -n "$NS" get httproute probe \
            -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}' 2> /dev/null || true)
        [ -n "$condition" ] && break
        sleep 1
    done
    echo "Accepted reason: ${condition:-<none>}"
    [ "$condition" = "NotAllowedByListeners" ] \
        && pass "the issuer's Gateway refuses routes from other namespaces" \
        || fail "route of $NS was not refused by the issuer's Gateway"
    kubectl -n "$NS" delete httproute probe > /dev/null
    trap - EXIT
    expect_jwks_served "the issuer still serves its own JWKS"

    TRAEFIK_ARGS=$(kubectl -n kube-system get deployment traefik -o jsonpath='{.spec.template.spec.containers[0].args}')
    if grep -qE 'providers.kubernetescrd|providers.kubernetesingress' <<< "$TRAEFIK_ARGS"; then
        fail "Traefik still reads Ingress objects or its own route CRDs"
    fi
    pass "Traefik reads neither Ingress objects nor its own route CRDs"
    grep -q 'providers.kubernetesgateway' <<< "$TRAEFIK_ARGS" \
        && pass "Traefik reads routes from the Gateway API" || fail "Traefik's Gateway API provider is off"

    section "H2. admission: images in $DISCOVERY_NS only by digest"
    issuer_deployment_manifest "nginxinc/nginx-unprivileged:1.29-alpine" \
        | expect_denied "Deployment with a tag-only image in $DISCOVERY_NS"
    DIGEST_IMAGE=$(kubectl -n "$DISCOVERY_NS" get deployment issuer-discovery \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="web")].image}')
    issuer_deployment_manifest "$DIGEST_IMAGE" | expect_admitted "Deployment with $DIGEST_IMAGE in $DISCOVERY_NS"

    section "H3. RBAC: nobody but cluster admins writes to $DISCOVERY_NS"
    local account verb resource answer
    for account in "$NS:consumer" "$DISCOVERY_NS:issuer-discovery"; do
        for verb_resource in "create configmaps" "patch deployments" "create pods" "create httproutes" "create gateways" "get secrets"; do
            read -r verb resource <<< "$verb_resource"
            answer=$(can_i "$account" "$verb" "$resource" -n "$DISCOVERY_NS")
            printf '  %-20s %-18s -n %s: %s\n' "$account" "$verb_resource" "$DISCOVERY_NS" "$answer"
            [ "$answer" = "no" ] || fail "$account may $verb_resource in $DISCOVERY_NS"
        done
    done
    pass "neither a workload nor the discovery pod's own ServiceAccount may write or read secrets in $DISCOVERY_NS"
    [ "$(can_i "$DISCOVERY_NS:issuer-discovery" get /openid/v1/jwks)" = "yes" ] \
        && pass "the discovery pod's ServiceAccount may read the JWKS (issuer-discovery role)" \
        || fail "the discovery pod's ServiceAccount cannot read the JWKS"

    section "H4. NetworkPolicy: in only from the gateway controller, out only to the API server"
    local consumer discovery_pod
    consumer=$(pod_of consumer)
    echo "consumer -> http://issuer-discovery.$DISCOVERY_NS.svc/openid/v1/jwks"
    if kubectl -n "$NS" exec "$consumer" -- curl -s -o /dev/null --max-time 4 \
        "http://issuer-discovery.$DISCOVERY_NS.svc/openid/v1/jwks" 2> /dev/null; then
        fail "a workload reaches the discovery pod directly"
    fi
    pass "workloads cannot reach the discovery pod"
    discovery_pod=$(discovery_pods | tail -n 1)
    discovery_pod=${discovery_pod#pod/}
    echo "$discovery_pod (sync) -> validator at 172.31.9.10:8443"
    if kubectl -n "$DISCOVERY_NS" exec "$discovery_pod" -c sync -- curl -sk -o /dev/null --max-time 4 \
        https://172.31.9.10:8443/healthz 2> /dev/null; then
        fail "the discovery pod reaches the validator"
    fi
    pass "the discovery pod reaches nothing but the API server"
    echo "$discovery_pod (sync) -> API server"
    kubectl -n "$DISCOVERY_NS" exec "$discovery_pod" -c sync -- sh -c \
        'curl -fsS -o /dev/null --max-time 5 --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
            -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
            "https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/openid/v1/jwks"' \
        && pass "the discovery pod reaches the API server" || fail "the discovery pod cannot reach the API server"

    section "H5. pod hardening"
    kubectl -n "$DISCOVERY_NS" get pod "$discovery_pod" -o json | jq -e '
        .spec.securityContext.runAsNonRoot == true
        and ([.spec.containers[].securityContext
              | .readOnlyRootFilesystem == true
                and .allowPrivilegeEscalation == false
                and .capabilities.drop == ["ALL"]
                and ((.capabilities.add // []) | length) == 0] | all)' > /dev/null \
        && pass "non-root, read-only root filesystem, no capabilities" || fail "discovery pod is not hardened"
    if kubectl -n "$DISCOVERY_NS" exec "$discovery_pod" -c web -- touch /probe 2> /dev/null; then
        fail "web container can write its root filesystem"
    fi
    pass "web container cannot write its root filesystem"
    if kubectl -n "$DISCOVERY_NS" exec "$discovery_pod" -c web -- \
        ls /var/run/secrets/kubernetes.io/serviceaccount > /dev/null 2>&1; then
        fail "web container holds a ServiceAccount token"
    fi
    pass "the web container, which faces the gateway, holds no ServiceAccount token"
}

# $1 = pod, $2 = pattern, $3 = seconds, $4 = optional RFC 3339 time: only log lines
# after it count -> fails unless the sync log shows the pattern
await_sync_log() {
    local i since=()
    [ -n "${4:-}" ] && since=(--since-time="$4")
    for i in $(seq 1 "$3"); do
        if kubectl -n "$DISCOVERY_NS" logs "$1" -c sync "${since[@]}" 2> /dev/null | grep -q "$2"; then
            kubectl -n "$DISCOVERY_NS" logs "$1" -c sync "${since[@]}" | grep "$2" | tail -n 1 | sed "s/^/  $1: /"
            return 0
        fi
        sleep 1
    done
    fail "no '$2' in the sync log of $1 within $3 s"
}

API_EGRESS='[{"to":[{"ipBlock":{"cidr":"172.31.7.2/32"}}],"ports":[{"port":6443}]}]'

set_api_egress() {
    kubectl -n "$DISCOVERY_NS" patch networkpolicy issuer-discovery-to-api-server --type=json \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/egress\",\"value\":$1}]" > /dev/null
}

restore_issuer() {
    set_api_egress "$API_EGRESS"
    if kubectl -n "$DISCOVERY_NS" get deployment issuer-discovery -o jsonpath='{.spec.template.spec.containers[0].env}' \
        | grep -q not-this-cluster; then
        kubectl -n "$DISCOVERY_NS" rollout undo deployment/issuer-discovery > /dev/null
    fi
    kubectl -n "$DISCOVERY_NS" rollout status deployment/issuer-discovery --timeout=120s > /dev/null
}

resilience_checks() {
    trap restore_issuer EXIT
    local kids_before pod new_pod i cut_at
    kids_before=$(published_kids)

    section "R1. API server unreachable: the discovery pods keep serving the last good state"
    echo "cutting the discovery pods' path to the API server (NetworkPolicy egress := none)"
    cut_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    set_api_egress '[]'
    for pod in $(discovery_pods); do
        await_sync_log "${pod#pod/}" "reading from the API server failed" 60 "$cut_at"
    done
    [ "$(published_kids)" = "$kids_before" ] && pass "the JWKS is served unchanged" \
        || fail "the served JWKS changed while the API server was unreachable"
    [ "$(ready_discovery_pods | wc -l)" = "2" ] && pass "both discovery pods stay ready" \
        || fail "discovery pods lost readiness"
    echo "restoring the path to the API server"
    set_api_egress "$API_EGRESS"

    section "R2. implausible state: a new pod never becomes ready, the others keep serving"
    echo "rolling out a pod that expects another issuer, so the API server's state is implausible to it"
    kubectl -n "$DISCOVERY_NS" set env deployment/issuer-discovery -c sync EXPECTED_ISSUER=https://not-this-cluster
    for i in $(seq 1 60); do
        [ "$(discovery_pods | wc -l)" -ge 3 ] && break
        sleep 1
    done
    new_pod=$(discovery_pods | tail -n 1)
    new_pod=${new_pod#pod/}
    echo "new pod: $new_pod"
    await_sync_log "$new_pod" "REJECTED state" 60
    sleep 10
    if ready_discovery_pods | grep -qx "$new_pod"; then
        fail "a pod without a plausible state became ready"
    fi
    pass "the new pod is not ready (no plausible state yet)"
    [ "$(ready_discovery_pods | wc -l)" = "2" ] && pass "the two previous pods keep serving" \
        || fail "previous discovery pods lost readiness"
    [ "$(published_kids)" = "$kids_before" ] && pass "the JWKS is served unchanged" \
        || fail "the served JWKS changed during the rollout"
    echo "rolling back"
    kubectl -n "$DISCOVERY_NS" rollout undo deployment/issuer-discovery
    kubectl -n "$DISCOVERY_NS" rollout status deployment/issuer-discovery --timeout=120s
    trap - EXIT
    restore_issuer
    expect_jwks_served "the discovery pods serve the JWKS after the rollback"
}

# $1 = seconds -> waits until the discovery endpoint answers through the Gateway. In the lab an
# API server restart restarts the whole node, and with it the discovery pods.
await_issuer() {
    local i
    for i in $(seq 1 "$1"); do
        curl -fsS -o /dev/null --max-time 3 --cacert "$CA" "$ISSUER/openid/v1/jwks" 2> /dev/null && return 0
        sleep 1
    done
    fail "issuer discovery endpoint not served within $1 s"
}

# $1 = kid -> fails unless every discovery pod logged the kid's appearance
expect_kid_logged() {
    local pod
    for pod in $(discovery_pods); do
        await_sync_log "${pod#pod/}" "WARNING kid appeared: $1" 60
    done
    pass "every discovery pod logged the new kid $1"
}

pre_rotation() {
    section "key change 0/2: token and published keys before the change"
    kubectl -n "$NS" create token consumer --audience "$AUD" --duration 1h > "$STATE/pre-rotation-token"
    published_kids > "$STATE/pre-rotation-kids"
    rm -f "$STATE/staged-kid"
    echo "published kids:"; sed 's/^/  /' "$STATE/pre-rotation-kids"
    echo "token kid: $(kid_of "$(cat "$STATE/pre-rotation-token")")"
    expect_status 200 "$(whoami_status "$(cat "$STATE/pre-rotation-token")")" "pre-rotation token accepted"
}

staged_phase() {
    section "key change 1/2: the staged key is published ahead, it does not sign yet"
    [ -s "$STATE/pre-rotation-token" ] || fail "run the pre-rotation phase first"
    local staged_kid="" i token assertion
    for i in $(seq 1 36); do
        staged_kid=$(published_kids 2> /dev/null | comm -13 "$STATE/pre-rotation-kids" - || true)
        [ -n "$staged_kid" ] && break
        printf '  t+%3ds  staged kid not served yet\n' "$((i * 5))"
        sleep 5
    done
    [ -n "$staged_kid" ] || fail "the staged kid was not served within 180s"
    echo "$staged_kid" > "$STATE/staged-kid"
    echo "published kids now:"; published_kids | sed 's/^/  /'
    pass "staged kid served: $staged_kid"
    expect_kid_logged "$staged_kid"

    token=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
    echo "new token kid: $(kid_of "$token")"
    grep -qx "$(kid_of "$token")" "$STATE/pre-rotation-kids" \
        && pass "the API server still signs with the current key" \
        || fail "the API server signs with the staged key already"
    expect_status 200 "$(whoami_status "$token")" "token accepted by the validator"
    assertion=$(kubectl -n "$NS" create token consumer --audience "$REALM_ISSUER" --duration 10m)
    expect_status 200 "$(direct_token_request "$assertion" r:orders:read)" "client assertion accepted by the realm"
}

post_rotation() {
    section "key change 2/2: the staged key signs — the first pass with it is accepted"
    [ -s "$STATE/staged-kid" ] || fail "run the staged phase first"
    local staged_kid rotated new
    staged_kid=$(cat "$STATE/staged-kid")
    await_issuer 180

    rotated=$(kubectl -n "$NS" create token consumer --audience "$REALM_ISSUER" --duration 10m)
    echo "client assertion kid: $(kid_of "$rotated")"
    [ "$(kid_of "$rotated")" = "$staged_kid" ] || fail "the API server does not sign with the staged key"
    expect_status 200 "$(direct_token_request "$rotated" r:orders:read)" \
        "first assertion with the new key accepted by the realm, without retry"

    new=$(kubectl -n "$NS" create token consumer --audience "$AUD" --duration 10m)
    echo "new token kid: $(kid_of "$new")"
    expect_status 200 "$(whoami_status "$new")" "first token with the new key accepted by the validator, without retry"
    expect_status 200 "$(whoami_status "$(cat "$STATE/pre-rotation-token")")" \
        "pre-rotation token still accepted (previous key kept in the JWKS)"

    echo "published kids now:"; published_kids | sed 's/^/  /'
    if published_kids | grep -qx "$staged_kid" && published_kids | grep -qxf "$STATE/pre-rotation-kids" \
        && [ "$(published_kids | wc -l)" = "2" ]; then
        pass "the JWKS holds exactly the new and the previous key (no other key, e.g. k3s's own)"
    else
        fail "unexpected key set after the change"
    fi
}

case "$PHASE" in
    all)           base_checks ;;
    authz)         authz_checks ;;
    hardening)     hardening_checks ;;
    resilience)    resilience_checks ;;
    pre-rotation)  pre_rotation ;;
    staged)        staged_phase ;;
    post-rotation) post_rotation ;;
    *)             fail "unknown phase '$PHASE' (all|authz|hardening|resilience|pre-rotation|staged|post-rotation)" ;;
esac

section "result"
pass "phase '$PHASE': all checks passed"
