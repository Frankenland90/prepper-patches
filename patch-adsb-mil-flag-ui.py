#!/usr/bin/env python3
"""Militär-Tabelle: kleinere Schrift, nowrap. /* milFlagUi */."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* milFlagUi */" in src:
    print("milFlagUi schon drin — nichts geaendert.")
    raise SystemExit(0)

old = '''  <table style="width:100%;border-collapse:collapse;font-size:0.85rem;line-height:1.35">
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
'''

new = '''  <table style="width:100%;border-collapse:collapse;font-size:0.7rem;line-height:1.2;table-layout:auto"><!-- /* milFlagUi */ -->
    <thead>
      <tr style="text-align:left;color:#94a3b8;border-bottom:1px solid #334155">
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Land</th>
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Rufzeichen</th>
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Hex</th>
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Typ</th>
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Höhe</th>
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Squawk</th>
      <th style="padding:1px 4px 3px 0;font-weight:600;white-space:nowrap">Kennzeichen</th>
      </tr>
    </thead>
    <tbody>
    {% for m in adsb.mil_list %}
      <tr style="border-bottom:1px solid #1e293b">
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.flag or "" }}{% if m.cc %} {{ m.cc }}{% else %}–{% endif %}</td>
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.flight or "–" }}</td>
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.hex }}</td>
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.t or "–" }}</td>
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{% if m.alt is not none %}{{ m.alt }}&nbsp;m{% else %}–{% endif %}</td>
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.sq or "–" }}</td>
        <td style="padding:1px 4px 1px 0;white-space:nowrap">{{ m.r or "–" }}</td>
      </tr>
    {% endfor %}
'''

n = src.count(old)
if n != 1:
    raise SystemExit("STOP milFlagUi: Tabellen-Anker %sx (erwartet 1)." % n)
PATH.write_text(src.replace(old, new, 1), encoding="utf-8")
print("OK milFlagUi ->", PATH)
