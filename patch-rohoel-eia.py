#!/usr/bin/env python3
"""Replace EuroOilWatch Rohöl fetch with EIA RBRTE + EZB (Yahoo fallback). Idempotent (# rohoelEia)."""
from pathlib import Path
import shutil
import sys
from datetime import datetime

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

MARKER = "# rohoelEia"
if MARKER in src:
    print("already patched (rohoelEia) — nichts geändert.")
    sys.exit(0)

if "def fetch_rohoel(" not in src:
    raise SystemExit("STOP: def fetch_rohoel() fehlt — EuroOilWatch-Patch zuerst?")

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
bak = PATH.with_name(f"dashboard.py.bak-rohoeleia-{stamp}")
shutil.copy2(PATH, bak)
print(f"Backup: {bak}")


def must_replace(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"STOP {label}: Anker {n}x gefunden (erwartet 1). Backup bleibt: {bak}")
    return text.replace(old, new, 1)


OLD_FETCH = '''def fetch_rohoel():
    """Brent aktuell + 14-Tage-Verlauf (EuroOilWatch, kein API-Key)."""
    result = {"brent": None}
    try:
        hist = requests.get("https://eurooilwatch.com/api/v1/brent-history", timeout=10)
        hist.raise_for_status()
        entries = (hist.json() or {}).get("entries") or []
        last14 = [e for e in entries if e.get("priceEur") is not None][-14:]
        oil_history.clear()
        for e in last14:
            d = str(e.get("date") or "")
            label = d[8:10] + "." + d[5:7] if len(d) >= 10 else d
            oil_history.append({"t": label, "v": round(float(e["priceEur"]), 2)})
        save_oil_history()
        live = requests.get("https://eurooilwatch.com/api/v1/brent", timeout=8)
        live.raise_for_status()
        px = (live.json() or {}).get("priceEur")
        if px is None and last14:
            px = last14[-1].get("priceEur")
        result["brent"] = round(float(px), 2) if px is not None else None
        update_fail_counter("rohoel", True)
    except Exception as e:
        print("Rohöl-Fehler:", e)
        update_fail_counter("rohoel", False)
        if oil_history:
            result["brent"] = oil_history[-1].get("v")
    return result
'''

NEW_FETCH = r'''def fetch_ecb_usd_per_eur():
    """EZB Referenzkurs: USD je 1 EUR → (rate, date_str YYYY-MM-DD)."""
    import xml.etree.ElementTree as ET
    r = requests.get(
        "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml",
        timeout=10,
        headers={"User-Agent": "prepper-dashboard/1.0"},
    )
    r.raise_for_status()
    root = ET.fromstring(r.content)
    for el in root.iter():
        if "}" in el.tag:
            el.tag = el.tag.split("}", 1)[1]
    date_str = None
    rate = None
    for cube in root.iter("Cube"):
        if cube.get("time"):
            date_str = cube.get("time")
        if cube.get("currency") == "USD" and cube.get("rate") is not None:
            rate = float(cube.get("rate"))
            break
    if rate is None:
        raise RuntimeError("ECB USD-Kurs fehlt")
    return rate, date_str


def fetch_eia_brent_daily(api_key, length=20):
    """EIA Europe Brent Spot FOB (RBRTE) → [{date, usd}, ...] neueste zuerst."""
    from urllib.parse import urlencode
    params = [
        ("api_key", api_key),
        ("frequency", "daily"),
        ("data[0]", "value"),
        ("facets[series][]", "RBRTE"),
        ("sort[0][column]", "period"),
        ("sort[0][direction]", "desc"),
        ("length", str(length)),
    ]
    url = "https://api.eia.gov/v2/petroleum/pri/spt/data/?" + urlencode(params)
    r = requests.get(url, timeout=20, headers={"User-Agent": "prepper-dashboard/1.0"})
    r.raise_for_status()
    rows = ((r.json() or {}).get("response") or {}).get("data") or []
    out = []
    for row in rows:
        period = str(row.get("period") or "")
        val = row.get("value")
        if not period or val is None or val == "":
            continue
        try:
            out.append({"date": period[:10], "usd": float(val)})
        except (TypeError, ValueError):
            continue
    return out


def fetch_yahoo_brent_daily():
    """Yahoo BZ=F Tages-Schlusskurse → [{date, usd}, ...] chronologisch."""
    url = "https://query1.finance.yahoo.com/v8/finance/chart/BZ=F?interval=1d&range=1mo"
    r = requests.get(url, timeout=15, headers={"User-Agent": "Mozilla/5.0"})
    r.raise_for_status()
    result = ((r.json() or {}).get("chart") or {}).get("result") or []
    if not result:
        raise RuntimeError("Yahoo chart leer")
    res0 = result[0]
    ts = res0.get("timestamp") or []
    quote = ((res0.get("indicators") or {}).get("quote") or [{}])[0]
    closes = quote.get("close") or []
    out = []
    for t, c in zip(ts, closes):
        if c is None:
            continue
        d = datetime.fromtimestamp(int(t), tz=timezone.utc).strftime("%Y-%m-%d")
        out.append({"date": d, "usd": float(c)})
    meta_px = (res0.get("meta") or {}).get("regularMarketPrice")
    if meta_px is not None and out:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if out[-1]["date"] != today:
            out.append({"date": today, "usd": float(meta_px)})
        else:
            out[-1]["usd"] = float(meta_px)
    return out


def fetch_rohoel():
    """Brent Spot EUR: EIA RBRTE + EZB, Fallback Yahoo BZ=F + EZB. # rohoelEia"""
    result = {
        "brent": None,
        "session": None,
        "source": None,
        "color": "#eab308",
        "usd": None,
        "fx": None,
        "fx_day": None,
    }

    def _session_color(date_str):
        if not date_str:
            return "#eab308"
        try:
            from zoneinfo import ZoneInfo
            today = datetime.now(ZoneInfo("Europe/Berlin")).date()
        except Exception:
            today = datetime.now().date()
        try:
            sess = datetime.strptime(str(date_str)[:10], "%Y-%m-%d").date()
        except Exception:
            return "#ef4444"
        age = (today - sess).days
        if age <= 3:
            return "#22c55e"
        if age <= 7:
            return "#eab308"
        return "#ef4444"

    def _read_eia_key():
        k = (os.environ.get("EIA_API_KEY") or "").strip()
        if k:
            return k
        here = os.path.dirname(os.path.abspath(__file__))
        for p in (
            os.path.join(here, "secrets", "eia_api_key"),
            "/home/fmg/prepper-dashboard/secrets/eia_api_key",
        ):
            try:
                with open(p, "r", encoding="utf-8") as f:
                    t = f.read().strip()
                if t:
                    return t
            except Exception:
                pass
        return None

    def _apply_series(series, fx, fx_day, source):
        # series chronologisch aufsteigend
        ordered = sorted(series, key=lambda x: x["date"])
        last14 = ordered[-14:]
        oil_history.clear()
        for e in last14:
            d = e["date"]
            label = d[8:10] + "." + d[5:7] if len(d) >= 10 else d
            oil_history.append({"t": label, "v": round(float(e["usd"]) / fx, 2)})
        save_oil_history()
        latest = ordered[-1]
        usd = float(latest["usd"])
        eur = usd / fx
        sess_iso = latest["date"]
        try:
            sess_label = datetime.strptime(sess_iso[:10], "%Y-%m-%d").strftime("%d.%m.%Y")
        except Exception:
            sess_label = sess_iso
        result["brent"] = round(eur, 2)
        result["usd"] = round(usd, 2)
        result["fx"] = fx
        result["fx_day"] = fx_day
        result["source"] = source
        result["session"] = "Sitzung " + sess_label
        result["color"] = _session_color(sess_iso)
        return result

    try:
        fx, fx_day = fetch_ecb_usd_per_eur()
        result["fx"] = fx
        result["fx_day"] = fx_day
        series = None
        source = None
        api_key = _read_eia_key()
        if api_key:
            try:
                eia_rows = fetch_eia_brent_daily(api_key, length=20)
                if len(eia_rows) >= 1:
                    series = eia_rows
                    source = "EIA+EZB"
            except Exception as e:
                print("Rohöl-Fehler: EIA:", e)
        if series is None:
            yahoo_rows = fetch_yahoo_brent_daily()
            if len(yahoo_rows) < 1:
                raise RuntimeError("Yahoo ohne Kurse")
            series = yahoo_rows
            source = "Yahoo+EZB"
        _apply_series(series, fx, fx_day, source)
        if result.get("brent") is not None:
            update_fail_counter("rohoel", True)
        else:
            update_fail_counter("rohoel", False)
    except Exception as e:
        print("Rohöl-Fehler:", e)
        update_fail_counter("rohoel", False)
        result["color"] = "#eab308"
        if oil_history:
            result["brent"] = oil_history[-1].get("v")
            if not result.get("session"):
                result["session"] = "Cache " + str(oil_history[-1].get("t") or "")
    return result
'''

src = must_replace(src, OLD_FETCH, NEW_FETCH, "fetch_rohoel")

# data_store: use session/color from fetch result
src = must_replace(
    src,
    '        "rohoel": {"value": fetch_rohoel(), "updated": now_str(), "color": get_freshness_color("rohoel")},\n',
    '        "rohoel": (lambda o: {"value": o, "updated": o.get("session") or now_str(), "color": o.get("color") or get_freshness_color("rohoel")})(fetch_rohoel()),\n',
    "data_store rohoel",
)

# Sources catalog
src = must_replace(
    src,
    '        ("rohoel", "Rohoel Brent", "EuroOilWatch"),\n',
    '        ("rohoel", "Rohoel Brent", "EIA RBRTE + EZB"),\n',
    "sources rohoel",
)

# Card HTML: subtitle + source
src = must_replace(
    src,
    '''  <div class="card full">
    <div class="title">🛢️ Rohöl</div>
    <div class="big">{{ rohoel.value.brent or '–' }} €</div>
    <div class="small">Brent · 14 Tage</div>
    <div class="chart-box"><canvas id="oilChart"></canvas></div>
    <div class="small" style="color:{{ rohoel.color }}">{{ rohoel.updated }}</div>
  </div>
''',
    '''  <div class="card full">
    <div class="title">🛢️ Rohöl</div>
    <div class="big">{{ rohoel.value.brent or '–' }} €</div>
    <div class="small">Brent Spot · 14 Tage{% if rohoel.value.source %} · {{ rohoel.value.source }}{% endif %}</div>
    <div class="chart-box"><canvas id="oilChart"></canvas></div>
    <div class="small" style="color:{{ rohoel.color }}">{{ rohoel.updated }}</div>
  </div>
''',
    "oil card html",
)

PATH.write_text(src, encoding="utf-8")
print("Patch geschrieben (rohoelEia).")
