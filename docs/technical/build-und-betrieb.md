# Build und Betrieb

**Für wen / was lernst du hier:** Du kennst Java und Docker-Grundlagen, aber nicht die
Besonderheiten dieses Repos. Diese Seite erklärt, wie die Container-Images entstehen
(Multi-Stage-Build, Tests im Build, Log4j2-Umstellung), die Betriebsbefehle inklusive
Schlüsselrotation und Gesamtprüfung, alle Umgebungsvariablen aus `.env` und die häufigsten
Probleme mit ihrer Lösung.

---

## Images im Überblick

| Image | Gebaut aus | Basis | Enthält |
|---|---|---|---|
| `wif-lab/tools` | `tools/Dockerfile` | `alpine:3.20` | `bash`, `curl`, `jq`, `coreutils`, `openssl`, `ca-certificates`, `kubectl v1.34.11`. Wird von `pki-init`, `sa-keys`, `bootstrap` **und** `demo` genutzt. |
| `wif-lab/validator` | `validator/Dockerfile` | Build: `maven:3.9-eclipse-temurin-25`; Laufzeit: `eclipse-temurin:25-jre-noble` | Das gebaute `validator.jar` + `curl` (für den Healthcheck) + `entrypoint.sh`. Wird von `validator` und `validator-foreign-ca` genutzt. |
| `server` | – (Fremd-Image) | `rancher/k3s:v1.34.11-k3s1` | k3s. Wird nur gezogen, nicht gebaut. |
| `issuer-web` | – (Fremd-Image) | `nginx:1.29-alpine` | Unveränderter nginx. |
| `jwks-publisher` (Pod) | – (Fremd-Image) | `curlimages/curl:8.11.1` | Wird im Cluster gezogen; das Skript kommt aus einer ConfigMap. |

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
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
```

Wichtige Punkte:

- **`mvn clean package` baut inklusive Tests.** `TokenValidatorTest` läuft **im
  Docker-Build**. Schlägt ein Test fehl, bricht der Build ab und es entsteht kein Image. Der
  Build ist damit zugleich das Test-Gate.
- **`--mount=type=cache,target=/root/.m2`** – ein BuildKit-Cache-Mount: das lokale
  Maven-Repository bleibt zwischen Builds erhalten, Abhängigkeiten werden nicht jedes Mal neu
  geladen. (Setzt BuildKit voraus – bei Docker/Compose v2 Standard.)
- **`finalName` = `validator`** in `pom.xml:70`, deshalb `target/validator.jar`.
- **Laufzeit-Image** ist ein reines JRE-Image (`25-jre-noble`, Ubuntu-basiert). `curl` wird
  nachinstalliert, weil der Compose-Healthcheck `curl -fsS http://localhost:8080/healthz`
  ausführt (`compose.yaml:190`).
- **`entrypoint.sh`** wartet vor dem `java`-Start, bis `/trust/ca.crt` da ist (siehe
  [validator.md](validator.md)), und startet dann mit `-XX:MaxRAMPercentage=75`.

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

**Auch** beim Test-Starter wird `spring-boot-starter-logging` ausgeschlossen (`pom.xml:60`) –
sonst zöge er Logback über die Testabhängigkeiten wieder herein, und es gäbe zwei
konkurrierende Logging-Bindings auf dem Classpath.

Der Anwendungscode loggt entsprechend über `org.apache.logging.log4j.LogManager`
(`JwksTrustConfig.java:21`).

### Weitere `pom.xml`-Besonderheiten

- **Java 25**, Spring Boot **4.1.1** (`spring-boot-starter-parent`).
- `nimbus-jose-jwt` **10.9.1** – explizit gepinnt (`pom.xml:23`).
- `jspecify` **1.0.1** für Null-Annotationen.
- **`-Werror -Xlint:all`** (`pom.xml:80`): jede Compiler-Warnung ist ein Build-Fehler.

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
tools/run-all-checks.sh              # alle Prüfungen inkl. Netztrennung und Rotation
docker compose down -v               # alles wieder entfernen (inkl. Volumes)
```

### `docker compose up -d --build`

- `--build` – baut die lokalen Images (`wif-lab/tools`, `wif-lab/validator`) vor dem Start neu.
- `-d` – "detached", läuft im Hintergrund. Der Befehl kehrt zurück, sobald die Container
  gestartet sind; `docker compose run --rm demo` wartet über `depends_on`, bis der Validator
  gesund ist. (`--wait` passt hier nicht: Compose wertet die beendeten Einmal-Jobs
  `pki-init`, `sa-keys` und `bootstrap` dabei als Fehler.)
- Startet `pki-init`, `sa-keys`, `server`, `bootstrap`, `issuer-web` und `validator` in der
  Reihenfolge aus [architecture.md](architecture.md#startreihenfolge). `demo` und
  `validator-foreign-ca` starten wegen ihrer Profile **nicht** mit.
- Status ansehen: `docker compose ps`; Logs: `docker compose logs -f validator`.

### `docker compose run --rm demo [all|pre-rotation|post-rotation]`

- `run` startet einen einmaligen `demo`-Container und aktiviert dessen Profil automatisch.
- `--rm` entfernt den Container nach dem Lauf.
- `all` (Standard): Discovery + JWKS anzeigen, Token prägen und dekodieren, Happy-Path aus dem
  Pod (HTTP 200), Negativfälle falsche Audience / manipulierte Signatur (HTTP 401),
  Upload-Versuche ohne gültiges Publisher-Zertifikat (400/400/403/403). Mit
  `DEMO_EXPIRY=1 docker compose run --rm demo` kommt ein ~10-minütiger Ablauf-Test dazu (die
  TokenRequest-API vergibt keine TTL unter 10 min).
- `pre-rotation` / `post-rotation`: die zwei Hälften des Rotationstests, siehe unten.
- Details der Schritte: [../use-cases.md](../use-cases.md#verifikation-auf-einen-blick).

### Schlüsselrotation

```bash
docker compose run --rm demo pre-rotation    # Token + kids vor der Rotation sichern
docker compose run --rm sa-keys rotate       # neuer Signierschlüssel, alter bleibt Prüfschlüssel
docker compose restart server                # kube-apiserver liest die Schlüssel nur beim Start
docker compose up -d --wait server
docker compose run --rm demo post-rotation   # neue kid veröffentlicht? alte und neue Tokens gültig?
```

Der Publisher lädt das geänderte JWKS innerhalb von 15 s nach dem Neustart hoch; ein Eingriff
an `issuer-web` ist nicht nötig. Hintergrund:
[bootstrap-und-issuer.md](bootstrap-und-issuer.md#toolssa-keyssh--signaturschlüssel-und-rotation).

### `tools/run-all-checks.sh`

Läuft auf dem Host und braucht nur `docker compose`. Es startet den Stack und führt
nacheinander aus: `demo all`, die Netztrennungsprüfung vom Validator aus (kein Zugriff auf
`172.31.9.2:6443`, `172.31.7.2:6443`, `172.31.8.20:8443`), `validator-foreign-ca` (muss mit
Fehlercode enden, Timeout 180 s) und die Schlüsselrotation wie oben. Bricht beim ersten
Fehler mit `FAIL:` ab, sonst `PASS: all lab checks passed`.

Nach einem Lauf ist der Signaturschlüssel rotiert. Für einen frischen Ausgangszustand
`docker compose down -v`.

### `docker compose down -v`

- `down` stoppt und entfernt Container und die Netze `cluster-net`, `relying-net`,
  `workload-net`.
- **`-v` entfernt zusätzlich alle Named Volumes** (Cluster-Zustand, Signaturschlüssel, PKI,
  `oidc-web`, `demo-state`). Ohne `-v` bleiben sie liegen – dann startet der nächste `up` mit
  dem alten Cluster, derselben CA, denselben Zertifikaten und Schlüsseln. Für einen echten
  Neuanfang immer `-v`.

---

## Umgebungsvariablen (`.env` / `.env.example`)

`docker compose` liest `.env` im Projektverzeichnis automatisch. Vorlage: `.env.example`
(1:1 nach `.env` kopieren).

| Variable | Beispielwert | Wirkung | Verwendet in |
|---|---|---|---|
| `K3S_TOKEN` | `lab-not-a-secret-change-me` | Cluster-internes Beitrittsgeheimnis von k3s. Im Single-Node-Lab ohne echte Sicherheitsbedeutung – trotzdem **kein echtes Secret committen**. | `compose.yaml:91` |
| `K3S_IMAGE` | `rancher/k3s:v1.34.11-k3s1` | Pinnt die k3s-Version. Bei Änderung sollte `KUBECTL_VERSION` in `tools/Dockerfile` mitziehen. | `compose.yaml:72` |
| `WIF_ISSUER` | `https://issuer-web` | Sollwert des `iss`-Claims **und** Basis-URL der OIDC-Discovery im Validator. Muss aus dem Validator-Container erreichbar sein (dort nur `issuer-web`) und zum SAN des Serverzertifikats passen (`DNS:issuer-web`). | `compose.yaml:174`, `application.yaml:2` |
| `WIF_AUDIENCE` | `wif-demo-validator` | Audience, die der Validator verlangt und mit der die Demo Tokens prägt. Muss zum `audience` im Pod-Manifest passen (`manifests/20-consumer.yaml:47`). | `compose.yaml:175`, `compose.yaml:218` |
| `VALIDATOR_HOST_PORT` | `18080` | Host-Port, auf dem der Validator-Port 8080 zusätzlich veröffentlicht wird (für `curl` vom Host). Nur diese Zuordnung, keine Funktionsänderung. | `compose.yaml:185` |

Nicht in `.env`, aber zur Laufzeit auswertbar:

| Variable | Default | Wirkung |
|---|---|---|
| `WIF_ISSUER_CA` | `/trust/ca.crt` | PEM-Datei mit dem Root-Zertifikat der internen CA, der der Validator für TLS zu `issuer-web` vertraut. Im Compose fest gesetzt (`compose.yaml:176`; bei `validator-foreign-ca` `/pki-demo/foreign-ca.crt`), zusätzlich von `entrypoint.sh:4` gelesen. |
| `JAVA_OPTS` | – | Zusätzliche JVM-Flags, an `java` durchgereicht (`entrypoint.sh:18`). |
| `NGINX_IMAGE` | `nginx:1.29-alpine` | Image von `issuer-web` (`compose.yaml:143`). |
| `DEMO_EXPIRY` | `0` | `1` hängt an `demo.sh` den echten Ablauf-Test an (`tools/demo.sh:103`). |
| `VALIDATOR_URL` | `http://validator:8080` | Ziel-URL, die `demo.sh` direkt anspricht (`compose.yaml:219`). |

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

Eine alte `.env` kann `WIF_ISSUER` auf eine andere URL als `https://issuer-web` setzen. Der
Validator erreicht außer `issuer-web` nichts, und das Serverzertifikat gilt nur für
`DNS:issuer-web`.

**Lösung:**

```bash
cp .env.example .env
docker compose up -d --force-recreate validator
```

### k3s braucht `privileged`

`server` läuft mit `privileged: true` (`compose.yaml:86`). k3s startet intern selbst Container
und braucht dafür weitreichende Kernel-Rechte. Wird das entfernt oder von der
Container-Laufzeit unterbunden (gehärtete Umgebungen, manche CI-Runner, Docker "rootless"),
startet der Cluster nicht und der Healthcheck bleibt für immer `starting`. Das Lab braucht
eine Umgebung, die privilegierte Container erlaubt.

### "read-only file system", wenn man Manifeste nach `server/manifests` mountet

k3s hat ein "Auto-Deploy"-Verzeichnis unter `/var/lib/rancher/k3s/server/manifests`. Verlockend,
die Lab-Manifeste dort per Bind Mount hineinzulegen. Das schlägt fehl bzw. führt zu
*"read-only file system"*-Fehlern, weil dieser Pfad im Volume `k3s-data` liegt und von k3s
selbst verwaltet wird. Deshalb wendet dieses Lab die Manifeste **von außen** an: `bootstrap`
führt `kubectl apply -f /manifests` aus (`tools/bootstrap.sh:27`), mit `./manifests` als
read-only Bind Mount in den *Bootstrap*-Container (`compose.yaml:128`).

### `docker compose down` ohne `-v` "vergisst" den Reset

**Symptom:** Nach vermeintlichem Neuaufsetzen zeigt der Cluster alte Objekte, der
Signaturschlüssel ist noch der rotierte, oder CA und Zertifikate sind die alten.

`down` allein lässt alle Volumes stehen. Der nächste `up` baut auf diesem alten Zustand auf –
`pki-init` und `sa-keys init` behalten vorhandenes Material bewusst. Werden nur einzelne
PKI-Volumes gelöscht, passen CA, Serverzertifikat und Vertrauensanker womöglich nicht mehr
zueinander.

**Lösung:** `docker compose down -v`, dann `docker compose up -d --build`.

### `issuer-web` wird nicht `healthy`

`issuer-web` wird erst gesund, wenn der Publisher das JWKS hochgeladen hat. Bleibt es
`starting`:

```bash
docker compose logs bootstrap                                          # Exit 0? Rollouts ok?
docker compose exec server kubectl -n wif-publisher logs deploy/jwks-publisher
docker compose logs issuer-web | grep -E 'PUT|client_dn'               # kam ein Upload an? Status?
```

Typische Ursachen: `bootstrap` ist gescheitert (kein Secret, kein Publisher), der Publisher
erreicht `172.31.7.20:8443` nicht, oder das Client-Zertifikat passt nicht zur CA in
`ca-trust` (dann `400` im Log; siehe vorheriger Abschnitt).

### Der Validator ist dauerhaft `unhealthy`

Prüf-Reihenfolge:

```bash
docker compose ps                       # welcher Service hängt?
docker compose logs issuer-web          # antwortet nginx, kam der Upload an?
docker compose logs validator           # Discovery-Fehler? PKIX? CA fehlt?
docker compose exec validator printenv WIF_ISSUER WIF_AUDIENCE WIF_ISSUER_CA
```

Häufigste Ursachen: `WIF_ISSUER` falsch (→ [trust-und-tls.md](trust-und-tls.md)), PKI-Volumes
nicht zueinander passend (→ `down -v`), oder `start_period` zu kurz auf sehr langsamer
Hardware (die JVM braucht Zeit; der Healthcheck hat `start_period: 40s`,
`compose.yaml:194`).

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
- [trust-und-tls.md](trust-und-tls.md) – `PKIX path building failed` im Detail
- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – PKI, Signaturschlüssel, Bootstrap, Publisher
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
- [../kubernetes-primer.md](../kubernetes-primer.md) – Kubernetes-Grundbegriffe
