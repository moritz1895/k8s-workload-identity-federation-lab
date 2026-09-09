#!/bin/sh
set -e

CA="${WIF_ISSUER_CA:-/oidc/tls.crt}"

echo "validator: waiting for the issuer certificate at ${CA} ..."
attempt=0
while [ ! -s "$CA" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 180 ]; then
        echo "validator: issuer certificate never appeared at ${CA}" >&2
        exit 1
    fi
    sleep 1
done
echo "validator: issuer certificate present after ${attempt}s, starting"

exec java -XX:MaxRAMPercentage=75 ${JAVA_OPTS:-} -jar /app/app.jar
