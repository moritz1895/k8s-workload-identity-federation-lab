#!/usr/bin/env bash
# One-shot lab PKI, standing in for the organisation's internal PKI:
#   - a root CA (key stays in the pki-ca volume, nobody else mounts it)
#   - the serving certificate of issuer-web
#   - the serving certificate of the domain authorization server (keycloak)
#   - the serving certificate of resource server R (service-r)
#   - the client certificate of the in-cluster JWKS publisher (mTLS upload)
#   - negative-test material: a client cert with the wrong CN and a foreign CA
# Each artefact lands in its own volume so every component sees only what it needs.
# Idempotent: existing material is kept across `docker compose up` runs.
set -euo pipefail

CA_DIR=/pki/ca
TRUST_DIR=/pki/trust
ISSUER_DIR=/pki/issuer
PUBLISHER_DIR=/pki/publisher
KEYCLOAK_DIR=/pki/keycloak
SERVICE_R_DIR=/pki/service-r
DEMO_DIR=/pki/demo

DAYS=825

issue_cert() {
    local name=$1 subject=$2 extensions=$3 ca_cert=$4 ca_key=$5 out_dir=$6
    openssl req -newkey rsa:2048 -nodes -subj "$subject" \
        -keyout "$out_dir/$name.key" -out "/tmp/$name.csr" 2>/dev/null
    printf '%s\n' "$extensions" > "/tmp/$name.ext"
    openssl x509 -req -in "/tmp/$name.csr" -days "$DAYS" -sha256 \
        -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -extfile "/tmp/$name.ext" -out "$out_dir/$name.crt" 2>/dev/null
}

new_root() {
    local dir=$1 cn=$2
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -sha256 \
        -subj "/O=WIF Lab/CN=$cn" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$dir/ca.key" -out "$dir/ca.crt" 2>/dev/null
}

SERVER_EXT="basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:issuer-web"

KEYCLOAK_EXT="basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:keycloak,DNS:localhost,IP:127.0.0.1"

SERVICE_R_EXT="basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:service-r.wif.local,DNS:service-r,DNS:localhost,IP:127.0.0.1"

CLIENT_EXT="basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth"

if [ -s "$CA_DIR/ca.crt" ]; then
    echo "pki-init: lab CA already present, keeping it"
else
    echo "pki-init: creating lab root CA"
    new_root "$CA_DIR" "WIF Lab Internal Root CA"
    rm -f "$ISSUER_DIR"/* "$PUBLISHER_DIR"/* "$KEYCLOAK_DIR"/* "$SERVICE_R_DIR"/* "$DEMO_DIR"/*
fi

cp "$CA_DIR/ca.crt" "$TRUST_DIR/ca.crt"

if [ ! -s "$ISSUER_DIR/tls.crt" ]; then
    echo "pki-init: issuing issuer-web serving certificate"
    issue_cert tls "/O=WIF Lab/CN=issuer-web" "$SERVER_EXT" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$ISSUER_DIR"
fi

if [ ! -s "$KEYCLOAK_DIR/tls.crt" ]; then
    echo "pki-init: issuing keycloak serving certificate"
    issue_cert tls "/O=WIF Lab/CN=keycloak" "$KEYCLOAK_EXT" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$KEYCLOAK_DIR"
fi

if [ ! -s "$SERVICE_R_DIR/tls.crt" ]; then
    echo "pki-init: issuing service-r serving certificate"
    issue_cert tls "/O=WIF Lab/CN=service-r.wif.local" "$SERVICE_R_EXT" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$SERVICE_R_DIR"
fi

if [ ! -s "$PUBLISHER_DIR/tls.crt" ]; then
    echo "pki-init: issuing jwks-publisher client certificate"
    issue_cert tls "/O=WIF Lab/CN=jwks-publisher" "$CLIENT_EXT" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$PUBLISHER_DIR"
fi

if [ ! -s "$DEMO_DIR/foreign-ca.crt" ]; then
    echo "pki-init: issuing negative-test material"
    issue_cert wrong-cn "/O=WIF Lab/CN=not-the-publisher" "$CLIENT_EXT" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$DEMO_DIR"
    issue_cert smuggled-cn "/O=x,CN=jwks-publisher/CN=not-the-publisher" "$CLIENT_EXT" "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$DEMO_DIR"

    mkdir -p /tmp/foreign
    new_root /tmp/foreign "Foreign Root CA"
    cp /tmp/foreign/ca.crt "$DEMO_DIR/foreign-ca.crt"
    issue_cert foreign-publisher "/O=Foreign/CN=jwks-publisher" "$CLIENT_EXT" /tmp/foreign/ca.crt /tmp/foreign/ca.key "$DEMO_DIR"
fi

chmod 644 "$TRUST_DIR"/ca.crt "$ISSUER_DIR"/*.crt "$PUBLISHER_DIR"/*.crt "$DEMO_DIR"/*.crt
chmod 600 "$ISSUER_DIR"/*.key "$PUBLISHER_DIR"/*.key "$DEMO_DIR"/*.key
# Keycloak runs as uid 1000 and has to read its own key.
chmod 644 "$KEYCLOAK_DIR"/tls.crt
chown 1000:0 "$KEYCLOAK_DIR"/tls.key
chmod 400 "$KEYCLOAK_DIR"/tls.key
# service-r runs as uid 10001.
chmod 644 "$SERVICE_R_DIR"/tls.crt
chown 10001:0 "$SERVICE_R_DIR"/tls.key
chmod 400 "$SERVICE_R_DIR"/tls.key
echo "pki-init: done"
