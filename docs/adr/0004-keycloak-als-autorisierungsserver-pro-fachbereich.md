# ADR 0004: Keycloak als Autorisierungsserver pro Fachbereich

**Datum:** 2026-11-17
**Status:** Vorgeschlagen (ergänzt [ADR 0001](0001-offline-jwks-statt-tokenreview.md) bis
[ADR 0003](0003-getrennte-vertrauensbereiche-interne-pki.md))

## Für wen ist das / was lernst du hier

Diese Notiz hält fest, wer im Lab entscheidet, **was** eine Workload darf, nachdem
ADR 0001–0003 geklärt haben, wie ein Dienst prüft, **wer** sie ist. Ablauf und
Akzeptanzkriterien stehen in [../features/keycloak-autorisierungsserver.md](../features/keycloak-autorisierungsserver.md).

## Kontext

Heute bilden Dienste den Subject-DN eines mTLS-Client-Zertifikats auf Rollen ab. Der CN hat
die Form `<Rolle> <Anwendungskontext> <Betriebsumgebung>`; die Rolle steckt damit in der
Identität, und wer Zertifikate ausstellt, entscheidet faktisch über Berechtigungen.

Ein ServiceAccount-Token trägt nur die Identität (`iss` + `sub`), keine Rolle (Issue #3).
Eine Workload ruft Dienste mehrerer Fachbereiche auf; jeder Fachbereich will selbst
bestimmen, wer seine Dienste nutzen darf. Ein zentraler Autorisierer über alle Fachbereiche
würde diese Verantwortung an eine Stelle ziehen, die die Dienste nicht kennt.

## Entscheidung

- **Authentisierung und Autorisierung sind getrennt.** Das ServiceAccount-Token beweist
  nur die Identität und wird ausschließlich beim Autorisierungsserver vorgelegt.
- **Ein Autorisierungsserver pro Fachbereich.** Der Fachbereich, dem ein Dienst gehört,
  stellt die Access-Tokens für diesen Dienst aus. Umsetzung: Keycloak, ein Realm pro
  Fachbereich.
- **Föderierte Client-Authentisierung statt Client-Secrets.** Die Workload legt ihr
  ServiceAccount-Token (Audienz = Realm-Issuer, 10 min) im `client_credentials`-Grant als
  Client-Assertion vor. Keycloak prüft es gegen die JWKS des Clusters, die `issuer-web`
  veröffentlicht, und ordnet es über Identity-Provider + `sub` einem Client zu.
- **Die Client-Scope-Zuordnung im Realm ist die Autorisierungsregel.** Der Dienst bildet
  Scopes im Code auf Endpunkte ab und kennt keine Workloads.
- **Ressourcendienste sind Standard-Spring-Resource-Server**, die nur Issuer-URL, Audienz
  und Scope-Namen kennen.
- **Realm als Code.** Im Lab per JSON-Import; im Unternehmen per keycloak-config-cli oder
  Terraform über Pull Requests mit 4-Augen-Review, Keycloak-Admin-Events als Audit.

## Konsequenzen

### Positiv

- Berechtigungen hängen nicht mehr an der PKI oder an Namenskonventionen von Zertifikaten.
- Jeder Fachbereich verwaltet nur seine eigenen Dienste; neue Workloads zu berechtigen
  ändert keinen Dienst.
- Kein Geheimnis in der Workload: Das einzige Credential ist das kurzlebige,
  automatisch erneuerte ServiceAccount-Token.
- Der Autorisierungsserver ist austauschbar, weil Dienste nur Issuer und Scopes kennen.

### Negativ / Kompromisse

- **Zusätzliche Laufzeitabhängigkeit.** Ohne erreichbaren Keycloak bekommt eine Workload
  nach Ablauf ihres Access-Tokens keinen neuen. Im Unternehmen muss der gemeinsame
  Keycloak hochverfügbar sein.
- **Kein Replay-Schutz** für ServiceAccount-Tokens als Client-Assertion; begrenzt nur durch
  die Laufzeit von höchstens zehn Minuten und die Audienz-Bindung an den Realm.
- **Entzug wirkt verzögert** um die Restlaufzeit des Access-Tokens.
- **Keycloak hat keinen Freigabe-Workflow** für Admin-Änderungen; das 4-Augen-Prinzip hängt
  am Git-Prozess und an eingeschränktem UI-Schreibzugriff.
- **Speicherbedarf im Lab:** ein Keycloak im Dev-Modus (rund 0,5–0,75 GB) und ein weiterer
  JVM-Dienst.

## Alternativen

- **Scopes oder Rollen direkt aus dem ServiceAccount-Token ableiten** (Mapping von `sub`
  oder Namespace im Dienst). Verschiebt die Berechtigungsliste in jeden Dienst und lässt
  Cluster-Namen über Rechte entscheiden.
- **Ein zentraler Autorisierungsserver für alle Fachbereiche.** Bündelt Entscheidungen
  über fremde Dienste an einer Stelle ohne fachliche Verantwortung.
- **Eigener Autorisierungsserver auf Basis von Spring Authorization Server.** Dokumentierte
  Ausweichlösung, solange der gemeinsame Keycloak nicht abgestimmt ist. Braucht einen
  eigenen Authenticator, weil das ServiceAccount-Token nicht die von RFC 7523 verlangte
  Form `iss = sub = client_id` hat.

## Weiterlesen

- [../features/keycloak-autorisierungsserver.md](../features/keycloak-autorisierungsserver.md) – Spezifikation mit Ablauf, Konfiguration und Tests.
- [0003-getrennte-vertrauensbereiche-interne-pki.md](0003-getrennte-vertrauensbereiche-interne-pki.md) – woher Keycloak die Schlüssel des Clusters bekommt.
