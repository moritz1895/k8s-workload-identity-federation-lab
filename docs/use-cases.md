# Use Cases: der Ablauf von Anfang bis Ende

## Für wen ist das / was lernst du hier

Diese Seite erzählt, was im Lab **tatsächlich passiert** - bei jeder Anfrage der Workload
an den externen Dienst, beim Hochfahren (`docker compose up`), beim Abgleich der Schlüssel
durch den Issuer-Pod und bei einem Schlüsselwechsel. Die Schritte sind konkret an dem
festgemacht, was der Code, [`tools/demo.sh`](../tools/demo.sh) und
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
  ┌───────────────────────────────────────────────────┐
  │  server (k3s)  172.31.7.2                         │
  │  API-Server :6443 und Traefik-Node-Port :30443,   │
  │  beide nur auf 172.31.7.2                         │
  │                                                   │
  │  ┌ Namespace wif-issuer ───────────────────────┐  │
  │  │ Pod issuer (2 Replikas)                     │  │
  │  │   sync ── GET alle 15 s ──► API-Server      │  │
  │  │   web (nur GET) ◄── Traefik, Ingress        │  │
  │  │                     issuer.wif.local        │  │
  │  └─────────────────────────────────────────────┘  │
  │  ┌──────────────────┐                             │
  │  │ Pod consumer     │                             │
  │  │ Token-Datei:     │                             │
  │  │ /var/run/secrets/│                             │
  │  │ tokens/sa-token  │                             │
  │  └────────┬─────────┘                             │
  └───────────┼──────────────────────────▲────────────┘
              │                          │ TCP, durchgereicht an 172.31.7.2:30443
              │              ┌───────────┴────────────┐
              │              │ ingress-lb (nginx TCP) │
              │              │ 172.31.8.20:443        │
              │              └───────────▲────────────┘
              │                          │ TLS bis Traefik, interne CA
              │                          │ GET Discovery + JWKS
              │              relying-net │ 172.31.8.0/24
              │              ┌───────────┴────────────┐
              │              │ validator (Spring)     │
              │              │ prüft: Signatur,       │
              │              │ iss, aud, exp, nbf     │
              │              │ 172.31.9.10:8443       │
              │              └───────────▲────────────┘
              │  GET /whoami, Authorization: Bearer <JWT>
              │  workload-net 172.31.9.0/24
              └──── validator.wif.local -> 172.31.9.10 (hostAliases)

   WICHTIG: Der Validator sendet NIE eine Anfrage an den API-Server (server) und kann ihn
            über kein Netz erreichen. Vom Cluster erreicht er nur die Ingress-Route
            https://issuer.wif.local über ingress-lb.
```

---

## Use Case 1: Workload authentisiert sich gegenüber externem Dienst

### Akteure

- **Workload** - der `consumer`-Pod im Cluster (in `demo.sh` handelnd über `kubectl exec`).
- **kubelet** - besorgt und erneuert das Token für den Pod.
- **Validator** - der externe Spring-Boot-Dienst, der das Token prüft.
- **Issuer-Pod** - liefert dem Validator über den Ingress Discovery-Dokument und JWKS.

### Auslöser

Die Workload will `GET /whoami` beim Validator aufrufen und muss sich dafür ausweisen. Im
Lab löst [`tools/demo.sh`](../tools/demo.sh) (Abschnitt 3) diesen Aufruf aus.

### Vorbedingungen

- Cluster, Issuer-Pod, `ingress-lb` und Validator laufen; der Start (Use Case 2) ist
  durchgelaufen und der Issuer-Pod liefert die aktuellen Schlüssel aus (Use Case 3).
- Der Validator hat beim Start erfolgreich OIDC-Discovery gegen `https://issuer.wif.local`
  gemacht: Das Feld `issuer` im Discovery-Dokument war exakt `https://issuer.wif.local`, und
  die `jwks_uri` daraus wurde geladen. (Schlägt das fehl, startet der Validator gar nicht -
  siehe Startfehler.)
- Der `consumer`-Pod hat unter `/var/run/secrets/tokens/sa-token` ein aktuelles Token.

### Hauptablauf (Happy Path)

1. **kubelet fordert das Token an.** Aufgrund der `serviceAccountToken`-Source im
   `projected` Volume ([`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml)) ruft
   das kubelet die TokenRequest-API des API-Servers auf: `audience: wif-demo-validator`,
   `expirationSeconds: 600`. Es erneuert das Token selbstständig vor Ablauf.

2. **Das Token liegt im Pod.** Der API-Server gibt ein signiertes JWT zurück
   (Algorithmus `RS256`, Signatur mit dem aktuellen ServiceAccount-Signaturschlüssel des
   Clusters). Das kubelet legt es als Datei `/var/run/secrets/tokens/sa-token` ab. Inhalt
   des Payloads:

   | Claim | Wert |
   |---|---|
   | `iss` | `https://issuer.wif.local` |
   | `aud` | `["wif-demo-validator"]` |
   | `sub` | `system:serviceaccount:wif-demo:consumer` |
   | `exp`, `iat`, `nbf` | Zeitstempel (Laufzeit 600 s) |
   | `kubernetes.io` | Objekt mit `namespace`, `pod`, `serviceaccount` |

3. **Die Workload ruft den Validator auf.** Der Pod sendet
   `GET https://validator.wif.local:8443/whoami` (TLS, Serverzertifikat der internen CA, geprüft
   mit `--cacert /etc/internal-ca/ca.crt`) mit dem Header
   `Authorization: Bearer <Inhalt der Token-Datei>`. Der Name `validator.wif.local` zeigt
   per `hostAliases` auf `172.31.9.10` (die Adresse des Validators in `workload-net`). In `demo.sh`:
   `kubectl -n wif-demo exec <pod> -- sh -c 'printf "Authorization: Bearer %s\n" "$(cat …/sa-token)" | curl --cacert … -H @- …'`
   (`printf` ist ein Shell-Builtin, das Token steht in keiner Argumentliste).

4. **Der Validator hat die Schlüssel bereits (Discovery beim Start, danach Cache).** Beim
   Hochfahren hat `JwksTrustConfig` das Discovery-Dokument von
   `https://issuer.wif.local/.well-known/openid-configuration` geholt (TLS, Serverzertifikat
   muss von der internen CA stammen), das `issuer`-Feld gegen die Konfiguration geprüft und
   der `jwks_uri` gefolgt - nur, weil sie auf dem HTTPS-Ursprung der Issuer-URL liegt
   (`JwksUriPolicy`). Die JWKS werden **5 Minuten** zwischengespeichert
   (`JWKS_CACHE_TTL_MS = 300000`) und bei Bedarf im Hintergrund aktualisiert; eine
   unbekannte `kid` löst einen sofortigen Abruf aus. Der Validator fragt hierfür **niemals**
   den API-Server.

5. **Der Validator prüft das Token offline** (`TokenValidator`, Nimbus JOSE):
   - Er liest die `kid` (Key-ID) aus dem JWS-Header und wählt den passenden öffentlichen
     Schlüssel aus dem JWKS. Akzeptierte Algorithmen: **nur `RS256` oder `ES256`**.
   - Er prüft die **Signatur** gegen diesen Schlüssel.
   - Er verlangt `iss` **exakt** gleich `https://issuer.wif.local`.
   - Er verlangt, dass `aud` den Wert `wif-demo-validator` **exakt** enthält.
   - Er prüft `exp` und `nbf` (Standard-Toleranz von Nimbus gegen Uhr-Abweichung: 60 s).
   - Er verlangt, dass die Claims `sub`, `iat`, `exp` vorhanden sind.

6. **Antwort bei Erfolg:** HTTP **200** mit JSON-Body:

   ```json
   {
     "authenticated": true,
     "sub": "system:serviceaccount:wif-demo:consumer",
     "iss": "https://issuer.wif.local",
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
| **E5** | **Falscher Issuer.** `iss` im Token ist nicht `https://issuer.wif.local`. | Unit-Test `validate_givenWrongIssuer_thenRejected`. | HTTP **401** | Text enthält `iss` |
| **E6** | **Kein / falsch formatierter Header.** `Authorization` fehlt oder beginnt nicht mit `Bearer `. | Direkter `curl` ohne Header. | HTTP **401** | Body: `{"error":"missing_bearer_token"}` |
| **E7** | **Kaputtes Token.** Kein gültiges JWT-Format. | Unit-Test `validate_givenMalformedToken_thenRejected`. | HTTP **401** | Parser-Fehlermeldung |

> Die genauen `reason`-Texte stammen aus der Bibliothek Nimbus JOSE + JWT und können sich
> zwischen Versionen minimal unterscheiden. Die in
> [`README.md`](../README.md) und [`tools/demo.sh`](../tools/demo.sh) genannten Texte
> (`JWT aud claim rejected`, `Signed JWT rejected: Invalid signature`) sind die, die dieses
> Lab erwartet.

### Startfehler (kein `/whoami`-Aufruf, sondern der Validator startet nicht)

- **Discovery-Issuer passt nicht.** Liefert
  `https://issuer.wif.local/.well-known/openid-configuration` ein `issuer`-Feld, das nicht
  exakt der konfigurierten `WIF_ISSUER` entspricht, wirft `JwksTrustConfig` beim Erzeugen
  der Beans eine `IllegalStateException` und der Spring-Kontext startet nicht. Das ist
  gewollt: Ein Validator mit fehlkonfiguriertem Vertrauensanker soll gar nicht erst laufen.
- **`jwks_uri` auf fremdem Ursprung.** Nennt das Discovery-Dokument eine `jwks_uri`, deren
  Schema, Host oder Port von der Issuer-URL abweicht (oder die Nutzerdaten enthält), wirft
  `JwksUriPolicy` eine `IllegalStateException`, und der Validator startet nicht. So lädt er
  Schlüssel nie von einem anderen Host, der bloß ein Zertifikat derselben CA hat. Geprüft in
  `JwksUriPolicyTest`, nicht in `demo.sh`.
- **Fremde CA.** Vertraut der Validator einer anderen CA als der, die das Serverzertifikat
  des Issuer-Ingress ausgestellt hat, scheitert die Discovery mit
  `PKIX path building failed` und der Validator beendet sich mit einem Fehlercode. Geprüft
  mit dem Service `validator-foreign-ca` (Profil `negative`,
  `WIF_ISSUER_CA=/pki-demo/foreign-ca.crt`) in `run-all-checks.sh`, Abschnitt 3.
- **CA-Zertifikat fehlt.** [`validator/entrypoint.sh`](../validator/entrypoint.sh)
  wartet bis zu 180 s auf die Datei `/trust/ca.crt` (die `pki-init` ablegt) und bricht
  danach mit einem Fehler ab.

---

## Use Case 2: Lab starten (`docker compose up -d --build`)

### Akteure

- **Docker Compose** - startet die Container in Abhängigkeitsreihenfolge.
- **pki-init** - Einmal-Container, der die Lab-PKI anlegt ([`tools/pki-init.sh`](../tools/pki-init.sh)).
- **sa-keys** - Einmal-Container für die ServiceAccount-Signaturschlüssel ([`tools/sa-keys.sh`](../tools/sa-keys.sh)).
- **server** - der k3s-Cluster samt Ingress-Controller Traefik.
- **bootstrap** - Einmal-Container, der den Cluster einrichtet ([`tools/bootstrap.sh`](../tools/bootstrap.sh)).
- **Issuer-Pod** - Deployment `issuer` im Cluster, das die Metadaten ausliefert (Use Case 3).
- **ingress-lb** - Stellvertreter des Load Balancers vor dem Ingress (schreibgeschütztes
  Dateisystem, nur die nötigen Capabilities, `no-new-privileges`).
- **validator** und **keycloak** - starten zuletzt.

### Auslöser

`docker compose up -d --build` auf dem Host. `docker compose run --rm demo` wartet anschließend
über `depends_on`, bis Validator, `service-r` und `keycloak-gateway` gesund sind.

### Vorbedingungen

- Auf dem Host laufen Docker und Compose v2.
- Eine Datei `.env` existiert (aus `.env.example` kopiert). Sie liefert u. a. `WIF_ISSUER`,
  `WIF_AUDIENCE`, das k3s-Image und den Host-Port des Validators.

### Hauptablauf

1. **pki-init legt die Lab-PKI an** (`network_mode: none`). Fehlt noch eine CA, erzeugt es
   die Root-CA `WIF Lab Internal Root CA` und stellt davon die Serverzertifikate aus: für
   den Issuer-Ingress (SAN `DNS:issuer.wif.local`), für Keycloak, `service-r` und den
   Validator. Für Negativtests legt es eine fremde CA an. Jedes Artefakt liegt in einem
   eigenen Volume (`pki-ca`, `ca-trust`, `issuer-tls`, `keycloak-tls`, `service-r-tls`,
   `validator-tls`, `pki-demo`); den CA-Schlüssel sieht nur `pki-init`. Bestehendes
   Material bleibt erhalten.

2. **sa-keys init** legt den ersten Signaturschlüssel an, falls keiner existiert
   (`signing.key`, dazu `verify.pub` mit allen Prüfschlüsseln) - im Volume `sa-keys`.

3. **k3s startet** (`server`, `depends_on: sa-keys completed`). Der API-Server signiert mit
   `service-account-signing-key-file=/sa-keys/signing.key`, veröffentlicht die Schlüssel aus
   `service-account-key-file=/sa-keys/verify.pub` und läuft mit
   `service-account-issuer=https://issuer.wif.local` und
   `service-account-jwks-uri=https://issuer.wif.local/openid/v1/jwks`. Er lauscht nur auf
   `172.31.7.2` in `cluster-net` (`--bind-address`); Node-Ports öffnet kube-proxy ebenfalls
   nur dort (`--nodeport-addresses`). Compose wartet, bis `kubectl get --raw /readyz` grün
   ist.

4. **bootstrap läuft einmal durch** (`depends_on: server healthy, pki-init completed`):
   1. Admin-Kubeconfig kopieren und die Server-Adresse auf `k3s-server:6443` umschreiben.
   2. Namespaces `wif-demo` und `wif-issuer` anlegen.
   3. Secret `issuer-tls` (Serverzertifikat des Ingress + Schlüssel) in `wif-issuer` und
      ConfigMap `internal-ca` (Root-Zertifikat) in `wif-demo` anlegen.
   4. `kubectl apply -f /manifests` (Traefik-Konfiguration, Admission-Regeln, Issuer-Pod
      samt Ingress und NetworkPolicies, Workloads), dann auf die Rollouts von `issuer`,
      Traefik, `consumer`, `reader` und `stranger` warten.
   5. Beenden (`restart: "no"`). Alle Schritte sind idempotent.

   `bootstrap` veröffentlicht selbst nichts.

5. **Der Issuer-Pod gleicht ab** (Use Case 3). Erst nach dem ersten erfolgreichen Abgleich
   ist er bereit und bekommt von Traefik Verkehr.

6. **ingress-lb wird `healthy`** (`depends_on: server healthy`), sobald
   `https://issuer.wif.local/openid/v1/jwks` über ihn mit einem Zertifikat der internen CA
   antwortet.

7. **validator startet** (`depends_on: ingress-lb healthy`). `entrypoint.sh` wartet auf
   `/trust/ca.crt`, dann startet die JVM. Beim Hochfahren macht der Validator die
   OIDC-Discovery (siehe Use Case 1, Schritt 4) und ist danach unter `https://…:8443` bereit
   (`/healthz` liefert `{"status":"UP"}`; auf dem Host unter dem in `.env` gesetzten Port,
   Standard `https://localhost:18080`). Keycloak wartet ebenfalls auf `ingress-lb`.

8. **demo läuft nicht automatisch mit.** `demo` und `validator-foreign-ca` stecken hinter
   Compose-Profilen und laufen nur mit `docker compose run --rm ...`.

### Nachbedingungen

- Im Cluster laufen `consumer` (mit projiziertem Token), `reader`, `stranger` und zwei
  bereite Issuer-Pods.
- `https://issuer.wif.local` liefert Discovery-Dokument und JWKS aus.
- Der Validator ist bereit und hat die JWKS geladen - ohne je den API-Server berührt zu
  haben.

### Fehlerfälle

| Situation | Ergebnis |
|---|---|
| k3s wird nicht rechtzeitig `ready` | `bootstrap` startet nicht (Compose-Abhängigkeit), `up` schlägt fehl. |
| Rollout von `issuer` oder einer Workload überschreitet 180 s, Traefik 300 s | `bootstrap.sh` bricht mit Fehler ab (`set -e`). |
| Issuer-Pod wird nicht bereit (API-Server nicht lesbar, Stand nicht plausibel) | `ingress-lb` wird nie `healthy`, Validator und Keycloak starten nicht. Ursache im Log des Containers `sync`. |
| Discovery-Dokument nennt einen anderen `issuer` als `WIF_ISSUER` | Validator wirft beim Start `IllegalStateException`, Container wird nicht `healthy`. |
| `/trust/ca.crt` erscheint nicht innerhalb von 180 s | `validator/entrypoint.sh` beendet sich mit Fehlercode 1. |

---

## Use Case 3: Issuer-Pod spiegelt und liefert Discovery-Dokument und JWKS

### Akteure

- **Issuer-Pod** - Deployment `issuer` im Namespace `wif-issuer` (zwei Replikas) mit den
  Containern `sync` und `web` ([`manifests/10-issuer.yaml`](../manifests/10-issuer.yaml)).
- **API-Server** - Quelle der Metadaten.
- **Traefik** - Ingress-Controller, veröffentlicht die beiden Pfade unter `issuer.wif.local`.
- **Relying Parties** - Validator und Keycloak, lesen über `ingress-lb`.

### Auslöser

`sync` läuft ab dem Start des Pods und gleicht alle 15 Sekunden ab
(`SYNC_INTERVAL_SECONDS`). Relying Parties lesen bei Bedarf.

### Vorbedingungen

- Der ServiceAccount `issuer` ist per ClusterRoleBinding an die eingebaute ClusterRole
  `system:service-account-issuer-discovery` gebunden (nur `GET` auf
  `/.well-known/openid-configuration` und `/openid/v1/jwks`).
- Nur der Container `sync` bekommt ein ServiceAccount-Token (projiziert, 1 h Laufzeit);
  `web` hat keines.
- Die NetworkPolicies erlauben dem Pod nur eingehend Traefik (Port 8080) und ausgehend den
  API-Server (`172.31.7.2:6443`).
- Secret `issuer-tls` liegt in `wif-issuer`; der Ingress `issuer` verweist darauf.

### Hauptablauf

1. **Je Durchlauf** holt `sync` beide Dokumente vom API-Server (eigenes
   ServiceAccount-Token, Cluster-CA, höchstens 64 KiB, 10 s Zeitlimit).
2. Stimmen sie mit der ausgelieferten Kopie überein, passiert nichts.
3. **Bei einer Abweichung** prüft `sync`, ob der Stand **plausibel** ist: Das
   Discovery-Dokument nennt `issuer` = `https://issuer.wif.local` und `jwks_uri` =
   `https://issuer.wif.local/openid/v1/jwks`, das JWKS enthält mindestens eine `kid`.
4. Für jede `kid`, die hinzukommt oder wegfällt, protokolliert er
   `issuer-sync: WARNING kid appeared: <kid>` bzw. `issuer-sync: WARNING kid vanished: <kid>`.
5. Er schreibt beide Dateien atomar (temporäre Datei, dann umbenennen) in das gemeinsame
   `emptyDir` und protokolliert
   `issuer-sync: serving JWKS sha256=<hash> kids=[ <kid> ... ]`.
6. `web` (nginx, ohne Root) liefert die Kopie nur per `GET` aus; jeder andere Pfad
   antwortet `404`. Die Readiness-Probe fragt `/openid/v1/jwks` ab, ein Pod ist also erst
   nach dem ersten erfolgreichen Abgleich bereit.
7. Traefik leitet nur `https://issuer.wif.local/.well-known/openid-configuration` und
   `https://issuer.wif.local/openid/v1/jwks` an den Service `issuer` weiter. TLS endet in
   Traefik, mit dem Zertifikat aus `issuer-tls`. Die Route trägt die Routing-Priorität
   `1000000000`, höher als jede, die Traefik aus der Länge einer Regel ableitet.

### Fehlerfälle

| # | Situation | Auslöser im Lab | Ergebnis |
|---|---|---|---|
| **I1** | `PUT`, `POST` oder `DELETE` auf das JWKS | `demo.sh` Abschnitt 6 | HTTP **403**; JWKS unverändert |
| **I2** | Pfad, den der Ingress nicht veröffentlicht (`/`) | `demo.sh` Abschnitt 6 | HTTP **404** |
| **I3** | TLS-Handshake über `ingress-lb` für einen fremden Host (SNI `other.wif.local`) | `demo.sh` Abschnitt 6 | kein HTTP-Austausch, Handshake abgelehnt (strict SNI) |
| **I4** | API-Server-Name über `ingress-lb` (SNI `kubernetes.default.svc`) | `demo.sh` Abschnitt 6 | kein HTTP-Austausch; kein Weg zum API-Server |
| **I5** | SNI `issuer.wif.local`, aber `Host: other.wif.local` | `demo.sh` Abschnitt 6 | HTTP **404** oder **421** |
| **I6** | API-Server für die Issuer-Pods nicht erreichbar | `demo resilience`, Abschnitt R1 (NetworkPolicy-Egress entzogen) | Log `reading from the API server failed, keeping the last good state, retrying in 15s`; JWKS unverändert; beide Pods bleiben bereit |
| **I7** | Stand nicht plausibel (Pod erwartet einen anderen Issuer) | `demo resilience`, Abschnitt R2 | Log `REJECTED state: …`; der neue Pod wird nie bereit, die beiden bisherigen liefern unverändert aus |
| **I8** | Relying Party versucht API-Server oder Node-Port direkt | `run-all-checks.sh` Abschnitt 2 | keine Verbindung |

### Schutz des Issuer-Endpoints

Wer bestimmt, was unter der JWKS-URL ausgeliefert wird, kann Tokens fälschen. Der Namespace
`wif-issuer` ist deshalb geschützt wie die Steuerung des Clusters. `demo hardening` prüft
das mit `kubectl apply --dry-run=server`, `kubectl auth can-i` und Aufrufen aus den Pods:

| # | Versuch | Ergebnis |
|---|---|---|
| **H1** | Ingress in `wif-demo` für `issuer.wif.local`, für `*.wif.local` oder `*.local`, mit einer Regel ohne Host, ohne Host mit langer Pfad-Regex (würde die Issuer-Route über die Regellänge überholen), mit Routing-Priorität oder Pfad-Matcher-Annotation, mit Default-Backend | abgewiesen (`ValidatingAdmissionPolicy` `issuer-host-reserved`); ein Ingress für einen anderen Host wird zugelassen. Die Issuer-Route trägt die höchste Routing-Priorität. Traefik liest weder eigene Routen-CRDs noch die Gateway API, nur `Ingress`-Objekte. |
| **H2** | Deployment in `wif-issuer` mit Image nur per Tag | abgewiesen (`issuer-image-digest`); mit festem Digest zugelassen |
| **H3** | ServiceAccounts `wif-demo:consumer` und `wif-issuer:issuer` wollen in `wif-issuer` ConfigMaps, Pods oder Ingresses anlegen, Deployments ändern oder Secrets lesen | jeweils `no`; `issuer` darf nur das JWKS lesen |
| **H4** | Workload ruft den Issuer-Pod direkt auf; Issuer-Pod ruft den Validator auf | keine Verbindung; nur der Weg zum API-Server ist offen |
| **H5** | Härtung der Pods | ohne Root, schreibgeschütztes Root-Dateisystem, keine Capabilities; `web` hat kein ServiceAccount-Token |

---

## Use Case 4: Signaturschlüssel wechseln (zwei Phasen)

### Akteure

- **Betreiber** (im Lab `run-all-checks.sh`, Abschnitt 4).
- **sa-keys**, **server**, **Issuer-Pod**, **validator**, **keycloak**.

### Ablauf

1. `docker compose run --rm demo pre-rotation` - prägt ein Token mit 1 h Laufzeit, speichert
   es und die aktuell veröffentlichten `kid`s im Volume `demo-state` und prüft, dass der
   Validator es annimmt.
2. `docker compose run --rm sa-keys stage` - **Phase 1**: Ein neuer Schlüssel entsteht als
   `staged.key`; sein öffentlicher Schlüssel kommt nur in `verify.pub`. Signiert wird
   weiter mit `signing.key`.
3. `docker compose restart server` und `docker compose up -d --wait server` - kube-apiserver
   liest die Schlüsseldateien nur beim Start.
4. Die Issuer-Pods übernehmen das geänderte JWKS beim nächsten Abgleich und protokollieren
   `WARNING kid appeared: <neue kid>`.
5. `docker compose run --rm demo staged` - wartet bis zu 180 s, bis die neue `kid` unter
   `https://issuer.wif.local/openid/v1/jwks` erscheint, und prüft:
   - jeder Issuer-Pod hat die neue `kid` protokolliert,
   - ein frisches Token trägt noch eine der bisherigen `kid`s (der API-Server signiert
     weiter mit dem aktuellen Schlüssel),
   - der Validator nimmt es an (**200**), der Realm nimmt eine Client-Assertion an (**200**).
6. `docker compose run --rm sa-keys activate` - **Phase 2**: Der vorbereitete Schlüssel wird
   `signing.key`, der bisherige bleibt als Prüfschlüssel (`previous.pub`), ältere fallen aus
   `verify.pub` heraus.
7. Erneut `docker compose restart server` und `docker compose up -d --wait server`.
8. `docker compose run --rm demo post-rotation` - wartet bis zu 180 s, bis der Issuer
   wieder antwortet, und prüft:
   - eine Client-Assertion mit der neuen `kid` nimmt der Realm **beim ersten Versuch** an
     (**200**),
   - ein neues Token mit der neuen `kid` nimmt der Validator beim ersten Versuch an (**200**),
   - das Token von vor dem Wechsel wird weiterhin angenommen (**200**),
   - das JWKS enthält genau den neuen und den vorherigen Schlüssel, keinen weiteren.

### Grenzen

Ein alter Schlüssel bleibt nach `activate` als Prüfschlüssel im JWKS und fällt erst beim
nächsten `activate` heraus. Zwischen zwei `activate` muss deshalb mindestens die maximale
Token-Laufzeit plus die Zeit liegen, die die Relying Parties Schlüssel zwischenspeichern
(Validator 5 min; Keycloak lädt bei unbekannter `kid` neu, frühestens 10 s nach dem letzten
Abruf). Im Lab startet ein Neustart des API-Servers den ganzen Knoten neu, also auch die
Issuer-Pods. Siehe [ADR 0005](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md).

Im Notfall, etwa wenn der vorherige Schlüssel kompromittiert ist, entfernt
`docker compose run --rm sa-keys retire` ihn sofort aus `verify.pub`; nach einem Neustart
des API-Servers liefern die Issuer-Pods das JWKS ohne ihn aus und protokollieren
`WARNING kid vanished: <kid>`. Tokens mit dieser `kid` lehnen die Relying Parties ab,
sobald sie ihre Schlüssel neu geladen haben. `run-all-checks.sh` führt `retire` nicht aus.

---

## Verifikation auf einen Blick

### `docker compose run --rm demo` (Phase `all`)

| Abschnitt in `demo.sh` | Was passiert | Erwartung |
|---|---|---|
| 0 | `GET https://issuer.wif.local/.well-known/openid-configuration` (mit `--cacert /trust/ca.crt`) | `issuer` = `https://issuer.wif.local`, `jwks_uri` gesetzt |
| 1 | `GET https://issuer.wif.local/openid/v1/jwks` | Schlüssel mit `kty` RSA, `alg` `RS256` |
| 2 | `kubectl create token consumer --audience wif-demo-validator --duration 10m` + Payload dekodieren | Claims wie in Use Case 1, Schritt 2 |
| 3 | Pod ruft mit dem **projizierten** Token `https://validator.wif.local:8443/whoami` auf (Token über stdin) | **HTTP 200** + Claims |
| 3 (TLS) | `tls_only_checks` für den Validator: Zertifikat, Klartext auf 8080 und 8443, nur öffentliche CAs | `CN=validator.wif.local` von der Lab-Root-CA; kein Listener auf 8080; kein `200`; curl Exit-Code 60 |
| 4 | Token mit `--audience not-this-service` | **HTTP 401**, `JWT aud claim rejected` |
| 5 | erstes Zeichen der Signatur ersetzt (das letzte base64url-Zeichen trägt nur 2 Datenbits) | **HTTP 401**, `Signed JWT rejected: Invalid signature` |
| 6 | I1-I5 aus Use Case 3 | **403** je Methode, **404**, kein Handshake (2×), **404/421**; JWKS unverändert |
| 7 (nur `DEMO_EXPIRY=1`) | 10-Minuten-Token, dann pollen bis Ablauf | Statuswechsel **200 → 401** |

Schlägt eine Erwartung fehl, bricht `demo.sh` mit rotem `FAIL:` und Exit-Code 1 ab. Am Ende:
`PASS: phase 'all': all checks passed`.

### `docker compose run --rm demo authz`

Die Prüfungen 8–21 zum Autorisierungsserver (Workload → Keycloak → `service-r`) mit
Erwartungen stehen in der
[Feature-Spezifikation, Abschnitt 12](features/keycloak-autorisierungsserver.md#12-testfälle).

### `docker compose run --rm demo hardening` / `resilience`

`hardening`: H1-H5 aus Use Case 3. `resilience`: I6 (Abschnitt R1) und I7 (Abschnitt R2);
danach stellt das Skript NetworkPolicy und Deployment wieder her und prüft, dass das JWKS
ausgeliefert wird.

### `tools/run-all-checks.sh` (auf dem Host)

| Abschnitt | Was passiert | Erwartung |
|---|---|---|
| lab up | `docker compose up -d --build` | alle Services gesund |
| 1 | `demo all` | wie oben |
| 1b | `demo authz` | wie oben |
| 1c | `demo hardening` | wie oben |
| 1d | `demo resilience` | wie oben |
| 2 | von Validator und `service-r` aus `172.31.9.2:6443`, `172.31.7.2:6443`, `172.31.7.2:30443`, `172.31.9.2:30443`; von Keycloak aus `172.31.9.2:6443`, `172.31.7.2:6443`, `172.31.7.2:30443` und die `cluster-net`-Seite von `ingress-lb` (`172.31.7.20:443`) | keine Verbindung; Keycloak erreicht `172.31.8.20:443` (Gegenprobe) |
| 3 | `validator-foreign-ca` | Exit-Code ungleich 0 (`PKIX`) |
| 4 | Schlüsselwechsel (Use Case 4) | alte und neue Tokens werden beim ersten Versuch angenommen, vom Validator wie vom Realm |

---

## Weiterlesen

- [Domain / Konzepte](domain.md) - Trust Anchor, offline vs. online, Glossar.
- [Kubernetes-Primer](kubernetes-primer.md) - jeder benutzte Kubernetes-Baustein.
- [ADR 0001](adr/0001-offline-jwks-statt-tokenreview.md),
  [ADR 0002](adr/0002-eigenstaendiger-issuer-endpoint.md),
  [ADR 0003](adr/0003-getrennte-vertrauensbereiche-interne-pki.md) und
  [ADR 0005](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md) - die zentralen
  Design-Entscheidungen.
