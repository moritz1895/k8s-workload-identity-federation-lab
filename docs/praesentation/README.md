# Präsentation: Kurzvorstellung des PoC

Quelldateien eines Foliensatzes (10 Folien), der den PoC für Kolleginnen und Kollegen ohne
tieferes Kubernetes-Wissen vorstellt: Ausgangssituation mit mTLS-Client-Zertifikaten, Idee als
„Pass und Visum“, zwei Ebenen (Identität und Rechte), Vergleich mit heute, der Ablauf als
Animation, die zwei Tokens, die Vertrauenskette, Prüfen ohne Rückfrage vs. online und Lab vs.
echter Einsatz.

Dazu kommt `animation/index.html`: eine eigenständige Seite (p5.js), die den Ende-zu-Ende-Ablauf
in 16 Schritten animiert, jeder Schritt per Klick – vom Überblick über PKI, Discovery-Pod, „Pass“
(ServiceAccount-Token) und „Visum“ (Access-Token) bis zum Aufruf von Dienst R und zum
Schlüsselwechsel in zwei Phasen. Jede Nachricht trägt im Bild ihren Datentyp (JWT, JWKS,
X.509 …), die Seitenleiste zeigt dazu einen dekodierten Auszug aus dem laufenden Lab.

Die Inhalte sind als Vorlage gedacht: Grafiken und Stichpunkte werden in das Corporate Design
einer PowerPoint-Vorlage übernommen. Die Gestaltung hier ist bewusst neutral.

## Format

| Datei | Inhalt |
|---|---|
| `deck.json` | Titel, Reihenfolge der Folien, Abschnitte, Schriften |
| `deck.css` | gemeinsame Styles aller Folien |
| `slides/<id>.html` | eine Folie je Datei: ein `<section>`-Element, Sprechernotizen im `<aside>` |
| `animation/index.html` | animierter Ablauf, im Browser direkt öffnen (lädt p5.js und Schriften aus dem Netz) |
| `animation/standbild-schritt09.png` | Standbild der Animation, auf der Folie `gesamtablauf` als Vorschau mit Link |

Die Folien sind HTML für das Slides-Format von Claude. Elemente wie `<x-connector>` (Pfeile in
den Diagrammen) sind dort definiert und werden von einem normalen Browser nicht gezeichnet.
Die Foliendateien sind daher Quelltext zum Versionieren und Weiterbearbeiten, keine eigenständig
anzeigbare Seite.

## Reihenfolge

`cover` → `problem` → `idee` → `ebenen` → `motivation` → `gesamtablauf` → `tokens` →
`vertrauen` → `offline-online` → `lab-vs-prod`

## Offline-Präsentation

`offline/` ist eine eigenständige Fassung zum Vortragen ohne Internet und ohne claude.ai:
`offline/index.html` im Browser öffnen, `F` für Vollbild.

| Taste | Wirkung |
|---|---|
| → / Leertaste / Klick | nächster Klickschritt bzw. nächste Folie |
| ← | zurück |
| F | Vollbild |
| N | Sprechernotizen ein/aus |

Die Folie `gesamtablauf` enthält dort die Animation selbst: Jeder Klick ist ein Schritt, nach
dem letzten Schritt geht es zur nächsten Folie.

`offline/` wird erzeugt, nicht von Hand bearbeitet:

```bash
python3 docs/praesentation/build_offline.py
```

Das Skript nimmt `deck.json`, `deck.css`, `slides/` und `animation/index.html` und legt
p5.js und die Schriften aus `vendor/` daneben (Lizenzen liegen bei).
