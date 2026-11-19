# Architektur: der Docker-Compose-Stack

**Für wen / was lernst du hier:** Du kennst JWT/JWS/JWK, aber wenig Kubernetes und Docker.
Diese Seite erklärt, aus welchen Containern das Lab besteht, in welchen Netzen sie hängen,
wer mit wem redet, welche Volumes es gibt, in welcher Reihenfolge alles startet und warum
Validator und `issuer-web` feste IP-Adressen haben. Danach verstehst du die `compose.yaml`
Zeile für Zeile. Die Entscheidung hinter dem Aufbau steht in
[ADR 0003](../adr/0003-getrennte-vertrauensbereiche-interne-pki.md).

---

## Worum es im Lab geht (in einem Absatz)

Ein Programm *innerhalb* eines Kubernetes-Clusters (der "Pod") bekommt vom Cluster ein
kurzlebiges JWT ausgestellt. Es schickt dieses Token an einen Dienst *außerhalb* des Clusters
(den "Validator"). Der Validator prüft das Token **offline**: Er lädt die öffentlichen
Signatur-Schlüssel des Ausstellers (JWKS) über HTTPS vom Issuer-Endpoint `issuer-web` und
verifiziert danach jedes Token lokal – Signatur, `iss`, `aud`, `exp`. Er ruft den
Kubernetes-API-Server nie zurück. Die Schlüssel bringt ein Publisher im Cluster per mTLS zu
`issuer-web`. Das Ganze nennt man **Workload Identity Federation**.

Ein paar Begriffe vorweg:

| Begriff | Bedeutung in diesem Lab |
|---|---|
| **Kubernetes / k8s** | System, das Container ("Pods") auf einem oder mehreren Rechnern betreibt. |
| **k3s** | Eine besonders kleine, in einem einzigen Programm gebündelte Kubernetes-Distribution. Läuft hier komplett in *einem* Container. |
| **API-Server** | Die zentrale Kubernetes-Komponente, mit der man redet (`kubectl` spricht mit ihr). Stellt auch die ServiceAccount-Tokens aus. |
| **Pod** | Kleinste Ausführungseinheit in Kubernetes: ein oder mehrere Container, die zusammen laufen. |
| **ServiceAccount** | Eine Maschinen-Identität innerhalb des Clusters. Ein Pod läuft "als" ein ServiceAccount und kann sich dafür ein Token ausstellen lassen. |
| **Manifest** | YAML-Datei, die Kubernetes-Objekte beschreibt (hier: `manifests/00-namespace.yaml`, `manifests/10-publisher.yaml`, `manifests/20-consumer.yaml`, `manifests/30-authz-workloads.yaml`). Wird mit `kubectl apply` angewendet. |
| **Namespace** | Logischer Ordner im Cluster zur Gruppierung von Objekten. Hier: `wif-demo` und `wif-publisher`. |
| **OIDC-Discovery** | Konvention, unter der ein Token-Aussteller seine Metadaten unter `<issuer>/.well-known/openid-configuration` als JSON veröffentlicht – darin steht u. a. die `jwks_uri`. |
| **JWKS** | JSON Web Key Set: die Liste der öffentlichen Schlüssel, gegen die man Token-Signaturen prüft. |
| **mTLS** | TLS, bei dem sich auch der Client mit einem Zertifikat ausweist. |

---

## Die Services auf einen Blick

Definiert in `compose.yaml`. "Service" = eine Container-Definition in Compose.

| Service | Image | Zweck | Läuft wie lange |
|---|---|---|---|
| `pki-init` | `wif-lab/tools` (aus `tools/`) | Lab-PKI: Root-CA, Serverzertifikate für `issuer-web`, `keycloak` und `service-r`, Client-Zertifikat für den Publisher, Material für Negativtests. Ohne Netz (`network_mode: none`). | einmalig |
| `sa-keys` | `wif-lab/tools` | Signaturschlüssel des Clusters anlegen (`init`) oder rotieren (`rotate`). Ohne Netz. | einmalig / auf Anforderung |
| `server` | `rancher/k3s:v1.34.11-k3s1` | Der komplette Kubernetes-Cluster (k3s). Stellt die Pod-Tokens aus. Im Cluster laufen `jwks-publisher`, `consumer`, `reader` und `stranger`. | dauerhaft |
| `bootstrap` | `wif-lab/tools` | Einmal-Job mit Admin-Kubeconfig: Namespaces, Secret für den Publisher, ConfigMap `internal-ca` in `wif-publisher` und `wif-demo`, Manifeste anwenden. Veröffentlicht nichts. | einmalig, Exit 0 |
| `issuer-web` | `nginx:1.29-alpine` | Issuer-Endpoint: `:443` liefert Discovery-Dokument + JWKS aus, `:8443` nimmt Uploads des Publishers per mTLS an. | dauerhaft |
| `validator` | `wif-lab/validator` (aus `validator/`) | Der Dienst *außerhalb* des Clusters. Spring Boot 4 / Java 25. Prüft die Tokens offline. | dauerhaft |
| `validator-foreign-ca` | `wif-lab/validator` | Negativtest: Validator mit fremder CA, muss beim Start scheitern. Profil `negative`. | auf Anforderung |
| `keycloak` | `quay.io/keycloak/keycloak:26.8.2` | Autorisierungsserver des Fachbereichs (Realm `domain-rst`): tauscht ServiceAccount-Tokens gegen Access-Tokens. Siehe [autorisierungsserver.md](autorisierungsserver.md). | dauerhaft |
| `keycloak-gateway` | `nginx:1.29-alpine` | Einziger Weg der Pods zu Keycloak; leitet nur `/realms/domain-rst/` weiter. | dauerhaft |
| `keycloak-admin` | `nginx:1.29-alpine` | Admin-Konsole vom Host (`127.0.0.1:18443`). Profil `admin`. | auf Anforderung |
| `service-r` | `wif-lab/service-r` (aus `service-r/`) | Dienst R: Spring-Security-Resource-Server, prüft Access-Tokens und Scopes. | dauerhaft |
| `demo` | `wif-lab/tools` | Der Ende-zu-Ende-Test (`all`, `authz`, `pre-rotation`, `post-rotation`). Profil `demo`. | auf Anforderung |

Der Host braucht nur **Docker + Compose v2**. Kein `kubectl`, kein `k3d`, kein Java auf dem
Host – alles steckt in den Containern.

---

## ASCII-Topologie

```
      cluster-net 172.31.7.0/24                          relying-net 172.31.8.0/24
 ┌───────────────────────────────┐                     ┌───────────────────────────────┐
 │ server  .2  (Alias k3s-server)│   ┌─────────────┐   │                               │
 │  API-Server nur auf .2:6443   │   │ issuer-web  │   │ validator  .10                │
 │  Pod jwks-publisher ──────────┼──►│ .7.20:8443  │   │  GET Discovery + JWKS ───┐    │
 │    PUT, mTLS                  │   │   Upload    │   │                          │    │
 │                               │   │ .8.20:443 ◄─┼───┼──────────────────────────┘    │
 │ bootstrap, demo               │   │   Lesen     │   │ demo, validator-foreign-ca    │
 └───────────────┬───────────────┘   └─────────────┘   └──────────────▲────────────────┘
                 │ server .2                                          │ validator .10 :8080
                 │                workload-net 172.31.9.0/24          │ (Host :18080)
                 └──── Pod consumer: GET /whoami, Bearer-Token ───────┘

 pki-init, sa-keys: ohne Netz (network_mode: none)
```

Autorisierungs-Pfad (Details in [autorisierungsserver.md](autorisierungsserver.md)):

```
 workload-net                               relying-net
 Pods ── HTTPS keycloak:8443 ──► keycloak-gateway .9.30 │ .8.31 ──► keycloak .8.30:8443 ──► issuer-web .8.20:443
      │                          nur /realms/domain-rst/                ▲
      └── HTTPS :8443 ─────────► service-r .9.40 │ .8.40 ───────────────┘ Discovery + JWKS
                                                     keycloak-admin .8.32 (Profil admin, Host 127.0.0.1:18443)
```

`issuer-web` ist das einzige Bauteil, das in beiden Bereichen hängt: Der Upload-Listener
`:8443` bindet nur an `172.31.7.20` (Cluster-Seite), der Lese-Listener `:443` an alle
Adressen. Der Validator hängt nur in `relying-net` und `workload-net` und erreicht damit
weder den API-Server noch den Upload-Listener.

---

## Service für Service

### `pki-init` – die Lab-PKI

- **`entrypoint: ["bash", "/work/pki-init.sh"]`**, `restart: "no"`, **`network_mode: none`**.
- **`volumes`:** `pki-ca` (CA-Schlüssel, nur hier eingehängt), `ca-trust` (Root-Zertifikat),
  `issuer-tls`, `keycloak-tls`, `service-r-tls`, `publisher-tls`, `pki-demo`.
- Was das Skript tut: [bootstrap-und-issuer.md](bootstrap-und-issuer.md#toolspki-initsh--die-lab-pki).

### `sa-keys` – die Signaturschlüssel

- **`entrypoint: ["bash", "/work/sa-keys.sh"]`**, `command: ["init"]`, ohne Netz.
- **`volumes`:** `sa-keys:/sa-keys` (rw).
- `docker compose run --rm sa-keys rotate` rotiert den Schlüssel; danach muss `server` neu
  starten. Details: [bootstrap-und-issuer.md](bootstrap-und-issuer.md#toolssa-keyssh--signaturschlüssel-und-rotation).

### `server` – der Kubernetes-Cluster

- **Image:** `rancher/k3s` (über `${K3S_IMAGE}` austauschbar).
- **`privileged: true`** – k3s startet intern selbst Container und braucht dafür erweiterte
  Rechte. Nur im Lab akzeptabel.
- **`command`** – Startflags des k3s-Servers:
  - `--disable=traefik`, `--disable=servicelb`, `--disable=metrics-server` – schalten
    Cluster-Zusatzkomponenten ab, die das Lab nicht braucht.
  - `--tls-san=k3s-server` – trägt den Namen `k3s-server` als **SAN** (Subject Alternative
    Name, siehe [trust-und-tls.md](trust-und-tls.md)) in das Serverzertifikat des API-Servers
    ein, damit `kubectl` ihn unter diesem Namen erreicht.
  - `--node-ip`, `--advertise-address`, `--bind-address` = `172.31.7.2` – der API-Server
    lauscht nur auf seiner Adresse in `cluster-net`.
  - `service-account-issuer=https://issuer-web` – **die zentrale Einstellung**: jeder
    ausgestellte Pod-Token trägt `iss=https://issuer-web`.
  - `service-account-jwks-uri=https://issuer-web/openid/v1/jwks` – Wert, der im
    Discovery-Dokument als `jwks_uri` landet.
  - `service-account-signing-key-file=/sa-keys/signing.key`,
    `service-account-key-file=/sa-keys/verify.pub` – eigene Schlüsseldateien aus `sa-keys`.
- **`tmpfs: /run, /var/run`** – flüchtige RAM-Dateisysteme für Laufzeit-Sockets.
- **`environment`** – `K3S_TOKEN` (Beitrittsgeheimnis, im Lab kein echtes Secret),
  `K3S_KUBECONFIG_OUTPUT=/output/kubeconfig.yaml`, `K3S_KUBECONFIG_MODE=644`.
- **`volumes`:** `k3s-data` (Cluster-Datenbank), `kubeconfig:/output`, `sa-keys:/sa-keys:ro`.
- **`networks`:** `cluster-net` mit fester IP `172.31.7.2` und **Alias** `k3s-server`,
  `workload-net` mit `172.31.9.2`. Über `workload-net` erreichen Pods den Validator; der
  API-Server lauscht dort nicht.
- **`depends_on: sa-keys → service_completed_successfully`**.
- **`healthcheck`:** `kubectl get --raw /readyz`.

### `bootstrap` – der Einmal-Job

- **`entrypoint: ["bash", "/work/bootstrap.sh"]`**, `restart: "no"`.
- **`volumes`:** `kubeconfig:/kube:ro`, `ca-trust:/trust:ro`,
  `publisher-tls:/publisher-tls:ro`, `./manifests:/manifests:ro`, `./tools:/work:ro`.
- **`networks`:** nur `cluster-net`.
- **`depends_on`:** `server → service_healthy`, `pki-init → service_completed_successfully`.
- Was das Skript tut: [bootstrap-und-issuer.md](bootstrap-und-issuer.md).

### `issuer-web` – der Issuer-Endpoint

- **Image:** `nginx:1.29-alpine` (über `${NGINX_IMAGE}` austauschbar).
- **`entrypoint`:** legt `/oidc/.tmp` an, übergibt `/oidc` an den Benutzer `nginx` (damit
  `PUT` schreiben darf) und startet nginx.
- **`volumes`:** `oidc-web:/oidc` (die hochgeladenen Dokumente, rw), `issuer-tls:/tls:ro`
  (Serverzertifikat), `ca-trust:/trust:ro` (zum Prüfen der Client-Zertifikate), die Config
  `./tools/nginx-issuer.conf`.
- **`networks`:** `cluster-net` mit `172.31.7.20`, `relying-net` mit `172.31.8.20` und Alias
  `issuer-web`.
- **`depends_on: pki-init → service_completed_successfully`**.
- **`healthcheck`:** `test -s /oidc/openid/v1/jwks` – gesund, sobald der Publisher das erste
  JWKS hochgeladen hat (`retries: 60`, alle 5 s).

### `validator` – der Dienst außerhalb des Clusters

- **`build.context: ./validator`** – Multi-Stage-Build, siehe
  [build-und-betrieb.md](build-und-betrieb.md).
- **`environment`:** `WIF_ISSUER` (Default `https://issuer-web`), `WIF_AUDIENCE` (Default
  `wif-demo-validator`), `WIF_ISSUER_CA=/trust/ca.crt`.
- **`volumes`:** nur `ca-trust:/trust:ro` – das Root-Zertifikat der internen CA. Kein Volume
  der Cluster-Seite.
- **`networks`:** `relying-net` mit `172.31.8.10`, `workload-net` mit `172.31.9.10`.
- **`ports: "${VALIDATOR_HOST_PORT:-18080}:8080"`** – zusätzlich auf dem Host veröffentlicht,
  damit man vom Host aus mit `curl` prüfen kann.
- **`depends_on: issuer-web → service_healthy`**.
- **`healthcheck`:** `curl -fsS http://localhost:8080/healthz`, `start_period: 40s`.

### `validator-foreign-ca` – der Negativtest

- Gleiches Image wie `validator`, aber `WIF_ISSUER_CA=/pki-demo/foreign-ca.crt` aus dem
  Volume `pki-demo`, nur in `relying-net`, Profil `negative`.
- `docker compose run --rm validator-foreign-ca` muss mit einem Fehlercode enden
  (`PKIX path building failed`).

### `keycloak` – der Autorisierungsserver

- **`command: ["start", "--import-realm"]`**, HTTPS nur auf 8443, Health auf Port 9000;
  `mem_limit: 1g`.
- **`networks`:** nur `relying-net` mit `172.31.8.30` und Alias `keycloak`. **Kein**
  veröffentlichter Port: Docker macht einen veröffentlichten Container-Port auch aus den
  anderen Bridge-Netzen erreichbar, unabhängig von der Host-Adresse (im Lab gemessen).
- **`volumes`:** `keycloak-tls:/tls:ro`, `ca-trust:/trust:ro`,
  `./keycloak/realm-domain-rst.json` (Realm-Import, ro).
- **`depends_on`:** `pki-init → service_completed_successfully`, `issuer-web → service_healthy`.
- **`healthcheck`:** `GET /health/ready` auf `localhost:9000` per Bash-`/dev/tcp` (kein `curl`
  im Image).
- Konfiguration im Detail: [autorisierungsserver.md](autorisierungsserver.md#keycloak).

### `keycloak-gateway` – der Weg der Workloads zu Keycloak

- nginx mit `tools/nginx-keycloak-gateway.conf`; `volumes`: `keycloak-tls:/tls:ro`,
  `ca-trust:/trust:ro`; `mem_limit: 64m`.
- **`networks`:** `relying-net` mit `172.31.8.31`, `workload-net` mit `172.31.9.30`.
- TLS auf 8443 mit dem Keycloak-Zertifikat; leitet nur `GET`/`POST` unter
  `/realms/domain-rst/` weiter, sonst `404`.
- **`depends_on: keycloak → service_healthy`**; **`healthcheck`:** `nc -z 127.0.0.1 8443`.

### `keycloak-admin` – Admin-Konsole auf Zuruf

- nginx mit `tools/nginx-keycloak-admin.conf`, Profil `admin`; nur `relying-net`
  (`172.31.8.32`); **`ports: "127.0.0.1:${KEYCLOAK_HOST_PORT:-18443}:8443"`**; `mem_limit: 64m`.
- `docker compose --profile admin up -d keycloak-admin`, danach
  `docker compose stop keycloak-admin`. Solange er läuft, ist sein Port auch aus
  `workload-net` erreichbar.

### `service-r` – Dienst R

- **`build.context: ./service-r`**; `environment`: `KC_REALM_ISSUER`, `SERVICE_R_AUDIENCE`,
  `SERVICE_R_TRUST_CA=/trust/ca.crt`, `SERVICE_R_TLS_DIR=/tls`; `volumes`: `ca-trust:/trust:ro`,
  `service-r-tls:/tls:ro`; `mem_limit: 384m`; läuft als `USER 10001`.
- **`networks`:** `relying-net` mit `172.31.8.40`, `workload-net` mit `172.31.9.40`;
  **`ports: "127.0.0.1:${SERVICE_R_HOST_PORT:-18081}:8443"`** – nur HTTPS (Port 8443), kein
  HTTP-Listener.
- **`depends_on: pki-init → service_completed_successfully`** (Serverzertifikat). Kein
  `depends_on` auf Keycloak: Die Realm-Discovery läuft erst beim ersten Token, R startet
  unabhängig von Keycloak.
- **`healthcheck`:** `curl -fsS --cacert /trust/ca.crt https://localhost:8443/healthz`.
- Details: [autorisierungsserver.md](autorisierungsserver.md#service-r--der-resource-server).

### `demo` – die Ende-zu-Ende-Prüfung

- Gleiches Image wie `bootstrap` (`wif-lab/tools`), Profil `demo`.
- **`command: ["all"]`** – Phase; außerdem `authz`, `pre-rotation` und `post-rotation`.
- **`environment`:** `WIF_AUDIENCE`, `VALIDATOR_URL=http://validator:8080`, `KC_REALM_ISSUER`.
- **`volumes`:** `kubeconfig:/kube:ro`, `ca-trust:/trust:ro`, `pki-demo:/pki-demo:ro`
  (Negativtest-Zertifikate), `demo-state:/state` (Token und `kid`s zwischen den
  Rotationsphasen).
- **`networks`:** `cluster-net` (für `kubectl` und den Upload-Listener) und `relying-net`
  (für `issuer-web :443` und den Validator).
- **`depends_on`:** `validator`, `service-r` und `keycloak-gateway` → `service_healthy`.
- Die Schritte: [../use-cases.md](../use-cases.md#verifikation-auf-einen-blick).

---

## Die Named Volumes

Ein **Named Volume** ist ein von Docker verwalteter, benannter Speicherbereich, der
unabhängig von den Containern lebt. Deklariert in `compose.yaml`. Jedes Stück
Vertrauensmaterial liegt in einem eigenen Volume, damit jeder Container nur sieht, was er
braucht.

| Volume | Beschrieben von | Gelesen von | Inhalt |
|---|---|---|---|
| `pki-ca` | `pki-init` | – | Root-CA: `ca.crt`, `ca.key`. |
| `ca-trust` | `pki-init` | `issuer-web`, `bootstrap`, `validator`, `keycloak`, `keycloak-gateway`, `keycloak-admin`, `service-r`, `demo` | `ca.crt` – Stellvertreter für die anderweitige Verteilung des Root-Zertifikats. |
| `issuer-tls` | `pki-init` | `issuer-web` | Serverzertifikat `tls.crt` / `tls.key` (SAN `DNS:issuer-web`). |
| `publisher-tls` | `pki-init` | `bootstrap` (→ Secret) | Client-Zertifikat `tls.crt` / `tls.key` (`CN=jwks-publisher`). |
| `pki-demo` | `pki-init` | `demo`, `validator-foreign-ca` | `wrong-cn.*`, `foreign-ca.crt`, `foreign-publisher.*`. |
| `keycloak-tls` | `pki-init` | `keycloak`, `keycloak-gateway`, `keycloak-admin` | Serverzertifikat `tls.crt` / `tls.key` (SAN `DNS:keycloak`, `DNS:localhost`, `IP:127.0.0.1`), Schlüssel gehört uid 1000. |
| `service-r-tls` | `pki-init` | `service-r` | Serverzertifikat `tls.crt` / `tls.key` (`CN=service-r.wif.local`, SAN `DNS:service-r.wif.local`, `DNS:service-r`, `DNS:localhost`, `IP:127.0.0.1`), Schlüssel gehört uid 10001 (Modus 400). |
| `sa-keys` | `sa-keys` | `server` (ro) | `signing.key`, `current.pub`, `previous.pub`, `verify.pub`. |
| `k3s-data` | `server` | – | Interne k3s-Datenbank, Cluster-Zustand. |
| `kubeconfig` | `server` | `bootstrap`, `demo` | `kubeconfig.yaml` – Adresse + Admin-Zugang für `kubectl`. |
| `oidc-web` | `issuer-web` (per `PUT`) | `issuer-web` | `.well-known/openid-configuration`, `openid/v1/jwks` – unter ihrem URL-Pfad abgelegt. |
| `demo-state` | `demo` | `demo` | Token und `kid`s von vor der Rotation. |

Zwischen Cluster-Seite und Validator gibt es **kein** gemeinsames Volume. Die Daten
(Discovery-Dokument, JWKS) erreichen den Validator nur über HTTPS von `issuer-web`, der
Vertrauensanker (`ca.crt`) über `ca-trust`.

> **`down -v`:** `docker compose down` allein lässt die Volumes stehen; erst `docker compose
> down -v` löscht sie. Siehe [build-und-betrieb.md](build-und-betrieb.md).

---

## Die drei Netze

| Netz | Subnetz | Mitglieder | Zweck |
|---|---|---|---|
| `cluster-net` | `172.31.7.0/24` | `server` (.2, Alias `k3s-server`), `issuer-web` (.20), `bootstrap`, `demo` | Der Cluster und sein einziger Weg nach außen: der Upload-Listener. |
| `relying-net` | `172.31.8.0/24` | `issuer-web` (.20, Alias `issuer-web`), `validator` (.10), `keycloak` (.30, Alias `keycloak`), `keycloak-gateway` (.31), `keycloak-admin` (.32), `service-r` (.40), `demo`, `validator-foreign-ca` | Öffentlicher Lese-Listener, Relying Parties und Autorisierungsserver. |
| `workload-net` | `172.31.9.0/24` | `server` (.2), `validator` (.10), `keycloak-gateway` (.30), `service-r` (.40) | Pods rufen Validator, Keycloak (über das Gateway) und `service-r` auf. |

- **`driver: bridge`** – der Standard-Netzwerktyp von Docker: ein privates virtuelles LAN.
  Container im selben Netz erreichen sich über Service-Namen und Aliase.
- **`ipam`** legt das Subnetz fest; feste Adressen kommen über `ipv4_address`.
- Pod-Verkehr verlässt den k3s-Container mit dessen Adresse im jeweiligen Netz. Ein Pod
  erreicht deshalb den Validator über `workload-net` und `issuer-web` über `cluster-net`.

Keycloak selbst hängt nicht in `workload-net`. Weil Docker veröffentlichte Ports auch aus
anderen Bridge-Netzen erreichbar macht, veröffentlicht er keinen Port; nicht veröffentlichte
Ports wie `issuer-web :443` oder Keycloak `:9000` bleiben auf ihre Netze beschränkt.

`tools/run-all-checks.sh` prüft die Trennung von Validator und `service-r` aus
(`172.31.9.2:6443`, `172.31.7.2:6443`, `172.31.8.20:8443` nicht erreichbar) und von Keycloak
aus (zusätzlich `172.31.7.20:8443`). `demo.sh authz` (Prüfung 20) prüft aus einem Pod, dass
Keycloak nur über das Gateway und nur mit dem Realm `domain-rst` erreichbar ist.

### Warum feste IPs – und warum brauchen die Pods `hostAliases`?

Validator und `issuer-web` laufen **außerhalb** des Clusters. Der cluster-interne DNS
(CoreDNS) kennt nur Dinge *im* Cluster. Die Pods lösen die Namen deshalb über `hostAliases`
auf, die statische Zeilen in `/etc/hosts` schreiben:

| Pod | Name | IP |
|---|---|---|
| `consumer` (`manifests/20-consumer.yaml`) | `validator.wif.local` | `172.31.9.10` (Validator in `workload-net`) |
| `consumer`, `reader`, `stranger` | `keycloak` | `172.31.9.30` (`keycloak-gateway` in `workload-net`) |
| `consumer`, `reader` | `service-r.wif.local` | `172.31.9.40` (`service-r` in `workload-net`) |
| `jwks-publisher` (`manifests/10-publisher.yaml:116`) | `issuer-web` | `172.31.7.20` (`issuer-web` in `cluster-net`) |

Damit diese Einträge stimmen, **müssen** die Adressen fest sein. `172.31.7.20` steht
außerdem in `tools/nginx-issuer.conf` als Bind-Adresse des Upload-Listeners und in
`tools/demo.sh` (`UPLOAD_ADDR`). Der Name `validator.wif.local` ist frei gewählt.

---

## Startreihenfolge

`depends_on` mit `condition` verkettet die Services. Compose startet nichts, bevor die
Bedingung des Vorgängers erfüllt ist:

```
pki-init     ─┬─ completed ──────────────────────────────┐
sa-keys      ─┼─ completed                                │
              ▼                                           ▼
server       healthy (kubectl get --raw /readyz)     issuer-web  startet, liefert noch nichts
              │                                           │
              ▼   (+ pki-init completed)                  │
bootstrap    Namespaces, Secret, ConfigMaps, Manifeste,   │
             Rollouts jwks-publisher, consumer,           │
             reader, stranger, Exit 0                     │
              │                                           │
              ▼                                           │
jwks-publisher (Pod) ── PUT mTLS ────────────────────────►│ healthy (JWKS-Datei vorhanden)
                                                          ▼
validator    entrypoint.sh wartet auf /trust/ca.crt, OIDC-Discovery, JWKSource
             healthy (curl /healthz)
keycloak     Realm-Import, healthy (/health/ready auf :9000)
              ▼
keycloak-gateway  healthy (nc -z 127.0.0.1 8443)

service-r    nach pki-init: entrypoint.sh baut Truststore, healthy (curl --cacert … https://localhost:8443/healthz)

demo         nur bei "docker compose run --rm demo" (wartet auf validator, service-r, keycloak-gateway)
```

`validator` und `keycloak` hängen beide nur an `issuer-web` und starten parallel;
`service-r` wartet nur auf `pki-init`. `demo` wartet über `keycloak-gateway` indirekt auf Keycloaks Healthcheck;
da `/health/ready` schon vor dem Abschluss des ersten Bootstraps UP meldet, wiederholt Prüfung 8
die Realm-Discovery bis zu 60 s.

`pki-init`, `sa-keys` und `bootstrap` laufen bei **jedem** `up` erneut und sind idempotent:
Vorhandene CA, Zertifikate und Signaturschlüssel bleiben erhalten.

---

## Weiterlesen

- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – PKI, Signaturschlüssel, Bootstrap,
  Publisher und nginx-Config im Detail
- [validator.md](validator.md) – der Java-Service innen
- [autorisierungsserver.md](autorisierungsserver.md) – Keycloak, Realm und `service-r`
- [trust-und-tls.md](trust-und-tls.md) – die TLS-Vertrauensbeziehungen
- [build-und-betrieb.md](build-und-betrieb.md) – Images bauen, betreiben, Fehler beheben
- [../kubernetes-primer.md](../kubernetes-primer.md) – Kubernetes-Grundbegriffe
- [../domain.md](../domain.md) – das fachliche Modell
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
