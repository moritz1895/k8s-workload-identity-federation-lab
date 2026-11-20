# PKI, Bootstrap und Discovery-Pod

**Für wen / was lernst du hier:** Du kennst JWT/JWKS, aber nicht Kubernetes-Werkzeuge wie
`kubectl` oder OpenSSL-Aufrufe. Diese Seite geht die Bausteine durch, die Discovery-Dokument
und JWKS vom API-Server zu den Relying Parties bringen: die Lab-PKI (`tools/pki-init.sh`), die
Signaturschlüssel (`tools/sa-keys.sh`), die Cluster-Einrichtung (`tools/bootstrap.sh`), den
Discovery-Pod mit Gateway und HTTPRoute (`manifests/10-issuer-discovery.yaml`), Traefik
(`manifests/01-traefik-config.yaml`), die Härtung des Namespace
(`manifests/05-issuer-discovery-admission.yaml`) und `ingress-lb` (`tools/nginx-ingress-lb.conf`).
Die Entscheidungen dahinter:
[ADR 0005](../adr/0005-discovery-pod-im-cluster-pull-ueber-ingress.md) (Discovery-Pod, Pull) und
[ADR 0006](../adr/0006-gateway-api-statt-ingress.md) (Gateway API).

---

## Der Weg der Metadaten

Der Kubernetes-API-Server *kann* selbst ein OIDC-Discovery-Dokument und ein JWKS ausliefern
(unter `/.well-known/openid-configuration` und `/openid/v1/jwks`). Die Relying Parties sollen
den API-Server aber nicht erreichen, und die Issuer-URL soll nicht an seiner Adresse hängen
([ADR 0002](../adr/0002-eigenstaendiger-issuer-endpoint.md)). Deshalb liefert ein Pod im
Cluster eine Kopie aus. Aussteller (Issuer) bleibt der API-Server, der die Tokens signiert; der
Discovery-Pod stellt nur dessen Metadaten unter der Issuer-URL `https://issuer.wif.local` bereit:

```
 validator, keycloak (relying-net)
        │ GET https://issuer.wif.local/...
        ▼
 ingress-lb 172.31.8.20:443 ── TCP, TLS unverändert ──► 172.31.7.2:30443 (cluster-net)
                                                              │
 ── Cluster ──────────────────────────────────────────────────┼───────────────
                                                              ▼
            Traefik: Gateway issuer-discovery (TLS für issuer.wif.local),
            HTTPRoute issuer-discovery (nur GET auf 2 Pfade)
                                                              │ HTTP :8080
                                                              ▼
 API-Server :6443 ◄── GET (SA-Token) ── sync ──► emptyDir ──► web (nur GET)
                       └── Pod issuer-discovery (2 Replikas, Namespace wif-issuer-discovery) ──┘
```

Wer bestimmen kann, was unter der JWKS-URL ausgeliefert wird, kann Tokens für jeden
ServiceAccount fälschen. Es gibt deshalb keinen Schreibweg von außen: Der Discovery-Pod holt
sich die Daten selbst beim API-Server, und der Namespace `wif-issuer-discovery` ist geschützt wie die
Steuerung des Clusters ([Härtung](#härtung-von-wif-issuer-discovery)).

---

## `tools/pki-init.sh` – die Lab-PKI

Läuft als Einmal-Container `pki-init` ohne Netz. Er steht für die interne PKI der
Organisation, deren Root-Zertifikat real bereits auf allen Systemen verteilt ist.

| Artefakt | Volume | Inhalt |
|---|---|---|
| Root-CA | `pki-ca` (nur `pki-init`) | `ca.crt`, `ca.key` – RSA 3072, 10 Jahre, `CN=WIF Lab Internal Root CA` |
| Vertrauensanker | `ca-trust` | Kopie von `ca.crt` |
| Serverzertifikat Issuer-Gateway | `issuer-tls` | `tls.crt` / `tls.key`, `CN=issuer.wif.local`, SAN `DNS:issuer.wif.local`, `extendedKeyUsage=serverAuth`; `bootstrap` legt es als Secret `issuer-tls` in `wif-issuer-discovery` ab |
| Serverzertifikat Keycloak | `keycloak-tls` | `tls.crt` / `tls.key`, `CN=keycloak`, SAN `DNS:keycloak`, `DNS:localhost`, `IP:127.0.0.1`; Schlüssel `chown 1000:0`, `chmod 400`, weil Keycloak als uid 1000 läuft |
| Serverzertifikat Validator | `validator-tls` | `tls.crt` / `tls.key`, `CN=validator.wif.local`, SAN `DNS:validator.wif.local`, `DNS:validator`, `DNS:localhost`, `IP:127.0.0.1`; Schlüssel `chown 10001:0`, `chmod 400`, weil der Validator als uid 10001 läuft |
| Serverzertifikat `service-r` | `service-r-tls` | `tls.crt` / `tls.key`, `CN=service-r.wif.local`, SAN `DNS:service-r.wif.local`, `DNS:service-r`, `DNS:localhost`, `IP:127.0.0.1`; Schlüssel `chown 10001:0`, `chmod 400`, weil `service-r` als uid 10001 läuft |
| Negativtest | `pki-demo` | `foreign-ca.crt` – Root-Zertifikat einer fremden CA für `validator-foreign-ca` |

Die End-Zertifikate sind RSA 2048 und 825 Tage gültig. Das Skript ist idempotent: Existiert
die CA, bleibt sie; nur fehlende Zertifikate werden ausgestellt. Das Issuer-Zertifikat stellt
es zusätzlich neu aus, wenn das vorhandene nicht für `issuer.wif.local` gilt
(`openssl x509 -checkhost`). Erzeugt es eine neue CA, verwirft es alle vorhandenen
End-Zertifikate und stellt sie von der neuen CA aus.

**Warum `subjectAltName=DNS:issuer.wif.local`?** Moderne TLS-Clients (Java, curl) prüfen den
angefragten Hostnamen ausschließlich gegen die **SAN**-Liste des Zertifikats. Validator und
Keycloak rufen `https://issuer.wif.local/...` auf, also **muss** dieser Name als SAN im
Zertifikat stehen. Details: [trust-und-tls.md](trust-und-tls.md).

---

## `tools/sa-keys.sh` – Signaturschlüssel

Der API-Server signiert ServiceAccount-Tokens mit eigenen Schlüsseldateien aus dem Volume
`sa-keys` (statt mit dem k3s-eigenen Schlüssel):

| Datei | Bedeutung |
|---|---|
| `signing.key` | privater RSA-2048-Schlüssel, `service-account-signing-key-file` |
| `current.pub` | öffentlicher Teil von `signing.key` |
| `staged.key` / `staged.pub` | der nächste Schlüssel, solange er vorab veröffentlicht ist, aber noch nicht signiert (zwischen `stage` und `activate`) |
| `previous.pub` | öffentlicher Teil des vorherigen Signierschlüssels (nach `activate`) |
| `verify.pub` | `current.pub` + `staged.pub` + `previous.pub`, soweit vorhanden; `service-account-key-file` – diese Schlüssel erscheinen im JWKS |

| Befehl | Wirkung |
|---|---|
| `init` (Standard beim `up`) | legt `signing.key` an, wenn keiner existiert, und baut `verify.pub` |
| `stage` | Phase 1: erzeugt `staged.key`/`staged.pub` (oder behält einen vorhandenen) und nimmt den öffentlichen Teil in `verify.pub` auf; signiert wird weiter mit `signing.key` |
| `activate` | Phase 2: `current.pub` → `previous.pub`, `staged.key` → `signing.key`, `staged.pub` → `current.pub`; ein älteres `previous.pub` fällt weg |
| `retire` | Notfall, z. B. bei kompromittiertem Schlüssel: entfernt `previous.pub` sofort aus `verify.pub`. Tokens mit dieser `kid` werden abgelehnt, sobald die Relying Parties ihre Schlüssel neu laden (Validator spätestens nach 5 min, Keycloak bis zu 24 h, siehe [autorisierungsserver.md](autorisierungsserver.md#föderierte-client-authentisierung)) |

kube-apiserver liest die Dateien nur beim Start. Nach `stage`, `activate` und `retire` also
jeweils `docker compose restart server`.

### Zweiphasiger Schlüsselwechsel

```bash
docker compose run --rm sa-keys stage        # neuer Schlüssel vorab veröffentlicht, signiert noch nicht
docker compose restart server
# warten, bis der Discovery-Pod die neue kid ausliefert (demo staged prüft das)
docker compose run --rm sa-keys activate     # neuer Schlüssel signiert, alter bleibt Prüfschlüssel
docker compose restart server
```

1. **`stage`:** Der neue öffentliche Schlüssel steht im JWKS des API-Servers; `sync` übernimmt
   ihn innerhalb eines Durchlaufs (15 s) und loggt `WARNING kid appeared: <kid>`. Tokens
   tragen weiter die bisherige `kid`.
2. **`activate`:** erst, wenn der Discovery-Pod die neue `kid` ausliefert. Ab dann signiert der
   API-Server mit ihr. Weil Validator und Keycloak bei unbekannter `kid` neu laden und der
   Discovery-Pod sie bereits ausliefert, wird schon das erste Token mit der neuen `kid`
   angenommen.

So ist nie ein Token mit einer `kid` unterwegs, die der Discovery-Pod noch nicht ausliefert –
auch nicht, wenn die zwei Replikas kurz verschiedene Stände haben. Tokens mit der vorherigen
`kid` bleiben gültig, bis das nächste `activate` deren Schlüssel entfernt. Zwischen zwei
`activate` muss mindestens die maximale Token-Laufzeit (600 s für die Client Assertion) plus
die Cache-Zeit der Relying Parties liegen. Ablauf und Test:
[build-und-betrieb.md](build-und-betrieb.md#schlüsselwechsel).

---

## `tools/bootstrap.sh` Schritt für Schritt

Läuft als Einmal-Container `bootstrap` mit der Admin-Kubeconfig, nachdem `server` gesund und
`pki-init` fertig ist, und bei jedem `docker compose up` erneut.

### Kopf: strikte Fehlerbehandlung

`tools/bootstrap.sh:9`

```bash
set -euo pipefail
```

- `-e` – bricht bei jedem fehlschlagenden Kommando sofort ab.
- `-u` – unbekannte Variable = Fehler.
- `-o pipefail` – eine Pipe `a | b` schlägt fehl, wenn *irgendein* Glied fehlschlägt.

### Schritt 1 – kubeconfig auf den Docker-Netz-Namen umschreiben

`tools/bootstrap.sh:11`

```bash
KCFG=/tmp/kubeconfig
sed -E 's#server: https://[^/]+:6443#server: https://k3s-server:6443#' /kube/kubeconfig.yaml > "$KCFG"
export KUBECONFIG="$KCFG"
```

**Was ist eine kubeconfig?** Eine YAML-Datei, die `kubectl` sagt, *unter welcher URL* der
API-Server erreichbar ist und *mit welchen Zertifikaten* man sich ausweist. k3s schreibt sie
ins Volume `kubeconfig`.

**Das Problem:** Die Server-Adresse in der kubeconfig stimmt nur *innerhalb des
server-Containers*. `sed` ersetzt jede `https://<host>:6443` durch `https://k3s-server:6443` –
den Alias des Servers in `cluster-net`. Dass der TLS-Handshake mit diesem Namen klappt, liegt
an `--tls-san=k3s-server` ([trust-und-tls.md](trust-und-tls.md)).

> Dieselbe Umschreibung steht wortgleich in `tools/demo.sh`.

### Schritt 2 – Namespaces anlegen

`tools/bootstrap.sh:16`

```bash
kubectl apply -f /manifests/00-namespace.yaml
```

Legt `wif-demo` und `wif-issuer-discovery` an (`wif-issuer-discovery` mit Pod Security Standard `restricted`).
Das muss vor Schritt 3 passieren, weil Secret und ConfigMap dort liegen.

### Schritt 3 – Gateway-Zertifikat und interne CA

`tools/bootstrap.sh:19`

```bash
kubectl -n wif-issuer-discovery create secret tls issuer-tls \
    --cert=/issuer-tls/tls.crt --key=/issuer-tls/tls.key \
    --dry-run=client -o yaml | kubectl apply --server-side -f -
kubectl -n wif-demo create configmap internal-ca \
    --from-file=ca.crt=/trust/ca.crt \
    --dry-run=client -o yaml | kubectl apply --server-side -f -
```

`create … --dry-run=client -o yaml | kubectl apply --server-side -f -` erzeugt das Objekt nur als
YAML und wendet es dann an – damit ist der Schritt idempotent. `--server-side` hält den
TLS-Schlüssel aus der Annotation `last-applied-configuration` heraus, die ein
clientseitiges `apply` ins Objekt schreiben würde. Das Secret `issuer-tls` referenziert der
Listener des Gateways `issuer-discovery`; Traefik präsentiert es für `issuer.wif.local`. Die ConfigMap `internal-ca`
brauchen die Demo-Pods (`/etc/internal-ca`), um Validator, Keycloak und `service-r` per TLS zu
prüfen. In einem echten Cluster übernähme das cert-manager oder die PKI-Anbindung der
Plattform.

### Schritt 4 – Manifeste anwenden und warten

`tools/bootstrap.sh:27`

```bash
kubectl apply -f /manifests
kubectl -n wif-issuer-discovery rollout status deployment/issuer-discovery --timeout=180s
until kubectl -n kube-system get deployment traefik > /dev/null 2>&1; do sleep 3; done
kubectl -n kube-system rollout status deployment/traefik --timeout=300s
kubectl -n wif-issuer-discovery wait gateway/issuer-discovery --for=condition=Programmed --timeout=120s
kubectl -n wif-demo rollout status deployment/consumer --timeout=180s
# ... ebenso reader und stranger
```

- `00-namespace.yaml` – die beiden Namespaces (erneut, idempotent).
- `01-traefik-config.yaml` – `HelmChartConfig` für das in k3s mitgelieferte Traefik
  ([Gateway](#gateway-traefik-gateway-httproute-und-ingress-lb)).
- `05-issuer-discovery-admission.yaml` – die `ValidatingAdmissionPolicy`s
  `issuer-host-reserved` und `issuer-discovery-image-digest` mit ihren Bindings.
- `10-issuer-discovery.yaml` – ServiceAccount, ClusterRoleBinding, ConfigMaps, Deployment, Service,
  Gateway, HTTPRoute und NetworkPolicies des Discovery-Pods (siehe unten).
- `20-consumer.yaml` – ServiceAccount `consumer` und Deployment `consumer` mit zwei
  projizierten Tokens (`sa-token` mit `audience: wif-demo-validator`, `kc-token` mit dem
  Realm-Issuer als Audienz, je `expirationSeconds: 600`) und
  `automountServiceAccountToken: false`, damit der Pod nur diese Tokens besitzt.
- `30-authz-workloads.yaml` – ConfigMap `authz-client` (`access-token.sh`) und die Pods
  `reader` und `stranger` der Autorisierungs-Demo, siehe
  [autorisierungsserver.md](autorisierungsserver.md#workload-seite).

`rollout status` **blockiert**, bis die Deployments bereit sind. Das Deployment `traefik`
legt k3s selbst per Helm an; `bootstrap` wartet, bis es existiert und bereit ist, und danach,
bis das Gateway `issuer-discovery` `Programmed` meldet.

---

## Der Discovery-Pod (`manifests/10-issuer-discovery.yaml`)

| Objekt | Zweck |
|---|---|
| ServiceAccount `issuer-discovery` (`wif-issuer-discovery`) | Identität von `sync` gegenüber dem API-Server; `automountServiceAccountToken: false`. |
| ClusterRoleBinding `wif-issuer-discovery` | Bindet die eingebaute ClusterRole `system:service-account-issuer-discovery` – nur `GET` auf die zwei Discovery-Pfade. |
| ConfigMap `issuer-discovery-sync` | Das Skript `sync.sh`. |
| ConfigMap `issuer-discovery-nginx` | nginx-Konfiguration `default.conf` für den Container `web`. |
| Deployment `issuer-discovery` | zwei Replikas, `RollingUpdate` mit `maxUnavailable: 0`, `maxSurge: 1`; Container `sync` und `web` teilen sich das `emptyDir` `oidc` (`/srv/oidc`). |
| Service `issuer-discovery` | Port 80 → `web:8080`. |
| Gateway `issuer-discovery` | ein HTTPS-Listener `issuer-https` für `issuer.wif.local`, TLS mit Secret `issuer-tls`, nur Routen aus dem eigenen Namespace ([Gateway](#gateway-issuer-discovery)). |
| HTTPRoute `issuer-discovery` | nur `GET` auf die zwei Pfade (`Exact`) zum Service. |
| NetworkPolicies | `default-deny`, `issuer-discovery-from-gateway`, `issuer-discovery-to-api-server`. |

Beide Images sind per Digest gepinnt (`curlimages/curl:8.23.0@sha256:…`,
`nginxinc/nginx-unprivileged:1.31.7-alpine@sha256:…`); ohne Digest lässt die Admission
Policy `issuer-discovery-image-digest` sie nicht zu.

### Container `sync`

Eine Schleife alle `SYNC_INTERVAL_SECONDS` (15):

1. Discovery-Dokument und JWKS vom API-Server holen
   (`https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT`), mit dem ServiceAccount-Token
   und der Cluster-CA aus dem projizierten Volume `discovery-token`. Das Token geht über eine
   Header-Datei an `curl` (`-H @file`), nicht über die Kommandozeile; `--max-time 10`,
   `--max-filesize 65536`.
2. Unverändert gegenüber dem ausgelieferten Stand → nichts tun.
3. Sonst **Plausibilitätsprüfung**: Das Discovery-Dokument nennt exakt `EXPECTED_ISSUER`
   (`https://issuer.wif.local`) und `EXPECTED_JWKS_URI`, das JWKS enthält mindestens eine
   `kid`. Scheitert sie: `issuer-discovery-sync: REJECTED state: …`, der alte Stand bleibt.
4. **`kid`-Änderungen loggen:** jede neue `kid` als `WARNING kid appeared: <kid>`, jede
   weggefallene als `WARNING kid vanished: <kid>`.
5. **Atomar übernehmen:** beide Dateien erst als `.tmp` daneben kopieren, dann per `mv`
   ersetzen. Log: `issuer-discovery-sync: serving JWKS sha256=<hash> kids=[ … ]`.
6. Ist der API-Server nicht lesbar:
   `reading from the API server failed, keeping the last good state, retrying in 15s`.

`/srv/oidc` startet leer. Bis zum ersten plausiblen Stand gibt es kein JWKS – und damit keine
Bereitschaft (siehe `web`).

Log ansehen:

```bash
docker compose exec server kubectl -n wif-issuer-discovery logs deploy/issuer-discovery -c sync
```

### Container `web`

nginx ohne Root (`nginx-unprivileged`) mit der ConfigMap `issuer-discovery-nginx`:

```nginx
server {
    listen 8080;
    server_tokens off;
    root /srv/oidc;

    location = /.well-known/openid-configuration {
        limit_except GET { deny all; }
        default_type application/json;
    }

    location = /openid/v1/jwks {
        limit_except GET { deny all; }
        default_type application/json;
    }

    location / {
        return 404;
    }
}
```

- **`location = /pfad`** – nur die zwei OIDC-Pfade; alles andere `404`.
- **`limit_except GET { deny all; }`** – nur `GET` (und damit `HEAD`); `PUT`, `POST`, `DELETE`
  ergeben `403`. Von außen kommen diese Methoden gar nicht bis hierher: Die HTTPRoute lässt nur
  `GET` durch.
- **`default_type application/json`** – die Dateien haben keine Endung; ohne diese Zeile fiele
  nginx auf `application/octet-stream` zurück. OIDC-Clients (und Nimbus) erwarten JSON.
- `/srv/oidc` ist read-only eingehängt. `web` hat **kein** ServiceAccount-Token und ist nicht
  dafür konfiguriert, den API-Server anzusprechen; keine Anfrage von außen wird dorthin
  durchgereicht.
- **Readiness:** `GET /openid/v1/jwks` alle 5 s. Bereit erst, wenn `sync` einen Stand
  übernommen hat. Ein neuer Pod ohne plausiblen Stand bekommt keinen Verkehr, und wegen
  `maxUnavailable: 0` bleiben die alten Pods so lange im Dienst. **Liveness:** TCP auf 8080.

### Pod-Härtung

- Pod: `runAsNonRoot`, uid/gid 101, `seccompProfile: RuntimeDefault`,
  `enableServiceLinks: false`.
- Beide Container: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
  `capabilities.drop: ["ALL"]`. Schreibbar sind nur die `emptyDir`s `oidc` (1 Mi),
  `sync-tmp` (1 Mi) und `web-tmp` (8 Mi).
- Das ServiceAccount-Token (projiziert, `expirationSeconds: 3600`) hängt nur in `sync`.

---

## Gateway: Traefik, Gateway, HTTPRoute und `ingress-lb`

Eine Route besteht aus dem **Proxy**, der Verbindungen annimmt, TLS beendet und weiterleitet
(Traefik, der Gateway-Controller in `kube-system`), und aus der **Beschreibung** als
Kubernetes-Objekte der Gateway API: Das **Gateway** legt Listener fest (Port, Hostname,
Zertifikat, wer Routen anhängen darf), die **HTTPRoute** hängt sich an einen Listener und
führt Pfade zu einem Service. Hintergrund:
[ADR 0006](../adr/0006-gateway-api-statt-ingress.md).

### Traefik (`manifests/01-traefik-config.yaml`)

k3s bringt Traefik mit; die `HelmChartConfig` passt ihn an:

| Wert | Wirkung |
|---|---|
| `service.spec.type: NodePort`, `ports.websecure.nodePort: 30443` | fester Node-Port für HTTPS |
| `ports.web.expose.default: false` | kein HTTP-Entrypoint nach außen |
| `providers.kubernetesGateway.enabled: true` | Routen kommen aus der Gateway API (`Gateway` + `HTTPRoute`) |
| `providers.kubernetesIngress.enabled: false`, `providers.kubernetesCRD.enabled: false` | `Ingress`-Objekte und Traefiks eigene CRDs (`IngressRoute` u. a.) sind wirkungslos; die Admission Policy deckt damit jede Route ab |
| `gatewayClass.enabled: true`, `name: traefik`; `gateway.enabled: false` | das Chart legt die GatewayClass `traefik` an, aber kein Standard-Gateway |
| `tls.options.default.sniStrict: true`, `minVersion: VersionTLS12` | TLS-Handshake für einen Host ohne eigenes Zertifikat scheitert |

kube-proxy öffnet Node-Ports nur auf der `cluster-net`-Adresse
(`--kube-proxy-arg=nodeport-addresses=172.31.7.0/24` in `compose.yaml`); auf `172.31.9.2`
(`workload-net`) ist 30443 nicht erreichbar.

### Gateway `issuer-discovery`

Das eigene Gateway des Discovery-Endpunkts (`gatewayClassName: traefik`) hat genau einen
Listener `issuer-https`:

| Feld | Wert | Wirkung |
|---|---|---|
| `protocol`, `port` | `HTTPS`, `8443` | Entrypoint `websecure` im Traefik-Pod; von außen über Node-Port 30443 |
| `hostname` | `issuer.wif.local` | der Listener nimmt nur diesen Host an |
| `tls.mode`, `certificateRefs` | `Terminate`, Secret `issuer-tls` | TLS endet bei Traefik mit dem Zertifikat der internen PKI |
| `allowedRoutes.namespaces.from` | `Same` (nur `HTTPRoute`) | nur Routen aus `wif-issuer-discovery` hängen sich an; eine fremde Route bekommt `Accepted=False`, Grund `NotAllowedByListeners` |
| `allowedListeners.namespaces.from` | `None` | kein `ListenerSet` kann weitere Listener an dieses Gateway hängen |

`bootstrap` wartet, bis das Gateway die Bedingung `Programmed` meldet.

### HTTPRoute `issuer-discovery`

Hängt sich an Gateway `issuer-discovery`, Listener `issuer-https`, Hostname
`issuer.wif.local`, und führt nur `GET` auf `/.well-known/openid-configuration` und
`/openid/v1/jwks` (Typ `Exact`) zum Service `issuer-discovery`, Port 80. Jede andere Methode
und jeder andere Pfad endet bei Traefik mit `404`; der Pod sieht sie nie.

Von Traefik zum Pod läuft HTTP ohne TLS (Port 8080), abgesichert nur durch die
NetworkPolicy `issuer-discovery-from-gateway`. Die Gateway API bietet dafür
`BackendTLSPolicy`; das Lab nutzt sie nicht.

### `ingress-lb` (`tools/nginx-ingress-lb.conf`)

Stellvertreter für den Load Balancer vor den Knoten mit dem Gateway-Controller und der
einzige Weg der Relying Parties in den Cluster. „Ingress“ meint im Namen den eingehenden
Verkehr, nicht das Kubernetes-Objekt. nginx im `stream`-Modus (TCP):

```nginx
server {
    listen 172.31.8.20:443;
    proxy_pass 172.31.7.2:30443;
    proxy_connect_timeout 5s;
}
```

- Lauscht nur auf seiner Adresse in `relying-net`; dort trägt er den Alias
  `issuer.wif.local`. Seine `cluster-net`-Adresse `172.31.7.20` dient nur dem Weg zum
  Node-Port.
- Reicht TCP durch; TLS endet erst bei Traefik im Cluster.
- Log pro Verbindung: Zeit, Quelle, Ziel, Status, Bytes.
- **Healthcheck:** `curl --cacert /trust/ca.crt --resolve issuer.wif.local:443:172.31.8.20
  https://issuer.wif.local/openid/v1/jwks` – gesund, sobald der Discovery-Pod das JWKS über
  das Gateway ausliefert. Erst dann starten `validator` und `keycloak`.

### Was `demo all` (Prüfung 6) am Endpunkt prüft

| Anfrage über `ingress-lb` | Ergebnis |
|---|---|
| `PUT`, `POST`, `DELETE` auf `/openid/v1/jwks` | `404` (die Route passt nur auf `GET`) |
| `GET /` (nicht geroutet) | `404` |
| SNI `other.wif.local` | kein TLS-Handshake (strict SNI) |
| SNI `kubernetes.default.svc` | kein TLS-Handshake, kein Weg zum API-Server |
| SNI `issuer.wif.local`, `Host: other.wif.local` | `404` bzw. `421` |

Danach wird das unveränderte JWKS weiter ausgeliefert.

---

## Härtung von `wif-issuer-discovery`

Wer in `wif-issuer-discovery` schreiben darf, kann Tokens fälschen. Der Namespace ist deshalb so
geschützt (geprüft mit `demo hardening`, H1–H5):

| Schutz | Umsetzung |
|---|---|
| RBAC | Kein RoleBinding gewährt Rechte in `wif-issuer-discovery`; schreiben dürfen nur Cluster-Admins bzw. der GitOps-Prozess. Weder `wif-demo:consumer` noch `wif-issuer-discovery:issuer-discovery` dürfen ConfigMaps, Pods, HTTPRoutes oder Gateways anlegen, Deployments ändern oder Secrets lesen. |
| Eigenes Gateway | `allowedRoutes: Same` und `allowedListeners: None` (siehe oben): Routen und Listener anderer Namespaces kommen nicht an das Gateway des Issuers. |
| `issuer-host-reserved` | Für `gateways`, `listenersets`, `httproutes`, `grpcroutes` und `tlsroutes` außerhalb von `wif-issuer-discovery`: Jeder Listener nennt einen Hostnamen, und weder Listener noch Routen verwenden `issuer.wif.local` oder eine Wildcard, die ihn abdeckt (`*.wif.local`, `*.local`). So beansprucht kein anderes Gateway den Host. |
| `issuer-discovery-image-digest` | In `wif-issuer-discovery` lässt die Policy Pods, Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs und CronJobs nur zu, wenn jedes Image (auch Init- und Ephemeral-Container) auf `@sha256:<64 hex>` endet. Welches Image es ist, prüft sie nicht. |
| NetworkPolicy | `default-deny` für Ingress und Egress; eingehend nur von Traefik-Pods aus `kube-system` auf 8080 (`issuer-discovery-from-gateway`); ausgehend nur zu `172.31.7.2:6443` (`issuer-discovery-to-api-server`). Die Policies gelten pro Pod: Netzseitig dürfte auch `web` den API-Server erreichen; ihm fehlen nur Token und Konfiguration dafür. |
| Pod Security | Namespace-Label `pod-security.kubernetes.io/enforce: restricted`; Container wie unter [Pod-Härtung](#pod-härtung). |

Beide Policies haben `failurePolicy: Fail` und Binding mit `validationActions: ["Deny"]`.

**Warum Hostname-Pflicht?** Ein Listener ohne Hostname nimmt jeden Host an, also auch
`issuer.wif.local`. `demo hardening` (H1) prüft:

- das Gateway `issuer-discovery` meldet `Programmed`;
- per `kubectl apply --dry-run=server` abgelehnt: Gateway-Listener in `wif-demo` für
  `issuer.wif.local`, `*.wif.local`, `*.local` und ohne Hostname, HTTPRoute für
  `issuer.wif.local` und `*.wif.local`; zugelassen: Gateway-Listener für `other.wif.local`;
- eine echte HTTPRoute aus `wif-demo` am Gateway des Issuers bekommt
  `NotAllowedByListeners`, das JWKS bleibt unverändert;
- Traefik liest `kubernetesgateway`, aber weder `kubernetesingress` noch `kubernetescrd`.

**Grenzen:**

- Die Härtung greift erst nach `bootstrap`. k3s installiert Traefik beim Start mit den
  Standardwerten; Traefik-Konfiguration und Admission Policies kommen mit `bootstrap`.
- Traefik bleibt im Vertrauenspfad: Er hält das Serverzertifikat und entscheidet über das
  Routing. Er teilt sich außerdem einen Zertifikatsspeicher mit allen Gateways; ein
  Zertifikat für `issuer.wif.local` aus einem anderen Namespace kann die Auswahl stören. Die
  Echtheit bleibt gewahrt, weil die Relying Parties nur der internen CA vertrauen, die
  Verfügbarkeit nicht.
- Traefik → Pod ist HTTP ohne TLS (`BackendTLSPolicy` nicht genutzt).
- Die Plausibilitätsprüfung in `sync` sucht per `grep` (kein `jq` im Image). Sie fängt
  Fehler ab, keine Angriffe; die Quelle ist der API-Server über TLS mit dessen CA.

Siehe [ADR 0005](../adr/0005-discovery-pod-im-cluster-pull-ueber-ingress.md) und
[ADR 0006](../adr/0006-gateway-api-statt-ingress.md), Kompromisse.

---

## Verhalten bei Fehlern

| Situation | Verhalten | Geprüft mit |
|---|---|---|
| API-Server nicht erreichbar | `sync` loggt den Fehler und behält den letzten gültigen Stand; beide Pods bleiben bereit, das JWKS bleibt unverändert. | `demo resilience`, R1 (Egress-Policy geleert) |
| Implausibler Stand (z. B. falscher `issuer`) | `REJECTED state`; ein neuer Pod wird nie bereit, die bisherigen liefern weiter aus. | `demo resilience`, R2 (`EXPECTED_ISSUER` verfälscht) |
| Leeres JWKS vom API-Server | wird nicht übernommen; nie ein leeres JWKS ausgeliefert. | Plausibilitätsprüfung |
| Neustart des API-Servers | Im Lab startet `docker compose restart server` den ganzen Knoten neu, also auch die Discovery-Pods; sie werden erst nach dem ersten Abgleich wieder bereit. In einem echten Cluster laufen sie weiter. | `demo post-rotation` (`await_issuer`) |
| Gateway kurz nicht erreichbar | Validator und Keycloak arbeiten mit ihrem Schlüssel-Cache weiter; auffällig nur, wenn genau dann eine neue `kid` auftaucht. | – |

Neue und weggefallene `kid`s erscheinen nur im Log von `sync`. Ob sie zu einem geplanten
Schlüsselwechsel gehören, muss ein Monitoring außerhalb entscheiden.

---

## Weiterlesen

- [architecture.md](architecture.md) – der ganze Stack, Netze und Startreihenfolge
- [trust-und-tls.md](trust-und-tls.md) – SAN, Hostname-Verification, strict SNI, interne CA
- [validator.md](validator.md) – wie der Validator die Metadaten benutzt
- [autorisierungsserver.md](autorisierungsserver.md) – Keycloaks Schlüssel-Cache
- [build-und-betrieb.md](build-und-betrieb.md) – das `tools/`-Image, Schlüsselwechsel, häufige Probleme
- [../kubernetes-primer.md](../kubernetes-primer.md) – ServiceAccount, RBAC, Secret, projiziertes Token
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
