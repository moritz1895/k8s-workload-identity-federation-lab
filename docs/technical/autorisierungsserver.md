# Autorisierungsserver: Keycloak, Realm `domain-rst` und Dienst R

**Für wen / was lernst du hier:** Du kennst Spring Security und OAuth2 grob, aber nicht dieses
Lab. Diese Seite erklärt, wie Keycloak als Autorisierungsserver des Fachbereichs konfiguriert
ist, wie er ServiceAccount-Tokens als Client-Nachweis annimmt, was der Realm enthält, wie
Workloads Keycloak nur über ein Gateway erreichen, wie `service-r` Access-Tokens prüft und wie
eine Workload ihr Access-Token holt und cacht. Dazu das im Lab gemessene Verhalten von
Keycloak und die bewussten Lab-Vereinfachungen. Fachlicher Ablauf und Akzeptanzkriterien:
[../features/keycloak-autorisierungsserver.md](../features/keycloak-autorisierungsserver.md),
Entscheidung: [ADR 0004](../adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md).

---

## Überblick

```
      workload-net 172.31.9.0/24                         relying-net 172.31.8.0/24
 Pod consumer ── POST /token (HTTPS) ──► keycloak-gateway ──► keycloak .30:8443 ── Discovery + JWKS ──► issuer-web :443
   (keycloak = 172.31.9.30)              .9.30 / .8.31         Realm domain-rst
      │                                  nur /realms/domain-rst/        ▲
      │                                                                 │ Discovery + JWKS (beim ersten Token)
      └── GET /orders (HTTP), Bearer <Access-Token> ──► service-r .9.40 / .8.40

 Host: 127.0.0.1:18081 → service-r; 127.0.0.1:18443 → keycloak-admin (nur Profil admin)
```

| Bauteil | Datei | Aufgabe |
|---|---|---|
| `keycloak` | `compose.yaml`, `keycloak/realm-domain-rst.json` | prüft das ServiceAccount-Token, ordnet es einem Client zu, stellt Access-Tokens mit den zugeordneten Scopes aus |
| `keycloak-gateway` | `tools/nginx-keycloak-gateway.conf` | einziger Weg der Workloads zu Keycloak; leitet nur `/realms/domain-rst/` weiter |
| `keycloak-admin` | `tools/nginx-keycloak-admin.conf` | Admin-Konsole vom Host, nur bei Bedarf (Profil `admin`) |
| `service-r` | `service-r/` | Spring-Security-Resource-Server; prüft Access-Tokens und schützt Endpunkte nach Scope |
| `access-token.sh` | `manifests/30-authz-workloads.yaml` (ConfigMap `authz-client`) | holt Access-Tokens in der Workload und cacht sie |

---

## Keycloak

### Betriebsmodus

Keycloak `26.8.2` läuft mit `start --import-realm`, also im Produktionsmodus, aber als
einzelner Knoten mit eingebetteter Datei-Datenbank. Der Dev-Modus (`start-dev`) öffnet immer
HTTP auf 8080; im `start`-Modus mit `KC_HTTP_ENABLED=false` spricht Keycloak ausschließlich
HTTPS auf 8443.

| Einstellung | Wert | Wirkung |
|---|---|---|
| `KC_DB` | `dev-file` | eingebettete Datei-Datenbank im Container, keine externe DB (nur Lab) |
| `KC_HOSTNAME` | `https://keycloak:8443` | fester Issuer-Hostname: Pods (über das Gateway), `demo` und `service-r` sehen denselben `iss` |
| `KC_HOSTNAME_ADMIN` | `https://localhost:${KEYCLOAK_HOST_PORT}` | URL der Admin-Konsole über `keycloak-admin` |
| `KC_HTTP_ENABLED` | `false` | kein HTTP-Listener |
| `KC_HTTPS_CERTIFICATE_FILE` / `_KEY_FILE` | `/tls/tls.crt`, `/tls/tls.key` | Serverzertifikat aus Volume `keycloak-tls` (`pki-init`) |
| `KC_TRUSTSTORE_PATHS` | `/trust/ca.crt` | ergänzt Keycloaks Default-Truststore um die Lab-CA (für TLS zu `issuer-web`); öffentliche CAs bleiben vertraut |
| `KC_CACHE` | `local` | lokaler Cache statt Infinispan-Cluster |
| `KC_HEALTH_ENABLED` | `true` | `/health/ready` auf dem Management-Port 9000 |
| `KC_HTTP_MANAGEMENT_SCHEME` | `http` | Management-Port 9000 spricht HTTP (sonst erbt er HTTPS) |
| `KC_FEATURES_DISABLED` | `identity-brokering-api,twitter-broker` | schaltet zwei standardmäßig aktive, als veraltet markierte Features ab; hält das Log frei von Warnungen |
| `KC_SPI_STICKY_SESSION_ENCODER__INFINISPAN__SHOULD_ATTACH_ROUTE` | `false` | keine Routen-Anhänge für Sticky Sessions; ohne Cluster sinnlos und sonst eine Warnung im Log |
| `JAVA_OPTS_KC_HEAP` | `-XX:MaxRAMPercentage=70` | Heap relativ zu `mem_limit: 1g` |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `_PASSWORD` | aus `.env` | Lab-Admin der Admin-Konsole, kein Geheimnis |

Föderierte Client-Authentisierung (`client-auth-federated`) und der Kubernetes-Identity-Provider
(`kubernetes-service-accounts`) sind in 26.8.2 standardmäßig aktiv; `KC_FEATURES` ist nicht
gesetzt.

**Healthcheck.** Das Image enthält kein `curl`. Der Healthcheck schickt per Bash-`/dev/tcp`
ein `GET /health/ready` an `localhost:9000` und sucht `UP`. Beim ersten Start meldet
`/health/ready` bereits `UP`, während die Realm-Endpunkte noch `503` („Bootstrap in
progress“) liefern. Prüfung 8 in `tools/demo.sh` wiederholt die Realm-Discovery deshalb bis
zu 60 s.

**Realm-Import.** `./keycloak/realm-domain-rst.json` ist read-only nach
`/opt/keycloak/data/import/` gemountet. `--import-realm` legt den Realm nur an, wenn er noch
nicht existiert (Strategie `IGNORE_EXISTING`); Änderungen an der Datei wirken erst nach
Neuerstellung des Containers. Die Datenbank liegt im Container: Wird er neu erstellt,
entstehen neue Realm-Schlüssel, und gecachte Access-Tokens werden bei `service-r` ungültig.

### Föderierte Client-Authentisierung

Der Realm vertraut dem Cluster über einen Identity-Provider:

```json
{ "alias": "lab-cluster", "providerId": "kubernetes", "config": { "issuer": "https://issuer-web" } }
```

Jeder Workload-Client bindet sich daran:

```json
"clientAuthenticatorType": "federated-jwt",
"attributes": {
  "jwt.credential.issuer": "lab-cluster",
  "jwt.credential.sub": "system:serviceaccount:wif-demo:consumer"
}
```

`jwt.credential.issuer` ist der **Alias** des Identity-Providers, nicht die Issuer-URL.
Bei einer Token-Anfrage findet Keycloak über `iss` der Client-Assertion den Identity-Provider,
prüft Signatur, `exp`, `nbf` und `aud` (= Realm-Issuer-URL) und sucht den Client mit passendem
`jwt.credential.sub`. Die Schlüssel lädt Keycloak lazy beim ersten Bedarf über
`https://issuer-web/.well-known/openid-configuration` → `jwks_uri` von `issuer-web` (über
`relying-net`, TLS mit Lab-CA) und hält sie im Cache. Eine Verbindung zum API-Server gibt es
nicht.

Weil der `sub` des ServiceAccount-Tokens die Workload identifiziert, gehört das
Cluster-RBAC zur Autorisierungsgrenze: Wer im Namespace `wif-demo` Tokens für einen
ServiceAccount anfordern (`serviceaccounts/token`, `create`) oder Pods mit einem bestimmten
`serviceAccountName` anlegen darf, bekommt dessen Scopes.

### Realm-Inhalt (`keycloak/realm-domain-rst.json`)

- Realm `domain-rst`, `accessTokenLifespan: 300`, Events `CLIENT_LOGIN` und
  `CLIENT_LOGIN_ERROR`, Admin-Events mit Details.
- `defaultDefaultClientScopes` und `defaultOptionalClientScopes` leer: kein `profile`,
  `email`, `roles`.
- Client-Scopes mit `include.in.token.scope: true` und je einem `oidc-audience-mapper`:

  | Scope | Audienz |
  |---|---|
  | `r:orders:read`, `r:orders:write`, `r:orders:admin` | `service-r` |
  | `s:inventory:read` | `service-s` |

- Clients, alle `serviceAccountsEnabled: true`, alle Browser-/Passwort-Flows aus,
  `fullScopeAllowed: false`, keine Default-Client-Scopes:

  | Client | `jwt.credential.sub` | optionale Client-Scopes |
  |---|---|---|
  | `workload-a` | `system:serviceaccount:wif-demo:consumer` | `r:orders:read`, `r:orders:write`, `s:inventory:read` |
  | `workload-b` | `system:serviceaccount:wif-demo:reader` | `r:orders:read` |

  `r:orders:admin` ist keinem Client zugeordnet; `wif-demo:stranger` hat keinen Client.

Eine Workload fordert pro Ressourcendienst ein eigenes Token an: Mischt sie Scopes
verschiedener Dienste (z. B. `r:orders:read s:inventory:read`), bekommt das Token zwei
Audienzen, und `service-r` lehnt es ab.

### Gemessenes Verhalten

Gemessen im Lab mit `tools/demo.sh authz` und der Rotationsprüfung:

| Situation | Antwort von Keycloak |
|---|---|
| Scope angefragt, der dem Client nicht zugeordnet ist | `400 invalid_scope` („Invalid scopes: …“); der Scope wird nicht stillschweigend weggelassen |
| gültiges ServiceAccount-Token ohne Client im Realm (`stranger`) | `401 invalid_client` |
| ServiceAccount-Token mit falscher Audienz (`sa-token` des Validators) | `400 invalid_client`, „Invalid token audience“ |
| gefälschte Assertion: fremder Issuer | `401 invalid_client` |
| gefälschte Assertion: `iss=https://issuer-web`, echte `kid`, fremder Schlüssel | `401 invalid_client` |
| dasselbe ServiceAccount-Token mehrfach als Assertion | akzeptiert; für Kubernetes-Tokens gibt es keine Einmal-Prüfung |
| Assertion mit neuer `kid` nach Schlüsselrotation | akzeptiert; Keycloak lädt das JWKS bei unbekannter `kid` neu |

Die Wiederverwendbarkeit ist Voraussetzung für den Cache in der Workload: Das kubelet tauscht
`kc-token` (600 s) erst nach rund acht Minuten aus, bis dahin liest jede Erneuerung dieselbe
Datei.

Access-Token von `workload-a` für `scope=r:orders:read r:orders:write`:

| Claim | Wert |
|---|---|
| `iss` | `https://keycloak:8443/realms/domain-rst` |
| `aud` | `"service-r"` (String, kein Array) |
| `typ` | `Bearer` |
| `azp` | `workload-a` |
| `scope` | `r:orders:write r:orders:read` – Reihenfolge nicht garantiert, nur als Menge vergleichen |
| `sub` | UUID des Service-Account-Benutzers des Clients (nicht die Client-ID) |
| `exp` | `iat` + 300 |

---

## Erreichbarkeit: Gateway und Admin-Zugang

Keycloak hängt nur in `relying-net` (172.31.8.30, Alias `keycloak`) und veröffentlicht
**keinen** Host-Port. Gemessen: Docker macht einen veröffentlichten Container-Port auch aus
den anderen Bridge-Netzen erreichbar, unabhängig von der Host-Adresse, an die er gebunden
ist – ein Pod erreichte `keycloak:8443` über 172.31.8.30, solange der Port veröffentlicht
war. Nicht veröffentlichte Ports (`issuer-web :443`, Keycloak `:9000`) bleiben isoliert.

### `keycloak-gateway`

nginx (`${NGINX_IMAGE}`) in `relying-net` (172.31.8.31) und `workload-net` (172.31.9.30);
`mem_limit: 64m`. Die Pods lösen `keycloak` per `hostAliases` auf 172.31.9.30 auf.

- TLS auf 8443 mit dem Keycloak-Zertifikat: Pods sprechen dieselbe Issuer-URL
  `https://keycloak:8443/realms/domain-rst` wie `service-r`.
- `location /realms/domain-rst/` mit `limit_except GET POST` leitet an
  `https://keycloak:8443/realms/domain-rst/` weiter (TLS zu Keycloak mit Lab-CA geprüft,
  `proxy_ssl_name keycloak`). Weil `proxy_pass` eine URI trägt, gibt nginx den
  normalisierten Pfad weiter: `/realms/domain-rst/../master/…` verlässt den Realm nicht.
- Alles andere – `/admin`, `/realms/master`, andere Realms – beantwortet das Gateway mit
  `404`. Der Management-Port 9000 ist von `workload-net` aus nicht erreichbar.
- Healthcheck `nc -z 127.0.0.1 8443` (`localhost` löst zuerst auf `::1` auf, nginx lauscht
  nur IPv4).

### `keycloak-admin` (Profil `admin`)

nginx in `relying-net` (172.31.8.32), veröffentlicht auf `127.0.0.1:${KEYCLOAK_HOST_PORT}`
(Standard 18443), reicht alles an Keycloak durch.

```bash
docker compose --profile admin up -d keycloak-admin   # https://localhost:18443/admin/
docker compose stop keycloak-admin
```

Solange `keycloak-admin` läuft, ist sein Port aus demselben Docker-Verhalten auch von
`workload-net` aus erreichbar. Er läuft deshalb nur bei Bedarf.

---

## `service-r` – der Resource Server

Spring Boot 4.1 / Java 25, Paket `ms.rohde.wifpoc.servicer`, flach wie der Validator. Läuft
als `USER 10001`.

### Konfiguration

`application.yaml` bindet eigene Properties (`ServiceRProperties`, `@ConfigurationProperties("service-r")`):

| Property | Umgebung | Default |
|---|---|---|
| `service-r.issuer` | `KC_REALM_ISSUER` | `https://keycloak:8443/realms/domain-rst` |
| `service-r.audience` | `SERVICE_R_AUDIENCE` | `service-r` |

Die Spring-Boot-Properties `spring.security.oauth2.resourceserver.jwt.*` werden nicht
verwendet; den `JwtDecoder` baut `SecurityConfig` selbst.

### `JwtDecoder` (`SecurityConfig.jwtDecoder`)

- `NimbusJwtDecoder.withIssuerLocation(issuer)` macht OIDC-Discovery am Realm und lädt das
  JWKS über die `jwks_uri` (direkt bei Keycloak über `relying-net`).
- Eingepackt in `SupplierJwtDecoder`: Discovery läuft beim ersten Token, nicht beim Start.
  Scheitert sie, wird sie mit dem nächsten Token erneut versucht. R startet damit unabhängig
  von Keycloak und hat in `compose.yaml` kein `depends_on` auf ihn.
- `.jwsAlgorithm(SignatureAlgorithm.RS256)`: nur RS256; ein mit dem öffentlichen RSA-Schlüssel
  als HMAC-Geheimnis signiertes HS256-Token wird abgelehnt.
- Validatoren (`AccessTokenValidators.forIssuerAndAudience`), alle müssen bestehen:

  | Validator | Regel |
  |---|---|
  | `JwtValidators.createDefaultWithIssuer(issuer)` | Zeitstempel mit 60 s Toleranz, exakter `iss` |
  | `aud` | genau `["service-r"]`; ein Token mit mehreren Audienzen wird abgelehnt, damit ein anderer Dienst (z. B. S) ein für ihn mit ausgestelltes Token nicht bei R wiederverwenden kann |
  | `typ` | `Bearer` (kein ID-Token) |
  | `azp` | vorhanden und nicht leer |

  Jeder Verstoß ergibt `401`.

### Authorities und Principal

`JwtAuthenticationConverter` mit `JwtGrantedAuthoritiesConverter` bildet jeden Eintrag aus
`scope` auf `SCOPE_<scope>` ab. Principal-Name ist der Claim `azp` (die Client-ID).
Spring Security 7 vergibt bei Bearer-Authentisierung zusätzlich die Authority
`FACTOR_BEARER`; der Test `ScopeAuthoritiesTest` vergleicht deshalb nur die `SCOPE_`-Authorities.

### `SecurityFilterChain`

| Endpunkt | Regel |
|---|---|
| `GET /healthz` | `permitAll` |
| `GET /orders` | `SCOPE_r:orders:read` |
| `POST /orders` | `SCOPE_r:orders:write` |
| `DELETE /orders/*` | `SCOPE_r:orders:admin` |
| alles andere (auch `GET /orders/`) | `denyAll` |

Zustandslos (`SessionCreationPolicy.STATELESS`), CSRF, HTTP Basic und Form-Login aus. Ohne
oder mit ungültigem Token antwortet R `401` mit `WWW-Authenticate: Bearer
error="invalid_token"`, bei fehlendem Scope `403` mit `error="insufficient_scope"`. Bei
Erfolg liefert `OrdersController` `{"clientId": <azp>, "scopes": [...], "endpoint": "..."}`.

### TLS-Vertrauen

`service-r/entrypoint.sh` wartet auf `SERVICE_R_TRUST_CA` (Default `/trust/ca.crt`), baut mit
`keytool` einen PKCS12-Truststore `/tmp/internal-ca.p12`, der nur die Lab-CA enthält, und
setzt ihn per `-Djavax.net.ssl.trustStore*` als JVM-Default. Jede ausgehende TLS-Verbindung
(Realm-Discovery, JWKS) vertraut damit nur der internen CA. Heap: `-XX:MaxRAMPercentage=75`
bei `mem_limit: 384m`. Host-Port: `127.0.0.1:18081`.

### Tests (offline)

`OrdersEndpointSecurityTest` (`@WebMvcTest` mit `SecurityConfig`, 18 Tests) ersetzt den
`JwtDecoder` per `@TestBean` durch einen `NimbusJwtDecoder` gegen einen lokal erzeugten
RSA-Schlüssel mit denselben Validatoren wie in Produktion. `ScopeAuthoritiesTest` prüft den
Converter. Testnamen: [Feature-Spezifikation, Abschnitt 12](../features/keycloak-autorisierungsserver.md#12-testfälle).

---

## Workload-Seite

### Projizierte Tokens (`manifests/20-consumer.yaml`, `30-authz-workloads.yaml`)

| Pod | ServiceAccount | Token-Dateien |
|---|---|---|
| `consumer` | `wif-demo:consumer` (Client `workload-a`) | `sa-token` (aud `wif-demo-validator`), `kc-token` (aud Realm-Issuer) |
| `reader` | `wif-demo:reader` (Client `workload-b`) | `kc-token` |
| `stranger` | `wif-demo:stranger` (kein Client) | `kc-token` |

Alle Tokens `expirationSeconds: 600`, `automountServiceAccountToken: false`. Jeder Pod
mountet die ConfigMap `internal-ca` unter `/etc/internal-ca` und `authz-client` unter
`/opt/authz`; `hostAliases` zeigen `keycloak` auf das Gateway (172.31.9.30) und
`service-r.wif.local` auf 172.31.9.40.

### `access-token.sh`

`/opt/authz/access-token.sh "<scope> [<scope> …]"` gibt ein Access-Token aus:

- `umask 077`: Cache und Log sind nur für den Pod-Benutzer lesbar.
- Cache unter `/tmp/access-tokens/<sha256>`; der Schlüssel ist der SHA-256 der sortierten,
  deduplizierten Scope-Liste, d. h. `"a b"` und `"b a"` teilen sich einen Eintrag. Inhalt:
  Zeile 1 Ablaufzeitpunkt, Zeile 2 Token.
- Neue Anfrage nur, wenn die Restlaufzeit ≤ 60 s ist (`MIN_REMAINING_SECONDS`).
- Anfrage: `client_credentials` mit `client_assertion_type=…:jwt-bearer`; curl liest die
  Assertion per `--data-urlencode "client_assertion@<datei>"` direkt aus `kc-token`. Das
  Token steht nie in einer Prozess-Argumentliste; die Datei wird bei jeder Anfrage neu
  gelesen.
- TLS mit `--cacert /etc/internal-ca/ca.crt`.
- Fehlen `access_token` oder `expires_in` in der Antwort, bricht das Skript ab.
- Schreiben atomar: erst `"$cache.$$"`, dann `mv`.
- Jede neue Anfrage schreibt „requested new access token“ nach stderr und
  `/tmp/access-token.log`; Prüfung 19 zählt diese Zeilen.
- Überschreibbar: `TOKEN_ENDPOINT`, `CLIENT_ASSERTION_FILE`.

`tools/demo.sh` hält Tokens ebenfalls aus Argumentlisten heraus: Bearer-Tokens gehen per
`kubectl exec -i` auf stdin an `curl -H @-`, Client-Assertions per `client_assertion@-` bzw.
`@<datei>`. Zu Beginn von `authz` leert es die Caches aller Pods.

---

## Netze und Namen

| Dienst | Netz | Adresse | Zweck |
|---|---|---|---|
| `keycloak` | `relying-net` | 172.31.8.30, Alias `keycloak` | liest Discovery/JWKS von `issuer-web`; `service-r`, `demo` und die Proxys erreichen ihn |
| `keycloak-gateway` | `relying-net` | 172.31.8.31 | Weiterleitung zu Keycloak |
| `keycloak-gateway` | `workload-net` | 172.31.9.30 | Pods holen Tokens (`keycloak` per `hostAliases`) |
| `keycloak-admin` | `relying-net` | 172.31.8.32 | Admin-Konsole, Host `127.0.0.1:18443`, nur Profil `admin` |
| `service-r` | `relying-net` | 172.31.8.40 | liest Discovery/JWKS von Keycloak |
| `service-r` | `workload-net` | 172.31.9.40 | Pods rufen R auf (Host `127.0.0.1:18081`) |

`tools/run-all-checks.sh` (Abschnitt 2) prüft per Bash-`/dev/tcp`, dass Keycloak weder den
API-Server (`172.31.7.2:6443`, `172.31.9.2:6443`) noch den Upload-Listener
(`172.31.7.20:8443`, `172.31.8.20:8443`) erreicht, wohl aber den Lese-Listener
`172.31.8.20:443`. Prüfung 20 in `demo.sh authz` prüft die Gegenrichtung aus dem Pod
`stranger`: Admin-API, Admin-Konsole und Master-Realm `404`, Pfad-Traversal bleibt im Realm,
172.31.8.30:8443 und :9000 unerreichbar, Realm-Discovery über das Gateway `200`.

---

## Lab-Vereinfachungen und Produktionshinweise

| Im Lab | In Produktion |
|---|---|
| Workload → `service-r` und Workload → `validator` über HTTP | TLS oder mTLS, z. B. über ein Service Mesh; optional sender-gebundene Tokens (DPoP oder mTLS-gebunden), damit ein abgegriffenes Access-Token allein nicht reicht |
| Realm per `--import-realm` (nur Anlage, `IGNORE_EXISTING`), Daten im Container | keycloak-config-cli oder Terraform in der CI als einziger Schreiber, Drift-Erkennung, Admin-Events an ein externes System; externe Datenbank, mehrere Knoten |
| Cluster-RBAC ist Lab-Standard | Rechte auf `serviceaccounts/token` und auf das Anlegen von Pods mit fremdem `serviceAccountName` bewusst vergeben und überwachen – sie entscheiden mit, wer welche Scopes bekommt |
| `KC_TRUSTSTORE_PATHS` ergänzt den Default-Truststore | Truststore auf die interne PKI beschränken, falls Keycloak keine öffentlichen Endpunkte braucht |
| Admin-Konsole über `keycloak-admin` auf Zuruf | Admin-Zugang nur aus einem getrennten Verwaltungsnetz |

---

## Speicherbedarf

Gemessen mit `docker stats` nach einem vollständigen Lauf:

| Container | Verbrauch | `mem_limit` |
|---|---|---|
| `keycloak` | ~626 MiB | `1g` |
| `service-r` | ~156 MiB | `384m` |
| `validator` (Vergleich) | ~257 MiB | – |

`keycloak-gateway` und `keycloak-admin` (nginx) sind auf `64m` begrenzt.

---

## Weiterlesen

- [../features/keycloak-autorisierungsserver.md](../features/keycloak-autorisierungsserver.md) – Ablauf, Akzeptanzkriterien, Prüfungen 8–21
- [trust-und-tls.md](trust-und-tls.md) – TLS-Beziehungen zu Keycloak und `service-r`
- [architecture.md](architecture.md) – Compose-Topologie
- [build-und-betrieb.md](build-und-betrieb.md) – Images, Befehle, `.env`-Variablen
