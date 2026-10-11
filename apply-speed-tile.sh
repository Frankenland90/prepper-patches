#!/bin/bash
set -euo pipefail
# speedTile: Speedtest-Box im Internet-Tile im Lage-Stil (Diagramm 14 Tage, Hoch/Tief, Ampelfarben). Nur Anzeige.
# Nur bei dashboard.py sha16 b0503a09a42fc9c3. Sendet nichts, misst nichts zusaetzlich. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/speedtile
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== speedTile apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="c4118b1f41978c18a96a6dc0654334071a8b7795838a7695d0856e2356c24162"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-speedtile.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""speedTile: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== speedTile:"
EXPECT = "b0503a09a42fc9c3"
NEED = ["# ===== speedTest:", "_ST_JS", "_st_status", "stBox", "# ===== piPolish2:"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== speedTile: Speedtest-Box im Internet-Tile im Lage-Stil (gross, Diagramm 14 Tage, Hoch/Tief, Ampelfarben), nur Anzeige =====
# Ampel: Down/Up gegen Basis (Median 14 Tage gleicher Uplink, ab 5 Messungen; vorher Telekom nominal 62/24, Starlink beobachtet).
# Ping/Last-Latenz: gruen <50, gelb <150, sonst rot. Verlust: gruen 0, gelb <1 %, sonst rot. /api/speedtest/history?days=14 (nur lesen).
import time as _stt_time
import statistics as _stt_stat

_STT_NOMINAL = {"telekom": (62.0, 24.0)}
_STT_COL = {"g": "#22c55e", "y": "#eab308", "r": "#ef4444", "n": "#94a3b8"}


def _stt_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _stt_hist(days=14):
    """Messpunkte der letzten N Tage aus speedtest.json (letzte Laeufe) + Archivreihen speed_<uplink>, nach Zeit, ohne Doppelte."""
    days = max(1, min(90, int(days)))
    cut = _stt_time.time() - days * 86400
    pts = {}
    a = globals().get("_arch")
    if a is not None and hasattr(a, "series_points"):
        for u in ("telekom", "starlink", "unklar"):
            try:
                d = a.series_points("speed_" + u, days) or {}
            except Exception:
                d = {}
            for x in d.get("raw") or []:
                v = x.get("v") or {}
                t = int(x.get("t") or 0)
                if t >= cut and _stt_num(v.get("down")):
                    pts[t] = {"t": t, "down": v.get("down"), "up": v.get("up") if _stt_num(v.get("up")) else None,
                              "ping": v.get("ping") if _stt_num(v.get("ping")) else None, "u": u}
    st = globals().get("_st")
    if st is not None:
        try:
            for r in st.runs():
                t = int(r.get("t") or 0)
                if t >= cut and _stt_num(r.get("down")):
                    pts[t] = {"t": t, "down": r["down"], "up": r.get("up") if _stt_num(r.get("up")) else None,
                              "ping": r.get("ping") if _stt_num(r.get("ping")) else None, "u": r.get("uplink") or "unklar"}
        except Exception:
            pass
    return [pts[k] for k in sorted(pts)]


def _stt_base(hist, u):
    xs = [p for p in hist if p["u"] == u]
    dn = [p["down"] for p in xs if _stt_num(p.get("down"))]
    up = [p["up"] for p in xs if _stt_num(p.get("up"))]
    if len(dn) >= 5:
        return {"down": round(_stt_stat.median(dn), 1), "up": round(_stt_stat.median(up), 1) if up else None, "src": "Median %d Messungen" % len(dn), "n": len(dn)}
    if u in _STT_NOMINAL:
        return {"down": _STT_NOMINAL[u][0], "up": _STT_NOMINAL[u][1], "src": "nominal (erst %d Messungen)" % len(dn), "n": len(dn)}
    if dn:
        return {"down": round(_stt_stat.median(dn), 1), "up": round(_stt_stat.median(up), 1) if up else None, "src": "beobachtet (%d)" % len(dn), "n": len(dn)}
    return None


def _stt_rel(v, b):
    if not _stt_num(v) or not _stt_num(b) or b <= 0:
        return _STT_COL["n"]
    r = v / b
    return _STT_COL["g"] if r >= 0.8 else (_STT_COL["y"] if r >= 0.5 else _STT_COL["r"])


def _stt_ms(v):
    if not _stt_num(v):
        return _STT_COL["n"]
    return _STT_COL["g"] if v < 50 else (_STT_COL["y"] if v < 150 else _STT_COL["r"])


def _stt_loss(v):
    if not _stt_num(v):
        return _STT_COL["n"]
    return _STT_COL["g"] if v <= 0 else (_STT_COL["y"] if v < 1 else _STT_COL["r"])


def _stt_cols(r, base):
    if not r:
        return {}
    b = base or {}
    return {"down": _stt_rel(r.get("down"), b.get("down")), "up": _stt_rel(r.get("up"), b.get("up")),
            "ping": _stt_ms(r.get("ping")), "dl_lat": _stt_ms(r.get("dl_lat")), "ul_lat": _stt_ms(r.get("ul_lat")),
            "loss": _stt_loss(r.get("loss"))}


def _stt_tile(d):
    hist = _stt_hist(14)
    last = d.get("last") or None
    u = (last or {}).get("uplink") or "unklar"
    base = {k: _stt_base(hist, k) for k in ("telekom", "starlink", "unklar")}
    sel = [p for p in hist if p["u"] == u] if u in ("telekom", "starlink") else hist
    hi = max(sel, key=lambda p: p["down"]) if sel else None
    lo = min(sel, key=lambda p: p["down"]) if sel else None
    other = {}
    for k, o in (d.get("by_uplink") or {}).items():
        if o:
            other[k] = _stt_cols(o, base.get(k))
    return {"v": 1, "base": base, "col": _stt_cols(last, base.get(u)), "col_by_uplink": other,
            "hi": {"t": hi["t"], "down": hi["down"], "u": hi["u"]} if hi else None,
            "lo": {"t": lo["t"], "down": lo["down"], "u": lo["u"]} if lo else None,
            "hilo_scope": u if u in ("telekom", "starlink") else "alle", "n14": len(hist),
            "pts": [[p["t"], p["down"], p["up"], p["u"]] for p in hist]}


if callable(globals().get("_st_status")):
    _stt_orig_status = _st_status

    def _st_status():
        d = _stt_orig_status()
        try:
            if d.get("ok"):
                d["tile"] = _stt_tile(d)
        except Exception as e:
            print("speedTile:", e, flush=True)
        return d


def _stt_api_hist():
    from flask import jsonify, request
    try:
        days = int(request.args.get("days", "14"))
    except Exception:
        days = 14
    days = max(1, min(90, days))
    return jsonify({"ok": True, "days": days, "points": _stt_hist(days)})


try:
    if "stt_hist" not in app.view_functions:
        app.add_url_rule("/api/speedtest/history", endpoint="stt_hist", view_func=_stt_api_hist, methods=["GET"])
except Exception as _stt_e:
    print("speedTile Route:", _stt_e, flush=True)

_ST_CSS = """<style id="st-style">
#stBox{margin:10px 0 4px;padding-top:10px;border-top:1px solid #334155}
#stBox .stt-t{font-size:0.72rem;letter-spacing:0.08em;color:#94a3b8;text-transform:uppercase;margin-bottom:6px}
#stBox .stt-big{display:flex;gap:14px;align-items:baseline;white-space:nowrap}
#stBox .stt-big .v{font-size:1.45rem;font-weight:700;line-height:1.15;font-variant-numeric:tabular-nums}
#stBox .stt-u{font-size:.8rem;color:#94a3b8;font-weight:500}
#stBox .stt-s{font-size:.72rem;color:#94a3b8;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#stBox .stt-s b{font-weight:600}
#stBox .chart-box{height:70px;margin-top:6px;position:relative}
#stBox .stt-hl{font-size:.72rem;color:#cbd5e1;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#stBox .stt-o{font-size:.72rem;color:#64748b;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#stBox .stt-k{display:inline-block;width:8px;height:8px;border-radius:2px;margin:0 3px 0 6px;vertical-align:middle}
</style>"""

_ST_JS = """<script id="st-js" data-v="stt-v1">
(function(){
var UPN={telekom:['🔌','Telekom','#3b82f6'],starlink:['🛰️','Starlink','#f59e0b'],unklar:['❔','unklar','#64748b']};
var chart=null;
function pad(x){return (x<10?'0':'')+x;}
function n(x,d){return (x===null||x===undefined)?'–':(+x).toFixed(d===undefined?1:d).replace('.',',');}
function when(t){if(!t)return '–';var d=new Date(t*1000),h=new Date();var hm=pad(d.getHours())+':'+pad(d.getMinutes());
return d.toDateString()===h.toDateString()?hm:pad(d.getDate())+'.'+pad(d.getMonth()+1)+'. '+hm;}
function ago(t){if(!t)return '';var a=Math.max(0,Date.now()/1000-t);return a<3600?Math.round(a/60)+' min':(a<172800?Math.round(a/3600)+' h':Math.round(a/86400)+' T');}
function el(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;if(txt!==undefined)e.textContent=txt;return e;}
function sp(txt,col,b){var s=el(b?'b':'span','',txt);if(col)s.style.color=col;return s;}
function add(p,list){list.forEach(function(x){p.appendChild(typeof x==='string'?document.createTextNode(x):x);});return p;}
function sname(sv){var s=(sv&&sv.name)||'?';return s.length>18?s.slice(0,17)+'…':s;}
function msg(t){var m=document.getElementById('stTileMsg');if(m){m.textContent=t||'';m.style.display=t?'':'none';}}
function loadChart(cb){if(window.Chart)return cb();if(window._sttQ){window._sttQ.push(cb);return;}window._sttQ=[cb];
var s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js';
s.onload=function(){var q=window._sttQ||[];window._sttQ=null;q.forEach(function(f){try{f();}catch(e){}});};
s.onerror=function(){window._sttQ=null;msg('Diagramm offline (Chart.js nicht ladbar)');};document.head.appendChild(s);}
function draw(pts){var cv=document.getElementById('stTileChart');if(!cv)return;
if(!pts||pts.length<2){msg('Diagramm ab 2 Messungen');return;}msg('');
loadChart(function(){if(chart){try{chart.destroy();}catch(e){}chart=null;}
var pc=pts.map(function(p){return (UPN[p[3]]||UPN.unklar)[2];});
var seg={borderColor:function(c){return pc[c.p1DataIndex];}};
var dn=pts.map(function(p){return {x:p[0]*1000,y:p[1]};}),up=pts.map(function(p){return {x:p[0]*1000,y:p[2]};});
chart=new Chart(cv.getContext('2d'),{type:'line',data:{datasets:[
{data:dn,borderColor:'#3b82f6',segment:seg,borderWidth:2,pointRadius:2,pointBackgroundColor:pc,pointBorderColor:pc,tension:0.25,spanGaps:true},
{data:up,borderColor:'#3b82f6',segment:seg,borderDash:[4,3],borderWidth:1.5,pointRadius:1.5,pointBackgroundColor:pc,pointBorderColor:pc,tension:0.25,spanGaps:true}]},
options:{responsive:true,maintainAspectRatio:false,animation:false,plugins:{legend:{display:false},tooltip:{callbacks:{
title:function(it){return when(it[0].parsed.x/1000);},label:function(it){return (it.datasetIndex?'⬆ ':'⬇ ')+n(it.parsed.y)+' Mbit/s';}}}},
scales:{x:{type:'linear',min:pts[0][0]*1000,max:Math.max(Date.now(),pts[pts.length-1][0]*1000),ticks:{color:'#64748b',font:{size:8},maxTicksLimit:4,maxRotation:0,
callback:function(v){var d=new Date(v);return pad(d.getDate())+'.'+pad(d.getMonth()+1)+'.';}},grid:{display:false}},
y:{min:0,ticks:{color:'#64748b',font:{size:8},maxTicksLimit:3},grid:{color:'#1e293b'}}}}});});}
function render(d){var box=document.getElementById('stBox');if(!box||!d)return;box.textContent='';
var t=d.tile||{},c=t.col||{},r=d.last;
box.appendChild(el('div','stt-t','⚡ Speedtest (Ookla)'+(d.running?' · läuft …':'')));
if(!r){box.appendChild(el('div','stt-s',d.binary?'noch keine Messung':'speedtest-Programm fehlt'));}
else{var u=UPN[r.uplink]||UPN.unklar,bs=(t.base||{})[r.uplink];
var big=el('div','stt-big');if(bs)big.title='Basis '+n(bs.down)+'/'+n(bs.up)+' Mbit/s · '+bs.src;
add(big,[sp('⬇ '+n(r.down),c.down),sp('⬆ '+n(r.up),c.up)]);big.children[0].className='v';big.children[1].className='v';big.appendChild(el('span','stt-u','Mbit/s'));box.appendChild(big);
var lossTxt=(r.loss===null||r.loss===undefined)?'–':(r.loss==0?'0 %':n(r.loss,1)+' %');
box.appendChild(add(el('div','stt-s'),['Ping ',sp(n(r.ping,0)+' ms',c.ping,1),' · Jitter '+n(r.jitter,1)+' · Last ',sp(n(r.dl_lat,0),c.dl_lat,1),'/',sp(n(r.ul_lat,0)+' ms',c.ul_lat,1),' · Verlust ',sp(lossTxt,c.loss,1)]));
box.appendChild(el('div','stt-s',u[0]+' '+u[1]+' · '+sname(r.server)+(r.server_auto?' (auto)':'')+' · '+when(r.t)+(d.next_at?' · nächste '+d.next_at.slice(11):'')));}
var cb=el('div','chart-box');var cv=el('canvas');cv.id='stTileChart';cb.appendChild(cv);box.appendChild(cb);
var m=el('div','stt-o');m.id='stTileMsg';m.style.display='none';box.appendChild(m);
if(t.hi&&t.lo){var sc=t.hilo_scope==='alle'?'':' '+((UPN[t.hilo_scope]||UPN.unklar)[0]);
box.appendChild(add(el('div','stt-hl'),[sp('↑','#22c55e'),' '+when(t.hi.t)+' · '+n(t.hi.down)+' Mbit/s'+sc]));
box.appendChild(add(el('div','stt-hl'),[sp('↓','#ef4444'),' '+when(t.lo.t)+' · '+n(t.lo.down)+' Mbit/s'+sc]));}
var lg=el('div','stt-o');var k1=el('span','stt-k');k1.style.background=UPN.telekom[2];var k2=el('span','stt-k');k2.style.background=UPN.starlink[2];
add(lg,['14 Tage',k1,'Telekom',k2,'Starlink · gestrichelt = Upload']);box.appendChild(lg);
['telekom','starlink'].forEach(function(k){if(r&&k===r.uplink)return;var o=(d.by_uplink||{})[k],q=UPN[k];
box.appendChild(el('div','stt-o',q[0]+' '+q[1]+': '+(o?('⬇ '+n(o.down)+' ⬆ '+n(o.up)+' Mbit/s · '+n(o.ping,0)+' ms · vor '+ago(o.t)):'noch keine Messung')));});
if(d.last_error&&(!r||d.last_error.t>r.t))box.appendChild(el('div','stt-o','letzter Fehler '+when(d.last_error.t)+': '+(d.last_error.msg||'').slice(0,80)));
draw(t.pts);}
function poll(k){fetch('/api/speedtest').then(function(r){return r.json();}).then(function(d){render(d);if(d.running&&k<50)setTimeout(function(){poll(k+1);},3000);}).catch(function(){});}
function place(){var box=document.getElementById('stBox');if(!box||box.getAttribute('data-st')==='1')return;
var card=null;[].slice.call(document.querySelectorAll('.card')).forEach(function(c){if(card||c.id)return;var t=c.querySelector('.title');if(t&&/Internet/.test(t.textContent))card=c;});
if(card){var row=card.querySelector('.row');if(row&&row.parentNode===card)card.insertBefore(box,row.nextSibling);else card.appendChild(box);
if(row){[].slice.call(row.children).forEach(function(c){var x=(c.textContent||'').trim();
if(x==='Ping')c.textContent='Ping 8.8.8.8';
else if((x==='Download'||x==='Download (Ookla)')&&c.nextElementSibling){c.style.display='none';c.nextElementSibling.style.display='none';}});}}
else{var c=el('div','card');c.id='stCard';var tt=el('div','title','🌐 Speedtest');c.appendChild(tt);var src=document.getElementById('srcCard');(src?src.parentNode:document.body).insertBefore(c,src||null);c.appendChild(box);}
box.style.display='';box.setAttribute('data-st','1');
var b=document.getElementById('dlBtn');if(b){b.textContent='⚡ Speedtest jetzt';b.addEventListener('click',function(){setTimeout(function(){var s=document.getElementById('dlStatus');if(s)s.textContent='Speedtest läuft … (bis ~60 s)';},30);setTimeout(function(){poll(0);},1500);});}
try{render(JSON.parse(document.getElementById('stData').textContent));}catch(e){}}
document.addEventListener('DOMContentLoaded',place);setTimeout(place,600);
})();
</script>"""

print("speedTile aktiv", flush=True)
# ===== /speedTile =====

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
    if "stt-v1" in src:
        raise SystemExit("STOP: stt-v1 gibt es schon - nichts geaendert")
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

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-speedtile.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if a.name.split(".")[0] in ("requests", "urllib", "socket", "http", "subprocess", "meshtastic"):
                print("verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        f = node.func
        fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("update_all", "urlopen", "Popen", "system", "remove", "unlink"):
            print("verbotener Aufruf", fn); hit = True
        if fn == "open" and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and any(c in str(node.args[1].value) for c in "wax+"):
            print("Schreib-open im Block"); hit = True
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
        print("data_store-Schreiben"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (Block liest nur, kein Senden, kein Abruf, kein Schreiben)"

# ---------- 1) Trockenlauf ----------
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
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /pi /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /energie=${PRE[/energie]}"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l); P0=$(grep -o 'id=.bakRestorePanel' "$W/pi0.html" | wc -l)
echo "vorher /pi: doPrepperRestore $R0 mal, bakRestorePanel $P0, backupBox $(grep -c 'id=.backupBox' "$W/pi0.html" || true)"

if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK speedTile schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-speedtile-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-speedtile-$TS"
  }
  cp -a "$F" "$F.bak-speedtile-$TS"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    grep -q 'stt-v1' "$W/pi.html" || { rb "/pi ohne speedTile"; exit 1; }
    grep -q 'id=.stBox' "$W/pi.html" && grep -q 'id=.pp2-js' "$W/pi.html" || { rb "/pi ohne stBox/piPolish2"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l); P1=$(grep -o 'id=.bakRestorePanel' "$W/pi.html" | wc -l)
    echo "nachher /pi: doPrepperRestore $R1 mal (vorher $R0), bakRestorePanel $P1 (vorher $P0)"
    [[ "$R1" == "$R0" && "$P1" == "$P0" ]] || { rb "Wiederherstellen-Teile veraendert"; exit 1; }
  fi
  hc=$("${CURL[@]}" "$B/api/speedtest/history?days=14" -o "$W/h.json" -w "%{http_code}" || true)
  [[ "$hc" == "200" ]] || { rb "/api/speedtest/history antwortet nicht ($hc)"; exit 1; }
  "${CURL[@]}" "$B/api/speedtest" -o "$W/s.json" || true
  python3 - "$W/h.json" "$W/s.json" << 'PY' || { rb "speedTile-Daten ungueltig"; exit 1; }
import json, sys
h = json.load(open(sys.argv[1])); s = json.load(open(sys.argv[2]))
assert h.get("ok") and isinstance(h.get("points"), list), h
t = s.get("tile") or {}
assert t.get("v") == 1, "tile fehlt"
by = {}
for p in h["points"]:
    by[p["u"]] = by.get(p["u"], 0) + 1
print("OK Verlauf 14 Tage: %d Messungen %s" % (len(h["points"]), by))
for u, b in sorted((t.get("base") or {}).items()):
    if b:
        print("BASIS %s: %s/%s Mbit/s (%s)" % (u, b.get("down"), b.get("up"), b.get("src")))
c = t.get("col") or {}
nm = {"#22c55e": "gruen", "#eab308": "gelb", "#ef4444": "rot", "#94a3b8": "grau"}
print("AMPEL letzte Messung: " + ", ".join("%s=%s" % (k, nm.get(c.get(k), c.get(k))) for k in ("down", "up", "ping", "dl_lat", "ul_lat", "loss")))
if t.get("hi"):
    print("HOCH/TIEF Download (%s): %s / %s Mbit/s" % (t.get("hilo_scope"), t["hi"]["down"], t["lo"]["down"]))
PY
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'speedTile' | tail -2 || true
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-speedtile-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "OK guards speedTile=$(grep -q '# ===== speedTile:' "$F" && echo 1 || echo 0) speedTest=$(grep -q '# ===== speedTest:' "$F" && echo 1 || echo 0) piPolish2=$(grep -q '# ===== piPolish2:' "$F" && echo 1 || echo 0) piPolish=$(grep -q '# ===== piPolish:' "$F" && echo 1 || echo 0) sdHealth=$(grep -q '# ===== sdHealth:' "$F" && echo 1 || echo 0) sourceWatch=$(grep -q '# ===== sourceWatch:' "$F" && echo 1 || echo 0) firmsKeep=$(grep -q '# ===== firmsKeep:' "$F" && echo 1 || echo 0) longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) priceAllTime=$(grep -q '# ===== priceAllTime:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-speedtile-$TS" ]] && echo "Backup: $F.bak-speedtile-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG speedTile=1"
