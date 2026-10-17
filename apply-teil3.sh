#!/bin/bash
set -euo pipefail
# Teil 3 von 4 (auf Teil 2): Meshtastic-Routing und Priorisierung. Mesh 2 (192.168.178.140, Bridge 5002) nur NINA; Mesh 1 (192.168.178.141, Bridge 5001)
# NINA + exklusiv DAB+ (send_dab_to_private_mesh, harte Sperre .140). NINA-Automatik an beide Knoten Kanal 0, Detailmeldung (Beschreibung, Empfehlung,
# Gebiet) per Warteschlange 60 s spaeter bei freiem Kanal (>= 60 s seit letztem Versand, keine DAB-Meldung offen, Auslastung < 40 %). DAB+ hat Vorrang.
# Vor jedem Versand Hash-Pruefung in mesh_log (6 h je Knoten, max 3/h je Knoten); Knoepfe nie gesperrt, nur Hinweis. Jeder Versand in mesh_log.
# Dateien: dashboard.py, database.py, mesh_router.py. Neustart nur prepper-dashboard. Sendet beim Einspielen nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
MODS=(database.py mesh_router.py)
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/teil3-apply
KEEP_LAST=3
KNOWN_DASH16="529a2c978d439ed3"  # live nach Teil 2 (Zweig 2b1b2f1e)
KNOWN_SDR16="e8a7ac1c3edfb076"   # bleibt unveraendert
KNOWN_SM16="855225dc03abb535"    # sdr_manager.py bleibt unveraendert
OLD_MOD16="47a3b6c30a38783b f0052cfd0f35d116"   # Teil 2: database.py mesh_router.py
EXP_M1="192.168.178.141"         # Mesh 1 = NINA + DAB+
EXP_M2="192.168.178.140"         # Mesh 2 = nur NINA
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== Teil 3 apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/msbx" "$W/new" "$W/old"
EXPECT_B2A="00633ebbf8bbe8035afbb964bfe3e744fac40709152f4643e6b803eef3a54a26"
cat > "$W/t2_dash_block_v1.py" << 'T3B2A_EOF'
# ===== teil2: Teil 2 von 4 - Stick-2-Uebernahme 5C bei echtem Alarm (NINA Severe/Extreme, echter BR24-Notfall, ASA-Echtalarm) oder per Knopf, Rueckgabe NUR per Knopf (POST, gleicher Ursprung, lokal, Bestaetigung); Auto-Versand echter Alarme an Mesh 1 ueber denselben Sendeweg wie der Knopf "An Mesh 1 senden" (Schalter, Standard AUS, eine Meldung je Alarm, 6 h, max 3/h, Tests nie); ASA-Ueberwachung; FIG 0/9/TII in lagezentrum.db; GPIO vorbereitet (AUS); Kachel auf der Lage-Seite =====
import threading as _t2d_thr
import time as _t2d_time
import re as _t2d_re

_T2D = {"ok": False, "err": None, "selftest": None, "nina": {}, "alarms": [], "rep": None, "gpio": None, "t": 0, "n": 0, "started": False, "takeover_ch": None}
_T2D_LOCK = _t2d_thr.Lock()
T2D_TICK_S = 20                        # Pruefung alle 20 s im eigenen Faden (unabhaengig von Seitenaufrufen)
T2D_NINA_URL = "https://warnung.bund.de/api31/warnings/%s.json"   # amtliche Detaildaten (Schweregrad, Status) wie bei NINA/lageGeo
T2D_NINA_NEW_MAX = 3                   # je NINA-Abruf hoechstens 3 neue Detailabfragen
T2D_NINA_RETRY_S = 600                 # Details je Warnung hoechstens alle 10 min neu (NINA-Abruf alle 15 min)
T2D_ID_RE = _t2d_re.compile(r"^[A-Za-z0-9._:-]{3,140}$")
T2D_NINA_DUP = "NINA geht schon ueber die bestehende NINA-Automatik an Mesh 1 (maybe_mesh_nina) - Teil 2 sendet NINA nicht doppelt"


def _t2d_nina_detail(warnings, now=None):
    """Schweregrad/Status je aktiver NINA-Warnung holen (Cache im Speicher, je Warnung hoechstens alle 10 min neu, damit eine
    Hochstufung auf Severe/Extreme ankommt; je Abruf hoechstens 3, aelteste zuerst). Nur Lesen bei warnung.bund.de."""
    now = int(now or _t2d_time.time())
    n, ids = 0, []
    for w in warnings or []:
        wid = str(w.get("id") or "") if isinstance(w, dict) else ""
        if T2D_ID_RE.match(wid) and wid not in ids:
            c = _T2D["nina"].get(wid)
            if not c or now - c.get("t", 0) >= T2D_NINA_RETRY_S:
                ids.append(wid)
    for wid in sorted(ids, key=lambda k: (_T2D["nina"].get(k) or {}).get("t", 0)):
        if n >= T2D_NINA_NEW_MAX:
            break
        n += 1
        try:
            r = requests.get(T2D_NINA_URL % wid, timeout=8, headers={"User-Agent": "KaeswasserLage/1.0"})
            d = r.json() if r.status_code == 200 else None
            if not isinstance(d, dict):
                _T2D["nina"][wid] = dict(_T2D["nina"].get(wid) or {}, t=now, http=r.status_code)   # alter Schweregrad bleibt
                continue
            info = (d.get("info") or [{}])[0] if isinstance(d, dict) and isinstance(d.get("info"), list) and d.get("info") else {}
            _T2D["nina"][wid] = {"severity": info.get("severity") if isinstance(info, dict) else None, "status": d.get("status") if isinstance(d, dict) else None,
                                 "msgType": d.get("msgType") if isinstance(d, dict) else None, "t": now, "http": r.status_code}
        except Exception as e:
            old = _T2D["nina"].get(wid) or {}
            _T2D["nina"][wid] = dict(old, t=now, err=str(e)[:80])   # alter Schweregrad bleibt bei Netzfehler
    if len(_T2D["nina"]) > 300:
        for k in sorted(_T2D["nina"], key=lambda k: _T2D["nina"][k].get("t", 0))[:100]:
            _T2D["nina"].pop(k, None)
    return n


_t2d_orig_fetch_nina = fetch_nina


def fetch_nina():
    r = _t2d_orig_fetch_nina()
    try:
        if _T2D["ok"] and isinstance(r, list):
            _t2d_nina_detail(r)
    except Exception as e:
        print("teil2 NINA-Details:", e, flush=True)
    return r


def _t2d_cfg():
    try:
        c = _sdr_load("sdr_config.json", {}) or {}
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}


def _t2d_manual_sent(now):
    """Texte, die in den letzten 6 h per Knopf an Mesh 1 gingen (lageMesh1, nur im Speicher)."""
    try:
        return [x[2] for x in (globals().get("_lm1_log") or []) if now - x[0] < _lz_mesh.AUTO_SAME_S]
    except Exception:
        return []


def _t2d_tick(now=None, send_fn=None, base=None, path=None, ctx=None):
    """Alarme erkennen -> Stick-2-Uebernahme (immer automatisch) -> Auto-Versand (nur wenn Schalter AN) -> GPIO (vorbereitet, AUS)."""
    now = int(now or _t2d_time.time())
    base, path = base or _SDR_BASE, path or _LZ_PATH
    if ctx is None:
        _lz_sync(30)
        ctx = _lz_ctx()
    _lz_mgr.t2_sync(base, path, now)
    to0 = _lz_mgr.takeover_load(base)
    al = _lz_mgr.alarms_from(ctx.get("nina"), _T2D["nina"], ctx.get("br24"), _lz_dbm.active_events(now, path), now, to0.get("seen"))
    if callable(globals().get("maybe_mesh_nina")):
        for a in al:
            if a.get("src") == "NINA":
                a["dup_existing"] = T2D_NINA_DUP
    to, ch = _lz_mgr.takeover_auto(base, al, now)
    if ch and send_fn is None:
        _T2D["takeover_ch"] = now
        if to.get("on") and not to0.get("on"):
            print("teil2: echter Alarm -> Stick 2 auf 5C gekapert (Ausloeser %s: %s)" % (to.get("src"), str(to.get("why") or "")[:80]), flush=True)
        else:
            print("teil2: weiterer echter Alarm, Stick 2 %s" % ("schon auf 5C" if to.get("on") else "bleibt im Hobby-Betrieb (nur neue Alarme kapern)"), flush=True)
    boot = globals().get("mesh_auto_allowed")
    if callable(boot) and not boot() and send_fn is None:
        rep = {"on": _lz_mesh.auto_state(base)["on"], "t": now, "sent": [], "skip": [{"why": "Dashboard-Start: Mesh-Automatik erst nach %d s" % globals().get("MESH_BOOT_GUARD_SEC", 300)}]}
    else:
        rep = _lz_mesh.auto_send(al, send_fn or send_meshtastic, base, path, now, _t2d_manual_sent(now))
    gp = _lz_mgr.gpio_alarm(_lz_mgr.alarm_identifier(al), _t2d_cfg())
    _T2D.update(alarms=al, rep=rep, gpio=gp, t=now, n=_T2D["n"] + 1, err=None)
    return al, rep


def _t2d_loop():
    _t2d_time.sleep(30)
    while True:
        try:
            with _T2D_LOCK:
                _t2d_tick()
        except Exception as e:
            _T2D["err"] = str(e)[:160]
            print("teil2 Pruefung:", e, flush=True)
        _t2d_time.sleep(T2D_TICK_S)


def _t2d_autosend_info(now):
    st = _lz_mesh.auto_state(_SDR_BASE)
    rep = _T2D.get("rep") or {}
    return {"on": st["on"], "t": st["t"], "by": st["by"], "limit_h": _lz_mesh.AUTO_HOUR_MAX, "same_h": _lz_mesh.AUTO_SAME_S // 3600,
            "hour_n": _lz_dbm.mesh_auto_count(now - 3600, _LZ_PATH), "recent": _lz_dbm.mesh_auto_recent(5, _LZ_PATH),
            "last_skip": (rep.get("skip") or [])[:6], "last_sent": rep.get("sent") or []}


def _t2d_status():
    now = int(_t2d_time.time())
    s = _lz_mgr.t2_status(_SDR_BASE, _LZ_PATH, now, alarms=_T2D.get("alarms"), autosend=_t2d_autosend_info(now), gpio=_T2D.get("gpio"))
    s["tick"] = {"t": _T2D["t"], "n": _T2D["n"], "err": _T2D["err"], "every_s": T2D_TICK_S, "thread": _T2D["started"]}
    st = _sdr_load("sdr_status.json", {}) or {}
    s["stick2_txt"] = ((st.get("stick2") or {}).get("txt") if isinstance(st.get("stick2"), dict) else None)
    s["dual"] = st.get("dual") if isinstance(st.get("dual"), dict) else None
    return s


def _t2d_api():
    from flask import jsonify
    try:
        return jsonify(_t2d_status())
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


def _t2d_same_origin(rq):
    base = rq.host_url.rstrip("/")
    o = rq.headers.get("Origin")
    if o is not None and o.rstrip("/") != base:
        return False
    ref = rq.headers.get("Referer") or ""
    if o is None and not (ref == base or ref.startswith(base + "/")):
        return False
    sfs = rq.headers.get("Sec-Fetch-Site")
    if sfs is not None and sfs != "same-origin":
        return False
    return rq.headers.get("X-T2") == "1" and (rq.mimetype or "") == "application/json"


def _t2d_local(addr):
    """Nur aus dem Heimnetz/Tailscale/vom Pi selbst (keine oeffentliche Adresse)."""
    import ipaddress
    try:
        a = ipaddress.ip_address(str(addr or "").split("%")[0])
        if getattr(a, "ipv4_mapped", None):
            a = a.ipv4_mapped
        return bool(a.is_loopback or a.is_private or (a.version == 4 and a in ipaddress.ip_network("100.64.0.0/10")))
    except Exception:
        return False


def _t2d_check(rq):
    if not _t2d_same_origin(rq):
        return "nur von der Lage-Seite (gleicher Ursprung)", 403
    if not _t2d_local(rq.remote_addr):
        return "nur aus dem lokalen Netz", 403
    j = rq.get_json(silent=True) or {}
    if j.get("confirm") is not True:
        return "Bestaetigung fehlt", 400
    return None, j


def _t2d_stick2_post():
    """Knopf: Stick 2 auf 5C (action alarm) oder zurueck in den Hobby-Betrieb (action zurueck). Rueckgabe gibt es nur hier."""
    from flask import jsonify, request as rq
    err, j = _t2d_check(rq)
    if err:
        return jsonify({"ok": False, "error": err}), j
    act = j.get("action")
    if act not in ("alarm", "zurueck"):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _T2D_LOCK:
        d = _lz_mgr.takeover_set(_SDR_BASE, act == "alarm", "manual", "Knopf auf der Lage-Seite" if act == "alarm" else "", "dashboard")
    print("teil2: Knopf -> Stick 2 %s" % ("auf 5C (Alarm)" if act == "alarm" else "zurueck in den Hobby-Betrieb"), flush=True)
    return jsonify({"ok": True, "on": d.get("on"), "since": d.get("since"), "src": d.get("src")})


def _t2d_autosend_post():
    """Schalter Auto-Versand an Mesh 1 (Kill-Switch)."""
    from flask import jsonify, request as rq
    err, j = _t2d_check(rq)
    if err:
        return jsonify({"ok": False, "error": err}), j
    if not isinstance(j.get("on"), bool):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _T2D_LOCK:
        st = _lz_mesh.set_auto(_SDR_BASE, j["on"], "dashboard")
    print("teil2: Auto-Versand echter Alarme an Mesh 1 jetzt %s" % ("AN" if st["on"] else "AUS"), flush=True)
    return jsonify({"ok": True, "on": st["on"]})


_T2D_JS = r"""
(function(){var D=null,BUSY=0;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function ninaCard(){var ts=document.querySelectorAll('.title');for(var i=0;i<ts.length;i++){if(/\bNINA\b/i.test(ts[i].textContent||'')){var c=ts[i].closest('.card');if(c&&c.id!=='br24Tile'&&c.id!=='t2Tile')return c;}}return null;}
var BS='margin-top:10px;width:100%;background:#1e3a5f;color:#93c5fd;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:0.95rem';
var BR='margin-top:10px;width:100%;background:#3f1d1d;color:#fca5a5;border:1px solid #7f1d1d;border-radius:8px;padding:10px 12px;font-size:0.95rem';
function fmt(t){return t?new Date(t*1000).toLocaleString('de-DE',{timeZone:'Europe/Berlin',day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'–';}
function line(t,cls){var l=el('div',cls||'small');l.style.cssText='white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px';t.appendChild(l);return l;}
function post(url,body,ask,st){if(BUSY)return;if(!window.confirm(ask))return;BUSY=1;st.textContent='…';body.confirm=true;
fetch(url,{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-T2':'1'},body:JSON.stringify(body)})
.then(function(r){return r.json();}).then(function(j){st.textContent=j.ok?'erledigt':('nicht erledigt: '+(j.error||'Fehler'));})
.catch(function(){st.textContent='nicht erledigt: Netzfehler';}).then(function(){BUSY=0;load();});}
function tile(){var n=ninaCard();if(!n||!D)return;var after=document.getElementById('br24Tile')||n;var t=document.getElementById('t2Tile');
if(!t){t=el('div',n.className);t.id='t2Tile';t.appendChild(el('div','title','Sticks & Alarm-Automatik'));t._l=[line(t,'t2-l1'),line(t),line(t),line(t),line(t),line(t)];
t._b1=el('button','t2-btn');t._b1.type='button';t.appendChild(t._b1);t._b2=el('button','t2-btn');t._b2.type='button';t.appendChild(t._b2);t._st=line(t);
t._b1.addEventListener('click',function(){var on=D.takeover&&D.takeover.on;post('/api/t2/stick2',{action:on?'zurueck':'alarm'},on?'Stick 2 wirklich zurück in den Hobby-Betrieb (RDS, QRM, 433, APRS)?\n\n5C (ASA DE) wird dann nicht mehr empfangen.':'Stick 2 jetzt fest auf 5C (ASA DE) schalten?\n\nZurück nur über diesen Knopf.',t._st);});
t._b2.addEventListener('click',function(){var on=D.autosend&&D.autosend.on;post('/api/t2/autosend',{on:!on},on?'Auto-Versand echter Alarme an Mesh 1 AUSschalten?':'Auto-Versand echter Alarme an Mesh 1 EINschalten?\n\nNur echte Alarme (ASA, BR24-Notfall; NINA über die bestehende NINA-Automatik), nie Tests, eine Meldung je Alarm, gleicher Inhalt erst nach 6 h, höchstens 3 je Stunde.',t._st);});}
if(after.nextSibling!==t)after.parentNode.insertBefore(t,after.nextSibling);
var to=D.takeover||{},r=D.roles||{},s1=r.s1||{},s2=r.s2||{},a=D.asa||{},f=(D.fig||{})['11D']||{},as=D.autosend||{},L=t._l;
L[0].textContent='Stick 1'+(s1.sn?' SN '+s1.sn:'')+': '+(s1.mode||'–');
L[1].textContent=to.on?('Stick 2: ALARM – fest auf 5C seit '+fmt(to.since)+' ('+(to.src||'?')+(to.why?': '+to.why:'')+')'):('Stick 2'+(s2.sn?' SN '+s2.sn:'')+': '+(s2.mode||'–'));
L[1].style.color=to.on?'#ef4444':'';L[1].style.fontWeight=to.on?'600':'';
L[2].textContent='ASA-Dienst: '+(a.status||'–')+(a.text?' · '+a.text:'');L[2].style.color=a.status==='ASA_INTERRUPTED'?'#ef4444':'#94a3b8';
var ti=(f.tii||[]).map(function(x){return ('0'+x.main).slice(-2)+'/'+('0'+x.sub).slice(-2);}).join(', ');
L[3].textContent='11D: '+(f.ens||'–')+(f.ecc?' · ECC '+f.ecc:'')+(f.lto!=null?' · LTO '+(f.lto>=0?'+':'')+f.lto+' h':'')+' · TII '+(ti||'–')+(f.t?' · '+fmt(f.t):'');L[3].style.color='#94a3b8';
L[4].textContent='Auto-Versand Mesh 1: '+(as.on?'AN':'AUS')+(as.hour_n!=null?' · letzte Stunde '+as.hour_n+'/'+as.limit_h:'')+((as.recent&&as.recent[0])?' · zuletzt '+fmt(as.recent[0].last_try)+' '+(as.recent[0].ok===1?'ok':'FEHLER'):'');
L[4].style.color=as.on?'#22c55e':'#94a3b8';
var real=(D.alarms||[]).filter(function(x){return x.real;});L[5].textContent=real.length?('Echter Alarm: '+real[0].src+' – '+real[0].text):'kein echter Alarm';L[5].style.color=real.length?'#ef4444':'#94a3b8';
t._b1.textContent=to.on?'↩ Stick 2 zurück in den Hobby-Betrieb':'⚠ Stick 2 jetzt auf 5C (Alarm)';t._b1.setAttribute('style',to.on?BS:BR);
t._b2.textContent=as.on?'📡 Auto-Versand Mesh 1 ausschalten':'📡 Auto-Versand Mesh 1 einschalten';t._b2.setAttribute('style',BS);}
function load(){fetch('/api/t2/status',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.ok){D=j;tile();}}).catch(function(){});}
try{D=JSON.parse(document.getElementById('t2-data').textContent);}catch(e){}
tile();setInterval(tile,2000);setInterval(load,20000);})();
"""


def _t2d_after(resp):
    try:
        from flask import request as _t2d_rq
        if (_t2d_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="t2-js"' not in body:
                try:
                    data = _sdr_json.dumps(_t2d_status(), ensure_ascii=False, default=str).replace("<", "\\u003c")
                except Exception:
                    data = "null"
                add = '<script type="application/json" id="t2-data">' + data + '</script><script id="t2-js">' + _T2D_JS + '</script>'
                j = body.rfind("</body>")
                body = (body[:j] + add + body[j:]) if j >= 0 else (body + add)
                resp.set_data(body)
    except Exception as e:
        print("teil2 Kachel:", e, flush=True)
    return resp


def _t2d_live_wrap():
    orig = _lz_mgr.live
    if getattr(orig, "_t2", False):
        return False

    def live(base, path=None, br=None, extra=None, now=None):
        out = orig(base, path, br, extra, now)
        try:
            out["asa_status"] = _lz_mgr.asa_monitor(base, path, now)["status"]
            out["stick2_takeover"] = _lz_mgr.takeover_load(base)["on"]
        except Exception as e:
            print("teil2 live:", e, flush=True)
        return out
    live._t2 = True
    _lz_mgr.live = live
    return True


def _t2d_selftest():
    import tempfile
    import os as _o
    d = tempfile.mkdtemp()
    p = _o.path.join(d, "lagezentrum.db")
    sent = []

    def fake(text, channel=0):
        sent.append((text, channel))
        return True
    fake.selftest = True
    now = 1790000000
    br = {"state": "rot", "why": {"t": now - 20, "src": "BR24 UKW", "kind": "RDS Notfall", "text": "RDS-Notfallgruppe 9A empfangen (3x in 10 s)", "cls": "rot"}}
    ctx = {"nina": [{"city": "Nürnberg", "title": "Gefahr", "id": "mow.t2", "msgType": "Alert"}], "br24": br}
    nd0, _T2D["nina"] = _T2D["nina"], {"mow.t2": {"severity": "Severe", "status": "Actual", "t": now}}
    ep0 = _lz_mgr._T2.get("br_ep")
    _lz_mgr._T2["br_ep"] = {}
    try:
        al, rep = _t2d_tick(now, fake, d, p, ctx)
        assert sent == [] and not rep["on"] and _lz_mgr.takeover_load(d)["on"], rep                       # Schalter AUS: nichts; Uebernahme trotzdem
        assert {a["src"] for a in al if a["real"]} == {"NINA", "BR24"} and _lz_mgr.alarm_identifier(al) == 2
        _lz_mesh.set_auto(d, True, "selftest", now)
        al, rep = _t2d_tick(now + 30, fake, d, p, ctx)
        assert len(sent) == 1 and sent[0][1] == 0 and sent[0][0].startswith("ALARM BR24") and any(x["why"] == T2D_NINA_DUP for x in rep["skip"]), (sent, rep)
        _t2d_tick(now + 60, fake, d, p, ctx)
        br2 = {"state": "rot", "why": dict(br["why"], t=now + 50)}
        _t2d_tick(now + 70, fake, d, p, {"nina": ctx["nina"], "br24": br2})
        assert len(sent) == 1                                                                             # eine Meldung je Alarm (auch mit neuem Zeitstempel)
        t30 = {"state": "grau", "test": True, "why": {"t": now, "src": "BR24 UKW", "kind": "RDS PTY 30 Alarmtest", "text": "PTY 30 Alarmtest", "cls": "test"}}
        _t2d_tick(now + 90, fake, d, p, {"nina": [], "br24": t30})
        assert len(sent) == 1 and _lz_dbm.mesh_hash_since(_lz_mesh.msg_hash(sent[0][0], _lz_mesh.AUTO_LOGCH), now, p) is True   # Test nie, Protokoll da
        _lz_mgr.takeover_set(d, False, now=now + 100)
        _t2d_tick(now + 120, fake, d, p, ctx)
        assert not _lz_mgr.takeover_load(d)["on"] and len(sent) == 1                                      # Rueckgabe bleibt, kein erneutes Kapern
        assert _t2d_local("127.0.0.1") and _t2d_local("192.168.178.20") and _t2d_local("100.101.1.2") and _t2d_local("::ffff:10.0.0.3")
        assert not _t2d_local("8.8.8.8") and not _t2d_local("") and not _t2d_local("2a00:1450::1")
        assert callable(globals().get("send_meshtastic")) and "send_meshtastic" in _t2d_tick.__code__.co_names
    finally:
        _T2D["nina"] = nd0
        _lz_mgr._T2["br_ep"] = ep0 if isinstance(ep0, dict) else {}
    return "teil2 selftest ok (Schalter AUS = nichts, Uebernahme automatisch, BR24-Notfall 1x an Mesh 1 Kanal 0, NINA nicht doppelt, PTY 30 nie, Rueckgabe nur per Knopf, nur lokal)"


try:
    if _lz_mgr is None or _lz_mesh is None or _lz_dbm is None or not hasattr(_lz_mesh, "auto_send") or not hasattr(_lz_mgr, "takeover_auto"):
        raise RuntimeError("Module Teil 2 fehlen (%s)" % (_LZ.get("err") or "mesh_router/sdr_manager alt"))
    _lz_dbm.migrate_t2(_LZ_PATH)
    _T2D["selftest"] = _t2d_selftest()
    _T2D["ok"] = True
    for _t2d_rule, _t2d_ep, _t2d_fn, _t2d_m in (("/api/t2/status", "t2_status", _t2d_api, "GET"), ("/api/t2/stick2", "t2_stick2", _t2d_stick2_post, "POST"),
                                                 ("/api/t2/autosend", "t2_autosend", _t2d_autosend_post, "POST")):
        if _t2d_ep not in app.view_functions:
            app.add_url_rule(_t2d_rule, endpoint=_t2d_ep, view_func=_t2d_fn, methods=[_t2d_m])
    if not any(getattr(f, "__name__", "") == "_t2d_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_t2d_after)
    _t2d_live_wrap()
    if __name__ == "__main__" and not _T2D["started"]:
        _t2d_thr.Thread(target=_t2d_loop, name="teil2", daemon=True).start()
        _T2D["started"] = True
    print("teil2 aktiv: %s; Auto-Versand Mesh 1 %s; Stick 2 %s" % (_T2D["selftest"], "AN" if _lz_mesh.auto_state(_SDR_BASE)["on"] else "AUS",
                                                                   "ALARM 5C" if _lz_mgr.takeover_load(_SDR_BASE)["on"] else "Hobby"), flush=True)
except Exception as _t2d_e:
    _T2D.update(ok=False, err=repr(_t2d_e)[:200])
    fetch_nina = _t2d_orig_fetch_nina
    print("teil2 FEHLER (Teil 2 aus, alter Stand aktiv):", repr(_t2d_e)[:300], flush=True)
# ===== /teil2 =====
T3B2A_EOF
EXPECT_B2N="96fd0b4f9b3a358cd9ca34f53c9816c2ab41f4afa5447e5c31eda15168280db7"
cat > "$W/t2_dash_block.py" << 'T3B2N_EOF'
# ===== teil2: Teil 2 von 4 - Stick-2-Uebernahme 5C bei echtem Alarm (NINA Severe/Extreme, echter BR24-Notfall, ASA-Echtalarm) oder per Knopf, Rueckgabe NUR per Knopf (POST, gleicher Ursprung, lokal, Bestaetigung); Auto-Versand echter Alarme an Mesh 1 ueber denselben Sendeweg wie der Knopf "An Mesh 1 senden" (Schalter, Standard AUS, eine Meldung je Alarm, 6 h, max 3/h, Tests nie); ASA-Ueberwachung; FIG 0/9/TII in lagezentrum.db; GPIO vorbereitet (AUS); Kachel auf der Lage-Seite =====
import threading as _t2d_thr
import time as _t2d_time
import re as _t2d_re

_T2D = {"ok": False, "err": None, "selftest": None, "nina": {}, "alarms": [], "rep": None, "gpio": None, "t": 0, "n": 0, "started": False, "takeover_ch": None}
_T2D_LOCK = _t2d_thr.Lock()
T2D_TICK_S = 20                        # Pruefung alle 20 s im eigenen Faden (unabhaengig von Seitenaufrufen)
T2D_NINA_URL = "https://warnung.bund.de/api31/warnings/%s.json"   # amtliche Detaildaten (Schweregrad, Status) wie bei NINA/lageGeo
T2D_NINA_NEW_MAX = 3                   # je NINA-Abruf hoechstens 3 neue Detailabfragen
T2D_NINA_RETRY_S = 600                 # Details je Warnung hoechstens alle 10 min neu (NINA-Abruf alle 15 min)
T2D_ID_RE = _t2d_re.compile(r"^[A-Za-z0-9._:-]{3,140}$")
T2D_NINA_DUP = "NINA geht schon ueber die bestehende NINA-Automatik an Mesh 1 (maybe_mesh_nina) - Teil 2 sendet NINA nicht doppelt"


def _t2d_plain(t, n):
    """HTML-Reste (<br/>, Tags, &nbsp;) aus NINA-Texten entfernen, auf n Zeichen kuerzen."""
    t = _t2d_re.sub(r"<[^>]{0,200}>", " ", str(t or "")).replace("&nbsp;", " ").replace("&amp;", "&")
    return " ".join(t.split())[:n] or None


def _t2d_nina_detail(warnings, now=None):
    """Schweregrad/Status je aktiver NINA-Warnung holen (Cache im Speicher, je Warnung hoechstens alle 10 min neu, damit eine
    Hochstufung auf Severe/Extreme ankommt; je Abruf hoechstens 3, aelteste zuerst). Nur Lesen bei warnung.bund.de."""
    now = int(now or _t2d_time.time())
    n, ids = 0, []
    for w in warnings or []:
        wid = str(w.get("id") or "") if isinstance(w, dict) else ""
        if T2D_ID_RE.match(wid) and wid not in ids:
            c = _T2D["nina"].get(wid)
            if not c or now - c.get("t", 0) >= T2D_NINA_RETRY_S:
                ids.append(wid)
    for wid in sorted(ids, key=lambda k: (_T2D["nina"].get(k) or {}).get("t", 0)):
        if n >= T2D_NINA_NEW_MAX:
            break
        n += 1
        try:
            r = requests.get(T2D_NINA_URL % wid, timeout=8, headers={"User-Agent": "KaeswasserLage/1.0"})
            d = r.json() if r.status_code == 200 else None
            if not isinstance(d, dict):
                _T2D["nina"][wid] = dict(_T2D["nina"].get(wid) or {}, t=now, http=r.status_code)   # alter Schweregrad bleibt
                continue
            info = (d.get("info") or [{}])[0] if isinstance(d, dict) and isinstance(d.get("info"), list) and d.get("info") else {}
            _T2D["nina"][wid] = {"severity": info.get("severity") if isinstance(info, dict) else None, "status": d.get("status") if isinstance(d, dict) else None,
                                 "msgType": d.get("msgType") if isinstance(d, dict) else None, "t": now, "http": r.status_code}
            if isinstance(info, dict):   # Teil 3: Beschreibung, Handlungsempfehlung, Gebiet fuer die NINA-Detailmeldung
                _T2D["nina"][wid].update(headline=_t2d_plain(info.get("headline"), 120), desc=_t2d_plain(info.get("description"), 400),
                                         instr=_t2d_plain(info.get("instruction"), 300),
                                         area=[_t2d_plain(x.get("areaDesc"), 60) for x in (info.get("area") or [])[:6] if isinstance(x, dict) and x.get("areaDesc")])
        except Exception as e:
            old = _T2D["nina"].get(wid) or {}
            _T2D["nina"][wid] = dict(old, t=now, err=str(e)[:80])   # alter Schweregrad bleibt bei Netzfehler
    if len(_T2D["nina"]) > 300:
        for k in sorted(_T2D["nina"], key=lambda k: _T2D["nina"][k].get("t", 0))[:100]:
            _T2D["nina"].pop(k, None)
    return n


_t2d_orig_fetch_nina = fetch_nina


def fetch_nina():
    r = _t2d_orig_fetch_nina()
    try:
        if _T2D["ok"] and isinstance(r, list):
            _t2d_nina_detail(r)
    except Exception as e:
        print("teil2 NINA-Details:", e, flush=True)
    return r


def _t2d_cfg():
    try:
        c = _sdr_load("sdr_config.json", {}) or {}
        return c if isinstance(c, dict) else {}
    except Exception:
        return {}


def _t2d_manual_sent(now):
    """Texte, die in den letzten 6 h per Knopf an Mesh 1 gingen (lageMesh1, nur im Speicher)."""
    try:
        return [x[2] for x in (globals().get("_lm1_log") or []) if now - x[0] < _lz_mesh.AUTO_SAME_S]
    except Exception:
        return []


def _t2d_tick(now=None, send_fn=None, base=None, path=None, ctx=None):
    """Alarme erkennen -> Stick-2-Uebernahme (immer automatisch) -> Auto-Versand (nur wenn Schalter AN) -> GPIO (vorbereitet, AUS)."""
    now = int(now or _t2d_time.time())
    base, path = base or _SDR_BASE, path or _LZ_PATH
    if ctx is None:
        _lz_sync(30)
        ctx = _lz_ctx()
    _lz_mgr.t2_sync(base, path, now)
    to0 = _lz_mgr.takeover_load(base)
    al = _lz_mgr.alarms_from(ctx.get("nina"), _T2D["nina"], ctx.get("br24"), _lz_dbm.active_events(now, path), now, to0.get("seen"))
    if callable(globals().get("maybe_mesh_nina")):
        for a in al:
            if a.get("src") == "NINA":
                a["dup_existing"] = T2D_NINA_DUP
    to, ch = _lz_mgr.takeover_auto(base, al, now)
    if ch and send_fn is None:
        _T2D["takeover_ch"] = now
        if to.get("on") and not to0.get("on"):
            print("teil2: echter Alarm -> Stick 2 auf 5C gekapert (Ausloeser %s: %s)" % (to.get("src"), str(to.get("why") or "")[:80]), flush=True)
        else:
            print("teil2: weiterer echter Alarm, Stick 2 %s" % ("schon auf 5C" if to.get("on") else "bleibt im Hobby-Betrieb (nur neue Alarme kapern)"), flush=True)
    boot = globals().get("mesh_auto_allowed")
    if callable(boot) and not boot() and send_fn is None:
        rep = {"on": _lz_mesh.auto_state(base)["on"], "t": now, "sent": [], "skip": [{"why": "Dashboard-Start: Mesh-Automatik erst nach %d s" % globals().get("MESH_BOOT_GUARD_SEC", 300)}]}
    else:
        rep = _lz_mesh.auto_send(al, send_fn or globals().get("send_dab_to_private_mesh") or send_meshtastic, base, path, now, _t2d_manual_sent(now))   # Teil 3: DAB nur .141
    gp = _lz_mgr.gpio_alarm(_lz_mgr.alarm_identifier(al), _t2d_cfg())
    _T2D.update(alarms=al, rep=rep, gpio=gp, t=now, n=_T2D["n"] + 1, err=None)
    return al, rep


def _t2d_loop():
    _t2d_time.sleep(30)
    while True:
        try:
            with _T2D_LOCK:
                _t2d_tick()
        except Exception as e:
            _T2D["err"] = str(e)[:160]
            print("teil2 Pruefung:", e, flush=True)
        _t2d_time.sleep(T2D_TICK_S)


def _t2d_autosend_info(now):
    st = _lz_mesh.auto_state(_SDR_BASE)
    rep = _T2D.get("rep") or {}
    return {"on": st["on"], "t": st["t"], "by": st["by"], "limit_h": _lz_mesh.AUTO_HOUR_MAX, "same_h": _lz_mesh.AUTO_SAME_S // 3600,
            "hour_n": _lz_dbm.mesh_auto_count(now - 3600, _LZ_PATH), "recent": _lz_dbm.mesh_auto_recent(5, _LZ_PATH),
            "last_skip": (rep.get("skip") or [])[:6], "last_sent": rep.get("sent") or []}


def _t2d_status():
    now = int(_t2d_time.time())
    s = _lz_mgr.t2_status(_SDR_BASE, _LZ_PATH, now, alarms=_T2D.get("alarms"), autosend=_t2d_autosend_info(now), gpio=_T2D.get("gpio"))
    s["tick"] = {"t": _T2D["t"], "n": _T2D["n"], "err": _T2D["err"], "every_s": T2D_TICK_S, "thread": _T2D["started"]}
    st = _sdr_load("sdr_status.json", {}) or {}
    s["stick2_txt"] = ((st.get("stick2") or {}).get("txt") if isinstance(st.get("stick2"), dict) else None)
    s["dual"] = st.get("dual") if isinstance(st.get("dual"), dict) else None
    return s


def _t2d_api():
    from flask import jsonify
    try:
        return jsonify(_t2d_status())
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


def _t2d_same_origin(rq):
    base = rq.host_url.rstrip("/")
    o = rq.headers.get("Origin")
    if o is not None and o.rstrip("/") != base:
        return False
    ref = rq.headers.get("Referer") or ""
    if o is None and not (ref == base or ref.startswith(base + "/")):
        return False
    sfs = rq.headers.get("Sec-Fetch-Site")
    if sfs is not None and sfs != "same-origin":
        return False
    return rq.headers.get("X-T2") == "1" and (rq.mimetype or "") == "application/json"


def _t2d_local(addr):
    """Nur aus dem Heimnetz/Tailscale/vom Pi selbst (keine oeffentliche Adresse)."""
    import ipaddress
    try:
        a = ipaddress.ip_address(str(addr or "").split("%")[0])
        if getattr(a, "ipv4_mapped", None):
            a = a.ipv4_mapped
        return bool(a.is_loopback or a.is_private or (a.version == 4 and a in ipaddress.ip_network("100.64.0.0/10")))
    except Exception:
        return False


def _t2d_check(rq):
    if not _t2d_same_origin(rq):
        return "nur von der Lage-Seite (gleicher Ursprung)", 403
    if not _t2d_local(rq.remote_addr):
        return "nur aus dem lokalen Netz", 403
    j = rq.get_json(silent=True) or {}
    if j.get("confirm") is not True:
        return "Bestaetigung fehlt", 400
    return None, j


def _t2d_stick2_post():
    """Knopf: Stick 2 auf 5C (action alarm) oder zurueck in den Hobby-Betrieb (action zurueck). Rueckgabe gibt es nur hier."""
    from flask import jsonify, request as rq
    err, j = _t2d_check(rq)
    if err:
        return jsonify({"ok": False, "error": err}), j
    act = j.get("action")
    if act not in ("alarm", "zurueck"):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _T2D_LOCK:
        d = _lz_mgr.takeover_set(_SDR_BASE, act == "alarm", "manual", "Knopf auf der Lage-Seite" if act == "alarm" else "", "dashboard")
    print("teil2: Knopf -> Stick 2 %s" % ("auf 5C (Alarm)" if act == "alarm" else "zurueck in den Hobby-Betrieb"), flush=True)
    return jsonify({"ok": True, "on": d.get("on"), "since": d.get("since"), "src": d.get("src")})


def _t2d_autosend_post():
    """Schalter Auto-Versand an Mesh 1 (Kill-Switch)."""
    from flask import jsonify, request as rq
    err, j = _t2d_check(rq)
    if err:
        return jsonify({"ok": False, "error": err}), j
    if not isinstance(j.get("on"), bool):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _T2D_LOCK:
        st = _lz_mesh.set_auto(_SDR_BASE, j["on"], "dashboard")
    print("teil2: Auto-Versand echter Alarme an Mesh 1 jetzt %s" % ("AN" if st["on"] else "AUS"), flush=True)
    return jsonify({"ok": True, "on": st["on"]})


_T2D_JS = r"""
(function(){var D=null,BUSY=0;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function ninaCard(){var ts=document.querySelectorAll('.title');for(var i=0;i<ts.length;i++){if(/\bNINA\b/i.test(ts[i].textContent||'')){var c=ts[i].closest('.card');if(c&&c.id!=='br24Tile'&&c.id!=='t2Tile')return c;}}return null;}
var BS='margin-top:10px;width:100%;background:#1e3a5f;color:#93c5fd;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:0.95rem';
var BR='margin-top:10px;width:100%;background:#3f1d1d;color:#fca5a5;border:1px solid #7f1d1d;border-radius:8px;padding:10px 12px;font-size:0.95rem';
function fmt(t){return t?new Date(t*1000).toLocaleString('de-DE',{timeZone:'Europe/Berlin',day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'–';}
function line(t,cls){var l=el('div',cls||'small');l.style.cssText='white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px';t.appendChild(l);return l;}
function post(url,body,ask,st){if(BUSY)return;if(!window.confirm(ask))return;BUSY=1;st.textContent='…';body.confirm=true;
fetch(url,{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-T2':'1'},body:JSON.stringify(body)})
.then(function(r){return r.json();}).then(function(j){st.textContent=j.ok?'erledigt':('nicht erledigt: '+(j.error||'Fehler'));})
.catch(function(){st.textContent='nicht erledigt: Netzfehler';}).then(function(){BUSY=0;load();});}
function tile(){var n=ninaCard();if(!n||!D)return;var after=document.getElementById('br24Tile')||n;var t=document.getElementById('t2Tile');
if(!t){t=el('div',n.className);t.id='t2Tile';t.appendChild(el('div','title','Sticks & Alarm-Automatik'));t._l=[line(t,'t2-l1'),line(t),line(t),line(t),line(t),line(t)];
t._b1=el('button','t2-btn');t._b1.type='button';t.appendChild(t._b1);t._b2=el('button','t2-btn');t._b2.type='button';t.appendChild(t._b2);t._st=line(t);
t._b1.addEventListener('click',function(){var on=D.takeover&&D.takeover.on;post('/api/t2/stick2',{action:on?'zurueck':'alarm'},on?'Stick 2 wirklich zurück in den Hobby-Betrieb (RDS, QRM, 433, APRS)?\n\n5C (ASA DE) wird dann nicht mehr empfangen.':'Stick 2 jetzt fest auf 5C (ASA DE) schalten?\n\nZurück nur über diesen Knopf.',t._st);});
t._b2.addEventListener('click',function(){var on=D.autosend&&D.autosend.on;post('/api/t2/autosend',{on:!on},on?'Auto-Versand echter Alarme an Mesh 1 AUSschalten?':'Auto-Versand echter Alarme an Mesh 1 EINschalten?\n\nNur echte Alarme (ASA, BR24-Notfall; NINA über die bestehende NINA-Automatik), nie Tests, eine Meldung je Alarm, gleicher Inhalt erst nach 6 h, höchstens 3 je Stunde.',t._st);});}
if(after.nextSibling!==t)after.parentNode.insertBefore(t,after.nextSibling);
var to=D.takeover||{},r=D.roles||{},s1=r.s1||{},s2=r.s2||{},a=D.asa||{},f=(D.fig||{})['11D']||{},as=D.autosend||{},L=t._l;
L[0].textContent='Stick 1'+(s1.sn?' SN '+s1.sn:'')+': '+(s1.mode||'–');
L[1].textContent=to.on?('Stick 2: ALARM – fest auf 5C seit '+fmt(to.since)+' ('+(to.src||'?')+(to.why?': '+to.why:'')+')'):('Stick 2'+(s2.sn?' SN '+s2.sn:'')+': '+(s2.mode||'–'));
L[1].style.color=to.on?'#ef4444':'';L[1].style.fontWeight=to.on?'600':'';
L[2].textContent='ASA-Dienst: '+(a.status||'–')+(a.text?' · '+a.text:'');L[2].style.color=a.status==='ASA_INTERRUPTED'?'#ef4444':'#94a3b8';
var ti=(f.tii||[]).map(function(x){return ('0'+x.main).slice(-2)+'/'+('0'+x.sub).slice(-2);}).join(', ');
L[3].textContent='11D: '+(f.ens||'–')+(f.ecc?' · ECC '+f.ecc:'')+(f.lto!=null?' · LTO '+(f.lto>=0?'+':'')+f.lto+' h':'')+' · TII '+(ti||'–')+(f.t?' · '+fmt(f.t):'');L[3].style.color='#94a3b8';
L[4].textContent='Auto-Versand Mesh 1: '+(as.on?'AN':'AUS')+(as.hour_n!=null?' · letzte Stunde '+as.hour_n+'/'+as.limit_h:'')+((as.recent&&as.recent[0])?' · zuletzt '+fmt(as.recent[0].last_try)+' '+(as.recent[0].ok===1?'ok':'FEHLER'):'');
L[4].style.color=as.on?'#22c55e':'#94a3b8';
var real=(D.alarms||[]).filter(function(x){return x.real;});L[5].textContent=real.length?('Echter Alarm: '+real[0].src+' – '+real[0].text):'kein echter Alarm';L[5].style.color=real.length?'#ef4444':'#94a3b8';
t._b1.textContent=to.on?'↩ Stick 2 zurück in den Hobby-Betrieb':'⚠ Stick 2 jetzt auf 5C (Alarm)';t._b1.setAttribute('style',to.on?BS:BR);
t._b2.textContent=as.on?'📡 Auto-Versand Mesh 1 ausschalten':'📡 Auto-Versand Mesh 1 einschalten';t._b2.setAttribute('style',BS);}
function load(){fetch('/api/t2/status',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.ok){D=j;tile();}}).catch(function(){});}
try{D=JSON.parse(document.getElementById('t2-data').textContent);}catch(e){}
tile();setInterval(tile,2000);setInterval(load,20000);})();
"""


def _t2d_after(resp):
    try:
        from flask import request as _t2d_rq
        if (_t2d_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="t2-js"' not in body:
                try:
                    data = _sdr_json.dumps(_t2d_status(), ensure_ascii=False, default=str).replace("<", "\\u003c")
                except Exception:
                    data = "null"
                add = '<script type="application/json" id="t2-data">' + data + '</script><script id="t2-js">' + _T2D_JS + '</script>'
                j = body.rfind("</body>")
                body = (body[:j] + add + body[j:]) if j >= 0 else (body + add)
                resp.set_data(body)
    except Exception as e:
        print("teil2 Kachel:", e, flush=True)
    return resp


def _t2d_live_wrap():
    orig = _lz_mgr.live
    if getattr(orig, "_t2", False):
        return False

    def live(base, path=None, br=None, extra=None, now=None):
        out = orig(base, path, br, extra, now)
        try:
            out["asa_status"] = _lz_mgr.asa_monitor(base, path, now)["status"]
            out["stick2_takeover"] = _lz_mgr.takeover_load(base)["on"]
        except Exception as e:
            print("teil2 live:", e, flush=True)
        return out
    live._t2 = True
    _lz_mgr.live = live
    return True


def _t2d_selftest():
    import tempfile
    import os as _o
    d = tempfile.mkdtemp()
    p = _o.path.join(d, "lagezentrum.db")
    sent = []

    def fake(text, channel=0):
        sent.append((text, channel))
        return True
    fake.selftest = True
    now = 1790000000
    br = {"state": "rot", "why": {"t": now - 20, "src": "BR24 UKW", "kind": "RDS Notfall", "text": "RDS-Notfallgruppe 9A empfangen (3x in 10 s)", "cls": "rot"}}
    ctx = {"nina": [{"city": "Nürnberg", "title": "Gefahr", "id": "mow.t2", "msgType": "Alert"}], "br24": br}
    nd0, _T2D["nina"] = _T2D["nina"], {"mow.t2": {"severity": "Severe", "status": "Actual", "t": now}}
    ep0 = _lz_mgr._T2.get("br_ep")
    _lz_mgr._T2["br_ep"] = {}
    try:
        al, rep = _t2d_tick(now, fake, d, p, ctx)
        assert sent == [] and not rep["on"] and _lz_mgr.takeover_load(d)["on"], rep                       # Schalter AUS: nichts; Uebernahme trotzdem
        assert {a["src"] for a in al if a["real"]} == {"NINA", "BR24"} and _lz_mgr.alarm_identifier(al) == 2
        _lz_mesh.set_auto(d, True, "selftest", now)
        al, rep = _t2d_tick(now + 30, fake, d, p, ctx)
        assert len(sent) == 1 and sent[0][1] == 0 and sent[0][0].startswith("ALARM BR24") and any(x["why"] == T2D_NINA_DUP for x in rep["skip"]), (sent, rep)
        _t2d_tick(now + 60, fake, d, p, ctx)
        br2 = {"state": "rot", "why": dict(br["why"], t=now + 50)}
        _t2d_tick(now + 70, fake, d, p, {"nina": ctx["nina"], "br24": br2})
        assert len(sent) == 1                                                                             # eine Meldung je Alarm (auch mit neuem Zeitstempel)
        t30 = {"state": "grau", "test": True, "why": {"t": now, "src": "BR24 UKW", "kind": "RDS PTY 30 Alarmtest", "text": "PTY 30 Alarmtest", "cls": "test"}}
        _t2d_tick(now + 90, fake, d, p, {"nina": [], "br24": t30})
        assert len(sent) == 1 and _lz_dbm.mesh_hash_since(_lz_mesh.msg_hash(sent[0][0], _lz_mesh.AUTO_LOGCH), now, p) is True   # Test nie, Protokoll da
        _lz_mgr.takeover_set(d, False, now=now + 100)
        _t2d_tick(now + 120, fake, d, p, ctx)
        assert not _lz_mgr.takeover_load(d)["on"] and len(sent) == 1                                      # Rueckgabe bleibt, kein erneutes Kapern
        assert _t2d_local("127.0.0.1") and _t2d_local("192.168.178.20") and _t2d_local("100.101.1.2") and _t2d_local("::ffff:10.0.0.3")
        assert not _t2d_local("8.8.8.8") and not _t2d_local("") and not _t2d_local("2a00:1450::1")
        assert callable(globals().get("send_meshtastic")) and "send_meshtastic" in _t2d_tick.__code__.co_names
    finally:
        _T2D["nina"] = nd0
        _lz_mgr._T2["br_ep"] = ep0 if isinstance(ep0, dict) else {}
    return "teil2 selftest ok (Schalter AUS = nichts, Uebernahme automatisch, BR24-Notfall 1x an Mesh 1 Kanal 0, NINA nicht doppelt, PTY 30 nie, Rueckgabe nur per Knopf, nur lokal)"


try:
    if _lz_mgr is None or _lz_mesh is None or _lz_dbm is None or not hasattr(_lz_mesh, "auto_send") or not hasattr(_lz_mgr, "takeover_auto"):
        raise RuntimeError("Module Teil 2 fehlen (%s)" % (_LZ.get("err") or "mesh_router/sdr_manager alt"))
    _lz_dbm.migrate_t2(_LZ_PATH)
    _T2D["selftest"] = _t2d_selftest()
    _T2D["ok"] = True
    for _t2d_rule, _t2d_ep, _t2d_fn, _t2d_m in (("/api/t2/status", "t2_status", _t2d_api, "GET"), ("/api/t2/stick2", "t2_stick2", _t2d_stick2_post, "POST"),
                                                 ("/api/t2/autosend", "t2_autosend", _t2d_autosend_post, "POST")):
        if _t2d_ep not in app.view_functions:
            app.add_url_rule(_t2d_rule, endpoint=_t2d_ep, view_func=_t2d_fn, methods=[_t2d_m])
    if not any(getattr(f, "__name__", "") == "_t2d_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_t2d_after)
    _t2d_live_wrap()
    if __name__ == "__main__" and not _T2D["started"]:
        _t2d_thr.Thread(target=_t2d_loop, name="teil2", daemon=True).start()
        _T2D["started"] = True
    print("teil2 aktiv: %s; Auto-Versand Mesh 1 %s; Stick 2 %s" % (_T2D["selftest"], "AN" if _lz_mesh.auto_state(_SDR_BASE)["on"] else "AUS",
                                                                   "ALARM 5C" if _lz_mgr.takeover_load(_SDR_BASE)["on"] else "Hobby"), flush=True)
except Exception as _t2d_e:
    _T2D.update(ok=False, err=repr(_t2d_e)[:200])
    fetch_nina = _t2d_orig_fetch_nina
    print("teil2 FEHLER (Teil 2 aus, alter Stand aktiv):", repr(_t2d_e)[:300], flush=True)
# ===== /teil2 =====
T3B2N_EOF
EXPECT_B3="cc7639e76b26cde1007ded55267020cfd3c4f2a2169dfe3a4b042108cbadb922"
cat > "$W/t3_dash_block.py" << 'T3B3_EOF'
# ===== teil3: Meshtastic-Routing und Priorisierung - Mesh 2 (.140) nur NINA, Mesh 1 (.141) NINA + exklusiv DAB+; NINA an beide Knoten Kanal 0, Details per Warteschlange nach 60 s bei freiem Kanal; DAB+ Vorrang auf Mesh 1; Dedup ueber mesh_log; kein neuer Socket, keine neue POST-Route =====
import threading as _t3_thr
import time as _t3_time
import json as _t3_json

T3_TICK_S = 5                 # Warteschlange alle 5 s pruefen
T3_FIRST_S = 60               # erster Lauf 60 s nach Start (und erst nach der Mesh-Startsperre)
T3_NOTE_S = 6 * 3600          # Hinweis bei Knopf, wenn gleicher Inhalt < 6 h schon gesendet
T3_HEALTH = {"m1": "http://127.0.0.1:5001/health", "m2": "http://127.0.0.1:5002/health"}   # nur lesen
_T3S = {"ok": False, "err": None, "selftest": None, "started": False, "t": 0, "n": 0, "tick_err": None, "last_send": {"m1": 0, "m2": 0},
        "free": {}, "dab": [], "notes": [], "rep": [], "inner": {}, "tx": {}, "cells": [], "prev": {}, "fake": None, "cleanup_t": 0}
_T3_LOCK = _t3_thr.RLock()
_T3_TLS = _t3_thr.local()


def _t3_now():
    f = (_T3S.get("fake") or {}).get("now")
    return int(f() if callable(f) else _t3_time.time())


def _t3_say(*a):
    """Ausgabe ins Journal - im Selbsttest still (dort wird nichts gesendet)."""
    if not _T3S.get("fake"):
        print(*a, flush=True)


def _t3_paths():
    f = _T3S.get("fake") or {}
    return f.get("base") or _SDR_BASE, f.get("path") or _LZ_PATH


def _t3_health(node):
    """GET /health der Bridge (nur lesen). node: "m1"/"m2" oder Port 5001/5002 -> dict | None"""
    node = {5001: "m1", 5002: "m2"}.get(node, node)
    if node not in T3_HEALTH:
        return None
    f = (_T3S.get("fake") or {}).get("health")
    if callable(f):
        return f(node)
    try:
        r = requests.get(T3_HEALTH[node], timeout=3)
        d = r.json() if r.status_code == 200 else None
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def _t3_sent(node, now=None):
    _T3S["last_send"][node] = int(now or _t3_now())


def _t3_kind():
    try:
        from flask import has_request_context
        if has_request_context():
            return "manuell"
    except Exception:
        pass
    tls = globals().get("_fh2_tls")
    return "auto:%s" % ((getattr(tls, "tag", None) if tls is not None else None) or "sonst")


def _t3_note_for(node, text, channel, kind, now=None, path=None):
    """Knopf: gleicher Inhalt schon gesendet? -> Hinweistext | None (sperrt nie)."""
    try:
        if kind != "manuell" or not str(text or "").strip():
            return None
        now = int(now or _t3_now())
        last = _lz_dbm.mesh_last(_lz_mesh.nina_hash(text, node, channel), path or _t3_paths()[1])
        if last and last.get("ok") == 1 and now - int(last.get("created") or 0) < T3_NOTE_S:
            return "Hinweis: gleicher Inhalt ging schon vor %d min an %s (Kanal %d) - trotzdem gesendet" % (
                (now - int(last["created"])) // 60, _lz_mesh.NODES[node]["name"], int(channel or 0))
    except Exception as e:
        print("teil3 Hinweis:", e, flush=True)
    return None


def _t3_add_note(note):
    if not note:
        return
    _T3S["notes"] = ([{"t": _t3_now(), "text": note}] + _T3S["notes"])[:10]
    try:
        from flask import g, has_request_context
        if has_request_context():
            g._t3_notes = (getattr(g, "_t3_notes", None) or []) + [note]
    except Exception:
        pass


def _t3_log(node, text, channel, ok, kind, now=None):
    """Jeden Versand mit Hash in mesh_log (Kanal 'm1:0' / 'm2:0')."""
    try:
        now = int(now or _t3_now())
        _lz_dbm.mesh_log_put(_lz_mesh.nina_hash(text, node, channel), _lz_mesh.nina_label(node, channel), now, "dashboard", str(text)[:300], bool(ok), kind, _t3_paths()[1])
        if ok:
            _t3_sent(node, now)
    except Exception as e:
        print("teil3 mesh_log:", e, flush=True)


def _t3_low(node, inner):
    """Unterste Ebene (unter funkHarden2): nur echte Versendungen protokollieren; Sendeweg unveraendert."""
    if node == "m1":
        def _t3_low_m1(text, channel=0, *a, **kw):  # teil3: Protokoll Mesh 1
            kind = _t3_kind()
            note = _t3_note_for("m1", text, channel, kind)
            ok = inner(text, channel, *a, **kw)
            _t3_log("m1", text, channel, ok, kind)
            _t3_add_note(note)
            return ok
        f = _t3_low_m1
    elif node == "m2":
        def _t3_low_m2(text, *a, **kw):  # teil3: Protokoll Mesh 2 (Kanal 0)
            kind = _t3_kind()
            note = _t3_note_for("m2", text, 0, kind)
            ok = inner(text, *a, **kw)
            _t3_log("m2", text, 0, ok, kind)
            _t3_add_note(note)
            return ok
        f = _t3_low_m2
    else:
        def _t3_low_cb(chunks, *a, **kw):  # teil3: Protokoll Mesh 2 Teilstuecke
            ok = inner(chunks, *a, **kw)
            kind = _t3_kind()
            for c in chunks or []:
                _t3_log("m2", str(c), 0, ok, kind)
            return ok
        f = _t3_low_cb
    f._t3 = True
    f.__wrapped__ = inner
    return f


def _t3_hook(fn, var, node):
    """In der funkHarden2-Huelle fn die innere Funktion (Freie Variable var) gegen die Protokoll-Ebene tauschen. -> innere Funktion"""
    names = fn.__code__.co_freevars
    if not getattr(fn, "_fh2", False) or var not in names or not fn.__closure__:
        raise RuntimeError("funkHarden2-Huelle %s fehlt" % getattr(fn, "__name__", "?"))
    cell = fn.__closure__[names.index(var)]
    inner = cell.cell_contents
    if getattr(inner, "_t3", False):
        return inner.__wrapped__
    if not callable(inner):
        raise RuntimeError("innere Funktion fehlt")
    cell.cell_contents = _t3_low(node, inner)
    _T3S["cells"].append((cell, inner))
    return inner


def _t3_m1_raw(text, channel=0):
    """Sendeweg Mesh 1 (send_meshtastic -> Bridge 127.0.0.1:5001 -> 192.168.178.141)."""
    return bool(_T3S["inner"]["m1"](text, int(channel or 0)))


def _t3_m2_raw(text, channel=0):
    """Sendeweg Mesh 2 (send_nina_to_bayern -> Bridge 127.0.0.1:5002 -> 192.168.178.140), nur Kanal 0."""
    if int(channel or 0) != 0:
        return False
    return bool(_T3S["inner"]["m2"](text))


def _t3_tx(node):
    f = (_T3S.get("fake") or {}).get("tx") or _T3S["tx"]
    return f[node]


def send_dab_to_private_mesh(text, channel=0):
    """DAB+-Meldung (ASA/BR24) NUR an Mesh 1 192.168.178.141, sofort, mit Vorrang. Nie an Mesh 2 192.168.178.140:
    harte Pruefung in mesh_router.dab_private_send (Kanal 0, Schalter AN, Bridge 5001 meldet Host .141). -> True/False"""
    try:
        base, path = _t3_paths()
        with _T3_LOCK:
            r = _lz_mesh.dab_private_send(text, _t3_tx("m1"), _t3_health, base, channel)
            if r["ok"]:
                _t3_sent("m1")
        _T3S["dab"] = ([{"t": _t3_now(), "ok": r["ok"], "why": r["why"], "host": r["host"], "text": str(text or "")[:120]}] + _T3S["dab"])[:6]
        if not r["ok"]:
            _t3_say("teil3 DAB nicht gesendet:", r["why"])
        return bool(r["ok"])
    except Exception as e:
        print("teil3 DAB:", e, flush=True)
        return False


send_dab_to_private_mesh._t3 = True


def _t3_refs(ctx, text):
    """Welche Meldungen stecken in der Kurzmeldung? -> {"ids": [...], "lines": [...]} | None (Entwarnungen ohne Details)"""
    try:
        ids, lines = [], []
        for w in ctx.get("items") or []:
            if not isinstance(w, dict) or not w.get("id") or w.get("cancel"):
                continue
            ln = _nc_mod._line(w)
            if ln and ln in text and str(w["id"]) not in ids:
                ids.append(str(w["id"]))
                lines.append(ln)
        return {"ids": ids[:6], "lines": lines[:6]} if ids else None
    except Exception as e:
        print("teil3 Details:", e, flush=True)
        return None


def _t3_short_ok(qid, path):
    r = _lz_dbm.q_get(qid, path) if qid else None
    if not r:
        return None
    if r["state"] in ("ok", "dup"):
        return True
    if r["state"] == "wait":
        return int(r["tries"] or 0) == 0      # wartet nur wegen Stundengrenze -> als angenommen melden
    return False


def _t3_nina_short(ctx, text, node):
    """NINA-Automatik (ninaCalm) ruft send_meshtastic / send_nina_to_bayern: Kurzmeldung fuer beide Knoten einreihen und sofort senden,
    Details folgen ueber die Warteschlange. -> Ergebnis fuer den Knoten"""
    base, path = _t3_paths()
    with _T3_LOCK:
        if "res" not in ctx:
            now = _t3_now()
            q = _lz_mesh.queue_nina(text, _t3_refs(ctx, text), now, path)
            if not q:
                raise RuntimeError("Warteschlange nicht beschreibbar")
            res = {}
            for nd in ("m1", "m2"):
                rep = _lz_mesh.queue_step(nd, now, _t3_tx(nd), path, None, None, "nina", 5)
                for x in rep:
                    if x.get("ok"):
                        _t3_sent(nd, now)
                res[nd] = _t3_short_ok((q.get(nd) or (None, None))[0], path)
                _t3_say("teil3 NINA %s: %s" % (_lz_mesh.NODES[nd]["name"], "; ".join("%s %s" % (x["kind"], x.get("why") or x["state"]) for x in rep) or "schon erledigt"))
            ctx["res"] = res
            ctx["text"] = text
        r = ctx["res"].get(node)
        return bool(r) if r is not None else False


def _t3_filter(nina_data):
    """Probe/Test/Uebung nie senden (Titel oder Status aus warnings/<id>.json)."""
    det = _T2D.get("nina") or {}

    def bad(w):
        t = _lz_mesh.nina_item_is_test(w, det.get(str(w.get("id"))) if isinstance(w, dict) else None)
        if t:
            k = str(w.get("id") if isinstance(w, dict) else w)[:80]
            if not _T3S.get("fake") and k not in _T3S.setdefault("test_seen", set()):
                _T3S["test_seen"].add(k)
                _t3_say("teil3: NINA-Probe/Test nicht gesendet:", (_nc_mod._line(w) if isinstance(w, dict) else str(w))[:80])
        return t
    if isinstance(nina_data, list):
        return [w for w in nina_data if not bad(w)]
    if isinstance(nina_data, dict):
        for k in ("alerts", "warnings"):
            if isinstance(nina_data.get(k), list):
                return dict(nina_data, **{k: [w for w in nina_data[k] if not bad(w)]})
    return nina_data


def _t3_mk_wrappers(prev_m1, prev_m2, prev_nina):
    def send_meshtastic(text, channel=0, *a, **kw):  # teil3 (Parameter channel bleibt sichtbar)
        ctx = getattr(_T3_TLS, "nina", None)
        if ctx is not None and not a and not kw and int(channel or 0) == 0:
            try:
                return _t3_nina_short(ctx, text, "m1")
            except Exception as e:
                print("teil3 NINA Mesh 1 -> alter Weg:", e, flush=True)
                ctx["fallback"] = True
        return prev_m1(text, channel, *a, **kw)

    def send_nina_to_bayern(text, *a, **kw):  # teil3
        ctx = getattr(_T3_TLS, "nina", None)
        if ctx is not None and not a and not kw and not ctx.get("fallback"):
            try:
                return _t3_nina_short(ctx, text, "m2")
            except Exception as e:
                print("teil3 NINA Mesh 2 -> alter Weg:", e, flush=True)
        return prev_m2(text, *a, **kw)

    def maybe_mesh_nina(nina_data, *a, **kw):  # teil3: NINA an beide Knoten + Details; Formatierung bleibt bei ninaCalm
        force = kw.get("force") is True or (len(a) > 0 and a[0] is True)
        if force or not _T3S["ok"]:
            return prev_nina(nina_data, *a, **kw)
        try:
            data = _t3_filter(nina_data)
            items = _nc_mod.active(data)
        except Exception as e:
            print("teil3 NINA-Filter:", e, flush=True)
            data, items = nina_data, []
        _T3_TLS.nina = {"items": items}
        try:
            return prev_nina(data, *a, **kw)
        finally:
            _T3_TLS.nina = None

    for f, p in ((send_meshtastic, prev_m1), (send_nina_to_bayern, prev_m2), (maybe_mesh_nina, prev_nina)):
        f._t3 = True
        f.__wrapped__ = p
        for attr in ("_fh2", "_mbq", "_ninaCalm"):
            if getattr(p, attr, False):
                setattr(f, attr, True)
    return send_meshtastic, send_nina_to_bayern, maybe_mesh_nina


def _t3_detail(ref):
    """Detailtext aus dem Teil-2-Cache warnings/<id>.json (Beschreibung, Handlungsempfehlung, Gebiet). -> Text | None"""
    det = _T2D.get("nina") or {}
    ids, lines = list(ref.get("ids") or []), list(ref.get("lines") or [])
    rows = []
    for i, wid in enumerate(ids):
        d = det.get(wid)
        if not isinstance(d, dict):
            return None              # noch nicht geladen -> spaeter erneut (max. 20 min)
        if d.get("status") in ("Exercise", "Test", "Draft", "System"):
            continue
        rows.append({"line": lines[i] if i < len(lines) else "", "headline": d.get("headline"), "desc": d.get("desc"), "instr": d.get("instr"), "area": d.get("area") or []})
    if not rows and ids and all(isinstance(det.get(w), dict) and "desc" not in det.get(w) for w in ids):
        return None
    return _lz_mesh.detail_text(lines, rows)


def _t3_free(node):
    base, path = _t3_paths()
    now = _t3_now()
    h = _t3_health(node)
    cu, age = _lz_mesh.chutil_get(base, node, now)
    dab = _lz_mesh.dab_pending((_T3S.get("fake") or {}).get("alarms", _T2D.get("alarms")), base, path, now) if node == _lz_mesh.PRIVATE_NODE else False
    free, why = _lz_mesh.channel_free(node, now, _T3S["last_send"].get(node), h, cu, dab)
    _T3S["free"][node] = {"t": now, "free": free, "why": why, "chutil": cu, "chutil_age": age, "dab_open": dab,
                          "host": (h or {}).get("host"), "queued": (h or {}).get("queued"), "connected": (h or {}).get("connected")}
    return free, why


def _t3_step():
    base, path = _t3_paths()
    out = []
    with _T3_LOCK:
        for node in ("m1", "m2"):
            now = _t3_now()
            rep = _lz_mesh.queue_step(node, now, _t3_tx(node), path, _t3_free, _t3_detail, None, 1)
            for x in rep:
                x["node"] = node
                if x.get("ok"):
                    _t3_sent(node, now)
                    _t3_say("teil3: %s %s gesendet: %s" % (_lz_mesh.NODES[node]["name"], x["kind"], str(x.get("text") or "")[:80]))
                elif x.get("state") in ("fail", "skip", "dup"):
                    _t3_say("teil3: %s %s %s: %s" % (_lz_mesh.NODES[node]["name"], x["kind"], x["state"], x.get("why")))
            out += rep
    if out:
        _T3S["rep"] = (out + _T3S["rep"])[:12]
    return out


def _t3_loop():
    _t3_time.sleep(T3_FIRST_S)
    while True:
        try:
            boot = globals().get("mesh_auto_allowed")
            if not callable(boot) or boot():
                _t3_step()
            _T3S.update(t=_t3_now(), n=_T3S["n"] + 1, tick_err=None)
            if _t3_now() - _T3S["cleanup_t"] > 3600:
                _T3S["cleanup_t"] = _t3_now()
                _lz_dbm.cleanup_t3(None, _LZ_PATH)
        except Exception as e:
            _T3S["tick_err"] = str(e)[:160]
            print("teil3 Warteschlange:", e, flush=True)
        _t3_time.sleep(T3_TICK_S)


def _t3_status():
    base, path = _t3_paths()
    now = _t3_now()
    nodes = {}
    for nd in ("m1", "m2"):
        n = _lz_mesh.NODES[nd]
        nodes[nd] = {"name": n["name"], "host": n["host"], "bridge": "127.0.0.1:%d" % n["port"],
                     "role": "NINA + exklusiv DAB+" if nd == _lz_mesh.PRIVATE_NODE else "nur NINA (DAB+ nie)",
                     "last_send": _T3S["last_send"].get(nd) or None, "free": _T3S["free"].get(nd),
                     "nina_hour_n": _lz_dbm.mesh_count_since(_lz_mesh.nina_label(nd), _lz_mesh.NINA_KINDS, now - 3600, path), "nina_hour_max": _lz_mesh.NINA_HOUR_MAX}
    return {"ok": _T3S["ok"], "err": _T3S["err"], "selftest": _T3S["selftest"], "nodes": nodes,
            "rules": {"detail_delay_s": _lz_mesh.DETAIL_DELAY_S, "free_gap_s": _lz_mesh.FREE_GAP_S, "chutil_max": _lz_mesh.CHUTIL_MAX, "same_h": _lz_mesh.NINA_SAME_S // 3600},
            "dab_pending": _lz_mesh.dab_pending(_T2D.get("alarms"), base, path, now), "dab_last": _T3S["dab"], "queue": _lz_dbm.q_recent(12, path),
            "last_steps": _T3S["rep"], "notes": _T3S["notes"][:5],
            "tick": {"t": _T3S["t"], "n": _T3S["n"], "err": _T3S["tick_err"], "every_s": T3_TICK_S, "thread": _T3S["started"]}}


def _t3_api():
    from flask import jsonify
    try:
        return jsonify(_t3_status())
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


_T3_JS = r"""(function(){if(window.__t3n)return;window.__t3n=1;var F=window.fetch;if(!F)return;
function show(t){try{var d=document.createElement('div');d.textContent=t;d.style.cssText='position:fixed;left:12px;right:12px;bottom:12px;z-index:9999;background:#1e293b;color:#fde68a;border:1px solid #a16207;border-radius:10px;padding:10px 12px;font-size:0.9rem;box-shadow:0 4px 14px rgba(0,0,0,.4)';document.body.appendChild(d);setTimeout(function(){d.remove();},9000);}catch(e){}}
window.fetch=function(){return F.apply(this,arguments).then(function(r){try{var ct=r.headers.get('content-type')||'';if(ct.indexOf('json')>=0){r.clone().json().then(function(j){if(j&&j.t3_note)show(j.t3_note);}).catch(function(){});}}catch(e){}return r;});};})();
"""


def _t3_after(resp):
    try:
        from flask import request as _t3_rq, g as _t3_g
        p = _t3_rq.path
        if ((p == "/api/mesh2_send" and _t3_rq.method == "POST") or p == "/api/mesh_test") and resp.status_code == 200:
            j = resp.get_json(silent=True) if resp.is_json else None
            if p == "/api/mesh2_send":
                pl = _t3_rq.get_json(silent=True) or {}
                txt, ch = str(pl.get("text") or "")[:200], int(pl.get("channel") or 0) if str(pl.get("channel") or "0").isdigit() else 0
                ok = bool(j.get("ok")) if isinstance(j, dict) and "ok" in j else True
            else:
                txt, ch = "NINA Test", 0
                ok = bool(j.get("bayern")) if isinstance(j, dict) else False
            if txt.strip():
                _t3_add_note(_t3_note_for("m2", txt, ch, "manuell"))
                _t3_log("m2", txt, ch, ok, "manuell")
        notes = getattr(_t3_g, "_t3_notes", None)
        if notes and resp.is_json and not resp.direct_passthrough:
            j = resp.get_json(silent=True)
            if isinstance(j, dict):
                j["t3_note"] = " | ".join(notes)
                resp.set_data(_t3_json.dumps(j, ensure_ascii=False))
        if resp.status_code == 200 and not resp.direct_passthrough and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="t3-js"' not in body and "</body>" in body:
                j = body.rfind("</body>")
                resp.set_data(body[:j] + '<script id="t3-js">' + _T3_JS + '</script>' + body[j:])
    except Exception as e:
        print("teil3 Antwort:", e, flush=True)
    return resp


def _t3_selftest():
    import tempfile
    import os as _o
    d = tempfile.mkdtemp()
    p = _o.path.join(d, "lagezentrum.db")
    sent = {"m1": [], "m2": []}
    host = {"m1": "192.168.178.141", "m2": "192.168.178.140"}
    clock = [1790000000]

    def mk(nd):
        def fake(text, channel=0):
            sent[nd].append((text, channel))
            return True
        fake.selftest = True
        return fake

    def health(nd):
        return {"host": host[nd], "connected": True, "queued": 0, "held": False, "last_send": None}
    _lz_dbm.migrate_t3(p)
    _lz_mesh.set_auto(d, True, "selftest", clock[0])
    nd0, ls0, dab0, rep0, notes0 = _T2D["nina"], dict(_T3S["last_send"]), list(_T3S["dab"]), list(_T3S["rep"]), list(_T3S["notes"])
    _T2D["nina"] = {"mow.t3": {"status": "Actual", "severity": "Severe", "headline": "Gefahrstoffaustritt", "desc": "Austritt von Chlorgas in einem Betrieb.",
                               "instr": "Fenster und Tueren schliessen.", "area": ["Stadt Nürnberg"], "t": clock[0]},
                    "mow.p3": {"status": "Exercise", "t": clock[0]}}
    _T3S["fake"] = {"now": lambda: clock[0], "base": d, "path": p, "health": health, "tx": {"m1": mk("m1"), "m2": mk("m2")}, "alarms": []}
    _T3S["last_send"] = {"m1": 0, "m2": 0}
    try:
        data = [{"city": "Nürnberg", "title": "Gefahrstoffaustritt", "id": "mow.t3", "msgType": "Alert"},
                {"city": "Nürnberg", "title": "Probealarm", "id": "mow.p3", "msgType": "Alert"}]
        f = _t3_filter(data)
        assert [w["id"] for w in f] == ["mow.t3"]                                                         # Probe/Test nie
        w1, w2, _ = _t3_mk_wrappers(lambda t, c=0, *a, **k: False, lambda t, *a, **k: False, None)
        text = "NINA: Nürnberg: Gefahrstoffaustritt"
        _T3_TLS.nina = {"items": _nc_mod.active(f)}
        try:
            assert w1(text) is True and w2(text) is True                                                  # wie ninaCalm: erst Mesh 1, dann Mesh 2
        finally:
            _T3_TLS.nina = None
        assert sent["m1"] == [(text, 0)] and sent["m2"] == [(text, 0)], sent                              # NINA an beide Knoten, Kanal 0
        clock[0] += 30
        assert not [x for x in _t3_step() if x.get("ok")]                                                 # Details nicht vor 60 s
        clock[0] += 31
        _T3S["fake"]["alarms"] = [{"src": "BR24", "real": True, "key": "selftest-br", "text": "Notfall", "t": clock[0]}]
        st = _t3_step()
        assert len(sent["m1"]) == 1 and any(x.get("ok") and x["node"] == "m2" for x in st), (st, sent)    # DAB offen: Mesh 1 wartet, Mesh 2 nicht
        _T3S["fake"]["alarms"] = []
        clock[0] += 5
        _t3_step()
        assert len(sent["m1"]) == 2 and sent["m1"][1][0].startswith("NINA Details: ") and "Fenster" in sent["m1"][1][0] and sent["m1"][1][1] == 0, sent
        assert len(sent["m2"]) == 2 and sent["m2"][1][0] == sent["m1"][1][0]
        _T3_TLS.nina = {"items": _nc_mod.active(f)}
        try:
            assert w1(text) is True                                                                       # gleicher Inhalt: kein zweiter Versand (6 h)
        finally:
            _T3_TLS.nina = None
        assert len(sent["m1"]) == 2 and len(sent["m2"]) == 2
        assert send_dab_to_private_mesh("ALARM BR24: Notfall eins") is True and len(sent["m1"]) == 3 and len(sent["m2"]) == 2
        host["m1"] = "192.168.178.140"
        assert send_dab_to_private_mesh("ALARM BR24: Notfall zwei") is False and len(sent["m1"]) == 3 and len(sent["m2"]) == 2   # .140 nie
        host["m1"] = None
        assert send_dab_to_private_mesh("ALARM BR24: Notfall drei") is False and len(sent["m1"]) == 3                           # unbekannt gesperrt
        host["m1"] = "192.168.178.141"
        assert send_dab_to_private_mesh("ALARM BR24: Notfall vier", channel=1) is False and len(sent["m1"]) == 3
        assert all(not t.startswith("ALARM") for t, c in sent["m2"])                                      # DAB+ nie an Mesh 2
        _lz_mesh.set_auto(d, False, "selftest", clock[0])
        assert send_dab_to_private_mesh("ALARM BR24: Notfall fuenf") is False and len(sent["m1"]) == 3   # Schalter AUS
        assert _t3_note_for("m1", sent["m1"][0][0], 0, "manuell", clock[0], p) and _t3_note_for("m1", "anders", 0, "manuell", clock[0], p) is None
        assert _t3_note_for("m1", sent["m1"][0][0], 0, "auto:sonst", clock[0], p) is None
        assert "channel" in w1.__code__.co_varnames
    finally:
        _T3S["fake"] = None
        _T3_TLS.nina = None
        _T2D["nina"] = nd0
        _T3S.update(last_send=ls0, dab=dab0, rep=rep0, notes=notes0)
    return "teil3 selftest ok (NINA beide Knoten Kanal 0, Details nach 60 s bei freiem Kanal, DAB+ Vorrang Mesh 1, DAB+ nur .141 - .140/unbekannt/AUS gesperrt, 6 h kein Doppel, Probe nie, Knopf nur Hinweis)"


try:
    if _lz_mesh is None or _lz_dbm is None or not hasattr(_lz_mesh, "queue_step") or not hasattr(_lz_dbm, "q_add"):
        raise RuntimeError("Module Teil 3 fehlen (%s)" % (_LZ.get("err") or "mesh_router/database alt"))
    if not _T2D.get("ok"):
        raise RuntimeError("Teil 2 nicht aktiv")
    if getattr(globals().get("send_meshtastic"), "_t3", False):
        raise RuntimeError("schon aktiv")
    _lz_dbm.migrate_t3(_LZ_PATH)
    _T3S["selftest"] = _t3_selftest()
    _t3_g0 = {k: globals().get(k) for k in ("send_meshtastic", "send_nina_to_bayern", "maybe_mesh_nina")}
    try:
        _T3S["inner"]["m1"] = _t3_hook(_t3_g0["send_meshtastic"], "o1", "m1")
        _T3S["inner"]["m2"] = _t3_hook(_t3_g0["send_nina_to_bayern"], "o2", "m2")
        _t3_hook(globals()["send_chunks_bayern"], "o", "cb")
        _T3S["tx"] = {"m1": _t3_m1_raw, "m2": _t3_m2_raw}
        _t3_w = _t3_mk_wrappers(_t3_g0["send_meshtastic"], _t3_g0["send_nina_to_bayern"], _t3_g0["maybe_mesh_nina"])
        globals()["send_meshtastic"], globals()["send_nina_to_bayern"], globals()["maybe_mesh_nina"] = _t3_w
        if "t3_status" not in app.view_functions:
            app.add_url_rule("/api/t3/status", endpoint="t3_status", view_func=_t3_api, methods=["GET"])
        if not any(getattr(f, "__name__", "") == "_t3_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_t3_after)
    except Exception:
        for _t3_c, _t3_i in _T3S["cells"]:
            _t3_c.cell_contents = _t3_i
        globals().update(_t3_g0)
        raise
    _T3S["ok"] = True
    if __name__ == "__main__" and not _T3S["started"]:
        _t3_thr.Thread(target=_t3_loop, name="teil3", daemon=True).start()
        _T3S["started"] = True
    print("teil3 aktiv: %s; Mesh 1 %s = NINA + DAB+, Mesh 2 %s = nur NINA" % (_T3S["selftest"], _lz_mesh.NODES["m1"]["host"], _lz_mesh.NODES["m2"]["host"]), flush=True)
except Exception as _t3_e:
    _T3S["err"] = str(_t3_e)[:160]
    print("teil3 FEHLER (alter Sendeweg bleibt):", _t3_e, flush=True)
# ===== /teil3 =====
T3B3_EOF
EXPECT_PD="f2bfceccc9852f8bd8456b75ed21a292184be24b71d0fc46f38d46fca89e9ced"
cat > "$W/patch-t3-dash.py" << 'T3PD_EOF'
"""teil3: teil2-Block (Stand Teil 2 -> Stand Teil 3) tauschen und teil3-Block direkt nach /teil2 einsetzen oder ersetzen (idempotent).
Aufruf: patch-t3-dash.py QUELLE ZIEL TEIL2_ALT TEIL2_NEU TEIL3 -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, t2a_f, t2n_f, t3_f = sys.argv[1:6]
s = open(src, encoding="utf-8").read()
t2a, t2n, t3 = (open(f, encoding="utf-8").read() for f in (t2a_f, t2n_f, t3_f))
A2, Z2 = "# ===== teil2:", "# ===== /teil2 =====\n"
A3, Z3 = "# ===== teil3:", "# ===== /teil3 =====\n"
MAIN = "\nif __name__ == \"__main__\":\n"
NEED = ("# ===== rdsNotfall:", "# ===== lageDB:", "# ===== ninaCalm:", "# ===== lageMesh1:", "import nina_calm as _nc_mod", "def _fh2_install_send():",
        "def _mbq_wrap(name, quiet_fn):", "def send_meshtastic(text, channel=0):", "def send_nina_to_bayern(text):", "def send_chunks_bayern(chunks):",
        "def send_meshtastic(text, channel=0, *a, **kw):  # funkHarden2", "def send_nina_to_bayern(text, *a, **kw):  # funkHarden2",
        "ok = o1(text, channel, *a, **kw)", "ok = o2(text, *a, **kw)", "ok = o(chunks, *a, **kw)", "def mesh_auto_allowed():", MAIN)
bad = [n.strip()[:50] for n in NEED if s.count(n) < 1]
if s.count(A2) != 1 or s.count(Z2) != 1:
    bad.append("teil2-Block fehlt/kaputt (%d/%d)" % (s.count(A2), s.count(Z2)))
if s.count(A3) > 1 or s.count(Z3) != s.count(A3):
    bad.append("teil3-Marker kaputt (%d/%d)" % (s.count(A3), s.count(Z3)))
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
a = s.index(A2); b = s.index(Z2) + len(Z2)
if s[a:b] not in (t2a, t2n):
    print("Basis passt nicht: teil2-Block ist weder Stand Teil 2 noch Stand Teil 3"); raise SystemExit(3)
if b > s.rindex(MAIN) or s.index("# ===== funkHarden2") > a or s.index("# ===== ninaCalm:") > a:
    print("Basis passt nicht: Reihenfolge ninaCalm/funkHarden2 < teil2 < __main__ stimmt nicht"); raise SystemExit(3)
s2 = s[:a] + t2n + s[b:]
b2 = a + len(t2n)
if A3 in s2:
    c = s2.index(A3); e = s2.index(Z3) + len(Z3)
    if c != b2:
        print("Basis passt nicht: teil3-Block steht nicht direkt nach /teil2"); raise SystemExit(3)
    s2 = s2[:c] + t3 + s2[e:]
else:
    s2 = s2[:b2] + t3 + s2[b2:]
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
T3PD_EOF
EXPECT_GUARD="f2138165b07662d9fe2dd66d09300853917c650183a8c90fdab66ab66a04a0c1"
cat > "$W/guard_t3.py" << 'T3GUARD_EOF'
"""Teil 3 AST-Guard. Aufruf: guard_t3.py DASH_ALT DASH_NEU MODDIR_ALT MODDIR_NEU TEIL2_ALT TEIL2_NEU -> 0 ok, 1 Verstoss.
dashboard.py: nur teil2-Block (genau die 3 erlaubten Aenderungen) und teil3-Block, sonst nichts geaendert; teil3 ohne Socket/Server/Prozess/shell,
kein direkter Bridge-Versand (kein requests.post, kein /send), Netz nur requests.get auf /health, genau 1 Faden, 1 Route (GET), 1 after_request;
send_dab_to_private_mesh nutzt nur den Mesh-1-Sendeweg. mesh_router.py: transport() nur in _txn, _txn nur in dab_private_send/queue_step,
send_fn nur in _tx, _tx nur in auto_send; DAB-Sperre .140. database.py/mesh_router.py: Teil-1/2-Code unveraendert, keine Netzmodule."""
import ast
import os
import sys

SEND = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "send_nina_to_bayern", "sendText", "sendData", "send_fn", "_tx", "_txn", "transport")
SOCK = ("socket", "create_connection", "bind", "listen", "serve_forever", "HTTPServer", "make_server", "TCPInterface", "SerialInterface", "urlopen",
        "system", "Popen", "check_output", "check_call", "call", "execv", "spawn", "fork", "killpg", "post", "put", "start_new_thread", "Timer", "unlink", "rmtree")
NETMOD = {"requests", "urllib", "http", "socket", "subprocess", "meshtastic", "serial", "asyncio", "socketserver"}
T2_EDITS = (
    ('''                                 "msgType": d.get("msgType") if isinstance(d, dict) else None, "t": now, "http": r.status_code}
            if isinstance(info, dict):   # Teil 3: Beschreibung, Handlungsempfehlung, Gebiet fuer die NINA-Detailmeldung
                _T2D["nina"][wid].update(headline=_t2d_plain(info.get("headline"), 120), desc=_t2d_plain(info.get("description"), 400),
                                         instr=_t2d_plain(info.get("instruction"), 300),
                                         area=[_t2d_plain(x.get("areaDesc"), 60) for x in (info.get("area") or [])[:6] if isinstance(x, dict) and x.get("areaDesc")])''',
     '''                                 "msgType": d.get("msgType") if isinstance(d, dict) else None, "t": now, "http": r.status_code}'''),
    ('''def _t2d_plain(t, n):
    """HTML-Reste (<br/>, Tags, &nbsp;) aus NINA-Texten entfernen, auf n Zeichen kuerzen."""
    t = _t2d_re.sub(r"<[^>]{0,200}>", " ", str(t or "")).replace("&nbsp;", " ").replace("&amp;", "&")
    return " ".join(t.split())[:n] or None


''', ""),
    ('''globals().get("send_dab_to_private_mesh") or send_meshtastic, base, path, now, _t2d_manual_sent(now))   # Teil 3: DAB nur .141''',
     '''send_meshtastic, base, path, now, _t2d_manual_sent(now))'''))


def info(src):
    t = ast.parse(src)
    imp, calls, shell, attrs, names, consts = set(), [], 0, [], [], []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False):
            shell += 1
        if isinstance(n, ast.Call):
            f = n.func
            calls.append(f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
            if isinstance(f, ast.Attribute):
                attrs.append(((f.value.id if isinstance(f.value, ast.Name) else "?"), f.attr))
        if isinstance(n, ast.Name):
            names.append(n.id)
        if isinstance(n, ast.Constant) and isinstance(n.value, str):
            consts.append(n.value)
    return imp, calls, shell, attrs, names, consts


def top_imports(src):
    return {(getattr(n, "module", None) or a.name).split(".")[0] for n in ast.parse(src).body if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names}


def cut(s, A, Z):
    if A not in s:
        return ""
    a = s.index(A)
    return s[a:s.index(Z, a) + len(Z) + 1]


def fdefs(src):
    return {f.name: f for f in ast.walk(ast.parse(src)) if isinstance(f, ast.FunctionDef)}


rd = lambda f: open(f, encoding="utf-8").read()
d0, d1 = rd(sys.argv[1]), rd(sys.argv[2])
m0, m1 = sys.argv[3:5]
t2a, t2n = rd(sys.argv[5]), rd(sys.argv[6])
err = []
# ---- dashboard.py
A2, Z2, A3, Z3 = "# ===== teil2:", "# ===== /teil2 =====", "# ===== teil3:", "# ===== /teil3 ====="
if d1.count(A2) != 1 or d1.count(Z2) != 1 or d1.count(A3) != 1 or d1.count(Z3) != 1:
    err.append("dashboard: teil2/teil3-Marker nicht genau 1x")
else:
    b2o, b2n, b3o, b3n = cut(d0, A2, Z2), cut(d1, A2, Z2), cut(d0, A3, Z3), cut(d1, A3, Z3)
    r0 = d0.replace(b2o, "").replace(b3o, "") if b3o else d0.replace(b2o, "")
    if r0 != d1.replace(b2n, "").replace(b3n, ""):
        err.append("dashboard: ausserhalb teil2/teil3 geaendert")
    if b2n != t2n + "\n" and b2n != t2n:
        err.append("dashboard: teil2-Block nicht Stand Teil 3")
    rev = t2n
    for new, old in T2_EDITS:
        if rev.count(new) != 1:
            err.append("dashboard: erlaubte teil2-Aenderung fehlt")
        rev = rev.replace(new, old)
    if rev != t2a:
        err.append("dashboard: teil2-Block anders geaendert als erlaubt")
    if b2o.rstrip("\n") not in (t2a.rstrip("\n"), t2n.rstrip("\n")):
        err.append("dashboard: alter teil2-Block unbekannt")
    bi, _, bs, _, _, _ = info(d0)
    ni, _, ns, _, _, _ = info(d1)
    ok3 = {"threading", "time", "json", "flask", "tempfile", "os"}
    if ni - bi - ok3:
        err.append("dashboard: neue Importe %s" % (ni - bi - ok3))
    if ns != bs:
        err.append("dashboard: shell= geaendert")
    ki, kc, ks, ka, kn, kk = info(b3n)
    if ks:
        err.append("teil3: shell=")
    if ki - ok3:
        err.append("teil3: importiert %s" % (ki - ok3))
    for nm in SEND + SOCK:
        if nm in kc:
            err.append("teil3: ruft %s direkt" % nm)
    net = [x for x in ka if x[0] in NETMOD]
    if net != [("requests", "get")]:
        err.append("teil3: Netzaufrufe %s (erlaubt genau 1x requests.get)" % net)
    if "requests.post" in b3n or "/send" in b3n or "socket" in kn or "socket" in ki or "subprocess" in kn:
        err.append("teil3: direkter Bridge-Versand/Socket")
    hu = [c for c in kk if c.startswith("http")]
    if sorted(hu) != ["http://127.0.0.1:5001/health", "http://127.0.0.1:5002/health"]:
        err.append("teil3: URLs %s (erlaubt nur /health)" % hu)
    if kc.count("Thread") != 1 or kc.count("add_url_rule") != 1 or kc.count("after_request") != 1 or 'methods=["GET"]' not in b3n:
        err.append("teil3: Faden/Route(GET)/after_request nicht genau je 1x")
    fd = fdefs(b3n)
    dab = fd.get("send_dab_to_private_mesh")
    if dab is None:
        err.append("teil3: send_dab_to_private_mesh fehlt")
    else:
        dc = [(c.func.id, [a.value for a in c.args if isinstance(a, ast.Constant)]) for c in ast.walk(dab) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name)]
        doc = dab.body[0].value if dab.body and isinstance(dab.body[0], ast.Expr) and isinstance(dab.body[0].value, ast.Constant) else None
        dk = [c.value for c in ast.walk(dab) if isinstance(c, ast.Constant) and c is not doc]
        if ("_t3_tx", ["m1"]) not in dc or [x for x in dc if x[0] == "_t3_tx"] != [("_t3_tx", ["m1"])] or "m2" in dk or "5002" in str(dk) or ".140" in str(dk):
            err.append("teil3: send_dab_to_private_mesh nicht nur Mesh 1")
        if not any(isinstance(c, ast.Attribute) and c.attr == "dab_private_send" for c in ast.walk(dab)):
            err.append("teil3: send_dab_to_private_mesh ohne harte Pruefung dab_private_send")
    if "send_dab_to_private_mesh" in b2n and b2n.count("send_dab_to_private_mesh") != 1:
        err.append("teil2: send_dab_to_private_mesh nicht genau 1x")
    if "channel" not in [a.arg for a in fd["send_meshtastic"].args.args] if "send_meshtastic" in fd else True:
        err.append("teil3: send_meshtastic-Huelle ohne Parameter channel")
# ---- Module
for name in ("database.py", "mesh_router.py"):
    o, n = rd(os.path.join(m0, name)), rd(os.path.join(m1, name))
    A = "\n\n# ---------------------------------------------------------------- Teil 3"
    MAINM = '\n\nif __name__ == "__main__":'
    if n.count(A) != 1:
        err.append("%s: Teil-3-Abschnitt nicht genau 1x" % name); continue

    def strip(x):
        if A not in x:
            return x
        return (x[:x.index(A)] + x[x.index(MAINM):]).replace("\n    print(selftest_t3())", "")
    if strip(n) != strip(o):
        err.append("%s: Teil-1/2-Code geaendert" % name)
    sec = n[n.index(A):n.index(MAINM)]
    si, sc, ss, sa, sn, sk = info(sec)
    if ss or info(n)[2]:
        err.append("%s: shell=" % name)
    if (top_imports(n) | si) & NETMOD:
        err.append("%s: Netzmodul %s" % (name, (top_imports(n) | si) & NETMOD))
    if top_imports(n) != top_imports(o):
        err.append("%s: Modul-Importe geaendert" % name)
    for nm in SOCK + ("Thread", "run_server"):
        if nm in sc:
            err.append("%s: Teil 3 ruft %s" % (name, nm))
    if name == "database.py":
        for nm in SEND:
            if nm in sc or nm in sn:
                err.append("database.py: Sendeweg %s" % nm)
        if si - {"tempfile", "os"}:
            err.append("database.py: Teil 3 importiert %s" % si)
    else:
        tree = ast.parse(n)
        where = {"send_fn": [], "_tx": [], "transport": [], "_txn": []}
        for f in [x for x in tree.body if isinstance(x, ast.FunctionDef)]:
            if f.name.startswith("selftest"):
                continue
            for c in ast.walk(f):
                if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id in where:
                    where[c.func.id].append(f.name)
        if where["send_fn"] != ["_tx"] or where["_tx"] != ["auto_send"] or where["transport"] != ["_txn"] or sorted(where["_txn"]) != ["dab_private_send", "queue_step"]:
            err.append("mesh_router: Sendestellen %s" % where)
        g = {}
        try:
            exec(compile(ast.Module(body=[x for x in ast.parse(sec).body if isinstance(x, ast.Assign) and all(isinstance(t, ast.Name) and t.id in
                 ("NODES", "PRIVATE_NODE", "PRIVATE_HOST", "NINA_ONLY_HOST", "NINA_CHANNEL") for t in x.targets)], type_ignores=[]), "sec", "exec"), g)
        except Exception as e:
            err.append("mesh_router: Konstanten unlesbar %s" % e)
        if g.get("PRIVATE_HOST") != "192.168.178.141" or g.get("NINA_ONLY_HOST") != "192.168.178.140" or g.get("PRIVATE_NODE") != "m1" or g.get("NINA_CHANNEL") != 0 \
                or (g.get("NODES") or {}).get("m1", {}).get("host") != "192.168.178.141" or (g.get("NODES") or {}).get("m1", {}).get("port") != 5001 \
                or (g.get("NODES") or {}).get("m2", {}).get("host") != "192.168.178.140" or (g.get("NODES") or {}).get("m2", {}).get("port") != 5002:
            err.append("mesh_router: Zuordnung Mesh 1 = .141/5001, Mesh 2 = .140/5002 stimmt nicht")
        dps = fdefs(n).get("dab_private_send")
        src = ast.unparse(dps) if dps is not None and hasattr(ast, "unparse") else (sec if dps is not None else "")
        if "host == NINA_ONLY_HOST" not in src or "host != PRIVATE_HOST" not in src or "auto_state(base)" not in src:
            err.append("mesh_router: harte DAB-Pruefung fehlt")
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard Teil 3: dashboard.py nur teil2 (3 erlaubte Aenderungen) + teil3, Module nur Teil-3-Abschnitt; kein shell=, keine Sockets/Server/Prozesse, "
      "kein direkter Bridge-Versand (nur GET /health); Sendestellen mesh_router._txn (Teil 3) und _tx (Teil 2); DAB+ nur Mesh 1 .141, .140 gesperrt")
T3GUARD_EOF
EXPECT_SHOW="b8ba278dec6488759df6a318056372d967f2e513eedc66a903b38219f72e5223"
cat > "$W/show_t3.py" << 'T3SHOW_EOF'
"""Teil 3 Anzeige (nur lesen). show_t3.py status|check DATEI(/api/t3/status als JSON)"""
import json
import sys
import time


def fmt(t):
    try:
        return time.strftime("%d.%m. %H:%M:%S", time.localtime(int(t))) if t else "-"
    except Exception:
        return "-"


mode, f = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(f, encoding="utf-8"))
except Exception as e:
    print("  /api/t3/status nicht lesbar:", str(e)[:80])
    raise SystemExit(1)
if not isinstance(d, dict):
    raise SystemExit(1)
n = d.get("nodes") or {}
if mode == "check":
    ok = d.get("ok") is True and (n.get("m1") or {}).get("host") == "192.168.178.141" and (n.get("m2") or {}).get("host") == "192.168.178.140" \
        and isinstance(d.get("queue"), list) and isinstance(d.get("tick"), dict) and isinstance(d.get("dab_pending"), bool)
    raise SystemExit(0 if ok else 1)
for k in ("m1", "m2"):
    x = n.get(k) or {}
    fr = x.get("free") or {}
    print("  %s %s (Bridge %s): %s; letzter Versand %s; NINA letzte Stunde %s/%s; Kanal %s" % (
        x.get("name"), x.get("host"), x.get("bridge"), x.get("role"), fmt(x.get("last_send")), x.get("nina_hour_n"), x.get("nina_hour_max"),
        (str(fr.get("why") or "")[:70] if fr.get("free") else "belegt - " + str(fr.get("why") or "")[:70]) if fr else "noch nicht geprueft"))
r = d.get("rules") or {}
print("  Regeln: Details %s s nach der Kurzmeldung, Kanal frei = >= %s s seit letztem Versand + Auslastung < %s %% + keine DAB-Meldung offen; gleicher Inhalt %s h gesperrt" % (
    r.get("detail_delay_s"), r.get("free_gap_s"), r.get("chutil_max"), r.get("same_h")))
print("  DAB+-Meldung offen (Vorrang Mesh 1): %s" % ("ja" if d.get("dab_pending") else "nein"))
q = [x for x in d.get("queue") or [] if x.get("state") == "wait"]
print("  Warteschlange: %s offen%s" % (len(q), (" - " + "; ".join("%s %s: %s" % (x.get("node"), x.get("kind"), str(x.get("why") or "")[:50]) for x in q[:4])) if q else ""))
tk = d.get("tick") or {}
print("  Pruefung alle %s s: %s Durchlaeufe, zuletzt %s%s" % (tk.get("every_s"), tk.get("n"), fmt(tk.get("t")), (", Fehler: " + str(tk.get("err"))[:80]) if tk.get("err") else ""))
T3SHOW_EOF
EXPECT_MDB="c3b138fbe10803737f16c6164df8f4712c9602a8cae55840372b6c30eafa259b"
cat > "$W/new/database.py" << 'T3MDB_EOF'
"""database.py - SQLite-Lagezentrum (lagezentrum.db) ZUSAETZLICH zu den JSON-Dateien.

Kaeswasser Lage Monitor, Teil 1. Nur Ablage/Abfrage, keine Netzwerkzugriffe, keine Sendewege.
- WAL-Modus, busy_timeout, eine Verbindung je Aufruf (thread-sicher ohne geteilte Verbindung)
- Schema-Migration idempotent (CREATE IF NOT EXISTS + fehlende Spalten per ALTER TABLE ADD COLUMN)
- jede Funktion faengt Fehler ab und liefert einen sicheren Standardwert (Seiten duerfen nie abstuerzen)

Tabellen:
  events     Lage-Ereignisse (NINA/MoWaS, DAB, ASA, BR24) - ext_id eindeutig (Upsert)
  mesh_log   md5-Hash gesehener Mesh-Texte je Kanal (nur Dublettenpruefung, kein Senden)
  telemetry  DAB-Empfangswerte je Stick/Kanal; 'ber' = FIC-CRC-Fehlerrate als Ersatz fuer die
             Bitfehlerrate (welle-cli liefert keine BER): numcrcerrors / (Messdauer_s * 125 FIB/s, DAB Mode I).
             kind 'dab' = echte Messung, kind 'hb' = Lebenszeichen aus sdr_status.json (Watchdog).
"""
import os
import sqlite3
import time

DB_PATH = "/home/fmg/prepper-dashboard/lagezentrum.db"
SCHEMA_VERSION = 1
TIMEOUT_S = 10.0

KEEP_MESH_S = 24 * 3600
KEEP_TELEMETRY_S = 48 * 3600

_TABLES = {
    "events": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("source", "TEXT NOT NULL"),          # NINA | DAB | ASA | BR24
        ("type", "TEXT"),                      # z. B. Alert/Update/Cancel, dls, ann, warn
        ("severity", "TEXT"),                  # info | warn | alarm | probe | unknown
        ("headline", "TEXT"),
        ("text", "TEXT"),
        ("lat", "REAL"),
        ("lon", "REAL"),
        ("geojson", "TEXT"),
        ("sent_at", "INTEGER"),
        ("created", "INTEGER"),
        ("updated", "INTEGER"),
        ("expires", "INTEGER"),
        ("is_test", "INTEGER DEFAULT 0"),      # eigene TEST-Knopf-Meldungen -> zaehlen nie
        ("ext_id", "TEXT"),
    ],
    "mesh_log": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("hash", "TEXT NOT NULL"),
        ("channel", "TEXT"),
        ("created", "INTEGER"),
    ],
    "telemetry": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("ts", "INTEGER NOT NULL"),
        ("kind", "TEXT DEFAULT 'dab'"),        # dab | hb
        ("serial", "TEXT"),
        ("channel", "TEXT"),                   # 11D | 5C (hb: Rolle/aktiv)
        ("snr", "REAL"),
        ("ber", "REAL"),                       # FIC-CRC-Fehlerrate (siehe oben)
        ("fic_err", "INTEGER"),
        ("secs", "REAL"),
        ("ensemble", "TEXT"),
        ("mast", "TEXT"),                      # Ensemble + Kanal, z. B. "Bayern · 11D"
        ("rssi", "REAL"),                      # nur wenn verfuegbar (welle-cli: nein)
        ("src_t", "INTEGER"),                  # Zeitstempel der Quelle (Dedup)
    ],
}
_INDEXES = (
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_events_ext ON events(ext_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_upd ON events(updated)",
    "CREATE INDEX IF NOT EXISTS ix_events_exp ON events(expires)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_hash ON mesh_log(hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_created ON mesh_log(created)",
    "CREATE INDEX IF NOT EXISTS ix_tel_ts ON telemetry(ts)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_tel_src ON telemetry(kind, serial, channel, src_t)",
)
_migrated = set()
_last_err = [None]


def _log(*a):
    _last_err[0] = " ".join(str(x) for x in a)[:200]
    print("lagezentrum.db:", *a, flush=True)


def last_error():
    return _last_err[0]


def connect(path=None):
    """Neue Verbindung (je Aufruf). WAL, busy_timeout, Row-Zugriff per Name."""
    con = sqlite3.connect(path or DB_PATH, timeout=TIMEOUT_S)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    return con


def migrate(path=None):
    """Schema anlegen/ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        con = connect(path)
        try:
            with con:
                con.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
                for tb, cols in _TABLES.items():
                    con.execute("CREATE TABLE IF NOT EXISTS %s (%s)" % (tb, ", ".join("%s %s" % c for c in cols)))
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ.replace("PRIMARY KEY AUTOINCREMENT", "").replace("NOT NULL", "")))
                for sql in _INDEXES:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_version', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (str(SCHEMA_VERSION),))
        finally:
            con.close()
        _migrated.add(path)
        return True
    except Exception as e:
        _log("Migration:", e)
        return False


def _ensure(path):
    path = path or DB_PATH
    if path not in _migrated:
        migrate(path)
    return path


def upsert_event(ev, path=None):
    """Ereignis anlegen oder (gleiche ext_id) aktualisieren. -> True/False"""
    path = _ensure(path)
    try:
        now = int(time.time())
        row = {k: ev.get(k) for k in ("source", "type", "severity", "headline", "text", "lat", "lon", "geojson", "sent_at", "created", "updated", "expires", "is_test", "ext_id")}
        if not row["ext_id"] or not row["source"]:
            return False
        row["created"] = int(row["created"] or now)
        row["updated"] = int(row["updated"] or row["created"])
        row["is_test"] = 1 if row["is_test"] else 0
        for k in ("headline", "text"):
            if row[k] is not None:
                row[k] = str(row[k])[:2000]
        con = connect(path)
        try:
            with con:
                con.execute(
                    "INSERT INTO events(source,type,severity,headline,text,lat,lon,geojson,sent_at,created,updated,expires,is_test,ext_id) "
                    "VALUES(:source,:type,:severity,:headline,:text,:lat,:lon,:geojson,:sent_at,:created,:updated,:expires,:is_test,:ext_id) "
                    "ON CONFLICT(ext_id) DO UPDATE SET updated=MAX(COALESCE(events.updated,0), COALESCE(excluded.updated,0)), "
                    "expires=CASE WHEN excluded.expires IS NULL THEN events.expires ELSE MAX(COALESCE(events.expires,0), excluded.expires) END, "
                    "severity=COALESCE(excluded.severity, events.severity), text=COALESCE(excluded.text, events.text), "
                    "headline=COALESCE(excluded.headline, events.headline), type=COALESCE(excluded.type, events.type), "
                    "lat=COALESCE(excluded.lat, events.lat), lon=COALESCE(excluded.lon, events.lon), geojson=COALESCE(excluded.geojson, events.geojson)", row)
        finally:
            con.close()
        return True
    except Exception as e:
        _log("Ereignis:", e)
        return False


def insert_telemetry(t, path=None):
    """Telemetrie-Zeile (gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    path = _ensure(path)
    try:
        row = {k: t.get(k) for k in ("ts", "kind", "serial", "channel", "snr", "ber", "fic_err", "secs", "ensemble", "mast", "rssi", "src_t")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        row["kind"] = row["kind"] or "dab"
        row["src_t"] = int(row["src_t"] if isinstance(row["src_t"], (int, float)) else row["ts"])
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,snr,ber,fic_err,secs,ensemble,mast,rssi,src_t) "
                                  "VALUES(:ts,:kind,:serial,:channel,:snr,:ber,:fic_err,:secs,:ensemble,:mast,:rssi,:src_t)", row)
                return cur.rowcount > 0
        finally:
            con.close()
    except Exception as e:
        _log("Telemetrie:", e)
        return False


def mesh_seen(hash_hex, channel=None, path=None, now=None):
    """Hash merken; True wenn er schon bekannt war (Dublette). Fehler -> None (Aufrufer entscheidet)."""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_log(hash, channel, created) VALUES(?,?,?)", (str(hash_hex), channel, int(now or time.time())))
                return cur.rowcount == 0
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_known(hash_hex, path=None):
    """Nur pruefen, nicht merken. -> True/False/None(Fehler)"""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return con.execute("SELECT 1 FROM mesh_log WHERE hash=?", (str(hash_hex),)).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def _rows(sql, args=(), path=None):
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return [dict(r) for r in con.execute(sql, args).fetchall()]
        finally:
            con.close()
    except Exception as e:
        _log("Abfrage:", e)
        return []


def recent_events(n=10, path=None, include_test=False):
    return _rows("SELECT * FROM events %s ORDER BY COALESCE(updated, created) DESC, id DESC LIMIT ?" % ("" if include_test else "WHERE COALESCE(is_test,0)=0"),
                 (int(n),), path)


def active_events(now=None, path=None, since_s=None):
    now = int(now or time.time())
    q = "SELECT * FROM events WHERE COALESCE(is_test,0)=0 AND (expires IS NULL OR expires >= ?)"
    a = [now]
    if since_s:
        q += " AND COALESCE(updated, created) >= ?"
        a.append(now - int(since_s))
    return _rows(q + " ORDER BY COALESCE(updated, created) DESC LIMIT 500", tuple(a), path)


def newest_telemetry(kind=None, path=None):
    r = _rows("SELECT * FROM telemetry %s ORDER BY ts DESC, id DESC LIMIT 1" % ("WHERE kind=?" if kind else ""), (kind,) if kind else (), path)
    return r[0] if r else None


def telemetry_latest_per_channel(path=None):
    return _rows("SELECT t.* FROM telemetry t JOIN (SELECT channel, MAX(ts) m FROM telemetry WHERE kind='dab' GROUP BY channel) x "
                 "ON t.channel=x.channel AND t.ts=x.m WHERE t.kind='dab' ORDER BY t.ts DESC", (), path)


def cleanup(now=None, path=None):
    """Abgelaufene Ereignisse, mesh_log > 24 h, Telemetrie > 48 h loeschen. -> {tabelle: anzahl}"""
    path = _ensure(path)
    now = int(now or time.time())
    out = {}
    try:
        con = connect(path)
        try:
            with con:
                out["events"] = con.execute("DELETE FROM events WHERE expires IS NOT NULL AND expires < ?", (now,)).rowcount
                out["mesh_log"] = con.execute("DELETE FROM mesh_log WHERE created < ?", (now - KEEP_MESH_S,)).rowcount
                out["telemetry"] = con.execute("DELETE FROM telemetry WHERE ts < ?", (now - KEEP_TELEMETRY_S,)).rowcount
        finally:
            con.close()
    except Exception as e:
        _log("Aufraeumen:", e)
    return out


def counts(path=None):
    out = {}
    for tb in _TABLES:
        r = _rows("SELECT COUNT(*) n FROM %s" % tb, (), path)
        out[tb] = r[0]["n"] if r else None
    return out


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "t.db")
    assert migrate(p) and migrate(p)  # idempotent
    con = connect(p)
    assert con.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    con.close()
    now = int(time.time())
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a", "expires": now + 60, "created": now - 10}, p)
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a2", "expires": now + 120, "updated": now}, p)
    ev = recent_events(5, p)
    assert len(ev) == 1 and ev[0]["headline"] == "a2" and ev[0]["expires"] == now + 120 and ev[0]["created"] == now - 10, ev
    assert upsert_event({"source": "BR24", "ext_id": "old", "expires": now - 5}, p)
    assert upsert_event({"source": "BR24", "ext_id": "t", "is_test": True}, p) and len(recent_events(9, p)) == 2
    assert insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert not insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert insert_telemetry({"ts": now - 3 * 86400, "serial": "1", "channel": "5C", "src_t": now - 3 * 86400}, p)
    assert newest_telemetry(path=p)["snr"] == 12.5 and telemetry_latest_per_channel(p)[0]["channel"] == "11D"
    assert mesh_seen("h", "0", p, now - 2 * 86400) is False and mesh_seen("h", "0", p) is True and mesh_known("zz", p) is False
    c = cleanup(now, p)
    assert c == {"events": 1, "mesh_log": 1, "telemetry": 1}, c
    assert counts(p) == {"events": 2, "mesh_log": 0, "telemetry": 1}, counts(p)
    assert recent_events(5, "/proc/nicht/schreibbar/x.db") == []  # Fehler -> leer, kein Absturz
    return "database selftest ok"


# ---------------------------------------------------------------- Teil 2 (SDR-Steuerung, Parser, Resilienz)
# Zusaetzlich, idempotent (migrate_t2): telemetry.tii/ecc/lto/ens_id (kind 'fig' = FIG 0/9 + TII + Ensemble aus welle-cli mux.json),
# mesh_log.src/text/ok/kind (Protokoll des Auto-Versands), Tabelle mesh_auto (eine Meldung je Alarm, 30 Tage) und
# Tabelle asa_rx (Empfangszeitpunkte des ASA-Dienstes auf 5C, 14 Tage). Bestehende Tabellen/Funktionen bleiben unveraendert.
KEEP_MESH_AUTO_S = 30 * 86400
KEEP_ASA_RX_S = 14 * 86400
_T2_ADD = {
    "telemetry": [("tii", "TEXT"), ("ecc", "TEXT"), ("lto", "REAL"), ("ens_id", "TEXT")],
    "mesh_log": [("src", "TEXT"), ("text", "TEXT"), ("ok", "INTEGER"), ("kind", "TEXT")],
}
_T2_SQL = (
    "CREATE TABLE IF NOT EXISTS mesh_auto (id INTEGER PRIMARY KEY AUTOINCREMENT, akey TEXT NOT NULL, hash TEXT, src TEXT, text TEXT, "
    "created INTEGER, last_try INTEGER, tries INTEGER DEFAULT 0, ok INTEGER)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_auto_key ON mesh_auto(akey)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_auto_try ON mesh_auto(last_try)",
    "CREATE TABLE IF NOT EXISTS asa_rx (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, channel TEXT, serial TEXT)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_asa_rx ON asa_rx(channel, ts)",
)
AUTO_RETRY_S = 600            # fehlgeschlagener Auto-Versand fruehestens nach 10 min erneut
AUTO_TRIES_MAX = 3            # hoechstens 3 Versuche je Alarm
_migrated_t2 = set()


def migrate_t2(path=None):
    """Teil-2-Schema ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
        if not migrate(path):
            return False
        con = connect(path)
        try:
            with con:
                for tb, cols in _T2_ADD.items():
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ))
                for sql in _T2_SQL:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_t2', '1') ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        finally:
            con.close()
        _migrated_t2.add(path)
        return True
    except Exception as e:
        _log("Migration Teil 2:", e)
        return False


def _ensure_t2(path):
    path = path or DB_PATH
    if path not in _migrated_t2:
        migrate_t2(path)
    return path


def _exec(sql, args, path, what):
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            with con:
                return con.execute(sql, args).rowcount
        finally:
            con.close()
    except Exception as e:
        _log(what, e)
        return None


def _rows_t2(sql, args, path):
    _ensure_t2(path)
    return _rows(sql, args, path)


def insert_fig(t, path=None):
    """FIG 0/9 + TII + Ensemble einer DAB-Pruefung (kind 'fig'; gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    try:
        row = {k: t.get(k) for k in ("ts", "serial", "channel", "ensemble", "mast", "tii", "ecc", "lto", "ens_id")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        return (_exec("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,ensemble,mast,src_t,tii,ecc,lto,ens_id) "
                      "VALUES(:ts,'fig',:serial,:channel,:ensemble,:mast,:ts,:tii,:ecc,:lto,:ens_id)", row, path, "Telemetrie fig:") or 0) > 0
    except Exception as e:
        _log("Telemetrie fig:", e)
        return False


def newest_fig(channel, path=None):
    r = _rows_t2("SELECT * FROM telemetry WHERE kind='fig' AND channel=? ORDER BY ts DESC, id DESC LIMIT 1", (str(channel),), path)
    return r[0] if r else None


def asa_rx_add(ts, channel="5C", serial=None, path=None):
    """Empfangszeitpunkt ASA-Dienst merken. -> True wenn neu"""
    if not isinstance(ts, (int, float)):
        return False
    return (_exec("INSERT OR IGNORE INTO asa_rx(ts, channel, serial) VALUES(?,?,?)", (int(ts), str(channel), serial), path, "asa_rx:") or 0) > 0


def asa_rx_list(since, channel="5C", path=None):
    return [r["ts"] for r in _rows_t2("SELECT ts FROM asa_rx WHERE channel=? AND ts>=? ORDER BY ts", (str(channel), int(since)), path)]


def mesh_hash_since(hash_hex, since, path=None, ok_only=True):
    """Gleicher Inhalt (Hash) seit 'since' gesendet? ok_only: fehlgeschlagene Versuche zaehlen nicht. -> True/False/None(Fehler)"""
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            q = "SELECT 1 FROM mesh_log WHERE hash=? AND created>=?" + (" AND COALESCE(ok, 1)=1" if ok_only else "")
            return con.execute(q, (str(hash_hex), int(since))).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_log_put(hash_hex, channel, now, src=None, text=None, ok=None, kind="auto", path=None):
    """Versand protokollieren (gleicher Hash -> Zeit/Ergebnis aktualisiert). -> True/False"""
    n = _exec("INSERT INTO mesh_log(hash, channel, created, src, text, ok, kind) VALUES(?,?,?,?,?,?,?) "
              "ON CONFLICT(hash) DO UPDATE SET created=excluded.created, channel=excluded.channel, src=excluded.src, text=excluded.text, ok=excluded.ok, kind=excluded.kind",
              (str(hash_hex), None if channel is None else str(channel), int(now), src, (str(text)[:300] if text is not None else None),
               None if ok is None else (1 if ok else 0), kind), path, "mesh_log:")
    return bool(n)


def mesh_auto_get(akey, path=None):
    r = _rows_t2("SELECT * FROM mesh_auto WHERE akey=?", (str(akey),), path)
    return r[0] if r else None


def mesh_auto_reserve(akey, hash_hex, src, text, now, path=None):
    """Versuch fuer einen Alarm anmelden. -> 'neu' | 'wieder' (frueherer Versuch fehlgeschlagen) | None (schon gesendet/zu frueh/zu oft/Fehler)"""
    now = int(now)
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_auto(akey, hash, src, text, created, last_try, tries, ok) VALUES(?,?,?,?,?,?,1,NULL)",
                                  (str(akey), str(hash_hex), src, str(text)[:300], now, now))
                if cur.rowcount > 0:
                    return "neu"
                r = con.execute("SELECT ok, tries, last_try FROM mesh_auto WHERE akey=?", (str(akey),)).fetchone()
                if r is None or r["ok"] != 0 or int(r["tries"] or 0) >= AUTO_TRIES_MAX or now - int(r["last_try"] or 0) < AUTO_RETRY_S:
                    return None
                con.execute("UPDATE mesh_auto SET tries=tries+1, last_try=?, ok=NULL, hash=?, text=? WHERE akey=?", (now, str(hash_hex), str(text)[:300], str(akey)))
                return "wieder"
        finally:
            con.close()
    except Exception as e:
        _log("mesh_auto:", e)
        return None


def mesh_auto_done(akey, ok, path=None):
    return bool(_exec("UPDATE mesh_auto SET ok=? WHERE akey=?", (1 if ok else 0, str(akey)), path, "mesh_auto:"))


def mesh_auto_count(since, path=None):
    """Auto-Versuche seit 'since' (Ratenbegrenzung). Fehler -> None"""
    r = _rows_t2("SELECT COUNT(*) n FROM mesh_auto WHERE last_try>=?", (int(since),), path)
    return r[0]["n"] if r else None


def mesh_auto_recent(n=10, path=None):
    return _rows_t2("SELECT akey, src, text, created, last_try, tries, ok FROM mesh_auto ORDER BY last_try DESC, id DESC LIMIT ?", (int(n),), path)


def cleanup_t2(now=None, path=None):
    now = int(now or time.time())
    return {"mesh_auto": _exec("DELETE FROM mesh_auto WHERE COALESCE(last_try, created, 0) < ?", (now - KEEP_MESH_AUTO_S,), path, "Aufraeumen:"),
            "asa_rx": _exec("DELETE FROM asa_rx WHERE ts < ?", (now - KEEP_ASA_RX_S,), path, "Aufraeumen:")}


def selftest_t2():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "t2.db")
    assert migrate_t2(p) and migrate_t2(p)
    con = connect(p)
    cols = {r[1] for r in con.execute("PRAGMA table_info(telemetry)")} | {r[1] for r in con.execute("PRAGMA table_info(mesh_log)")}
    con.close()
    assert {"tii", "ecc", "lto", "ens_id", "src", "text", "ok", "kind"} <= cols, cols
    now = int(time.time())
    assert insert_fig({"ts": now, "serial": "19348831", "channel": "11D", "ensemble": "Bayern", "mast": "BR Bayern MainID 07 / SubID 02", "tii": "[]", "ecc": "0xE0", "lto": 2.0}, p)
    assert not insert_fig({"ts": now, "serial": "19348831", "channel": "11D"}, p) and newest_fig("11D", p)["ecc"] == "0xE0"
    assert insert_telemetry({"ts": now, "serial": "19348831", "channel": "11D", "snr": 9.0, "src_t": now}, p)   # alte Telemetrie unberuehrt
    assert asa_rx_add(now - 100, path=p) and not asa_rx_add(now - 100, path=p) and asa_rx_add(now, path=p) and asa_rx_list(now - 200, path=p) == [now - 100, now]
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now, p) == "neu" and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 1, p) is None
    assert mesh_auto_done("A1", False, p) and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 60, p) is None          # zu frueh
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + AUTO_RETRY_S, p) == "wieder" and mesh_auto_done("A1", True, p)
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + 9 * AUTO_RETRY_S, p) is None and mesh_auto_get("A1", p)["tries"] == 2   # einmal ok = nie wieder
    assert mesh_auto_count(now, p) == 1 and mesh_auto_count(now + 10 * AUTO_RETRY_S, p) == 0
    assert mesh_hash_since("h1", now - 10, p) is False and mesh_log_put("h1", "auto0", now, "ASA", "x", True, path=p) and mesh_hash_since("h1", now - 10, p) is True
    assert mesh_log_put("h1", "auto0", now + 5, "ASA", "x", False, path=p) and mesh_hash_since("h1", now + 1, p) is False and mesh_known("h1", p) is True
    assert mesh_hash_since("h1", now + 1, p, ok_only=False) is True
    c = cleanup_t2(now + KEEP_ASA_RX_S + 1, p)
    assert c["asa_rx"] == 2 and c["mesh_auto"] == 0, c
    assert asa_rx_list(0, path="/proc/nicht/schreibbar/x.db") == [] and mesh_auto_reserve("x", "h", "s", "t", now, "/proc/nicht/schreibbar/x.db") is None
    return "database selftest Teil 2 ok"


# ---------------------------------------------------------------- Teil 3 (Meshtastic-Routing und Priorisierung)
# Zusaetzlich, idempotent (migrate_t3): Tabelle mesh_queue = Warteschlange je Knoten (m1 = Mesh 1 192.168.178.141,
# m2 = Mesh 2 192.168.178.140) fuer NINA-Kurzmeldung und NINA-Details (Details erst nach der eigenen Kurzmeldung,
# 60 s Abstand, Kanal frei). Zustand: wait | ok | dup | fail | skip. Bestehende Tabellen/Funktionen bleiben unveraendert.
KEEP_QUEUE_S = 7 * 86400
_T3_SQL = (
    "CREATE TABLE IF NOT EXISTS mesh_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, node TEXT NOT NULL, kind TEXT NOT NULL, ref TEXT, text TEXT, "
    "hash TEXT, created INTEGER, not_before INTEGER, after_id INTEGER, tries INTEGER DEFAULT 0, last_try INTEGER, state TEXT DEFAULT 'wait', "
    "why TEXT, done INTEGER)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_queue_open ON mesh_queue(node, state, id)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_queue_hash ON mesh_queue(node, hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_log_ch ON mesh_log(channel, created)",
)
_Q_FIELDS = ("text", "hash", "not_before", "tries", "last_try", "state", "why", "done", "ref")
_migrated_t3 = set()


def migrate_t3(path=None):
    """Teil-3-Schema ergaenzen (idempotent, setzt Teil 2 voraus). -> True/False"""
    path = path or DB_PATH
    try:
        if not migrate_t2(path):
            return False
        con = connect(path)
        try:
            with con:
                for sql in _T3_SQL:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_t3', '1') ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        finally:
            con.close()
        _migrated_t3.add(path)
        return True
    except Exception as e:
        _log("Migration Teil 3:", e)
        return False


def _ensure_t3(path):
    path = path or DB_PATH
    if path not in _migrated_t3:
        migrate_t3(path)
    return path


def q_add(node, kind, text, hash_hex, now, not_before=None, after_id=None, ref=None, path=None, same_s=6 * 3600):
    """Eintrag anlegen; gleicher Knoten + gleicher Hash, der noch wartet oder in den letzten 6 h erledigt wurde -> vorhandene id. -> id | None"""
    now = int(now)
    path = _ensure_t3(path)
    try:
        con = connect(path)
        try:
            with con:
                if hash_hex:
                    r = con.execute("SELECT id FROM mesh_queue WHERE node=? AND hash=? AND (state='wait' OR COALESCE(done, created, 0)>=?) "
                                    "ORDER BY id DESC LIMIT 1", (str(node), str(hash_hex), now - int(same_s))).fetchone()
                    if r is not None:
                        return int(r["id"])
                cur = con.execute("INSERT INTO mesh_queue(node, kind, ref, text, hash, created, not_before, after_id, tries, state) "
                                  "VALUES(?,?,?,?,?,?,?,?,0,'wait')",
                                  (str(node), str(kind), ref, None if text is None else str(text)[:300], hash_hex, now,
                                   int(now if not_before is None else not_before), after_id))
                return int(cur.lastrowid)
        finally:
            con.close()
    except Exception as e:
        _log("mesh_queue:", e)
        return None


def q_get(qid, path=None):
    r = _rows_t3("SELECT * FROM mesh_queue WHERE id=?", (int(qid),), path)
    return r[0] if r else None


def q_open(node, path=None):
    """Wartende Eintraege eines Knotens, aelteste zuerst (Kurzmeldungen vor Details)."""
    return _rows_t3("SELECT * FROM mesh_queue WHERE node=? AND state='wait' ORDER BY CASE kind WHEN 'nina' THEN 0 ELSE 1 END, id", (str(node),), path)


def q_set(qid, path=None, **kw):
    sets = [(k, v) for k, v in kw.items() if k in _Q_FIELDS]
    if not sets:
        return False
    sql = "UPDATE mesh_queue SET %s WHERE id=?" % ", ".join("%s=?" % k for k, _ in sets)
    return bool(_exec(sql, tuple(v for _, v in sets) + (int(qid),), _ensure_t3(path), "mesh_queue:"))


def q_recent(n=10, path=None):
    return _rows_t3("SELECT id, node, kind, text, created, not_before, after_id, tries, last_try, state, why, done FROM mesh_queue "
                    "ORDER BY id DESC LIMIT ?", (int(n),), path)


def mesh_count_since(channel, kinds, since, path=None):
    """Erfolgreiche Sendungen eines Kanals (Knoten) seit 'since' mit kind in kinds (Ratenbegrenzung). Fehler -> None"""
    kinds = tuple(kinds)
    r = _rows_t3("SELECT COUNT(*) n FROM mesh_log WHERE channel=? AND created>=? AND COALESCE(ok, 1)=1 AND kind IN (%s)" % ",".join("?" * len(kinds)),
                 (str(channel), int(since)) + kinds, path)
    return r[0]["n"] if r else None


def mesh_last(hash_hex, path=None):
    """Letzter Eintrag zu einem Hash (fuer Hinweis 'schon gesendet'). -> dict | None"""
    r = _rows_t3("SELECT hash, channel, created, src, ok, kind FROM mesh_log WHERE hash=?", (str(hash_hex),), path)
    return r[0] if r else None


def _rows_t3(sql, args, path):
    _ensure_t3(path)
    return _rows(sql, args, path)


def cleanup_t3(now=None, path=None):
    now = int(now or time.time())
    return {"mesh_queue": _exec("DELETE FROM mesh_queue WHERE state!='wait' AND COALESCE(done, last_try, created, 0) < ?", (now - KEEP_QUEUE_S,),
                                _ensure_t3(path), "Aufraeumen:")}


def selftest_t3():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "t3.db")
    assert migrate_t3(p) and migrate_t3(p)
    now = int(time.time())
    a = q_add("m1", "nina", "NINA: Nürnberg: Gefahr", "h1", now, path=p)
    assert a and q_add("m1", "nina", "NINA: Nürnberg: Gefahr", "h1", now + 5, path=p) == a          # wartet schon -> gleiche id
    b = q_add("m2", "nina", "NINA: Nürnberg: Gefahr", "h2", now, path=p)
    d = q_add("m1", "nina_detail", None, None, now, not_before=now + 60, after_id=a, ref='{"ids": []}', path=p)
    assert b != a and d and [r["id"] for r in q_open("m1", p)] == [a, d] and q_get(d, p)["after_id"] == a
    assert q_set(a, p, state="ok", done=now, tries=1, last_try=now) and [r["id"] for r in q_open("m1", p)] == [d]
    assert q_add("m1", "nina", "x", "h1", now + 100, path=p) == a and q_add("m1", "nina", "x", "h1", now + 7 * 3600, path=p) != a   # nach 6 h neu
    assert mesh_log_put("k1", "m1:0", now, "NINA", "x", True, "nina", p) and mesh_log_put("k2", "m1:0", now, "NINA", "y", False, "nina", p)
    assert mesh_log_put("k3", "m2:0", now, "NINA", "z", True, "nina", p) and mesh_log_put("k4", "m1:0", now, "x", "w", True, "manuell", p)
    assert mesh_count_since("m1:0", ("nina", "nina_detail"), now - 10, p) == 1 and mesh_count_since("m2:0", ("nina",), now - 10, p) == 1
    assert mesh_last("k4", p)["kind"] == "manuell" and mesh_last("nix", p) is None and not q_set(a, p, bogus=1)
    assert cleanup_t3(now + KEEP_QUEUE_S + 3 * 3600, p)["mesh_queue"] == 1
    assert q_add("m1", "nina", "x", "h", now, path="/proc/nicht/schreibbar/x.db") is None and q_open("m1", "/proc/nicht/schreibbar/x.db") == []
    return "database selftest Teil 3 ok"

if __name__ == "__main__":
    print(selftest())
    print(selftest_t2())
    print(selftest_t3())
T3MDB_EOF
EXPECT_MMR="c5ffda3907b0dd511a5e147ebe228bf6eb098dabba6ac0ad753526283f7595bd"
cat > "$W/new/mesh_router.py" << 'T3MMR_EOF'
"""mesh_router.py - Dublettenpruefung fuer Mesh-Texte (Teil 1) + automatischer Versand echter Alarme an Mesh 1 (Teil 2).

Teil 1: md5-Hashes normalisierter Texte je Kanal in lagezentrum.db (Tabelle mesh_log, 24 h).
Teil 2 (Freigabe Frank): echte Alarme (ASA-Echtalarm, NINA, echter BR24-Notfall) automatisch an Mesh 1 (Kanal 0).
  - Dieses Modul oeffnet selbst KEINE Verbindung und spricht kein Mesh-Geraet an: gesendet wird nur ueber die
    uebergebene Funktion send_fn (im Dashboard: dieselbe send_meshtastic wie der Knopf "An Mesh 1 senden",
    Bridge 127.0.0.1:5001). Einzige Sendestelle: _tx().
  - Schalter mesh_auto.json (Kill-Switch), fehlt/kaputt = AUS. Bei AUS wird nichts gesendet.
  - Probe/Test nie: Probealarm, Test/Uebung/Warntag im Text, eigene TEST-Meldungen, RDS PTY 30 (Alarmtest).
  - Eine Meldung je Alarm (Tabelle mesh_auto), gleicher Inhalt nicht innerhalb 6 h, hoechstens 3 Auto-Meldungen
    je Stunde, jeder Versuch in mesh_log protokolliert (Hash, Kanal auto0, Quelle, Text, Ergebnis).
"""
import hashlib
import json
import os
import re
import time

try:
    import database as _db
except Exception:  # Modul fehlt -> Hilfen liefern None, nie Absturz
    _db = None

_WS = re.compile(r"\s+")
_NUM = re.compile(r"\d+(?:[.,]\d+)?")


def normalize(text, ignore_numbers=False):
    """Kleinbuchstaben, Leerraum zusammengefasst; optional Zahlen neutralisiert (Messwert-Schwankung egal)."""
    t = _WS.sub(" ", str(text or "")).strip().lower()
    return _NUM.sub("#", t) if ignore_numbers else t


def msg_hash(text, channel=None, ignore_numbers=False):
    """md5 ueber Kanal + normalisierten Text (hex)."""
    raw = "%s|%s" % ("" if channel is None else str(channel), normalize(text, ignore_numbers))
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def is_duplicate(text, channel=None, ignore_numbers=False, path=None):
    """Nur pruefen (nicht merken). -> True/False, None bei Fehler/ohne DB."""
    if _db is None:
        return None
    return _db.mesh_known(msg_hash(text, channel, ignore_numbers), path)


def remember(text, channel=None, ignore_numbers=False, path=None):
    """Merken. -> True wenn schon bekannt war (Dublette), False wenn neu, None bei Fehler."""
    if _db is None:
        return None
    return _db.mesh_seen(msg_hash(text, channel, ignore_numbers), None if channel is None else str(channel), path)


def selftest():
    import os
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "m.db")
    assert normalize("  Hallo\n Welt ") == "hallo welt"
    assert msg_hash("Pegel 1,2 m", 0, True) == msg_hash("pegel 3,4 m", 0, True)
    assert msg_hash("a", 0) != msg_hash("a", 1)
    assert is_duplicate("x", 0, path=p) is False
    assert remember("x", 0, path=p) is False and remember(" X ", 0, path=p) is True and is_duplicate("x", 0, path=p) is True
    return "mesh_router selftest ok"


# ---------------------------------------------------------------- Teil 2: Auto-Versand echter Alarme an Mesh 1
AUTO_FILE = "mesh_auto.json"     # Kill-Switch {"on": true/false}; fehlt/kaputt = AUS
AUTO_CHANNEL = 0                 # Mesh 1 = Kanalindex 0 (wie Knopf "An Mesh 1 senden")
AUTO_LOGCH = "auto0"             # Kanal-Kennung im mesh_log fuer Auto-Versand
AUTO_SAME_S = 6 * 3600           # gleicher Inhalt erst nach 6 h wieder
AUTO_HOUR_MAX = 3                # hoechstens 3 Auto-Meldungen je Stunde
AUTO_MAX = 200                   # Zeichen (Bridge schneidet ebenfalls bei 200)
AUTO_SRC = {"ASA": "ALARM ASA DE", "BR24": "ALARM BR24", "NINA": "ALARM NINA"}
TEST_RE = re.compile(r"\b(probe\w*|test\w*|warntag|uebungs?\w*|übung\w*|exercise)\b", re.I)
OWN_TEST_RE = re.compile(r"^\s*TEST\b.*keine echte Warnung", re.I | re.S)


def auto_state(base):
    """-> {"on": bool, "t", "by"} - nur on == true (bool) zaehlt als AN."""
    try:
        with open(os.path.join(base, AUTO_FILE), encoding="utf-8") as f:
            d = json.load(f)
        d = d if isinstance(d, dict) else {}
    except Exception:
        d = {}
    return {"on": d.get("on") is True, "t": d.get("t") if isinstance(d.get("t"), (int, float)) else None, "by": str(d.get("by") or "")[:20] or None}


def set_auto(base, on, by="dashboard", now=None):
    """Schalter atomar setzen. -> neuer Zustand"""
    fn = os.path.join(base, AUTO_FILE)
    tmp = "%s.tmp-%d" % (fn, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"on": on is True, "t": int(now or time.time()), "by": str(by)[:20]}, f)
    os.replace(tmp, fn)
    return auto_state(base)


def is_test(a):
    """Probe/Test/Uebung/eigene TEST-Meldung/RDS PTY 30 -> True (wird nie gesendet)."""
    if not isinstance(a, dict) or a.get("test") or a.get("probe"):
        return True
    tx = " ".join(str(a.get(k) or "") for k in ("text", "kind", "why"))
    return bool(TEST_RE.search(tx) or OWN_TEST_RE.search(str(a.get("text") or "")) or re.search(r"\bPTY\s*30\b", tx))


def auto_text(a):
    t = " ".join(("%s: %s" % (AUTO_SRC.get(a.get("src"), "ALARM"), a.get("text") or "")).split())
    return t if len(t) <= AUTO_MAX else t[:AUTO_MAX - 1].rstrip() + "…"


def _tx(send_fn, text):
    """Einzige Sendestelle dieses Moduls."""
    return bool(send_fn(text, channel=AUTO_CHANNEL))


def auto_send(alarms, send_fn, base, path=None, now=None, also_sent=()):
    """Echte Alarme an Mesh 1 (nur wenn Schalter AN). alarms: [{"src": ASA|BR24|NINA, "key", "text", "real", "test", "dup_existing"}].
    also_sent: Texte, die in den letzten 6 h schon per Knopf an Mesh 1 gingen. -> Bericht {"on", "sent": [...], "skip": [...]}"""
    now = int(now or time.time())
    st = auto_state(base)
    rep = {"on": st["on"], "t": now, "sent": [], "skip": []}
    manual = {normalize(x) for x in (also_sent or ())}
    for a in alarms or []:
        try:
            if not isinstance(a, dict) or a.get("src") not in AUTO_SRC or not a.get("key") or not str(a.get("text") or "").strip():
                continue
            akey = "%s:%s" % (a["src"], a["key"])
            skip = lambda why: rep["skip"].append({"key": akey, "src": a["src"], "why": why})
            if is_test(a):
                skip("Probe/Test - wird nie gesendet")
                continue
            if not a.get("real"):
                skip("kein echter Alarm (z. B. NINA unter Severe) - wird nicht gesendet")
                continue
            if a.get("dup_existing"):
                skip(str(a.get("dup_existing"))[:120])
                continue
            if not st["on"]:
                skip("Auto-Versand AUS (Schalter)")
                continue
            if _db is None:
                skip("lagezentrum.db nicht verfuegbar - sicherheitshalber nicht gesendet")
                continue
            text = auto_text(a)
            h = msg_hash(text, AUTO_LOGCH)
            old = _db.mesh_auto_get(akey, path)
            if old and old.get("ok") == 1:
                skip("schon gesendet (eine Meldung je Alarm)")
                continue
            core = normalize(a.get("text"))
            if normalize(text) in manual or (len(core) >= 8 and any(core in m for m in manual)):
                skip("schon per Knopf an Mesh 1 gesendet")
                continue
            seen = _db.mesh_hash_since(h, now - AUTO_SAME_S, path)
            if seen is not False:
                skip("gleicher Inhalt in den letzten 6 h schon gesendet" if seen else "Dublettenpruefung nicht lesbar - nicht gesendet")
                continue
            n = _db.mesh_auto_count(now - 3600, path)
            if n is None or n >= AUTO_HOUR_MAX:
                skip("Grenze %d Auto-Meldungen je Stunde erreicht" % AUTO_HOUR_MAX if n is not None else "Zaehler nicht lesbar - nicht gesendet")
                continue
            r = _db.mesh_auto_reserve(akey, h, a["src"], text, now, path)
            if r is None:
                skip("schon versucht (naechster Versuch fruehestens nach %d min, hoechstens %d Versuche)" % (_db.AUTO_RETRY_S // 60, _db.AUTO_TRIES_MAX))
                continue
            try:
                ok = _tx(send_fn, text)
            except Exception as e:
                print("mesh_router Auto-Versand:", e, flush=True)
                ok = False
            _db.mesh_auto_done(akey, ok, path)
            _db.mesh_log_put(h, AUTO_LOGCH, now, a["src"], text, ok, "auto", path)
            rep["sent"].append({"key": akey, "src": a["src"], "text": text, "ok": ok, "try": r})
            if not getattr(send_fn, "selftest", False):     # Selbsttest-Sender nicht ins Journal (sieht sonst wie echter Versand aus)
                print("mesh_router: Auto-Versand %s an Mesh 1 (Kanal %d): %s -> %s" % (a["src"], AUTO_CHANNEL, text[:80], "ok" if ok else "FEHLER"), flush=True)
        except Exception as e:
            print("mesh_router Auto-Versand:", e, flush=True)
    return rep


def selftest_t2():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "m.db")
    out = []

    def fake(text, channel=0):
        out.append((text, channel))
        return True
    fake.selftest = True
    A = [{"src": "ASA", "key": "a1", "text": "Gefahr: Fenster und Türen schließen", "real": True}]
    assert auto_state(d)["on"] is False                                           # Standard AUS
    r = auto_send(A, fake, d, p, 1000)
    assert out == [] and r["skip"][0]["why"].startswith("Auto-Versand AUS"), r      # AUS -> nichts gesendet
    with open(os.path.join(d, AUTO_FILE), "w") as f:
        f.write('{"on": "ja"}')
    assert auto_state(d)["on"] is False and auto_send(A, fake, d, p, 1000) and out == []   # kaputt/kein true -> AUS
    tests = [{"src": "ASA", "key": "p", "text": "Probewarnung ASA DE", "real": True}, {"src": "BR24", "key": "t", "text": "RDS PTY 30 Alarmtest", "kind": "RDS PTY 30 Alarmtest", "real": True},
             {"src": "BR24", "key": "o", "text": "TEST BR24-Warnkette · keine echte Warnung", "real": True}, {"src": "NINA", "key": "w", "text": "Bundesweiter Warntag", "real": True},
             {"src": "ASA", "key": "x", "text": "Gefahr", "real": True, "test": True}, {"src": "ASA", "key": "y", "text": "Gefahr", "real": False}]
    set_auto(d, True, "selftest", 1000)
    assert auto_state(d)["on"] is True
    r = auto_send(tests, fake, d, p, 1000)
    assert out == [] and len(r["skip"]) == 6 and all("Test" in x["why"] for x in r["skip"][:5]) and "kein echter" in r["skip"][5]["why"], r   # Tests/Proben nie
    r = auto_send(A + A, fake, d, p, 1000)
    assert len(out) == 1 and out[0][1] == AUTO_CHANNEL and out[0][0].startswith("ALARM ASA DE: Gefahr") and r["skip"][0]["why"].startswith("schon gesendet"), r
    assert auto_send(A, fake, d, p, 1100)["skip"][0]["why"].startswith("schon gesendet") and len(out) == 1   # eine Meldung je Alarm
    B = [{"src": "ASA", "key": "a2", "text": "Gefahr: Fenster und Türen schließen", "real": True}]
    assert auto_send(B, fake, d, p, 2000)["skip"][0]["why"].startswith("gleicher Inhalt") and len(out) == 1  # gleicher Inhalt < 6 h
    assert len(auto_send(B, fake, d, p, 1000 + AUTO_SAME_S + 1)["sent"]) == 1 and len(out) == 2              # nach 6 h wieder erlaubt
    T = 1000 + AUTO_SAME_S + 10
    C = [{"src": "BR24", "key": "b%d" % i, "text": "Amtliche Gefahrendurchsage Nr. %d" % i, "real": True} for i in range(4)]
    r = auto_send(C, fake, d, p, T)
    assert len(r["sent"]) == 2 and r["skip"][-1]["why"].startswith("Grenze 3") and len(out) == 4, r          # max 3 je Stunde (B zaehlt mit)
    assert len(auto_send(C, fake, d, p, T + 3601)["sent"]) == 2 and len(out) == 6
    assert auto_send([{"src": "NINA", "key": "n1", "text": "Gefahr", "real": True, "dup_existing": "bestehende NINA-Automatik"}], fake, d, p, T + 9000)["skip"][0]["why"].startswith("bestehende")
    assert auto_send([{"src": "BR24", "key": "m1", "text": "Unwetter Erlangen", "real": True}], fake, d, p, T + 9000, also_sent=["BR24 Warnung 17.10.2026 12:00 BR24 UKW RadioText: Unwetter  Erlangen"])["skip"][0]["why"].startswith("schon per Knopf")

    def bad(text, channel=0):
        out.append((text, channel))
        return False
    bad.selftest = True
    D = [{"src": "ASA", "key": "f1", "text": "Gefahr Hochwasser", "real": True}]
    assert auto_send(D, bad, d, p, T + 20000)["sent"][0]["ok"] is False and len(out) == 7
    assert auto_send(D, fake, d, p, T + 20060)["skip"][0]["why"].startswith("schon versucht") and len(out) == 7
    assert auto_send(D, fake, d, p, T + 20000 + 601)["sent"][0]["try"] == "wieder" and len(out) == 8        # Fehlversuch -> spaeter erneut
    assert len(_db.mesh_auto_recent(50, p)) == 7 and all(x["ok"] == 1 for x in _db.mesh_auto_recent(50, p))
    set_auto(d, False, "selftest")
    assert auto_send([{"src": "ASA", "key": "z", "text": "Neue Gefahr", "real": True}], fake, d, p, T + 90000)["sent"] == [] and len(out) == 8   # Kill-Switch
    return "mesh_router selftest Teil 2 ok (AUS = nichts, Tests nie, eine Meldung je Alarm, 6 h gleicher Inhalt, max 3/h, Kill-Switch, Fehlversuch, nur ueber send_fn)"


# ---------------------------------------------------------------- Teil 3 (Meshtastic-Routing und Priorisierung)
# Knoten: m1 = Mesh 1 (192.168.178.141, Bridge 127.0.0.1:5001) = NINA + exklusiv DAB+ (ASA/BR24 aus Teil 2)
#         m2 = Mesh 2 (192.168.178.140, Bridge 127.0.0.1:5002) = nur NINA, DAB+ NIE.
# Auch hier oeffnet das Modul keine Verbindung: gesendet wird nur ueber die uebergebene Funktion transport
# (im Dashboard: send_meshtastic fuer m1, send_nina_to_bayern fuer m2). Einzige Sendestelle: _txn().
# NINA je Knoten: Kanal 0, gleicher Inhalt (Hash in mesh_log) nicht innerhalb 6 h, hoechstens 3 NINA-Meldungen je Stunde,
# Kurzmeldung sofort, Details danach in der Warteschlange: fruehestens 60 s nach der eigenen Kurzmeldung und nur bei freiem Kanal
# (>= 60 s seit unserem letzten Versand auf dem Knoten, Bridge-Warteschlange leer, auf m1 keine DAB-Meldung offen,
# Kanalauslastung < 40 % oder unbekannt). Probe/Test nie.
NODES = {"m1": {"host": "192.168.178.141", "port": 5001, "name": "Mesh 1", "chutil": "mesh1_chutil.json"},
         "m2": {"host": "192.168.178.140", "port": 5002, "name": "Mesh 2", "chutil": "mesh2_chutil.json"}}
PRIVATE_NODE = "m1"
PRIVATE_HOST = "192.168.178.141"     # DAB+ nur hierhin
NINA_ONLY_HOST = "192.168.178.140"   # DAB+ hier NIE
NINA_CHANNEL = 0
NINA_SAME_S = 6 * 3600
NINA_HOUR_MAX = 3
NINA_KINDS = ("nina", "nina_detail")
DETAIL_DELAY_S = 60
FREE_GAP_S = 60
CHUTIL_MAX = 40.0
CHUTIL_STALE_S = 1800                # Messwert aelter als 30 min = unbekannt
Q_TRIES_MAX = 3
Q_RETRY_S = 120
Q_MAX_AGE_S = 6 * 3600               # Kurzmeldung, die 6 h nicht raus konnte, verfaellt
DETAIL_WAIT_S = 20 * 60              # so lange auf NINA-Detaildaten warten, sonst ohne Details
DETAIL_MAX = 200
_T3 = {"dab_busy": 0}


def nina_label(node, channel=NINA_CHANNEL):
    return "%s:%d" % (node, int(channel or 0))


def nina_hash(text, node, channel=NINA_CHANNEL):
    return msg_hash(text, nina_label(node, channel))


def nina_item_is_test(item, detail=None):
    """NINA-Meldung Probe/Test/Uebung (Titel oder Status aus warnings/<id>.json)?"""
    if not isinstance(item, dict):
        return bool(TEST_RE.search(str(item or "")))
    t = " ".join(str(item.get(k) or "") for k in ("title", "headline", "text"))
    st = str((detail or {}).get("status") or "") if isinstance(detail, dict) else ""
    return bool(TEST_RE.search(t) or OWN_TEST_RE.search(t) or st in ("Exercise", "Test", "Draft", "System"))


def _txn(transport, text, channel=0):
    """Einzige Sendestelle von Teil 3."""
    return bool(transport(text, channel=int(channel)))


def dab_private_send(text, transport, health_fn, base, channel=0):
    """DAB+-Meldung (ASA/BR24) NUR an Mesh 1 (192.168.178.141). Harte Pruefung vor jedem Versand:
    Kanal 0, Auto-Versand-Schalter AN, Bridge 127.0.0.1:5001 meldet genau Host 192.168.178.141 (nie .140).
    transport ist die Mesh-1-Sendefunktion. -> {"ok", "why", "host"}"""
    out = {"ok": False, "why": None, "host": None}
    try:
        if int(channel or 0) != 0:
            out["why"] = "DAB nur Kanal 0"
            return out
        if not str(text or "").strip():
            out["why"] = "leer"
            return out
        if not auto_state(base)["on"]:
            out["why"] = "Auto-Versand AUS (Schalter)"
            return out
        h = health_fn(NODES[PRIVATE_NODE]["port"]) if callable(health_fn) else None
        host = str((h or {}).get("host") or "") if isinstance(h, dict) else ""
        out["host"] = host or None
        if host == NINA_ONLY_HOST or host != PRIVATE_HOST or NODES[PRIVATE_NODE]["port"] != 5001:
            out["why"] = "GESPERRT: Bridge 5001 meldet Host %s - DAB+ nur an %s, nie an %s" % (host or "unbekannt", PRIVATE_HOST, NINA_ONLY_HOST)
            return out
        _T3["dab_busy"] += 1
        try:
            out["ok"] = _txn(transport, str(text)[:AUTO_MAX], 0)
        finally:
            _T3["dab_busy"] -= 1
        out["why"] = "gesendet" if out["ok"] else "Bridge-Fehler"
        return out
    except Exception as e:
        out["why"] = "Fehler: %s" % str(e)[:80]
        print("mesh_router DAB:", e, flush=True)
        return out


def dab_pending(alarms, base, path=None, now=None):
    """Offene DAB-Meldung fuer Mesh 1? (Versand laeuft, oder echter ASA/BR24-Alarm, der bei AN noch raus muss)."""
    now = int(now or time.time())
    try:
        if _T3["dab_busy"] > 0:
            return True
        if not auto_state(base)["on"] or _db is None:
            return False
        for a in alarms or []:
            if not isinstance(a, dict) or a.get("src") not in ("ASA", "BR24") or not a.get("real") or is_test(a) or a.get("dup_existing") or not a.get("key"):
                continue
            row = _db.mesh_auto_get("%s:%s" % (a["src"], a["key"]), path)
            if row and (row.get("ok") == 1 or int(row.get("tries") or 0) >= _db.AUTO_TRIES_MAX):
                continue
            if _db.mesh_hash_since(msg_hash(auto_text(a), AUTO_LOGCH), now - AUTO_SAME_S, path):
                continue
            return True
        return False
    except Exception as e:
        print("mesh_router DAB offen:", e, flush=True)
        return True     # im Zweifel Details auf Mesh 1 zurueckhalten


def chutil_get(base, node, now=None):
    """Letzte Kanalauslastung aus meshX_chutil.json (Bridge schreibt alle 5 min). -> (Wert % | None, Alter s | None)"""
    now = time.time() if now is None else now
    try:
        with open(os.path.join(base, NODES[node]["chutil"]), encoding="utf-8") as f:
            h = json.load(f)
        p = h[-1] if isinstance(h, list) and h else None
        if not isinstance(p, dict) or p.get("ch_util") is None:
            return None, None
        age = now - float(p.get("ts") or 0)
        if age > CHUTIL_STALE_S or age < -300:
            return None, int(age)
        return float(p["ch_util"]), int(age)
    except Exception:
        return None, None


def parse_bridge_ts(s):
    """Bridge-Zeit '17.10.2026 14:05:03' (Ortszeit) -> epoch | None"""
    try:
        return time.mktime(time.strptime(str(s).strip(), "%d.%m.%Y %H:%M:%S"))
    except Exception:
        return None


def channel_free(node, now, last_send=None, health=None, chutil=None, dab_open=False):
    """'Kanal frei' (Vorgabe Frank): >= 60 s seit unserem letzten Versand, keine DAB-Meldung offen (m1),
    Kanalauslastung < 40 % (unbekannt = frei nach 60 s); dazu Bridge erreichbar, nicht angehalten, Bridge-Warteschlange leer. -> (bool, Grund)"""
    try:
        h = health if isinstance(health, dict) else None
        if h is None:
            return False, "Bridge %s nicht erreichbar" % NODES[node]["port"]
        if h.get("held"):
            return False, "Bridge angehalten (hold)"
        if int(h.get("queued") or 0) > 0:
            return False, "Bridge-Warteschlange %d" % int(h.get("queued") or 0)
        ts = [t for t in (last_send, parse_bridge_ts(h.get("last_send"))) if t]
        if ts and now - max(ts) < FREE_GAP_S:
            return False, "letzter Versand vor %d s (< %d s)" % (now - max(ts), FREE_GAP_S)
        if node == PRIVATE_NODE and dab_open:
            return False, "DAB-Meldung hat Vorrang (offen)"
        if chutil is not None and chutil >= CHUTIL_MAX:
            return False, "Kanalauslastung %.1f %% (>= %d %%)" % (chutil, CHUTIL_MAX)
        return True, "frei (Auslastung %s)" % ("unbekannt" if chutil is None else "%.1f %%" % chutil)
    except Exception as e:
        return False, "Fehler: %s" % str(e)[:60]


def _clip(t, n):
    t = " ".join(str(t or "").split())
    return t if len(t) <= n else t[:max(1, n - 1)].rstrip() + "…"


def detail_text(lines, details):
    """Zweite, laengere NINA-Meldung: Beschreibung, Handlungsempfehlung, Gebiet. lines: Zeilen der Kurzmeldung,
    details: [{"line", "headline", "desc", "instr", "area": [..]}] -> Text <= 200 Zeichen | None (keine Details)"""
    rows = [d for d in details or [] if isinstance(d, dict) and (d.get("desc") or d.get("instr") or d.get("area"))]
    if not rows:
        return None
    room = (DETAIL_MAX - len("NINA Details: ")) // len(rows) - 3
    parts = []
    for d in rows:
        head = _clip(d.get("headline") or d.get("line") or "", 50)
        area = ", ".join(str(x) for x in (d.get("area") or [])[:4] if x)
        seg = "%s: %s" % (head, _clip(d.get("desc"), 90)) if d.get("desc") else head
        if d.get("instr"):
            seg += " Empfehlung: " + _clip(d.get("instr"), 80)
        if area:
            seg += " Gebiet: " + _clip(area, 50)
        parts.append(_clip(seg, max(40, room)))
    return _clip("NINA Details: " + " || ".join(parts), DETAIL_MAX)


def queue_nina(text, ref, now, path=None, nodes=("m1", "m2")):
    """NINA-Kurzmeldung + Details je Knoten einreihen (gleicher Inhalt, der wartet oder < 6 h erledigt ist, nicht doppelt). -> {node: (short_id, detail_id)}"""
    out = {}
    if _db is None or not str(text or "").strip():
        return out
    for node in nodes:
        try:
            h = nina_hash(text, node)
            sid = _db.q_add(node, "nina", str(text)[:AUTO_MAX], h, now, now, None, None, path, NINA_SAME_S)
            did = None
            if sid is not None and ref:
                old = [r for r in _db._rows_t3("SELECT id FROM mesh_queue WHERE after_id=? AND kind='nina_detail'", (int(sid),), path)]
                did = old[0]["id"] if old else _db.q_add(node, "nina_detail", None, None, now, now + DETAIL_DELAY_S, sid, json.dumps(ref, ensure_ascii=False)[:4000], path)
            out[node] = (sid, did)
        except Exception as e:
            print("mesh_router Warteschlange:", e, flush=True)
    return out


def queue_step(node, now, transport, path=None, free_fn=None, detail_fn=None, only_kind=None, max_n=1):
    """Faellige Eintraege eines Knotens abarbeiten (Kurzmeldung zuerst, Details nur bei freiem Kanal). Vor jedem Versand:
    Hash schon in mesh_log (6 h)? -> dup. -> [{"id", "kind", "state", "why", "ok"}]"""
    rep = []
    if _db is None:
        return rep
    label = nina_label(node)
    for r in _db.q_open(node, path):
        if len(rep) >= max_n:
            break
        try:
            if only_kind and r["kind"] != only_kind:
                continue
            qid = r["id"]
            if now - int(r["created"] or now) > Q_MAX_AGE_S:
                _db.q_set(qid, path, state="skip", why="verfallen (6 h nicht sendbar)", done=now)
                rep.append({"id": qid, "kind": r["kind"], "state": "skip", "why": "verfallen"})
                continue
            if int(r["not_before"] or 0) > now:
                continue
            text = r["text"]
            if r["kind"] == "nina_detail":
                sh = _db.q_get(r["after_id"], path) if r["after_id"] else None
                if not sh or sh["state"] in ("fail", "skip"):
                    _db.q_set(qid, path, state="skip", why="Kurzmeldung nicht gesendet", done=now)
                    rep.append({"id": qid, "kind": "nina_detail", "state": "skip", "why": "Kurzmeldung nicht gesendet"})
                    continue
                if sh["state"] == "wait":
                    continue
                if now - int(sh["done"] or now) < DETAIL_DELAY_S:
                    continue
                if not text:
                    try:
                        ref = json.loads(r["ref"] or "{}")
                    except Exception:
                        ref = {}
                    text = detail_fn(ref) if callable(detail_fn) else None
                    if not text:
                        if now - int(r["created"] or now) > DETAIL_WAIT_S:
                            _db.q_set(qid, path, state="skip", why="keine Detaildaten (warnung.bund.de)", done=now)
                            rep.append({"id": qid, "kind": "nina_detail", "state": "skip", "why": "keine Detaildaten"})
                        continue
                    _db.q_set(qid, path, text=text[:300], hash=nina_hash(text, node))
                free, why = free_fn(node) if callable(free_fn) else (False, "keine Pruefung")
                if not free:
                    _db.q_set(qid, path, why="wartet: %s" % why)
                    continue
            h = nina_hash(text, node)
            seen = _db.mesh_hash_since(h, now - NINA_SAME_S, path)
            if seen is not False:
                st = "dup" if seen else "wait"
                why = "gleicher Inhalt in mesh_log (6 h) - nicht erneut" if seen else "mesh_log nicht lesbar"
                if seen:
                    _db.q_set(qid, path, state="dup", why=why, done=now)
                rep.append({"id": qid, "kind": r["kind"], "state": st, "why": why})
                continue
            n = _db.mesh_count_since(label, NINA_KINDS, now - 3600, path)
            if n is None or n >= NINA_HOUR_MAX:
                _db.q_set(qid, path, not_before=now + 60, why="Grenze %d NINA-Meldungen je Stunde auf %s" % (NINA_HOUR_MAX, NODES[node]["name"]))
                rep.append({"id": qid, "kind": r["kind"], "state": "wait", "why": "Stundengrenze"})
                continue
            try:
                ok = _txn(transport, text, NINA_CHANNEL)
            except Exception as e:
                print("mesh_router %s:" % node, e, flush=True)
                ok = False
            tries = int(r["tries"] or 0) + 1
            _db.mesh_log_put(h, label, now, "NINA", text, ok, r["kind"], path)
            if ok:
                _db.q_set(qid, path, state="ok", why="gesendet", done=now, tries=tries, last_try=now)
            elif tries >= Q_TRIES_MAX:
                _db.q_set(qid, path, state="fail", why="%d Versuche fehlgeschlagen" % tries, done=now, tries=tries, last_try=now)
            else:
                _db.q_set(qid, path, why="Fehlversuch %d, neu in %d s" % (tries, Q_RETRY_S), not_before=now + Q_RETRY_S, tries=tries, last_try=now)
            rep.append({"id": qid, "kind": r["kind"], "state": "ok" if ok else ("fail" if tries >= Q_TRIES_MAX else "wait"), "ok": ok, "text": text})
        except Exception as e:
            print("mesh_router Warteschlange %s:" % node, e, flush=True)
    return rep


def selftest_t3():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "lagezentrum.db")
    sent = []

    def mk(node, ok=True):
        def tr(text, channel=0):
            sent.append((node, text, channel))
            return ok
        tr.selftest = True
        return tr
    m1, m2 = mk("m1"), mk("m2")
    H = {5001: {"host": "192.168.178.141", "queued": 0}, 5002: {"host": "192.168.178.140", "queued": 0}}
    # DAB nur an .141 (harte Pruefung)
    assert dab_private_send("ALARM ASA DE: x", m1, H.get, d)["why"].startswith("Auto-Versand AUS") and sent == []
    set_auto(d, True, "selftest")
    assert dab_private_send("ALARM ASA DE: x", m1, lambda port: {"host": NINA_ONLY_HOST}, d)["ok"] is False and sent == []     # .140 -> NIE
    assert dab_private_send("ALARM ASA DE: x", m1, lambda port: None, d)["ok"] is False and sent == []                          # unbekannt -> nie
    assert dab_private_send("ALARM ASA DE: x", m1, H.get, d, channel=1)["ok"] is False and sent == []
    assert dab_private_send("ALARM ASA DE: x", m1, H.get, d)["ok"] is True and sent == [("m1", "ALARM ASA DE: x", 0)]
    assert all(s[0] != "m2" for s in sent) and _T3["dab_busy"] == 0
    sent.clear()
    # NINA beide Knoten, Kurzmeldung sofort, Details nach 60 s bei freiem Kanal
    now = 1790000000
    ref = {"lines": ["Nürnberg: Gefahr"], "ids": ["mow.1"]}
    det = lambda ref: detail_text(ref.get("lines"), [{"line": "Nürnberg: Gefahr", "headline": "Gefahrstoffaustritt", "desc": "Rauch über Nürnberg-Nord",
                                                        "instr": "Fenster und Türen schließen", "area": ["Stadt Nürnberg"]}])
    q = queue_nina("NINA: Nürnberg: Gefahr", ref, now, p)
    assert set(q) == {"m1", "m2"} and queue_nina("NINA: Nürnberg: Gefahr", ref, now + 1, p) == q          # nicht doppelt einreihen
    st = {"free": {"m1": (True, "frei"), "m2": (True, "frei")}}
    ff = lambda node: st["free"][node]
    assert queue_step("m1", now, m1, p, ff, det, only_kind="nina")[0]["ok"] and queue_step("m2", now, m2, p, ff, det, only_kind="nina")[0]["ok"]
    assert [s[0] for s in sent] == ["m1", "m2"] and all(s[2] == 0 for s in sent)
    assert queue_step("m1", now + 30, m1, p, ff, det) == [] and len(sent) == 2                                # Details erst nach 60 s
    st["free"]["m1"] = (False, "DAB-Meldung hat Vorrang (offen)")
    assert queue_step("m1", now + 61, m1, p, ff, det) == [] and len(sent) == 2                                # m1 belegt -> wartet
    r = queue_step("m2", now + 61, m2, p, ff, det)
    assert r and r[0]["ok"] and sent[-1][0] == "m2" and sent[-1][1].startswith("NINA Details: Gefahrstoffaustritt") and "Empfehlung" in sent[-1][1]
    st["free"]["m1"] = (True, "frei")
    assert queue_step("m1", now + 90, m1, p, ff, det)[0]["ok"] and sent[-1][0] == "m1" and len(sent) == 4
    assert queue_nina("NINA: Nürnberg: Gefahr", ref, now + 200, p) == q and queue_step("m1", now + 200, m1, p, ff, det) == [] and len(sent) == 4   # 6 h nicht doppelt
    # Dedup ueber mesh_log (z. B. per Knopf schon gesendet) + Stundengrenze 3 je Knoten
    _db.mesh_log_put(nina_hash("NINA: Fürth: Hochwasser", "m1"), "m1:0", now + 300, "x", "NINA: Fürth: Hochwasser", True, "manuell", p)
    queue_nina("NINA: Fürth: Hochwasser", None, now + 310, p)
    assert queue_step("m1", now + 310, m1, p, ff, det)[0]["state"] == "dup" and len(sent) == 4
    assert queue_step("m2", now + 310, m2, p, ff, det)[0]["ok"] and len(sent) == 5                            # m2 hat eigenes Protokoll
    queue_nina("NINA: Erlangen: Sturm", None, now + 320, p)
    assert queue_step("m2", now + 320, m2, p, ff, det)[0]["state"] == "wait" and len(sent) == 5               # m2: 3 in der Stunde
    assert queue_step("m1", now + 320, m1, p, ff, det)[0]["ok"] and len(sent) == 6                            # m1: erst 3
    assert queue_step("m2", now + 3700, m2, p, ff, det)[0]["ok"] and len(sent) == 7                           # Stunde vorbei
    # Fehlversuch -> spaeter erneut, nach 3 Versuchen aufgegeben, Details verfallen
    bad = mk("m1", False)
    queue_nina("NINA: Lauf: Brand", {"lines": ["Lauf: Brand"]}, now + 4000, p)
    assert queue_step("m1", now + 4000, bad, p, ff, det, only_kind="nina")[0]["state"] == "wait"
    assert queue_step("m1", now + 4060, bad, p, ff, det) == []                                                # 120 s Pause
    queue_step("m1", now + 4130, bad, p, ff, det)
    assert queue_step("m1", now + 4260, bad, p, ff, det)[0]["state"] == "fail"
    _r = queue_step("m1", now + 4400, m1, p, ff, det)
    assert _r and _r[0]["why"] == "Kurzmeldung nicht gesendet", _r
    # Kanal-frei-Regeln
    assert channel_free("m1", now, None, None)[0] is False
    assert channel_free("m1", now, now - 30, {"queued": 0})[0] is False and channel_free("m1", now, now - 61, {"queued": 0})[0] is True
    assert channel_free("m1", now, now - 61, {"queued": 2})[0] is False and channel_free("m1", now, None, {"queued": 0, "held": True})[0] is False
    assert channel_free("m1", now, now - 61, {"queued": 0}, 45.0)[0] is False and channel_free("m1", now, now - 61, {"queued": 0}, 12.0)[0] is True
    assert channel_free("m1", now, now - 61, {}, None, dab_open=True)[0] is False and channel_free("m2", now, now - 61, {}, None, dab_open=True)[0] is True
    assert channel_free("m1", time.time(), None, {"last_send": time.strftime("%d.%m.%Y %H:%M:%S")})[0] is False
    with open(os.path.join(d, "mesh1_chutil.json"), "w") as f:
        json.dump([{"ts": now - 100, "ch_util": 41.5}], f)
    assert chutil_get(d, "m1", now) == (41.5, 100) and chutil_get(d, "m1", now + CHUTIL_STALE_S + 1)[0] is None and chutil_get(d, "m2", now) == (None, None)
    # Probe/Test, DAB offen
    assert nina_item_is_test({"title": "Probealarm Sirenen"}) and nina_item_is_test({"title": "Gefahr"}, {"status": "Exercise"}) and not nina_item_is_test({"title": "Gefahr"}, {"status": "Actual"})
    al = [{"src": "ASA", "key": "k9", "text": "Gefahr Großbrand", "real": True}]
    assert dab_pending(al, d, p, now) is True and dab_pending([dict(al[0], test=True)], d, p, now) is False and dab_pending([], d, p, now) is False
    set_auto(d, False, "selftest")
    assert dab_pending(al, d, p, now) is False
    assert detail_text(["x"], [{"line": "x"}]) is None and len(detail_text(["x"], [{"line": "x", "desc": "y" * 500, "instr": "z" * 300, "area": ["a" * 99]}])) <= DETAIL_MAX
    return "mesh_router selftest Teil 3 ok (DAB nur .141 - .140/unbekannt gesperrt, NINA beide Knoten Kanal 0, Details nach 60 s bei freiem Kanal, DAB-Vorrang auf m1, 6 h Hash je Knoten, 3/h je Knoten, Fehlversuch, nur ueber transport)"


if __name__ == "__main__":
    print(selftest())
    print(selftest_t2())
    print(selftest_t3())
T3MMR_EOF
PD="$W/patch-t3-dash.py"; B2A="$W/t2_dash_block_v1.py"; B2N="$W/t2_dash_block.py"; B3="$W/t3_dash_block.py"; SG="$W/guard_t3.py"; SH="$W/show_t3.py"
for x in "$EXPECT_B2A $B2A" "$EXPECT_B2N $B2N" "$EXPECT_B3 $B3" "$EXPECT_PD $PD" "$EXPECT_GUARD $SG" "$EXPECT_SHOW $SH" \
         "$EXPECT_MDB $W/new/database.py" "$EXPECT_MMR $W/new/mesh_router.py"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
NEW_MOD16="$(for m in "${MODS[@]}"; do sha256sum "$W/new/$m" | cut -c1-16; done | tr '\n' ' ')"
# ---------- 1) Basis (sha16 bekannt oder Guards erkannt; Teil 2 muss drin sein) ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
case " $KNOWN_DASH16 " in *" $D16 "*) KD=bekannt;; *) KD="neu, Erkennung ueber Guards";; esac
[[ "$S16" == "$KNOWN_SDR16" ]] && KS="bekannt, bleibt" || KS="anders als erwartet, bleibt unveraendert"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $KD); prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $KS)"
grep -q '# ===== /teil2 =====' "$F" && grep -q '# ===== /sdrTeil2 =====' "$M" || { echo "STOP: Teil 2 fehlt noch - bitte zuerst apply-teil2.sh einspielen, nichts geaendert"; exit 1; }
python3 "$PD" "$F" "$W/work/dashboard.py" "$B2A" "$B2N" "$B3" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
i=0; set -- $OLD_MOD16; OLDS=("$@"); set -- $NEW_MOD16; NEWS=("$@")
for m in "${MODS[@]}"; do
  [[ -f "$DASH_DIR/$m" ]] || { echo "STOP: $m fehlt (Teil 2 nicht installiert?) - nichts geaendert"; exit 1; }
  h=$(sha256sum "$DASH_DIR/$m" | cut -c1-16)
  if [[ "$h" == "${OLDS[$i]}" ]]; then echo "  $m sha16 $h = Teil 2 -> wird ersetzt"
  elif [[ "$h" == "${NEWS[$i]}" ]]; then echo "  $m sha16 $h = Teil 3 schon drin"
  else echo "STOP: $m sha16 $h unbekannt (erwartet Teil 2 ${OLDS[$i]} oder Teil 3 ${NEWS[$i]}) - nichts geaendert"; exit 1; fi
  cp "$DASH_DIR/$m" "$W/old/$m"; i=$((i + 1))
done
SM16=$(sha256sum "$DASH_DIR/sdr_manager.py" 2>/dev/null | cut -c1-16 || echo fehlt)
grep -q '# ---------------------------------------------------------------- Teil 2' "$DASH_DIR/sdr_manager.py" 2>/dev/null || { echo "STOP: sdr_manager.py ohne Teil 2 - nichts geaendert"; exit 1; }
echo "  sdr_manager.py sha16 $SM16 ($([[ "$SM16" == "$KNOWN_SM16" ]] && echo bekannt || echo anders), bleibt unveraendert)"
echo "OK Basis erkannt: Dashboard Guards rdsNotfall/lageDB/ninaCalm/lageMesh1/funkHarden2/meshBootQuiet/teil2, Sendewege send_meshtastic + send_nina_to_bayern -> $(cat "$W/p2.log")"
# ---------- 1b) Zuordnung pruefen: Mesh 1 = .141 (Bridge 5001), Mesh 2 = .140 (Bridge 5002); sonst STOP ----------
python3 - "$DASH_DIR" "$EXP_M1" "$EXP_M2" > "$W/map.log" << 'MAPPY' || { cat "$W/map.log"; echo "STOP: Knoten-Zuordnung weicht ab - nichts geaendert (bitte klaeren, welcher Knoten Mesh 1/Mesh 2 ist)"; exit 1; }
import ast, re, sys
d, e1, e2 = sys.argv[1:4]
want = {"MESHTASTIC_HOST": e1, "MESH1_HOST": e1, "MESHTASTIC_HOST_BAYERN": e2, "MESH2_HOST": e2}
got = {}
for n in ast.parse(open(d + "/config.py", encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id in want:
                got[t.id] = n.value.value
bad = ["config.py %s = %s (erwartet %s)" % (k, got.get(k, "fehlt"), v) for k, v in want.items() if got.get(k) != v]
b1 = open(d + "/mesh_bridge.py", encoding="utf-8").read()
b2 = open(d + "/mesh_bridge_bayern.py", encoding="utf-8").read()
if not re.search(r'^LISTEN = \("127\.0\.0\.1", 5001\)', b1, re.M) or "from config import MESHTASTIC_HOST" not in b1:
    bad.append("mesh_bridge.py nicht Port 5001 mit MESHTASTIC_HOST aus config.py")
if not re.search(r'^LISTEN = \("127\.0\.0\.1", 5002\)', b2, re.M) or not re.search(r'^\s*MESHTASTIC_HOST = "192\.168\.178\.140"', b2, re.M):
    bad.append("mesh_bridge_bayern.py nicht Port 5002 mit 192.168.178.140")
if bad:
    print("  " + "\n  ".join(bad)); raise SystemExit(1)
print("Mesh 1 = %s (Bridge 5001, NINA + DAB+), Mesh 2 = %s (Bridge 5002, nur NINA)" % (e1, e2))
MAPPY
echo "OK Zuordnung: $(cat "$W/map.log")"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - erst Dienst pruefen, nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
python3 "$PD" "$W/work/dashboard.py" "$W/work/d2.py" "$B2A" "$B2N" "$B3" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: Dashboard nicht idempotent"; exit 1; }
rm -f "$W/work/d2.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/new/database.py" "$W/new/mesh_router.py"; do
    "$py" -W error -m py_compile "$x" || { echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp "$W/new/"*.py "$W/msbx/"
for py in "$SPY" "$VPY"; do
  for k in "database.py:database selftest Teil 3 ok" "mesh_router.py:mesh_router selftest Teil 3 ok" "database.py:database selftest Teil 2 ok" "mesh_router.py:mesh_router selftest Teil 2 ok"; do
    m=${k%%:*}; want=${k#*:}
    (cd "$W/msbx" && timeout 120 "$py" "$m" > "$W/mst.log" 2>&1) || { tail -12 "$W/mst.log"; echo "STOP: Selbsttest $m ($py) - nichts geaendert"; exit 1; }
    [[ "$(cat "$W/mst.log")" == *"$want"* ]] || { tail -5 "$W/mst.log"; echo "STOP: Selbsttest $m ohne '$want' ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest Module mit $SPY und $VPY (Sandbox, Testsender ohne Funk): database + mesh_router Teil 1/2/3 ($(grep 'mesh_router selftest Teil 3' "$W/mst.log" | cut -c1-150))"
python3 "$SG" "$F" "$W/work/dashboard.py" "$W/old" "$W/new" "$B2A" "$B2N" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons, alle 3 Dateien)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
SAME=1
cmp -s "$W/work/dashboard.py" "$F" || SAME=0
for m in "${MODS[@]}"; do cmp -s "$W/new/$m" "$DASH_DIR/$m" || SAME=0; done
ALL=("$F"); for m in "${MODS[@]}"; do ALL+=("$DASH_DIR/$m"); done
if [[ "$SAME" == 1 ]]; then
  echo "OK Teil 3 schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "teil3|Traceback|Error" | tail -8 | cut -c1-200 || true
    for x in "${ALL[@]}"; do [[ -f "$x.bak-teil3-$TS" ]] && cp -a "$x.bak-teil3-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-teil3-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  lagezentrum.db bleibt (neue Tabelle mesh_queue stoert Teil 2 nicht); Sicherung: lagezentrum.db.bak-teil3-$TS"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-teil3-$TS"
    { ls -1t "$x.bak-teil3-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$DASH_DIR/lagezentrum.db" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$DASH_DIR/lagezentrum.db" "$DASH_DIR/lagezentrum.db.bak-teil3-$TS" \
      || { rm -f "$DASH_DIR/lagezentrum.db.bak-teil3-$TS"; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$DASH_DIR/lagezentrum.db.bak-teil3-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for m in "${MODS[@]}"; do
    cp "$W/new/$m" "$DASH_DIR/$m.new" && chmod --reference="$DASH_DIR/$m.bak-teil3-$TS" "$DASH_DIR/$m.new" && mv -f "$DASH_DIR/$m.new" "$DASH_DIR/$m" || { rb "installieren $m"; exit 1; }
  done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-teil3-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-dashboard - warte auf HTTP (max 240 s; Warteschlange startet erst nach der Mesh-Startsperre, sendet jetzt nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in /api/sdr/ui /api/br24 /api/sdr/live /api/broadcast/events /api/t2/status /api/t3/status; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
c=$(code -X POST "$B/api/t3/status" -H 'Content-Type: application/json' -d '{}'); [[ "$c" == 405 ]] && echo "OK /api/t3/status nur lesen (POST $c)" || rbx "/api/t3/status nimmt POST an ($c)"
"${CURL[@]}" "$B/api/t3/status" -o "$W/t3_1.json" || true
python3 "$SH" check "$W/t3_1.json" && echo "OK /api/t3/status gueltig (Mesh 1 $EXP_M1 NINA + DAB+, Mesh 2 $EXP_M2 nur NINA)" || rbx "/api/t3/status ungueltig oder teil3 nicht aktiv"
"${CURL[@]}" "$B/" -o "$W/lage.html" || true
grep -q 'id="t2-js"' "$W/lage.html" && grep -q 'id="t3-js"' "$W/lage.html" && echo "OK Lage-Seite: Teil-2-Kachel + Teil-3-Hinweis eingebunden" || rbx "Lage-Seite ohne Teil-2-Kachel/Teil-3-Hinweis"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
L1=$(python3 -c "
import sys; s=open(sys.argv[1],encoding='utf-8',errors='replace').read(); i=s.rfind('doPrepperRestore'); print('ja' if i>=0 and s.find('class=\"tile', i) < 0 and s.find('class=\"card', i) < 0 else 'nein')" "$W/pi.html" 2>/dev/null || echo nein)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x), letzte Kachel: $L1" || rbx "/pi Sicherung veraendert ($R0/$R1)"
sleep 5
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "teil[23] (aktiv|FEHLER)" | tail -4 || true)
if [[ "$JD" == *"teil3 FEHLER"* || "$JD" == *"teil2 FEHLER"* ]]; then rbx "Dashboard: $JD"; fi
if [[ "$JD" == *"teil3 aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'teil3 aktiv' | tail -1 | cut -c1-220)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet teil3 nicht (Journal)"; fi
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|teil3 (Warteschlange|Antwort|mesh_log|Hinweis|DAB|Details|NINA-Filter|NINA Mesh [12] -> alter Weg):|teil2 (Pruefung|Kachel|live|NINA-Details):" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/teil3-Fehler" || rbx "$E Traceback/teil3-Fehlerzeilen im Journal Dashboard"
echo "OK guards teil3(dash)=$(grep -c '# ===== teil3:' "$F" || true) teil2(dash)=$(grep -c '# ===== teil2:' "$F" || true) ninaCalm=$(grep -c '# ===== ninaCalm:' "$F" || true) funkHarden2=$(grep -c '# ===== funkHarden2' "$F" || true) lageMesh1=$(grep -c '# ===== lageMesh1:' "$F" || true) rdsNotfall(dash)=$(grep -c '# ===== rdsNotfall:' "$F" || true) sdrTeil2(sdr)=$(grep -c '# ===== sdrTeil2:' "$M" || true) Teil3(Module)=$(for m in "${MODS[@]}"; do grep -c '# ---------------------------------------------------------------- Teil 3' "$DASH_DIR/$m" || true; done | tr '\n' '/')"
[[ -f "$F.bak-teil3-$TS" ]] && echo "Backups: *.bak-teil3-$TS (dashboard.py, database.py, mesh_router.py, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "${ALL[@]}" "$M" "$DASH_DIR/sdr_manager.py"; do echo "  $(basename "$x") sha16 $(sha256sum "$x" | cut -c1-16), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG teil3=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, Teil 3 bleibt aktiv. COMMIT $COMMIT_ARG teil3=1"; exit 0' INT
echo "Stand Teil 3:"
python3 "$SH" status "$W/t3_1.json" || true
echo "Hinweis: DAB+-Meldungen gehen nur bei eingeschaltetem Auto-Versand (Lage-Seite) und nur an Mesh 1. NINA laeuft wie bisher automatisch, jetzt an beide Knoten mit Detailmeldung."
echo "COMMIT $COMMIT_ARG teil3=1 fertig"
