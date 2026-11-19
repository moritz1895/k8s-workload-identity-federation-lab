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
| `pki-init` | Ein Wegwerf-Container mit `openssl` | Läuft **einmal**: spielt die interne PKI, erzeugt eine Lab-CA und die Serverzertifikate für den Issuer-Ingress (`issuer.wif.local`), den Validator, Keycloak und `service-r`. |
| `sa-keys` | Dasselbe Wegwerf-Image | Erzeugt den Schlüssel, mit dem der Cluster Tokens signiert; wechselt ihn auf Zuruf in zwei Phasen (`stage`, `activate`); im Notfall entfernt `retire` den vorherigen Schlüssel sofort. |
| `server` | k3s — ein vollständiges, aber leichtgewichtiges Kubernetes, das komplett in **einem** Container läuft | Der Cluster samt Ingress-Controller Traefik. Stellt die signierten Tokens aus. |
| `bootstrap` | Ein Wegwerf-Container mit `kubectl` | Läuft **einmal** beim Start: richtet den Cluster ein (Namespaces, Ingress-Zertifikat, Manifeste). Danach beendet er sich. |
| `ingress-lb` | Ein nginx im TCP-Modus | Stellvertreter des Load Balancers vor dem Cluster: reicht Port 443 aus `relying-net` an Traefik weiter. Der einzige Weg der Relying Parties in den Cluster. |
| `validator` | Ein kleiner Spring-Boot-Dienst (Java) | Der externe Dienst, der die Tokens prüft. **Erreicht vom Cluster nur `https://issuer.wif.local`, nie den API-Server.** |
| `keycloak` | Keycloak (Autorisierungsserver) | Tauscht ServiceAccount-Tokens gegen Access-Tokens mit Scopes; Teil der Autorisierungs-Demo (`demo authz`). |
| `keycloak-gateway` | Ein nginx-Webserver | Einziger Weg der Pods zu Keycloak; lässt nur die Endpunkte des Realms `domain-rst` durch. |
| `service-r` | Ein Spring-Boot-Resource-Server (Java) | Dienst R: prüft Access-Tokens von Keycloak und schützt seine Endpunkte nach Scope. |
| `demo` | Nochmal das Wegwerf-Image mit `kubectl` | Wird nur auf Zuruf gestartet und fährt die Ende-zu-Ende-Prüfung. |

Dazu im Cluster die **Pods** `consumer` — das ist unsere Workload — und `issuer` (zwei
Replikas im Namespace `wif-issuer`). Der Issuer-Pod spiegelt Discovery-Dokument und JWKS
vom API-Server und liefert sie hinter dem Ingress unter `https://issuer.wif.local` aus;
diese URL steht im `iss`-Feld jedes Tokens. Für die Autorisierungs-Demo kommen `reader`
und `stranger` dazu. Diese Tour folgt dem Validator-Pfad; den Pfad über Keycloak zu
`service-r` beschreibt
[features/keycloak-autorisierungsserver.md](features/keycloak-autorisierungsserver.md).

```
 cluster-net (172.31.7.0/24)
 ┌──────────────────────────────────────────┐
 │ server (k3s), API-Server nur hier        │
 │  stellt Tokens aus                       │
 │  ┌ Namespace wif-issuer ───────────────┐ │
 │  │ Pod issuer: sync ── GET ─► API-Server│ │
 │  │             web (nur GET)  ◄─┐       │ │
 │  └──────────────────────────────┼──────┘ │
 │  Traefik (Ingress issuer.wif.local) ─┘   │
 │   Node-Port 30443, nur in cluster-net    │
 │  Pod consumer                            │
 └────┬───────────────────────────▲─────────┘
      │                           │ TCP 443 durchgereicht (TLS endet im Cluster)
      │                      ingress-lb (Stellvertreter des Load Balancers)
      │                           ▲
      │                           │ GET Discovery + JWKS, relying-net (172.31.8.0/24)
      │ Bearer-Token, GET /whoami │
      │ workload-net              │
      │ (172.31.9.0/24)           │
      └──────────────────►  validator (Spring Boot), vertraut nur der internen CA
```

Merksatz: **Der Validator berührt den Kubernetes-API-Server nie** — er kann ihn über kein
Netz erreichen. Er kennt nur `https://issuer.wif.local`.

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

Der erste Lauf baut die Images (`validator`, `service-r` und das Tool-Image für
`pki-init`/`sa-keys`/`bootstrap`/`demo`) und startet dann alles in der richtigen
Reihenfolge. `--build` brauchst du nur beim ersten Mal oder nach Codeänderungen. Der Befehl
kehrt zurück, sobald die Container gestartet sind; `docker compose ps` zeigt, wann
`validator` auf `healthy` steht.

Die Startreihenfolge ist **nicht** zufällig — Compose kettet sie über `depends_on` und
Healthchecks:

```
pki-init      Exited (0)       ← Lab-CA und Zertifikate liegen bereit
sa-keys       Exited (0)       ← Signaturschlüssel des Clusters liegt bereit
server        Healthy          ← API-Server antwortet
bootstrap     Exited (0)       ← Namespaces, Ingress-Zertifikat, Manifeste; Issuer-Pod und Traefik laufen
ingress-lb    Healthy          ← https://issuer.wif.local liefert das JWKS über den Ingress
validator     Healthy          ← /healthz ok
```

Keycloak, `keycloak-gateway` und `service-r` starten parallel dazu; Keycloak wartet ebenfalls
auf `ingress-lb`.

### 4a. `pki-init` — die Lab-PKI

Das Lab nimmt an, dass es eine **interne PKI** gibt, deren Root-Zertifikat auf allen
Systemen schon verteilt ist. `pki-init` (Skript: `tools/pki-init.sh`) spielt diese PKI:

```
pki-init: creating lab root CA
pki-init: issuing issuer ingress serving certificate (issuer.wif.local)
pki-init: issuing keycloak serving certificate
pki-init: issuing service-r serving certificate
pki-init: issuing validator serving certificate
pki-init: issuing negative-test material (foreign CA)
pki-init: done
```

Es entstehen: eine Root-CA, die Serverzertifikate und eine fremde CA für den Negativtest.
Jedes Stück landet in einem eigenen Volume, damit jeder Container nur sieht, was er braucht;
den CA-Schlüssel sieht nur `pki-init` selbst. Beim nächsten `up` bleibt alles erhalten.

### 4b. `sa-keys` und `server` — der Cluster startet

`sa-keys` (Skript: `tools/sa-keys.sh`) legt den RSA-Schlüssel an, mit dem der Cluster seine
Tokens signiert. k3s bringt danach in ~30 s einen kompletten Ein-Knoten-Cluster hoch. Wichtig
sind die Flags, mit denen der API-Server gestartet wird (in `compose.yaml`):

```
--bind-address=172.31.7.2
--kube-proxy-arg=nodeport-addresses=172.31.7.0/24
--kube-apiserver-arg=service-account-issuer=https://issuer.wif.local
--kube-apiserver-arg=service-account-jwks-uri=https://issuer.wif.local/openid/v1/jwks
--kube-apiserver-arg=service-account-signing-key-file=/sa-keys/signing.key
--kube-apiserver-arg=service-account-key-file=/sa-keys/verify.pub
```

Damit legen wir fest: **Jedes Token, das dieser Cluster ausstellt, trägt
`iss: https://issuer.wif.local`** — und wer die Schlüssel sucht, soll bei
`https://issuer.wif.local/openid/v1/jwks` nachsehen. Unter dieser Adresse antwortet nicht
der API-Server, sondern gleich der Issuer-Pod hinter dem Ingress. Der API-Server und die
Node-Ports lauschen nur auf der Adresse im Netz `cluster-net`; der Validator hängt nicht in
diesem Netz.

### 4c. `bootstrap` — den Cluster einrichten

Dieser Container (Skript: `tools/bootstrap.sh`) arbeitet mit der Admin-Kubeconfig und
beendet sich danach:

```
bootstrap: creating namespaces
bootstrap: provisioning the issuer ingress certificate and the internal CA
bootstrap: applying lab manifests
deployment "issuer" successfully rolled out
bootstrap: waiting for the ingress controller
deployment "traefik" successfully rolled out
deployment "consumer" successfully rolled out
deployment "reader" successfully rolled out
deployment "stranger" successfully rolled out
bootstrap: done — the issuer pod serves discovery document + JWKS at https://issuer.wif.local
```

1. **Namespaces anlegen**: `wif-demo` für die Workloads, `wif-issuer` für den Issuer-Pod.
2. **Zertifikate verteilen**: das Serverzertifikat des Ingress als Secret `issuer-tls` in
   `wif-issuer`, das Root-Zertifikat der CA als ConfigMap `internal-ca` in `wif-demo`. In
   einem echten Cluster übernähme das cert-manager oder die PKI-Anbindung der Plattform.
3. **Manifeste anwenden** (`kubectl apply -f /manifests`) und warten, bis Issuer-Pod,
   Traefik und die Workloads laufen. Ein *Manifest* ist eine YAML-Datei, die einen
   gewünschten Zustand beschreibt; `kubectl apply` sorgt dafür, dass der Cluster diesen
   Zustand herstellt. Dazu gehören die Traefik-Konfiguration, die Admission-Regeln, die den
   Namespace `wif-issuer` schützen, und die NetworkPolicies des Issuer-Pods.

`bootstrap` veröffentlicht selbst nichts — das macht der Issuer-Pod.

### 4d. Der Issuer-Pod und `ingress-lb` — die Schlüssel werden ausgeliefert

Der Issuer-Pod (`manifests/10-issuer.yaml`) hat zwei Container. `sync` liest
Discovery-Dokument und JWKS mit seinem eigenen, nur dafür berechtigten ServiceAccount vom
API-Server und legt eine Kopie ab — aber nur, wenn der Stand plausibel ist. Danach gleicht
er alle 15 Sekunden ab. `web` liefert die Kopie nur per `GET` aus und wird erst bereit,
wenn sie da ist. Das Log von `sync`
(`docker compose exec server kubectl -n wif-issuer logs deploy/issuer -c sync`):

```
issuer-sync: WARNING kid appeared: <kid>
issuer-sync: serving JWKS sha256=<hash> kids=[ <kid> ]
```

Jede `kid`, die hinzukommt oder wegfällt, steht so im Log. Ist der API-Server nicht
erreichbar, liefert der Pod den letzten gültigen Stand weiter.

Traefik veröffentlicht unter dem Host `issuer.wif.local` nur die zwei Pfade
`/.well-known/openid-configuration` und `/openid/v1/jwks`, mit dem Zertifikat aus
`issuer-tls`; die Route trägt die höchste Routing-Priorität. `ingress-lb` reicht
TCP-Verbindungen auf Port 443 aus `relying-net` an Traefiks Node-Port durch; TLS endet erst
im Cluster. `ingress-lb` selbst läuft mit schreibgeschütztem Dateisystem, nur den nötigen
Capabilities und `no-new-privileges`. Sobald das JWKS über diesen Weg
abrufbar ist, meldet der Healthcheck `ingress-lb` als gesund.

Es gibt keinen Schreibweg: Niemand lädt Schlüssel hoch, kein Endpunkt nimmt ein JWKS
entgegen. Wer bestimmen könnte, was der Issuer-Pod ausliefert, könnte Tokens fälschen —
deshalb ist `wif-issuer` geschützt wie die Steuerung des Clusters. Begründung:
[ADR 0005](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md).

### 4e. `validator` — der externe Prüfdienst

```
validator: waiting for the internal CA certificate at /trust/ca.crt ...
validator: internal CA certificate present after 0s, starting

 :: Spring Boot ::                (v4.1.2)

INFO  m.r.w.JwksTrustConfig : OIDC discovery for https://issuer.wif.local resolved JWKS at https://issuer.wif.local/openid/v1/jwks
INFO  m.r.w.WifPocApplication : Started WifPocApplication in 1.721 seconds
```

Beim Start:

1. Das Entrypoint-Skript wartet, bis `/trust/ca.crt` (das Root-Zertifikat der internen CA)
   vorhanden ist.
2. `JwksTrustConfig` baut einen **Truststore nur mit dieser CA**. Damit akzeptiert der
   Validator ausschließlich Serverzertifikate der internen PKI.
3. Der Validator macht **OIDC-Discovery**: Er holt
   `https://issuer.wif.local/.well-known/openid-configuration`, prüft, dass das Feld
   `issuer` exakt `https://issuer.wif.local` ist, und liest `jwks_uri` aus. Die übernimmt er
   nur, wenn sie auf demselben HTTPS-Ursprung (Schema, Host, Port) liegt wie die
   Issuer-URL; sonst startet er nicht. Genau das sagt die Log-Zeile oben.
4. Von der `jwks_uri` lädt er die Schlüssel (gecacht, 5 Minuten) und ist bereit.

Der Validator hängt nur in `relying-net` (zu `ingress-lb`) und `workload-net` (für die Pods)
und teilt kein Volume mit der Cluster-Seite. Details zur Java-Seite:
[`technical/validator.md`](technical/validator.md) und
[`technical/trust-und-tls.md`](technical/trust-und-tls.md).

---

## 5. `docker compose run --rm demo`

Jetzt der eigentliche Beweis. `demo` (Skript: `tools/demo.sh`) läuft in **einem** Durchlauf durch
sieben Schritte (0–6). Compose stellt vorher sicher, dass `validator` und seine
Abhängigkeiten laufen. Der `demo`-Container hängt in `cluster-net` (für `kubectl`) und in
`relying-net` (für `https://issuer.wif.local` über `ingress-lb` und den Validator).

### Schritt 0 — Was der Issuer-Endpoint anbietet

```
== 0. OIDC discovery served by the in-cluster issuer pod through the ingress (internal CA) ==
GET https://issuer.wif.local/.well-known/openid-configuration
{
  "issuer": "https://issuer.wif.local",
  "jwks_uri": "https://issuer.wif.local/openid/v1/jwks",
  "id_token_signing_alg_values_supported": [ "RS256" ]
}
```

Das *OIDC-Discovery-Dokument*: eine kleine JSON-Datei an einer festen Adresse
(`/.well-known/openid-configuration`), die sagt „ich bin der Issuer
`https://issuer.wif.local`, meine Schlüssel findest du unter `jwks_uri`, ich signiere mit
RS256". Ein Prüfer muss so nur die Issuer-URL kennen und findet den Rest selbst.

### Schritt 1 — Die öffentlichen Schlüssel (JWKS)

```
== 1. JWKS served by the issuer pod (mirrored from the API server) ==
{
  "kid": "<kid>",
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
  "iss": "https://issuer.wif.local",
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
== 3. consumer POD  ->  external validator   (happy path) ==
pod consumer-<hash>  ->  https://validator.wif.local:8443/whoami   (token from projected volume)
HTTP 200
PASS: pod token accepted (200)
```

Antwort des Validators:

```json
{
  "authenticated": true,
  "sub": "system:serviceaccount:wif-demo:consumer",
  "iss": "https://issuer.wif.local",
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
2. Der Pod schickt es als `Authorization: Bearer <token>` per HTTPS an
   `https://validator.wif.local:8443` und prüft dessen Serverzertifikat mit der internen CA
   (`--cacert /etc/internal-ca/ca.crt`). Das Token geht über stdin an curl (`-H @-`), nicht als
   Argument.
   Diesen Namen kennt der Cluster-DNS nicht (der Validator ist ja außerhalb) — deshalb steht im
   Pod-Manifest ein `hostAliases`-Eintrag, der `validator.wif.local` fest auf die IP
   `172.31.9.10` zeigt. Genau diese IP hat der Validator-Container im Netz `workload-net`.
3. Der Validator nimmt das Bearer-Token, wählt per `kid` den passenden Schlüssel aus dem
   gecachten JWKS, prüft die **Signatur**, prüft `iss == https://issuer.wif.local`, prüft
   `aud` enthält `wif-demo-validator`, prüft `exp`/`nbf` (mit 60 s Toleranz). Alles grün →
   **HTTP 200** plus die Claims.

Direkt danach prüft `demo.sh` aus dem Pod, dass der Validator **nur** über HTTPS mit einem
Zertifikat der internen CA erreichbar ist: Es zeigt Subject `CN=validator.wif.local` und die
Lab-Root-CA als Aussteller, auf 8080 antwortet nichts, Klartext-HTTP auf 8443 wird nicht
bedient, und curl nur mit den öffentlichen CAs scheitert (Exit-Code 60).

### Schritte 4 & 5 — Absichtlich kaputte Fälle

```
== 4. negative: wrong audience  ->  rejected ==
HTTP 401
PASS: wrong audience rejected (401)

== 5. negative: tampered signature  ->  rejected ==
HTTP 401
PASS: tampered token rejected (401)
```

- **Falsche Audience:** Ein Token, das für `not-this-service` ausgestellt wurde. Signatur ok,
  aber `aud` passt nicht → abgelehnt (`reason`: `JWT aud claim rejected`). Das ist der Schutz
  gegen den „confused deputy": ein Token, das die Workload einem *anderen* Dienst gegeben
  hat, taugt hier nicht.
- **Manipulierte Signatur:** Das erste Zeichen der Signatur eines gültigen Tokens wird
  verändert. Die Signatur passt nicht mehr zum Inhalt → abgelehnt (`reason`:
  `Signed JWT rejected: Invalid signature`).

### Schritt 6 — Der Issuer-Endpoint ist nur lesbar und bedient nur seinen Host

```
== 6. the issuer endpoint is read-only and serves only its own host ==
PUT https://issuer.wif.local/openid/v1/jwks
HTTP 403
PASS: PUT on the JWKS rejected (403)
POST https://issuer.wif.local/openid/v1/jwks
HTTP 403
PASS: POST on the JWKS rejected (403)
DELETE https://issuer.wif.local/openid/v1/jwks
HTTP 403
PASS: DELETE on the JWKS rejected (403)
GET https://issuer.wif.local/  (a path the ingress does not route)
HTTP 404
PASS: unrouted path not served (404)
GET https://other.wif.local/openid/v1/jwks  through ingress-lb (foreign host, SNI other.wif.local)
HTTP 000
PASS: TLS handshake for a foreign host refused (strict SNI) (000)
GET https://kubernetes.default.svc/version  through ingress-lb (API server name)
HTTP 000
PASS: no way to the API server through the ingress (000)
GET https://issuer.wif.local/openid/v1/jwks  with SNI issuer.wif.local but Host: other.wif.local
HTTP <404 oder 421>
PASS: foreign Host header not routed (<404 oder 421>)
PASS: published JWKS untouched
```

Wer das JWKS austauschen könnte, könnte sich beliebige gültige Tokens ausstellen. Deshalb
versucht das Skript, ein leeres JWKS per `PUT`, `POST` und `DELETE` einzuspielen — alles
wird abgewiesen. Danach zeigt es, dass über `ingress-lb` nichts anderes erreichbar ist als
die zwei Pfade unter `issuer.wif.local`: kein anderer Pfad, kein fremder Host (Traefik lehnt
den TLS-Handshake ab, `000` heißt „kein HTTP-Austausch"), kein Weg zum API-Server. Das
veröffentlichte JWKS enthält danach weiterhin die Schlüssel des Clusters.

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
2. den **Schutz des Namespace** `wif-issuer` (`demo hardening`) und das Verhalten des
   Issuer-Pods bei **Ausfall des API-Servers** (`demo resilience`) — beides unten,
3. die **Netztrennung**: Validator, `service-r` und Keycloak erreichen weder den API-Server
   (`172.31.9.2:6443`, `172.31.7.2:6443`) noch Traefiks Node-Port direkt (`:30443`);
   Keycloak erreicht `ingress-lb` nur auf seiner `relying-net`-Seite,
4. dass ein Validator mit **fremder CA** (`validator-foreign-ca`) nicht startet,
5. einen **Schlüsselwechsel in zwei Phasen** (unten).

```
PASS: all lab checks passed
```

### `demo hardening` — der Namespace `wif-issuer` ist geschützt

```
== H1. admission: the issuer host is reserved for wif-issuer ==
PASS: Ingress for issuer.wif.local in wif-demo: denied
PASS: wildcard Ingress *.wif.local in wif-demo: denied
PASS: wildcard Ingress *.local in wif-demo: denied
PASS: Ingress rule without a host in wif-demo (matches every host): denied
PASS: host-less Ingress with a long path regex in wif-demo (would outrank by rule length): denied
PASS: Ingress with a raised routing priority in wif-demo: denied
PASS: Ingress with a Traefik path matcher annotation in wif-demo: denied
PASS: Ingress with a default backend in wif-demo: denied
PASS: Ingress for another host in wif-demo: admitted
PASS: the issuer route carries the top routing priority
PASS: Traefik reads neither its own route CRDs nor the Gateway API
PASS: Traefik reads routes from Ingress objects
== H2. admission: images in wif-issuer only by digest ==
PASS: Deployment with a tag-only image in wif-issuer: denied
PASS: Deployment with <image>@sha256:<digest> in wif-issuer: admitted
== H3. RBAC: nobody but cluster admins writes to wif-issuer ==
PASS: neither a workload nor the issuer's own ServiceAccount may write or read secrets in wif-issuer
PASS: the issuer's ServiceAccount may read the JWKS (issuer-discovery role)
== H4. NetworkPolicy: in only from the ingress controller, out only to the API server ==
PASS: workloads cannot reach the issuer pod
PASS: the issuer pod reaches nothing but the API server
PASS: the issuer pod reaches the API server
== H5. pod hardening ==
PASS: non-root, read-only root filesystem, no capabilities
PASS: web container cannot write its root filesystem
PASS: the web container, which faces the ingress, holds no ServiceAccount token
```

Die abgewiesenen Manifeste prüft das Skript mit `kubectl apply --dry-run=server`; über jeder
`denied`-Zeile steht die Meldung des API-Servers samt Text der Admission-Regel. H3 druckt
zusätzlich eine Tabelle der `kubectl auth can-i`-Antworten (überall `no`).

Warum H1 so viele Fälle hat: Eine Ingress-Regel ohne Host passt auf jeden Host, auch auf
`issuer.wif.local`, und Traefik ordnet Routen nach der Länge ihrer Regel. Ein Ingress ohne
Host mit einer langen Pfad-Regex könnte die Issuer-Route also überholen. Deshalb muss
außerhalb von `wif-issuer` jede Regel einen eigenen Host nennen, Default-Backends und
Traefik-Router-Annotationen sind verboten, und die Issuer-Route trägt selbst die höchste
Priorität (`1000000000`).

### `demo resilience` — der Issuer-Pod ohne API-Server

```
== R1. API server unreachable: the issuer pods keep serving the last good state ==
cutting the issuer pods' path to the API server (NetworkPolicy egress := none)
  issuer-<pod>: issuer-sync: reading from the API server failed, keeping the last good state, retrying in 15s
  issuer-<pod>: issuer-sync: reading from the API server failed, keeping the last good state, retrying in 15s
PASS: the JWKS is served unchanged
PASS: both issuer pods stay ready
restoring the path to the API server
== R2. implausible state: a new pod never becomes ready, the others keep serving ==
rolling out a pod that expects another issuer, so the API server's state is implausible to it
new pod: issuer-<pod>
  issuer-<pod>: issuer-sync: REJECTED state: discovery document does not name issuer https://not-this-cluster
PASS: the new pod is not ready (no plausible state yet)
PASS: the two previous pods keep serving
PASS: the JWKS is served unchanged
rolling back
PASS: the issuer serves the JWKS after the rollback
```

R1 entzieht den Issuer-Pods per NetworkPolicy den Weg zum API-Server: Sie liefern den
letzten gültigen Stand weiter und bleiben bereit. R2 rollt einen Pod aus, dem der Stand des
API-Servers nicht plausibel erscheint: Er wird nie bereit und bekommt keinen Verkehr, die
beiden bisherigen Pods liefern unverändert aus. Danach stellt das Skript alles wieder her.

### Schlüsselwechsel in zwei Phasen

`run-all-checks.sh` führt die Schritte in dieser Reihenfolge aus:

```bash
docker compose run --rm demo pre-rotation
docker compose run --rm sa-keys stage        # Phase 1: neuer Schlüssel nur zum Prüfen
docker compose restart server && docker compose up -d --wait server
docker compose run --rm demo staged
docker compose run --rm sa-keys activate     # Phase 2: neuer Schlüssel signiert
docker compose restart server && docker compose up -d --wait server
docker compose run --rm demo post-rotation
```

Der API-Server liest die Schlüsseldateien nur beim Start, deshalb jeweils der Neustart. Im
Lab startet dabei der ganze Knoten neu, also auch die Issuer-Pods.

```
== key change 0/2: token and published keys before the change ==
published kids:
  <kid-alt>
token kid: <kid-alt>
HTTP 200
PASS: pre-rotation token accepted (200)

== key change 1/2: the staged key is served as verify-only key ==
published kids now:
  <kid-alt>
  <kid-neu>
PASS: staged kid served: <kid-neu>
  issuer-<pod>: issuer-sync: WARNING kid appeared: <kid-neu>
  issuer-<pod>: issuer-sync: WARNING kid appeared: <kid-neu>
PASS: every issuer pod logged the new kid <kid-neu>
new token kid: <kid-alt>
PASS: the API server still signs with the current key
HTTP 200
PASS: token accepted by the validator (200)
HTTP 200
PASS: client assertion accepted by the realm (200)

== key change 2/2: the staged key signs — the first pass with it is accepted ==
client assertion kid: <kid-neu>
HTTP 200
PASS: first assertion with the new key accepted by the realm, without retry (200)
new token kid: <kid-neu>
HTTP 200
PASS: first token with the new key accepted by the validator, without retry (200)
HTTP 200
PASS: pre-rotation token still accepted (previous key kept in the JWKS) (200)
published kids now:
  <kid-alt>
  <kid-neu>
PASS: the JWKS holds exactly the new and the previous key (no other key, e.g. k3s's own)
```

Nach `stage` steht der neue Schlüssel schon im JWKS, signiert wird aber weiter mit dem alten.
Erst wenn der Issuer-Pod ihn ausliefert, macht `activate` ihn zum Signierschlüssel. Deshalb
nehmen Keycloak und Validator schon das **erste** Token mit der neuen `kid` an — ohne
Fehlversuch. Das Token von vor dem Wechsel bleibt gültig, weil der vorherige Schlüssel im
JWKS bleibt. Ist dieser vorherige Schlüssel kompromittiert, entfernt
`docker compose run --rm sa-keys retire` ihn sofort (danach wieder `docker compose restart
server`); `run-all-checks.sh` führt das nicht aus.

---

## 6. Selbst nachsehen

Der Stack läuft noch (`docker compose ps`). Ein paar nützliche Blicke:

```bash
# Discovery-Dokument, wie es der Validator sieht (validator hat curl + die interne CA gemountet)
docker compose exec validator curl -s --cacert /trust/ca.crt https://issuer.wif.local/.well-known/openid-configuration

# Wer hat sich über ingress-lb mit dem Ingress verbunden?
docker compose logs ingress-lb

# Was liefert der Issuer-Pod aus, welche kid kam wann hinzu?
docker compose exec server kubectl -n wif-issuer logs deploy/issuer -c sync

# Das Token direkt aus dem Pod
POD=$(docker compose exec server kubectl -n wif-demo get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
docker compose exec server kubectl -n wif-demo exec "$POD" -- cat /var/run/secrets/tokens/sa-token

# Validator direkt vom Host anfragen (nur HTTPS, Lab-CA; ohne Token -> 401)
docker compose cp validator:/trust/ca.crt lab-ca.crt
curl -s --cacert lab-ca.crt -o /dev/null -w '%{http_code}\n' https://localhost:18080/whoami
curl -s --cacert lab-ca.crt https://localhost:18080/healthz
```

Unter Windows (curl mit Schannel) zusätzlich `--ssl-no-revoke` angeben – die Lab-CA
veröffentlicht keine Sperrliste. Schannel prüft bei einer IP-Adresse den Zertifikatsnamen
gegen den CN statt gegen den IP-SAN, deshalb `localhost` statt `127.0.0.1` verwenden.

Im Log von `ingress-lb` siehst du, wer sich mit dem Ingress verbindet: der Validator von
`172.31.8.10` aus, Keycloak von `172.31.8.30`, jeweils weitergereicht an `172.31.7.2:30443`.
Pfade stehen dort nicht — `ingress-lb` sieht nur verschlüsselte Daten, TLS endet erst in
Traefik. Den API-Server spricht der Validator nie an — er hat gar keine Route dorthin.

---

## 7. Kaputtmachen zum Lernen

- **Fremde CA:** `docker compose run --rm validator-foreign-ca` startet einen zweiten
  Validator, der einer anderen CA vertraut. Er stirbt beim Start mit
  `PKIX path building failed`. → Warum: sein Truststore enthält nur die fremde CA, das
  Serverzertifikat des Issuer-Ingress stammt aber von der internen.
- **Audience im Pod ändern:** In `manifests/20-consumer.yaml` die `audience` auf etwas anderes
  setzen, `docker compose down -v && docker compose up -d`. Der Gutfall in Schritt 3
  wird dann zu einem 401 („JWT aud claim rejected").
- **Signieren, bevor der Schlüssel ausgeliefert wird:** Issuer-Pods anhalten
  (`docker compose exec server kubectl -n wif-issuer scale deploy/issuer --replicas=0`),
  dann `docker compose run --rm sa-keys stage`, `docker compose run --rm sa-keys activate`
  und `docker compose restart server`. Neue Tokens tragen eine `kid`, die unter
  `https://issuer.wif.local` nicht abrufbar ist — der Validator lehnt sie mit 401 ab. Mit
  `--replicas=2` liefern die Pods nach ihrem ersten Abgleich das neue JWKS aus, und die
  neuen Tokens werden angenommen. Genau diese Lücke schließt die Reihenfolge
  `stage` → ausgeliefert → `activate`.

---

## 8. Aufräumen

```bash
docker compose down -v
```

`-v` entfernt auch alle Named Volumes (Cluster-Zustand, Signaturschlüssel, PKI,
Demo-Zustand). Der nächste `up` beginnt komplett frisch (neuer Cluster, neue CA, neue
Zertifikate, neue Schlüssel).

---

## Weiterlesen

- [Das große Bild — Konzepte & Vokabular](domain.md)
- [Kubernetes-Primer — nur die Bausteine, die hier vorkommen](kubernetes-primer.md)
- [Der Ablauf als Use Case](use-cases.md)
- [Technik: Architektur des Compose-Stacks](technical/architecture.md)
- [Technik: PKI, Issuer-Pod und Ingress](technical/bootstrap-und-issuer.md)
- [Technik: der Validator im Detail](technical/validator.md)
- [Technik: Vertrauen & TLS](technical/trust-und-tls.md)
- [Entscheidung: Offline-JWKS statt TokenReview](adr/0001-offline-jwks-statt-tokenreview.md)
- [Entscheidung: getrennte Vertrauensbereiche, interne PKI](adr/0003-getrennte-vertrauensbereiche-interne-pki.md)
- [Entscheidung: Issuer-Pod im Cluster, Pull über einen Ingress](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md)
