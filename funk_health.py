#!/usr/bin/env python3
"""Funk-Seite: Mesh-Status + Kanalauslastung Mesh1/Mesh2. /* chutilFunk */"""
from flask import render_template_string, jsonify
from pathlib import Path

try:
    import mesh_chutil
except Exception:
    mesh_chutil = None

PAGE = r"""<!DOCTYPE html>
<html lang="de"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Käswasser · Funk</title>
<style>
body{margin:0;font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;padding:12px}
.card{background:#1e293b;border-radius:12px;padding:14px;margin-bottom:12px;border:1px solid #334155}
.title{font-size:0.75rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.06em;margin-bottom:8px}
.nav{margin-bottom:12px;font-size:0.9rem;white-space:nowrap;overflow-x:auto}
.nav a{color:#93c5fd;margin-right:10px;text-decoration:none}
.small{font-size:0.8rem;color:#94a3b8;margin-top:8px}
.big{font-size:1.8rem;font-weight:700;margin:4px 0 8px}
.grid{display:grid;gap:12px}
@media(min-width:900px){.grid{grid-template-columns:1fr 1fr}}
.chart-wrap{height:160px}
</style></head><body>
<div class="nav">
  <a href="/">Lage</a> <a href="/energie">Energie</a> <a href="/lokale-energie">Lokale Energie</a>
  <a href="/speicher">Speicher</a> <a href="/umwelt">Umwelt</a> <a href="/luft">Luft</a>
  <a href="/pegel">Pegel</a> <a href="/adsb">ADSB</a>
  <a href="/mesh">Mesh 1</a> <a href="/mesh2">Mesh 2</a>
  <a href="/funk">Funk</a> <a href="/pi">System</a> <a href="/medizin">Medizin</a>
</div>

<div class="card">
<div class="title">Mesh-Status</div>
{% for m in items %}
<div style="margin:12px 0;padding-bottom:12px;border-bottom:1px solid #334155">
<div><b>{{ m.name }}</b> · <span style="color:{{ m.color }}">{{ m.label }}</span></div>
<div class="small">{{ m.host }}:4403</div>
<div>TCP: {{ "offen" if m.tcp else "zu" }}</div>
<div>Dienst: {% if m.svc_ok %}aktiv{% elif m.svc_ok is none %}–{% else %}aus{% endif %}</div>
<div>Stand: {{ m.at or "–" }}</div>
<div>CLOSE-WAIT: {{ m.cw if m.cw is defined else m.closewait }}</div>
</div>
{% endfor %}
<div class="small">Grün = läuft · Gelb = Port offen / Dienst aus · Rot = offline</div>
</div>

<div class="grid">
  <div class="card">
    <div class="title">Kanalauslastung · Mesh 1</div>
    <div class="big" style="color:{{ c1.color }}">{% if c1.ch is not none %}{{ c1.ch }} %{% else %}–{% endif %}</div>
    <div class="small">Air-TX {% if c1.tx is not none %}{{ c1.tx }} %{% else %}–{% endif %} · {{ c1.node or "" }} · {{ c1.at or "noch keine Samples" }}</div>
    <div class="chart-wrap"><canvas id="ch1"></canvas></div>
    <div class="small">24h · Telemetrie DeviceMetrics · 5–10 min</div>
  </div>
  <div class="card">
    <div class="title">Kanalauslastung · Mesh 2</div>
    <div class="big" style="color:{{ c2.color }}">{% if c2.ch is not none %}{{ c2.ch }} %{% else %}–{% endif %}</div>
    <div class="small">Air-TX {% if c2.tx is not none %}{{ c2.tx }} %{% else %}–{% endif %} · {{ c2.node or "" }} · {{ c2.at or "noch keine Samples" }}</div>
    <div class="chart-wrap"><canvas id="ch2"></canvas></div>
    <div class="small">24h · Telemetrie DeviceMetrics · 5–10 min</div>
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<script>
function mk(id, labels, ch, tx, color){
  const el=document.getElementById(id);
  if(!el || !labels || !labels.length) return;
  new Chart(el.getContext('2d'),{
    type:'line',
    data:{labels:labels,datasets:[
      {label:'Kanal %',data:ch,borderColor:color,backgroundColor:color+'22',borderWidth:2,pointRadius:0,fill:true,tension:0.25},
      {label:'Air-TX %',data:tx,borderColor:'#94a3b8',borderWidth:1.5,pointRadius:0,fill:false,tension:0.25,borderDash:[4,3]}
    ]},
    options:{responsive:true,maintainAspectRatio:false,animation:false,
      plugins:{legend:{labels:{color:'#94a3b8',boxWidth:10}}},
      scales:{
        x:{ticks:{color:'#64748b',maxTicksLimit:6},grid:{color:'#1e293b'}},
        y:{min:0,suggestedMax:40,ticks:{color:'#64748b'},grid:{color:'#334155'}}
      }}
  });
}
mk('ch1', {{ c1.hist_t|tojson }}, {{ c1.hist_ch|tojson }}, {{ c1.hist_tx|tojson }}, '#3b82f6');
mk('ch2', {{ c2.hist_t|tojson }}, {{ c2.hist_ch|tojson }}, {{ c2.hist_tx|tojson }}, '#a78bfa');
</script>
</body></html>
"""


def _ampel(ch):
    if ch is None:
        return "#94a3b8"
    if ch < 25:
        return "#22c55e"
    if ch < 40:
        return "#eab308"
    return "#ef4444"


def _card(path, hours=24):
    empty = {
        "ch": None, "tx": None, "node": "", "at": "", "color": "#94a3b8",
        "hist_t": [], "hist_ch": [], "hist_tx": [],
    }
    if mesh_chutil is None:
        return empty
    try:
        p = mesh_chutil.hist_payload(Path(path), hours=hours)
        cur = p.get("current") or {}
        ch = cur.get("ch_util")
        return {
            "ch": ch,
            "tx": cur.get("air_tx"),
            "node": cur.get("node") or "",
            "at": (cur.get("t") or p.get("at") or ""),
            "color": _ampel(ch),
            "hist_t": p.get("hist_t") or [],
            "hist_ch": p.get("hist_ch") or [],
            "hist_tx": p.get("hist_tx") or [],
        }
    except Exception:
        return empty


def register_funk(app):
    @app.route("/funk")
    def page_funk():
        from dashboard import fetch_mesh_status
        st = fetch_mesh_status() or {}
        items = [x for x in (st.get("m1"), st.get("m2")) if x]
        base = Path("/home/fmg/prepper-dashboard")
        c1 = _card(base / "mesh1_chutil.json")
        c2 = _card(base / "mesh2_chutil.json")
        return render_template_string(PAGE, items=items, c1=c1, c2=c2)

    @app.route("/api/funk/chutil")
    def api_funk_chutil():
        base = Path("/home/fmg/prepper-dashboard")
        return jsonify({
            "m1": _card(base / "mesh1_chutil.json"),
            "m2": _card(base / "mesh2_chutil.json"),
        })
