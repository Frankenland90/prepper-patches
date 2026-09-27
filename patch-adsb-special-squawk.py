#!/usr/bin/env python3
"""ADSB: DE-Sonder-Squawks-Kachel unter Notlage (ohne Kunstflug). /* adsbSpecialSq */."""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* adsbSpecialSq */" in src:
    print("adsbSpecialSq schon drin — nichts geaendert.")
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

CONST = '''
# DE-Sonder-Squawks (ohne 0027 Kunstflug) /* adsbSpecialSq */
ADSB_SPECIAL_SQUAWKS = {
    "0020": "Hubschrauber-Rettung",
    "0023": "Bundespolizei",
    "0025": "Absetz (Fallschirm)",
    "0030": "Vermessung",
    "0034": "SAR",
    "0035": "VFR/IFR-Wechsel",
    "0036": "Polizei-Einsatz",
    "0037": "Polizei-Einsatz",
}

'''

# Insert const before fetch_adsb (or before emerg hist helper if present)
anchor_fn = "def _adsb_update_emerg_hist" if "def _adsb_update_emerg_hist" in src else "def fetch_adsb"
m = re.search(r"\n" + re.escape(anchor_fn) + r"\(", src)
if not m:
    raise SystemExit("STOP: fetch_adsb / emerg-hist Anker fehlt.")
if "ADSB_SPECIAL_SQUAWKS" not in src:
    src = src[: m.start()] + "\n" + CONST + src[m.start() :]
    changed.append("const")

# out init — prefer mil variant with emerg_hist, then without
for old, new, lab in [
    (
        '"with_pos": 0, "emerg": [], "emerg_hist": [], "mil": 0, "mil_list": [], "updated": now_str(),',
        '"with_pos": 0, "emerg": [], "emerg_hist": [], "special": [], "mil": 0, "mil_list": [], "updated": now_str(),',
        "out-init-eh-mil",
    ),
    (
        '"with_pos": 0, "emerg": [], "mil": 0, "mil_list": [], "updated": now_str(),',
        '"with_pos": 0, "emerg": [], "special": [], "mil": 0, "mil_list": [], "updated": now_str(),',
        "out-init-mil",
    ),
    (
        '"with_pos": 0, "emerg": [], "emerg_hist": [], "updated": now_str(),',
        '"with_pos": 0, "emerg": [], "emerg_hist": [], "special": [], "updated": now_str(),',
        "out-init-eh",
    ),
    (
        '"with_pos": 0, "emerg": [], "updated": now_str(),',
        '"with_pos": 0, "emerg": [], "special": [], "updated": now_str(),',
        "out-init",
    ),
]:
    if one(old, new, lab, False):
        break
else:
    raise SystemExit("STOP: out-init Anker nicht gefunden.")

# special = [] next to emerg = []
one("        emerg = []\n", "        emerg = []\n        special = []  # /* adsbSpecialSq */\n", "special-init")

# After emerg.append block, add special detection
OLD_APPEND = '''            if kind:
                emerg.append({
                    "kind": kind,
                    "hex": (a.get("hex") or "").upper(),
                    "flight": (a.get("flight") or "–").strip() or "–",
                    "alt": a.get("alt_baro"),
                    "sq": sq or "–",
                })
'''
NEW_APPEND = '''            if kind:
                emerg.append({
                    "kind": kind,
                    "hex": (a.get("hex") or "").upper(),
                    "flight": (a.get("flight") or "–").strip() or "–",
                    "alt": a.get("alt_baro"),
                    "sq": sq or "–",
                })
            sq_norm = (sq.zfill(4) if sq.isdigit() else sq)
            if sq_norm in ADSB_SPECIAL_SQUAWKS and len(special) < 40:
                alt_m = a.get("alt_baro")
                try:
                    if alt_m is not None:
                        alt_m = int(round(float(alt_m) * 0.3048))
                except Exception:
                    alt_m = a.get("alt_baro")
                special.append({
                    "sq": sq_norm,
                    "label": ADSB_SPECIAL_SQUAWKS[sq_norm],
                    "hex": (a.get("hex") or "").upper(),
                    "flight": (a.get("flight") or "–").strip() or "–",
                    "alt": alt_m,
                    "t": str(a.get("t") or a.get("type") or "").strip(),
                    "r": str(a.get("r") or "").strip(),
                })
'''
one(OLD_APPEND, NEW_APPEND, "detect")

# Add special to out.update
for old, new, lab in [
    (
        '"emerg": emerg, "mil": mil_n, "mil_list": mil_list, "updated": now_str(),',
        '"emerg": emerg, "special": special, "mil": mil_n, "mil_list": mil_list, "updated": now_str(),',
        "update-mil",
    ),
    (
        '"emerg": emerg, "updated": now_str(),',
        '"emerg": emerg, "special": special, "updated": now_str(),',
        "update-plain",
    ),
]:
    if one(old, new, lab, False):
        break
else:
    raise SystemExit("STOP: out.update emerg Anker nicht gefunden.")

# Also expose legend list once for template
# Inject after emerg_hist line or after out.update block — add special_legend on out
INJECT_LEGEND = '        out["special_legend"] = [{"sq": k, "label": v} for k, v in ADSB_SPECIAL_SQUAWKS.items()]  # /* adsbSpecialSq */\n'
if 'out["special_legend"]' not in src:
    if 'out["emerg_hist"] = _adsb_update_emerg_hist(emerg)' in src:
        src = src.replace(
            'out["emerg_hist"] = _adsb_update_emerg_hist(emerg)  # /* adsbEmergHist */\n',
            'out["emerg_hist"] = _adsb_update_emerg_hist(emerg)  # /* adsbEmergHist */\n' + INJECT_LEGEND,
            1,
        )
        changed.append("legend-after-hist")
    else:
        # after special in out.update — find the update closing and inject
        src2, n = re.subn(
            r'("special": special(?:, "mil": mil_n, "mil_list": mil_list)?, "updated": now_str\(\),\s*\}\)\n)',
            r'\1' + INJECT_LEGEND,
            src,
            count=1,
        )
        if n != 1:
            raise SystemExit("STOP: special_legend Inject fehlgeschlagen.")
        src = src2
        changed.append("legend-after-update")

# Template: insert new card after Squawk/Notlage card
# Prefer post-emerg-hist version, else classic
CARD = '''
<div class="card"><!-- /* adsbSpecialSq */ -->
  <div class="title">Sonder-Squawks (DE)</div>
  {% if adsb.special %}
  <div class="big" style="margin-bottom:6px">{{ adsb.special|length }}</div>
  <div style="display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:6px;margin-top:6px">
    {% for s in adsb.special %}
    <div style="background:#0f172a;border:1px solid #334155;border-radius:8px;padding:6px;font-size:0.68rem;line-height:1.25;overflow:hidden">
      <div style="color:#93c5fd;font-weight:700">{{ s.sq }}</div>
      <div style="color:#fde68a">{{ s.label }}</div>
      <div style="margin-top:2px">{{ s.flight }}</div>
      <div class="small" style="margin-top:1px">{{ s.hex }}{% if s.alt is not none %} · {{ s.alt }} m{% endif %}</div>
    </div>
    {% endfor %}
  </div>
  {% else %}
  <div><span class="okdot">●</span> Keine Sonder-Squawks aktuell</div>
  {% endif %}
  <div class="small" style="margin-top:10px;color:#93c5fd;font-weight:600">Standards (ohne Kunstflug)</div>
  <div style="display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:6px;margin-top:6px">
    {% for s in adsb.special_legend or [] %}
    <div style="background:#0f172a;border:1px solid #1e293b;border-radius:8px;padding:6px;font-size:0.68rem;line-height:1.25">
      <div style="color:#93c5fd;font-weight:700">{{ s.sq }}</div>
      <div>{{ s.label }}</div>
    </div>
    {% endfor %}
  </div>
  <div class="small">0020 Rettung · 0023 BPol · 0025 Absetz · 0030 Vermessung · 0034 SAR · 0035 VFR/IFR · 0036/37 Polizei</div>
</div>
'''

# Find closing of Notlage card — after emerg hist footer or classic footer
markers = [
    '  <div class="small">7500 Entführung · 7600 Funkausfall · 7700 allgemeiner Notfall · Historie in adsb_emerg_hist.json</div>\n</div>\n',
    '  <div class="small">7500 Entführung · 7600 Funkausfall · 7700 allgemeiner Notfall</div>\n</div>\n',
]
inserted = False
for mk in markers:
    if src.count(mk) == 1:
        src = src.replace(mk, mk + CARD, 1)
        changed.append("card")
        inserted = True
        break
if not inserted:
    raise SystemExit("STOP: Notlage-Karten-Ende nicht gefunden.")

PATH.write_text(src, encoding="utf-8")
print("OK adsbSpecialSq:", ", ".join(changed))
