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
| 4 | [use-cases.md](use-cases.md) | Der Ende-zu-Ende-Ablauf als Use Case, inklusive aller Fehlerfälle und ihrer erwarteten Ergebnisse. |

## Technische Referenz

Für Details zur Umsetzung:

| Dokument | Inhalt |
|---|---|
| [technical/architecture.md](technical/architecture.md) | Compose-Topologie: alle Services, die drei Volumes, das Netzwerk, Startreihenfolge. |
| [technical/bootstrap-und-issuer.md](technical/bootstrap-und-issuer.md) | `bootstrap.sh` Schritt für Schritt; das self-signed Zertifikat; die nginx-Config. |
| [technical/validator.md](technical/validator.md) | Der Java-Dienst: Konfiguration, Startablauf, die Nimbus-Validierungskette, die Endpunkte, die Tests. |
| [technical/trust-und-tls.md](technical/trust-und-tls.md) | Die zwei TLS-Vertrauensbeziehungen; wie der Validator einen Truststore mit einem einzigen Zertifikat baut; `PKIX path building failed`. |
| [technical/build-und-betrieb.md](technical/build-und-betrieb.md) | Images & Multi-Stage-Build, die drei Compose-Befehle, alle `.env`-Variablen, häufige Fehlerbilder. |

## Entscheidungen (ADRs)

| ADR | Entscheidung |
|---|---|
| [adr/0001-offline-jwks-statt-tokenreview.md](adr/0001-offline-jwks-statt-tokenreview.md) | Warum offline über JWKS statt online über die TokenReview-API. |
| [adr/0002-eigenstaendiger-issuer-endpoint.md](adr/0002-eigenstaendiger-issuer-endpoint.md) | Warum ein eigener `issuer-web`-Dienst statt anonymem Zugriff auf den API-Server. |
