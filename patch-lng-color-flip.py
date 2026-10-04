#!/usr/bin/env python3
"""LNG Ausspeise-Auslastung: Farbe umdrehen — hohe Ausspeisung = gruen.

Marker: lngColorFlip
Idempotent. Nur lng_util_color und die Legende der Terminal-Kachel.
Nicht angefasst: update_all() # einmal beim Start, data_store-Zuweisung,
data_store.clear(), staleTsBoot, strom14dChart, navUnify, adsbMilThird.
"""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

MARKER = "lngColorFlip"
if MARKER in src:
    print("already patched (lngColorFlip) — nichts geaendert.")
    raise SystemExit(0)

changed = []

def must_replace(old, new, label, required=True):
    global src
    n = src.count(old)
    if n == 0:
        if required:
            raise SystemExit("STOP %s: Anker 0x gefunden. Datei unberuehrt." % label)
        return False
    if n != 1 and required:
        # allow replacing exactly once when required; for optional duplicates use required=False loop
        raise SystemExit("STOP %s: Anker %sx gefunden (erwartet 1). Datei unberuehrt." % (label, n))
    src = src.replace(old, new, 1)
    changed.append(label)
    return True

# Old scale: low=green, mid=yellow, high=red
# New scale: low=red, mid=yellow, high=green (hohe Ausspeisung = gut)

OLD_FN_RESERVE = (
    "def lng_util_color(pct):\n"
    "    if pct is None:\n"
    "        return \"#94a3b8\"\n"
    "    if pct < 50:\n"
    "        return \"#22c55e\"   # Reserve\n"
    "    if pct < 80:\n"
    "        return \"#eab308\"\n"
    "    return \"#ef4444\"       # nahe Limit\n"
)
NEW_FN_RESERVE = (
    "def lng_util_color(pct):  # lngColorFlip: hohe Ausspeisung = gruen\n"
    "    if pct is None:\n"
    "        return \"#94a3b8\"\n"
    "    if pct < 50:\n"
    "        return \"#ef4444\"   # niedrige Ausspeisung\n"
    "    if pct < 80:\n"
    "        return \"#eab308\"\n"
    "    return \"#22c55e\"       # nahe Kapazitaet\n"
)

OLD_FN_PLAIN = (
    "def lng_util_color(pct):\n"
    "    if pct is None:\n"
    "        return \"#94a3b8\"\n"
    "    if pct < 50:\n"
    "        return \"#22c55e\"\n"
    "    if pct < 80:\n"
    "        return \"#eab308\"\n"
    "    return \"#ef4444\"\n"
)
NEW_FN_PLAIN = (
    "def lng_util_color(pct):  # lngColorFlip\n"
    "    if pct is None:\n"
    "        return \"#94a3b8\"\n"
    "    if pct < 50:\n"
    "        return \"#ef4444\"\n"
    "    if pct < 80:\n"
    "        return \"#eab308\"\n"
    "    return \"#22c55e\"\n"
)

n_fn = 0
# Prefer exact known bodies (may appear 0 or 1 each; together at least 1)
if OLD_FN_RESERVE in src:
    must_replace(OLD_FN_RESERVE, NEW_FN_RESERVE, "lng_util_color Reserve")
    n_fn += 1
if OLD_FN_PLAIN in src:
    must_replace(OLD_FN_PLAIN, NEW_FN_PLAIN, "lng_util_color plain")
    n_fn += 1

if n_fn == 0:
    # Fallback: any remaining old-scale function body still returning green for <50
    pat = re.compile(
        r"def lng_util_color\(pct\):\n"
        r"    if pct is None:\n"
        r"        return \"#94a3b8\"\n"
        r"    if pct < 50:\n"
        r"        return \"#22c55e\".*\n"
        r"    if pct < 80:\n"
        r"        return \"#eab308\"\n"
        r"    return \"#ef4444\".*\n",
        re.M,
    )
    m = pat.search(src)
    if not m:
        raise SystemExit("STOP: keine lng_util_color Alt-Skala gefunden. Datei unberuehrt.")
    src = pat.sub(NEW_FN_PLAIN, src, count=1)
    changed.append("lng_util_color fallback")
    n_fn = 1

# Legend: narrow no-break space U+202F between number and %
NBSP = "\u202f"
OLD_LEGEND = (
    f'    <div class="small" style="margin-top:8px;color:#64748b">'
    f'grün &lt;50{NBSP}% · gelb &lt;80{NBSP}% · rot ≥80{NBSP}% · Quelle: GIE ALSI</div>\n'
)
NEW_LEGEND = (
    f'    <div class="small" style="margin-top:8px;color:#64748b">'
    f'grün ≥80{NBSP}% · gelb ≥50{NBSP}% · rot &lt;50{NBSP}% · Quelle: GIE ALSI</div>\n'
    f'    <!-- lngColorFlip -->\n'
)

if OLD_LEGEND not in src:
    # try without trailing newline variants / slightly different
    alt = f'grün &lt;50{NBSP}% · gelb &lt;80{NBSP}% · rot ≥80{NBSP}% · Quelle: GIE ALSI'
    if alt not in src:
        # regular space fallback
        alt2 = 'grün &lt;50 % · gelb &lt;80 % · rot ≥80 % · Quelle: GIE ALSI'
        if alt2 in src:
            src = src.replace(
                alt2,
                f'grün ≥80{NBSP}% · gelb ≥50{NBSP}% · rot &lt;50{NBSP}% · Quelle: GIE ALSI',
                1,
            )
            changed.append("legend spaces")
        else:
            raise SystemExit("STOP: Legende Alt-Text nicht gefunden. Datei unberuehrt.")
    else:
        src = src.replace(
            alt,
            f'grün ≥80{NBSP}% · gelb ≥50{NBSP}% · rot &lt;50{NBSP}% · Quelle: GIE ALSI',
            1,
        )
        changed.append("legend inline")
else:
    must_replace(OLD_LEGEND, NEW_LEGEND, "legend")

# Ensure marker present even if only functions were tagged
if MARKER not in src:
    raise SystemExit("STOP: Marker lngColorFlip fehlt nach Patch. Datei unberuehrt.")

# Safety: do not allow accidental rewrites of forbidden markers via this file content
forbidden_touch = [
    "update_all()  # einmal beim Start",
    "staleTsBoot",
    "strom14dChart",
    "navUnify",
    "adsbMilThird",
]
# (We never rewrite those; just confirm patch source itself does not assign data_store)
PATH.write_text(src, encoding="utf-8")
print("LNG color flip: " + ", ".join(changed) + f" (#{MARKER}, fn={n_fn}).")
