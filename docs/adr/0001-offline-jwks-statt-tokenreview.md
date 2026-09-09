# ADR 0001: Token-Prüfung offline über JWKS statt online über TokenReview

**Datum:** 2026-09-09
**Status:** Angenommen

## Für wen ist das / was lernst du hier

Diese Entscheidungsnotiz ("ADR" = Architecture Decision Record) hält fest, warum der
Validator die ServiceAccount-Tokens des Clusters **lokal** prüft und dafür bewusst auf die
Online-Prüfung über die Kubernetes-TokenReview-API verzichtet. Die Begriffe sind in
[../domain.md](../domain.md) erklärt.

## Kontext

Eine Workload im Kubernetes-Cluster (der `consumer`-Pod) will sich gegenüber einem Dienst
**außerhalb** des Clusters ausweisen. Es gibt zwei etablierte Wege, wie dieser externe
Dienst ein Kubernetes-ServiceAccount-Token prüfen kann:

1. **Online, über die TokenReview-API.** Der Dienst schickt das Token an den API-Server und
   bekommt "gültig / ungültig" plus Identität zurück. Das erfordert, dass der Dienst
   - den API-Server über das Netzwerk erreichen kann und
   - selbst ein Cluster-Credential mit der Berechtigung besitzt, `TokenReview` aufzurufen.

2. **Offline, über OIDC-Discovery und JWKS.** Der Dienst lädt einmalig die öffentlichen
   Signaturschlüssel des Ausstellers und prüft danach jedes Token lokal: Signatur, `iss`,
   `aud`, `exp`.

Das Lab soll das Muster "Workload Identity Federation" in seiner verbreiteten Ausprägung
zeigen: Ein Dienst, der die ausstellende Plattform gar nicht kennt und nicht erreichen
können muss, vertraut Tokens allein anhand veröffentlichter, signierter Metadaten - so wie
Cloud-Anbieter untereinander föderieren.

## Entscheidung

Der Validator prüft Tokens **ausschließlich offline**:

- Beim Start macht er OIDC-Discovery gegen `WIF_ISSUER` (`.../.well-known/openid-configuration`),
  verifiziert das `issuer`-Feld und folgt der `jwks_uri`.
- Die JWKS werden geladen und **5 Minuten** zwischengespeichert
  (`JWKS_CACHE_TTL_MS = 300000` in `JwksTrustConfig`), mit Hintergrund-Aktualisierung.
- Pro Anfrage prüft `TokenValidator` (Nimbus JOSE + JWT): Signatur gegen den per `kid`
  ausgewählten Schlüssel (nur `RS256`/`ES256`), `iss` exakt gleich `WIF_ISSUER`, `aud`
  enthält `WIF_AUDIENCE` exakt, `exp`/`nbf` mit 60 s Toleranz, Pflicht-Claims `sub`, `iat`,
  `exp` vorhanden.
- Der Validator ruft den Kubernetes-API-Server **nie** auf. Er besitzt kein
  Cluster-Credential.

Die Token-Laufzeit ist kurz gewählt (`expirationSeconds: 600` im `projected` Volume - das
ist zugleich das Minimum, das die TokenRequest-API zulässt), damit das Zeitfenster ohne
Widerrufsmöglichkeit klein bleibt.

## Konsequenzen

### Positiv

- **Keine Abhängigkeit vom API-Server zur Laufzeit.** Fällt der Cluster kurz aus, prüft der
  Validator mit den gecachten Schlüsseln weiter.
- **Kein Credential beim Prüfer.** Der Validator braucht nur öffentliche Metadaten, kein
  ServiceAccount, keine RBAC-Rolle.
- **Minimale Netzwerk-Kopplung.** Der Validator öffnet genau eine ausgehende Verbindung -
  zum Issuer-Endpoint. Der Cluster muss von außen nicht erreichbar sein.
- **Günstig pro Anfrage.** Nur lokale Signaturprüfung, kein Netzwerk-Roundtrip.
- Entspricht dem realen Federation-Muster und ist damit lehrreich für den PoC.

### Negativ / Kompromisse

- **Kein Widerruf vor `exp`.** Ein ausgestelltes Token bleibt bis zum Ablauf gültig, auch
  wenn Pod oder ServiceAccount längst gelöscht sind. Gegenmittel wären kurze Laufzeiten
  (hier bereits am Minimum), eine `jti`-Sperrliste oder eben doch eine Online-Prüfung.
- **Identitätsdaten sind ein Snapshot.** Der Validator sieht nur, was zum
  Ausstellungszeitpunkt im Token stand, nicht den Live-Zustand des Clusters.
- **Cache-Verzögerung bei Schlüsselrotation.** Nach einem Schlüsselwechsel im Cluster
  akzeptiert der Validator neu signierte Tokens erst, wenn der 5-Minuten-Cache abläuft bzw.
  aktualisiert wurde. Der alte Schlüssel muss also lange genug parallel im JWKS bleiben.
- **Verfügbarkeit verschiebt sich zum Issuer-Endpoint.** Ist `issuer-web` beim allerersten
  Start nicht erreichbar, kommt der Validator nicht hoch (Discovery scheitert).

## Alternativen

- **Online-Prüfung über TokenReview.** Erlaubt sofortigen Widerruf und Live-Identitätsdaten,
  bringt aber eine harte Laufzeit-Abhängigkeit vom API-Server, einen Netzwerk-Roundtrip je
  Anfrage und ein weiteres zu verwaltendes Credential beim externen Dienst mit sich. Für den
  Zweck des Labs - das Federation-Muster zeigen - ist das der falsche Schwerpunkt. Ein
  denkbarer Ausbau wäre ein hybrider Ansatz: offline als Regelfall, TokenReview nur für
  besonders sensible Operationen.
- **Statische, langlebige API-Keys.** In [../domain.md](../domain.md) als Ausgangsproblem
  beschrieben und hier gerade das, was vermieden werden soll.

## Weiterlesen

- [../domain.md](../domain.md#5-offline-validierung-jwks-vs-online-validierung-tokenreview) - die Trade-off-Tabelle offline vs. online.
- [../use-cases.md](../use-cases.md) - wie die Prüfung Schritt für Schritt abläuft.
- [0002-eigenstaendiger-issuer-endpoint.md](0002-eigenstaendiger-issuer-endpoint.md) - wo die JWKS herkommen.
