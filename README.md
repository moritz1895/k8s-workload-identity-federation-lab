# k8s-workload-identity-federation-lab

Ein lauffähiges Labor für **Workload Identity Federation**: Ein Pod in einem
Kubernetes-Cluster bekommt ein kurzlebiges, audience-gebundenes ServiceAccount-Token (ein
JWT) und weist sich damit gegenüber einem Dienst **außerhalb** des Clusters aus. Dieser Dienst
prüft das Token **offline** — Signatur gegen die veröffentlichte JWKS des Ausstellers plus
`iss`, `aud`, `exp` — und ruft dafür nie den Kubernetes-API-Server.

Cluster, Issuer-Endpoint und Validator liegen in getrennten Vertrauens- und Netzbereichen:
Ein **Discovery-Pod im Cluster** spiegelt Discovery-Dokument und JWKS des API-Servers und
liefert sie über einen **Ingress** nur lesend aus. Validator und Keycloak holen sie dort ab
und erreichen nur diese Route, nicht den API-Server. Sie vertrauen nur dem Root-Zertifikat
einer **internen PKI** (im Lab eine Lab-CA). Es gibt weder ein Client-Zertifikat noch einen
Schreibweg für die Schlüssel. Begründung:
[ADR 0005](docs/adr/0005-discovery-pod-im-cluster-pull-ueber-ingress.md) (Veröffentlichung) und
[ADR 0003](docs/adr/0003-getrennte-vertrauensbereiche-interne-pki.md) (PKI, Netze).

Darauf aufbauend trennt das Lab **Authentisierung von Autorisierung**: Ein Keycloak als
Autorisierungsserver des Fachbereichs nimmt das ServiceAccount-Token als Client-Nachweis an
und stellt Access-Tokens mit Scopes aus; der Ressourcendienst `service-r` schützt seine
Endpunkte nach Scope. Begründung:
[ADR 0004](docs/adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md), Ablauf:
[Feature-Spezifikation](docs/features/keycloak-autorisierungsserver.md).

Alles läuft in Containern. Auf dem Host wird **nur Docker + Compose v2** gebraucht.

```bash
cp .env.example .env
docker compose up -d --build          # PKI, k3s + Traefik, Discovery-Pod, ingress-lb, Validator, Keycloak + Gateway, service-r
docker compose run --rm demo          # Ende-zu-Ende-Verifikation (Validator)
docker compose run --rm demo authz    # Autorisierungsserver + service-r
tools/run-all-checks.sh               # alles: Demos, Härtung, Ausfall des API-Servers, Netztrennung, fremde CA, Schlüsselwechsel
docker compose down -v                # alles wieder entfernen
```

Schlüsselwechsel in zwei Phasen (`run-all-checks.sh` führt beide aus):

```bash
docker compose run --rm sa-keys stage      # Phase 1: neuer Schlüssel vorab veröffentlicht, signiert noch nicht
docker compose restart server              # API-Server liest die Schlüsseldateien neu
# warten, bis https://issuer.wif.local/openid/v1/jwks die neue kid enthält
docker compose run --rm sa-keys activate   # Phase 2: neuer Schlüssel signiert
docker compose restart server
```

Vom Host erreichbar (nur HTTPS): Validator `https://localhost:18080`, `service-r` `https://localhost:18081`
(Zertifikat der Lab-CA, z. B. `curl --cacert <lab-ca>`).
Die Keycloak-Admin-Konsole läuft nur bei Bedarf über einen eigenen Proxy, weil ein
veröffentlichter Docker-Port auch aus dem Workload-Netz erreichbar ist:

```bash
docker compose --profile admin up -d keycloak-admin   # https://localhost:18443/admin/ (Lab-CA, KC_BOOTSTRAP_ADMIN_*)
docker compose stop keycloak-admin
```

```
 cluster-net (172.31.7.0/24)
 ┌──────────────────────────────────────────┐
 │ server (k3s), API-Server nur hier        │
 │  stellt Tokens aus                       │
 │  ┌ Namespace wif-issuer-discovery ───────────────┐ │
 │  │ Pod issuer: sync ── GET ─► API-Server│ │
 │  │             web (nur GET)  ◄─┐       │ │
 │  └──────────────────────────────┼──────┘ │
 │  Traefik (Ingress issuer.wif.local) ─┘   │
 │   Node-Port 30443, nur in cluster-net    │
 │  Pod consumer                            │
 └────┬───────────────────────────▲─────────┘
      │                           │ TCP 443 durchgereicht (TLS endet im Cluster)
      │                      ingress-lb (Stellvertreter des Load Balancers)
      │                           ▲
      │                           │ GET Discovery + JWKS, relying-net (172.31.8.0/24)
      │ Bearer-Token, GET /whoami │
      │ workload-net              │
      │ (172.31.9.0/24)           │
      └──────────────────►  validator (Spring Boot), vertraut nur der internen CA

 Der Validator erreicht vom Cluster nur die Ingress-Route über ingress-lb, nie den
 API-Server; kein Volume ist zwischen Cluster-Seite und Validator geteilt.
```

Keycloak hängt nur in `relying-net` und lädt dort die Cluster-Schlüssel von
`https://issuer.wif.local`.
Pods erreichen ihn ausschließlich über `keycloak-gateway` (nginx in `workload-net`), das nur
die Endpunkte des Realms `domain-rst` weiterleitet. `service-r` hängt in `relying-net`
(Realm-Schlüssel von Keycloak) und `workload-net` (Aufrufe der Pods). Topologie:
[docs/technical/autorisierungsserver.md](docs/technical/autorisierungsserver.md).

## Konfiguration

`.env.example` nach `.env` kopieren; `docker compose` liest sie automatisch. Keiner der Werte
ist ein echtes Geheimnis.

| Variable | Standard | Bedeutung |
|---|---|---|
| `K3S_TOKEN` | `lab-not-a-secret-change-me` | Beitrittsgeheimnis des k3s-Single-Node-Clusters. |
| `K3S_IMAGE` | `rancher/k3s:v1.34.11-k3s1` | Gepinntes k3s-Image. |
| `WIF_ISSUER` | `https://issuer.wif.local` | Issuer, den der Validator erwartet; Basis der OIDC-Discovery. |
| `WIF_AUDIENCE` | `wif-demo-validator` | Audienz, die der Validator verlangt. |
| `VALIDATOR_HOST_PORT` | `18080` | Host-Port (`127.0.0.1`) des HTTPS-Ports 8443 des Validators (`https://localhost:18080`). |
| `NGINX_IMAGE` | `nginx:1.29-alpine` | Gepinntes nginx-Image für `ingress-lb`, `keycloak-gateway` und `keycloak-admin`. |
| `KEYCLOAK_IMAGE` | `quay.io/keycloak/keycloak:26.8.2` | Gepinntes Keycloak-Image. |
| `KC_BOOTSTRAP_ADMIN_USERNAME` | `admin` | Lab-Admin der Keycloak-Admin-Konsole. |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | `lab-not-a-secret-change-me` | Passwort dazu (nur Lab). |
| `KEYCLOAK_HOST_PORT` | `18443` | Host-Port (`127.0.0.1`) des Admin-Proxys `keycloak-admin`; geht in `KC_HOSTNAME_ADMIN=https://localhost:<port>` ein. |
| `KC_REALM_ISSUER` | `https://keycloak:8443/realms/domain-rst` | Realm-Issuer: Audienz des `kc-token`, erwarteter `iss` in `service-r` und in `demo`. |
| `SERVICE_R_AUDIENCE` | `service-r` | Audienz, die `service-r` im Access-Token verlangt. |
| `SERVICE_R_HOST_PORT` | `18081` | Host-Port (`127.0.0.1`) des HTTPS-Ports von `service-r` (`https://localhost:18081`). |

Weitere Laufzeitvariablen (`WIF_ISSUER_CA`, `VALIDATOR_TLS_DIR`, `SERVICE_R_TRUST_CA`, `SERVICE_R_TLS_DIR`, `JAVA_OPTS`, `DEMO_EXPIRY`,
`VALIDATOR_URL`): [docs/technical/build-und-betrieb.md](docs/technical/build-und-betrieb.md#umgebungsvariablen-env--envexample).

## Dokumentation

Die ausführliche Erklärung — von den Grundbegriffen bis zur Implementierung, geschrieben für
jemanden ohne Kubernetes-Vorwissen — steht in **[`docs/`](docs/README.md)**.

Schnelleinstieg: **[docs/walkthrough.md](docs/walkthrough.md)** (geführte Tour mit echten
Log-Ausgaben).

## Was außerhalb eines Labors anders sein muss

Die Grundsatzentscheidungen stehen in den ADRs
([0001](docs/adr/0001-offline-jwks-statt-tokenreview.md),
[0002](docs/adr/0002-eigenstaendiger-issuer-endpoint.md),
[0003](docs/adr/0003-getrennte-vertrauensbereiche-interne-pki.md),
[0004](docs/adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md),
[0005](docs/adr/0005-discovery-pod-im-cluster-pull-ueber-ingress.md)), die Abwägung offline
vs. online in [docs/domain.md](docs/domain.md#5-offline-validierung-jwks-vs-online-validierung-tokenreview).
Bewusst offene Punkte des Labs:

- **Lab-CA statt interner PKI.** `pki-init` erzeugt CA und Zertifikate selbst; real kommt
  das Root-Zertifikat aus der vorhandenen PKI, das Serverzertifikat des Ingress über
  cert-manager oder die PKI-Anbindung der Plattform statt über `bootstrap`.
- **`ingress-lb` statt echtem Load Balancer.** Ein nginx im TCP-Modus reicht nur Port 443
  an Traefiks Node-Port weiter.
- **Der Namespace `wif-issuer-discovery` gehört zur Steuerung des Clusters.** Wer dort schreiben oder
  Traefik steuern kann, kann Tokens fälschen. RBAC, Admission-Regeln, NetworkPolicies und
  gehärtete Pods erschweren das, schützen aber nicht vor einem Cluster-Admin.
- **JWKS nicht zusätzlich signiert.** Gegen einen kompromittierten Ingress-Controller
  schützt nur eine Signatur mit einem zweiten Vertrauensanker bei den Relying Parties.
- **Überwachung nur über Logs.** Der Discovery-Pod protokolliert jede neue und entfallene
  `kid`; ob sie zu einer geplanten Rotation gehört, entscheidet das Monitoring außerhalb.
- **Rotationsfenster.** Zwischen zwei `sa-keys activate` muss mindestens die maximale
  Token-Laufzeit plus die Cache-Zeit der Relying Parties liegen (Validator 5 min,
  Keycloak lädt bei unbekannter `kid` neu, frühestens 10 s nach dem letzten Abruf).
- **Rotation braucht einen Neustart des API-Servers**, weil kube-apiserver die
  Schlüsseldateien nur beim Start liest. Im Lab startet dabei der ganze Knoten neu, also
  auch die Discovery-Pods.
- **Kein Zertifikatswechsel, keine Sperrlisten.** Die Lab-Zertifikate laufen 825 Tage und
  werden nicht erneuert.
- **`privileged`-k3s, Dummy-`K3S_TOKEN`, ein Node** — reine Lab-Vereinfachungen.
- **Keycloak als Einzelknoten mit Datei-Datenbank im Container** (`KC_DB=dev-file`). Der
  Realm wird per JSON-Import nur einmal angelegt; real schreibt ihn ausschließlich
  keycloak-config-cli oder Terraform aus der CI, mit Drift-Erkennung und extern
  gespeicherten Admin-Events.
- **TLS nur einseitig.** Alle Dienste außerhalb des Clusters sprechen TLS mit Zertifikaten der
  internen PKI; real kommen mTLS oder sender-gebundene Tokens (z. B. DPoP) als Option dazu.
- **Cluster-RBAC ist Teil der Autorisierung.** Wer Tokens für einen ServiceAccount anfordern
  oder Pods mit dessen `serviceAccountName` anlegen darf, bekommt dessen Scopes.

## Projektstruktur

```
compose.yaml                     alle Services, die drei Netze cluster-net / relying-net / workload-net
manifests/                       Namespaces, Traefik-Konfiguration, Admission-Regeln, Discovery-Pod (SA, RBAC,
                                 Deployment, Ingress, NetworkPolicies), Consumer-Deployment,
                                 reader/stranger + Token-Skript access-token.sh
validator/                       Spring Boot 4 / Java 25, Nimbus JOSE — der Offline-Prüfdienst
keycloak/                        Realm-Import des Fachbereichs (realm-domain-rst.json)
service-r/                       Spring Boot 4 / Java 25, Spring Security Resource Server — Dienst R
tools/                           pki-init.sh, sa-keys.sh, bootstrap.sh, nginx-ingress-lb.conf,
                                 nginx-keycloak-gateway.conf, nginx-keycloak-admin.conf,
                                 demo.sh, run-all-checks.sh
docs/                            die vollständige Dokumentation
```

`CLAUDE.md` hält fest, wo dieser PoC bewusst von den übergreifenden Projektstandards abweicht.

## Lizenz & Status

Dieses Projekt ist **proprietär** — siehe [LICENSE](LICENSE). Es ist bewusst **nicht**
quelloffen lizenziert.

Aktueller Stand: private Vorarbeit von Moritz Rohde, für Sichtung und fachliche Abstimmung.
Zugriff bedeutet kein Weitergaberecht; über eine weitergehende Nutzung oder eine
Veröffentlichung entscheidet der Autor.
