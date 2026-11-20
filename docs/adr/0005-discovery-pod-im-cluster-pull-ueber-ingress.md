# ADR 0005: Discovery-Pod im Cluster – Schlüssel per Pull über einen Ingress

**Datum:** 2026-11-19
**Status:** Angenommen; löst [ADR 0003](0003-getrennte-vertrauensbereiche-interne-pki.md) im Veröffentlichungsweg (Push per mTLS) ab; Beschreibung und Schutz der Route abgelöst durch [ADR 0006](0006-gateway-api-statt-ingress.md)

## Für wen ist das / was lernst du hier

Diese Notiz erklärt, woher Validator und Keycloak Discovery-Dokument und JWKS des Clusters
bekommen, warum dafür kein Zertifikat und kein Schreibweg mehr nötig ist und wie der
Namespace geschützt wird, der die Schlüssel ausliefert. Begriffe siehe
[../domain.md](../domain.md).

## Kontext

Discovery-Dokument und JWKS sind öffentliche Daten. Wer aber bestimmen kann, was unter der
JWKS-URL ausgeliefert wird, kann gültige ServiceAccount-Tokens für jeden ServiceAccount
fälschen. Die Frage ist also nicht, wer die Daten lesen darf, sondern wer bestimmt, was
ausgeliefert wird.

Ein Weg, bei dem eine Komponente im Cluster die Schlüssel zu einem Webserver außerhalb
hochlädt, braucht für diese Komponente ein eigenes Credential, etwa ein Client-Zertifikat.
Das ist genau das Muster, das die Workload Identity für alle anderen Pods abschafft:
ein privater Schlüssel im Pod, der lange gilt und sicher abgelegt werden muss. Automatisches
Ausstellen (cert-manager o. Ä.) ändert daran nichts, denn auch der Aussteller entscheidet
anhand von Kubernetes-RBAC bzw. ServiceAccount-Token, wer ein Zertifikat bekommt. Das
Zertifikat bringt also keinen zusätzlichen Vertrauensanker, nur einen Schlüssel mehr.

Annahme wie in ADR 0003: Eine interne PKI ist vorhanden, ihr Root-Zertifikat ist auf allen
Systemen bereits auf anderem Weg verteilt.

## Entscheidung

**Ein Pod im Cluster liefert die Dokumente selbst aus.**
Der Issuer, also der Aussteller der Tokens, bleibt der API-Server: Er signiert sie, und
seine Issuer-URL `https://issuer.wif.local` steht im `iss`-Claim. Der Discovery-Pod stellt
nichts aus. Er liefert unter dieser URL nur die öffentlichen Metadaten des Issuers aus.
Kubernetes nennt das „Service Account Issuer Discovery“, daher der Name.

Das Deployment `issuer-discovery` im Namespace `wif-issuer-discovery` (zwei Replikas)
besteht aus zwei Containern, die sich ein `emptyDir` teilen:

- `sync` liest alle 15 Sekunden `/.well-known/openid-configuration` und `/openid/v1/jwks`
  mit dem eigenen ServiceAccount beim API-Server. Der ServiceAccount hat nur die Rolle
  `system:service-account-issuer-discovery`. `sync` übernimmt einen Stand nur, wenn er
  plausibel ist: `issuer` und `jwks_uri` stimmen, das JWKS enthält mindestens einen
  Schlüssel. Er schreibt beide Dateien atomar. Ist der API-Server nicht erreichbar oder
  der Stand nicht plausibel, bleibt der letzte gültige Stand stehen. Jede `kid`, die
  hinzukommt oder wegfällt, protokolliert er als `WARNING`.
- `web` (nginx, ohne Root) liefert die Kopie nur per `GET` aus. Er hat kein
  ServiceAccount-Token und ist nicht dafür konfiguriert, den API-Server anzusprechen;
  keine Anfrage von außen wird dorthin durchgereicht. Die NetworkPolicy gilt für den
  ganzen Pod und ließe den Weg zum API-Server auch für `web` zu. Bereit (Readiness) ist er erst, wenn das JWKS einmal abgeglichen
  ist. Ein neu gestarteter Pod nimmt also erst Verkehr an, wenn er einen gültigen Stand hat.

**Erreichbar über ein Gateway.**
Das in k3s mitgelieferte Traefik veröffentlicht als Gateway-Controller nur die beiden
Pfade unter dem Host `issuer.wif.local`, beschrieben mit der Gateway API (`Gateway` +
`HTTPRoute`, siehe [ADR 0006](0006-gateway-api-statt-ingress.md)). Das Serverzertifikat
stammt aus der internen PKI. Traefik lehnt TLS-Verbindungen für Hosts ohne eigenes
Zertifikat ab (strict SNI). API-Server-Parameter: `service-account-issuer=https://issuer.wif.local`,
`service-account-jwks-uri=https://issuer.wif.local/openid/v1/jwks`.

**Netze.** Die Relying Parties (Validator, Keycloak) erreichen nur die Route
`issuer.wif.local`, nicht den API-Server. Im Lab steht dafür `load-balancer`, ein nginx im
TCP-Modus, als Stellvertreter für den Load Balancer vor dem Cluster: Er hört in `relying-net` auf
Port 443 und reicht nur dorthin an Traefiks Node-Port weiter. TLS endet im Cluster.
kube-proxy öffnet Node-Ports nur auf der Adresse in `cluster-net`
(`--nodeport-addresses`).

**Härtung des Namespace.** `wif-issuer-discovery` wird geschützt wie die Steuerung des Clusters:

- RBAC: Kein RoleBinding gewährt Rechte im Namespace; schreiben dürfen nur Cluster-Admins
  bzw. der GitOps-Prozess.
- Eigenes Gateway `issuer-discovery`, an das sich nur Routen aus `wif-issuer-discovery`
  hängen dürfen, und `ValidatingAdmissionPolicy` `issuer-host-reserved`: Außerhalb von
  `wif-issuer-discovery` nennt jeder Listener einen Hostnamen, und weder Listener noch
  Routen verwenden `issuer.wif.local` oder eine Wildcard, die ihn abdeckt. Einzelheiten in
  [ADR 0006](0006-gateway-api-statt-ingress.md).
- `ValidatingAdmissionPolicy` `issuer-discovery-image-digest`: In `wif-issuer-discovery` laufen nur Images mit
  festem Digest.
- NetworkPolicy: eingehend nur von Traefik, ausgehend nur zum API-Server.
- Pod Security Standard `restricted`; beide Container ohne Root, mit schreibgeschütztem
  Root-Dateisystem und ohne Capabilities.

**Schlüsselwechsel in zwei Phasen** (`sa-keys stage` / `sa-keys activate`, jeweils mit
Neustart des API-Servers):

1. `stage`: Der neue öffentliche Schlüssel wird vorab veröffentlicht, also ins JWKS
   aufgenommen. Signiert wird noch mit dem bisherigen Schlüssel, es gibt also noch kein
   Token, das ihn braucht. Weiter geht es erst, wenn der Discovery-Pod ihn ausliefert.
2. `activate`: Erst dann wird er zum Signierschlüssel. Ab hier stehen der neue und der
   bisherige Schlüssel im JWKS: der neue für neue Tokens, der bisherige für Tokens, die
   noch gültig sind. Ältere fallen weg.

| Zeitpunkt | Signiert mit | Im JWKS |
|---|---|---|
| vorher | A | A |
| nach `stage` | A | A, B (B vorab veröffentlicht) |
| nach `activate` | B | B, A (A für noch gültige Tokens) |
| nach dem nächsten `activate` | C | C, B |

Phase 1 ist nötig, weil die Relying Parties neue Schlüssel nur mit Verzögerung bekommen:
Der Discovery-Pod gleicht alle 15 Sekunden ab, Keycloak und Validator speichern Schlüssel
zwischen. Würde der API-Server sofort mit einem neuen Schlüssel signieren, könnte ein Token
mit der neuen `kid` ankommen, bevor sie ausgeliefert wird. Keycloak würde dann neu laden,
den alten Stand bekommen, ablehnen und frühestens nach 10 Sekunden wieder laden.

So gibt es keinen Moment, in dem ein Token mit einer `kid` unterwegs ist, die der
Discovery-Pod noch nicht ausliefert. Das deckt auch mehrere Replikas mit kurz verschiedenem
Stand ab. Einen alten Schlüssel entfernt `activate` frühestens bei der übernächsten
Rotation; zwischen zwei `activate` muss mindestens die längste Laufzeit liegen, die ein
Workload für ein Token anfordern kann (`expirationSeconds`, begrenzt durch den
API-Server), plus die Zeit, die die Relying Parties Schlüssel zwischenspeichern. Ist ein
Schlüssel kompromittiert, nimmt `sa-keys retire` den vorigen Schlüssel sofort aus dem
JWKS.

**Relying Parties laden Schlüssel nur vom Ursprung des Issuers.** Der Validator nimmt das
JWKS nur, wenn die `jwks_uri` des Discovery-Dokuments Schema, Host und Port des Issuers
hat. Ein anderer Dienst mit einem Zertifikat derselben CA kann so keine Schlüssel
unterschieben.

## Verfügbarkeit: Keycloak und Validator

Neue Schlüssel bekommen die Relying Parties nur, solange die Route `issuer.wif.local`
erreichbar ist.

- **Keycloak** speichert die Schlüssel des Identity Providers zwischen und lädt neu, wenn
  eine unbekannte `kid` ankommt. Dafür gelten zwei Werte des SPI
  `public-key-storage` (Provider `infinispan`):
  - `min-time-between-requests`: Standard 10 s. Innerhalb dieser Zeit nach dem letzten
    Abruf lädt Keycloak nicht erneut; eine Client Assertion mit unbekannter `kid` wird
    abgelehnt.
  - `max-cache-time`: Standard 86 400 s (24 h). So lange gelten die Schlüssel ohne neuen
    Abruf.
  Ein kurzer Ausfall der Route fällt also nur auf, wenn genau dann eine neue `kid`
  auftaucht. Ein Wechsel in zwei Phasen sorgt dafür, dass das außerhalb eines geplanten
  Fensters nicht passiert.
- **Validator** (Nimbus): JWKS-Cache 5 Minuten, ein unbekanntes `kid` löst einen
  sofortigen Abruf aus (siehe [../technical/validator.md](../technical/validator.md)).

## Konsequenzen

### Positiv

- Kein privater Schlüssel mehr im Cluster, um Schlüssel zu veröffentlichen: kein
  Client-Zertifikat, kein Secret dafür, kein Ablaufdatum, das man im Blick behalten muss.
- Kein Schreibweg: Es gibt keinen Endpunkt, über den jemand von außen ein JWKS einspielen
  könnte.
- Der Discovery-Pod übernimmt nur plausible Stände und liefert bei Ausfall des API-Servers
  den letzten gültigen Stand weiter, nie ein leeres JWKS.
- Die Issuer-URL hängt nicht an der Adresse des API-Servers.

### Negativ / Kompromisse

- **Der Namespace `wif-issuer-discovery` wird zum Teil der Steuerung des Clusters.** Wer dort
  schreiben darf, kann Tokens fälschen. Die Härtung oben macht das sichtbar und erschwert
  es, schützt aber nicht vor einem Cluster-Admin.
- **Gateway-Controller im Vertrauenspfad.** Traefik hält das Serverzertifikat und
  entscheidet über das Routing. Wer Traefik kontrolliert, kann ebenfalls ausliefern, was
  er will. Wie die Route beschrieben und gegen andere Namespaces geschützt wird, steht in
  [ADR 0006](0006-gateway-api-statt-ingress.md).
- **Härtung greift erst nach `bootstrap`.** k3s installiert Traefik beim Start mit den
  Standardwerten; Traefik-Konfiguration und Admission-Regeln kommen erst mit `bootstrap`.
  Bis dahin gibt es im Lab nur den Admin.
- **Plausibilitätsprüfung per Textsuche.** Das Image des `sync`-Containers enthält kein
  `jq`; geprüft wird per `grep` auf `issuer`, `jwks_uri` und mindestens eine `kid`. Die
  Quelle ist der API-Server über TLS mit dessen CA, die Prüfung fängt also Fehler ab,
  keine Angriffe.
- **Image-Regel prüft nur den Digest**, nicht, welches Image es ist.
- **Alarm nur über Logs.** Jede neue oder entfallene `kid` wird protokolliert. Ob sie zu
  einer geplanten Rotation gehört, muss das Monitoring außerhalb entscheiden.
- **Verfügbarkeit hängt am Gateway.** Siehe oben; Keycloak und Validator überbrücken
  kurze Ausfälle mit ihrem Cache.
- **Im Lab startet ein Neustart des API-Servers den ganzen Knoten neu**, also auch die
  Discovery-Pods. In einem echten Cluster laufen die Pods während eines Neustarts des
  API-Servers weiter.

## Alternativen

- **Push per mTLS zu einem Webserver außerhalb** (ADR 0003). Braucht ein
  Client-Zertifikat im Cluster und einen Schreibweg von außen erreichbar; Begründung oben.
- **Keycloak holt direkt beim API-Server**, mit anonymem Zugriff auf die beiden Pfade.
  Der API-Server müsste dann aus dem Netz des Fachbereichs erreichbar sein, mit seiner
  gesamten vor der Anmeldung erreichbaren Angriffsfläche, und die Issuer-URL wäre an seine
  Adresse gebunden. Bei verwalteten Clustern in der Cloud übernimmt der Anbieter diese
  Rolle; on-prem spricht mehr für den Pod dazwischen.
- **Eigener Dienst (z. B. in Go) statt nginx + Skript.** Näher an Produktion, aber ein
  eigenes Image, das gebaut und in den Cluster gebracht werden muss. Für das Lab genügen
  öffentliche Images mit festem Digest.
- **Alarm nur bei `kid`, die nicht angekündigt wurde** (z. B. über eine ConfigMap, die
  `sa-keys stage` befüllt). Bewusst weggelassen; das gehört ins Monitoring.

## Weiterlesen

- [0003-getrennte-vertrauensbereiche-interne-pki.md](0003-getrennte-vertrauensbereiche-interne-pki.md) – interne PKI und Netztrennung.
- [../technical/bootstrap-und-issuer.md](../technical/bootstrap-und-issuer.md) – Discovery-Pod, Gateway und Härtung im Detail.
