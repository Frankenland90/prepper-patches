#!/bin/bash
set -eEuo pipefail
# perfWsgi (commit45): PERF-01 Webserver: waitress 3.0.2 statt Werkzeug-Entwicklungsserver - ein Prozess, 8 feste Arbeitsfaeden, Bind 0.0.0.0:PORT wie bisher; Start weiter nur ueber dashboard.py als Hauptprogramm (alle Hintergrundfaeden wie bisher genau einmal), app.run nur noch Rueckfall ohne waitress; toter _dt_debug-Haken bleibt unregistriert; kein Zugriffsprotokoll, App-Fehler ins Journal; Unit unveraendert (NotifyAccess=main passt, ein Prozess); verlangt waitress 3.0.2 im venv (Schritt A apply-pipwaitress.sh)
# Aufruf: bash /tmp/apply-perfwsgi.sh commit45 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 1898fde2aa91d066 (Stand nach pegelSplit commit44) oder perfWsgi schon drin (d0f34851146d65b5); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-perfwsgi-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/perfwsgi-apply
KEEP_LAST=3
KNOWN_D16="1898fde2aa91d066"      # dashboard.py vor perfWsgi (Basis: Stand nach pegelSplit commit44)
KNOWN_D16N="d0f34851146d65b5"             # dashboard.py nach perfWsgi (Ziel)
PHASE=vorher
ERRLN=""; ERRCMD=""
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
trap 'ec=$?; if [[ $ec -ne 0 && -n "$ERRLN" ]]; then echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE$([[ "$PHASE" == vorher ]] && echo " - es wurde nichts geaendert")"; fi' EXIT
stop() { echo "STOP: $1 - nichts geaendert"; exit 1; }
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then stop "Dashboard-Port unklar ($PORT)"; fi
if [[ "$PORT" == "8080" ]]; then stop "Port 8080 ist kiwix-serve, nicht das Dashboard"; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== perfWsgi apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): waitress 3.0.2 (8 Faeden, ein Prozess) statt Werkzeug, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="a9c4b2001eaff70ac575ac4023162df7c5b6b14491329f6593770cc79162704f"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher perfWsgi (generisch wie relStop). Aufruf: patch-pw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis/teilweise gepatcht. Schreibt nur ZIEL (nie QUELLE)."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E = g["%s_EDITS" % kind.upper()]
ANCH = g.get("%s_ANCHOR" % kind.upper())
s = open(src, encoding="utf-8").read()
B = None
if blk != "-":
    B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
name = {"dsh": "dashboard.py", "fh": "funk_health.py", "hw": "mesh_hang_watchdog.py", "pd": "prepper_docs.py"}[kind]
new_in = [s.count(n) >= 1 for o, n in E]
blk_in = (B is None) or (s.count(B) == 1)
if all(new_in) and blk_in:
    rest = s.replace(B, "", 1) if B else s
    ok = all(rest.count(n) == 1 for o, n in E) and (B is None or s.count(B.splitlines()[0]) == 1)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
if any(new_in) or (B is not None and B.splitlines()[0] in s):
    print("%s: %s teilweise vorhanden (%d von %d Stellen%s)" % (name, label, sum(new_in), len(E), ", Block da" if B and B.splitlines()[0] in s else "")); raise SystemExit(2)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if B is not None:
    if s.count(ANCH) != 1:
        print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
    i = s.index(ANCH)
    s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen%s %s" % (name, len(E), (" + Block" if B else ""), label))
MK_PAL_EOF
EXPECT_RAE="17020528416b862bc0b84d01b0c0581447cda782d92851be8eedaafec8584521"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer perfWsgi (commit45): Basis 1898fde2aa91d066 (Stand nach pegelSplit commit44); Block vor __main__, app.run -> _perf_serve(), toter _dt_debug-Haken wird nie registriert
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    ('    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False, threaded=True)  # sysBoot\n',
     '    _perf_serve()  # perfWsgi: waitress (8 Arbeitsfaeden, ein Prozess) statt app.run; ohne waitress app.run wie bisher\n'),
    ('@app.after_request\ndef _dt_debug(resp):\n',
     'def _dt_debug(resp):  # perfWsgi: Debug-Haken bleibt unregistriert (lief nie, da app.run vorher blockierte)\n'),
]
MK_RAE_EOF
EXPECT_RAB="f2103e5edfced0ad8f367736c97be66dd6064893ec4de02f9020c689165a6c32"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== perfWsgi: Webserver waitress statt Werkzeug-Entwicklungsserver (PERF-01) - ein Prozess, 8 feste Arbeitsfaeden, Bind 0.0.0.0:PORT wie bisher, Start nur im Hauptprogramm (alle Faeden wie bisher genau einmal), kein Zugriffsprotokoll, App-Fehler ins Journal; ohne waitress Start wie bisher mit Werkzeug; sendet nichts =====
import threading as _pw_th
import logging as _pw_logging
import time as _pw_time
import os as _pw_os
import re as _pw_re

PW_VERSION = "3.0.2"           # geprueft und vom Apply verlangt (apply-pipwaitress.sh)
PW_THREADS = 8                 # feste Zahl Arbeitsfaeden (waitress-0 .. waitress-7)
PW_HOST = "0.0.0.0"            # wie bisher app.run(host="0.0.0.0")
PW_QUEUE_PER_MIN = 1           # waitress-Warnung 'Task queue depth' hoechstens 1x je Minute ins Journal (mit Zaehler)
PW_CORE = ("relWatch", "relWatchBeat", "sysBootFirst", "weather_mesh_loop", "freq_loop", "alarm_loop", "teil2", "teil3", "teil4", "wxSlot", "uplinkDetect", "longArchive", "lzKick")  # sysBootFirst traegt nach dem ersten Voll-Update background_loop
_PW = {"server": None, "version": None, "err": None, "t_listen": None, "pid": None, "q_n": 0, "q_sup": 0}


def _pw_kw(port):
    """Einstellungen fuer waitress (geprueft im Selbsttest ohne Socket)."""
    return {"host": PW_HOST, "port": int(port), "threads": PW_THREADS, "ident": "waitress", "asyncore_use_poll": True,
            "connection_limit": 100, "channel_timeout": 120, "expose_tracebacks": False, "clear_untrusted_proxy_headers": True}


def _pw_norm(name):
    """Fadenname ohne laufende Nummer: 'Thread-7 (freq_loop)' -> '(freq_loop)', 'waitress-3' -> 'waitress'."""
    n = str(name or "")
    if _pw_re.fullmatch(r"waitress-\d+", n):
        return "waitress"
    m = _pw_re.fullmatch(r"(?:Thread|Dummy)-\d+ (\(.+\))", n)
    if m:
        return m.group(1)
    return n


def _pw_threads(names=None):
    """Zaehlt Faeden je Name (ohne laufende Nummer). Wirft nie."""
    try:
        if names is None:
            names = [t.name for t in _pw_th.enumerate() if t.is_alive()]
        cnt = {}
        for n in names:
            k = _pw_norm(n)
            cnt[k] = cnt.get(k, 0) + 1
        return cnt
    except Exception:
        return {}


class _PwQueueFilter:
    """waitress meldet volle Warteschlange als WARNING 'Task queue depth is N' - hoechstens per_min je Minute ins Journal, Rest gezaehlt."""
    _pw_queue = True

    def __init__(self, per_min=PW_QUEUE_PER_MIN, clock=None):
        self.per_min, self.clock = per_min, clock or _pw_time.monotonic
        self.lock = _pw_th.Lock()
        self.t0, self.n, self.sup = None, 0, 0

    def filter(self, record):
        try:
            if "queue depth" not in str(record.msg):
                return True
            with self.lock:
                _PW["q_n"] += 1
                now = self.clock()
                sup = 0
                if self.t0 is None or now - self.t0 >= 60:
                    sup, self.t0, self.n, self.sup = self.sup, now, 0, 0
                if self.n >= self.per_min:
                    self.sup += 1
                    _PW["q_sup"] += 1
                    return False
                self.n += 1
            record.msg = "perfWsgi: alle %d Arbeitsfaeden belegt, " % PW_THREADS + record.getMessage() + ("  [%d weitere in der letzten Minute]" % sup if sup else "")
            record.args = ()
            return True
        except Exception:
            return True


def _pw_status():
    from flask import jsonify
    try:
        c = _pw_threads()
        dup = sorted(k for k, v in c.items() if v > 1 and k != "waitress")
        sbt = globals().get("_SbTiming")
        return jsonify({"server": _PW["server"], "version": _PW["version"], "threads_cfg": PW_THREADS, "workers": c.get("waitress", 0), "pid": _pw_os.getpid(), "err": _PW["err"],
                        "listen_s": None if _PW["t_listen"] is None else int(_pw_time.time() - _PW["t_listen"]),
                        "core": {k: c.get(k, 0) for k in PW_CORE}, "doppelt": dup, "faeden_n": sum(c.values()), "faeden": c,
                        "wsgi_zeit": bool(sbt is not None and isinstance(app.wsgi_app, sbt)), "queue_warn": _PW["q_n"], "queue_warn_unterdrueckt": _PW["q_sup"]})
    except Exception as e:
        return jsonify({"error": str(e)[:120]})


def _perf_serve():
    """Ersetzt app.run(...) im Hauptprogramm: waitress im Hauptfaden (blockiert wie app.run). Fehlt waitress, Start wie bisher mit Werkzeug."""
    try:
        from waitress.server import create_server as _pw_create
        srv = _pw_create(app, **_pw_kw(PORT))
    except ImportError as e:
        _PW["server"], _PW["err"] = "werkzeug", "waitress fehlt: %s" % e
        print("perfWsgi FEHLER: waitress nicht ladbar (%s) - Start wie bisher mit Werkzeug (app.run)" % e, flush=True)
        app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False, threaded=True)
        return
    _PW["server"], _PW["pid"], _PW["t_listen"] = "waitress", _pw_os.getpid(), _pw_time.time()
    print("perfWsgi: waitress %s lauscht auf http://%s:%s (%d Arbeitsfaeden, ein Prozess, PID %d, kein Zugriffsprotokoll)" % (_PW["version"], PW_HOST, PORT, PW_THREADS, _pw_os.getpid()), flush=True)
    srv.run()


def _selftest_perfwsgi():
    import importlib.metadata as _pw_md
    from waitress.adjustments import Adjustments as _pw_adj
    v = _pw_md.version("waitress")
    _PW["version"] = v
    assert v == PW_VERSION, "waitress %s statt %s" % (v, PW_VERSION)
    kw = _pw_kw(PORT)
    a = _pw_adj(**kw)
    assert a.threads == PW_THREADS == 8 and a.asyncore_use_poll is True and a.expose_tracebacks is False, "Einstellungen"
    assert kw["host"] == "0.0.0.0" and kw["port"] == int(PORT), "Bind"
    assert _pw_norm("Thread-12 (freq_loop)") == "(freq_loop)" and _pw_norm("waitress-7") == "waitress" and _pw_norm("teil2") == "teil2" and _pw_norm("waitress-x") == "waitress-x"
    c = _pw_threads(["teil2", "waitress-0", "waitress-1", "Thread-3 (freq_loop)", "Thread-9 (freq_loop)"])
    assert c == {"teil2": 1, "waitress": 2, "(freq_loop)": 2}, c
    t = [0.0]
    f = _PwQueueFilter(per_min=1, clock=lambda: t[0])
    q0, s0 = _PW["q_n"], _PW["q_sup"]
    mk = lambda m, *x: _pw_logging.LogRecord("waitress.queue", _pw_logging.WARNING, "x", 1, m, x, None)
    r1 = mk("Task queue depth is %d", 1)
    assert f.filter(r1) is True and "Arbeitsfaeden belegt" in r1.getMessage() and "depth is 1" in r1.getMessage()
    assert f.filter(mk("Task queue depth is %d", 2)) is False and f.filter(mk("Task queue depth is %d", 3)) is False
    t[0] = 61.0
    r2 = mk("Task queue depth is %d", 4)
    assert f.filter(r2) is True and "2 weitere" in r2.getMessage()
    assert f.filter(mk("Exception while serving /x")) is True, "Fehler muessen durch"
    _PW["q_n"], _PW["q_sup"] = q0, s0
    return "perfWsgi ok (waitress %s, %d Arbeitsfaeden, ein Prozess, Bind %s:%s, Start nur im Hauptprogramm, kein Zugriffsprotokoll, Warteschlangen-Warnung hoechstens %d/min)" % (v, PW_THREADS, PW_HOST, PORT, PW_QUEUE_PER_MIN)


try:
    _PW_ST = _selftest_perfwsgi()
except Exception as _pw_e:
    _PW_ST = None
    _PW["err"] = "%s: %s" % (type(_pw_e).__name__, _pw_e)
    print("perfWsgi Selbsttest FEHLER (%s: %s)" % (type(_pw_e).__name__, _pw_e), flush=True)
try:
    _pw_ql = _pw_logging.getLogger("waitress.queue")
    if not any(getattr(x, "_pw_queue", False) for x in _pw_ql.filters):
        _pw_ql.addFilter(_PwQueueFilter())
    if "perfwsgi_status" not in app.view_functions:
        app.add_url_rule("/api/perfwsgi/status", "perfwsgi_status", _pw_status, methods=["GET"])
except Exception as _pw_e2:
    print("perfWsgi Selbsttest FEHLER (Status/Filter: %s)" % _pw_e2, flush=True)
if _PW_ST:
    print("perfWsgi aktiv: %s" % _PW_ST, flush=True)
# ===== /perfWsgi =====
MK_RAB_EOF
EXPECT_RAG="3d41bcb0074df886c4f40a489b8b48c200176ddc52846c70a673062e9f779209"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""Guard perfWsgi (nur dashboard.py: Block vor __main__, app.run -> _perf_serve(), _dt_debug ohne Registrierung). Aufruf:
  guard_pw.py revert NEU_VERZ ALT_VERZ BLOCK EDITS   -> ALT_VERZ/dashboard.py = NEU ohne perfWsgi (byte-genau)
  guard_pw.py check  ALT_VERZ NEU_VERZ BLOCK EDITS   -> Rueckbau = ALT, Lage, statische Regeln, Verhaltenstests (echtes waitress in Kindprozessen auf 127.0.0.1, echtes SIGTERM)
  RH_ALT=ALT_VERZ guard_pw.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest (jede Mutation muss check scheitern lassen)
Braucht flask und waitress 3.0.2 im ausfuehrenden Python (venv)."""
import ast, io, json, os, re, signal, socket, subprocess, sys, tempfile, threading, time, tokenize, urllib.request

CHILD_SRC = r'''# Kindprozess fuer guard_pw.py: fuehrt den perfWsgi-Block mit einer kleinen Flask-App aus (nur 127.0.0.1, freier Port), kein Netz nach aussen
import json, os, signal, sys, threading, time, socket
mode, out, bp, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
blk = open(bp, encoding="utf-8").read()
def w(x):
    with open(out, "a") as f:
        f.write(x + "\n")
if mode == "noimport":
    sys.modules["waitress"] = None
    sys.modules["waitress.server"] = None
    sys.modules["waitress.adjustments"] = None
if mode == "badver":
    import importlib.metadata as md
    _v = md.version
    md.version = lambda n: "3.0.1" if n == "waitress" else _v(n)
from flask import Flask
app = Flask("pwtest")
@app.route("/x")
def _x():
    time.sleep(0.4)
    return "x"
@app.route("/boom")
def _boom():
    raise RuntimeError("absichtlich")
g = {"__name__": "__main__", "app": app, "PORT": port}
exec(compile(blk, "perfWsgi-Block", "exec"), g)
if mode == "badver":
    w("badver_ende")
    sys.exit(0)
if mode == "twice":
    exec(compile(blk, "perfWsgi-Block", "exec"), g)
    import logging
    w(json.dumps({"filters": len(logging.getLogger("waitress.queue").filters), "rules": sum(1 for r in app.url_map.iter_rules() if r.endpoint == "perfwsgi_status")}))
    sys.exit(0)
w(json.dumps({"kw": g["_pw_kw"](5000)}))
g["PW_HOST"] = "127.0.0.1"
def _term(s, f):
    try:
        w("flush")
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)
signal.signal(signal.SIGTERM, _term)
if mode == "noimport":
    def fake_run(**k):
        w(json.dumps({"apprun": k}))
    app.run = fake_run
def ready():
    for i in range(200):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            w("ready")
            return
        except OSError:
            time.sleep(0.05)
if mode == "serve":
    threading.Thread(target=ready, name="pwReady", daemon=True).start()
w("main=%s" % (threading.current_thread() is threading.main_thread()))
g["_perf_serve"]()
w("zurueck")
'''
ANCH = '\n\nif __name__ == "__main__":\n'
FORBID = ("requests", "urlopen", "socket", "subprocess", "os.system", "send_", "mesh", "telegram", "open(", "systemctl", "eval(", "exec(", "__import__",
          "signal", "kill", "_exit", "sys.exit", "notify", "WATCHDOG", "fork", "Popen", "basicConfig", "setLevel", "global ", "serve(", "atexit")
APPRUN = 'app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False, threaded=True)'
KW = {"host": "0.0.0.0", "port": 5000, "threads": 8, "ident": "waitress", "asyncore_use_poll": True, "connection_limit": 100, "channel_timeout": 120,
      "expose_tracebacks": False, "clear_untrusted_proxy_headers": True}
OWN = re.compile(r"^(_pw_\w*|_PW\w*|PW_[A-Z_]+|_perf_serve|_selftest_perfwsgi|_PwQueueFilter|_pw_e2?)$")
rd = lambda p: open(p, encoding="utf-8").read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"]


def revert_text(s, B, E):
    B = B.rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block perfWsgi nicht genau einmal"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in E:
        assert s.count(n) == 1, "Stelle nicht genau einmal: %r" % n[:50]
        s = s.replace(n, o, 1)
    return s


def code_only(B):
    return " ".join(t.string for t in tokenize.generate_tokens(io.StringIO(B).readline) if t.type not in (tokenize.COMMENT, tokenize.STRING))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def get(port, path, t=10):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=t) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except Exception as e:
        return 0, str(e).encode(), {}


def run_child(mode, bp):
    with tempfile.TemporaryDirectory() as d:
        out, cp = os.path.join(d, "out"), os.path.join(d, "child.py")
        open(cp, "w", encoding="utf-8").write(CHILD_SRC)
        port = free_port()
        p = subprocess.Popen([sys.executable, cp, mode, out, bp, str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        R = {"port": port}
        lines = lambda: rd(out).splitlines() if os.path.exists(out) else []
        if mode == "serve":
            t1 = time.time() + 15
            while time.time() < t1 and "ready" not in lines() and p.poll() is None:
                time.sleep(0.05)
            if "ready" in lines():
                time.sleep(0.3)
                c, b, h = get(port, "/api/perfwsgi/status")
                R["st0"] = json.loads(b) if c == 200 else None
                R["server_hdr"] = h.get("Server")
                res = []
                ths = [threading.Thread(target=lambda: res.append(get(port, "/x")[0])) for _ in range(24)]
                for t in ths:
                    t.start()
                time.sleep(0.6)
                c, b, h = get(port, "/api/perfwsgi/status")
                R["st1"] = json.loads(b) if c == 200 else None
                for t in ths:
                    t.join(20)
                R["load"] = sorted(res)
                R["boom"] = get(port, "/boom")[0]
                c, b, h = get(port, "/api/perfwsgi/status")
                R["st2"] = json.loads(b) if c == 200 else None
                t0 = time.monotonic()
                p.send_signal(signal.SIGTERM)
                try:
                    p.wait(6)
                except subprocess.TimeoutExpired:
                    p.kill()
                R["dur"] = time.monotonic() - t0
        try:
            so = p.communicate(timeout=15)[0]
        except subprocess.TimeoutExpired:
            p.kill()
            so = p.communicate()[0]
        R["rc"], R["lines"], R["so"] = p.returncode, lines(), so
        return R


def check(alt, neu, bp, ep):
    A, N, B = rd(alt), rd(neu), rd(bp)
    E = load_edits(ep)
    n = 0
    fails = []

    def ok(c, msg):
        nonlocal n
        n += 1
        if not c:
            fails.append(msg)
    try:
        ok(revert_text(N, B, E) == A, "Rueckbau ungleich Basis")
    except AssertionError as e:
        ok(False, "Rueckbau: %s" % e)
    ok("perfWsgi" not in A and "_perf_serve" not in A, "Basis enthaelt perfWsgi schon")
    ok(A.count(APPRUN) == 1 and B.count(APPRUN) == 1 and N.count(APPRUN) == 1, "app.run nicht genau einmal (nur noch als Rueckfall im Block, Argumente wie bisher)")
    Bs = B.rstrip("\n")
    ok(N.count("\n\n" + Bs + ANCH) == 1, "Block nicht direkt vor __main__")
    ok("# ===== /pegelSplit =====" in N and N.index("# ===== /pegelSplit =====") < N.index("# ===== perfWsgi:"), "Block nicht nach pegelSplit")
    ok(B.startswith("# ===== perfWsgi:") and B.rstrip().endswith("# ===== /perfWsgi ====="), "Marker")
    try:
        TN, TA, TB = ast.parse(N), ast.parse(A), ast.parse(B)
        ok(True, "")
    except SyntaxError as e:
        return n + 1, fails + ["Syntax: %s" % e]
    mains = [s for s in TN.body if isinstance(s, ast.If) and ast.unparse(s.test) == "__name__ == '__main__'"]
    mainA = [s for s in TA.body if isinstance(s, ast.If) and ast.unparse(s.test) == "__name__ == '__main__'"]
    ok(len(mains) == 1 and len(mainA) == 1, "__main__-Block nicht genau einmal")
    if mains and mainA:
        mb, ma = mains[0].body, mainA[0].body
        ok(ast.unparse(mb[-1]) == "_perf_serve()" and ast.unparse(ma[-1]) == ast.unparse(ast.parse(APPRUN)), "letzte Anweisung im Hauptprogramm nicht _perf_serve()")
        ok([ast.dump(x) for x in mb[:-1]] == [ast.dump(x) for x in ma[:-1]], "Hauptprogramm sonst veraendert")
        ok(sum(1 for x in ast.walk(mains[0]) if isinstance(x, ast.Call) and ast.unparse(x.func) == "_perf_serve") == 1, "_perf_serve nicht genau einmal")
        ok(TN.body.index(mains[0]) > max(i for i, s in enumerate(TN.body) if isinstance(s, ast.FunctionDef) and s.name == "_perf_serve"), "_perf_serve nach __main__ definiert")
    calls = [x for x in ast.walk(TN) if isinstance(x, ast.Call) and ast.unparse(x.func) == "_perf_serve"]
    ok(len(calls) == 1, "_perf_serve() ausserhalb des Hauptprogramms")
    dd = [s for s in TN.body if isinstance(s, ast.FunctionDef) and s.name == "_dt_debug"]
    ok(len(dd) == 1 and not dd[0].decorator_list, "_dt_debug wird wieder registriert")
    ok(not re.search(r"after_request\s*\(\s*_dt_debug", N) and "_dt_debug" not in B, "_dt_debug anderswo registriert")
    ok(len([s for s in TN.body if isinstance(s, ast.FunctionDef) and s.name == "_dt_debug"]) == 1, "_dt_debug doppelt")
    C = code_only(B)
    for f in FORBID:
        ok(f not in C, "verboten im Block: " + f)
    defsA = set()
    for s in TA.body:
        for t in ast.walk(s):
            if isinstance(t, (ast.FunctionDef, ast.ClassDef)):
                defsA.add(t.name)
            elif isinstance(t, ast.Name) and isinstance(t.ctx, ast.Store):
                defsA.add(t.id)
            elif isinstance(t, ast.alias):
                defsA.add(t.asname or t.name.split(".")[0])
    own = set()
    for s in TB.body:
        if isinstance(s, (ast.FunctionDef, ast.ClassDef)):
            own.add(s.name)
        elif isinstance(s, (ast.Import, ast.ImportFrom)):
            own |= {a.asname or a.name for a in s.names}
        elif isinstance(s, ast.Assign):
            own |= {t.id for t in s.targets if isinstance(t, ast.Name)}
        elif isinstance(s, ast.Try):
            for t in ast.walk(s):
                if isinstance(t, ast.Assign):
                    own |= {x.id for x in t.targets if isinstance(x, ast.Name)}
                if isinstance(t, ast.ExceptHandler) and t.name:
                    own.add(t.name)
        elif not isinstance(s, (ast.If, ast.Expr)):
            own.add("?%s" % type(s).__name__)
    bad = sorted(x for x in own if not OWN.match(x) or x in defsA)
    ok(not bad, "Block bindet fremde/vorhandene Namen: %s" % bad)
    ok(re.search(r'^PW_THREADS = 8\b', B, re.M) and re.search(r'^PW_HOST = "0\.0\.0\.0"', B, re.M) and re.search(r'^PW_VERSION = "3\.0\.2"', B, re.M), "Grundwerte (8 Faeden, 0.0.0.0, 3.0.2) geaendert")
    ok(C.count("_pw_create (") == 1 and C.count("srv . run ( )") == 1, "waitress-Start nicht genau einmal")
    T = {}
    ths = [threading.Thread(target=lambda m=m: T.__setitem__(m, run_child(m, bp))) for m in ("serve", "noimport", "badver", "twice")]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    R = T["serve"]
    L, so = R["lines"], R["so"]
    kw = json.loads(L[0])["kw"] if L and L[0].startswith("{") else None
    ok(kw == KW, "Einstellungen waitress: %r" % kw)
    ok("main=True" in L and "ready" in L, "serve: nicht im Hauptfaden gestartet/keine Antwort (%r)" % L[:4])
    s0, s1, s2 = R.get("st0"), R.get("st1"), R.get("st2")
    ok(bool(s0) and s0.get("server") == "waitress" and s0.get("version") == "3.0.2" and s0.get("workers") == 8 and s0.get("threads_cfg") == 8, "Status vor Last: %r" % (s0 and {k: s0.get(k) for k in ("server", "version", "workers")}))
    ok(bool(s0) and s0.get("faeden", {}).get("MainThread") == 1 and s0.get("doppelt") == [], "Fadenliste: %r" % (s0 and s0.get("faeden")))
    ok(bool(s1) and bool(s2) and s1.get("faeden_n") == s2.get("faeden_n") == s0.get("faeden_n") - (1 if s0.get("faeden", {}).get("pwReady") else 0) and s1.get("workers") == s2.get("workers") == 8,
       "Fadenzahl unter Last nicht fest: %r" % [x and x.get("faeden_n") for x in (s0, s1, s2)])
    ok(R.get("load") == [200] * 24, "Last: %r" % R.get("load"))
    ok(R.get("boom") == 500 and "RuntimeError: absichtlich" in so, "App-Fehler nicht ins Journal (500 + Traceback)")
    ok(R.get("server_hdr") == "waitress", "Server-Kopf %r" % R.get("server_hdr"))
    ok("perfWsgi: waitress 3.0.2 lauscht auf http://127.0.0.1:%d (8 Arbeitsfaeden, ein Prozess" % R["port"] in so, "Journalzeile 'lauscht' fehlt")
    ok("perfWsgi aktiv: perfWsgi ok (waitress 3.0.2, 8 Arbeitsfaeden" in so, "Journalzeile 'aktiv' fehlt")
    ok(so.count("perfWsgi: alle 8 Arbeitsfaeden belegt") == 1 and "queue depth" in so.lower(), "Warteschlangen-Warnung nicht genau 1x (gedrosselt): %d" % so.count("Arbeitsfaeden belegt"))
    ok(not re.search(r'"GET /x', so) and "GET /x" not in so and "Serving on" not in so and "WARNING:" not in so, "Zugriffsprotokoll/basicConfig aktiv")
    ok(R["rc"] == -15 and "flush" in L and R.get("dur") is not None and R["dur"] < 3 and "zurueck" not in L, "SIGTERM: rc %r, %r, %.1f s" % (R["rc"], L[-3:], R.get("dur") or -1))
    R = T["noimport"]
    ar = [json.loads(x)["apprun"] for x in R["lines"] if x.startswith('{"apprun"')]
    ok(ar == [{"host": "0.0.0.0", "port": R["port"], "debug": False, "use_reloader": False, "threaded": True}] and "zurueck" in R["lines"], "ohne waitress kein app.run wie bisher: %r" % ar)
    ok("perfWsgi FEHLER: waitress nicht ladbar" in R["so"] and "perfWsgi Selbsttest FEHLER" in R["so"] and "perfWsgi aktiv" not in R["so"], "ohne waitress: Meldungen")
    R = T["badver"]
    ok("perfWsgi Selbsttest FEHLER (AssertionError: waitress 3.0.1 statt 3.0.2)" in R["so"] and "perfWsgi aktiv" not in R["so"] and R["rc"] == 0, "falsche waitress-Version nicht erkannt")
    R = T["twice"]
    tw = json.loads(R["lines"][0]) if R["lines"] else None
    ok(tw == {"filters": 1, "rules": 1} and R["rc"] == 0 and "FEHLER" not in R["so"] and R["so"].count("perfWsgi aktiv") == 2, "zweimal ausgefuehrt: %r %r" % (tw, R["so"][-200:]))
    return n, fails


MUT = [
    ("B", "PW_THREADS = 8 ", "PW_THREADS = 16 "),
    ("B", 'PW_HOST = "0.0.0.0"', 'PW_HOST = "127.0.0.1"'),
    ("B", "use_reloader=False, threaded=True)\n        return", "use_reloader=False, threaded=False)\n        return"),
    ("B", "    srv.run()\n", "    pass\n"),
    ("B", "    except ImportError as e:\n", "    except OSError as e:\n"),
    ("B", "        _pw_ql.addFilter(_PwQueueFilter())\n", "        pass\n"),
    ("B", "                if self.n >= self.per_min:", "                if False:"),
    ("B", '    assert v == PW_VERSION, "waitress %s statt %s" % (v, PW_VERSION)\n', ""),
    ("B", '"asyncore_use_poll": True', '"asyncore_use_poll": False'),
    ("B", "import re as _pw_re\n", "import re as _pw_re\nimport subprocess as _pw_sp\n"),
    ("B", '    if "perfwsgi_status" not in app.view_functions:\n', "    if True:\n"),
    ("B", '"expose_tracebacks": False', '"expose_tracebacks": True'),
    ("B", '"channel_timeout": 120', '"channel_timeout": 5'),
    ("B", '    _PW["server"], _PW["pid"], _PW["t_listen"] = "waitress",', '    _PW["server"], _PW["pid"], _PW["t_listen"] = "?",'),
    ("B", 'r"waitress-\\d+"', 'r"waitress\\d+"'),
    ("B", '    if not any(getattr(x, "_pw_queue", False) for x in _pw_ql.filters):\n', "    if True:\n"),
    ("B", "        srv = _pw_create(app, **_pw_kw(PORT))\n", "        srv = _pw_create(app, **_pw_kw(PORT))\n        import logging; logging.basicConfig()\n"),
    ("B", '    print("perfWsgi: waitress %s lauscht', '    0 and print("perfWsgi: waitress %s lauscht'),
    ("B", "    from flask import jsonify\n    try:\n        c = _pw_threads()", "    from flask import jsonify\n    try:\n        c = _pw_threads([])"),
    ("B", "            if \"queue depth\" not in str(record.msg):\n                return True\n", "            return True\n"),
    ("B", "PW_QUEUE_PER_MIN = 1 ", "PW_QUEUE_PER_MIN = 100 "),
    ("B", "_PW = {", "app = None\n_PW = {"),
    ("B", "    srv.run()\n", "    _pw_th.Thread(target=srv.run, daemon=True).start()\n"),
    ("N", "def _dt_debug(resp):  # perfWsgi", "@app.after_request\ndef _dt_debug(resp):  # perfWsgi"),
    ("N", "    _perf_serve()  # perfWsgi", "    _perf_serve()\n    _perf_serve()  # perfWsgi"),
    ("N", "    load_wbi_history()\n", ""),
    ("N", "\n\nif __name__ == \"__main__\":\n    # sourceWatch final", "\n_perf_serve()\n\nif __name__ == \"__main__\":\n    # sourceWatch final"),
    ("N", "\n\nif __name__ == \"__main__\":\n    # sourceWatch final", "\napp.after_request(_dt_debug)\n\nif __name__ == \"__main__\":\n    # sourceWatch final"),
]


def mutate(alt, neu, bp, ep):
    B, N = rd(bp), rd(neu)
    Bs = B.rstrip("\n")
    miss = 0
    for i, (where, o, nw) in enumerate(MUT, 1):
        if where == "B":
            cnt = B.count(o)
        else:
            cnt = N.replace(Bs, "", 1).count(o)
        if cnt != 1:
            print("UEBERSEHEN Mutation %d Stelle nicht eindeutig (%d): %r" % (i, cnt, o[:60]))
            miss += 1
            continue
        if where == "B":
            B2 = B.replace(o, nw, 1)
            N2 = N.replace(Bs, B2.rstrip("\n"), 1)
        else:
            B2 = B
            i0 = N.index(Bs)
            pre, post = N[:i0], N[i0 + len(Bs):]
            N2 = (pre.replace(o, nw, 1) + Bs + post) if o in pre else (pre + Bs + post.replace(o, nw, 1))
        with tempfile.TemporaryDirectory() as d:
            bp2, np2 = os.path.join(d, "blk.py"), os.path.join(d, "dash.py")
            open(bp2, "w", encoding="utf-8").write(B2)
            open(np2, "w", encoding="utf-8").write(N2)
            try:
                n, f = check(alt, np2, bp2, ep)
            except Exception as e:
                f = ["Ausnahme %s: %s" % (type(e).__name__, e)]
        print("%s Mutation %2d: %s" % ("OK" if f else "UEBERSEHEN", i, (f[0] if f else o.strip()[:60])[:110]))
        miss += 0 if f else 1
    print("%s Mutationstest perfWsgi: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", len(MUT), miss))
    return miss


if __name__ == "__main__":
    cmd = sys.argv[1]
    dp = lambda d: os.path.join(d, "dashboard.py") if os.path.isdir(d) else d
    if cmd == "revert":
        open(dp(sys.argv[3]), "w", encoding="utf-8").write(revert_text(rd(dp(sys.argv[2])), rd(sys.argv[4]), load_edits(sys.argv[5])))
        print("OK Rueckbau perfWsgi byte-genau erzeugt")
    elif cmd == "check":
        n, f = check(dp(sys.argv[2]), dp(sys.argv[3]), sys.argv[4], sys.argv[5])
        for x in f:
            print("FEHLER", x)
        print("%s Guard perfWsgi: %d Pruefungen, %d Fehler (Rueckbau byte-genau, Lage vor __main__, Hauptprogramm nur app.run -> _perf_serve, _dt_debug unregistriert, kein Netz/Senden, echtes waitress auf 127.0.0.1: 8 Faeden fest unter Last, App-Fehler ins Journal, ohne Zugriffsprotokoll, SIGTERM; ohne waitress app.run wie bisher)" % ("OK" if not f else "FEHLER", n, len(f)))
        sys.exit(1 if f else 0)
    elif cmd == "mutate":
        sys.exit(1 if mutate(dp(os.environ["RH_ALT"]), dp(sys.argv[2]), sys.argv[3], sys.argv[4]) else 0)
MK_RAG_EOF
PPK="$W/patch.py"; RED="$W/edits.py"; RBK="$W/blk.py"; RGD="$W/guard.py"
for x in "$EXPECT_PAL $PPK" "$EXPECT_RAE $RED" "$EXPECT_RAB $RBK" "$EXPECT_RAG $RGD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Patcher, Stellen, Block, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach pegelSplit commit44" "$KNOWN_D16N" "perfWsgi schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      perfWsgi passt nur auf den Stand Stand nach pegelSplit commit44 (dashboard.py 1898fde2aa91d066). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- perfWsgi: waitress 3.0.2 muss im venv sein (Schritt A: apply-pipwaitress.sh) - sonst STOP ----
[[ "$VPY" == "$DASH_DIR/venv/bin/python" ]] || stop "venv-Python $DASH_DIR/venv/bin/python fehlt - perfWsgi braucht waitress 3.0.2 im venv"
PWV=$("$VPY" -c 'import sys, os, importlib.metadata as m, waitress.server, waitress.adjustments
v = m.version("waitress"); f = os.path.realpath(waitress.server.__file__); p = os.path.realpath(sys.prefix)
print(v if f.startswith(p + os.sep) else "ausserhalb des venv: %s %s" % (v, f))' 2>/dev/null || true)
[[ "$PWV" == 3.0.2 ]] || stop "waitress 3.0.2 ist nicht im venv ($([[ -z "$PWV" ]] && echo "nicht installiert/nicht ladbar" || echo "gefunden: $PWV")) - zuerst Schritt A: bash /tmp/apply-pipwaitress.sh"
echo "OK waitress 3.0.2 im venv ($VPY)"
[[ -f "$DASH_DIR/lage_pages.py" ]] || stop "lage_pages.py fehlt (Stand nach pegelSplit erwartet)"
PWL=$(s16 "$DASH_DIR/lage_pages.py")
[[ "$PWL" == 7f9fc0cf17d52644 ]] || stop "lage_pages.py sha16 $PWL statt 7f9fc0cf17d52644 (Stand nach pegelSplit) - bitte diese Ausgabe an Grok schicken"
echo "OK lage_pages.py 7f9fc0cf17d52644 (Stand nach pegelSplit, wird nicht angefasst)"
# ---- perfWsgi: Unit nur lesen - ExecStart muss dashboard.py als Hauptprogramm starten; keine Unit-Aenderung ----
PWX=$(systemctl show -p ExecStart --value prepper-dashboard 2>/dev/null | tr '\n' ' ' || true)
if [[ "$PWX" == *dashboard.py* ]]; then
  [[ "$PWX" == *gunicorn* || "$PWX" == *waitress-serve* ]] && stop "ExecStart startet schon einen WSGI-Server ($(echo "$PWX" | cut -c1-120)) - perfWsgi erwartet python dashboard.py"
  echo "OK ExecStart startet dashboard.py als Hauptprogramm (Unit bleibt unveraendert)"
else
  echo "HINWEIS ExecStart nicht lesbar ($(echo "$PWX" | cut -c1-80)) - perfWsgi aendert die Unit nicht; Pruefung nach dem Neustart ueber die Journalzeile 'lauscht'"
fi
echo "Info: Unit unveraendert - Type=$(systemctl show -p Type --value prepper-dashboard 2>/dev/null || echo ?), NotifyAccess=$(systemctl show -p NotifyAccess --value prepper-dashboard 2>/dev/null || echo ?), WatchdogUSec=$(systemctl show -p WatchdogUSec --value prepper-dashboard 2>/dev/null || echo ?): ein Prozess, Herzschlag weiter aus dem Hauptprozess"
# ---- perfWsgi: Neustart-Sperre HH:55-HH:04 (jede Stunde, Berlin-Zeit); geprueft jetzt und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${PW_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$PW_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Sperre: perfWsgi ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - zwischen HH:55 und HH:04 wird prepper-dashboard nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04 ($1)"; fi; }
rscheck "Vorpruefung"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" perfWsgi dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer perfWsgi nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" perfWsgi dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: perfWsgi im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne perfWsgi ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard perfWsgi meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" nice -n 10 "$VPY" "$RGD" mutate "$W/neu" "$RBK" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^aequivalent|^OK" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local i; for i in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
pcode() { code -X POST "$@"; }
PILAT0=$(tmed "$B/pi")
echo "Zustand vorher: /pi antwortet im Median in ${PILAT0} s"
# ---- perfWsgi: Zustand vorher (nur Lesen): Server-Kopf, Faeden des Hauptprozesses, ueberwachte Faeden ----
pwhdr() { "${CURL[@]}" -D - -o /dev/null "$B/api/time" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="server"{print $2}' | head -1; }
pwmp() { systemctl show -p MainPID --value prepper-dashboard 2>/dev/null || echo 0; }
pwthr() { awk '/^Threads:/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }
pwrel() { "${CURL[@]}" "$B/api/sysboot/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin).get("rel") or {}
except Exception:
    d = {}
t = d.get("threads") or {}; w = d.get("wd") or {}
print(" ".join("%s=%s" % (k, (v or {}).get("state")) for k, v in sorted(t.items())) or "-", "|", "sock=%s beats=%s armed=%s probe_age=%s" % (w.get("sock"), w.get("beats"), w.get("armed"), w.get("probe_age_s")))' 2>/dev/null || echo "- | -"; }
PWS0=$(pwhdr); PWMP0=$(pwmp); PWT0=$(pwthr "$PWMP0"); PWR0=$(pwrel)
echo "Zustand vorher: Server-Kopf '${PWS0:-?}', Hauptprozess PID $PWMP0 mit $PWT0 Faeden (Werkzeug: je Anfrage ein eigener Faden), relWatch: $PWR0"
rscheck "vor dem Neustart"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: perfWsgi ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-perfwsgi-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG perfwsgi=dry fertig"
  exit 0
fi
if [[ "$NEED_D" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "perfWsgi|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-perfwsgi-$TS" ]] && cp -a "$F.bak-perfwsgi-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-perfwsgi-$TS" ]] && { cmp -s "$F" "$F.bak-perfwsgi-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK perfWsgi schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-perfwsgi-$TS"
  { ls -1t "$F.bak-perfwsgi-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-perfwsgi-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-perfwsgi-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'perfWsgi aktiv' im Journal ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
fi
PHASE=Pruefung
# ---------- 5) Pruefung ----------
for p in "${PAGES[@]}" "${APIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rbx "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs antworten wie vorher (alle $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); P1=$(grep -o 'Projektbeschreibung' "$W/pi.html" | wc -l || true)
[[ "$R1" -ge 1 && "$P1" -ge 1 ]] || rbx "/pi liefert Sicherung/Projektbeschreibung nicht mehr (doPrepperRestore ${R1}x, Projektbeschreibung ${P1}x)"
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; perfWsgi aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- perfWsgi: waitress aktiv, ein Prozess, 8 feste Arbeitsfaeden, Hintergrundfaeden je genau einmal, Watchdog/relWatch, kein Zugriffsprotokoll ----
PWM=$(grep -c "^# ===== perfWsgi:" "$F" || true); PWA=$(grep -c "^    _perf_serve()  # perfWsgi" "$F" || true); PWD=$(grep -c "^@app.after_request$" "$F" || true)
[[ "$PWM" == 1 && "$PWA" == 1 ]] && echo "OK Marker perfWsgi 1x, Start ueber _perf_serve() 1x im Hauptprogramm" || rbx "dashboard.py perfWsgi falsch (Marker ${PWM}x, _perf_serve ${PWA}x)"
PWS1=$(pwhdr)
[[ "$PWS1" == waitress ]] && echo "OK Server-Kopf jetzt 'waitress' (vorher '${PWS0:-?}')" || rbx "Server-Kopf '$PWS1' statt waitress - Dashboard laeuft nicht unter waitress"
pwst() { "${CURL[@]}" "$B/api/perfwsgi/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER kein JSON"); sys.exit(0)
c = d.get("core") or {}
print(d.get("server"), d.get("version"), d.get("workers"), d.get("pid"), d.get("faeden_n"), c.get("relWatch"), c.get("sysBootFirst"), c.get("weather_mesh_loop"), c.get("freq_loop"), c.get("alarm_loop"), c.get("relWatchBeat"), "".join(d.get("doppelt") or []) or "-", d.get("wsgi_zeit"),
      " ".join("%s=%s" % (k, v) for k, v in sorted(c.items())))' 2>/dev/null || echo "FEHLER"; }
pwwd() { "${CURL[@]}" "$B/api/sysboot/status" 2>/dev/null | python3 -c 'import json, sys
try:
    w = (json.load(sys.stdin).get("rel") or {}).get("wd") or {}
except Exception:
    w = {}
print(w.get("sock"), w.get("beats"), w.get("armed"), w.get("probe_age_s"), w.get("fail_s"), w.get("trigger_sent"))' 2>/dev/null || echo "? ? ? ? ? ?"; }
# gemeinsame Wartezeit: hoechstens 60x3 s bis erstes Voll-Update fertig, Hintergrundfaeden laufen und relWatch die eigene Pruefung bestanden hat
PWW=0; PWOK=0
while [[ "$PWW" -lt 60 ]]; do
  read -r S_SRV S_VER S_WRK S_PID S_N S_RW S_BG S_WM S_FQ S_AL S_BEAT S_DUP S_WZ S_CORE <<< "$(pwst)"
  read -r W_SOCK W_BEATS W_ARMED W_PROBE W_FAIL W_TRIG <<< "$(pwwd)"
  if [[ "$S_WM" == 1 && "$S_FQ" == 1 && "$S_AL" == 1 && "$W_ARMED" == True && "$W_PROBE" != None ]]; then PWOK=1; break; fi
  [[ "$S_WM" == 1 && "$S_FQ" == 1 && "$S_AL" == 1 && "$W_SOCK" != True && "$PWW" -ge 10 ]] && { PWOK=2; break; }
  PWW=$(( PWW + 1 )); sleep 3
done
PWMP1=$(pwmp)
echo "perfWsgi Status: Server $S_SRV $S_VER, Arbeitsfaeden $S_WRK, PID $S_PID (MainPID $PWMP1), Faeden gesamt $S_N, wsgi-Zeitmessung $S_WZ; ueberwacht: $S_CORE (gewartet $(( PWW * 3 )) s)"
[[ "$S_SRV" == waitress && "$S_VER" == 3.0.2 && "$S_WRK" == 8 ]] || rbx "perfWsgi Status falsch (Server $S_SRV $S_VER, Arbeitsfaeden $S_WRK statt 8)"
[[ "$S_PID" == "$PWMP1" ]] && echo "OK ein Prozess: waitress laeuft im systemd-Hauptprozess (PID $PWMP1) - NotifyAccess=main passt" || rbx "waitress-PID $S_PID ist nicht der Hauptprozess $PWMP1"
PWCH=$(pgrep -P "$PWMP1" -f dashboard.py 2>/dev/null | wc -l || true)
[[ "${PWCH:-0}" == 0 ]] && echo "OK keine weiteren Dashboard-Prozesse (keine Kindprozesse mit dashboard.py)" || rbx "$PWCH Kindprozess(e) mit dashboard.py"
PWLS=$(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | sort -u | tr '\n' ' ' || true)
if [[ -n "$PWLS" ]]; then [[ "$PWLS" == "pid=$PWMP1 " ]] && echo "OK Port $PORT: genau ein lauschender Prozess (PID $PWMP1)" || rbx "Port $PORT: lauschende Prozesse $PWLS (erwartet nur $PWMP1)"; else echo "HINWEIS Port $PORT: lauschender Prozess nicht lesbar (ss ohne Rechte) - Status-PID oben geprueft"; fi
[[ "$S_BG" == 1 && "$S_WM" == 1 && "$S_FQ" == 1 && "$S_AL" == 1 && "$S_RW" == 1 ]] || rbx "Hintergrundfaeden nicht je genau einmal (sysBootFirst/background_loop=$S_BG weather_mesh_loop=$S_WM freq_loop=$S_FQ alarm_loop=$S_AL relWatch=$S_RW) nach $(( PWW * 3 )) s"
[[ "$S_DUP" == "-" ]] && echo "OK Fadenliste: jeder Faden hoechstens einmal (sysBootFirst mit background_loop, weather_mesh_loop, freq_loop, alarm_loop, relWatch je 1; doppelt: keiner)" || rbx "Faeden doppelt: $S_DUP"
echo "$S_CORE" | tr ' ' '\n' | grep -E '=([2-9]|[1-9][0-9])$' >/dev/null && rbx "ueberwachter Faden mehrfach: $S_CORE"
[[ "$S_WZ" == True ]] && echo "OK sysBoot-WSGI-Zeitmessung haengt weiter vor der App (langsame Anfragen > 3 s ins Journal)" || rbx "sysBoot-WSGI-Zeitmessung nicht aktiv ($S_WZ)"
if [[ "$W_SOCK" == True ]]; then
  [[ "$S_BEAT" == 1 ]] || rbx "relWatchBeat (systemd-Herzschlag) laeuft nicht genau einmal ($S_BEAT)"
  [[ "$PWOK" == 1 ]] && echo "OK relWatch: Aufseher scharf, eigene Pruefung /api/time ueber waitress bestanden (vor ${W_PROBE} s), Herzschlag ${W_BEATS}x" || echo "HINWEIS relWatch: erstes Voll-Update/Pruefung nach $(( PWW * 3 )) s noch nicht fertig (scharf=$W_ARMED, Pruefung=$W_PROBE) - spaeter: curl -s $B/api/sysboot/status"
else
  echo "HINWEIS kein systemd-Watchdog in dieser Umgebung (NOTIFY_SOCKET/WATCHDOG_USEC fehlen) - Herzschlag nicht pruefbar"
fi
# Last: 48 parallele Anfragen; Fadenzahl des Hauptprozesses muss fest bleiben (Werkzeug: +1 Faden je Anfrage)
PWT1=$(pwthr "$PWMP1"); PWTM=$PWT1
seq 1 48 | sed "s#.*#$B/api/time#" | sed '1~6s#/api/time$#/pi#' > "$W/pwurls.txt"
( xargs -P 24 -n 1 "${CURL[@]}" -o /dev/null -w "%{http_code}\n" < "$W/pwurls.txt" > "$W/pwload.txt" 2>/dev/null ) &
PWLP=$!
while kill -0 "$PWLP" 2>/dev/null; do t=$(pwthr "$PWMP1"); [[ "$t" -gt "$PWTM" ]] && PWTM=$t; sleep 0.2; done
wait "$PWLP" || true
PWT2=$(pwthr "$PWMP1"); PWLOK=$(grep -c '^200$' "$W/pwload.txt" || true)
echo "Last: $PWLOK/48 Antworten 200; Faeden Hauptprozess vor/max waehrend/nach: $PWT1/$PWTM/$PWT2 (vorher unter Werkzeug in Ruhe $PWT0)"
[[ "$PWLOK" == 48 ]] || rbx "unter Last nur $PWLOK/48 Antworten mit 200"
[[ $(( PWTM - PWT1 )) -le 3 ]] && echo "OK Fadenzahl fest: unter 48 parallelen Anfragen hoechstens +$(( PWTM - PWT1 )) (Arbeitsfaeden bleiben 8)" || rbx "Fadenzahl waechst unter Last ($PWT1 -> $PWTM)"
read -r S_SRV S_VER S_WRK S_PID S_N S_RW S_BG S_WM S_FQ S_AL S_BEAT S_DUP S_WZ S_CORE <<< "$(pwst)"
[[ "$S_WRK" == 8 && "$S_DUP" == "-" ]] && echo "OK nach der Last: 8 Arbeitsfaeden, keine doppelten Faeden" || rbx "nach der Last: Arbeitsfaeden $S_WRK, doppelt $S_DUP"
if [[ "$W_SOCK" == True ]]; then
  read -r W2_SOCK W2_BEATS W2_ARMED W2_PROBE W2_FAIL W2_TRIG <<< "$(pwwd)"
  [[ "$W2_TRIG" == False ]] || rbx "relWatch hat einen Neustart angefordert ($W2_TRIG)"
  [[ "$W2_BEATS" =~ ^[0-9]+$ && "$W_BEATS" =~ ^[0-9]+$ && "$W2_BEATS" -ge "$W_BEATS" && "$W2_BEATS" -ge 1 ]] && echo "OK systemd-Herzschlag laeuft (${W2_BEATS}x seit Start, aus PID $PWMP1)" || rbx "systemd-Herzschlag laeuft nicht (${W_BEATS} -> ${W2_BEATS})"
fi
if [[ "$RESTARTED_D" == 1 ]]; then
  PWJ=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
  if [[ -z "$(echo "$PWJ" | tr -d ' \n')" ]]; then echo "HINWEIS Journal nicht lesbar - Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep perfWsgi"
  else
    PWJL=$(echo "$PWJ" | grep -F "perfWsgi: waitress 3.0.2 lauscht auf http://0.0.0.0:$PORT (8 Arbeitsfaeden, ein Prozess" | tail -1 || true)
    [[ -n "$PWJL" ]] && echo "OK Journal: $(echo "$PWJL" | cut -c1-160)" || rbx "Journal ohne 'perfWsgi: waitress 3.0.2 lauscht auf http://0.0.0.0:$PORT'"
    PWAC=$(echo "$PWJ" | grep -cE '"(GET|POST|HEAD) /[^"]* HTTP/1\.[01]" [0-9]{3}' || true)
    [[ "${PWAC:-0}" == 0 ]] && echo "OK kein Zugriffsprotokoll im Journal (trotz $PWLOK Lastanfragen)" || echo "HINWEIS $PWAC Zugriffszeile(n) im Journal seit Neustart"
    echo "$PWJ" | grep -qE "relStop aktiv: .*SIGTERM-Haken aktiv" && echo "OK relStop: SIGTERM-Haken unter waitress aktiv (Hauptfaden)" || rbx "relStop ohne SIGTERM-Haken unter waitress"
  fi
fi
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep -E perfWsgi"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "perfWsgi aktiv: perfWsgi ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'perfWsgi aktiv: perfWsgi ok' ($(echo "$JD" | grep -F perfWsgi | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'perfWsgi Selbsttest FEHLER|perfWsgi FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'perfWsgi Selbsttest FEHLER|perfWsgi FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein perfWsgi-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)")"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"))" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-perfwsgi-$TS" ]] && echo "Backup: dashboard.py.bak-perfwsgi-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-perfwsgi-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine perfwsgi-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c perfWsgi /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s -D - -o /dev/null http://127.0.0.1:5000/api/time | grep -i ^server   (waitress erwartet)"
echo "  curl -s http://127.0.0.1:5000/api/perfwsgi/status"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep -E perfWsgi"
echo "  sudo journalctl -u prepper-dashboard -n 500 --no-pager | grep relStop"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG perfwsgi=1 fertig"
