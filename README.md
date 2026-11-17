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

Alles läuft in Containern. Auf dem Host wird **nur Docker + Compose v2** gebraucht.

```bash
cp .env.example .env
docker compose up -d --build   # PKI, k3s, Publisher, Issuer-Endpoint, Validator
docker compose run --rm demo          # Ende-zu-Ende-Verifikation
tools/run-all-checks.sh               # alles: Demo, Netztrennung, fremde CA, Schlüsselrotation
docker compose down -v                # alles wieder entfernen
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

## Dokumentation

Die ausführliche Erklärung — von den Grundbegriffen bis zur Implementierung, geschrieben für
jemanden ohne Kubernetes-Vorwissen — steht in **[`docs/`](docs/README.md)**.

Schnelleinstieg: **[docs/walkthrough.md](docs/walkthrough.md)** (geführte Tour mit echten
Log-Ausgaben).

## Was außerhalb eines Labors anders sein muss

Die Grundsatzentscheidungen stehen in den ADRs
([0001](docs/adr/0001-offline-jwks-statt-tokenreview.md),
[0002](docs/adr/0002-eigenstaendiger-issuer-endpoint.md),
[0003](docs/adr/0003-getrennte-vertrauensbereiche-interne-pki.md)), die Abwägung offline
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

## Projektstruktur

```
compose.yaml                     alle Services, die drei Netze cluster-net / relying-net / workload-net
manifests/                       Namespaces, jwks-publisher (SA, RBAC, Deployment), Consumer-Deployment
validator/                       Spring Boot 4 / Java 25, Nimbus JOSE — der Offline-Prüfdienst
tools/                           pki-init.sh, sa-keys.sh, bootstrap.sh, nginx-issuer.conf,
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
