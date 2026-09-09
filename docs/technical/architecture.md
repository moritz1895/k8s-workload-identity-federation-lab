# Architektur: der Docker-Compose-Stack

**Für wen / was lernst du hier:** Du kennst JWT/JWS/JWK, aber wenig Kubernetes und Docker.
Diese Seite erklärt, aus welchen Containern das Lab besteht, wer mit wem redet, in welcher
Reihenfolge alles startet und warum der Validator eine feste IP-Adresse hat. Danach verstehst
du die `compose.yaml` Zeile für Zeile.

---

## Worum es im Lab geht (in einem Absatz)

Ein Programm *innerhalb* eines Kubernetes-Clusters (der "Pod") bekommt vom Cluster ein
kurzlebiges JWT ausgestellt. Es schickt dieses Token an einen Dienst *außerhalb* des Clusters
(den "Validator"). Der Validator prüft das Token **offline**: Er lädt einmalig die öffentlichen
Signatur-Schlüssel des Ausstellers (JWKS) über HTTPS und verifiziert danach jedes Token nur
noch lokal – Signatur, `iss`, `aud`, `exp`. Er ruft den Kubernetes-API-Server nie zurück.
Das nennt man **Workload Identity Federation**.

Ein paar Begriffe vorweg:

| Begriff | Bedeutung in diesem Lab |
|---|---|
| **Kubernetes / k8s** | System, das Container ("Pods") auf einem oder mehreren Rechnern betreibt. |
| **k3s** | Eine besonders kleine, in einem einzigen Programm gebündelte Kubernetes-Distribution. Läuft hier komplett in *einem* Container. |
| **API-Server** | Die zentrale Kubernetes-Komponente, mit der man redet (`kubectl` spricht mit ihr). Stellt auch die ServiceAccount-Tokens aus. |
| **Pod** | Kleinste Ausführungseinheit in Kubernetes: ein oder mehrere Container, die zusammen laufen. |
| **ServiceAccount** | Eine Maschinen-Identität innerhalb des Clusters. Ein Pod läuft "als" ein ServiceAccount und kann sich dafür ein Token ausstellen lassen. |
| **Manifest** | YAML-Datei, die Kubernetes-Objekte beschreibt (hier: `manifests/00-namespace.yaml`, `manifests/20-consumer.yaml`). Wird mit `kubectl apply` angewendet. |
| **Namespace** | Logischer Ordner im Cluster zur Gruppierung von Objekten. Hier: `wif-demo`. |
| **OIDC-Discovery** | Konvention, unter der ein Token-Aussteller seine Metadaten unter `<issuer>/.well-known/openid-configuration` als JSON veröffentlicht – darin steht u. a. die `jwks_uri`. |
| **JWKS** | JSON Web Key Set: die Liste der öffentlichen Schlüssel, gegen die man Token-Signaturen prüft. |

---

## Die fünf Services auf einen Blick

Definiert in `compose.yaml`. "Service" = eine Container-Definition in Compose.

| Service | Image | Zweck | Läuft wie lange |
|---|---|---|---|
| `server` | `rancher/k3s:v1.34.11-k3s1` | Der komplette Kubernetes-Cluster (k3s) in einem Container. Stellt die Pod-Tokens aus. | dauerhaft |
| `bootstrap` | selbst gebaut aus `tools/` | Einmal-Job: wendet die Manifeste an, erzeugt das TLS-Zertifikat für `issuer-web`, kopiert Discovery-Dokument + JWKS aus dem Cluster heraus, endet. | einmalig, endet mit Exit-Code 0 |
| `issuer-web` | `nginx:alpine` | Statischer Webserver, der Discovery-Dokument + JWKS unter `https://issuer-web` ausliefert. Das ist die URL im `iss`-Claim jedes Tokens. | dauerhaft |
| `validator` | selbst gebaut aus `validator/` | Der Dienst *außerhalb* des Clusters. Spring Boot 4 / Java 25. Prüft die Tokens offline. | dauerhaft |
| `demo` | selbst gebaut aus `tools/` | Der Ende-zu-Ende-Test. Läuft nur auf Zuruf (`docker compose run --rm demo`). | auf Anforderung |

Der Host braucht nur **Docker + Compose v2**. Kein `kubectl`, kein `k3d`, kein Java auf dem
Host – alles steckt in den Containern.

---

## ASCII-Topologie

```
                Docker-Netzwerk  "wifnet"   (172.31.7.0/24)
  ┌───────────────────────────────────────────────────────────────────────────────┐
  │                                                                               │
  │   ┌─────────────────────────┐          ┌──────────────────────────┐            │
  │   │  server  (k3s)          │          │  issuer-web  (nginx)      │            │
  │   │  Alias: k3s-server      │          │  Alias: issuer-web        │            │
  │   │                         │          │  :443  HTTPS             ─┼──┐         │
  │   │  API-Server-Flags:      │          │  /.well-known/openid-...  │  │         │
  │   │   service-account-      │          │  /openid/v1/jwks          │  │ OIDC-   │
  │   │   issuer = https://     │          │  :80  /healthz (nur HC)   │  │ Disco + │
  │   │   issuer-web            │          └──────────▲───────────────┘  │ JWKS-   │
  │   │                         │                     │ einmalig         │ Fetch   │
  │   │  ┌───────────────────┐  │           befüllt von bootstrap        │ (HTTPS) │
  │   │  │ Pod "consumer"    │  │                                        │         │
  │   │  │ projiziertes Token│  │     ┌──────────────────────────────┐   │         │
  │   │  │ aud=wif-demo-...  │  │     │  validator  (Spring Boot)     │◄──┘         │
  │   │  │                   │──┼────►│  feste IP 172.31.7.10 : 8080  │             │
  │   │  └───────────────────┘  │ GET │  vertraut NUR issuer-webs Zert│             │
  │   │   hostAliases:          │/who │  prüft sig + iss + aud + exp  │             │
  │   │   validator.wif.local   │ ami │                              ─┼──► Host     │
  │   │     -> 172.31.7.10      │     └──────────────────────────────┘   :18080    │
  │   └─────────────────────────┘                                                  │
  │                                                                               │
  │   bootstrap (Einmal-Job)   demo (auf Anforderung)                              │
  └───────────────────────────────────────────────────────────────────────────────┘

  Named Volumes (persistenter Speicher, von Containern geteilt):
    k3s-data     server                     -> Cluster-Zustand von k3s
    kubeconfig   server (rw) -> bootstrap/demo (ro)   -> Zugangsdatei für kubectl
    oidc-web     bootstrap (rw) -> issuer-web/validator (ro) -> Zert + Disco + JWKS
```

---

## Service für Service

### `server` – der Kubernetes-Cluster

`compose.yaml:19`

- **Image:** `rancher/k3s` (über `${K3S_IMAGE}` austauschbar).
- **`privileged: true`** – der Container darf fast alles auf dem Host-Kernel. k3s startet
  intern selbst Container und braucht dafür erweiterte Rechte. Nur im Lab akzeptabel.
- **`command`** – Startflags des k3s-Servers (`compose.yaml:21`):
  - `--disable=traefik`, `--disable=servicelb`, `--disable=metrics-server` – schalten
    Cluster-Zusatzkomponenten ab, die das Lab nicht braucht (kleiner, schneller).
  - `--tls-san=k3s-server` – trägt den Namen `k3s-server` als **SAN** (Subject Alternative
    Name, siehe [trust-und-tls.md](trust-und-tls.md)) in das Serverzertifikat des API-Servers
    ein, damit `kubectl` ihn unter diesem Docker-Namen ohne Zertifikatsfehler erreicht.
  - `--kube-apiserver-arg=service-account-issuer=https://issuer-web` – **die zentrale
    Einstellung**: jeder ausgestellte Pod-Token trägt `iss=https://issuer-web`.
  - `--kube-apiserver-arg=service-account-jwks-uri=https://issuer-web/openid/v1/jwks` – Wert,
    der im Discovery-Dokument als `jwks_uri` landet.
- **`tmpfs: /run, /var/run`** – flüchtige RAM-Dateisysteme; k3s legt hier Laufzeit-Sockets ab.
- **`environment`** – `K3S_TOKEN` (Cluster-internes Beitrittsgeheimnis, im Lab kein echtes
  Secret), `K3S_KUBECONFIG_OUTPUT=/output/kubeconfig.yaml` schreibt die kubeconfig ins Volume,
  `K3S_KUBECONFIG_MODE=644` macht sie für andere Container lesbar.
- **`volumes`:** `k3s-data:/var/lib/rancher/k3s` (Cluster-Datenbank), `kubeconfig:/output`.
- **`networks`:** hängt in `wifnet` mit dem **Alias** `k3s-server`. Ein Alias ist ein
  zusätzlicher DNS-Name, unter dem andere Container den Service finden.
- **`healthcheck`** (`compose.yaml:44`): `kubectl get --raw /readyz` – Docker ruft das
  regelmäßig im Container auf; solange es fehlschlägt, gilt der Service als `starting`, dann
  als `healthy`. `depends_on … service_healthy` bei anderen Services wartet genau darauf.

### `bootstrap` – der Einmal-Job

`compose.yaml:53`

- **`build.context: ./tools`** – Image wird lokal aus `tools/Dockerfile` gebaut (Alpine +
  `kubectl` + `jq` + `openssl` + `curl` + `bash`).
- **`entrypoint: ["bash", "/work/bootstrap.sh"]`** – führt das Skript aus und endet danach.
- **`restart: "no"`** – Docker startet den Container nicht neu, wenn er endet. Er *soll* enden.
- **`volumes`:** `kubeconfig:/kube:ro` (nur lesen), `oidc-web:/oidc` (schreiben – hier legt es
  Zertifikat + Metadaten ab), `./manifests:/manifests:ro` und `./tools:/work:ro` als **Bind
  Mounts** (ein Bind Mount hängt ein Host-Verzeichnis direkt in den Container).
- **`depends_on: server → service_healthy`** – startet erst, wenn der API-Server bereit ist.
- Was das Skript tut, steht in [bootstrap-und-issuer.md](bootstrap-und-issuer.md).

### `issuer-web` – der Aussteller-Endpunkt

`compose.yaml:72`

- **Image:** `nginx:alpine` – unveränderter, offizieller nginx.
- **`volumes`:** `oidc-web:/oidc:ro` (die von `bootstrap` erzeugten Dateien), die Config
  `./tools/nginx-issuer.conf` als Bind Mount nach `/etc/nginx/conf.d/default.conf`.
- **`networks`:** Alias `issuer-web` in `wifnet`.
- **`depends_on: bootstrap → service_completed_successfully`** – startet erst, wenn der
  Bootstrap-Container **mit Exit-Code 0** geendet hat (sonst wären `/oidc/tls.crt` &
  Metadaten nicht da).
- **`healthcheck`:** `wget -q -O /dev/null http://127.0.0.1/healthz`. Bewusst `127.0.0.1`
  statt `localhost` – das busybox-`wget` im Alpine-Image versucht bei `localhost` zuerst IPv6
  (`::1`), wo nichts lauscht, und meldet einen Fehler. Mehr dazu in
  [bootstrap-und-issuer.md](bootstrap-und-issuer.md).

### `validator` – der Dienst außerhalb des Clusters

`compose.yaml:93`

- **`build.context: ./validator`** – Multi-Stage-Build, siehe
  [build-und-betrieb.md](build-und-betrieb.md).
- **`environment`:** `WIF_ISSUER` (Default `https://issuer-web`), `WIF_AUDIENCE` (Default
  `wif-demo-validator`), `WIF_ISSUER_CA=/oidc/tls.crt`.
- **`volumes`:** `oidc-web:/oidc:ro` – **nur lesend**. Der Validator liest ausschließlich
  `/oidc/tls.crt` und braucht sonst nichts aus dem Cluster.
- **`networks`:** feste IP **`172.31.7.10`** in `wifnet` (`ipv4_address`). Warum fest: siehe
  unten.
- **`ports: "${VALIDATOR_HOST_PORT:-18080}:8080"`** – der Container-Port 8080 wird zusätzlich
  auf dem Host unter Port 18080 veröffentlicht, damit man vom Host aus mit `curl` prüfen kann.
  Rein optional für das Cluster-zu-Validator-Szenario.
- **`depends_on: issuer-web → service_healthy`** – der Validator macht beim Start OIDC-
  Discovery gegen `issuer-web`; der muss also schon antworten.
- **`healthcheck`:** `curl -fsS http://localhost:8080/healthz` mit großzügigem
  `start_period: 40s` (die JVM + Spring Boot brauchen zum Hochfahren einen Moment).

### `demo` – die Ende-zu-Ende-Prüfung

`compose.yaml:120`

- Gleiches Image wie `bootstrap` (`wif-lab/tools`).
- **`profiles: ["demo"]`** – ein **Compose-Profil** ist ein Schalter: Services mit einem
  Profil starten bei `docker compose up` **nicht** automatisch mit, sondern nur, wenn man das
  Profil aktiv anfordert. Hier über `docker compose run --rm demo` (`run` aktiviert das
  Profil des genannten Service automatisch, `--rm` löscht den Container nach dem Lauf).
- **`environment`:** `WIF_AUDIENCE`, `VALIDATOR_URL=http://validator:8080` (im selben Netz
  reicht der Service-Name).
- **`depends_on: validator → service_healthy`**.
- Das Skript `tools/demo.sh` ist in [validator.md](validator.md) und
  [use-cases.md](../use-cases.md) beschrieben.

---

## Die drei Named Volumes

Ein **Named Volume** ist ein von Docker verwalteter, benannter Speicherbereich, der
unabhängig von den Containern lebt und von mehreren Containern gleichzeitig eingehängt werden
kann. Deklariert in `compose.yaml:10`.

| Volume | Beschrieben von | Gelesen von | Inhalt |
|---|---|---|---|
| `k3s-data` | `server` (rw) | – | Interne k3s-Datenbank, Cluster-Zustand. |
| `kubeconfig` | `server` (rw) | `bootstrap` (ro), `demo` (ro) | `kubeconfig.yaml` – Adresse + Zugangszertifikate für `kubectl`. |
| `oidc-web` | `bootstrap` (rw) | `issuer-web` (ro), `validator` (ro) | `tls.crt`, `tls.key`, `openid-configuration.json`, `jwks.json`. |

`oidc-web` ist der einzige Kanal, über den Vertrauensmaterial vom Cluster zum Validator
gelangt. Der Validator sieht davon nur `tls.crt` (lesend). Details in
[trust-und-tls.md](trust-und-tls.md).

> **`down -v`:** `docker compose down` allein lässt die Volumes stehen; erst `docker compose
> down -v` löscht sie. Das ist wichtig beim Zurücksetzen – siehe
> [build-und-betrieb.md](build-und-betrieb.md).

---

## Das Netzwerk `wifnet`

`compose.yaml:3`

```yaml
networks:
  wifnet:
    driver: bridge
    ipam:
      config:
        - subnet: 172.31.7.0/24
```

- **`driver: bridge`** – der Standard-Netzwerktyp von Docker: ein privates virtuelles LAN nur
  für die Container dieses Stacks. Container erreichen sich über ihre Service-Namen (Docker
  betreibt dafür einen internen DNS).
- **`ipam`** (IP Address Management) – legt fest, aus welchem Adressbereich Docker die
  Container-IPs vergibt. Hier `172.31.7.0/24`, also `172.31.7.1`–`172.31.7.254`.
- Der Validator bekommt daraus die **fest zugewiesene** Adresse `172.31.7.10`
  (`compose.yaml:105`).

### Warum hat der Validator eine feste IP – und warum braucht der Pod `hostAliases`?

Der Validator läuft **außerhalb** des Clusters. Der cluster-interne DNS (CoreDNS) kennt nur
Dinge *im* Cluster – von einem Container im Docker-Netz weiß er nichts. Der Pod kann
`validator` also nicht per Name auflösen.

Lösung im Pod-Manifest (`manifests/20-consumer.yaml:28`):

```yaml
hostAliases:
  - ip: "172.31.7.10"
    hostnames:
      - validator.wif.local
```

`hostAliases` schreibt statische Zeilen in die `/etc/hosts` **jedes Containers im Pod**. Der
Pod ruft dann `http://validator.wif.local:8080/whoami` auf, und `/etc/hosts` löst diesen Namen
fest zu `172.31.7.10` auf – ganz ohne DNS.

Damit dieser Eintrag stimmt, **muss** der Validator immer dieselbe IP haben. Würde Docker sie
dynamisch vergeben, wäre der `hostAliases`-Eintrag beim nächsten Start womöglich falsch.
Deshalb die feste `ipv4_address` im Compose-File. Der Name `validator.wif.local` ist frei
gewählt (`.wif.local` ist eine reine Phantasie-Domain fürs Lab).

---

## Startreihenfolge

`depends_on` mit `condition` verkettet die Services zu einer festen Kette. Compose startet
nichts, bevor die Bedingung des Vorgängers erfüllt ist:

```
1. server       wird gestartet
   └─ healthcheck  kubectl get --raw /readyz  ->  healthy
2. bootstrap    startet (depends_on server: service_healthy)
   ├─ wendet manifests/ an, wartet auf Deployment "consumer"
   ├─ erzeugt /oidc/tls.crt + tls.key
   ├─ kopiert openid-configuration.json + jwks.json ins Volume
   └─ endet mit Exit 0        ->  completed successfully
3. issuer-web   startet (depends_on bootstrap: service_completed_successfully)
   └─ healthcheck  wget http://127.0.0.1/healthz  ->  healthy
4. validator    startet (depends_on issuer-web: service_healthy)
   ├─ entrypoint.sh wartet auf /oidc/tls.crt
   ├─ OIDC-Discovery gegen https://issuer-web
   ├─ baut gecachten JWKSource
   └─ healthcheck  curl http://localhost:8080/healthz  ->  healthy
5. demo         (nur bei "docker compose run --rm demo",
                 depends_on validator: service_healthy)
```

`bootstrap` läuft bei **jedem** `up` erneut. Das Skript ist idempotent: Das Zertifikat wird
nur erzeugt, wenn `/oidc/tls.crt` noch fehlt (`tools/bootstrap.sh:20`), die Metadaten werden
jedes Mal frisch aus dem Cluster kopiert.

---

## Weiterlesen

- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – was `bootstrap.sh` und die nginx-Config
  im Detail machen
- [validator.md](validator.md) – der Java-Service innen
- [trust-und-tls.md](trust-und-tls.md) – die TLS-Vertrauensbeziehungen
- [build-und-betrieb.md](build-und-betrieb.md) – Images bauen, betreiben, Fehler beheben
- [../kubernetes-primer.md](../kubernetes-primer.md) – Kubernetes-Grundbegriffe
- [../domain.md](../domain.md) – das fachliche Modell
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
