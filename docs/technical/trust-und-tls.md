# Vertrauen und TLS im Lab

**Für wen / was lernst du hier:** Du kennst JWT/JWS/JWK, aber nicht die Feinheiten von TLS:
Serverzertifikat vs. CA, SAN, SNI, Hostname-Verification, PKIX-Pfadbildung, Truststore.
Diese Seite erklärt diese Begriffe kurz, zeigt dann die TLS-Vertrauensbeziehungen im
Lab (A–C und I für den Validator-Pfad, D–H für Keycloak und `service-r`) und wie `JwksTrustConfig`
im Validator einen Truststore baut, der nur der internen CA vertraut. Die Entscheidungen dahinter:
[ADR 0003](../adr/0003-getrennte-vertrauensbereiche-interne-pki.md) (interne PKI) und
[ADR 0005](../adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md) (Issuer-Pod hinter einem
Ingress).

---

## Ein paar Grundbegriffe

### Serverzertifikat vs. CA

Ein **Serverzertifikat** identifiziert *einen* Server (z. B. `issuer.wif.local`). Es enthält dessen
öffentlichen Schlüssel und die Namen, für die es gilt.

Eine **Certificate Authority (CA)** ist eine Instanz, die Zertifikate **unterschreibt**.
Ein Client vertraut nicht jedem einzelnen Serverzertifikat, sondern der CA – und akzeptiert
damit alle von ihr unterschriebenen Zertifikate. Im Lab ist das die Root-CA der Lab-PKI
(`tools/pki-init.sh`), Stellvertreterin für die interne PKI einer Organisation.

### SAN und Hostname-Verification

Nach dem TLS-Handshake prüft der Client: *Gilt dieses Zertifikat überhaupt für den Namen, den
ich angesprochen habe?* Diese **Hostname-Verification** vergleicht den angefragten Hostnamen
(z. B. `issuer.wif.local`) mit der Liste der **Subject Alternative Names (SAN)** im Zertifikat. Der
alte `Subject`/`CN`-Eintrag wird von modernen Clients (auch Java) dafür **ignoriert**.

Deshalb stellt `pki-init` das Ingress-Zertifikat mit `subjectAltName=DNS:issuer.wif.local` aus:
ohne diesen SAN-Eintrag würde der Validator den Handshake mit *"No subject alternative DNS
name matching issuer.wif.local found"* abbrechen.

### SNI

**Server Name Indication** ist eine TLS-Erweiterung: Der Client nennt schon im ersten
Handshake-Paket den Hostnamen, den er erreichen will. Ein Server mit mehreren Zertifikaten –
hier Traefik – wählt danach das passende aus. Mit **strict SNI** bricht Traefik den Handshake
ab, wenn es für den genannten Namen kein Zertifikat hat, statt ein Standardzertifikat zu
zeigen.

### PKIX-Pfadbildung / "path building"

**PKIX** ist der Standard (RFC 5280), nach dem Java Zertifikatsketten validiert. Der Client
versucht, eine **Kette** ("path") vom präsentierten Serverzertifikat bis zu einem Zertifikat
zu bilden, dem er **vertraut** (einem Anker im Truststore). Im Lab ist die Kette
`issuer.wif.local-Zertifikat → Lab-Root-CA`; die Root-CA liegt im Truststore des Validators.

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

## Beziehung A – bootstrap/demo/Issuer-Pod → Kubernetes-API-Server

**Wer:** die Container `bootstrap` und `demo` (via `kubectl`) sowie der Container `sync` im
Issuer-Pod.
**Wohin:** `https://k3s-server:6443` bzw. im Cluster
`https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT`.

**Vertrauensmaterial:** die **Cluster-CA** von k3s. `kubectl` liest sie aus der kubeconfig
(`certificate-authority-data`), `sync` aus dem projizierten Volume
(`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`, aus der ConfigMap
`kube-root-ca.crt`). Diese CA hat mit der internen PKI nichts zu tun.

**Der Namensdreh:** `bootstrap.sh` und `demo.sh` schreiben die Server-Adresse der kubeconfig
per `sed` auf `https://k3s-server:6443` um. Damit der Handshake mit diesem Namen gelingt,
läuft der API-Server mit `--tls-san=k3s-server` – der Name steht als **SAN** im
API-Server-Zertifikat.

Diese Beziehung betrifft die **Relying Parties nicht** – Validator und Keycloak sprechen nie
mit dem API-Server und erreichen ihn über kein Netz.

---

## Beziehung B – `ingress-lb` und Traefik: wo TLS endet

**Wer:** jeder Client von `https://issuer.wif.local` (Validator, Keycloak, `demo`).
**Weg:** `ingress-lb` (`172.31.8.20:443`, Alias `issuer.wif.local` in `relying-net`) reicht
die TCP-Verbindung unverändert an Traefiks Node-Port `172.31.7.2:30443` durch. `ingress-lb`
sieht nur verschlüsselte Daten und hält kein Zertifikat.

**TLS-Endpunkt:** Traefik im Cluster. Es präsentiert für `issuer.wif.local` das Secret
`issuer-tls` (ausgestellt von der internen CA, SAN `DNS:issuer.wif.local`) und reicht die
Anfrage per HTTP an den Container `web` (Port 8080) weiter. Diesen letzten Abschnitt im
Cluster schützt die NetworkPolicy `issuer-from-ingress-controller`: Nur Traefik-Pods aus
`kube-system` erreichen Port 8080.

**Strict SNI** (`manifests/01-traefik-config.yaml`, TLS-Option `default`, mindestens TLS 1.2):
Für einen Hostnamen ohne Zertifikat scheitert schon der Handshake. Ergebnis im Lab
(`demo.sh`, Prüfung 6):

| Anfrage über `ingress-lb` | Ergebnis |
|---|---|
| SNI `issuer.wif.local` | Handshake mit dem Ingress-Zertifikat |
| SNI `other.wif.local` | kein Handshake |
| SNI `kubernetes.default.svc` | kein Handshake – kein Weg zum API-Server |
| SNI `issuer.wif.local`, `Host: other.wif.local` | `404` bzw. `421`, keine Route |

Die Issuer-Route trägt die Routing-Priorität `1000000000`; andere Namespaces dürfen weder den
Host noch Router-Annotationen setzen
([bootstrap-und-issuer.md](bootstrap-und-issuer.md#härtung-von-wif-issuer)). Traefik teilt
sich einen Zertifikatsspeicher mit allen Ingress-Objekten: Ein fremdes Zertifikat für
`issuer.wif.local` kann die Auswahl stören – die Echtheit nicht, denn die Relying Parties
vertrauen nur der internen CA, wohl aber die Verfügbarkeit. Wer Traefik kontrolliert, hält das
Serverzertifikat und entscheidet über das Routing – Traefik gehört damit zum Vertrauenspfad
([ADR 0005](../adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md), Kompromisse).

---

## Beziehung C – Validator → `issuer.wif.local`

**Wer:** der `validator`-Container (Java, Nimbus `DefaultResourceRetriever`).
**Wohin:** `https://issuer.wif.local` – für OIDC-Discovery (`/.well-known/openid-configuration`)
und den JWKS-Abruf (`/openid/v1/jwks`), über `ingress-lb` (Beziehung B).

**Vertrauensmaterial:** ausschließlich die PEM-Datei `/trust/ca.crt` – das Root-Zertifikat der
internen CA aus dem Volume `ca-trust` (`WIF_ISSUER_CA=/trust/ca.crt`). Es erreicht den
Validator über einen anderen Weg als die Daten; real wäre es über Betriebssystem-Trust-Store
oder Konfigurationsmanagement verteilt.

Ergebnis: Der JWKS-Abruf läuft über **echtes TLS mit Hostname-Verification**. Er gelingt genau
dann, wenn die Gegenstelle ein von der internen CA ausgestelltes Zertifikat für den Namen
`issuer.wif.local` vorzeigt. Kein `curl -k`, keine Änderung am globalen JVM-Truststore. Die
`jwks_uri` aus dem Discovery-Dokument nimmt der Validator nur auf demselben HTTPS-Origin an
(`JwksUriPolicy`); ein anderer Host mit einem Zertifikat derselben CA wird so nie zur
Schlüsselquelle. Ein
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
ausgehenden Vertrauen des Validators zu `issuer.wif.local` (Beziehung C).

---

## Beziehungen D–H – Keycloak und `service-r`

Keycloak bekommt von `pki-init` ein eigenes Serverzertifikat der internen CA (Volume
`keycloak-tls`, `CN=keycloak`, SAN `DNS:keycloak`, `DNS:localhost`, `IP:127.0.0.1`).
`localhost` und `127.0.0.1` decken die Admin-Konsole über den Host-Port von
`keycloak-admin` ab. Der Schlüssel
gehört uid 1000 (`chmod 400`), weil Keycloak nicht als root läuft.

| Beziehung | Wer → wohin | Vertrauensmaterial |
|---|---|---|
| D | Keycloak → `https://issuer.wif.local` (Discovery + JWKS des Clusters, über `ingress-lb`) | `KC_TRUSTSTORE_PATHS=/trust/ca.crt`: ergänzt Keycloaks Default-Truststore um die Lab-CA; öffentliche CAs bleiben dort vertraut |
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
(Beziehungen F, H, I). In Produktion kommen mTLS (auch der Client weist sich per Zertifikat aus, z. B. über ein
Service Mesh) oder sender-gebundene Tokens (DPoP, mTLS-gebunden) als Option dazu.

---

## Wie `JwksTrustConfig` den Truststore baut

Methode `trustOnly(Path caPem)` in `JwksTrustConfig.java:77`. Schritt für Schritt:

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

`JwksTrustConfig.java:48`:

```java
DefaultResourceRetriever retriever = new DefaultResourceRetriever(
        CONNECT_TIMEOUT_MS,   // 2000
        READ_TIMEOUT_MS,      // 2000
        SIZE_LIMIT_BYTES,     // 64 KiB
        true,                 // disconnectAfterUse (Verbindung nach dem Lesen schließen)
        trustOnly(props.issuerCa()));   // <-- die maßgeschneiderte SSLSocketFactory
```

Dieser `retriever` wird sowohl für die Discovery (`retrieveResource(wellKnown)`,
`JwksTrustConfig.java:67`) als auch vom `JWKSourceBuilder` für den JWKS-Abruf verwendet. Jede
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

**Ursache:** Das Serverzertifikat, das der Ingress für `issuer.wif.local` vorzeigt, stammt nicht von der CA in
`WIF_ISSUER_CA`. Genau das zeigt der Negativtest `validator-foreign-ca`
(`WIF_ISSUER_CA=/pki-demo/foreign-ca.crt`).

| Ursache | Behebung |
|---|---|
| `WIF_ISSUER_CA` zeigt auf eine andere Datei als `/trust/ca.crt` | Wert im Compose-File prüfen: `docker compose exec validator printenv WIF_ISSUER_CA` |
| Einzelne PKI-Volumes gelöscht (z. B. nur `pki-ca`), `pki-init` hat eine neue CA erzeugt, im Secret `issuer-tls` steht noch das alte Zertifikat | `docker compose up -d` (`bootstrap` schreibt das Secret neu), dann `docker compose up -d --force-recreate validator keycloak`; im Zweifel `docker compose down -v` und neu starten |
| Falscher Hostname im SAN (Meldung: *No subject alternative DNS name matching …*) | `WIF_ISSUER` muss `https://issuer.wif.local` sein; das Zertifikat gilt nur für `DNS:issuer.wif.local` |

Zeigt `WIF_ISSUER` auf einen anderen Host (etwa den API-Server), scheitert die Discovery
schon vorher: Der Validator erreicht vom Cluster nur `ingress-lb :443`. Dann
`cp .env.example .env` und `docker compose up -d --force-recreate validator`.

---

## Der Unterschied zur Signatur-Vertrauenswurzel

Nicht verwechseln: Es gibt hier **zwei** voneinander unabhängige Vertrauensketten:

1. **TLS-Transportvertrauen** – "rede ich mit dem echten `issuer.wif.local`?" → über
   `/trust/ca.crt` und den Truststore mit der internen CA (Beziehung C).
2. **Token-Signaturvertrauen** – "ist dieses JWT mit einem Cluster-Schlüssel signiert?" → über
   die öffentlichen Schlüssel im JWKS, das der Issuer-Pod vom API-Server übernimmt. Das
   sind die ServiceAccount-Signaturschlüssel aus `sa-keys` (RSA, `RS256`). Siehe
   [validator.md](validator.md).

Das TLS-Zertifikat schützt nur den Transportweg der Metadaten. Dass im JWKS die richtigen
Schlüssel stehen, sichert der Cluster selbst: Es gibt keinen Schreibweg von außen, `sync`
liest nur beim API-Server und übernimmt nur plausible Stände, und der Namespace `wif-issuer`
ist durch RBAC, Admission Policies und NetworkPolicies geschützt
([bootstrap-und-issuer.md](bootstrap-und-issuer.md#härtung-von-wif-issuer)). Wer dort oder an
Traefik schreiben darf, kann trotzdem ausliefern, was er will; das JWKS ist nicht zusätzlich
signiert ([ADR 0005](../adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md), Kompromisse).

---

## Weiterlesen

- [validator.md](validator.md) – die vollständige Nimbus-Validierungskette und die Endpunkte
- [autorisierungsserver.md](autorisierungsserver.md) – Keycloak und `service-r`
- [bootstrap-und-issuer.md](bootstrap-und-issuer.md) – Lab-PKI, Issuer-Pod, Ingress und
  Härtung im Detail
- [architecture.md](architecture.md) – Volumes und Netze
- [build-und-betrieb.md](build-und-betrieb.md) – weitere häufige Fehlerbilder
- [../kubernetes-primer.md](../kubernetes-primer.md) – Cluster-CA, kubeconfig
- [../use-cases.md](../use-cases.md) – die Abläufe end to end
