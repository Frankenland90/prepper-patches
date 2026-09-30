#!/usr/bin/env python3
"""Energie Hi/Lo: immer DD.MM HH:MM bei Diesel + Rohöl (# dieselOilHiLoDt).

Idempotent. Ersetzt die dieselHiLo/oilHiLo Text-Zuweisungen so, dass
- Datum-only (Rohöl, z.B. 15.09) → 15.09 00:00
- Zeit-only (alte Diesel-Punkte, z.B. 12:12) → DD.MM 12:12 (Datum aus Serie)
- bereits DD.MM HH:MM → normalisiert
Kein JS-Regex (\\d), damit dashboard.py py_compile-safe in \"\"\" bleibt.
"""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

MARKER = "dieselOilHiLoDt"
if MARKER in src:
    print("already patched (dieselOilHiLoDt) — nichts geaendert.")
    raise SystemExit(0)

changed = []


def must_replace(old, new, label):
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx gefunden (erwartet 1). Datei unberuehrt." % (label, n))
    src = src.replace(old, new, 1)
    changed.append(label)


# Compact JS without regex — safe inside Python """ templates.
_HELPER = (
    "  // dieselOilHiLoDt: immer DD.MM HH:MM\n"
    "  const _pad2 = n => String(n).padStart(2, '0');\n"
    "  const _fmtHiLoDt = (raw, dm) => {\n"
    "    const s = String(raw == null ? '' : raw).trim();\n"
    "    if (!s) return '–';\n"
    "    const sp = s.indexOf(' ');\n"
    "    if (sp > 0) {\n"
    "      const dpart = s.slice(0, sp), tpart = s.slice(sp + 1);\n"
    "      const dp = dpart.split('.');\n"
    "      const tp = tpart.split(':');\n"
    "      if (dp.length >= 2 && tp.length >= 2)\n"
    "        return _pad2(+dp[0]) + '.' + _pad2(+dp[1]) + ' ' + _pad2(+tp[0]) + ':' + _pad2(+tp[1]);\n"
    "    }\n"
    "    if (s.indexOf(':') >= 0 && s.indexOf('.') < 0) {\n"
    "      const tp = s.split(':');\n"
    "      if (tp.length >= 2) return (dm || '–') + ' ' + _pad2(+tp[0]) + ':' + _pad2(+tp[1]);\n"
    "    }\n"
    "    if (s.indexOf('.') >= 0 && s.indexOf(':') < 0) {\n"
    "      const dp = s.split('.');\n"
    "      if (dp.length >= 2) return _pad2(+dp[0]) + '.' + _pad2(+dp[1]) + ' 00:00';\n"
    "    }\n"
    "    return s;\n"
    "  };\n"
    "  const _histDM = (hist) => {\n"
    "    const n = hist.length, out = new Array(n), now = new Date();\n"
    "    const today = _pad2(now.getDate()) + '.' + _pad2(now.getMonth() + 1);\n"
    "    let cur = null, lastMins = null;\n"
    "    for (let i = n - 1; i >= 0; i--) {\n"
    "      const t = String((hist[i] && hist[i].t) || '').trim();\n"
    "      const sp = t.indexOf(' ');\n"
    "      if (sp > 0 && t.indexOf('.') >= 0) {\n"
    "        const dp = t.slice(0, sp).split('.');\n"
    "        const tp = t.slice(sp + 1).split(':');\n"
    "        if (dp.length >= 2) {\n"
    "          cur = _pad2(+dp[0]) + '.' + _pad2(+dp[1]);\n"
    "          lastMins = (tp.length >= 2) ? (+tp[0]) * 60 + (+tp[1]) : 0;\n"
    "          out[i] = cur; continue;\n"
    "        }\n"
    "      }\n"
    "      if (t.indexOf('.') >= 0 && t.indexOf(':') < 0) {\n"
    "        const dp = t.split('.');\n"
    "        if (dp.length >= 2) {\n"
    "          cur = _pad2(+dp[0]) + '.' + _pad2(+dp[1]);\n"
    "          lastMins = 0; out[i] = cur; continue;\n"
    "        }\n"
    "      }\n"
    "      if (t.indexOf(':') >= 0 && t.indexOf('.') < 0) {\n"
    "        const tp = t.split(':');\n"
    "        const mins = (+tp[0]) * 60 + (+tp[1]);\n"
    "        if (cur && lastMins != null && mins > lastMins + 30) {\n"
    "          const parts = cur.split('.').map(Number);\n"
    "          const dt = new Date(now.getFullYear(), parts[1] - 1, parts[0]);\n"
    "          dt.setDate(dt.getDate() - 1);\n"
    "          cur = _pad2(dt.getDate()) + '.' + _pad2(dt.getMonth() + 1);\n"
    "        }\n"
    "        if (!cur) cur = today;\n"
    "        out[i] = cur; lastMins = mins; continue;\n"
    "      }\n"
    "      out[i] = cur || today; lastMins = null;\n"
    "    }\n"
    "    return out;\n"
    "  };\n"
)

OLD_DIESEL = (
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
)

NEW_DIESEL = (
    _HELPER
    + "  const _dmD = _histDM(dieselHist);\n"
    + "  let hiPt = null, loPt = null, hiI = -1, loI = -1;\n"
    + "  for (let i = 0; i < dieselHist.length; i++) {\n"
    + "    const p = dieselHist[i];\n"
    + "    if (p == null || p.v == null) continue;\n"
    + "    if (hiPt == null || p.v > hiPt.v) { hiPt = p; hiI = i; }\n"
    + "    if (loPt == null || p.v < loPt.v) { loPt = p; loI = i; }\n"
    + "  }\n"
    + "  const hiEl = document.getElementById('dieselHiText');\n"
    + "  const loEl = document.getElementById('dieselLoText');\n"
    + "  if (hiEl && hiPt) hiEl.textContent = _fmtHiLoDt(hiPt.t, _dmD[hiI]) + ' · ' + Number(hiPt.v).toFixed(3) + ' €';\n"
    + "  if (loEl && loPt) loEl.textContent = _fmtHiLoDt(loPt.t, _dmD[loI]) + ' · ' + Number(loPt.v).toFixed(3) + ' €';\n"
)

OLD_OIL = (
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
)

NEW_OIL = (
    _HELPER
    + "  const _dmO = _histDM(oilHist);\n"
    + "  let hiPt = null, loPt = null, hiI = -1, loI = -1;\n"
    + "  for (let i = 0; i < oilHist.length; i++) {\n"
    + "    const p = oilHist[i];\n"
    + "    if (p == null || p.v == null) continue;\n"
    + "    if (hiPt == null || p.v > hiPt.v) { hiPt = p; hiI = i; }\n"
    + "    if (loPt == null || p.v < loPt.v) { loPt = p; loI = i; }\n"
    + "  }\n"
    + "  const hiEl = document.getElementById('oilHiText');\n"
    + "  const loEl = document.getElementById('oilLoText');\n"
    + "  if (hiEl && hiPt) hiEl.textContent = _fmtHiLoDt(hiPt.t, _dmO[hiI]) + ' · ' + Number(hiPt.v).toFixed(2) + ' €';\n"
    + "  if (loEl && loPt) loEl.textContent = _fmtHiLoDt(loPt.t, _dmO[loI]) + ' · ' + Number(loPt.v).toFixed(2) + ' €';\n"
)

must_replace(OLD_DIESEL, NEW_DIESEL, "diesel hilo dt")
must_replace(OLD_OIL, NEW_OIL, "oil hilo dt")

PATH.write_text(src, encoding="utf-8")
print("Hi/Lo Datum+Zeit: " + ", ".join(changed) + " (# dieselOilHiLoDt).")
