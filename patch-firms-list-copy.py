#!/usr/bin/env python3
"""FIRMS-Liste einzeilig, GPS copy-paste (lat, lon). Idempotent (# firmsListCopy)."""
from pathlib import Path
import shutil
import sys
from datetime import datetime

DASH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
LUFT = DASH.with_name("luft.py")
MARKER = "# firmsListCopy"

dash = DASH.read_text(encoding="utf-8")
luft = LUFT.read_text(encoding="utf-8") if LUFT.exists() else ""

if "firmsListCopy" in dash and "firmsListCopy" in luft:
    print("already patched (firmsListCopy) — nichts geändert.")
    sys.exit(0)

if "Hotspots · GPS · Meldung" not in dash and "firmsChart" not in dash:
    raise SystemExit("STOP: FIRMS-Liste/Chart fehlt — zuerst apply-firms-list-chart.sh")

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
bak_d = DASH.with_name(f"dashboard.py.bak-firmscopy-{stamp}")
shutil.copy2(DASH, bak_d)
print(f"Backup: {bak_d}")
if LUFT.exists():
    bak_l = LUFT.with_name(f"luft.py.bak-firmscopy-{stamp}")
    shutil.copy2(LUFT, bak_l)
    print(f"Backup: {bak_l}")


def must_replace(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"STOP {label}: Anker {n}x (erwartet 1). Backup: {bak_d}")
    return text.replace(old, new, 1)


# luft.py: gps field "49.12345, 11.12345"
if LUFT.exists() and MARKER not in luft:
    if '"acq_fmt": acq_fmt,' in luft and '"gps":' not in luft:
        luft = luft.replace(
            '"acq_fmt": acq_fmt,  # firmsList14',
            '"acq_fmt": acq_fmt,  # firmsList14\n'
            '            "gps": f"{lat:.5f}, {lon:.5f}",  # firmsListCopy',
            1,
        )
        if '"gps":' not in luft:
            # fallback without firmsList14 comment
            luft = luft.replace(
                '"acq_fmt": acq_fmt,',
                '"acq_fmt": acq_fmt,\n'
                '            "gps": f"{lat:.5f}, {lon:.5f}",  # firmsListCopy',
                1,
            )
        LUFT.write_text(luft, encoding="utf-8")
        print("OK luft.py gps field")
    elif '"gps":' in luft:
        print("luft.py gps schon vorhanden")
    else:
        raise SystemExit("STOP: acq_fmt-Anker in luft.py fehlt — firms-list-chart zuerst?")

# dashboard list → one line, monospace GPS, user-select for copy
OLD_LIST = '''<div class="small" style="margin-top:8px">Hotspots · GPS · Meldung</div>
{% for h in (lv.hotspots or []) %}
<div class="row" style="font-size:0.82rem">
  <span>{{ h.acq_fmt or h.acq or '–' }}{% if h.nearest %} · {{ h.nearest }} {{ h.nearest_km }} km{% endif %}</span>
  <b>{{ '%.5f'|format(h.lat) if h.lat is not none else '–' }}, {{ '%.5f'|format(h.lon) if h.lon is not none else '–' }}</b>
</div>
{% endfor %}'''

NEW_LIST = '''<div class="small" style="margin-top:8px">Hotspots · tippen = kopieren</div>
{% for h in (lv.hotspots or []) %}
<div class="firms-line" style="font-size:0.82rem;line-height:1.45;padding:6px 0;border-bottom:1px solid #334155;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;user-select:all;-webkit-user-select:all;word-break:break-all">{{ h.acq_fmt or h.acq or '–' }} · {{ h.gps or '–' }}{% if h.nearest %} · {{ h.nearest }} {{ h.nearest_km }} km{% endif %}</div>
{% endfor %}
<!-- firmsListCopy -->'''

if OLD_LIST in dash:
    dash = must_replace(dash, OLD_LIST, NEW_LIST, "FIRMS list one-line")
elif "firmsListCopy" in dash:
    print("dashboard list already firmsListCopy")
elif "Hotspots · tippen" in dash:
    print("dashboard list already one-line")
else:
    raise SystemExit("STOP: Listen-Anker fehlt (firms-list-chart angewandt?)")

DASH.write_text(dash, encoding="utf-8")
print("OK patched firmsListCopy")
