# CLAUDE.md — project-local overrides

This is a **throwaway lab / PoC**. It deliberately deviates from the global `~/CLAUDE.md`
in the following, scoped ways. The global file is unchanged and still applies everywhere else.

## Deliberate deviations

| Global rule | Here | Why |
|---|---|---|
| Hexagonal architecture, `ports/adapters/core` package split | Flat package `ms.rohde.wifpoc`, ~4 classes | The validator is a single-purpose demo. Layering would add ceremony without teaching value. |
| `ms.rohde:hexagonal-arch` annotations + ArchUnit test mandatory | Not used | Nothing to enforce in a flat 4-class service. |
| Specialized coder/reviewer agents mandatory before Java code | Written directly | PoC scope; no domain model, no security surface beyond the one documented flow. |
| MapStruct for DTO mapping | Not used | No DTO-to-entity mapping exists. |
| Docker Compose file named `docker-compose.yml` | `compose.yaml` | Compose v2 canonical name; this repo is Compose-v2-only. |

## Rules that still apply

- Java 25, Spring Boot 4.x (latest stable), latest stable dependencies, zero compiler warnings,
  no deprecated APIs.
- JSpecify `@NullMarked` at module/package level, `@Nullable` only where null is legitimate.
- Log4j2 for logging. Java `record` for DTOs. No Lombok.
- TDD: `TokenValidatorTest` is written against the validation contract and runs fully offline.
- English identifiers, `UPPER_SNAKE_CASE` constants, intent-revealing names over comments.
- Docs describe current state only — no changelog prose in README/JavaDoc.
- Git: feature branch + PR, never self-merge, no `Claude-Session` footer (repo may be shared),
  `Co-Authored-By` stays.
