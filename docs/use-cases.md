# Use Cases: der Ablauf von Anfang bis Ende

## Für wen ist das / was lernst du hier

Diese Seite erzählt, was im Lab **tatsächlich passiert** - einmal beim Hochfahren
(`docker compose up`) und einmal bei jeder Anfrage der Workload an den externen Dienst
(`docker compose run --rm demo`). Die Schritte sind konkret an dem festgemacht, was der Code
und [`tools/demo.sh`](../tools/demo.sh) wirklich tun: welche Claims geprüft werden, welche
HTTP-Statuscodes zurückkommen und welche Ablehnungsgründe im Fehlerfall im Body stehen.

Begriffe werden hier nicht noch einmal erklärt - falls etwas unklar ist, siehe
[domain.md](domain.md) (Konzepte) und [kubernetes-primer.md](kubernetes-primer.md)
(Kubernetes-Bausteine).

---

## Wer spricht mit wem

```
   ┌─────────────────────────── Docker-Netz "wifnet" (172.31.7.0/24) ───────────────────────────┐
   │                                                                                            │
   │  ┌──────────────────────┐        ┌──────────────────────┐       ┌────────────────────────┐  │
   │  │  server (k3s)        │        │  issuer-web (nginx)  │       │  validator (Spring)    │  │
   │  │                      │        │  https://issuer-web  │       │  172.31.7.10:8080      │  │
   │  │  API-Server stellt   │        │  /.well-known/...    │◄──────│  OIDC-Discovery        │  │
   │  │  Tokens aus,         │        │  /openid/v1/jwks     │  TLS  │  + JWKS laden          │  │
   │  │  iss=https://issuer- │        └──────────┬───────────┘       │                        │  │
   │  │  web                 │                   │ einmalig durch    │  prüft: Signatur,      │  │
   │  │                      │                   │ bootstrap befüllt │  iss, aud, exp, nbf    │  │
   │  │  ┌────────────────┐  │                                       └───────────▲────────────┘  │
   │  │  │ Pod "consumer" │  │                                                   │               │
   │  │  │ Token-Datei:   │  │   GET /whoami                                     │               │
   │  │  │ /var/run/      │  │   Authorization: Bearer <JWT>                     │               │
   │  │  │ secrets/tokens │  ├───────────────  (via hostAliases  ───────────────►┘               │
   │  │  │ /sa-token      │  │                  validator.wif.local -> 172.31.7.10)              │
   │  │  └────────────────┘  │                                                                   │
   │  └──────────────────────┘                                                                   │
   └────────────────────────────────────────────────────────────────────────────────────────────┘

   WICHTIG: Der Validator sendet NIE eine Anfrage an den API-Server (server).
            Er spricht ausschließlich mit issuer-web.
```

---

## Use Case 1: Workload authentisiert sich gegenüber externem Dienst

### Akteure

- **Workload** - der `consumer`-Pod im Cluster (in `demo.sh` handelnd über `kubectl exec`).
- **kubelet** - besorgt und erneuert das Token für den Pod.
- **Validator** - der externe Spring-Boot-Dienst, der das Token prüft.
- **issuer-web** - liefert dem Validator Discovery-Dokument und JWKS.

### Auslöser

Die Workload will `GET /whoami` beim Validator aufrufen und muss sich dafür ausweisen. Im
Lab löst [`tools/demo.sh`](../tools/demo.sh) (Abschnitt 3) diesen Aufruf aus.

### Vorbedingungen

- Cluster, `issuer-web` und Validator laufen; der Bootstrap (Use Case 2) ist durchgelaufen.
- Der Validator hat beim Start erfolgreich OIDC-Discovery gegen `https://issuer-web`
  gemacht: Das Feld `issuer` im Discovery-Dokument war exakt `https://issuer-web`, und die
  `jwks_uri` daraus wurde geladen. (Schlägt das fehl, startet der Validator gar nicht -
  siehe Fehlerfall E5.)
- Der `consumer`-Pod hat unter `/var/run/secrets/tokens/sa-token` ein aktuelles Token.

### Hauptablauf (Happy Path)

1. **kubelet fordert das Token an.** Aufgrund der `serviceAccountToken`-Source im
   `projected` Volume ([`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml)) ruft
   das kubelet die TokenRequest-API des API-Servers auf: `audience: wif-demo-validator`,
   `expirationSeconds: 600`. Es erneuert das Token selbstständig vor Ablauf.

2. **Das Token liegt im Pod.** Der API-Server gibt ein signiertes JWT zurück
   (Algorithmus `RS256`, Signatur mit einem der ServiceAccount-Signaturschlüssel des
   Clusters). Das kubelet legt es als Datei `/var/run/secrets/tokens/sa-token` ab. Inhalt
   des Payloads:

   | Claim | Wert |
   |---|---|
   | `iss` | `https://issuer-web` |
   | `aud` | `["wif-demo-validator"]` |
   | `sub` | `system:serviceaccount:wif-demo:consumer` |
   | `exp`, `iat`, `nbf` | Zeitstempel (Laufzeit 600 s) |
   | `kubernetes.io` | Objekt mit `namespace`, `pod`, `serviceaccount` |

3. **Die Workload ruft den Validator auf.** Der Pod sendet
   `GET http://validator.wif.local:8080/whoami` mit dem Header
   `Authorization: Bearer <Inhalt der Token-Datei>`. Der Name `validator.wif.local` zeigt
   per `hostAliases` auf `172.31.7.10` (den Validator). In `demo.sh`:
   `kubectl -n wif-demo exec <pod> -- sh -c 'curl ... -H "Authorization: Bearer $(cat /var/run/secrets/tokens/sa-token)" ...'`.

4. **Der Validator hat die Schlüssel bereits (Discovery beim Start, danach Cache).** Beim
   Hochfahren hat `JwksTrustConfig` das Discovery-Dokument von
   `https://issuer-web/.well-known/openid-configuration` geholt (nur über die eine
   vertraute TLS-Verbindung), das `issuer`-Feld gegen die Konfiguration geprüft und der
   `jwks_uri` gefolgt. Die JWKS werden **5 Minuten** zwischengespeichert
   (`JWKS_CACHE_TTL_MS = 300000`) und bei Bedarf im Hintergrund aktualisiert. Der Validator
   fragt hierfür **niemals** den API-Server.

5. **Der Validator prüft das Token offline** (`TokenValidator`, Nimbus JOSE):
   - Er liest die `kid` (Key-ID) aus dem JWS-Header und wählt den passenden öffentlichen
     Schlüssel aus dem JWKS. Akzeptierte Algorithmen: **nur `RS256` oder `ES256`**.
   - Er prüft die **Signatur** gegen diesen Schlüssel.
   - Er verlangt `iss` **exakt** gleich `https://issuer-web`.
   - Er verlangt, dass `aud` den Wert `wif-demo-validator` **exakt** enthält.
   - Er prüft `exp` und `nbf` (Standard-Toleranz von Nimbus gegen Uhr-Abweichung: 60 s).
   - Er verlangt, dass die Claims `sub`, `iat`, `exp` vorhanden sind.

6. **Antwort bei Erfolg:** HTTP **200** mit JSON-Body:

   ```json
   {
     "authenticated": true,
     "sub": "system:serviceaccount:wif-demo:consumer",
     "iss": "https://issuer-web",
     "aud": ["wif-demo-validator"],
     "exp": 1234567890,
     "kubernetes.io": { "namespace": "wif-demo", "pod": { "...": "..." }, "serviceaccount": { "...": "..." } }
   }
   ```

   `demo.sh` prüft in Abschnitt 3: Status muss `200` sein (`PASS: pod token accepted (200)`),
   sonst bricht das Skript mit `FAIL` ab.

### Nachbedingungen

- Der Validator hat **keinen** Zustand gespeichert (keine Session, kein Log-in). Jede
  Anfrage wird eigenständig geprüft.
- Der Cluster wurde nicht kontaktiert.
- Das Token bleibt bis `exp` gültig und kann in dieser Zeit weiter verwendet werden.

### Fehlerfälle

In allen Fehlerfällen antwortet `/whoami` mit HTTP **401** und einem JSON-Body. Bei fehlendem
oder formatfalschem Header:

```json
{ "error": "missing_bearer_token" }
```

Bei einem abgelehnten Token:

```json
{ "error": "token_rejected", "reason": "<kurze Begründung aus der Prüf-Bibliothek>" }
```

| # | Situation | Auslöser im Lab | Ergebnis | `reason` (Text) |
|---|---|---|---|---|
| **E1** | **Falsche Audience.** Token wurde für einen anderen Empfänger ausgestellt. | `demo.sh` Abschnitt 4: `kubectl create token consumer --audience "not-this-service"` | HTTP **401** | `JWT aud claim rejected` |
| **E2** | **Abgelaufen.** `exp` liegt (mehr als 60 s) in der Vergangenheit. | `demo.sh` Abschnitt 6 (`DEMO_EXPIRY=1`): 10-Minuten-Token, dann warten, bis `/whoami` von `200` auf `401` kippt. | HTTP **401** | Text enthält `expired` (Nimbus: `Expired JWT`) |
| **E3** | **Manipulierte Signatur.** Ein Zeichen des gültigen Tokens wurde verändert. | `demo.sh` Abschnitt 5: `TAMPERED="${GOOD%?}X"` | HTTP **401** | `Signed JWT rejected: Invalid signature` |
| **E4** | **Unbekannter Signaturschlüssel.** Das Token ist mit einem Schlüssel signiert, dessen `kid` nicht im JWKS steht. | Im Unit-Test `validate_givenUnknownSigningKey_thenRejected` (nicht in `demo.sh`). | HTTP **401** | Text im Sinne von `no matching key(s) found` |
| **E5** | **Falscher Issuer.** `iss` im Token ist nicht `https://issuer-web`. | Unit-Test `validate_givenWrongIssuer_thenRejected`. | HTTP **401** | Text enthält `iss` |
| **E6** | **Kein / falsch formatierter Header.** `Authorization` fehlt oder beginnt nicht mit `Bearer `. | Direkter `curl` ohne Header. | HTTP **401** | Body: `{"error":"missing_bearer_token"}` |
| **E7** | **Kaputtes Token.** Kein gültiges JWT-Format. | Unit-Test `validate_givenMalformedToken_thenRejected`. | HTTP **401** | Parser-Fehlermeldung |

> Die genauen `reason`-Texte stammen aus der Bibliothek Nimbus JOSE + JWT und können sich
> zwischen Versionen minimal unterscheiden. Die in
> [`README.md`](../README.md) und [`tools/demo.sh`](../tools/demo.sh) genannten Texte
> (`JWT aud claim rejected`, `Signed JWT rejected: Invalid signature`) sind die, die dieses
> Lab erwartet.

### Startfehler (kein `/whoami`-Aufruf, sondern der Validator startet nicht)

- **Discovery-Issuer passt nicht.** Liefert `https://issuer-web/.well-known/openid-configuration`
  ein `issuer`-Feld, das nicht exakt der konfigurierten `WIF_ISSUER` entspricht, wirft
  `JwksTrustConfig` beim Erzeugen der Beans eine `IllegalStateException` und der
  Spring-Kontext startet nicht. Das ist gewollt: Ein Validator mit fehlkonfiguriertem
  Vertrauensanker soll gar nicht erst laufen.
- **Issuer-Zertifikat fehlt.** [`validator/entrypoint.sh`](../validator/entrypoint.sh)
  wartet bis zu 180 s auf die Datei `/oidc/tls.crt` (die der Bootstrap erzeugt) und bricht
  danach mit einem Fehler ab.

---

## Use Case 2: Cluster-Bootstrap (`docker compose up -d --build`)

### Akteure

- **Docker Compose** - startet die Container in Abhängigkeitsreihenfolge.
- **server** - der k3s-Cluster.
- **bootstrap** - der Einmal-Container ([`tools/bootstrap.sh`](../tools/bootstrap.sh)).
- **issuer-web** - der nginx, der danach die Metadaten ausliefert.
- **validator** - startet zuletzt.

### Auslöser

`docker compose up -d --build` auf dem Host.

### Vorbedingungen

- Auf dem Host laufen Docker und Compose v2.
- Eine Datei `.env` existiert (aus `.env.example` kopiert). Sie liefert u. a. `WIF_ISSUER`,
  `WIF_AUDIENCE`, das k3s-Image und den Host-Port des Validators.

### Hauptablauf

1. **k3s startet** (`server`). Der API-Server wird mit
   `service-account-issuer=https://issuer-web` und
   `service-account-jwks-uri=https://issuer-web/openid/v1/jwks` gestartet. Ab jetzt trägt
   jedes ausgestellte ServiceAccount-Token `iss = https://issuer-web`, und das
   Discovery-Dokument des Clusters nennt bereits die externe `jwks_uri`. Compose wartet, bis
   der Health-Check (`kubectl get --raw /readyz`) grün ist.

2. **bootstrap läuft einmal durch** (`depends_on: server healthy`):
   1. Es kopiert die von k3s erzeugte Admin-Kubeconfig und ersetzt die Loopback-Adresse
      durch den Netz-Namen `k3s-server:6443`, damit `kubectl` aus dem Container funktioniert.
   2. `kubectl apply -f /manifests` legt Namespace `wif-demo`, ServiceAccount `consumer` und
      das Deployment `consumer` an. Danach `kubectl rollout status deployment/consumer`
      (wartet bis der Pod bereit ist, Timeout 120 s).
   3. Falls noch nicht vorhanden, erzeugt `openssl` ein **selbst-signiertes TLS-Zertifikat**
      für `issuer-web` (`CN=issuer-web`, SAN `DNS:issuer-web`, 10 Jahre gültig) und legt
      `tls.crt` / `tls.key` in das geteilte Volume `oidc-web`.
   4. `kubectl get --raw /.well-known/openid-configuration` und
      `kubectl get --raw /openid/v1/jwks` holen die OIDC-Metadaten des Clusters und
      schreiben sie als `openid-configuration.json` und `jwks.json` in dasselbe Volume.
      Weil der API-Server bereits mit dem externen Issuer konfiguriert ist, stimmen `issuer`
      und `jwks_uri` in diesen Dateien schon - sie werden unverändert übernommen.
   5. Der Container beendet sich (`restart: "no"`). Alle Schritte sind idempotent und laufen
      bei jedem `up` erneut.

3. **issuer-web startet** (`depends_on: bootstrap completed successfully`). nginx liefert
   aus dem Volume `oidc-web` aus:
   - `https://issuer-web/.well-known/openid-configuration` (TLS mit dem Bootstrap-Zertifikat),
   - `https://issuer-web/openid/v1/jwks`,
   - alles andere: `404`.
   - zusätzlich `http://issuer-web/healthz` (nur für den Container-Health-Check).

4. **validator startet** (`depends_on: issuer-web healthy`). `entrypoint.sh` wartet auf
   `/oidc/tls.crt`, dann startet die JVM. Beim Hochfahren macht der Validator die einmalige
   OIDC-Discovery (siehe Use Case 1, Schritt 4) und ist danach unter `:8080` bereit
   (`/healthz` liefert `{"status":"UP"}`; auf dem Host erreichbar unter dem in `.env`
   gesetzten Port, Standard `localhost:18080`).

5. **demo läuft nicht automatisch mit.** Der Service `demo` steckt hinter einem
   Compose-Profil und wird nur mit `docker compose run --rm demo` gestartet (Use Case 1).

### Nachbedingungen

- Im Cluster läuft der `consumer`-Pod mit projiziertem Token.
- `issuer-web` liefert Discovery-Dokument und JWKS aus.
- Der Validator ist bereit und hat die JWKS geladen - ohne je den API-Server berührt zu
  haben.

### Fehlerfälle

| Situation | Ergebnis |
|---|---|
| k3s wird nicht rechtzeitig `ready` | `bootstrap` startet nicht (Compose-Abhängigkeit), `up` schlägt fehl. |
| `consumer`-Rollout überschreitet 120 s | `bootstrap.sh` bricht mit Fehler ab (`set -e`), `issuer-web` und `validator` starten nicht. |
| Discovery-Dokument des Clusters nennt einen anderen `issuer` als `WIF_ISSUER` | Validator wirft beim Start `IllegalStateException`, Container wird nicht `healthy`. |
| `/oidc/tls.crt` erscheint nicht innerhalb von 180 s | `validator/entrypoint.sh` beendet sich mit Fehlercode 1. |

---

## Verifikation auf einen Blick (`docker compose run --rm demo`)

| Abschnitt in `demo.sh` | Was passiert | Erwartung |
|---|---|---|
| 0 | `GET https://issuer-web/.well-known/openid-configuration` (mit `--cacert /oidc/tls.crt`) | `issuer` = `https://issuer-web`, `jwks_uri` gesetzt |
| 1 | `GET https://issuer-web/openid/v1/jwks` | genau ein Schlüssel, `kty` RSA, `alg` `RS256` |
| 2 | `kubectl create token consumer --audience wif-demo-validator --duration 10m` + Payload dekodieren | Claims wie in Use Case 1, Schritt 2 |
| 3 | Pod ruft mit dem **projizierten** Token `/whoami` auf | **HTTP 200** + Claims |
| 4 | Token mit `--audience not-this-service` | **HTTP 401**, `JWT aud claim rejected` |
| 5 | letztes Zeichen des gültigen Tokens ersetzt | **HTTP 401**, `Signed JWT rejected: Invalid signature` |
| 6 (nur `DEMO_EXPIRY=1`) | 10-Minuten-Token, dann pollen bis Ablauf | Statuswechsel **200 → 401** |

Schlägt eine Erwartung fehl, bricht `demo.sh` mit rotem `FAIL:` und Exit-Code 1 ab. Am Ende:
`PASS: all checks passed`.

---

## Weiterlesen

- [Domain / Konzepte](domain.md) - Trust Anchor, offline vs. online, Glossar.
- [Kubernetes-Primer](kubernetes-primer.md) - jeder benutzte Kubernetes-Baustein.
- [ADR 0001](adr/0001-offline-jwks-statt-tokenreview.md) und
  [ADR 0002](adr/0002-eigenstaendiger-issuer-endpoint.md) - die zwei zentralen Design-Entscheidungen.
