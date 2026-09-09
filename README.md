# k8s-workload-identity-federation-lab

Ein lauffähiges Labor für **Workload Identity Federation**: Ein Pod in einem
Kubernetes-Cluster bekommt ein kurzlebiges, audience-gebundenes ServiceAccount-Token (ein
JWT) und weist sich damit gegenüber einem Dienst **außerhalb** des Clusters aus. Dieser Dienst
prüft das Token **offline** — Signatur gegen die veröffentlichte JWKS des Ausstellers plus
`iss`, `aud`, `exp` — und ruft dafür nie den Kubernetes-API-Server.

Alles läuft in Containern. Auf dem Host wird **nur Docker + Compose v2** gebraucht.

```bash
cp .env.example .env
docker compose up -d --build      # k3s + Issuer-Endpoint + externer Validator
docker compose run --rm demo      # Ende-zu-Ende-Verifikation
docker compose down -v            # alles wieder entfernen
```

```
        ┌──────────── Docker-Netz "wifnet" ─────────────────────────────────┐
        │  server (k3s) ──► bootstrap ──► issuer-web (nginx)                 │
        │  stellt Tokens aus   kopiert    https://issuer-web/.well-known/…   │
        │  ┌───────────────┐   Schlüssel  https://issuer-web/openid/v1/jwks  │
        │  │ Pod "consumer"│   hierher              ▲                        │
        │  └──────┬────────┘                        │ OIDC-Discovery         │
        │         │ Bearer-Token                    │                        │
        │         ▼                                 │                        │
        │  validator (Spring Boot) ─────────────────┘                        │
        │  prüft Signatur + iss + aud + exp   —   spricht NIE mit dem Cluster │
        └───────────────────────────────────────────────────────────────────┘
```

## Dokumentation

Die ausführliche Erklärung — von den Grundbegriffen bis zur Implementierung, geschrieben für
jemanden ohne Kubernetes-Vorwissen — steht in **[`docs/`](docs/README.md)**.

Schnelleinstieg: **[docs/walkthrough.md](docs/walkthrough.md)** (geführte Tour mit echten
Log-Ausgaben).

Was man für „echt statt Labor" anders machen müsste, steht in den ADRs
([0001](docs/adr/0001-offline-jwks-statt-tokenreview.md),
[0002](docs/adr/0002-eigenstaendiger-issuer-endpoint.md)) und in
[docs/domain.md](docs/domain.md#5-offline-validierung-jwks-vs-online-validierung-tokenreview).

## Projektstruktur

```
compose.yaml                     alle Services + das wifnet-Netz
manifests/                       Namespace + Consumer-Deployment mit projiziertem Token-Volume
validator/                       Spring Boot 4 / Java 25, Nimbus JOSE — der Offline-Prüfdienst
tools/                           bootstrap.sh, nginx-issuer.conf, demo.sh
docs/                            die vollständige Dokumentation
```

`CLAUDE.md` hält fest, wo dieser PoC bewusst von den übergreifenden Projektstandards abweicht.

## Lizenz & Status

Dieses Projekt ist **proprietär** — siehe [LICENSE](LICENSE). Es ist bewusst **nicht**
quelloffen lizenziert.

Aktueller Stand: private Vorarbeit von Moritz Rohde. Einzelnen Personen kann vorab lesender
Zugriff zur Sichtung und fachlichen Diskussion gewährt werden; das begründet kein Recht zur
Weitergabe. Eine Übergabe an eine Abteilung oder eine Veröffentlichung erfolgt ausschließlich
durch den Autor selbst — nicht durch Dritte, die die Vorarbeit in seiner Abwesenheit
aufgreifen.
