# k8s-workload-identity-federation-lab

Ein lauffähiges Labor für **Workload Identity Federation**: Ein Pod in einem
Kubernetes-Cluster bekommt ein kurzlebiges, audience-gebundenes ServiceAccount-Token (ein
JWT) und weist sich damit gegenüber einem Dienst **außerhalb** des Clusters aus. Dieser Dienst
prüft das Token **offline** — Signatur gegen die veröffentlichte JWKS des Ausstellers plus
`iss`, `aud`, `exp` — und ruft dafür nie den Kubernetes-API-Server.

Cluster, Issuer-Endpoint und Validator liegen in getrennten Vertrauens- und Netzbereichen:
Ein Publisher im Cluster lädt Discovery-Dokument und JWKS per **mTLS** zum Issuer-Endpoint
hoch, der Validator vertraut nur dem Root-Zertifikat einer **internen PKI** (im Lab eine
Lab-CA). Begründung: [ADR 0003](docs/adr/0003-getrennte-vertrauensbereiche-interne-pki.md).

Darauf aufbauend trennt das Lab **Authentisierung von Autorisierung**: Ein Keycloak als
Autorisierungsserver des Fachbereichs nimmt das ServiceAccount-Token als Client-Nachweis an
und stellt Access-Tokens mit Scopes aus; der Ressourcendienst `service-r` schützt seine
Endpunkte nach Scope. Begründung:
[ADR 0004](docs/adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md), Ablauf:
[Feature-Spezifikation](docs/features/keycloak-autorisierungsserver.md).

Alles läuft in Containern. Auf dem Host wird **nur Docker + Compose v2** gebraucht.

```bash
cp .env.example .env
docker compose up -d --build          # PKI, k3s, Publisher, Issuer-Endpoint, Validator, Keycloak + Gateway, service-r
docker compose run --rm demo          # Ende-zu-Ende-Verifikation (Validator)
docker compose run --rm demo authz    # Autorisierungsserver + service-r
tools/run-all-checks.sh               # alles: Demos, Netztrennung, fremde CA, Schlüsselrotation
docker compose down -v                # alles wieder entfernen
```

Vom Host erreichbar: Validator `http://localhost:18080`, `service-r` `http://127.0.0.1:18081`.
Die Keycloak-Admin-Konsole läuft nur bei Bedarf über einen eigenen Proxy, weil ein
veröffentlichter Docker-Port auch aus dem Workload-Netz erreichbar ist:

```bash
docker compose --profile admin up -d keycloak-admin   # https://localhost:18443/admin/ (Lab-CA, KC_BOOTSTRAP_ADMIN_*)
docker compose stop keycloak-admin
```

```
 cluster-net (172.31.7.0/24)
 ┌──────────────────────────────┐
 │ server (k3s)                 │      PUT, mTLS (CN=jwks-publisher)
 │  stellt Tokens aus           │
 │  Pod jwks-publisher ─────────┼──────────────────────────────►  issuer-web :8443
 │  Pod consumer                │                                 (nginx, Zertifikat
 └────┬─────────────────────────┘                                  der internen CA)
      │                                                           issuer-web :443
      │ Bearer-Token, GET /whoami                                       ▲
      │ workload-net (172.31.9.0/24)                                    │ GET Discovery + JWKS
      │                                                                 │ relying-net (172.31.8.0/24)
      └──────────────────────────────────────────────────►  validator (Spring Boot)
                                                             vertraut nur der internen CA

 Der Validator erreicht den API-Server über kein Netz; kein Volume ist zwischen
 Cluster-Seite und Validator geteilt.
```

Keycloak hängt nur in `relying-net` und lädt dort die Cluster-Schlüssel von `issuer-web`.
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
| `WIF_ISSUER` | `https://issuer-web` | Issuer, den der Validator erwartet; Basis der OIDC-Discovery. |
| `WIF_AUDIENCE` | `wif-demo-validator` | Audienz, die der Validator verlangt. |
| `VALIDATOR_HOST_PORT` | `18080` | Host-Port des Validators. |
| `NGINX_IMAGE` | `nginx:1.29-alpine` | Gepinntes nginx-Image für `issuer-web`. |
| `KEYCLOAK_IMAGE` | `quay.io/keycloak/keycloak:26.8.2` | Gepinntes Keycloak-Image. |
| `KC_BOOTSTRAP_ADMIN_USERNAME` | `admin` | Lab-Admin der Keycloak-Admin-Konsole. |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | `lab-not-a-secret-change-me` | Passwort dazu (nur Lab). |
| `KEYCLOAK_HOST_PORT` | `18443` | Host-Port (`127.0.0.1`) des Admin-Proxys `keycloak-admin`; geht in `KC_HOSTNAME_ADMIN=https://localhost:<port>` ein. |
| `KC_REALM_ISSUER` | `https://keycloak:8443/realms/domain-rst` | Realm-Issuer: Audienz des `kc-token`, erwarteter `iss` in `service-r` und in `demo`. |
| `SERVICE_R_AUDIENCE` | `service-r` | Audienz, die `service-r` im Access-Token verlangt. |
| `SERVICE_R_HOST_PORT` | `18081` | Host-Port (`127.0.0.1`) von `service-r`. |

Weitere Laufzeitvariablen (`WIF_ISSUER_CA`, `SERVICE_R_TRUST_CA`, `JAVA_OPTS`, `DEMO_EXPIRY`,
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
[0004](docs/adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md)), die Abwägung offline
vs. online in [docs/domain.md](docs/domain.md#5-offline-validierung-jwks-vs-online-validierung-tokenreview).
Bewusst offene Punkte des Labs:

- **Lab-CA statt interner PKI.** `pki-init` erzeugt CA und Zertifikate selbst; real kommt
  das Root-Zertifikat aus der vorhandenen PKI, das Publisher-Zertifikat über cert-manager oder
  die PKI-Anbindung der Plattform statt über `bootstrap`.
- **Keine inhaltliche Prüfung beim Upload.** `issuer-web` prüft weder `issuer` noch die
  Schlüssel. Wer das Publisher-Zertifikat besitzt, kann jedes JWKS hochladen.
- **JWKS nicht zusätzlich signiert.** Gegen einen kompromittierten `issuer-web`-Host schützt
  nur eine Signatur mit einem zweiten Vertrauensanker beim Validator.
- **Überwachung nur über Logs.** Publisher und nginx protokollieren jede Änderung; ein Alarm
  bei einem neuen `kid` außerhalb einer geplanten Rotation fehlt.
- **Rotationsfenster.** Der alte Schlüssel muss mindestens maximale Token-Laufzeit plus
  JWKS-Cache-TTL des Validators (5 min) im JWKS bleiben. Im Lab bleibt er bis zur nächsten
  Rotation — sicher nur, solange zwischen zwei Rotationen mehr als diese Zeit liegt.
- **Rotation braucht einen Neustart des API-Servers**, weil kube-apiserver die
  Schlüsseldateien nur beim Start liest.
- **Kein Zertifikatswechsel, keine Sperrlisten.** Die Lab-Zertifikate laufen 825 Tage und
  werden nicht erneuert.
- **`privileged`-k3s, Dummy-`K3S_TOKEN`, ein Node** — reine Lab-Vereinfachungen.
- **Keycloak als Einzelknoten mit Datei-Datenbank im Container** (`KC_DB=dev-file`). Der
  Realm wird per JSON-Import nur einmal angelegt; real schreibt ihn ausschließlich
  keycloak-config-cli oder Terraform aus der CI, mit Drift-Erkennung und extern
  gespeicherten Admin-Events.
- **HTTP zwischen Workloads und `service-r` / Validator.** Real TLS oder mTLS (z. B. Service
  Mesh), optional sender-gebundene Tokens (DPoP, mTLS).
- **Cluster-RBAC ist Teil der Autorisierung.** Wer Tokens für einen ServiceAccount anfordern
  oder Pods mit dessen `serviceAccountName` anlegen darf, bekommt dessen Scopes.

## Projektstruktur

```
compose.yaml                     alle Services, die drei Netze cluster-net / relying-net / workload-net
manifests/                       Namespaces, jwks-publisher (SA, RBAC, Deployment), Consumer-Deployment,
                                 reader/stranger + Token-Skript access-token.sh
validator/                       Spring Boot 4 / Java 25, Nimbus JOSE — der Offline-Prüfdienst
keycloak/                        Realm-Import des Fachbereichs (realm-domain-rst.json)
service-r/                       Spring Boot 4 / Java 25, Spring Security Resource Server — Dienst R
tools/                           pki-init.sh, sa-keys.sh, bootstrap.sh, nginx-issuer.conf,
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
