#!/bin/bash
set -euo pipefail
# funkHarden3: watchdog.py gehaertet + Status-/Verlaufsdateien im Dashboard atomar
# watchdog.py: Port aus config.py (8080 -> 5000), OK nur 1x/h + bei Zustandswechsel,
#   Log-Kuerzen und Cooldown-Datei atomar, Neustart (sudo systemctl restart) + 30 min Cooldown wie bisher.
# dashboard.py: save_*-Funktionen (Verlaeufe, DWD/WBI, NINA, Wetter) + ADSB-Verlauf schreiben ueber
#   Temp-Datei + os.replace unter Sperre; Inhalt und globale Variablen unveraendert.
# Nur bei exakt geprueftem Live-Stand, sonst STOP ohne Aenderung. Sendet nichts.
# Neustart nur prepper-dashboard (watchdog ist ein Timer-Oneshot). Smoke gegen config.py PORT, nie :8080.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/funkharden3
FILES="watchdog.py dashboard.py"
EXPECT_PATCH="cef26672a0323389308b9a59e44d3500bbf5983cbf212e86edd1cb4133a642b0"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-funk-harden3.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""funkHarden3: watchdog.py ersetzen + Status-/Verlaufsdateien im Dashboard atomar.
Nur bei exakt geprueftem Live-Stand (sha256/16), sonst STOP ohne Aenderung. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== funkHarden3"
EXPECT = {"dashboard.py": "649945b9f6bfa4de", "watchdog.py": "6c94d672f57d3a2a"}
KNOWN = ["save_history", "save_fuel_history", "save_firms_history", "save_oil_history",
         "save_outage_history", "save_mesh_weather_status", "save_wbi_history",
         "save_dwd_mesh_status", "save_dwd_wbi_status", "save_nina_mesh_status"]
HIST_ANCHOR = re.compile(r"""open\(\s*hist_path\s*,\s*["']w["']\s*\)""")
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
DASH_BLOCK = r'''
# ===== funkHarden3: Status-/Verlaufsdateien atomar schreiben =====
# Die save_*-Funktionen laufen unveraendert (gleicher JSON-Inhalt, gleiche globale Variablen).
# Nur waehrend ihres Aufrufs wird ein open(..., "w") zu: Temp-Datei im selben Ordner,
# flush + fsync, dann os.replace. Bricht das Schreiben ab, bleibt die alte Datei ganz.
# Alle anderen open()-Aufrufe (andere Threads, Lesen, Anhaengen) gehen 1:1 an builtins.open.
import builtins as _fh3_builtins
import os as _fh3_os
import threading as _fh3_th
import itertools as _fh3_it
import time as _fh3_time

FH3_NAMES = __FH3_NAMES__
_fh3_tls = _fh3_th.local()
_fh3_locks = {}
_fh3_glock = _fh3_th.Lock()
_fh3_seq = _fh3_it.count(1)
_fh3 = {"res": {}, "atomic": 0, "fail": 0, "plain": 0}


def _fh3_lock_for(path):
    with _fh3_glock:
        lk = _fh3_locks.get(path)
        if lk is None:
            lk = _fh3_locks[path] = _fh3_th.RLock()
        return lk


class _Fh3AtomicFile:
    """Datei-Objekt fuer genau einen atomaren Schreibvorgang."""

    def __init__(self, path, mode, a, kw):
        self._path = path
        self._lock = _fh3_lock_for(path)
        self._lock.acquire()
        self._done = False
        try:
            d = _fh3_os.path.dirname(path) or "."
            self._tmp = _fh3_os.path.join(d, ".%s.fh3tmp-%d-%d" % (
                _fh3_os.path.basename(path), _fh3_os.getpid(), next(_fh3_seq)))
            self._f = _fh3_builtins.open(self._tmp, mode, *a, **kw)
        except BaseException:
            self._lock.release()
            self._done = True
            raise

    def __getattr__(self, name):
        return getattr(self._f, name)

    def __iter__(self):
        return iter(self._f)

    def write(self, s):
        return self._f.write(s)

    def writelines(self, lines):
        return self._f.writelines(lines)

    def _finish(self, ok):
        if self._done:
            return
        self._done = True
        try:
            if ok:
                self._f.flush()
                try:
                    _fh3_os.fsync(self._f.fileno())
                except Exception:
                    pass
                self._f.close()
                try:
                    st = _fh3_os.stat(self._path)
                    _fh3_os.chmod(self._tmp, st.st_mode & 0o7777)
                except Exception:
                    pass
                _fh3_os.replace(self._tmp, self._path)
                _fh3["atomic"] += 1
            else:
                try:
                    self._f.close()
                except Exception:
                    pass
                _fh3["fail"] += 1
        finally:
            try:
                if _fh3_os.path.exists(self._tmp):
                    _fh3_os.unlink(self._tmp)
            except Exception:
                pass
            self._lock.release()

    def close(self):
        self._finish(True)

    @property
    def closed(self):
        return self._done

    def __enter__(self):
        return self

    def __exit__(self, et, ev, tb):
        self._finish(et is None)
        return False

    def __del__(self):
        try:
            if not self._done:
                self._finish(True)  # wie bisher: ohne with/close schreibt GC die Datei
        except Exception:
            pass


def open(file, mode="r", *a, **kw):  # funkHarden3: nur in save_* atomar, sonst builtins.open
    if getattr(_fh3_tls, "depth", 0) > 0 and isinstance(mode, str) and mode in ("w", "wt", "wb", "w+", "w+b") \
            and isinstance(file, (str, bytes, _fh3_os.PathLike)):
        p = _fh3_os.fsdecode(_fh3_os.fspath(file))
        if not _fh3_os.path.islink(p):
            return _Fh3AtomicFile(p, mode, a, kw)
        _fh3["plain"] += 1
    return _fh3_builtins.open(file, mode, *a, **kw)


def _fh3_wrap(name):
    cur = globals().get(name)
    if not callable(cur):
        return "fehlt"
    if getattr(cur, "_fh3", False):
        return "schon"

    def wrapped(*a, **kw):  # funkHarden3
        _fh3_tls.depth = getattr(_fh3_tls, "depth", 0) + 1
        try:
            return cur(*a, **kw)
        finally:
            _fh3_tls.depth -= 1

    wrapped._fh3 = True
    wrapped.__wrapped__ = cur
    wrapped.__name__ = name
    wrapped.__doc__ = getattr(cur, "__doc__", None)
    for attr in ("_fh2", "_mbq", "_ninaCalm"):
        if hasattr(cur, attr):
            setattr(wrapped, attr, getattr(cur, attr))
    globals()[name] = wrapped
    return "neu"


def _fh3_cleanup():
    """Reste abgebrochener Schreibvorgaenge (aelter als 1 h) wegraeumen."""
    n = 0
    dirs = set()
    for v in list(globals().values()):
        if isinstance(v, str) and v.endswith(".json") and _fh3_os.path.isabs(v):
            dirs.add(_fh3_os.path.dirname(v))
    dirs.add(_fh3_os.path.dirname(_fh3_os.path.abspath(__file__)))
    for d in dirs:
        try:
            for fn in _fh3_os.listdir(d):
                if ".fh3tmp-" in fn and fn.startswith("."):
                    p = _fh3_os.path.join(d, fn)
                    if _fh3_time.time() - _fh3_os.path.getmtime(p) > 3600:
                        _fh3_os.unlink(p)
                        n += 1
        except Exception:
            pass
    return n


def _fh3_install():
    res = {}
    for name in FH3_NAMES + ["save_pegel_mesh_status"]:
        r = _fh3_wrap(name)
        if r != "fehlt" or name != "save_pegel_mesh_status":
            res[name] = r
    res["_aufgeraeumt"] = _fh3_cleanup()
    _fh3["res"] = res
    try:
        from flask import jsonify as _fh3_js

        def fh3_status():  # funkHarden3: nur lesen
            return _fh3_js({"funkHarden3": 1, "res": _fh3["res"], "atomic": _fh3["atomic"],
                            "fail": _fh3["fail"], "plain": _fh3["plain"]})
        if "fh3_status" not in app.view_functions:
            app.add_url_rule("/api/funk/atomic", endpoint="fh3_status", view_func=fh3_status, methods=["GET"])
    except Exception as e:
        res["_status_route"] = "Fehler: %s" % e
    print("funkHarden3 aktiv: %s" % res, flush=True)
    return res


try:
    _fh3_install()
except Exception as _fh3_e:
    print("funkHarden3 install:", _fh3_e, flush=True)
# ===== /funkHarden3 =====

'''
WATCHDOG_NEW = r'''#!/usr/bin/env python3
# ===== funkHarden3 watchdog: Port aus config.py, OK 1x/h, atomar =====
"""Schlanker Watchdog: Dienst + GET / → optional Restart (Cooldown 30 min).  # funkHarden3

funkHarden3: Port aus config.py (8080 = kiwix -> 5000), OK nur 1x pro Stunde und bei
Zustandswechsel im Log, Log kuerzen und Cooldown-Datei atomar. Neustart wie bisher.
"""
import os
import re
import sys
import time
import json
import subprocess
import urllib.request
from pathlib import Path
from datetime import datetime

BASE = Path("/home/fmg/prepper-dashboard")
FLAG = BASE / "last_dashboard_restart.txt"
LOG = BASE / "watchdog.log"
STATE = BASE / "watchdog_state.json"
COOLDOWN_MIN = 30
OK_LOG_EVERY = 3600
DEFAULT_PORT = 5000


def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def _atomic_write(path, text):
    path = Path(path)
    tmp = path.with_name(".%s.tmp-%d" % (path.name, os.getpid()))
    try:
        with open(tmp, "w") as f:
            f.write(text)
            f.flush()
            try:
                os.fsync(f.fileno())
            except Exception:
                pass
        os.replace(tmp, path)
    finally:
        try:
            if tmp.exists():
                tmp.unlink()
        except Exception:
            pass


def dash_port():
    """PORT aus config.py; fehlt/kaputt/8080 -> 5000."""
    try:
        txt = (BASE / "config.py").read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^PORT\s*=\s*(\d+)", txt, re.M)
        if m:
            p = int(m.group(1))
            if p != 8080 and 0 < p < 65536:
                return p
    except Exception:
        pass
    return DEFAULT_PORT


def log(msg):
    line = f"[{now_str()}] {msg}"
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
        lines = LOG.read_text().splitlines()
        if len(lines) > 400:
            _atomic_write(LOG, "\n".join(lines[-300:]) + "\n")
    except Exception:
        pass


def _load_state():
    try:
        d = json.loads(STATE.read_text())
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _save_state(d):
    try:
        _atomic_write(STATE, json.dumps(d))
    except Exception:
        pass


def active():
    p = subprocess.run(
        ["systemctl", "is-active", "prepper-dashboard"],
        capture_output=True, text=True,
    )
    return p.returncode == 0 and p.stdout.strip() == "active"


def http_root():
    try:
        r = urllib.request.urlopen("http://127.0.0.1:%d/" % dash_port(), timeout=5)
        return r.status == 200
    except Exception:
        return False


def can_restart():
    if not FLAG.exists():
        return True
    return (time.time() - FLAG.stat().st_mtime) >= COOLDOWN_MIN * 60


def main():
    ok_svc = active()
    ok_http = http_root()
    st = _load_state()
    prev = st.get("state")
    now = time.time()
    if ok_svc and ok_http:
        if prev != "ok" or now - float(st.get("ok_logged") or 0) >= OK_LOG_EVERY:
            log("OK service+http" + (" (wieder ok)" if prev not in (None, "ok") else ""))
            st["ok_logged"] = now
        st["state"] = "ok"
        _save_state(st)
        return 0
    st["state"] = "fail"
    _save_state(st)
    log(f"FAIL service={ok_svc} http={ok_http}")
    if not can_restart():
        log(f"Cooldown {COOLDOWN_MIN} min – kein Restart")
        return 1
    log("Restart prepper-dashboard")
    subprocess.run(
        ["sudo", "systemctl", "restart", "prepper-dashboard"],
        check=False,
    )
    _atomic_write(FLAG, now_str())
    time.sleep(20)
    ok2 = active() and http_root()
    log(f"nach Restart recovered={ok2}")
    return 0 if ok2 else 1


def selftest():
    """Nur lesen: zeigt Port/Zustand, kein Log, kein Restart."""
    print("watchdog funkHarden3 port=%d svc=%s http=%s cooldown_frei=%s" % (
        dash_port(), active(), http_root(), can_restart()))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        raise SystemExit(selftest())
    raise SystemExit(main())
'''


def sha16(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]


def p_watchdog(src):
    if "def main():" not in src or '["sudo", "systemctl", "restart", "prepper-dashboard"]' not in src:
        raise SystemExit("STOP watchdog.py: Anker fehlt")
    return WATCHDOG_NEW, "ersetzt"


def p_dash(src):
    tree = ast.parse(src)
    top = {}
    for n in tree.body:
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            top[n.name] = n
        for t in ([n] if isinstance(n, (ast.FunctionDef, ast.ClassDef)) else []):
            if t.name == "open":
                raise SystemExit("STOP dashboard.py: eigenes open() schon vorhanden")
    for n in tree.body:
        for x in ([n] if not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) else []):
            for y in ast.walk(x):
                if isinstance(y, ast.Name) and y.id == "open" and isinstance(y.ctx, ast.Store):
                    raise SystemExit("STOP dashboard.py: Modul-Zuweisung an open gefunden")
                if isinstance(y, (ast.Import, ast.ImportFrom)) and any((a.asname or a.name) == "open" for a in y.names):
                    raise SystemExit("STOP dashboard.py: open wird auf Modulebene importiert")
    miss = [k for k in KNOWN if k not in top]
    if miss:
        raise SystemExit("STOP dashboard.py: fehlt %s" % ",".join(miss))
    names = list(KNOWN)
    extra = "keine"
    lines = src.splitlines()
    hits = [i + 1 for i, l in enumerate(lines) if HIST_ANCHOR.search(l)]
    for ln in hits:
        for nm, n in top.items():
            if n.lineno <= ln <= n.end_lineno:
                loop = any(isinstance(x, (ast.While,)) for x in ast.walk(n))
                if not n.decorator_list and not loop and nm not in names:
                    names.append(nm)
                    extra = "%s (Zeile %d)" % (nm, ln)
                elif nm not in names:
                    extra = "%s uebersprungen (Dekorator/Schleife)" % nm
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP dashboard.py: __main__ %d mal" % len(ms))
    p = ms[0].start()
    # Funktionen, die vor dem Block nur als Wert (nicht als Aufruf) benutzt werden -> nicht abgedeckt
    called = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name):
            called.add(id(n.func))
    refs = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Name) and n.id in names and isinstance(n.ctx, ast.Load) and id(n) not in called:
            refs.append("%s@%d" % (n.id, n.lineno))
    block = DASH_BLOCK.replace("__FH3_NAMES__", repr(names))
    new = src[:p].rstrip("\n") + "\n\n" + block + "\n\n" + src[p:]
    return new, "neu, %d Funktionen, Extra %s, Wert-Referenzen %s" % (len(names), extra, ",".join(refs) or "keine")


def main():
    root = Path(sys.argv[1])
    nosha = "--nosha" in sys.argv[2:]
    out = {}
    for name, fn in (("watchdog.py", p_watchdog), ("dashboard.py", p_dash)):
        f = root / name
        if not f.is_file():
            raise SystemExit("STOP: fehlt %s - nichts geaendert" % f)
        src = f.read_text(encoding="utf-8")
        if MARK in src:
            out[name] = (None, "schon")
            continue
        h = sha16(src)
        if h != EXPECT[name] and not nosha:
            raise SystemExit("STOP: %s sha16 %s statt %s - nichts geaendert" % (name, h, EXPECT[name]))
        new, info = fn(src)
        ast.parse(new)
        compile(new, str(f), "exec")
        out[name] = (new, info)
    for name, (new, info) in out.items():
        if new is not None:
            (root / name).write_text(new, encoding="utf-8")
        print("RESULT %s=%s" % (name, info))


if __name__ == "__main__":
    main()
PATCHPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
[[ -x "$VPY" ]] || VPY=python3
echo "=== funkHarden3 apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-funk-harden3.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
trees = [("patch", ast.parse(src))]
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ("DASH_BLOCK", "WATCHDOG_NEW") for t in n.targets):
        trees.append((n.targets[0].id, ast.parse(n.value.value.replace("__FH3_NAMES__", "[]"))))
hit = False
for nm, tree in trees:
    for node in ast.walk(tree):
        tg = node.targets if isinstance(node, ast.Assign) else ([node.target] if isinstance(node, (ast.AnnAssign, ast.AugAssign)) else [])
        for t in tg:
            if isinstance(t, ast.Name) and t.id == "data_store":
                print(nm, "data_store-Zuweisung", node.lineno); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if fn in ("update_all", "TCPInterface", "sendText", "sendData", "send_meshtastic", "send_nina_to_bayern",
                      "send_chunks_local", "send_chunks_bayern", "post", "create_connection"):
                print(nm, "verbotener Aufruf", fn, node.lineno); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein data_store, kein update_all, kein Sendeaufruf)"

# ---------- 1) Live-Stand + Trockenlauf ----------
for f in $FILES; do
  [[ -f "$DASH_DIR/$f" ]] || { echo "STOP: fehlt $f - nichts geaendert"; exit 1; }
  echo "  $f $(sha256sum "$DASH_DIR/$f" | cut -c1-16) $(grep -q '# ===== funkHarden3' "$DASH_DIR/$f" && echo schon || echo pruefen)"
done
grep -q '# ===== funkHarden2:' "$DASH_DIR/dashboard.py" || { echo "STOP: funkHarden2 fehlt im Dashboard - nichts geaendert"; exit 1; }
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
for f in $FILES; do cp -a "$DASH_DIR/$f" "$W/work/"; done
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Live-Stand weicht ab oder Trockenlauf fehlgeschlagen - NICHTS geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
for f in $FILES; do
  cmp -s "$W/work/$f" "$W/work1/$f" || { echo "STOP: nicht idempotent ($f) - nichts geaendert"; exit 1; }
  "$VPY" -m py_compile "$W/work/$f" || { echo "STOP: py_compile $f - nichts geaendert"; exit 1; }
done
/usr/bin/python3 -m py_compile "$W/work/watchdog.py" || { echo "STOP: System-Python watchdog - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /funk /mesh /mesh2 /luft /pi /api/funk/harden; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /funk=${PRE[/funk]} /mesh=${PRE[/mesh]} /mesh2=${PRE[/mesh2]} /luft=${PRE[/luft]} /pi=${PRE[/pi]} harden=${PRE[/api/funk/harden]}"

# ---------- 2) watchdog.py (Timer-Oneshot, kein Neustart) ----------
rbw() {
  echo "ROLLBACK watchdog.py: $1"
  [[ -f "$DASH_DIR/watchdog.py.bak-fh3-$TS" ]] && cp -a "$DASH_DIR/watchdog.py.bak-fh3-$TS" "$DASH_DIR/watchdog.py"
  echo "alter Watchdog wieder aktiv"
}
if cmp -s "$W/work/watchdog.py" "$DASH_DIR/watchdog.py"; then
  echo "OK watchdog.py hat funkHarden3 schon"
else
  cp -a "$DASH_DIR/watchdog.py" "$DASH_DIR/watchdog.py.bak-fh3-$TS"
  cp "$W/work/watchdog.py" "$DASH_DIR/watchdog.py"
  "$VPY" -m py_compile "$DASH_DIR/watchdog.py" || { rbw "py_compile"; exit 1; }
  st=$(cd "$DASH_DIR" && "$VPY" watchdog.py --selftest 2>&1 | tail -1 || true)
  echo "Watchdog Selbsttest (nur lesen): $st"
  [[ "$st" == *"port=$PORT "* ]] || { rbw "Selbsttest falsch"; exit 1; }
  echo "OK watchdog.py ersetzt (naechster Timer-Lauf nutzt ihn)"
fi

# ---------- 3) dashboard.py ----------
rbd() {
  echo "ROLLBACK dashboard.py: $1"
  [[ -f "$DASH_DIR/dashboard.py.bak-fh3-$TS" ]] && cp -a "$DASH_DIR/dashboard.py.bak-fh3-$TS" "$DASH_DIR/dashboard.py"
  sudo systemctl restart prepper-dashboard.service || true
  for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
  echo "alter Dashboard-Stand wieder aktiv (HTTP / = $(code "$B/"))"
}
if cmp -s "$W/work/dashboard.py" "$DASH_DIR/dashboard.py"; then
  echo "OK dashboard.py hat funkHarden3 schon - kein Neustart"
else
  sudo -v
  cp -a "$DASH_DIR/dashboard.py" "$DASH_DIR/dashboard.py.bak-fh3-$TS"
  cp "$W/work/dashboard.py" "$DASH_DIR/dashboard.py"
  "$VPY" -m py_compile "$DASH_DIR/dashboard.py" || { rbd "py_compile"; exit 1; }
  touch "$DASH_DIR/last_dashboard_restart.txt"   # Watchdog-Cooldown: startet waehrend des Neustarts nicht dazwischen
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; 5 min Ruhezeit, sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rbd "Dashboard antwortet nicht"; exit 1; }
  "${CURL[@]}" "$B/api/funk/atomic" -o "$W/a.json" || true
  python3 - "$W/a.json" << 'PY' || { rbd "funkHarden3 im Dashboard nicht aktiv"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
res = d.get("res") or {}
need = ["save_history", "save_fuel_history", "save_firms_history", "save_oil_history", "save_outage_history",
        "save_mesh_weather_status", "save_wbi_history", "save_dwd_mesh_status", "save_dwd_wbi_status", "save_nina_mesh_status"]
bad = [k for k in need if res.get(k) not in ("neu", "schon")]
extra = [k for k in res if k not in need and not k.startswith("_")]
print("Dashboard funkHarden3: %d/%d atomar%s, Temp-Reste aufgeraeumt %s" % (
    len(need) - len(bad), len(need), (" + " + ",".join(extra)) if extra else "", res.get("_aufgeraeumt")))
sys.exit(0 if d.get("funkHarden3") == 1 and not bad else 1)
PY
  echo "OK Dashboard laeuft mit funkHarden3"
fi
fail=0
for p in / /funk /mesh /mesh2 /luft /pi /api/funk/harden; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
[[ "$fail" -eq 0 ]] || { rbd "Seite antwortet schlechter als vorher"; exit 1; }
bad=0; n=0
for f in history.json fuel_history.json firms_history.json oil_history.json outage_history.json wbi_history.json mesh_weather_status.json nina_mesh_status.json dwd_mesh_status.json dwd_wbi_status.json adsb_history.json; do
  [[ -f "$DASH_DIR/$f" ]] || continue
  n=$((n+1)); python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$DASH_DIR/$f" 2>/dev/null || { bad=$((bad+1)); echo "  WARN $f kein gueltiges JSON"; }
done
echo "Statusdateien: $n vorhanden, $bad ungueltig"
fh3=1
for f in $FILES; do grep -q '# ===== funkHarden3' "$DASH_DIR/$f" || fh3=0; done
echo "OK guards funkHarden3=$fh3 funkHarden2=$(grep -q '# ===== funkHarden2:' "$DASH_DIR/dashboard.py" && echo 1 || echo 0) meshBootQuiet=$(grep -q '# ===== /meshBootQuiet' "$DASH_DIR/dashboard.py" && echo 1 || echo 0)"
echo "Backups: *.bak-fh3-$TS"
echo "OK funkHarden3 fertig: Watchdog leise + Port aus config.py, Statusdateien atomar, Status unter /api/funk/atomic"
echo "COMMIT $COMMIT_ARG funkHarden3=$fh3"
