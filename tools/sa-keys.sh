#!/usr/bin/env bash
# Manages the ServiceAccount token signing keys of the lab cluster. A key change runs
# in two phases, each followed by a restart of the API server:
#   init     — create the first signing key (no-op when one exists)
#   stage    — phase 1: create the next key and publish its public key ahead (verify
#              set, hence JWKS); the API server keeps signing with the current key
#   activate — phase 2: the staged key becomes the signing key; the previous signing
#              key stays in the verify set, older keys are dropped
#   retire   — emergency: drop the previous key from the verify set at once, e.g.
#              when it is compromised; tokens signed with it stop being accepted
#              once the relying parties refresh their keys
# Phase 1 exists because the relying parties get keys with a delay (discovery pod sync,
# caches): run `activate` only after the staged key is served at the JWKS URL, so no
# relying party sees a token whose kid it cannot find yet. Between two `activate` runs lie at
# least the maximum token lifetime plus the relying parties' key cache time.
# The API server signs with signing.key and publishes every key in verify.pub.
set -euo pipefail

DIR=/sa-keys

generate_key() {
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1.key" 2>/dev/null
    openssl pkey -in "$1.key" -pubout -out "$1.pub"
}

assemble_verify_set() {
    local file
    : > "$DIR/verify.pub"
    for file in current.pub staged.pub previous.pub; do
        if [ -s "$DIR/$file" ]; then
            cat "$DIR/$file" >> "$DIR/verify.pub"
        fi
    done
    chmod 600 "$DIR/signing.key"
    [ -s "$DIR/staged.key" ] && chmod 600 "$DIR/staged.key"
    chmod 644 "$DIR"/*.pub
}

case "${1:-}" in
    init)
        if [ -s "$DIR/signing.key" ]; then
            echo "sa-keys: signing key already present, keeping it"
        else
            echo "sa-keys: creating initial signing key"
            generate_key "$DIR/signing"
            mv "$DIR/signing.pub" "$DIR/current.pub"
            rm -f "$DIR/previous.pub" "$DIR/staged.key" "$DIR/staged.pub"
        fi
        assemble_verify_set
        ;;
    stage)
        [ -s "$DIR/current.pub" ] || { echo "sa-keys: nothing to stage against, run init first" >&2; exit 1; }
        if [ -s "$DIR/staged.key" ]; then
            echo "sa-keys: a staged key exists already, keeping it"
        else
            echo "sa-keys: phase 1 — publishing the next key ahead; it does not sign yet"
            generate_key "$DIR/staged"
        fi
        assemble_verify_set
        ;;
    activate)
        [ -s "$DIR/staged.key" ] || { echo "sa-keys: no staged key, run stage first" >&2; exit 1; }
        echo "sa-keys: phase 2 — the staged key becomes the signing key"
        mv "$DIR/current.pub" "$DIR/previous.pub"
        mv "$DIR/staged.key" "$DIR/signing.key"
        mv "$DIR/staged.pub" "$DIR/current.pub"
        assemble_verify_set
        ;;
    retire)
        [ -s "$DIR/previous.pub" ] || { echo "sa-keys: no previous key to retire" >&2; exit 1; }
        echo "sa-keys: retiring the previous key from the verify set"
        rm -f "$DIR/previous.pub"
        assemble_verify_set
        ;;
    *)
        echo "usage: sa-keys.sh init|stage|activate|retire" >&2
        exit 2
        ;;
esac

echo "sa-keys: verify set now holds $(grep -c 'BEGIN PUBLIC KEY' "$DIR/verify.pub") public key(s)"
