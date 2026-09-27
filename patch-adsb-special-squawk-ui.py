#!/usr/bin/env python3
"""ADSB Sonder-Squawks: Prepper-Haptik (scharf, vollbreit, kurze Labels). /* adsbSpecialSqUi */."""
from pathlib import Path
import re
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* adsbSpecialSqUi */" in src:
    print("adsbSpecialSqUi schon drin — nichts geaendert.")
    raise SystemExit(0)
if "/* adsbSpecialSq */" not in src and "ADSB_SPECIAL_SQUAWKS" not in src:
    raise SystemExit("STOP: Sonder-Squawk-Basis fehlt — erst adsbSpecialSq anwenden.")

changed = []

OLD_DICT = '''ADSB_SPECIAL_SQUAWKS = {
    "0020": "Hubschrauber-Rettung",
    "0023": "Bundespolizei",
    "0025": "Absetz (Fallschirm)",
    "0030": "Vermessung",
    "0034": "SAR",
    "0035": "VFR/IFR-Wechsel",
    "0036": "Polizei-Einsatz",
    "0037": "Polizei-Einsatz",
}'''
NEW_DICT = '''ADSB_SPECIAL_SQUAWKS = {  # /* adsbSpecialSqUi */ kurze Labels
    "0020": "RETTUNG",
    "0023": "BPOL",
    "0025": "ABSETZ",
    "0030": "VERMESS.",
    "0034": "SAR",
    "0035": "VFR/IFR",
    "0036": "POLIZEI",
    "0037": "POLIZEI",
}'''
if src.count(OLD_DICT) == 1:
    src = src.replace(OLD_DICT, NEW_DICT, 1)
    changed.append("labels")
elif "RETTUNG" in src and '"0020": "RETTUNG"' in src:
    changed.append("labels-skip")
else:
    # fuzzy: replace values inside existing dict
    m = re.search(r"ADSB_SPECIAL_SQUAWKS = \{.*?\}", src, re.S)
    if not m:
        raise SystemExit("STOP: ADSB_SPECIAL_SQUAWKS Dict fehlt.")
    src = src[: m.start()] + NEW_DICT + src[m.end() :]
    changed.append("labels-re")

OLD_CARD = '''<div class="card"><!-- /* adsbSpecialSq */ -->
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
</div>'''

NEW_CARD = '''<div class="card{% if adsb.special %} warn{% endif %}"><!-- /* adsbSpecialSq */ /* adsbSpecialSqUi */ -->
  <div class="title">Sonder-Squawks (DE)</div>
  {% if adsb.special %}
  <div style="display:flex;justify-content:space-between;align-items:baseline;gap:8px;margin-bottom:8px">
    <div class="big" style="color:#fde68a">{{ adsb.special|length }} AKTIV</div>
    <div class="small" style="color:#fca5a5;font-weight:600">SOFORT PRÜFEN</div>
  </div>
  {% for s in adsb.special %}
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
  {% else %}
  <div><span class="okdot">●</span> Keine Sonder-Squawks</div>
  {% endif %}
  <div class="small" style="margin-top:12px;color:#93c5fd;font-weight:700;letter-spacing:0.04em">CODES · OHNE KUNSTFLUG</div>
  <div style="display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:5px;margin-top:6px">
    {% for s in adsb.special_legend or [] %}
    <div style="background:#0f172a;border:1px solid #334155;border-radius:8px;padding:8px 4px;text-align:center">
      <div style="color:#93c5fd;font-weight:800;font-size:0.95rem;font-variant-numeric:tabular-nums">{{ s.sq }}</div>
      <div style="color:#e2e8f0;font-weight:700;font-size:0.72rem;letter-spacing:0.03em;margin-top:2px">{{ s.label }}</div>
    </div>
    {% endfor %}
  </div>
</div>'''

if src.count(OLD_CARD) != 1:
    # try regex extract from marker to next card
    m = re.search(
        r'<div class="card(?:\{% if adsb\.special %\} warn\{% endif %\})?"><!-- /\* adsbSpecialSq \*/(?: /\* adsbSpecialSqUi \*/)? -->.*?</div>\n(?=<div class="card")',
        src,
        re.S,
    )
    if not m:
        raise SystemExit("STOP: Sonder-Squawk-Kachel HTML nicht gefunden.")
    src = src[: m.start()] + NEW_CARD + "\n" + src[m.end() :]
    changed.append("card-re")
else:
    src = src.replace(OLD_CARD, NEW_CARD, 1)
    changed.append("card")

PATH.write_text(src, encoding="utf-8")
print("OK adsbSpecialSqUi:", ", ".join(changed))
