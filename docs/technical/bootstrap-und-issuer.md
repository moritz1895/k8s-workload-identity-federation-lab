# PKI, Bootstrap, Publisher und Issuer-Endpoint

**Für wen / was lernst du hier:** Du kennst JWT/JWKS, aber nicht Kubernetes-Werkzeuge wie
`kubectl` oder OpenSSL-Aufrufe. Diese Seite geht die Bausteine durch, die Discovery-Dokument
und JWKS vom API-Server zum Issuer-Endpoint bringen: die Lab-PKI (`tools/pki-init.sh`), die
Signaturschlüssel (`tools/sa-keys.sh`), die Cluster-Einrichtung (`tools/bootstrap.sh`), den
`jwks-publisher` (`manifests/10-publisher.yaml`) und die nginx-Konfiguration
`tools/nginx-issuer.conf`. Die Entscheidung dahinter:
[ADR 0003](../adr/0003-getrennte-vertrauensbereiche-interne-pki.md).

---

## Der Weg der Metadaten

Der Kubernetes-API-Server *kann* selbst ein OIDC-Discovery-Dokument und ein JWKS ausliefern
(unter `/.well-known/openid-configuration` und `/openid/v1/jwks`). In einem echten
Federation-Setup sollen diese Metadaten aber von einem **stabilen, öffentlichen Endpunkt**
kommen, der nicht der API-Server ist ([ADR 0002](../adr/0002-eigenstaendiger-issuer-endpoint.md)).

Im Lab:

```
API-Server ──GET (SA-Token, Leserolle)──► jwks-publisher (Pod) ──PUT (mTLS)──► issuer-web :8443
                                                                                    │
                                                         Volume oidc-web ◄──────────┘
                                                                │
                                         issuer-web :443 ──GET──► validator
```

Wer das JWKS am Issuer-Endpoint austauschen kann, kann beliebige Tokens ausstellen, die der
Validator akzeptiert. Deshalb darf nur ein Client mit dem Publisher-Zertifikat der internen
CA schreiben, und nur aus dem Cluster-Netz.

---

## `tools/pki-init.sh` – die Lab-PKI

Läuft als Einmal-Container `pki-init` ohne Netz. Er steht für die interne PKI der
Organisation, deren Root-Zertifikat real bereits auf allen Systemen verteilt ist.

| Artefakt | Volume | Inhalt |
|---|---|---|
| Root-CA | `pki-ca` (nur `pki-init`) | `ca.crt`, `ca.key` – RSA 3072, 10 Jahre, `CN=WIF Lab Internal Root CA` |
| Vertrauensanker | `ca-trust` | Kopie von `ca.crt` |
| Serverzertifikat `issuer-web` | `issuer-tls` | `tls.crt` / `tls.key`, `CN=issuer-web`, SAN `DNS:issuer-web`, `extendedKeyUsage=serverAuth` |
| Serverzertifikat Keycloak | `keycloak-tls` | `tls.crt` / `tls.key`, `CN=keycloak`, SAN `DNS:keycloak`, `DNS:localhost`, `IP:127.0.0.1`; Schlüssel `chown 1000:0`, `chmod 400`, weil Keycloak als uid 1000 läuft |
| Serverzertifikat Validator | `validator-tls` | `tls.crt` / `tls.key`, `CN=validator.wif.local`, SAN `DNS:validator.wif.local`, `DNS:validator`, `DNS:localhost`, `IP:127.0.0.1`; Schlüssel `chown 10001:0`, `chmod 400`, weil der Validator als uid 10001 läuft |
| Serverzertifikat `service-r` | `service-r-tls` | `tls.crt` / `tls.key`, `CN=service-r.wif.local`, SAN `DNS:service-r.wif.local`, `DNS:service-r`, `DNS:localhost`, `IP:127.0.0.1`; Schlüssel `chown 10001:0`, `chmod 400`, weil `service-r` als uid 10001 läuft |
| Client-Zertifikat Publisher | `publisher-tls` | `tls.crt` / `tls.key`, `CN=jwks-publisher`, `extendedKeyUsage=clientAuth` |
| Negativtests | `pki-demo` | `wrong-cn.*` (interne CA, `CN=not-the-publisher`), `smuggled-cn.*` (interne CA, `CN=jwks-publisher` nur im Feld `O`), `foreign-ca.crt`, `foreign-publisher.*` (fremde CA, `CN=jwks-publisher`) |

Die End-Zertifikate sind RSA 2048 und 825 Tage gültig. Das Skript ist idempotent: Existiert
die CA, bleibt sie; nur fehlende Zertifikate werden ausgestellt. Erzeugt es eine neue CA,
verwirft es alle vorhandenen End-Zertifikate und stellt sie von der neuen CA aus.

**Warum `subjectAltName=DNS:issuer-web`?** Moderne TLS-Clients (Java, curl) prüfen den
angefragten Hostnamen ausschließlich gegen die **SAN**-Liste des Zertifikats. Validator und
Publisher rufen `https://issuer-web/...` auf, also **muss** `issuer-web` als SAN im
Zertifikat stehen. Details: [trust-und-tls.md](trust-und-tls.md).

---

## `tools/sa-keys.sh` – Signaturschlüssel und Rotation

Der API-Server signiert ServiceAccount-Tokens mit eigenen Schlüsseldateien aus dem Volume
`sa-keys` (statt mit dem k3s-eigenen Schlüssel):

| Datei | Bedeutung |
|---|---|
| `signing.key` | privater RSA-2048-Schlüssel, `service-account-signing-key-file` |
| `current.pub` | öffentlicher Teil von `signing.key` |
| `previous.pub` | öffentlicher Teil des vorherigen Schlüssels (nach einer Rotation) |
| `verify.pub` | `current.pub` + `previous.pub`, `service-account-key-file` – diese Schlüssel erscheinen im JWKS |

- **`init`** (Standard beim `up`): legt `signing.key` an, wenn keiner existiert, und baut
  `verify.pub`.
- **`rotate`** (`docker compose run --rm sa-keys rotate`): `current.pub` wird zu
  `previous.pub`, ein neuer Schlüssel wird `signing.key`. Schlüssel älter als der vorherige
  fallen heraus.

kube-apiserver liest die Dateien nur beim Start. Nach `rotate` also
`docker compose restart server`. Danach signiert der Cluster mit dem neuen Schlüssel, das
JWKS enthält beide, und der Publisher veröffentlicht es beim nächsten Durchlauf. Tokens von
vor der Rotation bleiben gültig, bis zur nächsten Rotation. Ablauf und Test:
[../use-cases.md](../use-cases.md#use-case-4-signaturschlüssel-rotieren).

---

## `tools/bootstrap.sh` Schritt für Schritt

Läuft als Einmal-Container `bootstrap` mit der Admin-Kubeconfig, nachdem `server` gesund und
`pki-init` fertig ist, und bei jedem `docker compose up` erneut. `bootstrap` spricht
`issuer-web` nicht an.

### Kopf: strikte Fehlerbehandlung

`tools/bootstrap.sh:10`

```bash
set -euo pipefail
```

- `-e` – bricht bei jedem fehlschlagenden Kommando sofort ab.
- `-u` – unbekannte Variable = Fehler.
- `-o pipefail` – eine Pipe `a | b` schlägt fehl, wenn *irgendein* Glied fehlschlägt.

### Schritt 1 – kubeconfig auf den Docker-Netz-Namen umschreiben

`tools/bootstrap.sh:12`

```bash
KCFG=/tmp/kubeconfig
sed -E 's#server: https://[^/]+:6443#server: https://k3s-server:6443#' /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"
```

**Was ist eine kubeconfig?** Eine YAML-Datei, die `kubectl` sagt, *unter welcher URL* der
API-Server erreichbar ist und *mit welchen Zertifikaten* man sich ausweist. k3s schreibt sie
ins Volume `kubeconfig`.

**Das Problem:** Die Server-Adresse in der kubeconfig stimmt nur *innerhalb des
server-Containers*. `sed` ersetzt jede `https://<host>:6443` durch `https://k3s-server:6443` –
den Alias des Servers in `cluster-net`. Dass der TLS-Handshake mit diesem Namen klappt, liegt
an `--tls-san=k3s-server` ([trust-und-tls.md](trust-und-tls.md)).

> Dieselbe Umschreibung steht wortgleich in `tools/demo.sh`.

### Schritt 2 – Namespaces anlegen

`tools/bootstrap.sh:17`

```bash
kubectl apply -f /manifests/00-namespace.yaml
```

Legt `wif-demo` und `wif-publisher` an. Das muss vor Schritt 3 passieren, weil Secret und
ConfigMap in `wif-publisher` liegen.

### Schritt 3 – Client-Zertifikat und CA für den Publisher

`tools/bootstrap.sh:20`

```bash
kubectl -n wif-publisher create secret tls jwks-publisher-mtls \
    --cert=/publisher-tls/tls.crt --key=/publisher-tls/tls.key \
    --dry-run=client -o yaml | kubectl apply -f -
for namespace in wif-publisher wif-demo; do
    kubectl -n "$namespace" create configmap internal-ca \
        --from-file=ca.crt=/trust/ca.crt \
        --dry-run=client -o yaml | kubectl apply -f -
done
```

`create … --dry-run=client -o yaml | kubectl apply -f -` erzeugt das Objekt nur als YAML und
wendet es dann an – damit ist der Schritt idempotent. Im Publisher-Pod landen Secret unter
`/mtls` und ConfigMap unter `/trust`. In `wif-demo` brauchen die Demo-Pods die ConfigMap
(`/etc/internal-ca`), um Keycloak per TLS zu prüfen. In einem echten Cluster übernähme das cert-manager oder
die PKI-Anbindung der Plattform.

### Schritt 4 – Manifeste anwenden und warten

`tools/bootstrap.sh:30`

```bash
kubectl apply -f /manifests
kubectl -n wif-publisher rollout status deployment/jwks-publisher --timeout=180s
kubectl -n wif-demo rollout status deployment/consumer --timeout=180s
kubectl -n wif-demo rollout status deployment/reader --timeout=180s
kubectl -n wif-demo rollout status deployment/stranger --timeout=180s
```

- `00-namespace.yaml` – die beiden Namespaces (erneut, idempotent).
- `10-publisher.yaml` – ServiceAccount, ClusterRoleBinding, Skript-ConfigMap und Deployment
  des Publishers (siehe unten).
- `20-consumer.yaml` – ServiceAccount `consumer` und Deployment `consumer` mit zwei
  projizierten Tokens (`sa-token` mit `audience: wif-demo-validator`, `kc-token` mit dem
  Realm-Issuer als Audienz, je `expirationSeconds: 600`) und
  `automountServiceAccountToken: false`, damit der Pod nur diese Tokens besitzt.
- `30-authz-workloads.yaml` – ConfigMap `authz-client` (`access-token.sh`) und die Pods
  `reader` und `stranger` der Autorisierungs-Demo, siehe
  [autorisierungsserver.md](autorisierungsserver.md#workload-seite).

`rollout status` **blockiert**, bis die Deployments einen laufenden Pod haben (oder nach
180 s aufgeben).

---

## `jwks-publisher` – Veröffentlichung aus dem Cluster

Definiert in `manifests/10-publisher.yaml`.

| Objekt | Zweck |
|---|---|
| ServiceAccount `jwks-publisher` (`wif-publisher`) | Identität des Publishers gegenüber dem API-Server. |
| ClusterRoleBinding `jwks-publisher-issuer-discovery` | Bindet die eingebaute ClusterRole `system:service-account-issuer-discovery` – nur `GET` auf die zwei Discovery-Pfade. |
| ConfigMap `jwks-publisher-script` | Das Shell-Skript `publish.sh`. |
| Deployment `jwks-publisher` | `curlimages/curl`, eine Replik, hängt Skript (`/scripts`), Secret (`/mtls`) und CA (`/trust`) ein; `hostAliases`: `issuer-web` → `172.31.7.20`. |

Ablauf von `publish.sh`:

Eine **Schleife** alle `PUBLISH_INTERVAL_SECONDS` (15):

1. Discovery-Dokument und JWKS von `https://kubernetes.default.svc` holen, mit dem
   ServiceAccount-Token und der Cluster-CA aus `/var/run/secrets/kubernetes.io/serviceaccount`.
   Das Token geht über eine Header-Datei an `curl` (`-H @file`), nicht über die
   Kommandozeile.
2. Lesen, was `issuer-web` gerade öffentlich ausliefert (`PUBLIC_URL`, Default
   `https://issuer-web`, also `:443`).
3. SHA-256 über beide Stände bilden. Gleich → nichts tun.
4. Sonst per `curl -T` (`PUT`) an `PUBLISH_TARGET` (Default `https://issuer-web:8443`)
   hochladen: erst `/openid/v1/jwks`, dann `/.well-known/openid-configuration`.
   Client-Zertifikat `/mtls/tls.crt`, Serverprüfung gegen `/trust/ca.crt`.
   Log: `publisher: published JWKS sha256=<hash> kids=[ <neu> ] previous=[ <ausgeliefert> ]`.
5. Liefert `issuer-web` etwas aus, das der Publisher nicht selbst hochgeladen hat (fremder
   Upload, geleertes Volume), loggt er zusätzlich
   `publisher: WARNING issuer serves content this publisher did not upload ...` und stellt
   den Stand des Clusters wieder her.
6. Fehler beim Lesen oder Hochladen werden geloggt; der nächste Durchlauf versucht es neu.

Weil das JWKS des API-Servers sich bei einer Rotation ändert, erkennt der Publisher sie ohne
eigenen Mechanismus. Gegenüber `issuer-web` weist er sich **nie** mit einem
ServiceAccount-Token aus: Ein solches Token würde gegen genau die Schlüssel geprüft, die er
gerade veröffentlicht.

Log ansehen:

```bash
docker compose exec server kubectl -n wif-publisher logs deploy/jwks-publisher
```

---

## `tools/nginx-issuer.conf`

Wird in `issuer-web` als `/etc/nginx/conf.d/default.conf` eingehängt. Beide `server`-Blöcke
nutzen `root /oidc` – die Dokumente liegen im Volume `oidc-web` unter ihrem URL-Pfad
(`/oidc/.well-known/openid-configuration`, `/oidc/openid/v1/jwks`), sodass Lese- und
Schreibseite dieselbe Ablage teilen.

### Block 1 – Lesen (`:443`)

`tools/nginx-issuer.conf:14`

```nginx
server {
    listen 443 ssl;
    server_name issuer-web;

    ssl_certificate     /tls/tls.crt;
    ssl_certificate_key /tls/tls.key;

    root /oidc;

    location = /.well-known/openid-configuration {
        limit_except GET { deny all; }
        default_type application/json;
    }

    location = /openid/v1/jwks {
        limit_except GET { deny all; }
        default_type application/json;
    }

    location / {
        return 404;
    }
}
```

- **`listen 443 ssl`** auf allen Adressen – erreichbar aus `relying-net` (Validator) und aus
  `cluster-net` (der Publisher liest hier den veröffentlichten Stand).
- **Serverzertifikat** aus `issuer-tls`, ausgestellt von der internen CA.
- **`location = /pfad`** – nur die zwei bekannten OIDC-Pfade; alles andere `404`.
- **`limit_except GET { deny all; }`** – nur `GET` (und damit `HEAD`); ein `PUT` hier ergibt
  `403`.
- **`default_type application/json`** – die Dateien haben keine Endung; ohne diese Zeile fiele
  nginx auf `application/octet-stream` zurück. OIDC-Clients (und Nimbus) erwarten JSON.

### Block 2 – Upload (`:8443`, mTLS)

`tools/nginx-issuer.conf:38`

```nginx
server {
    listen 172.31.7.20:8443 ssl;
    server_name issuer-web;

    ssl_certificate         /tls/tls.crt;
    ssl_certificate_key     /tls/tls.key;
    ssl_client_certificate  /trust/ca.crt;
    ssl_verify_client       on;
    ssl_verify_depth        1;

    access_log /var/log/nginx/access.log upload;

    root /oidc;
    client_body_temp_path /oidc/.tmp;
    client_max_body_size  64k;

    location = /openid/v1/jwks {
        if ($publisher_ok = 0) { return 403; }
        limit_except PUT { deny all; }
        dav_methods PUT;
        create_full_put_path on;
        dav_access user:rw group:r all:r;
    }
    # ... derselbe Block für /.well-known/openid-configuration, sonst 404
}
```

| Direktive | Wirkung |
|---|---|
| `listen 172.31.7.20:8443` | nur auf der Adresse in `cluster-net` – aus `relying-net` nicht erreichbar |
| `ssl_client_certificate` + `ssl_verify_client on` | Client-Zertifikat ist Pflicht und muss von der internen CA stammen. Fehlt es oder stammt es von einer anderen CA, antwortet nginx mit `400`. |
| `ssl_verify_depth 1` | Kette höchstens Client → Root, keine Zwischen-CAs |
| `map $ssl_client_s_dn $publisher_ok` (auf `http`-Ebene) | Schreibrecht nur bei exakt dem DN `CN=jwks-publisher,O=WIF Lab`, sonst `403`. Ein exakter Vergleich statt einer Teilstring-Suche verhindert, dass `CN=jwks-publisher` in einem anderen DN-Feld (z. B. `O=x\,CN=jwks-publisher`) durchrutscht. |
| `limit_except PUT` | nur `PUT` auf die zwei Pfade |
| `dav_methods PUT`, `create_full_put_path on` | nginx speichert den Body als Datei unter dem Pfad und legt fehlende Verzeichnisse an |
| `client_max_body_size 64k` | Obergrenze für hochgeladene Dokumente |
| `access_log … upload` | Logformat mit `client_dn="$ssl_client_s_dn"` und `verify=$ssl_client_verify` |

`issuer-web` prüft den **Inhalt** der hochgeladenen Dokumente nicht. Wer das
Publisher-Zertifikat besitzt, kann jedes JWKS hochladen (siehe ADR 0003, Kompromisse).

### Healthcheck

`compose.yaml`, Dienst `issuer-web`:

```yaml
test: ["CMD", "test", "-s", "/oidc/openid/v1/jwks"]
```

`issuer-web` gilt als gesund, sobald das JWKS als nicht-leere Datei existiert – also nach dem
ersten Upload des Publishers. Erst dann startet der Validator.

Die Log-Zeile `can not modify /etc/nginx/conf.d/default.conf (read-only file system?)` beim
Start ist harmlos: Das Startskript des nginx-Images will die schreibgeschützt eingehängte
Config anpassen; diese Config braucht das nicht.

---

## Weiterlesen

- [architecture.md](architecture.md) – der ganze Stack, Netze und Startreihenfolge
- [trust-und-tls.md](trust-und-tls.md) – SAN, Hostname-Verification, mTLS, interne CA
- [validator.md](validator.md) – wie der Validator die Metadaten benutzt
- [build-und-betrieb.md](build-und-betrieb.md) – das `tools/`-Image, Rotation, häufige Probleme
- [../kubernetes-primer.md](../kubernetes-primer.md) – ServiceAccount, RBAC, Secret, projiziertes Token
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
