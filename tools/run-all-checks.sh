#!/usr/bin/env bash
# Host-side driver for every lab check. Needs only docker compose on the host:
#   1. base demo (discovery, pod -> validator, negative token and Gateway cases)
#   1b. authorization server demo (pod -> keycloak -> service R, negative cases)
#   1c. protection of the issuer discovery namespace (admission, RBAC, NetworkPolicy, pod)
#   1d. discovery pod without API server and with an implausible state
#   2. network separation as seen from validator, keycloak and service R
#   3. validator with a foreign CA refuses to start
#   4. signing key change in two phases, served by the in-cluster discovery pod
set -euo pipefail
cd "$(dirname "$0")/.."

section() { printf '\n\033[1;35m##### %s #####\033[0m\n' "$1"; }
pass()    { printf '\033[1;32mPASS: %s\033[0m\n' "$1"; }
fail()    { printf '\033[1;31mFAIL: %s\033[0m\n' "$1"; exit 1; }

section "lab up"
docker compose up -d --build

section "1. base demo"
docker compose run --rm demo all

section "1b. authorization server demo"
docker compose run --rm demo authz

section "1c. protection of the issuer discovery namespace"
docker compose run --rm demo hardening

section "1d. discovery pod resilience"
docker compose run --rm demo resilience

section "2. network separation (seen from the relying parties)"
# $1 = service, $2 = host:port, $3 = description
unreachable() {
    if docker compose exec -T "$1" curl -sk -o /dev/null --max-time 4 "https://$2/"; then
        fail "$1 reaches $2 ($3)"
    fi
    pass "$1 cannot reach $2 ($3)"
}
# The keycloak image has no curl: plain TCP connect with bash, bounded from the host.
unreachable_from_keycloak() {
    if timeout 8 docker compose exec -T keycloak bash -c "exec 3<>/dev/tcp/${1%:*}/${1#*:}" 2> /dev/null; then
        fail "keycloak reaches $1 ($2)"
    fi
    pass "keycloak cannot reach $1 ($2)"
}
for service in validator service-r; do
    unreachable "$service" 172.31.9.2:6443   "API server via workload-net"
    unreachable "$service" 172.31.7.2:6443   "API server via cluster-net"
    unreachable "$service" 172.31.7.2:30443  "gateway node port via cluster-net"
    unreachable "$service" 172.31.9.2:30443  "gateway node port via workload-net"
done
timeout 8 docker compose exec -T keycloak bash -c "exec 3<>/dev/tcp/172.31.8.20/443" \
    && pass "keycloak reaches the ingress route through ingress-lb (probe works)" \
    || fail "keycloak cannot reach ingress-lb — TCP probe is broken"
unreachable_from_keycloak 172.31.9.2:6443  "API server via workload-net"
unreachable_from_keycloak 172.31.7.2:6443  "API server via cluster-net"
unreachable_from_keycloak 172.31.7.2:30443 "gateway node port via cluster-net"
unreachable_from_keycloak 172.31.7.20:443  "ingress-lb's cluster-net side"

section "3. validator with a foreign CA refuses to start"
FOREIGN_LOG=$(mktemp)
set +e
timeout 180 docker compose run --rm --name wif-lab-foreign-ca validator-foreign-ca > "$FOREIGN_LOG" 2>&1
FOREIGN_EXIT=$?
set -e
docker rm -f wif-lab-foreign-ca > /dev/null 2>&1 || true
grep -m1 -E 'PKIX|certification path' "$FOREIGN_LOG" || true
rm -f "$FOREIGN_LOG"
[ "$FOREIGN_EXIT" = "124" ] && fail "validator with foreign CA kept running"
[ "$FOREIGN_EXIT" != "0" ] && pass "validator with foreign CA exited with $FOREIGN_EXIT" \
    || fail "validator with foreign CA exited cleanly"

section "4. signing key change in two phases"
docker compose run --rm demo pre-rotation
docker compose run --rm sa-keys stage
docker compose restart server
docker compose up -d --wait server
docker compose run --rm demo staged
docker compose run --rm sa-keys activate
docker compose restart server
docker compose up -d --wait server
docker compose run --rm demo post-rotation

section "result"
pass "all lab checks passed"
