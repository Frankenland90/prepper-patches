#!/usr/bin/env python3
"""Diesel regional Chart: History 14 Tage (1344) + Label TT.MM HH:MM + UI 14 Tage."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

changed = []

def must_replace(old, new, label):
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx gefunden (erwartet 1). Datei unberuehrt." % (label, n))
    src = src.replace(old, new, 1)
    changed.append(label)

# maxlen
if "diesel_history = deque(maxlen=1344)" not in src:
    must_replace(
        "diesel_history = deque(maxlen=192)\n",
        "diesel_history = deque(maxlen=1344)\n",
        "maxlen",
    )

# load slice
if 'for item in data.get("diesel", [])[-1344:]:' not in src:
    must_replace(
        'for item in data.get("diesel", [])[-192:]:',
        'for item in data.get("diesel", [])[-1344:]:',
        "load slice",
    )

# diesel timestamp format (append block only)
old_ts = (
    '        t = now().strftime("%H:%M")\n'
    '        if result["diesel"] is not None:\n'
    '            diesel_history.append({"t": t, "v": result["diesel"]})\n'
)
new_ts = (
    '        t = now().strftime("%d.%m %H:%M")\n'
    '        if result["diesel"] is not None:\n'
    '            diesel_history.append({"t": t, "v": result["diesel"]})\n'
)
if new_ts not in src:
    must_replace(old_ts, new_ts, "diesel timestamp")

# UI subtitle (match Rohöl: Brent · 14 Tage)
old_ui = '    <div class="small">ELO Uttenreuth</div>\n'
new_ui = '    <div class="small">ELO Uttenreuth · 14 Tage</div>\n'
if "ELO Uttenreuth · 14 Tage" not in src:
    must_replace(old_ui, new_ui, "ui subtitle")

if not changed:
    print("Diesel ist schon auf 14 Tage — nichts geaendert.")
    raise SystemExit(0)

PATH.write_text(src, encoding="utf-8")
print("Diesel-History 14 Tage: " + ", ".join(changed) + " (1344 Punkte, Label TT.MM HH:MM).")
