# ADR 0002: Eigenständiger Issuer-Endpoint statt anonymer Discovery am API-Server

**Datum:** 2026-09-09
**Status:** Angenommen

## Für wen ist das / was lernst du hier

Diese Notiz erklärt, warum das OIDC-Discovery-Dokument und die JWKS in diesem Lab von einem
separaten kleinen Webserver (`issuer-web`, ein nginx) ausgeliefert werden - und nicht direkt
und ohne Anmeldung vom Kubernetes-API-Server. Begriffe siehe [../domain.md](../domain.md)
und [../kubernetes-primer.md](../kubernetes-primer.md).

## Kontext

Für die Offline-Prüfung (siehe [ADR 0001](0001-offline-jwks-statt-tokenreview.md)) muss der
Validator an zwei öffentliche Dokumente kommen:

- das Discovery-Dokument unter `<issuer>/.well-known/openid-configuration`,
- die JWKS unter der darin genannten `jwks_uri`.

Kubernetes kann diese beiden Dokumente selbst am API-Server bereitstellen (Pfade
`/.well-known/openid-configuration` und `/openid/v1/jwks`). Der Zugriff darauf ist aber
nicht per se offen: Er benötigt entweder ein Credential oder eine ausdrückliche Freigabe für
nicht authentifizierte Aufrufer. Kubernetes bringt dafür die eingebaute ClusterRole
`system:service-account-issuer-discovery` mit, die genau `GET` auf diese beiden Pfade
erlaubt; per `ClusterRoleBinding` lässt sie sich der Gruppe `system:unauthenticated`
zuweisen.

Damit wären zwei Dinge nötig, die in einem realen Aufbau unüblich sind:

1. **`anonymous-auth=true`** am API-Server, also nicht authentifizierter Zugriff.
2. Ein **ClusterRoleBinding**, das genau diesen anonymen Zugriff auf die Discovery-Pfade
   erlaubt.

Außerdem müsste der externe Validator dann den **API-Server selbst** über das Netzwerk
erreichen und dessen Serving-Zertifikat als Vertrauensanker mitbekommen - der Validator
hinge also doch an einer API-Server-Adresse.

Ein echter Workload-Identity-Federation-Aufbau löst das anders: Discovery-Dokument und JWKS
werden an einer **stabilen, öffentlichen HTTPS-URL** veröffentlicht (Objektspeicher, CDN,
Gateway), entkoppelt vom API-Server und von dessen Erreichbarkeit und Rechtesystem.

## Entscheidung

Das Lab betreibt einen **eigenständigen Issuer-Endpoint** `issuer-web` (nginx-Container,
[`tools/nginx-issuer.conf`](../../tools/nginx-issuer.conf)):

- Der k3s-API-Server wird mit `service-account-issuer=https://issuer-web` und
  `service-account-jwks-uri=https://issuer-web/openid/v1/jwks` gestartet. Jedes Token trägt
  damit `iss = https://issuer-web`, und das Discovery-Dokument nennt die externe `jwks_uri`.
- Der `bootstrap`-Container holt Discovery-Dokument und JWKS **einmalig** mit der
  Admin-Kubeconfig (`kubectl get --raw ...`) aus dem Cluster und legt sie als statische
  Dateien in ein von nginx ausgeliefertes Volume. Er erzeugt außerdem das selbst-signierte
  TLS-Zertifikat für `issuer-web`.
- `issuer-web` liefert ausschließlich diese beiden Pfade über HTTPS aus; alles andere
  ergibt `404`.
- Der Validator macht echte OIDC-Discovery gegen `https://issuer-web`, vertraut dabei
  **nur** dem einen Bootstrap-Zertifikat und berührt den API-Server nie.
- Es gibt **kein** RBAC-Manifest und **kein** `anonymous-auth=true` im Lab.

## Konsequenzen

### Positiv

- **Der Validator ist vollständig vom API-Server entkoppelt** - kein API-Server-Netzzugang,
  kein API-Server-Zertifikat als Vertrauensanker, kein anonymer Cluster-Zugriff nötig.
- **Näher am realen Muster.** Der Aufbau demonstriert die "separate, öffentlich publizierte
  Discovery-URL", wie sie produktiv verwendet wird.
- **Kleinere Angriffsfläche am Cluster.** Der API-Server muss keine nicht authentifizierten
  Aufrufer akzeptieren.
- **Klarer Vertrauensanker.** Genau ein Zertifikat, genau ein Issuer-Name (siehe
  [../domain.md](../domain.md#4-der-trust-anchor-wer-vertraut-wem-und-warum-darf-der-validator-offline-glauben)).

### Negativ / Kompromisse

- **Zusätzlicher Dienst** (`issuer-web`) plus ein `bootstrap`-Schritt, der die Metadaten
  kopiert.
- **Die JWKS sind eine Momentaufnahme.** `bootstrap` kopiert sie einmalig pro
  `docker compose up`. Rotiert der Cluster seine Signaturschlüssel im laufenden Betrieb,
  bekommt `issuer-web` das erst beim nächsten Bootstrap mit. In Produktion übernimmt diese
  Synchronisation eine Automatisierung, die den alten Schlüssel erst entfernt, wenn der neue
  überall angekommen ist.
- **Selbst-signiertes Zertifikat, out of band verteilt.** Der Validator bekommt das
  Issuer-Zertifikat direkt in den Container gereicht. Eine echte Relying Party vertraut
  einer öffentlichen Zertifizierungsstelle oder einem explizit gepinnten Bundle.
- **`issuer-web` ist ein Netz-Name im Docker-Netz**, keine echte öffentliche URL.

Diese Kompromisse sind bewusst und im Abschnitt "What you would do differently outside a lab"
der [README](../../README.md) aufgeführt.

## Alternativen

- **Anonyme Discovery direkt am API-Server** (`anonymous-auth=true` plus
  ClusterRoleBinding von `system:service-account-issuer-discovery` an
  `system:unauthenticated`). Kommt ohne den zusätzlichen nginx aus, verlangt dafür aber
  nicht authentifizierten Zugriff auf den API-Server und macht den Validator wieder von der
  API-Server-Adresse und deren Zertifikat abhängig - das Gegenteil der gewünschten
  Entkopplung. Dies war ein früherer Stand des Labs
  ([`manifests/10-rbac-anonymous-oidc.yaml`](../../manifests/), inzwischen entfernt).
- **Authentifizierte Discovery** mit einem eigenen ServiceAccount-Token für den Validator.
  Beseitigt den anonymen Zugriff, führt aber wieder ein zu verwaltendes Credential beim
  externen Dienst ein und behält die Netz-/Zertifikatsabhängigkeit vom API-Server.
- **Statische Metadaten von Hand pflegen** (JWKS abtippen). Fehleranfällig und bricht bei
  jeder Schlüsselrotation; der Bootstrap-Schritt automatisiert genau das.

## Weiterlesen

- [0001-offline-jwks-statt-tokenreview.md](0001-offline-jwks-statt-tokenreview.md) - warum überhaupt offline geprüft wird.
- [../kubernetes-primer.md](../kubernetes-primer.md#rbac--nur-so-viel-wie-hier-nötig) - RBAC und warum der PoC keins braucht.
- [../use-cases.md](../use-cases.md#use-case-2-cluster-bootstrap-docker-compose-up--d---build) - was der Bootstrap konkret tut.
