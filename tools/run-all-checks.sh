#!/usr/bin/env bash
# Host-side driver for every lab check. Needs only docker compose on the host:
#   1. base demo (discovery, pod -> validator, negative token and upload cases)
#   2. network separation as seen from the validator
#   3. validator with a foreign CA refuses to start
#   4. signing key rotation in the cluster, published by the jwks-publisher
set -euo pipefail
cd "$(dirname "$0")/.."

section() { printf '\n\033[1;35m##### %s #####\033[0m\n' "$1"; }
pass()    { printf '\033[1;32mPASS: %s\033[0m\n' "$1"; }
fail()    { printf '\033[1;31mFAIL: %s\033[0m\n' "$1"; exit 1; }

section "lab up"
docker compose up -d --build

section "1. base demo"
docker compose run --rm demo all

section "2. network separation (seen from the validator)"
unreachable() {
    if docker compose exec -T validator curl -sk -o /dev/null --max-time 4 "https://$1/"; then
        fail "validator reaches $1 ($2)"
    fi
    pass "validator cannot reach $1 ($2)"
}
unreachable 172.31.9.2:6443  "API server via workload-net"
unreachable 172.31.7.2:6443  "API server via cluster-net"
unreachable 172.31.8.20:8443 "issuer upload listener via relying-net"

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

section "4. signing key rotation"
docker compose run --rm demo pre-rotation
docker compose run --rm sa-keys rotate
docker compose restart server
docker compose up -d --wait server
docker compose run --rm demo post-rotation

section "result"
pass "all lab checks passed"
