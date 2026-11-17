# ADR 0003: Getrennte Vertrauensbereiche – Publisher im Cluster, Upload per mTLS, interne PKI

**Datum:** 2026-11-17
**Status:** Angenommen (ergänzt [ADR 0002](0002-eigenstaendiger-issuer-endpoint.md))

## Für wen ist das / was lernst du hier

Diese Notiz erklärt, wie Discovery-Dokument und JWKS aus dem Cluster zum Issuer-Endpoint
`issuer-web` kommen, wer dort schreiben darf und woher der Validator sein Vertrauen in
`issuer-web` bezieht. Begriffe siehe [../domain.md](../domain.md).

## Kontext

[ADR 0002](0002-eigenstaendiger-issuer-endpoint.md) legt fest, dass ein eigenständiger
Issuer-Endpoint die Metadaten ausliefert und der Validator den API-Server nie anspricht.
Offen bleibt, wie die Metadaten dorthin gelangen und worauf ihre Echtheit beruht.

In einem realen Aufbau liegen API-Server (im Cluster) und Issuer-Endpoint (außerhalb,
eventuell ganz woanders) in getrennten Vertrauens- und Netzbereichen. Wer das JWKS am
Issuer-Endpoint austauschen kann, kann beliebige Tokens ausstellen, die der Validator
akzeptiert. Der Schreibweg ist damit die kritischste Stelle des ganzen Aufbaus.

Annahme: Eine interne PKI ist vorhanden, und ihr Root-Zertifikat ist auf allen Systemen,
die es brauchen, bereits auf anderem Weg verteilt (Betriebssystem-Trust-Store,
Konfigurationsmanagement). Die bestehende Client-Authentisierung über mTLS nutzt sie schon.

## Entscheidung

**Veröffentlichung: Push aus dem Cluster.**
Ein Deployment `jwks-publisher` im Namespace `wif-publisher` liest Discovery-Dokument und
JWKS mit dem eigenen ServiceAccount vom API-Server. Der ServiceAccount hat nur die
eingebaute ClusterRole `system:service-account-issuer-discovery` (`GET` auf genau diese
beiden Pfade). Alle 15 Sekunden vergleicht der Publisher den Stand mit dem, was
`issuer-web` gerade ausliefert, und lädt nur bei einer Abweichung hoch. Dabei protokolliert
er, welche `kid` hinzugekommen oder weggefallen sind. Eine Schlüsselrotation erkennt er so
ohne eigenen Mechanismus: Das JWKS des API-Servers ändert sich.

Pull von außen wurde verworfen, weil er einen Netzweg und ein Credential *in* den Cluster
bräuchte.

**Schreibzugriff: mTLS mit einem Zertifikat für genau eine Komponente.**
`issuer-web` hat zwei Listener:

- `:443` (öffentlich) liefert die beiden Dokumente nur per `GET` aus.
- `:8443` nimmt `PUT` auf genau diese beiden Pfade an, hört nur auf der Adresse im
  Cluster-Netz und verlangt ein Client-Zertifikat der internen CA mit
  genau dem DN `CN=jwks-publisher,O=WIF Lab` (exakter Vergleich, keine Teilstring-Suche). Fehlt das Zertifikat oder stammt es von einer anderen CA, bricht
  nginx mit `400` ab; ein anderer CN ergibt `403`. Jeder Upload wird mit dem DN des Clients
  protokolliert.

Der Publisher weist sich gegenüber `issuer-web` nie mit einem ServiceAccount-Token aus.
Ein solches Token würde gegen genau die Schlüssel geprüft, die er gerade veröffentlicht,
und wer das JWKS manipuliert, könnte sich das passende Token selbst ausstellen.

**Vertrauen des Validators: interne CA statt mitgeliefertem Zertifikat.**
Das Serverzertifikat von `issuer-web` stammt aus der internen PKI. Der Validator vertraut
ausschließlich dem Root-Zertifikat dieser CA. Es erreicht ihn über einen anderen Weg als die
Daten (im Lab: das schreibgeschützte Volume `ca-trust`, stellvertretend für die
anderweitige Verteilung).

**Abbildung im Lab.**

- `pki-init` erzeugt eine Lab-CA als Stellvertreter der internen PKI und davon abgeleitet
  das Serverzertifikat von `issuer-web` und das Client-Zertifikat des Publishers. Jedes
  Artefakt liegt in einem eigenen Volume; den CA-Schlüssel sieht nur `pki-init`.
- `bootstrap` übergibt dem Publisher Zertifikat und CA als Secret und ConfigMap. Real
  übernimmt das cert-manager oder die PKI-Anbindung der Plattform.
- Drei Docker-Netze: `cluster-net` (Cluster und Upload-Listener), `relying-net`
  (öffentlicher Listener und Validator), `workload-net` (Pods rufen den Validator auf).
  Der API-Server lauscht nur auf seiner Adresse in `cluster-net`
  (`--bind-address`), ist also vom Validator aus nicht erreichbar.
- Es gibt kein gemeinsames Volume mehr zwischen Cluster-Seite und Validator.
- Die ServiceAccount-Signaturschlüssel verwaltet `sa-keys`. Bei einer Rotation wird ein
  neuer Schlüssel zum Signierschlüssel; der bisherige bleibt als reiner Prüfschlüssel im
  JWKS, bis zur nächsten Rotation.

## Konsequenzen

### Positiv

- Die Trennung zwischen Cluster, Issuer-Endpoint und Relying Party ist im Lab sichtbar und
  wird getestet (Netz, Upload-Rechte, fremde CA, Rotation).
- Die Echtheit der Schlüssel hängt an zwei klar benannten Ankern: dem Publisher-Zertifikat
  (Schreiben) und der internen CA (Lesen) – nicht mehr am Docker-Host allein.
- Schlüsselrotation läuft ohne manuellen Eingriff am Issuer-Endpoint durch.

### Negativ / Kompromisse

- **Keine inhaltliche Prüfung beim Upload.** `issuer-web` prüft nicht, ob `issuer` passt
  oder die Schlüssel plausibel sind. Wer das Publisher-Zertifikat besitzt, kann jedes JWKS
  hochladen.
- **JWKS nicht zusätzlich signiert.** Eine Signatur würde nur dagegen schützen, dass der
  Host von `issuer-web` selbst kompromittiert ist, und bräuchte einen zweiten
  Vertrauensanker beim Validator. Im Lab bewusst weggelassen.
- **Überwachung nur über Logs.** Publisher und nginx protokollieren jede Änderung. Liefert
  `issuer-web` etwas aus, das der Publisher nicht hochgeladen hat, warnt er und stellt den
  Stand des Clusters wieder her – im Abstand von bis zu 15 Sekunden bleibt ein fremdes JWKS
  also sichtbar. Ein Alarm bei einem neuen `kid` außerhalb einer geplanten Rotation ist
  nicht umgesetzt.
- **Rotationsfenster.** Der alte Schlüssel muss mindestens maximale Token-Laufzeit plus
  Cache-TTL des Validators im JWKS bleiben. Im Lab bleibt er bis zur nächsten Rotation;
  das ist nur sicher, solange zwischen zwei Rotationen mehr als diese Zeit liegt.
- **Rotation braucht einen Neustart des API-Servers**, weil kube-apiserver die
  Schlüsseldateien nur beim Start liest.
- **Kein Zertifikatswechsel, keine Sperrlisten.** Die Lab-Zertifikate laufen 825 Tage und
  werden nicht erneuert.

## Alternativen

- **Pull durch `issuer-web` aus dem Cluster.** Bräuchte einen Netzweg und ein Credential in
  den Cluster – genau die Kopplung, die vermieden werden soll.
- **Publisher authentisiert sich mit einem ServiceAccount-Token.** Zirkulär (siehe oben).
- **Self-signed Zertifikat von `issuer-web`, über ein gemeinsames Volume verteilt.** Das
  Vertrauen hinge allein am Docker-Host, und Daten wie Vertrauensanker liefen über
  denselben Kanal.
- **Rotation über `k3s certificate rotate-ca`.** Bindet die Rotation an die k3s-eigene
  CA-Verwaltung; mit eigenen Schlüsseldateien (`service-account-signing-key-file`,
  `service-account-key-file`) bleibt der Ablauf auf jeden Kubernetes-Cluster übertragbar.

## Weiterlesen

- [0002-eigenstaendiger-issuer-endpoint.md](0002-eigenstaendiger-issuer-endpoint.md) – warum es den Issuer-Endpoint gibt.
- [../technical/trust-und-tls.md](../technical/trust-und-tls.md) – Zertifikate und Vertrauenskette im Detail.
- [../technical/bootstrap-und-issuer.md](../technical/bootstrap-und-issuer.md) – PKI, Publisher und Upload im Detail.
