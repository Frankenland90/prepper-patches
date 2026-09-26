#!/usr/bin/env python3
"""Funk-Seite: Mesh-Status + Kanalauslastung Mesh1/Mesh2. /* chutilFunk */ # meshHangFunk"""
import json
from flask import render_template_string, jsonify
from pathlib import Path

try:
    import mesh_chutil
except Exception:
    mesh_chutil = None

try:
    import mesh_reply_watch
except Exception:
    mesh_reply_watch = None

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
.stats{display:grid;grid-template-columns:1fr 1fr;gap:4px 12px;font-size:0.8rem;margin:6px 0 4px;color:#cbd5e1}
.stats b{color:#e2e8f0;font-weight:600}
.hint{margin-top:8px;padding:8px 10px;border-radius:8px;font-size:0.8rem}
.hint.yellow{background:#422006;color:#fde68a;border:1px solid #a16207}
.hint.red{background:#450a0a;color:#fecaca;border:1px solid #b91c1c}
.kv{display:grid;grid-template-columns:140px 1fr;gap:4px 10px;margin-top:6px;font-size:0.9rem}
.kv .k{color:#94a3b8}
.ampel{font-weight:600}
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
<div><b>{{ m.name }}</b></div>
<div class="small">{{ m.host }}:4403</div>
<div class="kv">
  <div class="k">LAN</div>
  <div class="ampel" style="color:{{ m.lan_color }}">{{ m.lan_label }}</div>
  <div class="k">Funk</div>
  <div class="ampel" style="color:{{ m.funk_color }}">{{ m.funk_label }}</div>
  <div class="k">TCP</div><div><b>{{ "offen" if m.tcp else "zu" }}</b></div>
  <div class="k">Dienst</div>
  <div>{% if m.svc_ok %}aktiv{% elif m.svc_ok is none %}–{% else %}aus{% endif %}</div>
  <div class="k">Stand</div><div>{{ m.at or "–" }}</div>
  <div class="k">CLOSE-WAIT</div><div>{{ m.cw if m.cw is defined else m.closewait }}</div>
  <div class="k">Node-DB</div><div>{% if m.nodedb is not none %}{{ m.nodedb }}{% else %}–{% endif %}</div>
  <div class="k">lastHeard</div>
  <div>{% if m.heard_sec is not none %}{{ m.heard_sec }} s{% else %}–{% endif %}</div>
  <div class="k">Ping RX</div><div>{{ m.ping_rx or "–" }}</div>
  <div class="k">Ping TX</div><div>{{ m.ping_tx or "–" }}</div>
  {% if m.watch_hint %}
  <div class="k">Watchdog</div><div style="color:{{ m.watch_color or '#eab308' }}">{{ m.watch_hint }}</div>
  {% endif %}
</div>
</div>
{% endfor %}
<div class="small">
  <b>LAN</b> = Bridge/TCP/systemd (bisherige Ampel) ·
  <b>Funk</b> = Telemetrie + Ping-Reply ·
  <b>Stuck</b> = gleicher Telemetriewert zu lange ·
  <b>Stumm</b> = Ping empfangen, keine Antwort
</div>
</div>

<div class="grid">
  <div class="card">
    <div class="title">Kanalauslastung · Mesh 1</div>
    <div class="big" style="color:{{ c1.color }}">{% if c1.ch is not none %}{{ c1.ch }} %{% else %}–{% endif %}</div>
    <div class="small">Air-TX {% if c1.tx is not none %}{{ c1.tx }} %{% else %}–{% endif %} · {{ c1.node or "" }} · {{ c1.at or "noch keine Samples" }}</div>
    <div class="stats">
      <div>Mittel 24h <b>{% if c1.avg_24h is not none %}{{ c1.avg_24h }} %{% else %}–{% endif %}</b></div>
      <div>Peak 24h <b>{% if c1.peak_24h is not none %}{{ c1.peak_24h }} %{% else %}–{% endif %}</b></div>
      <div>Mittel 7d <b>{% if c1.avg_7d is not none %}{{ c1.avg_7d }} %{% else %}–{% endif %}</b></div>
      <div>Peak 7d <b>{% if c1.peak_7d is not none %}{{ c1.peak_7d }} %{% else %}–{% endif %}</b></div>
    </div>
    {% if c1.hint %}<div class="hint {{ c1.hint_level }}">{{ c1.hint }}</div>{% endif %}
    {% if c1.stuck_hint %}<div class="hint yellow">{{ c1.stuck_hint }}</div>{% endif %}
    <div class="chart-wrap"><canvas id="ch1"></canvas></div>
    <div class="small">24h · Telemetrie · Funk {{ c1.tele_state or "–" }}{% if c1.reply_state %} · Reply {{ c1.reply_state }}{% endif %}</div>
  </div>
  <div class="card">
    <div class="title">Kanalauslastung · Mesh 2</div>
    <div class="big" style="color:{{ c2.color }}">{% if c2.ch is not none %}{{ c2.ch }} %{% else %}–{% endif %}</div>
    <div class="small">Air-TX {% if c2.tx is not none %}{{ c2.tx }} %{% else %}–{% endif %} · {{ c2.node or "" }} · {{ c2.at or "noch keine Samples" }}</div>
    <div class="stats">
      <div>Mittel 24h <b>{% if c2.avg_24h is not none %}{{ c2.avg_24h }} %{% else %}–{% endif %}</b></div>
      <div>Peak 24h <b>{% if c2.peak_24h is not none %}{{ c2.peak_24h }} %{% else %}–{% endif %}</b></div>
      <div>Mittel 7d <b>{% if c2.avg_7d is not none %}{{ c2.avg_7d }} %{% else %}–{% endif %}</b></div>
      <div>Peak 7d <b>{% if c2.peak_7d is not none %}{{ c2.peak_7d }} %{% else %}–{% endif %}</b></div>
    </div>
    {% if c2.hint %}<div class="hint {{ c2.hint_level }}">{{ c2.hint }}</div>{% endif %}
    {% if c2.stuck_hint %}<div class="hint yellow">{{ c2.stuck_hint }}</div>{% endif %}
    <div class="chart-wrap"><canvas id="ch2"></canvas></div>
    <div class="small">24h · Telemetrie · Funk {{ c2.tele_state or "–" }}{% if c2.reply_state %} · Reply {{ c2.reply_state }}{% endif %}</div>
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
        "avg_24h": None, "peak_24h": None, "avg_7d": None, "peak_7d": None,
        "hint": None, "hint_level": "",
        "nodedb": None, "heard_sec": None,
        "stuck_hint": None, "tele_state": "none", "tele_color": "#94a3b8", "reply_state": None,
        "stuck": None,
    }
    if mesh_chutil is None:
        return empty
    try:
        p = mesh_chutil.hist_payload(Path(path), hours=hours)
        cur = p.get("current") or {}
        ch = cur.get("ch_util")
        streak = p.get("streak") or {}
        return {
            "ch": ch,
            "tx": cur.get("air_tx"),
            "node": cur.get("node") or "",
            "at": (cur.get("t") or p.get("at") or ""),
            "color": _ampel(ch),
            "hist_t": p.get("hist_t") or [],
            "hist_ch": p.get("hist_ch") or [],
            "hist_tx": p.get("hist_tx") or [],
            "avg_24h": p.get("avg_24h"),
            "peak_24h": p.get("peak_24h"),
            "avg_7d": p.get("avg_7d"),
            "peak_7d": p.get("peak_7d"),
            "hint": p.get("hint"),
            "hint_level": streak.get("level") or "",
            "nodedb": p.get("nodedb") if p.get("nodedb") is not None else cur.get("nodedb"),
            "heard_sec": p.get("heard_sec") if p.get("heard_sec") is not None else cur.get("heard_sec"),
            "stuck_hint": p.get("stuck_hint"),
            "stuck": p.get("stuck"),
            "tele_state": p.get("tele_state") or "none",
            "tele_color": p.get("tele_color") or "#94a3b8",
        }
    except Exception:
        return empty


def _funk_ampel(lan_color, lan_label, card, mesh_key):  # meshHangFunk
    """Kombiniert Telemetrie + Reply-Watch zu Funk-Status."""
    # offline if LAN red
    lan_l = (lan_label or "").lower()
    if lan_color == "#ef4444" or "offline" in lan_l or lan_l in ("rot", "down", "aus"):
        return "offline", "#ef4444"

    reply = None
    if mesh_reply_watch is not None:
        try:
            reply = mesh_reply_watch.status(mesh_key, stale_sec=3600)
        except Exception:
            reply = None

    tele_state = (card or {}).get("tele_state") or "none"
    stuck = (card or {}).get("stuck")
    stuck_sec = int((stuck or {}).get("sec") or 0) if stuck else 0

    # stumm if reply silent
    if reply and (reply.get("silent") or reply.get("state") == "stumm"):
        # yellow normally, red if also stuck long
        if stuck_sec >= 7200:
            return "stumm", "#ef4444"
        return "stumm", "#eab308"

    # stuck if tele stuck
    if tele_state == "stuck" or stuck:
        if stuck_sec >= 7200:
            return "stuck", "#ef4444"
        return "stuck", "#eab308"

    if tele_state == "stale":
        return "alt", "#eab308"

    if tele_state == "ok":
        return "ok", "#22c55e"

    if reply and reply.get("state") == "ok":
        return "ok", "#22c55e"

    if tele_state == "none" and (not reply or reply.get("state") == "unbekannt"):
        return "–", "#94a3b8"

    return "–", "#94a3b8"


def register_funk(app):
    @app.route("/funk")
    def page_funk():
        from dashboard import fetch_mesh_status
        st = fetch_mesh_status() or {}
        base = Path("/home/fmg/prepper-dashboard")
        c1 = _card(base / "mesh1_chutil.json")
        c2 = _card(base / "mesh2_chutil.json")
        items = []
        for key, card in (("m1", c1), ("m2", c2)):
            m = st.get(key)
            if not m:
                continue
            m = dict(m)
            if m.get("nodedb") is None:
                m["nodedb"] = card.get("nodedb")
            if m.get("heard_sec") is None:
                m["heard_sec"] = card.get("heard_sec")
            # LAN = bisherige Ampel
            m["lan_color"] = m.get("color") or "#94a3b8"
            m["lan_label"] = m.get("label") or "–"
            funk_label, funk_color = _funk_ampel(
                m["lan_color"], m["lan_label"], card, key
            )
            m["funk_label"] = funk_label
            m["funk_color"] = funk_color
            # Ping RX/TX ages + watchdog hint (meshHangFunk)
            m["ping_rx"] = "–"
            m["ping_tx"] = "–"
            if mesh_reply_watch is not None:
                try:
                    rs = mesh_reply_watch.status(key, stale_sec=3600) or {}
                    card["reply_state"] = rs.get("state") or "unbekannt"
                    def _age(sec):
                        if sec is None:
                            return "–"
                        sec = int(sec)
                        if sec < 60:
                            return f"{sec} s"
                        if sec < 3600:
                            return f"{sec // 60} min"
                        return f"{sec // 3600} h"
                    m["ping_rx"] = _age(rs.get("last_rx_age"))
                    m["ping_tx"] = _age(rs.get("last_tx_age"))
                except Exception:
                    pass
            m["watch_hint"] = None
            m["watch_color"] = "#eab308"
            try:
                wst = json.loads((base / "mesh_hang_status.json").read_text() or "{}")
                mesh_st = (wst.get("meshes") or {}).get(key) or {}
                act = mesh_st.get("action")
                if mesh_st.get("recommend_restart"):
                    m["watch_hint"] = "Restart empfohlen" + (f" ({act})" if act else "")
                    m["watch_color"] = "#ef4444"
                elif act and act not in ("ok", None, ""):
                    m["watch_hint"] = str(act)
                    m["watch_color"] = "#eab308"
                elif mesh_st.get("stuck"):
                    m["watch_hint"] = "Telemetrie stuck"
            except Exception:
                pass
            items.append(m)
        # reply_state on channel cards
        for card, key in ((c1, "m1"), (c2, "m2")):
            if mesh_reply_watch is not None and not card.get("reply_state"):
                try:
                    card["reply_state"] = (mesh_reply_watch.status(key) or {}).get("state")
                except Exception:
                    card["reply_state"] = None
        return render_template_string(PAGE, items=items, c1=c1, c2=c2)

    @app.route("/api/funk/chutil")
    def api_funk_chutil():
        base = Path("/home/fmg/prepper-dashboard")
        return jsonify({
            "m1": _card(base / "mesh1_chutil.json"),
            "m2": _card(base / "mesh2_chutil.json"),
        })

