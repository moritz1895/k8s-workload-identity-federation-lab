# Konzepte und Vokabular: Workload Identity Federation

## Für wen ist das / was lernst du hier

Diese Seite erklärt die **Idee** hinter dem Lab, bevor du dir Kubernetes-Details oder den
Ablauf ansiehst. Du lernst, warum eine Software sich überhaupt ausweisen muss, was der
Begriff "Workload Identity Federation" bedeutet, welche Akteure in diesem PoC (Proof of
Concept, also ein kleiner Machbarkeitsnachweis) mitspielen und warum ein Dienst einem Token
glauben darf, das er komplett **offline** prüft.

Vorausgesetzt wird nur, dass du JSON Web Token (JWT), JSON Web Signature (JWS) und JSON Web
Key Set (JWKS) im Prinzip kennst. Alle Kubernetes-Begriffe werden hier und im
[Kubernetes-Primer](kubernetes-primer.md) beim ersten Auftreten erklärt.

---

## 1. Das Problem: Wie weist sich eine Software gegenüber einer anderen aus?

Stell dir zwei Programme vor, die über das Netzwerk miteinander reden:

- **Programm A** (der "Client" oder die "Workload" - eine Workload ist einfach ein Stück
  laufende Software, z. B. ein Web-Service oder ein Batch-Job) will etwas von
- **Programm B** (der "Dienst", der etwas Wertvolles anbietet - z. B. eine Datenbank, eine
  Bezahl-API oder ein Datei-Speicher).

Programm B muss sich sicher sein: "Bist du wirklich A, oder gibt sich hier jemand als A
aus?" Das nennt man **Authentifizierung** (Nachweis der Identität).

### Der klassische, schlechte Weg: langlebige API-Keys

Ein **API-Key** (oder "Secret", "Access Token", "Passwort") ist eine lange Zeichenkette, die
A bei jedem Aufruf mitschickt und die B kennt. Wer die Zeichenkette hat, ist A.

Das funktioniert, hat aber gravierende Nachteile:

| Problem | Warum das weh tut |
|---|---|
| **Langlebig** | Ein API-Key gilt oft Monate oder Jahre. Wird er einmal kopiert, kann ein Angreifer ihn lange nutzen. |
| **Muss verteilt werden** | Der Key muss irgendwie zu Programm A kommen: in eine Konfigurationsdatei, eine Umgebungsvariable, ein Deployment-Skript. Jede dieser Stationen ist eine Stelle, an der er verloren gehen kann. |
| **Landet in Logs und Git** | Klassiker: Der Key wird versehentlich ins Versionskontrollsystem eingecheckt oder in eine Log-Datei geschrieben. |
| **Rotation ist Handarbeit** | Einen kompromittierten Key auszutauschen ("rotieren") bedeutet: neuen Key erzeugen, überall verteilen, alten Key abschalten - fehleranfällig und oft mit Ausfallzeit. |
| **Kein Kontext** | Der Key sagt nur "ich bin A". Er sagt nicht, *welche* Instanz von A, in welcher Umgebung, wie lange gültig. |

### Der bessere Weg: kurzlebige, an einen Empfänger gebundene Tokens

Was wäre, wenn Programm A gar keinen dauerhaften Key bräuchte, sondern sich bei Bedarf ein
frisches, nur wenige Minuten gültiges Token von einer **vertrauenswürdigen Stelle** holt -
und dieses Token nur für **genau einen Empfänger** brauchbar ist? Genau das ist die Idee
hinter Workload Identity Federation.

---

## 2. Was ist "Workload Identity Federation"?

**Federation** heißt "Verbund" oder "gegenseitige Anerkennung". Zwei Systeme, die sich
eigentlich nicht kennen, einigen sich darauf, den Identitätsnachweisen des jeweils anderen
zu vertrauen - ohne dass vorher irgendwo ein gemeinsames Passwort hinterlegt wurde.

**Workload Identity Federation** bedeutet also:

> Eine Workload (laufende Software) beweist einem **externen** Dienst ihre Identität mit
> einem Token, das von ihrer **eigenen Plattform** ausgestellt und signiert wurde. Der
> externe Dienst kennt die Workload nicht persönlich - er vertraut nur der Plattform, die
> das Token ausgestellt hat, und prüft die Signatur des Tokens gegen die öffentlich
> veröffentlichten Schlüssel dieser Plattform.

In diesem Lab ist die Plattform ein Kubernetes-Cluster (ein Verbund von Rechnern, der
Container betreibt - siehe [Kubernetes-Primer](kubernetes-primer.md)), und der externe
Dienst ist ein kleiner Spring-Boot-Service, der bewusst **nicht** im Cluster läuft.

### Eine Analogie: der Reisepass

- **Du** bist die Workload.
- Dein **Heimatland** ist die Plattform (der Kubernetes-Cluster).
- Das **Passamt** deines Landes stellt dir einen Pass aus - ein Dokument mit Ablaufdatum,
  mit Sicherheitsmerkmalen, unterschrieben/gesiegelt vom Staat. Das entspricht dem
  ausgestellten und signierten Token.
- Der **Grenzbeamte in einem anderen Land** ist der externe Dienst (die "Relying Party").
  Er kennt dich nicht. Er hat auch keine Standleitung zu deinem Passamt. Aber er kennt die
  **Sicherheitsmerkmale und Siegel** gültiger Pässe deines Landes und kann anhand derer
  prüfen, ob der Pass echt ist.
- Die veröffentlichte Liste der gültigen Siegel/Prüfmerkmale entspricht dem **JWKS**.
- Dass der Pass ein **Ablaufdatum** hat, entspricht dem `exp`-Claim (Verfallszeit) im Token.
- Dass ein Visum manchmal **nur für ein bestimmtes Land** gilt, entspricht dem `aud`-Claim
  (Audience, "für wen ist das Token bestimmt").

Der Grenzbeamte muss nirgendwo anrufen. Er prüft das Dokument **offline** anhand von
öffentlich bekannten Merkmalen. Genau das macht der Validator in diesem Lab.

---

## 3. Die Akteure in diesem PoC

```
  ┌──────────────────────── Kubernetes-Cluster (Container "server", k3s) ────────────────────────┐
  │                                                                                              │
  │   API-Server  ── stellt Tokens aus, signiert mit dem ServiceAccount-Signaturschlüssel        │
  │        ▲                                                                                     │
  │        │ GET Discovery-Doc + JWKS (nur Leserolle)                                            │
  │   Pod "issuer" (Namespace wif-issuer):  sync ──► Kopie ──► web (nur GET)                     │
  │                                                             ▲                                │
  │   ServiceAccount "consumer"  ── die Identität, auf die das Token ausgestellt wird            │
  │   Pod "consumer"  ── bekommt das Token in eine Datei gelegt, schickt es per HTTPS raus       │
  │        │                                                    │                                │
  │        │       Traefik (Ingress, Host issuer.wif.local) ────┘                                │
  │        │       ▲                                                                             │
  └────────┼───────┼─────────────────────────────────────────────────────────────────────────────┘
           │       │  TCP 443, durchgereicht von ingress-lb (Stellvertreter des Load Balancers)
           │       │
           │       │  OIDC-Discovery + JWKS, nur HTTPS:
           │       │    https://issuer.wif.local/.well-known/openid-configuration
           │       │    https://issuer.wif.local/openid/v1/jwks
           │  HTTPS GET /whoami        Authorization: Bearer <JWT>
           ▼       │
   ┌─────────────────────────────┐
   │  Validator (Relying Party)  │
   │  Spring Boot, NICHT im       │
   │  Cluster                     │
   │  prüft Signatur+iss+aud+exp  │
   └─────────────────────────────┘

   Der Validator spricht NIEMALS mit dem API-Server und kann ihn über kein Netz erreichen.
   Vom Cluster erreicht er nur die Ingress-Route des Issuer-Pods.
```

### Der Cluster / der API-Server

Der **Kubernetes-Cluster** ist die Plattform, die Container betreibt. Sein Kern ist der
**API-Server**: der zentrale Dienst, mit dem alles im Cluster redet. Für dieses Lab ist eine
Fähigkeit des API-Servers entscheidend: Er kann für eine Identität im Cluster ein
**signiertes JWT** ausstellen. Die dafür verwendeten privaten Signaturschlüssel
("ServiceAccount signing keys", hier RSA-Schlüssel für den Algorithmus `RS256`) kennt nur
der Cluster. Die dazugehörigen **öffentlichen** Schlüssel darf jeder haben - genau die
landen im JWKS.

In diesem Lab läuft der Cluster als einzelner Container namens `server` (k3s, siehe
[Kubernetes-Primer](kubernetes-primer.md)).

### Der ServiceAccount

Ein **ServiceAccount** ist eine **Maschinen-Identität innerhalb des Clusters** - kein Mensch,
sondern ein Nutzerkonto für laufende Software. Er hat einen Namen und lebt in einem
**Namespace** (einem benannten Bereich zur Gruppierung von Objekten im Cluster). Wenn der
API-Server ein Token ausstellt, trägt es im `sub`-Claim (Subject, "wer ist das") den Namen
dieses ServiceAccounts.

In diesem Lab: ServiceAccount `consumer` im Namespace `wif-demo`. Der `sub`-Claim im Token
lautet deshalb `system:serviceaccount:wif-demo:consumer`. Definiert in
[`manifests/20-consumer.yaml`](../manifests/20-consumer.yaml).

### Der Pod / die Workload

Ein **Pod** ist die kleinste ausführbare Einheit in Kubernetes: ein oder mehrere Container,
die zusammen laufen. Der Pod in diesem Lab (Name beginnt mit `consumer-`) ist die
**Workload**, die sich ausweisen will. Er bekommt das signierte Token vom Cluster in eine
Datei im Container gelegt (`/var/run/secrets/tokens/sa-token`) und schickt es als
HTTP-Header `Authorization: Bearer <token>` an den Validator.

Der Pod selbst enthält nur ein `curl`-Image, das nichts tut außer zu warten. Die eigentliche
"Anfrage an den externen Dienst" löst das Demo-Skript
([`tools/demo.sh`](../tools/demo.sh)) aus.

### Der Issuer-Endpoint (Issuer-Pod hinter dem Ingress)

**Issuer** heißt "Aussteller". Der `iss`-Claim im Token nennt die URL des Ausstellers. Damit
die Prüfung offline funktionieren kann, muss unter dieser URL ein kleines Stück öffentliche
Metadaten liegen:

- das **OIDC-Discovery-Dokument** unter dem Pfad `/.well-known/openid-configuration`
  (OIDC = OpenID Connect, ein verbreiteter Standard für Identitäts-Tokens;
  `.well-known` ist ein per Konvention festgelegter Pfad, unter dem Software solche
  Metadaten erwartet). Das Dokument nennt u. a. den eigenen `issuer` und die URL des JWKS
  (`jwks_uri`).
- das **JWKS** unter der im Discovery-Dokument genannten `jwks_uri`
  (hier `/openid/v1/jwks`) - die öffentlichen Signaturschlüssel des Clusters.

In diesem Lab liefert ein **Pod im Cluster** (Deployment `issuer` im Namespace
`wif-issuer`, zwei Replikas) genau diese zwei Dokumente unter der Issuer-URL
`https://issuer.wif.local` aus - **getrennt vom API-Server**. Er besteht aus zwei
Containern:

- **`sync`** liest alle 15 Sekunden Discovery-Dokument und JWKS mit dem eigenen
  ServiceAccount vom API-Server. Der hat nur die eingebaute Leserolle
  `system:service-account-issuer-discovery`. `sync` übernimmt einen Stand nur, wenn er
  **plausibel** ist: `issuer` und `jwks_uri` stimmen, das JWKS enthält mindestens einen
  Schlüssel. Ist der API-Server nicht erreichbar oder der Stand nicht plausibel, bleibt der
  **letzte gültige Stand** stehen. Jede `kid`, die hinzukommt oder wegfällt, protokolliert
  er als Warnung.
- **`web`** (nginx) liefert die Kopie nur per `GET` aus. Er hat kein ServiceAccount-Token
  und spricht nie mit dem API-Server. Bereit ist er erst, wenn `sync` einmal erfolgreich
  abgeglichen hat; ein frisch gestarteter Pod nimmt also erst mit gültigem Stand Verkehr an.

Nach außen veröffentlicht der Ingress-Controller **Traefik** nur diese beiden Pfade unter
dem Host `issuer.wif.local`, mit einem Serverzertifikat der internen PKI. Es gibt **keinen
Schreibweg**: Kein Endpunkt nimmt ein JWKS entgegen, und keine Komponente braucht ein
Zertifikat, um Schlüssel zu veröffentlichen.

Wer bestimmen kann, was unter der JWKS-URL ausgeliefert wird, kann beliebige Tokens
ausstellen, die der Validator akzeptiert. Deshalb ist der Namespace `wif-issuer` geschützt
wie die Steuerung des Clusters: kein RoleBinding, Admission-Regeln, NetworkPolicies
(eingehend nur von Traefik, ausgehend nur zum API-Server) und gehärtete Pods (ohne Root,
schreibgeschütztes Root-Dateisystem, keine Capabilities). Die Admission-Regeln reservieren
den Host `issuer.wif.local` für `wif-issuer`: Außerhalb davon muss jede Ingress-Regel
einen eigenen Host nennen, der weder `issuer.wif.local` ist noch ihn per Wildcard abdeckt;
ein Default-Backend und Traefik-Router-Annotationen (Priorität, Pfad-Matcher) sind
verboten. Denn eine Regel ohne Host passt auf jeden Host, und Traefik ordnet Routen nach
der Länge ihrer Regel - eine lange Pfad-Regex könnte sonst die Issuer-Route überholen. Die
Issuer-Route selbst trägt die höchste Routing-Priorität. In `wif-issuer` laufen nur Images
mit festem Digest. Warum
der Issuer-Endpoint ein eigener Dienst ist, steht in
[ADR 0002](adr/0002-eigenstaendiger-issuer-endpoint.md), warum ein Pod im Cluster per Pull
über einen Ingress in [ADR 0005](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md).
Definiert in [`manifests/10-issuer.yaml`](../manifests/10-issuer.yaml) und
[`manifests/05-issuer-admission.yaml`](../manifests/05-issuer-admission.yaml).

### Der Schlüsselwechsel in zwei Phasen

Der Cluster signiert mit genau einem privaten Schlüssel, veröffentlicht aber alle
Prüfschlüssel im JWKS. Ein Wechsel läuft in zwei Phasen, jeweils mit Neustart des
API-Servers ([`tools/sa-keys.sh`](../tools/sa-keys.sh)):

1. **`sa-keys stage`**: Der neue öffentliche Schlüssel kommt zunächst nur als
   **Prüfschlüssel** ins JWKS; signiert wird weiter mit dem bisherigen Schlüssel.
2. **`sa-keys activate`**: Erst wenn der Issuer-Pod den neuen Schlüssel ausliefert, wird er
   zum **Signierschlüssel**. Der bisherige bleibt als Prüfschlüssel, ältere fallen weg.

So ist nie ein Token mit einer `kid` unterwegs, die die Relying Parties nicht abrufen
können; schon das erste Token mit dem neuen Schlüssel wird akzeptiert. Zwischen zwei
`activate` liegt mindestens die maximale Token-Laufzeit plus die Zeit, die die Relying
Parties Schlüssel zwischenspeichern.

Für den Notfall, etwa wenn der vorherige Schlüssel kompromittiert ist, entfernt
**`sa-keys retire`** ihn sofort aus dem JWKS (ebenfalls mit Neustart des API-Servers). Mit
ihm signierte Tokens werden nicht mehr angenommen, sobald die Relying Parties ihre
Schlüssel neu geladen haben.

### Die interne PKI

Eine **PKI** (Public Key Infrastructure) ist die Stelle, die Zertifikate ausstellt. Die
Annahme dieses Labs: Die Organisation hat eine interne PKI, deren Root-Zertifikat auf allen
Systemen bereits verteilt ist. Im Lab spielt der Einmal-Container `pki-init` diese Rolle
([`tools/pki-init.sh`](../tools/pki-init.sh)): Er erzeugt eine Lab-CA und davon die
Serverzertifikate des Issuer-Ingress (`issuer.wif.local`), des Validators, von Keycloak und
von `service-r`.

### Der Validator / die Relying Party

**Relying Party** heißt "die vertrauende Partei" - die Seite, die sich auf ein Token
*verlässt*, statt es auszustellen. In diesem Lab ist das der **Validator**: ein
Spring-Boot-Service (Java), der **nicht** im Cluster läuft. Er ist der externe Dienst, gegen
den sich der Pod ausweist.

Der Validator bietet zwei Endpunkte, nur über HTTPS (Port 8443, Zertifikat der internen PKI):

| Pfad | Zweck |
|---|---|
| `GET /healthz` | Liveness-Check, antwortet `{"status":"UP"}`. |
| `GET /whoami` | Nimmt das Bearer-Token entgegen, prüft es offline und antwortet mit den Claims (`200`) oder mit einem Ablehnungsgrund (`401`). |

Was genau er prüft, steht in [use-cases.md](use-cases.md). Quellcode:
`validator/src/main/java/ms/rohde/wifpoc/`.

### Der Autorisierungsserver und Dienst R

Der Validator beantwortet nur, **wer** eine Workload ist. **Was** sie darf, entscheidet der
Fachbereich, dem ein Dienst gehört, über einen eigenen Autorisierungsserver – im Lab ein
Keycloak mit dem Realm `domain-rst`, den Pods nur über ein Gateway erreichen. Die Workload legt dort ihr ServiceAccount-Token als
Client-Nachweis vor und bekommt ein Access-Token mit **Scopes** (z. B. `r:orders:read`).
Der Ressourcendienst `service-r` prüft dieses Access-Token und schützt seine Endpunkte nach
Scope; Workload-Namen kennt er nicht. Im Lab gibt es dafür zwei weitere Pods: `reader`
(nur Leserecht) und `stranger` (gültige Identität, aber im Realm nicht registriert).
Details: [ADR 0004](adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md) und
[features/keycloak-autorisierungsserver.md](features/keycloak-autorisierungsserver.md).

---

## 4. Der Trust Anchor: Wer vertraut wem, und warum darf der Validator offline glauben?

**Trust Anchor** heißt "Vertrauensanker": der eine Punkt, an dem die Prüfung beginnt und dem
man ohne weiteren Beweis vertraut. Alles andere leitet sich daraus ab.

Der Validator prüft ein Token, **ohne** den Cluster zu fragen, ob das Token echt ist. Das
kann er nur, weil es eine lückenlose Kette gibt, an deren Anfang etwas steht, dem er von
vornherein vertraut.

### Die Kette (von unten nach oben gelesen)

```
   iss-Claim im Token           "https://issuer.wif.local"
          │  der Validator akzeptiert nur exakt diesen Wert (fest konfiguriert)
          ▼
   Issuer-URL                   https://issuer.wif.local
          │  unter dieser URL holt der Validator das Discovery-Dokument
          │  (TLS: er vertraut NUR der internen CA, /trust/ca.crt)
          ▼
   Discovery-Dokument           /.well-known/openid-configuration
          │  Feld "issuer" MUSS wieder "https://issuer.wif.local" sein  (sonst Abbruch)
          │  Feld "jwks_uri" zeigt auf ... - nur auf demselben HTTPS-Ursprung
          │  (Schema, Host, Port) wie die Issuer-URL  (sonst Abbruch)
          ▼
   JWKS                         https://issuer.wif.local/openid/v1/jwks
          │  enthält die öffentlichen Signaturschlüssel, jeder mit einer "kid" (Key-ID)
          ▼
   Signaturschlüssel            der öffentliche Schlüssel mit der "kid" aus dem
                                JWS-Header des Tokens
          │
          ▼
   Signaturprüfung              stimmt die Signatur des Tokens zu diesem Schlüssel?
```

### Was ist hier der eigentliche Vertrauensanker?

Zwei Dinge sind fest im Validator hinterlegt (per Umgebungsvariable / `application.yaml`)
und werden **nicht** aus dem Netz geladen:

1. **Der erwartete `issuer`-Wert** (`WIF_ISSUER`, hier `https://issuer.wif.local`). Der Validator
   akzeptiert kein Token, dessen `iss` davon abweicht, und keine Discovery-Antwort, deren
   `issuer`-Feld davon abweicht.
2. **Das Root-Zertifikat der internen CA** (`WIF_ISSUER_CA`, Datei `/trust/ca.crt`). Der
   Validator baut sich daraus einen eigenen, isolierten TLS-Vertrauensspeicher
   (`SSLSocketFactory` in `JwksTrustConfig`) und akzeptiert für `https://issuer.wif.local` **nur**
   Serverzertifikate dieser CA - keinen öffentlichen Zertifizierungsstellen-Speicher, kein
   `curl -k`. Das Root-Zertifikat erreicht ihn auf einem anderen Weg als die Daten (im Lab:
   das schreibgeschützte Volume `ca-trust`, stellvertretend für die anderweitige Verteilung).

Die `jwks_uri` aus dem Discovery-Dokument übernimmt der Validator nur, wenn sie auf dem
HTTPS-Ursprung der Issuer-URL liegt (gleiches Schema, gleicher Host, gleicher Port).
Schlüssel lädt er so immer vom Endpunkt, für dessen Namen der Issuer steht - nie von einem
anderen Host, der bloß ein Zertifikat derselben CA hat. Andernfalls startet er nicht.

Weil der Validator sicher weiß, dass er mit dem **echten** Issuer-Endpoint spricht
(Punkt 2), und dieser ihm die öffentlichen Schlüssel des Clusters liefert, kann er jede
Token-Signatur prüfen. Und weil er nur Tokens mit dem einen erwarteten `iss` (Punkt 1) und
der einen erwarteten `aud` akzeptiert, kann sich kein fremder Aussteller einschleichen.

Dass der Issuer-Endpoint die **richtigen** Schlüssel ausliefert, sichert der Cluster selbst:
Der Issuer-Pod übernimmt nur, was der API-Server liefert, es gibt keinen Schreibweg von
außen, und der Namespace `wif-issuer` sowie die Route für `issuer.wif.local` sind gegen
Änderungen durch andere als Cluster-Admins geschützt.

> **Kurz:** Der Validator vertraut (a) der internen CA und (b) einem konkreten
> Issuer-Namen. Aus diesen beiden Ankern plus der veröffentlichten JWKS ergibt sich alles
> Weitere - ganz ohne Rückfrage beim Cluster. Die Echtheit der JWKS selbst hängt daran, dass
> nur die Steuerung des Clusters bestimmt, was der Issuer-Pod ausliefert.

### PKIX in einem Satz

**PKIX** ("Public Key Infrastructure using X.509") ist das Regelwerk, nach dem Software
TLS-Zertifikate prüft: Ist das Zertifikat von einer vertrauenswürdigen Stelle unterschrieben,
ist es zeitlich gültig, passt der Hostname? In diesem Lab ist die "vertrauenswürdige Stelle"
die Root-CA der (Lab-)internen PKI. Ein Validator, dem eine fremde CA mitgegeben wird,
startet nicht (`validator-foreign-ca`, siehe [use-cases.md](use-cases.md)).

---

## 5. Offline-Validierung (JWKS) vs. Online-Validierung (TokenReview)

Es gibt zwei Wege, wie ein externer Dienst ein Kubernetes-ServiceAccount-Token prüfen kann.

### Offline (dieses Lab)

Der Dienst holt sich **einmalig** (und dann zwischengespeichert) die öffentlichen Schlüssel
über OIDC-Discovery und prüft jedes Token lokal: Signatur, `iss`, `aud`, `exp`. Kein Kontakt
zum Cluster pro Anfrage.

### Online (TokenReview)

**TokenReview** ist eine API des Kubernetes-API-Servers. Der externe Dienst schickt das
Token an den API-Server und fragt: "Ist das gültig, und wenn ja, wer ist es?" Der API-Server
antwortet mit Ja/Nein plus Identität. Das setzt voraus, dass der Dienst den API-Server
erreichen kann **und** selbst ein Credential besitzt, um die TokenReview-API aufzurufen.

### Trade-offs

| Aspekt | Offline (JWKS) | Online (TokenReview) |
|---|---|---|
| **Widerruf ("Revocation")** | Nicht möglich vor `exp`. Ein einmal ausgestelltes Token gilt bis zum Ablauf, auch wenn Pod oder ServiceAccount längst weg sind. Gegenmittel: kurze Laufzeiten, optional eine `jti`-Sperrliste. | Sofort. Der API-Server verweigert ein Token, dessen Pod/ServiceAccount nicht mehr existiert. |
| **Verfügbarkeit** | Hohe Unabhängigkeit. Ist der Cluster kurz weg, prüft der Dienst trotzdem weiter (JWKS ist gecacht, hier 5 Minuten). | Harte Abhängigkeit: Ist der API-Server nicht erreichbar, schlägt jede Prüfung fehl. |
| **Netzwerk** | Nur ein Weg zum Issuer-Endpoint (eine Ingress-Route). Der API-Server muss von außen gar nicht erreichbar sein. | Der externe Dienst muss den API-Server erreichen - oft unerwünscht bei einem Dienst außerhalb des Cluster-Netzes. |
| **Credentials beim Prüfer** | Keine. Der Validator braucht kein Cluster-Konto, nur öffentliche Metadaten. | Der Prüfer braucht ein eigenes ServiceAccount-Token mit Recht auf `TokenReview` - wieder ein Credential, das verwaltet werden muss. |
| **Pro-Anfrage-Kosten** | Nur lokale Rechenarbeit (Signaturprüfung). | Ein Netzwerk-Roundtrip zum API-Server je Anfrage. |
| **Aktualität der Identitätsdaten** | Nur, was im Token steht (Snapshot vom Ausstellungszeitpunkt). | Live-Zustand des Clusters. |

Dieses Lab zeigt bewusst die **Offline-Hälfte**. Die Begründung steht in
[ADR 0001](adr/0001-offline-jwks-statt-tokenreview.md).

---

## 6. Glossar

| Begriff | Bedeutung (kurz) |
|---|---|
| **API-Server** | Zentraler Dienst eines Kubernetes-Clusters. Stellt hier die signierten ServiceAccount-Tokens aus. |
| **`aud` (Audience)** | Claim im Token: für welchen Empfänger das Token bestimmt ist. Hier `wif-demo-validator`. Der Validator lehnt jeden anderen Wert ab. |
| **audience-gebundenes Token** | Ein Token, das nur für einen bestimmten Empfänger (`aud`) brauchbar ist. Bei einem anderen Dienst vorgezeigt, wird es abgelehnt. |
| **Bearer-Token** | "Inhaber-Token": Wer es vorzeigt (im Header `Authorization: Bearer <token>`), gilt als berechtigt. Deshalb kurze Laufzeit und `aud`-Bindung. |
| **Bootstrap** | Hier: der Einmal-Container, der beim Start den Cluster einrichtet (Namespaces, Serverzertifikat des Issuer-Ingress als Secret, CA als ConfigMap, Manifeste). Veröffentlicht selbst nichts. |
| **CA (Certificate Authority)** | Stelle, die Zertifikate unterschreibt. Hier die Root-CA der (Lab-)internen PKI. |
| **Claim** | Ein einzelnes Feld im JWT-Payload, z. B. `iss`, `sub`, `exp`. |
| **Cluster** | Verbund von Rechnern (Nodes), der von Kubernetes gemeinsam als eine Plattform verwaltet wird. |
| **CoreDNS** | Der DNS-Server *innerhalb* des Clusters. Löst Cluster-interne Namen auf, kennt aber nichts außerhalb des Clusters. |
| **Deployment** | Kubernetes-Objekt, das dafür sorgt, dass eine gewünschte Anzahl gleicher Pods läuft. |
| **Discovery-Dokument** | Die JSON-Datei unter `/.well-known/openid-configuration`, die `issuer` und `jwks_uri` nennt. |
| **Docker Compose** | Werkzeug, das mehrere Container gemeinsam aus einer Datei (`compose.yaml`) startet. |
| **`exp` (Expiration)** | Claim: Zeitpunkt, ab dem das Token ungültig ist. |
| **Federation** | Verbund: zwei Systeme erkennen die Identitätsnachweise des jeweils anderen an, ohne gemeinsames Passwort. |
| **`hostAliases`** | Feld im Pod, das feste Name-zu-IP-Einträge in die `/etc/hosts` des Pods schreibt - für Namen, die CoreDNS nicht kennt. |
| **`iat` (Issued At)** | Claim: Ausstellungszeitpunkt des Tokens. |
| **Ingress / Ingress-Controller** | Ein `Ingress` beschreibt, unter welchem Host und Pfad ein Dienst im Cluster von außen erreichbar ist; der Ingress-Controller (hier Traefik) setzt das um und beendet TLS. |
| **ingress-lb** | Im Lab der Stellvertreter des Load Balancers vor den Ingress-Knoten: reicht nur TCP 443 an Traefik weiter. Der einzige Weg der Relying Parties in den Cluster. |
| **`iss` (Issuer)** | Claim: URL des Ausstellers. Hier `https://issuer.wif.local`. |
| **Issuer / Issuer-Endpoint** | Der Aussteller bzw. die URL, unter der seine öffentlichen Metadaten (Discovery-Dokument, JWKS) liegen. |
| **Issuer-Pod** | Deployment `issuer` im Namespace `wif-issuer`: spiegelt Discovery-Dokument und JWKS vom API-Server und liefert sie nur lesend hinter dem Ingress `issuer.wif.local` aus. |
| **`jti` (JWT ID)** | Eindeutige Kennung eines einzelnen Tokens. Grundlage für eine Sperrliste, falls doch Widerruf nötig ist. |
| **JWKS (JSON Web Key Set)** | Öffentlich veröffentlichte Menge von Schlüsseln, gegen die JWT-Signaturen geprüft werden. |
| **`kid` (Key ID)** | Kennung eines Schlüssels. Steht im JWS-Header des Tokens und im JWKS, damit der Prüfer den richtigen Schlüssel findet. |
| **kubelet** | Der Agent auf jedem Node, der die Container startet und die Tokens für die Pods anfordert und aktuell hält. |
| **Kubernetes** | System zum Betreiben von Container-Workloads auf einem Cluster. |
| **`kubernetes.io`-Claim** | Zusatz-Claim im ServiceAccount-Token mit Namespace, Pod- und ServiceAccount-Angaben. |
| **k3s** | Leichtgewichtige Kubernetes-Distribution; hier läuft der ganze Cluster als ein einzelner Container. |
| **Namespace** | Benannter Bereich im Cluster zur Gruppierung von Objekten. Hier `wif-demo` (Workloads) und `wif-issuer` (Issuer-Pod). |
| **NetworkPolicy** | Kubernetes-Regel, welche Pods mit wem reden dürfen. Der Issuer-Pod nimmt nur Verbindungen von Traefik an und spricht nur mit dem API-Server. |
| **`nbf` (Not Before)** | Claim: Zeitpunkt, vor dem das Token noch nicht gültig ist. |
| **Node** | Ein einzelner Rechner (physisch oder virtuell) im Cluster, auf dem Pods laufen. |
| **OIDC (OpenID Connect)** | Standard für Identitäts-Tokens, aufbauend auf OAuth 2.0. Definiert u. a. das Discovery-Dokument. |
| **OIDC-Discovery** | Der Vorgang, aus der Issuer-URL das Discovery-Dokument und daraus die `jwks_uri` zu ermitteln. |
| **PKI (Public Key Infrastructure)** | Die Stelle samt Abläufen, die Zertifikate ausstellt. Hier vertreten durch `pki-init`. |
| **PKIX** | Regelwerk zur Prüfung von X.509-TLS-Zertifikaten (Signaturkette, Gültigkeitszeit, Hostname). |
| **Pod** | Kleinste ausführbare Einheit in Kubernetes: ein oder mehrere zusammen laufende Container. |
| **`projected` Volume** | Ein zusammengesetztes Dateisystem, das Kubernetes in den Pod einhängt. Kann als Quelle ein frisch angefordertes ServiceAccount-Token enthalten. |
| **RBAC (Role-Based Access Control)** | Kubernetes-Rechtesystem: Wer (Nutzer/ServiceAccount) darf was (Verben) auf welchen Objekten. |
| **Relying Party** | Die Partei, die sich auf ein Token verlässt (es prüft), statt es auszustellen. Hier der Validator. |
| **`RS256` / `ES256`** | Signaturalgorithmen für JWS. Der Validator akzeptiert nur diese beiden; der Cluster nutzt `RS256`. |
| **Rotation** | Regelmäßiger Austausch von Schlüsseln oder Credentials. Bei kurzlebigen Tokens automatisch, bei API-Keys Handarbeit. Die Signaturschlüssel des Clusters wechselt hier `sa-keys` in zwei Phasen (`stage`, dann `activate`); der vorherige öffentliche Schlüssel bleibt im JWKS, damit ältere Tokens gültig bleiben. Im Notfall entfernt `sa-keys retire` ihn sofort. |
| **ServiceAccount** | Maschinen-Identität innerhalb des Clusters, auf die Tokens ausgestellt werden. |
| **`sub` (Subject)** | Claim: wer das Token repräsentiert. Hier `system:serviceaccount:wif-demo:consumer`. |
| **TokenRequest-API** | API des API-Servers, über die kurzlebige, audience-gebundene ServiceAccount-Tokens angefordert werden. |
| **TokenReview-API** | API des API-Servers, mit der ein Dienst ein Token *online* prüfen lässt. In diesem Lab bewusst nicht genutzt. |
| **Trust Anchor** | Vertrauensanker: der Punkt, dem ohne weiteren Beweis vertraut wird und von dem die Prüfung ausgeht. |
| **Validator** | In diesem Lab der Name des externen Spring-Boot-Dienstes (die Relying Party). |
| **Workload** | Ein Stück laufende Software (Service, Job, ...). |
| **Workload Identity Federation** | Muster, bei dem eine Workload sich mit einem von ihrer Plattform signierten Token gegenüber einem externen Dienst ausweist. |
| **`.well-known`** | Per Konvention festgelegter URL-Pfad-Präfix, unter dem Software Metadaten erwartet. |

---

## Weiterlesen

- [Kubernetes-Primer](kubernetes-primer.md) - jeder Kubernetes-Baustein, den dieser PoC benutzt, einzeln erklärt.
- [Use Cases](use-cases.md) - der Ende-zu-Ende-Ablauf Schritt für Schritt, mit allen Fehlerfällen.
- [ADR 0001](adr/0001-offline-jwks-statt-tokenreview.md) - warum offline statt TokenReview.
- [ADR 0002](adr/0002-eigenstaendiger-issuer-endpoint.md) - warum ein eigener Issuer-Endpoint.
- [ADR 0003](adr/0003-getrennte-vertrauensbereiche-interne-pki.md) - interne PKI, getrennte Netze.
- [ADR 0004](adr/0004-keycloak-als-autorisierungsserver-pro-fachbereich.md) - Keycloak als Autorisierungsserver pro Fachbereich.
- [ADR 0005](adr/0005-issuer-pod-im-cluster-pull-ueber-ingress.md) - Issuer-Pod im Cluster, Pull über einen Ingress, Schlüsselwechsel in zwei Phasen.
