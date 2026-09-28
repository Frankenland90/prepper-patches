#!/usr/bin/env python3
"""Restore ADSB Militär Land-Flaggen (milFlag UI). /* milFlags */.

Regression-Fix: stellt Spalte Land (Flag-Emoji + ISO2) wieder her — gleicher
Stil wie patch-adsb-mil-flag.py. Greift auch wenn /* milFlag */ noch im Helper
steht (Early-Exit) aber die Land-Spalte fehlt (bakRestore/Teil-Overwrite).
"""
from pathlib import Path
import os, re, sys, tempfile, urllib.request

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
COMMIT = os.environ.get("COMMIT", "main")
BASE = "https://raw.githubusercontent.com/Frankenland90/prepper-patches/%s" % COMMIT
src = PATH.read_text(encoding="utf-8")

def mil_card(text):
    return re.search(
        r'  <div class="title">Militär \(tar1090 dbFlags\)</div>.*?'
        r'  <div class="small">[^<]*</div>\n</div>\n',
        text, re.S,
    )

def stamp(text):
    if "/* milFlags */" in text:
        return text, False
    if "<!-- /* milFlagUi */" in text:
        return text.replace("<!-- /* milFlagUi */", "<!-- /* milFlagUi */ /* milFlags */", 1), True
    return text.replace(
        '  <div class="title">Militär (tar1090 dbFlags)</div>\n',
        '  <div class="title">Militär (tar1090 dbFlags)</div><!-- /* milFlags */ -->\n',
        1,
    ), True

def fetch_milflag():
    url = BASE + "/patch-adsb-mil-flag.py"
    with urllib.request.urlopen(url, timeout=60) as r:
        code = r.read().decode("utf-8")
    if "NEW_CARD" not in code or "_adsb_icao_cc" not in code:
        raise SystemExit("STOP: upstream patch-adsb-mil-flag.py sieht falsch aus.")
    return code

cm = mil_card(src)
card = cm.group(0) if cm else ""
has_land = "Land</th>" in card and "{{ m.flag" in card
has_flag = '"flag"' in src and "mil_list.append" in src
has_helper = "def _adsb_icao_cc(" in src

if "/* milFlags */" in src and has_land and has_flag and has_helper:
    print("milFlags schon drin — nichts geaendert.")
    raise SystemExit(0)

if "def _adsb_is_mil(a):" not in src:
    raise SystemExit("STOP: _adsb_is_mil fehlt — ADSB-Militär-Patch zuerst.")

# A: helper+flag data OK, Land HTML missing → restore NEW_CARD from upstream milFlag
if has_helper and has_flag and not has_land:
    if not cm:
        raise SystemExit("STOP: Militär-Kachel nicht gefunden.")
    code = fetch_milflag()
    m = re.search(r"NEW_CARD = '''(.*?)'''\n", code, re.S)
    if not m:
        raise SystemExit("STOP: NEW_CARD in milFlag nicht gefunden.")
    new_card = m.group(1)
    # keep Dist table if milDist was present
    if "Dist</th>" in card or "/* milDist */" in card:
        # insert Dist column after Land (surgical on restored card)
        new_card = new_card.replace(
            '<th style="padding:2px 6px 4px 0;font-weight:600">Land</th>\n'
            '      <th style="padding:2px 6px 4px 0;font-weight:600">Rufzeichen</th>',
            '<th style="padding:2px 6px 4px 0;font-weight:600">Land</th>\n'
            '      <th style="padding:2px 6px 4px 0;font-weight:600">Dist</th>\n'
            '      <th style="padding:2px 6px 4px 0;font-weight:600">Rufzeichen</th>',
            1,
        )
        new_card = new_card.replace(
            '<td style="padding:2px 6px 2px 0;white-space:nowrap">{{ m.flag or "" }}{% if m.cc %} {{ m.cc }}{% else %}–{% endif %}</td>\n'
            '        <td style="padding:2px 6px 2px 0">{{ m.flight or "–" }}</td>',
            '<td style="padding:2px 6px 2px 0;white-space:nowrap">{{ m.flag or "" }}{% if m.cc %} {{ m.cc }}{% else %}–{% endif %}</td>\n'
            '        <td style="padding:2px 6px 2px 0;white-space:nowrap">{% if m.dist_km is not none %}{{ m.dist_km }} km{% if m.dist_dir %} {{ m.dist_dir }}{% endif %}{% else %}–{% endif %}</td>\n'
            '        <td style="padding:2px 6px 2px 0">{{ m.flight or "–" }}</td>',
            1,
        )
    new_card = new_card.replace(
        '  <div class="title">Militär (tar1090 dbFlags)</div>\n',
        '  <div class="title">Militär (tar1090 dbFlags)</div><!-- /* milFlags */ -->\n',
        1,
    )
    src = src[: cm.start()] + new_card + src[cm.end() :]
    PATH.write_text(src, encoding="utf-8")
    print("OK milFlags (card-restore) ->", PATH)
    raise SystemExit(0)

# B: fully good → stamp
if has_land and has_flag and has_helper:
    src2, did = stamp(src)
    PATH.write_text(src2, encoding="utf-8")
    print("OK milFlags (stamp) ->", PATH)
    raise SystemExit(0)

# C: missing pieces → run upstream milFlag repair-safe
code = fetch_milflag()
code = code.replace(
    'if "/* milFlag */" in src:\n    print("milFlag schon drin — nichts geaendert.")\n    raise SystemExit(0)\n',
    'if "Land</th>" in src and "{{ m.flag" in src and "def _adsb_icao_cc(" in src:\n'
    '    print("milFlag UI schon ok")\n    raise SystemExit(0)\n',
)
code = code.replace(
    'src = must_replace(src, "def _adsb_is_mil(a):\\n", helper, "icao helper")\n',
    'if "def _adsb_icao_cc(" not in src:\n'
    '    src = must_replace(src, "def _adsb_is_mil(a):\\n", helper, "icao helper")\n',
)
tf = Path(tempfile.gettempdir()) / "patch-adsb-mil-flag-via-milFlags.py"
tf.write_text(code, encoding="utf-8")
import runpy
sys.argv = [str(tf), str(PATH)]
runpy.run_path(str(tf), run_name="__main__")
src = PATH.read_text(encoding="utf-8")
src2, did = stamp(src)
if did:
    PATH.write_text(src2, encoding="utf-8")
print("OK milFlags (via-milFlag%s) -> %s" % ("+stamp" if did else "", PATH))
