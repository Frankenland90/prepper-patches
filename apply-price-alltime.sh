#!/bin/bash
set -euo pipefail
# priceAllTime: Diesel- und Brent-Kachel zeigen zusaetzlich Hoechst/Tiefst seit Aufzeichnung.
# Eigene Datei price_alltime.json (atomar), Startwerte aus fuel_history/oil_history, danach nach jedem
# Speichern der Historie nachgefuehrt. Unplausible Werte werden ignoriert. 14-Tage-Zeilen bleiben.
# Nur dashboard.py, nur bei sha16 73c85cfe196baad1. Sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/pricealltime
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== priceAllTime apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="44f6228ef627560fc7a33b8235cbb25046502a65da40de451628959f8dffc6a8"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-price-alltime.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""priceAllTime: Diesel/Brent Hoechst/Tiefst seit Aufzeichnung. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== priceAllTime:"
EXPECT = "73c85cfe196baad1"   # dashboard.py nach pegelTrend
ANCHORS = ['<span id="dieselLoText">–</span></div>', '<span id="oilLoText">–</span></div>',
           'id="dieselHiLo"', 'id="oilHiLo"', "# ===== funkHarden3:", "# ===== pegelTrend:"]
NEED_DEFS = ["save_fuel_history", "save_oil_history", "load_fuel_history", "load_oil_history"]
NEED_NAMES = ["diesel_history", "oil_history", "app"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== priceAllTime: Hoechst/Tiefst seit Aufzeichnung fuer Diesel und Brent =====
# Eigene Datei price_alltime.json (atomar), erster Inhalt aus den aktuellen Historien, danach nach jedem
# save_fuel_history/save_oil_history aus der ganzen aktuellen Historie nachgefuehrt (nur max/min-Vergleich).
# Anzeige per Jinja-Global price_alltime(key) unter den 14-Tage-Zeilen. Sendet nichts, schreibt kein data_store.
import io as _pat_io
import json as _pat_json
import os as _pat_os
import re as _pat_re
import threading as _pat_th
from datetime import datetime as _pat_dt, date as _pat_date, timedelta as _pat_td

PAT_FILE = _pat_os.path.join(_pat_os.path.dirname(_pat_os.path.abspath(__file__)), "price_alltime.json")
# Erweiterbar: key -> (Name der History-Deque mit {t, v}, Zeitstempel mit Uhrzeit), Plausibilitaet, Nachkommastellen.
PAT_SERIES = {"diesel": ("diesel_history", True), "brent": ("oil_history", False)}
PAT_RANGE = {"diesel": (0.5, 5.0), "brent": (5.0, 500.0)}
PAT_DEC = {"diesel": 3, "brent": 2}
_pat_lk = _pat_th.RLock()
_pat = {"data": None, "res": {}}
_PAT_RE = _pat_re.compile(r"^\s*(\d{1,2})\.(\d{1,2})\.?(?:(\d{4}))?(?:\s+(\d{1,2}):(\d{2}))?\s*$")


def _pat_points(hist, today=None):
    """[(datetime, value)] aus {t:'DD.MM[ HH:MM]', v} in zeitlicher Reihenfolge; Jahr rueckwaerts ab heute."""
    today = today or _pat_dt.now()
    raw = []
    for p in list(hist or []):
        try:
            if not isinstance(p, dict) or p.get("v") is None:
                continue
            m = _PAT_RE.match(str(p.get("t") or ""))
            if not m:
                continue
            v = float(p.get("v"))
            raw.append((int(m.group(1)), int(m.group(2)), m.group(3), int(m.group(4) or 0), int(m.group(5) or 0), v))
        except Exception:
            continue
    out = []
    year = today.year
    nxt = None
    for d, mo, y, hh, mi, v in reversed(raw):
        try:
            if y:
                year = int(y)
            elif nxt is None:
                if _pat_date(year, mo, d) > today.date() + _pat_td(days=30):
                    year -= 1
            elif (mo, d) > nxt:
                year -= 1
            nxt = (mo, d)
            out.append((_pat_dt(year, mo, d, hh, mi), v))
        except Exception:
            continue
    out.reverse()
    return out


def _pat_load():
    if _pat["data"] is not None:
        return _pat["data"]
    data = {}
    try:
        with _pat_io.open(PAT_FILE, "r", encoding="utf-8") as f:
            d = _pat_json.load(f)
        if isinstance(d, dict):
            data = d
    except FileNotFoundError:
        pass
    except Exception as e:
        print("priceAllTime lesen:", e)
    _pat["data"] = data
    return data


def _pat_write(data):
    tmp = "%s.tmp.%d" % (PAT_FILE, _pat_os.getpid())
    with _pat_io.open(tmp, "w", encoding="utf-8") as f:
        _pat_json.dump(data, f, ensure_ascii=False, indent=1)
        f.flush()
        _pat_os.fsync(f.fileno())
    _pat_os.replace(tmp, PAT_FILE)


def _pat_merge(key, hist, has_time):
    lo_ok, hi_ok = PAT_RANGE[key]
    pts = [(t, v) for t, v in _pat_points(hist) if lo_ok <= v <= hi_ok]
    if not pts:
        return False
    fmt = "%Y-%m-%d %H:%M" if has_time else "%Y-%m-%d"
    with _pat_lk:
        data = _pat_load()
        rec = dict(data.get(key) or {})
        ch = False
        for t, v in pts:
            ts = t.strftime(fmt)
            hi = rec.get("hi") or {}
            lo = rec.get("lo") or {}
            if hi.get("v") is None or v > float(hi["v"]):
                rec["hi"] = {"v": v, "t": ts}
                ch = True
            if lo.get("v") is None or v < float(lo["v"]):
                rec["lo"] = {"v": v, "t": ts}
                ch = True
            since = t.strftime("%Y-%m-%d")
            if not rec.get("since") or since < rec["since"]:
                rec["since"] = since
                ch = True
        if ch:
            rec["updated"] = _pat_dt.now().strftime("%Y-%m-%d %H:%M")
            new = dict(data)
            new["_schema"] = 1
            new[key] = rec
            _pat_write(new)
            _pat["data"] = new
        _pat["res"][key] = "ok %d Punkte" % len(pts)
        return ch


def _pat_refresh(which=None):
    for key in (which or list(PAT_SERIES.keys())):
        try:
            hist_name, has_time = PAT_SERIES[key]
            _pat_merge(key, globals().get(hist_name), has_time)
        except Exception as e:
            _pat["res"][key] = "Fehler %s" % e
            print("priceAllTime %s:" % key, e)


def _pat_chain(name, which):
    orig = globals().get(name)
    if not callable(orig) or getattr(orig, "_priceAllTime", False):
        return "fehlt" if not callable(orig) else "schon"

    def wrapped(*a, **k):
        r = orig(*a, **k)
        _pat_refresh(which)
        return r
    wrapped._priceAllTime = True
    wrapped.__name__ = getattr(orig, "__name__", name)
    wrapped.__wrapped__ = orig
    globals()[name] = wrapped
    return "neu"


_pat["res"]["save_fuel_history"] = _pat_chain("save_fuel_history", ("diesel",))
_pat["res"]["save_oil_history"] = _pat_chain("save_oil_history", ("brent",))


def _pat_de(ts, has_time):
    try:
        t = _pat_dt.strptime(ts, "%Y-%m-%d %H:%M" if has_time else "%Y-%m-%d")
        return t.strftime("%d.%m.%Y %H:%M" if has_time else "%d.%m.%Y")
    except Exception:
        return str(ts or "–")


def price_alltime(key):
    """Fuer das Template: {'since','hi_t','hi_v','lo_t','lo_v'} oder None."""
    try:
        with _pat_lk:
            rec = (_pat_load() or {}).get(key)
            if not rec:
                _pat_refresh((key,))
                rec = (_pat_load() or {}).get(key)
        if not rec or not rec.get("hi") or not rec.get("lo"):
            return None
        ht = bool(PAT_SERIES.get(key, (None, False))[1])
        dec = PAT_DEC.get(key, 2)
        return {"since": _pat_de(rec.get("since"), False),
                "hi_t": _pat_de(rec["hi"].get("t"), ht), "hi_v": ("%%.%df" % dec) % float(rec["hi"]["v"]),
                "lo_t": _pat_de(rec["lo"].get("t"), ht), "lo_v": ("%%.%df" % dec) % float(rec["lo"]["v"])}
    except Exception as e:
        print("priceAllTime Anzeige:", e)
        return None


def _pat_html(key):
    return ('\n      {% if price_alltime is defined %}{% set pat = price_alltime("' + key + '") %}{% if pat %}'
            '<div class="pat-alltime" style="font-size:.72rem;color:#94a3b8;margin-top:4px;line-height:1.4">'
            '<div>seit Aufzeichnung ({{ pat.since }}):</div>'
            '<div><span style="color:#ef4444;opacity:.75">↑</span> {{ pat.hi_t }} · {{ pat.hi_v }} €</div>'
            '<div><span style="color:#22c55e;opacity:.75">↓</span> {{ pat.lo_t }} · {{ pat.lo_v }} €</div>'
            '</div>{% endif %}{% endif %}')


_PAT_ANCH = {"diesel": '<span id="dieselLoText">–</span></div>', "brent": '<span id="oilLoText">–</span></div>'}


def _pat_patch_templates():
    hits = []
    g = globals()
    for name in list(g.keys()):
        v = g.get(name)
        if not isinstance(v, str) or len(v) < 200 or "pat-alltime" in v:
            continue
        nv = v
        for key, a in _PAT_ANCH.items():
            if nv.count(a) == 1:
                nv = nv.replace(a, a + _pat_html(key))
                hits.append("%s:%s" % (name, key))
        if nv is not v:
            g[name] = nv
    return hits


try:
    _pat["res"]["templates"] = _pat_patch_templates()
    app.jinja_env.globals["price_alltime"] = price_alltime
except Exception as _pat_e:
    _pat["res"]["templates"] = "Fehler %s" % _pat_e
print("priceAllTime aktiv:", _pat["res"], flush=True)
# ===== /priceAllTime =====

'''


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    if MARK in src:
        print("RESULT dashboard.py=schon")
        return
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    if h != EXPECT and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    miss = [a for a in ANCHORS if a not in src]
    if miss:
        raise SystemExit("STOP: Anker fehlt %s - nichts geaendert" % miss)
    if "pat-alltime" in src or "price_alltime" in src:
        raise SystemExit("STOP: price_alltime schon im Text - nichts geaendert")
    tree = ast.parse(src)
    defs = set()
    names = set()
    for n in tree.body:
        if isinstance(n, ast.FunctionDef):
            defs.add(n.name)
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    names.add(t.id)
    miss = [k for k in NEED_DEFS if k not in defs] + [k for k in NEED_NAMES if k not in names]
    if miss:
        raise SystemExit("STOP: fehlt %s - nichts geaendert" % miss)
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s, Anker Diesel %dx Brent %dx in Datei)" % (h, src.count(ANCHORS[0]), src.count(ANCHORS[1])))


if __name__ == "__main__":
    main()
PATCHPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-price-alltime.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "BLOCK" for t in n.targets):
        blk = n.value.value
if blk is None:
    raise SystemExit(4)
hit = False
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, ast.Call):
        f = node.func
        nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if nm.startswith(("send", "maybe_mesh", "fetch")) or nm in ("TCPInterface", "sendText", "urlopen", "create_connection", "update_all", "post", "get_json", "Popen", "system", "run", "request"):
            print("verbotener Aufruf", nm, "Zeile", node.lineno); hit = True
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id in ("requests", "urllib", "socket", "subprocess"):
            print("Netz/Prozess-Aufruf", f.value.id, "Zeile", node.lineno); hit = True
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if a.name.split(".")[0] in ("requests", "urllib", "socket", "subprocess", "http"):
                print("verbotener Import", a.name); hit = True
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id in ("data_store", "diesel_history", "oil_history"):
                print("Zuweisung an", t.id); hit = True
            if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name) and t.value.id == "data_store":
                print("data_store-Schreiben"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Sendeweg, kein Netz, kein data_store, keine History-Zuweisung)"

# ---------- 1) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error::SyntaxWarning -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
grep -q '# ===== priceAllTime:' "$W/work/dashboard.py" || { echo "STOP: Marker fehlt im Trockenlauf"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /energie /pegel /funk; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /energie=${PRE[/energie]} /pegel=${PRE[/pegel]} /funk=${PRE[/funk]}"

if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK dashboard.py hat priceAllTime schon - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-alltime-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-alltime-$TS bleibt"
  }
  cp -a "$F" "$F.bak-alltime-$TS"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; 5 min Ruhezeit, sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  hitp=""
  for p in /energie /; do
    "${CURL[@]}" -L --max-redirs 5 "$B$p" -o "$W/page.html" || true
    n=$(grep -o 'class="pat-alltime"' "$W/page.html" 2>/dev/null | wc -l || true)
    echo "GET $p: Allzeit-Bloecke=$n"
    if [[ "$n" -ge 1 ]]; then hitp=$p; (grep -o 'seit Aufzeichnung[^<]*' "$W/page.html" || true) | head -1; sed -e 's/<[^>]*>/ /g' "$W/page.html" | grep -o '[0-9][0-9.]*[0-9: ]* · [0-9.]* €' | head -6 || true; break; fi
  done
  [[ -n "$hitp" ]] || { rb "keine Seite zeigt den Allzeit-Block"; exit 1; }
  [[ -s "$DASH_DIR/price_alltime.json" ]] && python3 -m json.tool "$DASH_DIR/price_alltime.json" > /dev/null || { rb "price_alltime.json fehlt oder kaputt"; exit 1; }
  echo "OK $hitp zeigt seit Aufzeichnung, price_alltime.json gueltig"
fi
fail=0
for p in / /energie /pegel /funk; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  if [[ -f "$F.bak-alltime-$TS" ]]; then rb "Seite antwortet schlechter als vorher"; fi
  exit 1
fi
echo "OK guards priceAllTime=$(grep -q '# ===== priceAllTime:' "$F" && echo 1 || echo 0) pegelTrend=$(grep -q '# ===== pegelTrend:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0) funkHarden2=$(grep -q '# ===== funkHarden2:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-alltime-$TS" ]] && echo "Backup: $F.bak-alltime-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16)"
echo "COMMIT $COMMIT_ARG priceAllTime=1"
