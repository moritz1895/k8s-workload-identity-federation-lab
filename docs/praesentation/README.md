# Präsentation: Kurzvorstellung des PoC

Quelldateien eines Foliensatzes (13 Folien Hauptteil, 7 Folien Anhang), der den PoC für
Kolleginnen und Kollegen ohne tieferes Kubernetes-Wissen vorstellt. Der Hauptteil folgt dem Weg
über Keycloak: Ausgangssituation mit mTLS-Client-Zertifikaten, Idee als „Pass und Visum“,
zwei Ebenen (Identität und Rechte), Ablauf Pod → Keycloak → Dienst R, die zwei Tokens,
Schlüsselverteilung, Vertrauenskette, Prüfen ohne Rückfrage vs. online, Demo, Lab vs. echter
Einsatz. Der Anhang enthält die Variante ohne Keycloak (Pod → Validator), Netze und TLS, die
Startreihenfolge und die Prüfungen.

Dazu kommt `animation/index.html`: eine eigenständige Seite (p5.js), die den Ende-zu-Ende-Ablauf
in 21 Schritten animiert – von der PKI über Publisher, ServiceAccount-Token und Keycloak bis zum
Aufruf von Dienst R und zur Schlüsselrotation.

Die Inhalte sind als Vorlage gedacht: Grafiken und Stichpunkte werden in das Corporate Design
einer PowerPoint-Vorlage übernommen. Die Gestaltung hier ist bewusst neutral.

## Format

| Datei | Inhalt |
|---|---|
| `deck.json` | Titel, Reihenfolge der Folien, Abschnitte, Schriften |
| `deck.css` | gemeinsame Styles aller Folien |
| `slides/<id>.html` | eine Folie je Datei: ein `<section>`-Element, Sprechernotizen im `<aside>` |
| `animation/index.html` | animierter Ablauf, im Browser direkt öffnen (lädt p5.js und Schriften aus dem Netz) |
| `animation/standbild-schritt12.png` | Standbild der Animation, auf der Folie `gesamtablauf` als Vorschau mit Link |

Die Folien sind HTML für das Slides-Format von Claude. Elemente wie `<x-connector>` (Pfeile in
den Diagrammen) sind dort definiert und werden von einem normalen Browser nicht gezeichnet.
Die Foliendateien sind daher Quelltext zum Versionieren und Weiterbearbeiten, keine eigenständig
anzeigbare Seite. Die Ablauf-Folien zeigen ihre Schritte beim Präsentieren per Klick
(`class="fragment"`).

## Reihenfolge

Hauptteil: `cover` → `problem` → `idee` → `ebenen` → `motivation` → `ablauf-authz` → `gesamtablauf` → `tokens` →
`architektur` → `vertrauen` → `offline-online` → `demo` → `lab-vs-prod`

Anhang: `anhang` → `ablauf` → `fehlerfaelle` → `netze` → `aufbau` → `fehlerfaelle-authz` →
`fehlerfaelle-betrieb`
