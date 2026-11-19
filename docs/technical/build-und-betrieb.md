# Build und Betrieb

**Für wen / was lernst du hier:** Du kennst Java und Docker-Grundlagen, aber nicht die
Besonderheiten dieses Repos. Diese Seite erklärt, wie die Container-Images entstehen
(Multi-Stage-Build, Tests im Build, Log4j2-Umstellung), die Betriebsbefehle inklusive
Schlüsselwechsel und Gesamtprüfung, alle Umgebungsvariablen aus `.env` und die häufigsten
Probleme mit ihrer Lösung.

---

## Images im Überblick

| Image | Gebaut aus | Basis | Enthält |
|---|---|---|---|
| `wif-lab/tools` | `tools/Dockerfile` | `alpine:3.20` | `bash`, `curl`, `jq`, `coreutils`, `openssl`, `ca-certificates`, `kubectl v1.34.11`. Wird von `pki-init`, `sa-keys`, `bootstrap` **und** `demo` genutzt. |
| `wif-lab/validator` | `validator/Dockerfile` | Build: `maven:3.9-eclipse-temurin-25`; Laufzeit: `eclipse-temurin:25-jre-noble` | Das gebaute `validator.jar` + `curl` (für den Healthcheck) + `entrypoint.sh`. Wird von `validator` und `validator-foreign-ca` genutzt. |
| `wif-lab/service-r` | `service-r/Dockerfile` | wie `wif-lab/validator` | `service-r.jar` + `curl` + `entrypoint.sh` (baut den PKCS12-Truststore nur mit der Lab-CA). Tests laufen im Build. |
| `keycloak` | – (Fremd-Image) | `quay.io/keycloak/keycloak:26.8.2` | Unverändertes Keycloak; Realm per Bind Mount, siehe [autorisierungsserver.md](autorisierungsserver.md). |
| `server` | – (Fremd-Image) | `rancher/k3s:v1.34.11-k3s1` | k3s mit dem mitgelieferten Traefik. Wird nur gezogen, nicht gebaut. |
| `ingress-lb`, `keycloak-gateway`, `keycloak-admin` | – (Fremd-Image) | `nginx:1.29-alpine` | Unveränderter nginx; Konfiguration per Bind Mount aus `tools/`. |
| `issuer` (Pod, `wif-issuer`) | – (Fremd-Image) | `curlimages/curl:8.23.0` (`sync`), `nginxinc/nginx-unprivileged:1.31.7-alpine` (`web`), beide per Digest gepinnt | Wird im Cluster gezogen; Skript und nginx-Config kommen aus ConfigMaps. |
| `consumer`, `reader`, `stranger` (Pods) | – (Fremd-Image) | `curlimages/curl:8.11.1` | Wird im Cluster gezogen; Skripte kommen aus ConfigMaps. |

### Das `tools/`-Image

`tools/Dockerfile` installiert die Shell-Werkzeuge per `apk add` und lädt `kubectl` in der zur
k3s-Version passenden Fassung herunter (`ARG KUBECTL_VERSION=v1.34.11`). `TARGETARCH` erlaubt
amd64/arm64. `kubectl version --client` im Build ist ein Rauchtest, dass das Binary läuft.

### Das `validator/`-Image – Multi-Stage-Build

Ein **Multi-Stage-Build** hat mehrere `FROM`-Abschnitte. Der erste ("Stage") baut die
Anwendung mit allen Build-Werkzeugen; der zweite kopiert nur das fertige Artefakt in ein
schlankes Laufzeit-Image. Das Ergebnis-Image enthält weder Maven noch das JDK-Compiler-Toolkit.

`validator/Dockerfile`:

```dockerfile
FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B -q clean package

FROM eclipse-temurin:25-jre-noble
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/target/validator.jar app.jar
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER 10001
EXPOSE 8443
ENTRYPOINT ["/entrypoint.sh"]
```

Wichtige Punkte:

- **`mvn clean package` baut inklusive Tests.** `TokenValidatorTest` und `JwksUriPolicyTest`
  laufen **im Docker-Build**. Schlägt ein Test fehl, bricht der Build ab und es entsteht kein Image. Der
  Build ist damit zugleich das Test-Gate.
- **`--mount=type=cache,target=/root/.m2`** – ein BuildKit-Cache-Mount: das lokale
  Maven-Repository bleibt zwischen Builds erhalten, Abhängigkeiten werden nicht jedes Mal neu
  geladen. (Setzt BuildKit voraus – bei Docker/Compose v2 Standard.)
- **`finalName` = `validator`** in `pom.xml:83`, deshalb `target/validator.jar`.
- **Laufzeit-Image** ist ein reines JRE-Image (`25-jre-noble`, Ubuntu-basiert). `curl` wird
  nachinstalliert, weil der Compose-Healthcheck
  `curl -fsS --cacert /trust/ca.crt https://localhost:8443/healthz`
  ausführt.
- **`entrypoint.sh`** wartet vor dem `java`-Start, bis `/trust/ca.crt` da ist (siehe
  [validator.md](validator.md)), und startet dann mit `-XX:MaxRAMPercentage=75`.
- **Nur HTTPS:** Der Container läuft als `USER 10001` und öffnet nur 8443; das
  Serverzertifikat kommt aus dem Volume `validator-tls` (`VALIDATOR_TLS_DIR=/tls`).

`service-r/Dockerfile` ist gleich aufgebaut (`finalName` `service-r`), ebenfalls als
`USER 10001` und öffnet nur `EXPOSE 8443` (HTTPS). Der Healthcheck ist
`curl -fsS --cacert /trust/ca.crt https://localhost:8443/healthz`; das Serverzertifikat kommt
aus dem Volume `service-r-tls` (`SERVICE_R_TLS_DIR=/tls`). `OrdersEndpointSecurityTest`
und `ScopeAuthoritiesTest` laufen im Build. Ihr `pom.xml` nutzt
`spring-boot-starter-security-oauth2-resource-server` und schließt Logback ebenso aus.

### Log4j2 statt Logback (`pom.xml`)

Spring Boot bringt standardmäßig Logback mit (`spring-boot-starter-logging`). Das globale
Projekt-Setup verlangt Log4j2. In `pom.xml` ist das so umgesetzt:

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-web</artifactId>
  <exclusions>
    <exclusion>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-logging</artifactId>   <!-- Logback raus -->
    </exclusion>
  </exclusions>
</dependency>
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-log4j2</artifactId>        <!-- Log4j2 rein -->
</dependency>
```

**Auch** beim Test-Starter wird `spring-boot-starter-logging` ausgeschlossen (`pom.xml:76`) –
sonst zöge er Logback über die Testabhängigkeiten wieder herein, und es gäbe zwei
konkurrierende Logging-Bindings auf dem Classpath.

Der Anwendungscode loggt entsprechend über `org.apache.logging.log4j.LogManager`
(`JwksTrustConfig.java:21`).

### Weitere `pom.xml`-Besonderheiten

- **Java 25**, Spring Boot **4.1.2** in Validator und `service-r`
  (`spring-boot-starter-parent`).
- `nimbus-jose-jwt` **10.9.1** – im Validator explizit gepinnt (`pom.xml:36`).
- `jspecify` **1.0.1** für Null-Annotationen.
- **`-Werror -Xlint:all`** (Validator `pom.xml:94`, ebenso in `service-r`): jede
  Compiler-Warnung ist ein Build-Fehler.

Das Repo weicht bewusst von einigen globalen Projektstandards ab (kein hexagonales
Package-Layout, keine `hexagonal-arch`-Annotationen, `compose.yaml` statt
`docker-compose.yml`). Das ist in der repo-lokalen `CLAUDE.md` dokumentiert und **kein
Mangel**.

---

## Die Betriebsbefehle

```bash
cp .env.example .env                 # einmalig: Konfiguration anlegen
docker compose up -d --build  # Stack bauen und starten, warten bis alles gesund ist
docker compose run --rm demo         # Ende-zu-Ende-Prüfung ausführen
docker compose run --rm demo authz   # Autorisierungsserver + service-r prüfen
tools/run-all-checks.sh              # alle Prüfungen inkl. Härtung, Netztrennung und Schlüsselwechsel
docker compose down -v               # alles wieder entfernen (inkl. Volumes)
```

### `docker compose up -d --build`

- `--build` – baut die lokalen Images (`wif-lab/tools`, `wif-lab/validator`,
  `wif-lab/service-r`) vor dem Start neu.
- `-d` – "detached", läuft im Hintergrund. Der Befehl kehrt zurück, sobald die Container
  gestartet sind; `docker compose run --rm demo` wartet über `depends_on`, bis der Validator
  gesund ist. (`--wait` passt hier nicht: Compose wertet die beendeten Einmal-Jobs
  `pki-init`, `sa-keys` und `bootstrap` dabei als Fehler.)
- Startet `pki-init`, `sa-keys`, `server`, `bootstrap`, `ingress-lb`, `validator`,
  `keycloak`, `keycloak-gateway` und `service-r` in der Reihenfolge aus
  [architecture.md](architecture.md#startreihenfolge). `keycloak-admin` startet nur mit
  `docker compose --profile admin up -d keycloak-admin` (Admin-Konsole unter
  `https://localhost:18443/admin/`); danach `docker compose stop keycloak-admin`, weil sein
  veröffentlichter Port auch aus `workload-net` erreichbar ist. `demo` und
  `validator-foreign-ca` starten wegen ihrer Profile **nicht** mit.
- Status ansehen: `docker compose ps`; Logs: `docker compose logs -f validator`.

### `docker compose run --rm demo [all|authz|hardening|resilience|pre-rotation|staged|post-rotation]`

- `run` startet einen einmaligen `demo`-Container und aktiviert dessen Profil automatisch.
- `--rm` entfernt den Container nach dem Lauf.
- `all` (Standard): Discovery + JWKS über den Ingress anzeigen, Token prägen und dekodieren,
  Happy-Path aus dem Pod (HTTP 200), Negativfälle falsche Audience / manipulierte Signatur
  (HTTP 401), Issuer-Endpunkt nur lesbar und nur für den eigenen Host (`PUT`/`POST`/`DELETE`
  `403`, fremder SNI ohne Handshake). Mit `DEMO_EXPIRY=1 docker compose run --rm demo` kommt
  ein ~10-minütiger Ablauf-Test dazu (die TokenRequest-API vergibt keine TTL unter 10 min).
- `authz`: Prüfungen 8–21 zu Keycloak und `service-r` (Token-Austausch, Scope-Zuordnung,
  gefälschte Assertions, 200/401/403 bei R, eine Audienz pro Token, Cache,
  Admin-Oberfläche aus dem Pod unerreichbar). Mit `DEMO_EXPIRY=1` zusätzlich ein
  ~6-minütiger Ablauf-Test des Access-Tokens. Siehe
  [../features/keycloak-autorisierungsserver.md](../features/keycloak-autorisierungsserver.md#12-testfälle).
- `hardening`: Schutz von `wif-issuer` (H1–H5): Admission Policies per
  `kubectl apply --dry-run=server` (Issuer-Host, Wildcards, Regeln ohne Host, Router-Annotationen,
  Default-Backend, Images ohne Digest), Priorität der Issuer-Route, Traefik ohne CRD- und
  Gateway-Provider, RBAC per `kubectl auth can-i`, NetworkPolicies, Pod-Härtung.
- `resilience`: Issuer-Pod ohne API-Server (R1) und mit implausiblem Stand (R2); stellt
  NetworkPolicy und Deployment danach wieder her.
- `pre-rotation` / `staged` / `post-rotation`: die drei Prüfpunkte des Schlüsselwechsels,
  siehe unten; `staged` und `post-rotation` prüfen auch Keycloak.
- Details der Schritte: [../use-cases.md](../use-cases.md#verifikation-auf-einen-blick).

### Schlüsselwechsel

```bash
docker compose run --rm demo pre-rotation    # Token + kids vor dem Wechsel sichern
docker compose run --rm sa-keys stage        # Phase 1: neuer Schlüssel nur als Prüfschlüssel
docker compose restart server                # kube-apiserver liest die Schlüssel nur beim Start
docker compose up -d --wait server
docker compose run --rm demo staged          # neue kid ausgeliefert? signiert wird noch mit der alten
docker compose run --rm sa-keys activate     # Phase 2: neuer Schlüssel signiert, alter bleibt Prüfschlüssel
docker compose restart server
docker compose up -d --wait server
docker compose run --rm demo post-rotation   # erstes Token mit neuer kid ohne Wiederholung angenommen?
```

`demo staged` wartet bis zu 180 s, bis der Issuer-Pod die neue `kid` ausliefert, und prüft,
dass jeder Issuer-Pod sie geloggt hat. `activate` erst danach ausführen. Im Lab startet
ein Neustart von `server` den ganzen Knoten neu; `demo post-rotation` wartet deshalb zuerst,
bis der Issuer wieder ausliefert, und prüft am Ende, dass das JWKS genau zwei Schlüssel
enthält: den neuen und den vorherigen. Hintergrund:
[bootstrap-und-issuer.md](bootstrap-und-issuer.md#zweiphasiger-schlüsselwechsel).

Im Notfall, etwa bei kompromittiertem vorherigem Schlüssel, entfernt
`docker compose run --rm sa-keys retire` ihn sofort aus dem Prüfsatz; danach ebenfalls
`docker compose restart server`.

### `tools/run-all-checks.sh`

Läuft auf dem Host und braucht nur `docker compose`. Es startet den Stack und führt
nacheinander aus: `demo all`, `demo authz`, `demo hardening`, `demo resilience`, die
Netztrennungsprüfung aus Sicht von Validator, `service-r` und Keycloak (kein Zugriff auf
API-Server und Ingress-Node-Port, Keycloak erreicht nur `ingress-lb` in `relying-net`),
`validator-foreign-ca` (muss mit Fehlercode enden, Timeout 180 s) und den Schlüsselwechsel
wie oben. Bricht beim ersten Fehler mit `FAIL:` ab, sonst `PASS: all lab checks passed`.

Nach einem Lauf ist der Signaturschlüssel gewechselt. Für einen frischen Ausgangszustand
`docker compose down -v`.

### `docker compose down -v`

- `down` stoppt und entfernt Container und die Netze `cluster-net`, `relying-net`,
  `workload-net`.
- **`-v` entfernt zusätzlich alle Named Volumes** (Cluster-Zustand, Signaturschlüssel, PKI,
  `demo-state`). Ohne `-v` bleiben sie liegen – dann startet der nächste `up` mit
  dem alten Cluster, derselben CA, denselben Zertifikaten und Schlüsseln. Für einen echten
  Neuanfang immer `-v`.

---

## Umgebungsvariablen (`.env` / `.env.example`)

`docker compose` liest `.env` im Projektverzeichnis automatisch. Vorlage: `.env.example`
(1:1 nach `.env` kopieren).

| Variable | Beispielwert | Wirkung | Verwendet in |
|---|---|---|---|
| `K3S_TOKEN` | `lab-not-a-secret-change-me` | Cluster-internes Beitrittsgeheimnis von k3s. Im Single-Node-Lab ohne echte Sicherheitsbedeutung – trotzdem **kein echtes Secret committen**. | Service `server` |
| `K3S_IMAGE` | `rancher/k3s:v1.34.11-k3s1` | Pinnt die k3s-Version. Bei Änderung sollte `KUBECTL_VERSION` in `tools/Dockerfile` mitziehen. | Service `server` |
| `WIF_ISSUER` | `https://issuer.wif.local` | Sollwert des `iss`-Claims **und** Basis-URL der OIDC-Discovery im Validator. Muss aus dem Validator-Container erreichbar sein (dort nur über `ingress-lb`, Alias `issuer.wif.local`) und zum SAN des Ingress-Zertifikats passen (`DNS:issuer.wif.local`). | Service `validator`, `validator/…/application.yaml:2` |
| `WIF_AUDIENCE` | `wif-demo-validator` | Audience, die der Validator verlangt und mit der die Demo Tokens prägt. Muss zum `audience` des `sa-token` im Pod-Manifest passen (`manifests/20-consumer.yaml`). | Services `validator`, `demo` |
| `VALIDATOR_HOST_PORT` | `18080` | Host-Port (`127.0.0.1`) für den HTTPS-Port 8443 des Validators: `https://localhost:18080` (Lab-CA). Nur diese Zuordnung, keine Funktionsänderung. | Service `validator` |
| `NGINX_IMAGE` | `nginx:1.29-alpine` | Image von `ingress-lb`, `keycloak-gateway` und `keycloak-admin`. | Services `ingress-lb`, `keycloak-gateway`, `keycloak-admin` |
| `KEYCLOAK_IMAGE` | `quay.io/keycloak/keycloak:26.8.2` | Pinnt die Keycloak-Version. | Service `keycloak` |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` | `admin` / `lab-not-a-secret-change-me` | Lab-Admin der Keycloak-Admin-Konsole. Kein Geheimnis, nur Lab. | Service `keycloak` |
| `KEYCLOAK_HOST_PORT` | `18443` | Host-Port (`127.0.0.1`) des Admin-Proxys `keycloak-admin` (Profil `admin`); zugleich Port in `KC_HOSTNAME_ADMIN=https://localhost:<port>` von Keycloak. | Services `keycloak-admin`, `keycloak` |
| `KC_REALM_ISSUER` | `https://keycloak:8443/realms/domain-rst` | Realm-Issuer. Muss zur `audience` des `kc-token` in den Pod-Manifesten passen. | Services `service-r` (`service-r.issuer`), `demo` |
| `SERVICE_R_AUDIENCE` | `service-r` | Audienz, die `service-r` verlangt; muss zum Audience-Mapper im Realm passen. | Service `service-r` (`service-r.audience`) |
| `SERVICE_R_HOST_PORT` | `18081` | Host-Port (`127.0.0.1`) für den HTTPS-Port 8443 von `service-r`: `https://localhost:18081` (Lab-CA). | Service `service-r` |

Nicht in `.env`, aber zur Laufzeit auswertbar:

| Variable | Default | Wirkung |
|---|---|---|
| `WIF_ISSUER_CA` | `/trust/ca.crt` | PEM-Datei mit dem Root-Zertifikat der internen CA, der der Validator für TLS zu `issuer.wif.local` vertraut. Im Compose fest gesetzt (bei `validator-foreign-ca` `/pki-demo/foreign-ca.crt`), zusätzlich von `validator/entrypoint.sh` gelesen. |
| `VALIDATOR_TLS_DIR` | `/tls` | Verzeichnis mit `tls.crt` / `tls.key` des HTTPS-Listeners des Validators (PEM-Bundle `validator`). Im Compose fest gesetzt, auch bei `validator-foreign-ca`. |
| `SERVICE_R_TRUST_CA` | `/trust/ca.crt` | PEM-Datei der internen CA, aus der `service-r/entrypoint.sh` den Truststore baut. Im Compose fest gesetzt. |
| `SERVICE_R_TLS_DIR` | `/tls` | Verzeichnis mit `tls.crt` / `tls.key` des HTTPS-Listeners von `service-r` (PEM-Bundle `service-r`). Im Compose fest gesetzt. |
| `JAVA_OPTS` | – | Zusätzliche JVM-Flags, von beiden `entrypoint.sh` an `java` durchgereicht. |
| `DEMO_EXPIRY` | `0` | `1` hängt an `demo.sh all` und `demo.sh authz` die echten Ablauf-Tests an (Prüfungen 7 und 21). |
| `VALIDATOR_URL` | `https://validator:8443` | Ziel-URL, die `demo.sh` direkt anspricht (Service `demo`, geprüft mit `--cacert /trust/ca.crt`). |

**Secrets:** Es gibt in diesem Lab keine echten Geheimnisse. `.env` steht in `.gitignore`;
committe stattdessen nur `.env.example` mit Platzhaltern.

---

## Häufige Probleme und Lösungen

### Port 6443 oder 18080 ist belegt

**Symptom:** `up` scheitert mit *"bind: address already in use"* oder *"port is already
allocated"*.

- **6443** – der API-Server-Port. Belegt z. B. durch ein lokales k3d/minikube/Rancher
  Desktop. Der `server`-Service veröffentlicht 6443 nicht auf dem Host (nur auf
  `172.31.7.2` in `cluster-net`), aber manche k3s-Setups tun es. Konkurrierendes Kubernetes stoppen oder das Lab auf einer
  Maschine ohne laufendes k8s ausführen.
- **18080** – der optionale Host-Port des Validators. Lösung: in `.env`
  `VALIDATOR_HOST_PORT=<freier-port>` setzen, z. B. `28080`, dann `docker compose up -d`.
  Frei prüfen mit (Windows) `netstat -ano | findstr :18080`.

### `.env` ist veraltet nach einem Umbau

**Symptom:** Der Validator startet nicht, Log zeigt einen Verbindungsfehler,
`PKIX path building failed` oder
`discovery document issuer '...' does not match configured issuer '...'`.

Eine alte `.env` kann `WIF_ISSUER` auf eine andere URL als `https://issuer.wif.local` setzen.
Der Validator erreicht vom Cluster nur `ingress-lb`, und das Ingress-Zertifikat gilt nur für
`DNS:issuer.wif.local`.

**Lösung:**

```bash
cp .env.example .env
docker compose up -d --force-recreate validator
```

### k3s braucht `privileged`

`server` läuft mit `privileged: true`. k3s startet intern selbst Container
und braucht dafür weitreichende Kernel-Rechte. Wird das entfernt oder von der
Container-Laufzeit unterbunden (gehärtete Umgebungen, manche CI-Runner, Docker "rootless"),
startet der Cluster nicht und der Healthcheck bleibt für immer `starting`. Das Lab braucht
eine Umgebung, die privilegierte Container erlaubt.

### "read-only file system", wenn man Manifeste nach `server/manifests` mountet

k3s hat ein "Auto-Deploy"-Verzeichnis unter `/var/lib/rancher/k3s/server/manifests`. Verlockend,
die Lab-Manifeste dort per Bind Mount hineinzulegen. Das schlägt fehl bzw. führt zu
*"read-only file system"*-Fehlern, weil dieser Pfad im Volume `k3s-data` liegt und von k3s
selbst verwaltet wird. Deshalb wendet dieses Lab die Manifeste **von außen** an: `bootstrap`
führt `kubectl apply -f /manifests` aus (`tools/bootstrap.sh`), mit `./manifests` als
read-only Bind Mount in den *Bootstrap*-Container.

### `docker compose down` ohne `-v` "vergisst" den Reset

**Symptom:** Nach vermeintlichem Neuaufsetzen zeigt der Cluster alte Objekte, der
Signaturschlüssel ist noch der gewechselte, oder CA und Zertifikate sind die alten.

`down` allein lässt alle Volumes stehen. Der nächste `up` baut auf diesem alten Zustand auf –
`pki-init` und `sa-keys init` behalten vorhandenes Material bewusst. Werden nur einzelne
PKI-Volumes gelöscht, passen CA, Serverzertifikat und Vertrauensanker womöglich nicht mehr
zueinander.

**Lösung:** `docker compose down -v`, dann `docker compose up -d --build`.

### `ingress-lb` wird nicht `healthy`

`ingress-lb` wird erst gesund, wenn der Issuer-Pod das JWKS über den Ingress ausliefert. Bleibt
es `starting`:

```bash
docker compose logs bootstrap                                               # Exit 0? Rollouts ok?
docker compose exec server kubectl -n wif-issuer get pods                   # issuer bereit?
docker compose exec server kubectl -n wif-issuer logs deploy/issuer -c sync # REJECTED? API-Server lesbar?
docker compose exec server kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik
docker compose logs ingress-lb                                              # kommen Verbindungen an?
```

Typische Ursachen: `bootstrap` ist gescheitert (kein Secret `issuer-tls`, Manifest abgelehnt),
Traefik läuft noch nicht, `sync` lehnt den Stand als implausibel ab (`REJECTED state`, z. B.
weil `service-account-issuer` nicht `https://issuer.wif.local` ist), oder das Ingress-Zertifikat
passt nicht zur CA in `ca-trust` (siehe vorheriger Abschnitt).

### Der Validator ist dauerhaft `unhealthy`

Prüf-Reihenfolge:

```bash
docker compose ps                       # welcher Service hängt?
docker compose logs ingress-lb          # kommen Verbindungen an, Status?
docker compose logs validator           # Discovery-Fehler? PKIX? CA fehlt?
docker compose exec validator printenv WIF_ISSUER WIF_AUDIENCE WIF_ISSUER_CA VALIDATOR_TLS_DIR
```

Häufigste Ursachen: `WIF_ISSUER` falsch (→ [trust-und-tls.md](trust-und-tls.md)), PKI-Volumes
nicht zueinander passend (→ `down -v`), oder `start_period` zu kurz auf sehr langsamer
Hardware (die JVM braucht Zeit; der Healthcheck hat `start_period: 40s`).

### `demo authz` scheitert direkt nach dem ersten Start an Prüfung 8

Beim ersten Start meldet Keycloak `/health/ready` als `UP`, während die Realm-Endpunkte noch
`503` („Bootstrap in progress“) liefern. Prüfung 8 wiederholt die Realm-Discovery bis zu
60 s; bricht sie danach ab, mit `docker compose logs keycloak` den Realm-Import prüfen.

### Windows-Hinweis: Zeilenenden der Skripte

Die Shell-Skripte (`pki-init.sh`, `sa-keys.sh`, `bootstrap.sh`, `demo.sh`,
`run-all-checks.sh`, `entrypoint.sh`) **müssen** LF-Zeilenenden behalten. Das ist über
`.gitattributes` erzwungen. Editoren, die CRLF erzeugen, führen zu `bad interpreter`-Fehlern.
`tools/run-all-checks.sh` läuft auf dem Host und braucht dort eine Bash (unter Windows z. B.
Git Bash): `bash tools/run-all-checks.sh`.

---

## Weiterlesen

- [architecture.md](architecture.md) – der Stack, Volumes, Startreihenfolge
- [validator.md](validator.md) – der Java-Service, Startablauf, Endpunkte
- [autorisierungsserver.md](autorisierungsserver.md) – Keycloak und `service-r`
- [trust-und-tls.md](trust-und-tls.md) – `PKIX path building failed` im Detail
- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – PKI, Signaturschlüssel, Bootstrap, Issuer-Pod
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
- [../kubernetes-primer.md](../kubernetes-primer.md) – Kubernetes-Grundbegriffe
