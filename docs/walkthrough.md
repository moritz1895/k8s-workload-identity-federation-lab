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
| `server` | k3s — ein vollständiges, aber leichtgewichtiges Kubernetes, das komplett in **einem** Container läuft | Der Cluster. Stellt die signierten Tokens aus. |
| `bootstrap` | Ein Wegwerf-Container mit `kubectl`, `openssl`, `jq` | Läuft **einmal** beim Start: richtet den Cluster ein und veröffentlicht das Schlüsselmaterial. Danach beendet er sich. |
| `issuer-web` | Ein nginx-Webserver | Liefert das OIDC-Discovery-Dokument und die öffentlichen Schlüssel (JWKS) unter `https://issuer-web` aus. Diese URL steht im `iss`-Feld jedes Tokens. |
| `validator` | Ein kleiner Spring-Boot-Dienst (Java) | Der externe Dienst, der die Tokens prüft. **Spricht nur mit `issuer-web`, nie mit dem Cluster.** |
| `demo` | Nochmal das Wegwerf-Image mit `kubectl` | Wird nur auf Zuruf gestartet und fährt die Ende-zu-Ende-Prüfung. |

Dazu im Cluster: ein **Pod** namens `consumer` — das ist unsere Workload.

```
        ┌──────────── Docker-Netz "wifnet" ─────────────────────────────────┐
        │                                                                   │
        │   server (k3s) ───────────►  bootstrap ──►  issuer-web (nginx)     │
        │   stellt Tokens aus         kopiert         https://issuer-web     │
        │   ┌───────────────┐         Schlüssel       /.well-known/...       │
        │   │ Pod "consumer"│         hierher ─────►  /openid/v1/jwks        │
        │   │  hat ein Token│                                ▲               │
        │   └──────┬────────┘                                │ OIDC-Discovery│
        │          │  Bearer-Token                           │ (nur lesen)   │
        │          ▼                                         │               │
        │   validator (Spring Boot) ────────────────────────►┘               │
        │   prüft Signatur + iss + aud + exp                                 │
        └───────────────────────────────────────────────────────────────────┘
```

Merksatz: **Der Validator berührt den Kubernetes-API-Server nie.** Er kennt nur `issuer-web`.

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
`WIF_ISSUER`-URL ist die häufigste Fehlerquelle (der Validator würde dann das falsche
Serverzertifikat sehen).

---

## 4. `docker compose up -d --build`

Der erste Lauf baut zwei Images (`validator` und das Tool-Image für `bootstrap`/`demo`) und
startet dann alles in der richtigen Reihenfolge. `--build` brauchst du nur beim ersten Mal oder
nach Codeänderungen; danach reicht `docker compose up -d`.

Die Startreihenfolge ist **nicht** zufällig — Compose kettet sie über `depends_on` und
Healthchecks:

```
server        Started
server        Healthy          ← API-Server antwortet
bootstrap     Started
bootstrap     Exited (0)       ← einmalige Einrichtung fertig
issuer-web    Started
issuer-web    Healthy          ← nginx liefert aus
validator     Started
validator     Healthy          ← /healthz ok
```

### 4a. `server` — der Cluster startet

k3s bringt in ~30 s einen kompletten Ein-Knoten-Cluster hoch. Wichtig sind die Flags, mit denen
der API-Server gestartet wird (in `compose.yaml`):

```
--kube-apiserver-arg=service-account-issuer=https://issuer-web
--kube-apiserver-arg=service-account-jwks-uri=https://issuer-web/openid/v1/jwks
```

Damit legen wir fest: **Jedes Token, das dieser Cluster ausstellt, trägt `iss: https://issuer-web`**
— und wer die Schlüssel sucht, soll bei `https://issuer-web/openid/v1/jwks` nachsehen. Der
Cluster selbst hostet unter dieser Adresse *nichts*; das macht gleich `issuer-web`.

Aus dem k3s-Log (gekürzt):

```
msg="Started tunnel to 172.31.7.2:6443"
kubelet_network.go:47  "Updating Pod CIDR" newPodCIDR="10.42.0.0/24"
pod_startup_latency_tracker.go:144  "Observed pod startup duration" pod="wif-demo/consumer-..."
```

Die letzte Zeile heißt: Unser `consumer`-Pod läuft. Den hat aber nicht k3s von selbst gestartet,
sondern `bootstrap`.

### 4b. `bootstrap` — Einrichtung und Schlüssel-Veröffentlichung

Dieser Container (Skript: `tools/bootstrap.sh`) macht vier Dinge und beendet sich dann:

```
bootstrap: applying lab manifests
namespace/wif-demo created
serviceaccount/consumer created
deployment.apps/consumer created
deployment "consumer" successfully rolled out
bootstrap: minting a self-signed serving certificate for issuer-web
....+...+++++++  [openssl erzeugt einen RSA-Schlüssel]  +++++++
bootstrap: publishing discovery document + JWKS
bootstrap: done — discovery document now served at https://issuer-web/.well-known/openid-configuration
{"issuer":"https://issuer-web","jwks_uri":"https://issuer-web/openid/v1/jwks", ... ,"id_token_signing_alg_values_supported":["RS256"]}
```

1. **Manifeste anwenden** (`kubectl apply -f /manifests`): legt den Namespace `wif-demo`, den
   `ServiceAccount` `consumer` und das `Deployment` `consumer` an. Ein *Manifest* ist eine
   YAML-Datei, die einen gewünschten Zustand beschreibt; `kubectl apply` sorgt dafür, dass der
   Cluster diesen Zustand herstellt. (Warum ein eigener Container und nicht k3s' Auto-Mechanismus:
   siehe Kommentar in `bootstrap.sh` bzw. [Kubernetes-Primer](kubernetes-primer.md).)
2. **Auf den Pod warten** (`kubectl rollout status`): erst weitermachen, wenn `consumer` wirklich
   läuft.
3. **TLS-Zertifikat erzeugen** (`openssl req -x509 ...`): ein *self-signed* Zertifikat für den
   Hostnamen `issuer-web`. „Self-signed" heißt: es ist von niemandem außer sich selbst
   beglaubigt — für ein Labor völlig ok, in Produktion nähme man ein Zertifikat einer echten CA.
   Das Zertifikat landet im geteilten Volume `oidc-web`.
4. **Discovery-Dokument + JWKS veröffentlichen**: `bootstrap` holt mit Admin-Rechten
   `/.well-known/openid-configuration` und `/openid/v1/jwks` aus dem Cluster und legt sie
   ebenfalls in `oidc-web` ab. Genau diese Dateien serviert gleich `issuer-web`.

Ergebnis: Im Volume `oidc-web` liegen jetzt `tls.crt`, `tls.key`, `openid-configuration.json`,
`jwks.json`.

### 4c. `issuer-web` — der Issuer-Endpoint

nginx (`tools/nginx-issuer.conf`) startet und liefert die eben abgelegten Dateien unter HTTPS aus:

```
nginx/1.31.5
start worker processes
```

- `https://issuer-web/.well-known/openid-configuration` → das Discovery-Dokument
- `https://issuer-web/openid/v1/jwks` → die öffentlichen Signaturschlüssel
- `http://127.0.0.1/healthz` → nur intern, damit der Container-Healthcheck „gesund" melden kann

Die Log-Zeile `can not modify /etc/nginx/conf.d/default.conf (read-only file system?)` ist
**harmlos** — nginx' Standard-Startskript will unsere (bewusst schreibgeschützt gemountete)
Config anfassen; unsere Config braucht die Änderung nicht.

### 4d. `validator` — der externe Prüfdienst

```
validator: waiting for the issuer certificate at /oidc/tls.crt ...
validator: issuer certificate present after 0s, starting

 :: Spring Boot ::                (v4.1.1)

INFO  m.r.w.JwksTrustConfig : OIDC discovery for https://issuer-web resolved JWKS at https://issuer-web/openid/v1/jwks
INFO  m.r.w.WifPocApplication : Started WifPocApplication in 1.721 seconds
```

Beim Start:

1. Das Entrypoint-Skript wartet, bis `/oidc/tls.crt` im gemounteten Volume auftaucht (also bis
   `bootstrap` fertig war).
2. `JwksTrustConfig` baut einen **Truststore mit genau diesem einen Zertifikat**. Damit vertraut
   der Validator ausschließlich `issuer-web` und keiner anderen HTTPS-Gegenstelle.
3. Der Validator macht **OIDC-Discovery**: Er holt `https://issuer-web/.well-known/openid-configuration`,
   prüft, dass das Feld `issuer` exakt `https://issuer-web` ist, und liest `jwks_uri` aus. Genau
   das sagt die Log-Zeile oben.
4. Von der `jwks_uri` lädt er die Schlüssel (gecacht, 5 Minuten) und ist bereit.

Details zur Java-Seite: [`technical/validator.md`](technical/validator.md) und
[`technical/trust-und-tls.md`](technical/trust-und-tls.md).

---

## 5. `docker compose run --rm demo`

Jetzt der eigentliche Beweis. `demo` (Skript: `tools/demo.sh`) läuft in **einem** Durchlauf durch
sechs Schritte. Compose startet vorher automatisch alle Abhängigkeiten und `bootstrap` erneut
(die Anwendung der Manifeste ist idempotent — mehrfach ausführen schadet nicht).

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
   `172.31.7.10` zeigt. Genau diese IP hat der Validator-Container im Docker-Netz.
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

**Echtes Ablaufen** (`exp` in der Vergangenheit) lässt sich nicht schnell zeigen: Die
Kubernetes-TokenRequest-API stellt keine Tokens mit weniger als **10 Minuten** Laufzeit aus. Mit
`DEMO_EXPIRY=1 docker compose run --rm demo` hängt das Skript einen Schritt an, der ein
10-Minuten-Token mintet und `/whoami` so lange pollt, bis es von `200` auf `401` kippt.

### Abschluss

```
== result ==
PASS: all checks passed
```

---

## 6. Selbst nachsehen

Der Stack läuft noch (`docker compose ps`). Ein paar nützliche Blicke:

```bash
# Discovery-Dokument, wie es der Validator sieht (validator hat curl + das Zertifikat gemountet)
docker compose exec validator curl -s --cacert /oidc/tls.crt https://issuer-web/.well-known/openid-configuration

# Wer hat was von issuer-web geholt? (172.31.7.10 = Validator, andere IP = demo-Container)
docker compose logs issuer-web | grep GET

# Das Token direkt aus dem Pod
POD=$(docker compose exec server kubectl -n wif-demo get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
docker compose exec server kubectl -n wif-demo exec "$POD" -- cat /var/run/secrets/tokens/sa-token

# Validator direkt vom Host anfragen (ohne Token -> 401)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/whoami
curl -s http://localhost:18080/healthz
```

Im nginx-Access-Log siehst du auch schön, dass der Validator (`172.31.7.10`) nur mit
`issuer-web` spricht und **nie** mit dem API-Server (`172.31.7.2`):

```
172.31.7.10  "GET /.well-known/openid-configuration"  200  "Java/25.0.4"   ← Validator beim Start
172.31.7.10  "GET /openid/v1/jwks"                    200  "Java/25.0.4"   ← Validator beim 1. Token
172.31.7.4   "GET /.well-known/openid-configuration"  200  "curl/8.14.1"   ← demo, Schritt 0
```

---

## 7. Kaputtmachen zum Lernen

- **`.env` verbiegen:** Setze `WIF_ISSUER=https://k3s-server:6443` und starte neu. Der Validator
  zeigt jetzt auf den API-Server statt auf `issuer-web`, sieht dort ein Zertifikat, das er nicht
  kennt, und stirbt beim Start mit `PKIX path building failed`. → Warum: der Truststore des
  Validators enthält nur das `issuer-web`-Zertifikat.
- **Audience im Pod ändern:** In `manifests/20-consumer.yaml` die `audience` auf etwas anderes
  setzen, `docker compose down -v && docker compose up -d`. Der Gutfall in Schritt 3 wird dann zu
  einem 401 („JWT aud claim rejected").
- **Einen Schlüssel-Mismatch erzeugen:** Lösche `jwks.json` aus dem Volume, während der Validator
  läuft, und warte, bis der 5-Minuten-Cache abläuft — oder starte den Validator neu. Discovery
  schlägt fehl, der Bean lässt sich nicht bauen, der Container wird `unhealthy`.

---

## 8. Aufräumen

```bash
docker compose down -v
```

`-v` entfernt auch die drei Named Volumes (`k3s-data`, `kubeconfig`, `oidc-web`). Danach ist
nichts mehr übrig; der nächste `up` beginnt komplett frisch (neuer Cluster, neues
Issuer-Zertifikat, neue Schlüssel).

---

## Weiterlesen

- [Das große Bild — Konzepte & Vokabular](domain.md)
- [Kubernetes-Primer — nur die Bausteine, die hier vorkommen](kubernetes-primer.md)
- [Der Ablauf als Use Case](use-cases.md)
- [Technik: Architektur des Compose-Stacks](technical/architecture.md)
- [Technik: der Validator im Detail](technical/validator.md)
- [Technik: Vertrauen & TLS](technical/trust-und-tls.md)
- [Entscheidung: Offline-JWKS statt TokenReview](adr/0001-offline-jwks-statt-tokenreview.md)
