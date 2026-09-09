# Build und Betrieb

**Für wen / was lernst du hier:** Du kennst Java und Docker-Grundlagen, aber nicht die
Besonderheiten dieses Repos. Diese Seite erklärt, wie die Container-Images entstehen
(Multi-Stage-Build, Tests im Build, Log4j2-Umstellung), die drei Betriebsbefehle, alle
Umgebungsvariablen aus `.env` und die häufigsten Probleme mit ihrer Lösung.

---

## Images im Überblick

| Image | Gebaut aus | Basis | Enthält |
|---|---|---|---|
| `wif-lab/tools` | `tools/Dockerfile` | `alpine:3.20` | `bash`, `curl`, `jq`, `coreutils`, `openssl`, `ca-certificates`, `kubectl v1.34.11`. Wird von `bootstrap` **und** `demo` genutzt. |
| `wif-lab/validator` | `validator/Dockerfile` | Build: `maven:3.9-eclipse-temurin-25`; Laufzeit: `eclipse-temurin:25-jre-noble` | Das gebaute `validator.jar` + `curl` (für den Healthcheck) + `entrypoint.sh`. |
| `server` | – (Fremd-Image) | `rancher/k3s:v1.34.11-k3s1` | k3s. Wird nur gezogen, nicht gebaut. |
| `issuer-web` | – (Fremd-Image) | `nginx:alpine` | Unveränderter nginx. |

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
  ausführt (`compose.yaml:113`).
- **`entrypoint.sh`** wartet vor dem `java`-Start, bis `/oidc/tls.crt` da ist (siehe
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

## Die drei Betriebsbefehle

```bash
cp .env.example .env                 # einmalig: Konfiguration anlegen
docker compose up -d --build         # Stack bauen und starten
docker compose run --rm demo         # Ende-zu-Ende-Prüfung ausführen
docker compose down -v               # alles wieder entfernen (inkl. Volumes)
```

### `docker compose up -d --build`

- `--build` – baut die lokalen Images (`wif-lab/tools`, `wif-lab/validator`) vor dem Start neu.
- `-d` – "detached", läuft im Hintergrund.
- Startet die Kette `server → bootstrap → issuer-web → validator` (siehe
  [architecture.md](architecture.md)). `demo` startet wegen `profiles: [demo]` **nicht** mit.
- Status ansehen: `docker compose ps`; Logs: `docker compose logs -f validator`.

### `docker compose run --rm demo`

- `run` startet einen einmaligen `demo`-Container und aktiviert dessen Profil automatisch.
- `--rm` entfernt den Container nach dem Lauf.
- Führt `tools/demo.sh` aus: Discovery + JWKS anzeigen, Token prägen und dekodieren,
  Happy-Path aus dem Pod (HTTP 200), Negativfälle falsche audience / manipulierte Signatur
  (HTTP 401). Mit `DEMO_EXPIRY=1 docker compose run --rm demo` kommt ein ~10-minütiger
  Ablauf-Test dazu (die TokenRequest-API vergibt keine TTL unter 10 min).
- Details der Schritte: [validator.md](validator.md) und [../use-cases.md](../use-cases.md).

### `docker compose down -v`

- `down` stoppt und entfernt Container und das Netzwerk `wifnet`.
- **`-v` entfernt zusätzlich die Named Volumes** `k3s-data`, `kubeconfig`, `oidc-web`. Ohne
  `-v` bleiben sie liegen – dann startet der nächste `up` mit dem alten Cluster-Zustand, dem
  alten Zertifikat und den alten Metadaten. Für einen echten Neuanfang immer `-v`.

---

## Umgebungsvariablen (`.env` / `.env.example`)

`docker compose` liest `.env` im Projektverzeichnis automatisch. Vorlage: `.env.example`
(1:1 nach `.env` kopieren).

| Variable | Beispielwert | Wirkung | Verwendet in |
|---|---|---|---|
| `K3S_TOKEN` | `lab-not-a-secret-change-me` | Cluster-internes Beitrittsgeheimnis von k3s. Im Single-Node-Lab ohne echte Sicherheitsbedeutung – trotzdem **kein echtes Secret committen**. | `compose.yaml:34` |
| `K3S_IMAGE` | `rancher/k3s:v1.34.11-k3s1` | Pinnt die k3s-Version. Bei Änderung sollte `KUBECTL_VERSION` in `tools/Dockerfile` mitziehen. | `compose.yaml:20` |
| `WIF_ISSUER` | `https://issuer-web` | Sollwert des `iss`-Claims **und** Basis-URL der OIDC-Discovery im Validator. Muss aus dem Validator-Container auflösbar sein. Falscher Wert → `PKIX path building failed` (siehe [trust-und-tls.md](trust-und-tls.md)). | `compose.yaml:98`, `application.yaml:2` |
| `WIF_AUDIENCE` | `wif-demo-validator` | Audience, die der Validator verlangt und mit der die Demo Tokens prägt. Muss zum `audience` im Pod-Manifest passen (`manifests/20-consumer.yaml:47`). | `compose.yaml:99`, `compose.yaml:125` |
| `VALIDATOR_HOST_PORT` | `18080` | Host-Port, auf dem der Validator-Port 8080 zusätzlich veröffentlicht wird (für `curl` vom Host). Nur diese Zuordnung, keine Funktionsänderung. | `compose.yaml:108` |

Nicht in `.env`, aber zur Laufzeit auswertbar:

| Variable | Default | Wirkung |
|---|---|---|
| `WIF_ISSUER_CA` | `/oidc/tls.crt` | Pfad der PEM-Datei, der der Validator für TLS zu `issuer-web` vertraut. Im Compose fest gesetzt (`compose.yaml:100`), zusätzlich von `entrypoint.sh:4` gelesen. |
| `JAVA_OPTS` | – | Zusätzliche JVM-Flags, an `java` durchgereicht (`entrypoint.sh:18`). |
| `DEMO_EXPIRY` | `0` | `1` hängt an `demo.sh` den echten Ablauf-Test an (`tools/demo.sh:69`). |
| `VALIDATOR_URL` | `http://validator:8080` | Ziel-URL, die `demo.sh` direkt anspricht (`compose.yaml:126`). |

**Secrets:** Es gibt in diesem Lab keine echten Geheimnisse. `.env` steht in `.gitignore`;
committe stattdessen nur `.env.example` mit Platzhaltern.

---

## Häufige Probleme und Lösungen

### Port 6443 oder 18080 ist belegt

**Symptom:** `up` scheitert mit *"bind: address already in use"* oder *"port is already
allocated"*.

- **6443** – der API-Server-Port. Belegt z. B. durch ein lokales k3d/minikube/Rancher
  Desktop. Der `server`-Service veröffentlicht 6443 nicht auf dem Host (nur im Netz `wifnet`),
  aber manche k3s-Setups tun es. Konkurrierendes Kubernetes stoppen oder das Lab auf einer
  Maschine ohne laufendes k8s ausführen.
- **18080** – der optionale Host-Port des Validators. Lösung: in `.env`
  `VALIDATOR_HOST_PORT=<freier-port>` setzen, z. B. `28080`, dann `docker compose up -d`.
  Frei prüfen mit (Windows) `netstat -ano | findstr :18080`.

### `.env` ist veraltet nach einem Umbau

**Symptom:** Der Validator startet nicht, Log zeigt `PKIX path building failed` oder
`discovery document issuer '...' does not match configured issuer '...'`.

Eine alte `.env` kann noch `WIF_ISSUER` auf den API-Server (oder eine andere URL) zeigen.

**Lösung:**

```bash
cp .env.example .env
docker compose up -d --force-recreate validator
```

### k3s braucht `privileged`

`server` läuft mit `privileged: true` (`compose.yaml:29`). k3s startet intern selbst Container
und braucht dafür weitreichende Kernel-Rechte. Wird das entfernt oder von der
Container-Laufzeit unterbunden (gehärtete Umgebungen, manche CI-Runner, Docker "rootless"),
startet der Cluster nicht und der Healthcheck bleibt für immer `starting`. Das Lab braucht
eine Umgebung, die privilegierte Container erlaubt.

### "read-only file system", wenn man Manifeste nach `server/manifests` mountet

k3s hat ein "Auto-Deploy"-Verzeichnis unter `/var/lib/rancher/k3s/server/manifests`. Verlockend,
die Lab-Manifeste dort per Bind Mount hineinzulegen. Das schlägt fehl bzw. führt zu
*"read-only file system"*-Fehlern, weil dieser Pfad im Volume `k3s-data` liegt und von k3s
selbst verwaltet wird. Deshalb wendet dieses Lab die Manifeste **von außen** an: `bootstrap`
führt `kubectl apply -f /manifests` aus (`tools/bootstrap.sh:16`), mit `./manifests` als
read-only Bind Mount in den *Bootstrap*-Container (`compose.yaml:62`).

### `docker compose down` ohne `-v` "vergisst" den Reset

**Symptom:** Nach vermeintlichem Neuaufsetzen zeigt der Cluster alte Objekte, oder `issuer-web`
liefert ein Zertifikat, das nicht zu dem passt, was der Validator erwartet.

`down` allein lässt `k3s-data`, `kubeconfig` und `oidc-web` stehen. Der nächste `up` baut auf
diesem alten Zustand auf – inklusive des einmalig erzeugten `tls.crt` (der Guard in
`bootstrap.sh:20` erzeugt es dann nicht neu).

**Lösung:** `docker compose down -v`, dann `docker compose up -d --build`.

### Der Validator ist dauerhaft `unhealthy`

Prüf-Reihenfolge:

```bash
docker compose ps                       # welcher Service hängt?
docker compose logs bootstrap           # kam der Bootstrap sauber durch (Exit 0)?
docker compose logs issuer-web          # antwortet nginx?
docker compose logs validator           # Discovery-Fehler? PKIX? Cert fehlt?
docker compose exec validator printenv WIF_ISSUER WIF_AUDIENCE WIF_ISSUER_CA
```

Häufigste Ursachen: `WIF_ISSUER` falsch (→ [trust-und-tls.md](trust-und-tls.md)), Volume
`oidc-web` in altem Zustand (→ `down -v`), oder `start_period` zu kurz auf sehr langsamer
Hardware (die JVM braucht Zeit; der Healthcheck hat `start_period: 40s`,
`compose.yaml:117`).

### Windows-Hinweis: Zeilenenden der Skripte

Die Shell-Skripte (`bootstrap.sh`, `demo.sh`, `entrypoint.sh`) **müssen** LF-Zeilenenden und
das Executable-Bit behalten. Das ist über `.gitattributes` erzwungen. Editoren, die
CRLF erzeugen, führen zu `bad interpreter`-Fehlern im Container.

---

## Weiterlesen

- [architecture.md](architecture.md) – der Stack, Volumes, Startreihenfolge
- [validator.md](validator.md) – der Java-Service, Startablauf, Endpunkte
- [trust-und-tls.md](trust-und-tls.md) – `PKIX path building failed` im Detail
- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – was der Bootstrap-Job tut
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
- [../kubernetes-primer.md](../kubernetes-primer.md) – Kubernetes-Grundbegriffe
