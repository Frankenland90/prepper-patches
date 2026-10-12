#!/bin/bash
set -euo pipefail
# sdrPlus: SDR-Planer prepper-sdr v2 - alle 30 min kurzer Rundfunk-Block (UKW-RDS via redsea, DAB+ via welle-cli: Warn-/Durchsagetexte),
# Meteor-M LRPT 137,9 MHz bei Ueberfluegen >= 20 Grad (satdump, Bahndaten celestrak mit Offline-Cache), Seite /meteor,
# Funk-Kachel-Zeilen Rundfunk + Meteor. Nur Empfang - sendet nichts (kein Funk, kein Mesh).
# Nur bei dashboard.py sha16 18daef1da37a85b5 (vor sdAck), a54abd412adc0503 (nach sdAck) oder 18daef1da37a85b5 + sdAck-Block. Neustart nur prepper-sdr + prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdr3-apply
UNIT="prepper-sdr.service"
REDSEA_URL="https://github.com/windytan/redsea/archive/refs/tags/v1.3.1.tar.gz"
REDSEA_SHA="2d1137dba23c1ae2d8af87bda45ab90ee962e55d3b93dc9295d1a53e15a8cfae"
REDSEA_BIN="${SDR_REDSEA_BIN:-/usr/local/bin/redsea}"
SGP4_URL="https://files.pythonhosted.org/packages/14/a8/4d6b7e2d964582be06ab6ebcbd00ae9b54cd0d9ca9c0dbb393e49ea568e6/sgp4-2.22.tar.gz"
SGP4_SHA="17f0a2eaad2dca065b6de25c1ceaa940ff7cfa8cc67120cb4111a00f177b86f9"
NEW_LIB=0
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sdrPlus apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="e966209ca4f78c73ea58a54ffad784acaea1e3415a58ee54f64f3b7f4ba8b92a"
EXPECT_MOD="04701aad9b2ac2a6511bea9433535d9d73c14e46bd05cc2f791794662e345d9b"
EXPECT_NET="1ffc61d0268fd874e5ff0b5f9a85274875c73a31051b5eb7b067092a90ac2336"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-sdr-plus.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""sdrPlus: Block vor __main__ in dashboard.py (Rundfunk-Zeile, Meteor-Zeile, /meteor). Sendet nichts.
Akzeptiert dashboard.py vor sdAck (sha16 EXPECT) oder nach sdAck (sdAck-Block herausgerechnet ergibt EXPECT)."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== sdrPlus:"
EXPECT = "18daef1da37a85b5"
EXPECT_ACK = "a54abd412adc0503"
NEED = ["# ===== sdrFunk:", "# ===== sdrFunk2:", "def _sdr_status():", "\n_SDR_TILE_JS = ", "sdrBtns(c,d,poll);}", "var t=(SDRN[a]||a||'–');",
        "def _sdr_page(title, body_js, data):", "\n_SDR_HEAD_JS = ", "app = Flask("]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== sdrPlus: Rundfunk-Warntexte (UKW-RDS, DAB+) + Meteor-M LRPT (/meteor) auf der Funk-SDR-Kachel; nur Empfang, Dashboard liest nur =====
import re as _sdrp_re

_SDRP_IMG_RE = _sdrp_re.compile(r"^[0-9]{8}-[0-9]{4}_[A-Za-z0-9]{1,8}_[A-Za-z0-9_-]{1,40}\.(jpg|png)$")
_SDRP_JOBN = "(/^rds/.test(a)?'UKW-RDS':(/^dab/.test(a)?'DAB+':(a==='meteor'?'Meteor-Empfang':a)))"
_sdrp_orig_status = _sdr_status


def _sdrp_bc():
    b = _sdr_load("broadcast_state.json", {}) or {}
    now = _sdr_time.time()
    fm = [x for x in (b.get("fm") or {}).values() if isinstance(x, dict)]
    dab = [x for x in (b.get("dab") or {}).values() if isinstance(x, dict)]
    warn = [w for w in (b.get("warn") or []) if isinstance(w, dict) and now - (w.get("last") or w.get("t") or 0) < 6 * 3600]
    warn.sort(key=lambda w: -(w.get("last") or w.get("t") or 0))
    return {"fm_n": sum(1 for x in fm if x.get("ps") and now - (x.get("t") or 0) < 6 * 3600),
            "dab_n": sum(1 for x in dab if x.get("n") and now - (x.get("t") or 0) < 6 * 3600),
            "fm": sorted(fm, key=lambda x: str(x.get("name"))), "dab": dab, "warn": warn[:20], "t": b.get("saved")}


def _sdrp_meteor():
    ms = _sdr_load("meteor_state.json", {}) or {}
    pp = _sdr_load("sdr_passes.json", {}) or {}
    now = _sdr_time.time()
    imgs = []
    d = _sdr_os.path.join(_SDR_BASE, "meteor")
    try:
        for f in sorted(_sdr_os.listdir(d), reverse=True):
            if _SDRP_IMG_RE.match(f):
                imgs.append({"f": f, "kb": int(_sdr_os.path.getsize(_sdr_os.path.join(d, f)) / 1024)})
    except Exception:
        pass
    nxt = [x for x in (pp.get("passes") or []) if isinstance(x, dict) and (x.get("los") or 0) > now]
    sg = (_sdr_load("sdr_status.json", {}) or {}).get("sgp4")
    return {"sgp4": sg, "images": imgs[:40], "passes": nxt[:12], "hist": (ms.get("passes") or [])[-10:][::-1], "tle_t": pp.get("tle_t"), "pred_t": pp.get("t")}


def _sdr_status():
    d = _sdrp_orig_status()
    try:
        st = d.get("status") or {}
        a = str(st.get("active") or "")
        if (a.startswith("rds:") or a.startswith("dab:") or a == "meteor") and d.get("service") == "läuft":
            d["state"] = "ok"
        bc = _sdrp_bc()
        d["bc"] = {"fm_n": bc["fm_n"], "dab_n": bc["dab_n"], "warn": bc["warn"][:3], "next": st.get("next_bc"),
                   "tools": st.get("tools") or {}}
        imgs = _sdrp_meteor()["images"]
        d["meteor"] = {"next": st.get("next_pass"), "last_img": imgs[0]["f"] if imgs else None, "n_img": len(imgs),
                       "on": a == "meteor"}
    except Exception as e:
        d["plus_err"] = str(e)[:100]
    return d


def _sdrp_api_bc():
    from flask import jsonify
    return jsonify(_sdrp_bc())


def _sdrp_api_meteor():
    from flask import jsonify
    return jsonify(_sdrp_meteor())


def _sdrp_img(name):
    from flask import send_from_directory, abort
    if not _SDRP_IMG_RE.match(name or ""):
        abort(404)
    d = _sdr_os.path.join(_SDR_BASE, "meteor")
    try:
        return send_from_directory(d, name, max_age=86400)
    except TypeError:
        return send_from_directory(d, name)


_SDRP_METEOR_JS = _SDR_HEAD_JS + """
function d2(x){return x<10?'0'+x:''+x;}function hm(t){var d=new Date(t*1000);return d2(d.getHours())+':'+d2(d.getMinutes());}
function dm(t){var d=new Date(t*1000);return d2(d.getDate())+'.'+d2(d.getMonth()+1)+'. '+hm(t);}
function render(d,st){head(st);var m=document.getElementById('sdrMain');m.textContent='';var tl=(st.status||{}).tools||{};
if(!tl.satdump||d.sgp4===false){var w=sdrEl('div','card');w.appendChild(sdrEl('div','title','Meteor-Empfang nicht bereit'));
if(!tl.satdump)w.appendChild(sdrEl('div','sub','satdump: nicht installiert – keine Aufnahme (sudo apt install satdump)'));
if(d.sgp4===false)w.appendChild(sdrEl('div','sub','Bahnrechnung (sgp4): nicht installiert – keine Überflug-Vorhersage'));m.appendChild(w);}
var c=sdrEl('div','card');c.appendChild(sdrEl('div','title','🛰 Nächste Meteor-M Überflüge (über '+((d.passes[0]||{}).min_el||20)+'°)'));
if(!d.passes.length)c.appendChild(sdrEl('div','sub','Keine Vorhersage – noch keine Bahndaten (TLE). Der Planer holt sie, sobald Internet da ist, und rechnet danach offline weiter.'));
else{var tb=sdrEl('table');var h=sdrEl('tr');['Satellit','Beginn','Ende','max. Höhe','um','Richtung','Dauer'].forEach(function(x){h.appendChild(sdrEl('th','',x));});tb.appendChild(h);
d.passes.forEach(function(p){sdrRow(tb,[p.sat,dm(p.aos),hm(p.los),Math.round(p.max_el)+'°',hm(p.max_t),p.dir||'',Math.round((p.los-p.aos)/60)+' min']);});
var sc=sdrEl('div','scroll');sc.appendChild(tb);c.appendChild(sc);}
c.appendChild(sdrEl('div','sub','Bahndaten '+(d.tle_t?'vom '+dm(d.tle_t):'fehlen')+'. Während eines Überflugs hat Meteor Vorrang vor 433/APRS (137,9 MHz LRPT, satdump).'));m.appendChild(c);
var g=sdrEl('div','card');g.appendChild(sdrEl('div','title','Letzte Bilder ('+d.images.length+')'));
if(!d.images.length)g.appendChild(sdrEl('div','sub','Noch keine Bilder. Dafür braucht es eine V-Dipol- oder QFH-Antenne im Freien; mit der Stabantenne kommt meist nichts an.'));
d.images.slice(0,30).forEach(function(x){var a=sdrEl('a');a.href='/meteor/img/'+encodeURIComponent(x.f);a.target='_blank';var im=document.createElement('img');im.src=a.href;im.loading='lazy';
im.style.maxWidth='100%';im.style.width='360px';im.style.margin='4px';im.style.borderRadius='6px';im.alt=x.f;a.appendChild(im);var w=sdrEl('div');w.style.display='inline-block';w.style.verticalAlign='top';
w.appendChild(a);w.appendChild(sdrEl('div','sub',x.f.replace(/\\.(jpg|png)$/,'')+' · '+x.kb+' kB'));g.appendChild(w);});m.appendChild(g);
var hc=sdrEl('div','card');hc.appendChild(sdrEl('div','title','Letzte Aufnahmen'));if(!d.hist.length)hc.appendChild(sdrEl('div','sub','noch keine'));
else{var t2=sdrEl('table');d.hist.forEach(function(p){sdrRow(t2,[p.aos?dm(p.aos):'',p.sat||'',p.max_el?Math.round(p.max_el)+'°':'',{t:(p.images||[]).length?(p.images.length+' Bild(er)'):(p.note||'keine Bilder'),cls:'w'}]);});hc.appendChild(t2);}
m.appendChild(hc);}
function refresh(){Promise.all([fetch('/api/meteor').then(function(r){return r.json();}),fetch('/api/sdr/status').then(function(r){return r.json();})]).then(function(x){render(x[0],x[1]);}).catch(function(){});}
try{var D=JSON.parse(document.getElementById('sdrData').textContent);render(D.d,D.st);}catch(e){}
setInterval(refresh,60000);
"""


def _sdrp_page_meteor():
    try:
        return _sdr_page("Meteor-M Wettersatellit", _SDRP_METEOR_JS, {"d": _sdrp_meteor(), "st": _sdr_status()})
    except Exception as e:
        print("sdrPlus /meteor:", e, flush=True)
        return ('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>Meteor</title></head><body style="background:#0f172a;color:#e2e8f0;font-family:sans-serif">'
                '<p>Meteor-Seite: Daten gerade nicht lesbar (%s).</p><p><a style="color:#93c5fd" href="/funk">↩ Funk</a></p></body></html>') % _sdr_html.escape(str(e)[:120])


_SDRP_TILE_ADD = r"""var B=d.bc||{},M=d.meteor||{};
if(B.tools&&(B.tools.redsea||B.tools.welle)||B.fm_n||B.dab_n){var ws=B.warn||[],w=ws.filter(function(x){return x.kind!=='TA'&&(ws[0].last||0)-(x.last||0)<3600;})[0]||ws[0];
if(w){var red=(w.kind!=='TA');ln(c,(red?'⚠ ':'● ')+'Rundfunk: '+w.src+' '+w.kind+' '+sdrHM(w.last||w.t).slice(-5)+': '+String(w.text||'').slice(0,80),red?'#ef4444':'#eab308');}
else ln(c,'📻 Rundfunk: '+(B.fm_n||0)+' UKW · '+(B.dab_n||0)+' DAB · keine Warnung'+(B.next?' · nächster Blick '+sdrHM(B.next).slice(-5):''),'#94a3b8');}else ln(c,'📻 Rundfunk: redsea/welle-cli nicht installiert','#64748b');
var np=M.next;ln(c,'🛰 Meteor: '+((B.tools&&B.tools.satdump===false)?'satdump nicht installiert':M.on?'Empfang läuft':(np?'nächster Überflug '+sdrHM(np.aos).slice(-5)+' ('+String(np.sat||'').replace('METEOR-','')+', '+Math.round(np.max_el)+'°)':'keine Vorhersage'))+(M.n_img?' · '+M.n_img+' Bilder':'')+' ›',null,'/meteor');
"""


def _sdrp_patch_js():
    global _SDR_TILE_JS, _SDR_JS_COMMON
    old = "var t=(SDRN[a]||a||'–');"
    new = "var t=(SDRN[a]||" + _SDRP_JOBN + "||'–');"
    _SDR_JS_COMMON = _SDR_JS_COMMON.replace(old, new)
    t = _SDR_TILE_JS.replace(old, new)
    k = "sdrBtns(c,d,poll);}"
    if "id=\"sdr-js\"" in t and t.count(k) == 1:
        t = t.replace(k, _SDRP_TILE_ADD + k)
    _SDR_TILE_JS = t
    return t.count("Meteor:") == 1


try:
    _sdrp_ok = _sdrp_patch_js()
    for _sdr_r, _sdr_ep, _sdr_fn in (("/meteor", "sdrp_meteor", _sdrp_page_meteor), ("/meteor/img/<name>", "sdrp_img", _sdrp_img),
                                     ("/api/meteor", "sdrp_api_meteor", _sdrp_api_meteor), ("/api/broadcast", "sdrp_api_bc", _sdrp_api_bc)):
        if _sdr_ep not in app.view_functions and not any(r.rule == _sdr_r for r in app.url_map.iter_rules()):
            app.add_url_rule(_sdr_r, endpoint=_sdr_ep, view_func=_sdr_fn, methods=["GET"])
    app.view_functions["sdr_status"] = _sdr_api_status
    print("sdrPlus aktiv: Kachel=%s" % _sdrp_ok, flush=True)
except Exception as _sdr_e:
    print("sdrPlus:", _sdr_e, flush=True)
# ===== /sdrPlus =====
'''


def h16(s):
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def which(src):
    if h16(src) == EXPECT:
        return "vor sdAck"
    if h16(src) == EXPECT_ACK and src.count("# ===== sdAck:") == 1:
        return "nach sdAck"
    a, e = "# ===== sdAck:", "# ===== /sdAck =====\n"
    if src.count(a) != 1 or src.count(e) != 1 or "/api/sd_health/ack" not in src:
        return None
    i = src.index(a)
    j = src.index(e) + len(e)
    if j < i:
        return None
    head, rest = src[:i].rstrip("\n"), src[j:].lstrip("\n")
    for k in range(0, 5):
        if h16(head + "\n" * k + rest) == EXPECT:
            return "nach sdAck"
    return None


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    h = h16(src)
    if MARK in src:
        print("RESULT dashboard.py=schon sha16 %s" % h)
        return
    st = which(src)
    if st is None and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s ist weder %s (vor sdAck) noch %s + sdAck - nichts geaendert" % (h, EXPECT, EXPECT))
    miss = [a for a in NEED if a not in src]
    if miss:
        raise SystemExit("STOP: fehlt %s - nichts geaendert" % miss)
    if '"/meteor"' in src or "def _sdrp_" in src or "/api/broadcast" in src:
        raise SystemExit("STOP: sdrPlus-Teile gibt es schon - nichts geaendert")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (%s; sha16 vorher %s, nachher %s)" % (st or "nosha", h, h16(new)))


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
  bc   = alle 30 min kurzer Rundfunk-Block: UKW-RDS (rtl_fm | redsea: PS/Radiotext/TA) + DAB+ (welle-cli: DLS/Ansagen)
  meteor = Wettersatellit Meteor-M LRPT 137,9 MHz (satdump) bei Ueberfluegen >= 20 Grad, hat dann Vorrang
Nur Empfang: Rundfunk + Wettersatellit + ISM + Amateurfunk.
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

V = 2
BASE = os.path.dirname(os.path.abspath(__file__))
MODES = ("auto", "433", "aprs", "tcp", "off")
DEFAULT_CFG = {
    "slice_433_s": 300, "slice_aprs_s": 300, "auto": ["433", "aprs"],
    "f433": "433.92M", "faprs": "144.800M", "ppm": 0, "gain_433": None, "gain_aprs": None,
    "device": None, "tcp_port": 1234, "tcp_bind": "0.0.0.0", "tcp_default_min": 60, "tcp_max_min": 480,
    "usb_ids": ["0bda:2838", "0bda:2832"], "max_jsonl_mb": 8, "aprs_max_jsonl_mb": 4,
    "home": None, "keep_days": 14,
    "bc_enable": True, "bc_interval_s": 1800, "fm": None, "fm_s": 25, "dab": None, "dab_s": 60, "dab_port": 7979, "gain_fm": None, "gain_dab": None,
    "meteor_enable": True, "sats": None, "meteor_min_el": 20, "meteor_gain": 38, "meteor_samplerate": "1.024e6",
    "meteor_keep": 30, "meteor_cap_mb": 300, "meteor_tmp": "/tmp/prepper-meteor", "tle_refresh_h": 12,
    "redsea": None, "welle": None, "satdump": None,
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


# ---------------------------------------------------------------- Rundfunk (UKW-RDS / DAB+) - nur Warn-/Verkehrskennungen + Texte
FM_DEFAULT = [{"name": "BR24", "f": "102.0M"}, {"name": "Bayern 3", "f": "97.9M"}, {"name": "Bayern 1", "f": "88.9M"}]
DAB_DEFAULT = ["11D"]
WARN_WORDS = re.compile(r"warn|unwetter|gefahr|katastroph|evaku|sirene|alarm|hochwasser|stromausfall|bevoelkerung|bevölkerung|amtliche", re.I)


class StateBC:
    """broadcast_state.json: je UKW-Sender PS/RT/TA/TP, je DAB-Kanal Ensemble/DLS/Ansagen, Warnliste."""

    def __init__(self, base):
        self.f = p("broadcast_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "fm": {}, "dab": {}, "warn": []}
        for k, v in (("fm", {}), ("dab", {}), ("warn", [])):
            self.d.setdefault(k, v)
        self.dirty = False
        self.last_saved = 0
        self.cur = None

    def warn(self, src, kind, text, now):
        w = self.d["warn"]
        for x in w[-20:]:
            same = x.get("text") == text or (kind == "TA" and now - x.get("last", 0) < 1800)
            if x.get("src") == src and x.get("kind") == kind and same and now - x.get("t", 0) < 6 * 3600:
                x["last"] = int(now)
                return
        w.append({"t": int(now), "last": int(now), "src": src, "kind": kind, "text": (text or "")[:160]})
        cut = now - 48 * 3600
        self.d["warn"] = [x for x in w if x.get("last", x.get("t", 0)) >= cut][-60:]

    def on_rds(self, name, freq, line, now=None):
        line = line.strip()
        if not line.startswith("{"):
            return None
        try:
            g = json.loads(line)
        except Exception:
            return None
        now = now or time.time()
        s = self.d["fm"].get(name) or {"name": name, "f": freq}
        s.update({"f": freq, "t": int(now)})
        s["groups"] = s.get("groups", 0) + 1
        for k_in, k_out in (("pi", "pi"), ("ps", "ps"), ("radiotext", "rt"), ("prog_type", "pty"), ("tp", "tp"), ("ta", "ta")):
            if k_in in g:
                s[k_out] = g[k_in] if not isinstance(g[k_in], str) else g[k_in].strip()[:80]
        if g.get("ta") is True and s.get("tp"):
            s["ta_t"] = int(now)
            self.warn(name, "TA", "Durchsage aktiv (TA)", now)
        if isinstance(g.get("radiotext"), str) and WARN_WORDS.search(g["radiotext"]):
            self.warn(name, "RT", g["radiotext"].strip(), now)
        if g.get("group") in ("9A",) or "ews" in g:
            self.warn(name, "EWS", "RDS-Notfallgruppe empfangen", now)
        self.d["fm"][name] = s
        self.dirty = True
        return s

    def on_dab(self, ch, mux, now=None):
        now = now or time.time()
        if not isinstance(mux, dict):
            return None
        ens = mux.get("ensemble") or {}
        lab = ens.get("label") if isinstance(ens.get("label"), str) else (ens.get("label") or {}).get("label")
        svcs, alarm = [], []

        def walk(o, path):
            if isinstance(o, dict):
                for k, v in o.items():
                    kl = str(k).lower()
                    if ("announc" in kl or "alarm" in kl or kl in ("asu", "asw")) and v not in (None, False, 0, "", [], {}):
                        alarm.append("%s%s=%s" % (path, k, json.dumps(v, ensure_ascii=False)[:80]))
                    walk(v, path + str(k) + ".")
            elif isinstance(o, list):
                for x in o[:80]:
                    walk(x, path)
        walk(mux, "")
        for sv in (mux.get("services") or [])[:40]:
            if not isinstance(sv, dict):
                continue
            l = sv.get("label")
            l = l if isinstance(l, str) else (l or {}).get("label")
            dls = sv.get("dls")
            dls = dls if isinstance(dls, str) else (dls or {}).get("label")
            svcs.append({"label": (l or "?").strip()[:30], "dls": (dls or "").strip()[:160]})
            if dls and WARN_WORDS.search(dls):
                self.warn("DAB %s %s" % (ch, (l or "").strip()), "DLS", dls.strip(), now)
        for a in alarm[:3]:
            self.warn("DAB %s" % ch, "Ansage", a, now)
        self.d["dab"][ch] = {"ch": ch, "t": int(now), "ensemble": (lab or "").strip()[:40], "services": svcs, "alarm": alarm[:5], "n": len(svcs)}
        self.dirty = True
        return self.d["dab"][ch]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


# ---------------------------------------------------------------- Wettersatelliten (Meteor-M LRPT) - Bahnvorhersage
SATS_DEFAULT = [{"name": "METEOR-M2 3", "norad": 57166, "f": "137.9e6"}, {"name": "METEOR-M2 4", "norad": 59051, "f": "137.9e6"}]


def _gmst(jd_ut1):
    t = (jd_ut1 - 2451545.0) / 36525.0
    g = 67310.54841 + (876600.0 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t ** 3
    return math.radians((g % 86400.0) / 240.0)


def _obs_ecef(lat, lon, h_km=0.35):
    a, f = 6378.137, 1 / 298.257223563
    e2 = f * (2 - f)
    la, lo = math.radians(lat), math.radians(lon)
    n = a / math.sqrt(1 - e2 * math.sin(la) ** 2)
    return ((n + h_km) * math.cos(la) * math.cos(lo), (n + h_km) * math.cos(la) * math.sin(lo), (n * (1 - e2) + h_km) * math.sin(la))


def look(sat, t, lat, lon):
    """-> (Elevation, Azimut) in Grad zum Zeitpunkt t (Unix) oder None. sgp4 TEME -> ECEF (GMST-Drehung)."""
    jd = t / 86400.0 + 2440587.5
    jd0 = math.floor(jd - 0.5) + 0.5
    e, r, _v = sat.sgp4(jd0, jd - jd0)
    if e != 0:
        return None
    g = _gmst(jd)
    x = r[0] * math.cos(g) + r[1] * math.sin(g)
    y = -r[0] * math.sin(g) + r[1] * math.cos(g)
    z = r[2]
    ox, oy, oz = _obs_ecef(lat, lon)
    dx, dy, dz = x - ox, y - oy, z - oz
    la, lo = math.radians(lat), math.radians(lon)
    east = -math.sin(lo) * dx + math.cos(lo) * dy
    north = -math.sin(la) * math.cos(lo) * dx - math.sin(la) * math.sin(lo) * dy + math.cos(la) * dz
    up = math.cos(la) * math.cos(lo) * dx + math.cos(la) * math.sin(lo) * dy + math.sin(la) * dz
    rng = math.sqrt(east ** 2 + north ** 2 + up ** 2)
    return math.degrees(math.asin(up / rng)), (math.degrees(math.atan2(east, north)) + 360) % 360


def predict(tles, lat, lon, start, hours=36, min_el=20.0, horizon=8.0):
    """Ueberfluege mit Max-Elevation >= min_el. tles: [{name,norad,f,l1,l2}]."""
    try:
        from sgp4.api import Satrec
    except Exception:
        lib = os.path.join(BASE, "sdr_lib")  # Ersatz ohne Debian-Paket: reines Python-sgp4 (vom Patch, sha256-geprueft)
        if os.path.isdir(os.path.join(lib, "sgp4")) and lib not in sys.path:
            sys.path.append(lib)
        try:
            from sgp4.api import Satrec
        except Exception:
            return None
    out = []
    for s in tles:
        try:
            sat = Satrec.twoline2rv(s["l1"], s["l2"])
        except Exception:
            continue
        t, end, step = start, start + hours * 3600, 30
        inpass, aos, best, best_t, aos_az = False, None, -90, None, None
        while t <= end:
            la = look(sat, t, lat, lon)
            el = la[0] if la else -90
            if el >= horizon and not inpass:
                inpass, aos, best, best_t, aos_az = True, t, el, t, la[1]
            elif inpass and el >= horizon:
                if el > best:
                    best, best_t = el, t
            elif inpass:
                if best >= min_el:
                    out.append({"sat": s["name"], "norad": s["norad"], "f": s["f"], "aos": int(aos), "los": int(t), "max_el": round(best, 1),
                                "max_t": int(best_t), "dur_s": int(t - aos), "dir": "N→S" if aos_az is not None and (aos_az < 90 or aos_az > 270) else "S→N"})
                inpass = False
            t += step
    out.sort(key=lambda x: x["aos"])
    # Ueberschneidungen: hoeheren Ueberflug behalten
    res = []
    for x in out:
        if res and x["aos"] < res[-1]["los"]:
            if x["max_el"] > res[-1]["max_el"]:
                res[-1] = x
            continue
        res.append(x)
    return res


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
        self.counts = {"433": 0, "aprs": 0, "rds": 0, "dab": 0, "meteor": 0}
        self.sbc = StateBC(base)
        self.special = None
        self.last_bc = time.time() - float(self.cfg.get("bc_interval_s") or 1800) + 120
        self.passes = (load_json(p("sdr_passes.json", base), {}) or {}).get("passes") or []
        self.last_predict = 0
        self.last_tle_try = 0
        self.tools = {}
        self.started = time.time()
        self.lastsig = None

    def log(self, *a):
        print("prepper-sdr:", *a, flush=True)

    def _dev(self, args, flag="-d"):
        if self.cfg.get("device") not in (None, ""):
            args += [flag, str(self.cfg["device"])]
        return args

    def tool(self, name):
        if name not in self.tools:
            import shutil
            exe = {"redsea": "redsea", "welle": "welle-cli", "satdump": "satdump"}[name]
            cand = self.cfg.get(name) or shutil.which(exe) or ("/usr/local/bin/" + exe if os.path.exists("/usr/local/bin/" + exe) else None)
            ok = cand and os.path.basename(str(cand)) == exe and os.path.isfile(cand) and os.access(cand, os.X_OK)
            self.tools[name] = cand if ok else None
        return self.tools[name]

    def fm_list(self):
        v = self.cfg.get("fm")
        return v if isinstance(v, list) and v else FM_DEFAULT

    def dab_list(self):
        v = self.cfg.get("dab")
        return v if isinstance(v, list) and v else DAB_DEFAULT

    def sat_list(self):
        v = self.cfg.get("sats")
        return v if isinstance(v, list) and v else SATS_DEFAULT

    def cmd(self, what):
        c = self.cfg
        if what.startswith("rds:"):
            st = self.fm_list()[int(what[4:])]
            a = ["rtl_fm", "-M", "fm", "-l", "0", "-A", "std", "-s", "171k", "-F", "9", "-f", str(st["f"])]
            if c.get("ppm"):
                a += ["-p", str(int(c["ppm"]))]
            if c.get("gain_fm") not in (None, ""):
                a += ["-g", str(c["gain_fm"])]
            return [self._dev(a) + ["-"], [self.tool("redsea"), "-r", "171k"]]
        if what.startswith("dab:"):
            ch = str(self.dab_list()[int(what[4:])])
            a = [self.tool("welle"), "-c", ch, "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_sdr"]
            if c.get("gain_dab") not in (None, ""):
                a += ["-g", str(c["gain_dab"])]
            return [a]
        if what == "meteor":
            sp = self.special or {}
            ps = sp.get("pass") or {}
            secs = max(60, int(ps.get("los", time.time() + 600) - time.time()))
            return [[self.tool("satdump"), "live", "meteor_m2-x_lrpt", sp.get("tmp") or c["meteor_tmp"], "--source", "rtlsdr",
                     "--samplerate", str(c["meteor_samplerate"]), "--frequency", str(ps.get("f") or "137.9e6"),
                     "--gain", str(c["meteor_gain"]), "--timeout", str(secs)]]
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

    def onrds(self, st, line):
        with self.lock:
            if self.sbc.on_rds(st["name"], st["f"], line):
                self.counts["rds"] += 1

    def start(self, what):
        cmds = self.cmd(what)
        if any(not a[0] for a in cmds):
            raise RuntimeError("Start %s: Programm fehlt" % what)
        self.stderr = []
        prev = None
        procs = []
        try:
            for i, a in enumerate(cmds):
                last = i == len(cmds) - 1
                pr = subprocess.Popen(a, stdin=(prev.stdout if prev else subprocess.DEVNULL), stdout=subprocess.PIPE if (not last or what in ("433", "aprs") or what.startswith("rds:")) else subprocess.DEVNULL,
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
        elif what.startswith("rds:"):
            st = self.fm_list()[int(what[4:])]
            threading.Thread(target=self._reader, args=(procs[-1].stdout, lambda ln, st=st: self.onrds(st, ln)), daemon=True).start()
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
        sp = self.special
        if sp:
            if now < sp["sub_end"]:
                return sp["queue"][sp["i"]]
            self.sub_done(sp, now)
            sp["i"] += 1
            if sp["i"] < len(sp["queue"]) and now < sp.get("hard_end", now + 1):
                sp["sub_end"] = now + sp["durs"][sp["i"]]
                return sp["queue"][sp["i"]]
            if sp["kind"] == "bc":
                self.last_bc = now
                self.sbc.last_saved = 0  # Block-Ergebnis gleich einmal speichern
            self.special = None
        ps = self.pass_now(now)
        if ps:
            tmp = self.cfg["meteor_tmp"]
            self._clean_tmp(tmp)
            os.makedirs(tmp, exist_ok=True)
            self.special = {"kind": "meteor", "queue": ["meteor"], "durs": [ps["los"] - now + 300], "i": 0, "sub_end": ps["los"] + 300,
                            "pass": ps, "tmp": tmp, "t0": now}
            self.log("Meteor-Ueberflug %s max %s Grad bis %s" % (ps["sat"], ps["max_el"], time.strftime("%H:%M", time.localtime(ps["los"]))))
            return "meteor"
        q = self.bc_queue()
        if q and now - self.last_bc >= float(self.cfg.get("bc_interval_s") or 1800):
            tot = sum(d for _, d in q)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + tot + 60:
                self.special = {"kind": "bc", "queue": [j for j, _ in q], "durs": [d for _, d in q], "i": 0, "sub_end": now + q[0][1],
                                "hard_end": now + tot + 30, "t0": now}
                return q[0][0]
            self.last_bc = now - float(self.cfg.get("bc_interval_s") or 1800) + 300
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")] or ["433"]
        if self.active not in order:
            self.auto_idx = self.auto_idx % len(order)
            return order[self.auto_idx]
        sl = float(self.cfg.get("slice_%s_s" % self.active) or 300)
        if len(order) > 1 and now - self.slice_start >= sl:
            self.auto_idx = (order.index(self.active) + 1) % len(order)
            return order[self.auto_idx]
        return self.active

    def bc_queue(self):
        if not self.cfg.get("bc_enable"):
            return []
        q = []
        if self.tool("redsea"):
            q += [("rds:%d" % i, float(self.cfg.get("fm_s") or 25)) for i in range(len(self.fm_list()))]
        if self.tool("welle"):
            q += [("dab:%d" % i, float(self.cfg.get("dab_s") or 60)) for i in range(len(self.dab_list()))]
        return q

    def sub_done(self, sp, now):
        job = sp["queue"][sp["i"]]
        if job.startswith("dab:") and self.procs and self.alive():
            ch = str(self.dab_list()[int(job[4:])])
            try:
                import prepper_sdr_net
                mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
                with self.lock:
                    if self.sbc.on_dab(ch, mux, now):
                        self.counts["dab"] += 1
            except Exception as e:
                self.log("DAB %s: kein Status (%s)" % (ch, e))
                with self.lock:
                    self.sbc.d["dab"].setdefault(ch, {"ch": ch})["err"] = str(e)[:100]
                    self.sbc.d["dab"][ch]["err_t"] = int(now)
                    self.sbc.dirty = True
        if job == "meteor":
            if self.procs:
                self.kill()
            self.collect_meteor(sp)

    def pass_now(self, now):
        if not self.cfg.get("meteor_enable") or not self.tool("satdump"):
            return None
        for ps in self.passes:
            if ps["aos"] - 20 <= now < ps["los"] - 60 and ps["max_el"] >= float(self.cfg.get("meteor_min_el") or 20) and not ps.get("done"):
                ps["done"] = True
                return ps
        return None

    def next_pass(self, now):
        for ps in self.passes:
            if ps["los"] > now and ps["max_el"] >= float(self.cfg.get("meteor_min_el") or 20):
                return ps
        return None

    def maintain(self, now):
        """TLE holen (wenn online, alle 12 h), Ueberfluege vorhersagen (stuendlich). Ohne Netz: Cache."""
        if not self.cfg.get("meteor_enable"):
            return
        fn = p("sdr_tle.json", self.base)
        cache = load_json(fn, {}) or {}
        age = now - (cache.get("t") or 0)
        if age > float(self.cfg.get("tle_refresh_h") or 12) * 3600 and now - self.last_tle_try > 1800:
            self.last_tle_try = now
            try:
                import prepper_sdr_net
                got = []
                for s in self.sat_list():
                    name, l1, l2 = prepper_sdr_net.fetch_tle(s["norad"])
                    got.append({"name": s["name"], "norad": int(s["norad"]), "f": s["f"], "l1": l1, "l2": l2})
                cache = {"t": int(now), "tles": got, "src": "celestrak"}
                write_json(fn, cache)
                self.last_predict = 0
                self.log("TLE aktualisiert:", ", ".join(x["name"] for x in got))
            except Exception as e:
                self.log("TLE nicht geholt (offline?), nutze Cache vom %s: %s" % (time.strftime("%d.%m. %H:%M", time.localtime(cache.get("t") or 0)) if cache.get("t") else "-", e))
        if cache.get("tles") and now - self.last_predict > 3600:
            done = {(x["sat"], x["aos"]) for x in self.passes if x.get("done")}
            ps = predict(cache["tles"], self.saprs.home[0], self.saprs.home[1], now - 900, 36, float(self.cfg.get("meteor_min_el") or 20))
            if ps is not None:
                for x in ps:
                    if (x["sat"], x["aos"]) in done:
                        x["done"] = True
                self.passes = ps
                write_json(p("sdr_passes.json", self.base), {"t": int(now), "tle_t": cache.get("t"), "passes": ps, "min_el": self.cfg.get("meteor_min_el")})
            self.last_predict = now

    def _clean_tmp(self, tmp):
        import shutil
        if tmp.startswith("/tmp/prepper-meteor") and os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)

    def collect_meteor(self, sp):
        """Bilder aus dem satdump-Ausgabeordner (tmpfs) als JPEG nach meteor/ uebernehmen, alte loeschen."""
        ps = sp.get("pass") or {}
        tmp = sp.get("tmp") or ""
        dst = p("meteor", self.base)
        os.makedirs(dst, exist_ok=True)
        pngs = []
        for root, _d, files in os.walk(tmp):
            for fn in files:
                if fn.lower().endswith((".png", ".jpg")):
                    pngs.append(os.path.join(root, fn))
        def score(x):
            n = os.path.basename(x).lower()
            return (0 if "221" in n else 1 if "rgb" in n or "natural" in n else 2 if "msu" in n else 3, -os.path.getsize(x))
        pick = sorted(pngs, key=score)[:3]
        stamp = time.strftime("%Y%m%d-%H%M", time.localtime(ps.get("aos") or time.time()))
        sat = re.sub(r"[^A-Za-z0-9]+", "", (ps.get("sat") or "meteor").replace("METEOR-", ""))[-8:]
        saved = []
        for src in pick:
            base = re.sub(r"[^A-Za-z0-9_-]+", "_", os.path.splitext(os.path.basename(src))[0])[:40]
            out = os.path.join(dst, "%s_%s_%s.jpg" % (stamp, sat, base))
            try:
                from PIL import Image
                im = Image.open(src)
                im = im.convert("RGB")
                if im.width > 1600:
                    im = im.resize((1600, int(im.height * 1600 / im.width)))
                im.save(out + ".tmp", "JPEG", quality=85)
                os.replace(out + ".tmp", out)
            except Exception:
                out = out[:-4] + ".png"
                with open(src, "rb") as a, open(out + ".tmp", "wb") as b:
                    b.write(a.read())
                os.replace(out + ".tmp", out)
            saved.append(os.path.basename(out))
        self._clean_tmp(tmp)
        self._prune_meteor(dst)
        st = load_json(p("meteor_state.json", self.base), {}) or {}
        hist = st.get("passes") or []
        hist.append({"t": int(time.time()), "sat": ps.get("sat"), "aos": ps.get("aos"), "los": ps.get("los"), "max_el": ps.get("max_el"),
                     "images": saved, "note": None if saved else "keine Bilder (Signal zu schwach / Antenne?)",
                     "err": (self.stderr[-1] if self.stderr else None)})
        st["passes"] = hist[-60:]
        st["v"] = V
        write_json(p("meteor_state.json", self.base), st)
        with self.lock:
            self.counts["meteor"] += len(saved)
        self.log("Meteor: %d Bild(er) gespeichert" % len(saved))

    def _prune_meteor(self, dst):
        keep = int(self.cfg.get("meteor_keep") or 30)
        cap = float(self.cfg.get("meteor_cap_mb") or 300) * 1024 * 1024
        files = sorted((os.path.join(dst, f) for f in os.listdir(dst) if f.endswith((".jpg", ".png"))), key=os.path.getmtime, reverse=True)
        tot = 0
        for i, f in enumerate(files):
            tot += os.path.getsize(f)
            if i >= keep or tot > cap:
                os.remove(f)

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
                  "freq": {"433": self.cfg["f433"], "aprs": self.cfg["faprs"]}, "home": list(self.saprs.home),
                  "special": ({"kind": self.special["kind"], "job": self.special["queue"][self.special["i"]], "until": int(self.special["sub_end"])} if self.special else None),
                  "next_bc": int(self.last_bc + float(self.cfg.get("bc_interval_s") or 1800)) if self.bc_queue() else None,
                  "next_pass": self.next_pass(now), "sgp4": predict([], 0, 0, now) is not None, "tools": {"redsea": bool(self.tool("redsea")), "welle": bool(self.tool("welle")), "satdump": bool(self.tool("satdump"))}}
        sig = (st["mode"], st["active"], st["err"], len(st["stick"]), st["until"], bool(self.special))
        if force or sig != self.lastsig or now - self.last_status >= 60:
            write_json(p("sdr_status.json", self.base), st)
            self.last_status, self.lastsig = now, sig
        return st

    def flush(self, force=False):
        with self.lock:
            self.s433.save(force)
            self.saprs.save(force)
            self.sbc.save(force)

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
        if self.procs and not self.alive() and self.special and self.active in self.special["queue"]:
            sp = self.special
            rc = [pr.poll() for pr in self.procs]
            with self.lock:
                tail = self.stderr[-1] if self.stderr else ""
            if sp["kind"] == "bc":
                self.err, self.err_t = "%s beendet (rc %s): %s" % (self.active, rc, tail), int(now)
                self.log(self.err)
            self.kill()
            sp["sub_end"] = now  # naechster Teil / Ende
            self.active = "idle"
            return 1, mode
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
        if self.active == "fehler" and self.special and w in self.special["queue"]:
            self.retry_at = 0
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
                if not self.special:
                    self.maintain(time.time())
            except Exception as e:
                self.log("Wartung:", e)
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
    b = StateBC(tmp)
    assert b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","tp":true,"ta":false,"ps":"BR24    "}')["ps"] == "BR24"
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"0A","tp":true,"ta":true,"ps":"BAYERN 3"}')
    b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Amtliche Warnung vor Unwetter im Landkreis ERH"}')
    assert [w["kind"] for w in b.d["warn"]] == ["TA", "RT"], b.d["warn"]
    dab = b.on_dab("11D", {"ensemble": {"label": {"label": "BR Bayern"}}, "services": [{"label": {"label": "BR24"}, "dls": {"label": "Nachrichten"}},
                                                                                      {"label": {"label": "Bayern 3"}, "dls": {"label": "Unwetterwarnung Nürnberg"}}],
                                     "announcements": [{"type": "Alarm", "active": True}]})
    assert dab["ensemble"] == "BR Bayern" and dab["n"] == 2 and dab["alarm"] and len(b.d["warn"]) == 4, (dab, b.d["warn"])
    b.save(True)
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
cat > "$W/prepper_sdr_net.py" << 'NETPY_EOF'
#!/usr/bin/env python3
"""prepper_sdr_net: einzige Netzzugriffe des SDR-Planers (nur lesen):
- Bahndaten (TLE) der Wettersatelliten von celestrak.org (fester Host, nur wenn online; Cache fuer offline)
- Status-JSON von welle-cli auf 127.0.0.1 (lokal, DAB+-Texte)
Sendet nichts - kein Mesh, kein Funk."""
import json
import re
import urllib.request

CELESTRAK = "https://celestrak.org/NORAD/elements/gp.php?CATNR=%d&FORMAT=tle"
RE_L1 = re.compile(r"^1 (\d{5})[A-Z ]")
RE_L2 = re.compile(r"^2 (\d{5}) ")


def fetch_tle(catnr, timeout=15):
    """-> (name, line1, line2) oder Exception. Nur celestrak.org, Ergebnis wird geprueft."""
    catnr = int(catnr)
    req = urllib.request.Request(CELESTRAK % catnr, headers={"User-Agent": "prepper-sdr/1 (Wetterbilder)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        txt = r.read(4096).decode("ascii", "replace")
    lines = [x.rstrip() for x in txt.splitlines() if x.strip()]
    if len(lines) < 3:
        raise ValueError("TLE leer: %s" % txt[:60])
    name, l1, l2 = lines[0].strip(), lines[1], lines[2]
    m1, m2 = RE_L1.match(l1), RE_L2.match(l2)
    if not (m1 and m2 and int(m1.group(1)) == catnr and int(m2.group(1)) == catnr and len(l1) >= 68 and len(l2) >= 68):
        raise ValueError("TLE ungueltig")
    return name, l1, l2


def fetch_welle(port, timeout=4):
    """mux.json von welle-cli (nur 127.0.0.1)."""
    port = int(port)
    with urllib.request.urlopen("http://127.0.0.1:%d/mux.json" % port, timeout=timeout) as r:
        return json.loads(r.read(2000000).decode("utf-8", "replace"))
NETPY_EOF

# ---------- 0) Bytes + AST-Guards + Selbsttest ----------
P="$W/patch-sdr-plus.py"; M="$W/prepper_sdr.py"; N="$W/prepper_sdr_net.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $M" | sha256sum -c - >/dev/null || { echo "STOP: Modul sha256 falsch"; exit 1; }
echo "$EXPECT_NET  $N" | sha256sum -c - >/dev/null || { echo "STOP: Netzmodul sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
for x in "$M" "$N"; do python3 -W error::SyntaxWarning -m py_compile "$x" || { echo "STOP: py_compile $x - nichts geaendert"; exit 1; }; done
set +e
python3 - "$P" "$M" "$N" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
NET = ("requests", "urllib", "socket", "http", "meshtastic", "subprocess")
def fname(f):
    return f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in NET:
                print("Block: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        fn = fname(node.func)
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record", "set_")) or fn in ("open", "update_all", "urlopen", "Popen", "system", "call", "run", "remove", "unlink", "rmtree", "write_json", "write_text"):
            if fn != "send_from_directory":
                print("Block: verbotener Aufruf", fn); hit = True
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
        print("Block: data_store-Schreiben"); hit = True
for bad in ("POST", "mesh", "Mesh"):
    if bad in blk:
        print("Block enthaelt", bad); hit = True
mod = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
ALLOWED = {"rtl_433", "rtl_fm", "rtl_tcp", "direwolf"}
TOOLS = {"redsea", "welle", "satdump"}
tree = ast.parse(mod)
owner = {}
for fn_node in ast.walk(tree):
    if isinstance(fn_node, ast.FunctionDef):
        for sub in ast.walk(fn_node):
            owner[id(sub)] = fn_node.name
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in ("requests", "urllib", "socket", "http", "meshtastic"):
                print("Modul: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        fn = fname(node.func)
        where = owner.get(id(node))
        if fn == "rmtree" and where == "_clean_tmp":
            pass
        elif fn == "remove" and where == "_prune_meteor":
            pass
        elif fn.startswith(("send", "maybe_mesh")) or fn in ("system", "popen", "call", "check_output", "check_call", "run", "rmtree", "unlink", "remove", "execv", "execvp"):
            print("Modul: verbotener Aufruf", fn, "in", where); hit = True
        if fn == "tool" and not (node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value in TOOLS):
            print("Modul: tool() mit", ast.dump(node.args[0]) if node.args else "-"); hit = True
        for kw in node.keywords:
            if kw.arg == "shell":
                print("Modul: shell="); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and isinstance(node.elts[0].value, str):
        v = node.elts[0].value
        if v.startswith(("rtl", "direwolf", "rpitx", "hackrf", "sendiq", "tx", "multimon", "redsea", "welle", "satdump")) and v not in ALLOWED:
            print("Modul: Programm", v); hit = True
for bad in ("rpitx", "hackrf_transfer", "multimon", "POCSAG", "PTT GPIO", "PTT /dev", "IGSERVER", "PBEACON", "--tx", "/dev/tty"):
    if bad in mod:
        print("Modul: verboten", bad); hit = True
net = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
URLS = {"https://celestrak.org/NORAD/elements/gp.php?CATNR=%d&FORMAT=tle", "http://127.0.0.1:%d/mux.json"}
for node in ast.walk(ast.parse(net)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            m = (getattr(node, "module", None) or a.name)
            if m not in ("json", "re", "urllib.request"):
                print("Netz: Import", m); hit = True
    if isinstance(node, ast.Constant) and isinstance(node.value, str) and "://" in node.value and node.value not in URLS:
        print("Netz: URL", node.value); hit = True
    if isinstance(node, ast.Call) and fname(node.func) not in ("Request", "urlopen", "read", "decode", "splitlines", "strip", "rstrip", "match", "int", "len", "ValueError", "group", "loads", "compile"):
        print("Netz: Aufruf", fname(node.func)); hit = True
    if isinstance(node, ast.keyword) and node.arg == "data":
        print("Netz: data= (POST)"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
python3 "$M" selftest > "$W/selftest.txt" 2>&1 || { cat "$W/selftest.txt"; echo "STOP: Selbsttest Dekoder - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Mesh, Netz nur celestrak/127.0.0.1 lesend, nur Empfangsprogramme ohne Shell) + Selbsttest"

# ---------- 1) Voraussetzungen (nur lesen) ----------
[[ -f "$DASH_DIR/prepper_sdr.py" ]] && grep -q 'prepper_sdr: SDR-Planer' "$DASH_DIR/prepper_sdr.py" || { echo "STOP: prepper_sdr.py (sdrFunk) fehlt - nichts geaendert"; exit 1; }
if [[ -f "$DASH_DIR/prepper_sdr_net.py" ]] && ! cmp -s "$N" "$DASH_DIR/prepper_sdr_net.py" && ! grep -q 'prepper_sdr_net: einzige Netzzugriffe' "$DASH_DIR/prepper_sdr_net.py"; then
  echo "STOP: fremde prepper_sdr_net.py - nichts geaendert"; exit 1; fi
systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "STOP: $UNIT fehlt (erst sdrFunk) - nichts geaendert"; exit 1; }
SDR_WAS=$(systemctl is-active "$UNIT" 2>/dev/null || true)
echo "prepper-sdr vorher: $SDR_WAS"
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen, sdAck=$(grep -c '# ===== sdAck:' "$F" || true)"

# ---------- 2) Trockenlauf ----------
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
for p in / /funk /pi /funk433 /aprs /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /funk=${PRE[/funk]} /pi=${PRE[/pi]} /funk433=${PRE[/funk433]} /aprs=${PRE[/aprs]}"
[[ "${PRE[/funk]}" == "200" ]] || { echo "STOP: /funk antwortet nicht (${PRE[/funk]}) - nichts geaendert"; exit 1; }
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
A0=$(grep -o "sda-js\|sdh-" "$W/pi0.html" | wc -l || true)

# ---------- 3) Programme (apt + redsea) - schon vorhandene bleiben, fehlende = Teil wird uebersprungen ----------
have() { LC_ALL=C dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed'; }
cand() { LC_ALL=C apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [0-9]'; }
need_rs=1
if [[ -x "$REDSEA_BIN" ]] && "$REDSEA_BIN" --version 2>/dev/null | grep -q '1\.3\.1'; then need_rs=0; fi
PK=(welle.io satdump python3-sgp4 python3-pil)
[[ "$need_rs" == 1 ]] && PK+=(build-essential meson ninja-build pkg-config libsndfile1-dev libliquid-dev nlohmann-json3-dev)
MISS=(); for p in "${PK[@]}"; do have "$p" || MISS+=("$p"); done
if [[ ${#MISS[@]} -gt 0 ]]; then
  FREE=$(df -Pm / | awk 'NR==2{print $4}')
  if [[ "${FREE:-0}" -lt 1500 ]]; then
    echo "WARN nur ${FREE} MB frei auf / - installiere keine Pakete (${MISS[*]}); betroffene Teile werden uebersprungen"
  else
    sudo -v
    echo "apt-get update ..."
    sudo env LC_ALL=C apt-get update -qq || echo "WARN apt-get update fehlgeschlagen (offline?)"
    OKP=(); for p in "${MISS[@]}"; do if cand "$p"; then OKP+=("$p"); else echo "WARN Paket $p nicht verfuegbar"; fi; done
    if [[ ${#OKP[@]} -gt 0 ]]; then
      echo "apt install: ${OKP[*]} (kann einige Minuten dauern) ..."
      # shellcheck disable=SC2024
      if ! sudo env LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${OKP[@]}" > "$W/apt.txt" 2>&1; then
        tail -4 "$W/apt.txt"; echo "WARN apt install gesamt fehlgeschlagen - versuche einzeln"
        for p in "${OKP[@]}"; do
          # shellcheck disable=SC2024
          sudo env LC_ALL=C DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$p" >> "$W/apt.txt" 2>&1 || echo "WARN $p nicht installierbar"
        done
      fi
      for p in "${OKP[@]}"; do have "$p" && echo "  installiert: $p" || echo "  WARN fehlt weiter: $p"; done
    fi
  fi
fi
if [[ "$need_rs" == 1 ]]; then
  if command -v meson >/dev/null 2>&1 && dpkg -s libliquid-dev >/dev/null 2>&1; then
    echo "redsea 1.3.1 bauen (einmalig, ~5-10 min auf dem Pi) ..."
    rm -rf "$W/rs" && mkdir -p "$W/rs"
    if curl -fsSL --max-time 120 "$REDSEA_URL" -o "$W/rs/rs.tgz" && echo "$REDSEA_SHA  $W/rs/rs.tgz" | sha256sum -c - >/dev/null; then
      ( cd "$W/rs" && tar xzf rs.tgz && cd redsea-1.3.1 && meson setup build --buildtype=release > "$W/rs/meson.txt" 2>&1 && nice meson compile -C build >> "$W/rs/meson.txt" 2>&1 ) \
        && "$W/rs/redsea-1.3.1/build/redsea" --version 2>/dev/null | grep -q '1\.3\.1' \
        && sudo install -m 0755 "$W/rs/redsea-1.3.1/build/redsea" "$REDSEA_BIN" && echo "OK redsea installiert: $REDSEA_BIN" \
        || { tail -5 "$W/rs/meson.txt" 2>/dev/null; echo "WARN redsea-Bau fehlgeschlagen - UKW-RDS wird uebersprungen"; }
    else
      echo "WARN redsea-Quelle nicht geladen oder sha256 falsch - UKW-RDS wird uebersprungen"
    fi
    rm -rf "$W/rs"
  else
    echo "WARN Bauwerkzeuge fehlen - redsea/UKW-RDS wird uebersprungen"
  fi
fi
RS_AT=""; if [[ -x "$REDSEA_BIN" ]]; then RS_AT="$REDSEA_BIN"; else RS_AT=$(command -v redsea 2>/dev/null || true); fi
T_RS=0; [[ -n "$RS_AT" ]] && T_RS=1 && echo "redsea gefunden: $RS_AT ($("$RS_AT" --version 2>&1 | head -1 | cut -c1-40))"
T_WE=0; command -v welle-cli >/dev/null 2>&1 && T_WE=1
T_SD=0; command -v satdump >/dev/null 2>&1 && T_SD=1
T_SG=0; "${SDR_SG_PY:-/usr/bin/python3}" -c "import sgp4.api" 2>/dev/null && T_SG=1
NEW_LIB=0
if [[ "$T_SG" == 0 ]]; then
  if [[ -f "$DASH_DIR/sdr_lib/sgp4/api.py" ]]; then T_SG=2
  else
    echo "sgp4 ohne Debian-Paket: reines Python-sgp4 2.22 von PyPI (sha256-geprueft) nach $DASH_DIR/sdr_lib ..."
    rm -rf "$W/sg" && mkdir -p "$W/sg"
    if curl -fsSL --max-time 60 "$SGP4_URL" -o "$W/sg/s.tgz" && echo "$SGP4_SHA  $W/sg/s.tgz" | sha256sum -c - >/dev/null \
       && tar xzf "$W/sg/s.tgz" -C "$W/sg" && [[ -f "$W/sg/sgp4-2.22/sgp4/api.py" ]]; then
      mkdir -p "$DASH_DIR/sdr_lib/sgp4" && cp "$W/sg/sgp4-2.22/sgp4/"*.py "$DASH_DIR/sdr_lib/sgp4/" && NEW_LIB=1 && T_SG=2
      echo "OK sgp4 (reines Python) bereit"
    else
      echo "WARN sgp4 nicht ladbar - keine Ueberflug-Vorhersage"
    fi
  fi
fi
T_PI=0; /usr/bin/python3 -c "import PIL" 2>/dev/null && T_PI=1
echo "Programme: redsea=$T_RS welle-cli=$T_WE satdump=$T_SD sgp4=$T_SG PIL=$T_PI"
[[ "$T_RS$T_WE" == "00" ]] && echo "WARN weder redsea noch welle-cli - Rundfunk-Block bleibt aus"
[[ "$T_SD" == 0 || "$T_SG" == 0 ]] && echo "WARN satdump oder sgp4 fehlt - Meteor bleibt aus"

# ---------- 4) Installieren + Neustart (nur prepper-sdr + prepper-dashboard) ----------
same_dash=0; cmp -s "$W/work/dashboard.py" "$F" && same_dash=1
same_mod=0; cmp -s "$M" "$DASH_DIR/prepper_sdr.py" && same_mod=1
same_net=0; cmp -s "$N" "$DASH_DIR/prepper_sdr_net.py" 2>/dev/null && same_net=1
if [[ "$same_dash$same_mod$same_net" == "111" && "$SDR_WAS" == active ]]; then
  echo "OK sdrPlus schon installiert - kein Neustart"
else
  sudo -v
  NEW_NET=0; [[ -f "$DASH_DIR/prepper_sdr_net.py" ]] || NEW_NET=1
  rb() {
    echo "ROLLBACK: $1"
    echo "--- Dashboard-Log (letzte Zeilen) ---"
    sudo journalctl -u prepper-dashboard --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | tail -12 | cut -c1-200 || true
    echo "--- prepper-sdr-Log ---"
    sudo journalctl -u "$UNIT" --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | tail -5 | cut -c1-200 || true
    cp -a "$F.bak-sdr3-$TS" "$F"
    [[ "$NEW_LIB" == 1 ]] && rm -rf "$DASH_DIR/sdr_lib"
    [[ -f "$DASH_DIR/prepper_sdr.py.bak-sdr3-$TS" ]] && cp -a "$DASH_DIR/prepper_sdr.py.bak-sdr3-$TS" "$DASH_DIR/prepper_sdr.py"
    if [[ "$NEW_NET" == 1 ]]; then rm -f "$DASH_DIR/prepper_sdr_net.py"; elif [[ -f "$DASH_DIR/prepper_sdr_net.py.bak-sdr3-$TS" ]]; then cp -a "$DASH_DIR/prepper_sdr_net.py.bak-sdr3-$TS" "$DASH_DIR/prepper_sdr_net.py"; fi
    sudo systemctl restart "$UNIT" 2>/dev/null || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/"), prepper-sdr $(systemctl is-active "$UNIT" 2>/dev/null || true)), Backup $F.bak-sdr3-$TS"
    echo "(installierte Pakete/redsea bleiben - sie tun ohne den neuen Planer nichts)"
  }
  cp -a "$F" "$F.bak-sdr3-$TS"
  [[ "$same_mod" == 0 ]] && cp -a "$DASH_DIR/prepper_sdr.py" "$DASH_DIR/prepper_sdr.py.bak-sdr3-$TS"
  [[ "$NEW_NET" == 0 && "$same_net" == 0 ]] && cp -a "$DASH_DIR/prepper_sdr_net.py" "$DASH_DIR/prepper_sdr_net.py.bak-sdr3-$TS"
  install -m 644 "$N" "$DASH_DIR/prepper_sdr_net.py.new" && mv -f "$DASH_DIR/prepper_sdr_net.py.new" "$DASH_DIR/prepper_sdr_net.py" || { rb "Netzmodul installieren"; exit 1; }
  install -m 644 "$M" "$DASH_DIR/prepper_sdr.py.new" && mv -f "$DASH_DIR/prepper_sdr.py.new" "$DASH_DIR/prepper_sdr.py" || { rb "Modul installieren"; exit 1; }
  mkdir -p "$DASH_DIR/meteor"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
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
  for i in $(seq 1 20); do [[ "$(code "$B/funk")" == "200" && "$(code "$B/api/sdr/status")" == "200" ]] && break; sleep 3; done
  for i in $(seq 1 15); do python3 -c "import json,sys; assert json.load(open(sys.argv[1])).get('v')==2" "$DASH_DIR/sdr_status.json" 2>/dev/null && break; sleep 2; done
  systemctl is-active --quiet "$UNIT" || { sudo journalctl -u "$UNIT" --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -5; rb "$UNIT laeuft nicht"; exit 1; }
  sc=$("${CURL[@]}" "$B/api/sdr/status" -o "$W/s0.json" -w "%{http_code}" || true)
  [[ "$sc" == "200" ]] || { rb "/api/sdr/status antwortet nicht ($sc)"; exit 1; }
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); s=d.get('status') or {}; assert d.get('module') and s.get('v')==2 and d['service']=='läuft' and 'bc' in d and 'meteor' in d and 'tools' in s, d" "$W/s0.json" || { rb "/api/sdr/status ungueltig (Planer v2 schreibt keinen Status?)"; exit 1; }
  echo "OK prepper-sdr v2 laeuft, /api/sdr/status mit Rundfunk + Meteor"
  mok=0
  for i in 1 2 3 4 5 6; do
    mc=$(curl --compressed -sS --connect-timeout 5 --max-time 60 "$B/meteor" -o "$W/meteor.html" -w "%{http_code}" 2> "$W/meteor.err" || true)
    if [[ "$mc" == "200" ]] && grep -q 'id="sdrData"' "$W/meteor.html"; then mok=1; break; fi
    echo "  /meteor Versuch $i: HTTP ${mc:-000} $(head -c 120 "$W/meteor.err" 2>/dev/null) · /funk $(code "$B/funk")"
    sleep 10
  done
  [[ "$mok" == 1 ]] || { head -c 300 "$W/meteor.html" 2>/dev/null; echo; rb "/meteor fehlerhaft (${mc:-000})"; exit 1; }
  for ap in /api/meteor /api/broadcast; do
    aok=0
    for i in 1 2 3; do python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d, dict) and len(d)" < <("${CURL[@]}" "$B$ap") 2>/dev/null && { aok=1; break; }; sleep 5; done
    [[ "$aok" == 1 ]] || { rb "$ap ungueltig"; exit 1; }
  done
  ic=$(code "$B/meteor/img/..%2Fconfig.py"); [[ "$ic" == "404" ]] || { rb "/meteor/img nicht abgesichert ($ic)"; exit 1; }
  echo "OK /meteor /api/meteor /api/broadcast (Bildpfad abgesichert)"
  fc=$("${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" -w "%{http_code}" || true)
  [[ "$fc" == "200" ]] || { rb "/funk antwortet nicht ($fc)"; exit 1; }
  python3 - "$W/funk.html" << 'PY' || { rb "/funk: SDR-Kachel ohne Rundfunk-/Meteor-Zeile"; exit 1; }
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
assert h.count('id="sdrCard"') == 1 and 'id="sdr-js"' in h, "Kachel fehlt"
assert "Rundfunk: " in h and "Meteor: " in h and "'/meteor'" in h and "/funk433" in h and "/aprs" in h, "Zeilen fehlen"
PY
  echo "OK /funk SDR-Kachel mit Zeilen Rundfunk + Meteor (Link /meteor)"
  "${CURL[@]}" -L --max-redirs 5 "$B/" -o "$W/lage.html" || true
  if grep -q -e 'id="sdr-js"' -e 'id="sdrCard"' "$W/lage.html"; then rb "Lage-Seite hat ploetzlich die SDR-Kachel"; exit 1; fi
  for pg in /funk433 /aprs; do
    pc=$("${CURL[@]}" "$B$pg" -o "$W/pg.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] && grep -q 'id="sdrData"' "$W/pg.html" || { rb "$pg fehlerhaft ($pc)"; exit 1; }
  done
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] && grep -q 'id="sdr-pi-js"' "$W/pi.html" || { rb "/pi ohne SDR-Zeile ($pc)"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); A1=$(grep -o "sda-js\|sdh-" "$W/pi.html" | wc -l || true)
    [[ "$R1" == "$R0" && "$A1" == "$A0" ]] || { rb "/pi veraendert (Sicherung $R0/$R1, SD-Kachel $A0/$A1)"; exit 1; }
  fi
  echo "OK Lage ohne Kachel, /funk433 /aprs ok, /pi unveraendert"
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'sdrPlus' | tail -2 || true
fi
fail=0
for p in / /funk /pi /funk433 /aprs /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-sdr3-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi

# ---------- 5) Bahndaten + Vorhersage (nur lesen/anzeigen) ----------
for i in $(seq 1 "${SDR_TLE_WAIT:-15}"); do [[ -f "$DASH_DIR/sdr_passes.json" ]] && break; sleep 2; done
python3 - "$DASH_DIR" << 'PY' || echo "WARN Vorhersage nicht lesbar"
import json, sys, time, os
b = sys.argv[1]
try:
    t = json.load(open(os.path.join(b, "sdr_tle.json")))
    print("TLE: %s vom %s (%s)" % (", ".join(x["name"] for x in t.get("tles") or []), time.strftime("%d.%m. %H:%M", time.localtime(t.get("t") or 0)), t.get("src")))
except Exception as e:
    print("WARN noch keine Bahndaten (offline?) - Planer versucht es alle 30 min:", e)
try:
    pp = json.load(open(os.path.join(b, "sdr_passes.json")))
    ps = [x for x in pp.get("passes") or [] if x["los"] > time.time()][:4]
    print("Meteor-Ueberfluege >= %s Grad: %s" % (pp.get("min_el"), " | ".join("%s %s %d Grad" % (x["sat"].replace("METEOR-", ""), time.strftime("%H:%M", time.localtime(x["aos"])), x["max_el"]) for x in ps) or "keine in 36 h"))
except Exception:
    print("Meteor-Vorhersage: noch keine")
PY
"${CURL[@]}" "$B/api/sdr/status" | python3 -c "
import json,sys
d=json.load(sys.stdin); s=d.get('status') or {}
print('SDR Dienst %s · aktiv %s · Modus %s · naechster Rundfunk-Block %s · Programme %s' % (d.get('service'), s.get('active'), (d.get('mode') or {}).get('mode'),
  __import__('time').strftime('%H:%M', __import__('time').localtime(s['next_bc'])) if s.get('next_bc') else '-', s.get('tools')))
print('SDR Fehler: %s' % (s.get('err') or 'keiner'))
" 2>/dev/null || echo "WARN Status nicht lesbar"
echo "OK guards sdrPlus=$(grep -q '# ===== sdrPlus:' "$F" && echo 1 || echo 0) sdAck=$(grep -q '# ===== sdAck:' "$F" && echo 1 || echo 0) sdrFunk2=$(grep -q '# ===== sdrFunk2:' "$F" && echo 1 || echo 0) sdrFunk=$(grep -q '# ===== sdrFunk:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-sdr3-$TS" ]] && echo "Backup: $F.bak-sdr3-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG sdrPlus=1"
