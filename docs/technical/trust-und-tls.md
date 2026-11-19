# Vertrauen und TLS im Lab

**Für wen / was lernst du hier:** Du kennst JWT/JWS/JWK, aber nicht die Feinheiten von TLS:
Serverzertifikat vs. CA, SAN, Hostname-Verification, PKIX-Pfadbildung, Truststore, mTLS.
Diese Seite erklärt diese Begriffe kurz, zeigt dann die TLS-Vertrauensbeziehungen im
Lab (A–C und I für den Validator-Pfad, D–H für Keycloak und `service-r`) und wie `JwksTrustConfig`
im Validator einen Truststore baut, der nur der internen CA vertraut. Die Entscheidung dahinter:
[ADR 0003](../adr/0003-getrennte-vertrauensbereiche-interne-pki.md).

---

## Ein paar Grundbegriffe

### Serverzertifikat vs. CA

Ein **Serverzertifikat** identifiziert *einen* Server (z. B. `issuer-web`). Es enthält dessen
öffentlichen Schlüssel und die Namen, für die es gilt.

Eine **Certificate Authority (CA)** ist eine Instanz, die Zertifikate **unterschreibt**.
Ein Client vertraut nicht jedem einzelnen Serverzertifikat, sondern der CA – und akzeptiert
damit alle von ihr unterschriebenen Zertifikate. Im Lab ist das die Root-CA der Lab-PKI
(`tools/pki-init.sh`), Stellvertreterin für die interne PKI einer Organisation.

### SAN und Hostname-Verification

Nach dem TLS-Handshake prüft der Client: *Gilt dieses Zertifikat überhaupt für den Namen, den
ich angesprochen habe?* Diese **Hostname-Verification** vergleicht den angefragten Hostnamen
(z. B. `issuer-web`) mit der Liste der **Subject Alternative Names (SAN)** im Zertifikat. Der
alte `Subject`/`CN`-Eintrag wird von modernen Clients (auch Java) dafür **ignoriert**.

Deshalb stellt `pki-init` das Serverzertifikat mit `subjectAltName=DNS:issuer-web` aus: ohne
diesen SAN-Eintrag würde der Validator den Handshake mit *"No subject alternative DNS name
matching issuer-web found"* abbrechen.

### PKIX-Pfadbildung / "path building"

**PKIX** ist der Standard (RFC 5280), nach dem Java Zertifikatsketten validiert. Der Client
versucht, eine **Kette** ("path") vom präsentierten Serverzertifikat bis zu einem Zertifikat
zu bilden, dem er **vertraut** (einem Anker im Truststore). Im Lab ist die Kette
`issuer-web-Zertifikat → Lab-Root-CA`; die Root-CA liegt im Truststore des Validators.

Findet Java keine Kette zu einem vertrauten Anker, scheitert der Handshake mit der
charakteristischen Meldung:

```
sun.security.provider.certpath.SunCertPathBuilderException:
  unable to find valid certification path to requested target
        ... PKIX path building failed ...
```

### Truststore

Ein **Truststore** ist ein `KeyStore`-Objekt (bzw. eine Datei), das die Zertifikate enthält,
denen ein Client vertraut – die "trust anchors". Die JVM hat einen globalen Default-Truststore
(`$JAVA_HOME/lib/security/cacerts`) mit den öffentlichen CAs. Man kann aber auch einen
**eigenen, kleinen** Truststore bauen und ihn nur für bestimmte Verbindungen verwenden. Genau
das tut der Validator.

### `SSLSocketFactory`

Java-Klasse, die TLS-Sockets erzeugt. Welchem Truststore diese Sockets vertrauen, steckt im
`SSLContext`, aus dem die Factory stammt. Übergibt man einer HTTP-Bibliothek eine
maßgeschneiderte `SSLSocketFactory`, benutzt sie für ihre Verbindungen genau dieses Vertrauen
– ohne den globalen JVM-Truststore anzufassen.

### mTLS

Bei **mutual TLS** weist sich nicht nur der Server, sondern auch der Client mit einem
Zertifikat aus. Der Server prüft es gegen seine CA und kann anhand des Subjects (hier des
`CN`) entscheiden, was der Client darf.

---

## Beziehung A – bootstrap/demo/Publisher → Kubernetes-API-Server

**Wer:** die Container `bootstrap` und `demo` (via `kubectl`) sowie der Pod `jwks-publisher`.
**Wohin:** `https://k3s-server:6443` bzw. im Cluster `https://kubernetes.default.svc`.

**Vertrauensmaterial:** die **Cluster-CA** von k3s. `kubectl` liest sie aus der kubeconfig
(`certificate-authority-data`), der Publisher aus
`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`. Diese CA hat mit der internen PKI
nichts zu tun.

**Der Namensdreh:** `bootstrap.sh` und `demo.sh` schreiben die Server-Adresse der kubeconfig
per `sed` auf `https://k3s-server:6443` um. Damit der Handshake mit diesem Namen gelingt,
läuft der API-Server mit `--tls-san=k3s-server` – der Name steht als **SAN** im
API-Server-Zertifikat.

Diese Beziehung betrifft den **Validator nicht** – er spricht nie mit dem API-Server und
erreicht ihn über kein Netz.

---

## Beziehung B – Publisher → `issuer-web :8443` (mTLS)

**Wer:** der Pod `jwks-publisher`.
**Wohin:** `https://issuer-web:8443` (im Pod per `hostAliases` → `172.31.7.20`).

| Richtung | Vertrauensmaterial |
|---|---|
| Publisher prüft `issuer-web` | `--cacert /trust/ca.crt` (ConfigMap `internal-ca`) |
| `issuer-web` prüft den Publisher | Client-Zertifikat `/mtls/tls.crt` (Secret `jwks-publisher-mtls`, `CN=jwks-publisher`); nginx prüft es mit `ssl_client_certificate /trust/ca.crt` und vergleicht den `CN` |

Ergebnis im Lab (`demo.sh`, Abschnitt 6):

| Client-Zertifikat | Antwort |
|---|---|
| keins | `400` |
| fremde CA, `CN=jwks-publisher` | `400` |
| interne CA, `CN=not-the-publisher` | `403` |
| interne CA, `CN=jwks-publisher` | Upload (`201`/`204`) |

Details zur nginx-Config: [bootstrap-und-issuer.md](bootstrap-und-issuer.md#block-2--upload-8443-mtls).

---

## Beziehung C – Validator → `issuer-web :443`

**Wer:** der `validator`-Container (Java, Nimbus `DefaultResourceRetriever`).
**Wohin:** `https://issuer-web` – für OIDC-Discovery (`/.well-known/openid-configuration`) und
den JWKS-Abruf (`/openid/v1/jwks`).

**Vertrauensmaterial:** ausschließlich die PEM-Datei `/trust/ca.crt` – das Root-Zertifikat der
internen CA aus dem Volume `ca-trust` (`WIF_ISSUER_CA=/trust/ca.crt`). Es erreicht den
Validator über einen anderen Weg als die Daten; real wäre es über Betriebssystem-Trust-Store
oder Konfigurationsmanagement verteilt.

Ergebnis: Der JWKS-Abruf läuft über **echtes TLS mit Hostname-Verification**. Er gelingt genau
dann, wenn die Gegenstelle ein von der internen CA ausgestelltes Zertifikat für den Namen
`issuer-web` vorzeigt. Kein `curl -k`, keine Änderung am globalen JVM-Truststore. Ein
Validator mit fremder CA (`validator-foreign-ca`) startet nicht.

---

## Beziehung I – Pods und `demo` → Validator

**Wer:** der Pod `consumer` und der `demo`-Container.
**Wohin:** `https://validator.wif.local:8443/whoami` (Pod, per `hostAliases` → `172.31.9.10`)
bzw. `https://validator:8443` (`demo`, `VALIDATOR_URL`).

Der Validator spricht nur HTTPS auf 8443 (TLS 1.3/1.2, Spring-SSL-Bundle `validator`). Sein
Serverzertifikat stellt `pki-init` aus: Volume `validator-tls`, `CN=validator.wif.local`, SAN
`DNS:validator.wif.local`, `DNS:validator`, `DNS:localhost`, `IP:127.0.0.1`, Schlüssel uid
10001. Der Pod prüft es mit `--cacert /etc/internal-ca/ca.crt` (ConfigMap `internal-ca`),
`demo` mit `/trust/ca.crt`. Das SA-Token geht im Pod per `printf … | curl -H @-` über
stdin an curl, steht also in keiner Argumentliste. Die gemeinsame Funktion `tls_only_checks`
in `demo.sh` zeigt nach Prüfung 3 Subject und Aussteller, prüft, dass auf 8080 kein Listener
antwortet, dass Klartext-HTTP auf 8443 mit `400` abgewiesen wird und dass curl nur mit dem
öffentlichen CA-Bundle mit Exit-Code 60 scheitert. Dieses Serverzertifikat ist unabhängig vom
ausgehenden Vertrauen des Validators zu `issuer-web` (Beziehung C).

---

## Beziehungen D–H – Keycloak und `service-r`

Keycloak bekommt von `pki-init` ein eigenes Serverzertifikat der internen CA (Volume
`keycloak-tls`, `CN=keycloak`, SAN `DNS:keycloak`, `DNS:localhost`, `IP:127.0.0.1`).
`localhost` und `127.0.0.1` decken die Admin-Konsole über den Host-Port von
`keycloak-admin` ab. Der Schlüssel
gehört uid 1000 (`chmod 400`), weil Keycloak nicht als root läuft.

| Beziehung | Wer → wohin | Vertrauensmaterial |
|---|---|---|
| D | Keycloak → `https://issuer-web` (Discovery + JWKS des Clusters) | `KC_TRUSTSTORE_PATHS=/trust/ca.crt`: ergänzt Keycloaks Default-Truststore um die Lab-CA; öffentliche CAs bleiben dort vertraut |
| E | `service-r` → `https://keycloak:8443/realms/domain-rst` (Discovery + JWKS des Realms) | PKCS12-Truststore aus `service-r/entrypoint.sh`, enthält **nur** die Lab-CA und ist JVM-Default (`-Djavax.net.ssl.trustStore`) |
| F | Pods `consumer`/`reader`/`stranger` → `https://keycloak:8443` (= `keycloak-gateway`), `demo` → Keycloak direkt | `--cacert /etc/internal-ca/ca.crt` aus der ConfigMap `internal-ca`, die `bootstrap` auch in `wif-demo` anlegt; im `demo`-Container `/trust/ca.crt` |
| G | `keycloak-gateway` und `keycloak-admin` → Keycloak | `proxy_ssl_verify on` gegen `/trust/ca.crt`, `proxy_ssl_name keycloak` |
| H | Pods `consumer`/`reader` → `https://service-r.wif.local:8443` | Serverzertifikat aus `pki-init` (Volume `service-r-tls`, `CN=service-r.wif.local`, SAN `DNS:service-r.wif.local`, `DNS:service-r`, `DNS:localhost`, `IP:127.0.0.1`, Schlüssel uid 10001); die Pods prüfen es mit `--cacert /etc/internal-ca/ca.crt` aus der ConfigMap `internal-ca`. R spricht nur HTTPS (TLS 1.3/1.2); mit dem öffentlichen CA-Bundle scheitert der Handshake (curl Exit-Code 60, Prüfung 14b) |

`keycloak-gateway` und `keycloak-admin` zeigen den Clients dasselbe Keycloak-Zertifikat aus
`keycloak-tls`. Für die Pods ist das Gateway deshalb unter `keycloak` nicht von Keycloak zu
unterscheiden, und Issuer-URL und Hostname-Verification bleiben gleich.

Anders als der Validator (eigene `SSLSocketFactory` nur für Nimbus) setzt `service-r` den
Truststore prozessweit: Der Dienst baut ausgehend nur TLS-Verbindungen zu Keycloak auf. Sein
eigenes Serverzertifikat (Beziehung H) ist davon unabhängig.
Alle Dienste außerhalb des Clusters sprechen damit TLS mit Zertifikaten der internen PKI
(Beziehungen F, H, I). In Produktion kommen mTLS (z. B. Service Mesh) oder sender-gebundene
Tokens (DPoP, mTLS-gebunden) als Option dazu.

---

## Wie `JwksTrustConfig` den Truststore baut

Methode `trustOnly(Path caPem)` in `JwksTrustConfig.java:76`. Schritt für Schritt:

```java
// 1. PEM-Datei einlesen und in X.509-Zertifikatsobjekte umwandeln
CertificateFactory certificateFactory = CertificateFactory.getInstance("X.509");
Collection<? extends Certificate> caCertificates;
try (InputStream in = Files.newInputStream(caPem)) {
    caCertificates = certificateFactory.generateCertificates(in);   // meist genau 1
}

// 2. einen leeren, in-memory Truststore anlegen
KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
trustStore.load(null, null);                 // null, null = frischer, leerer KeyStore

// 3. jedes gelesene Zertifikat als vertrauenswürdigen Anker eintragen
int index = 0;
for (Certificate caCertificate : caCertificates) {
    trustStore.setCertificateEntry("issuer-ca-" + index++, caCertificate);
}

// 4. eine TrustManagerFactory auf genau diesen Truststore initialisieren
TrustManagerFactory trustManagerFactory =
        TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
trustManagerFactory.init(trustStore);

// 5. einen SSLContext mit diesen TrustManagern bauen ...
SSLContext sslContext = SSLContext.getInstance("TLS");
sslContext.init(null, trustManagerFactory.getTrustManagers(), null);
//               ^^^^ keine Client-Key-Manager (kein mTLS)      ^^^^ Default-SecureRandom

// 6. ... und daraus die SSLSocketFactory zurückgeben
return sslContext.getSocketFactory();
```

Der so erzeugte `SSLContext` kennt **nur** die Anker aus `/trust/ca.crt`. Die globalen
`cacerts` sind nicht enthalten. Eine PKIX-Pfadbildung gelingt also ausschließlich zu
Zertifikaten der internen CA.

### Übergabe an Nimbus

`JwksTrustConfig.java:47`:

```java
DefaultResourceRetriever retriever = new DefaultResourceRetriever(
        CONNECT_TIMEOUT_MS,   // 2000
        READ_TIMEOUT_MS,      // 2000
        SIZE_LIMIT_BYTES,     // 64 KiB
        true,                 // disconnectAfterUse (Verbindung nach dem Lesen schließen)
        trustOnly(props.issuerCa()));   // <-- die maßgeschneiderte SSLSocketFactory
```

Dieser `retriever` wird sowohl für die Discovery (`retrieveResource(wellKnown)`,
`JwksTrustConfig.java:66`) als auch vom `JWKSourceBuilder` für den JWKS-Abruf verwendet. Jede
HTTPS-Verbindung, die Nimbus im Validator aufbaut, nutzt damit diesen Truststore.

### Warum der 5-Argument-Konstruktor?

`nimbus-jose-jwt` **10.9.1** bietet auf `DefaultResourceRetriever` **keine** Setter-Methode
wie `setSSLSocketFactory(...)`. Die einzige unterstützte Art, eine eigene `SSLSocketFactory`
zu hinterlegen, ist der Konstruktor mit fünf Argumenten
`(connectTimeout, readTimeout, sizeLimit, disconnectAfterUse, sslSocketFactory)`. Deshalb wird
im Code exakt diese Signatur benutzt – nicht aus Stilgründen, sondern weil es die einzige
verfügbare Schnittstelle ist.

---

## Typische Falle: `PKIX path building failed`

**Symptom:** Der Validator-Container startet nicht sauber (Healthcheck bleibt `unhealthy`
bzw. der Container beendet sich), im Log:

```
... unable to find valid certification path to requested target
... PKIX path building failed
```

**Ursache:** Das Serverzertifikat, das `issuer-web` vorzeigt, stammt nicht von der CA in
`WIF_ISSUER_CA`. Genau das zeigt der Negativtest `validator-foreign-ca`
(`WIF_ISSUER_CA=/pki-demo/foreign-ca.crt`).

| Ursache | Behebung |
|---|---|
| `WIF_ISSUER_CA` zeigt auf eine andere Datei als `/trust/ca.crt` | Wert im Compose-File prüfen: `docker compose exec validator printenv WIF_ISSUER_CA` |
| Einzelne PKI-Volumes gelöscht (z. B. nur `pki-ca`), `pki-init` hat eine neue CA erzeugt, `issuer-web` läuft noch mit dem alten Zertifikat | `docker compose up -d --force-recreate issuer-web validator`, im Zweifel `docker compose down -v` und neu starten |
| Falscher Hostname im SAN (Meldung: *No subject alternative DNS name matching …*) | `WIF_ISSUER` muss `https://issuer-web` sein; das Zertifikat gilt nur für `DNS:issuer-web` |

Zeigt `WIF_ISSUER` auf einen anderen Host (etwa den API-Server), scheitert die Discovery
schon vorher: Der Validator erreicht außer `issuer-web` nichts auf der Cluster-Seite. Dann
`cp .env.example .env` und `docker compose up -d --force-recreate validator`.

---

## Der Unterschied zur Signatur-Vertrauenswurzel

Nicht verwechseln: Es gibt hier **zwei** voneinander unabhängige Vertrauensketten:

1. **TLS-Transportvertrauen** – "rede ich mit dem echten `issuer-web`?" → über
   `/trust/ca.crt` und den Truststore mit der internen CA (Beziehung C).
2. **Token-Signaturvertrauen** – "ist dieses JWT mit einem Cluster-Schlüssel signiert?" → über
   die öffentlichen Schlüssel im JWKS, die der Publisher aus dem Cluster veröffentlicht. Das
   sind die ServiceAccount-Signaturschlüssel aus `sa-keys` (RSA, `RS256`). Siehe
   [validator.md](validator.md).

Das TLS-Zertifikat schützt nur den Transportweg der Metadaten. Dass im JWKS die richtigen
Schlüssel stehen, sichert die Schreibseite (Beziehung B): Nur der Publisher mit seinem
Zertifikat darf es ersetzen. `issuer-web` prüft den Inhalt nicht, und das JWKS ist nicht
zusätzlich signiert ([ADR 0003](../adr/0003-getrennte-vertrauensbereiche-interne-pki.md),
Kompromisse).

---

## Weiterlesen

- [validator.md](validator.md) – die vollständige Nimbus-Validierungskette und die Endpunkte
- [autorisierungsserver.md](autorisierungsserver.md) – Keycloak und `service-r`
- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – Lab-PKI, Publisher und nginx-Config
  im Detail
- [architecture.md](architecture.md) – Volumes und Netze
- [build-und-betrieb.md](build-und-betrieb.md) – weitere häufige Fehlerbilder
- [../kubernetes-primer.md](../kubernetes-primer.md) – Cluster-CA, kubeconfig
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
