# Dokumentation

Diese Doku erklärt den PoC von Grund auf. **Vorausgesetzt** wird nur Grundverständnis von
JWT, JWS und JWK. Jeder Kubernetes-, Docker- und TLS-Begriff wird beim ersten Auftreten
erklärt.

## Lesereihenfolge

Wenn du neu hier bist, lies in dieser Reihenfolge:

| # | Dokument | Was drinsteht |
|---|---|---|
| 1 | [**walkthrough.md**](walkthrough.md) | Die geführte Tour: `docker compose up` → Demo → aufräumen, mit echten Log-Ausschnitten. Bester Einstieg. |
| 2 | [domain.md](domain.md) | Das Problem, der Begriff „Workload Identity Federation", die Akteure, der Trust Anchor, offline vs. online. Analogie + Glossar. |
| 3 | [kubernetes-primer.md](kubernetes-primer.md) | Nur die Kubernetes-Bausteine, die dieser PoC benutzt — einzeln erklärt, mit Verweis auf die konkrete Datei. |
| 4 | [use-cases.md](use-cases.md) | Der Ende-zu-Ende-Ablauf als Use Cases (Token prüfen, Start, Veröffentlichung, Rotation), inklusive aller Fehlerfälle und ihrer erwarteten Ergebnisse. |
| 5 | [features/keycloak-autorisierungsserver.md](features/keycloak-autorisierungsserver.md) | Feature-Spezifikation Autorisierungsserver: Ablauf Workload → Keycloak → Dienst R, Akzeptanzkriterien, Prüfungen 8–21. |

## Technische Referenz

Für Details zur Umsetzung:

| Dokument | Inhalt |
|---|---|
| [technical/architecture.md](technical/architecture.md) | Compose-Topologie: alle Services inkl. `load-balancer`, die Volumes, die drei Netze, Startreihenfolge. |
| [technical/bootstrap-und-issuer.md](technical/bootstrap-und-issuer.md) | Lab-PKI (`pki-init.sh`), Signaturschlüssel und zweiphasiger Wechsel (`sa-keys.sh`), `bootstrap.sh`, der Discovery-Pod (`sync` + `web`), Gateway, HTTPRoute und `load-balancer`, Härtung von `wif-issuer-discovery`, Verhalten bei Fehlern. |
| [technical/validator.md](technical/validator.md) | Der Java-Dienst: Konfiguration, Startablauf, die Nimbus-Validierungskette, die Endpunkte, die Tests. |
| [technical/trust-und-tls.md](technical/trust-und-tls.md) | Die TLS-Vertrauensbeziehungen inkl. strict SNI am Gateway; wie der Validator einen Truststore nur mit der internen CA baut; `PKIX path building failed`. |
| [technical/build-und-betrieb.md](technical/build-und-betrieb.md) | Images & Multi-Stage-Build, die Betriebsbefehle, Schlüsselwechsel, `run-all-checks.sh`, alle `.env`-Variablen, häufige Fehlerbilder. |
| [technical/autorisierungsserver.md](technical/autorisierungsserver.md) | Keycloak (Startmodus, föderierte Client-Authentisierung, Realm), `service-r` als Resource Server, `access-token.sh`, gemessenes Keycloak-Verhalten und Speicherbedarf. |

## Entscheidungen (ADRs)

| ADR | Entscheidung |
|---|---|
| [adr/0001-offline-jwks-statt-tokenreview.md](adr/0001-offline-jwks-statt-tokenreview.md) | Warum offline über JWKS statt online über die TokenReview-API. |
| [adr/0002-eigenstaendiger-issuer-endpoint.md](adr/0002-eigenstaendiger-issuer-endpoint.md) | Warum ein eigener Issuer-Endpoint statt anonymem Zugriff auf den API-Server. |
| [adr/0003-getrennte-vertrauensbereiche-interne-pki.md](adr/0003-getrennte-vertrauensbereiche-interne-pki.md) | Interne PKI als Vertrauensanker, getrennte Netze; der Veröffentlichungsweg (Push per mTLS) ist durch ADR 0005 abgelöst. |
| [adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md](adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md) | Autorisierung getrennt von Identität: ein Keycloak-Realm pro Fachbereich, ServiceAccount-Token als Client-Nachweis, Scopes als Rechte. |
| [adr/0005-discovery-pod-im-cluster-pull-ueber-ingress.md](adr/0005-discovery-pod-im-cluster-pull-ueber-ingress.md) | Discovery-Pod im Cluster liefert Discovery-Dokument und JWKS per Pull aus; Härtung des Namespace, Schlüsselwechsel in zwei Phasen. |
| [adr/0006-gateway-api-statt-ingress.md](adr/0006-gateway-api-statt-ingress.md) | Gateway API (eigenes `Gateway` + `HTTPRoute`) statt `Ingress` für die Route zum Discovery-Pod; Schutz der Issuer-Adresse über `allowedRoutes`/`allowedListeners` und Hostname-Pflicht. |

## Präsentation

| Ordner | Inhalt |
|---|---|
| [praesentation/](praesentation/README.md) | Quelldateien des Foliensatzes zur Kurzvorstellung des PoC (HTML/CSS/JSON). |
