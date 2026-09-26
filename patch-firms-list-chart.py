#!/usr/bin/env python3
"""FIRMS-Kachel: Hotspot-Liste (GPS+Zeit) + 14-Tage-Chart. Idempotent (# firmsList14)."""
from pathlib import Path
import shutil
import sys
from datetime import datetime

DASH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
LUFT = DASH.with_name("luft.py")
MARKER = "# firmsList14"

dash = DASH.read_text(encoding="utf-8")
if MARKER in dash and LUFT.exists() and MARKER in LUFT.read_text(encoding="utf-8"):
    print("already patched (firmsList14) — nichts geändert.")
    sys.exit(0)

if "Brände FIRMS" not in dash:
    raise SystemExit("STOP: FIRMS-Kachel fehlt in dashboard.py")
if not LUFT.exists():
    raise SystemExit("STOP: luft.py fehlt")

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
bak_d = DASH.with_name(f"dashboard.py.bak-firms14-{stamp}")
bak_l = LUFT.with_name(f"luft.py.bak-firms14-{stamp}")
shutil.copy2(DASH, bak_d)
shutil.copy2(LUFT, bak_l)
print(f"Backup: {bak_d}")
print(f"Backup: {bak_l}")


def must_replace(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"STOP {label}: Anker {n}x (erwartet 1). Backup: {bak_d}")
    return text.replace(old, new, 1)


# ---------- luft.py: format acq + keep coords ----------
luft = LUFT.read_text(encoding="utf-8")
if MARKER not in luft:
    OLD_SPOT = '''        spots.append({
            "lat": lat,
            "lon": lon,
            "confidence": row.get("confidence"),
            "acq": f"{row.get('acq_date', '')} {row.get('acq_time', '')}".strip(),
            "frp": row.get("frp"),
        })'''
    NEW_SPOT = '''        acq_date = str(row.get("acq_date") or "").strip()
        acq_time = str(row.get("acq_time") or "").strip().zfill(4) if row.get("acq_time") not in (None, "") else ""
        acq_raw = f"{acq_date} {acq_time}".strip()
        acq_fmt = acq_raw
        try:
            if len(acq_date) >= 10 and len(acq_time) >= 4:
                acq_fmt = (
                    f"{acq_date[8:10]}.{acq_date[5:7]}.{acq_date[0:4]} "
                    f"{acq_time[0:2]}:{acq_time[2:4]}"
                )
        except Exception:
            acq_fmt = acq_raw
        spots.append({
            "lat": lat,
            "lon": lon,
            "confidence": row.get("confidence"),
            "acq": acq_raw,
            "acq_fmt": acq_fmt,  # firmsList14
            "gps": f"{lat:.5f}, {lon:.5f}",  # firmsListCopy
            "frp": row.get("frp"),
        })'''
    if OLD_SPOT not in luft:
        raise SystemExit("STOP: spots.append-Anker in luft.py fehlt")
    luft = luft.replace(OLD_SPOT, NEW_SPOT, 1)
    # bump list size slightly for UI list
    if '"hotspots": spots[:12],' in luft:
        luft = luft.replace('"hotspots": spots[:12],', '"hotspots": spots[:20],  # firmsList14', 1)
    LUFT.write_text(luft, encoding="utf-8")
    print("OK luft.py acq_fmt")
else:
    print("luft.py already has firmsList14")

# ---------- dashboard.py ----------
if MARKER in dash:
    print("dashboard already firmsList14")
else:
    # 1) history deque near diesel_history
    if "firms_history" not in dash:
        # prefer after diesel_history line
        import re
        m = re.search(r"^diesel_history = deque\(maxlen=\d+\)\s*$", dash, re.M)
        if not m:
            raise SystemExit("STOP: diesel_history-Anker fehlt")
        insert = m.group(0) + "\nfirms_history = deque(maxlen=1344)  # 14 Tage à ~15 Min # firmsList14\n"
        dash = dash[: m.start()] + insert + dash[m.end() :]
        # FUEL_HISTORY_FILE sibling
        if 'FUEL_HISTORY_FILE = "fuel_history.json"' in dash:
            dash = dash.replace(
                'FUEL_HISTORY_FILE = "fuel_history.json"',
                'FUEL_HISTORY_FILE = "fuel_history.json"\nFIRMS_HISTORY_FILE = "firms_history.json"  # firmsList14',
                1,
            )
        else:
            raise SystemExit("STOP: FUEL_HISTORY_FILE fehlt")

    # 2) load/save helpers after save_fuel_history
    if "def load_firms_history" not in dash:
        OLD_SAVE = '''def save_fuel_history():
    with open(FUEL_HISTORY_FILE, "w") as f:
        json.dump({"diesel": list(diesel_history)}, f)'''
        NEW_SAVE = '''def save_fuel_history():
    with open(FUEL_HISTORY_FILE, "w") as f:
        json.dump({"diesel": list(diesel_history)}, f)


def load_firms_history():
    """FIRMS Hotspot-Count 14 Tage. # firmsList14"""
    if os.path.exists(FIRMS_HISTORY_FILE):
        try:
            with open(FIRMS_HISTORY_FILE, "r") as f:
                data = json.load(f)
                firms_history.clear()
                for item in data.get("firms", [])[-1344:]:
                    firms_history.append(item)
        except Exception:
            pass


def save_firms_history():
    with open(FIRMS_HISTORY_FILE, "w") as f:
        json.dump({"firms": list(firms_history)}, f)


def record_firms_history(n_hotspots):
    """Einen Punkt anhängen (Throttle ~10 Min). # firmsList14"""
    try:
        n = int(n_hotspots or 0)
    except Exception:
        n = 0
    t = now().strftime("%d.%m %H:%M")
    if firms_history:
        last = firms_history[-1]
        if last.get("t") == t and last.get("v") == n:
            return
    firms_history.append({"t": t, "v": n})
    try:
        save_firms_history()
    except Exception as e:
        print("firms history save:", e)'''
        if OLD_SAVE not in dash:
            raise SystemExit("STOP: save_fuel_history-Anker fehlt")
        dash = must_replace(dash, OLD_SAVE, NEW_SAVE, "load/save firms_history")

    # 3) record in maybe_mesh_luft after n is known
    OLD_N = '''    n = int(data.get("n_hotspots") or 0)
    pm = (data.get("sensors") or {}).get("pm25")'''
    NEW_N = '''    n = int(data.get("n_hotspots") or 0)
    try:
        record_firms_history(n)  # firmsList14
    except Exception as _fh:
        print("firms history:", _fh)
    pm = (data.get("sensors") or {}).get("pm25")'''
    if OLD_N in dash and "record_firms_history(n)" not in dash:
        dash = must_replace(dash, OLD_N, NEW_N, "record in maybe_mesh_luft")

    # 4) data_store firms_history if diesel_history present
    if '"firms_history"' not in dash and '"diesel_history": list(diesel_history)' in dash:
        dash = dash.replace(
            '"diesel_history": list(diesel_history),',
            '"diesel_history": list(diesel_history),\n        "firms_history": list(firms_history),  # firmsList14',
            1,
        )

    # 5) load on startup
    if "load_firms_history()" not in dash:
        if "    load_fuel_history()\n    load_oil_history()" in dash:
            dash = dash.replace(
                "    load_fuel_history()\n    load_oil_history()",
                "    load_fuel_history()\n    load_firms_history()  # firmsList14\n    load_oil_history()",
                1,
            )
        elif "    load_fuel_history()" in dash:
            dash = dash.replace(
                "    load_fuel_history()",
                "    load_fuel_history()\n    load_firms_history()  # firmsList14",
                1,
            )

    # 6) PAGE_LUFT: chart.js + css + FIRMS card
    OLD_HEAD = '''PAGE_LUFT = """<!DOCTYPE html>
<html lang="de"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Käswasser · Luft</title>
<style>
body{margin:0;font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;padding:12px}'''
    NEW_HEAD = '''PAGE_LUFT = """<!DOCTYPE html>
<html lang="de"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Käswasser · Luft</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
body{margin:0;font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;padding:12px}
.chart-box{height:120px;margin-top:8px} /* firmsList14 */'''
    if "firmsList14" not in dash[dash.find("PAGE_LUFT"):dash.find("PAGE_LUFT")+500]:
        if OLD_HEAD not in dash:
            raise SystemExit("STOP: PAGE_LUFT head-Anker fehlt")
        dash = must_replace(dash, OLD_HEAD, NEW_HEAD, "PAGE_LUFT head")

    OLD_TILE = '''<div class="card"><div class="title">Brände FIRMS</div>
<div class="small">{{ lv.updated if lv else "" }}</div>

{% if lv and lv.n_hotspots %}
<div class="big">{{ lv.n_hotspots }}</div>
{% if lv.nearest %}
<div class="row"><span>Nächster</span><b>{{ lv.nearest.nearest }} · {{ lv.nearest.nearest_km }} km</b></div>
{% endif %}
{% else %}
<div class="big" style="color:#22c55e">keine</div>
<div class="small">Überwacht: 10,75–11,75°O · 49,25–49,87°N<br>~35 km um Kalchreuth / Schnaittach (Nürnberg, Erlangen, Lauf, Höchstadt)</div>
{% endif %}
<div class="small">NASA FIRMS VIIRS 24h · ohne low-confidence</div></div>'''

    NEW_TILE = '''<div class="card"><div class="title">Brände FIRMS</div>
<div class="small">{{ lv.updated if lv else "" }}</div>

{% if lv and lv.n_hotspots %}
<div class="big">{{ lv.n_hotspots }}</div>
{% if lv.nearest %}
<div class="row"><span>Nächster</span><b>{{ lv.nearest.nearest }} · {{ lv.nearest.nearest_km }} km</b></div>
{% endif %}
<div class="small" style="margin-top:8px">Hotspots · tippen = kopieren</div>
{% for h in (lv.hotspots or []) %}
<div class="firms-line" style="font-size:0.82rem;line-height:1.45;padding:6px 0;border-bottom:1px solid #334155;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;user-select:all;-webkit-user-select:all;word-break:break-all">{{ h.acq_fmt or h.acq or '–' }} · {{ h.gps or '–' }}{% if h.nearest %} · {{ h.nearest }} {{ h.nearest_km }} km{% endif %}</div>
{% endfor %}
{% else %}
<div class="big" style="color:#22c55e">keine</div>
<div class="small">Überwacht: 10,75–11,75°O · 49,25–49,87°N<br>~35 km um Kalchreuth / Schnaittach (Nürnberg, Erlangen, Lauf, Höchstadt)</div>
{% endif %}
<div class="small" style="margin-top:8px">Hotspots · 14 Tage</div>
<div class="chart-box"><canvas id="firmsChart"></canvas></div>
<div class="small">NASA FIRMS VIIRS 24h · ohne low-confidence</div></div>
<script>/* firmsList14 */
const firmsHist = {{ firms_history | tojson }};
(function(){
  const canvas = document.getElementById('firmsChart');
  if (!canvas || typeof Chart === 'undefined') return;
  const vals = (firmsHist||[]).map(x=>x.v).filter(v=>v!=null);
  const dMin = 0;
  const dMax = vals.length ? Math.max(1, Math.max(...vals)) : 1;
  new Chart(canvas.getContext('2d'), {
    type: 'line',
    data: { labels: (firmsHist||[]).map(x=>x.t), datasets: [{ data: (firmsHist||[]).map(x=>x.v), borderColor: '#ef4444', backgroundColor: '#ef444422', borderWidth: 2, pointRadius: 0, fill: true, tension: 0.3 }] },
    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } },
      scales: {
        x: { display: true, ticks: { color: '#64748b', font: { size: 8 }, maxRotation: 0, maxTicksLimit: 5 }, grid: { display: false } },
        y: { display: true, min: dMin, max: dMax, ticks: { color: '#64748b', font: { size: 8 }, stepSize: 1 }, grid: { color: '#1e293b' } }
      }
    }
  });
})();
</script>'''

    if OLD_TILE not in dash:
        raise SystemExit("STOP: FIRMS-Tile-Anker fehlt (Whitespace?)")
    dash = must_replace(dash, OLD_TILE, NEW_TILE, "FIRMS tile")

    # 7) page_luft passes firms_history
    OLD_CTX = '''    ctx["last_luft_mesh_auto"] = last_luft_mesh_auto
    ctx["last_luft_mesh_manual"] = last_luft_mesh_manual
    return render_template_string(PAGE_LUFT, **ctx)'''
    NEW_CTX = '''    ctx["last_luft_mesh_auto"] = last_luft_mesh_auto
    ctx["last_luft_mesh_manual"] = last_luft_mesh_manual
    ctx["firms_history"] = list(firms_history)  # firmsList14
    try:
        if val and isinstance(val, dict):
            record_firms_history(val.get("n_hotspots") or 0)
            ctx["firms_history"] = list(firms_history)
    except Exception:
        pass
    return render_template_string(PAGE_LUFT, **ctx)'''
    if "ctx[\"firms_history\"]" not in dash:
        dash = must_replace(dash, OLD_CTX, NEW_CTX, "page_luft firms_history")

    DASH.write_text(dash, encoding="utf-8")
    print("OK dashboard.py firmsList14")

print("OK patched firmsList14")
print("  marker dashboard:", DASH.read_text(encoding="utf-8").count(MARKER))
print("  marker luft:", LUFT.read_text(encoding="utf-8").count(MARKER))
