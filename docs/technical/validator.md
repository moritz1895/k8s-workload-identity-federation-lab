# Der Validator (Spring-Boot-Service)

**Für wen / was lernst du hier:** Du kennst JWT/JWS/JWK und Java, aber nicht die Bibliothek
Nimbus JOSE und nicht Spring-Boot-`@ConfigurationProperties`. Diese Seite zeigt den Aufbau des
Java-Dienstes unter `validator/src/main/java/ms/rohde/wifpoc/`: die Konfigurationsparameter,
den Startablauf, das Zusammenspiel der Klassen, die genaue Nimbus-Validierungskette, die
HTTP-Endpunkte mit Beispielen und die Testfälle.

---

## Überblick

Der Validator ist ein bewusst kleiner Spring-Boot-4-Dienst (Java 25, ~6 Klassen, flaches
Paket `ms.rohde.wifpoc`). Er nimmt ein `Authorization: Bearer <JWT>` entgegen und prüft das
Token **vollständig offline**:

- Signatur gegen die JWKS des Ausstellers (`RS256`/`ES256`),
- `iss` exakt gleich dem konfigurierten Aussteller,
- `aud` enthält den konfigurierten Audience-Wert,
- `exp` / `nbf` (mit 60 s Toleranz).

Er ruft dafür **nie** den Kubernetes-API-Server (kein `TokenReview`). Die einzige
Netzwerkverbindung nach außen ist die OIDC-Discovery + der JWKS-Abruf gegen `issuer-web`,
einmalig beim Start und danach höchstens alle 5 Minuten zum Cache-Refresh.

**Bibliotheken:** `nimbus-jose-jwt` 10.9.1 (JOSE/JWT-Verarbeitung), Spring Boot Web,
Log4j2 statt Logback, JSpecify für Null-Annotationen. Details in
[build-und-betrieb.md](build-und-betrieb.md).

---

## Konfigurationsparameter

Gebunden über die Klasse `WifProperties` (`WifProperties.java:16`), ein Java-`record` mit
`@ConfigurationProperties(prefix = "wif")`.

**Was ist `@ConfigurationProperties`?** Eine Spring-Boot-Annotation, die einen Satz
Konfigurationswerte (aus `application.yaml`, Umgebungsvariablen, …) typsicher in ein Objekt
bindet. `prefix = "wif"` heißt: `wif.issuer` landet in `issuer`, `wif.audience` in `audience`,
`wif.issuer-ca` (Kebab-Case) in `issuerCa`. Aktiviert wird die Bindung durch
`@EnableConfigurationProperties(WifProperties.class)` auf `JwksTrustConfig`
(`JwksTrustConfig.java:33`).

Werte-Kette in `application.yaml:1`:

```yaml
wif:
  issuer:    ${WIF_ISSUER:https://issuer-web}
  audience:  ${WIF_AUDIENCE:wif-demo-validator}
  issuer-ca: ${WIF_ISSUER_CA:/oidc/tls.crt}
```

`${ENV:default}` heißt: nimm die Umgebungsvariable, sonst den Default.

| Env-Variable | Property | Java-Feld | Default | Bedeutung |
|---|---|---|---|---|
| `WIF_ISSUER` | `wif.issuer` | `issuer` (String) | `https://issuer-web` | Exakter Sollwert des `iss`-Claims. Zugleich die Basis-URL für die OIDC-Discovery (`issuer + "/.well-known/openid-configuration"`). |
| `WIF_AUDIENCE` | `wif.audience` | `audience` (String) | `wif-demo-validator` | Wert, der in `aud` enthalten sein muss. |
| `WIF_ISSUER_CA` | `wif.issuer-ca` | `issuerCa` (`java.nio.file.Path`) | `/oidc/tls.crt` | PEM-Datei mit dem (self-signed) Zertifikat, dem der Validator für die HTTPS-Verbindung zu `issuer-web` – und *nur* dafür – vertraut. |
| `SERVER_PORT` / `server.port` | – | – | `8080` | HTTP-Port des Dienstes (`application.yaml:7`). |

Im Compose-Stack werden `WIF_ISSUER`, `WIF_AUDIENCE`, `WIF_ISSUER_CA` gesetzt
(`compose.yaml:97`). `entrypoint.sh` liest zusätzlich `WIF_ISSUER_CA` (Default `/oidc/tls.crt`)
direkt (`entrypoint.sh:4`).

Feste Werte im Code (keine Konfiguration):

| Konstante | Wert | Ort |
|---|---|---|
| Verbindungs-/Lese-Timeout für Discovery + JWKS | 2000 ms | `JwksTrustConfig.java:38` |
| Größenlimit der abgerufenen Dokumente | 64 KiB | `JwksTrustConfig.java:40` |
| JWKS-Cache-Lebensdauer | 300 000 ms (5 min) | `JwksTrustConfig.java:41` |
| JWKS-Cache-Refresh-Timeout | 30 000 ms | `JwksTrustConfig.java:42` |
| Akzeptierte Signatur-Algorithmen | `RS256`, `ES256` | `TokenValidator.java:23` |
| Pflicht-Claims | `sub`, `iat`, `exp` | `TokenValidator.java:24` |
| Clock-Skew-Toleranz | 60 s (Nimbus-Default) | implizit in `DefaultJWTClaimsVerifier` |

---

## Startablauf

```
docker startet Container
        │
        ▼
entrypoint.sh                       (validator/entrypoint.sh)
  ├─ liest WIF_ISSUER_CA  (Default /oidc/tls.crt)
  ├─ Schleife: warte bis /oidc/tls.crt existiert und nicht leer ist
  │            (max. 180 s, sonst Exit 1)
  └─ exec java -XX:MaxRAMPercentage=75 -jar /app/app.jar
        │
        ▼
Spring Boot startet
        │
        ▼
JwksTrustConfig.jwkSource(props)    (@Bean, JwksTrustConfig.java:45)
  1. trustOnly(props.issuerCa())
       -> liest tls.crt, baut KeyStore mit nur diesem Zertifikat,
          daraus TrustManagerFactory -> SSLContext -> SSLSocketFactory
  2. new DefaultResourceRetriever(connectTO, readTO, sizeLimit,
                                  disconnectAfter=true, sslSocketFactory)
  3. discoverJwksUri(retriever, issuer):
       GET  {issuer}/.well-known/openid-configuration
       prüfe  metadata["issuer"] == props.issuer()   (sonst IllegalStateException)
       return metadata["jwks_uri"]  ->  URL
  4. JWKSourceBuilder.create(jwksUrl, retriever)
        .cache(5 min, 30 s refresh-timeout)
        .rateLimited(false)
        .build()                    ->  gecachter JWKSource
        │
        ▼
JwksTrustConfig.tokenValidator(jwkSource, props)   (@Bean, JwksTrustConfig.java:59)
  -> new TokenValidator(jwkSource, issuer, audience)
        │
        ▼
TokenController wird mit dem TokenValidator injiziert   (TokenController.java:18)
        │
        ▼
HTTP-Server lauscht auf :8080   ->  Healthcheck wird "healthy"
```

Scheitert die Discovery beim Start (z. B. falscher `WIF_ISSUER`, kein Netz, Zertifikat passt
nicht), wirft `jwkSource(...)` eine Exception, der Spring-Kontext startet nicht, der Container
gilt nie als `healthy`. Das ist gewollt: ein Validator, der die Schlüssel nicht laden kann,
soll auch keine Tokens annehmen.

---

## Die Klassen und ihr Zusammenspiel

| Klasse | Rolle |
|---|---|
| `WifPocApplication` | `@SpringBootApplication`-Einstiegspunkt, nur `main` (`WifPocApplication.java:9`). |
| `WifProperties` | `record` mit `issuer`, `audience`, `issuerCa`; `@ConfigurationProperties(prefix="wif")`. |
| `JwksTrustConfig` | `@Configuration`. Baut die cert-gepinnte `SSLSocketFactory`, macht OIDC-Discovery, stellt `JWKSource` und `TokenValidator` als Beans bereit. |
| `TokenValidator` | Kapselt einen Nimbus `DefaultJWTProcessor`. Methode `validate(String)` → `ValidationResult`. Framework-frei, dadurch offline testbar. |
| `ValidationResult` | `record (boolean valid, @Nullable Map claims, @Nullable String reason)` mit Fabrikmethoden `ok(...)` / `rejected(...)`. |
| `TokenController` | `@RestController`. `GET /whoami`, `GET /healthz`. Zieht das Bearer-Token aus dem Header, ruft `validator.validate(...)`, mappt auf 200/401. |
| `package-info` | `@NullMarked` (JSpecify): im ganzen Paket sind Typen standardmäßig non-null. |

### Komponenten-/Sequenzdiagramm für `GET /whoami`

```
 Pod                TokenController           TokenValidator        Nimbus DefaultJWTProcessor       JWKSource (Cache)
  │  GET /whoami         │                          │                        │                            │
  │  Authorization:      │                          │                        │                            │
  │  Bearer <jwt>        │                          │                        │                            │
  │────────────────────► │                          │                        │                            │
  │                      │ prüft "Bearer "-Präfix   │                        │                            │
  │                      │ validate(token)          │                        │                            │
  │                      │────────────────────────► │ processor.process(jwt) │                            │
  │                      │                          │──────────────────────► │ parse Header, lies "kid"   │
  │                      │                          │                        │ Key-Selektor: kid+alg     │
  │                      │                          │                        │──────────────────────────► │ liefert passenden
  │                      │                          │                        │                            │ public JWK (aus Cache;
  │                      │                          │                        │ ◄──────────────────────────│ Refresh falls TTL alt)
  │                      │                          │                        │ verifiziere Signatur      │
  │                      │                          │                        │ ClaimsVerifier:           │
  │                      │                          │                        │  aud, iss, exp/nbf, req.  │
  │                      │                          │ ◄──────────────────────│ JWTClaimsSet  ODER Fehler │
  │                      │ ◄────────────────────────│ ValidationResult.ok/rejected                        │
  │  200 + Claims   ODER │                          │                        │                            │
  │  401 + {error,reason}│                          │                        │                            │
  │ ◄────────────────────│                          │                        │                            │
```

---

## Die Nimbus-Validierungskette im Detail

"Nimbus JOSE + JWT" ist eine Java-Bibliothek für JOSE (JWS/JWE/JWK) und JWT. Zentrale Klasse
hier: `DefaultJWTProcessor`, konfiguriert in `TokenValidator`s Konstruktor
(`TokenValidator.java:28`).

### 1. Ressourcen-Abruf und Discovery – `JwksTrustConfig`

- `DefaultResourceRetriever` ist Nimbus' HTTP-Client für das Laden von JSON-Dokumenten. Er
  wird mit der cert-gepinnten `SSLSocketFactory` als **5. Konstruktor-Argument** erzeugt
  (`JwksTrustConfig.java:46`):

  ```java
  new DefaultResourceRetriever(connectTimeout, readTimeout, sizeLimit,
                               /* disconnectAfterUse */ true,
                               sslSocketFactory);
  ```

  In Nimbus 10.9.1 gibt es **keine** Setter-Methode `setSSLSocketFactory(...)`; die Factory
  kann nur über diesen 5-Argument-Konstruktor gesetzt werden. Deshalb wird genau diese
  Signatur verwendet.
- `discoverJwksUri(...)` (`JwksTrustConfig.java:63`):
  1. `GET {issuer}/.well-known/openid-configuration`, JSON parsen.
  2. Feld `issuer` aus dem Dokument lesen und **exakt** gegen `props.issuer()` vergleichen.
     Weicht es ab → `IllegalStateException`, Start bricht ab. (Schutz gegen
     "issuer confusion": das Dokument darf keinen anderen Aussteller ausweisen als den
     konfigurierten.)
  3. Feld `jwks_uri` als URL zurückgeben.
- `JWKSourceBuilder` baut daraus einen `JWKSource`, der die Schlüssel **cacht**:
  - `.cache(300_000, 30_000)` – Schlüssel 5 Minuten lang aus dem Speicher bedienen; ein
    Refresh darf max. 30 s dauern.
  - `.rateLimited(false)` – keine zusätzliche Ratenbegrenzung auf Cache-Misses.

  Ein `kid`, das nicht im Cache ist, löst einen einmaligen Refresh-Abruf gegen die
  `jwks_uri` aus (nützlich bei Schlüsselrotation).

### 2. Schlüssel-Selektion nach `kid` und Algorithmus – `JWSVerificationKeySelector`

`TokenValidator.java:30`

```java
jwtProcessor.setJWSKeySelector(
    new JWSVerificationKeySelector<>(ACCEPTED_ALGS, jwkSource));
```

- `ACCEPTED_ALGS = { RS256, ES256 }` (`TokenValidator.java:23`). Ein Token mit einem anderen
  `alg` im JWS-Header (z. B. `none`, `HS256`, `RS512`) wird abgelehnt, **bevor** überhaupt ein
  Schlüssel gesucht wird. Das schließt den klassischen "alg=none"- und
  "RS256→HS256-Confusion"-Angriff aus.
- Der Selektor liest `kid` aus dem JWS-Header und holt aus dem `JWKSource` den öffentlichen
  Schlüssel mit passendem `kid` und passender Verwendung (`use: sig`). Fehlt ein passender
  Schlüssel, gibt es keinen Verifikationsschlüssel → Ablehnung.

### 3. Signaturprüfung

`DefaultJWTProcessor` verifiziert die JWS-Signatur des Tokens mit dem selektierten
öffentlichen Schlüssel. Schlägt sie fehl (manipuliertes Token, falscher Signierschlüssel) →
`BadJOSEException` / `JOSEException`.

### 4. Claims-Prüfung – `DefaultJWTClaimsVerifier`

`TokenValidator.java:31`

```java
new DefaultJWTClaimsVerifier<>(
    Set.of(expectedAudience),                                  // akzeptierte audience-Menge
    new JWTClaimsSet.Builder().issuer(expectedIssuer).build(), // exakte Soll-Claims
    REQUIRED_CLAIMS,                                           // {"sub","iat","exp"}
    null);                                                     // keine verbotenen Claims
```

| Prüfung | Verhalten |
|---|---|
| **audience** | Der `aud`-Claim des Tokens muss den Wert `expectedAudience` enthalten. `aud` darf ein einzelner String oder eine Liste sein; mindestens ein Element muss passen. Andernfalls: `reason` = `"JWT aud claim rejected"`. |
| **issuer** | `iss` muss **exakt** `expectedIssuer` sein (String-Gleichheit, kein Präfix-Match). Andernfalls: `reason` beginnt mit `"JWT iss claim has value …"`. |
| **Pflicht-Claims** | `sub`, `iat`, `exp` müssen vorhanden sein. Fehlt einer → Ablehnung mit `"JWT missing required claims: …"`. |
| **`exp` (Ablauf)** | Nimbus prüft `exp` selbst gegen die aktuelle Zeit, mit **60 s** Toleranz (`DefaultJWTClaimsVerifier.DEFAULT_MAX_CLOCK_SKEW_SECONDS`). Abgelaufen → `reason` = `"Expired JWT"`. |
| **`nbf` (not before)** | Falls vorhanden: Token darf nicht mehr als 60 s in der Zukunft "gültig ab" sein. |

Der `iat`-Claim wird als Pflicht verlangt, aber nicht gegen eine Obergrenze geprüft.

### 5. Ergebnis

`TokenValidator.validate(...)` (`TokenValidator.java:39`):

```java
try {
    JWTClaimsSet claims = processor.process(bearerToken, null);
    return ValidationResult.ok(claims.toJSONObject());
} catch (ParseException | BadJOSEException | JOSEException e) {
    return ValidationResult.rejected(e.getMessage());
}
```

Bei Erfolg werden **alle** Claims als `Map<String,Object>` zurückgegeben; bei Misserfolg die
Nimbus-Fehlermeldung als `reason`.

---

## HTTP-Endpunkte

Kein Spring Security, kein Kontextpfad, keine Versionierung – flache Pfade auf Port 8080.

### `GET /healthz`

`TokenController.java:22` – gibt `200` mit `{"status":"UP"}` zurück. Vom Docker-Healthcheck
und für manuelle Checks vom Host (`curl localhost:18080/healthz`) genutzt. Keine
Authentifizierung.

### `GET /whoami`

`TokenController.java:27`. Erwartet den Header `Authorization: Bearer <JWT>`.

**Ablauf:**
1. Header fehlt oder beginnt nicht mit `Bearer ` → `401` `{"error":"missing_bearer_token"}`.
2. Token wird validiert. Ungültig → `401` `{"error":"token_rejected","reason":"<nimbus-meldung>"}`.
3. Gültig → `200` mit einem Auszug der Claims.

**Beispiel – gültiges Token (200):**

```
$ curl -s -H "Authorization: Bearer $GOOD_TOKEN" http://localhost:18080/whoami
```

```json
{
  "authenticated": true,
  "sub": "system:serviceaccount:wif-demo:consumer",
  "iss": "https://issuer-web",
  "aud": "wif-demo-validator",
  "exp": 1788971157,
  "kubernetes.io": {
    "namespace": "wif-demo",
    "pod": { "name": "consumer-5c9d…", "uid": "…" },
    "serviceaccount": { "name": "consumer", "uid": "…" }
  }
}
```

Die Feldnamen sind exakt die aus `TokenController.java:43`: `authenticated`, `sub`, `iss`,
`aud`, `exp`, `kubernetes.io`. Fehlt einer der Claims im Token, wird ein leerer Ersatzwert
eingesetzt (`""` bzw. `{}`).

**Beispiel – falsche audience (401):**

```
$ curl -s -H "Authorization: Bearer $WRONG_AUD_TOKEN" http://localhost:18080/whoami
```

```json
{ "error": "token_rejected", "reason": "JWT aud claim rejected" }
```

**Beispiel – manipulierte Signatur (401):**

```json
{ "error": "token_rejected", "reason": "Signed JWT rejected: Invalid signature" }
```

**Beispiel – kein Header (401):**

```json
{ "error": "missing_bearer_token" }
```

### Rate Limiting

Nicht konfiguriert. Der Dienst hat kein Throttling – bewusst, es ist ein Lab.

---

## Testfälle (`TokenValidatorTest`)

`validator/src/test/java/ms/rohde/wifpoc/TokenValidatorTest.java`. Vollständig **offline**:
Der Test erzeugt selbst ein RSA-Schlüsselpaar, baut daraus per `ImmutableJWKSet` einen
statischen `JWKSource` und signiert Test-Tokens selbst. Kein Netz, kein Docker, kein
`issuer-web`.

| Testmethode | Wie provoziert | Erwartung |
|---|---|---|
| `validate_givenValidToken_thenOk` (`:40`) | Token mit korrektem `iss`/`aud`/`sub`/`iat`/`exp`, signiert mit dem Cluster-Schlüssel. | `valid() == true`, `claims` enthält `sub`. |
| `validate_givenWrongAudience_thenRejected` (`:48`) | `audience("someone-else")` statt `wif-demo-validator`. | `valid() == false`, `reason` enthält `aud`. |
| `validate_givenExpiredToken_thenRejected` (`:58`) | `iat` und `exp` liegen ~1 h in der Vergangenheit. | `valid() == false`, `reason` enthält `expired`. |
| `validate_givenWrongIssuer_thenRejected` (`:72`) | `issuer("https://evil.example")`. | `valid() == false`, `reason` enthält `iss`. |
| `validate_givenUnknownSigningKey_thenRejected` (`:82`) | Signiert mit `unknownKey` (`kid=rogue-kid`), der nicht im JWKS steht. | `valid() == false`. |
| `validate_givenTamperedSignature_thenRejected` (`:91`) | Letztes Zeichen eines gültigen Tokens umgedreht. | `valid() == false`. |
| `validate_givenMalformedToken_thenRejected` (`:100`) | Eingabe `"this.is.not-a-jwt"`. | `valid() == false` (`ParseException` gefangen). |

Diese Tests laufen im Docker-Build mit (`mvn clean package`), siehe
[build-und-betrieb.md](build-und-betrieb.md). Die Ende-zu-Ende-Prüfung mit echten
k3s-Tokens macht `tools/demo.sh` (siehe [../use-cases.md](../use-cases.md)).

---

## Weiterlesen

- [architecture.md](architecture.md) – wo der Validator im Stack sitzt, feste IP, `hostAliases`
- [trust-und-tls.md](trust-und-tls.md) – wie `trustOnly(...)` den Ein-Zertifikat-Truststore
  baut und warum der 5-arg-`DefaultResourceRetriever` nötig ist
- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – woher `/oidc/tls.crt` und die Metadaten
  kommen
- [build-und-betrieb.md](build-und-betrieb.md) – Multi-Stage-Build, Log4j2, `pom.xml`
- [../domain.md](../domain.md) – das fachliche Modell hinter Token und Claims
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
