#!/usr/bin/env python3
"""Militär-Median wie Verkehrs-Median (0.45 / 1.9). /* milMedCmp */."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* milMedCmp */" in src:
    print("milMedCmp schon drin — nichts geaendert.")
    raise SystemExit(0)

old = '''        # Militär-Median (eigene Skala/Tendenz) /* milyAxis */
        mils24 = [int(p.get("mil") or 0) for p in hist if now_ts - float(p.get("ts") or 0) <= 24 * 3600]
        mils_h = [int(p.get("mil") or 0) for p in hist if abs(int(p.get("hour") or 0) - now().hour) <= 1 and now_ts - float(p.get("ts") or 0) > 3600]
        mil_base = sorted(mils_h) if len(mils_h) >= 8 else sorted(mils24)
        out["mil_median"] = None
        out["verdict_mil"] = "Militär-Baseline wird aufgebaut"
        out["verdict_mil_color"] = "#94a3b8"
        if len(mil_base) >= 8:
            mil_med = mil_base[len(mil_base) // 2]
            out["mil_median"] = mil_med
            if mil_n >= max(2, mil_med * 2 + 1):
                out["verdict_mil"] = "ungewöhnlich viel Militär (Median ~%s)" % mil_med
                out["verdict_mil_color"] = "#eab308"
            elif mil_med >= 1 and mil_n == 0:
                out["verdict_mil"] = "unter Militär-Median (~%s)" % mil_med
                out["verdict_mil_color"] = "#94a3b8"
            else:
                out["verdict_mil"] = "Militär im Rahmen (Median ~%s)" % mil_med
                out["verdict_mil_color"] = "#22c55e"
'''

new = '''        # Militär-Median wie Verkehr (gleiche Uhrzeit / 24h, 0.45 / 1.9) /* milyAxis */ /* milMedCmp */
        mils24 = [int(p.get("mil") or 0) for p in hist if now_ts - float(p.get("ts") or 0) <= 24 * 3600]
        mils_h = [int(p.get("mil") or 0) for p in hist if abs(int(p.get("hour") or 0) - now().hour) <= 1 and now_ts - float(p.get("ts") or 0) > 3600]
        mil_base = sorted(mils_h) if len(mils_h) >= 8 else sorted(mils24)
        out["mil_median"] = None
        out["verdict_mil"] = "Militär-Baseline wird aufgebaut (%s Punkte)" % len(hist)
        out["verdict_mil_color"] = "#94a3b8"
        if len(mil_base) >= 8:
            mil_med = mil_base[len(mil_base) // 2]
            out["mil_median"] = mil_med
            hour = now().hour
            # wie Verkehr; bei Median 0 (oft Ruhe) zählen >=2 als auffällig
            if mil_med > 0 and mil_n < mil_med * 0.45 and 7 <= hour <= 21:
                out["verdict_mil"] = "ungewöhnlich wenig Militär (Tag, Median ~%s)" % mil_med
                out["verdict_mil_color"] = "#eab308"
            elif (mil_med > 0 and mil_n > mil_med * 1.9) or (mil_med == 0 and mil_n >= 2):
                out["verdict_mil"] = "ungewöhnlich viel Militär (Median ~%s)" % mil_med
                out["verdict_mil_color"] = "#eab308"
            else:
                out["verdict_mil"] = "Militär im Rahmen (Median ~%s)" % mil_med
                out["verdict_mil_color"] = "#22c55e"
'''

n = src.count(old)
if n != 1:
    raise SystemExit("STOP milMedCmp: Anker %sx (erwartet 1)." % n)
PATH.write_text(src.replace(old, new, 1), encoding="utf-8")
print("OK milMedCmp ->", PATH)
