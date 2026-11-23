#!/usr/bin/env python3
"""Builds a stand-alone, offline presentation from the deck sources.

Input:  deck.json, deck.css, slides/<id>.html, animation/index.html, vendor/
Output: offline/index.html     the whole deck in one file (open it, press F for full screen)
        offline/animation.html the animation on its own, also in one file
        offline/licenses/      licenses of the embedded fonts and of p5.js

The slide files are the single source; this script only packages them. Arrows
(<x-connector>) and click steps (.fragment) are rendered by a small runtime in
the generated page. The slide "gesamtablauf" is replaced by the live animation.

Fonts and p5.js are embedded, and the animation sits in an iframe via srcdoc, so
the page never loads another local file. Browsers restrict file:// subresources
and file:// frames differently; a single file works in all of them.
"""
from __future__ import annotations

import base64
import json
import re
import shutil
import sys
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "offline"
VENDOR = HERE / "vendor"
ANIMATION_SLIDE = "gesamtablauf"
P5_CDN_TAG = '<script src="https://cdnjs.cloudflare.com/ajax/libs/p5.js/1.9.4/p5.min.js"></script>'
EMBED_DETECTION = 'new URLSearchParams(location.search).has("embed")'

FONT_FACES = [
    ("Inter", 400, "inter-latin-400-normal.woff2"),
    ("Inter", 600, "inter-latin-600-normal.woff2"),
    ("Inter", 700, "inter-latin-700-normal.woff2"),
    ("JetBrains Mono", 400, "jetbrains-mono-latin-400-normal.woff2"),
    ("JetBrains Mono", 600, "jetbrains-mono-latin-600-normal.woff2"),
]
ANIMATION_FONT_FACES = [
    ("IBM Plex Sans", 400, "ibm-plex-sans-latin-400-normal.woff2"),
    ("IBM Plex Sans", 500, "ibm-plex-sans-latin-500-normal.woff2"),
    ("IBM Plex Sans", 600, "ibm-plex-sans-latin-600-normal.woff2"),
    ("IBM Plex Sans", 700, "ibm-plex-sans-latin-700-normal.woff2"),
    ("IBM Plex Mono", 400, "ibm-plex-mono-latin-400-normal.woff2"),
    ("IBM Plex Mono", 500, "ibm-plex-mono-latin-500-normal.woff2"),
]

BASE_CSS = """
* { margin: 0; }
html, body { height: 100%; background: #101418; overflow: hidden; }
body { font: 32px/1.2 sans-serif; }
body > section { position: absolute; left: 50%; top: 50%; width: 1920px; height: 1080px;
  box-sizing: border-box; overflow: hidden; transform-origin: 0 0; visibility: hidden; }
body > section.current { visibility: visible; }
aside { display: none !important; }
h1 { font-size: 96px; font-weight: 600; } h2 { font-size: 64px; font-weight: 600; } h3 { font-size: 44px; font-weight: 600; }
table { width: 100%; border-collapse: separate; border-spacing: 0; border: solid #0003; border-width: 2px 0 0 2px; }
th, td { padding: .35em .6em; text-align: left; border: solid #0003; border-width: 0 2px 2px 0; }
svg.xc, svg.xc-flow { border: 0 !important; }
svg.xc { position: absolute; left: 0; top: 0; width: 100%; height: 100%; overflow: visible; pointer-events: none; }
svg.xc-flow { flex: none; width: 48px; height: 24px; align-self: center; overflow: visible; }
.anim-box { width: 1664px; height: 860px; overflow: hidden; }
iframe.anim { border: 0; width: 1331px; height: 688px; transform: scale(1.25); transform-origin: 0 0; background: transparent; }
#hud { position: fixed; right: 14px; bottom: 10px; font: 13px/1 system-ui, sans-serif; color: #8a96a3; }
#notes { position: fixed; left: 0; right: 0; bottom: 0; max-height: 40vh; overflow: auto; display: none;
  background: #1b2128ee; color: #e6eaee; font: 18px/1.5 system-ui, sans-serif; padding: 16px 24px; }
#notes.on { display: block; }
#help { position: fixed; left: 14px; bottom: 10px; font: 13px/1 system-ui, sans-serif; color: #5b6672; }
"""

RUNTIME_JS = r"""
"use strict";
const SVGNS = "http://www.w3.org/2000/svg";
const slides = [...document.querySelectorAll("body > section")];
let si = 0, step = 0;
const anim = { step: 0, total: Infinity };

// ---- arrows: <x-connector> -> inline SVG ----
function pathPoints(x1, y1, x2, y2, route) {
  if (route === "hv") return [[x1, y1], [x2, y1], [x2, y2]];
  if (route === "vh") return [[x1, y1], [x1, y2], [x2, y2]];
  if (route === "elbow") {
    if (Math.abs(x2 - x1) >= Math.abs(y2 - y1)) { const mx = (x1 + x2) / 2; return [[x1, y1], [mx, y1], [mx, y2], [x2, y2]]; }
    const my = (y1 + y2) / 2; return [[x1, y1], [x1, my], [x2, my], [x2, y2]];
  }
  return [[x1, y1], [x2, y2]];
}
function head(svg, from, to, w, color) {
  const dx = to[0] - from[0], dy = to[1] - from[1], len = Math.hypot(dx, dy) || 1;
  const ux = dx / len, uy = dy / len, L = 4 * w, H = 2 * w;
  const bx = to[0] - ux * L, by = to[1] - uy * L;
  const p = document.createElementNS(SVGNS, "polygon");
  p.setAttribute("points", `${to[0]},${to[1]} ${bx - uy * H},${by + ux * H} ${bx + uy * H},${by - ux * H}`);
  p.setAttribute("fill", color);
  svg.appendChild(p);
  return [bx + ux * w * 0.5, by + uy * w * 0.5];
}
function renderConnectors() {
  for (const xc of [...document.querySelectorAll("x-connector")]) {
    const color = getComputedStyle(xc).color;
    const w = xc.classList.contains("life") ? 2 : 3;
    const dashed = xc.classList.contains("dash") || xc.classList.contains("life");
    const headMode = xc.getAttribute("head") || "end";
    const svg = document.createElementNS(SVGNS, "svg");
    let pts;
    if (!xc.hasAttribute("x1")) { svg.setAttribute("class", "xc-flow"); pts = [[0, 12], [48, 12]]; }
    else {
      svg.setAttribute("class", "xc " + xc.className);
      const n = a => parseFloat(xc.getAttribute(a));
      pts = pathPoints(n("x1"), n("y1"), n("x2"), n("y2"), xc.getAttribute("route") || "straight");
    }
    if (xc.dataset.fragmentIndex !== undefined) svg.dataset.fragmentIndex = xc.dataset.fragmentIndex;
    if (xc.classList.contains("fragment")) svg.classList.add("fragment");
    if (headMode === "end" || headMode === "both") pts[pts.length - 1] = head(svg, pts[pts.length - 2], pts[pts.length - 1], w, color);
    if (headMode === "both") pts[0] = head(svg, pts[1], pts[0], w, color);
    const pl = document.createElementNS(SVGNS, "polyline");
    pl.setAttribute("points", pts.map(p => p.join(",")).join(" "));
    pl.setAttribute("fill", "none"); pl.setAttribute("stroke", color); pl.setAttribute("stroke-width", w);
    pl.setAttribute("stroke-linecap", "round"); pl.setAttribute("stroke-linejoin", "round");
    if (dashed) pl.setAttribute("stroke-dasharray", `${3 * w} ${3 * w}`);
    svg.insertBefore(pl, svg.firstChild);
    xc.replaceWith(svg);
  }
}

// ---- click steps (.fragment) ----
function groups(sec) {
  const frs = [...sec.querySelectorAll(".fragment")];
  const keys = [...new Set(frs.map(f => Number(f.dataset.fragmentIndex ?? 1e6)))].sort((a, b) => a - b);
  return { frs, keys };
}
function applyFragments() {
  const { frs, keys } = groups(slides[si]);
  for (const f of frs) {
    const k = keys.indexOf(Number(f.dataset.fragmentIndex ?? 1e6));
    f.classList.toggle("visible", k < step);
    f.classList.toggle("current-fragment", k === step - 1);
  }
}
const isAnim = sec => sec.hasAttribute("data-anim");
const frameOf = sec => sec.querySelector("iframe");
function send(sec, msg) { const f = frameOf(sec); if (f && f.contentWindow) f.contentWindow.postMessage({ wif: msg }, "*"); }

// ---- navigation ----
function show(i, atEnd) {
  si = Math.max(0, Math.min(slides.length - 1, i));
  slides.forEach((s, k) => s.classList.toggle("current", k === si));
  step = atEnd ? groups(slides[si]).keys.length : 0;
  applyFragments();
  if (isAnim(slides[si])) { if (atEnd) { send(slides[si], "last"); anim.step = anim.total - 1; } else { send(slides[si], "first"); anim.step = 0; } }
  document.getElementById("hud").textContent = (si + 1) + " / " + slides.length;
  const aside = slides[si].querySelector("aside");
  document.getElementById("notes").textContent = aside ? aside.textContent : "";
  history.replaceState(null, "", "#" + (si + 1));
}
function next() {
  const sec = slides[si];
  if (isAnim(sec) && anim.step < anim.total - 1) { send(sec, "next"); anim.step++; return; }
  if (step < groups(sec).keys.length) { step++; applyFragments(); return; }
  if (si < slides.length - 1) show(si + 1, false);
}
function prev() {
  const sec = slides[si];
  if (isAnim(sec) && anim.step > 0) { send(sec, "prev"); anim.step--; return; }
  if (step > 0) { step--; applyFragments(); return; }
  if (si > 0) show(si - 1, true);
}
window.addEventListener("message", e => {
  const m = e.data || {};
  if (m.wif === "state") { anim.step = m.step; anim.total = m.total; }
});
document.addEventListener("keydown", e => {
  const k = e.key;
  if (["ArrowRight", "PageDown", " ", "Enter"].includes(k)) { next(); e.preventDefault(); }
  else if (["ArrowLeft", "PageUp", "Backspace"].includes(k)) { prev(); e.preventDefault(); }
  else if (k === "Home") show(0, false);
  else if (k === "End") show(slides.length - 1, false);
  else if (k === "f" || k === "F") { if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen().catch(() => {}); }
  else if (k === "n" || k === "N") document.getElementById("notes").classList.toggle("on");
});
document.addEventListener("click", e => { if (e.target.closest("a, iframe, #notes")) return; if (e.clientX < innerWidth / 3) prev(); else next(); });

function fit() {
  const s = Math.min(innerWidth / 1920, innerHeight / 1080);
  for (const sec of slides) sec.style.transform = `scale(${s}) translate(-50%, -50%)`;
}
window.addEventListener("resize", fit);

renderConnectors();
fit();
slides.filter(isAnim).forEach(sec => { const f = frameOf(sec); f.addEventListener("load", () => send(sec, "state")); send(sec, "state"); });
const start = parseInt((location.hash || "#1").slice(1), 10);
show(Number.isFinite(start) ? start - 1 : 0, false);
"""


def font_data_uri(file: str) -> str:
    data = base64.b64encode((VENDOR / "fonts" / file).read_bytes()).decode("ascii")
    return f"data:font/woff2;base64,{data}"


def font_css(faces) -> str:
    return "\n".join(
        f'@font-face {{ font-family: "{fam}"; font-weight: {wt}; font-style: normal; font-display: swap; '
        f'src: url("{font_data_uri(file)}") format("woff2"); }}'
        for fam, wt, file in faces
    )


def inline_p5() -> str:
    code = (VENDOR / "p5.min.js").read_text(encoding="utf-8")
    if "</script" in code.lower():
        sys.exit("vendor/p5.min.js contains '</script' and cannot be inlined")
    return "<script>\n" + code + "\n</script>"


def animation_slide(original: str, embedded_animation: str) -> str:
    title = re.search(r"<h2>(.*?)</h2>", original, re.S)
    notes = re.search(r"<aside>(.*?)</aside>", original, re.S)
    heading = title.group(1).replace(" (Animation)", "") if title else "Gesamtablauf"
    return (
        f'<section id="{ANIMATION_SLIDE}" data-anim style="padding:64px 128px; gap:24px">\n'
        f"<h2>{heading}</h2>\n"
        '<div class="anim-box"><iframe class="anim" title="Animierter Gesamtablauf, Schritt für Schritt" '
        f'srcdoc="{escape(embedded_animation, quote=True)}"></iframe></div>\n'
        "<aside>Weiterklicken wie bei den übrigen Folien: Jeder Klick ist ein Schritt der Animation, "
        "nach dem letzten Schritt geht es zur nächsten Folie. "
        + (notes.group(1) if notes else "")
        + "</aside>\n</section>"
    )


def offline_animation(src: str, embedded: bool) -> str:
    """Self-contained animation; embedded=True is the variant inside the deck (no URL, so no ?embed)."""
    src = re.sub(r'<link rel="preconnect"[^>]*>\s*', "", src)
    fonts = "<style>\n" + font_css(ANIMATION_FONT_FACES) + "\n</style>"
    src = re.sub(r'<link href="https://fonts\.googleapis\.com[^>]*>', lambda _: fonts, src)
    if P5_CDN_TAG not in src:
        sys.exit("animation/index.html: p5.js script tag not found")
    src = src.replace(P5_CDN_TAG, inline_p5())
    if embedded:
        if EMBED_DETECTION not in src:
            sys.exit("animation/index.html: embed detection not found")
        src = src.replace(EMBED_DETECTION, "true")
    if "cdnjs.cloudflare.com" in src or "fonts.googleapis.com" in src:
        sys.exit("animation/index.html still references the network – check the replacements")
    return src


def main() -> None:
    deck = json.loads((HERE / "deck.json").read_text(encoding="utf-8"))
    css = (HERE / "deck.css").read_text(encoding="utf-8")
    anim_src = (HERE / "animation" / "index.html").read_text(encoding="utf-8")
    sections = []
    for slide_id in deck["order"]:
        html = (HERE / "slides" / f"{slide_id}.html").read_text(encoding="utf-8")
        sections.append(animation_slide(html, offline_animation(anim_src, embedded=True))
                        if slide_id == ANIMATION_SLIDE else html)
    page = (
        "<!DOCTYPE html>\n<html lang=\"de\">\n<head>\n<meta charset=\"utf-8\">\n"
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{escape(deck.get('title', 'Präsentation'))}</title>\n"
        "<style>\n" + font_css(FONT_FACES) + "\n" + BASE_CSS + "\n" + css + "\n</style>\n"
        "</head>\n<body>\n" + "\n".join(sections) + "\n"
        '<div id="hud"></div>\n<div id="notes"></div>\n'
        '<div id="help">→ / Leertaste weiter · ← zurück · F Vollbild · N Notizen</div>\n'
        "<script>\n" + RUNTIME_JS + "\n</script>\n</body>\n</html>\n"
    )
    if re.search(r'src="/_blob/', page):
        sys.exit("a slide still references a claude.ai asset (/_blob/…)")

    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "licenses").mkdir(parents=True)
    (OUT / "index.html").write_text(page, encoding="utf-8")
    (OUT / "animation.html").write_text(offline_animation(anim_src, embedded=False), encoding="utf-8")
    for f in (VENDOR / "fonts").glob("LICENSE-*.txt"):
        shutil.copy2(f, OUT / "licenses" / f.name)
    shutil.copy2(VENDOR / "p5-LICENSE.txt", OUT / "licenses" / "p5-LICENSE.txt")
    print(f"written: {OUT / 'index.html'} ({len(deck['order'])} slides)")


if __name__ == "__main__":
    main()
