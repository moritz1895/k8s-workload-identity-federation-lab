# Vertrauen und TLS im Lab

**Für wen / was lernst du hier:** Du kennst JWT/JWS/JWK, aber nicht die Feinheiten von TLS:
Serverzertifikat vs. CA, SAN, Hostname-Verification, PKIX-Pfadbildung, Truststore. Diese Seite
erklärt diese Begriffe kurz und zeigt dann die **zwei** TLS-Vertrauensbeziehungen im Lab und
wie `JwksTrustConfig` im Validator einen Truststore mit nur einem einzigen Zertifikat baut.

---

## Ein paar Grundbegriffe

### Serverzertifikat vs. CA

Ein **Serverzertifikat** identifiziert *einen* Server (z. B. `issuer-web`). Es enthält dessen
öffentlichen Schlüssel und die Namen, für die es gilt.

Eine **Certificate Authority (CA)** ist eine Instanz, die Serverzertifikate **unterschreibt**.
Ein Client vertraut nicht jedem einzelnen Serverzertifikat, sondern der CA – und akzeptiert
damit alle von ihr unterschriebenen Serverzertifikate.

Ein **self-signed Zertifikat** ("selbstsigniert") hat keine separate CA: es unterschreibt sich
mit seinem eigenen Schlüssel selbst. Es ist Serverzertifikat und CA in einem. Kein Client
vertraut ihm automatisch – man muss es explizit hinterlegen. `issuer-web` benutzt so eines
(erzeugt in `tools/bootstrap.sh:21`).

### SAN und Hostname-Verification

Nach dem TLS-Handshake prüft der Client: *Gilt dieses Zertifikat überhaupt für den Namen, den
ich angesprochen habe?* Diese **Hostname-Verification** vergleicht den angefragten Hostnamen
(z. B. `issuer-web`) mit der Liste der **Subject Alternative Names (SAN)** im Zertifikat. Der
alte `Subject`/`CN`-Eintrag wird von modernen Clients (auch Java) dafür **ignoriert**.

Deshalb steht im Bootstrap `-addext "subjectAltName=DNS:issuer-web"`: ohne diesen SAN-Eintrag
würde der Validator den Handshake mit *"No subject alternative DNS name matching issuer-web
found"* abbrechen.

### PKIX-Pfadbildung / "path building"

**PKIX** ist der Standard (RFC 5280), nach dem Java Zertifikatsketten validiert. Der Client
versucht, eine **Kette** ("path") vom präsentierten Serverzertifikat bis zu einem Zertifikat
zu bilden, dem er **vertraut** (einem Anker im Truststore). Bei einer echten CA ist die Kette
`Server → Zwischen-CA → Root-CA`. Bei einem self-signed Zertifikat ist die Kette genau ein
Glied lang – und dieses eine Glied *selbst* muss im Truststore liegen.

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

---

## Beziehung A – bootstrap/demo → Kubernetes-API-Server

**Wer:** die Container `bootstrap` und `demo` (via `kubectl`).
**Wohin:** `https://k3s-server:6443` (der API-Server).

**Vertrauensmaterial:** Die **Cluster-CA** ist direkt in der kubeconfig eingebettet
(`certificate-authority-data`, Base64). k3s erzeugt diese CA beim ersten Start und schreibt
die kubeconfig ins Volume `kubeconfig`. `kubectl` liest die CA von dort und braucht keinen
externen Truststore.

**Der Namensdreh:** k3s trägt in die kubeconfig `https://127.0.0.1:6443` ein. `bootstrap.sh`
und `demo.sh` schreiben das per `sed` auf `https://k3s-server:6443` um
(`tools/bootstrap.sh:10`). Damit der Handshake mit dem *neuen* Namen `k3s-server` gelingt,
wurde der API-Server mit `--tls-san=k3s-server` gestartet (`compose.yaml:26`) – der Name steht
also als **SAN** im API-Server-Zertifikat, und die Hostname-Verification geht durch.

Diese Beziehung betrifft den **Validator nicht** – er spricht nie mit dem API-Server.

---

## Beziehung B – Validator → `issuer-web`

**Wer:** der `validator`-Container (Java, Nimbus `DefaultResourceRetriever`).
**Wohin:** `https://issuer-web` – für OIDC-Discovery (`/.well-known/openid-configuration`) und
den JWKS-Abruf (`/openid/v1/jwks`).

**Vertrauensmaterial:** ausschließlich die eine PEM-Datei `/oidc/tls.crt` – das self-signed
Zertifikat, das `bootstrap` erzeugt hat und das `nginx` als `ssl_certificate` präsentiert
(`tools/nginx-issuer.conf:10`). Der Validator mountet das Volume `oidc-web` **read-only**
(`compose.yaml:102`) und liest daraus nur diese Datei (`WIF_ISSUER_CA=/oidc/tls.crt`).

Ergebnis: Der JWKS-Abruf läuft über **echtes TLS mit Hostname-Verification**. Er gelingt genau
dann, wenn die Gegenstelle dieses eine Zertifikat für den Namen `issuer-web` vorzeigt – und
scheitert bei jedem anderen Zertifikat. Kein `curl -k`, keine Änderung am globalen
JVM-Truststore.

---

## Wie `JwksTrustConfig` den Ein-Zertifikat-Truststore baut

Methode `trustOnly(Path caPem)` in `JwksTrustConfig.java:75`. Schritt für Schritt:

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

Der so erzeugte `SSLContext` kennt **nur** die Anker aus `/oidc/tls.crt`. Die globalen
`cacerts` sind nicht enthalten. Eine PKIX-Pfadbildung gelingt also ausschließlich zu diesem
einen self-signed Zertifikat.

### Übergabe an Nimbus

`JwksTrustConfig.java:46`:

```java
DefaultResourceRetriever retriever = new DefaultResourceRetriever(
        CONNECT_TIMEOUT_MS,   // 2000
        READ_TIMEOUT_MS,      // 2000
        SIZE_LIMIT_BYTES,     // 64 KiB
        true,                 // disconnectAfterUse (Verbindung nach dem Lesen schließen)
        trustOnly(props.issuerCa()));   // <-- die maßgeschneiderte SSLSocketFactory
```

Dieser `retriever` wird sowohl für die Discovery (`retrieveResource(wellKnown)`,
`JwksTrustConfig.java:65`) als auch vom `JWKSourceBuilder` für den JWKS-Abruf verwendet. Jede
HTTPS-Verbindung, die Nimbus im Validator aufbaut, nutzt damit den Ein-Zertifikat-Truststore.

### Warum der 5-Argument-Konstruktor?

`nimbus-jose-jwt` **10.9.1** bietet auf `DefaultResourceRetriever` **keine** Setter-Methode
wie `setSSLSocketFactory(...)`. Die einzige unterstützte Art, eine eigene `SSLSocketFactory`
zu hinterlegen, ist der Konstruktor mit fünf Argumenten
`(connectTimeout, readTimeout, sizeLimit, disconnectAfterUse, sslSocketFactory)`. Deshalb wird
im Code exakt diese Signatur benutzt – nicht aus Stilgründen, sondern weil es die einzige
verfügbare Schnittstelle ist.

---

## Typische Falle: `PKIX path building failed`

**Symptom:** Der Validator-Container startet nicht sauber (Healthcheck bleibt `unhealthy`),
im Log:

```
... unable to find valid certification path to requested target
... PKIX path building failed
```

**Häufigste Ursache:** `WIF_ISSUER` zeigt auf den **API-Server** statt auf `issuer-web` – z. B.
eine veraltete `.env` aus einer früheren Lab-Variante, in der der API-Server selbst der
Aussteller war. Dann versucht der Validator, `https://<api-server>/.well-known/...` über TLS
zu laden, bekommt aber das **API-Server-Zertifikat** präsentiert – das ist von der Cluster-CA
unterschrieben, und diese CA ist **nicht** in `/oidc/tls.crt`. Die PKIX-Pfadbildung findet
keinen Anker → Abbruch.

**Prüfen / beheben:**

```bash
docker compose exec validator printenv WIF_ISSUER    # muss https://issuer-web sein
grep WIF_ISSUER .env                                 # ggf. auf https://issuer-web setzen
cp .env.example .env                                 # oder die Vorlage frisch übernehmen
docker compose up -d --force-recreate validator
```

Weitere Varianten derselben Meldung:

| Ursache | Behebung |
|---|---|
| `oidc-web` gelöscht/neu, aber Validator-Container hat noch alte Sicht | `docker compose up -d --force-recreate validator` |
| `tls.crt` wurde neu erzeugt (Volume mit `down -v` gelöscht), `issuer-web` liefert aber noch das alte | Ganzen Stack neu starten, nicht nur einzelne Services |
| Falscher Hostname im SAN (Meldung: *No subject alternative DNS name matching …*) | Zertifikat mit `subjectAltName=DNS:issuer-web` neu erzeugen (Volume löschen, Bootstrap erneut) |

---

## Der Unterschied zur Signatur-Vertrauenswurzel

Nicht verwechseln: Es gibt hier **zwei** voneinander unabhängige Vertrauensketten für die
Verbindung Validator ↔ `issuer-web`:

1. **TLS-Transportvertrauen** – "rede ich mit dem echten `issuer-web`?" → über `/oidc/tls.crt`
   und den Ein-Zertifikat-Truststore (diese Seite).
2. **Token-Signaturvertrauen** – "ist dieses JWT mit einem Cluster-Schlüssel signiert?" → über
   die öffentlichen Schlüssel im JWKS (`jwks.json`), die `bootstrap` aus dem Cluster kopiert
   hat. Das sind die k3s-ServiceAccount-Signaturschlüssel (RSA, `RS256`). Siehe
   [validator.md](validator.md).

Das TLS-Zertifikat schützt nur den Transportweg der Metadaten; die eigentliche
Token-Prüfung hängt an den JWKS-Schlüsseln.

---

## Weiterlesen

- [validator.md](validator.md) – die vollständige Nimbus-Validierungskette und die Endpunkte
- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – wie das Zertifikat und die Metadaten
  entstehen, SAN im Detail
- [architecture.md](architecture.md) – die Volumes und wer `oidc-web` wie mountet
- [build-und-betrieb.md](build-und-betrieb.md) – weitere häufige Fehlerbilder
- [../kubernetes-primer.md](../kubernetes-primer.md) – Cluster-CA, kubeconfig
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
