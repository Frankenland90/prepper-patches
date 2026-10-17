#!/bin/bash
set -euo pipefail
# kartevec (nach tiiFix2): /karte als eigene Seite im Hauptmenue (Eintrag Karte nach Funk, Raster 4x4); TII-Vektorlinien je Mast alle 5 s
# (/api/t4/tii, dauerhafte Tabelle tii_seen in lagezentrum.db, grau = nie / blau = schon empfangen, aktiv nur bei letzter Pruefung <= 150 s und laufendem Stick,
# Linienstaerke = Schaetzung aus SNR/TII, pulsierend = Ueberreichweite, Funkhorizont nur bei offenem Popup); 41 weitere 11D-Masten mit recherchierter Position
# (ungefaehr; ohne gesicherte Position nur Liste unter der Karte); 5C/10C (Stick 2) laut fmlist 10BC/10AD gegengeprueft; Buettelberg-Koordinate korrigiert.
# Lage-Seite: Kacheln Sticks & Alarm-Automatik, SDR-Status, Ereignis-Historie -> unten auf /funk; Knoepfe Testnachricht + Route /api/lage_test/prepare entfernt.
# Aendert dashboard.py + sdr_manager.py; prepper_sdr.py und database.py bleiben unveraendert. Neustart nur prepper-dashboard. Sendet nichts, Sticks unberuehrt.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
M="$DASH_DIR/prepper_sdr.py"
DBF="$DASH_DIR/database.py"
LZ="$DASH_DIR/lagezentrum.db"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/kartevec-apply
KEEP_LAST=3
KNOWN_D16="4d9d753330fa91ed"     # dashboard.py nach Teil 4
KNOWN_SM16="211a24247de1a770"    # sdr_manager.py nach Teil 4
KNOWN_SDR16="de3fad568616ffb3"   # prepper_sdr.py nach tiiFix2 (bleibt unveraendert)
KNOWN_DB16="c3b138fbe1080373"    # database.py (bleibt unveraendert)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== kartevec apply (Karte TII-Vektorlinien, Menue Karte, 3 Kacheln -> Funk, Testnachricht-Knoepfe weg), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/msbx"
EXPECT_PD="d0d465fa06c626dc0d2d4a36c7e0f9cfe401bb32e57bc2daad3c3ea35916c46c"
cat > "$W/patch-kv-dash.py" << 'KVPD_EOF'
"""kartevec dashboard.py: Block lageTest (Knoepfe 'Testnachricht vorbereiten' + Route /api/lage_test/prepare) entfernen; Kacheln Sticks & Alarm-Automatik,
SDR-Status, Ereignis-Historie von der Lage-Seite ans Ende von /funk (vor Antennentest); Texte Lage-Seite -> Funk-Seite; Block kartevec nach diskTiles.
Aufruf: patch-kv-dash.py ALT NEU BLOCK -> 0 ok (auch wenn schon drin), 1 unbekannte Basis"""
import sys
src, dst, blk = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
LT0, LT1 = "# ===== lageTest: Lage-Seite - Knopf 'Testnachricht vorbereiten'", "# ===== /lageTest =====\n"
ANCH = "# ===== /diskTiles =====\n"
PUT = ("function kvGrid(){var s=document.getElementById('stickTestCard');if(s&&s.parentNode)return s.parentNode;var gs=document.querySelectorAll('.grid'),b=null,bn=-1;"
       "for(var i=0;i<gs.length;i++){var c=0,ch=gs[i].children;for(var j=0;j<ch.length;j++){if(ch[j].classList&&ch[j].classList.contains('card'))c++;}if(c>bn){bn=c;b=gs[i];}}return b;}\n"
       "function kvPut(t,prev){var p=prev?document.getElementById(prev):null;if(p&&p.parentNode){if(p.nextSibling!==t)p.parentNode.insertBefore(t,p.nextSibling);return;}"
       "var g=kvGrid();if(!g){if(!t.parentNode)document.body.appendChild(t);return;}if(t.parentNode!==g){var s=document.getElementById('stickTestCard');"
       "if(s&&s.parentNode===g)g.insertBefore(t,s);else g.appendChild(t);}}\n")
EDITS = (
    ('        return "nur von der Lage-Seite (gleicher Ursprung)", 403\n',
     '        return "nur von der Funk-Seite (gleicher Ursprung)", 403   # kartevec: Knoepfe jetzt auf /funk\n'),
    ('"Knopf auf der Lage-Seite" if act == "alarm" else ""', '"Knopf auf der Funk-Seite" if act == "alarm" else ""'),
    ("function tile(){var n=ninaCard();if(!n||!D)return;var after=document.getElementById('br24Tile')||n;var t=document.getElementById('t2Tile');\n"
     "if(!t){t=el('div',n.className);t.id='t2Tile';",
     PUT + "function tile(){if(!D)return;var t=document.getElementById('t2Tile');\nif(!t){t=el('div','card full');t.id='t2Tile';"),
    ("if(after.nextSibling!==t)after.parentNode.insertBefore(t,after.nextSibling);\nvar to=D.takeover", "kvPut(t,null);\nvar to=D.takeover"),
    ('        if (_t2d_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200',
     '        if (_t2d_rq.path.rstrip("/") or "/") == "/funk" and resp.status_code == 200'),
    ("function sdr(){var a=after();if(!a||!D||!D.sdr)return;var t=document.getElementById('t4Sdr');\nif(!t){t=el('div',(ninaCard()||a).className);t.id='t4Sdr';",
     PUT + "var KV_FUNK=(location.pathname.replace(/\\/+$/,'')==='/funk');\n"
     "function sdr(){if(!D||!D.sdr)return;var t=document.getElementById('t4Sdr');\nif(!t){t=el('div','card full');t.id='t4Sdr';"),
    ("if(a.nextSibling!==t)a.parentNode.insertBefore(t,a.nextSibling);\nvar s1=", "kvPut(t,'t2Tile');\nvar s1="),
    ("if(!t){t=el('div',a.className);t.id='t4Hist';", "if(!t){t=el('div','card full');t.id='t4Hist';"),
    ("if(a.nextSibling!==t)a.parentNode.insertBefore(t,a.nextSibling);\nvar h=D.hist", "kvPut(t,'t4Sdr');\nvar h=D.hist"),
    ("function draw(){lage();sdr();hist();}", "function draw(){lage();if(KV_FUNK){sdr();hist();}}"),
    ('        if (_t4_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200',
     '        if (_t4_rq.path.rstrip("/") or "/") in ("/", "/funk") and resp.status_code == 200'),
    (".t4-l{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px}\n</style>",
     ".t4-l{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px}\n"
     "#t2Tile,#t4Sdr,#t4Hist{grid-column:1/-1;min-width:0;max-width:100%;box-sizing:border-box}\n</style>"),
)
bad = []
done = s.count("# ===== kartevec:") == 1
if not done:
    if s.count(LT0) != 1 or s.count(LT1) != 1 or s.count(ANCH) != 1 or s.count("# ===== kartevec:") != 0:
        bad.append("Basis: lageTest/diskTiles-Marken nicht eindeutig")
    else:
        i, j = s.index(LT0), s.index(LT1) + len(LT1)
        if i >= j or s.rfind("\n", 0, i) != i - 1:
            bad.append("lageTest-Block nicht am Zeilenanfang")
        s = s[:i] + s[j:]
        for old, new in EDITS:
            if s.count(old) != 1 or new in s:
                bad.append("Stelle nicht eindeutig: %s" % old.strip().splitlines()[0][:70])
                continue
            s = s.replace(old, new, 1)
        if not bad:
            k = s.index(ANCH) + len(ANCH)
            s = s[:k] + B + s[k:]
else:
    if LT0 in s or LT1 in s or s.count(B) != 1 or s.index(B) != s.index(ANCH) + len(ANCH):
        bad.append("kartevec teilweise/anders vorhanden")
    s2 = s.replace(B, "", 1)
    for old, new in EDITS:
        if s2.count(new) != 1 or old in s2:
            bad.append("kartevec-Stelle fehlt: %s" % new.strip().splitlines()[0][:70])
if bad:
    print("; ".join(bad)); raise SystemExit(1)
open(dst, "w", encoding="utf-8").write(s)
print("dashboard: lageTest entfernt, 3 Kacheln -> /funk, %d Stellen, Block kartevec" % len(EDITS))
KVPD_EOF
EXPECT_PM="d5d3df4f75c336c48937cbddc873ba3c9f85b55c69705a4677c57f5788f9f8e2"
cat > "$W/patch-kv-sm.py" << 'KVPM_EOF'
"""kartevec sdr_manager.py: Buettelberg-Koordinaten in T4_MASTS (Wikipedia 49.4146/10.3780) + Block kartevec vor dem Hauptteil + selftest_kv im Hauptteil.
Aufruf: patch-kv-sm.py ALT NEU BLOCK -> 0 ok (auch wenn schon drin), 1 unbekannte Basis"""
import sys
src, dst, blk = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read()
OLD_B = '    {"id": "buettelberg", "name": "Büttelberg (Frankenhöhe)", "lat": 49.4070, "lon": 10.4030, "site_m": 527, "ant_m": 159, "tii": {"11D": "0515", "5C": "1212"}},\n'
NEW_B = '    {"id": "buettelberg", "name": "Büttelberg (Frankenhöhe)", "lat": 49.4146, "lon": 10.3780, "site_m": 527, "ant_m": 159, "tii": {"11D": "0515", "5C": "1212"}},   # kartevec: Wikipedia Sender Buettelberg\n'
MAIN0 = '\n\nif __name__ == "__main__":\n    print(selftest())\n    print(selftest_t2())\n    print(selftest_t4())\n'
MAIN1 = '\n\nif __name__ == "__main__":\n    print(selftest())\n    print(selftest_t2())\n    print(selftest_t4())\n    print(selftest_kv())\n'
HEAD = "\n\n# ---------------------------------------------------------------- kartevec"
bad = []
if s.count(HEAD) == 0:
    if s.count(OLD_B) != 1 or not s.endswith(MAIN0) or s.count(MAIN0) != 1:
        bad.append("Basis: Buettelberg-Zeile oder Hauptteil nicht wie erwartet")
    else:
        s = s.replace(OLD_B, NEW_B, 1)
        s = s[:-len(MAIN0)] + B.rstrip("\n") + "\n" + MAIN1
elif s.count(HEAD) != 1 or s.count(NEW_B) != 1 or not s.endswith(MAIN1) or B.rstrip("\n") + "\n" + MAIN1 not in s:
    bad.append("kartevec teilweise/anders vorhanden")
if bad:
    print("; ".join(bad)); raise SystemExit(1)
open(dst, "w", encoding="utf-8").write(s)
print("sdr_manager: Buettelberg + Block kartevec + selftest_kv")
KVPM_EOF
EXPECT_BD="aaf28f63317b4a602ec9bb915b35aae812d997874bdd92172405945cfa01af82"
cat > "$W/dash_kv_block.py" << 'KVBD_EOF'
# ===== kartevec: /karte eigene Seite im Hauptmenue (Karte nach Funk, Raster 4x4); TII-Vektorlinien je Mast alle 5 s (/api/t4/tii, tii_seen dauerhaft, grau nie / blau schon empfangen, aktiv <= 150 s + Stick laeuft, pulsierend = Ueberreichweite, Funkhorizont nur bei offenem Popup); nur Lesen, sendet nichts =====
import re as _kv_re

KV_NAV_CSS0 = ".nav-unify .nr{display:grid!important;grid-template-columns:repeat(5,minmax(0,1fr));"
KV_NAV_CSS1 = ".nav-unify .nr{display:grid!important;grid-template-columns:repeat(4,minmax(0,1fr));"
KV_NAV_RE = _kv_re.compile(r'<div class="nav-unify" id="navUnify">((?:<div class="nr">(?:(?!</div>).)*</div>)+)</div>', _kv_re.S)
KV_NAV_A = _kv_re.compile(r"<a\b[^>]*>.*?</a>", _kv_re.S)
KV_NAV_KARTE = '<a href="/karte">Karte</a>'


KV_NAV_OLD = _kv_re.compile(r'<div class="nav">(?:(?!</div>).)*</div>', _kv_re.S)
KV_FUNK_A = '<a href="/funk">Funk</a>'


def _kv_nav(body):
    """Hauptmenue: Eintrag Karte direkt nach Funk. Einheitliches Menue: Raster 4 Spalten (16 Eintraege = 4 x 4); aeltere Zeilen-Menues
    (z. B. /funk): Karte nach Funk in derselben Zeile. Schon drin -> unveraendert."""
    o = KV_NAV_OLD.search(body)
    if o and KV_FUNK_A in o.group(0) and 'href="/karte"' not in o.group(0):
        body = body[:o.start()] + o.group(0).replace(KV_FUNK_A, KV_FUNK_A + " " + KV_NAV_KARTE, 1) + body[o.end():]
    m = KV_NAV_RE.search(body)
    if not m or 'href="/karte"' in m.group(1):
        return body
    links = KV_NAV_A.findall(m.group(1))
    if not links:
        return body
    i = next((k for k, a in enumerate(links) if 'href="/funk"' in a), len(links) - 1)
    links.insert(i + 1, KV_NAV_KARTE)
    rows = "".join('<div class="nr">%s</div>' % "".join(links[k:k + 4]) for k in range(0, len(links), 4))
    body = body[:m.start()] + '<div class="nav-unify" id="navUnify">' + rows + "</div>" + body[m.end():]
    return body.replace(KV_NAV_CSS0, KV_NAV_CSS1, 1) if len(links) % 4 == 0 else body


def _kv_nav_after(resp):
    try:
        if resp.status_code != 200 or resp.direct_passthrough or (resp.mimetype or "") != "text/html" or resp.headers.get("Content-Encoding"):
            return resp
        body = resp.get_data(as_text=True)
        if 'id="navUnify"' not in body and '<div class="nav">' not in body:
            return resp
        b2 = _kv_nav(body)
        if b2 != body:
            resp.set_data(b2)
    except Exception as e:
        print("kartevec Menue:", e, flush=True)
    return resp


def _kv_api():
    from flask import jsonify
    try:
        base, path = _t4_paths()
        return jsonify(_lz_mgr.kv_status(base, path))
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120], "masts": [], "nopos": [], "unknown": [], "ch": {}})


_KV_JS = r"""
(function(){var V=null,Z=null,T=null,map=null,ZL=null,ML={},LL={},HC=null,OPEN=null;
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function n(v,d){return (v===null||v===undefined)?'–':Number(v).toFixed(d).replace('.',',');}
function ft(t){if(!t)return '–';var s=new Date(t*1000).toLocaleString('de-DE',{timeZone:'Europe/Berlin',day:'2-digit',month:'2-digit',year:'numeric',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false});return s.replace(',','');}
function age(s){return s==null?'–':(s<120?s+' s':Math.round(s/60)+' min');}
var CC={'11D':'#7dd3fc','5C':'#ef4444','10C':'#f97316'},GREY='#94a3b8',BLUE='#3b82f6';
function cls(l,on){var e=l&&l.getElement?l.getElement():(l&&l._path);if(!e)return;if(on){if(e.classList)e.classList.add('kv-pulse');}else if(e.classList)e.classList.remove('kv-pulse');}
function init(){T=JSON.parse(document.getElementById('kv-tiles').textContent||'{}');var info=document.getElementById('kvInfo');
if(typeof L==='undefined'){info.textContent='Leaflet fehlt (static/leaflet) – apply-teil4.sh erneut ausführen';return;}
var h=(V&&V.home)||{lat:49.55782283,lon:11.15501383,name:'Kalchreuth (Empfänger)',h_m:431.7};map=L.map('kvmap',{zoomControl:true,minZoom:3,maxZoom:13}).setView([h.lat,h.lon],8);
var blank='data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
var att=T.attribution_html||'Kacheln fehlen – prepper-tiles-teil4.sh ausführen';
L.tileLayer('/karte/res/tiles/{z}/{x}/{y}.png',{maxNativeZoom:T.z_wide||10,maxZoom:13,minZoom:0,attribution:att,errorTileUrl:blank}).addTo(map);
var dn=(T.r_near_km||60)/111.32,de=(T.r_near_km||60)/(111.32*Math.cos(h.lat*Math.PI/180));
L.tileLayer('/karte/res/tiles/{z}/{x}/{y}.png',{minZoom:(T.z_wide||10)+1,maxZoom:13,maxNativeZoom:T.z_near||13,bounds:[[h.lat-dn,h.lon-de],[h.lat+dn,h.lon+de]],errorTileUrl:blank}).addTo(map);
ZL=L.layerGroup().addTo(map);
L.circleMarker([h.lat,h.lon],{radius:7,color:'#22c55e',fillColor:'#22c55e',fillOpacity:.9}).bindPopup('<b>'+esc(h.name)+'</b><br>'+n(h.lat,5)+', '+n(h.lon,5)+' · '+n(h.h_m,1)+' m ü. NN').addTo(map);
map.on('popupclose',function(){if(HC){map.removeLayer(HC);HC=null;}OPEN=null;});
info.textContent=T.have?('Offline-Kacheln ('+(T.date||'?')+') · TII alle 5 s'):'Offline-Kacheln fehlen – prepper-tiles-teil4.sh ausführen';draw();zones();}
function pop(m){var r='<b>'+esc(m.name)+'</b>'+(m.ever?' <span style="color:'+BLUE+'">● schon empfangen</span>':' <span style="color:'+GREY+'">● noch nie bestätigt empfangen</span>');
r+='<br>Distanz '+n(m.dist_km,1)+' km · Funkhorizont D '+n(m.D_km,1)+' km'+(m.dist_km!=null&&m.D_km!=null?(m.dist_km>m.D_km?' · <b style="color:#f97316">Überreichweite</b> (Distanz > D)':' · innerhalb D'):'');
r+='<br>Höhe '+(m.h_m==null?'–':m.h_m+' m ü. NN ('+m.site_m+' m + Antenne '+m.ant_m+' m)')+' · ERP '+(m.erp_kw==null?'–':n(m.erp_kw,1)+' kW');
for(var i=0;i<m.ch.length;i++){var c=m.ch[i];r+='<hr style="border:0;border-top:1px solid #334155;margin:4px 0"><b style="color:'+(CC[c.ch]||GREY)+'">'+esc(c.ch)+'</b> TII '+esc(c.tii_txt)+': '+(c.active?'<b>aktiv</b>':(c.ever?'schon empfangen, gerade nicht':(c.seen_unconfirmed?'nur vereinzelt gesehen (nicht bestätigt)':'nie empfangen')));
r+='<br>zuletzt '+ft(c.last_t)+' · '+c.n+'× gesehen'+(c.max_run?' · max. '+c.max_run+' Prüfungen in Folge':'')+(c.stable?' · stabil':'');
r+='<br>SNR '+n(c.snr,1)+' dB · FIC '+n(c.fic_rate,4)+' · TII-Fehler '+n(c.last_err,1)+(c.best_err!=null?' (bester '+n(c.best_err,1)+')':'')+' · TII-Verzögerung '+n(c.last_km,1)+' km'+(c.q!=null?' · Signal ≈ '+Math.round(c.q*100)+' %':'');}
r+='<br><span style="opacity:.75">kein RSSI je Mast (welle-cli liefert keinen Pegel je Sender) – Signal = Schaetzung aus SNR/TII<br>Position ungefähr: '+esc(m.geo_src||'?')+'</span>';return r;}
function horizon(m){if(HC){map.removeLayer(HC);HC=null;}if(m.D_km){HC=L.circle([m.lat,m.lon],{radius:m.D_km*1000,color:m.ever?BLUE:GREY,weight:1,opacity:.6,fill:false,dashArray:'6 6',interactive:false}).addTo(map);}}
function draw(){if(!map||!V||!V.masts)return;var h=V.home,ms=V.masts,keep={},lk={};
for(var i=0;i<ms.length;i++){(function(m){var k=m.id;keep[k]=1;var col=m.ever?BLUE:GREY,mk=ML[k];
if(!mk){mk=L.circleMarker([m.lat,m.lon],{radius:5,weight:2});mk.bindPopup('',{maxWidth:320});mk.on('popupopen',function(){OPEN=k;if(mk._m)horizon(mk._m);});mk.addTo(map);ML[k]=mk;}
mk._m=m;mk.setLatLng([m.lat,m.lon]);mk.setStyle({color:m.active?'#e2e8f0':col,fillColor:col,fillOpacity:m.ever?0.9:0.35,radius:m.active?8:(m.ever?6:5)});
var p=pop(m);if(mk._p!==p){mk._p=p;mk.setPopupContent(p);}cls(mk,m.overreach);if(OPEN===k&&HC&&m.D_km)HC.setRadius(m.D_km*1000);
for(var j=0;j<m.ch.length;j++){var c=m.ch[j],key=k+'|'+c.ch;if(!c.active)continue;lk[key]=1;var q=c.q==null?0.15:Math.max(0.15,c.q),ln=LL[key];
if(!ln){ln=L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{interactive:false}).addTo(map);LL[key]=ln;if(mk.bringToFront)mk.bringToFront();}
ln.setStyle({color:CC[c.ch]||'#7dd3fc',weight:1+6*q,opacity:.3+.65*q});cls(ln,m.overreach);}})(ms[i]);}
for(var k in LL){if(!lk[k]){map.removeLayer(LL[k]);delete LL[k];}}
for(var k in ML){if(!keep[k]){if(OPEN===k&&HC){map.removeLayer(HC);HC=null;}map.removeLayer(ML[k]);delete ML[k];}}
legend();}
function zones(){if(!map||!ZL||!Z)return;ZL.clearLayers();
var zs=Z.zones||[];for(var i=0;i<zs.length;i++){var z=zs[i],g=z.geometry||{},p='<b>'+esc(z.source)+'</b>: '+esc(z.headline)+(z.approx?'<br>Gebiet ungefähr':'');
if(g.type==='Point'&&g.coordinates){L.circle([g.coordinates[1],g.coordinates[0]],{radius:z.radius_m||3000,color:'#ef4444',weight:2,fillColor:'#ef4444',fillOpacity:.18}).bindPopup(p).addTo(ZL);}
else if(g.type){L.geoJSON(g,{style:{color:'#ef4444',weight:2,fillColor:'#ef4444',fillOpacity:.18}}).bindPopup(p).addTo(ZL);}}
var rs=Z.roads||[];for(var i=0;i<rs.length;i++){var z=rs[i],g=z.geometry||{},ll=null;if(g.type==='Point')ll=[g.coordinates[1],g.coordinates[0]];else if(g.type){try{ll=L.geoJSON(g).getBounds().getCenter();}catch(e){}}
if(ll)L.marker(ll,{icon:L.divIcon({className:'t4-tri',html:'▲',iconSize:[22,22]})}).bindPopup('<b>Straßensperre</b> ('+esc(z.source)+'): '+esc(z.headline)).addTo(ZL);}legend();}
function legend(){var lg=document.getElementById('kvLeg');if(!lg||!V)return;var x='',c11=(V.ch||{})['11D']||{},na=0,ne=0;
for(var i=0;i<(V.masts||[]).length;i++){if(V.masts[i].active)na++;if(V.masts[i].ever)ne++;}
for(var ch in (V.ch||{})){var c=V.ch[ch];if(!c.fig_t&&ch!=='11D')continue;x+='<div><b style="color:'+(CC[ch]||GREY)+'">'+esc(ch)+'</b>: '+(c.stick_ok?'':'<b style="color:#f97316">'+esc(c.stick_why)+'</b> · ')+'letzte TII-Prüfung '+(c.fig_t?ft(c.fig_t)+' (vor '+age(c.age_s)+')':'–')+(c.fresh?'':' · älter als '+V.active_s+' s – keine Linie')+' · SNR '+n(c.snr,1)+' dB · TII '+esc((c.tii||[]).join(', ')||'–')+'</div>';}
x+='<div>'+na+' Masten aktiv · '+ne+' schon empfangen · '+(V.masts||[]).length+' mit Position gezeichnet</div>';
x+='<div style="margin-top:4px"><b>Legende</b>: Linie = Mast in der letzten TII-Prüfung (≤ '+V.active_s+' s, Stick läuft) · Stärke/Deckkraft: <b>'+esc(V.legend)+'</b> (SNR 0–25 dB, je Mast abgeschwächt nach TII-Fehler) · Linienfarbe 11D hellblau, 5C rot, 10C orange · ● grau = nie bestätigt empfangen · ● blau = schon empfangen (≥ '+V.ever_run+' Prüfungen in Folge oder stabil, bleibt) · weißer Rand = aktiv · pulsierend = Überreichweite (Distanz > Funkhorizont D) · gestrichelter Kreis = Funkhorizont D des Masts (nur bei offenem Popup) · rot = Gefahrenzone · ▲ = Straßensperre</div>';
if(Z&&(Z.nogeo||[]).length){x+='<div><b>Ohne Ort</b>: ';for(var i=0;i<Z.nogeo.length;i++)x+=(i?' · ':'')+esc(Z.nogeo[i].source)+': '+esc(Z.nogeo[i].headline)+(Z.nogeo[i].road?' (Sperre)':'');x+='</div>';}
var np=V.nopos||[];if(np.length){x+='<div style="margin-top:4px"><b>Ohne gesicherte Position – nicht gezeichnet ('+np.length+')</b>: ';for(var i=0;i<np.length;i++){var m=np[i],cs=(m.ch||[]).map(function(c){return c.ch+' '+c.tii_txt+(c.n?' '+c.n+'×':'');}).join(', ');x+=(i?' · ':'')+'<span style="color:'+(m.ever?BLUE:'#cbd5e1')+'">'+esc(m.name)+'</span> ('+esc(cs)+(m.km_fmlist!=null?', ca. '+m.km_fmlist+' km':'')+')';}x+='</div>';}
var uk=V.unknown||[];if(uk.length){x+='<div style="margin-top:4px"><b>TII nicht in MASTS_DB – nie gezeichnet</b>: ';for(var i=0;i<uk.length;i++){var u=uk[i];x+=(i?' · ':'')+esc(u.ch)+' '+esc(u.tii_txt)+' ('+u.n+'×, zuletzt '+ft(u.last_t)+', Fehler '+n(u.last_err,0)+')';}x+='</div>';}
x+='<div style="opacity:.7;margin-top:4px">'+esc(V.note)+'<br>Funkhorizont: '+esc((Z&&Z.formula)||'')+'<br>Positionen: '+esc(V.src)+(Z&&Z.src?'<br>Masten Teil 4: '+esc(Z.src):'')+'</div>';
if(lg._x!==x){lg._x=x;lg.innerHTML=x;}}
function load(){fetch('/api/t4/tii',{credentials:'same-origin',cache:'no-store'}).then(function(r){return r.json();}).then(function(j){if(j&&j.masts){V=j;draw();}}).catch(function(){});}
function loadZ(){fetch('/api/t4/map',{credentials:'same-origin',cache:'no-store'}).then(function(r){return r.json();}).then(function(j){if(j&&j.zones){Z=j;zones();}}).catch(function(){});}
try{V=JSON.parse(document.getElementById('kv-data').textContent);}catch(e){}
try{Z=JSON.parse(document.getElementById('kv-zones').textContent);}catch(e){}
init();setInterval(load,5000);setInterval(loadZ,30000);})();
"""


def _kv_karte():
    from flask import Response
    base, path = _t4_paths()
    try:
        d = _sdr_json.dumps(_lz_mgr.kv_status(base, path), ensure_ascii=False, default=str).replace("<", "\\u003c")
    except Exception as e:
        print("kartevec Karte:", e, flush=True)
        d = "null"
    try:
        z = _sdr_json.dumps(_lz_mgr.t4_map(base, path), ensure_ascii=False, default=str).replace("<", "\\u003c")
    except Exception as e:
        print("kartevec Karte Zonen:", e, flush=True)
        z = "null"
    ti = _sdr_json.dumps(_t4_tiles_info(), ensure_ascii=False).replace("<", "\\u003c")
    html = (globals().get("NAV_UNIFY") or "") + """
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>Karte</title><link rel="stylesheet" href="/karte/res/leaflet/leaflet.css">
<style>body{margin:0;background:#0f172a;color:#e2e8f0;font-family:system-ui,-apple-system,sans-serif}
.kv-h{padding:6px 10px;font-size:.9rem;font-weight:600}.kv-h small{font-weight:400;color:#94a3b8;margin-left:6px}
#kvmap{height:calc(100vh - 210px);min-height:340px;margin:0 6px;border-radius:10px;border:1px solid #334155;background:#1e293b}
#kvLeg{padding:8px 10px;font-size:.75rem;color:#cbd5e1;line-height:1.45}#kvLeg div{margin-top:2px}
.leaflet-container{background:#1e293b}.leaflet-popup-content{font-size:.8rem;line-height:1.35}
.kv-pulse{animation:kvp 1.4s ease-in-out infinite}
@keyframes kvp{0%{stroke-opacity:1;stroke-width:3px}50%{stroke-opacity:.25;stroke-width:10px}100%{stroke-opacity:1;stroke-width:3px}}
.t4-tri{color:#f97316;font-size:20px;line-height:22px;text-align:center;text-shadow:0 0 3px #000}
</style></head><body>
<div class="kv-h">🗺 Karte Kalchreuth – DAB-Masten per TII <small id="kvInfo"></small></div>
<div id="kvmap"></div><div id="kvLeg"></div>
<script type="application/json" id="kv-data">""" + d + """</script><script type="application/json" id="kv-zones">""" + z + """</script>
<script type="application/json" id="kv-tiles">""" + ti + """</script>
<script src="/karte/res/leaflet/leaflet.js"></script><script id="kv-js">""" + _KV_JS + """</script>
</body></html>"""
    return Response(html, mimetype="text/html")


def _kv_selftest():
    import tempfile
    nav = (globals().get("NAV_UNIFY") or "") + "<p>x</p>"
    n1 = _kv_nav(nav)
    m = KV_NAV_RE.search(n1)
    rows = _kv_re.findall(r'<div class="nr">(.*?)</div>', m.group(1)) if m else []
    hr = [_kv_re.findall(r'href="([^"]+)"', r) for r in rows]
    assert len(hr) == 4 and all(len(r) == 4 for r in hr) and hr[3][:2] == ["/funk", "/karte"], hr
    assert KV_NAV_CSS1 in n1 and KV_NAV_CSS0 not in n1 and _kv_nav(n1) == n1 and n1.count(KV_NAV_KARTE) == 1     # idempotent
    assert _kv_nav("<div>ohne Menue</div>") == "<div>ohne Menue</div>"
    o1 = _kv_nav('<div class="nav">\n  <a href="/mesh">Mesh 1</a> <a href="/funk">Funk</a> <a href="/pi">System</a>\n</div><a href="/funk">Funk</a>')
    assert o1 == '<div class="nav">\n  <a href="/mesh">Mesh 1</a> <a href="/funk">Funk</a> <a href="/karte">Karte</a> <a href="/pi">System</a>\n</div><a href="/funk">Funk</a>' and _kv_nav(o1) == o1, o1
    for k in ("setInterval(load,5000)", "removeLayer", "setStyle", "kv-pulse", "popupopen", "popupclose", "Schaetzung aus SNR/TII", "/api/t4/tii", "kein RSSI je Mast"):
        assert k in _KV_JS, k
    assert "method:'POST'" not in _KV_JS and "/send" not in _KV_JS
    # Kacheln auf /funk, nicht mehr auf der Lage-Seite; Lage-Seite nur noch Ampel
    assert "kvPut(t,null)" in _T2D_JS and "kvPut(t,'t2Tile')" in _T4_JS and "kvPut(t,'t4Sdr')" in _T4_JS and "function draw(){lage();if(KV_FUNK){sdr();hist();}}" in _T4_JS
    assert any("nur von der Funk-Seite" in str(c) for c in _t2d_check.__code__.co_consts) and "lt_prepare" not in app.view_functions
    assert not any("/api/lage_test" in str(r.rule) for r in app.url_map.iter_rules())
    assert "_lt_prepare_post" not in globals() and "lt-btn" not in (globals().get("_LM1_JS") or "")
    # Daten: Testverzeichnis, nichts gesendet
    d = tempfile.mkdtemp()
    p = _t4_os.path.join(d, "lagezentrum.db")
    s = _lz_mgr.kv_status(d, p, 1790000000)
    assert s["ok"] and s["legend"] == "Schaetzung aus SNR/TII" and len(s["masts"]) + len(s["nopos"]) == len(_lz_mgr.T4_MASTS) and not any(x["active"] for x in s["masts"]), s
    return "kartevec selftest ok (Menue 4x4 mit Karte nach Funk, idempotent, Karte 5 s je Mast removeLayer/setStyle/pulsierend, Kacheln auf /funk, Testnachricht-Route weg)"


try:
    if not _T4.get("ok") or _lz_mgr is None or not hasattr(_lz_mgr, "kv_status"):
        raise RuntimeError("Teil 4 nicht aktiv oder sdr_manager.py ohne kartevec (%s)" % (_T4.get("err") or "alt"))
    _KV_ST = _kv_selftest()
    if "kv_tii" not in app.view_functions:
        app.add_url_rule("/api/t4/tii", endpoint="kv_tii", view_func=_kv_api, methods=["GET"])
    app.view_functions["t4_karte"] = _kv_karte
    if not any(getattr(f, "__name__", "") == "_kv_nav_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_kv_nav_after)
    print("kartevec aktiv: %s; Masten %d (MASTS_DB 11D + 5C/10C)" % (_KV_ST, _lz_mgr.kv_status(*_t4_paths(), update=False).get("n_masts", 0)), flush=True)
except Exception as _kv_e:
    print("kartevec FEHLER (alte Karte aktiv):", _kv_e, flush=True)
# ===== /kartevec =====
KVBD_EOF
EXPECT_BM="094bf83fe4558048c247397b67fdfc487e13f215e95014f650756e4d92b3d226"
cat > "$W/sm_kv_block.py" << 'KVBM_EOF'


# ---------------------------------------------------------------- kartevec (TII-Vektorlinien /karte: tii_seen dauerhaft, aktiv je Mast, 11D + 5C/10C)
# Liest broadcast_state.json, sdr_status.json und Telemetrie kind 'fig' aus lagezentrum.db; schreibt NUR die eigenen Tabellen tii_seen/tii_seen_meta.
# Kein Netz, keine Sticks, keine Prozesse, nichts wird gesendet. Signal je Mast = Schaetzung aus SNR (Kanal) und TII-Fehler (welle-cli liefert keinen Pegel je Mast).
# Schon empfangen (blau, dauerhaft) = Kennung aus MASTS_DB/T4_MASTS UND (in >= 2 Pruefungen nacheinander ODER im stabilen TII-Satz von prepper-sdr):
# einzelne Treffer mit hohem Fehler (z. B. 00/18, 04/18, 13/18, 15/14, 25/14, 38/18 mit 1-5 Treffern) sind meist Fehldeutungen derselben Kamm-Nummer.
# Kennungen ausserhalb MASTS_DB werden nie gezeichnet, nur gezaehlt und unter der Karte gelistet.
import threading as _kv_threading

KV_ACTIVE_S = 150              # aktiv = in der letzten TII-Pruefung, Pruefung hoechstens 150 s alt, Stick laeuft
KV_EVER_RUN = 2                # schon empfangen ab 2 Pruefungen in Folge (oder stabiler Satz)
KV_SNR_MAX = 25.0              # SNR 0-25 dB -> 0-1
KV_ERR_HALF = 300.0            # TII-Fehler 0 -> voll, >= 300 -> halbe Staerke
KV_POLL_S = 5
KV_BACKFILL_S = 48 * 3600      # Telemetrie fig wird 48 h behalten
KV_GEO_11D = {                 # kartevec: Koordinaten (ungefaehr) der 11D-Masten ohne lat/lon in MASTS_DB, recherchiert 17.10.2026
    "0706": (49.51255, 11.59309, "OpenStreetMap (Overpass) Funkmast 40 m bei Ernhuell, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Weigendorf (Ernhüll)
    "0803": (49.75433, 11.55942, "OpenStreetMap (Overpass) Funkmast auf dem Gunzerberg, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Pegnitz (Gunzerberg)
    "0810": (49.79494, 10.61092, "Wikipedia (de, Artikelkoordinate) Sender Burgwindheim"),   # Burgwindheim
    "0505": (49.04379, 11.01065, "OpenStreetMap (Overpass) Funkmast auf dem Rohrberg, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Weißenburg (Rohrberg)
    "0808": (50.10043, 11.46980, "OpenStreetMap (Overpass) Gipfel Rehberg (Rehturm), Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Kulmbach (Rehberg)
    "0618": (50.01886, 10.59943, "OpenStreetMap (Overpass) Turm Schleifberg, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Zeil am Main (Schleifberg)
    "0621": (50.10880, 10.73589, "OpenStreetMap (Overpass) Funkmast auf dem Haubeberg, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Ebern (Haubeberg)
    "0506": (48.95758, 10.90142, "OpenStreetMap (Overpass) Funkmast Schlossberg, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Treuchtlingen (Schloßberg)
    "0105": (48.94641, 11.42876, "Wikipedia (de, Artikelkoordinate) Sender Gelbelsee"),   # Gelbelsee
    "0104": (48.90125, 11.16175, "OpenStreetMap (Overpass) Sender Schoenblick, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Eichstätt (Schönblick)
    "0806": (50.21371, 11.33228, "OpenStreetMap (Overpass) Fernsehturm bei Kronach, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Kronach
    "0617": (49.85780, 10.16389, "OpenStreetMap (Overpass) Funkmast bei Escherndorf, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Volkach (Escherndorf)
    "0807": (50.25312, 10.98483, "Wikipedia (de, Artikelkoordinate) Sender Coburg-Eckardtsberg"),   # Coburg (Eckardtsberg)
    "0616": (50.03303, 10.30288, "OpenStreetMap (Overpass) Sender Schonungen (Betreiber BR), Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Schweinfurt (A70/Weyer)
    "0619": (49.78054, 9.90628, "Wikipedia (de, Artikelkoordinate) Frankenwarte, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Würzburg (Frankenwarte/BR)
    "0407": (48.90296, 11.86953, "OpenStreetMap (Overpass) Umsetzer Hohenpfahl, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Kelheim (Hohenpfahl)
    "0310": (48.78554, 10.66821, "Wikipedia (de, Artikelkoordinate) Sender Huehnerberg (Schwaben)"),   # Hühnerberg
    "0708": (49.50817, 12.57664, "OpenStreetMap (Overpass) Funkmast auf dem Drechselberg, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Schönsee (Drechselberg)
    "0805": (50.49502, 11.36782, "Wikipedia (de, Artikelkoordinate) Sender Ebersdorf, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Ludwigsstadt-Ebersdorf
    "0607": (50.13624, 9.93173, "OpenStreetMap (Overpass) Sendemast bei Westheim (137 m), Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Hammelburg (Westheim)
    "0112": (48.54321, 11.43134, "Wikipedia (de, Artikelkoordinate) Sender Pfaffenhofen (Ilm)"),   # Pfaffenhofen (Wolfsberg)
    "0620": (49.93281, 9.24084, "Wikipedia (de, Artikelkoordinate) Sender Pfaffenberg (Spessart), Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Pfaffenberg
    "0421": (48.76062, 12.33486, "Wikipedia (de, Artikelkoordinate) Fernmeldeturm Hofkirchen, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Mallersdorf (Hofkirchen)
    "0622": (49.75667, 9.52305, "Wikipedia (de, Artikelkoordinate) Sender Wertheim (Schlossberg)"),   # Wertheim (Schloßberg)
    "0615": (50.42690, 10.21500, "OpenStreetMap (Overpass) Heidelbergturm, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Ostheim (Heidelberg)
    "0606": (50.36944, 9.98051, "Wikipedia (de, Artikelkoordinate) Sender Kreuzberg"),   # Kreuzberg (Rhön)
    "0604": (50.14983, 9.66741, "Wikipedia (de, Artikelkoordinate) Sender Burgsinn, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Burgsinn
    "0411": (48.56930, 12.11271, "Wikipedia (de, Artikelkoordinate) Sender Altdorf, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Landshut (Altdorf)
    "0721": (49.24911, 12.89096, "Wikipedia (de, Artikelkoordinate) Sender Hoher Bogen"),   # Hoher Bogen
    "0306": (48.35940, 10.88585, "Wikipedia (de, Artikelkoordinate) Augsburger Hotelturm"),   # Augsburg (Hotelturm)
    "0602": (49.68381, 9.27231, "Wikipedia (de, Artikelkoordinate) Sender Miltenberg-Wenschdorf"),   # Miltenberg (Wenschdorf)
    "0402": (48.92750, 13.02790, "Wikipedia (de, Artikelkoordinate) Einoedriegel (Gipfel), Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Einödriegel
    "0207": (48.25000, 11.75200, "Wikipedia (de, Artikelkoordinate) Sender Ismaning"),   # München (Ismaning)
    "0201": (48.18782, 11.62765, "OpenStreetMap (Overpass) BR Gittermast Freimann, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # München-Freimann
    "0208": (48.17444, 11.55361, "Wikipedia (de, Artikelkoordinate) Olympiaturm"),   # München (Olympiaturm)
    "0309": (48.38197, 9.94867, "Wikipedia (de, Artikelkoordinate) Sender Ulm-Kuhberg"),   # Ulm (Kuhberg)
    "0106": (48.13196, 11.22405, "OpenStreetMap (Overpass) Fernmeldeturm Schoengeising, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Fürstenfeldbruck (Schöngeising)
    "0608": (50.07863, 9.11000, "Wikipedia (de, Artikelkoordinate) Sender Alzenau-Hahnenkamm"),   # Alzenau (Hahnenkamm BR)
    "0420": (48.81696, 13.21758, "Wikipedia (de, Artikelkoordinate) Sender Brotjacklriegel"),   # Brotjacklriegel
    "0419": (48.40527, 12.88599, "Wikipedia (de, Artikelkoordinate) Sender Pfarrkirchen, Gelaendehoehe passt zu fmlist (EU-DEM)"),   # Pfarrkirchen (Postmünster)
    "0103": (47.80110, 11.02458, "Wikipedia (de, Artikelkoordinate) Sender Hohenpeissenberg"),   # Hohenpeißenberg
}
KV_GEO_SRC = ("Koordinaten ungefaehr (etwa 0,1-1 km): Wikipedia-Senderartikel (de, Artikelkoordinate) oder OpenStreetMap-Sendemast (Overpass), "
              "jeweils mit Gelaendehoehe (EU-DEM 25 m) gegen die fmlist-Standorthoehe geprueft, Abruf 17.10.2026; ohne gesicherte Position nicht gezeichnet")
_KV_LOCK = _kv_threading.Lock()
_KV = {"err": None, "t": 0}
_KV_SQL = ("CREATE TABLE IF NOT EXISTS tii_seen (ch TEXT NOT NULL, code TEXT NOT NULL, first_t INTEGER, last_t INTEGER, n INTEGER DEFAULT 0, "
           "best_err REAL, last_err REAL, last_km REAL, run INTEGER DEFAULT 0, max_run INTEGER DEFAULT 0, stable INTEGER DEFAULT 0, PRIMARY KEY (ch, code))",
           "CREATE TABLE IF NOT EXISTS tii_seen_meta (ch TEXT PRIMARY KEY, last_t INTEGER, prev TEXT)")


def kv_code(main, sub):
    return "%02d%02d" % (int(main), int(sub))


def kv_txt(code):
    return "%s/%s" % (code[:2], code[2:])


def _kv_migrate(con, path):
    for q in _KV_SQL:
        con.execute(q)


def _kv_codes(tii):
    out = {}
    for y in tii or []:
        try:
            c = kv_code(y.get("main"), y.get("sub"))
        except Exception:
            continue
        if c not in out:
            out[c] = {"err": _num(y.get("err")), "km": _num(y.get("km"))}
    return out


def _kv_feed(con, ch, ts, tii, meta):
    """Eine TII-Pruefung (Zeit ts, Liste tii) in tii_seen einrechnen; aeltere/gleiche Zeit -> ignoriert. -> True wenn neu"""
    ts = int(ts)
    last_t, prev = meta.get(ch, (0, []))
    if ts <= int(last_t or 0):
        return False
    cur = _kv_codes(tii)
    prev = set(prev or [])
    for c, x in cur.items():
        r = con.execute("SELECT run, max_run, n, best_err FROM tii_seen WHERE ch=? AND code=?", (ch, c)).fetchone()
        run = (int(r[0] or 0) + 1) if (r and c in prev) else 1
        if r is None:
            con.execute("INSERT INTO tii_seen(ch, code, first_t, last_t, n, best_err, last_err, last_km, run, max_run, stable) VALUES(?,?,?,?,1,?,?,?,?,?,0)",
                        (ch, c, ts, ts, x["err"], x["err"], x["km"], run, run))
        else:
            be = r[3] if x["err"] is None else (x["err"] if r[3] is None else min(float(r[3]), x["err"]))
            con.execute("UPDATE tii_seen SET last_t=?, n=n+1, best_err=?, last_err=?, last_km=?, run=?, max_run=? WHERE ch=? AND code=?",
                        (ts, be, x["err"], x["km"], run, max(int(r[1] or 0), run), ch, c))
    for c in prev - set(cur):
        con.execute("UPDATE tii_seen SET run=0 WHERE ch=? AND code=?", (ch, c))
    meta[ch] = (ts, sorted(cur))
    con.execute("INSERT OR REPLACE INTO tii_seen_meta(ch, last_t, prev) VALUES(?,?,?)", (ch, ts, json.dumps(sorted(cur))))
    return True


def kv_update(base, path=None, now=None, bs=None):
    """tii_seen nachfuehren: erst Telemetrie fig aus lagezentrum.db (Nachtrag bis 48 h), dann die aktuelle Pruefung aus broadcast_state.json;
    stabiler TII-Satz (tii_set) -> stable. Idempotent. -> Anzahl neu eingerechneter Pruefungen"""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    n = 0
    if db is None or not hasattr(db, "connect"):
        return 0
    try:
        bs = bs if isinstance(bs, dict) else _t4_dab(base)
        fig = ((bs.get("t2") or {}).get("fig") or {}) if isinstance(bs.get("t2"), dict) else {}
        fig = fig if isinstance(fig, dict) else {}
        with _KV_LOCK:
            con = db.connect(path)
            try:
                with con:
                    _kv_migrate(con, path)
                    meta = {}
                    for ch, lt, pv in con.execute("SELECT ch, last_t, prev FROM tii_seen_meta").fetchall():
                        try:
                            meta[ch] = (int(lt or 0), json.loads(pv or "[]"))
                        except Exception:
                            meta[ch] = (int(lt or 0), [])
                    have_tel = con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='telemetry'").fetchone() is not None
                    for ch in sorted(set(T4_CH) | set(meta) | set(str(k) for k in fig)):
                        if have_tel:
                            since = max(int(meta.get(ch, (0, []))[0] or 0), now - KV_BACKFILL_S)
                            for ts, tj in con.execute("SELECT ts, tii FROM telemetry WHERE kind='fig' AND channel=? AND ts>? ORDER BY ts, id", (ch, since)).fetchall():
                                try:
                                    tl = json.loads(tj or "[]")
                                except Exception:
                                    tl = []
                                n += 1 if _kv_feed(con, ch, ts, tl if isinstance(tl, list) else [], meta) else 0
                        x = fig.get(ch) if isinstance(fig.get(ch), dict) else {}
                        if isinstance(x.get("t"), (int, float)) and x["t"] <= now + 60:
                            n += 1 if _kv_feed(con, ch, x["t"], [y for y in (x.get("tii") or []) if isinstance(y, dict)], meta) else 0
                        for s in x.get("tii_set") or [] if isinstance(x.get("tii_set"), list) else []:
                            try:
                                a, b = str(s).split("/")
                                con.execute("UPDATE tii_seen SET stable=1 WHERE ch=? AND code=? AND stable=0", (ch, kv_code(a, b)))
                            except Exception:
                                pass
            finally:
                con.close()
        _KV.update(err=None, t=now)
    except Exception as e:
        _KV["err"] = str(e)[:160]
        print("sdr_manager kartevec tii_seen:", e, flush=True)
    return n


def kv_seen(path):
    """tii_seen -> {(ch, code): zeile}"""
    out = {}
    try:
        for r in db._rows("SELECT * FROM tii_seen", (), path):
            out[(r["ch"], r["code"])] = r
    except Exception as e:
        if "no such table" not in str(e):
            print("sdr_manager kartevec lesen:", e, flush=True)
    return out


def kv_ever(r):
    return bool(r) and (int(r.get("max_run") or 0) >= KV_EVER_RUN or bool(r.get("stable")))


def kv_q(snr, err):
    """Signal-Schaetzung 0-1: SNR 0-25 dB, je Mast abgeschwaecht nach TII-Fehler (0 -> x1, >= 300 -> x0,5). Ohne SNR -> None"""
    if snr is None:
        return None
    q = max(0.0, min(1.0, float(snr) / KV_SNR_MAX))
    if err is not None:
        q *= 1.0 - 0.5 * max(0.0, min(1.0, float(err) / KV_ERR_HALF))
    return round(q, 3)


def kv_sticks(base, bs, now):
    """Laeuft prepper-sdr (sdr_status.json <= 90 s, pid lebt) und meldet der Kanal Sync? -> {ch: (ok, grund)}"""
    st = _load(os.path.join(base, "sdr_status.json"), {}) or {}
    alive = heartbeat_row(st, now) is not None
    s2 = st.get("stick2") if isinstance(st.get("stick2"), dict) else {}
    s2_ok = alive and (not s2 or s2.get("present", True) is not False)
    out = {}
    for ch in T4_CH:
        d = ((bs.get("dab") or {}).get(ch) or {}) if isinstance(bs.get("dab"), dict) else {}
        stick_ok = alive if ch == "11D" else s2_ok
        if not alive:
            out[ch] = (False, "prepper-sdr ohne frischen Status (> %d s) oder Prozess beendet - Stick offline" % STATUS_MAX_AGE_S)
        elif not stick_ok:
            out[ch] = (False, "Stick 2 fehlt")
        elif d.get("rx") is False:
            out[ch] = (False, "Kanal %s ohne Sync%s" % (ch, (": " + str(d.get("rx_why"))[:60]) if d.get("rx_why") else ""))
        else:
            out[ch] = (True, "Stick %d laeuft" % (1 if ch == "11D" else 2))
    return out


def kv_mastlist(bs):
    """Alle Masten: MASTS_DB 11D (von prepper-sdr in broadcast_state.json t2.masts) + T4_MASTS (5C/10C). Je Standort ein Eintrag mit Kanaelen."""
    t4 = {}
    for m in T4_MASTS:
        for ch, code in m["tii"].items():
            t4[(ch, code)] = m
    md = (((bs.get("t2") or {}).get("masts") or {}).get("11D") or {}) if isinstance(bs.get("t2"), dict) else {}
    lst = [x for x in (md.get("tii") or []) if isinstance(x, dict)] if isinstance(md, dict) else []
    src = "MASTS_DB (prepper-sdr)"
    if not lst:
        src = "T4_MASTS (MASTS_DB noch nicht gemeldet)"
        lst = [{"main": int(m["tii"]["11D"][:2]), "sub": int(m["tii"]["11D"][2:]), "mast": m["name"]} for m in T4_MASTS if "11D" in m["tii"]]
    sites = {}
    order = []

    def site(sid, name, m4=None, x=None):
        if sid not in sites:
            order.append(sid)
            x = x or {}
            lat, lon, gsrc = None, None, None
            if m4:
                lat, lon, gsrc = m4["lat"], m4["lon"], "T4_MASTS (Wikipedia/helmuthzeitler.com/Teil-1-Liste)"
            elif isinstance(x.get("lat"), (int, float)) and isinstance(x.get("lon"), (int, float)):
                lat, lon, gsrc = x["lat"], x["lon"], "MASTS_DB (Wikipedia-Senderartikel)"
            elif x.get("_code") in KV_GEO_11D:
                g = KV_GEO_11D[x["_code"]]
                lat, lon, gsrc = g[0], g[1], g[2]
            sm = (m4 or {}).get("site_m") or x.get("site_m")
            am = (m4 or {}).get("ant_m") or x.get("ant_m")
            sites[sid] = {"id": sid, "name": name, "lat": lat, "lon": lon, "approx": True, "geo_src": gsrc, "site_m": sm, "ant_m": am,
                          "erp_kw": x.get("erp_kw"), "km_fmlist": x.get("km"), "ch": []}
        return sites[sid]
    for x in lst:
        try:
            code = kv_code(x.get("main"), x.get("sub"))
        except Exception:
            continue
        m4 = t4.get(("11D", code))
        s = site(m4["id"] if m4 else "11d-" + code, m4["name"] if m4 else str(x.get("mast") or kv_txt(code)), m4, dict(x, _code=code))
        if s["erp_kw"] is None and x.get("erp_kw") is not None:
            s["erp_kw"] = x.get("erp_kw")
        s["ch"].append({"ch": "11D", "tii": code})
    for m in T4_MASTS:
        for ch in ("5C", "10C"):
            if ch in m["tii"]:
                site(m["id"], m["name"], m)["ch"].append({"ch": ch, "tii": m["tii"][ch]})
    return [sites[k] for k in order], src


def kv_status(base, path=None, now=None, update=True):
    """Daten fuer /api/t4/tii (5-s-Abruf /karte): Masten mit Position, je Kanal TII schon empfangen/aktiv, Signal-Schaetzung, Ueberreichweite."""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    out = {"ok": True, "t": now, "home": T4_HOME, "k": T4_K, "active_s": KV_ACTIVE_S, "poll_s": KV_POLL_S, "ever_run": KV_EVER_RUN,
           "legend": "Schaetzung aus SNR/TII", "masts": [], "nopos": [], "unknown": [], "ch": {},
           "note": "welle-cli liefert je Mast keinen Pegel (kein RSSI je Mast): Linienstaerke = Schaetzung aus SNR des Kanals (0-25 dB), "
                   "je Mast abgeschwaecht nach TII-Fehler. Schon empfangen = >= %d Pruefungen in Folge oder stabiler TII-Satz; Kennungen ausserhalb MASTS_DB nie gezeichnet." % KV_EVER_RUN,
           "src": KV_GEO_SRC}
    try:
        bs = _t4_dab(base)
        if update:
            kv_update(base, path, now, bs)
        fig = ((bs.get("t2") or {}).get("fig") or {}) if isinstance(bs.get("t2"), dict) else {}
        fig = fig if isinstance(fig, dict) else {}
        sticks = kv_sticks(base, bs, now)
        seen = kv_seen(path)
        cur = {}
        for ch in T4_CH:
            x = fig.get(ch) if isinstance(fig.get(ch), dict) else {}
            te = _t4_tel(bs, ch, now)
            ft = int(x["t"]) if isinstance(x.get("t"), (int, float)) else None
            fresh = ft is not None and 0 <= now - ft <= KV_ACTIVE_S
            codes = _kv_codes([y for y in (x.get("tii") or []) if isinstance(y, dict)]) if ft else {}
            ok, why = sticks.get(ch, (False, "?"))
            cur[ch] = (codes if (fresh and ok) else {}, te)
            out["ch"][ch] = {"fig_t": ft, "age_s": (now - ft) if ft else None, "fresh": fresh, "stick_ok": ok, "stick_why": why, "snr": te.get("snr"),
                             "fic_rate": te.get("fic_rate"), "ens": te.get("ens") or x.get("ens"), "tii": [kv_txt(c) for c in codes],
                             "tii_set": x.get("tii_set") if isinstance(x.get("tii_set"), list) else None}
        masts, msrc = kv_mastlist(bs)
        out["mast_src"] = msrc
        known = set()
        for m in masts:
            h = (m["site_m"] or 0) + (m["ant_m"] or 0) if (m["site_m"] is not None and m["ant_m"] is not None) else None
            m["h_m"] = h
            m["D_km"] = t4_horizon_km(h) if h is not None else None
            m["dist_km"] = t4_dist_km(T4_HOME["lat"], T4_HOME["lon"], m["lat"], m["lon"]) if m["lat"] is not None else None
            for c in m["ch"]:
                known.add((c["ch"], c["tii"]))
                r = seen.get((c["ch"], c["tii"])) or {}
                codes, te = cur.get(c["ch"], ({}, {}))
                ever = kv_ever(r)
                act = ever and c["tii"] in codes
                err = (codes.get(c["tii"]) or {}).get("err") if act else r.get("last_err")
                c.update(tii_txt=kv_txt(c["tii"]), ever=ever, n=int(r.get("n") or 0), first_t=r.get("first_t"), last_t=r.get("last_t"), last_err=r.get("last_err"),
                         best_err=r.get("best_err"), last_km=r.get("last_km"), max_run=int(r.get("max_run") or 0), stable=bool(r.get("stable")),
                         active=act, snr=te.get("snr"), fic_rate=te.get("fic_rate"), q=kv_q(te.get("snr"), err) if act else None,
                         seen_unconfirmed=bool(r) and not ever)
            m["ever"] = any(c["ever"] for c in m["ch"])
            m["active"] = any(c["active"] for c in m["ch"])
            m["overreach"] = bool(m["active"] and m["dist_km"] is not None and m["D_km"] is not None and m["dist_km"] > m["D_km"])
            if m["lat"] is None:
                out["nopos"].append({"name": m["name"], "km_fmlist": m["km_fmlist"], "ever": m["ever"], "active": m["active"],
                                     "ch": [{k: c[k] for k in ("ch", "tii_txt", "n", "last_t", "ever")} for c in m["ch"]]})
            else:
                out["masts"].append(m)
        for (ch, code), r in sorted(seen.items(), key=lambda kv: -(kv[1].get("last_t") or 0)):
            if (ch, code) not in known:
                out["unknown"].append({"ch": ch, "tii_txt": kv_txt(code), "n": int(r.get("n") or 0), "last_t": r.get("last_t"), "last_err": r.get("last_err"),
                                       "max_run": int(r.get("max_run") or 0)})
        out["unknown"] = out["unknown"][:20]
        out["n_masts"] = len(masts)
        out["err"] = _KV.get("err")
    except Exception as e:
        out.update(ok=False, error=str(e)[:160])
        print("sdr_manager kartevec Status:", e, flush=True)
    return out


_kv_t2_sync0 = t2_sync


def t2_sync(base, path=None, now=None):
    """Teil 2 Abgleich wie bisher, danach tii_seen nachfuehren (kartevec, Fehler dort aendern den Abgleich nicht)."""
    r = _kv_t2_sync0(base, path, now)
    try:
        kv_update(base, path, now)
    except Exception as e:
        print("sdr_manager kartevec tii_seen:", e, flush=True)
    return r


def selftest_kv():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "lagezentrum.db")
    now = 1790000000
    db.migrate(p)
    db.migrate_t2(p)
    masts11 = {"tii": [{"main": 8, "sub": 18, "mast": "Bamberg (Geisberg)", "lat": 49.866, "lon": 10.844},
                       {"main": 5, "sub": 14, "mast": "Nürnberg (Fernmeldeturm Schweinau)", "lat": 49.4283, "lon": 11.0403},
                       {"main": 5, "sub": 15, "mast": "Büttelberg", "lat": 49.4146, "lon": 10.378, "km": 58, "site_m": 527, "ant_m": 159, "erp_kw": 10},
                       {"main": 6, "sub": 18, "mast": "Zeil am Main (Schleifberg)", "km": 65, "site_m": 350, "ant_m": 27, "erp_kw": 10},
                       {"main": 7, "sub": 1, "mast": "Amberg-Süd", "km": 57, "site_m": 383, "ant_m": 45, "erp_kw": 1},
                       {"main": 2, "sub": 8, "mast": "München (Olympiaturm)", "km": 157, "site_m": 511, "ant_m": 272, "erp_kw": 10}]}

    def put(t, tii, tset=None, rx=True, snr=18.0):
        f11 = {"t": t, "tii": tii}
        if tset is not None:
            f11["tii_set"] = tset
        _write_json(os.path.join(d, "broadcast_state.json"), {"dab": {"11D": {"rx": rx, "t": t, "demod": {"t": t, "snr": snr, "fic_rate": 0.002}}},
                                                               "t2": {"masts": {"11D": masts11}, "fig": {"11D": f11}}})
    _write_json(os.path.join(d, "sdr_status.json"), {"t": now, "pid": os.getpid()})
    # 48-h-Nachtrag aus der Telemetrie: 3 Pruefungen 08/18 + 05/14, eine mit Fehltreffer 00/18 und 06/18
    rows = [(now - 7200, [{"main": 8, "sub": 18, "err": 40.0, "km": 1.2}, {"main": 5, "sub": 14, "err": 60.0}, {"main": 0, "sub": 18, "err": 210.0}]),
            (now - 7140, [{"main": 8, "sub": 18, "err": 35.0}, {"main": 5, "sub": 14, "err": 55.0}, {"main": 6, "sub": 18, "err": 182.0}]),
            (now - 7080, [{"main": 8, "sub": 18, "err": 30.0}, {"main": 5, "sub": 14, "err": 50.0}]),
            (now - KV_BACKFILL_S - 100, [{"main": 2, "sub": 8, "err": 1.0}])]
    for t, tl in rows:
        assert db.insert_fig({"ts": t, "serial": "19348831", "channel": "11D", "ensemble": "Bayern", "tii": json.dumps(tl)}, p)
    put(now - 30, [{"main": 8, "sub": 18, "err": 20.0, "km": 1.0}, {"main": 6, "sub": 18, "err": 190.0}, {"main": 7, "sub": 1, "err": 200.0}])
    assert kv_update(d, p, now) == 4 and kv_update(d, p, now) == 0                                                    # Nachtrag + aktuell, idempotent
    s = kv_seen(p)
    assert s[("11D", "0818")]["n"] == 4 and s[("11D", "0818")]["max_run"] == 4 and s[("11D", "0818")]["best_err"] == 20.0, s[("11D", "0818")]
    assert s[("11D", "0514")]["max_run"] == 3 and s[("11D", "0514")]["run"] == 0 and s[("11D", "0018")]["n"] == 1 and ("11D", "0208") not in s
    assert s[("11D", "0618")]["n"] == 2 and s[("11D", "0618")]["max_run"] == 1 and not kv_ever(s[("11D", "0618")])  # 2 Treffer, nicht in Folge -> nicht bestaetigt
    st = kv_status(d, p, now)
    assert st["ok"] and st["legend"] == "Schaetzung aus SNR/TII" and st["ch"]["11D"]["fresh"] and st["ch"]["11D"]["stick_ok"], st
    by = {m["id"]: m for m in st["masts"]}
    bam, nbg, zeil = by["bamberg-geisberg"], by["nbg-schweinau"], by["11d-0618"]
    c = [x for x in bam["ch"] if x["ch"] == "11D"][0]
    assert bam["ever"] and bam["active"] and c["active"] and c["n"] == 4 and c["q"] == kv_q(18.0, 20.0) and 0 < c["q"] < 0.72, c
    assert nbg["ever"] and not nbg["active"] and [x for x in nbg["ch"] if x["ch"] == "5C"][0]["ever"] is False                 # 05/14 nicht in der letzten Pruefung
    assert zeil["lat"] == KV_GEO_11D["0618"][0] and not zeil["ever"] and not zeil["active"] and [x for x in zeil["ch"]][0]["seen_unconfirmed"]
    assert [x["name"] for x in st["nopos"]] == ["Amberg-Süd"] and not st["nopos"][0]["ever"]                                     # ohne Position: nur Liste
    assert [u["tii_txt"] for u in st["unknown"]] == ["00/18"]                                                                    # nicht in MASTS_DB: nie gezeichnet
    assert by["buettelberg"]["lat"] == 49.4146 and by["buettelberg"]["lon"] == 10.378 and "5C" in [x["ch"] for x in by["buettelberg"]["ch"]]
    assert {x["ch"] for x in by["hersbruck"]["ch"]} == {"10C"} and by["hersbruck"]["D_km"] == t4_horizon_km(542)
    assert not bam["overreach"] and bam["dist_km"] < bam["D_km"]
    # zweite Pruefung in Folge -> 06/18 bestaetigt (blau, dauerhaft) und aktiv; stabiler Satz markiert ebenso
    put(now + 30, [{"main": 8, "sub": 18, "err": 22.0}, {"main": 6, "sub": 18, "err": 180.0}], tset=["06/18", "08/18"])
    st = kv_status(d, p, now + 35)
    z = {m["id"]: m for m in st["masts"]}["11d-0618"]
    assert z["ever"] and z["active"] and kv_seen(p)[("11D", "0618")]["stable"] == 1, z
    # aelter als 150 s -> nichts aktiv, aber blau bleibt
    st = kv_status(d, p, now + 30 + KV_ACTIVE_S + 1)
    assert not any(m["active"] for m in st["masts"]) and {m["id"]: m for m in st["masts"]}["11d-0618"]["ever"]
    # Stick 1 offline (Status alt) -> nichts aktiv
    put(now + 60, [{"main": 8, "sub": 18, "err": 22.0}])
    _write_json(os.path.join(d, "sdr_status.json"), {"t": now - 200, "pid": os.getpid()})
    st = kv_status(d, p, now + 61)
    assert not st["ch"]["11D"]["stick_ok"] and not any(m["active"] for m in st["masts"]) and "offline" in st["ch"]["11D"]["stick_why"]
    # Kanal ohne Sync -> nichts aktiv
    _write_json(os.path.join(d, "sdr_status.json"), {"t": now + 60, "pid": os.getpid()})
    put(now + 90, [{"main": 8, "sub": 18, "err": 22.0}], rx=False)
    assert not any(m["active"] for m in kv_status(d, p, now + 91)["masts"])
    # Ueberreichweite: Testmast weit weg
    put(now + 120, [{"main": 2, "sub": 8, "err": 5.0}])
    assert kv_update(d, p, now + 121) == 1
    put(now + 150, [{"main": 2, "sub": 8, "err": 5.0}])
    _write_json(os.path.join(d, "sdr_status.json"), {"t": now + 150, "pid": os.getpid()})
    T4_MASTS.append({"id": "fern", "name": "Testmast fern", "lat": 52.5, "lon": 13.4, "site_m": 50, "ant_m": 50, "tii": {"11D": "0208"}})
    try:
        st = kv_status(d, p, now + 151)
        f2 = {m["id"]: m for m in st["masts"]}["fern"]
        assert f2["active"] and f2["overreach"] and f2["dist_km"] > f2["D_km"], f2
    finally:
        T4_MASTS.pop()
    # t2_sync fuehrt tii_seen mit
    n0 = kv_seen(p)[("11D", "0818")]["n"]
    put(now + 200, [{"main": 8, "sub": 18, "err": 21.0}])
    t2s0 = (_T2["asa_max"], list(_T2["ev"]), _T2["clean"])
    try:
        t2_sync(d, p, now + 201)
    finally:
        _T2["asa_max"], _T2["ev"], _T2["clean"] = t2s0
    assert kv_seen(p)[("11D", "0818")]["n"] == n0 + 1
    assert len(KV_GEO_11D) == 41 and all(47.0 < g[0] < 51.0 and 8.5 < g[1] < 14.0 and g[2] for g in KV_GEO_11D.values())
    return ("sdr_manager selftest kartevec ok (tii_seen dauerhaft + 48-h-Nachtrag, idempotent, blau erst ab 2 Pruefungen in Folge/stabil, Fremdkennungen nie gezeichnet, "
            "aktiv nur <= 150 s + Stick laeuft + Sync, Signal SNR/TII, Ueberreichweite, Buettelberg 49.4146/10.3780, ohne Position nur Liste)")
KVBM_EOF
EXPECT_GUARD="4f056537a1f2beafb77e26963fa6dfb294bca8d4f9dd0db9138d8950e3686a39"
cat > "$W/guard_kartevec.py" << 'KVG_EOF'
"""kartevec AST-Guard. Aufruf: guard_kartevec.py DASH_ALT DASH_NEU SM_ALT SM_NEU PATCH_DASH PATCH_SM BLOCK_DASH BLOCK_SM -> 0 ok, 1 Verstoss.
dashboard.py: nur lageTest-Block weg, 12 Stellen (Kacheln -> /funk, Texte Funk-Seite) und Block kartevec nach diskTiles (Ruecktausch ergibt Byte fuer Byte die Basis ohne lageTest).
sdr_manager.py: nur Buettelberg-Zeile, Block kartevec vor dem Hauptteil und selftest_kv. Neue Bloecke: keine Prozesse, kein Netz, kein shell, keine Sendewege, keine POST-Route."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
d0, d1, m0, m1, pd, pm, bd, bm = (rd(x) for x in sys.argv[1:9])
err = []
g = {}
sys.argv = ["x", sys.argv[1], "/dev/null", sys.argv[7]]
exec(compile(pd.split("bad = []")[0], "pd", "exec"), g)
B, EDITS, LT0, LT1, ANCH = g["B"], g["EDITS"], g["LT0"], g["LT1"], g["ANCH"]
DONE = (d0 == d1 and m0 == m1 and LT0 not in d0)  # schon eingespielt: Basis = Ergebnis, nur Struktur pruefen
if DONE:
    lt, base = "lt_prepare /api/lage_test/prepare", None
else:
    i, j = d0.index(LT0), d0.index(LT1) + len(LT1)
    lt = d0[i:j]
    base = d0[:i] + d0[j:]
if d1.count(B) != 1 or d1.index(B) != d1.index(ANCH) + len(ANCH):
    err.append("dashboard.py: Block kartevec fehlt oder an falscher Stelle")
r = d1.replace(B, "", 1)
for old, new in EDITS:
    if r.count(new) != 1:
        err.append("dashboard.py: Stelle fehlt %s" % new.strip().splitlines()[0][:60])
    r = r.replace(new, old, 1)
if base is not None and r != base:
    err.append("dashboard.py: anders geaendert als lageTest weg + 12 Stellen + Block kartevec")
for k in ("/api/lage_test", "lt_prepare", "_lt_prepare_post", "Testnachricht vorbereiten", "lt-btn"):
    if k in d1.replace(B, "", 1):
        err.append("dashboard.py: Rest der Testnachricht-Funktion: %s" % k)
if "lt_prepare" not in lt or "/api/lage_test/prepare" not in lt:
    err.append("entfernter Block ist nicht lageTest")
gm = {}
sys.argv = ["x", sys.argv[3] if len(sys.argv) > 3 else "", "/dev/null", ""]
src_pm = pm.split("bad = []")[0].replace("s = open(src, encoding=\"utf-8\").read()\nB = open(blk, encoding=\"utf-8\").read()\n", "")
exec(compile(src_pm.replace("src, dst, blk = sys.argv[1], sys.argv[2], sys.argv[3]\n", ""), "pm", "exec"), gm)
rm = m1
BM = bm.rstrip("\n") + "\n"
if rm.count(BM) != 1 or rm.count(gm["NEW_B"]) != 1 or not rm.endswith(BM + gm["MAIN1"]):
    err.append("sdr_manager.py: kartevec-Stellen fehlen")
rm = rm.replace(gm["NEW_B"], gm["OLD_B"], 1)
rm = rm[:-len(BM + gm["MAIN1"])] + gm["MAIN0"] if rm.endswith(BM + gm["MAIN1"]) else rm
if not DONE and rm != m0:
    err.append("sdr_manager.py: anders geaendert als Buettelberg + Block kartevec + selftest_kv")


def chk(name, code):
    t = ast.parse(code)
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                mod = (getattr(n, "module", None) or a.name).split(".")[0]
                if mod not in ("re", "threading", "tempfile", "flask", "json", "os", "time", "math"):
                    err.append("%s: Import %s" % (name, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s: shell" % name)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            if any(k in nm.lower() for k in ("send", "popen", "system", "urlopen", "socket", "mesh", "takeover_set", "set_auto", "post")) or nm in ("run", "call", "check_output", "exec", "eval"):
                err.append("%s: Aufruf %s" % (name, nm))
            if nm == "add_url_rule":
                for kw in n.keywords:
                    if kw.arg == "methods" and "POST" in ast.dump(kw.value):
                        err.append("%s: POST-Route" % name)


chk("Block dashboard", B)
chk("Block sdr_manager", BM)
KJ = B.split('_KV_JS = r"""', 1)[1].split('"""', 1)[0] if '_KV_JS = r"""' in B else ""
if not KJ or "method:" in KJ or "/send" in KJ or "/api/t2/" in KJ or "POST" in KJ:
    err.append("Block dashboard: Sendeweg/POST im JS")
if err:
    print("\n".join(err)); raise SystemExit(1)
if DONE:
    print("OK AST-Guard kartevec: schon eingespielt - Block kartevec, 12 Stellen und sdr_manager-Stellen vorhanden, Testnachricht-Funktion weg, keine Sendewege/POST")
    raise SystemExit(0)
print("OK AST-Guard kartevec: dashboard.py nur lageTest entfernt (Testnachricht-Knoepfe + Route), 12 Stellen (3 Kacheln -> /funk, Funk-Seite), Block kartevec; "
      "sdr_manager.py nur Buettelberg + Block kartevec + selftest_kv; keine neuen Prozesse, kein Netz, kein shell, keine Sendewege/POST")
KVG_EOF
EXPECT_CK="88fda02ff402c9d3ecc29ab2a0dce8fde84575284773c7c66289dd24062ff237"
cat > "$W/kvcheck.py" << 'KVC_EOF'
"""kartevec Pruefung/Anzeige (nur lesen). kvcheck.py check TII_JSON | show TII_JSON | lage LAGE_HTML FUNK_HTML KARTE_HTML | seen DB | takeover DASH_DIR"""
import json
import sys
import time


def ft(t):
    try:
        return time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(int(t)))
    except Exception:
        return "–"


def rd(f):
    return open(f, encoding="utf-8", errors="replace").read()


a = sys.argv[1]
if a == "check":
    d = json.load(open(sys.argv[2]))
    assert d.get("ok") and d.get("legend") == "Schaetzung aus SNR/TII" and isinstance(d.get("masts"), list) and isinstance(d.get("nopos"), list), d.get("error")
    n = d.get("n_masts") or 0
    assert n == len(d["masts"]) + len(d["nopos"]) and n >= 9, n
    assert all(isinstance(m.get("lat"), (int, float)) for m in d["masts"]) and not any(m.get("lat") is not None for m in d["nopos"])
    b = [m for m in d["masts"] if m.get("id") == "buettelberg"]
    assert b and b[0]["lat"] == 49.4146 and b[0]["lon"] == 10.378, b
    print("Masten %d (%s): %d mit Position gezeichnet, %d ohne Position nur gelistet; schon empfangen %d, gerade aktiv %d" % (
        n, d.get("mast_src"), len(d["masts"]), len(d["nopos"]), sum(1 for m in d["masts"] + d["nopos"] if m.get("ever")), sum(1 for m in d["masts"] if m.get("active"))))
elif a == "show":
    d = json.load(open(sys.argv[2]))
    for ch, c in sorted((d.get("ch") or {}).items()):
        if c.get("fig_t") or ch == "11D":
            print("  %s: letzte TII-Pruefung %s (vor %s s), %s, TII %s" % (ch, ft(c.get("fig_t")) if c.get("fig_t") else "–", c.get("age_s"), c.get("stick_why"), ", ".join(c.get("tii") or []) or "–"))
    for m in d.get("masts") or []:
        for c in m.get("ch") or []:
            if c.get("ever") or c.get("n"):
                print("  %-4s %s %-40s %s, %3dx gesehen, zuletzt %s, max. %d in Folge%s%s" % (c["ch"], c["tii_txt"], m["name"][:40], "BLAU (schon empfangen)" if c["ever"] else "grau (nicht bestaetigt)",
                      c.get("n") or 0, ft(c.get("last_t")), c.get("max_run") or 0, ", AKTIV" if c.get("active") else "", ", UEBERREICHWEITE" if m.get("overreach") else ""))
    for m in d.get("nopos") or []:
        for c in m.get("ch") or []:
            if c.get("ever") or c.get("n"):
                print("  %-4s %s %-40s %s, %3dx gesehen, zuletzt %s (ohne gesicherte Position, nicht gezeichnet)" % (c["ch"], c["tii_txt"], m["name"][:40],
                      "BLAU (schon empfangen)" if c["ever"] else "grau (nicht bestaetigt)", c.get("n") or 0, ft(c.get("last_t"))))
    u = d.get("unknown") or []
    if u:
        print("  Nicht in MASTS_DB (nie gezeichnet): " + "; ".join("%s %s %dx Fehler %s" % (x["ch"], x["tii_txt"], x["n"], x.get("last_err")) for x in u[:10]))
    print("  Ohne gesicherte Position (unter der Karte gelistet): %d Masten" % len(d.get("nopos") or []))
elif a == "lage":
    lage, funk, karte = rd(sys.argv[2]), rd(sys.argv[3]), rd(sys.argv[4])
    bad = []
    for name, s in (("Lage", lage), ("Funk", funk), ("Karte", karte)):
        if 'href="/karte">Karte</a>' not in s or ('id="navUnify"' in s and "repeat(4,minmax(0,1fr))" not in s):
            bad.append("%s: Menue ohne Karte/4x4" % name)
    if 'id="t2-js"' in lage or 'id="t4Lage"' not in lage or 'id="t4-js"' not in lage:
        bad.append("Lage: Kachel Sticks noch da oder Ampel fehlt")
    if "/api/lage_test" in lage or "lt-btn" in lage or "Testnachricht vorbereiten" in lage:
        bad.append("Lage: Testnachricht-Knoepfe noch da")
    if 'id="t2-js"' not in funk or 'id="t4-js"' not in funk or "kvPut(t,'t2Tile')" not in funk:
        bad.append("Funk: Kacheln fehlen")
    if 'id="kv-js"' not in karte or "/api/t4/tii" not in karte or "/karte/res/leaflet/leaflet.js" not in karte:
        bad.append("Karte: neue Karte fehlt")
    if bad:
        print("; ".join(bad)); raise SystemExit(1)
    print("Lage ohne die 3 Kacheln und ohne Testnachricht-Knoepfe (Ampel bleibt); Funk mit Sticks & Alarm-Automatik, SDR-Status, Ereignis-Historie; Menue 4x4 mit Karte")
elif a == "seen":
    import sqlite3
    con = sqlite3.connect("file:%s?mode=ro" % sys.argv[2], uri=True, timeout=10)
    try:
        r = con.execute("SELECT COUNT(*), COALESCE(SUM(n),0) FROM tii_seen").fetchone()
        m = con.execute("SELECT COUNT(*) FROM tii_seen_meta").fetchone()
    finally:
        con.close()
    print("tii_seen: %d Kennungen, %d Treffer, %d Kanaele" % (r[0], r[1], m[0]))
elif a == "tables":
    import sqlite3
    con = sqlite3.connect("file:%s?mode=ro" % sys.argv[2], uri=True, timeout=10)
    try:
        print(" ".join(x[0] for x in con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'tii_seen%' ORDER BY name")))
    finally:
        con.close()
elif a == "takeover":
    try:
        d = json.load(open(sys.argv[2] + "/sdr_takeover.json"))
    except Exception as e:
        print("  sdr_takeover.json nicht lesbar: %s" % e); raise SystemExit(0)
    print("  jetzt: %s seit %s, Quelle %s, Grund %s, von %s" % ("AN (Stick 2 fest auf 5C)" if d.get("on") else "aus", ft(d.get("since")), d.get("src"), d.get("why") or "–", d.get("by")))
    for h in (d.get("hist") or [])[-5:]:
        if isinstance(h, dict):
            print("  Verlauf %s: %s, Quelle %s, Grund %s, von %s" % (ft(h.get("t")), "AN" if h.get("on") else "aus", h.get("src"), h.get("why") or "–", h.get("by")))
KVC_EOF
PD="$W/patch-kv-dash.py"; PM="$W/patch-kv-sm.py"; BD="$W/dash_kv_block.py"; BM="$W/sm_kv_block.py"; SG="$W/guard_kartevec.py"; CK="$W/kvcheck.py"
for x in "$EXPECT_PD $PD" "$EXPECT_PM $PM" "$EXPECT_BD $BD" "$EXPECT_BM $BM" "$EXPECT_GUARD $SG" "$EXPECT_CK $CK"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$M" "$DBF"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
D16=$(sha256sum "$F" | cut -c1-16); SM16=$(sha256sum "$SMF" | cut -c1-16); SDR16=$(sha256sum "$M" | cut -c1-16); DB16=$(sha256sum "$DBF" | cut -c1-16)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || echo "neu, Erkennung ueber Guards"; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "Teil 4"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "Teil 4"))"
echo "prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "tiiFix2")) - bleibt unveraendert"
echo "database.py sha16 $DB16 ($(wc -l < "$DBF") Zeilen, $(kn "$DB16" "$KNOWN_DB16" "Teil 2/3")) - bleibt unveraendert"
grep -q '# ===== teil4:' "$F" || { echo "STOP: Teil 4 fehlt in dashboard.py - bitte zuerst apply-teil4.sh, nichts geaendert"; exit 1; }
grep -q '# tiiFix2' "$M" || { echo "STOP: tiiFix2 fehlt in prepper_sdr.py - bitte zuerst apply-tiifix2.sh, nichts geaendert"; exit 1; }
grep -q 'def t4_map(' "$SMF" || { echo "STOP: Teil 4 fehlt in sdr_manager.py - nichts geaendert"; exit 1; }
python3 "$PD" "$F" "$W/work/dashboard.py" "$BD" > "$W/pd.log" || { cat "$W/pd.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
python3 "$PM" "$SMF" "$W/work/sdr_manager.py" "$BM" > "$W/pm.log" || { cat "$W/pm.log"; echo "STOP: sdr_manager.py unbekannte Basis (sha16 $SM16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: $(cat "$W/pd.log"); $(cat "$W/pm.log")"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
python3 "$PD" "$W/work/dashboard.py" "$W/work/x.py" "$BD" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || { echo "STOP: dashboard nicht idempotent"; exit 1; }
python3 "$PM" "$W/work/sdr_manager.py" "$W/work/x.py" "$BM" >/dev/null && cmp -s "$W/work/sdr_manager.py" "$W/work/x.py" || { echo "STOP: sdr_manager nicht idempotent"; exit 1; }
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/sdr_manager.py"; do
    "$py" -W error -m py_compile "$x" || { echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp "$DBF" "$DASH_DIR/mesh_router.py" "$W/work/sdr_manager.py" "$W/msbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/msbx" && timeout 120 "$py" sdr_manager.py > "$W/mst.log" 2>&1) || { tail -12 "$W/mst.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok"; do
    grep -qF "$k" "$W/mst.log" || { echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest sdr_manager mit $SPY und $VPY (Sandbox, Testdaten, nichts gesendet): $(grep 'selftest kartevec' "$W/mst.log" | cut -c1-170)"
python3 "$SG" "$F" "$W/work/dashboard.py" "$SMF" "$W/work/sdr_manager.py" "$PD" "$PM" "$BD" "$BM" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
if command -v node >/dev/null 2>&1; then
  python3 - "$W/work/dashboard.py" "$W" << 'JSPY' || { echo "STOP: JavaScript fehlerhaft - nichts geaendert"; exit 1; }
import ast, subprocess, sys
for n in ast.parse(open(sys.argv[1], encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("_KV_JS", "_T2D_JS", "_T4_JS") and isinstance(n.value, ast.Constant):
        f = "%s/%s.js" % (sys.argv[2], n.targets[0].id)
        open(f, "w", encoding="utf-8").write(n.value.value)
        if subprocess.run(["node", "--check", f]).returncode:
            raise SystemExit(1)
JSPY
  echo "OK JavaScript (Karte, Sticks-Kachel, SDR-Kachel) syntaktisch geprueft (node)"
fi
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
TB0=""; [[ -f "$LZ" ]] && TB0=$(python3 "$CK" tables "$LZ" 2>/dev/null || true)
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
ALL=("$F" "$SMF")
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/sdr_manager.py" "$SMF"; then
  echo "OK kartevec schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "kartevec|teil[24]|Traceback|Error" | tail -8 | cut -c1-200 || true
    for x in "${ALL[@]}"; do [[ -f "$x.bak-kartevec-$TS" ]] && cp -a "$x.bak-kartevec-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 60); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    if [[ -f "$LZ" && -z "$TB0" ]]; then
      python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1], timeout=30)
with c:
    c.execute('DROP TABLE IF EXISTS tii_seen'); c.execute('DROP TABLE IF EXISTS tii_seen_meta')
c.close()" "$LZ" && echo "  Tabellen tii_seen/tii_seen_meta wieder entfernt (waren vorher nicht da)" || echo "  WARNUNG tii_seen nicht entfernt (stoert den alten Stand nicht)"
    fi
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-kartevec-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-kartevec-$TS"
    { ls -1t "$x.bak-kartevec-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-kartevec-$TS" \
      || { rm -f "$LZ.bak-kartevec-$TS"; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-kartevec-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  cp "$W/work/sdr_manager.py" "$SMF.new" && chmod --reference="$SMF.bak-kartevec-$TS" "$SMF.new" && mv -f "$SMF.new" "$SMF" || { rb "installieren sdr_manager"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-kartevec-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-dashboard (prepper-sdr laeuft weiter, Sticks unberuehrt) - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in /karte /funk / /api/t2/status /api/t4/status /api/t4/map /api/t4/tii /karte/res/leaflet/leaflet.js; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
c=$(code -X POST "$B/api/lage_test/prepare" -H 'Content-Type: application/json' -H 'X-Lage-Test: 1' -d '{"kind":"aus"}'); [[ "$c" == 404 ]] && echo "OK Route /api/lage_test/prepare entfernt ($c)" || rbx "/api/lage_test/prepare antwortet noch ($c)"
c=$(code -X POST "$B/api/t4/tii" -H 'Content-Type: application/json' -d '{}'); [[ "$c" == 405 ]] && echo "OK /api/t4/tii nur lesen (POST $c)" || rbx "/api/t4/tii nimmt POST an ($c)"
c=$(code -X POST "$B/api/t2/stick2" -H 'Content-Type: application/json' -d '{"action":"alarm","confirm":true}'); [[ "$c" == 403 ]] && echo "OK Stick-2-Knopf ohne Funk-Seite abgewiesen ($c, nichts geschaltet)" || rbx "/api/t2/stick2 ohne Pruefung ($c)"
"${CURL[@]}" "$B/api/t4/tii" -o "$W/tii.json" || true
python3 "$CK" check "$W/tii.json" > "$W/tii.log" && echo "OK /api/t4/tii: $(cat "$W/tii.log")" || { cat "$W/tii.log"; rbx "/api/t4/tii ungueltig"; }
"${CURL[@]}" "$B/" -o "$W/lage.html" || true
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
"${CURL[@]}" "$B/karte" -o "$W/karte.html" || true
python3 "$CK" lage "$W/lage.html" "$W/funk.html" "$W/karte.html" > "$W/lage.log" && echo "OK $(cat "$W/lage.log")" || { cat "$W/lage.log"; rbx "Seiten nicht wie erwartet"; }
grep -q 'id="stickTestCard"' "$W/funk.html" && echo "OK /funk: Antennentest bleibt letzte Kachel, die 3 Kacheln stehen direkt davor" || echo "Hinweis: /funk ohne Antennentest-Kachel - die 3 Kacheln stehen am Ende des Rasters"
c=$(code "$B/zuhause"); if [[ "$c" == 200 ]]; then "${CURL[@]}" "$B/zuhause" -o "$W/zuhause.html" || true; grep -q 'href="/karte">Karte</a>' "$W/zuhause.html" && echo "OK /zuhause: Menue mit Karte" || echo "Hinweis: /zuhause ohne Karte im Menue (eigene Menue-Kopie)"; fi
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
L1=$(python3 -c "
import sys; s=open(sys.argv[1],encoding='utf-8',errors='replace').read(); i=s.rfind('doPrepperRestore'); print('ja' if i>=0 and s.find('class=\"tile', i) < 0 and s.find('class=\"card', i) < 0 else 'nein')" "$W/pi.html" 2>/dev/null || echo nein)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x), letzte Kachel: $L1" || rbx "/pi Sicherung veraendert ($R0/$R1)"
sleep 5
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(kartevec|teil[234]) (aktiv|FEHLER)" | tail -8 || true)
if [[ "$JD" == *"FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2)"; fi
if [[ "$JD" == *"kartevec aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'kartevec aktiv' | tail -1 | cut -c1-230)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet kartevec nicht (Journal)"; fi
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|kartevec (Menue|Karte|Karte Zonen):|sdr_manager kartevec" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/kartevec-Fehler" || rbx "$E Traceback/kartevec-Fehlerzeilen im Journal Dashboard"
[[ -f "$LZ" ]] && { python3 "$CK" seen "$LZ" > "$W/seen.log" 2>&1 && echo "OK $(cat "$W/seen.log") (dauerhaft, Nachtrag aus 48 h Telemetrie)" || rbx "tii_seen nicht lesbar: $(cat "$W/seen.log")"; }
[[ "$(sha256sum "$M" | cut -c1-16)" == "$SDR16" ]] && echo "OK prepper_sdr.py unveraendert ($SDR16)" || rbx "prepper_sdr.py hat sich veraendert"
[[ "$(sha256sum "$DBF" | cut -c1-16)" == "$DB16" ]] && echo "OK database.py unveraendert ($DB16)" || rbx "database.py hat sich veraendert"
echo "OK guards kartevec(dash)=$(grep -c '# ===== kartevec:' "$F" || true) lageTest(dash)=$(grep -c '# ===== lageTest:' "$F" || true) teil4(dash)=$(grep -c '# ===== teil4:' "$F" || true) teil2(dash)=$(grep -c '# ===== teil2:' "$F" || true) stickTestFix(dash)=$(grep -c '# ===== stickTestFix:' "$F" || true) kartevec(sdr_manager)=$(grep -c '# ---------------------------------------------------------------- kartevec' "$SMF" || true) Teil4(sdr_manager)=$(grep -c '# ---------------------------------------------------------------- Teil 4' "$SMF" || true) tiiFix2(sdr)=$(grep -c '# tiiFix2' "$M" || true)"
[[ -f "$F.bak-kartevec-$TS" ]] && echo "Backups: *.bak-kartevec-$TS (dashboard.py, sdr_manager.py, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$M" "$DBF"; do echo "  $(basename "$x") sha16 $(sha256sum "$x" | cut -c1-16), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG kartevec=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, kartevec bleibt aktiv. COMMIT $COMMIT_ARG kartevec=1"; exit 0' INT
echo "TII je Mast (aus tii_seen, nur lesen):"
python3 "$CK" show "$W/tii.json" || true
echo "Stick 2 / Uebernahme (nur lesen, nichts geaendert):"
python3 "$CK" takeover "$DASH_DIR" || true
sudo journalctl -u prepper-dashboard --since "2026-10-17 17:55" --until "2026-10-17 18:05" --no-pager -o short-iso 2>/dev/null | grep -E "teil2: (Knopf|Auto-Versand)|teil4: .*(Vor-Alarm|VORALARM)" | tail -6 | cut -c1-200 || true
echo "Karte: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT/karte (Menue: Karte nach Funk)"
echo "COMMIT $COMMIT_ARG kartevec=1 fertig"
