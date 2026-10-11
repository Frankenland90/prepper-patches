#!/bin/bash
set -euo pipefail
# sourceWatch: Datenquellen-Karte + Ausfall-Banner auf /pi, /api/sources (nur lesen), Mesh-Ping-Zaehler live.
# Nur bei dashboard.py sha16 1bc1dbf2441a1e39. Nur Anzeige, sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sourcewatch
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sourceWatch apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="b107bfaa4acd27394af96505a20c812f6eee7ca2efc2ea3b2b9bbc7683491a6d"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-source-watch.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""sourceWatch: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== sourceWatch:"
EXPECT = "1bc1dbf2441a1e39"
NEED = ["# ===== longArchive:", "# ===== firmsKeep:", "def load_ping_stats", "fail_counters", "def update_fail_counter", "def now_str"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== sourceWatch: Datenquellen-Waechter (nur Anzeige: /pi-Karte + Banner, /api/sources; keine Sendungen) =====
# Alter = jetzt - data_store[k]["updated"] (keepLast behaelt die Zeit der echten Lieferung), kombiniert mit fail_counters.
# OK: frisch und letzter Abruf ok | alt: gehaltener Wert (Abruf fehlgeschlagen) oder aelter als Schwelle | ausgefallen: > 2x Schwelle.
# Dazu: load_ping_stats liefert die Mesh-Ping-Zaehler live aus den Bridge-Inboxen statt der veralteten ping_stats.json.
import threading as _sw_th
import time as _sw_time
import json as _sw_json
import hashlib as _sw_hash
from datetime import datetime as _sw_dt, timedelta as _sw_td

# Schluessel, Name, Schwelle (s), fail_counters-Schluessel, wichtig (Banner)
SW_SOURCES = [
    ("frequenz", "Netzfrequenz", 300, None, True),
    ("internet", "Internet/Ping", 600, None, True),
    ("pegel", "Pegel", 3 * 3600, "pegel", True),
    ("nina", "NINA", 3600, "nina", True),
    ("dwd", "DWD-Warnungen", 3600, "dwd_warn", True),
    ("stromausfall", "Stromausfälle", 3600, "stromausfall", True),
    ("wetter", "Wetter", 6 * 3600, "wetter", True),
    ("adsb", "ADS-B", 1800, None, False),
    ("kraftstoff", "Diesel", 24 * 3600, "kraftstoff", False),
    ("rohoel", "Brent", 3 * 86400, "rohoel", False),
    ("strom", "Strompreis", 24 * 3600, "strom", False),
    ("load", "Netzlast", 2 * 3600, "load", False),
    ("mix", "Strommix", 2 * 3600, "mix", False),
    ("gas", "Gasspeicher", 2 * 86400, "gas", False),
    ("lng", "LNG", 2 * 86400, "lng", False),
    ("luft", "Luft", 6 * 3600, "luft", False),
    ("odl", "ODL", 6 * 3600, "odl", False),
    ("wbi", "Waldbrand-Index", 24 * 3600, "dwd_wbi", False),
    ("spaceweather", "Weltraumwetter", 6 * 3600, "spaceweather", False),
    ("metalle", "Metalle/Krypto", 3 * 86400, "metalle", False),
]
_SW_FMTS = ("%d.%m.%Y %H:%M:%S", "%d.%m.%Y %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S")
_sw_chg = {}
_sw_lk = _sw_th.Lock()
_sw_started = {"t": _sw_time.time(), "thread": False}


def _sw_parse(s):
    if isinstance(s, (int, float)) and not isinstance(s, bool):
        return float(s) / 1000.0 if s > 1e12 else (float(s) if s > 1e9 else None)
    if isinstance(s, _sw_dt):
        return s.timestamp()
    if not isinstance(s, str):
        return None
    s = s.strip()
    for f in _SW_FMTS:
        try:
            return _sw_dt.strptime(s[:19], f).timestamp()
        except Exception:
            pass
    try:
        hh, mm = s[:5].split(":")
        t = _sw_dt.now().replace(hour=int(hh), minute=int(mm), second=0, microsecond=0)
        if t > _sw_dt.now() + _sw_td(minutes=5):
            t -= _sw_td(days=1)
        return t.timestamp()
    except Exception:
        return None


def _sw_sig(v):
    try:
        return _sw_hash.sha1(_sw_json.dumps(v, sort_keys=True, default=str).encode()).hexdigest()[:12]
    except Exception:
        return None


def _sw_track():
    """Merkt sich, wann sich ein Wert zuletzt geaendert hat (nur fuer Quellen ohne Zeitstempel)."""
    ds = globals().get("data_store") or {}
    now = _sw_time.time()
    with _sw_lk:
        for key, *_ in SW_SOURCES:
            slot = ds.get(key)
            val = slot.get("value") if isinstance(slot, dict) and "value" in slot else slot
            if val is None:
                continue
            sg = _sw_sig(val)
            old = _sw_chg.get(key)
            if old is None or old[0] != sg:
                _sw_chg[key] = (sg, now)


def _sw_loop():
    while True:
        try:
            _sw_track()
        except Exception as e:
            print("sourceWatch track:", e, flush=True)
        _sw_time.sleep(60)


def _sw_deque_age(name):
    try:
        dq = globals().get(name)
        if dq:
            last = list(dq)[-1]
            t = _sw_parse(last.get("t") if isinstance(last, dict) else None)
            return (_sw_time.time() - t) if t else None
    except Exception:
        return None
    return None


def _sw_fmt_age(a):
    if a is None:
        return "–"
    a = max(0, int(a))
    if a < 120:
        return "%d s" % a
    if a < 7200:
        return "%d min" % (a // 60)
    if a < 3 * 86400:
        return ("%.1f h" % (a / 3600.0)).replace(".", ",")
    return ("%.1f Tage" % (a / 86400.0)).replace(".", ",")


def _sw_ping24():
    """Internet-Ping der letzten 24 h: aus Archiv (15-min-Werte) + ping_history (aktuell)."""
    vals, online = [], []
    try:
        a = globals().get("_arch")
        if a is not None:
            for ser in ("ping_hist", "ping"):
                d = a.series_points(ser, 1) or {}
                for p in d.get("raw") or []:
                    v = (p.get("v") or {}).get("v")
                    if isinstance(v, (int, float)):
                        vals.append(float(v))
                if vals:
                    break
            d = a.series_points("internet", 1) or {}
            for p in d.get("raw") or []:
                o = (p.get("v") or {}).get("online")
                if isinstance(o, (int, float)):
                    online.append(float(o))
    except Exception:
        pass
    try:
        for p in ([] if vals else list(globals().get("ping_history") or [])[-80:]):
            v = p.get("v") if isinstance(p, dict) else None
            if isinstance(v, (int, float)):
                vals.append(float(v))
    except Exception:
        pass
    if not vals:
        return None
    out = {"min": round(min(vals), 1), "avg": round(sum(vals) / len(vals), 1), "max": round(max(vals), 1), "n": len(vals)}
    if online:
        out["offline_pct"] = round(100.0 * (1 - sum(online) / len(online)), 1)
    return out


def sw_sources():
    ds = globals().get("data_store") or {}
    fc = globals().get("fail_counters") or {}
    now = _sw_time.time()
    rows = []
    for key, name, thr, fkey, imp in SW_SOURCES:
        slot = ds.get(key)
        has_slot = key in ds
        val = slot.get("value") if isinstance(slot, dict) and "value" in slot else slot
        t = None
        src = None
        if isinstance(slot, dict):
            for f in ("updated", "ts", "at", "time", "updated_at"):
                t = _sw_parse(slot.get(f))
                if t:
                    src = f
                    break
        age = (now - t) if t else None
        if key == "internet":
            pa = _sw_deque_age("ping_history")
            if pa is not None and (age is None or pa < age):
                age, src = pa, "ping_history"
        if key == "frequenz" and age is None:
            fa = _sw_deque_age("freq_history")
            if fa is not None:
                age, src = fa, "freq_history"
        if age is None:
            with _sw_lk:
                ch = _sw_chg.get(key)
            if ch:
                age, src = now - ch[1], "wertaenderung"
        fails = int(fc.get(fkey) or 0) if fkey else 0
        empty = val is None or (key == "internet" and isinstance(slot, dict) and slot.get("value") is False)
        if not has_slot:
            state, why = "unbekannt", "fehlt im Datenstand"
        elif age is None:
            up = now - _sw_started["t"]
            state = "ausgefallen" if (val is None and up > 900) else "unbekannt"
            why = "kein Wert" if val is None else "kein Zeitstempel (Wertänderung wird beobachtet)"
        elif key == "internet" and empty:
            state, why = "ausgefallen", "offline"
        elif age > 2 * thr:
            state, why = "ausgefallen", "älter als 2× Schwelle"
        elif age > thr:
            state, why = "alt", "älter als Schwelle"
        elif fails > 0:
            state, why = "alt", "letzter Abruf fehlgeschlagen (%dx), Wert gehalten" % fails
        elif empty:
            state, why = "alt", "kein Wert"
        else:
            state, why = "ok", ""
        rows.append({"key": key, "name": name, "state": state, "age_s": (int(age) if age is not None else None),
                     "age_txt": _sw_fmt_age(age), "threshold_s": thr, "threshold_txt": _sw_fmt_age(thr),
                     "fails": fails, "important": imp, "why": why, "time_source": src})
    arch = None
    try:
        a = globals().get("_arch")
        if a is not None:
            st = a.status()
            fl = _sw_time.time() - float(st.get("last_flush") or 0)
            arch = {"paused": bool(st.get("paused")), "series": st.get("series"), "last_flush_s": int(fl),
                    "state": "ausgefallen" if st.get("paused") else ("alt" if fl > 3 * 3600 else "ok")}
    except Exception as e:
        arch = {"state": "unbekannt", "error": str(e)[:100]}
    bad = [r["name"] for r in rows if r["important"] and r["state"] == "ausgefallen"]
    cnt = {s: sum(1 for r in rows if r["state"] == s) for s in ("ok", "alt", "ausgefallen", "unbekannt")}
    return {"ok": True, "at": _sw_dt.now().strftime("%d.%m.%Y %H:%M:%S"), "sources": rows, "counts": cnt,
            "important_down": bad, "archive": arch, "ping24": _sw_ping24(),
            "uptime_s": int(now - _sw_started["t"])}


_SW_COL = {"ok": "#22c55e", "alt": "#eab308", "ausgefallen": "#ef4444", "unbekannt": "#64748b"}


def _sw_esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _sw_card(d):
    tr = []
    for r in d["sources"]:
        c = _SW_COL.get(r["state"], "#64748b")
        tr.append('<tr><td>%s</td><td style="color:%s;font-weight:600">%s</td><td style="text-align:right">%s</td>'
                  '<td style="text-align:right;opacity:.6">%s</td><td style="opacity:.7">%s</td></tr>'
                  % (_sw_esc(r["name"]), c, r["state"], r["age_txt"], r["threshold_txt"], _sw_esc(r["why"])))
    p = d.get("ping24")
    pl = ("Ping 24 h: min %s · Ø %s · max %s ms (%d Werte)%s" % (p["min"], p["avg"], p["max"], p["n"],
          (" · offline %s %%" % p["offline_pct"]) if "offline_pct" in p else "")).replace(".", ",") if p else "Ping 24 h: noch keine Werte"
    a = d.get("archive") or {}
    al = "Archiv: %s" % a.get("state", "–") + (" (pausiert, Platte fast voll)" if a.get("paused") else "")
    c = d["counts"]
    return ('<div class="card src-card" id="srcCard" style="margin-top:12px"><div class="title">📡 Datenquellen</div>'
            '<div class="small" style="margin:4px 0 6px">%d ok · %d alt · %d ausgefallen · Stand %s</div>'
            '<table class="small" style="width:100%%;border-collapse:collapse;line-height:1.5">'
            '<tr style="opacity:.6"><td>Quelle</td><td>Status</td><td style="text-align:right">Alter</td>'
            '<td style="text-align:right">Schwelle</td><td></td></tr>%s</table>'
            '<div class="small" style="margin-top:6px;opacity:.8">%s<br>%s · alt = gehaltener oder überfälliger Wert, '
            'ausgefallen = älter als 2× Schwelle</div></div>') % (c["ok"], c["alt"], c["ausgefallen"], d["at"][11:16], "".join(tr), pl, al)


def _sw_banner(d):
    if not d["important_down"]:
        return ""
    return ('<div class="src-banner" style="background:#7f1d1d;color:#fff;padding:10px 14px;margin:0 0 10px;'
            'border-radius:8px;font-weight:600">⚠️ Datenquelle ausgefallen: %s – Werte sind veraltet, siehe Karte Datenquellen</div>'
            % _sw_esc(", ".join(d["important_down"])))


def _sw_after(resp):
    try:
        from flask import request as _sw_req
        if _sw_req.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if "src-card" in body:
            return resp
        d = sw_sources()
        i = body.rfind("</body>")
        if i < 0:
            return resp
        body = body[:i] + _sw_card(d) + body[i:]
        bn = _sw_banner(d)
        if bn:
            j = body.find("<body")
            k = body.find(">", j) if j >= 0 else -1
            if k > 0:
                body = body[:k + 1] + bn + body[k + 1:]
        resp.set_data(body)
    except Exception as e:
        print("sourceWatch /pi:", e, flush=True)
    return resp


def _sw_api():
    from flask import jsonify as _sw_jsonify
    return _sw_jsonify(sw_sources())


# ---- load_ping_stats: live Mesh-Ping-Zaehler (gleiche Form: total, updated, rows[id,count,last,name]) ----
if callable(globals().get("load_ping_stats")):
    _sw_orig_load_ping_stats = load_ping_stats

    def load_ping_stats():
        old = _sw_orig_load_ping_stats()
        if not isinstance(old, dict):
            old = {"total": 0, "updated": "–", "rows": []}
        try:
            ds = globals().get("data_store") or {}
            rows, total, last_any, live = {}, 0, None, False
            for k in ("mesh_ping", "mesh_ping2"):
                slot = ds.get(k)
                v = slot.get("value") if isinstance(slot, dict) else None
                if not isinstance(v, dict) or not isinstance(v.get("nodes"), list):
                    continue
                live = True
                total += int(v.get("total") or 0)
                for n in v["nodes"]:
                    if not isinstance(n, dict):
                        continue
                    nid = str(n.get("id") or "?")
                    r = rows.setdefault(nid, {"id": nid, "count": 0, "last": "–", "name": n.get("name") or None})
                    r["count"] += int(n.get("n") or n.get("count") or 0)
                    ls = str(n.get("last") or "")
                    if ls and (r["last"] == "–" or ls > str(r["last"])):
                        r["last"] = ls
                    if ls and (last_any is None or ls > last_any):
                        last_any = ls
            if live:
                rr = sorted(rows.values(), key=lambda x: (-x["count"], x["id"]))
                return {"total": total, "updated": (last_any or "live, noch keine Pings"), "rows": rr,
                        "stale": False, "source": "live (Bridge-Inbox)", "file_updated": old.get("updated")}
        except Exception as e:
            print("sourceWatch ping_stats:", e, flush=True)
        out = dict(old)
        out["stale"] = True
        out["rows"] = []
        out["total"] = 0
        out["updated"] = "veraltet (Datei %s) – ausgeblendet" % old.get("updated", "–")
        return out

if "sw_sources" not in app.view_functions:
    app.add_url_rule("/api/sources", endpoint="sw_sources", view_func=_sw_api, methods=["GET"])
app.after_request(_sw_after)
if __name__ == "__main__" and not _sw_started["thread"]:
    _sw_started["thread"] = True
    _sw_th.Thread(target=_sw_loop, name="sourceWatch", daemon=True).start()
print("sourceWatch aktiv: %d Quellen" % len(SW_SOURCES), flush=True)
# ===== /sourceWatch =====

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
    if "/api/sources" in src:
        raise SystemExit("STOP: /api/sources gibt es schon - nichts geaendert")
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
P="$W/patch-source-watch.py"
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
  echo "OK sourceWatch schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-sourcewatch-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-sourcewatch-$TS"
  }
  cp -a "$F" "$F.bak-sourcewatch-$TS"
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
print("Quellen: %d ok, %d alt, %d ausgefallen, %d unbekannt" % (c["ok"], c["alt"], c["ausgefallen"], c["unbekannt"]))
for r in d["sources"]:
    print("  %-16s %-11s %9s (Schwelle %s, Fehler %d, Zeit aus %s) %s" % (r["name"][:16], r["state"], r["age_txt"], r["threshold_txt"], r["fails"], r["time_source"] or "-", r["why"][:50]))
print("Banner:", ", ".join(d["important_down"]) or "keins")
p = d.get("ping24")
print("Ping 24 h:", ("min %s / avg %s / max %s ms, %d Werte, offline %s %%" % (p["min"], p["avg"], p["max"], p["n"], p.get("offline_pct", "-"))) if p else "noch keine Werte")
print("Archiv:", (d.get("archive") or {}).get("state"))
PY
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    if grep -q 'src-card' "$W/pi.html"; then echo "OK /pi zeigt Karte Datenquellen$(grep -q 'src-banner' "$W/pi.html" && echo ' + rotes Banner' || echo ', kein Banner')"; else echo "WARN /pi 200, aber Karte nicht eingefuegt"; fi
    grep -q 'arch-card' "$W/pi.html" && echo "OK Archiv-Karte weiterhin da" || echo "Hinweis: Archiv-Karte nicht gefunden"
  fi
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-sourcewatch-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "OK guards sourceWatch=$(grep -q '# ===== sourceWatch:' "$F" && echo 1 || echo 0) firmsKeep=$(grep -q '# ===== firmsKeep:' "$F" && echo 1 || echo 0) longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) priceAllTime=$(grep -q '# ===== priceAllTime:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-sourcewatch-$TS" ]] && echo "Backup: $F.bak-sourcewatch-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG sourceWatch=1"
