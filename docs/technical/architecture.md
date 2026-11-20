# Architektur: der Docker-Compose-Stack

**Für wen / was lernst du hier:** Du kennst JWT/JWS/JWK, aber wenig Kubernetes und Docker.
Diese Seite erklärt, aus welchen Containern das Lab besteht, in welchen Netzen sie hängen,
wer mit wem redet, welche Volumes es gibt, in welcher Reihenfolge alles startet und warum
einige Container feste IP-Adressen haben. Danach verstehst du die `compose.yaml` Zeile für
Zeile. Die Entscheidungen hinter dem Aufbau stehen in
[ADR 0003](../adr/0003-getrennte-vertrauensbereiche-interne-pki.md) (interne PKI, getrennte
Netze), [ADR 0005](../adr/0005-discovery-pod-im-cluster-pull-ueber-ingress.md) (Discovery-Pod)
und [ADR 0006](../adr/0006-gateway-api-statt-ingress.md) (Gateway API).

---

## Worum es im Lab geht (in einem Absatz)

Ein Programm *innerhalb* eines Kubernetes-Clusters (der "Pod") bekommt vom Cluster ein
kurzlebiges JWT ausgestellt. Es schickt dieses Token an einen Dienst *außerhalb* des Clusters
(den "Validator"). Der Validator prüft das Token **offline**: Er lädt die öffentlichen
Signatur-Schlüssel des Ausstellers (JWKS) über HTTPS von `https://issuer.wif.local` und
verifiziert danach jedes Token lokal – Signatur, `iss`, `aud`, `exp`. Er ruft den
Kubernetes-API-Server nie zurück. Aussteller ist der API-Server; unter seiner Issuer-URL `https://issuer.wif.local` liefert
ein Pod im Cluster (der Discovery-Pod `issuer-discovery`) eine Kopie von Discovery-Dokument
und JWKS über ein Gateway der Gateway API aus.
Das Ganze nennt man **Workload Identity Federation**.

Ein paar Begriffe vorweg:

| Begriff | Bedeutung in diesem Lab |
|---|---|
| **Kubernetes / k8s** | System, das Container ("Pods") auf einem oder mehreren Rechnern betreibt. |
| **k3s** | Eine besonders kleine, in einem einzigen Programm gebündelte Kubernetes-Distribution. Läuft hier komplett in *einem* Container. |
| **API-Server** | Die zentrale Kubernetes-Komponente, mit der man redet (`kubectl` spricht mit ihr). Stellt auch die ServiceAccount-Tokens aus. |
| **Pod** | Kleinste Ausführungseinheit in Kubernetes: ein oder mehrere Container, die zusammen laufen. |
| **ServiceAccount** | Eine Maschinen-Identität innerhalb des Clusters. Ein Pod läuft "als" ein ServiceAccount und kann sich dafür ein Token ausstellen lassen. |
| **Manifest** | YAML-Datei, die Kubernetes-Objekte beschreibt (hier: `manifests/00-namespace.yaml`, `01-traefik-config.yaml`, `05-issuer-discovery-admission.yaml`, `10-issuer-discovery.yaml`, `20-consumer.yaml`, `30-authz-workloads.yaml`). Wird mit `kubectl apply` angewendet. |
| **Namespace** | Logischer Ordner im Cluster zur Gruppierung von Objekten. Hier: `wif-demo` und `wif-issuer-discovery`. |
| **Gateway API** | Kubernetes-API für Routen von außen in den Cluster: Ein **Gateway** legt Listener fest (Port, Hostname, Zertifikat, wer Routen anhängen darf), eine **HTTPRoute** führt Host und Pfad zu einem Service. Umgesetzt vom Gateway-Controller, hier dem in k3s mitgelieferten Traefik. Nicht zu verwechseln mit `keycloak-gateway`, einem nginx-Proxy vor Keycloak. |
| **OIDC-Discovery** | Konvention, unter der ein Token-Aussteller seine Metadaten unter `<issuer>/.well-known/openid-configuration` als JSON veröffentlicht – darin steht u. a. die `jwks_uri`. |
| **JWKS** | JSON Web Key Set: die Liste der öffentlichen Schlüssel, gegen die man Token-Signaturen prüft. |

---

## Die Services auf einen Blick

Definiert in `compose.yaml`. "Service" = eine Container-Definition in Compose.

| Service | Image | Zweck | Läuft wie lange |
|---|---|---|---|
| `pki-init` | `wif-lab/tools` (aus `tools/`) | Lab-PKI: Root-CA, Serverzertifikate für das Issuer-Gateway (`issuer.wif.local`), `keycloak`, `validator` und `service-r`, fremde CA für den Negativtest. Ohne Netz (`network_mode: none`). | einmalig |
| `sa-keys` | `wif-lab/tools` | Signaturschlüssel des Clusters anlegen (`init`), in zwei Phasen wechseln (`stage`, `activate`) oder im Notfall den vorherigen entfernen (`retire`). Ohne Netz. | einmalig / auf Anforderung |
| `server` | `rancher/k3s:v1.34.11-k3s1` | Der komplette Kubernetes-Cluster (k3s) mit Traefik als Gateway-Controller. Stellt die Pod-Tokens aus. Im Cluster laufen `issuer-discovery` (Discovery-Pod), `consumer`, `reader` und `stranger`. | dauerhaft |
| `bootstrap` | `wif-lab/tools` | Einmal-Job mit Admin-Kubeconfig: Namespaces, Secret `issuer-tls` in `wif-issuer-discovery`, ConfigMap `internal-ca` in `wif-demo`, Manifeste anwenden. | einmalig, Exit 0 |
| `load-balancer` | `nginx:1.29-alpine` | Stellvertreter für den Load Balancer vor dem Cluster: reicht TCP 443 aus `relying-net` an Traefiks Node-Port durch. | dauerhaft |
| `validator` | `wif-lab/validator` (aus `validator/`) | Der Dienst *außerhalb* des Clusters. Spring Boot 4 / Java 25. Prüft die Tokens offline. | dauerhaft |
| `validator-foreign-ca` | `wif-lab/validator` | Negativtest: Validator mit fremder CA, muss beim Start scheitern. Profil `negative`. | auf Anforderung |
| `keycloak` | `quay.io/keycloak/keycloak:26.8.2` | Autorisierungsserver des Fachbereichs (Realm `domain-rst`): tauscht ServiceAccount-Tokens gegen Access-Tokens. Siehe [autorisierungsserver.md](autorisierungsserver.md). | dauerhaft |
| `keycloak-gateway` | `nginx:1.29-alpine` | Einziger Weg der Pods zu Keycloak; leitet nur `/realms/domain-rst/` weiter. | dauerhaft |
| `keycloak-admin` | `nginx:1.29-alpine` | Admin-Konsole vom Host (`127.0.0.1:18443`). Profil `admin`. | auf Anforderung |
| `service-r` | `wif-lab/service-r` (aus `service-r/`) | Dienst R: Spring-Security-Resource-Server, prüft Access-Tokens und Scopes. | dauerhaft |
| `demo` | `wif-lab/tools` | Der Ende-zu-Ende-Test (`all`, `authz`, `hardening`, `resilience`, `pre-rotation`, `staged`, `post-rotation`). Profil `demo`. | auf Anforderung |

Der Host braucht nur **Docker + Compose v2**. Kein `kubectl`, kein `k3d`, kein Java auf dem
Host – alles steckt in den Containern.

---

## ASCII-Topologie

```
      cluster-net 172.31.7.0/24                          relying-net 172.31.8.0/24
 ┌────────────────────────────────────┐                ┌───────────────────────────────┐
 │ server  .2  (Alias k3s-server)     │                │                               │
 │  API-Server nur auf .2:6443        │  ┌──────────┐  │ validator  .10                │
 │  Traefik Node-Port nur .2:30443 ◄──┼──┤load-balancer│◄─┼── GET Discovery + JWKS        │
 │   └─ Gateway issuer.wif.local      │  │.7.20     │  │   (https://issuer.wif.local)  │
 │       └─ Discovery-Pod (sync+web)  │  │ .8.20:443│  │ keycloak .30 (ebenso)         │
 │                                    │  └──────────┘  │                               │
 │ bootstrap, demo                    │                │ demo, validator-foreign-ca    │
 └───────────────┬────────────────────┘                └──────────────▲────────────────┘
                 │ server .2                                          │ validator .10 :8443
                 │                workload-net 172.31.9.0/24          │ (Host 127.0.0.1:18080)
                 └──── Pod consumer: HTTPS GET /whoami, Bearer ───────┘

 pki-init, sa-keys: ohne Netz (network_mode: none)
```

Autorisierungs-Pfad (Details in [autorisierungsserver.md](autorisierungsserver.md)):

```
 workload-net                               relying-net
 Pods ── HTTPS keycloak:8443 ──► keycloak-gateway .9.30 │ .8.31 ──► keycloak .8.30:8443 ──► load-balancer .8.20:443
      │                          nur /realms/domain-rst/                ▲
      └── HTTPS :8443 ─────────► service-r .9.40 │ .8.40 ───────────────┘ Discovery + JWKS
                                                     keycloak-admin .8.32 (Profil admin, Host 127.0.0.1:18443)
```

`load-balancer` ist das einzige Bauteil, das `relying-net` mit `cluster-net` verbindet: Es
lauscht nur auf `172.31.8.20:443` und leitet ausschließlich an `172.31.7.2:30443` weiter. Der
API-Server und der Node-Port lauschen nur auf der `cluster-net`-Adresse des Servers. Die
Relying Parties erreichen damit vom Cluster nur die Gateway-Route des Discovery-Pods.

---

## Service für Service

### `pki-init` – die Lab-PKI

- **`entrypoint: ["bash", "/work/pki-init.sh"]`**, `restart: "no"`, **`network_mode: none`**.
- **`volumes`:** `pki-ca` (CA-Schlüssel, nur hier eingehängt), `ca-trust` (Root-Zertifikat),
  `issuer-tls`, `keycloak-tls`, `service-r-tls`, `validator-tls`, `pki-demo`.
- Was das Skript tut: [bootstrap-und-issuer.md](bootstrap-und-issuer.md#toolspki-initsh--die-lab-pki).

### `sa-keys` – die Signaturschlüssel

- **`entrypoint: ["bash", "/work/sa-keys.sh"]`**, `command: ["init"]`, ohne Netz.
- **`volumes`:** `sa-keys:/sa-keys` (rw).
- `docker compose run --rm sa-keys stage` und später `… activate` wechseln den Schlüssel in
  zwei Phasen; `… retire` entfernt im Notfall den vorherigen Schlüssel sofort. Danach muss
  `server` jeweils neu starten. Details:
  [bootstrap-und-issuer.md](bootstrap-und-issuer.md#zweiphasiger-schlüsselwechsel).

### `server` – der Kubernetes-Cluster

- **Image:** `rancher/k3s` (über `${K3S_IMAGE}` austauschbar).
- **`privileged: true`** – k3s startet intern selbst Container und braucht dafür erweiterte
  Rechte. Nur im Lab akzeptabel.
- **`command`** – Startflags des k3s-Servers:
  - `--disable=servicelb`, `--disable=metrics-server` – schalten Cluster-Zusatzkomponenten
    ab, die das Lab nicht braucht. Traefik bleibt an; konfiguriert wird es über
    `manifests/01-traefik-config.yaml`.
  - `--tls-san=k3s-server` – trägt den Namen `k3s-server` als **SAN** (Subject Alternative
    Name, siehe [trust-und-tls.md](trust-und-tls.md)) in das Serverzertifikat des API-Servers
    ein, damit `kubectl` ihn unter diesem Namen erreicht.
  - `--node-ip`, `--advertise-address`, `--bind-address` = `172.31.7.2` – der API-Server
    lauscht nur auf seiner Adresse in `cluster-net`.
  - `--kube-proxy-arg=nodeport-addresses=172.31.7.0/24` – Node-Ports (Traefik: 30443) nur
    auf der `cluster-net`-Adresse, nicht in `workload-net`.
  - `service-account-issuer=https://issuer.wif.local` – **die zentrale Einstellung**: jeder
    ausgestellte Pod-Token trägt `iss=https://issuer.wif.local`.
  - `service-account-jwks-uri=https://issuer.wif.local/openid/v1/jwks` – Wert, der im
    Discovery-Dokument als `jwks_uri` landet.
  - `service-account-signing-key-file=/sa-keys/signing.key`,
    `service-account-key-file=/sa-keys/verify.pub` – eigene Schlüsseldateien aus `sa-keys`.
- **`tmpfs: /run, /var/run`** – flüchtige RAM-Dateisysteme für Laufzeit-Sockets.
- **`environment`** – `K3S_TOKEN` (Beitrittsgeheimnis, im Lab kein echtes Secret),
  `K3S_KUBECONFIG_OUTPUT=/output/kubeconfig.yaml`, `K3S_KUBECONFIG_MODE=644`.
- **`volumes`:** `k3s-data` (Cluster-Datenbank), `kubeconfig:/output`, `sa-keys:/sa-keys:ro`.
- **`networks`:** `cluster-net` mit fester IP `172.31.7.2` und **Alias** `k3s-server`,
  `workload-net` mit `172.31.9.2`. Über `workload-net` erreichen Pods Validator, Keycloak
  (Gateway) und `service-r`; API-Server und Node-Port lauschen dort nicht.
- **`depends_on: sa-keys → service_completed_successfully`**.
- **`healthcheck`:** `kubectl get --raw /readyz`.

### `bootstrap` – der Einmal-Job

- **`entrypoint: ["bash", "/work/bootstrap.sh"]`**, `restart: "no"`.
- **`volumes`:** `kubeconfig:/kube:ro`, `ca-trust:/trust:ro`, `issuer-tls:/issuer-tls:ro`,
  `./manifests:/manifests:ro`, `./tools:/work:ro`.
- **`networks`:** nur `cluster-net`.
- **`depends_on`:** `server → service_healthy`, `pki-init → service_completed_successfully`.
- Was das Skript tut: [bootstrap-und-issuer.md](bootstrap-und-issuer.md#toolsbootstrapsh-schritt-für-schritt).

### `load-balancer` – der Weg der Relying Parties in den Cluster

- **Image:** `nginx:1.29-alpine` (über `${NGINX_IMAGE}` austauschbar),
  `command: nginx -c /etc/nginx/load-balancer.conf`; `mem_limit: 32m`.
- **Härtung:** `read_only: true` mit `tmpfs` für `/tmp` und `/var/cache/nginx`,
  `cap_drop: ALL`, nur `NET_BIND_SERVICE`, `SETUID`, `SETGID` zurück (Port 443, Wechsel der
  Worker auf den Benutzer `nginx`), `no-new-privileges`.
- **`volumes`:** `ca-trust:/trust:ro` (nur für den Healthcheck), die Config
  `./tools/nginx-load-balancer.conf`.
- **`networks`:** `cluster-net` mit `172.31.7.20`, `relying-net` mit `172.31.8.20` und Alias
  `issuer.wif.local`.
- TCP-Pass-through `172.31.8.20:443` → `172.31.7.2:30443`; TLS endet bei Traefik im Cluster.
- **`depends_on: server → service_healthy`**.
- **`healthcheck`:** `curl` mit Lab-CA auf `https://issuer.wif.local/openid/v1/jwks` – gesund,
  sobald der Discovery-Pod das JWKS über das Gateway ausliefert (`retries: 120`, alle 5 s,
  `start_period: 30s`).
- Details: [bootstrap-und-issuer.md](bootstrap-und-issuer.md#gateway-traefik-gateway-httproute-und-load-balancer).

### `validator` – der Dienst außerhalb des Clusters

- **`build.context: ./validator`** – Multi-Stage-Build, siehe
  [build-und-betrieb.md](build-und-betrieb.md).
- **`environment`:** `WIF_ISSUER` (Default `https://issuer.wif.local`), `WIF_AUDIENCE`
  (Default `wif-demo-validator`), `WIF_ISSUER_CA=/trust/ca.crt`, `VALIDATOR_TLS_DIR=/tls`.
- **`volumes`:** `ca-trust:/trust:ro` – das Root-Zertifikat der internen CA – und
  `validator-tls:/tls:ro` – das eigene Serverzertifikat. Kein Volume der Cluster-Seite.
- **`networks`:** `relying-net` mit `172.31.8.10`, `workload-net` mit `172.31.9.10`.
- **`ports: "127.0.0.1:${VALIDATOR_HOST_PORT:-18080}:8443"`** – nur HTTPS, kein
  HTTP-Listener; vom Host unter `https://localhost:18080` (Lab-CA). Läuft als `USER 10001`.
- **`depends_on: load-balancer → service_healthy`**.
- **`healthcheck`:** `curl -fsS --cacert /trust/ca.crt https://localhost:8443/healthz`,
  `start_period: 40s`.

### `validator-foreign-ca` – der Negativtest

- Gleiches Image wie `validator`, aber `WIF_ISSUER_CA=/pki-demo/foreign-ca.crt` aus dem
  Volume `pki-demo`, nur in `relying-net`, Profil `negative`. Es hängt auch `validator-tls` ein,
  damit der Start allein an der fremden Issuer-CA (PKIX) scheitert.
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
- **`depends_on`:** `pki-init → service_completed_successfully`, `load-balancer → service_healthy`.
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
- **`command: ["all"]`** – Phase; außerdem `authz`, `hardening`, `resilience`,
  `pre-rotation`, `staged` und `post-rotation`.
- **`environment`:** `WIF_AUDIENCE`, `VALIDATOR_URL=https://validator:8443`, `KC_REALM_ISSUER`.
- **`volumes`:** `kubeconfig:/kube:ro`, `ca-trust:/trust:ro`, `pki-demo:/pki-demo:ro`,
  `demo-state:/state` (Token und `kid`s zwischen den Phasen des Schlüsselwechsels).
- **`networks`:** `cluster-net` (für `kubectl`) und `relying-net` (für
  `https://issuer.wif.local` über `load-balancer`, Validator und Keycloak).
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
| `ca-trust` | `pki-init` | `bootstrap`, `load-balancer`, `validator`, `keycloak`, `keycloak-gateway`, `keycloak-admin`, `service-r`, `demo` | `ca.crt` – Stellvertreter für die anderweitige Verteilung des Root-Zertifikats. |
| `issuer-tls` | `pki-init` | `bootstrap` (→ Secret `issuer-tls` in `wif-issuer-discovery`) | Serverzertifikat `tls.crt` / `tls.key` des Gateways (`CN=issuer.wif.local`, SAN `DNS:issuer.wif.local`). |
| `pki-demo` | `pki-init` | `demo`, `validator-foreign-ca` | `foreign-ca.crt`. |
| `keycloak-tls` | `pki-init` | `keycloak`, `keycloak-gateway`, `keycloak-admin` | Serverzertifikat `tls.crt` / `tls.key` (SAN `DNS:keycloak`, `DNS:localhost`, `IP:127.0.0.1`), Schlüssel gehört uid 1000. |
| `validator-tls` | `pki-init` | `validator`, `validator-foreign-ca` | Serverzertifikat `tls.crt` / `tls.key` (`CN=validator.wif.local`, SAN `DNS:validator.wif.local`, `DNS:validator`, `DNS:localhost`, `IP:127.0.0.1`), Schlüssel gehört uid 10001 (Modus 400). |
| `service-r-tls` | `pki-init` | `service-r` | Serverzertifikat `tls.crt` / `tls.key` (`CN=service-r.wif.local`, SAN `DNS:service-r.wif.local`, `DNS:service-r`, `DNS:localhost`, `IP:127.0.0.1`), Schlüssel gehört uid 10001 (Modus 400). |
| `sa-keys` | `sa-keys` | `server` (ro) | `signing.key`, `current.pub`, `staged.*` (zwischen `stage` und `activate`), `previous.pub`, `verify.pub`. |
| `k3s-data` | `server` | – | Interne k3s-Datenbank, Cluster-Zustand. |
| `kubeconfig` | `server` | `bootstrap`, `demo` | `kubeconfig.yaml` – Adresse + Admin-Zugang für `kubectl`. |
| `demo-state` | `demo` | `demo` | Token und `kid`s zwischen den Phasen des Schlüsselwechsels. |

Zwischen Cluster-Seite und Relying Parties gibt es **kein** gemeinsames Volume. Die Daten
(Discovery-Dokument, JWKS) erreichen Validator und Keycloak nur über HTTPS von
`issuer.wif.local`, der Vertrauensanker (`ca.crt`) über `ca-trust`. Die Kopie, die der
Discovery-Pod ausliefert, liegt in einem `emptyDir` im Pod, nicht in einem Docker-Volume.

> **`down -v`:** `docker compose down` allein lässt die Volumes stehen; erst `docker compose
> down -v` löscht sie. Siehe [build-und-betrieb.md](build-und-betrieb.md).

---

## Die drei Netze

| Netz | Subnetz | Mitglieder | Zweck |
|---|---|---|---|
| `cluster-net` | `172.31.7.0/24` | `server` (.2, Alias `k3s-server`), `load-balancer` (.20), `bootstrap`, `demo` | Der Cluster: API-Server und Node-Port von Traefik lauschen nur hier. |
| `relying-net` | `172.31.8.0/24` | `load-balancer` (.20, Alias `issuer.wif.local`), `validator` (.10), `keycloak` (.30, Alias `keycloak`), `keycloak-gateway` (.31), `keycloak-admin` (.32), `service-r` (.40), `demo`, `validator-foreign-ca` | Relying Parties und Autorisierungsserver; Zugang zum Cluster nur über `load-balancer :443`. |
| `workload-net` | `172.31.9.0/24` | `server` (.2), `validator` (.10), `keycloak-gateway` (.30), `service-r` (.40) | Pods rufen Validator, Keycloak (über das Gateway) und `service-r` auf. |

- **`driver: bridge`** – der Standard-Netzwerktyp von Docker: ein privates virtuelles LAN.
  Container im selben Netz erreichen sich über Service-Namen und Aliase.
- **`ipam`** legt das Subnetz fest; feste Adressen kommen über `ipv4_address`.
- Pod-Verkehr verlässt den k3s-Container mit dessen Adresse im jeweiligen Netz. Ein Pod
  erreicht deshalb den Validator über `workload-net`.

Keycloak selbst hängt nicht in `workload-net`. Weil Docker veröffentlichte Ports auch aus
anderen Bridge-Netzen erreichbar macht, veröffentlicht er keinen Port; nicht veröffentlichte
Ports wie `load-balancer :443` oder Keycloak `:9000` bleiben auf ihre Netze beschränkt.

`tools/run-all-checks.sh` prüft die Trennung von Validator und `service-r` aus
(`172.31.9.2:6443`, `172.31.7.2:6443`, `172.31.7.2:30443`, `172.31.9.2:30443` nicht
erreichbar) und von Keycloak aus (`172.31.9.2:6443`, `172.31.7.2:6443`, `172.31.7.2:30443`,
`172.31.7.20:443` nicht erreichbar, `172.31.8.20:443` erreichbar). `demo.sh authz`
(Prüfung 20) prüft aus einem Pod, dass Keycloak nur über das Gateway und nur mit dem Realm
`domain-rst` erreichbar ist.

### Warum feste IPs – und warum brauchen die Pods `hostAliases`?

Validator, Keycloak-Gateway und `service-r` laufen **außerhalb** des Clusters. Der
cluster-interne DNS (CoreDNS) kennt nur Dinge *im* Cluster. Die Pods lösen die Namen deshalb
über `hostAliases` auf, die statische Zeilen in `/etc/hosts` schreiben:

| Pod | Name | IP |
|---|---|---|
| `consumer` (`manifests/20-consumer.yaml`) | `validator.wif.local` | `172.31.9.10` (Validator in `workload-net`) |
| `consumer`, `reader`, `stranger` | `keycloak` | `172.31.9.30` (`keycloak-gateway` in `workload-net`) |
| `consumer`, `reader` | `service-r.wif.local` | `172.31.9.40` (`service-r` in `workload-net`) |

Damit diese Einträge stimmen, **müssen** die Adressen fest sein. Weitere feste Adressen:
`172.31.7.2` (Ziel in `tools/nginx-load-balancer.conf`, Egress-Ziel der NetworkPolicy
`issuer-discovery-to-api-server`), `172.31.8.20` (Bind-Adresse in `tools/nginx-load-balancer.conf`,
`LOAD_BALANCER_ADDR` in `tools/demo.sh`). Außerhalb des Clusters löst `issuer.wif.local` über
den Compose-Alias von `load-balancer` in `relying-net` auf. Die Namen unter `wif.local` sind frei
gewählt.

---

## Startreihenfolge

`depends_on` mit `condition` verkettet die Services. Compose startet nichts, bevor die
Bedingung des Vorgängers erfüllt ist:

```
pki-init     ─┬─ completed
sa-keys      ─┤  completed
              ▼
server       healthy (kubectl get --raw /readyz)
              ├────────────────────────────────────────┐
              ▼   (+ pki-init completed)               ▼
bootstrap    Namespaces, Secret, ConfigMap,       load-balancer  startet, Healthcheck
             Manifeste, Rollouts discovery,                   noch rot
             traefik, Gateway Programmed,              │
             consumer, reader, stranger, Exit 0        │
              │                                        │
              ▼                                        │
Discovery-Pod  sync holt den ersten Stand, web ready ► │ healthy (JWKS über das Gateway)
                                                       ▼
validator    entrypoint.sh wartet auf /trust/ca.crt, OIDC-Discovery, JWKSource
             healthy (curl --cacert … https://localhost:8443/healthz)
keycloak     Realm-Import, healthy (/health/ready auf :9000)
              ▼
keycloak-gateway  healthy (nc -z 127.0.0.1 8443)

service-r    nach pki-init: entrypoint.sh baut Truststore, healthy (curl --cacert … https://localhost:8443/healthz)

demo         nur bei "docker compose run --rm demo" (wartet auf validator, service-r, keycloak-gateway)
```

`validator` und `keycloak` hängen beide an `load-balancer` und starten parallel;
`service-r` wartet nur auf `pki-init`. `demo` wartet über `keycloak-gateway` indirekt auf Keycloaks Healthcheck;
da `/health/ready` schon vor dem Abschluss des ersten Bootstraps UP meldet, wiederholt Prüfung 8
die Realm-Discovery bis zu 60 s.

`pki-init`, `sa-keys` und `bootstrap` laufen bei **jedem** `up` erneut und sind idempotent:
Vorhandene CA, Zertifikate und Signaturschlüssel bleiben erhalten.

---

## Weiterlesen

- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – PKI, Signaturschlüssel, Bootstrap,
  Discovery-Pod, Gateway und Härtung im Detail
- [validator.md](validator.md) – der Java-Service innen
- [autorisierungsserver.md](autorisierungsserver.md) – Keycloak, Realm und `service-r`
- [trust-und-tls.md](trust-und-tls.md) – die TLS-Vertrauensbeziehungen
- [build-und-betrieb.md](build-und-betrieb.md) – Images bauen, betreiben, Fehler beheben
- [../kubernetes-primer.md](../kubernetes-primer.md) – Kubernetes-Grundbegriffe
- [../domain.md](../domain.md) – das fachliche Modell
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
