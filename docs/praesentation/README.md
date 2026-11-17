# Präsentation: Kurzvorstellung des PoC

Quelldateien eines Foliensatzes (13 Folien), der den PoC für Kolleginnen und Kollegen ohne
tieferes Kubernetes-Wissen vorstellt: Ausgangssituation mit mTLS-Client-Zertifikaten,
Grundidee von Workload Identity Federation, Akteure, Ablauf, Vertrauenskette, Prüfungen,
Fehlerfälle, offline vs. online, Lab vs. echter Einsatz, Demo.

Die Inhalte sind als Vorlage gedacht: Grafiken und Stichpunkte werden in das Corporate Design
einer PowerPoint-Vorlage übernommen. Die Gestaltung hier ist bewusst neutral.

## Format

| Datei | Inhalt |
|---|---|
| `deck.json` | Titel, Reihenfolge der Folien, Abschnitte, Schriften |
| `deck.css` | gemeinsame Styles aller Folien |
| `slides/<id>.html` | eine Folie je Datei: ein `<section>`-Element, Sprechernotizen im `<aside>` |

Die Folien sind HTML für das Slides-Format von Claude. Elemente wie `<x-connector>` (Pfeile in
den Diagrammen) sind dort definiert und werden von einem normalen Browser nicht gezeichnet.
Die Dateien sind daher Quelltext zum Versionieren und Weiterbearbeiten, keine eigenständig
anzeigbare Seite.

## Reihenfolge

`cover` → `problem` → `motivation` → `idee` → `architektur` → `aufbau` → `ablauf` →
`vertrauen` → `token` → `fehlerfaelle` → `offline-online` → `lab-vs-prod` → `demo`
