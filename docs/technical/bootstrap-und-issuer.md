# Bootstrap und Aussteller-Endpunkt

**Für wen / was lernst du hier:** Du kennst JWT/JWKS, aber nicht Kubernetes-Werkzeuge wie
`kubectl` oder OpenSSL-Aufrufe. Diese Seite geht `tools/bootstrap.sh` Schritt für Schritt
durch – die kubeconfig-Umschreibung, das Erzeugen eines self-signed Zertifikats, das
Herauskopieren von Discovery-Dokument und JWKS – und erklärt danach die nginx-Konfiguration
`tools/nginx-issuer.conf`.

---

## Was der Bootstrap leisten muss

Der Kubernetes-API-Server *kann* selbst ein OIDC-Discovery-Dokument und ein JWKS ausliefern
(unter `/.well-known/openid-configuration` und `/openid/v1/jwks`). In einem echten
Federation-Setup will man aber, dass diese Metadaten von einem **stabilen, öffentlichen
Endpunkt** kommen, der nicht der API-Server ist – der API-Server ist oft privat, wechselt
Adressen und soll nicht von Fremddiensten angesprochen werden.

Das Lab bildet das nach: `bootstrap` kopiert die Metadaten *einmal* aus dem Cluster in ein
Volume, und der nginx-Service `issuer-web` liefert sie von dort aus. Der Validator redet
danach nur mit `issuer-web`.

`bootstrap` läuft als Einmal-Container (`compose.yaml:53`), nachdem der `server` gesund ist,
und wird bei jedem `docker compose up` erneut ausgeführt.

---

## `tools/bootstrap.sh` Schritt für Schritt

### Kopf: strikte Fehlerbehandlung

`tools/bootstrap.sh:7`

```bash
set -euo pipefail
```

- `-e` – bricht bei jedem fehlschlagenden Kommando sofort ab.
- `-u` – unbekannte Variable = Fehler.
- `-o pipefail` – eine Pipe `a | b` schlägt fehl, wenn *irgendein* Glied fehlschlägt.

Zusammen: Das Skript läuft entweder sauber durch oder endet mit einem Fehler-Exit-Code – und
dann startet `issuer-web` wegen `service_completed_successfully` gar nicht erst.

### Schritt 1 – kubeconfig auf den Docker-Netz-Namen umschreiben

`tools/bootstrap.sh:9`

```bash
KCFG=/tmp/kubeconfig
sed -e 's#https://127.0.0.1:6443#https://k3s-server:6443#' \
    -e 's#https://0.0.0.0:6443#https://k3s-server:6443#' \
    /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"
```

**Was ist eine kubeconfig?** Eine YAML-Datei, die `kubectl` sagt: *unter welcher URL* der
API-Server erreichbar ist und *mit welchen Zertifikaten* man sich ausweist. k3s schreibt sie
ins Volume `kubeconfig` (`compose.yaml:35`).

**Das Problem:** k3s trägt die Server-Adresse als `https://127.0.0.1:6443` ein – also
"localhost". Das stimmt *innerhalb des server-Containers*, aber nicht im `bootstrap`-Container:
dort wäre `127.0.0.1` der Bootstrap-Container selbst.

**Die Lösung:** `sed` ersetzt die Adresse durch `https://k3s-server:6443` – den Docker-Netz-
Alias des Servers (`compose.yaml:42`). Port `6443` ist der Standard-Port des Kubernetes-API-
Servers. Die umgeschriebene Kopie landet in `/tmp/kubeconfig`, und `export KUBECONFIG=…` sagt
allen folgenden `kubectl`-Aufrufen, diese Datei zu benutzen.

Dass der TLS-Handshake mit dem neuen Namen `k3s-server` klappt, liegt am Flag
`--tls-san=k3s-server` des Servers (`compose.yaml:26`) – dazu [trust-und-tls.md](trust-und-tls.md).

> Dieselbe Umschreibung steht wortgleich in `tools/demo.sh:13`.

### Schritt 2 – Lab-Manifeste anwenden

`tools/bootstrap.sh:15`

```bash
kubectl apply -f /manifests
kubectl -n wif-demo rollout status deployment/consumer --timeout=120s
```

- `kubectl apply -f /manifests` – wendet **alle** YAML-Dateien im Verzeichnis an (per Bind
  Mount aus `./manifests`, `compose.yaml:62`). Das sind:
  - `00-namespace.yaml` – legt den Namespace `wif-demo` an (ein Namespace ist ein logischer
    Ordner im Cluster).
  - `20-consumer.yaml` – ein **ServiceAccount** `consumer` (die Maschinen-Identität) und ein
    **Deployment** `consumer` (eine verwaltete Pod-Instanz), das ein *projiziertes*
    ServiceAccount-Token mit `audience: wif-demo-validator` und `expirationSeconds: 600` in den
    Pod einhängt.
- `kubectl … rollout status deployment/consumer` – **blockiert**, bis das Deployment wirklich
  einen laufenden Pod hat (oder nach 120 s aufgibt). So ist sichergestellt, dass die
  Demo später einen Pod zum `exec` findet.

**Warum `automountServiceAccountToken: false` im Manifest?** Damit Kubernetes *nicht*
zusätzlich das Standard-Token (mit `aud` = API-Server) einhängt. Der Pod soll nur das eine,
bewusst auf `wif-demo-validator` ausgestellte Token besitzen.

### Schritt 3 – ein self-signed Serverzertifikat für `issuer-web` erzeugen

`tools/bootstrap.sh:19`

```bash
if [ ! -s /oidc/tls.crt ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /oidc/tls.key -out /oidc/tls.crt \
        -subj "/CN=issuer-web" -addext "subjectAltName=DNS:issuer-web"
fi
```

**Was ist ein self-signed Zertifikat?** Normalerweise unterschreibt eine
**Certificate Authority (CA)** ein Serverzertifikat, und Clients vertrauen der CA. Ein
*self-signed* ("selbstsigniertes") Zertifikat unterschreibt sich mit seinem eigenen Schlüssel
selbst – es ist zugleich Zertifikat und (implizite) CA. Kein öffentlicher Client vertraut ihm
automatisch; man muss es explizit ins Vertrauen aufnehmen. Genau das tut der Validator (siehe
[trust-und-tls.md](trust-und-tls.md)).

Die `openssl req`-Optionen:

| Option | Bedeutung |
|---|---|
| `-x509` | Erzeuge ein fertiges Zertifikat, nicht nur einen Signieranfrage-Request (CSR). |
| `-newkey rsa:2048` | Erzeuge zugleich einen neuen 2048-Bit-RSA-Schlüssel. |
| `-nodes` | "no DES" – privaten Schlüssel **nicht** mit Passwort verschlüsseln (nginx soll ihn ohne Eingabe lesen). |
| `-days 3650` | 10 Jahre gültig. |
| `-keyout /oidc/tls.key` / `-out /oidc/tls.crt` | Zielpfade für Schlüssel und Zertifikat – beide im geteilten Volume `oidc-web`. |
| `-subj "/CN=issuer-web"` | Setzt den Common Name, damit `openssl` nicht interaktiv nachfragt. |
| `-addext "subjectAltName=DNS:issuer-web"` | **Der wichtige Teil.** |

**Warum `subjectAltName=DNS:issuer-web`?** Moderne TLS-Clients (auch die Java-Bibliothek
Nimbus, die der Validator nutzt) prüfen bei der **Hostname-Verification** den angefragten
Hostnamen ausschließlich gegen die **SAN**-Liste (Subject Alternative Name) des Zertifikats –
der veraltete `CN` zählt dafür nicht mehr. Der Validator ruft `https://issuer-web/...` auf,
also **muss** `issuer-web` als SAN im Zertifikat stehen, sonst scheitert der Handshake mit
"No subject alternative DNS name matching issuer-web found".

**Warum die Guard-Bedingung `if [ ! -s /oidc/tls.crt ]`?** `-s` heißt "Datei existiert und ist
nicht leer". Da `bootstrap` bei jedem `up` läuft, würde ein neues Zertifikat bei jedem Start
das alte ersetzen. Der Guard sorgt dafür, dass das Zertifikat **nur einmal** erzeugt wird und
über Neustarts hinweg stabil bleibt (solange das Volume `oidc-web` nicht mit `down -v`
gelöscht wird). Stabil heißt: `issuer-web` und `validator` müssen nicht bei jedem `up` neu
aufeinander abgestimmt werden.

### Schritt 4 – Discovery-Dokument und JWKS aus dem Cluster kopieren

`tools/bootstrap.sh:26`

```bash
kubectl get --raw /.well-known/openid-configuration > /oidc/openid-configuration.json
kubectl get --raw /openid/v1/jwks                   > /oidc/jwks.json
```

`kubectl get --raw <pfad>` ruft einen HTTP-Pfad direkt am API-Server ab und gibt die
**rohe** Antwort aus – hier JSON. Das läuft über die Admin-kubeconfig, also mit voller
Cluster-Berechtigung; ein Fremddienst hätte diesen Zugriff nicht.

- `/.well-known/openid-configuration` → das OIDC-Discovery-Dokument. Weil der API-Server mit
  `service-account-issuer=https://issuer-web` gestartet wurde, steht dort bereits
  `"issuer": "https://issuer-web"` und `"jwks_uri": "https://issuer-web/openid/v1/jwks"` –
  **es muss nichts umgeschrieben werden**, die Dateien werden 1:1 abgelegt.
- `/openid/v1/jwks` → das JWK Set mit den öffentlichen ServiceAccount-Signaturschlüsseln von
  k3s (RSA, `RS256`). Diese Schlüssel sind die eigentliche Vertrauenswurzel für die
  Token-Prüfung.

Beide Dateien landen im Volume `oidc-web`, aus dem `issuer-web` (und lesend auch `validator`)
sie sieht.

### Schritt 5 – Abschluss

`tools/bootstrap.sh:32`

```bash
echo "bootstrap: done — ..."
cat /oidc/openid-configuration.json
```

Gibt das kopierte Discovery-Dokument ins Log aus (nützlich für `docker compose logs
bootstrap`) und endet mit Exit 0. Genau darauf wartet `issuer-web` per
`service_completed_successfully`.

---

## `tools/nginx-issuer.conf`

Diese Datei wird in den `issuer-web`-Container als `/etc/nginx/conf.d/default.conf` eingehängt
(`compose.yaml:76`). Sie enthält **zwei** `server`-Blöcke.

### Block 1 – der HTTPS-Aussteller

`tools/nginx-issuer.conf:6`

```nginx
server {
    listen 443 ssl;
    server_name issuer-web;

    ssl_certificate     /oidc/tls.crt;
    ssl_certificate_key /oidc/tls.key;

    location = /.well-known/openid-configuration {
        default_type application/json;
        alias /oidc/openid-configuration.json;
    }

    location = /openid/v1/jwks {
        default_type application/json;
        alias /oidc/jwks.json;
    }

    location / {
        return 404;
    }
}
```

- **`listen 443 ssl`** – HTTPS auf dem Standard-Port. `ssl_certificate` / `ssl_certificate_key`
  zeigen auf die von `bootstrap` erzeugten Dateien im geteilten Volume.
- **`location = /pfad`** – das `=` bedeutet "exakt dieser Pfad, nichts anderes". Nur die zwei
  bekannten OIDC-Pfade werden bedient.
- **`alias /oidc/...json`** – liefert diese Datei aus dem Volume als Antwort.
- **`default_type application/json`** – **notwendig**, weil die Dateien `openid-configuration.json`
  bzw. `jwks.json` heißen, aber unter *endungslosen* URLs (`/.well-known/openid-configuration`,
  `/openid/v1/jwks`) ausgeliefert werden. nginx rät den `Content-Type` sonst aus der URL-Endung;
  ohne Endung fiele es auf `application/octet-stream` zurück. `default_type` erzwingt
  `Content-Type: application/json`, was OIDC-Clients (und Nimbus) erwarten.
- **`location / { return 404; }`** – alles andere gibt es hier nicht.

### Block 2 – der Plain-HTTP-Healthcheck

`tools/nginx-issuer.conf:29`

```nginx
server {
    listen 80;
    location = /healthz {
        return 200 "ok\n";
    }
}
```

Ein getrennter Klartext-HTTP-Server nur für den Docker-Healthcheck. Warum nicht den
HTTPS-Endpunkt prüfen? Weil das Healthcheck-Tool im Alpine-Image das minimalistische
busybox-`wget` ist, das self-signed Zertifikate nicht ohne Weiteres akzeptiert. Ein
Klartext-`/healthz` ist einfacher und für einen reinen Lebendigkeitstest ausreichend.

### Die IPv6- / `127.0.0.1`-Falle

Der Healthcheck (`compose.yaml:85`) lautet:

```yaml
test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1/healthz"]
```

Mit `http://localhost/healthz` würde das busybox-`wget` den Namen `localhost` zuerst zu der
IPv6-Adresse `::1` auflösen. nginx lauscht hier aber nur auf IPv4 (`listen 80` ohne
`[::]:80`), sodass die Verbindung zu `::1` scheitert und `wget` – je nach busybox-Version –
den Fehler nicht sauber auf IPv4 zurückfällt. Die **literale** IPv4-Adresse `127.0.0.1`
umgeht die Namensauflösung komplett und trifft nginx direkt. Deshalb im Healthcheck bewusst
`127.0.0.1` statt `localhost`.

---

## Weiterlesen

- [architecture.md](architecture.md) – der ganze Stack und die Startreihenfolge
- [trust-und-tls.md](trust-und-tls.md) – SAN, Hostname-Verification, warum der Validator dem
  self-signed Zertifikat vertraut
- [validator.md](validator.md) – wie der Validator die kopierten Metadaten benutzt
- [build-und-betrieb.md](build-und-betrieb.md) – das `tools/`-Image und häufige Probleme
- [../kubernetes-primer.md](../kubernetes-primer.md) – ServiceAccount, Deployment, projiziertes Token
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
