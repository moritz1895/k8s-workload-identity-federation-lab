# Use Cases: der Ablauf von Anfang bis Ende

## Für wen ist das / was lernst du hier

Diese Seite erzählt, was im Lab **tatsächlich passiert** - bei jeder Anfrage der Workload
an den externen Dienst, beim Hochfahren (`docker compose up`), bei jeder Veröffentlichung der
Schlüssel durch den Publisher und bei einer Schlüsselrotation. Die Schritte sind konkret an
dem festgemacht, was der Code, [`tools/demo.sh`](../tools/demo.sh) und
[`tools/run-all-checks.sh`](../tools/run-all-checks.sh) wirklich tun: welche Claims geprüft
werden, welche HTTP-Statuscodes zurückkommen und welche Ablehnungsgründe im Fehlerfall im
Body stehen.

Begriffe werden hier nicht noch einmal erklärt - falls etwas unklar ist, siehe
[domain.md](domain.md) (Konzepte) und [kubernetes-primer.md](kubernetes-primer.md)
(Kubernetes-Bausteine).

---

## Wer spricht mit wem

```
  cluster-net 172.31.7.0/24
  ┌──────────────────────────────────┐
  │  server (k3s)  172.31.7.2        │
  │  API-Server, iss=https://        │      PUT  (mTLS, CN=jwks-publisher)
  │  issuer-web, nur auf 172.31.7.2  │                                    ┌──────────────────────┐
  │                                  │                                    │  issuer-web (nginx)  │
  │  ┌──────────────────┐            │                                    │  172.31.7.20:8443    │
  │  │ Pod jwks-        │ ───────────┼──── alle 15 s bei Änderung ──────► │  Upload, nur PUT     │
  │  │ publisher        │            │                                    │                      │
  │  └──────────────────┘            │                                    │  172.31.8.20:443     │
  │  ┌──────────────────┐            │                                    │  Lesen, nur GET      │
  │  │ Pod consumer     │            │                                    └──────────▲───────────┘
  │  │ Token-Datei:     │            │                                               │ TLS, interne CA
  │  │ /var/run/secrets/│            │                          relying-net          │ 172.31.8.0/24
  │  │ tokens/sa-token  │            │                                    ┌──────────┴───────────┐
  │  └────────┬─────────┘            │                                    │  validator (Spring)  │
  └───────────┼──────────────────────┘                                    │  prüft: Signatur,    │
              │  GET /whoami, Authorization: Bearer <JWT>                 │  iss, aud, exp, nbf  │
              │  workload-net 172.31.9.0/24                               │  172.31.9.10:8080    │
              └──── validator.wif.local -> 172.31.9.10 (hostAliases) ───► └──────────────────────┘

   WICHTIG: Der Validator sendet NIE eine Anfrage an den API-Server (server) und kann ihn
            über kein Netz erreichen. Er spricht ausschließlich mit issuer-web.
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

- Cluster, `issuer-web` und Validator laufen; der Start (Use Case 2) ist durchgelaufen und
  der Publisher hat die aktuellen Schlüssel veröffentlicht (Use Case 3).
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
   per `hostAliases` auf `172.31.9.10` (die Adresse des Validators in `workload-net`). In `demo.sh`:
   `kubectl -n wif-demo exec <pod> -- sh -c 'curl ... -H "Authorization: Bearer $(cat /var/run/secrets/tokens/sa-token)" ...'`.

4. **Der Validator hat die Schlüssel bereits (Discovery beim Start, danach Cache).** Beim
   Hochfahren hat `JwksTrustConfig` das Discovery-Dokument von
   `https://issuer-web/.well-known/openid-configuration` geholt (TLS, Serverzertifikat muss
   von der internen CA stammen), das `issuer`-Feld gegen die Konfiguration geprüft und der
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
| **E2** | **Abgelaufen.** `exp` liegt (mehr als 60 s) in der Vergangenheit. | `demo.sh` Abschnitt 7 (`DEMO_EXPIRY=1`): 10-Minuten-Token, dann warten, bis `/whoami` von `200` auf `401` kippt. | HTTP **401** | Text enthält `expired` (Nimbus: `Expired JWT`) |
| **E3** | **Manipulierte Signatur.** Ein Zeichen des gültigen Tokens wurde verändert. | `demo.sh` Abschnitt 5: `tamper_signature`: erstes Signaturzeichen ersetzt (das letzte trägt nur teilweise Nutzbits) | HTTP **401** | `Signed JWT rejected: Invalid signature` |
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
- **Fremde CA.** Vertraut der Validator einer anderen CA als der, die das Serverzertifikat
  von `issuer-web` ausgestellt hat, scheitert die Discovery mit `PKIX path building failed`
  und der Validator beendet sich mit einem Fehlercode. Geprüft mit dem Service
  `validator-foreign-ca` (Profil `negative`, `WIF_ISSUER_CA=/pki-demo/foreign-ca.crt`) in
  `run-all-checks.sh`, Abschnitt 3.
- **CA-Zertifikat fehlt.** [`validator/entrypoint.sh`](../validator/entrypoint.sh)
  wartet bis zu 180 s auf die Datei `/trust/ca.crt` (die `pki-init` ablegt) und bricht
  danach mit einem Fehler ab.

---

## Use Case 2: Lab starten (`docker compose up -d --build`)

### Akteure

- **Docker Compose** - startet die Container in Abhängigkeitsreihenfolge.
- **pki-init** - Einmal-Container, der die Lab-PKI anlegt ([`tools/pki-init.sh`](../tools/pki-init.sh)).
- **sa-keys** - Einmal-Container für die ServiceAccount-Signaturschlüssel ([`tools/sa-keys.sh`](../tools/sa-keys.sh)).
- **server** - der k3s-Cluster.
- **bootstrap** - Einmal-Container, der den Cluster einrichtet ([`tools/bootstrap.sh`](../tools/bootstrap.sh)).
- **jwks-publisher** - Deployment im Cluster, das die Metadaten hochlädt (Use Case 3).
- **issuer-web** - der nginx, der die Metadaten ausliefert.
- **validator** - startet zuletzt.

### Auslöser

`docker compose up -d --build` auf dem Host. `docker compose run --rm demo` wartet anschließend
über `depends_on`, bis der Validator gesund ist.

### Vorbedingungen

- Auf dem Host laufen Docker und Compose v2.
- Eine Datei `.env` existiert (aus `.env.example` kopiert). Sie liefert u. a. `WIF_ISSUER`,
  `WIF_AUDIENCE`, das k3s-Image und den Host-Port des Validators.

### Hauptablauf

1. **pki-init legt die Lab-PKI an** (`network_mode: none`). Fehlt noch eine CA, erzeugt es
   die Root-CA `WIF Lab Internal Root CA` und stellt davon aus: das Serverzertifikat von
   `issuer-web` (SAN `DNS:issuer-web`, `serverAuth`), das Client-Zertifikat des Publishers
   (`CN=jwks-publisher`, `clientAuth`) und Material für Negativtests (Client-Zertifikat mit
   `CN=not-the-publisher`, eine fremde CA samt Client-Zertifikat). Jedes Artefakt liegt in
   einem eigenen Volume (`pki-ca`, `ca-trust`, `issuer-tls`, `publisher-tls`, `pki-demo`);
   den CA-Schlüssel sieht nur `pki-init`. Bestehendes Material bleibt erhalten.

2. **sa-keys init** legt den ersten Signaturschlüssel an, falls keiner existiert
   (`signing.key`, dazu `verify.pub` mit allen Prüfschlüsseln) - im Volume `sa-keys`.

3. **k3s startet** (`server`, `depends_on: sa-keys completed`). Der API-Server signiert mit
   `service-account-signing-key-file=/sa-keys/signing.key`, veröffentlicht die Schlüssel aus
   `service-account-key-file=/sa-keys/verify.pub` und läuft mit
   `service-account-issuer=https://issuer-web` und
   `service-account-jwks-uri=https://issuer-web/openid/v1/jwks`. Er lauscht nur auf
   `172.31.7.2` in `cluster-net` (`--bind-address`). Compose wartet, bis
   `kubectl get --raw /readyz` grün ist.

4. **issuer-web startet** (`depends_on: pki-init completed`) mit Serverzertifikat aus
   `issuer-tls` und CA aus `ca-trust`. Es liefert zunächst nichts aus (`404`) und gilt erst
   als `healthy`, wenn der Publisher das JWKS hochgeladen hat (Healthcheck: Datei
   `/oidc/openid/v1/jwks` existiert und ist nicht leer).

5. **bootstrap läuft einmal durch** (`depends_on: server healthy, pki-init completed`):
   1. Admin-Kubeconfig kopieren und die Server-Adresse auf `k3s-server:6443` umschreiben.
   2. Namespaces `wif-demo` und `wif-publisher` anlegen.
   3. Secret `jwks-publisher-mtls` (Client-Zertifikat + Schlüssel) und ConfigMap
      `internal-ca` (Root-Zertifikat) in `wif-publisher` anlegen.
   4. `kubectl apply -f /manifests`, dann auf den Rollout von `jwks-publisher` und
      `consumer` warten (je 180 s).
   5. Beenden (`restart: "no"`). Alle Schritte sind idempotent.

   `bootstrap` veröffentlicht selbst nichts und spricht `issuer-web` nicht an.

6. **Der Publisher lädt hoch** (Use Case 3). Danach wird `issuer-web` `healthy`.

7. **validator startet** (`depends_on: issuer-web healthy`). `entrypoint.sh` wartet auf
   `/trust/ca.crt`, dann startet die JVM. Beim Hochfahren macht der Validator die
   OIDC-Discovery (siehe Use Case 1, Schritt 4) und ist danach unter `:8080` bereit
   (`/healthz` liefert `{"status":"UP"}`; auf dem Host unter dem in `.env` gesetzten Port,
   Standard `localhost:18080`).

8. **demo läuft nicht automatisch mit.** `demo` und `validator-foreign-ca` stecken hinter
   Compose-Profilen und laufen nur mit `docker compose run --rm ...`.

### Nachbedingungen

- Im Cluster laufen `consumer` (mit projiziertem Token) und `jwks-publisher`.
- `issuer-web` liefert Discovery-Dokument und JWKS aus.
- Der Validator ist bereit und hat die JWKS geladen - ohne je den API-Server berührt zu
  haben.

### Fehlerfälle

| Situation | Ergebnis |
|---|---|
| k3s wird nicht rechtzeitig `ready` | `bootstrap` startet nicht (Compose-Abhängigkeit), `up` schlägt fehl. |
| Rollout von `jwks-publisher` oder `consumer` überschreitet 180 s | `bootstrap.sh` bricht mit Fehler ab (`set -e`). |
| Publisher kann nicht hochladen (z. B. Zertifikat abgelehnt) | `issuer-web` wird nie `healthy`, der Validator startet nicht. Ursache im Log von `jwks-publisher` und `issuer-web`. |
| Discovery-Dokument nennt einen anderen `issuer` als `WIF_ISSUER` | Validator wirft beim Start `IllegalStateException`, Container wird nicht `healthy`. |
| `/trust/ca.crt` erscheint nicht innerhalb von 180 s | `validator/entrypoint.sh` beendet sich mit Fehlercode 1. |

---

## Use Case 3: Publisher veröffentlicht Discovery-Dokument und JWKS

### Akteure

- **jwks-publisher** - Pod im Namespace `wif-publisher`, ServiceAccount `jwks-publisher`
  ([`manifests/10-publisher.yaml`](../manifests/10-publisher.yaml)).
- **API-Server** - Quelle der Metadaten.
- **issuer-web** - Ziel des Uploads (Listener `:8443`).

### Auslöser

Der Publisher-Pod startet, danach alle 15 Sekunden (`PUBLISH_INTERVAL_SECONDS`).

### Vorbedingungen

- Der ServiceAccount `jwks-publisher` ist per ClusterRoleBinding an die eingebaute
  ClusterRole `system:service-account-issuer-discovery` gebunden (nur `GET` auf
  `/.well-known/openid-configuration` und `/openid/v1/jwks`).
- Secret `jwks-publisher-mtls` und ConfigMap `internal-ca` sind eingehängt (`/mtls`, `/trust`).
- `issuer-web` ist im Pod per `hostAliases` als `172.31.7.20` (Adresse in `cluster-net`)
  bekannt.

### Hauptablauf

1. **Je Durchlauf** (alle 15 s) holt der Publisher beide Dokumente vom API-Server
   (`https://kubernetes.default.svc`, eigenes ServiceAccount-Token, Cluster-CA).
2. Er liest, was `issuer-web` gerade öffentlich ausliefert (`https://issuer-web`, `:443`).
3. Er bildet je einen SHA-256 über beide Stände. Stimmen sie überein, passiert nichts.
   Liefert `issuer-web` etwas aus, das der Publisher nicht selbst hochgeladen hat, loggt er
   eine Warnung (`WARNING issuer serves content this publisher did not upload`) und fährt
   mit dem Upload fort.
4. **Bei einer Abweichung** lädt er per `PUT` hoch, zuerst das JWKS, dann das
   Discovery-Dokument, an `https://issuer-web:8443/...` - mit Client-Zertifikat
   (`/mtls/tls.crt`) und Prüfung des Serverzertifikats gegen `/trust/ca.crt`.
5. `issuer-web` prüft das Client-Zertifikat gegen die interne CA und den `CN`, speichert die
   Dokumente unter ihrem URL-Pfad im Volume `oidc-web` und protokolliert den Upload mit dem
   DN des Clients.
6. Der Publisher loggt
   `publisher: published JWKS sha256=<hash> kids=[ ... ] previous=[ ... ]`.

### Fehlerfälle (Schreibzugriff)

| # | Situation | Auslöser im Lab | Ergebnis |
|---|---|---|---|
| **U1** | Upload ohne Client-Zertifikat | `demo.sh` Abschnitt 6 | HTTP **400** (nginx: kein Zertifikat gesendet) |
| **U2** | Client-Zertifikat einer fremden CA (`CN=jwks-publisher`) | `demo.sh` Abschnitt 6, `/pki-demo/foreign-publisher.crt` | HTTP **400** (Zertifikatsprüfung fehlgeschlagen) |
| **U3** | Zertifikat der internen CA, aber `CN=not-the-publisher` | `demo.sh` Abschnitt 6, `/pki-demo/wrong-cn.crt` | HTTP **403** |
| **U3b** | Zertifikat der internen CA, `CN=jwks-publisher` nur im Feld `O` versteckt | `demo.sh` Abschnitt 6, `/pki-demo/smuggled-cn.crt` | HTTP **403** (exakter DN-Vergleich) |
| **U4** | `PUT` auf den öffentlichen Listener `:443` | `demo.sh` Abschnitt 6 | HTTP **403** (`limit_except GET`) |
| **U5** | Upload-Listener aus `relying-net` | `run-all-checks.sh` Abschnitt 2: `172.31.8.20:8443` vom Validator | nicht erreichbar (`:8443` lauscht nur auf `172.31.7.20`) |
| - | API-Server nicht lesbar | - | Log `reading from the API server failed`, neuer Versuch nach 15 s |
| - | Upload scheitert | - | Log `upload failed`, neuer Versuch nach 15 s |

Nach U1-U4 prüft `demo.sh`, dass das veröffentlichte JWKS weiterhin Schlüssel enthält.

---

## Use Case 4: Signaturschlüssel rotieren

### Akteure

- **Betreiber** (im Lab `run-all-checks.sh`, Abschnitt 4).
- **sa-keys**, **server**, **jwks-publisher**, **validator**.

### Ablauf

1. `docker compose run --rm demo pre-rotation` - prägt ein Token mit 1 h Laufzeit, speichert
   es und die aktuell veröffentlichten `kid`s im Volume `demo-state` und prüft, dass der
   Validator es annimmt.
2. `docker compose run --rm sa-keys rotate` - der bisherige öffentliche Schlüssel wird zu
   `previous.pub`, ein neuer Schlüssel wird `signing.key`; `verify.pub` enthält danach beide
   öffentlichen Schlüssel. Ältere als der vorherige fallen heraus.
3. `docker compose restart server` und `docker compose up -d --wait server` - kube-apiserver
   liest die Schlüsseldateien nur beim Start.
4. Der Publisher erkennt das geänderte JWKS beim nächsten Durchlauf und lädt es hoch.
5. `docker compose run --rm demo post-rotation` - wartet bis zu 120 s auf eine neue `kid` am
   Issuer-Endpoint, prägt ein neues Token und prüft:
   - das neue Token trägt die neue `kid` und wird angenommen (**200**),
   - das Token von vor der Rotation wird weiterhin angenommen (**200**), weil der vorherige
     Schlüssel im JWKS bleibt.

### Grenzen

Der alte Schlüssel bleibt bis zur nächsten Rotation im JWKS. Das ist nur sicher, solange
zwischen zwei Rotationen mehr Zeit liegt als maximale Token-Laufzeit plus JWKS-Cache-TTL des
Validators (5 min). Siehe [ADR 0003](adr/0003-getrennte-vertrauensbereiche-interne-pki.md).

---

## Verifikation auf einen Blick

### `docker compose run --rm demo` (Phase `all`)

| Abschnitt in `demo.sh` | Was passiert | Erwartung |
|---|---|---|
| 0 | `GET https://issuer-web/.well-known/openid-configuration` (mit `--cacert /trust/ca.crt`) | `issuer` = `https://issuer-web`, `jwks_uri` gesetzt |
| 1 | `GET https://issuer-web/openid/v1/jwks` | Schlüssel mit `kty` RSA, `alg` `RS256` |
| 2 | `kubectl create token consumer --audience wif-demo-validator --duration 10m` + Payload dekodieren | Claims wie in Use Case 1, Schritt 2 |
| 3 | Pod ruft mit dem **projizierten** Token `/whoami` auf | **HTTP 200** + Claims |
| 4 | Token mit `--audience not-this-service` | **HTTP 401**, `JWT aud claim rejected` |
| 5 | letztes Zeichen des gültigen Tokens ersetzt | **HTTP 401**, `Signed JWT rejected: Invalid signature` |
| 6 | Upload-Versuche U1-U4 | **400, 400, 403, 403**; JWKS unverändert |
| 7 (nur `DEMO_EXPIRY=1`) | 10-Minuten-Token, dann pollen bis Ablauf | Statuswechsel **200 → 401** |

Schlägt eine Erwartung fehl, bricht `demo.sh` mit rotem `FAIL:` und Exit-Code 1 ab. Am Ende:
`PASS: phase 'all': all checks passed`.

### `tools/run-all-checks.sh` (auf dem Host)

| Abschnitt | Was passiert | Erwartung |
|---|---|---|
| lab up | `docker compose up -d --build` | alle Services gesund |
| 1 | `demo all` | wie oben |
| 2 | vom Validator aus `172.31.9.2:6443`, `172.31.7.2:6443`, `172.31.8.20:8443` | keine Verbindung |
| 3 | `validator-foreign-ca` | Exit-Code ungleich 0 (`PKIX`) |
| 4 | Rotation (Use Case 4) | neue und alte Tokens werden angenommen |

---

## Weiterlesen

- [Domain / Konzepte](domain.md) - Trust Anchor, offline vs. online, Glossar.
- [Kubernetes-Primer](kubernetes-primer.md) - jeder benutzte Kubernetes-Baustein.
- [ADR 0001](adr/0001-offline-jwks-statt-tokenreview.md),
  [ADR 0002](adr/0002-eigenstaendiger-issuer-endpoint.md) und
  [ADR 0003](adr/0003-getrennte-vertrauensbereiche-interne-pki.md) - die zentralen
  Design-Entscheidungen.
