#!/bin/sh
# Builds a trust store that contains only the internal CA and makes it the JVM default,
# so every outbound TLS connection (realm discovery, JWKS) trusts nothing else.
set -e

CA="${SERVICE_R_TRUST_CA:-/trust/ca.crt}"
TRUSTSTORE=/tmp/internal-ca.p12
TRUSTSTORE_PASSWORD=internal-ca-only

attempt=0
while [ ! -s "$CA" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 180 ]; then
        echo "service-r: internal CA certificate never appeared at ${CA}" >&2
        exit 1
    fi
    sleep 1
done

rm -f "$TRUSTSTORE"
keytool -importcert -noprompt -alias internal-ca -file "$CA" \
    -keystore "$TRUSTSTORE" -storetype PKCS12 -storepass "$TRUSTSTORE_PASSWORD" > /dev/null
echo "service-r: trust store holds only the internal CA from ${CA}"

exec java -XX:MaxRAMPercentage=75 \
    -Djavax.net.ssl.trustStore="$TRUSTSTORE" \
    -Djavax.net.ssl.trustStoreType=PKCS12 \
    -Djavax.net.ssl.trustStorePassword="$TRUSTSTORE_PASSWORD" \
    ${JAVA_OPTS:-} -jar /app/app.jar
