#!/bin/bash
set -eEuo pipefail
# relStop (commit39): REL-10 Teil 3 Speichern beim Beenden: bei systemctl stop (SIGTERM) und normalem Ende einmal uplinkDetect (uplink_state.json, sonst bis 600 s gedrosselt) sichern, dann wie bisher longArchive-Flush und Standard-Beenden; je Eintrag 2 s, gesamt 4 s, nur lokale Datei, kein Netz, sendet nichts; Teil 1 und 2 unberuehrt
# Aufruf: bash /tmp/apply-relstop.sh commit39 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py bb94f52af6e03c3b (Stand nach hideTexts commit37) oder relStop schon drin (7be7e011ee2426a6); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-relstop-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/relstop-apply
KEEP_LAST=3
KNOWN_D16="bb94f52af6e03c3b"      # dashboard.py vor relStop (Basis: Stand nach hideTexts commit37)
KNOWN_D16N="7be7e011ee2426a6"             # dashboard.py nach relStop (Ziel)
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
echo "=== relStop apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Zustaende beim Beenden sichern (REL-10 Teil 3), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="e9eacee87cb25ffaac81b9d0ef84fa0868d951f9c3741154cd47a6a1d197e36c"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher hideTexts. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
EXPECT_RAE="bf519fa2cec398c35e51a7d5e86e82c2ed3df2c321876feff0b49b401b806fd3"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer relStop (commit39): Basis bb94f52af6e03c3b (Stand nach hideTexts commit37); nur der Block vor __main__
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_RAE_EOF
EXPECT_RAB="5fd3b0c7df9b47d472fc0041f420271c6f3cc38441268922b8a99fe5cde88343"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== relStop: Speichern beim Beenden (REL-10 Teil 3) - bei systemctl stop (SIGTERM) und normalem Ende einmal die nur gedrosselt gespeicherten Zustaende sichern; nur lokale Dateien, kein Netz, sendet nichts =====
# Bestand: uplinkDetect (uplink_detect.py _save) schreibt uplink_state.json bei unveraendertem Kern hoechstens alle 600 s -> hier einmal mit force=True.
#          longArchive (archive_store.py) puffert bis 1 h und hat einen eigenen SIGTERM-Haken (Flush, dann Standard-Beenden) -> wird nach relStop unveraendert aufgerufen.
#          Alle anderen Zustandsdateien des Dashboards werden schon bei jeder Aenderung geschrieben; sdr_wd_gate.json bleibt bewusst unberuehrt (frischer Zeitstempel beim Beenden waere falsch).
# Warum ein SIGTERM-Haken: Python hat fuer SIGTERM keinen eigenen Haken - der Prozess endet sofort, atexit laeuft nicht; der Haken von longArchive beendet ebenfalls ohne atexit.
# Daher genau ein Haken im Hauptfaden: erst relStop sichern, dann den vorherigen Haken (longArchive) bzw. das Standard-Beenden (Exit-Status wie bisher: SIGTERM). SIGABRT (Watchdog, WATCHDOG=trigger) bleibt unveraendert.
# Zeit: je Eintrag hoechstens RS_ITEM_S, gesamt RS_TOTAL_S (deutlich unter TimeoutStopSec); Eintraege laufen in Hilfsfaeden, ein haengender Eintrag haelt das Beenden nicht auf.
import atexit as _rs_atexit
import os as _rs_os
import signal as _rs_sig
import sys as _rs_sys
import threading as _rs_th
import time as _rs_time

RS_ITEM_S = 2.0
RS_TOTAL_S = 4.0
_RS = {"done": False, "lock": _rs_th.Lock(), "res": [], "prev": None, "hook": False, "reg": False, "dur": None}


def _rs_uplink():
    m = _rs_sys.modules.get("uplink_detect")
    if m is None or not getattr(m, "_started", False) or not callable(getattr(m, "_save", None)):
        return "uebersprungen (nicht aktiv)"
    m._save(force=True)
    return "gespeichert"


RS_ITEMS = [("uplinkDetect uplink_state.json", _rs_uplink)]


def _rs_say(txt):
    try:
        print(txt, flush=True)
    except Exception:
        pass


def _rs_flush(why, items=None, st=None, item_s=None, total_s=None, say=None):
    st = _RS if st is None else st
    say = _rs_say if say is None else say
    if not st["lock"].acquire(False):
        return st["res"]
    try:
        if st["done"]:
            return st["res"]
        st["done"] = True
    finally:
        st["lock"].release()
    item_s = RS_ITEM_S if item_s is None else item_s
    total_s = RS_TOTAL_S if total_s is None else total_s
    t0 = _rs_time.monotonic()
    out = []
    for name, fn in (RS_ITEMS if items is None else items):
        left = total_s - (_rs_time.monotonic() - t0)
        if left <= 0.05:
            r = "uebersprungen (Zeitbudget)"
        else:
            box = {}

            def run(fn=fn, box=box):
                try:
                    box["r"] = fn()
                except Exception as e:
                    box["e"] = "%s: %s" % (type(e).__name__, e)
            th = _rs_th.Thread(target=run, name="relStop", daemon=True)
            try:
                th.start()
                th.join(min(item_s, left))
            except RuntimeError:
                run()
            if "e" in box:
                r = "FEHLER " + box["e"][:160]
            elif "r" in box:
                r = str(box["r"])
            else:
                r = "Zeitlimit %.1f s - weiter" % min(item_s, left)
        out.append((name, r))
        say("relStop %s: %s %s" % (why, name, r))
    st["res"] = out
    st["dur"] = round(_rs_time.monotonic() - t0, 3)
    say("relStop %s: fertig in %.2f s" % (why, st["dur"]))
    return out


def _rs_term(signum, frame):
    try:
        _rs_flush("SIGTERM")
    except Exception:
        pass
    prev = _RS.get("prev")
    try:
        if callable(prev):
            prev(signum, frame)
    finally:
        _rs_sig.signal(_rs_sig.SIGTERM, _rs_sig.SIG_DFL)
        _rs_os.kill(_rs_os.getpid(), _rs_sig.SIGTERM)


def _rs_install(g):
    if not _RS["reg"]:
        _rs_atexit.register(_rs_flush, "atexit")
        _RS["reg"] = True
    if g.get("__name__") != "__main__" or _rs_th.current_thread() is not _rs_th.main_thread():
        return "nur atexit (nicht Hauptprogramm)"
    prev = _rs_sig.getsignal(_rs_sig.SIGTERM)
    if prev is _rs_term:
        return "SIGTERM-Haken schon aktiv"
    if not (prev in (_rs_sig.SIG_DFL, None) or callable(prev)):
        return "nur atexit (SIGTERM ist %r)" % (prev,)
    _RS["prev"] = prev if callable(prev) else None
    _rs_sig.signal(_rs_sig.SIGTERM, _rs_term)
    _RS["hook"] = True
    return "SIGTERM-Haken aktiv" + (" (danach longArchive)" if callable(prev) else "")


def _selftest_relstop():
    assert 0 < RS_ITEM_S <= RS_TOTAL_S <= 10, "Zeitbudget zu gross"
    assert [n for n, f in RS_ITEMS] == ["uplinkDetect uplink_state.json"] and all(callable(f) for n, f in RS_ITEMS)
    st = {"done": False, "lock": _rs_th.Lock(), "res": [], "dur": None}
    calls, lines = [], []

    def ok():
        calls.append("ok")
        return "gespeichert"

    def bad():
        calls.append("bad")
        raise OSError("Platte voll")

    def slow():
        calls.append("slow")
        _rs_time.sleep(0.4)
        return "spaet"
    r = _rs_flush("test", [("a", ok), ("b", bad), ("c", slow), ("d", ok)], st, 0.1, 0.15, lines.append)
    assert [x[0] for x in r] == ["a", "b", "c", "d"], r
    assert r[0][1] == "gespeichert" and r[1][1].startswith("FEHLER OSError") and r[2][1].startswith("Zeitlimit"), r
    assert r[3][1] == "uebersprungen (Zeitbudget)" and calls == ["ok", "bad", "slow"], (r, calls)
    assert st["done"] and st["dur"] < 0.5 and len(lines) == 5
    assert _rs_flush("test", [("e", ok)], st, 0.1, 0.15, lines.append) is r and calls == ["ok", "bad", "slow"], "nicht idempotent"
    return "relStop ok (Zustaende beim Beenden sichern: %d Eintrag, Budget %.0f s)" % (len(RS_ITEMS), RS_TOTAL_S)


try:
    _RS_ST = _selftest_relstop()
    _RS_HOOK = _rs_install(globals())
except Exception as _rs_e:
    _RS_ST = None
    print("relStop Selbsttest FEHLER (%s: %s)" % (type(_rs_e).__name__, _rs_e), flush=True)
if _RS_ST:
    print("relStop aktiv: %s; %s" % (_RS_ST, _RS_HOOK), flush=True)
# ===== /relStop =====
MK_RAB_EOF
EXPECT_RAG="1d352fa630bb9518b49f0f3ce3a045cf42789ecfe724222883c2adb304dec89f"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""Guard relStop (nur dashboard.py: Block vor __main__, keine Stellen). Aufruf:
  guard_rs.py revert NEU_VERZ ALT_VERZ BLOCK EDITS   -> ALT_VERZ/dashboard.py = NEU ohne relStop (byte-genau)
  guard_rs.py check  ALT_VERZ NEU_VERZ BLOCK EDITS   -> Rueckbau = ALT, Lage, statische Regeln, Verhaltenstests (echtes SIGTERM an Kindprozesse)
  RH_ALT=ALT_VERZ guard_rs.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest (jede Mutation muss check scheitern lassen)"""
import io, os, re, signal, subprocess, sys, tempfile, time, tokenize

CHILD_SRC = r'''# Kindprozess fuer guard_rs.py: fuehrt den relStop-Block mit Attrappen aus (uplink_detect, longArchive-Haken), kein Netz, keine echten Dateien ausser OUT
import os, signal, socket, sys, time, types
mode, out, bp = sys.argv[1:4]
blk = open(bp, encoding="utf-8").read()
def w(x):
    with open(out, "a") as f:
        f.write(x + "\n")
m = types.ModuleType("uplink_detect")
m._started = mode != "notstarted"
def _save(force=False):
    if mode == "hang":
        time.sleep(30)
    if mode == "err":
        raise OSError("kaputt")
    w("uplink force=%s" % force)
m._save = _save
sys.modules["uplink_detect"] = m
if mode != "noprev":
    def _term(s, f):
        try:
            w("archive")
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            os.kill(os.getpid(), signal.SIGTERM)
    signal.signal(signal.SIGTERM, _term)
def nonet(*a, **k):
    raise AssertionError("Netzzugriff")
socket.socket = nonet
socket.create_connection = nonet
g = {"__name__": "dashboard" if mode == "notmain" else "__main__"}
exec(compile(blk, "relStop-Block", "exec"), g)
if mode == "badflush":
    def _bad(*a, **k):
        raise RuntimeError("Flush kaputt")
    g["_rs_flush"] = _bad
w("ready")
if mode in ("exit", "notmain"):
    sys.exit(0)
time.sleep(20)
w("weiter")
'''
ANCH = '\n\nif __name__ == "__main__":\n'
FORBID = ("requests", "urlopen", "socket", "subprocess", "os.system", "send_", "mesh", "telegram", "open(", "systemctl", "eval(", "exec(",
          "__import__", "SIGKILL", "SIGINT", "SIGABRT", "_exit", "sys.exit", "notify", "WATCHDOG", "alarm")
rd = lambda p: open(p, encoding="utf-8").read()


def revert_text(s, B):
    B = B.rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block relStop nicht genau einmal"
    return s.replace("\n\n" + B, "", 1)


def code_only(B):
    out = []
    for t in tokenize.generate_tokens(io.StringIO(B).readline):
        if t.type == tokenize.COMMENT:
            continue
        out.append(t.string)
    return " ".join(out)


def run_child(mode, bp):
    with tempfile.TemporaryDirectory() as d:
        out, cp = os.path.join(d, "out"), os.path.join(d, "child.py")
        open(cp, "w", encoding="utf-8").write(CHILD_SRC)
        p = subprocess.Popen([sys.executable, cp, mode, out, bp], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        t1 = time.time() + 10
        while time.time() < t1 and not (os.path.exists(out) and "ready" in rd(out)) and p.poll() is None:
            time.sleep(0.02)
        dur = None
        if mode not in ("exit", "notmain") and p.poll() is None and os.path.exists(out):
            t0 = time.monotonic()
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(8)
            except subprocess.TimeoutExpired:
                p.kill()
            dur = time.monotonic() - t0
        try:
            so = p.communicate(timeout=8)[0]
        except subprocess.TimeoutExpired:
            p.kill()
            so = p.communicate()[0]
        lines = rd(out).splitlines() if os.path.exists(out) else []
        return p.returncode, lines, so, dur


def check(alt, neu, bp):
    A, N, B = rd(alt), rd(neu), rd(bp)
    n = 0
    fails = []

    def ok(c, msg):
        nonlocal n
        n += 1
        if not c:
            fails.append(msg)
    ok(revert_text(N, B) == A, "Rueckbau ungleich Basis")
    ok("relStop" not in A, "Basis enthaelt relStop schon")
    Bs = B.rstrip("\n")
    ok(N.count("\n\n" + Bs + ANCH) == 1, "Block nicht direkt vor __main__")
    ok(N.index("# ===== /longArchive =====") < N.index("# ===== relStop:"), "Block nicht nach longArchive")
    try:
        compile(N, "dashboard.py", "exec")
        ok(True, "")
    except SyntaxError as e:
        ok(False, "Syntax: %s" % e)
    C = code_only(B)
    for f in FORBID:
        ok(f not in C, "verboten im Block: " + f)
    ok(C.count("_rs_sig . signal (") == 2 and C.count("_rs_sig . SIGTERM") == 4, "Signal-Aufrufe nicht nur SIGTERM")
    ok(C.count("_rs_os . kill (") == 1 and "_rs_os . kill ( _rs_os . getpid ( ) , _rs_sig . SIGTERM )" in C, "kill nur an sich selbst mit SIGTERM")
    ok(C.count("_rs_atexit . register (") == 1, "atexit genau einmal")
    ok(re.search(r"RS_ITEM_S = 2\.0\b", B) and re.search(r"RS_TOTAL_S = 4\.0\b", B), "Zeitbudget geaendert")
    ok(B.startswith("# ===== relStop:") and B.rstrip().endswith("# ===== /relStop ====="), "Marker")
    T = {}
    for mode in ("normal", "noprev", "hang", "err", "notstarted", "exit", "notmain", "badflush"):
        T[mode] = run_child(mode, bp)
    rc, L, so, d = T["normal"]
    ok(rc == -15 and L == ["ready", "uplink force=True", "archive"] and d is not None and d < 1.5, "normal: %r %r %r" % (rc, L, d))
    ok("relStop aktiv: relStop ok" in so and "SIGTERM-Haken aktiv (danach longArchive)" in so, "normal: Journal aktiv")
    ok("relStop SIGTERM: uplinkDetect uplink_state.json gespeichert" in so and "relStop SIGTERM: fertig in" in so, "normal: Journal Flush")
    ok("relStop atexit" not in so and "Traceback" not in so and "Netzzugriff" not in so, "normal: atexit/Traceback/Netz")
    rc, L, so, d = T["noprev"]
    ok(rc == -15 and L == ["ready", "uplink force=True"] and "SIGTERM-Haken aktiv" in so and "(danach" not in so, "noprev: %r %r" % (rc, L))
    rc, L, so, d = T["hang"]
    ok(rc == -15 and L == ["ready", "archive"] and d is not None and 1.8 < d < 3.0 and "Zeitlimit 2.0 s" in so, "hang: %r %r %r" % (rc, L, d))
    rc, L, so, d = T["err"]
    ok(rc == -15 and L == ["ready", "archive"] and "FEHLER OSError: kaputt" in so and d < 1.5, "err: %r %r" % (rc, L))
    rc, L, so, d = T["notstarted"]
    ok(rc == -15 and L == ["ready", "archive"] and "uebersprungen (nicht aktiv)" in so, "notstarted: %r %r" % (rc, L))
    rc, L, so, d = T["badflush"]
    ok(rc == -15 and L == ["ready", "archive"] and "Traceback" not in so, "badflush: %r %r" % (rc, L))
    rc, L, so, d = T["exit"]
    ok(rc == 0 and L == ["ready", "uplink force=True"] and "relStop atexit: uplinkDetect uplink_state.json gespeichert" in so, "exit: %r %r" % (rc, L))
    rc, L, so, d = T["notmain"]
    ok(rc == 0 and L == ["ready", "uplink force=True"] and "nur atexit (nicht Hauptprogramm)" in so, "notmain: %r %r" % (rc, L))
    return n, fails


MUT = [
    ("m._save(force=True)", "m._save()"),
    ("            prev(signum, frame)\n", "            pass\n"),
    ('        _rs_flush("SIGTERM")\n', "        pass\n"),
    ("                th.join(min(item_s, left))", "                th.join()"),
    ('        if st["done"]:\n            return st["res"]\n', ""),
    ('        _rs_atexit.register(_rs_flush, "atexit")\n', "        pass\n"),
    ("        _rs_os.kill(_rs_os.getpid(), _rs_sig.SIGTERM)", "        pass"),
    ("        if left <= 0.05:", "        if False:"),
    ("RS_TOTAL_S = 4.0", "RS_TOTAL_S = 40.0"),
    ("    _rs_sig.signal(_rs_sig.SIGTERM, _rs_term)\n", ""),
    ('                    box["e"] = "%s: %s" % (type(e).__name__, e)', "                    pass"),
    ('not getattr(m, "_started", False) or ', ""),
    ('    _RS["prev"] = prev if callable(prev) else None', '    _RS["prev"] = None'),
    ('if g.get("__name__") != "__main__" or ', "if "),
    ("    except Exception:\n        pass\n    prev = ", "    except Exception:\n        raise\n    prev = "),
    ('        say("relStop %s: %s %s" % (why, name, r))', "        pass"),
    ("    return out\n\n\ndef _rs_term", "    return out\n    import socket\n\n\ndef _rs_term"),
    ("RS_ITEMS = [(", "RS_ITEMS = [] and [("),
    ('    print("relStop aktiv: %s; %s" % (_RS_ST, _RS_HOOK), flush=True)', '    print("relStop aktiv", flush=True)'),
    ("    m._save(force=True)\n", "    m._save(force=True)\n    _rs_os.kill(_rs_os.getpid(), _rs_sig.SIGKILL)\n"),
]


def mutate(alt, neu, bp):
    B = rd(bp)
    N = rd(neu)
    miss = 0
    for i, (o, nw) in enumerate(MUT, 1):
        if B.count(o) != 1:
            print("UEBERSEHEN Mutation %d Stelle nicht eindeutig (%d): %r" % (i, B.count(o), o[:60]))
            miss += 1
            continue
        B2 = B.replace(o, nw, 1)
        with tempfile.TemporaryDirectory() as d:
            bp2, np2 = os.path.join(d, "blk.py"), os.path.join(d, "dash.py")
            open(bp2, "w", encoding="utf-8").write(B2)
            open(np2, "w", encoding="utf-8").write(N.replace(B.rstrip("\n"), B2.rstrip("\n"), 1))
            try:
                n, f = check(alt, np2, bp2)
            except Exception as e:
                f = ["Ausnahme %s" % e]
        print("%s Mutation %2d: %s" % ("OK" if f else "UEBERSEHEN", i, (f[0] if f else o.strip()[:60])[:110]))
        miss += 0 if f else 1
    print("%s Mutationstest relStop: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", len(MUT), miss))
    return miss


if __name__ == "__main__":
    cmd = sys.argv[1]
    dp = lambda d: os.path.join(d, "dashboard.py") if os.path.isdir(d) else d
    if cmd == "revert":
        open(dp(sys.argv[3]), "w", encoding="utf-8").write(revert_text(rd(dp(sys.argv[2])), rd(sys.argv[4])))
        print("OK Rueckbau relStop byte-genau erzeugt")
    elif cmd == "check":
        n, f = check(dp(sys.argv[2]), dp(sys.argv[3]), sys.argv[4])
        for x in f:
            print("FEHLER", x)
        print("%s Guard relStop: %d Pruefungen, %d Fehler (Rueckbau byte-genau, Lage vor __main__, kein Netz/Senden, echtes SIGTERM an 8 Kindprozesse)" % ("OK" if not f else "FEHLER", n, len(f)))
        sys.exit(1 if f else 0)
    elif cmd == "mutate":
        sys.exit(1 if mutate(dp(os.environ["RH_ALT"]), dp(sys.argv[2]), sys.argv[3]) else 0)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach hideTexts commit37" "$KNOWN_D16N" "relStop schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      relStop passt nur auf den Stand Stand nach hideTexts commit37 (dashboard.py bb94f52af6e03c3b). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- relStop: Neustart-Sperre HH:55-HH:04 (jede Stunde, Berlin-Zeit); geprueft jetzt und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${RELSTOP_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$RELSTOP_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Sperre: relStop ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - zwischen HH:55 und HH:04 wird prepper-dashboard nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04 ($1)"; fi; }
rscheck "Vorpruefung"
RSTS=$(systemctl show -p TimeoutStopUSec --value prepper-dashboard 2>/dev/null || true)
echo "Info: prepper-dashboard TimeoutStopSec=${RSTS:-?} (relStop braucht beim Beenden hoechstens 4 s); WatchdogSec bleibt wie gesetzt (Watchdog beendet per SIGABRT - relStop greift dort bewusst nicht ein)"
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
python3 "$PPK" relStop dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer relStop nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" relStop dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: relStop im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne relStop ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard relStop meldet Verstoss"; }
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
# ---- relStop: Zustand vorher (nur Lesen) ----
RSU0=$(stat -c %Y "$DASH_DIR/uplink_state.json" 2>/dev/null || echo 0)
echo "Zustand vorher: uplink_state.json $([[ "$RSU0" == 0 ]] && echo "fehlt (uplinkDetect legt sie an)" || echo "zuletzt geschrieben $(date -d "@$RSU0" '+%d.%m. %H:%M:%S')")"
rscheck "vor dem Neustart"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: relStop ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-relstop-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG relstop=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "relStop|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-relstop-$TS" ]] && cp -a "$F.bak-relstop-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-relstop-$TS" ]] && { cmp -s "$F" "$F.bak-relstop-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK relStop schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-relstop-$TS"
  { ls -1t "$F.bak-relstop-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-relstop-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-relstop-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'relStop aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; relStop aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- relStop: Marker, Haken aktiv (Journal), Hinweis zum Beenden ----
RSM=$(grep -c "^# ===== relStop:" "$F" || true)
[[ "$RSM" == 1 ]] && echo "OK Marker relStop 1x im Programm" || rbx "Marker relStop ${RSM}x"
if [[ "$RESTARTED_D" == 1 ]]; then
  RSJ=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat | grep -F "relStop aktiv:" | tail -1 || true)
  case "$RSJ" in
    *"SIGTERM-Haken aktiv (danach longArchive)"*) echo "OK relStop: SIGTERM-Haken aktiv, longArchive-Flush wird danach weiter aufgerufen" ;;
    *"SIGTERM-Haken aktiv"*) echo "HINWEIS relStop: SIGTERM-Haken aktiv, aber longArchive hatte keinen eigenen Haken (Archiv aus?) - relStop beendet selbst per Standard" ;;
    "") echo "HINWEIS relStop: Journalzeile nicht lesbar - Pruefung folgt in Abschnitt 6" ;;
    *) rbx "relStop ohne SIGTERM-Haken: $(echo "$RSJ" | cut -c1-160)" ;;
  esac
fi
echo "Hinweis: der Neustart eben beendete noch den ALTEN Prozess (ohne relStop). Ab dem naechsten Stopp/Neustart steht im Journal 'relStop SIGTERM: ... fertig in X s'."
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E relStop"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "relStop aktiv: relStop ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'relStop aktiv: relStop ok' ($(echo "$JD" | grep -F relStop | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein relStop-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-relstop-$TS" ]] && echo "Backup: dashboard.py.bak-relstop-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-relstop-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine relstop-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c relStop /home/fmg/prepper-dashboard/dashboard.py"
echo "  sudo journalctl -u prepper-dashboard --since -1h --no-pager | grep -E 'relStop (aktiv|SIGTERM)'"
echo "  stat -c %y /home/fmg/prepper-dashboard/uplink_state.json"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep relStop"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG relstop=1 fertig"
