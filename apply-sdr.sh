#!/bin/bash
set -euo pipefail
# sdrFunk: SDR-Planer prepper-sdr (rtl_433 433,92 MHz + APRS 144,800 MHz im Wechsel, rtl_tcp Port 1234 auf Knopfdruck),
# Seiten /funk433 + /aprs, SDR-Kachel auf der Lage-Seite, SDR-Zeile in Datenquellen (/pi). Nur Empfang - sendet nichts (kein Funk, kein Mesh).
# Nur bei dashboard.py sha16 265bbe975962fb0f. Neustart nur prepper-dashboard + neuer Dienst prepper-sdr.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdr-apply
UNIT_DIR="${SDR_UNIT_DIR:-/etc/systemd/system}"
MODPROBE_DIR="${SDR_MODPROBE_DIR:-/etc/modprobe.d}"
UNIT="prepper-sdr.service"
RUN_USER="$(id -un)"
TCP_PORT=1234
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sdrFunk apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}), Benutzer $RUN_USER ==="
EXPECT_PATCH="d46f62451041985d638ca1aeb28d88bd39873146508c7291d20566b8245f0105"
EXPECT_MOD="6a2956f5d2f77f154cb4c135d70468c1c91b9388a798c5a049ebfb3b577d3549"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-sdr.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""sdrFunk: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== sdrFunk:"
EXPECT = "265bbe975962fb0f"
NEED = ["# ===== speedTile:", "# ===== speedTest:", "# ===== piPolish2:", "# ===== sourceWatch:", "app = Flask("]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== sdrFunk: SDR-Planer (rtl_433 433 MHz, APRS 144,800 MHz, rtl_tcp auf Abruf) - Seiten /funk433 + /aprs, Lage-Kachel, /pi-Zeile; nur Empfang, sendet nichts =====
# Der Dienst prepper-sdr (prepper_sdr.py) besitzt den Stick und schreibt sdr_status.json, funk433_state.json, aprs_state.json.
# Das Dashboard liest nur und setzt die Betriebsart (sdr_mode.json) ueber prepper_sdr.set_mode. Kein BOS/POCSAG.
import os as _sdr_os
import json as _sdr_json
import time as _sdr_time
import html as _sdr_html

_SDR_BASE = _sdr_os.path.dirname(_sdr_os.path.abspath(__file__))
_SDR_NAMES = {"433": "433 MHz Sensoren", "aprs": "APRS 144,800", "tcp": "Netz (rtl_tcp)", "idle": "Pause", "nostick": "kein Stick",
              "fehler": "Fehler", "off": "aus", "auto": "Automatik"}
try:
    import prepper_sdr as _sdr_mod
except Exception as _sdr_e:
    _sdr_mod = None
    print("sdrFunk Modul:", _sdr_e, flush=True)


def _sdr_load(name, default):
    if _sdr_mod is None:
        return default
    v = _sdr_mod.load_json(_sdr_os.path.join(_SDR_BASE, name), default)
    return v if v is not None else default


def _sdr_status():
    st = _sdr_load("sdr_status.json", {}) or {}
    now = _sdr_time.time()
    age = now - (st.get("t") or 0) if st else None
    d = {"ok": _sdr_mod is not None, "module": _sdr_mod is not None, "status": st, "age_s": int(age) if age is not None else None,
         "service": "läuft" if (age is not None and age < 150) else ("veraltet" if st else "nie gestartet"),
         "mode": (_sdr_mod.get_mode(_SDR_BASE) if _sdr_mod else {"mode": "auto"}), "now": int(now)}
    s433 = _sdr_load("funk433_state.json", {}) or {}
    sa = _sdr_load("aprs_state.json", {}) or {}
    sens = list((s433.get("sensors") or {}).values())
    stas = list((sa.get("stations") or {}).values())
    d["n433_1h"] = sum(1 for x in sens if now - (x.get("t") or 0) < 3600)
    d["n433"] = len(sens)
    d["naprs_1h"] = sum(1 for x in stas if now - (x.get("t") or 0) < 3600)
    d["naprs"] = len(stas)
    d["last_433_t"] = s433.get("last_t")
    d["last_aprs_t"] = sa.get("last_t")
    near = [x for x in stas if isinstance(x.get("dist_km"), (int, float)) and now - (x.get("t") or 0) < 86400]
    d["aprs_far"] = max(near, key=lambda x: x["dist_km"])["call"] if near else None
    d["aprs_far_km"] = max(x["dist_km"] for x in near) if near else None
    temps = sorted([x for x in sens if isinstance(x.get("temperature_C"), (int, float)) and now - (x.get("t") or 0) < 7200],
                   key=lambda x: -(x.get("t") or 0))[:3]
    d["temps"] = [{"model": x.get("model"), "id": x.get("id"), "ch": x.get("channel"), "c": x.get("temperature_C"), "h": x.get("humidity")} for x in temps]
    msgs = sa.get("msgs") or []
    d["last_msg"] = msgs[-1] if msgs else None
    a = st.get("active")
    d["state"] = ("ok" if a in ("433", "aprs", "tcp") and d["service"] == "läuft" else
                  ("alt" if a in ("idle", "nostick") and d["service"] == "läuft" else "ausgefallen"))
    return d


def _sdr_api_status():
    from flask import jsonify
    return jsonify(_sdr_status())


def _sdr_api_mode():
    from flask import jsonify, request
    if _sdr_mod is None:
        return jsonify({"ok": False, "error": "Modul fehlt"}), 503
    j = request.get_json(silent=True) or {}
    mode = j.get("mode") or request.form.get("mode") or request.args.get("mode")
    try:
        mins = float(j.get("minutes") or request.form.get("minutes") or request.args.get("minutes") or 0) or None
    except Exception:
        mins = None
    if mode not in _sdr_mod.MODES:
        return jsonify({"ok": False, "error": "mode muss auto/433/aprs/tcp/off sein"}), 400
    m = _sdr_mod.set_mode(_SDR_BASE, mode, mins)
    print("sdrFunk Betriebsart:", m, flush=True)
    return jsonify({"ok": True, "mode": m})


def _sdr_433_data():
    s = _sdr_load("funk433_state.json", {}) or {}
    rows = sorted((s.get("sensors") or {}).values(), key=lambda x: -(x.get("t") or 0))
    return {"ok": True, "now": int(_sdr_time.time()), "n": s.get("n", 0), "last_t": s.get("last_t"), "sensors": rows}


def _sdr_aprs_data():
    s = _sdr_load("aprs_state.json", {}) or {}
    rows = sorted((s.get("stations") or {}).values(), key=lambda x: -(x.get("t") or 0))
    for r in rows:
        r.pop("raw", None)
    home = s.get("home") or ((_sdr_mod.home_from_config(_SDR_BASE)) if _sdr_mod else None)
    return {"ok": True, "now": int(_sdr_time.time()), "n": s.get("n", 0), "last_t": s.get("last_t"), "home": home,
            "stations": rows, "wx": [r for r in rows if r.get("wx")], "msgs": list(reversed((s.get("msgs") or [])[-60:]))}


def _sdr_api_433():
    from flask import jsonify
    return jsonify(_sdr_433_data())


def _sdr_api_aprs():
    from flask import jsonify
    return jsonify(_sdr_aprs_data())


_SDR_CSS = """
.sdr-wrap{max-width:1100px;margin:0 auto}
.sdr-wrap .card{background:var(--card,#111827);border:1px solid #1f2937;border-radius:12px;padding:12px;margin-bottom:10px}
.sdr-wrap .title{font-size:.72rem;letter-spacing:.08em;color:#94a3b8;text-transform:uppercase;margin-bottom:6px}
.sdr-wrap .sub{font-size:.75rem;color:#94a3b8}
.sdr-wrap table{width:100%;border-collapse:collapse;font-size:.8rem;font-variant-numeric:tabular-nums}
.sdr-wrap th{color:#64748b;font-weight:500;text-align:left;padding:3px 4px;border-bottom:1px solid #334155;white-space:nowrap;font-size:.7rem}
.sdr-wrap td{padding:4px;border-bottom:1px solid #1f2937;white-space:nowrap}
.sdr-wrap td.w{white-space:normal;max-width:260px;overflow:hidden;text-overflow:ellipsis}
.sdr-wrap .scroll{overflow-x:auto;-webkit-overflow-scrolling:touch}
.sdr-wrap .dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;vertical-align:middle}
.sdr-wrap .big{font-size:1.35rem;font-weight:700}
.sdr-wrap .btns{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.sdr-btn{background:#1e293b;color:#cbd5e1;border:1px solid #334155;border-radius:8px;padding:5px 9px;font-size:.75rem;cursor:pointer}
.sdr-btn.on{background:#1d4ed8;color:#fff;border-color:#3b82f6}
.sdr-wrap .sdrsub a{color:#93c5fd;text-decoration:none;margin-right:12px;font-size:.8rem}
.sdr-wrap .kv{display:flex;justify-content:space-between;font-size:.8rem;padding:2px 0}
.sdr-wrap .kv span:first-child{color:#94a3b8}
"""

_SDR_JS_COMMON = """
function sdrEl(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined&&x!==null)e.textContent=x;return e;}
function sdrN(x,d){return (x===null||x===undefined||x==='')?'–':(typeof x==='number'?x.toFixed(d===undefined?1:d).replace('.',','):String(x));}
function sdrAgo(t,now){if(!t)return '–';var a=Math.max(0,(now||Date.now()/1000)-t);return a<90?Math.round(a)+' s':(a<5400?Math.round(a/60)+' min':(a<172800?Math.round(a/3600)+' h':Math.round(a/86400)+' T'));}
function sdrCol(t,now,lim){if(!t)return '#64748b';var a=(now||Date.now()/1000)-t;return a<lim?'#22c55e':(a<lim*6?'#eab308':'#64748b');}
function sdrHM(t){if(!t)return '–';var d=new Date(t*1000);function p(x){return (x<10?'0':'')+x;}return p(d.getDate())+'.'+p(d.getMonth()+1)+'. '+p(d.getHours())+':'+p(d.getMinutes());}
function sdrRow(tb,cells){var tr=sdrEl('tr');cells.forEach(function(c){var td=sdrEl('td',c&&c.cls?c.cls:'');if(c&&c.node){td.appendChild(c.node);}else{td.textContent=(c&&c.t!==undefined)?c.t:c;}if(c&&c.col)td.style.color=c.col;if(c&&c.tip)td.title=c.tip;tr.appendChild(td);});tb.appendChild(tr);}
var SDRN={'433':'433 MHz','aprs':'APRS','tcp':'Netz rtl_tcp','idle':'Pause','nostick':'kein Stick','fehler':'Fehler','off':'aus','auto':'Automatik'};
function sdrMode(m,mins,cb){fetch('/api/sdr/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:m,minutes:mins||0})}).then(function(r){return r.json();}).then(function(){setTimeout(cb,2500);}).catch(function(){});}
function sdrBtns(box,d,cb){var w=sdrEl('div','btns');var cur=(d.mode||{}).mode;
[['auto','Automatik'],['433','nur 433'],['aprs','nur APRS'],['tcp','Netz 60 min'],['off','aus']].forEach(function(b){var x=sdrEl('button','sdr-btn'+(cur===b[0]?' on':''),b[1]);x.type='button';
x.onclick=function(){x.textContent='…';sdrMode(b[0],b[0]==='tcp'?60:0,cb);};w.appendChild(x);});box.appendChild(w);}
function sdrLine(d){var s=d.status||{},a=s.active,now=d.now;var col=d.state==='ok'?'#22c55e':(d.state==='alt'?'#eab308':'#ef4444');
var t=(SDRN[a]||a||'–');if(d.service!=='läuft')t='Dienst '+d.service;
var x=t+' · Modus '+(SDRN[(d.mode||{}).mode]||'?');if(s.next_switch&&(d.mode||{}).mode==='auto')x+=' · Wechsel in '+sdrAgo(now,s.next_switch);
if(a==='tcp')x+=' · Port '+((s.tcp||{}).port||1234)+((d.mode||{}).until?' bis '+sdrHM((d.mode||{}).until).slice(8):'');
return {col:col,txt:x};}
"""


def _sdr_page(title, body_js, data):
    nav = globals().get("NAV_UNIFY") or ""
    base_css = globals().get("BASE_STYLE") or ""
    if not isinstance(base_css, str) or "{{" in base_css or "{%" in base_css:
        base_css = ""
    data_s = _sdr_json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    return ('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">'
            '<title>%s</title><style>%s%s</style></head><body>%s'
            '<div class="sdr-wrap"><div class="header"><div class="brand">Käswasser Lage Monitor</div>%s</div>'
            '<div class="sdrsub" style="margin:4px 0 10px"><a href="/funk433">📡 433 MHz</a><a href="/aprs">📻 APRS</a><a href="/">↩ Lage</a><a href="/pi">System</a></div>'
            '<div id="sdrHead" class="card"></div><div id="sdrMain"></div></div>'
            '<script type="application/json" id="sdrData">%s</script>'
            '<script>%s%s</script></body></html>') % (
        _sdr_html.escape(title), base_css, _SDR_CSS, nav, _sdr_html.escape(title), data_s, _SDR_JS_COMMON, body_js)


_SDR_HEAD_JS = """
function head(st){var h=document.getElementById('sdrHead');if(!h)return;h.textContent='';h.appendChild(sdrEl('div','title','SDR-Empfänger (Nooelec NESDR SMArt v5)'));
var l=sdrLine(st);var r=sdrEl('div','kv');var dot=sdrEl('span','dot');dot.style.background=l.col;var v=sdrEl('span');v.appendChild(dot);v.appendChild(document.createTextNode(l.txt));
r.appendChild(sdrEl('span','','Status'));r.appendChild(v);h.appendChild(r);
var s=st.status||{};if(s.err)h.appendChild(sdrEl('div','sub','letzter Fehler '+sdrHM(s.err_t)+': '+s.err));
if((s.stick||[]).length){var k=s.stick[0];h.appendChild(sdrEl('div','sub','Stick '+(k.product||k.usb)+(k.serial?' · SN '+k.serial:'')+' · Planer seit '+sdrHM(s.started)));}
sdrBtns(h,st,refresh);
if(s.active==='tcp'){h.appendChild(sdrEl('div','sub','rtl_tcp: in SDR++/SDR#/GQRX Quelle rtl_tcp, Host '+location.hostname+', Port '+((s.tcp||{}).port||1234)+' · Decoder pausieren solange.'));}}
"""

_SDR_433_JS = _SDR_HEAD_JS + """
function render(d,st){head(st);var m=document.getElementById('sdrMain');m.textContent='';var now=d.now;
var c=sdrEl('div','card');c.appendChild(sdrEl('div','title','433-MHz-Sensoren ('+d.sensors.length+') · '+d.n+' Telegramme · letztes '+sdrAgo(d.last_t,now)));
if(!d.sensors.length){c.appendChild(sdrEl('div','sub','Noch keine Sensoren empfangen. rtl_433 läuft im Wechsel mit APRS (je 5 min).'));m.appendChild(c);return;}
var sc=sdrEl('div','scroll');var tb=sdrEl('table');var hd=sdrEl('tr');
['','Modell','ID','Kanal','Temp °C','Feuchte %','Wind km/h','Böe','Richtung','Regen mm','Batt.','zuletzt','RSSI dB','SNR','Anz.'].forEach(function(x){hd.appendChild(sdrEl('th','',x));});tb.appendChild(hd);
d.sensors.forEach(function(s){var dot=sdrEl('span','dot');dot.style.background=sdrCol(s.t,now,600);
sdrRow(tb,[{node:dot},{t:s.model,cls:'w'},s.id===undefined?'–':String(s.id),s.channel===undefined?'–':String(s.channel),sdrN(s.temperature_C),sdrN(s.humidity,0),
sdrN(s.wind_avg_km_h),sdrN(s.wind_max_km_h),s.wind_dir_deg===undefined?'–':s.wind_dir_deg+'°',sdrN(s.rain_mm),
s.battery_ok===undefined?'–':(s.battery_ok?'ok':'⚠ leer'),{t:sdrAgo(s.t,now),tip:sdrHM(s.t)},sdrN(s.rssi),sdrN(s.snr),String(s.n||'')]);});
sc.appendChild(tb);c.appendChild(sc);c.appendChild(sdrEl('div','sub','Grün < 10 min · Gelb < 1 h · Grau älter. Nur ISM-Sensoren (Wetter, Thermometer); fremde Sensoren der Nachbarn erscheinen ebenfalls. Liste 14 Tage.'));m.appendChild(c);}
function refresh(){Promise.all([fetch('/api/funk433').then(function(r){return r.json();}),fetch('/api/sdr/status').then(function(r){return r.json();})]).then(function(x){render(x[0],x[1]);}).catch(function(){});}
try{var D=JSON.parse(document.getElementById('sdrData').textContent);render(D.d,D.st);}catch(e){}
setInterval(refresh,30000);
"""

_SDR_APRS_JS = _SDR_HEAD_JS + """
var DIRS=['N','NO','O','SO','S','SW','W','NW'];function dir(b){return (b===undefined||b===null)?'':DIRS[Math.round(b/45)%8];}
function render(d,st){head(st);var m=document.getElementById('sdrMain');m.textContent='';var now=d.now;
var c=sdrEl('div','card');c.appendChild(sdrEl('div','title','APRS-Stationen ('+d.stations.length+') · '+d.n+' Pakete · letztes '+sdrAgo(d.last_t,now)));
if(!d.stations.length){c.appendChild(sdrEl('div','sub','Noch keine APRS-Pakete. 144,800 MHz läuft im Wechsel mit 433 MHz (je 5 min); mit der Stab-/Discone-Antenne im Freien sind 20-80 km üblich.'));m.appendChild(c);}
else{var sc=sdrEl('div','scroll');var tb=sdrEl('table');var hd=sdrEl('tr');
['','Rufzeichen','Typ','Entfernung','Richtung','km/h','Position','zuletzt','direkt/Digi','Pakete','Kommentar'].forEach(function(x){hd.appendChild(sdrEl('th','',x));});tb.appendChild(hd);
d.stations.slice(0,150).forEach(function(s){var dot=sdrEl('span','dot');dot.style.background=sdrCol(s.t,now,1800);
var pos=(s.lat!==undefined)?sdrEl('a','',s.lat.toFixed(4)+', '+s.lon.toFixed(4)):null;if(pos){pos.href='https://www.openstreetmap.org/?mlat='+s.lat+'&mlon='+s.lon+'#map=12/'+s.lat+'/'+s.lon;pos.target='_blank';pos.style.color='#93c5fd';}
var typ=s.obj?'Objekt':(s.wx?'Wetter':(s.last_type==='msg'?'Nachricht':(s.lat!==undefined?'Position':(s.last_type||''))));
sdrRow(tb,[{node:dot},{t:s.call+(s.obj&&s.by?' ('+s.by+')':'')},typ,s.dist_km!==undefined?sdrN(s.dist_km)+' km':'–',dir(s.brg)+(s.brg!==undefined?' '+s.brg+'°':''),
s.speed_kmh?String(s.speed_kmh):'–',pos?{node:pos}:'–',{t:sdrAgo(s.t,now),tip:sdrHM(s.t)},s.direct?'direkt':{t:'via '+(s.path||'').split(',').filter(function(x){return x.indexOf('*')>=0;}).join(',').replace(/[*]/g,''),tip:s.path},
String(s.n||''),{t:s.status||s.comment||'',cls:'w',tip:s.comment||''}]);});
sc.appendChild(tb);c.appendChild(sc);m.appendChild(c);}
var w=sdrEl('div','card');w.appendChild(sdrEl('div','title','APRS-Wetterstationen ('+d.wx.length+')'));
if(!d.wx.length)w.appendChild(sdrEl('div','sub','noch keine'));else{var tb2=sdrEl('table');var h2=sdrEl('tr');
['Station','Entf.','Temp °C','Feuchte %','hPa','Wind km/h','Böe','Richtung','Regen 1h/24h mm','Messung'].forEach(function(x){h2.appendChild(sdrEl('th','',x));});tb2.appendChild(h2);
d.wx.forEach(function(s){var x=s.wx||{};sdrRow(tb2,[s.call,s.dist_km!==undefined?sdrN(s.dist_km)+' km':'–',sdrN(x.temp_c),sdrN(x.hum,0),sdrN(x.hpa),sdrN(x.wind_kmh),sdrN(x.gust_kmh),
x.wind_dir!==undefined?dir(x.wind_dir)+' '+x.wind_dir+'°':'–',sdrN(x.rain_1h_mm)+' / '+sdrN(x.rain_24h_mm),{t:sdrAgo(s.wx_t,now),tip:sdrHM(s.wx_t)}]);});
var sc2=sdrEl('div','scroll');sc2.appendChild(tb2);w.appendChild(sc2);}m.appendChild(w);
var g=sdrEl('div','card');g.appendChild(sdrEl('div','title','APRS-Nachrichten & Bulletins ('+d.msgs.length+')'));
if(!d.msgs.length)g.appendChild(sdrEl('div','sub','noch keine'));else{var tb3=sdrEl('table');var h3=sdrEl('tr');['Zeit','von','an','Text'].forEach(function(x){h3.appendChild(sdrEl('th','',x));});tb3.appendChild(h3);
d.msgs.forEach(function(x){sdrRow(tb3,[sdrHM(x.t),x.from,x.to||'',{t:x.text||'',cls:'w'}]);});var sc3=sdrEl('div','scroll');sc3.appendChild(tb3);g.appendChild(sc3);}
g.appendChild(sdrEl('div','sub','Öffentlicher Amateurfunk (APRS). Nur Empfang – das Dashboard sendet nichts. Entfernung ab Heimatposition '+(d.home?d.home[0].toFixed(2)+'N '+d.home[1].toFixed(2)+'E':'?')+'.'));m.appendChild(g);}
function refresh(){Promise.all([fetch('/api/aprs').then(function(r){return r.json();}),fetch('/api/sdr/status').then(function(r){return r.json();})]).then(function(x){render(x[0],x[1]);}).catch(function(){});}
try{var D=JSON.parse(document.getElementById('sdrData').textContent);render(D.d,D.st);}catch(e){}
setInterval(refresh,30000);
"""


def _sdr_page_433():
    return _sdr_page("Funk 433 MHz", _SDR_433_JS, {"d": _sdr_433_data(), "st": _sdr_status()})


def _sdr_page_aprs():
    return _sdr_page("APRS 144,800 MHz", _SDR_APRS_JS, {"d": _sdr_aprs_data(), "st": _sdr_status()})


_SDR_TILE_JS = """<script id="sdr-js">
(function(){""" + _SDR_JS_COMMON + """
function render(d){var c=document.getElementById('sdrCard');if(!c||!d)return;c.textContent='';var now=d.now;
c.appendChild(sdrEl('div','title','📻 SDR-Funk'));var l=sdrLine(d);
var b=sdrEl('div','big',d.state==='ok'?'● '+(SDRN[(d.status||{}).active]||''):(d.state==='alt'?'● '+(SDRN[(d.status||{}).active]||'Pause'):'● AUS'));b.style.color=l.col;b.style.fontSize='1.2rem';c.appendChild(b);
c.appendChild(sdrEl('div','small',l.txt));
var a=sdrEl('a','',null);a.href='/funk433';a.style.color='inherit';a.style.textDecoration='none';a.style.display='block';a.style.marginTop='4px';
a.appendChild(sdrEl('div','medium','📡 433: '+d.n433_1h+' Sensoren/1h · letztes '+sdrAgo(d.last_433_t,now)));
(d.temps||[]).forEach(function(t){a.appendChild(sdrEl('div','small','· '+t.model+(t.ch!==undefined&&t.ch!==null?' K'+t.ch:'')+': '+sdrN(t.c)+' °C'+(t.h!==undefined&&t.h!==null?' · '+t.h+' %':'')));});c.appendChild(a);
var q=sdrEl('a','',null);q.href='/aprs';q.style.color='inherit';q.style.textDecoration='none';q.style.display='block';q.style.marginTop='4px';
q.appendChild(sdrEl('div','medium','📻 APRS: '+d.naprs_1h+' Stationen/1h · letztes '+sdrAgo(d.last_aprs_t,now)));
if(d.aprs_far)q.appendChild(sdrEl('div','small','weiteste 24 h: '+d.aprs_far+' '+sdrN(d.aprs_far_km)+' km'));
if(d.last_msg)q.appendChild(sdrEl('div','small','✉ '+d.last_msg.from+' → '+(d.last_msg.to||'')+': '+String(d.last_msg.text||'').slice(0,60)));c.appendChild(q);
sdrBtns(c,d,poll);[].slice.call(c.querySelectorAll('.btns')).forEach(function(x){x.style.display='flex';x.style.flexWrap='wrap';x.style.gap='5px';x.style.marginTop='8px';});}
function poll(){fetch('/api/sdr/status').then(function(r){return r.json();}).then(render).catch(function(){});}
function place(){var c=document.getElementById('sdrCard');if(!c||c.getAttribute('data-p')==='1')return;var g=document.querySelector('.grid');
if(g){g.appendChild(c);}c.style.display='';c.setAttribute('data-p','1');
try{render(JSON.parse(document.getElementById('sdrTileData').textContent));}catch(e){}setInterval(poll,60000);}
document.addEventListener('DOMContentLoaded',place);setTimeout(place,700);
})();
</script>"""

_SDR_TILE_CSS = """<style id="sdr-style">
#sdrCard .sdr-btn{background:#1e293b;color:#cbd5e1;border:1px solid #334155;border-radius:8px;padding:4px 7px;font-size:.7rem;cursor:pointer}
#sdrCard .sdr-btn.on{background:#1d4ed8;color:#fff;border-color:#3b82f6}
#sdrCard .small{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
</style>"""

_SDR_PI_JS = """<script id="sdr-pi-js">
(function(){function go(){var g=document.querySelector('#srcCard .pp-grid');var d;try{d=JSON.parse(document.getElementById('sdrPiData').textContent);}catch(e){return;}
if(!g||document.getElementById('sdrPiRow'))return;var col={ok:'#22c55e',alt:'#eab308',ausgefallen:'#ef4444'}[d.state]||'#64748b';
var N={'433':'433 MHz','aprs':'APRS','tcp':'rtl_tcp','idle':'Pause','nostick':'kein Stick','fehler':'Fehler'};var s=d.status||{};
var r=document.createElement('div');r.className='pp-row';r.id='sdrPiRow';r.title='SDR-Planer prepper-sdr: Dienst '+d.service+(s.err?' · '+s.err:'')+' · 433 '+d.n433_1h+'/1h · APRS '+d.naprs_1h+'/1h';
var a=document.createElement('span');a.className='pp-dot';a.style.background=col;var b=document.createElement('span');b.className='pp-name';b.textContent='SDR';
var c=document.createElement('span');c.className='pp-val';c.textContent=(d.service==='läuft'?(N[s.active]||s.active||'?'):d.service);
var l=document.createElement('a');l.href='/funk433';l.style.color='inherit';l.style.textDecoration='none';l.style.display='contents';l.appendChild(a);l.appendChild(b);l.appendChild(c);r.appendChild(l);g.appendChild(r);}
document.addEventListener('DOMContentLoaded',go);setTimeout(go,900);setTimeout(go,2500);})();
</script>"""


def _sdr_after(resp):
    try:
        from flask import request as _sdr_req
        if _sdr_req.path not in ("/", "/pi") or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="sdr-js"' in body or 'id="sdr-pi-js"' in body:
            return resp
        data = _sdr_json.dumps(_sdr_status(), ensure_ascii=False).replace("<", "\\u003c")
        if _sdr_req.path == "/":
            blk = ('<div class="card" id="sdrCard" style="display:none"></div><script type="application/json" id="sdrTileData">%s</script>' % data) + _SDR_TILE_JS
            i = body.find("</head>")
            body = (body[:i] + _SDR_TILE_CSS + body[i:]) if i >= 0 else (_SDR_TILE_CSS + body)
        else:
            blk = ('<script type="application/json" id="sdrPiData">%s</script>' % data) + _SDR_PI_JS
        j = body.rfind("</body>")
        body = (body[:j] + blk + body[j:]) if j >= 0 else (body + blk)
        resp.set_data(body)
    except Exception as e:
        print("sdrFunk inject:", e, flush=True)
    return resp


# bisherige Scanner-Umschaltung (/api/scanner_mode, systemctl rtl433/openwebrx) auf den Planer umlenken - kein sudo mehr
def scanner_mode_get():
    m = (_sdr_mod.get_mode(_SDR_BASE) if _sdr_mod else {"mode": "auto"}).get("mode")
    return "scanner" if m == "tcp" else "sensor"


def scanner_mode_set(mode):
    if _sdr_mod is not None:
        _sdr_mod.set_mode(_SDR_BASE, "tcp" if mode == "scanner" else "auto", None)
    return scanner_mode_get()


try:
    for _sdr_r, _sdr_ep, _sdr_fn, _sdr_m in (("/api/sdr/status", "sdr_status", _sdr_api_status, ["GET"]),
                                            ("/api/sdr/mode", "sdr_mode", _sdr_api_mode, ["POST"]),
                                            ("/api/funk433", "sdr_api433", _sdr_api_433, ["GET"]),
                                            ("/api/aprs", "sdr_apiaprs", _sdr_api_aprs, ["GET"]),
                                            ("/funk433", "sdr_page433", _sdr_page_433, ["GET"]),
                                            ("/aprs", "sdr_pageaprs", _sdr_page_aprs, ["GET"])):
        if _sdr_ep not in app.view_functions and not any(r.rule == _sdr_r for r in app.url_map.iter_rules()):
            app.add_url_rule(_sdr_r, endpoint=_sdr_ep, view_func=_sdr_fn, methods=_sdr_m)
except Exception as _sdr_e:
    print("sdrFunk Routen:", _sdr_e, flush=True)
app.after_request(_sdr_after)
print("sdrFunk aktiv: Modul=%s" % (_sdr_mod is not None), flush=True)
# ===== /sdrFunk =====
'''


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    if MARK in src:
        print("RESULT dashboard.py=schon sha16 %s" % h)
        return
    if h != EXPECT and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    miss = [a for a in NEED if a not in src]
    if miss:
        raise SystemExit("STOP: fehlt %s - nichts geaendert" % miss)
    rr = re.search(r"""(?:route|add_url_rule)\(\s*['"]/(?:funk433|aprs|api/sdr/|api/funk433|api/aprs)""", src)
    if rr:
        raise SystemExit("STOP: Route %s gibt es schon - nichts geaendert" % rr.group(0))
    for bad in ('id="sdr-js"', 'id="sdrCard"', "prepper_sdr"):
        if bad in src:
            raise SystemExit("STOP: %s gibt es schon - nichts geaendert" % bad)
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s, nachher %s)" % (h, hashlib.sha256(new.encode()).hexdigest()[:16]))


if __name__ == "__main__":
    main()
PATCHPY_EOF
cat > "$W/prepper_sdr.py" << 'MODPY_EOF'
#!/usr/bin/env python3
"""prepper_sdr: SDR-Planer fuer den RTL-SDR-Stick (nur Empfang, sendet nichts - weder Funk noch Mesh).

Ein Programm besitzt den Stick und teilt ihn zeitlich auf:
  433  = rtl_433 auf 433,92 MHz (ISM-Sensoren) -> rtl433.jsonl + funk433_state.json
  aprs = rtl_fm 144,800 MHz | direwolf (APRS, Amateurfunk) -> aprs.jsonl + aprs_state.json
  tcp  = rtl_tcp Port 1234 fuer SDR-Apps im LAN (Decoder pausiert, endet automatisch)
Betriebsart steht in sdr_mode.json (schreibt das Dashboard). Status: sdr_status.json.
Fehlt der Stick, wartet der Planer ruhig (kein Neustart-Karussell). Nur ISM/Amateurfunk, keine Pager-/BOS-Dekodierung.
Aufruf: prepper_sdr.py run | selftest | status
"""
import json
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time

V = 1
BASE = os.path.dirname(os.path.abspath(__file__))
MODES = ("auto", "433", "aprs", "tcp", "off")
DEFAULT_CFG = {
    "slice_433_s": 300, "slice_aprs_s": 300, "auto": ["433", "aprs"],
    "f433": "433.92M", "faprs": "144.800M", "ppm": 0, "gain_433": None, "gain_aprs": None,
    "device": None, "tcp_port": 1234, "tcp_bind": "0.0.0.0", "tcp_default_min": 60, "tcp_max_min": 480,
    "usb_ids": ["0bda:2838", "0bda:2832"], "max_jsonl_mb": 8, "aprs_max_jsonl_mb": 4,
    "home": None, "keep_days": 14,
}
HOME_FALLBACK = (49.56, 11.13)


# ---------------------------------------------------------------- Dateien
def p(name, base=None):
    return os.path.join(base or BASE, name)


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def config(base=None):
    c = dict(DEFAULT_CFG)
    u = load_json(p("sdr_config.json", base), {}) or {}
    if isinstance(u, dict):
        for k, v in u.items():
            if k in c:
                c[k] = v
    if not c.get("home"):
        c["home"] = list(home_from_config(base))
    return c


def home_from_config(base=None):
    try:
        txt = open(p("config.py", base), encoding="utf-8").read()
        la = re.search(r"^WEATHER_LAT\s*=\s*([0-9.+-]+)", txt, re.M)
        lo = re.search(r"^WEATHER_LON\s*=\s*([0-9.+-]+)", txt, re.M)
        if la and lo:
            a, b = float(la.group(1)), float(lo.group(1))
            if 47 < a < 56 and 5 < b < 16:
                return (a, b)
    except Exception:
        pass
    return HOME_FALLBACK


def get_mode(base=None):
    d = load_json(p("sdr_mode.json", base), {}) or {}
    m = d.get("mode") if d.get("mode") in MODES else "auto"
    until = d.get("until")
    if m == "tcp" and (not isinstance(until, (int, float)) or until <= time.time()):
        m = "auto"
    if m in ("433", "aprs") and isinstance(until, (int, float)) and until <= time.time():
        m = "auto"
    return {"mode": m, "until": until if m != "auto" else None, "at": d.get("at")}


def set_mode(base, mode, minutes=None):
    """Vom Dashboard: Betriebsart setzen (nur Datei schreiben; der Planer reagiert in ~2 s)."""
    if mode not in MODES:
        raise ValueError("mode")
    c = config(base)
    until = None
    if mode == "tcp":
        mins = minutes if isinstance(minutes, (int, float)) and minutes > 0 else c["tcp_default_min"]
        until = int(time.time() + 60 * min(float(mins), float(c["tcp_max_min"])))
    elif mode in ("433", "aprs") and isinstance(minutes, (int, float)) and minutes > 0:
        until = int(time.time() + 60 * min(float(minutes), 1440.0))
    write_json(p("sdr_mode.json", base), {"mode": mode, "until": until, "at": int(time.time())})
    return get_mode(base)


def stick_info(ids):
    """USB-Stick per sysfs suchen (ohne Programmstart)."""
    root = os.environ.get("SDR_SYSFS_USB", "/sys/bus/usb/devices")
    out = []
    try:
        names = sorted(os.listdir(root))
    except Exception:
        return out
    for n in names:
        d = os.path.join(root, n)
        try:
            vid = open(os.path.join(d, "idVendor")).read().strip()
            pid = open(os.path.join(d, "idProduct")).read().strip()
        except Exception:
            continue
        if "%s:%s" % (vid, pid) in ids:
            info = {"usb": "%s:%s" % (vid, pid), "bus": n}
            for k in ("manufacturer", "product", "serial"):
                try:
                    info[k] = open(os.path.join(d, k)).read().strip()
                except Exception:
                    pass
            out.append(info)
    return out


def rotate(path, max_mb):
    try:
        if os.path.getsize(path) > max_mb * 1024 * 1024:
            os.replace(path, path + ".1")
    except Exception:
        pass


# ---------------------------------------------------------------- Geo
def dist_km(a, b, c, d):
    r = 6371.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def bearing(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    dl = math.radians(d - b)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


# ---------------------------------------------------------------- rtl_433
KEEP433 = ("model", "id", "channel", "subtype", "battery_ok", "temperature_C", "temperature_F", "humidity", "pressure_hPa",
           "wind_avg_km_h", "wind_max_km_h", "wind_avg_m_s", "wind_max_m_s", "wind_dir_deg", "rain_mm", "rain_rate_mm_h",
           "uv", "light_lux", "moisture", "button", "state", "event", "code", "rssi", "snr", "noise", "freq", "protocol")


def parse_433(line):
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None
    if not isinstance(d, dict) or not d.get("model"):
        return None
    t = d.get("time")
    try:
        t = float(t)
    except Exception:
        t = time.time()
    if "temperature_C" not in d and isinstance(d.get("temperature_F"), (int, float)):
        d["temperature_C"] = round((d["temperature_F"] - 32) / 1.8, 1)
    if "wind_avg_km_h" not in d and isinstance(d.get("wind_avg_m_s"), (int, float)):
        d["wind_avg_km_h"] = round(d["wind_avg_m_s"] * 3.6, 1)
    if "wind_max_km_h" not in d and isinstance(d.get("wind_max_m_s"), (int, float)):
        d["wind_max_km_h"] = round(d["wind_max_m_s"] * 3.6, 1)
    rec = {k: d[k] for k in KEEP433 if k in d and isinstance(d[k], (int, float, str))}
    rec["t"] = int(t)
    key = "%s|%s|%s" % (d.get("model"), d.get("id", ""), d.get("channel", ""))
    return key, rec, d


class State433:
    def __init__(self, base):
        self.base = base
        self.f = p("funk433_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "sensors": {}, "n": 0}
        self.d.setdefault("sensors", {})
        self.dirty = False
        self.last_saved = 0
        self.recent = {}

    def add(self, line, now=None):
        r = parse_433(line)
        if not r:
            return None
        key, rec, raw = r
        now = now or time.time()
        sig = json.dumps({k: v for k, v in raw.items() if k not in ("time", "rssi", "snr", "noise", "freq", "mic", "mod")}, sort_keys=True)
        if self.recent.get(key) == sig and now - self.recent.get(key + "#t", 0) < 3:
            return None  # Wiederholung desselben Telegramms (Sensoren senden 2-6x)
        self.recent[key], self.recent[key + "#t"] = sig, now
        s = self.d["sensors"].get(key) or {"first": rec["t"], "n": 0}
        s.update(rec)
        s["n"] = s.get("n", 0) + 1
        s["key"] = key
        self.d["sensors"][key] = s
        self.d["n"] = self.d.get("n", 0) + 1
        self.d["last_t"] = rec["t"]
        self.dirty = True
        return raw

    def prune(self, keep_days):
        cut = time.time() - keep_days * 86400
        for k in [k for k, v in self.d["sensors"].items() if (v.get("t") or 0) < cut]:
            del self.d["sensors"][k]
        if len(self.d["sensors"]) > 300:
            for k, _ in sorted(self.d["sensors"].items(), key=lambda kv: kv[1].get("t") or 0)[:len(self.d["sensors"]) - 300]:
                del self.d["sensors"][k]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


# ---------------------------------------------------------------- APRS
RE_DW = re.compile(r"^\[[0-9A-Za-z.]{1,8}\]\s*([A-Za-z0-9-]{1,9})>([^:\s]+):(.*)$")
RE_TNC2 = re.compile(r"^([A-Za-z0-9-]{1,9})>([^:\s]+):(.*)$")
RE_UNC = re.compile(r"^(\d{2})([0-9 ]{2}\.[0-9 ]{2})([NS])(.)(\d{3})([0-9 ]{2}\.[0-9 ]{2})([EW])(.)")
RE_WX = re.compile(r"([cstgrpPhbL])(-?\d{1,5}|\.{2,5}|\s{2,5})")


def _num(s):
    try:
        return float(s)
    except Exception:
        return None


def _unc(m):
    la = int(m.group(1)) + float(m.group(2).replace(" ", "0")) / 60.0
    lo = int(m.group(5)) + float(m.group(6).replace(" ", "0")) / 60.0
    if m.group(3) == "S":
        la = -la
    if m.group(7) == "W":
        lo = -lo
    return la, lo, m.group(4) + m.group(8)


def _b91(s):
    v = 0
    for ch in s:
        v = v * 91 + (ord(ch) - 33)
    return v


def _compressed(s):
    if len(s) < 13:
        return None
    t = s[0]
    if not (t in "/\\" or "A" <= t <= "Z" or "a" <= t <= "j"):
        return None
    body = s[1:9]
    if any(not (33 <= ord(c) <= 124) for c in body):
        return None
    la = 90.0 - _b91(body[:4]) / 380926.0
    lo = -180.0 + _b91(body[4:8]) / 190463.0
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return la, lo, t + s[9], s[13:]


def _mice(dest, info):
    d = dest.split("-")[0]
    if len(d) != 6 or len(info) < 9:
        return None
    dig = ""
    for c in d:
        if "0" <= c <= "9":
            dig += c
        elif "A" <= c <= "J":
            dig += chr(ord(c) - 17)
        elif "P" <= c <= "Y":
            dig += chr(ord(c) - 32)
        elif c in "KLZ":
            dig += "0"
        else:
            return None
    la = int(dig[0:2]) + (int(dig[2:4]) + int(dig[4:6]) / 100.0) / 60.0
    if not ("P" <= d[3] <= "Z"):
        la = -la
    off = 100 if "P" <= d[4] <= "Z" else 0
    west = "P" <= d[5] <= "Z"
    deg = ord(info[1]) - 28 + off
    if 180 <= deg <= 189:
        deg -= 80
    elif 190 <= deg <= 199:
        deg -= 190
    mi = ord(info[2]) - 28
    if mi >= 60:
        mi -= 60
    hu = ord(info[3]) - 28
    lo = deg + (mi + hu / 100.0) / 60.0
    if west:
        lo = -lo
    sp = (ord(info[4]) - 28) * 10 + (ord(info[5]) - 28) // 10
    dc = (ord(info[5]) - 28) % 10 * 100 + (ord(info[6]) - 28)
    if sp >= 800:
        sp -= 800
    if dc >= 400:
        dc -= 400
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return la, lo, info[8] + info[7], round(sp * 1.852), dc, info[9:]


def _wx(s):
    w = {}
    m = re.match(r"^(\d{3}|\.{3}|\s{3})/(\d{3}|\.{3}|\s{3})", s)
    if m:
        if _num(m.group(1)) is not None:
            w["wind_dir"] = int(m.group(1))
        if _num(m.group(2)) is not None:
            w["wind_kmh"] = round(int(m.group(2)) * 1.609, 1)
        s = s[7:]
    for k, v in RE_WX.findall(s[:60]):
        x = _num(v)
        if x is None:
            continue
        if k == "c" and "wind_dir" not in w:
            w["wind_dir"] = int(x)
        elif k == "s" and "wind_kmh" not in w:
            w["wind_kmh"] = round(x * 1.609, 1)
        elif k == "g":
            w["gust_kmh"] = round(x * 1.609, 1)
        elif k == "t":
            w["temp_c"] = round((x - 32) / 1.8, 1)
        elif k == "r":
            w["rain_1h_mm"] = round(x * 0.254, 1)
        elif k == "p":
            w["rain_24h_mm"] = round(x * 0.254, 1)
        elif k == "P":
            w["rain_mid_mm"] = round(x * 0.254, 1)
        elif k == "h":
            w["hum"] = 100 if int(x) == 0 else int(x)
        elif k == "b":
            w["hpa"] = round(x / 10.0, 1)
    return w if ("temp_c" in w or "hpa" in w or "hum" in w) else None


def parse_aprs(line, depth=0):
    """TNC2-Zeile (direwolf) -> dict oder None. Nur Lesen/Dekodieren."""
    line = line.rstrip("\r\n")
    m = RE_DW.match(line) if line.startswith("[") else RE_TNC2.match(line)
    if not m:
        return None
    src, path, info = m.group(1).upper(), m.group(2), m.group(3)
    parts = path.split(",")
    dest = parts[0]
    via = [x for x in parts[1:] if not x.startswith(("q", "TCPIP"))]
    r = {"src": src, "dest": dest, "path": ",".join(via), "direct": not any("*" in x for x in via), "raw": line[:300]}
    if not info:
        return None
    dti = info[0]
    try:
        if dti == "}" and depth < 2:
            inner = parse_aprs(info[1:], depth + 1)
            if inner:
                inner["third"] = src
                return inner
            return None
        if dti in "!=/@":
            s = info[1:]
            if dti in "/@":
                s = s[7:]
            mm = RE_UNC.match(s)
            if mm:
                la, lo, sym = _unc(mm)
                rest = s[19:]
            else:
                c = _compressed(s)
                if not c:
                    r["type"] = "other"
                    return r
                la, lo, sym, rest = c
            r.update({"type": "pos", "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "comment": rest.strip()[:120]})
            if sym[1:] == "_":
                w = _wx(rest)
                if w:
                    r["type"], r["wx"] = "wx", w
                    r["comment"] = ""
            else:
                cs = re.match(r"^(\d{3})/(\d{3})", rest)
                if cs:
                    r["course"], r["speed_kmh"] = int(cs.group(1)), round(int(cs.group(2)) * 1.852)
            alt = re.search(r"/A=(-?\d{6})", rest)
            if alt:
                r["alt_m"] = round(int(alt.group(1)) * 0.3048)
            return r
        if dti in "`'\x1c\x1d":
            mc = _mice(dest, info)
            if mc:
                la, lo, sym, sp, dc, rest = mc
                r.update({"type": "pos", "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "speed_kmh": sp, "course": dc,
                          "comment": re.sub(r"[\x00-\x1f]", "", rest).strip()[:120], "mice": True})
                return r
        if dti == "_":
            w = _wx(info[9:])
            if w:
                r.update({"type": "wx", "wx": w})
                return r
        if dti == ":" and len(info) >= 11 and info[10] == ":":
            to = info[1:10].strip().upper()
            txt = info[11:]
            mid = None
            if "{" in txt:
                txt, mid = txt.rsplit("{", 1)
            if re.match(r"^(ack|rej)[A-Za-z0-9]{1,5}$", txt):
                r.update({"type": "ack", "to": to})
                return r
            kind = "bulletin" if to.startswith(("BLN", "NWS")) else ("telemetry" if txt.startswith(("PARM.", "UNIT.", "EQNS.", "BITS.")) else "msg")
            r.update({"type": kind, "to": to, "text": txt[:200], "msgid": (mid or "")[:5] or None})
            return r
        if dti == ";" and len(info) > 18:
            name, live = info[1:10].strip(), info[10] == "*"
            s = info[18:]
            mm = RE_UNC.match(s)
            if mm:
                la, lo, sym = _unc(mm)
                rest = s[19:]
            else:
                c = _compressed(s)
                if not c:
                    return None
                la, lo, sym, rest = c
            r.update({"type": "obj", "name": name, "live": live, "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "comment": rest.strip()[:120]})
            return r
        if dti == ">":
            r.update({"type": "status", "text": info[1:120]})
            return r
        if dti == "T":
            r["type"] = "telemetry"
            return r
    except Exception:
        return None
    r["type"] = "other"
    return r


class StateAPRS:
    def __init__(self, base, home):
        self.base = base
        self.home = home
        self.f = p("aprs_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "stations": {}, "msgs": [], "n": 0}
        self.d.setdefault("stations", {})
        self.d.setdefault("msgs", [])
        self.dirty = False
        self.last_saved = 0

    def add(self, line, now=None):
        r = parse_aprs(line)
        if not r or r.get("type") in ("ack",):
            return None
        now = int(now or time.time())
        r["t"] = now
        key = r.get("name") if r.get("type") == "obj" else r["src"]
        s = self.d["stations"].get(key) or {"call": key, "first": now, "n": 0}
        s["n"] = s.get("n", 0) + 1
        s["t"] = now
        s["path"] = r.get("path")
        s["direct"] = r.get("direct")
        if r.get("type") == "obj":
            s["obj"] = True
            s["by"] = r["src"]
        if "lat" in r:
            s.update({"lat": r["lat"], "lon": r["lon"], "sym": r.get("sym"), "pos_t": now})
            s["dist_km"] = round(dist_km(self.home[0], self.home[1], r["lat"], r["lon"]), 1)
            s["brg"] = round(bearing(self.home[0], self.home[1], r["lat"], r["lon"]))
            for k in ("speed_kmh", "course", "alt_m"):
                if k in r:
                    s[k] = r[k]
                else:
                    s.pop(k, None)
        if r.get("comment"):
            s["comment"] = r["comment"]
        if r.get("type") == "status":
            s["status"] = r.get("text")
        if r.get("wx"):
            s["wx"] = r["wx"]
            s["wx_t"] = now
        if r.get("type") in ("msg", "bulletin") and not any(
                x.get("from") == r["src"] and x.get("to") == r.get("to") and x.get("text") == r.get("text") and now - (x.get("t") or 0) < 1800
                for x in self.d["msgs"][-30:]):
            self.d["msgs"].append({"t": now, "from": r["src"], "to": r.get("to"), "text": r.get("text"), "kind": r["type"]})
            self.d["msgs"] = self.d["msgs"][-150:]
        s["last_type"] = r.get("type")
        self.d["stations"][key] = s
        self.d["n"] = self.d.get("n", 0) + 1
        self.d["last_t"] = now
        self.dirty = True
        return r

    def prune(self, keep_days):
        cut = time.time() - keep_days * 86400
        for k in [k for k, v in self.d["stations"].items() if (v.get("t") or 0) < cut]:
            del self.d["stations"][k]
        if len(self.d["stations"]) > 600:
            for k, _ in sorted(self.d["stations"].items(), key=lambda kv: kv[1].get("t") or 0)[:len(self.d["stations"]) - 600]:
                del self.d["stations"][k]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"], self.d["home"] = V, int(time.time()), list(self.home)
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


DIREWOLF_CONF = """# prepper-sdr: nur Empfang (kein PTT, keine Audioausgabe, kein IGate, keine Baken)
ADEVICE null null
ACHANNELS 1
CHANNEL 0
MYCALL N0CALL
MODEM 1200
AGWPORT 0
KISSPORT 0
"""


# ---------------------------------------------------------------- Planer
class Planner:
    def __init__(self, base):
        self.base = base
        self.cfg = config(base)
        self.s433 = State433(base)
        self.saprs = StateAPRS(base, tuple(self.cfg["home"]))
        self.procs = []
        self.active = "idle"
        self.since = time.time()
        self.slice_start = time.time()
        self.auto_idx = 0
        self.fails = 0
        self.retry_at = 0
        self.err = None
        self.err_t = None
        self.stderr = []
        self.stop = False
        self.lock = threading.Lock()
        self.last_status = 0
        self.last_prune = 0
        self.stick = []
        self.counts = {"433": 0, "aprs": 0}
        self.started = time.time()
        self.lastsig = None

    def log(self, *a):
        print("prepper-sdr:", *a, flush=True)

    def _dev(self, args, flag="-d"):
        if self.cfg.get("device") not in (None, ""):
            args += [flag, str(self.cfg["device"])]
        return args

    def cmd(self, what):
        c = self.cfg
        if what == "433":
            a = ["rtl_433", "-f", str(c["f433"]), "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"]
            if c.get("ppm"):
                a += ["-p", str(int(c["ppm"]))]
            if c.get("gain_433") not in (None, ""):
                a += ["-g", str(c["gain_433"])]
            return [self._dev(a)]
        if what == "aprs":
            conf = p("sdr_direwolf.conf", self.base)
            try:
                if open(conf).read() != DIREWOLF_CONF:
                    raise ValueError
            except Exception:
                with open(conf, "w") as f:
                    f.write(DIREWOLF_CONF)
            a = ["rtl_fm", "-f", str(c["faprs"]), "-s", "24000"]
            if c.get("ppm"):
                a += ["-p", str(int(c["ppm"]))]
            if c.get("gain_aprs") not in (None, ""):
                a += ["-g", str(c["gain_aprs"])]
            a = self._dev(a) + ["-"]
            return [a, ["direwolf", "-c", conf, "-r", "24000", "-D", "1", "-t", "0", "-q", "hd", "-"]]
        if what == "tcp":
            return [self._dev(["rtl_tcp", "-a", str(c["tcp_bind"]), "-p", str(int(c["tcp_port"]))])]
        return []

    def _reader(self, stream, fn):
        try:
            for raw in iter(stream.readline, b""):
                try:
                    fn(raw.decode("utf-8", "replace"))
                except Exception as e:
                    self.log("Zeile:", e)
        except Exception:
            pass

    def _err_reader(self, stream):
        try:
            for raw in iter(stream.readline, b""):
                s = raw.decode("utf-8", "replace").strip()
                if s:
                    with self.lock:
                        self.stderr = (self.stderr + [s[:160]])[-8:]
        except Exception:
            pass

    def on433(self, line):
        with self.lock:
            raw = self.s433.add(line)
            if raw is None:
                return
            self.counts["433"] += 1
        fn = p("rtl433.jsonl", self.base)
        rotate(fn, self.cfg["max_jsonl_mb"])
        with open(fn, "a", encoding="utf-8") as f:
            f.write(json.dumps(raw, ensure_ascii=False, separators=(",", ":")) + "\n")

    def onaprs(self, line):
        with self.lock:
            r = self.saprs.add(line)
            if r is None:
                return
            self.counts["aprs"] += 1
        fn = p("aprs.jsonl", self.base)
        rotate(fn, self.cfg["aprs_max_jsonl_mb"])
        r = {k: v for k, v in r.items() if k != "raw"} | {"raw": r.get("raw", "")[:200]}
        with open(fn, "a", encoding="utf-8") as f:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")

    def start(self, what):
        cmds = self.cmd(what)
        self.stderr = []
        prev = None
        procs = []
        try:
            for i, a in enumerate(cmds):
                last = i == len(cmds) - 1
                pr = subprocess.Popen(a, stdin=(prev.stdout if prev else subprocess.DEVNULL), stdout=subprocess.PIPE if (not last or what != "tcp") else subprocess.DEVNULL,
                                      stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
                if prev is not None:
                    prev.stdout.close()
                procs.append(pr)
                threading.Thread(target=self._err_reader, args=(pr.stderr,), daemon=True).start()
                prev = pr
        except Exception as e:
            self.procs = procs
            self.kill()
            raise RuntimeError("Start %s: %s" % (cmds[len(procs)][0] if len(procs) < len(cmds) else what, e))
        self.procs = procs
        if what == "433":
            threading.Thread(target=self._reader, args=(procs[-1].stdout, self.on433), daemon=True).start()
        elif what == "aprs":
            threading.Thread(target=self._reader, args=(procs[-1].stdout, self.onaprs), daemon=True).start()
        self.active, self.since = what, time.time()
        self.log("Start", what, " | ".join(" ".join(a) for a in cmds))

    def kill(self):
        for pr in self.procs:
            try:
                os.killpg(pr.pid, signal.SIGTERM)
            except Exception:
                pass
        end = time.time() + 4
        for pr in self.procs:
            try:
                pr.wait(timeout=max(0.1, end - time.time()))
            except Exception:
                try:
                    os.killpg(pr.pid, signal.SIGKILL)
                    pr.wait(timeout=2)
                except Exception:
                    pass
        had = bool(self.procs)
        self.procs = []
        if had:
            time.sleep(1.0)  # USB freigeben lassen

    def alive(self):
        return bool(self.procs) and all(pr.poll() is None for pr in self.procs)

    def want(self, mode, now):
        m = mode["mode"]
        if m == "off":
            return "idle"
        if m in ("433", "aprs", "tcp"):
            return m
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")] or ["433"]
        if self.active not in order:
            self.auto_idx = self.auto_idx % len(order)
            return order[self.auto_idx]
        sl = float(self.cfg.get("slice_%s_s" % self.active) or 300)
        if len(order) > 1 and now - self.slice_start >= sl:
            self.auto_idx = (order.index(self.active) + 1) % len(order)
            return order[self.auto_idx]
        return self.active

    def status(self, mode, force=False):
        now = time.time()
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")]
        nxt = None
        if mode["mode"] == "auto" and self.active in order and len(order) > 1:
            nxt = int(self.slice_start + float(self.cfg.get("slice_%s_s" % self.active) or 300))
        with self.lock:
            st = {"v": V, "t": int(now), "pid": os.getpid(), "started": int(self.started), "mode": mode["mode"], "until": mode.get("until"),
                  "active": self.active, "since": int(self.since), "next_switch": nxt, "stick": self.stick,
                  "err": self.err, "err_t": self.err_t, "fails": self.fails, "retry_at": int(self.retry_at) if self.retry_at > now else None,
                  "stderr": self.stderr[-3:], "counts": dict(self.counts), "last_433_t": self.s433.d.get("last_t"),
                  "last_aprs_t": self.saprs.d.get("last_t"), "sensors": len(self.s433.d["sensors"]), "stations": len(self.saprs.d["stations"]),
                  "tcp": {"port": int(self.cfg["tcp_port"]), "bind": self.cfg["tcp_bind"]}, "auto": order,
                  "slices": {"433": self.cfg["slice_433_s"], "aprs": self.cfg["slice_aprs_s"]},
                  "freq": {"433": self.cfg["f433"], "aprs": self.cfg["faprs"]}, "home": list(self.saprs.home)}
        sig = (st["mode"], st["active"], st["err"], len(st["stick"]), st["until"])
        if force or sig != self.lastsig or now - self.last_status >= 60:
            write_json(p("sdr_status.json", self.base), st)
            self.last_status, self.lastsig = now, sig
        return st

    def flush(self, force=False):
        with self.lock:
            self.s433.save(force)
            self.saprs.save(force)

    def step(self):
        now = time.time()
        mode = get_mode(self.base)
        self.stick = stick_info(self.cfg["usb_ids"])
        if not self.stick:
            if self.procs:
                self.kill()
            if self.active != "nostick":
                self.log("kein RTL-SDR-Stick gefunden - warte (pruefe alle 15 s)")
            self.active, self.err = "nostick", "kein Stick"
            self.fails = 0
            return 15, mode
        if self.active == "nostick":
            self.active, self.err, self.since = "idle", None, now
            self.log("Stick da:", self.stick[0].get("product"), self.stick[0].get("serial"))
        w = self.want(mode, now)
        if self.procs and not self.alive():
            rc = [pr.poll() for pr in self.procs]
            ran = now - self.since
            self.kill()
            self.fails = 1 if ran > 120 else self.fails + 1
            back = min(300, 10 * 2 ** (self.fails - 1))
            self.retry_at = now + back
            with self.lock:
                tail = self.stderr[-1] if self.stderr else ""
            self.err, self.err_t = "%s beendet (rc %s) nach %d s: %s" % (self.active, rc, ran, tail), int(now)
            self.log(self.err, "- neuer Versuch in %d s" % back)
            self.active = "fehler"
            return 2, mode
        if w == "idle":
            if self.procs:
                self.kill()
            self.active, self.since = "idle", now if self.active != "idle" else self.since
            return 2, mode
        if w != self.active or not self.procs:
            if now < self.retry_at and w == getattr(self, "_last_try", None):
                return 2, mode
            if self.procs:
                self.kill()
            self._last_try = w
            try:
                self.start(w)
                self.slice_start = time.time()
                if self.err and self.err.startswith("Start"):
                    self.err = None
            except Exception as e:
                self.fails += 1
                back = min(300, 10 * 2 ** (self.fails - 1))
                self.retry_at = now + back
                self.err, self.err_t = str(e)[:200], int(now)
                self.active = "fehler"
                self.log(self.err, "- neuer Versuch in %d s" % back)
        elif self.fails and now - self.since > 120:
            self.fails, self.err = 0, None
        return 2, mode

    def loop(self):
        def _sig(*_):
            self.stop = True
        signal.signal(signal.SIGTERM, _sig)
        signal.signal(signal.SIGINT, _sig)
        self.log("Start v%d, Basis %s, Heimat %s, auto %s" % (V, self.base, self.cfg["home"], self.cfg["auto"]))
        mode = get_mode(self.base)
        while not self.stop:
            try:
                wait, mode = self.step()
            except Exception as e:
                self.log("Planer-Fehler:", e)
                wait = 10
            try:
                self.status(mode)
                self.flush()
                if time.time() - self.last_prune > 3600:
                    with self.lock:
                        self.s433.prune(self.cfg["keep_days"])
                        self.saprs.prune(self.cfg["keep_days"])
                    self.last_prune = time.time()
            except Exception as e:
                self.log("Speichern:", e)
            end = time.time() + wait
            while not self.stop and time.time() < end:
                time.sleep(0.5)
                if get_mode(self.base)["mode"] != mode["mode"]:
                    break
        self.kill()
        self.active = "idle"
        self.flush(True)
        self.status(mode, True)
        self.log("Ende")


# ---------------------------------------------------------------- Selbsttest (ohne Stick)
SAMPLES_433 = [
    '{"time":"1760270000","model":"Nexus-TH","id":177,"channel":1,"battery_ok":1,"temperature_C":12.3,"humidity":71,"rssi":-7.1,"snr":21.4,"noise":-28.5}',
    '{"time":"1760270000","model":"Nexus-TH","id":177,"channel":1,"battery_ok":1,"temperature_C":12.3,"humidity":71,"rssi":-7.0,"snr":21.0,"noise":-28.5}',
    '{"time":"1760270031","model":"Fineoffset-WH24","id":44,"temperature_C":10.9,"humidity":88,"wind_dir_deg":225,"wind_avg_m_s":2.1,"wind_max_m_s":4.4,"rain_mm":12.6,"uv":3,"light_lux":5540.0}',
    '{"time":"1760270040","model":"Acurite-Tower","id":9876,"channel":"A","temperature_F":50.0,"humidity":60}',
    'kein json', '{"kaputt":',
]
SAMPLES_APRS = [
    "[0.4] DB0NU>APNU19,WIDE2-1:!4927.37N/01105.36E#PHG5130 Digi Nuernberg",
    "[0.3] DL1ABC-9>493S33,DB0NU*,WIDE2:`'#t\x1e\x1cv>/Fahrt",
    "[0L] DO2XYZ-13>APRS,WIDE1-1:@121215z4933.33N/01107.88E_225/004g009t050r000p012P012h88b10132WX Kalchreuth",
    "[0.1] DL2BBB>APRS,WIDE2-2::DL1ABC-9 :Hallo, QRV?{42",
    "[0.1] DL1ABC-9>APRS::DL2BBB   :ack42",
    "[0.2] DK0XX>APOT30,WIDE2-1:=/5L!!<*e7>7P[Kompr",
    "[0.2] DB0XYZ>APRS:;LEOSAT   *121200z4930.00N/01100.00E`Objekt",
    "[0.2] DL3QQ>APRS:>Status Text",
    "audio level = 34(10/9)   [NONE]   ||||||___",
    "[0.2] DB0ABC>APRS:}DL9XX>APRS,TCPIP,DB0ABC*:!4950.00N/01110.00E-drittes",
]


def selftest():
    import tempfile
    tmp = tempfile.mkdtemp(prefix="sdrtest")
    s = State433(tmp)
    got = [s.add(x) for x in SAMPLES_433]
    assert got[0] and got[1] is None and got[2] and got[3] and got[4] is None and got[5] is None, got
    w = s.d["sensors"]["Fineoffset-WH24|44|"]
    assert w["wind_avg_km_h"] == 7.6 and w["rain_mm"] == 12.6, w
    assert s.d["sensors"]["Acurite-Tower|9876|A"]["temperature_C"] == 10.0
    s.save(True)
    a = StateAPRS(tmp, HOME_FALLBACK)
    res = [parse_aprs(x) for x in SAMPLES_APRS]
    assert res[0]["type"] == "pos" and abs(res[0]["lat"] - 49.45617) < 1e-3 and abs(res[0]["lon"] - 11.08933) < 1e-3, res[0]
    assert res[1]["type"] == "pos" and res[1].get("mice") and not res[1]["direct"] and abs(res[1]["lat"] - 49.5555) < 1e-3 and abs(res[1]["lon"] - 11.1313) < 1e-3 and res[1]["speed_kmh"] == 37, res[1]
    assert res[2]["type"] == "wx" and res[2]["wx"]["temp_c"] == 10.0 and res[2]["wx"]["hpa"] == 1013.2 and res[2]["wx"]["hum"] == 88, res[2]
    assert res[3]["type"] == "msg" and res[3]["to"] == "DL1ABC-9" and res[3]["text"] == "Hallo, QRV?" and res[3]["msgid"] == "42", res[3]
    assert res[4]["type"] == "ack"
    assert res[5]["type"] == "pos" and -90 < res[5]["lat"] < 90, res[5]
    assert res[6]["type"] == "obj" and res[6]["name"] == "LEOSAT", res[6]
    assert res[7]["type"] == "status"
    assert res[8] is None
    assert res[9]["src"] == "DL9XX" and res[9]["third"] == "DB0ABC", res[9]
    for x in SAMPLES_APRS:
        a.add(x)
    a.save(True)
    st = load_json(p("aprs_state.json", tmp))
    assert st["stations"]["DB0NU"]["dist_km"] < 20 and len(st["msgs"]) == 1, st["stations"]["DB0NU"]
    mice = res[1]
    print("selftest OK: 433 Sensoren=%d, APRS Stationen=%d, Mic-E %.4f/%.4f, WX %s" % (
        len(s.d["sensors"]), len(st["stations"]), mice["lat"], mice["lon"], res[2]["wx"]))
    return True


if __name__ == "__main__":
    a = sys.argv[1] if len(sys.argv) > 1 else "status"
    if a == "run":
        Planner(BASE).loop()
    elif a == "selftest":
        selftest()
    else:
        print(json.dumps(load_json(p("sdr_status.json"), {}), indent=1, ensure_ascii=False))
MODPY_EOF

# ---------- 0) Bytes + AST-Guards + Selbsttest ----------
P="$W/patch-sdr.py"; M="$W/prepper_sdr.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $M" | sha256sum -c - >/dev/null || { echo "STOP: Modul sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
python3 -W error::SyntaxWarning -m py_compile "$M" || { echo "STOP: Modul py_compile - nichts geaendert"; exit 1; }
set +e
python3 - "$P" "$M" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
BAD_IMP = ("requests", "urllib", "socket", "http", "meshtastic", "subprocess")
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in BAD_IMP:
                print("Block: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        f = node.func
        fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("update_all", "urlopen", "Popen", "system", "call", "run", "remove", "unlink", "write_json"):
            print("Block: verbotener Aufruf", fn); hit = True
        if fn == "open":
            print("Block: open"); hit = True
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
        print("Block: data_store-Schreiben"); hit = True
mod = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
ALLOWED = {"rtl_433", "rtl_fm", "rtl_tcp", "direwolf"}
for node in ast.walk(ast.parse(mod)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in ("requests", "urllib", "socket", "http", "meshtastic"):
                print("Modul: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        f = node.func
        fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if fn.startswith(("send", "maybe_mesh")) or fn in ("system", "popen", "call", "check_output", "check_call", "run", "rmtree", "unlink", "remove", "execv", "execvp"):
            print("Modul: verbotener Aufruf", fn); hit = True
        for kw in node.keywords:
            if kw.arg == "shell":
                print("Modul: shell="); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and isinstance(node.elts[0].value, str):
        v = node.elts[0].value
        if v.startswith(("rtl", "direwolf", "rpitx", "hackrf", "sendiq", "tx")) and v not in ALLOWED:
            print("Modul: Programm", v); hit = True
for bad in ("rpitx", "hackrf_transfer", "multimon", "POCSAG", "PTT GPIO", "PTT /dev", "IGSERVER", "PBEACON"):
    if bad in mod:
        print("Modul: verboten", bad); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
python3 "$M" selftest || { echo "STOP: Selbsttest Dekoder - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Mesh, kein Netz-Import, nur rtl_433/rtl_fm/direwolf/rtl_tcp ohne Shell, kein Senden)"

# ---------- 1) Voraussetzungen (nur lesen) ----------
miss=""
for b in rtl_433 rtl_fm rtl_tcp direwolf; do command -v "$b" >/dev/null 2>&1 || miss="$miss $b"; done
[[ -z "$miss" ]] || { echo "STOP: Programme fehlen:$miss (sudo apt install rtl-sdr rtl-433 direwolf) - nichts geaendert"; exit 1; }
echo "OK Programme: $(rtl_433 -V 2>&1 | head -1 | cut -c1-40) · direwolf $(direwolf -h 2>&1 | grep -o -m1 'version [0-9.]*' || echo ?)"
if [[ -f "$DASH_DIR/prepper_sdr.py" ]] && ! cmp -s "$M" "$DASH_DIR/prepper_sdr.py" && ! grep -q 'prepper_sdr: SDR-Planer' "$DASH_DIR/prepper_sdr.py"; then
  echo "STOP: fremde $DASH_DIR/prepper_sdr.py vorhanden - nichts geaendert"; exit 1; fi
SDR_MINE=0; systemctl is-active --quiet "$UNIT" 2>/dev/null && SDR_MINE=1
if [[ "$SDR_MINE" == 0 ]]; then
  busy=$(pgrep -a -x 'rtl_433|rtl_fm|rtl_tcp|rtl_sdr|rtl_power|dump1090|dump1090-fa|readsb|openwebrx' 2>/dev/null || true)
  if [[ -n "$busy" ]]; then
    own=""
    for u in rtl433 rtl_433 openwebrx rtl_tcp rtltcp; do systemctl is-active --quiet "$u" 2>/dev/null && own="$own $u"; done
    if [[ -z "$own" ]]; then echo "STOP: SDR-Programm laeuft ausserhalb eines Dienstes:"; echo "$busy"; echo "bitte beenden - nichts geaendert"; exit 1; fi
  fi
fi
if ss -ltn 2>/dev/null | grep -q ":$TCP_PORT "; then
  if [[ "$SDR_MINE" == 0 ]]; then echo "STOP: Port $TCP_PORT belegt (rtl_tcp-Port) - nichts geaendert"; exit 1; fi
fi
CONFLICT=()
for u in rtl433 rtl_433 openwebrx rtl_tcp rtltcp; do
  if systemctl cat "$u.service" >/dev/null 2>&1; then
    a=$(systemctl is-active "$u.service" 2>/dev/null || true); e=$(systemctl is-enabled "$u.service" 2>/dev/null || true)
    if [[ "$a" == active || "$e" == enabled ]]; then CONFLICT+=("$u:$a:$e"); fi
  fi
done
[[ ${#CONFLICT[@]} -gt 0 ]] && echo "Hinweis: alte SDR-Dienste werden gestoppt + deaktiviert (Rollback stellt sie wieder her): ${CONFLICT[*]}"
DVB_LOADED=0; lsmod 2>/dev/null | grep -q '^dvb_usb_rtl28xxu' && DVB_LOADED=1
DVB_BL=0; grep -rqs '^[[:space:]]*blacklist[[:space:]]\+dvb_usb_rtl28xxu' "$MODPROBE_DIR" /lib/modprobe.d /usr/lib/modprobe.d 2>/dev/null && DVB_BL=1
echo "DVB-Treiber dvb_usb_rtl28xxu: geladen=$DVB_LOADED gesperrt=$DVB_BL"
STICK=$(lsusb 2>/dev/null | grep -i -E '0bda:(2838|2832)' | head -1 || true)
echo "Stick: ${STICK:-nicht gefunden (Planer wartet dann ruhig)}"
id -nG "$RUN_USER" | grep -qw plugdev && GRP_PLUG=1 || GRP_PLUG=0
getent group plugdev >/dev/null 2>&1 && HAVE_PLUG=1 || HAVE_PLUG=0

# ---------- 2) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error::SyntaxWarning -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
GRPLINE=""; [[ "$HAVE_PLUG" == 1 ]] && GRPLINE="SupplementaryGroups=plugdev"
cat > "$W/$UNIT" << UNITEOF
[Unit]
Description=Prepper SDR-Planer (rtl_433 433 MHz / APRS-Empfang / rtl_tcp) - nur Empfang, sendet nichts
After=network-online.target
StartLimitIntervalSec=900
StartLimitBurst=4

[Service]
Type=simple
User=$RUN_USER
$GRPLINE
WorkingDirectory=$DASH_DIR
ExecStart=/usr/bin/python3 $DASH_DIR/prepper_sdr.py run
Restart=on-failure
RestartSec=60
KillMode=control-group
TimeoutStopSec=15
Nice=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNITEOF
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /pi /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /energie=${PRE[/energie]}"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l)

same_dash=0; cmp -s "$W/work/dashboard.py" "$F" && same_dash=1
same_mod=0; cmp -s "$M" "$DASH_DIR/prepper_sdr.py" 2>/dev/null && same_mod=1
same_unit=0; cmp -s "$W/$UNIT" "$UNIT_DIR/$UNIT" 2>/dev/null && same_unit=1
if [[ "$same_dash" == 1 && "$same_mod" == 1 && "$same_unit" == 1 && "$SDR_MINE" == 1 && ${#CONFLICT[@]} -eq 0 && ( "$DVB_BL" == 1 ) ]]; then
  echo "OK sdrFunk schon installiert - kein Neustart"
else
  sudo -v
  NEW_MOD=0; [[ -f "$DASH_DIR/prepper_sdr.py" ]] || NEW_MOD=1
  NEW_UNIT=0; [[ -f "$UNIT_DIR/$UNIT" ]] || NEW_UNIT=1
  NEW_BL=0; UNLOADED=0
  rb() {
    echo "ROLLBACK: $1"
    sudo systemctl stop "$UNIT" 2>/dev/null || true
    if [[ "$NEW_UNIT" == 1 ]]; then sudo systemctl disable "$UNIT" 2>/dev/null || true; sudo rm -f "$UNIT_DIR/$UNIT"
    elif [[ -f "$W/$UNIT.old" ]]; then sudo cp "$W/$UNIT.old" "$UNIT_DIR/$UNIT"; fi
    sudo systemctl daemon-reload || true
    [[ "$NEW_UNIT" == 0 && "$SDR_MINE" == 1 ]] && sudo systemctl start "$UNIT" 2>/dev/null || true
    cp -a "$F.bak-sdr-$TS" "$F"
    if [[ "$NEW_MOD" == 1 ]]; then rm -f "$DASH_DIR/prepper_sdr.py"; elif [[ -f "$DASH_DIR/prepper_sdr.py.bak-sdr-$TS" ]]; then cp -a "$DASH_DIR/prepper_sdr.py.bak-sdr-$TS" "$DASH_DIR/prepper_sdr.py"; fi
    [[ "$NEW_BL" == 1 ]] && sudo rm -f "$MODPROBE_DIR/prepper-sdr-blacklist.conf"
    [[ "$UNLOADED" == 1 ]] && sudo modprobe dvb_usb_rtl28xxu 2>/dev/null || true
    for c in "${CONFLICT[@]}"; do u=${c%%:*}; r=${c#*:}; a=${r%%:*}; e=${r#*:}
      [[ "$e" == enabled ]] && sudo systemctl enable "$u.service" 2>/dev/null || true
      [[ "$a" == active ]] && sudo systemctl start "$u.service" 2>/dev/null || true; done
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-sdr-$TS"
  }
  cp -a "$F" "$F.bak-sdr-$TS"
  [[ "$NEW_MOD" == 0 && "$same_mod" == 0 ]] && cp -a "$DASH_DIR/prepper_sdr.py" "$DASH_DIR/prepper_sdr.py.bak-sdr-$TS"
  [[ "$NEW_UNIT" == 0 ]] && cp "$UNIT_DIR/$UNIT" "$W/$UNIT.old"
  for c in "${CONFLICT[@]}"; do u=${c%%:*}; sudo systemctl stop "$u.service" || true; sudo systemctl disable "$u.service" 2>/dev/null || true; echo "alter Dienst $u gestoppt + deaktiviert"; done
  if [[ "$DVB_BL" == 0 ]]; then
    printf '# prepper-sdr: DVB-T-Treiber sperren, damit rtl_433/rtl_fm/rtl_tcp den RTL-SDR-Stick bekommen\nblacklist dvb_usb_rtl28xxu\nblacklist rtl2832\nblacklist rtl2830\n' > "$W/bl.conf"
    sudo install -m 644 "$W/bl.conf" "$MODPROBE_DIR/prepper-sdr-blacklist.conf" && NEW_BL=1 || { rb "Blacklist schreiben"; exit 1; }
    echo "DVB-Treiber gesperrt: $MODPROBE_DIR/prepper-sdr-blacklist.conf"
  fi
  if [[ "$DVB_LOADED" == 1 ]]; then
    if sudo modprobe -r dvb_usb_rtl28xxu 2>/dev/null; then UNLOADED=1; echo "DVB-Treiber entladen"; else echo "WARN DVB-Treiber nicht entladbar - Stick evtl. erst nach Neustart/Umstecken frei"; fi
  fi
  if [[ -n "$STICK" ]]; then
    timeout 6 rtl_test -s 1024000 > "$W/rtltest.txt" 2>&1 || true
    if grep -q -E 'usb_claim_interface|usb_open error|No supported devices|Failed to open' "$W/rtltest.txt"; then
      echo "WARN Stick-Test: $(grep -m1 -E 'usb_claim_interface|usb_open error|No supported devices|Failed to open' "$W/rtltest.txt")"
      [[ "$GRP_PLUG" == 0 ]] && echo "WARN $RUN_USER ist nicht in plugdev - ggf. sudo usermod -aG plugdev $RUN_USER"
      echo "Patch laeuft weiter, Planer zeigt den Fehler und versucht es mit Pause erneut"
    else
      echo "OK Stick-Test: $(grep -m1 -E 'Found .* tuner|Found [0-9] device' "$W/rtltest.txt" | cut -c1-70)"
    fi
  fi
  install -m 644 "$M" "$DASH_DIR/prepper_sdr.py.new" && mv -f "$DASH_DIR/prepper_sdr.py.new" "$DASH_DIR/prepper_sdr.py" || { rb "Modul installieren"; exit 1; }
  [[ -f "$DASH_DIR/rtl433.jsonl" ]] || : > "$DASH_DIR/rtl433.jsonl"
  sudo install -m 644 "$W/$UNIT" "$UNIT_DIR/$UNIT" || { rb "Unit schreiben"; exit 1; }
  sudo systemctl daemon-reload
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl enable "$UNIT" >/dev/null 2>&1 || { rb "enable $UNIT"; exit 1; }
  sudo systemctl restart "$UNIT" || { rb "Start $UNIT"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard + prepper-sdr neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  for i in $(seq 1 10); do [[ -f "$DASH_DIR/sdr_status.json" ]] && break; sleep 2; done
  systemctl is-active --quiet "$UNIT" || { sudo journalctl -u "$UNIT" --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -5; rb "$UNIT laeuft nicht"; exit 1; }
  sc=$("${CURL[@]}" "$B/api/sdr/status" -o "$W/s0.json" -w "%{http_code}" || true)
  [[ "$sc" == "200" ]] || { rb "/api/sdr/status antwortet nicht ($sc)"; exit 1; }
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d.get('module') and d.get('status',{}).get('v')==1 and d['service']=='läuft', d" "$W/s0.json" || { rb "/api/sdr/status ungueltig oder Planer schreibt keinen Status"; exit 1; }
  for pg in /funk433 /aprs; do
    pc=$("${CURL[@]}" "$B$pg" -o "$W/pg.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] && grep -q 'id="sdrData"' "$W/pg.html" || { rb "$pg fehlerhaft ($pc)"; exit 1; }
  done
  for ap in /api/funk433 /api/aprs; do
    python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok')" < <("${CURL[@]}" "$B$ap") || { rb "$ap ungueltig"; exit 1; }
  done
  echo "OK /funk433 /aprs /api/sdr/status /api/funk433 /api/aprs"
  if [[ "${PRE[/]}" == "200" ]]; then
    "${CURL[@]}" -L --max-redirs 5 "$B/" -o "$W/lage.html" || true
    grep -q 'id="sdr-js"' "$W/lage.html" && grep -q 'id="sdrCard"' "$W/lage.html" || { rb "Lage-Seite ohne SDR-Kachel"; exit 1; }
    echo "OK Lage-Seite mit SDR-Kachel"
  fi
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    grep -q 'id="sdr-pi-js"' "$W/pi.html" || { rb "/pi ohne SDR-Zeile"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l)
    [[ "$R1" == "$R0" ]] || { rb "/pi Sicherung veraendert"; exit 1; }
    echo "OK /pi mit SDR-Zeile in Datenquellen (Sicherung unveraendert, doPrepperRestore $R1)"
  fi
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'sdrFunk' | tail -2 || true
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-sdr-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi

# ---------- 3) erster Empfang (nur anzeigen, ~40 s) ----------
echo "Empfang 40 s beobachten ..."
sleep "${SDR_WATCH_S:-40}"
"${CURL[@]}" "$B/api/sdr/status" | python3 -c "
import json,sys
d=json.load(sys.stdin); s=d.get('status') or {}; k=(s.get('stick') or [{}])[0]
print('SDR Dienst %s · aktiv %s · Modus %s · Stick %s %s' % (d.get('service'), s.get('active'), (d.get('mode') or {}).get('mode'), k.get('product') or '-', k.get('serial') or ''))
print('SDR 433-Telegramme %s · Sensoren %s · APRS-Pakete %s · Stationen %s' % ((s.get('counts') or {}).get('433'), d.get('n433'), (s.get('counts') or {}).get('aprs'), d.get('naprs')))
print('SDR Fehler: %s' % (s.get('err') or 'keiner'))
for x in (s.get('stderr') or [])[-2:]: print('  stderr:', x[:100])
" 2>/dev/null || echo "WARN Status nicht lesbar"
sudo journalctl -u "$UNIT" -n 4 --no-pager -o cat 2>/dev/null | cut -c1-160 || true
echo "OK guards sdrFunk=$(grep -q '# ===== sdrFunk:' "$F" && echo 1 || echo 0) speedTile=$(grep -q '# ===== speedTile:' "$F" && echo 1 || echo 0) speedTest=$(grep -q '# ===== speedTest:' "$F" && echo 1 || echo 0) piPolish2=$(grep -q '# ===== piPolish2:' "$F" && echo 1 || echo 0) sourceWatch=$(grep -q '# ===== sourceWatch:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-sdr-$TS" ]] && echo "Backup: $F.bak-sdr-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG sdrFunk=1"
