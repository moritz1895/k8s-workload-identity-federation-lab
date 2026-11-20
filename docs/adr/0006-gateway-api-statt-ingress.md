# ADR 0006: Gateway API statt Ingress für den Discovery-Endpunkt

**Datum:** 2026-11-20
**Status:** Angenommen; löst [ADR 0005](0005-discovery-pod-im-cluster-pull-ueber-ingress.md) in der Frage ab, wie die Route zum Discovery-Pod beschrieben und geschützt wird

## Für wen ist das / was lernst du hier

Diese Notiz erklärt, warum die Route zu `https://issuer.wif.local` mit der Gateway API
(`Gateway` + `HTTPRoute`) beschrieben wird und nicht mit einem `Ingress`, und wie das den
Schutz der Issuer-Adresse vereinfacht. Begriffe siehe [../domain.md](../domain.md) und
[../kubernetes-primer.md](../kubernetes-primer.md).

## Kontext

Eine Route besteht aus zwei Teilen:

- **dem Proxy**, der Verbindungen annimmt, TLS beendet und weiterleitet. Im Lab ist das
  Traefik, ein Pod in `kube-system`. Kubernetes nennt so etwas Ingress- bzw.
  Gateway-Controller.
- **der Beschreibung**, welcher Host und welcher Pfad zu welchem Service führt. Sie ist
  ein Kubernetes-Objekt und tut selbst nichts; der Controller liest sie.

Für die Beschreibung gibt es zwei APIs:

- **`Ingress`** (`networking.k8s.io/v1`): stabil, aber eingefroren. Kubernetes entwickelt sie
  nicht weiter und empfiehlt für Neues die Gateway API. Was über Host und Pfad hinausgeht,
  regeln herstellerspezifische Annotationen (bei Traefik z. B. Priorität und Pfad-Matcher).
  Alle Ingress-Objekte aller Namespaces landen in einer gemeinsamen Routing-Tabelle.
- **Gateway API** (`gateway.networking.k8s.io/v1`): der Nachfolger, seit v1.0 stabil, im
  Lab in Version 1.5.1 (von k3s mitgeliefert). Sie trennt Rollen: Das **Gateway** gehört
  dem Plattform-Betrieb und legt Listener fest (Port, Hostname, Zertifikat, welche
  Namespaces Routen anhängen dürfen). Die **HTTPRoute** gehört der Anwendung und hängt sich
  an einen Listener. Die Vorrangregeln sind in der Spezifikation festgelegt, nicht vom
  Hersteller.

Mit `Ingress` musste das Lab die Issuer-Adresse per Admission-Regel gegen alles schützen,
was in der gemeinsamen Tabelle die Route des Issuers überholen könnte: Regeln ohne Host,
Default-Backends, Traefik-Annotationen für Priorität und Pfad-Matcher. Dazu kam eine
künstlich hohe Priorität für die eigene Route.

## Entscheidung

**Traefik liest Routen nur noch aus der Gateway API.** Der Ingress-Provider und Traefiks
eigene CRDs sind aus. Das Chart legt die GatewayClass `traefik` an, aber kein
Standard-Gateway.

**Der Discovery-Endpunkt hat ein eigenes Gateway** `issuer-discovery` im Namespace
`wif-issuer-discovery`:

- ein HTTPS-Listener für genau `issuer.wif.local`, TLS endet dort mit dem Zertifikat der
  internen PKI (Secret `issuer-tls`);
- `allowedRoutes.namespaces.from: Same`: Nur Routen aus `wif-issuer-discovery` dürfen sich
  anhängen. Eine HTTPRoute aus einem anderen Namespace wird mit `NotAllowedByListeners`
  abgewiesen;
- `allowedListeners.namespaces.from: None`: Niemand kann über ein `ListenerSet` weitere
  Listener an dieses Gateway hängen.

**Die HTTPRoute** `issuer-discovery` lässt nur `GET` auf die beiden Pfade
`/.well-known/openid-configuration` und `/openid/v1/jwks` (Typ `Exact`) zum Service. Jede
andere Methode und jeder andere Pfad endet bei Traefik mit `404`, der Pod sieht sie nie.

**Admission-Regel `issuer-host-reserved`** (für Gateway, ListenerSet, HTTPRoute,
GRPCRoute, TLSRoute außerhalb von `wif-issuer-discovery`):

- Jeder Listener nennt einen Hostnamen. Ein Listener ohne Hostname nimmt jeden Host an,
  also auch `issuer.wif.local`.
- Weder Listener noch Routen verwenden `issuer.wif.local` oder eine Wildcard, die ihn
  abdeckt.

Das ersetzt die Regeln für Ingress-Objekte, das Annotationsverbot und die künstliche
Priorität. Gegen fremde Routen am eigenen Gateway schützt die Gateway API selbst; die
Admission-Regel sorgt nur dafür, dass kein anderes Gateway den Host beansprucht.

## Konsequenzen

### Positiv

- Der Schutz beruht auf eingebauten Mechanismen der API (`allowedRoutes`,
  `allowedListeners`, Hostname-Bindung von Listenern) statt auf dem Wissen, welche
  Traefik-Annotation was bewirkt.
- Die Rollen sind getrennt, wie im Unternehmensumfeld üblich: Das Gateway gehört dem
  Plattform-Betrieb, die Route der Anwendung.
- Der Ansatz ist nicht an Traefik gebunden. Jeder Controller, der die Gateway API
  umsetzt, liest dieselben Objekte.
- Nur `GET` erreicht den Pod.

### Negativ / Kompromisse

- **Ein Gateway nur für den Issuer.** In einem Cluster mit vielen Diensten teilt man sich
  meist wenige Gateways. Für den Issuer ist ein eigenes Gateway trotzdem angemessen, weil
  er zur Steuerung des Clusters gehört.
- **Der Controller bleibt im Vertrauenspfad.** Traefik hält das Serverzertifikat und
  entscheidet über das Routing, wie zuvor.
- **Zwischen Traefik und Pod läuft weiterhin HTTP ohne TLS.** Die Gateway API bietet dafür
  `BackendTLSPolicy` (im Lab vorhanden, aber nicht genutzt).
- **`ingress-lb` behält seinen Namen.** „Ingress“ meint dort den eingehenden Verkehr, nicht
  das Kubernetes-Objekt.

## Alternativen

- **Bei `Ingress` bleiben.** Funktioniert und ist im Lab getestet, braucht aber die
  herstellerspezifischen Schutzregeln und setzt auf eine API, die nicht weiterentwickelt
  wird.
- **Ein gemeinsames Gateway mit einem eigenen Listener für den Issuer.** Gleiche
  Schutzwirkung über `allowedRoutes` pro Listener, aber das Gateway gehörte dann nicht
  mehr allein zum geschützten Namespace.

## Weiterlesen

- [0005-discovery-pod-im-cluster-pull-ueber-ingress.md](0005-discovery-pod-im-cluster-pull-ueber-ingress.md) – Discovery-Pod, Pull, Schlüsselwechsel.
- [../technical/bootstrap-und-issuer.md](../technical/bootstrap-und-issuer.md) – Gateway, HTTPRoute und Härtung im Detail.
