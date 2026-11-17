# Durchlauf: von `docker compose up` bis zum grünen Ende

**Für wen / was lernst du hier:** Dies ist die geführte Tour durch den PoC — von oben nach unten
einmal durchlesen und, wenn du willst, parallel selbst mittippen. Du brauchst **nur Docker mit
Compose v2** auf deinem Rechner, sonst nichts. Vorausgesetzt werden nur Grundkenntnisse zu JWT,
JWS und JWK; jeder Kubernetes-Begriff wird hier oder im
[Kubernetes-Primer](kubernetes-primer.md) erklärt.

Wenn du die Begriffe zuerst einordnen willst, lies vorab
[Das große Bild (`domain.md`)](domain.md). Wenn du gleich loslegen willst: hier entlang.

---

## 1. Was gleich passiert — in drei Sätzen

In einem Kubernetes-Cluster läuft ein Programm ("die Workload", hier ein simpler Pod). Es bekommt
vom Cluster einen kryptografisch signierten Ausweis (ein JWT, "ServiceAccount-Token") und schickt
diesen an einen Dienst **außerhalb** des Clusters ("den Validator"). Der Validator prüft den
Ausweis **offline** — nur mit öffentlichem Schlüsselmaterial, ohne beim Cluster zurückzufragen —
und lässt die Workload rein oder weist sie ab.

Das ist **Workload Identity Federation**: Ein System vertraut den Identitäten eines anderen
Systems, weil es dessen Signaturschlüssel kennt.

---

## 2. Die Beteiligten

| Container | Was es ist | Rolle im PoC |
|---|---|---|
| `pki-init` | Ein Wegwerf-Container mit `openssl` | Läuft **einmal**: spielt die interne PKI, erzeugt eine Lab-CA und die Zertifikate für `issuer-web`, Keycloak und den Publisher. |
| `sa-keys` | Dasselbe Wegwerf-Image | Erzeugt den Schlüssel, mit dem der Cluster Tokens signiert; rotiert ihn auf Zuruf. |
| `server` | k3s — ein vollständiges, aber leichtgewichtiges Kubernetes, das komplett in **einem** Container läuft | Der Cluster. Stellt die signierten Tokens aus. |
| `bootstrap` | Ein Wegwerf-Container mit `kubectl` | Läuft **einmal** beim Start: richtet den Cluster ein (Namespaces, Publisher-Zertifikat, Manifeste). Danach beendet er sich. |
| `issuer-web` | Ein nginx-Webserver | Liefert das OIDC-Discovery-Dokument und die öffentlichen Schlüssel (JWKS) unter `https://issuer-web` aus. Diese URL steht im `iss`-Feld jedes Tokens. Nimmt Uploads nur vom Publisher an. |
| `validator` | Ein kleiner Spring-Boot-Dienst (Java) | Der externe Dienst, der die Tokens prüft. **Spricht nur mit `issuer-web`, nie mit dem Cluster.** |
| `keycloak` | Keycloak (Autorisierungsserver) | Tauscht ServiceAccount-Tokens gegen Access-Tokens mit Scopes; Teil der Autorisierungs-Demo (`demo authz`). |
| `keycloak-gateway` | Ein nginx-Webserver | Einziger Weg der Pods zu Keycloak; lässt nur die Endpunkte des Realms `domain-rst` durch. |
| `service-r` | Ein Spring-Boot-Resource-Server (Java) | Dienst R: prüft Access-Tokens von Keycloak und schützt seine Endpunkte nach Scope. |
| `demo` | Nochmal das Wegwerf-Image mit `kubectl` | Wird nur auf Zuruf gestartet und fährt die Ende-zu-Ende-Prüfung. |

Dazu im Cluster die **Pods** `consumer` — das ist unsere Workload — und `jwks-publisher`,
der die öffentlichen Schlüssel des Clusters zu `issuer-web` bringt. Für die
Autorisierungs-Demo kommen `reader` und `stranger` dazu. Diese Tour folgt dem
Validator-Pfad; den Pfad über Keycloak zu `service-r` beschreibt
[features/keycloak-autorisierungsserver.md](features/keycloak-autorisierungsserver.md).

```
 cluster-net (172.31.7.0/24)
 ┌──────────────────────────────┐
 │ server (k3s)                 │      PUT, mTLS (CN=jwks-publisher)
 │  stellt Tokens aus           │
 │  Pod jwks-publisher ─────────┼──────────────────────────────►  issuer-web :8443
 │  Pod consumer                │                                 (nginx, Zertifikat
 └────┬─────────────────────────┘                                  der internen CA)
      │                                                           issuer-web :443
      │ Bearer-Token, GET /whoami                                       ▲
      │ workload-net (172.31.9.0/24)                                    │ GET Discovery + JWKS
      │                                                                 │ relying-net (172.31.8.0/24)
      └──────────────────────────────────────────────────►  validator (Spring Boot)
                                                             vertraut nur der internen CA
```

Merksatz: **Der Validator berührt den Kubernetes-API-Server nie** — er kann ihn über kein
Netz erreichen. Er kennt nur `issuer-web`.

---

## 3. Vorbereitung

```bash
git clone <dieses-repo>
cd k8s-workload-identity-federation-lab
cp .env.example .env
```

`.env` enthält nur Labor-Werte (ein Dummy-Cluster-Token, die Issuer-URL, der Host-Port des
Validators). `docker compose` liest die Datei automatisch. **Wichtig:** Wenn du das Repo nach
einem Update ziehst, `cp .env.example .env` erneut ausführen — eine veraltete `.env` mit falscher
`WIF_ISSUER`-URL ist die häufigste Fehlerquelle (der Validator würde dann den falschen
Server ansprechen).

---

## 4. `docker compose up -d --build`

Der erste Lauf baut zwei Images (`validator` und das Tool-Image für `pki-init`/`sa-keys`/
`bootstrap`/`demo`) und startet dann alles in der richtigen Reihenfolge. `--build` brauchst
du nur beim ersten Mal oder nach Codeänderungen. Der Befehl kehrt zurück, sobald die Container
gestartet sind; `docker compose ps` zeigt, wann `validator` auf `healthy` steht.

Die Startreihenfolge ist **nicht** zufällig — Compose kettet sie über `depends_on` und
Healthchecks:

```
pki-init      Exited (0)       ← Lab-CA und Zertifikate liegen bereit
sa-keys       Exited (0)       ← Signaturschlüssel des Clusters liegt bereit
server        Healthy          ← API-Server antwortet
issuer-web    Started          ← nginx läuft, liefert aber noch nichts aus
bootstrap     Exited (0)       ← Namespaces, Publisher-Zertifikat, Manifeste
issuer-web    Healthy          ← der Publisher hat das JWKS hochgeladen
validator     Healthy          ← /healthz ok
```

### 4a. `pki-init` — die Lab-PKI

Das Lab nimmt an, dass es eine **interne PKI** gibt, deren Root-Zertifikat auf allen
Systemen schon verteilt ist. `pki-init` (Skript: `tools/pki-init.sh`) spielt diese PKI:

```
pki-init: creating lab root CA
pki-init: issuing issuer-web serving certificate
pki-init: issuing jwks-publisher client certificate
pki-init: issuing negative-test material
pki-init: done
```

Es entstehen: eine Root-CA, das Serverzertifikat für `issuer-web`, das Client-Zertifikat für
den Publisher (`CN=jwks-publisher`) und Material für Negativtests (falscher CN, fremde CA).
Jedes Stück landet in einem eigenen Volume, damit jeder Container nur sieht, was er braucht;
den CA-Schlüssel sieht nur `pki-init` selbst. Beim nächsten `up` bleibt alles erhalten.

### 4b. `sa-keys` und `server` — der Cluster startet

`sa-keys` (Skript: `tools/sa-keys.sh`) legt den RSA-Schlüssel an, mit dem der Cluster seine
Tokens signiert. k3s bringt danach in ~30 s einen kompletten Ein-Knoten-Cluster hoch. Wichtig
sind die Flags, mit denen der API-Server gestartet wird (in `compose.yaml`):

```
--bind-address=172.31.7.2
--kube-apiserver-arg=service-account-issuer=https://issuer-web
--kube-apiserver-arg=service-account-jwks-uri=https://issuer-web/openid/v1/jwks
--kube-apiserver-arg=service-account-signing-key-file=/sa-keys/signing.key
--kube-apiserver-arg=service-account-key-file=/sa-keys/verify.pub
```

Damit legen wir fest: **Jedes Token, das dieser Cluster ausstellt, trägt `iss: https://issuer-web`**
— und wer die Schlüssel sucht, soll bei `https://issuer-web/openid/v1/jwks` nachsehen. Der
Cluster selbst hostet unter dieser Adresse *nichts*; das macht gleich `issuer-web`. Der
API-Server lauscht nur auf seiner Adresse im Netz `cluster-net`; der Validator hängt nicht
in diesem Netz.

### 4c. `bootstrap` — den Cluster einrichten

Dieser Container (Skript: `tools/bootstrap.sh`) arbeitet mit der Admin-Kubeconfig und
beendet sich danach:

```
bootstrap: creating namespaces
bootstrap: provisioning publisher client certificate and internal CA
bootstrap: applying lab manifests
deployment "jwks-publisher" successfully rolled out
deployment "consumer" successfully rolled out
bootstrap: done — jwks-publisher pushes discovery document + JWKS to issuer-web
```

1. **Namespaces anlegen**: `wif-demo` für die Workload, `wif-publisher` für den Publisher.
2. **Publisher ausstatten**: das Client-Zertifikat als Secret `jwks-publisher-mtls`, das
   Root-Zertifikat der CA als ConfigMap `internal-ca`. In einem echten Cluster übernähme das
   cert-manager oder die PKI-Anbindung der Plattform.
3. **Manifeste anwenden** (`kubectl apply -f /manifests`) und warten, bis `jwks-publisher`
   und `consumer` laufen. Ein *Manifest* ist eine YAML-Datei, die einen gewünschten Zustand
   beschreibt; `kubectl apply` sorgt dafür, dass der Cluster diesen Zustand herstellt.

`bootstrap` veröffentlicht selbst nichts — das ist Aufgabe des Publishers.

### 4d. `jwks-publisher` und `issuer-web` — die Schlüssel werden veröffentlicht

Der Publisher ist ein Pod im Cluster. Er liest Discovery-Dokument und JWKS mit seinem eigenen,
nur dafür berechtigten ServiceAccount vom API-Server und lädt sie per **mTLS** (er zeigt sein
Client-Zertifikat vor) zu `issuer-web` hoch. Danach prüft er alle 15 Sekunden, ob sich etwas
geändert hat. Sein Log (`docker compose exec server kubectl -n wif-publisher logs deploy/jwks-publisher`):

```
publisher: issuer serves nothing yet
publisher: published JWKS sha256=<hash> kids=[ <kid> ] previous=[ ]
```

`issuer-web` (nginx, `tools/nginx-issuer.conf`) hat zwei Listener:

- `https://issuer-web` (Port 443) → liefert `/.well-known/openid-configuration` und
  `/openid/v1/jwks` aus, nur lesend.
- `https://issuer-web:8443` → nimmt `PUT` auf genau diese zwei Pfade an, nur auf der Adresse
  im Cluster-Netz und nur mit einem Client-Zertifikat der internen CA mit
  `CN=jwks-publisher`. Jeder Upload landet mit dem DN des Clients im Log.

Sobald das JWKS da ist, meldet der Healthcheck `issuer-web` als gesund. Warum der
Schreibweg so eng ist, steht in
[ADR 0003](adr/0003-getrennte-vertrauensbereiche-interne-pki.md).

Die Log-Zeile `can not modify /etc/nginx/conf.d/default.conf (read-only file system?)` ist
**harmlos** — nginx' Standard-Startskript will unsere (bewusst schreibgeschützt gemountete)
Config anfassen; unsere Config braucht die Änderung nicht.

### 4e. `validator` — der externe Prüfdienst

```
validator: waiting for the internal CA certificate at /trust/ca.crt ...
validator: internal CA certificate present after 0s, starting

 :: Spring Boot ::                (v4.1.2)

INFO  m.r.w.JwksTrustConfig : OIDC discovery for https://issuer-web resolved JWKS at https://issuer-web/openid/v1/jwks
INFO  m.r.w.WifPocApplication : Started WifPocApplication in 1.721 seconds
```

Beim Start:

1. Das Entrypoint-Skript wartet, bis `/trust/ca.crt` (das Root-Zertifikat der internen CA)
   vorhanden ist.
2. `JwksTrustConfig` baut einen **Truststore nur mit dieser CA**. Damit akzeptiert der
   Validator ausschließlich Serverzertifikate der internen PKI.
3. Der Validator macht **OIDC-Discovery**: Er holt `https://issuer-web/.well-known/openid-configuration`,
   prüft, dass das Feld `issuer` exakt `https://issuer-web` ist, und liest `jwks_uri` aus. Genau
   das sagt die Log-Zeile oben.
4. Von der `jwks_uri` lädt er die Schlüssel (gecacht, 5 Minuten) und ist bereit.

Der Validator hängt nur in `relying-net` (zu `issuer-web`) und `workload-net` (für die Pods)
und teilt kein Volume mit der Cluster-Seite. Details zur Java-Seite:
[`technical/validator.md`](technical/validator.md) und
[`technical/trust-und-tls.md`](technical/trust-und-tls.md).

---

## 5. `docker compose run --rm demo`

Jetzt der eigentliche Beweis. `demo` (Skript: `tools/demo.sh`) läuft in **einem** Durchlauf durch
sieben Schritte (0–6). Compose stellt vorher sicher, dass `validator` und seine
Abhängigkeiten laufen. Der `demo`-Container hängt in `cluster-net` (für `kubectl` und die
Upload-Tests) und in `relying-net` (für `issuer-web` und den Validator).

### Schritt 0 — Was der Issuer-Endpoint anbietet

```
GET https://issuer-web/.well-known/openid-configuration
{
  "issuer": "https://issuer-web",
  "jwks_uri": "https://issuer-web/openid/v1/jwks",
  "id_token_signing_alg_values_supported": [ "RS256" ]
}
```

Das *OIDC-Discovery-Dokument*: eine kleine JSON-Datei an einer festen Adresse
(`/.well-known/openid-configuration`), die sagt „ich bin der Issuer `https://issuer-web`, meine
Schlüssel findest du unter `jwks_uri`, ich signiere mit RS256". Ein Prüfer muss so nur die
Issuer-URL kennen und findet den Rest selbst.

### Schritt 1 — Die öffentlichen Schlüssel (JWKS)

```
{
  "kid": "VZPPD_y4Q6BvLjaPyZM_0RHm-Y9y1IAmKjHb9EQUXI8",
  "kty": "RSA",
  "alg": "RS256",
  "use": "sig"
}
```

Ein *JWKS* (JSON Web Key Set) ist eine Liste öffentlicher Schlüssel. Jeder hat eine `kid`
(Key-ID). Nur der **private** Gegenpart (im Cluster, streng gehütet) kann Tokens signieren; mit
dem hier gezeigten **öffentlichen** Schlüssel kann jeder die Signatur *prüfen*.

### Schritt 2 — Ein Token ausstellen und ansehen

Das Skript lässt sich vom Cluster ein Token für die Audience `wif-demo-validator` geben und
dekodiert dessen Payload:

```json
{
  "aud": [ "wif-demo-validator" ],
  "exp": 1788971209,
  "iat": 1788970609,
  "iss": "https://issuer-web",
  "jti": "373c6f8f-...",
  "kubernetes.io": {
    "namespace": "wif-demo",
    "serviceaccount": { "name": "consumer", "uid": "..." }
  },
  "nbf": 1788970609,
  "sub": "system:serviceaccount:wif-demo:consumer"
}
```

- `iss` — der Aussteller. Genau die URL, die wir dem Cluster als `service-account-issuer` gegeben
  haben.
- `aud` — für wen das Token bestimmt ist. Der Validator akzeptiert **nur** genau
  `wif-demo-validator`.
- `sub` — wer die Workload ist: `system:serviceaccount:<namespace>:<name>`.
- `exp` / `iat` / `nbf` — gültig bis / ausgestellt am / nicht vor (Unix-Zeit). Hier: 600 Sekunden
  Lebensdauer.
- `kubernetes.io` — Zusatzinfos: Namespace, ServiceAccount, (im echten Pod-Token auch Pod und
  Node).

Der Header des Tokens (hier nicht gezeigt) enthält `alg: RS256` und die `kid` — dieselbe `kid`
wie in Schritt 1. So weiß der Validator, welchen Schlüssel aus dem JWKS er zum Prüfen nehmen muss.

### Schritt 3 — Der Pod ruft den Validator (Gutfall)

Das ist der Kern. Das Skript führt **im `consumer`-Pod** ein `curl` aus:

```
pod consumer-7599bd45b8-skn4j  ->  http://validator.wif.local:8080/whoami
HTTP 200
PASS: pod token accepted (200)
```

Antwort des Validators:

```json
{
  "authenticated": true,
  "sub": "system:serviceaccount:wif-demo:consumer",
  "iss": "https://issuer-web",
  "aud": "wif-demo-validator",
  "exp": 1788971157,
  "kubernetes.io": { "namespace": "wif-demo", "pod": { "name": "consumer-..." }, ... }
}
```

Was hier passiert ist:

1. Der Pod liest sein Token aus der Datei `/var/run/secrets/tokens/sa-token`. Dorthin hat es das
   **kubelet** (der Kubernetes-Agent auf dem Knoten) gelegt — über ein *projected volume*, das
   im Pod-Manifest (`manifests/20-consumer.yaml`) mit `audience: wif-demo-validator` und
   `expirationSeconds: 600` konfiguriert ist. Das kubelet erneuert das Token automatisch vor
   Ablauf.
2. Der Pod schickt es als `Authorization: Bearer <token>` an `http://validator.wif.local:8080`.
   Diesen Namen kennt der Cluster-DNS nicht (der Validator ist ja außerhalb) — deshalb steht im
   Pod-Manifest ein `hostAliases`-Eintrag, der `validator.wif.local` fest auf die IP
   `172.31.9.10` zeigt. Genau diese IP hat der Validator-Container im Netz `workload-net`.
3. Der Validator nimmt das Bearer-Token, wählt per `kid` den passenden Schlüssel aus dem
   gecachten JWKS, prüft die **Signatur**, prüft `iss == https://issuer-web`, prüft
   `aud` enthält `wif-demo-validator`, prüft `exp`/`nbf` (mit 60 s Toleranz). Alles grün →
   **HTTP 200** plus die Claims.

### Schritte 4 & 5 — Absichtlich kaputte Fälle

```
== 4. negative: wrong audience  ->  rejected ==
HTTP 401
{ "reason": "JWT aud claim rejected", "error": "token_rejected" }
PASS

== 5. negative: tampered signature  ->  rejected ==
HTTP 401
{ "reason": "Signed JWT rejected: Invalid signature", "error": "token_rejected" }
PASS
```

- **Falsche Audience:** Ein Token, das für `not-this-service` ausgestellt wurde. Signatur ok,
  aber `aud` passt nicht → abgelehnt. Das ist der Schutz gegen den „confused deputy": ein Token,
  das die Workload einem *anderen* Dienst gegeben hat, taugt hier nicht.
- **Manipulierte Signatur:** Das letzte Zeichen eines gültigen Tokens wird verändert. Die
  Signatur passt nicht mehr zum Inhalt → abgelehnt.

### Schritt 6 — Fremde Uploads werden abgewiesen

```
== 6. negative: JWKS upload without a valid publisher certificate  ->  rejected ==
PUT https://issuer-web:8443/openid/v1/jwks  without client certificate
HTTP 400
PUT ... with a client certificate from a foreign CA
HTTP 400
PUT ... with an internal-CA certificate for CN=not-the-publisher
HTTP 403
PUT ... with an internal-CA certificate hiding CN=jwks-publisher in the O field
HTTP 403
PUT https://issuer-web/openid/v1/jwks  (public read listener)
HTTP 403
PASS: published JWKS untouched
```

Wer das JWKS austauschen könnte, könnte sich beliebige gültige Tokens ausstellen. Deshalb
versucht das Skript, ein leeres JWKS hochzuladen: ohne Client-Zertifikat, mit einem
Zertifikat einer fremden CA, mit einem Zertifikat der richtigen CA, aber falschem Namen, mit
einem, das `CN=jwks-publisher` im Feld `O` versteckt, und
über den öffentlichen Lese-Listener. Alles wird abgewiesen, und das veröffentlichte JWKS
enthält danach weiterhin die Schlüssel des Clusters.

**Echtes Ablaufen** (`exp` in der Vergangenheit) lässt sich nicht schnell zeigen: Die
Kubernetes-TokenRequest-API stellt keine Tokens mit weniger als **10 Minuten** Laufzeit aus. Mit
`DEMO_EXPIRY=1 docker compose run --rm demo` hängt das Skript einen Schritt 7 an, der ein
10-Minuten-Token mintet und `/whoami` so lange pollt, bis es von `200` auf `401` kippt.

### Abschluss

```
== result ==
PASS: phase 'all': all checks passed
```

### Alles auf einmal: `tools/run-all-checks.sh`

Auf dem Host (braucht nur `docker compose`) fährt `tools/run-all-checks.sh` den Stack hoch und
prüft nacheinander:

1. die Demo von oben und die Autorisierungs-Demo (`demo authz`),
2. die **Netztrennung**: Validator, `service-r` und Keycloak erreichen weder den API-Server
   (`172.31.9.2:6443`, `172.31.7.2:6443`) noch den Upload-Listener (`172.31.8.20:8443`,
   bei Keycloak zusätzlich `172.31.7.20:8443`),
3. dass ein Validator mit **fremder CA** (`validator-foreign-ca`) nicht startet,
4. eine **Schlüsselrotation**: Token vor der Rotation prägen (`demo pre-rotation`),
   `sa-keys rotate`, API-Server neu starten, warten, bis der Publisher die neue `kid`
   veröffentlicht hat, dann prüfen, dass neue und alte Tokens angenommen werden und
   Keycloak eine Client-Assertion mit der neuen `kid` annimmt (`demo post-rotation`).

```
PASS: all lab checks passed
```

---

## 6. Selbst nachsehen

Der Stack läuft noch (`docker compose ps`). Ein paar nützliche Blicke:

```bash
# Discovery-Dokument, wie es der Validator sieht (validator hat curl + die interne CA gemountet)
docker compose exec validator curl -s --cacert /trust/ca.crt https://issuer-web/.well-known/openid-configuration

# Wer hat was von issuer-web geholt oder hochgeladen?
docker compose logs issuer-web | grep -E 'GET|PUT'

# Was hat der Publisher veröffentlicht?
docker compose exec server kubectl -n wif-publisher logs deploy/jwks-publisher

# Das Token direkt aus dem Pod
POD=$(docker compose exec server kubectl -n wif-demo get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
docker compose exec server kubectl -n wif-demo exec "$POD" -- cat /var/run/secrets/tokens/sa-token

# Validator direkt vom Host anfragen (ohne Token -> 401)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/whoami
curl -s http://localhost:18080/healthz
```

Im nginx-Log siehst du, wer mit `issuer-web` spricht: der Validator von `172.31.8.10` aus
(nur `GET`), der Publisher aus dem Cluster-Netz (`PUT` auf `:8443`, im Log mit
`client_dn="CN=jwks-publisher,O=WIF Lab"` und `verify=SUCCESS`). Den API-Server spricht der
Validator nie an — er hat gar keine Route dorthin.

---

## 7. Kaputtmachen zum Lernen

- **Fremde CA:** `docker compose run --rm validator-foreign-ca` startet einen zweiten
  Validator, der einer anderen CA vertraut. Er stirbt beim Start mit
  `PKIX path building failed`. → Warum: sein Truststore enthält nur die fremde CA, das
  Serverzertifikat von `issuer-web` stammt aber von der internen.
- **Audience im Pod ändern:** In `manifests/20-consumer.yaml` die `audience` auf etwas anderes
  setzen, `docker compose down -v && docker compose up -d`. Der Gutfall in Schritt 3
  wird dann zu einem 401 („JWT aud claim rejected").
- **Rotation ohne Publisher:** Publisher anhalten
  (`docker compose exec server kubectl -n wif-publisher scale deploy/jwks-publisher --replicas=0`),
  dann `docker compose run --rm sa-keys rotate` und `docker compose restart server`. Neue
  Tokens tragen eine `kid`, die `issuer-web` nicht kennt — der Validator lehnt sie mit 401 ab.
  Publisher wieder auf `--replicas=1` setzen: Er lädt das neue JWKS hoch, und die neuen
  Tokens werden angenommen.

---

## 8. Aufräumen

```bash
docker compose down -v
```

`-v` entfernt auch alle Named Volumes (Cluster-Zustand, Signaturschlüssel, PKI, ausgelieferte
Metadaten, Demo-Zustand). Der nächste `up` beginnt komplett frisch (neuer Cluster, neue CA,
neue Zertifikate, neue Schlüssel).

---

## Weiterlesen

- [Das große Bild — Konzepte & Vokabular](domain.md)
- [Kubernetes-Primer — nur die Bausteine, die hier vorkommen](kubernetes-primer.md)
- [Der Ablauf als Use Case](use-cases.md)
- [Technik: Architektur des Compose-Stacks](technical/architecture.md)
- [Technik: PKI, Publisher und Issuer-Endpoint](technical/bootstrap-und-issuer.md)
- [Technik: der Validator im Detail](technical/validator.md)
- [Technik: Vertrauen & TLS](technical/trust-und-tls.md)
- [Entscheidung: Offline-JWKS statt TokenReview](adr/0001-offline-jwks-statt-tokenreview.md)
- [Entscheidung: getrennte Vertrauensbereiche, interne PKI](adr/0003-getrennte-vertrauensbereiche-interne-pki.md)
