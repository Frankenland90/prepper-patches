#!/usr/bin/env python3
"""Rohöl/Brent: Höchst/Tiefst über 14-Tage-Serie unter dem Chart (# oilHiLo)."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

MARKER = "oilHiLo"
if MARKER in src:
    print("already patched (oilHiLo) — nichts geaendert.")
    raise SystemExit(0)

changed = []


def must_replace(old, new, label):
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx gefunden (erwartet 1). Datei unberuehrt." % (label, n))
    src = src.replace(old, new, 1)
    changed.append(label)


OLD_HTML = (
    '    <div class="chart-box"><canvas id="oilChart"></canvas></div>\n'
    '    <div class="small" style="color:{{ rohoel.color }}">{{ rohoel.updated }}</div>\n'
)
NEW_HTML = (
    '    <div class="chart-box"><canvas id="oilChart"></canvas></div>\n'
    '    <div id="oilHiLo" class="small" style="margin-top:6px;line-height:1.45">\n'
    '      <div><span style="color:#ef4444">↑</span> <span id="oilHiText">–</span></div>\n'
    '      <div><span style="color:#22c55e">↓</span> <span id="oilLoText">–</span></div>\n'
    '    </div>\n'
    '    <div class="small" style="color:{{ rohoel.color }}">{{ rohoel.updated }}</div>\n'
)
must_replace(OLD_HTML, NEW_HTML, "html hilo")

# Kurzer Anker wie diesel-hilo — Chart-Body (if canvas / € / Optionen) kann auf dem Pi abweichen
OLD_JS = (
    "  const vals = oilHist.map(x=>x.v).filter(v=>v!=null);\n"
    "  const dMin = vals.length ? Math.min(...vals) : 50;\n"
    "  const dMax = vals.length ? Math.max(...vals) : 120;\n"
    "  const canvas = document.getElementById('oilChart');\n"
)
NEW_JS = (
    "  const vals = oilHist.map(x=>x.v).filter(v=>v!=null);\n"
    "  const dMin = vals.length ? Math.min(...vals) : 50;\n"
    "  const dMax = vals.length ? Math.max(...vals) : 120;\n"
    "  // oilHiLo: Höchst/Tiefst mit Zeitstempel aus 14-Tage-Serie\n"
    "  let hiPt = null, loPt = null;\n"
    "  for (const p of oilHist) {\n"
    "    if (p == null || p.v == null) continue;\n"
    "    if (hiPt == null || p.v > hiPt.v) hiPt = p;\n"
    "    if (loPt == null || p.v < loPt.v) loPt = p;\n"
    "  }\n"
    "  const hiEl = document.getElementById('oilHiText');\n"
    "  const loEl = document.getElementById('oilLoText');\n"
    "  if (hiEl && hiPt) hiEl.textContent = (hiPt.t || '–') + ' · ' + Number(hiPt.v).toFixed(2) + ' €';\n"
    "  if (loEl && loPt) loEl.textContent = (loPt.t || '–') + ' · ' + Number(loPt.v).toFixed(2) + ' €';\n"
    "  const canvas = document.getElementById('oilChart');\n"
)
must_replace(OLD_JS, NEW_JS, "js hilo")

PATH.write_text(src, encoding="utf-8")
print("Rohöl Hi/Lo: " + ", ".join(changed) + " (# oilHiLo).")
