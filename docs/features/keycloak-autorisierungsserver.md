# Feature-Spezifikation: Keycloak als Autorisierungsserver pro Fachbereich

**Status:** Entwurf, vor der Umsetzung
**Bezug:** Issue #3 (Mapping von Token-Claims auf Spring-Security-Authorities),
[ADR 0004](../adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md)

## 1. Ziel

Das Lab trennt **Authentisierung** von **Autorisierung**:

- Das ServiceAccount-Token des Clusters beweist nur die Identität einer Workload
  („ich bin Workload A“). Es trägt keine Rechte.
- Ob Workload A einen Dienst aufrufen darf, entscheidet der **Fachbereich, dem der Dienst
  gehört** – über einen eigenen Autorisierungsserver. Im Lab ist das ein Keycloak mit einem
  Realm pro Fachbereich.

Beispiel: Workload A spricht mit den Diensten O, P, Q eines fremden Fachbereichs und mit
R, S, T des eigenen. Der Realm des eigenen Fachbereichs entscheidet nur über R, S, T. Für
O, P, Q entscheidet der Realm des anderen Fachbereichs. Einen globalen Autorisierer über
allen Fachbereichen gibt es nicht.

Damit beantwortet das Feature Issue #3: Das Gegenstück zum heutigen Mapping
„Subject-DN → Rolle“ ist „Scope im Access-Token → Spring-Security-Authority“. Die Rolle
steckt nicht mehr in der Identität (heute: CN `<Rolle> <Anwendungskontext>
<Betriebsumgebung>`, also faktisch entschieden von der PKI), sondern in einer Zuordnung,
die der Fachbereich selbst pflegt.

Das Lab zeigt den Ablauf Ende zu Ende mit einem Ressourcendienst R und prüft alle
Fehlerfälle automatisch.

## 2. Abgrenzung (nicht Teil dieses Features)

- **Kein Produktivbetrieb von Keycloak.** Keycloak läuft im Dev-Modus mit eingebetteter
  H2-Datenbank, ohne Cluster/HA, ohne externe Datenbank, ohne Tuning. Die Konfiguration ist
  ausdrücklich keine Vorlage für den Betrieb.
- **Nur ein Fachbereich.** Im Lab gibt es genau einen Realm (`domain-rst`) und einen
  Ressourcendienst (R). S, T und der fremde Fachbereich (O, P, Q) existieren nur als
  Scope-Namen bzw. als Erklärung.
- **Kein Konfigurationswerkzeug für den Realm.** Der Realm kommt per JSON-Import beim Start.
  keycloak-config-cli oder der Terraform-Keycloak-Provider werden beschrieben, aber nicht
  eingebaut.
- **Kein Token Exchange, keine Weitergabe der Identität über mehrere Dienste** (R ruft
  keinen weiteren Dienst im Namen von A auf).
- **Keine feingranulare Autorisierung in Keycloak** (Authorization Services, Policies,
  Permissions). Die Autorisierungsentscheidung ist die Zuordnung Client → Scope.
- **Kein Umbau des bestehenden `validator`.** Er bleibt der Offline-Prüfer für
  ServiceAccount-Tokens (direkte Föderation ohne Autorisierungsserver, ADR 0001–0003).
- **Kein eigener Spring-Autorisierungsserver.** Er ist als Ausweichlösung beschrieben
  (Abschnitt 9), wird aber nicht gebaut.
- **Keine Replay-Erkennung** für ServiceAccount-Tokens (Keycloak unterstützt sie für
  Kubernetes-Tokens nicht; siehe Abschnitt 5, Schritt 1).

## 3. Akteure

| Akteur | Rolle im Ablauf | Im Lab |
|---|---|---|
| **Workload A** | Ruft Dienste des Fachbereichs auf. Weist sich mit seinem ServiceAccount-Token aus, holt ein Access-Token und hält es im Cache. | Pod `consumer`, ServiceAccount `wif-demo:consumer` |
| **Workload B (nur lesend)** | Wie A, aber im Realm nur für Lesezugriff berechtigt. | Pod `reader`, ServiceAccount `wif-demo:reader` |
| **Unbekannte Workload** | Hat ein gültiges ServiceAccount-Token, ist im Realm aber nicht registriert. | Pod `stranger`, ServiceAccount `wif-demo:stranger` |
| **Cluster (Identitätsaussteller)** | Stellt ServiceAccount-Tokens aus; Schlüssel öffentlich über `issuer-web`. | `server` (k3s), `iss=https://issuer-web` |
| **Autorisierungsserver des Fachbereichs** | Prüft das ServiceAccount-Token, ordnet es einem Client zu und stellt ein Access-Token mit den zugeordneten Scopes aus. | `keycloak`, Realm `domain-rst` |
| **Fachbereichs-Administration** | Legt fest, welche Workload welche Scopes bekommt (Client → Scope). | Realm-Import-Datei im Repo |
| **Ressourcendienst R** | Prüft das Access-Token und schützt seine Endpunkte nach Scope. | neuer Dienst `service-r` |

## 4. Begriffe

| Begriff | Bedeutung |
|---|---|
| **ServiceAccount-Token** | JWT des Clusters, `sub=system:serviceaccount:<ns>:<sa>`, `iss=https://issuer-web`. Beweist Identität. |
| **Access-Token** | JWT von Keycloak, `iss=<Realm-Issuer>`, trägt `aud` und `scope`. Beweist Berechtigung für bestimmte Dienste. |
| **Föderierte Client-Authentisierung** | Keycloak akzeptiert ein fremd ausgestelltes JWT (hier das ServiceAccount-Token) als Client-Nachweis statt eines Client-Secrets. |
| **Kubernetes-Identity-Provider** | Eintrag im Realm, der einem Cluster-Issuer vertraut (dessen Schlüssel er über Discovery und JWKS lädt). |
| **Föderiertes Subject** | Der `sub` des ServiceAccount-Tokens, der einem Keycloak-Client fest zugeordnet ist. Nur `iss` und `sub` zusammen identifizieren die Workload eindeutig. |
| **Scope** | Benanntes Recht, Schema `<dienst>:<ressource>:<aktion>`, z. B. `r:orders:read`. |
| **Client-Scope-Zuordnung** | Die Autorisierungsregel: „Client X darf Scope Y bekommen.“ Liegt im Realm. |
| **Scope-Endpunkt-Zuordnung** | Die Durchsetzungsregel: „Endpunkt Z verlangt Scope Y.“ Liegt im Code von R. |

## 5. Ablauf

```
 Workload A (Pod)            Keycloak (Realm domain-rst)            issuer-web            Dienst R
      │                                │                                 │                    │
 (1)  │ kubelet legt SA-Token ab:      │                                 │                    │
      │ aud=<Realm-Issuer>, 600 s      │                                 │                    │
 (2)  │── POST /token ────────────────►│                                 │                    │
      │   client_credentials,          │── GET Discovery + JWKS ────────►│ (TLS, Lab-CA,      │
      │   client_assertion=SA-Token    │◄────────────────────────────────│  gecacht)          │
      │                                │ prüft Signatur, iss, aud, exp;  │                    │
      │                                │ sucht Client mit IdP + sub      │                    │
 (3)  │◄── Access-Token ───────────────│                                 │                    │
      │    aud=service-r, scope=…      │                                 │                    │
 (4)  │ cacht Token bis kurz vor exp   │                                 │                    │
 (5)  │── GET /orders, Bearer <Access-Token> ─────────────────────────────────────────────────►│
      │                                │◄── JWKS (einmalig, gecacht) ────────────────────────────│
      │                                │                                 │  prüft Signatur,   │
      │                                │                                 │  iss, aud, exp;    │
      │                                │                                 │  scope → Authority │
      │◄── 200 / 401 / 403 ───────────────────────────────────────────────────────────────────│
```

### Schritt 1 – ServiceAccount-Token für Keycloak

Der Pod bekommt über ein `projected`-Volume ein zweites ServiceAccount-Token unter
`/var/run/secrets/tokens/kc-token`:

- `audience` = Realm-Issuer-URL, genau ein Wert: `https://keycloak:8443/realms/domain-rst`.
- `expirationSeconds: 600` (zehn Minuten). Kubernetes erlaubt kein kürzeres projiziertes
  Token; Keycloak empfiehlt höchstens zehn Minuten, weil ServiceAccount-Tokens keinen
  Replay-Schutz haben (kein einmal verwendbares `jti`).
- Das bestehende Token `sa-token` für den `validator` bleibt unverändert. Jedes Token ist
  an genau einen Empfänger gebunden.

### Schritt 2 – Token-Anfrage an Keycloak

Die Workload ruft den Token-Endpunkt des Realms auf:

```
POST https://keycloak:8443/realms/domain-rst/protocol/openid-connect/token
grant_type=client_credentials
client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
client_assertion=<Inhalt von kc-token>
scope=r:orders:read r:orders:write
```

Keycloak (föderierte Client-Authentisierung, voll unterstützt ab 26.6):

1. liest `iss` des ServiceAccount-Tokens und findet den Kubernetes-Identity-Provider
   `lab-cluster` mit Issuer `https://issuer-web`;
2. lädt über `https://issuer-web/.well-known/openid-configuration` die `jwks_uri` und die
   Schlüssel (TLS mit Zertifikat der Lab-CA; Keycloak vertraut der Lab-CA über seinen
   Truststore) und hält sie im Cache;
3. prüft Signatur, `exp`, `nbf` und dass `aud` die Realm-Issuer-URL ist;
4. sucht den Client, der an `lab-cluster` gebunden ist und als föderiertes Subject genau
   den `sub` des Tokens trägt;
5. lehnt ab, wenn einer dieser Schritte scheitert (`401 invalid_client`).

Ein Client-Secret gibt es nicht. Die Client-ID (`workload-a`) ist eine lokale Bezeichnung im
Realm; die Verbindung zur Workload entsteht ausschließlich über Identity-Provider + `sub`.

### Schritt 3 – Access-Token

Keycloak stellt ein Access-Token aus:

| Claim | Wert |
|---|---|
| `iss` | `https://keycloak:8443/realms/domain-rst` |
| `aud` | `service-r` (aus dem Audience-Mapper der angefragten `r:*`-Scopes) |
| `scope` | die angefragten Scopes; ein dem Client nicht zugeordneter Scope führt zur Ablehnung (`invalid_scope`) |
| `azp` / `client_id` | `workload-a` |
| `exp` | Ausstellungszeit + 300 s (Realm-Einstellung `accessTokenLifespan`) |

Die Client-Scope-Zuordnung **ist** die Autorisierungsregel: „`workload-a` darf
`r:orders:read` und `r:orders:write` bekommen“. Scopes sind dem Client als **optionale**
Client-Scopes zugeordnet; der Client fordert pro Zielaudienz nur, was er braucht. Der Realm
hat keine Standard-Scopes (kein `profile`, `email`, `roles`), der Client hat
`fullScopeAllowed: false`.

### Schritt 4 – Cache in der Workload

Die Workload fragt nicht pro Aufruf ein neues Token an. Sie hält das Access-Token im
Speicher und erneuert es, sobald die Restlaufzeit unter 60 s fällt. Für die Erneuerung
liest sie `kc-token` jedes Mal neu (das kubelet tauscht die Datei rechtzeitig aus).

Im Lab übernimmt das ein Shell-Skript `access-token.sh` im Pod (ConfigMap), das das Token
samt Ablaufzeit unter `/tmp` ablegt und bei Bedarf erneuert; es protokolliert jede neue
Token-Anfrage. In einer Spring-Anwendung übernimmt das ein `OAuth2AuthorizedClientManager`
mit `client_credentials` und einer Client-Assertion aus der Token-Datei.

### Schritt 5 – Prüfung in Dienst R

`service-r` ist ein Standard-Spring-Boot-4-Dienst mit Spring Security OAuth2 Resource
Server – keine eigene Prüfkette:

- **Issuer:** `spring.security.oauth2.resourceserver.jwt.issuer-uri` = Realm-Issuer. Spring
  macht beim ersten Bedarf Discovery und cacht das JWKS (Standard-Cache von
  `NimbusJwtDecoder`).
- **TLS:** R vertraut für Keycloak nur der Lab-CA (gleiches Prinzip wie der `validator`
  gegenüber `issuer-web`).
- **Audienz:** ein zusätzlicher Validator verlangt `service-r` in `aud`
  (`spring.security.oauth2.resourceserver.jwt.audiences`).
- **Algorithmus:** nur `RS256`.
- **Authorities:** `JwtAuthenticationConverter` mit `JwtGrantedAuthoritiesConverter` bildet
  jeden Eintrag aus `scope` auf `SCOPE_<scope>` ab, z. B. `SCOPE_r:orders:read`.
- **Endpunkte** (`SecurityFilterChain`, `authorizeHttpRequests`):

  | Endpunkt | verlangte Authority |
  |---|---|
  | `GET /orders` | `SCOPE_r:orders:read` |
  | `POST /orders` | `SCOPE_r:orders:write` |
  | `DELETE /orders/{id}` | `SCOPE_r:orders:admin` |
  | `GET /healthz` | keine |
  | alles andere | abgelehnt (`denyAll`) |

- **Antworten:** ohne oder mit ungültigem Token `401` mit `WWW-Authenticate: Bearer
  error="invalid_token"`; gültiges Token ohne passenden Scope `403` mit
  `error="insufficient_scope"`. Bei Erfolg liefert R ein JSON mit `client_id`, `scope` und
  dem aufgerufenen Endpunkt (Daten sind Attrappen, kein Speicher).

### Die Aufteilung der Regeln

| Frage | Wer entscheidet | Wo liegt die Regel |
|---|---|---|
| Wer ist die Workload? | Cluster | ServiceAccount-Token (`iss` + `sub`) |
| Welcher Client im Realm ist das? | Fachbereich | Realm: Client ↔ Identity-Provider + föderiertes Subject |
| Was darf die Workload? | Fachbereich | Realm: Client-Scope-Zuordnung |
| Welcher Scope schützt welchen Endpunkt? | Team von R | Code von R (`SecurityFilterChain`) |

R kennt keine Workload-Namen. Eine neue Workload zu berechtigen ändert nur den Realm; einen
neuen Endpunkt zu schützen ändert nur R.

## 6. Umsetzungsentscheidungen im Lab

### Neuer Dienst `service-r` statt Umbau des `validator`

`service-r` ist ein eigenes Maven-Modul `service-r/` mit eigenem Image. Der `validator`
bleibt unverändert.

Begründung: Der `validator` demonstriert die direkte Föderation ohne Autorisierungsserver
(ADR 0001–0003), und alle bestehenden Prüfungen hängen an ihm. Ein Umbau zum
Resource-Server würde zwei Vertrauensmodelle in einem Dienst mischen (eigene
Nimbus-Kette für SA-Tokens, Spring-Resource-Server für Keycloak-Tokens). Der neue Dienst
besteht dagegen nur aus Standard-Spring-Konfiguration und zwei bis drei Klassen; genau das
soll das Lab als Vorlage für Issue #3 zeigen. Preis: ein zweiter JVM-Dienst
(Speicherbedarf siehe Abschnitt 7).

Für `service-r` gelten dieselben projektlokalen Abweichungen wie für den `validator`
(flaches Paket, keine Hexagonal-Schichten, siehe `CLAUDE.md`). Paket: `ms.rohde.wifpoc.servicer`.

### Netze und Namen

| Dienst | Netz | Adresse | Zweck |
|---|---|---|---|
| `keycloak` | `relying-net` | 172.31.8.30, Alias `keycloak` | liest Discovery/JWKS von `issuer-web`; R liest JWKS von Keycloak |
| `keycloak` | `workload-net` | 172.31.9.30 | Pods holen Tokens |
| `service-r` | `relying-net` | 172.31.8.40 | liest Discovery/JWKS von Keycloak |
| `service-r` | `workload-net` | 172.31.9.40 | Pods rufen R auf |

Pods erreichen `keycloak` und `service-r.wif.local` über `hostAliases`. Keycloak sitzt nicht
in `cluster-net` und erreicht den API-Server nicht. Der Issuer-Hostname ist fest
(`KC_HOSTNAME=https://keycloak:8443`), damit Pods und R denselben `iss` sehen.

### TLS

`pki-init` stellt zusätzlich ein Serverzertifikat `CN=keycloak`, SAN `DNS:keycloak` aus
(Volume `keycloak-tls`). Keycloak spricht nur HTTPS (`KC_HTTP_ENABLED=false`). Keycloak
vertraut `issuer-web` über `KC_TRUSTSTORE_PATHS=/trust/ca.crt`. `bootstrap` legt die
ConfigMap `internal-ca` zusätzlich im Namespace `wif-demo` an, damit die Pods Keycloak und R
über TLS prüfen können.

### Realm als Code

Der Realm liegt als `keycloak/realm-domain-rst.json` im Repo und wird beim Start mit
`start-dev --import-realm` geladen. Inhalt:

- Realm `domain-rst`, `accessTokenLifespan: 300`, keine Standard-Client-Scopes.
- Identity-Provider `lab-cluster`, Typ Kubernetes, Issuer `https://issuer-web`.
- Client-Scopes `r:orders:read`, `r:orders:write`, `r:orders:admin`, `s:inventory:read`;
  jeder `r:*`-Scope mit Audience-Mapper `service-r`, `s:inventory:read` mit `service-s`;
  `include.in.token.scope: true`.
- Clients (alle `serviceAccountsEnabled: true`, `standardFlowEnabled: false`,
  `fullScopeAllowed: false`, Client-Authentisierung „föderiert“, gebunden an `lab-cluster`):

  | Client | föderiertes Subject | optionale Client-Scopes |
  |---|---|---|
  | `workload-a` | `system:serviceaccount:wif-demo:consumer` | `r:orders:read`, `r:orders:write`, `s:inventory:read` |
  | `workload-b` | `system:serviceaccount:wif-demo:reader` | `r:orders:read` |

  `r:orders:admin` ist keinem Client zugeordnet. `wif-demo:stranger` hat keinen Client.

## 7. Konfiguration

Neue Einträge in `compose.yaml`, `.env.example` und der Konfigurationstabelle der README:

| Variable | Standard | Bedeutung |
|---|---|---|
| `KEYCLOAK_IMAGE` | `quay.io/keycloak/keycloak:26.8.2` | Gepinntes Keycloak-Image (zum Zeitpunkt der Spezifikation aktuellste Version). |
| `KC_BOOTSTRAP_ADMIN_USERNAME` | `admin` | Lab-Admin der Admin-Konsole. Kein Geheimnis, nur Lab. |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | `lab-not-a-secret-change-me` | Passwort dazu. Nur Lab. |
| `KEYCLOAK_HOST_PORT` | `18443` | Host-Port der Admin-Konsole (HTTPS, Lab-CA). |
| `KC_REALM_ISSUER` | `https://keycloak:8443/realms/domain-rst` | Realm-Issuer; Audienz des `kc-token` und `issuer-uri` von R. |
| `SERVICE_R_AUDIENCE` | `service-r` | Audienz, die R im Access-Token verlangt. |
| `SERVICE_R_HOST_PORT` | `18081` | Host-Port von R. |

Feste Keycloak-Einstellungen im Compose-Service (nicht in `.env`): `start-dev
--import-realm`, `KC_HOSTNAME=https://keycloak:8443`, `KC_HTTP_ENABLED=false`,
`KC_HTTPS_CERTIFICATE_FILE` / `KC_HTTPS_CERTIFICATE_KEY_FILE` aus `keycloak-tls`,
`KC_TRUSTSTORE_PATHS=/trust/ca.crt`, `KC_HEALTH_ENABLED=true`, `KC_FEATURES` laut
Umsetzungsaufgabe U1.

Neue Konfiguration von `service-r` (`application.yaml`, per Umgebung überschreibbar):
`spring.security.oauth2.resourceserver.jwt.issuer-uri=${KC_REALM_ISSUER}`,
`…jwt.audiences=${SERVICE_R_AUDIENCE}`, `…jwt.jws-algorithms=RS256`, Truststore nur mit
`/trust/ca.crt` (Spring-SSL-Bundle).

**Speicherbedarf.** Keycloak (Quarkus auf der JVM, Dev-Modus mit H2) braucht erwartet
500–750 MB; `mem_limit: 1g`, Heap über `JAVA_OPTS_KC_HEAP=-XX:MaxRAMPercentage=70`.
`service-r` erwartet 150–250 MB, `mem_limit: 384m`. Die tatsächlichen Werte werden bei der
Umsetzung mit `docker stats` gemessen und in `docs/technical/` festgehalten. Der Dev-Modus
ist keine Produktivkonfiguration.

## 8. Betriebsmodell im Unternehmen

- **Plattformteam** betreibt einen gemeinsamen Keycloak (Hochverfügbarkeit, Datenbank,
  Updates, Überwachung liegen dort).
- **Jeder Fachbereich** bekommt einen eigenen Realm und administriert ihn selbst. Er
  registriert die Identity-Provider der Cluster, denen er vertraut, legt Clients für die
  Workloads an, die seine Dienste nutzen, und definiert seine Scopes.
- **Änderungen als Code.** Der Realm wird deklarativ in Git gepflegt (z. B.
  keycloak-config-cli oder Terraform-Keycloak-Provider) und per Pull Request geändert.
  Jede neue Client-Scope-Zuordnung ist damit ein Review nach dem 4-Augen-Prinzip. Keycloak
  selbst hat keinen Freigabe-Workflow für Admin-Änderungen; die Freigabe liegt im
  PR-Prozess.
- **Schreibzugriff über die UI** ist für Menschen eingeschränkt (lesend für Fachbereichs-
  Admins, schreibend nur als Break-Glass mit nachträglicher Übernahme in Git).
- **Audit:** Keycloak-Admin-Events (mit Darstellung der Änderung) dokumentieren jede
  Änderung, auch die des Deploy-Werkzeugs; die Git-Historie dokumentiert Antrag und
  Freigabe.

## 9. Ausweichlösung: eigener Spring-Autorisierungsserver

Solange die organisatorische Abstimmung zum gemeinsamen Keycloak offen ist, ist ein
eigener Autorisierungsserver pro Fachbereich auf Basis von Spring Authorization Server die
dokumentierte Ausweichlösung. Die Ressourcendienste hängen nur an **Issuer-URL und
Scope-Namen**; der Autorisierungsserver ist damit austauschbar, ohne R zu ändern.

Einschränkung: RFC 7523 verlangt in einer Client-Assertion `iss = sub = client_id`. Ein
ServiceAccount-Token hat `iss=https://issuer-web` und
`sub=system:serviceaccount:<ns>:<sa>`. Spring Authorization Server bräuchte deshalb einen
eigenen `AuthenticationProvider` für die Client-Assertion, der Issuer und Subject wie
Keycloak auf einen registrierten Client abbildet und die Schlüssel über die JWKS des
Clusters prüft.

## 10. Migration (Bezug Issue #3)

mTLS und Token können in einer Übergangszeit parallel akzeptiert werden und auf
**dieselben Authorities** abbilden: Ein Dienst mit zwei Authentisierungswegen
(`x509` mit DN-Mapping und `oauth2ResourceServer` mit Scope-Mapping) vergibt in beiden
Fällen z. B. `SCOPE_r:orders:read`. Die Endpunkt-Regeln bleiben gleich; nur die Quelle der
Authority wechselt. Im Lab wird das nicht gebaut.

## 11. Akzeptanzkriterien

**AK1 – Token für registrierte Workload**
Gegeben `consumer` mit gültigem `kc-token`,
wenn er `client_credentials` mit diesem Token als Client-Assertion und
`scope=r:orders:read r:orders:write` anfragt,
dann liefert Keycloak `200` und ein Access-Token mit `iss=<Realm-Issuer>`,
`aud` enthält `service-r`, `scope` enthält genau `r:orders:read r:orders:write`,
`client_id=workload-a`.

**AK2 – nicht zugeordneter Scope wird nicht vergeben**
Gegeben `reader`, wenn er `scope=r:orders:read r:orders:write` anfragt,
dann lehnt Keycloak mit `400 invalid_scope` ab; fragt er nur `scope=r:orders:read` an,
enthält das Access-Token genau `r:orders:read`.

**AK3 – unbekannte Workload**
Gegeben `stranger` mit gültigem `kc-token`, wenn er ein Token anfragt,
dann antwortet Keycloak `401` mit `error=invalid_client`.

**AK4 – SA-Token mit falscher Audienz**
Gegeben `consumer`, wenn er sein `sa-token` (Audienz `wif-demo-validator`) als
Client-Assertion verwendet, dann antwortet Keycloak `401 invalid_client`.

**AK5 – fremder Cluster**
Gegeben ein JWT mit `iss=https://other-cluster`, `sub=system:serviceaccount:wif-demo:consumer`,
`aud=<Realm-Issuer>`, signiert mit einem Schlüssel außerhalb des Lab-Clusters,
wenn es als Client-Assertion verwendet wird, dann antwortet Keycloak `401 invalid_client`.
Dasselbe gilt für ein JWT mit `iss=https://issuer-web`, das mit einem fremden Schlüssel
signiert ist.

**AK6 – erlaubter Aufruf**
Gegeben ein Access-Token aus AK1, wenn `consumer` `GET /orders` und `POST /orders` bei R
aufruft, dann antwortet R jeweils `200` und nennt `client_id=workload-a`.

**AK7 – fehlender Scope**
Gegeben ein Access-Token von `reader`, wenn er `POST /orders` aufruft, dann antwortet R
`403` mit `error="insufficient_scope"`. Gegeben ein Access-Token von `consumer`, wenn er
`DELETE /orders/1` aufruft, dann antwortet R `403`.

**AK8 – falsche Audienz**
Gegeben ein Access-Token von `consumer` mit nur `scope=s:inventory:read`
(`aud=service-s`), wenn er `GET /orders` aufruft, dann antwortet R `401`.

**AK9 – manipuliertes oder abgelaufenes Token**
Gegeben ein Access-Token mit veränderter Signatur oder `exp` in der Vergangenheit (über die
Toleranz von 60 s hinaus), wenn es bei R verwendet wird, dann antwortet R `401`.

**AK10 – direktes SA-Token bei R**
Gegeben das `kc-token` (gültiges Cluster-Token, falscher Aussteller für R), wenn es direkt
als Bearer bei R verwendet wird, dann antwortet R `401`.

**AK11 – Cache**
Gegeben `consumer` ruft `access-token.sh` dreimal innerhalb von 30 s auf, dann stellt er
genau eine Token-Anfrage an Keycloak (eine Log-Zeile „requested new access token“).

**AK12 – Netztrennung**
Keycloak erreicht den API-Server weder über `172.31.7.2:6443` noch über `172.31.9.2:6443`
und nicht den Upload-Listener `172.31.7.20:8443`.

**AK13 – bestehendes Verhalten**
Alle bestehenden Prüfungen von `tools/run-all-checks.sh` laufen unverändert durch.

## 12. Testfälle

### Unit- und Slice-Tests in `service-r` (offline, TDD)

Mit einem lokal erzeugten RSA-Schlüssel und einem `JwtDecoder` gegen diesen Schlüssel
(gleiche Validatoren wie in Produktion: Issuer, Audienz, Zeitstempel):

- `getOrders_givenReadScope_thenReturns200`
- `postOrders_givenOnlyReadScope_thenReturns403`
- `deleteOrder_givenReadAndWriteScope_thenReturns403`
- `getOrders_givenWrongAudience_thenReturns401`
- `getOrders_givenWrongIssuer_thenReturns401`
- `getOrders_givenExpiredToken_thenReturns401`
- `getOrders_givenTamperedSignature_thenReturns401`
- `getOrders_givenNoToken_thenReturns401`
- `unmappedPath_givenAllScopes_thenReturns403`
- `convert_givenScopeClaim_thenMapsToScopeAuthorities` (Converter)

### Neue Ende-zu-Ende-Prüfungen in `tools/demo.sh` (neuer Modus `authz`)

| # | Prüfung | Erwartung |
|---|---|---|
| 8 | Realm-Discovery von Keycloak über TLS mit Lab-CA | `issuer` = Realm-Issuer |
| 9 | `consumer` holt Access-Token (AK1), Claims dekodieren | `aud`, `scope`, `client_id` wie erwartet |
| 10 | `reader` fordert Lese- und Schreib-Scope, dann nur Lese-Scope (AK2) | `400 invalid_scope`, dann nur `r:orders:read` |
| 11 | `stranger` fordert Token (AK3) | `401 invalid_client` |
| 12 | `sa-token` als Client-Assertion (AK4) | `401 invalid_client` |
| 13 | JWT fremder Cluster / fremder Schlüssel (AK5) | `401 invalid_client` |
| 14 | `consumer` → R `GET`/`POST /orders` (AK6) | `200` |
| 15 | `reader` → R `POST /orders`, `consumer` → `DELETE` (AK7) | `403` |
| 16 | Token mit `aud=service-s` → R (AK8) | `401` |
| 17 | manipuliertes Access-Token → R (AK9) | `401` |
| 18 | `kc-token` direkt → R (AK10) | `401` |
| 19 | dreimal `access-token.sh` (AK11) | eine Token-Anfrage |
| 20 | optional `DEMO_EXPIRY=1`: Access-Token nach `exp` + 60 s → R (AK9) | `401` |

### Erweiterungen von `tools/run-all-checks.sh`

- Abschnitt „1b. authorization server demo“: `docker compose run --rm demo authz`.
- Abschnitt 2 um die Sicht von Keycloak ergänzt (AK12), mit `bash`-`/dev/tcp`, da das
  Keycloak-Image kein `curl` enthält.
- Abschnitt 4 (Rotation): nach `post-rotation` zusätzlich `consumer` holt erneut ein
  Access-Token. Erwartung: Keycloak akzeptiert das mit dem neuen Schlüssel signierte
  `kc-token`, sobald der Publisher das neue JWKS veröffentlicht hat.

## 13. Umsetzungsaufgaben mit Klärungsbedarf

- **U1 – Feature-Flags und Konfigurationsfelder verifizieren.** Für Keycloak 26.8.2 klären,
  ob föderierte Client-Authentisierung und Kubernetes-Identity-Provider ohne
  `KC_FEATURES` aktiv sind oder Flags brauchen (in Quellen für ältere Versionen genannt:
  `client-auth-federated`, `kubernetes-service-accounts`). Ebenso die exakten Namen im
  Realm-JSON: Typ des Identity-Providers, `clientAuthenticatorType` (berichtet:
  `federated-jwt`) und die Client-Attribute für Identity-Provider und föderiertes Subject.
  Ergebnis in `docs/technical/` dokumentieren.
- **U2 – Verhalten bei nicht zugeordnetem Scope.** Prüfen, dass Keycloak einen angefragten,
  aber dem Client nicht zugeordneten Scope mit `invalid_scope` ablehnt (AK2) statt ihn
  stillschweigend wegzulassen; AK2 ggf. an das tatsächliche Verhalten anpassen.
- **U3 – JWKS-Cache von Keycloak bei Rotation.** Prüfen, ob Keycloak bei einer unbekannten
  `kid` das JWKS neu lädt; sonst Wartezeit in der Rotationsprüfung ergänzen.
- **U4 – Spring-Client in der Workload.** Für die Beschreibung in Schritt 4 klären, wie ein
  `OAuth2AuthorizedClientManager` eine fertige Client-Assertion aus einer Datei verwendet
  (eigener Parameter-Converter für `client_credentials`).

## 14. Offene Fragen

1. **Scope-Schema:** Reicht `<dienst>:<ressource>:<aktion>`, oder braucht es einen
   Fachbereichs-Präfix, damit Scopes über Realms hinweg eindeutig bleiben?
2. **Audienz pro Dienst oder pro Dienstgruppe:** Im Lab ein `aud` pro Dienst (`service-r`).
   Soll eine Workload, die R, S und T nacheinander aufruft, je Dienst ein eigenes Token
   holen (engere Bindung) oder ein Token mit mehreren Audienzen (weniger Anfragen)?
3. **Bindung an den Cluster:** Ein Identity-Provider pro Cluster oder pro
   Cluster-Verbund? Wer meldet einen neuen Cluster beim Fachbereich an?
4. **Merkmale aus dem heutigen DN:** `<Anwendungskontext>` und `<Betriebsumgebung>` haben im
   Token keine direkte Entsprechung. Werden sie über getrennte Realms/Cluster,
   Namespace-Konventionen oder eigene Scopes abgebildet?
5. **Access-Token-Laufzeit:** 300 s im Lab. Welche Laufzeit akzeptieren die Fachbereiche,
   da ein entzogener Scope erst mit Ablauf des Tokens wirkt?
