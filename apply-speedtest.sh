#!/bin/bash
set -euo pipefail
# speedTest: Ookla speedtest CLI 1.2.0 (aarch64, sha256 fest) statt 2-MB-Download. Ergebnisse je Uplink (Telekom/Starlink).
# Nur bei dashboard.py sha16 2ed07dd2c573e6c5. Sendet nichts ins Mesh. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/speedtest-apply
NEED_ARCH=aarch64
ST_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz"
ST_TGZ_SHA="3953d231da3783e2bf8904b6dd72767c5c6e533e163d3742fd0437affa431bd3"
ST_BIN_SHA="d99fa13293f658b53eaa79fe81f4b210db39fdfc1e9698f33da3f234a6008df7"
ST_DIR="$DASH_DIR/tools/ookla"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== speedTest apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
[[ "$(uname -m)" == "$NEED_ARCH" ]] || { echo "STOP: Architektur $(uname -m) statt $NEED_ARCH - nichts geaendert"; exit 1; }
EXPECT_PATCH="b6bf17787616e9a63fdb6deefc73072b1a7422dd21c402219cdb05f8e09bb69b"
EXPECT_MOD="bb3ed433e9139cd4929c653c73896806e010bcd6385897b26dc1d33a45727f8c"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-speedtest.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""speedTest: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== speedTest:"
EXPECT = "2ed07dd2c573e6c5"
NEED = ["# ===== piPolish2:", "# ===== longArchive:", "def fetch_download_mbps", "def fetch_ping", "/api/download_test", "last_download"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== speedTest: Ookla-Speedtest statt 2-MB-Download, Ergebnisse je Uplink (Telekom/Starlink), sendet nichts =====
# Messung alle 3 h (xx:41) + Knopf. update_all ruft keinen Cloudflare-Download mehr ab: fetch_download_mbps liefert
# den letzten Ookla-Wert (ohne Netz). /api/download_test startet eine Ookla-Messung (JSON mit mbps wie bisher).
import os as _st_os
import sys as _st_sys
import json as _st_json
import time as _st_time

_ST_BASE = _st_os.path.dirname(_st_os.path.abspath(__file__))
_st = None
_st_ping = {"v": None, "t": 0}


def _st_uplink():
    try:
        m = _st_sys.modules.get("uplink_detect")
        if m is not None and hasattr(m, "public_state"):
            c = (m.public_state() or {}).get("current")
            if c:
                return c
    except Exception:
        pass
    try:
        with open(_st_os.path.join(_ST_BASE, "uplink_state.json"), "r", encoding="utf-8") as f:
            return (_st_json.load(f) or {}).get("current")
    except Exception:
        return None


def _st_at(rec):
    """Zeitformat wie bisher in last_download['at'] (nur Uhrzeit oder Datum+Uhrzeit)."""
    t = rec.get("t") or 0
    old = (globals().get("last_download") or {}).get("at") if isinstance(globals().get("last_download"), dict) else None
    lt = _st_time.localtime(t)
    if isinstance(old, str) and len(old.strip()) == 8 and old.count(":") == 2:
        if _st_time.strftime("%Y%m%d", lt) == _st_time.strftime("%Y%m%d"):
            return _st_time.strftime("%H:%M:%S", lt)
        return _st_time.strftime("%d.%m. %H:%M:%S", lt)
    return rec.get("at") or _st_time.strftime("%d.%m.%Y %H:%M:%S", lt)


def _st_feed(rec):
    if not rec or rec.get("down") is None:
        return
    ld = globals().get("last_download")
    v = {"mbps": rec["down"], "at": _st_at(rec), "up": rec.get("up"), "src": "ookla", "uplink": rec.get("uplink")}
    if isinstance(ld, dict):
        ld.update(v)
    else:
        globals()["last_download"] = v


def _st_on_result(rec):
    _st_feed(rec)
    a = globals().get("_arch")
    if a is not None and hasattr(a, "_add"):
        vals = {k: rec.get(k) for k in ("down", "up", "ping", "jitter", "dl_lat", "ul_lat", "loss") if isinstance(rec.get(k), (int, float))}
        a._add("speed_" + rec.get("uplink", "unklar"), rec.get("t") or _st_time.time(), vals)


try:
    import speedtest_run as _st_mod
    _st = _st_mod.Runner(_ST_BASE, _st_uplink, _st_on_result)
    _st_feed((_st.d or {}).get("last"))
except Exception as _st_e:
    print("speedTest Modul:", _st_e, flush=True)

if callable(globals().get("fetch_ping")):
    _st_orig_ping = fetch_ping

    def fetch_ping():
        """Ping 8.8.8.8 wie bisher; waehrend eines Speedtests den letzten Leerlauf-Wert liefern (keine Lastwerte)."""
        if _st is not None and _st.running and _st_ping["v"] is not None and _st_time.time() - _st_ping["t"] < 300:
            return _st_ping["v"]
        v = _st_orig_ping()
        if v is not None:
            _st_ping["v"], _st_ping["t"] = v, _st_time.time()
        return v


def fetch_download_mbps():
    """speedTest: kein Netzabruf mehr - letzter Ookla-Download (Mbit/s) oder None."""
    if _st is None:
        return None
    rec = (_st.d or {}).get("last")
    if not rec:
        return None
    _st_feed(rec)
    return rec.get("down")


def _st_pub(rec):
    if not rec:
        return None
    return {k: rec.get(k) for k in ("down", "up", "ping", "jitter", "ping_low", "ping_high", "dl_lat", "ul_lat", "loss", "isp",
                                    "server", "server_auto", "uplink", "at", "t", "dur_s", "manual", "dl_mb", "ul_mb", "url", "note")}


def _st_status():
    if _st is None:
        return {"ok": False, "error": "Modul fehlt"}
    d = _st.status()
    d["last"] = _st_pub(d.get("last"))
    d["by_uplink"] = {k: _st_pub(v) for k, v in (d.get("by_uplink") or {}).items()}
    d["ping_888"] = {"v": _st_ping["v"], "t": int(_st_ping["t"]) if _st_ping["t"] else None}
    return d


def _st_api():
    from flask import jsonify, request
    if request.method == "POST":
        if _st is None:
            return jsonify({"ok": False, "error": "Modul fehlt"}), 503
        if request.args.get("wait") == "1":
            r = _st.run(manual=True, wait=150)
        else:
            r = _st.run(manual=True, wait=0.01)
        out = _st_status()
        out["run"] = {"ok": r.get("ok"), "cached": r.get("cached", False), "running": r.get("running", False)}
        return jsonify(out)
    return jsonify(_st_status())


def _st_download_test():
    """Kompatibel zur Kachel-JS: {ok, mbps, at} - jetzt per Ookla (wartet bis ~100 s)."""
    from flask import jsonify
    if _st is None:
        return jsonify({"ok": False, "mbps": None, "at": None, "error": "Modul fehlt"})
    r = _st.run(manual=True, wait=100)
    rec = r.get("result") if r.get("ok") else None
    if rec:
        _st_feed(rec)
        data_store["download"] = rec.get("down")
        data_store["download_at"] = _st_at(rec)
    return jsonify({"ok": bool(rec), "mbps": rec.get("down") if rec else None, "at": _st_at(rec) if rec else None,
                    "up": rec.get("up") if rec else None, "ping": rec.get("ping") if rec else None,
                    "jitter": rec.get("jitter") if rec else None, "uplink": rec.get("uplink") if rec else None,
                    "server": (rec.get("server") or {}).get("name") if rec else None, "cached": bool(r.get("cached")),
                    "running": bool(r.get("running")), "error": (r.get("error") or {}).get("msg") if not rec and isinstance(r.get("error"), dict) else None})


try:
    _st_ep = None
    for _st_rule in app.url_map.iter_rules():
        if _st_rule.rule == "/api/download_test":
            _st_ep = _st_rule.endpoint
    if _st_ep:
        app.view_functions[_st_ep] = _st_download_test
    else:
        app.add_url_rule("/api/download_test", endpoint="st_download_test", view_func=_st_download_test, methods=["GET"])
    if "st_api" not in app.view_functions:
        app.add_url_rule("/api/speedtest", endpoint="st_api", view_func=_st_api, methods=["GET", "POST"])
except Exception as _st_e:
    print("speedTest Routen:", _st_e, flush=True)

_ST_CSS = """<style id="st-style">
#stBox{margin:8px 0 2px;padding:6px 8px;border:1px solid rgba(148,163,184,.25);border-radius:8px;font-size:13px;line-height:1.5}
#stBox .st-l{display:flex;gap:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
#stBox .st-l>span:first-child{opacity:.7;min-width:4.6em}
#stBox .st-big{font-weight:600;font-variant-numeric:tabular-nums}
#stBox .st-s{font-size:11px;opacity:.6;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#stBox .st-o{font-size:12px;opacity:.8;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
</style>"""

_ST_JS = """<script id="st-js">
(function(){
var UPN={telekom:['🔌','Telekom'],starlink:['🛰️','Starlink'],unklar:['❔','Uplink unklar']};
function n(x,d){return (x===null||x===undefined)?'–':(+x).toFixed(d===undefined?1:d).replace('.',',');}
function ago(t){if(!t)return '';var a=Math.max(0,Date.now()/1000-t);return a<3600?Math.round(a/60)+' min':(a<172800?Math.round(a/3600)+' h':Math.round(a/86400)+' T');}
function el(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;if(txt!==undefined)e.textContent=txt;return e;}
function line(k,v,big){var d=el('div','st-l');d.appendChild(el('span','',k));d.appendChild(el('span',big?'st-big':'',v));return d;}
function render(d){var box=document.getElementById('stBox');if(!box||!d)return;box.textContent='';
var r=d.last;box.appendChild(el('div','st-s','Speedtest (Ookla)'+(d.running?' · läuft …':'')));
if(!r){box.appendChild(el('div','st-o',d.binary?'noch keine Messung':'speedtest-Programm fehlt'));}
else{var u=UPN[r.uplink]||UPN.unklar;
box.appendChild(line('Down/Up','⬇ '+n(r.down)+' · ⬆ '+n(r.up)+' Mbit/s',1));
box.appendChild(line('Ping','Server '+n(r.ping,0)+' ms · Jitter '+n(r.jitter,1)+' ms'+(r.loss!==null&&r.loss!==undefined?' · Verlust '+n(r.loss,1)+' %':'')));
if(r.dl_lat!=null||r.ul_lat!=null)box.appendChild(line('unter Last','⬇ '+n(r.dl_lat,0)+' · ⬆ '+n(r.ul_lat,0)+' ms'));
var sv=r.server||{};box.appendChild(el('div','st-s',u[0]+' '+u[1]+' · '+(sv.name||'?')+(sv.location?', '+sv.location:'')+(r.server_auto?' (auto)':'')+' · '+(r.at||'').slice(0,16)));
['telekom','starlink'].forEach(function(k){if(k===r.uplink)return;var o=(d.by_uplink||{})[k];var q=UPN[k];
box.appendChild(el('div','st-o',q[0]+' '+q[1]+': '+(o?('⬇ '+n(o.down)+' ⬆ '+n(o.up)+' · '+n(o.ping,0)+' ms · vor '+ago(o.t)):'noch keine Messung')));});}
if(d.last_error&&(!r||d.last_error.t>r.t))box.appendChild(el('div','st-o','letzter Fehler '+(d.last_error.at||'').slice(11,16)+': '+(d.last_error.msg||'').slice(0,80)));
var p=d.ping_888||{};box.appendChild(el('div','st-s','Ping oben = 8.8.8.8 im Leerlauf'+(d.next_at?' · nächste Messung '+d.next_at.slice(11):'')));}
function poll(k){fetch('/api/speedtest').then(function(r){return r.json();}).then(function(d){render(d);if(d.running&&k<50)setTimeout(function(){poll(k+1);},3000);}).catch(function(){});}
function place(){var box=document.getElementById('stBox');if(!box||box.getAttribute('data-st')==='1')return;
var card=null;[].slice.call(document.querySelectorAll('.card')).forEach(function(c){if(card||c.id)return;var t=c.querySelector('.title');if(t&&/Internet/.test(t.textContent))card=c;});
if(card){var row=card.querySelector('.row');if(row&&row.parentNode===card)card.insertBefore(box,row.nextSibling);else card.appendChild(box);
[].slice.call((row||card).children).forEach(function(c){var x=(c.textContent||'').trim();if(x==='Ping')c.textContent='Ping 8.8.8.8';else if(x==='Download')c.textContent='Download (Ookla)';});}
else{var c=el('div','card');c.id='stCard';c.appendChild(el('div','title','🌐 Speedtest'));var src=document.getElementById('srcCard');(src?src.parentNode:document.body).insertBefore(c,src||null);c.appendChild(box);}
box.style.display='';box.setAttribute('data-st','1');
var b=document.getElementById('dlBtn');if(b){b.textContent='↓ Speedtest jetzt (~30 s)';b.addEventListener('click',function(){setTimeout(function(){var s=document.getElementById('dlStatus');if(s)s.textContent='Speedtest läuft … (bis ~60 s)';},30);setTimeout(function(){poll(0);},1500);});}
try{render(JSON.parse(document.getElementById('stData').textContent));}catch(e){}}
document.addEventListener('DOMContentLoaded',place);setTimeout(place,600);
})();
</script>"""


def _st_after(resp):
    try:
        from flask import request as _st_req
        if _st_req.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="st-js"' in body:
            return resp
        data = _st_json.dumps(_st_status(), ensure_ascii=False).replace("</", "<\\/")
        blk = ('<div id="stBox" style="display:none"></div><script type="application/json" id="stData">%s</script>' % data) + _ST_JS
        i = body.find("</head>")
        body = (body[:i] + _ST_CSS + body[i:]) if i >= 0 else (_ST_CSS + body)
        j = body.rfind("</body>")
        body = (body[:j] + blk + body[j:]) if j >= 0 else (body + blk)
        resp.set_data(body)
    except Exception as e:
        print("speedTest /pi:", e, flush=True)
    return resp


app.after_request(_st_after)
if __name__ == "__main__" and _st is not None:
    _st.start()
print("speedTest aktiv: Modul=%s Server=%s letzter=%s" % (_st is not None, (_st.config().get("server_id") if _st else None),
      ((_st.d.get("last") or {}).get("at") if _st else None)), flush=True)
# ===== /speedTest =====

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
    if "st-js" in src:
        raise SystemExit("STOP: st-js gibt es schon - nichts geaendert")
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
cat > "$W/speedtest_run.py" << 'MODPY_EOF'
#!/usr/bin/env python3
"""speedTest: Ookla-Speedtest fuer das Prepper-Dashboard (nur messen, sendet nichts ins Mesh).

- feste Messung alle 3 h (01:41, 04:41, ... 22:41) plus manueller Start
- Server fest aus speedtest_config.json (Flavius Hager Nuernberg), sonst einmal automatische Wahl
- jedes Ergebnis mit Uplink (telekom/starlink/unklar), letzte Werte je Uplink getrennt
- speedtest.json atomar (tmp + fsync + os.replace)
"""
import json
import os
import subprocess
import threading
import time
from datetime import datetime

VERSION = 1
SLOT_HOURS = (1, 4, 7, 10, 13, 16, 19, 22)
SLOT_MIN = 41
MANUAL_GAP_S = 300
RUN_TIMEOUT_S = 120
CATCHUP_AFTER_S = 600
CATCHUP_IF_OLDER_S = 3 * 3600 + 1800
KEEP_RUNS = 60
UPLINKS = ("telekom", "starlink", "unklar")


def _r(x, n=1):
    try:
        return round(float(x), n)
    except Exception:
        return None


def parse_result(stdout):
    """Ookla-JSON (type=result) -> kompaktes Ergebnis; None wenn kein Ergebnis."""
    res = None
    for ln in (stdout or "").splitlines():
        ln = ln.strip()
        if not ln.startswith("{"):
            continue
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if isinstance(d, dict) and d.get("type") == "result":
            res = d
    if not res:
        return None
    dl = res.get("download") or {}
    ul = res.get("upload") or {}
    pg = res.get("ping") or {}
    sv = res.get("server") or {}
    bw = lambda x: _r((x.get("bandwidth") or 0) * 8 / 1e6, 1) if isinstance(x.get("bandwidth"), (int, float)) else None
    lat = lambda x: _r(((x.get("latency") or {}).get("iqm")), 1)
    down, up = bw(dl), bw(ul)
    if down is None or down <= 0:
        return None
    return {
        "down": down, "up": up,
        "ping": _r(pg.get("latency")), "jitter": _r(pg.get("jitter"), 2),
        "ping_low": _r(pg.get("low")), "ping_high": _r(pg.get("high")),
        "dl_lat": lat(dl), "ul_lat": lat(ul),
        "loss": _r(res.get("packetLoss"), 2) if isinstance(res.get("packetLoss"), (int, float)) else None,
        "dl_mb": _r((dl.get("bytes") or 0) / 1e6, 1), "ul_mb": _r((ul.get("bytes") or 0) / 1e6, 1),
        "isp": str(res.get("isp") or "")[:60],
        "server": {"id": sv.get("id"), "name": str(sv.get("name") or "")[:60], "location": str(sv.get("location") or "")[:40]},
        "url": str((res.get("result") or {}).get("url") or "")[:120],
    }


def parse_errors(stderr):
    out = []
    for ln in (stderr or "").splitlines():
        ln = ln.strip()
        try:
            d = json.loads(ln) if ln.startswith("{") else None
        except Exception:
            d = None
        if isinstance(d, dict) and d.get("level") == "error":
            out.append(str(d.get("message") or "")[:160])
        elif ln and not d and ("error" in ln.lower() or "fehler" in ln.lower()):
            out.append(ln[:160])
    return out[-3:]


def next_slot(now=None):
    now = now if now is not None else time.time()
    lt = time.localtime(now)
    best = None
    for dd in (0, 1):
        for h in SLOT_HOURS:
            t = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday + dd, h, SLOT_MIN, 0, 0, 0, -1))
            if t > now + 5 and (best is None or t < best):
                best = t
    return best


class Runner:
    def __init__(self, base, get_uplink=None, on_result=None, binary=None):
        self.base = os.path.realpath(base)
        self.bin = binary or os.path.join(self.base, "tools", "ookla", "speedtest")
        self.cfg_file = os.path.join(self.base, "speedtest_config.json")
        self.out_file = os.path.join(self.base, "speedtest.json")
        self.get_uplink = get_uplink or (lambda: None)
        self.on_result = on_result
        self.lk = threading.RLock()
        self.run_lk = threading.Lock()
        self.done = threading.Condition(self.lk)
        self.running = False
        self.started_at = None
        self.boot = time.time()
        self.thread = None
        self.next_at = None
        self.d = {"version": VERSION, "last": None, "by_uplink": {}, "runs": [], "errors": 0, "last_error": None, "count": 0}
        self._load()

    # ---------- Dateien ----------
    def _load(self):
        try:
            with open(self.out_file, "r", encoding="utf-8") as f:
                d = json.load(f)
            if isinstance(d, dict):
                for k in self.d:
                    if k in d:
                        self.d[k] = d[k]
                if not isinstance(self.d.get("runs"), list):
                    self.d["runs"] = []
                if not isinstance(self.d.get("by_uplink"), dict):
                    self.d["by_uplink"] = {}
        except Exception:
            pass

    def _save(self):
        tmp = "%s.tmp.%d" % (self.out_file, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.d, f, ensure_ascii=False, indent=1)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.out_file)

    def config(self):
        try:
            with open(self.cfg_file, "r", encoding="utf-8") as f:
                c = json.load(f)
            return c if isinstance(c, dict) else {}
        except Exception:
            return {}

    # ---------- Messen ----------
    def uplink(self):
        try:
            u = str(self.get_uplink() or "").lower()
        except Exception:
            u = ""
        return u if u in ("telekom", "starlink") else "unklar"

    def _exec(self, server_id=None):
        args = [self.bin, "--accept-license", "--accept-gdpr", "--format=json", "--progress=no"]
        if server_id:
            args += ["--server-id=%d" % int(server_id)]
        try:
            p = subprocess.run(args, capture_output=True, text=True, timeout=RUN_TIMEOUT_S, cwd=self.base)
        except subprocess.TimeoutExpired:
            return None, ["Zeitlimit %d s" % RUN_TIMEOUT_S]
        except Exception as e:
            return None, [str(e)[:160]]
        r = parse_result(p.stdout)
        if r is None:
            return None, parse_errors(p.stderr) or ["kein Ergebnis (rc=%s)" % p.returncode]
        return r, []

    def _measure(self, manual):
        if not os.access(self.bin, os.X_OK):
            return None, ["speedtest fehlt: %s" % self.bin]
        u0 = self.uplink()
        t0 = time.time()
        sid = self.config().get("server_id")
        r, err = self._exec(sid) if sid else (None, [])
        auto = False
        if r is None:
            r2, err2 = self._exec(None)
            if r2 is not None:
                r, auto = r2, True
            err = err + err2
        u1 = self.uplink()
        if r is None:
            return None, err
        r["uplink"] = u0 if u0 == u1 else "unklar"
        r["server_auto"] = bool(auto or not sid)
        r["t"] = int(t0)
        r["at"] = datetime.fromtimestamp(t0).strftime("%d.%m.%Y %H:%M:%S")
        r["dur_s"] = int(time.time() - t0)
        r["manual"] = bool(manual)
        if err:
            r["note"] = err[-1]
        return r, []

    def run(self, manual=False, wait=None):
        """Startet eine Messung. wait=None: im Aufrufer-Thread; wait=Sekunden: Hintergrund + warten."""
        with self.lk:
            last = self.d.get("last") or {}
            if manual and not self.running and last.get("t") and time.time() - float(last.get("t") or 0) < MANUAL_GAP_S:
                return {"ok": True, "cached": True, "result": last}
            if self.running:
                if wait:
                    self.done.wait(timeout=wait)
                    return {"ok": not self.running and bool(self.d.get("last")), "cached": True, "running": self.running, "result": self.d.get("last")}
                return {"ok": True, "running": True, "result": last or None}
            self.running = True
            self.started_at = time.time()
        if wait is not None:
            th = threading.Thread(target=self._run_inner, args=(manual,), name="speedtest-run", daemon=True)
            th.start()
            with self.lk:
                if self.running:
                    self.done.wait(timeout=wait)
                return {"ok": not self.running and self.d.get("last") is not None and self.d["last"].get("t", 0) >= int(self.started_at or 0),
                        "running": self.running, "result": self.d.get("last"), "error": self.d.get("last_error")}
        self._run_inner(manual)
        return {"ok": True, "result": self.d.get("last")}

    def _run_inner(self, manual):
        rec, err = None, []
        try:
            with self.run_lk:
                rec, err = self._measure(manual)
        except Exception as e:
            err = [str(e)[:160]]
        with self.lk:
            try:
                if rec:
                    self.d["last"] = rec
                    self.d["by_uplink"][rec["uplink"]] = rec
                    self.d["runs"] = (self.d.get("runs") or [])[-(KEEP_RUNS - 1):] + [rec]
                    self.d["count"] = int(self.d.get("count") or 0) + 1
                else:
                    self.d["errors"] = int(self.d.get("errors") or 0) + 1
                    self.d["last_error"] = {"at": datetime.now().strftime("%d.%m.%Y %H:%M:%S"), "t": int(time.time()),
                                            "msg": "; ".join(err)[:300], "uplink": self.uplink()}
                self._save()
            except Exception as e:
                print("speedTest speichern:", e, flush=True)
            self.running = False
            self.done.notify_all()
        if rec:
            print("speedTest: %s down %s up %s ping %s jitter %s (%s, %s)" % (rec["uplink"], rec["down"], rec["up"], rec["ping"], rec["jitter"],
                  rec["server"].get("name"), "auto" if rec["server_auto"] else "fest"), flush=True)
            if self.on_result:
                try:
                    self.on_result(rec)
                except Exception as e:
                    print("speedTest Weitergabe:", e, flush=True)
        else:
            print("speedTest Fehler:", "; ".join(err)[:300], flush=True)

    # ---------- Ablauf ----------
    def status(self):
        with self.lk:
            d = json.loads(json.dumps(self.d))
        d.pop("runs", None)
        d["running"] = self.running
        d["running_s"] = int(time.time() - self.started_at) if self.running and self.started_at else None
        na = self.next_at
        lt = float(((self.d.get("last") or {}).get("t")) or 0)
        if na and time.time() - lt < 1800 and na < (next_slot() or na):
            na = next_slot()
        d["next_at"] = datetime.fromtimestamp(na).strftime("%d.%m.%Y %H:%M") if na else None
        c = self.config()
        d["server_cfg"] = {k: c.get(k) for k in ("server_id", "server_name", "location", "chosen")}
        d["binary"] = os.access(self.bin, os.X_OK)
        d["uplink_now"] = self.uplink()
        d["ok"] = True
        return d

    def runs(self):
        with self.lk:
            return list(self.d.get("runs") or [])

    def _loop(self):
        last = (self.d.get("last") or {}).get("t") or 0
        catch = (time.time() - float(last)) > CATCHUP_IF_OLDER_S
        while True:
            try:
                ns = next_slot()
                if catch:
                    ns = min(ns, self.boot + CATCHUP_AFTER_S)
                    catch = False
                self.next_at = ns
                while time.time() < ns:
                    time.sleep(min(60, max(1, ns - time.time())))
                lt = float((self.d.get("last") or {}).get("t") or 0)
                if time.time() - lt > 1800 and not self.running:
                    self.run(manual=False)
            except Exception as e:
                print("speedTest Ablauf:", e, flush=True)
                time.sleep(300)

    def start(self):
        if self.thread:
            return False
        self.thread = threading.Thread(target=self._loop, name="speedtest-loop", daemon=True)
        self.thread.start()
        return True


def choose_server(server_list_json):
    """Aus speedtest -L -f json: Flavius Hager, sonst Nuernberg, sonst naechster."""
    try:
        d = json.loads(server_list_json)
        sv = [s for s in (d.get("servers") or []) if isinstance(s, dict) and s.get("id")]
    except Exception:
        return None
    if not sv:
        return None
    pick, why = None, None
    for s in sv:
        if "flavius" in str(s.get("name", "")).lower() or "hager" in str(s.get("name", "")).lower():
            pick, why = s, "Flavius Hager"
            break
    if not pick:
        for s in sv:
            if str(s.get("location", "")).lower() in ("nuremberg", "nürnberg", "nuernberg"):
                pick, why = s, "Nuernberg"
                break
    if not pick:
        pick, why = sv[0], "naechster"
    return {"server_id": int(pick["id"]), "server_name": str(pick.get("name", ""))[:60], "location": str(pick.get("location", ""))[:40],
            "host": str(pick.get("host", ""))[:80], "chosen": why, "at": datetime.now().strftime("%d.%m.%Y %H:%M:%S")}


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 3 and sys.argv[1] == "choose":
        c = choose_server(open(sys.argv[2], encoding="utf-8").read())
        if not c:
            print("KEIN_SERVER")
            sys.exit(2)
        out = sys.argv[3]
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(c, f, ensure_ascii=False, indent=1)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, out)
        print("SERVER %d %s, %s (%s)" % (c["server_id"], c["server_name"], c["location"], c["chosen"]))
MODPY_EOF

# ---------- 0) Bytes + AST-Guards ----------
P="$W/patch-speedtest.py"; M="$W/speedtest_run.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $M" | sha256sum -c - >/dev/null || { echo "STOP: Modul sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
"$VPY" -W error::SyntaxWarning -m py_compile "$M" || { echo "STOP: Modul py_compile - nichts geaendert"; exit 1; }
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
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("update_all", "urlopen", "Popen", "system", "remove", "unlink"):
            print("Block: verbotener Aufruf", fn); hit = True
        if fn == "open" and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and any(c in str(node.args[1].value) for c in "wax+"):
            print("Block: Schreib-open"); hit = True
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
        k = node.slice.value if isinstance(node.slice, ast.Constant) else None
        if k not in ("download", "download_at"):
            print("Block: data_store-Schreiben", k); hit = True
mod = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
for node in ast.walk(ast.parse(mod)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in ("requests", "urllib", "socket", "http", "meshtastic"):
                print("Modul: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        f = node.func
        fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if fn.startswith(("send", "maybe_mesh")) or fn in ("Popen", "system", "popen", "call", "check_output", "remove", "unlink", "rmtree"):
            print("Modul: verbotener Aufruf", fn); hit = True
        for kw in node.keywords:
            if kw.arg == "shell":
                print("Modul: shell="); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Mesh, kein requests/socket; Programmstart nur speedtest ohne Shell)"

# ---------- 1) Ookla laden + pruefen (vor jeder Aenderung) ----------
curl -fsSL --connect-timeout 10 --max-time 180 -o "$W/ookla.tgz" "$ST_URL" || { echo "STOP: Download Ookla CLI fehlgeschlagen - nichts geaendert"; exit 1; }
echo "$ST_TGZ_SHA  $W/ookla.tgz" | sha256sum -c - >/dev/null || { echo "STOP: Ookla-Archiv sha256 falsch - nichts geaendert"; exit 1; }
mkdir -p "$W/ookla" && tar -xzf "$W/ookla.tgz" -C "$W/ookla" speedtest speedtest.md || { echo "STOP: Archiv entpacken - nichts geaendert"; exit 1; }
echo "$ST_BIN_SHA  $W/ookla/speedtest" | sha256sum -c - >/dev/null || { echo "STOP: speedtest sha256 falsch - nichts geaendert"; exit 1; }
chmod 755 "$W/ookla/speedtest"
SV=$("$W/ookla/speedtest" --version 2>/dev/null | head -1 || true)
[[ "$SV" == Speedtest* ]] || { echo "STOP: speedtest startet nicht ($SV) - nichts geaendert"; exit 1; }
echo "OK $SV (Archiv + Programm sha256 geprueft)"
timeout 60 "$W/ookla/speedtest" --accept-license --accept-gdpr --servers --format=json > "$W/servers.json" 2> "$W/servers.err" || true
if python3 "$M" choose "$W/servers.json" "$W/speedtest_config.json"; then :; else echo "WARN Serverliste leer - Messung waehlt Server automatisch"; rm -f "$W/speedtest_config.json"; fi

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
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /pi /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /energie=${PRE[/energie]}"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l)

same_bin=0; cmp -s "$W/ookla/speedtest" "$ST_DIR/speedtest" 2>/dev/null && same_bin=1
same_mod=0; cmp -s "$M" "$DASH_DIR/speedtest_run.py" 2>/dev/null && same_mod=1
if cmp -s "$W/work/dashboard.py" "$F" && [[ "$same_bin" == 1 && "$same_mod" == 1 ]]; then
  echo "OK speedTest schon installiert - kein Neustart"
else
  sudo -v
  NEW_DIR=0; [[ -d "$ST_DIR" ]] || NEW_DIR=1
  NEW_MOD=0; [[ -f "$DASH_DIR/speedtest_run.py" ]] || NEW_MOD=1
  NEW_CFG=0; [[ -f "$DASH_DIR/speedtest_config.json" ]] || NEW_CFG=1
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-speedtest-$TS" "$F"
    if [[ "$NEW_MOD" == 1 ]]; then rm -f "$DASH_DIR/speedtest_run.py"; elif [[ -f "$DASH_DIR/speedtest_run.py.bak-speedtest-$TS" ]]; then cp -a "$DASH_DIR/speedtest_run.py.bak-speedtest-$TS" "$DASH_DIR/speedtest_run.py"; fi
    [[ "$NEW_DIR" == 1 ]] && rm -rf "$ST_DIR"
    [[ "$NEW_CFG" == 1 ]] && rm -f "$DASH_DIR/speedtest_config.json"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-speedtest-$TS"
  }
  cp -a "$F" "$F.bak-speedtest-$TS"
  [[ "$NEW_MOD" == 0 && "$same_mod" == 0 ]] && cp -a "$DASH_DIR/speedtest_run.py" "$DASH_DIR/speedtest_run.py.bak-speedtest-$TS"
  mkdir -p "$ST_DIR"
  install -m 755 "$W/ookla/speedtest" "$ST_DIR/speedtest.new" && mv -f "$ST_DIR/speedtest.new" "$ST_DIR/speedtest" || { rb "speedtest installieren"; exit 1; }
  cp "$W/ookla/speedtest.md" "$ST_DIR/" 2>/dev/null || true
  install -m 644 "$M" "$DASH_DIR/speedtest_run.py.new" && mv -f "$DASH_DIR/speedtest_run.py.new" "$DASH_DIR/speedtest_run.py" || { rb "Modul installieren"; exit 1; }
  if [[ -f "$W/speedtest_config.json" ]]; then
    if [[ "$NEW_CFG" == 1 ]]; then cp "$W/speedtest_config.json" "$DASH_DIR/speedtest_config.json"; echo "Server-Konfiguration neu angelegt"; else echo "Server-Konfiguration vorhanden - unveraendert"; fi
  fi
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
  sc=$("${CURL[@]}" "$B/api/speedtest" -o "$W/st0.json" -w "%{http_code}" || true)
  [[ "$sc" == "200" ]] || { rb "/api/speedtest antwortet nicht ($sc)"; exit 1; }
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d.get('ok') and d.get('binary'), d" "$W/st0.json" || { rb "/api/speedtest ungueltig"; exit 1; }
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    grep -q 'id=.st-js' "$W/pi.html" && grep -q 'id=.stBox' "$W/pi.html" || { rb "/pi ohne Speedtest-Anzeige"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l)
    [[ "$R1" == "$R0" ]] || { rb "/pi Sicherung veraendert"; exit 1; }
    echo "OK /pi mit Speedtest-Anzeige (Sicherung unveraendert, doPrepperRestore $R1)"
  fi
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'speedTest' | tail -3 || true
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-speedtest-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi

# ---------- 3) erste Messung (~30 s, laedt ~100-200 MB) ----------
echo "Erste Messung laeuft (bis ~150 s) ..."
curl -s --max-time 170 -X POST "$B/api/speedtest?wait=1" -o "$W/st1.json" || true
python3 - "$W/st1.json" << 'PY' || echo "WARN Messung nicht auswertbar - Patch bleibt, naechster Versuch per Zeitplan"
import json, sys
d = json.load(open(sys.argv[1]))
r = d.get("last") or {}
e = d.get("last_error") or {}
if r and (not e or (e.get("t") or 0) <= (r.get("t") or 0)):
    s = r.get("server") or {}
    f = lambda x, n=1: ("%.*f" % (n, x)).replace(".", ",") if isinstance(x, (int, float)) else "-"
    print("MESSUNG %s: down %s up %s Mbit/s, ping %s ms, jitter %s ms, Last down/up %s/%s ms, Verlust %s %%" % (
        r.get("uplink"), f(r.get("down")), f(r.get("up")), f(r.get("ping")), f(r.get("jitter"), 2), f(r.get("dl_lat"), 0), f(r.get("ul_lat"), 0), f(r.get("loss"))))
    print("SERVER %s %s, %s%s · %s s · %s / %s MB" % (s.get("id"), s.get("name"), s.get("location"), " (auto)" if r.get("server_auto") else " (fest)",
          r.get("dur_s"), r.get("dl_mb"), r.get("ul_mb")))
else:
    print("WARN Messung fehlgeschlagen:", e.get("msg") or d.get("run"))
PY
dt=$("${CURL[@]}" --max-time 20 "$B/api/download_test" || true)
echo "download_test (Kachel-Knopf, jetzt Ookla, innerhalb 5 min aus Speicher): $(echo "$dt" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok=%s mbps=%s at=%s cached=%s' % (d.get('ok'), d.get('mbps'), d.get('at'), d.get('cached')))" 2>/dev/null || echo unlesbar)"
echo "OK guards speedTest=$(grep -q '# ===== speedTest:' "$F" && echo 1 || echo 0) piPolish2=$(grep -q '# ===== piPolish2:' "$F" && echo 1 || echo 0) piPolish=$(grep -q '# ===== piPolish:' "$F" && echo 1 || echo 0) sdHealth=$(grep -q '# ===== sdHealth:' "$F" && echo 1 || echo 0) sourceWatch=$(grep -q '# ===== sourceWatch:' "$F" && echo 1 || echo 0) longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-speedtest-$TS" ]] && echo "Backup: $F.bak-speedtest-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG speedTest=1"
