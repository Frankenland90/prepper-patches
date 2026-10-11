#!/bin/bash
set -euo pipefail
# piPolish: einheitliche kompakte Karten auf /pi, Sicherung zuletzt (JS), DWD/WBI-Quellen per Suche. Nur Anzeige.
# Nur bei dashboard.py sha16 50ece2fb3d7b8c3e. Sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/pipolish
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== piPolish apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="574f64d8c8069d38609f1c16196b372aedbee005db59a70ecf62a0e73dbff8b5"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-pi-polish.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""piPolish: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== piPolish:"
EXPECT = "50ece2fb3d7b8c3e"
NEED = ["# ===== sdHealth:", "# ===== sourceWatch:", "# ===== longArchive:", "def _sw_card", "def _sdh_card", "def sw_sources", "SW_SOURCES", "def _sw_parse", "def _sw_fmt_age"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== piPolish: einheitliche, kompakte Karten auf /pi, Sicherung zuletzt, DWD/WBI-Quellen gefunden (nur Anzeige) =====
import sys as _pp_sys
import os as _pp_os
import json as _pp_json
import re as _pp_re
import time as _pp_time

_PP_SHORT = {"Netzfrequenz": "Frequenz", "Internet/Ping": "Internet", "DWD-Warnungen": "DWD", "Stromausfälle": "Stromausf.",
             "Waldbrand-Index": "WBI", "Weltraumwetter": "Space", "Metalle/Krypto": "Metalle", "Gasspeicher": "Gas",
             "Strompreis": "Strom", "Netzlast": "Last", "Strommix": "Mix", "SD-Karte": "SD-Karte"}
_PP_COL = {"ok": "#22c55e", "alt": "#eab308", "ausgefallen": "#ef4444", "unbekannt": "#64748b"}
_PP_CAND = {
    "dwd": (["dwd", "dwd_warn", "dwd_warnungen", "warnungen", "dwd_warnings", "unwetter"], _pp_re.compile(r"dwd|unwetter|warnung", _pp_re.I), _pp_re.compile(r"wbi|mesh|status|wald", _pp_re.I)),
    "wbi": (["wbi", "dwd_wbi", "waldbrand", "waldbrandindex", "wbi_dwd"], _pp_re.compile(r"wbi|waldbrand", _pp_re.I), _pp_re.compile(r"mesh|status|history", _pp_re.I)),
}
_pp_disc = {}
_pp_orig = {}
_pp_kl = {"m": None, "d": None}
_PP_KL_FILE = _pp_os.path.join(_pp_os.path.dirname(_pp_os.path.abspath(__file__)), "keep-last.json")


def _pp_age(a):
    if a is None:
        return "–"
    a = max(0, int(a))
    if a < 90:
        return "%ds" % a
    if a < 3600:
        return "%dm" % (a // 60)
    if a < 48 * 3600:
        return "%dh" % (a // 3600)
    return "%dT" % (a // 86400)


def _pp_esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _pp_keeplast():
    try:
        m = _pp_os.path.getmtime(_PP_KL_FILE)
        if _pp_kl["m"] != m:
            with open(_PP_KL_FILE, "r", encoding="utf-8") as f:
                _pp_kl["d"] = _pp_json.load(f)
            _pp_kl["m"] = m
        return _pp_kl["d"] if isinstance(_pp_kl["d"], dict) else {}
    except Exception:
        return {}


def _pp_tfield(o):
    if not isinstance(o, dict):
        return None, None
    for f in ("updated", "at", "ts", "_keepLastTs", "fetched", "time", "updated_at"):
        t = _sw_parse(o.get(f))
        if t:
            return t, f
    for sub in ("payload", "slot", "data"):
        if isinstance(o.get(sub), dict):
            t, f = _pp_tfield(o[sub])
            if t:
                return t, sub + "." + f
    return None, None


def _pp_discover(ds):
    """Sucht den data_store-Schluessel fuer DWD/WBI. Ergebnis wird gemerkt und bei Aenderung geloggt."""
    res = {}
    for key, (cands, rx, excl) in _PP_CAND.items():
        found = None
        for c in cands:
            if c in ds and ds.get(c) is not None:
                found = ("data_store", c)
                break
        if not found:
            for k in sorted(ds.keys(), key=str):
                if rx.search(str(k)) and not excl.search(str(k)) and isinstance(ds.get(k), dict):
                    found = ("data_store", str(k))
                    break
        if not found:
            kl = _pp_keeplast()
            for c in cands + [k for k in kl if rx.search(str(k)) and not excl.search(str(k))]:
                if c in kl and _pp_tfield(kl[c])[0]:
                    found = ("keep-last.json", c)
                    break
        if not found:
            g = globals()
            for n in sorted(g.keys()):
                if n.startswith("_pp_") or not rx.search(n) or excl.search(n):
                    continue
                if isinstance(g[n], dict) and _pp_tfield(g[n])[0]:
                    found = ("global", n)
                    break
        if not found and key == "wbi":
            if globals().get("wbi_history"):
                found = ("deque", "wbi_history")
        res[key] = found
        if _pp_disc.get(key) != found:
            print("piPolish: Quelle %s -> %s" % (key, ("%s:%s" % found) if found else "nicht gefunden"), flush=True)
    _pp_disc.update(res)
    return res


def _pp_state(age, thr, fails, val_none=False):
    if age is None:
        return "unbekannt", "kein Zeitstempel"
    if age > 2 * thr:
        return "ausgefallen", "älter als 2× Schwelle"
    if age > thr:
        return "alt", "älter als Schwelle"
    if fails > 0:
        return "alt", "letzter Abruf fehlgeschlagen (%dx), Wert gehalten" % fails
    if val_none:
        return "alt", "kein Wert"
    return "ok", ""


if callable(globals().get("sw_sources")):
    _pp_orig_sw_sources = sw_sources

    def sw_sources():
        ds = globals().get("data_store") or {}
        disc = {}
        try:
            disc = _pp_discover(ds)
            for i, ent in enumerate(list(SW_SOURCES)):
                if ent[0] in ("dwd", "wbi") and ("_orig_" + ent[0]) not in _pp_orig:
                    _pp_orig["_orig_" + ent[0]] = (i, ent)
            for k in ("dwd", "wbi"):
                o = _pp_orig.get("_orig_" + k)
                f = disc.get(k)
                if o:
                    i, ent = o
                    SW_SOURCES[i] = ((f[1],) + tuple(ent[1:])) if (f and f[0] == "data_store") else ent
        except Exception as e:
            print("piPolish discover:", e, flush=True)
        d = _pp_orig_sw_sources()
        try:
            fc = globals().get("fail_counters") or {}
            now = _pp_time.time()
            for r in d.get("sources") or []:
                k = "dwd" if r.get("name") == "DWD-Warnungen" else ("wbi" if r.get("name") == "Waldbrand-Index" else None)
                if not k:
                    continue
                f = disc.get(k)
                r["data_key"] = ("%s:%s" % f) if f else None
                if r.get("state") != "unbekannt" or not f or f[0] == "data_store":
                    continue
                t = src = None
                if f[0] == "keep-last.json":
                    t, src = _pp_tfield(_pp_keeplast().get(f[1]))
                elif f[0] == "global":
                    t, src = _pp_tfield(globals().get(f[1]))
                elif f[0] == "deque":
                    dq = list(globals().get(f[1]) or [])
                    t = _sw_parse(dq[-1].get("t")) if dq and isinstance(dq[-1], dict) else None
                    src = "t"
                if not t:
                    continue
                age = now - t
                fk = "dwd_warn" if k == "dwd" else "dwd_wbi"
                fails = int(fc.get(fk) or 0)
                old = r["state"]
                r["state"], r["why"] = _pp_state(age, r["threshold_s"], fails)
                r["age_s"], r["age_txt"], r["fails"] = int(age), _sw_fmt_age(age), fails
                r["time_source"] = "%s:%s.%s" % (f[0], f[1], src)
                d["counts"][old] = max(0, d["counts"].get(old, 1) - 1)
                d["counts"][r["state"]] = d["counts"].get(r["state"], 0) + 1
                if r["important"] and r["state"] == "ausgefallen" and r["name"] not in d["important_down"]:
                    d["important_down"].append(r["name"])
            d["discovery"] = {k: (("%s:%s" % v) if v else None) for k, v in disc.items()}
        except Exception as e:
            print("piPolish sources:", e, flush=True)
        return d


def _pp_rowhtml(name, val, state, tip="", extra=""):
    c = _PP_COL.get(state, "#64748b")
    return ('<div class="pp-row" title="%s"><span class="pp-dot" style="background:%s"></span>'
            '<span class="pp-name">%s</span><span class="pp-val">%s</span>%s</div>'
            % (_pp_esc(tip), c, _pp_esc(name), _pp_esc(val), extra))


def _sw_card(d):
    rows = []
    for r in d["sources"]:
        st = r["state"]
        nm = _PP_SHORT.get(r["name"], r["name"])
        tip = "%s: %s · Alter %s · Schwelle %s%s" % (r["name"], st, r["age_txt"], r["threshold_txt"], (" · " + r["why"]) if r.get("why") else "")
        extra = "" if st == "ok" else '<span class="pp-sub">&gt;%s</span>' % _pp_esc(_pp_age(r["threshold_s"]))
        rows.append(_pp_rowhtml(nm, _pp_age(r["age_s"]) if r.get("age_s") is not None else "–", st, tip, extra))
    c = d["counts"]
    p = d.get("ping24")
    pl = ("Ping 24h %s/%s/%s ms" % (p["min"], p["avg"], p["max"])).replace(".", ",") if p else "Ping 24h –"
    if p and "offline_pct" in p:
        pl += (" · offline %s %%" % p["offline_pct"]).replace(".", ",")
    return ('<div class="card src-card pp-card" id="srcCard"><div class="title">📡 Datenquellen '
            '<span class="pp-sub">%d ok · %d alt · %d aus · %s</span></div><div class="pp-grid">%s</div>'
            '<div class="pp-foot">%s · alt = gehalten/überfällig · aus = &gt;2× Schwelle</div></div>'
            % (c.get("ok", 0), c.get("alt", 0), c.get("ausgefallen", 0), d["at"][11:16], "".join(rows), _pp_esc(pl)))


def _pp_kv(k, v, tip=""):
    return '<div class="pp-kv" title="%s"><span>%s</span><span class="pp-val">%s</span></div>' % (_pp_esc(tip or ("%s %s" % (k, v))), _pp_esc(k), _pp_esc(v))


def _sdh_card(v):
    lvl = v.get("level")
    st = {"green": "ok", "yellow": "alt", "red": "ausgefallen"}.get(lvl, "unbekannt")
    txt = {"green": "gesund", "yellow": "beobachten", "red": "Fehler – Backup prüfen!"}.get(lvl, "?")
    c = v.get("card") or {}
    t2 = v.get("tune2fs") or {}
    f = lambda x, n=1: ("%.*f" % (n, x)).replace(".", ",") if isinstance(x, (int, float)) else "–"
    mon = c.get("months")
    rows = [
        _pp_kv("Karte", "%s %s · %s%s" % (v.get("maker", "?"), c.get("name") or "?", c.get("date") or "?", (" (~%d Mon.)" % mon) if isinstance(mon, int) else "")),
        _pp_kv("Geschrieben", "%s TB · %s GB/Tag" % (f(v.get("written_tb"), 2), f(v.get("gb_day"))), "GB/Tag aus %s" % (v.get("gb_day_src") or "–")),
        _pp_kv("Fehler 24h", "Kernel %s · Warn %s · ext4 %s" % (v.get("errors_24h", "–"), v.get("warn_24h", "–"), (v.get("ext4") or {}).get("errors_count") or "–")),
        _pp_kv("Schreibprobe", ("ok" if v.get("probe_ok") else ("FEHLER" if v.get("probe_ok") is False else "–")) + (" · nur lesbar!" if (v.get("root") or {}).get("ro") else "")),
        _pp_kv("ext4", "%s · Mounts %s" % (t2.get("Errors behavior") or "–", t2.get("Mount count") or "–"), "Errors behavior / Mount count"),
    ]
    rs = "".join('<div class="pp-warn">%s</div>' % _pp_esc(r) for r in (v.get("reasons") or []))
    age = v.get("age_s")
    return ('<div class="card sd-card pp-card" id="sdCard"><div class="title">💾 SD-Karte '
            '<span class="pp-dot" style="background:%s;display:inline-block;vertical-align:middle"></span> '
            '<span class="pp-sub">%s</span></div>%s%s<div class="pp-foot">%s · Stand %s (%s)</div></div>'
            % (_PP_COL.get(st), _pp_esc(txt), "".join(rows), rs, _pp_esc(v.get("wear") or "Verschleiss nicht auslesbar (Consumer-SD)"),
               _pp_esc((v.get("at") or "–")[11:16]), _pp_age(age) if isinstance(age, int) else "–"))


def _pp_arch_card(a):
    m = _pp_sys.modules.get("archive_store")
    s = a.status()
    est = s.get("estimate") or {}
    yrs = est.get("years_until_guard")
    if isinstance(yrs, (int, float)):
        yl = ">100 Jahre" if yrs > 100 else ("~%s Jahre" % (("%d" % yrs) if yrs >= 10 else ("%.1f" % yrs).replace(".", ",")))
        mb = (est.get("bytes_year_after_90d") or 0) / 1024.0 ** 2
        yl += (" (~%s MB/Jahr)" % ("%.1f" % mb).replace(".", ","))
    else:
        yl = "Schätzung nach 2 h"
    fb = m._fmt_b if m else (lambda n: str(n))
    ev = sum((s.get("events") or {}).values())
    paused = s.get("paused")
    rows = [
        _pp_kv("Reihen", "%d · %s Punkte" % (s.get("series", 0), "{:,}".format(s.get("points", 0)).replace(",", "."))),
        _pp_kv("Ereignisse", "%d" % ev),
        _pp_kv("Größe", "%s · frei %s" % (fb(s.get("bytes")), fb(s.get("free_bytes")))),
        _pp_kv("Reicht für", yl),
    ]
    return ('<div class="card arch-card pp-card" id="archCard"><div class="title">🗄️ Archiv '
            '<span class="pp-dot" style="background:%s;display:inline-block;vertical-align:middle"></span> '
            '<span class="pp-sub">%s</span></div>%s<div class="pp-foot">Rohdaten %d Tage, danach Tageswerte</div></div>'
            % ("#ef4444" if paused else "#22c55e", "pausiert (unter 5 GB frei)" if paused else "ok", "".join(rows), s.get("raw_days", 90)))


try:
    _pp_am = _pp_sys.modules.get("archive_store")
    if _pp_am is not None and hasattr(_pp_am, "pi_card_html"):
        _pp_am.pi_card_html = _pp_arch_card
except Exception as _pp_e:
    print("piPolish Archiv-Karte:", _pp_e, flush=True)

_PP_CSS = """<style id="pp-style">
.card .title,.card>h2,.card>h3{font-size:15px;font-weight:600;line-height:1.3;margin:0 0 6px}
.card .small,.card small{font-size:12px}
.pp-card{font-size:13px;line-height:1.45}
.pp-sub{font-size:12px;font-weight:400;opacity:.65;margin-left:4px;white-space:nowrap}
.pp-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:0 14px}
.pp-row,.pp-kv{display:flex;align-items:center;gap:6px;white-space:nowrap;overflow:hidden;min-width:0}
.pp-kv{justify-content:space-between}
.pp-kv>span:first-child{opacity:.7}
.pp-name{flex:1;overflow:hidden;text-overflow:ellipsis}
.pp-val{font-variant-numeric:tabular-nums;overflow:hidden;text-overflow:ellipsis}
.pp-row .pp-sub{margin-left:0}
.pp-dot{width:8px;height:8px;border-radius:50%;flex:none}
.pp-foot{font-size:11px;opacity:.6;margin-top:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pp-warn{font-size:12px;color:#ef4444;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
</style>"""

_PP_JS = """<script id="pp-js">
document.addEventListener('DOMContentLoaded',function(){try{
var ours=['srcCard','sdCard','archCard'];
var cards=Array.prototype.slice.call(document.querySelectorAll('.card'));
var host=null;
for(var i=0;i<cards.length;i++){if(ours.indexOf(cards[i].id)<0&&!cards[i].parentNode.closest('.card')){host=cards[i].parentNode;break;}}
if(host){ours.forEach(function(id){var e=document.getElementById(id);if(e&&e.parentNode!==host){host.appendChild(e);}});}
var sich=null;
cards=Array.prototype.slice.call(document.querySelectorAll('.card'));
for(var j=0;j<cards.length;j++){var c=cards[j];if(ours.indexOf(c.id)>=0||c.parentNode.closest('.card'))continue;
var h=c.querySelector('.title,h1,h2,h3,h4,strong,b');var t=((h?h.textContent:c.textContent)||'').slice(0,80);
if(/Sicherung/i.test(t)){sich=c;}}
if(sich){var all=Array.prototype.slice.call(document.querySelectorAll('.card')).filter(function(x){return !x.parentNode.closest('.card');});
var last=all[all.length-1];if(last&&last!==sich&&!sich.contains(last)){last.parentNode.insertBefore(sich,last.nextSibling);}
document.body.setAttribute('data-pp-sicherung','zuletzt');}else{document.body.setAttribute('data-pp-sicherung','nicht gefunden');}
}catch(e){}});
</script>"""


def _pp_after(resp):
    try:
        from flask import request as _pp_req
        if _pp_req.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="pp-style"' in body:
            return resp
        i = body.find("</head>")
        body = (body[:i] + _PP_CSS + body[i:]) if i >= 0 else (_PP_CSS + body)
        j = body.rfind("</body>")
        if j >= 0:
            body = body[:j] + _PP_JS + body[j:]
        resp.set_data(body)
    except Exception as e:
        print("piPolish /pi:", e, flush=True)
    return resp


app.after_request(_pp_after)
print("piPolish aktiv", flush=True)
# ===== /piPolish =====

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
    if "pp-style" in src:
        raise SystemExit("STOP: pp-style gibt es schon - nichts geaendert")
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
P="$W/patch-pi-polish.py"
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

if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK piPolish schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-pipolish-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-pipolish-$TS"
  }
  cp -a "$F" "$F.bak-pipolish-$TS"
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
  ok=0
  for i in $(seq 1 20); do
    "${CURL[@]}" "$B/api/sources" -o "$W/src.json" || true
    if python3 - "$W/src.json" << 'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("ok") is True and len(d.get("sources") or []) >= 15 else 1)
PY
    then ok=1; break; fi
    sleep 3
  done
  [[ "$ok" -eq 1 ]] || { head -c 300 "$W/src.json" 2>/dev/null; echo; rb "/api/sources antwortet nicht"; exit 1; }
  python3 - "$W/src.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
c = d["counts"]
print("Quellen: %d ok, %d alt, %d ausgefallen, %d unbekannt" % (c.get("ok", 0), c.get("alt", 0), c.get("ausgefallen", 0), c.get("unbekannt", 0)))
print("Suche:", ", ".join("%s -> %s" % kv for kv in sorted((d.get("discovery") or {}).items())))
for r in d["sources"]:
    if r["name"] in ("DWD-Warnungen", "Waldbrand-Index") or r["state"] != "ok":
        print("  %-16s %-11s %6s (Schwelle %s, Zeit aus %s, Schluessel %s) %s" % (r["name"][:16], r["state"], r["age_txt"], r["threshold_txt"], r.get("time_source") or "-", r.get("data_key") or r["key"], r["why"][:40]))
print("Banner:", ", ".join(d["important_down"]) or "keins")
PY
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    grep -q 'id=.pp-style' "$W/pi.html" || { rb "/pi ohne piPolish-Stil"; exit 1; }
    k=""; for m in pp-js src-card sd-card arch-card pp-grid; do grep -q "$m" "$W/pi.html" && k="$k $m=ja" || k="$k $m=NEIN"; done
    echo "OK /pi: Stil eingefuegt;$k"
    if grep -q 'Sicherung' "$W/pi.html"; then echo "OK Karte Sicherung gefunden - wird im Browser ans Ende gesetzt"; else echo "Hinweis: kein Text Sicherung auf /pi gefunden - Reihenfolge bleibt"; fi
    echo "Karten auf /pi (Server-Reihenfolge): $(grep -o -E 'class=.card' "$W/pi.html" | wc -l)"
  fi
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a 'piPolish' | tail -4 || true
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-pipolish-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "OK guards piPolish=$(grep -q '# ===== piPolish:' "$F" && echo 1 || echo 0) sdHealth=$(grep -q '# ===== sdHealth:' "$F" && echo 1 || echo 0) sourceWatch=$(grep -q '# ===== sourceWatch:' "$F" && echo 1 || echo 0) firmsKeep=$(grep -q '# ===== firmsKeep:' "$F" && echo 1 || echo 0) longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) priceAllTime=$(grep -q '# ===== priceAllTime:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-pipolish-$TS" ]] && echo "Backup: $F.bak-pipolish-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG piPolish=1"
