#!/usr/bin/env python3
"""Militär-Tabelle: Distanz von Kalchreuth (WEATHER_LAT/LON). /* milDist */."""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* milDist */" in src:
    print("milDist schon drin — nichts geaendert.")
    raise SystemExit(0)

if '"flag"' not in src or "mil_list.append" not in src:
    raise SystemExit("STOP: milFlag fehlt — zuerst Flaggen-Patch.")

helper = '''def _adsb_home_dist(lat, lon):
    """km + kurze Richtung von WEATHER_LAT/LON (Kalchreuth). /* milDist */"""
    try:
        from config import WEATHER_LAT, WEATHER_LON
        lat0, lon0 = float(WEATHER_LAT), float(WEATHER_LON)
    except Exception:
        lat0, lon0 = 49.557, 11.133
    try:
        la, lo = float(lat), float(lon)
    except Exception:
        return None, ""
    import math
    r = 6371.0
    p1, p2 = math.radians(lat0), math.radians(la)
    dphi = math.radians(la - lat0)
    dlmb = math.radians(lo - lon0)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    km = 2 * r * math.asin(min(1.0, math.sqrt(a)))
    y = math.sin(dlmb) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dlmb)
    brg = (math.degrees(math.atan2(y, x)) + 360.0) % 360.0
    dirs = ("N", "NO", "O", "SO", "S", "SW", "W", "NW")
    label = dirs[int((brg + 22.5) // 45) % 8]
    return round(km, 1), label


'''

if "def _adsb_icao_cc(hx):" in src:
    if src.count("def _adsb_icao_cc(hx):\n") != 1:
        raise SystemExit("STOP: _adsb_icao_cc Anker unklar.")
    src = src.replace("def _adsb_icao_cc(hx):\n", helper + "def _adsb_icao_cc(hx):\n", 1)
else:
    raise SystemExit("STOP: _adsb_icao_cc fehlt.")

old_tail = '''                        "cc": _cc or "",
                        "flag": _flag or "",
                    })
'''
new_tail = '''                        "cc": _cc or "",
                        "flag": _flag or "",
                        "dist_km": _dkm,
                        "dist_dir": _ddir,
                    })
'''
if src.count(old_tail) != 1:
    raise SystemExit("STOP: mil_list cc/flag-Ende nicht gefunden.")

m = re.search(
    r'(                    _hx = \(a\.get\("hex"\) or ""\)\.upper\(\)\n'
    r'                    _cc, _flag = _adsb_icao_cc\(_hx\)\n)',
    src,
)
if not m:
    raise SystemExit("STOP: _hx/_cc Block nicht gefunden.")

inject = m.group(1) + (
    '                    _dkm, _ddir = _adsb_home_dist(a.get("lat"), a.get("lon"))\n'
)
src = src[: m.start()] + inject + src[m.end() :]
src = src.replace(old_tail, new_tail, 1)

sort_anchor = '"mil": mil_n, "mil_list": mil_list,'
if src.count(sort_anchor) != 1:
    raise SystemExit("STOP: mil_list out.update Anker.")
src = src.replace(
    sort_anchor,
    '"mil": mil_n, "mil_list": sorted(mil_list, key=lambda x: (x.get("dist_km") is None, x.get("dist_km") if x.get("dist_km") is not None else 0)),',
    1,
)

old_tbl = '''  <table style="width:100%;border-collapse:collapse;font-size:0.7rem;line-height:1.2;table-layout:auto"><!-- /* milFlagUi */ -->
    <thead>
      <tr style="text-align:left;color:#94a3b8;border-bottom:1px solid #334155">
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Land</th>
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Rufzeichen</th>
'''
new_tbl = '''  <table style="width:100%;border-collapse:collapse;font-size:0.62rem;line-height:1.15;table-layout:auto"><!-- /* milFlagUi */ /* milDist */ -->
    <thead>
      <tr style="text-align:left;color:#94a3b8;border-bottom:1px solid #334155">
      <th style="padding:1px 3px 3px 0;font-weight:600;white-space:nowrap">Land</th>
      <th style="padding:1px 3px 3px 0;font-weight:600;white-space:nowrap">Dist</th>
      <th style="padding:1px 3px 3px 0;font-weight:600;white-space:nowrap">Rufzeichen</th>
'''
if src.count(old_tbl) != 1:
    raise SystemExit("STOP: Tabellen-Header (milFlagUi) nicht gefunden.")
src = src.replace(old_tbl, new_tbl, 1)

old_row = '''        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.flag or "" }}{% if m.cc %} {{ m.cc }}{% else %}–{% endif %}</td>
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.flight or "–" }}</td>
'''
new_row = '''        <td style="padding:1px 3px 1px 0;white-space:nowrap">{{ m.flag or "" }}{% if m.cc %} {{ m.cc }}{% else %}–{% endif %}</td>
        <td style="padding:1px 3px 1px 0;white-space:nowrap">{% if m.dist_km is not none %}{{ m.dist_km }}&nbsp;km{% if m.dist_dir %} {{ m.dist_dir }}{% endif %}{% else %}–{% endif %}</td>
        <td style="padding:1px 3px 1px 0;white-space:nowrap">{{ m.flight or "–" }}</td>
'''
if src.count(old_row) != 1:
    raise SystemExit("STOP: Tabellen-Zeile Land/Flug nicht gefunden.")
src = src.replace(old_row, new_row, 1)

src_count_before = src.count('padding:1px 4px 1px 0;white-space:nowrap')
if src_count_before <= 8:
    src = src.replace(
        'padding:1px 4px 1px 0;white-space:nowrap',
        'padding:1px 3px 1px 0;white-space:nowrap',
    )
    src = src.replace(
        'padding:1px 4px 3px 0;font-weight:600;white-space:nowrap',
        'padding:1px 3px 3px 0;font-weight:600;white-space:nowrap',
    )

old_ft = 'dbFlags Bit0 · max. 20 Zeilen · Höhe ft->m · Land aus ICAO-Hex'
new_ft = 'dbFlags Bit0 · max. 20 · ft->m · ICAO-Land · Dist Kalchreuth'
if old_ft in src:
    src = src.replace(old_ft, new_ft, 1)

PATH.write_text(src, encoding="utf-8")
print("OK milDist ->", PATH)
