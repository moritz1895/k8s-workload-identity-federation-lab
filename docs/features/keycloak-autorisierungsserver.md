# Feature-Spezifikation: Keycloak als Autorisierungsserver pro Fachbereich

**Status:** umgesetzt
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

- **Kein Produktivbetrieb von Keycloak.** Keycloak läuft im `start`-Modus, aber als einzelner
  Knoten mit eingebetteter Datei-Datenbank (`KC_DB=dev-file`), ohne Cluster/HA, ohne externe
  Datenbank, ohne Tuning. Die Konfiguration ist
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
| **Cluster (Identitätsaussteller)** | Stellt ServiceAccount-Tokens aus; Schlüssel öffentlich über den Issuer-Pod hinter dem Ingress. | `server` (k3s), `iss=https://issuer.wif.local` |
| **Autorisierungsserver des Fachbereichs** | Prüft das ServiceAccount-Token, ordnet es einem Client zu und stellt ein Access-Token mit den zugeordneten Scopes aus. | `keycloak`, Realm `domain-rst` |
| **Fachbereichs-Administration** | Legt fest, welche Workload welche Scopes bekommt (Client → Scope). | Realm-Import-Datei im Repo |
| **Ressourcendienst R** | Prüft das Access-Token und schützt seine Endpunkte nach Scope. | neuer Dienst `service-r` |

## 4. Begriffe

| Begriff | Bedeutung |
|---|---|
| **ServiceAccount-Token** | JWT des Clusters, `sub=system:serviceaccount:<ns>:<sa>`, `iss=https://issuer.wif.local`. Beweist Identität. |
| **Access-Token** | JWT von Keycloak, `iss=<Realm-Issuer>`, trägt `aud` und `scope`. Beweist Berechtigung für bestimmte Dienste. |
| **Föderierte Client-Authentisierung** | Keycloak akzeptiert ein fremd ausgestelltes JWT (hier das ServiceAccount-Token) als Client-Nachweis statt eines Client-Secrets. |
| **Kubernetes-Identity-Provider** | Eintrag im Realm, der einem Cluster-Issuer vertraut (dessen Schlüssel er über Discovery und JWKS lädt). |
| **Föderiertes Subject** | Der `sub` des ServiceAccount-Tokens, der einem Keycloak-Client fest zugeordnet ist. Nur `iss` und `sub` zusammen identifizieren die Workload eindeutig. |
| **Scope** | Benanntes Recht, Schema `<dienst>:<ressource>:<aktion>`, z. B. `r:orders:read`. |
| **Client-Scope-Zuordnung** | Die Autorisierungsregel: „Client X darf Scope Y bekommen.“ Liegt im Realm. |
| **Scope-Endpunkt-Zuordnung** | Die Durchsetzungsregel: „Endpunkt Z verlangt Scope Y.“ Liegt im Code von R. |

## 5. Ablauf

```
 Workload A (Pod)            Keycloak (Realm domain-rst)            issuer.wif.local      Dienst R
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

Die Workload ruft den Token-Endpunkt des Realms auf. Der Name `keycloak` zeigt im Pod auf
`keycloak-gateway`, das nur `/realms/domain-rst/` an Keycloak weiterleitet:

```
POST https://keycloak:8443/realms/domain-rst/protocol/openid-connect/token
grant_type=client_credentials
client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
client_assertion=<Inhalt von kc-token>
scope=r:orders:read r:orders:write
```

Keycloak (föderierte Client-Authentisierung, voll unterstützt ab 26.6):

1. liest `iss` des ServiceAccount-Tokens und findet den Kubernetes-Identity-Provider
   `lab-cluster` mit Issuer `https://issuer.wif.local`;
2. lädt über `https://issuer.wif.local/.well-known/openid-configuration` die `jwks_uri` und die
   Schlüssel (TLS mit Zertifikat der Lab-CA; `KC_TRUSTSTORE_PATHS` ergänzt Keycloaks
   Default-Truststore um die Lab-CA) und hält sie im Cache;
3. prüft Signatur, `exp`, `nbf` und dass `aud` die Realm-Issuer-URL ist;
4. sucht den Client, der an `lab-cluster` gebunden ist und als föderiertes Subject genau
   den `sub` des Tokens trägt;
5. lehnt ab, wenn einer dieser Schritte scheitert: `400 invalid_client` bei falscher
   Audienz, sonst `401 invalid_client`.

Ein Client-Secret gibt es nicht. Die Client-ID (`workload-a`) ist eine lokale Bezeichnung im
Realm; die Verbindung zur Workload entsteht ausschließlich über Identity-Provider + `sub`.

### Schritt 3 – Access-Token

Keycloak stellt ein Access-Token aus:

| Claim | Wert |
|---|---|
| `iss` | `https://keycloak:8443/realms/domain-rst` |
| `aud` | `service-r` (aus dem Audience-Mapper der angefragten `r:*`-Scopes; als String) |
| `scope` | die angefragten Scopes in nicht garantierter Reihenfolge; ein dem Client nicht zugeordneter Scope führt zur Ablehnung (`invalid_scope`) |
| `typ` | `Bearer` |
| `azp` | `workload-a` |
| `sub` | UUID des Service-Account-Benutzers des Clients |
| `exp` | `iat` + 300 s (Realm-Einstellung `accessTokenLifespan`) |

Die Client-Scope-Zuordnung **ist** die Autorisierungsregel: „`workload-a` darf
`r:orders:read` und `r:orders:write` bekommen“. Scopes sind dem Client als **optionale**
Client-Scopes zugeordnet; der Client fordert pro Ressourcendienst ein eigenes Token mit nur
den Scopes dieses Dienstes an (eine Audienz pro Token, siehe AK14). Der Realm
hat keine Standard-Scopes (kein `profile`, `email`, `roles`), der Client hat
`fullScopeAllowed: false`.

### Schritt 4 – Cache in der Workload

Die Workload fragt nicht pro Aufruf ein neues Token an. Sie hält das Access-Token im
Speicher und erneuert es, sobald die Restlaufzeit unter 60 s fällt. Für die Erneuerung
liest sie `kc-token` jedes Mal neu. Das kubelet tauscht die Datei erst nach rund acht
Minuten aus; bis dahin legt die Workload dasselbe ServiceAccount-Token erneut vor, was
Keycloak für Kubernetes-Tokens akzeptiert.

Im Lab übernimmt das ein Shell-Skript `access-token.sh` im Pod (ConfigMap), das das Token
samt Ablaufzeit unter `/tmp` ablegt (`umask 077`, atomar geschrieben, Schlüssel = SHA-256
der sortierten Scope-Liste) und bei Bedarf erneuert; es protokolliert jede neue
Token-Anfrage. curl liest die Client-Assertion direkt aus der Datei
(`client_assertion@<datei>`), sodass das Token in keiner Argumentliste steht. In einer Spring-Anwendung übernimmt das ein `OAuth2AuthorizedClientManager`
mit `client_credentials` und einer Client-Assertion aus der Token-Datei.

### Schritt 5 – Prüfung in Dienst R

`service-r` ist ein Standard-Spring-Boot-4-Dienst mit Spring Security OAuth2 Resource
Server – keine eigene Prüfkette:

- **Issuer:** `service-r.issuer` = Realm-Issuer. `NimbusJwtDecoder.withIssuerLocation`,
  eingepackt in `SupplierJwtDecoder`, macht die Discovery beim ersten Token (bei Fehlschlag
  erneut mit dem nächsten) und cacht das JWKS. R startet damit unabhängig von Keycloak.
- **TLS:** R vertraut für Keycloak nur der Lab-CA (gleiches Prinzip wie der `validator`
  gegenüber dem Issuer-Endpoint).
- **Audienz:** ein zusätzlicher Validator verlangt, dass `aud` genau `["service-r"]` ist
  (`service-r.audience`). Ein Token mit mehreren Audienzen wird abgelehnt, damit ein anderer
  Dienst ein für ihn mit ausgestelltes Token nicht bei R wiederverwenden kann.
- **Token-Typ und Client:** `typ` muss `Bearer` sein, `azp` vorhanden.
- **Algorithmus:** nur `RS256`.
- **Authorities:** `JwtAuthenticationConverter` mit `JwtGrantedAuthoritiesConverter` bildet
  jeden Eintrag aus `scope` auf `SCOPE_<scope>` ab, z. B. `SCOPE_r:orders:read`. Principal
  ist `azp`.
- **Endpunkte** (`SecurityFilterChain`, `authorizeHttpRequests`):

  | Endpunkt | verlangte Authority |
  |---|---|
  | `GET /orders` | `SCOPE_r:orders:read` |
  | `POST /orders` | `SCOPE_r:orders:write` |
  | `DELETE /orders/{id}` | `SCOPE_r:orders:admin` |
  | `GET /healthz` | keine |
  | alles andere (auch `GET /orders/`) | abgelehnt (`denyAll`) |

- **Antworten:** ohne oder mit ungültigem Token `401` mit `WWW-Authenticate: Bearer
  error="invalid_token"`; gültiges Token ohne passenden Scope `403` mit
  `error="insufficient_scope"`. Bei Erfolg liefert R ein JSON mit `clientId` (aus `azp`),
  `scopes` und dem aufgerufenen Endpunkt (Daten sind Attrappen, kein Speicher).

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
Nimbus-Kette für SA-Tokens, Spring-Resource-Server für Keycloak-Tokens). Der eigene Dienst
besteht dagegen nur aus Standard-Spring-Konfiguration und wenigen kleinen Klassen; genau das
soll das Lab als Vorlage für Issue #3 zeigen. Preis: ein zweiter JVM-Dienst
(Speicherbedarf siehe Abschnitt 7).

Für `service-r` gelten dieselben projektlokalen Abweichungen wie für den `validator`
(flaches Paket, keine Hexagonal-Schichten, siehe `CLAUDE.md`). Paket: `ms.rohde.wifpoc.servicer`.

### Netze und Namen

| Dienst | Netz | Adresse | Zweck |
|---|---|---|---|
| `keycloak` | `relying-net` | 172.31.8.30, Alias `keycloak` | liest Discovery/JWKS von `issuer.wif.local` (über `ingress-lb`); R liest JWKS von Keycloak |
| `keycloak-gateway` | `relying-net` | 172.31.8.31 | Weiterleitung zu Keycloak |
| `keycloak-gateway` | `workload-net` | 172.31.9.30 | Pods holen Tokens (nur `/realms/domain-rst/`) |
| `keycloak-admin` | `relying-net` | 172.31.8.32 | Admin-Konsole vom Host, nur Profil `admin` |
| `service-r` | `relying-net` | 172.31.8.40 | liest Discovery/JWKS von Keycloak |
| `service-r` | `workload-net` | 172.31.9.40 | Pods rufen R auf |

Keycloak hängt nur in `relying-net` und veröffentlicht keinen Host-Port: Docker macht einen
veröffentlichten Port auch aus den anderen Bridge-Netzen erreichbar (im Lab gemessen), das
hätte den Workloads die Admin-API geöffnet. Pods lösen `keycloak` per `hostAliases` auf das
Gateway auf; es zeigt das Keycloak-Zertifikat, leitet nur `GET`/`POST` unter
`/realms/domain-rst/` weiter (normalisierter Pfad, kein Ausbruch per `../`) und antwortet
sonst `404`. Die Admin-Konsole läuft über den Proxy `keycloak-admin`, der nur bei Bedarf
gestartet wird (`docker compose --profile admin up -d keycloak-admin`); solange er läuft, ist
auch sein Port aus `workload-net` erreichbar. Keycloak sitzt nicht in `cluster-net` und
erreicht den API-Server nicht. Der Issuer-Hostname ist fest
(`KC_HOSTNAME=https://keycloak:8443`), damit Pods und R denselben `iss` sehen. Details:
[../technical/autorisierungsserver.md](../technical/autorisierungsserver.md#erreichbarkeit-gateway-und-admin-zugang).

### TLS

`pki-init` stellt zusätzlich ein Serverzertifikat `CN=keycloak`, SAN `DNS:keycloak`,
`DNS:localhost`, `IP:127.0.0.1` aus (Volume `keycloak-tls`, Schlüssel gehört uid 1000);
Keycloak, `keycloak-gateway` und `keycloak-admin` zeigen es. Keycloak spricht nur HTTPS
(`KC_HTTP_ENABLED=false`) und vertraut dem Issuer-Ingress über `KC_TRUSTSTORE_PATHS=/trust/ca.crt`
(zusätzlich zu seinem Default-Truststore). `bootstrap` legt die ConfigMap `internal-ca`
zusätzlich im Namespace `wif-demo` an, damit die Pods Keycloak über TLS prüfen können.
`pki-init` stellt außerdem ein Serverzertifikat `CN=service-r.wif.local` (SAN
`DNS:service-r.wif.local`, `DNS:service-r`, `DNS:localhost`, `IP:127.0.0.1`) aus (Volume
`service-r-tls`, Schlüssel gehört uid 10001). `service-r` spricht nur HTTPS auf 8443 (TLS 1.3
und 1.2, Spring-SSL-Bundle `service-r`); die Pods prüfen es über dieselbe ConfigMap
`internal-ca`.

### Realm als Code

Der Realm liegt als `keycloak/realm-domain-rst.json` im Repo und wird beim Start mit
`start --import-realm` angelegt, wenn er noch nicht existiert (`IGNORE_EXISTING`; der Import
legt den Realm nur an und gleicht ihn später nicht ab). Die Keycloak-Datenbank liegt im
Container; ein neu erstellter Container hat neue Realm-Schlüssel, gecachte Access-Tokens
werden dann ungültig. Inhalt:

- Realm `domain-rst`, `accessTokenLifespan: 300`, keine Standard-Client-Scopes.
- Identity-Provider `lab-cluster`, `providerId: kubernetes`, `config.issuer: https://issuer.wif.local`.
- Client-Scopes `r:orders:read`, `r:orders:write`, `r:orders:admin`, `s:inventory:read`;
  jeder `r:*`-Scope mit Audience-Mapper `service-r`, `s:inventory:read` mit `service-s`;
  `include.in.token.scope: true`.
- Clients (alle `serviceAccountsEnabled: true`, `standardFlowEnabled: false`,
  `fullScopeAllowed: false`, `clientAuthenticatorType: federated-jwt` mit den Attributen
  `jwt.credential.issuer: lab-cluster` und `jwt.credential.sub: <föderiertes Subject>`):

  | Client | föderiertes Subject | optionale Client-Scopes |
  |---|---|---|
  | `workload-a` | `system:serviceaccount:wif-demo:consumer` | `r:orders:read`, `r:orders:write`, `s:inventory:read` |
  | `workload-b` | `system:serviceaccount:wif-demo:reader` | `r:orders:read` |

  `r:orders:admin` ist keinem Client zugeordnet. `wif-demo:stranger` hat keinen Client.

## 7. Konfiguration

Einträge in `compose.yaml`, `.env.example` und der Konfigurationstabelle der README:

| Variable | Standard | Bedeutung |
|---|---|---|
| `KEYCLOAK_IMAGE` | `quay.io/keycloak/keycloak:26.8.2` | Gepinntes Keycloak-Image. |
| `KC_BOOTSTRAP_ADMIN_USERNAME` | `admin` | Lab-Admin der Admin-Konsole. Kein Geheimnis, nur Lab. |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | `lab-not-a-secret-change-me` | Passwort dazu. Nur Lab. |
| `KEYCLOAK_HOST_PORT` | `18443` | Host-Port des Admin-Proxys `keycloak-admin` (`127.0.0.1`, HTTPS, Lab-CA, nur Profil `admin`); geht auch in `KC_HOSTNAME_ADMIN=https://localhost:<port>` ein. |
| `KC_REALM_ISSUER` | `https://keycloak:8443/realms/domain-rst` | Realm-Issuer; Audienz des `kc-token` und `service-r.issuer`. |
| `SERVICE_R_AUDIENCE` | `service-r` | Audienz, die R im Access-Token verlangt. |
| `SERVICE_R_HOST_PORT` | `18081` | Host-Port von R (`127.0.0.1`, HTTPS: `https://localhost:18081`). |

Feste Keycloak-Einstellungen im Compose-Service (nicht in `.env`): `start --import-realm`,
`KC_DB=dev-file`, `KC_HOSTNAME=https://keycloak:8443`,
`KC_HOSTNAME_ADMIN=https://localhost:${KEYCLOAK_HOST_PORT}`, `KC_HTTP_ENABLED=false`,
`KC_HTTPS_CERTIFICATE_FILE` / `KC_HTTPS_CERTIFICATE_KEY_FILE` aus `keycloak-tls`,
`KC_TRUSTSTORE_PATHS=/trust/ca.crt`, `KC_CACHE=local`, `KC_HEALTH_ENABLED=true`,
`KC_HTTP_MANAGEMENT_SCHEME=http` (Health auf Port 9000), `KC_FEATURES_DISABLED` und die
Sticky-Session-Option gegen Warnungen im Log. Der `start`-Modus ist gewählt, weil der
Dev-Modus immer HTTP auf 8080 öffnet. Details:
[../technical/autorisierungsserver.md](../technical/autorisierungsserver.md).

Konfiguration von `service-r` (`application.yaml`, per Umgebung überschreibbar):
`service-r.issuer=${KC_REALM_ISSUER}`, `service-r.audience=${SERVICE_R_AUDIENCE}`; RS256 ist
im `JwtDecoder` fest eingestellt. `entrypoint.sh` baut aus `SERVICE_R_TRUST_CA`
(`/trust/ca.crt`) einen PKCS12-Truststore nur mit der Lab-CA und setzt ihn als JVM-Default.
Der Container läuft als `USER 10001`. R spricht nur HTTPS auf 8443: `server.ssl.bundle=service-r`,
PEM-Bundle `spring.ssl.bundle.pem.service-r` mit `keystore.certificate` / `keystore.private-key`
aus `${SERVICE_R_TLS_DIR:/tls}/tls.crt` bzw. `tls.key` (Volume `service-r-tls`), Protokolle
`TLSv1.3`, `TLSv1.2`; kein HTTP-Listener.

`keycloak-gateway` und `keycloak-admin` sind nginx-Container (`${NGINX_IMAGE}`,
`mem_limit: 64m`) mit `tools/nginx-keycloak-gateway.conf` bzw.
`tools/nginx-keycloak-admin.conf`.

**Speicherbedarf** (gemessen mit `docker stats`): Keycloak ~626 MiB bei `mem_limit: 1g`
(Heap über `JAVA_OPTS_KC_HEAP=-XX:MaxRAMPercentage=70`), `service-r` ~156 MiB bei
`mem_limit: 384m`; zum Vergleich der `validator` ~257 MiB.

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
  Änderung, auch die des Deploy-Werkzeugs, und werden an ein externes System geliefert; die
  Git-Historie dokumentiert Antrag und Freigabe.
- **Ein Schreiber.** keycloak-config-cli oder Terraform läuft in der CI als einziger
  Schreiber des Realms; eine Drift-Erkennung meldet Abweichungen zwischen Git und Keycloak.
  Im Lab legt `--import-realm` den Realm dagegen nur einmal an (`IGNORE_EXISTING`).
- **Cluster-RBAC gehört zur Autorisierungsgrenze.** Wer Tokens für einen ServiceAccount
  anfordern (`serviceaccounts/token`) oder Pods mit dessen `serviceAccountName` anlegen
  darf, bekommt dessen Scopes. Diese Rechte sind entsprechend restriktiv zu vergeben.
- **Transport zu den Diensten.** Alle Dienste außerhalb des Clusters sprechen TLS mit
  Zertifikaten der internen PKI. In Produktion kommen mTLS (z. B. Service Mesh) oder
  sender-gebundene Tokens wie DPoP als Option dazu.
- **Admin-Zugang** nur aus einem getrennten Verwaltungsnetz. Im Lab startet der Proxy
  `keycloak-admin` nur bei Bedarf, weil ein veröffentlichter Docker-Port auch aus
  `workload-net` erreichbar ist.

## 9. Ausweichlösung: eigener Spring-Autorisierungsserver

Solange die organisatorische Abstimmung zum gemeinsamen Keycloak offen ist, ist ein
eigener Autorisierungsserver pro Fachbereich auf Basis von Spring Authorization Server die
dokumentierte Ausweichlösung. Die Ressourcendienste hängen nur an **Issuer-URL und
Scope-Namen**; der Autorisierungsserver ist damit austauschbar, ohne R zu ändern.

Einschränkung: RFC 7523 verlangt in einer Client-Assertion `iss = sub = client_id`. Ein
ServiceAccount-Token hat `iss=https://issuer.wif.local` und
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
`aud=service-r`, `typ=Bearer`, `scope` enthält als Menge genau `r:orders:read` und
`r:orders:write` (Reihenfolge beliebig), `azp=workload-a`.

**AK2 – nicht zugeordneter Scope wird nicht vergeben**
Gegeben `reader`, wenn er `scope=r:orders:read r:orders:write` anfragt,
dann lehnt Keycloak mit `400 invalid_scope` ab; fragt er nur `scope=r:orders:read` an,
enthält das Access-Token genau `r:orders:read`.

**AK3 – unbekannte Workload**
Gegeben `stranger` mit gültigem `kc-token`, wenn er ein Token anfragt,
dann antwortet Keycloak `401` mit `error=invalid_client`.

**AK4 – SA-Token mit falscher Audienz**
Gegeben `consumer`, wenn er sein `sa-token` (Audienz `wif-demo-validator`) als
Client-Assertion verwendet, dann antwortet Keycloak `400 invalid_client`
(„Invalid token audience“).

**AK5 – fremder Cluster**
Gegeben ein JWT mit `iss=https://other-cluster`, `sub=system:serviceaccount:wif-demo:consumer`,
`aud=<Realm-Issuer>`, signiert mit einem Schlüssel außerhalb des Lab-Clusters,
wenn es als Client-Assertion verwendet wird, dann antwortet Keycloak `401 invalid_client`.
Dasselbe gilt für ein JWT mit `iss=https://issuer.wif.local`, das mit einem fremden Schlüssel
signiert ist.

**AK6 – erlaubter Aufruf**
Gegeben ein Access-Token aus AK1, wenn `consumer` `GET /orders` und `POST /orders` bei R
aufruft, dann antwortet R jeweils `200` und nennt `clientId=workload-a` (aus `azp`).

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
Keycloak erreicht den API-Server weder über `172.31.7.2:6443` noch über `172.31.9.2:6443`,
Traefiks Node-Port nicht direkt über `172.31.7.2:30443` und `ingress-lb` nicht über dessen
`cluster-net`-Seite `172.31.7.20:443`. Der einzige Weg in den Cluster ist
`172.31.8.20:443` (`ingress-lb`, Ingress-Route `issuer.wif.local`).

**AK13 – bestehendes Verhalten**
Alle bestehenden Prüfungen von `tools/run-all-checks.sh` laufen unverändert durch.

**AK14 – eine Audienz pro Token**
Gegeben ein Access-Token von `consumer` für `scope=r:orders:read s:inventory:read`
(`aud` = `service-r` und `service-s`), wenn er `GET /orders` aufruft, dann antwortet R `401`.
R akzeptiert nur Tokens mit `aud` genau `["service-r"]`, `typ=Bearer` und vorhandenem `azp`.

**AK15 – Admin-Oberfläche für Workloads unerreichbar**
Gegeben der Pod `stranger`, wenn er über `https://keycloak:8443` `GET /admin/realms`,
`GET /admin/master/console/` oder einen Password-Grant am Master-Realm versucht, dann
antwortet das Gateway `404`. Ein Pfad `/realms/domain-rst/../master/…` erreicht den
Master-Realm nicht. Keycloak selbst (`172.31.8.30:8443`, `:9000`) ist aus dem Pod nicht
erreichbar; die Realm-Discovery über das Gateway liefert `200`.

**AK16 – R nur über HTTPS mit Zertifikat der internen CA**
Gegeben ein Pod mit der ConfigMap `internal-ca`, wenn er `https://service-r.wif.local:8443`
aufruft, dann zeigt R ein Zertifikat mit Subject `CN=service-r.wif.local`, ausgestellt von
der Lab-Root-CA. Auf 8080 antwortet kein Klartext-Listener, Klartext-HTTP auf 8443 wird mit
`400` abgewiesen, und ein Aufruf nur mit dem öffentlichen CA-Bundle scheitert (curl
Exit-Code 60).

## 12. Testfälle

### Unit- und Slice-Tests in `service-r` (offline, TDD)

Mit einem lokal erzeugten RSA-Schlüssel und einem `JwtDecoder` gegen diesen Schlüssel
(gleiche Validatoren wie in Produktion: Issuer, Audienz, Token-Typ, `azp`, Zeitstempel):

`OrdersEndpointSecurityTest`:

- `getOrders_givenReadScope_thenReturns200`
- `postOrders_givenWriteScope_thenReturns200`
- `postOrders_givenOnlyReadScope_thenReturns403`
- `deleteOrder_givenReadAndWriteScope_thenReturns403`
- `deleteOrder_givenAdminScope_thenReturns200`
- `getOrders_givenWrongAudience_thenReturns401`
- `getOrders_givenAudienceAsPlainString_thenReturns200`
- `getOrders_givenTokenForSeveralAudiences_thenReturns401`
- `getOrders_givenIdTokenType_thenReturns401`
- `getOrders_givenNoClientId_thenReturns401`
- `getOrders_givenHs256SignedWithRealmPublicKey_thenReturns401`
- `getOrdersWithTrailingSlash_givenReadScope_thenReturns403`
- `getOrders_givenWrongIssuer_thenReturns401`
- `getOrders_givenExpiredToken_thenReturns401`
- `getOrders_givenTamperedSignature_thenReturns401`
- `getOrders_givenTokenSignedByForeignKey_thenReturns401`
- `getOrders_givenNoToken_thenReturns401`
- `unmappedPath_givenAllScopes_thenReturns403`

`ScopeAuthoritiesTest`:

- `convert_givenScopeClaim_thenMapsToScopeAuthorities`

### Ende-zu-Ende-Prüfungen in `tools/demo.sh` (Modus `authz`)

| # | Prüfung | Erwartung |
|---|---|---|
| 8 | Realm-Discovery von Keycloak über TLS mit Lab-CA, bis zu 60 s wiederholt (beim ersten Start meldet `/health/ready` schon `UP`, während der Realm noch `503` liefert) | `issuer` = Realm-Issuer |
| 9 | `consumer` holt Access-Token (AK1), Claims dekodieren | `aud`, `scope` (als Menge), `azp` wie erwartet |
| 10 | `reader` fordert Lese- und Schreib-Scope, dann nur Lese-Scope (AK2) | `400 invalid_scope`, dann nur `r:orders:read` |
| 11 | `stranger` fordert Token (AK3) | `401 invalid_client` |
| 12 | `sa-token` als Client-Assertion (AK4) | `400 invalid_client` |
| 13 | JWT fremder Cluster / fremder Schlüssel (AK5) | `401 invalid_client` |
| 14 | `consumer` → R `GET`/`POST /orders` über HTTPS (AK6) | `200` |
| 14b | TLS von R aus dem Pod: Zertifikat, Klartext auf 8080 und 8443, öffentliches CA-Bundle (AK16) | `CN=service-r.wif.local` von der Lab-Root-CA; kein Listener auf 8080; `400`; curl Exit-Code 60 |
| 15 | `reader` → R `POST /orders`, `consumer` → `DELETE` (AK7) | `403` |
| 16 | Token mit `aud=service-s` → R (AK8) | `401` |
| 16b | Token für R und S zugleich → R (AK14) | `401` |
| 17 | manipuliertes Access-Token → R (AK9) | `401` |
| 18 | `kc-token` direkt → R (AK10) | `401` |
| 19 | dreimal `access-token.sh` (AK11) | eine Token-Anfrage |
| 20 | `stranger`: Admin-API, Admin-Konsole, Master-Realm-Password-Grant, Pfad-Traversal, Keycloak direkt, Realm-Discovery über das Gateway (AK15) | `404`/`404`/`404`, bleibt im Realm, unerreichbar, `200` |
| 21 | optional `DEMO_EXPIRY=1`: Access-Token nach `exp` + 60 s → R (AK9) | `401` |

`demo.sh` leert zu Beginn von `authz` die Token-Caches aller Pods und übergibt Tokens nie
als Argument: Bearer-Tokens per `kubectl exec -i` auf stdin an `curl -H @-`,
Client-Assertions per `client_assertion@-` bzw. `@<datei>`.

### Abschnitte in `tools/run-all-checks.sh`

- Abschnitt „1b. authorization server demo“: `docker compose run --rm demo authz`.
- Abschnitt 2 prüft die Netztrennung auch aus Sicht von `service-r` und Keycloak (AK12);
  bei Keycloak mit `bash`-`/dev/tcp`, da das Image kein `curl` enthält, abgesichert durch
  eine Positivprobe auf `ingress-lb` (`172.31.8.20:443`).
- Abschnitt 4 (Schlüsselwechsel in zwei Phasen): `staged` legt nach `sa-keys stage` eine
  Client-Assertion vor, die noch mit dem bisherigen Schlüssel signiert ist; `post-rotation`
  prägt nach `sa-keys activate` per `kubectl create token` ein Token mit Realm-Audienz und
  neuer `kid` und legt es direkt als Client-Assertion vor. Erwartung jeweils `200`, beim
  ersten Versuch.

## 13. Geklärte Punkte und offene Umsetzungsaufgabe

Geklärt (gemessen im Lab mit Keycloak 26.8.2, Details in
[../technical/autorisierungsserver.md](../technical/autorisierungsserver.md)):

- **Feature-Flags und Realm-Felder.** `client-auth-federated` und
  `kubernetes-service-accounts` sind standardmäßig aktiv; `KC_FEATURES` ist nicht nötig.
  Identity-Provider: `providerId: kubernetes`, `config.issuer`. Client:
  `clientAuthenticatorType: federated-jwt`, Attribute `jwt.credential.issuer` (= Alias des
  Identity-Providers) und `jwt.credential.sub`. Keycloak lädt die Cluster-Schlüssel lazy über
  `<issuer>/.well-known/openid-configuration`, also vom Issuer-Pod hinter dem Ingress.
- **Nicht zugeordneter Scope.** Keycloak lehnt mit `400 invalid_scope` („Invalid scopes: …“)
  ab und lässt den Scope nicht stillschweigend weg (AK2).
- **Weitere Fehlerantworten.** Unregistrierte Workload und gefälschte Assertions (fremder
  Issuer; `https://issuer.wif.local` mit echter `kid`, aber fremdem Schlüssel): `401 invalid_client`.
  Falsche Audienz: `400 invalid_client` („Invalid token audience“).
- **Wiederverwendung.** Dasselbe ServiceAccount-Token wird mehrfach als Client-Assertion
  akzeptiert; für Kubernetes-Tokens gibt es keine Einmal-Prüfung. Darauf beruht die
  Cache-Erneuerung, solange das kubelet dieselbe Datei hält.
- **JWKS-Cache beim Schlüsselwechsel.** Bei einer unbekannten `kid` lädt Keycloak das JWKS
  neu, frühestens 10 s nach dem letzten Abruf (`min-time-between-requests`). Weil der neue
  Schlüssel nach `sa-keys stage` schon ausgeliefert wird, bevor er signiert, wird die erste
  Assertion mit ihm ohne Wartezeit akzeptiert.
- **Access-Token.** `aud` ist der String `"service-r"`, `azp` die Client-ID, `sub` die UUID
  des Service-Account-Benutzers, `exp = iat + 300`; die Reihenfolge in `scope` ist nicht
  garantiert.
- **Audienz pro Token.** Ein Access-Token trägt genau eine Audienz; eine Workload, die R, S
  und T aufruft, holt je Dienst ein eigenes Token. R lehnt Tokens mit mehreren Audienzen ab
  (AK14), damit S ein für sich mit ausgestelltes Token nicht bei R wiederverwenden kann.
- **Netzplatzierung von Keycloak.** Ein veröffentlichter Docker-Port ist auch aus den anderen
  Bridge-Netzen erreichbar, unabhängig von der Host-Bindung. Keycloak veröffentlicht deshalb
  keinen Port; Workloads erreichen nur `keycloak-gateway` (AK15).

Offen:

- **U4 – Spring-Client in der Workload.** Für die Beschreibung in Schritt 4 klären, wie ein
  `OAuth2AuthorizedClientManager` eine fertige Client-Assertion aus einer Datei verwendet
  (eigener Parameter-Converter für `client_credentials`).

## 14. Offene Fragen

1. **Scope-Schema:** Reicht `<dienst>:<ressource>:<aktion>`, oder braucht es einen
   Fachbereichs-Präfix, damit Scopes über Realms hinweg eindeutig bleiben? Ein Scope ist
   ein frei strukturierbarer Bezeichner (RFC 6749, Abschnitt 3.3: keine Leerzeichen, keine
   Anführungszeichen, kein Backslash); seine Bedeutung ergibt sich nur zusammen mit Issuer
   (Realm) und Audienz.
2. **Bindung an den Cluster:** Ein Identity-Provider pro Cluster oder ein gemeinsamer
   Issuer für einen Cluster-Verbund? Wer meldet einen neuen Cluster beim Fachbereich an?
3. **Anwendungskontext im Scope:** Der `<Anwendungskontext>` aus dem heutigen DN wird Teil
   des Scope-Namens; das genaue Schema ist noch festzulegen.
4. **Absicherung im Cluster:** Wer darf im Namespace einer aufrufenden Workload Pods
   anlegen und Tokens für ihren ServiceAccount anfordern, mit welchem Freigabeprozess, und
   wie erfährt der Fachbereich davon? Ein Access-Token unterscheidet zwei Anwendungen, die
   sich einen ServiceAccount teilen, nicht.

### Festgelegt

- **Betriebsumgebung:** Test und Produktion vertrauen einander nie. Jede Umgebung hat ihren
  eigenen Realm (oder ihre eigene Keycloak-Instanz), der nur den Clustern derselben
  Umgebung vertraut.
- **Access-Token-Laufzeit:** 300 s im Lab; der Wert für den Betrieb ist Feinabstimmung.
