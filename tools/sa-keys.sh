#!/usr/bin/env bash
# Manages the ServiceAccount token signing keys of the lab cluster.
#   init   — create the first signing key (no-op when one exists)
#   rotate — make a fresh key the signing key and keep the previous public key
#            for verification, so tokens signed before the rotation stay valid
# The API server signs with signing.key and publishes every key in verify.pub
# in its JWKS; keys older than the previous one are dropped on rotation.
set -euo pipefail

DIR=/sa-keys

new_key() {
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$DIR/signing.key" 2>/dev/null
    openssl pkey -in "$DIR/signing.key" -pubout -out "$DIR/current.pub"
}

assemble_verify_set() {
    if [ -s "$DIR/previous.pub" ]; then
        cat "$DIR/current.pub" "$DIR/previous.pub" > "$DIR/verify.pub"
    else
        cp "$DIR/current.pub" "$DIR/verify.pub"
    fi
    chmod 600 "$DIR/signing.key"
    chmod 644 "$DIR/current.pub" "$DIR/verify.pub"
}

case "${1:-}" in
    init)
        if [ -s "$DIR/signing.key" ]; then
            echo "sa-keys: signing key already present, keeping it"
        else
            echo "sa-keys: creating initial signing key"
            new_key
            rm -f "$DIR/previous.pub"
        fi
        assemble_verify_set
        ;;
    rotate)
        [ -s "$DIR/current.pub" ] || { echo "sa-keys: nothing to rotate, run init first" >&2; exit 1; }
        echo "sa-keys: rotating — current key becomes the verify-only previous key"
        cp "$DIR/current.pub" "$DIR/previous.pub"
        new_key
        assemble_verify_set
        ;;
    *)
        echo "usage: sa-keys.sh init|rotate" >&2
        exit 2
        ;;
esac

echo "sa-keys: verify set now holds $(grep -c 'BEGIN PUBLIC KEY' "$DIR/verify.pub") public key(s)"
