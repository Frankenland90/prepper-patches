#!/usr/bin/env python3
"""Zuhause: Abfall ERH Käswasser + Notrufe + Tierkliniken. # zuhausePage # zuhauseJinjaFix # zuhauseCacheFix # zuhausePolizeiPI"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from datetime import date, datetime
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
CACHE = BASE / "zuhause_status.json"
ICS_URL = "https://www.erlangen-hoechstadt.de/komx/surface/dfxabfallics/GetAbfallIcs"
ORT = "KALCHREUTH"
STRASSE = "Käswasser"  # Landkreis-Ortsteil; Adresse = Käswasserstrasse
CACHE_MAX_AGE_SEC = 6 * 3600

WEEKDAYS_DE = [
    "Montag", "Dienstag", "Mittwoch", "Donnerstag",
    "Freitag", "Samstag", "Sonntag",
]

VETS = [
    {
        "id": "hafen",
        "name": "Tierklinik am Hafen",
        "note": "24/7 Notfallklinik",
        "address": "Wertachstraße 1, 90451 Nürnberg",
        "phone": "0911 643110",
        "phone_tel": "+49911643110",
        "url": "https://www.tierklinik-nbg.de",
        "hours": "Rund um die Uhr (Notfälle). Vorher anrufen wenn möglich.",
        "badge": "24/7",
    },
    {
        "id": "nordring",
        "name": "Tierklinik am Nordring",
        "note": "Tagesklinik · erweiterter Notdienst",
        "address": "Obermaierstraße 10, 90408 Nürnberg",
        "phone": "0911 366513",
        "phone_tel": "+49911366513",
        "url": "https://www.tierkliniknuernberg.com",
        "hours": (
            "Mo–Fr 8–13 & 14–22 (ab 18 Notdienst). "
            "Sa/So/Feiertag 9–13 & 15–17 nur Notdienst. "
            "Telefon im Notdienst oft nicht besetzt — ggf. Hafen."
        ),
        "badge": "bis 22 Uhr",
    },
]

EMERGENCY = [
    {
        "group": "Notruf",
        "entries": [
            {"name": "Feuerwehr / Rettung", "phone": "112", "hint": "Leben, Brand, Unfall"},
            {"name": "Polizei", "phone": "110", "hint": ""},
            {
                "name": "Polizeiinspektion Erlangen-Land",
                "phone": "09131 98842-0",
                "hint": "Ersatz bei 110-Ausfall · Gräfenberger Str. 41, Uttenreuth",
            },
            {"name": "Ärztlicher Bereitschaftsdienst", "phone": "116117", "hint": "ohne Notarzt"},
            {"name": "Giftnotruf Bayern", "phone": "089 19240", "hint": "München"},
        ],
    },
    {
        "group": "Gemeinde & Landkreis",
        "entries": [
            {
                "name": "Gemeinde Kalchreuth (Rathaus)",
                "phone": "0911 518344-0",
                "hint": "Rathausstraße 1",
            },
            {
                "name": "Landratsamt ERH",
                "phone": "09131 803-1000",
                "hint": "Nägelsbachstr. 1, Erlangen",
            },
        ],
    },
    {
        "group": "Energie & Versorgung",
        "entries": [
            {"name": "N-ERGIE Störung Strom", "phone": "0800 4442000", "hint": "kostenfrei"},
            {"name": "N-ERGIE Kundenservice", "phone": "0911 80253000", "hint": ""},
        ],
    },
    {
        "group": "Abfall",
        "entries": [
            {
                "name": "Veolia Restmüll-Reklamation",
                "phone": "0911 94577669",
                "hint": "nicht geleert",
            },
            {
                "name": "Gelber-Sack-Hotline",
                "phone": "0800 1004337",
                "hint": "Hofmann / Duales System",
            },
        ],
    },
]


def _now_str() -> str:
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def _http_get(url: str, timeout: int = 25) -> str:
    req = urllib.request.Request(
        url, headers={"User-Agent": "prepper-dashboard-zuhause/1.0"}
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    for enc in ("utf-8", "latin-1"):
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode("utf-8", "replace")


def _parse_ics(text: str):
    events = []
    cur_d = None
    cur_s = None
    for line in text.splitlines():
        line = line.strip()
        if line == "BEGIN:VEVENT":
            cur_d, cur_s = None, None
        elif line.startswith("DTSTART"):
            m = re.search(r"(\d{8})", line)
            if m:
                cur_d = datetime.strptime(m.group(1), "%Y%m%d").date()
        elif line.startswith("SUMMARY:"):
            cur_s = line[8:].replace("\\,", ",").replace("\\;", ";").strip()
        elif line == "END:VEVENT" and cur_d and cur_s:
            events.append((cur_d, cur_s))
    return events


def _classify(summary: str):
    s = summary.lower()
    if "gartenabfall" in s or "problemabfall" in s:
        return None
    if "papier" in s or "gelb" in s:
        return "papier_gelb"
    if "restmüll" in s or "restmuell" in s or "restmülltonne" in s or "biotonne" in s:
        return "rest"
    return None


def _ampel(days: int):
    if days <= 0:
        return "red", "heute"
    if days <= 2:
        return "yellow", ("morgen" if days == 1 else "in 2 Tagen")
    return "ok", f"in {days} Tagen"


def _next_of(events, kind, today):
    for d, s in sorted(events, key=lambda x: x[0]):
        if _classify(s) != kind:
            continue
        if d < today:
            continue
        days = (d - today).days
        color, until = _ampel(days)
        return {
            "date": d.isoformat(),
            "date_fmt": d.strftime("%d.%m.%Y"),
            "weekday": WEEKDAYS_DE[d.weekday()],
            "days": days,
            "until": until,
            "color": color,
            "summary": s.split(",")[0].strip(),
        }
    return None


def fetch_waste(force: bool = False) -> dict:
    today = date.today()
    years = [today.year]
    if today.month >= 11:
        years.append(today.year + 1)

    all_ev = []
    err = None
    try:
        for y in years:
            q = urllib.parse.urlencode(
                {"ort": ORT, "strasse": STRASSE, "abfallart": "Alle", "jahr": y}
            )
            text = _http_get(f"{ICS_URL}?{q}")
            all_ev.extend(_parse_ics(text))
    except Exception as e:
        err = str(e)[:160]

    rest = _next_of(all_ev, "rest", today)
    pg = _next_of(all_ev, "papier_gelb", today)

    papier = gelb = None
    if pg:
        papier = dict(pg)
        papier["label"] = "Papiermüll"
        papier["summary"] = "Papiertonne"
        gelb = dict(pg)
        gelb["label"] = "Gelber Sack"
        gelb["summary"] = "Gelber Sack"

    if rest:
        rest = dict(rest)
        rest["label"] = "Restmüll"
        rest["summary"] = "Restmüll"

    return {
        "ok": err is None and bool(all_ev),
        "error": err,
        "ort": "Kalchreuth",
        "strasse_ics": STRASSE,
        "strasse_addr": "Käswasserstrasse",
        "items": [x for x in (rest, papier, gelb) if x],
        "count_events": len(all_ev),
        "at": _now_str(),
        "ts": time.time(),
    }


def load_or_refresh(force: bool = False) -> dict:
    if not force and CACHE.exists():
        try:
            data = json.loads(CACHE.read_text(encoding="utf-8"))
            age_ok = time.time() - float(data.get("ts") or 0) < CACHE_MAX_AGE_SEC
            em = data.get("emergency") or []
            # alter Cache hatte key "items" — Jinja braucht "entries"
            has_entries = bool(em) and all(
                isinstance(g, dict) and (g.get("entries") or g.get("items"))
                for g in em
            )
            if age_ok and has_entries:
                # migrate items -> entries in memory
                for g in em:
                    if "entries" not in g and "items" in g:
                        g["entries"] = g.pop("items")
                data["emergency"] = em
                return data
        except Exception:
            pass
    waste = fetch_waste(force=force)
    out = {
        "ts": time.time(),
        "at": _now_str(),
        "waste": waste,
        "vets": VETS,
        "emergency": EMERGENCY,
        "location": {
            "plz": "90562",
            "ort": "Kalchreuth",
            "strasse": "Käswasserstrasse",
            "landkreis": "Erlangen-Höchstadt",
        },
    }
    try:
        tmp = CACHE.with_suffix(".tmp")
        tmp.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp.replace(CACHE)
    except Exception:
        pass
    return out


def page_template(base_style: str) -> str:
    """Vollständige Jinja-Seite; base_style = BASE_STYLE aus dashboard.py."""
    nav = """<nav class="nav-top">
  <div class="nav-row">
    <a href="/">Lage</a>
    <a href="/energie">Energie</a> <a href="/lokale-energie">Lokale Energie</a>
    <a href="/speicher">Speicher</a>
    <a href="/umwelt">Umwelt</a> <a href="/luft">Luft</a>
  <a href="/pegel">Pegel</a>
    <a href="/adsb">ADSB</a>
    <a href="/zuhause" class="on">Zuhause</a>
  </div>

  <div class="nav-row">
    <a href="/mesh">Mesh 1</a>
    <a href="/mesh2">Mesh 2</a>
    <a href="/news">News</a>
    <a href="/funk">Funk</a> <a href="/pi">System</a>
    <a href="/medizin">Medizin</a>

  </div>
</nav>
"""
    head = (
        '<!DOCTYPE html><html lang="de"><head>\n'
        '<meta charset="utf-8"><meta name="viewport" '
        'content="width=device-width,initial-scale=1,maximum-scale=1">\n'
        "<title>Zuhause</title>\n<style>\n"
        + base_style
        + """
.zuh-ok{background:#0f172a}
.zuh-yellow{background:#422006;border-color:#f59e0b!important}
.zuh-red{background:#450a0a;border-color:#ef4444!important}
.zuh-badge{font-size:0.78rem;color:#cbd5e1;background:#1e293b;padding:2px 8px;border-radius:999px}
.zuh-yellow .zuh-badge{background:#92400e;color:#fde68a}
.zuh-red .zuh-badge{background:#7f1d1d;color:#fecaca}
.small{color:#94a3b8;font-size:0.78rem}
</style></head><body>
"""
    )
    body = """
<div class="header">Zuhause · Kalchreuth</div>
<div class="page-title">🏠 Käswasserstrasse · 90562</div>
<div class="page-sub">Müll · Notrufe · Tierkliniken · Stand {{ z.at }}</div>

<div class="grid">
  <div class="card full">
    <div class="title">Müllabfuhr</div>
    <div class="small">Landkreis ERH · Ortsteil Käswasser · ohne Biomüll-Anzeige</div>
    {% set w = z.waste or {} %}
    {% if not w.get('ok') %}
      <div class="big" style="color:#f87171;margin-top:8px">Kalender nicht geladen</div>
      <div class="small">{{ w.get('error') or '—' }}</div>
    {% else %}
      {% for it in w.get('items') or [] %}
      <div class="zuh-row zuh-{{ it.color }}" style="margin-top:10px;padding:10px;border-radius:10px;border:1px solid #334155">
        <div style="display:flex;justify-content:space-between;gap:8px;align-items:baseline">
          <b>{{ it.label }}</b>
          <span class="zuh-badge">{{ it.until }}</span>
        </div>
        <div style="margin-top:4px;font-size:1.05rem">{{ it.weekday }} · {{ it.date_fmt }}</div>
        <div class="small">{{ it.summary }}</div>
      </div>
      {% endfor %}
    {% endif %}
  </div>

  <div class="card full">
    <div class="title">Tierkliniken</div>
    <div class="small">Im Notfall wenn möglich vorher anrufen</div>
    {% for v in z.vets or [] %}
    <div style="margin-top:12px;padding:10px;border-radius:10px;border:1px solid #334155">
      <div style="display:flex;justify-content:space-between;gap:8px;align-items:baseline">
        <b>{{ v.name }}</b>
        <span class="zuh-badge">{{ v.badge }}</span>
      </div>
      <div class="small">{{ v.note }}</div>
      <div style="margin-top:6px">{{ v.address }}</div>
      <div style="margin-top:6px;font-size:1.15rem">
        <a href="tel:{{ v.phone_tel }}" style="color:#93c5fd;text-decoration:none">{{ v.phone }}</a>
      </div>
      <div class="small" style="margin-top:4px">{{ v.hours }}</div>
      <div class="small" style="margin-top:4px"><a href="{{ v.url }}" style="color:#7dd3fc">{{ v.url.replace('https://','') }}</a></div>
    </div>
    {% endfor %}
  </div>

  <div class="card full">
    <div class="title">Notrufe &amp; Wichtige Nummern</div>
    {% for g in z.emergency or [] %}
    <div style="margin-top:12px">
      <div class="small" style="color:#93c5fd;font-weight:600">{{ g.group }}</div>
      {% for it in (g.get('entries') or g.get('items') or []) %}
      <div style="display:flex;justify-content:space-between;gap:10px;padding:8px 0;border-bottom:1px solid #1e293b;align-items:baseline">
        <div>
          <div>{{ it.name }}</div>
          {% if it.hint %}<div class="small">{{ it.hint }}</div>{% endif %}
        </div>
        <a href="tel:{{ it.phone.replace(' ','').replace('-','') }}" style="color:#93c5fd;text-decoration:none;font-weight:600;white-space:nowrap">{{ it.phone }}</a>
      </div>
      {% endfor %}
    </div>
    {% endfor %}
  </div>
</div>
</body></html>
"""
    return nav + head + body


if __name__ == "__main__":
    d = load_or_refresh(force=True)
    print(json.dumps(d["waste"], ensure_ascii=False, indent=2))
