#!/usr/bin/env python3
"""Diesel regional: Höchst/Tiefst über 14-Tage-Serie unter dem Chart (# dieselHiLo)."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

MARKER = "dieselHiLo"
if MARKER in src:
    print("already patched (dieselHiLo) — nichts geaendert.")
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
    '    <div class="chart-box"><canvas id="dieselChart"></canvas></div>\n'
    '    <div class="small" style="color:{{ kraftstoff.color }}">{{ kraftstoff.updated }}</div>\n'
)
NEW_HTML = (
    '    <div class="chart-box"><canvas id="dieselChart"></canvas></div>\n'
    '    <div id="dieselHiLo" class="small" style="margin-top:6px;line-height:1.45">\n'
    '      <div><span style="color:#ef4444">↑</span> <span id="dieselHiText">–</span></div>\n'
    '      <div><span style="color:#22c55e">↓</span> <span id="dieselLoText">–</span></div>\n'
    '    </div>\n'
    '    <div class="small" style="color:{{ kraftstoff.color }}">{{ kraftstoff.updated }}</div>\n'
)
must_replace(OLD_HTML, NEW_HTML, "html hilo")

OLD_JS = (
    "  const vals = dieselHist.map(x=>x.v).filter(v=>v!=null);\n"
    "  const dMin = vals.length ? Math.min(...vals) : 2;\n"
    "  const dMax = vals.length ? Math.max(...vals) : 2.5;\n"
    "  const canvas = document.getElementById('dieselChart');\n"
)
NEW_JS = (
    "  const vals = dieselHist.map(x=>x.v).filter(v=>v!=null);\n"
    "  const dMin = vals.length ? Math.min(...vals) : 2;\n"
    "  const dMax = vals.length ? Math.max(...vals) : 2.5;\n"
    "  // dieselHiLo: Höchst/Tiefst mit Zeitstempel aus 14-Tage-Serie\n"
    "  let hiPt = null, loPt = null;\n"
    "  for (const p of dieselHist) {\n"
    "    if (p == null || p.v == null) continue;\n"
    "    if (hiPt == null || p.v > hiPt.v) hiPt = p;\n"
    "    if (loPt == null || p.v < loPt.v) loPt = p;\n"
    "  }\n"
    "  const hiEl = document.getElementById('dieselHiText');\n"
    "  const loEl = document.getElementById('dieselLoText');\n"
    "  if (hiEl && hiPt) hiEl.textContent = (hiPt.t || '–') + ' · ' + Number(hiPt.v).toFixed(3) + ' €';\n"
    "  if (loEl && loPt) loEl.textContent = (loPt.t || '–') + ' · ' + Number(loPt.v).toFixed(3) + ' €';\n"
    "  const canvas = document.getElementById('dieselChart');\n"
)
must_replace(OLD_JS, NEW_JS, "js hilo")

PATH.write_text(src, encoding="utf-8")
print("Diesel Hi/Lo: " + ", ".join(changed) + " (# dieselHiLo).")
