#!/usr/bin/env python3
"""Health-Kachel Label: Auto alle 3h. /* health3hUi */"""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* health3hUi */" in src or "Auto alle 3h" in src:
    print("health3hUi schon drin — nichts geaendert.")
    raise SystemExit(0)

old = "Zuletzt {{ h.get('at', '–') }} · Auto 09:00 / 21:00 · Watchdog 5 min"
new = "Zuletzt {{ h.get('at', '–') }} · Auto alle 3h (0/3/6/9…) · Watchdog 5 min<!-- /* health3hUi */ -->"
n = src.count(old)
if n != 1:
    raise SystemExit("STOP health3hUi: Label-Anker %sx (erwartet 1)." % n)
PATH.write_text(src.replace(old, new, 1), encoding="utf-8")
print("OK health3hUi ->", PATH)
