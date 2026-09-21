#!/usr/bin/env python3
"""Militär-Tabelle: Schrift wieder 0.7rem. /* milDistFont */."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* milDistFont */" in src:
    print("milDistFont schon drin — nichts geaendert.")
    raise SystemExit(0)

old = 'font-size:0.62rem;line-height:1.15;table-layout:auto"><!-- /* milFlagUi */ /* milDist */ -->'
new = 'font-size:0.7rem;line-height:1.2;table-layout:auto"><!-- /* milFlagUi */ /* milDist */ /* milDistFont */ -->'
n = src.count(old)
if n != 1:
    old2 = "font-size:0.62rem;line-height:1.15"
    if src.count(old2) == 1:
        src = src.replace(old2, "font-size:0.7rem;line-height:1.2 /* milDistFont */", 1)
        PATH.write_text(src, encoding="utf-8")
        print("OK milDistFont (fallback) ->", PATH)
        raise SystemExit(0)
    raise SystemExit("STOP milDistFont: Anker %sx (erwartet 1)." % n)
PATH.write_text(src.replace(old, new, 1), encoding="utf-8")
print("OK milDistFont ->", PATH)
