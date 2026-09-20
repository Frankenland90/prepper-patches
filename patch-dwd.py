#!/usr/bin/env python3
"""Patch dashboard.py: DWD Warnungen + WBI (Punkt 2+3), Mesh Stil C Emoji. Idempotent via /* dwdV3 */."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

if "/* dwdV3 */" in src:
    print("DWD v3 ist schon drin — nichts geaendert.")
    raise SystemExit(0)


def must_replace(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx gefunden (erwartet 1). Datei unberuehrt." % (label, n))
    return text.replace(old, new, 1)


# --- 1) Konstanten + History-Deque ---
src = must_replace(
    src,
    'OUTAGE_HISTORY_FILE = "outage_history.json"\n',
    'OUTAGE_HISTORY_FILE = "outage_history.json"\n'
    'WBI_HISTORY_FILE = "wbi_history.json"\n'
    'DWD_MESH_STATUS_FILE = "/home/fmg/prepper-dashboard/dwd_mesh_status.json"\n'
    'DWD_WBI_STATUS_FILE = "/home/fmg/prepper-dashboard/dwd_wbi_status.json"\n',
    "WBI/DWD file constants",
)

src = must_replace(
    src,
    "outage_history = deque(maxlen=1344)\n",
    "outage_history = deque(maxlen=1344)\n"
    "wbi_history = deque(maxlen=90)\n",
    "wbi_history deque",
)

# --- 2) Fetcher + Mesh nach fetch_nina ---
FETCH_AND_MESH = r'''
# /* dwdV3 */
DWD_WARN_CELLS = {
    "809572137": "Kalchreuth",
    "809572457": "Kalchreuther Forst",
    "809562000": "Erlangen",
    "109572000": "Kreis ERH",
    "809574155": "Schnaittach",
}
DWD_ERLANGEN_ALT = "109562000"
DWD_WBI_URL = (  # /* wbiForecast */
    "https://opendata.dwd.de/climate_environment/CDC/derived_germany/"
    "fire_danger_index/woodland/forecast/recent/"
    "derived_germany_fire_danger_index_woodland_forecast_recent_3668_v2-3--0.csv.gz"
)
last_dwd_mesh = None
last_dwd_mesh_status = {"ok": None, "text": "", "at": None, "received": None, "cleared": None}
last_dwd_wbi_stage = None
last_dwd_wbi_mesh_status = {"ok": None, "text": "", "at": None, "stage": None}


def _dwd_level_color(level):
    try:
        lv = int(level or 0)
    except Exception:
        lv = 0
    if lv >= 4:
        return "#ef4444"
    if lv >= 3:
        return "#f97316"
    if lv >= 2:
        return "#eab308"
    if lv >= 1:
        return "#84cc16"
    return "#22c55e"


def _dwd_wbi_color(stage):
    try:
        n = int(stage)
    except Exception:
        return "#94a3b8"
    return {1: "#22c55e", 2: "#84cc16", 3: "#eab308", 4: "#f97316", 5: "#ef4444"}.get(n, "#94a3b8")


def _dwd_ms_to_str(ms):
    if ms is None:
        return None
    try:
        return datetime.fromtimestamp(int(ms) / 1000.0).strftime("%d.%m.%Y %H:%M")
    except Exception:
        return None


def load_wbi_history():
    if os.path.exists(WBI_HISTORY_FILE):
        try:
            with open(WBI_HISTORY_FILE, "r") as f:
                data = json.load(f)
                wbi_history.clear()
                for item in data.get("wbi", [])[-90:]:
                    wbi_history.append(item)
        except Exception:
            pass


def save_wbi_history():
    try:
        with open(WBI_HISTORY_FILE, "w") as f:
            json.dump({"wbi": list(wbi_history)}, f)
    except Exception as e:
        print("wbi history save:", e)


def load_dwd_mesh_status():
    global last_dwd_mesh_status, last_dwd_mesh, last_dwd_wbi_stage, last_dwd_wbi_mesh_status
    try:
        with open(DWD_MESH_STATUS_FILE) as f:
            d = json.load(f)
            last_dwd_mesh_status = d
            if d.get("text") and not d.get("cleared"):
                last_dwd_mesh = d.get("text")
    except Exception:
        pass
    try:
        with open(DWD_WBI_STATUS_FILE) as f:
            d = json.load(f)
            last_dwd_wbi_mesh_status = d
            if d.get("stage") is not None:
                last_dwd_wbi_stage = d.get("stage")
    except Exception:
        pass


def save_dwd_mesh_status(text, cleared=None):
    d = {
        "ok": True,
        "text": (text or "")[:300],
        "at": now_str(),
        "received": now_str(),
        "sent": now_str(),
        "cleared": cleared,
    }
    try:
        with open(DWD_MESH_STATUS_FILE, "w") as f:
            json.dump(d, f, ensure_ascii=False)
    except Exception as e:
        print("dwd mesh json:", e)


def save_dwd_wbi_status(stage, text=None):
    global last_dwd_wbi_mesh_status
    d = {
        "ok": True,
        "stage": stage,
        "text": (text or "")[:200],
        "at": now_str(),
    }
    last_dwd_wbi_mesh_status = d
    try:
        with open(DWD_WBI_STATUS_FILE, "w") as f:
            json.dump(d, f, ensure_ascii=False)
    except Exception as e:
        print("dwd wbi json:", e)


def fetch_dwd_warnungen():
    """DWD Warnungen JSONP fuer lokale Warnzellen. Fail -> leeres dict."""
    empty = {
        "items": [],
        "max_level": 0,
        "count": 0,
        "cells": list(DWD_WARN_CELLS.keys()),
    }
    try:
        r = requests.get(
            "https://www.dwd.de/DWD/warnungen/warnapp/json/warnings.json",
            timeout=12,
            headers={"User-Agent": "KaeswasserLage/1.0"},
        )
        if r.status_code != 200 or not r.text.strip():
            update_fail_counter("dwd_warn", False)
            print("DWD Warn: HTTP", r.status_code)
            return empty
        raw = r.text.strip()
        if raw.startswith("warnWetter.loadWarnings("):
            raw = raw[len("warnWetter.loadWarnings("):]
            if raw.endswith(");"):
                raw = raw[:-2]
            elif raw.endswith(")"):
                raw = raw[:-1]
        data = json.loads(raw)
        warnings = data.get("warnings") or {}
        items = []

        def collect_cell(cid, name):
            found = []
            for key in (str(cid), cid):
                arr = warnings.get(key) or warnings.get(str(key))
                if arr:
                    found = arr
                    break
            out = []
            for w in found if isinstance(found, list) else []:
                if not isinstance(w, dict):
                    continue
                try:
                    level = int(w.get("level") or 0)
                except Exception:
                    level = 0
                out.append({
                    "cell": str(cid),
                    "name": name,
                    "level": level,
                    "event": (w.get("event") or "").strip(),
                    "headline": (w.get("headline") or "").strip(),
                    "description": (w.get("description") or "").strip(),
                    "instruction": (w.get("instruction") or "").strip(),
                    "start": _dwd_ms_to_str(w.get("start")),
                    "end": _dwd_ms_to_str(w.get("end")),
                })
            return out

        for cid, name in DWD_WARN_CELLS.items():
            cell_items = collect_cell(cid, name)
            if not cell_items and cid == "809562000":
                cell_items = collect_cell(DWD_ERLANGEN_ALT, name)
                for it in cell_items:
                    it["cell"] = DWD_ERLANGEN_ALT
            items.extend(cell_items)

        items.sort(key=lambda x: int(x.get("level") or 0), reverse=True)
        max_level = max((int(x.get("level") or 0) for x in items), default=0)
        update_fail_counter("dwd_warn", True)
        return {
            "items": items,
            "max_level": max_level,
            "count": len(items),
            "cells": list(DWD_WARN_CELLS.keys()),
            "color": _dwd_level_color(max_level),
        }
    except Exception as e:
        update_fail_counter("dwd_warn", False)
        print("DWD Warn:", e)
        return empty


def fetch_dwd_wbi():
    """WBI Nürnberg (3668) aus DWD forecast/recent (wbi_0 = heute)."""
    result = {
        "station_id": "3668",
        "station_name": "Nürnberg",
        "distance_km": 8.2,
        "wbi": None,
        "date": None,
        "date_fmt": None,
        "termin": None,
        "forecast": [],
        "stale": True,
        "color": "#94a3b8",
    }
    try:
        import gzip as _gzip
        r = requests.get(DWD_WBI_URL, timeout=20, headers={"User-Agent": "KaeswasserLage/1.0"})
        if r.status_code != 200 or not r.content:
            update_fail_counter("dwd_wbi", False)
            print("DWD WBI: HTTP", r.status_code)
            return result
        text = _gzip.decompress(r.content).decode("utf-8", "replace")
        data_lines = []
        for ln in text.splitlines():
            ln = ln.strip()
            if not ln or ln.startswith("#") or ln.lower().startswith("stations"):
                continue
            data_lines.append(ln)
        if not data_lines:
            update_fail_counter("dwd_wbi", False)
            print("DWD WBI: keine Datenzeilen")
            return result
        last = data_lines[-1]
        parts = [p.strip() for p in last.split(";")]
        # forecast: StationsID;Termin;wbi_0;...;wbi_6
        # recomputed fallback: Stationsid;Datum;wbi
        if len(parts) < 3:
            update_fail_counter("dwd_wbi", False)
            return result
        sid = parts[0] or "3668"
        termin = parts[1]
        forecast = []
        wbi_v = None
        if len(parts) >= 9:
            for p in parts[2:9]:
                try:
                    forecast.append(int(float(p.replace(",", "."))))
                except Exception:
                    forecast.append(None)
            wbi_v = forecast[0]
        else:
            try:
                wbi_v = int(float(parts[2].replace(",", ".")))
            except Exception:
                wbi_v = None
            forecast = [wbi_v] if wbi_v is not None else []
        date_fmt = None
        date_key = None
        stale = True
        try:
            # "20260920 04:14" oder "20260821"
            dt = datetime.strptime(termin[:8], "%Y%m%d")
            date_fmt = dt.strftime("%d.%m.%Y")
            date_key = termin[:8]
            stale = dt.date() < (now().date() - timedelta(days=1))
        except Exception:
            date_fmt = termin
            date_key = termin[:8] if termin else None
            stale = True
        result.update({
            "station_id": sid,
            "station_name": "Nürnberg",
            "distance_km": 8.2,
            "wbi": wbi_v,
            "date": date_key,
            "date_fmt": date_fmt,
            "termin": termin,
            "forecast": forecast,
            "stale": stale,
            "color": _dwd_wbi_color(wbi_v) if wbi_v is not None else "#94a3b8",
        })
        if wbi_v is not None and date_fmt:
            t_short = date_fmt[:5] if len(date_fmt) >= 5 else date_fmt
            if not wbi_history or wbi_history[-1].get("t") != t_short or wbi_history[-1].get("v") != wbi_v:
                if wbi_history and wbi_history[-1].get("t") == t_short:
                    wbi_history[-1] = {"t": t_short, "v": wbi_v}
                else:
                    wbi_history.append({"t": t_short, "v": wbi_v})
                save_wbi_history()
        update_fail_counter("dwd_wbi", wbi_v is not None)
        return result
    except Exception as e:
        update_fail_counter("dwd_wbi", False)
        print("DWD WBI:", e)
        return result


def maybe_mesh_dwd(items):
    """Mesh 1: DWD-Warnungen analog NINA (Aenderung / Entwarnung)."""
    global last_dwd_mesh, last_dwd_mesh_status
    try:
        if items is None:
            return False
        if fail_counters.get("dwd_warn", 0) > 0:
            print("DWD: Fetch fehlgeschlagen – Mesh unverändert")
            return False
        parts = []
        for w in items or []:
            if not isinstance(w, dict):
                continue
            name = (w.get("name") or "").strip()
            ev = (w.get("event") or w.get("headline") or "").strip()
            line = ("%s %s" % (name, ev)).strip()
            if line:
                parts.append(line)
        key = " · ".join(parts)[:160] if parts else ""

        if not key:
            if not last_dwd_mesh:
                return False
            text = "✅ DWD Entwarnung – lokal keine Warnung"
            ok = send_meshtastic(text)
            ts = now_str()
            last_dwd_mesh_status = {
                "ok": ok,
                "text": text,
                "at": ts if ok else (last_dwd_mesh_status or {}).get("at"),
                "received": (last_dwd_mesh_status or {}).get("received"),
                "cleared": ts if ok else None,
                "sent": ts if ok else None,
            }
            if ok:
                last_dwd_mesh = None
                save_dwd_mesh_status(text, cleared=ts)
                print("DWD-Mesh Entwarnung OK")
            else:
                print("DWD-Mesh Entwarnung FAIL")
            return ok

        if key == last_dwd_mesh:
            return False

        text = ("🌪 DWD · " + key)[:200]
        ok = send_meshtastic(text)
        ts = now_str()
        last_dwd_mesh_status = {
            "ok": ok,
            "text": key,
            "at": ts if ok else None,
            "received": ts,
            "cleared": None,
            "sent": ts if ok else None,
        }
        if ok:
            last_dwd_mesh = key
            save_dwd_mesh_status(key, cleared=None)
            print("DWD-Mesh OK:", key[:80])
        else:
            print("DWD-Mesh FAIL:", key[:80])
        return ok
    except Exception as e:
        print("maybe_mesh_dwd:", e)
        return False


def maybe_mesh_dwd_wbi(wbi_dict):
    """Mesh sparsam: nur Schwellwert-Uebergaenge WBI >=4 bzw. Rueckgang <=2."""
    global last_dwd_wbi_stage
    try:
        if not isinstance(wbi_dict, dict):
            return False
        if wbi_dict.get("stale"):
            return False
        wbi = wbi_dict.get("wbi")
        if not isinstance(wbi, int):
            return False
        prev = last_dwd_wbi_stage
        if prev is None:
            last_dwd_wbi_stage = wbi
            save_dwd_wbi_status(wbi)
            return False
        send_text = None
        if prev < 4 and wbi >= 4:
            send_text = "🔥 DWD WBI Nürnberg: %s/5" % wbi
        elif prev >= 4 and wbi <= 2:
            send_text = "✅ DWD WBI Nürnberg: Stufe %s" % wbi
        last_dwd_wbi_stage = wbi
        if not send_text:
            save_dwd_wbi_status(wbi)
            return False
        ok = send_meshtastic(send_text[:200])
        if ok:
            save_dwd_wbi_status(wbi, text=send_text)
            print("DWD-WBI-Mesh OK:", send_text)
        else:
            print("DWD-WBI-Mesh FAIL:", send_text)
            # Stufe trotzdem fortschreiben, damit nicht gespamt wird? Spec: persist lightly on OK-ish.
            # Bei FAIL Stufe behalten fuer Retry beim naechsten Zyklus mit gleichem Schwellwert:
            last_dwd_wbi_stage = prev
        return ok
    except Exception as e:
        print("maybe_mesh_dwd_wbi:", e)
        return False


'''

src = must_replace(
    src,
    '    update_fail_counter("nina", True)\n    return warnings[:8]\n\n\ndef fetch_metalle():\n',
    '    update_fail_counter("nina", True)\n    return warnings[:8]\n'
    + FETCH_AND_MESH
    + "\ndef fetch_metalle():\n",
    "insert DWD fetch/mesh after fetch_nina",
)

# --- 3) build_source_status catalog ---
src = must_replace(
    src,
    '        ("nina", "NINA", "NINA"),\n',
    '        ("nina", "NINA", "NINA"),\n'
    '        ("dwd_warn", "DWD Warnungen", "DWD"),\n'
    '        ("dwd_wbi", "DWD WBI", "DWD / Nürnberg"),\n',
    "source catalog DWD",
)

# --- 4) calculate_lage light touch ---
src = must_replace(
    src,
    '    if nina: return "AUFFÄLLIG", "#eab308", "Warnungen vorhanden"\n',
    '    if nina: return "AUFFÄLLIG", "#eab308", "Warnungen vorhanden"\n'
    '    try:\n'
    '        _dw = (data.get("dwd_warn") or {}).get("value") or {}\n'
    '        if isinstance(_dw, dict) and int(_dw.get("max_level") or 0) >= 3:\n'
    '            return "AUFFÄLLIG", "#eab308", "DWD-Wetterwarnung Stufe %s" % _dw.get("max_level")\n'
    '    except Exception:\n'
    '        pass\n',
    "calculate_lage DWD",
)

# --- 5) update_all data_store keys ---
src = must_replace(
    src,
    '        "outage_history": list(outage_history),\n',
    '        "outage_history": list(outage_history),\n'
    '        "dwd_warn": {"value": fetch_dwd_warnungen(), "updated": now_str(), "color": get_freshness_color("dwd_warn")},\n'
    '        "dwd_wbi": {"value": fetch_dwd_wbi(), "updated": now_str(), "color": get_freshness_color("dwd_wbi")},\n'
    '        "wbi_history": list(wbi_history),\n',
    "update_all dwd keys",
)

src = must_replace(
    src,
    '    data_store["nina_mesh_status"] = last_nina_mesh_status\n'
    '    data_store["lage"] = {"text": text, "color": color, "reason": reason}',
    '    data_store["nina_mesh_status"] = last_nina_mesh_status\n'
    '    data_store["dwd_mesh_status"] = last_dwd_mesh_status\n'
    '    data_store["lage"] = {"text": text, "color": color, "reason": reason}',
    "update_all dwd_mesh_status",
)

src = must_replace(
    src,
    '        maybe_mesh_nina(data_store.get("nina", {}).get("value"))\n',
    '        maybe_mesh_nina(data_store.get("nina", {}).get("value"))\n'
    '        try:\n'
    '            _dwv = (data_store.get("dwd_warn") or {}).get("value") or {}\n'
    '            maybe_mesh_dwd(_dwv.get("items") if isinstance(_dwv, dict) else None)\n'
    '        except Exception as _de:\n'
    '            print("DWD-Mesh-Hook:", _de)\n'
    '        try:\n'
    '            maybe_mesh_dwd_wbi((data_store.get("dwd_wbi") or {}).get("value"))\n'
    '        except Exception as _we:\n'
    '            print("DWD-WBI-Mesh-Hook:", _we)\n',
    "mesh hooks DWD",
)

# --- 6) PAGE3 UI after Wetter card ---
UI_CARDS = r'''    <div class="small" style="color:{{ wetter.color }}">{{ wetter.updated }}</div>
  </div>
  <!-- dwdV3 -->
  <div class="card full">
    <div class="title">⚠️ DWD Warnungen</div>
    {% set dw = dwd_warn.value if dwd_warn is defined and dwd_warn.value else {} %}
    {% set ml = dw.get('max_level', 0) if dw is mapping else 0 %}
    <div class="big" style="color:{{ dw.get('color', '#22c55e') if dw is mapping else '#22c55e' }}">Stufe {{ ml if ml is not none else 0 }}</div>
    <div class="small" style="color:#94a3b8;margin-bottom:6px">Kalchreuth · Forst · Erlangen · ERH · Schnaittach · DWD</div>
    {% if dw is mapping and dw.get('items') %}
      <div style="margin-top:6px;font-size:0.82rem;line-height:1.45">
      {% for it in dw.get('items') %}
        <div style="padding:5px 0;border-bottom:1px solid #1e293b">
          <b>{{ it.name }}</b>
          <span style="color:{{ '#ef4444' if (it.level or 0) >= 4 else ('#f97316' if (it.level or 0) >= 3 else ('#eab308' if (it.level or 0) >= 2 else '#84cc16')) }}"> · St. {{ it.level }}</span>
          <div>{{ it.event or it.headline or '–' }}</div>
          {% if it.headline and it.event and it.headline != it.event %}<div class="small" style="color:#94a3b8">{{ it.headline }}</div>{% endif %}
          {% if it.start or it.end %}<div class="small" style="color:#64748b">{{ it.start or '–' }} – {{ it.end or '–' }}</div>{% endif %}
        </div>
      {% endfor %}
      </div>
    {% else %}
      <div class="small">Keine lokalen DWD-Warnungen</div>
    {% endif %}
    <div class="small" style="margin-top:6px;color:#64748b">Quelle: DWD</div>
    <div class="small" style="color:{{ dwd_warn.color if dwd_warn is defined else '#94a3b8' }}">{{ dwd_warn.updated if dwd_warn is defined else '' }}</div>
    {% if dwd_mesh_status is defined and dwd_mesh_status %}
      <div class="small" style="margin-top:4px;color:#64748b">
        Mesh · {% if dwd_mesh_status.cleared %}Entwarnung {{ dwd_mesh_status.cleared }}{% elif dwd_mesh_status.text %}{{ dwd_mesh_status.text[:80] }}{% else %}–{% endif %}
        {% if dwd_mesh_status.at %} · {{ dwd_mesh_status.at }}{% endif %}
      </div>
    {% endif %}
  </div>
  <div class="card">
    <div class="title">🔥 DWD WBI · Waldbrand</div>
    {% set wb = dwd_wbi.value if dwd_wbi is defined and dwd_wbi.value else {} %}
    {% if wb is mapping and wb.get('wbi') is not none %}
      <div class="big" style="color:{{ wb.get('color', '#e2e8f0') }}">Stufe {{ wb.wbi }}</div>
      {% if wb.get('stale') %}<div class="small" style="color:#eab308">Datenstand veraltet ({{ wb.get('date_fmt') or wb.get('date') or '–' }})</div>{% endif %}
      <div class="small" style="margin-top:4px">Station {{ wb.get('station_name') or 'Nürnberg' }} ({{ wb.get('station_id') or '3668' }}) · {{ wb.get('distance_km') or 8.2 }} km</div>
      <div class="small" style="color:#94a3b8">Datum {{ wb.get('date_fmt') or wb.get('date') or '–' }}{% if wb.get('termin') %} · {{ wb.get('termin') }}{% endif %}</div>
      {% if wb.get('forecast') and wb.forecast|length > 1 %}
      <div class="small" style="margin-top:4px;color:#94a3b8">Vorhersage:
        {% for v in wb.forecast %}{% if loop.index0 == 0 %}heute {{ v }}{% else %}+{{ loop.index0 }}:{{ v }}{% endif %}{% if not loop.last %} · {% endif %}{% endfor %}
      </div>
      {% endif %}
    {% else %}
      <div class="small">Keine WBI-Daten</div>
    {% endif %}
    {% if wbi_history is defined and wbi_history %}
      <div class="small" style="margin-top:6px;color:#64748b;word-break:break-word">
        Verlauf:
        {% for h in wbi_history[-14:] %}{{ h.t }}:{{ h.v }}{% if not loop.last %} · {% endif %}{% endfor %}
      </div>
    {% endif %}
    <div class="small" style="margin-top:6px;color:#64748b">Quelle: DWD WBI Forecast</div>
    <div class="small" style="color:{{ dwd_wbi.color if dwd_wbi is defined else '#94a3b8' }}">{{ dwd_wbi.updated if dwd_wbi is defined else '' }}</div>
  </div>
  <div class="card full" style="padding:10px;text-align:center">'''

src = must_replace(
    src,
    '''    <div class="small" style="color:{{ wetter.color }}">{{ wetter.updated }}</div>
  </div>
  <div class="card full" style="padding:10px;text-align:center">''',
    UI_CARDS,
    "PAGE3 DWD cards",
)

# --- 7) page3 route: expose dwd_mesh_status ---
src = must_replace(
    src,
    '    data_store["odl_mesh_status"] = last_odl_mesh_status\n'
    '    data_store["mesh_weather_status"] = {\n'
    '        "auto": last_mesh_weather_auto,\n'
    '        "manual": last_mesh_weather_manual,\n'
    '    }\n'
    '    return render_template_string(PAGE3, **data_store)\n',
    '    data_store["odl_mesh_status"] = last_odl_mesh_status\n'
    '    data_store["dwd_mesh_status"] = last_dwd_mesh_status\n'
    '    data_store["mesh_weather_status"] = {\n'
    '        "auto": last_mesh_weather_auto,\n'
    '        "manual": last_mesh_weather_manual,\n'
    '    }\n'
    '    return render_template_string(PAGE3, **data_store)\n',
    "page3 dwd_mesh_status",
)

# --- 8) Startup loads ---
src = must_replace(
    src,
    '    load_outage_history()\n',
    '    load_outage_history()\n'
    '    load_wbi_history()\n'
    '    load_dwd_mesh_status()\n',
    "startup load DWD",
)

PATH.write_text(src, encoding="utf-8")
print("OK: DWD v3 gepatcht ->", PATH)
