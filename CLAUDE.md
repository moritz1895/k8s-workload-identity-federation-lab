# CLAUDE.md — projektlokale Abweichungen

Dies ist ein **Wegwerf-Lab / PoC**. Es weicht in den folgenden, klar abgegrenzten Punkten
bewusst von der globalen `~/CLAUDE.md` ab. Die globale Datei bleibt unverändert und gilt
überall sonst weiter.

## Bewusste Abweichungen

| Globale Regel | Hier | Warum |
|---|---|---|
| Hexagonale Architektur, Aufteilung `ports/adapters/core` | Flaches Paket `ms.rohde.wifpoc`, ~4 Klassen | Der Validator ist eine Demo mit einem einzigen Zweck. Schichtung brächte Zeremonie ohne Lerngewinn. |
| `ms.rohde:hexagonal-arch`-Annotationen + ArchUnit-Test verpflichtend | Nicht verwendet | In einem flachen Dienst mit 4 Klassen gibt es nichts zu erzwingen. |
| Spezialisierte Coder-/Reviewer-Agenten vor Java-Code verpflichtend | Direkt geschrieben | PoC-Umfang; kein Domänenmodell, keine Sicherheitsfläche außer dem einen dokumentierten Ablauf. |
| MapStruct für DTO-Mapping | Nicht verwendet | Es gibt kein DTO-zu-Entity-Mapping. |
| Docker-Compose-Datei heißt `docker-compose.yml` | `compose.yaml` | Kanonischer Name für Compose v2; dieses Repo ist reines Compose-v2. |

## Regeln, die weiter gelten

- Java 25, Spring Boot 4.x (jeweils aktuellste stabile Version), aktuellste stabile
  Abhängigkeiten, null Compiler-Warnungen, keine veralteten APIs.
- JSpecify `@NullMarked` auf Modul-/Paketebene, `@Nullable` nur dort, wo null legitim ist.
- Log4j2 zum Loggen. Java-`record` für DTOs. Kein Lombok.
- TDD: `TokenValidatorTest` prüft den Validierungsvertrag und läuft vollständig offline.
- Englische Bezeichner, `UPPER_SNAKE_CASE`-Konstanten, sprechende Namen statt Kommentaren.
- Dokumentation beschreibt nur den IST-Zustand — keine Changelog-Prosa in README/JavaDoc.
- Repo-Dokumentation (README, `docs/`) auf Deutsch; Code, Bezeichner und JavaDoc auf Englisch.
- Git: Feature-Branch + PR, kein Self-Merge, kein `Claude-Session`-Footer (Repo kann geteilt
  werden), `Co-Authored-By` bleibt.
