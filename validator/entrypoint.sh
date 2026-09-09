#!/bin/sh
set -e

CA="${WIF_CLUSTER_CA:-/k3s/server/tls/server-ca.crt}"

echo "validator: waiting for cluster CA at ${CA} ..."
attempt=0
while [ ! -s "$CA" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 180 ]; then
        echo "validator: cluster CA never appeared at ${CA}" >&2
        exit 1
    fi
    sleep 1
done
echo "validator: cluster CA present after ${attempt}s, starting"

exec java -XX:MaxRAMPercentage=75 -jar /app/app.jar
