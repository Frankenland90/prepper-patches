#!/usr/bin/env python3
"""ADSB-Verlauf: 14 Tage speichern + Titel. /* adsbHist14 */."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* adsbHist14 */" in src:
    print("adsbHist14 schon drin — nichts geaendert.")
    raise SystemExit(0)

def must(old, new, label):
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx (erwartet 1)." % (label, n))
    src = src.replace(old, new, 1)

must(
    '    """Live-Lage vom lokalen tar1090/readsb + 7-Tage-Verlauf."""\n',
    '    """Live-Lage vom lokalen tar1090/readsb + 14-Tage-Verlauf. /* adsbHist14 */"""\n',
    "docstring",
)
must(
    "        # Verlauf speichern (max alle 10 min ein Punkt, 7 Tage)\n",
    "        # Verlauf speichern (max alle 10 min ein Punkt, 14 Tage) /* adsbHist14 */\n",
    "comment",
)
must(
    "        cut = now_ts - 7 * 24 * 3600\n",
    "        cut = now_ts - 14 * 24 * 3600\n",
    "cut 14d",
)
# 14d * 24h * 6 Punkte/h = 2016 → etwas Puffer
must(
    "                json.dump(hist[-1200:], f)\n",
    "                json.dump(hist[-2200:], f)\n",
    "cap 2200",
)
must(
    '  <div class="title">Verlauf 7 Tage · Erkennung</div>\n',
    '  <div class="title">Verlauf 14 Tage · Erkennung</div>\n',
    "title",
)

PATH.write_text(src, encoding="utf-8")
print("OK adsbHist14 ->", PATH)
