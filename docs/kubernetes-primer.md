# Kubernetes-Primer: nur die Bausteine, die dieser PoC benutzt

## Für wen ist das / was lernst du hier

Diese Seite erklärt **genau die** Kubernetes-Bausteine, die in diesem Lab vorkommen - nicht
mehr. Für jeden Baustein steht hier: was es ist, wozu es da ist und wo genau es in diesem
PoC auftaucht (mit Verweis auf die Datei). Wenn du Kubernetes praktisch noch nie benutzt
hast, ist das der richtige Einstieg. Danach ergibt [use-cases.md](use-cases.md) den vollen
Ablauf.

Ein Hinweis vorweg: Kubernetes-Objekte werden als **Manifeste** beschrieben - YAML-Dateien,
die den *gewünschten Zustand* festlegen ("es soll ein Deployment mit diesem Namen geben").
Kubernetes sorgt dann dafür, dass die Wirklichkeit diesem Zustand entspricht. Die Manifeste
dieses Labs liegen im Ordner [`manifests/`](../manifests/).

---

## Cluster und Node

**Was:** Ein **Cluster** ist ein Verbund von Rechnern, den Kubernetes gemeinsam verwaltet.
Jeder einzelne Rechner darin heißt **Node**. Nodes stellen CPU, RAM und Netzwerk bereit;
auf ihnen laufen die Container.

**Wozu:** Der Cluster ist die Plattform. Anwendungen sagen "ich brauche 3 Instanzen dieses
Containers", und Kubernetes verteilt sie auf die verfügbaren Nodes, startet sie neu, wenn
sie abstürzen, usw.

**In diesem PoC:** Es gibt genau **einen** Node. Der komplette Cluster - Steuerungsebene und
Node in einem - läuft als ein einziger Docker-Container namens `server`, siehe
[`compose.yaml`](../compose.yaml) (Service `server`, Image `rancher/k3s`).

### k3s in einem Satz

**k3s** ist eine besonders schlanke, in einer einzelnen ausführbaren Datei gebündelte
Kubernetes-Distribution, mit der sich hier der ganze Cluster als **ein Container** betreiben
lässt - ideal für ein Lab, ohne dass auf dem Host irgendetwas außer Docker installiert sein
muss. k3s bringt den Ingress-Controller Traefik mit (siehe [Ingress](#service-und-ingress)).

In [`compose.yaml`](../compose.yaml) wird k3s mit ein paar Extras gestartet:

| Startparameter | Bedeutung |
|---|---|
| `--disable=servicelb`, `--disable=metrics-server` | Schaltet mitgelieferte Zusatzkomponenten ab, die dieses Lab nicht braucht. |
| `--kube-apiserver-arg=service-account-issuer=https://issuer.wif.local` | Legt fest, welche URL als `iss`-Claim in jedes ausgestellte ServiceAccount-Token geschrieben wird. |
| `--kube-apiserver-arg=service-account-jwks-uri=https://issuer.wif.local/openid/v1/jwks` | Legt fest, welche `jwks_uri` im Discovery-Dokument des Clusters steht. |
| `--kube-apiserver-arg=service-account-signing-key-file=/sa-keys/signing.key` | Der private Schlüssel, mit dem der API-Server Tokens signiert (erzeugt von `sa-keys`). |
| `--kube-apiserver-arg=service-account-key-file=/sa-keys/verify.pub` | Die öffentlichen Schlüssel, mit denen Tokens geprüft werden - und die im JWKS erscheinen. Hier stehen der aktuelle Schlüssel und, je nach Phase des Schlüsselwechsels, ein vorbereiteter und der vorherige. |
| `--bind-address=172.31.7.2`, `--node-ip=172.31.7.2`, `--advertise-address=172.31.7.2` | Der API-Server lauscht nur auf seiner Adresse im Netz `cluster-net`; aus den anderen Netzen ist er nicht erreichbar. |
| `--kube-proxy-arg=nodeport-addresses=172.31.7.0/24` | Node-Ports (hier Traefiks `30443`) sind ebenfalls nur auf der Adresse in `cluster-net` offen. |
| `--tls-san=k3s-server` | Trägt den Namen `k3s-server` ins Serverzertifikat des API-Servers ein, damit `kubectl` aus `bootstrap` und `demo` ihn unter diesem Namen erreicht. |

Der Cluster verweist mit `service-account-issuer` und `service-account-jwks-uri` also **auf
den Issuer-Endpoint hinter dem Ingress**, nicht auf den API-Server selbst. kube-apiserver
liest die Schlüsseldateien nur beim Start; jede Phase eines Schlüsselwechsels braucht
deshalb einen Neustart von `server`.

---

## Namespace

**Was:** Ein **Namespace** ist ein benannter Bereich innerhalb des Clusters, in dem Objekte
gruppiert werden. Objekte in verschiedenen Namespaces können den gleichen Namen tragen, ohne
sich in die Quere zu kommen.

**Wozu:** Trennung. Verschiedene Teams, Umgebungen oder Anwendungen bekommen eigene
Namespaces. Rechte (RBAC) und Regeln (NetworkPolicies, Admission-Regeln, Pod Security)
lassen sich pro Namespace vergeben.

**In diesem PoC:** Zwei Namespaces, angelegt in
[`manifests/00-namespace.yaml`](../manifests/00-namespace.yaml): `wif-demo` für die
Workloads `consumer`, `reader` und `stranger` - deshalb enthält der `sub`-Claim ihrer
Tokens den Namespace, z. B. `system:serviceaccount:wif-demo:consumer` - und `wif-issuer`
für den Issuer-Pod. `wif-issuer` trägt das Label
`pod-security.kubernetes.io/enforce: restricted` (siehe [Pod-Härtung](#pod-härtung-und-readiness)).

---

## Pod und Deployment

**Was ist ein Pod:** Die kleinste Einheit, die Kubernetes ausführt - ein oder mehrere
Container, die sich Netzwerk und Speicher teilen und immer zusammen auf demselben Node
laufen. Ein Pod ist **vergänglich**: Stirbt er, wird nicht *dieser* Pod wiederbelebt,
sondern ein neuer erstellt (mit neuem Namen).

**Was ist ein Deployment:** Ein Objekt, das eine gewünschte Anzahl gleicher Pods am Leben
hält. Du beschreibst einmal die Pod-Vorlage ("template") und sagst `replicas: 1`; das
Deployment sorgt dafür, dass immer ein passender Pod läuft, und ersetzt ihn bei Absturz oder
Update.

**Wozu:** Du willst nicht einzelne Pods von Hand verwalten. Das Deployment ist die
selbstheilende Hülle darum.

**In diesem PoC:** [`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml) definiert
ein Deployment `consumer` mit `replicas: 1`. Der Pod enthält nur ein `curl`-Image
(`curlimages/curl`), dessen Kommando `sleep infinity` ist - der Container tut also nichts
von selbst, er wartet nur. Die eigentliche Anfrage an den Validator wird von außen per
`kubectl exec` ausgelöst (durch [`tools/demo.sh`](../tools/demo.sh)). Der Pod ist hier
schlicht der Ort, an dem das projizierte Token liegt.

Das Deployment `issuer` in [`manifests/10-issuer.yaml`](../manifests/10-issuer.yaml) läuft
mit `replicas: 2`. Jeder Pod hat zwei Container, die sich ein `emptyDir` (ein leeres
Verzeichnis, das so lange lebt wie der Pod) teilen: `sync` (`curlimages/curl`, Skript aus
der ConfigMap `issuer-sync`) liest alle 15 Sekunden Discovery-Dokument und JWKS vom
API-Server und schreibt einen plausiblen Stand dorthin; `web`
(`nginxinc/nginx-unprivileged`) liefert ihn nur per `GET` aus. Ein Rollout ersetzt Pods
erst, wenn der neue bereit ist (`maxUnavailable: 0`).

---

## Secret und ConfigMap

**Was:** Eine **ConfigMap** hält Konfigurationsdaten (Dateien, Werte), ein **Secret** dasselbe
für vertrauliche Daten (Schlüssel, Passwörter). Beide lassen sich als Dateien in einen Pod
einhängen.

**In diesem PoC:** `bootstrap` legt in `wif-issuer` das Secret `issuer-tls`
(Serverzertifikat und Schlüssel für `issuer.wif.local`, das der Ingress verwendet) und in
`wif-demo` die ConfigMap `internal-ca` (Root-Zertifikat der internen CA, im Pod unter
`/etc/internal-ca`) an. In einem echten Cluster liefert diese cert-manager oder die
PKI-Anbindung der Plattform. Das Skript von `sync` und die nginx-Konfiguration von `web`
liegen ebenfalls in ConfigMaps.

---

## ServiceAccount

**Was:** Eine **Identität für Software innerhalb des Clusters**. Kein Mensch, kein Passwort -
ein benanntes Konto, das ein Pod "trägt". Jeder Namespace hat einen `default`-ServiceAccount;
meist legt man eigene an.

**Wozu:** Damit der Cluster (und externe Systeme) wissen, *als wer* ein Pod handelt. Der
`sub`-Claim eines ausgestellten Tokens ist der Name des ServiceAccounts in der Form
`system:serviceaccount:<namespace>:<name>`.

**In diesem PoC:** [`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml) legt einen
ServiceAccount `consumer` an. Das Deployment referenziert ihn mit
`serviceAccountName: consumer`. Auffällig: `automountServiceAccountToken: false`. Das schaltet
das *automatische* Standard-Token ab - der Pod bekommt **nur** die ausdrücklich per
`projected` Volume angeforderten Tokens (siehe unten), nichts sonst. Genauso beim
ServiceAccount `issuer`: Dort bekommt nur der Container `sync` ein Token für den
API-Server, `web` keines.

---

## Das kubelet

**Was:** Auf jedem Node läuft ein Agent namens **kubelet**. Er nimmt vom API-Server
entgegen, welche Pods auf "seinem" Node laufen sollen, startet die zugehörigen Container und
überwacht sie.

**Wozu:** Das kubelet ist das Bindeglied zwischen der Cluster-Steuerung und den echten
Containern auf dem Node. Für dieses Lab wichtig: Das kubelet ist es, das die **ServiceAccount-
Tokens für die Pods anfordert** - über die TokenRequest-API - und sie rechtzeitig vor Ablauf
erneuert.

**In diesem PoC:** Das kubelet steckt im k3s-Container. Du siehst es nicht direkt, aber es
ist der Akteur, der das Token in Schritt 1 des
[Haupt-Use-Case](use-cases.md#use-case-1-workload-authentisiert-sich-gegenüber-externem-dienst)
besorgt und in die Datei `/var/run/secrets/tokens/sa-token` im Pod legt.

---

## Die TokenRequest-API und "bound" / audience-gebundene Tokens

**Was:** Die **TokenRequest-API** ist eine Funktion des API-Servers, über die man ein
kurzlebiges JWT für einen ServiceAccount anfordert. Man gibt dabei an:

- eine oder mehrere **Audiences** (`aud`) - für wen das Token bestimmt ist,
- eine **Laufzeit** (`expirationSeconds`).

Das Ergebnis ist ein **"bound token"**: Es ist nicht nur an den ServiceAccount gebunden,
sondern optional auch an das Objekt, für das es angefordert wurde (z. B. den konkreten Pod),
und an die angegebene Audience. Ein solches Token ist damit:

- **kurzlebig** (Minuten statt Monate),
- **empfängergebunden** - der Validator akzeptiert nur Tokens mit `aud` = `wif-demo-validator`;
  ein für einen anderen Empfänger ausgestelltes Token wird abgelehnt,
- bei Pod-Bindung **automatisch ungültig**, sobald der Pod weg ist (relevant nur für
  Online-Prüfung, nicht für die Offline-Prüfung dieses Labs).

Zwei Wege, wie ein solches Token entsteht:

| Weg | Wer nutzt ihn hier |
|---|---|
| Automatisch über ein `projected` Volume - das kubelet fordert an und erneuert. | Der `consumer`-Pod im laufenden Betrieb. |
| Manuell mit `kubectl create token consumer --audience ... --duration ...`. | [`tools/demo.sh`](../tools/demo.sh), um zusätzlich Tokens mit *falscher* Audience für die Negativtests zu erzeugen. |

**Mindestlaufzeit:** Die TokenRequest-API stellt kein Token mit einer Laufzeit unter
**10 Minuten** (600 Sekunden) aus. Deshalb steht in
[`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml) `expirationSeconds: 600`, und
deshalb braucht der Ablauf-Test in `demo.sh` eine echte Wartezeit von rund 10 Minuten.

**Was steht in so einem Token:** `iss = https://issuer.wif.local`,
`aud = ["wif-demo-validator"]`, `sub = system:serviceaccount:wif-demo:consumer`, dazu `exp`,
`iat`, `nbf` und ein `kubernetes.io`-Claim mit Namespace, Pod- und ServiceAccount-Angaben.

---

## `projected` Volume mit `serviceAccountToken`-Source

**Was ist ein Volume:** Ein Dateisystem, das Kubernetes in einen Container einhängt. Ein
**`projected` Volume** ist ein spezielles Volume, das mehrere Quellen zu einem Verzeichnis
zusammenführt. Eine der möglichen Quellen ist `serviceAccountToken`.

**Was macht die `serviceAccountToken`-Source:** Sie weist das kubelet an, über die
TokenRequest-API ein frisches Token anzufordern und als Datei in den Container zu legen -
und es vor Ablauf immer wieder zu erneuern, ohne dass der Container neu starten muss.

**Die Felder in diesem PoC** ([`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml),
gekürzt auf das Token für den Validator; ein zweites Token `kc-token` ist für Keycloak
bestimmt):

```yaml
volumes:
  - name: tokens
    projected:
      sources:
        - serviceAccountToken:
            audience: wif-demo-validator      # -> landet als aud-Claim im Token
            expirationSeconds: 600            # -> gewünschte Laufzeit (Minimum 600)
            path: sa-token                    # -> Dateiname innerhalb des Volumes
```

und das Einhängen:

```yaml
volumeMounts:
  - name: tokens
    mountPath: /var/run/secrets/tokens       # -> Verzeichnis im Container
    readOnly: true
```

Ergebnis: Im Pod liegt das aktuelle Token unter **`/var/run/secrets/tokens/sa-token`**.
Genau diese Datei liest `demo.sh` per `kubectl exec` aus und schickt ihren Inhalt als
`Authorization: Bearer ...` an den Validator.

| Feld | Wirkung |
|---|---|
| `audience` | Setzt den `aud`-Claim. Muss exakt dem entsprechen, was der Validator erwartet (`WIF_AUDIENCE`). |
| `expirationSeconds` | Gewünschte Token-Laufzeit in Sekunden. Der API-Server erzwingt mindestens 600. Das kubelet erneuert das Token nach etwa 80 % der Laufzeit. |
| `path` | Dateiname des Tokens innerhalb des Volumes. Zusammen mit `mountPath` ergibt sich der volle Pfad im Container. |

---

## RBAC - nur so viel wie hier nötig

**Was:** **RBAC** ("Role-Based Access Control") ist das Rechtesystem von Kubernetes. Es
beantwortet: "Darf *dieser* Nutzer / ServiceAccount *diese* Aktion (`get`, `list`, `create`,
...) auf *diesen* Objekten ausführen?" Rechte bündelt man in einer `Role` (namespace-weit)
oder `ClusterRole` (clusterweit) und weist sie per `RoleBinding` / `ClusterRoleBinding` einem
Subjekt zu.

**In diesem PoC:** Es gibt genau **ein** RBAC-Objekt, die ClusterRoleBinding
`wif-issuer-discovery` in [`manifests/10-issuer.yaml`](../manifests/10-issuer.yaml):

- Der ServiceAccount `issuer` bekommt die eingebaute ClusterRole
  `system:service-account-issuer-discovery`. Sie erlaubt nur `GET` auf
  `/.well-known/openid-configuration` und `/openid/v1/jwks` - genau das, was `sync` liest.
  Keine weiteren Rechte, insbesondere keine im eigenen Namespace.
- Kein RoleBinding gewährt Rechte in `wif-issuer`. Dort schreiben nur Cluster-Admins (im
  echten Betrieb der GitOps-Prozess).
- Der `consumer`-ServiceAccount **braucht keine Rechte**. Der Pod ruft den API-Server
  überhaupt nicht auf - er benutzt sein Token nur, um sich beim *externen* Validator
  auszuweisen.
- Der `bootstrap`-Container benutzt die **Administrator-Kubeconfig**, die k3s beim Start
  erzeugt (Datei `kubeconfig.yaml` im Volume `kubeconfig`). Damit hat er ohnehin volle Rechte
  und braucht keine zusätzliche Rolle.

Der Validator bekommt die Discovery-Metadaten **ohne** jedes Cluster-Recht, weil sie vom
Issuer-Pod hinter dem Ingress ausgeliefert werden und nicht vom API-Server. Die Leserolle
bekommt nur der Issuer-Pod im Cluster, nicht anonyme Aufrufer von außen
([ADR 0002](adr/0002-eigenstaendiger-issuer-endpoint.md),
[ADR 0005](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md)).

---

## Service und Ingress

**Was ist ein Service:** Ein stabiler Name und eine stabile Adresse im Cluster für eine
Gruppe gleichartiger Pods. Wer `issuer.wif-issuer.svc` anspricht, landet bei einem der
bereiten Pods des Deployments `issuer`, egal wie diese gerade heißen.

**Was ist ein Ingress:** Ein Objekt, das beschreibt, unter welchem **Host** und welchem
**Pfad** ein Service von außerhalb des Clusters per HTTP(S) erreichbar ist, und mit welchem
TLS-Zertifikat. Umgesetzt wird das von einem **Ingress-Controller**, einem Reverse Proxy im
Cluster - hier **Traefik**, das k3s mitbringt.

**In diesem PoC:** Der Ingress `issuer` in
[`manifests/10-issuer.yaml`](../manifests/10-issuer.yaml) veröffentlicht unter dem Host
`issuer.wif.local` genau zwei Pfade (`/.well-known/openid-configuration` und
`/openid/v1/jwks`, jeweils `pathType: Exact`) zum Service `issuer`, mit dem Zertifikat aus
dem Secret `issuer-tls`. Traefik ordnet Routen sonst nach der Länge ihrer Regel; die
Annotation `traefik.ingress.kubernetes.io/router.priority: "1000000000"` setzt die
Issuer-Route über jede so abgeleitete Priorität. Traefik ist in
[`manifests/01-traefik-config.yaml`](../manifests/01-traefik-config.yaml) so eingestellt:

- Service vom Typ `NodePort` mit festem Port `30443`, nur der HTTPS-Eingang ist offen.
- Routen kommen nur aus `Ingress`-Objekten; Traefiks eigene Routen-CRDs (`IngressRoute`
  u. a.) und die Gateway API sind abgeschaltet, damit die Admission-Regeln unten jede Route
  erfassen.
- **Strict SNI**: Ein TLS-Handshake für einen Host ohne eigenes Zertifikat schlägt fehl.

Von außen erreicht man Traefik nur über `ingress-lb` (ein nginx im TCP-Modus in Docker
Compose), der Port 443 aus `relying-net` an `172.31.7.2:30443` durchreicht - der
Stellvertreter für den Load Balancer vor den Ingress-Knoten eines echten Clusters.

---

## NetworkPolicy

**Was:** Eine **NetworkPolicy** legt fest, mit wem die Pods eines Namespace auf
Netzwerkebene reden dürfen - eingehend (`Ingress`) und ausgehend (`Egress`). Sobald eine
Policy einen Pod erfasst, ist alles verboten, was nicht ausdrücklich erlaubt ist. k3s setzt
NetworkPolicies selbst durch.

**In diesem PoC** ([`manifests/10-issuer.yaml`](../manifests/10-issuer.yaml)), alle im
Namespace `wif-issuer`:

| Policy | Wirkung |
|---|---|
| `default-deny` | Kein Verkehr rein oder raus, solange keine andere Policy ihn erlaubt. |
| `issuer-from-ingress-controller` | Eingehend nur von den Traefik-Pods in `kube-system`, nur Port 8080. |
| `issuer-to-api-server` | Ausgehend nur zum API-Server (`172.31.7.2:6443`). |

Workloads aus `wif-demo` erreichen den Issuer-Pod also nicht direkt, und der Issuer-Pod
erreicht nichts außer dem API-Server.

---

## Admission-Regeln (`ValidatingAdmissionPolicy`)

**Was:** Bevor der API-Server ein Objekt speichert, kann er es gegen Regeln prüfen und
ablehnen. Eine **`ValidatingAdmissionPolicy`** formuliert eine solche Regel als Ausdruck
(in der Sprache CEL); eine `ValidatingAdmissionPolicyBinding` schaltet sie scharf.

**In diesem PoC** ([`manifests/05-issuer-admission.yaml`](../manifests/05-issuer-admission.yaml)):

- **`issuer-host-reserved`**: Außerhalb von `wif-issuer` muss jede Ingress-Regel einen
  Host nennen, und der darf weder `issuer.wif.local` sein noch ihn per Wildcard abdecken
  (`*.wif.local`, `*.local`) - weder in den Regeln noch im TLS-Abschnitt. Default-Backends
  und Traefik-Router-Annotationen (`traefik.ingress.kubernetes.io/router.*`, etwa Priorität
  oder Pfad-Matcher) sind verboten. Eine Regel ohne Host passt auf jeden Host; zusammen mit
  einer langen Pfad-Regex könnte sie die Issuer-Route überholen und ein anderer Namespace
  die Route auf eigene Pods umbiegen.
- **`issuer-image-digest`**: In `wif-issuer` laufen nur Images mit festem Digest
  (`@sha256:…`), egal ob als Pod, Deployment, Job oder anderes Objekt angelegt.

---

## Pod-Härtung und Readiness

**Was:** Der **Pod Security Standard** `restricted` (per Label am Namespace) lässt nur Pods
zu, die ohne Root laufen, keine Rechteausweitung erlauben und alle Linux-Capabilities
abgeben. Der `securityContext` eines Containers legt das fest. Eine **Readiness-Probe**
fragt regelmäßig, ob ein Container Anfragen annehmen kann; erst dann schickt der Service
ihm Verkehr.

**In diesem PoC:** Beide Container des Issuer-Pods laufen als Nutzer `101`, mit
schreibgeschütztem Root-Dateisystem (`readOnlyRootFilesystem: true`), ohne
`allowPrivilegeEscalation` und mit `capabilities.drop: ["ALL"]`. Die Readiness-Probe von
`web` ruft `/openid/v1/jwks` ab; solange `sync` noch keinen plausiblen Stand abgelegt hat,
antwortet nginx `404`, und der Pod bekommt keinen Verkehr.

---

## Wie Manifeste in den Cluster kommen (und warum über den bootstrap-Container)

**Der normale Weg:** Man ruft `kubectl apply -f <datei>` auf. `kubectl` ist das
Kommandozeilen-Werkzeug, das mit dem API-Server spricht. "Apply" bedeutet: "Sorge dafür,
dass der im Manifest beschriebene Zustand im Cluster existiert" - idempotent, d. h. mehrfach
ausführbar ohne Schaden.

k3s bringt zusätzlich einen **Auto-Deploy-Ordner** mit (`/var/lib/rancher/k3s/server/manifests`):
Alles, was dort liegt, wendet k3s beim Start automatisch an.

**Warum dieser PoC den bootstrap-Container nimmt:** Der Kommentar in
[`tools/bootstrap.sh`](../tools/bootstrap.sh) fasst die Aufgabe zusammen. Der Container
erledigt alles, was *nach* dem Hochfahren des Clusters und von einem Client mit
Cluster-Zugriff passieren muss:

1. die Namespaces anlegen,
2. Secret `issuer-tls` und ConfigMap `internal-ca` aus den Volumes der Lab-PKI anlegen (die
   Dateien liegen außerhalb des Clusters, im Auto-Deploy-Ordner hätte k3s sie nicht),
3. die Lab-Manifeste anwenden (`kubectl apply -f /manifests`) und auf die Rollouts von
   `issuer`, Traefik und den Workloads warten.

Die Auslieferung der Metadaten ist **nicht** seine Aufgabe; die übernimmt der Issuer-Pod im
Cluster. Der `bootstrap`-Service läuft bei jedem `docker compose up` einmal durch und beendet
sich dann (`restart: "no"`); die Aktionen sind idempotent.

---

## `hostAliases`

**Was:** Ein Feld in der Pod-Spezifikation, das feste **Name-zu-IP-Einträge in die Datei
`/etc/hosts`** des Pods schreibt. Damit wird ein Hostname aufgelöst, ohne einen DNS-Server
zu fragen.

**Wozu:** Für Namen, die der normale DNS des Clusters nicht kennt - z. B. etwas außerhalb
des Clusters.

**In diesem PoC** ([`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml), gekürzt):

```yaml
hostAliases:
  - ip: "172.31.9.10"
    hostnames:
      - validator.wif.local
```

Der Validator hat im Docker-Netz `workload-net` die feste IP `172.31.9.10`
([`compose.yaml`](../compose.yaml)). Der Pod ruft ihn unter
`https://validator.wif.local:8443/whoami` auf (TLS mit Zertifikat der internen CA); der
`hostAliases`-Eintrag sorgt dafür, dass dieser Name im Pod auf `172.31.9.10` zeigt. Ebenso
zeigen `keycloak` und `service-r.wif.local` auf die Adressen von `keycloak-gateway` und
`service-r` in `workload-net`.

---

## Warum CoreDNS den externen Validator nicht kennt

**Was ist CoreDNS:** Der DNS-Server, der *innerhalb* eines Kubernetes-Clusters läuft. Er
löst die Namen von Cluster-Objekten auf - vor allem von **Services**. Namen wie
`meine-app.mein-namespace.svc.cluster.local` beantwortet CoreDNS.

**Warum der Validator fehlt:** Der Validator ist **kein Cluster-Objekt**. Er ist ein
separater Docker-Container, von Kubernetes gar nicht verwaltet. CoreDNS hat also keinen
Eintrag für ihn und *kann* keinen haben. Deshalb wird sein Name im Pod über `hostAliases`
fest verdrahtet, statt über DNS aufgelöst zu werden. Das ist im Kleinen genau die Situation
echter Workload Identity Federation: Die Workload redet mit etwas **außerhalb** ihrer
Plattform.

---

## Weiterlesen

- [Use Cases](use-cases.md) - der komplette Ablauf Schritt für Schritt, inklusive Bootstrap und aller Fehlerfälle.
- [Domain / Konzepte](domain.md) - falls du zurück zu den Grundbegriffen willst (Trust Anchor, offline vs. online).
- [ADR 0002](adr/0002-eigenstaendiger-issuer-endpoint.md) - warum die Metadaten von einem eigenen Issuer-Endpoint statt vom API-Server kommen.
- [ADR 0005](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md) - warum ein Pod im Cluster sie hinter einem Ingress ausliefert und wie der Namespace geschützt ist.
