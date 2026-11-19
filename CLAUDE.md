# CLAUDE.md — projektlokale Abweichungen

Dies ist ein **Wegwerf-Lab / PoC**. Es weicht in den folgenden, klar abgegrenzten Punkten
bewusst von der globalen `~/CLAUDE.md` ab. Die globale Datei bleibt unverändert und gilt
überall sonst weiter.

## Bewusste Abweichungen

| Globale Regel | Hier | Warum |
|---|---|---|
| Hexagonale Architektur, Aufteilung `ports/adapters/core` | Flache Pakete: `ms.rohde.wifpoc` (validator), `ms.rohde.wifpoc.servicer` (service-r), je wenige Klassen | Beide Dienste sind Demos mit einem einzigen Zweck; service-r ist bewusst reine Spring-Security-Konfiguration als Vorlage. Schichtung brächte Zeremonie ohne Lerngewinn. |
| `ms.rohde:hexagonal-arch`-Annotationen + ArchUnit-Test verpflichtend | Nicht verwendet | In flachen Diensten mit wenigen Klassen gibt es nichts zu erzwingen. |
| Spezialisierte Coder-/Reviewer-Agenten vor Java-Code verpflichtend | Direkt geschrieben | PoC-Umfang; kein Domänenmodell, keine Sicherheitsfläche außer dem einen dokumentierten Ablauf. |
| MapStruct für DTO-Mapping | Nicht verwendet | Es gibt kein DTO-zu-Entity-Mapping. |
| Docker-Compose-Datei heißt `docker-compose.yml` | `compose.yaml` | Kanonischer Name für Compose v2; dieses Repo ist reines Compose-v2. |

## Regeln, die weiter gelten

- Java 25, Spring Boot 4.x (jeweils aktuellste stabile Version), aktuellste stabile
  Abhängigkeiten, null Compiler-Warnungen, keine veralteten APIs.
- JSpecify `@NullMarked` auf Modul-/Paketebene, `@Nullable` nur dort, wo null legitim ist.
- Log4j2 zum Loggen. Java-`record` für DTOs. Kein Lombok.
- TDD: `TokenValidatorTest` (validator) sowie `OrdersEndpointSecurityTest` und
  `ScopeAuthoritiesTest` (service-r) prüfen den Validierungs- bzw. Autorisierungsvertrag und
  laufen vollständig offline.
- Sicherheitsrelevante Änderungen (Token-Prüfung, Realm, Netzplatzierung, Gateway) bekommen
  einen Security-Review-Lauf.
- Englische Bezeichner, `UPPER_SNAKE_CASE`-Konstanten, sprechende Namen statt Kommentaren.
- Dokumentation beschreibt nur den IST-Zustand — keine Changelog-Prosa in README/JavaDoc.
- Repo-Dokumentation (README, `docs/`) auf Deutsch; Code, Bezeichner und JavaDoc auf Englisch.
- Git: Feature-Branch + PR, kein Self-Merge, kein `Claude-Session`-Footer (Repo kann geteilt
  werden), `Co-Authored-By` bleibt.
