#!/usr/bin/env python3
"""Sonder-Squawks: Distanz Kalchreuth + Ampel <5 rot / <10 gelb / >=10 grün. /* adsbSpecialDist */."""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* adsbSpecialDist */" in src and "dist_col" in src:
    print("adsbSpecialDist schon drin — nichts geaendert.")
    raise SystemExit(0)
if "ADSB_SPECIAL_SQUAWKS" not in src or "special.append" not in src:
    raise SystemExit("STOP: Sonder-Squawk-Basis fehlt.")
if "adsbSpecialSqUi" not in src and "SOFORT PRÜFEN" not in src:
    raise SystemExit("STOP: UI-Patch (adsbSpecialSqUi) fehlt zuerst.")

changed = []

if "def _adsb_home_dist(" not in src:
    helper = '''def _adsb_home_dist(lat, lon):
    """km + Richtung von WEATHER_LAT/LON (Kalchreuth). /* adsbSpecialDist */"""
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
    m = re.search(r"\nADSB_SPECIAL_SQUAWKS = \{", src)
    if not m:
        raise SystemExit("STOP: ADSB_SPECIAL_SQUAWKS Anker für Helper fehlt.")
    src = src[: m.start()] + "\n" + helper + src[m.start() :]
    changed.append("helper")

OLD_APPEND = '''                special.append({
                    "sq": sq_norm,
                    "label": ADSB_SPECIAL_SQUAWKS[sq_norm],
                    "hex": (a.get("hex") or "").upper(),
                    "flight": (a.get("flight") or "–").strip() or "–",
                    "alt": alt_m,
                    "t": str(a.get("t") or a.get("type") or "").strip(),
                    "r": str(a.get("r") or "").strip(),
                })
'''
NEW_APPEND = '''                _dkm, _ddir = _adsb_home_dist(a.get("lat"), a.get("lon"))
                if _dkm is not None and _dkm < 5:
                    _dcol = "red"
                elif _dkm is not None and _dkm < 10:
                    _dcol = "yellow"
                elif _dkm is not None:
                    _dcol = "green"
                else:
                    _dcol = ""
                special.append({
                    "sq": sq_norm,
                    "label": ADSB_SPECIAL_SQUAWKS[sq_norm],
                    "hex": (a.get("hex") or "").upper(),
                    "flight": (a.get("flight") or "–").strip() or "–",
                    "alt": alt_m,
                    "t": str(a.get("t") or a.get("type") or "").strip(),
                    "r": str(a.get("r") or "").strip(),
                    "dist_km": _dkm,
                    "dist_dir": _ddir,
                    "dist_col": _dcol,
                })  # /* adsbSpecialDist */
'''
if src.count(OLD_APPEND) != 1:
    raise SystemExit("STOP: special.append Anker nicht gefunden.")
src = src.replace(OLD_APPEND, NEW_APPEND, 1)
changed.append("append")

anchor = '        out["special_legend"] = [{"sq": k, "label": v} for k, v in ADSB_SPECIAL_SQUAWKS.items()]  # /* adsbSpecialSq */\n'
sort_block = (
    '        special.sort(key=lambda x: (x.get("dist_km") is None, '
    'x.get("dist_km") if x.get("dist_km") is not None else 0))  # /* adsbSpecialDist */\n'
    '        out["special"] = special\n'
)
if "special.sort(key=" not in src:
    if src.count(anchor) != 1:
        raise SystemExit("STOP: special_legend Anker für Sort fehlt.")
    src = src.replace(anchor, sort_block + anchor, 1)
    changed.append("sort")

OLD_ROW = '''  {% for s in adsb.special %}
  <div style="margin:8px 0;padding:10px;border-radius:10px;border:2px solid #f59e0b;background:#422006">
    <div style="display:flex;justify-content:space-between;gap:8px;align-items:baseline;flex-wrap:wrap">
      <div style="font-size:1.35rem;font-weight:800;color:#fde68a;letter-spacing:0.04em">{{ s.sq }}</div>
      <div style="font-size:1.05rem;font-weight:800;color:#fff;letter-spacing:0.06em">{{ s.label }}</div>
    </div>
    <div style="margin-top:6px;font-size:1rem;font-weight:600">
      {{ s.flight }} · {{ s.hex }}{% if s.alt is not none %} · {{ s.alt }} m{% endif %}{% if s.t %} · {{ s.t }}{% endif %}
    </div>
  </div>
  {% endfor %}
'''

NEW_ROW = '''  {% for s in adsb.special %}
  {% set bcol = '#22c55e' if s.dist_col == 'green' else ('#f59e0b' if s.dist_col == 'yellow' else ('#ef4444' if s.dist_col == 'red' else '#f59e0b')) %}
  {% set bg = '#052e16' if s.dist_col == 'green' else ('#422006' if s.dist_col == 'yellow' else ('#450a0a' if s.dist_col == 'red' else '#422006')) %}
  {% set tcol = '#86efac' if s.dist_col == 'green' else ('#fde68a' if s.dist_col == 'yellow' else ('#fecaca' if s.dist_col == 'red' else '#fde68a')) %}
  <div style="margin:8px 0;padding:10px;border-radius:10px;border:2px solid {{ bcol }};background:{{ bg }}"><!-- /* adsbSpecialDist */ -->
    <div style="display:flex;justify-content:space-between;gap:8px;align-items:baseline;flex-wrap:wrap">
      <div style="font-size:1.35rem;font-weight:800;color:{{ tcol }};letter-spacing:0.04em">{{ s.sq }}</div>
      <div style="font-size:1.05rem;font-weight:800;color:#fff;letter-spacing:0.06em">{{ s.label }}</div>
    </div>
    <div style="margin-top:6px;font-size:1.15rem;font-weight:800;color:{{ tcol }}">
      {% if s.dist_km is not none %}{{ s.dist_km }} km{% if s.dist_dir %} {{ s.dist_dir }}{% endif %}{% else %}Dist ?{% endif %}
    </div>
    <div style="margin-top:4px;font-size:1rem;font-weight:600">
      {{ s.flight }} · {{ s.hex }}{% if s.alt is not none %} · {{ s.alt }} m{% endif %}{% if s.t %} · {{ s.t }}{% endif %}
    </div>
  </div>
  {% endfor %}
'''
if src.count(OLD_ROW) != 1:
    raise SystemExit("STOP: Alarmzeilen-HTML (nach UI-Patch) nicht gefunden.")
src = src.replace(OLD_ROW, NEW_ROW, 1)
changed.append("row")

OLD_CODES = '  <div class="small" style="margin-top:12px;color:#93c5fd;font-weight:700;letter-spacing:0.04em">CODES · OHNE KUNSTFLUG</div>\n'
NEW_CODES = '  <div class="small" style="margin-top:12px;color:#93c5fd;font-weight:700;letter-spacing:0.04em">CODES · OHNE KUNSTFLUG · Dist Kalchreuth</div>\n  <div class="small">&lt;5 km rot · &lt;10 km gelb · ≥10 km grün</div>\n'
if src.count(OLD_CODES) == 1:
    src = src.replace(OLD_CODES, NEW_CODES, 1)
    changed.append("legend")

PATH.write_text(src, encoding="utf-8")
print("OK adsbSpecialDist:", ", ".join(changed))
