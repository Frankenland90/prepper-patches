#!/usr/bin/env python3
"""ADSB Militär: Land (Flagge + ISO2) aus ICAO-Hex. /* milFlag */."""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* milFlag */" in src:
    print("milFlag schon drin — nichts geaendert.")
    raise SystemExit(0)

def must_replace(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx (erwartet 1)." % (label, n))
    return text.replace(old, new, 1)

if "def _adsb_is_mil(a):" not in src:
    raise SystemExit("STOP: _adsb_is_mil fehlt — ADSB-Militär-Patch zuerst.")

helper = '''def _adsb_icao_cc(hx):
    """ICAO 24-bit → ISO2 + Flag-Emoji. /* milFlag */"""
    try:
        n = int(str(hx or "").strip(), 16) & 0xFFFFFF
    except Exception:
        return None, ""
    ranges = (
        (0x000000, 0x003FFF, "US"), (0x004000, 0x0043FF, "ZA"),
        (0x006000, 0x006FFF, "EG"), (0x008000, 0x00FFFF, "RU"),
        (0x010000, 0x011FFF, "RU"), (0x014000, 0x014FFF, "LY"),
        (0x300000, 0x33FFFF, "IT"), (0x340000, 0x37FFFF, "ES"),
        (0x380000, 0x3BFFFF, "FR"), (0x3C0000, 0x3FFFFF, "DE"),
        (0x400000, 0x43FFFF, "GB"), (0x440000, 0x447FFF, "AT"),
        (0x448000, 0x44FFFF, "BE"), (0x450000, 0x457FFF, "BG"),
        (0x458000, 0x45FFFF, "DK"), (0x460000, 0x467FFF, "FI"),
        (0x468000, 0x46FFFF, "GR"), (0x470000, 0x477FFF, "HU"),
        (0x478000, 0x47FFFF, "NO"), (0x480000, 0x487FFF, "NL"),
        (0x488000, 0x48FFFF, "PL"), (0x490000, 0x497FFF, "PT"),
        (0x498000, 0x49FFFF, "CZ"), (0x4A0000, 0x4A7FFF, "RO"),
        (0x4A8000, 0x4AFFFF, "SE"), (0x4B0000, 0x4B7FFF, "CH"),
        (0x4B8000, 0x4BFFFF, "TR"), (0x4C0000, 0x4C7FFF, "RS"),
        (0x4C8000, 0x4CFFFF, "HR"), (0x4D0000, 0x4DFFFF, "LU"),
        (0x4E0000, 0x4E7FFF, "MT"), (0x4E8000, 0x4EFFFF, "CY"),
        (0x500000, 0x5003FF, "SI"), (0x501000, 0x5013FF, "MD"),
        (0x502000, 0x502FFF, "LV"), (0x503000, 0x5033FF, "EE"),
        (0x504000, 0x5043FF, "BY"), (0x505000, 0x5053FF, "UA"),
        (0x506000, 0x506FFF, "SK"), (0x508000, 0x508FFF, "BA"),
        (0x50C000, 0x50C3FF, "AZ"), (0x510000, 0x5103FF, "MK"),
        (0x511000, 0x5113FF, "AL"), (0x700000, 0x700FFF, "AF"),
        (0x740000, 0x74FFFF, "JP"), (0x750000, 0x750FFF, "TH"),
        (0x760000, 0x760FFF, "CN"), (0x768000, 0x76FFFF, "KR"),
        (0x780000, 0x7BFFFF, "CN"), (0x7C0000, 0x7FFFFF, "AU"),
        (0x800000, 0x83FFFF, "IN"), (0x840000, 0x87FFFF, "IL"),
        (0x880000, 0x88FFFF, "SA"), (0x896000, 0x896FFF, "AE"),
        (0xA00000, 0xAFFFFF, "US"), (0xC00000, 0xC3FFFF, "CA"),
        (0xC80000, 0xC87FFF, "NZ"), (0xE00000, 0xE3FFFF, "AR"),
        (0xE40000, 0xE40FFF, "BR"), (0xE80000, 0xE80FFF, "CL"),
        (0xEC0000, 0xEFFFFF, "BR"),
    )
    cc = None
    for lo, hi, code in ranges:
        if lo <= n <= hi:
            cc = code
            break
    if not cc:
        return None, ""
    try:
        flag = "".join(chr(0x1F1E6 + ord(c) - 65) for c in cc)
    except Exception:
        flag = ""
    return cc, flag


def _adsb_is_mil(a):
'''

src = must_replace(src, "def _adsb_is_mil(a):\n", helper, "icao helper")

# Replace mil_list.append block (any prior alt conversion) with cc/flag + ft->m
new_app = '''                    _hx = (a.get("hex") or "").upper()
                    _cc, _flag = _adsb_icao_cc(_hx)
                    _alt_ft = a.get("alt_baro")
                    _alt_m = None
                    try:
                        if _alt_ft is not None and str(_alt_ft).strip().lower() not in ("", "ground", "none", "null"):
                            _alt_m = int(round(float(_alt_ft) * 0.3048))
                    except Exception:
                        _alt_m = None
                    mil_list.append({
                        "hex": _hx,
                        "flight": (a.get("flight") or "").strip(),
                        "t": str(a.get("t") or a.get("type") or "").strip(),
                        "alt": _alt_m,
                        "sq": str(a.get("squawk") or "").strip(),
                        "r": str(a.get("r") or "").strip(),
                        "cc": _cc or "",
                        "flag": _flag or "",
                    })
'''
m = re.search(r'[ \t]*mil_list\.append\(\{.*?\}\)\n', src, re.S)
if not m:
    raise SystemExit("STOP: mil_list.append Anker nicht gefunden.")
# Prefer block that includes a few lines of prep before append if they assign _alt
start = m.start()
# expand backward over consecutive indented assignment lines related to mil_list
pre = src[:start]
lines = pre.splitlines(True)
i = len(lines) - 1
while i >= 0 and re.match(r'[ \t]+(_alt|_hx|_cc|try:|except|if _alt)', lines[i]):
    i -= 1
# also pull a try/except block ending just before append
# simpler: if previous non-empty indented lines look like alt conversion, include from first _alt
j = len(lines) - 1
while j >= 0 and lines[j].strip() == "":
    j -= 1
k = j
while k >= 0 and (lines[k].startswith("                    ") or lines[k].startswith("                        ") or lines[k].strip() in ("try:", "except Exception:", "pass")):
    if "mil_list" in lines[k] or "for a in" in lines[k] or "if _adsb_is_mil" in lines[k]:
        break
    k -= 1
# If we walked into alt-prep, use k+1
block_start_line = k + 1
# Only expand if we saw _alt in the walked region
region = "".join(lines[block_start_line:])
if "_alt" in region or "0.3048" in region:
    start = sum(len(x) for x in lines[:block_start_line])
src = src[:start] + new_app + src[m.end():]

NEW_CARD = '''  <div class="title">Militär (tar1090 dbFlags)</div>
  <div class="big">{% if adsb.ok %}{{ adsb.mil }}{% else %}–{% endif %}</div>
  {% if adsb.mil_list %}
  <div style="overflow-x:auto;margin-top:6px">
  <table style="width:100%;border-collapse:collapse;font-size:0.85rem;line-height:1.35">
    <thead>
      <tr style="text-align:left;color:#94a3b8;border-bottom:1px solid #334155">
      <th style="padding:2px 6px 4px 0;font-weight:600">Land</th>
      <th style="padding:2px 6px 4px 0;font-weight:600">Rufzeichen</th>
      <th style="padding:2px 6px 4px 0;font-weight:600">Hex</th>
      <th style="padding:2px 6px 4px 0;font-weight:600">Typ</th>
      <th style="padding:2px 6px 4px 0;font-weight:600">Höhe</th>
      <th style="padding:2px 6px 4px 0;font-weight:600">Squawk</th>
      <th style="padding:2px 6px 4px 0;font-weight:600">Kennzeichen</th>
      </tr>
    </thead>
    <tbody>
    {% for m in adsb.mil_list %}
      <tr style="border-bottom:1px solid #1e293b">
        <td style="padding:2px 6px 2px 0;white-space:nowrap">{{ m.flag or "" }}{% if m.cc %} {{ m.cc }}{% else %}–{% endif %}</td>
        <td style="padding:2px 6px 2px 0">{{ m.flight or "–" }}</td>
        <td style="padding:2px 6px 2px 0">{{ m.hex }}</td>
        <td style="padding:2px 6px 2px 0">{{ m.t or "–" }}</td>
        <td style="padding:2px 6px 2px 0">{% if m.alt is not none %}{{ m.alt }} m{% else %}–{% endif %}</td>
        <td style="padding:2px 6px 2px 0">{{ m.sq or "–" }}</td>
        <td style="padding:2px 6px 2px 0">{{ m.r or "–" }}</td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
  </div>
  {% else %}
    <div class="small">keine als Militär markiert</div>
  {% endif %}
  <div class="small">dbFlags Bit0 · max. 20 Zeilen · Höhe ft->m · Land aus ICAO-Hex</div>
</div>
'''

# Replace entire Militär card (list OR table variant)
pat = re.compile(
    r'  <div class="title">Militär \(tar1090 dbFlags\)</div>.*?'
    r'  <div class="small">(?:braucht aircraft-DB am Feeder \(dbFlags\); sonst immer 0|dbFlags Bit0[^<]*)</div>\n</div>\n',
    re.S,
)
m = pat.search(src)
if not m:
    raise SystemExit("STOP: Militär-Kachel nicht gefunden.")
src = src[: m.start()] + NEW_CARD + src[m.end() :]

PATH.write_text(src, encoding="utf-8")
print("OK milFlag ->", PATH)
