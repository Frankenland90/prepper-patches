#!/usr/bin/env python3
"""ADSB-Verlauf: 14 Tage speichern + Titel. /* adsbHist14 */."""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* adsbHist14 */" in src or "cut = now_ts - 14 * 24 * 3600" in src:
    print("adsbHist14 schon drin — nichts geaendert.")
    raise SystemExit(0)

changed = []

def one(old, new, label, required=True):
    global src
    n = src.count(old)
    if n == 1:
        src = src.replace(old, new, 1)
        changed.append(label)
        return True
    if required:
        raise SystemExit("STOP %s: Anker %sx (erwartet 1)." % (label, n))
    return False

# critical — auch Varianten ohne trailing spaces
def replace_cut():
    global src
    pats = [
        ("        cut = now_ts - 7 * 24 * 3600\n", "        cut = now_ts - 14 * 24 * 3600  # /* adsbHist14 */\n"),
        ("        cut = now_ts - 7*24*3600\n", "        cut = now_ts - 14 * 24 * 3600  # /* adsbHist14 */\n"),
    ]
    for old, new in pats:
        if src.count(old) == 1:
            src = src.replace(old, new, 1)
            changed.append("cut 14d")
            return
    # regex fallback
    src2, n = re.subn(
        r"cut = now_ts - 7\s*\*\s*24\s*\*\s*3600",
        "cut = now_ts - 14 * 24 * 3600  # /* adsbHist14 */",
        src,
        count=1,
    )
    if n != 1:
        raise SystemExit("STOP cut 14d: kein 7-Tage-Cut gefunden.")
    src = src2
    changed.append("cut 14d-re")

def replace_cap():
    global src
    if src.count("                json.dump(hist[-1200:], f)\n") == 1:
        src = src.replace("                json.dump(hist[-1200:], f)\n", "                json.dump(hist[-2200:], f)\n", 1)
        changed.append("cap 2200")
        return
    src2, n = re.subn(r"json\.dump\(hist\[-1200:\], f\)", "json.dump(hist[-2200:], f)", src, count=1)
    if n != 1:
        raise SystemExit("STOP cap 2200: hist[-1200:] nicht gefunden.")
    src = src2
    changed.append("cap 2200-re")

replace_cut()
replace_cap()

one(
    "        # Verlauf speichern (max alle 10 min ein Punkt, 7 Tage)\n",
    "        # Verlauf speichern (max alle 10 min ein Punkt, 14 Tage) /* adsbHist14 */\n",
    "comment",
    False,
)
one(
    '  <div class="title">Verlauf 7 Tage · Erkennung</div>\n',
    '  <div class="title">Verlauf 14 Tage · Erkennung</div>\n',
    "title7",
    False,
)
if "Verlauf 14 Tage" not in src and "Verlauf 7 Tage" in src:
    src2, n = re.subn(
        r'(<div class="title">Verlauf )7( Tage)',
        r"\g<1>14\2",
        src,
        count=1,
    )
    if n == 1:
        src = src2
        changed.append("title-re")

for old in (
    '    """Live-Lage vom lokalen tar1090/readsb + 7-Tage-Verlauf."""\n',
    '    """Live-Lage vom lokalen tar1090/readsb + 14-Tage-Verlauf."""\n',
):
    if one(
        old,
        '    """Live-Lage vom lokalen tar1090/readsb + 14-Tage-Verlauf. /* adsbHist14 */"""\n',
        "docstring",
        False,
    ):
        break

PATH.write_text(src, encoding="utf-8")
print("OK adsbHist14 ->", PATH, "changed:", ",".join(changed))
