#!/bin/bash
set -eEuo pipefail
# commit47 (speedAsync + Aufraeumen + fullcheck 2.0.2) - ein Skript, drei Teile:
#  1) speedAsync (PERF-03 Punkt 4): /api/download_test und POST /api/speedtest?wait=1 blockieren nicht mehr (Start im Hintergrund, sofort HTTP 202, Ergebnis ueber /api/speedtest);
#     dashboard.py: ein Block vor __main__ (keine geaenderte Zeile); lage_pages.py: nur measureDownload() der Pi-Seite fragt den Status ab. /api/backup/restore unberuehrt.
#  2) Aufraeumen: alte *.bak*-Dateien im Projektordner in bak-archiv/ZEIT verschieben (nie loeschen; je Datei und Patch-Name bleiben die 3 neuesten liegen = Rueckwege der Skripte);
#     prepper_sdr.py: 3 nachweislich ueberdeckte Funktions-Erstfassungen entfernen (toter Code, Verhalten gleich); ~ip-Rest aus venv site-packages ins Archiv.
#  3) fullcheck.sh 2.0.2 nach ~/fullcheck.sh (Airspy-Seriennummer ohne Praefix "AIRSPY SN:", Soll nach commit47) und am Ende einmal laufen lassen (nur lesend).
# Aufruf: bash /tmp/apply-commit47.sh commit47 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16), alle drei Programmdateien gemeinsam: alle alt (dashboard.py 4594deab53d8ce7b, lage_pages.py 7f9fc0cf17d52644, prepper_sdr.py 8b887c795e64b87f) oder alle neu; Mischstand = STOP.
# Sicherungen: DATEI.bak-commit47-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet (prepper-sdr nicht: Code dort verhaltensgleich).
# Sendet nichts (kein Mesh, kein Telegram, keine Alarme), startet keine Speedtest-Messung, oeffnet keine SDR-Sticks, Gain-Stufe 16 bleibt.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
FL="$DASH_DIR/lage_pages.py"
FS="$DASH_DIR/prepper_sdr.py"
FCD="$(dirname "$DASH_DIR")/fullcheck.sh"
VENV="$DASH_DIR/venv"
VPY="$VENV/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/commit47-apply
KEEP_LAST=3
NM=commit47
KNOWN_D16="4594deab53d8ce7b"; KNOWN_D16N="74ac7bfd0eebd4e0"
KNOWN_L16="7f9fc0cf17d52644"; KNOWN_L16N="1d33ae9fd78f53dc"
KNOWN_S16="8b887c795e64b87f"; KNOWN_S16N="0900bfe6ba67e657"
KNOWN_FCN="192f3b9b1c0f6418"; KNOWN_FCA="46f42d85bb4e71d1 c56905e7b7373937"
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
echo "=== commit47 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): speedAsync + Aufraeumen + fullcheck 2.0.2, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="45feaed48b77a616035112a3f48bd1eb80d364200d0f8a50946bb1c06f3c5f2a"
cat > "$W/patch.py" << 'MK_C47_PAL_EOF'
"""Patcher speedAsync (generisch wie relStop). Aufruf: patch-pw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
MK_C47_PAL_EOF
EXPECT_RAE="b0028d4451daade799265c68eefd09b6f70ef4e94eae43c4c42fe63166933d48"
cat > "$W/edits.py" << 'MK_C47_RAE_EOF'
# Stellen fuer speedAsync (commit47): Basis 4594deab53d8ce7b (Stand nach perf03Cache commit46); nur ein Block vor __main__, keine Aenderung an bestehenden Zeilen
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_C47_RAE_EOF
EXPECT_RAB="407d4bc2ba698fb6886fb4113009e7ed9c79d9c5de273ee06a302bd7c527362c"
cat > "$W/blk.py" << 'MK_C47_RAB_EOF'
# ===== speedAsync: PERF-03 Punkt 4 - /api/download_test und POST /api/speedtest?wait=1 blockieren nicht mehr (Messung startet im Hintergrund, Antwort sofort: HTTP 202 + Status-Abfrage ueber /api/speedtest); Messung, Takt, Ergebnisse und Speedtest-Modul unveraendert; /api/backup/restore unberuehrt; sendet nichts =====
import threading as _sa_th
import time as _sa_time

SA_START_WAIT = 0.01       # s: nur kurz auf den Start warten (Ergebnis kommt ueber den Status /api/speedtest)
_SA = {"dl_start": 0, "dl_202": 0, "dl_direkt": 0, "wait_202": 0, "wait_direkt": 0, "ds_nach": 0, "max_ms": 0, "dl_offen": False, "err": None, "aktiv": False}
_SA_LOCK = _sa_th.Lock()


def _sa_inc(k, ms=None):
    with _SA_LOCK:
        _SA[k] += 1
        if ms is not None and ms > _SA["max_ms"]:
            _SA["max_ms"] = int(ms)


def _sa_rec_json(r, feed=None, ds=None):
    """Antwort wie bisher /api/download_test ({ok, mbps, at, ...}) aus einem fertigen run()-Ergebnis; uebernimmt es wie bisher (last_download, data_store)."""
    rec = r.get("result") if r.get("ok") else None
    if rec:
        (feed or _st_feed)(rec)
        ds = data_store if ds is None else ds
        ds["download"] = rec.get("down")
        ds["download_at"] = _st_at(rec)
    err = r.get("error")
    return {"ok": bool(rec), "mbps": rec.get("down") if rec else None, "at": _st_at(rec) if rec else None,
            "up": rec.get("up") if rec else None, "ping": rec.get("ping") if rec else None,
            "jitter": rec.get("jitter") if rec else None, "uplink": rec.get("uplink") if rec else None,
            "server": (rec.get("server") or {}).get("name") if rec else None, "cached": bool(r.get("cached")),
            "running": bool(r.get("running")), "error": err.get("msg") if not rec and isinstance(err, dict) else None}


def _sa_dl(st, feed=None, ds=None):
    """Kern von /api/download_test: startet die Messung (oder nimmt den Ergebniswert der letzten Minuten) und kehrt sofort zurueck."""
    t0 = _sa_time.time()
    r = st.run(manual=True, wait=SA_START_WAIT)
    if r.get("running"):
        _SA["dl_offen"] = True
        _sa_inc("dl_202", (_sa_time.time() - t0) * 1000)
        return {"ok": False, "running": True, "mbps": None, "at": None, "poll": "/api/speedtest",
                "seit": int(st.started_at or t0), "hinweis": "Messung laeuft im Hintergrund - Ergebnis ueber /api/speedtest"}, 202
    _sa_inc("dl_direkt", (_sa_time.time() - t0) * 1000)
    return _sa_rec_json(r, feed, ds), 200


def _sa_download_test():
    from flask import jsonify
    if _st is None:
        return jsonify({"ok": False, "mbps": None, "at": None, "error": "Modul fehlt"})
    _sa_inc("dl_start")
    d, code = _sa_dl(_st)
    return jsonify(d), code


def _sa_api():
    """POST /api/speedtest?wait=1 wartet nicht mehr bis 150 s: Start + Status sofort (202, solange die Messung laeuft); alles andere wie bisher."""
    from flask import jsonify, request
    if request.method == "POST" and request.args.get("wait") == "1" and _st is not None:
        t0 = _sa_time.time()
        r = _st.run(manual=True, wait=SA_START_WAIT)
        out = _st_status()
        out["run"] = {"ok": r.get("ok"), "cached": r.get("cached", False), "running": r.get("running", False)}
        out["poll"] = "/api/speedtest"
        if r.get("running"):
            _sa_inc("wait_202", (_sa_time.time() - t0) * 1000)
            return jsonify(out), 202
        _sa_inc("wait_direkt", (_sa_time.time() - t0) * 1000)
        return jsonify(out)
    return _st_api()


def _sa_on_result(rec):
    """Ergebnis-Weitergabe wie bisher (_st_on_result); kam die Messung von /api/download_test, zusaetzlich data_store wie frueher im Aufruf."""
    _st_on_result(rec)
    if _SA["dl_offen"] and rec and rec.get("manual") and rec.get("down") is not None:
        _SA["dl_offen"] = False
        data_store["download"] = rec.get("down")
        data_store["download_at"] = _st_at(rec)
        _sa_inc("ds_nach")


def _sa_status():
    from flask import jsonify
    with _SA_LOCK:
        d = {k: _SA[k] for k in ("dl_start", "dl_202", "dl_direkt", "wait_202", "wait_direkt", "ds_nach", "max_ms", "dl_offen")}
    d.update({"aktiv": _SA["aktiv"], "err": _SA["err"], "laeuft": bool(_st is not None and _st.running), "start_wait_s": SA_START_WAIT})
    return jsonify(d)


def _sa_install():
    """Haengt /api/download_test und /api/speedtest um (einmalig; bei erneutem Laden bleibt es bei den urspruenglichen Funktionen)."""
    vf = app.view_functions
    eps = {}
    for rule, orig in (("/api/download_test", _st_download_test), ("/api/speedtest", _st_api)):
        rs = [r for r in app.url_map.iter_rules() if r.rule == rule]
        assert len(rs) == 1, "%s: %d Regeln" % (rule, len(rs))
        cur = vf[rs[0].endpoint]
        assert cur is orig or getattr(cur, "_sa_prev", None) is orig, "%s: Endpunkt %s unerwartet (%s)" % (rule, rs[0].endpoint, getattr(cur, "__name__", "?"))
        eps[rule] = rs[0].endpoint
    _sa_download_test._sa_prev = _st_download_test
    _sa_api._sa_prev = _st_api
    vf[eps["/api/download_test"]] = _sa_download_test
    vf[eps["/api/speedtest"]] = _sa_api
    if _st is not None:
        _st.on_result = _sa_on_result
    if "speedasync_status" not in vf:
        app.add_url_rule("/api/speedasync/status", "speedasync_status", _sa_status, methods=["GET"])


class _SaFake:
    """nur fuer den Selbsttest: startet nichts, misst nichts"""
    def __init__(self, r, start=None):
        self.r, self.started_at, self.calls = r, start, []

    def run(self, manual=False, wait=None):
        self.calls.append((manual, wait))
        return self.r


def _selftest_speedasync():
    sa0 = dict(_SA)
    fed, ds = [], {}
    try:
        f = _SaFake({"ok": False, "running": True, "result": None}, 1700000000)
        d, c = _sa_dl(f, fed.append, ds)
        assert c == 202 and d["running"] is True and d["ok"] is False and d["poll"] == "/api/speedtest" and d["seit"] == 1700000000, "202 bei laufender Messung"
        assert f.calls == [(True, SA_START_WAIT)] and 0 < SA_START_WAIT <= 0.05, "Start ohne Warten"
        rec = {"down": 88.5, "up": 9.1, "ping": 12, "jitter": 1.5, "uplink": "telekom", "server": {"name": "X"}, "t": int(_sa_time.time()), "at": "01.01.2026 00:00:00"}
        g = _SaFake({"ok": True, "cached": True, "result": rec})
        d, c = _sa_dl(g, fed.append, ds)
        assert c == 200 and d["ok"] is True and d["mbps"] == 88.5 and d["cached"] is True and d["server"] == "X" and d["at"], "Ergebnis der letzten Minuten direkt"
        assert fed == [rec] and ds.get("download") == 88.5 and ds.get("download_at") == d["at"], "Uebernahme wie bisher (last_download, data_store)"
        e = _SaFake({"ok": False, "running": False, "result": None, "error": {"msg": "speedtest fehlt"}})
        d, c = _sa_dl(e, fed.append, ds)
        assert c == 200 and d["ok"] is False and d["error"] == "speedtest fehlt" and d["mbps"] is None and len(fed) == 1, "Fehler direkt"
        assert set(_sa_rec_json({"ok": False}, fed.append, ds).keys()) == {"ok", "mbps", "at", "up", "ping", "jitter", "uplink", "server", "cached", "running", "error"}, "Antwortfelder wie bisher"
    finally:
        with _SA_LOCK:
            _SA.update(sa0)
    assert callable(_st_download_test) and callable(_st_api) and callable(_st_on_result) and callable(_st_status), "Speedtest-Grundfunktionen"
    return "speedAsync ok (/api/download_test und POST /api/speedtest?wait=1: Start im Hintergrund, Antwort sofort, 202 + Status ueber /api/speedtest; Ergebnis der letzten Minuten direkt wie bisher; Messung/Takt unveraendert)"


try:
    _SA_ST = _selftest_speedasync()
    _sa_install()
    _SA["aktiv"] = True
except Exception as _sa_e:
    _SA_ST = None
    _SA["err"] = "%s: %s" % (type(_sa_e).__name__, _sa_e)
    print("speedAsync Selbsttest FEHLER (%s: %s) - /api/download_test und /api/speedtest wie bisher" % (type(_sa_e).__name__, _sa_e), flush=True)
if _SA_ST:
    print("speedAsync aktiv: %s" % _SA_ST, flush=True)
# ===== /speedAsync =====
MK_C47_RAB_EOF
EXPECT_RAG="119198dc90d33d3cf8aab1b951cdcb3d494bc14e9fabd95fbd08872e9fa1b7d7"
cat > "$W/guard.py" << 'MK_C47_RAG_EOF'
"""Guard speedAsync (commit47). dashboard.py: ein Block vor __main__, keine geaenderten Zeilen; lage_pages.py: nur measureDownload() in page_pi.
  guard_sa.py revert NEU_VERZ ALT_VERZ BLOCK EDITS LPEDITS   -> ALT_VERZ/dashboard.py + lage_pages.py = NEU ohne speedAsync (byte-genau)
  guard_sa.py check  ALT_VERZ NEU_VERZ BLOCK EDITS LPEDITS   -> Rueckbau = ALT, statische Regeln, Verhaltenstests (echter speedTest-Abschnitt + echtes speedtest_run im Kindprozess, Messung gefaelscht, kein Netz)
  RH_ALT=ALT_VERZ guard_sa.py mutate NEU_VERZ BLOCK EDITS LPEDITS -> Mutationstest (jede Mutation muss check scheitern lassen)
Umgebung: SA_STMOD = Pfad zu speedtest_run.py (Projektordner). Braucht flask im ausfuehrenden Python (venv); node (falls vorhanden) fuer den Seiten-Skripttest."""
import ast, io, json, os, re, shutil, subprocess, sys, tempfile, threading, tokenize

CHILD_SRC = r'''# Kindprozess fuer guard_sa.py: echter speedTest-Abschnitt aus dashboard.py (NEU) + speedAsync-Block, echtes speedtest_run.Runner mit gefaelschter Messung
import importlib.util, json, os, sys, tempfile, threading, time
mode, out, bp, np, stm = sys.argv[1:6]
blk = open(bp, encoding="utf-8").read()
N = open(np, encoding="utf-8").read()
i0, i1 = N.index("# ===== speedTest:"), N.index("# ===== /speedTest =====")
sec = N[i0:i1]
R = {}
def w():
    open(out, "w").write(json.dumps(R))
spec = importlib.util.spec_from_file_location("speedtest_run", stm)
M = importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
sys.modules["speedtest_run"] = M
C = {"n": 0, "delay": 0.5, "fail": False, "down": 91.5, "send": 0, "max": 0, "run": 0}
L = threading.Lock()
def fake_measure(self, manual):
    with L:
        C["n"] += 1; C["run"] += 1; C["max"] = max(C["max"], C["run"])
    try:
        time.sleep(C["delay"])
        if C["fail"]:
            return None, ["kein Ergebnis (rc=2)"]
        t = time.time()
        return {"down": C["down"], "up": 9.5, "ping": 11.0, "jitter": 0.8, "server": {"name": "Testserver"}, "uplink": "telekom", "t": int(t),
                "at": time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(t)), "manual": bool(manual), "server_auto": False}, []
    finally:
        with L:
            C["run"] -= 1
M.Runner._measure = fake_measure
from flask import Flask, jsonify
app = Flask("satest")
tmp = tempfile.mkdtemp()
def send_meshtastic(*a, **k):
    C["send"] += 1
def api_download_test_alt():
    return jsonify({"ok": False, "alt": True})
app.add_url_rule("/api/download_test", "api_download_test", api_download_test_alt)
g = {"__name__": "__main__", "__file__": os.path.join(tmp, "dashboard.py"), "app": app, "jsonify": jsonify, "data_store": {}, "last_download": {"mbps": 1.0, "at": "00:00:00"},
     "send_meshtastic": send_meshtastic}
if mode == "nomod":
    sys.modules["speedtest_run"] = None
exec(compile(sec, "speedTest-Abschnitt", "exec"), g)
ORIG = {"dl": app.view_functions["api_download_test"], "api": app.view_functions["st_api"]}
if mode == "broken":
    g["_st_status"] = None
if mode == "fremd":
    def fremd():
        return jsonify({"fremd": True})
    app.view_functions["api_download_test"] = fremd
    ORIG["dl"] = fremd
exec(compile(blk, "speedAsync-Block", "exec"), g)
if mode == "twice":
    exec(compile(blk, "speedAsync-Block", "exec"), g)
vf = app.view_functions
R["orig_bleibt"] = {"dl": vf["api_download_test"] is ORIG["dl"], "api": vf["st_api"] is ORIG["api"]}
R["prev_ok"] = {"dl": getattr(vf["api_download_test"], "_sa_prev", None) is g["_st_download_test"], "api": getattr(vf["st_api"], "_sa_prev", None) is g["_st_api"]}
R["status_regeln"] = sum(1 for r in app.url_map.iter_rules() if r.endpoint == "speedasync_status")
R["on_result"] = None if g["_st"] is None else getattr(g["_st"].on_result, "__name__", "?")
R["regeln"] = sorted(r.rule for r in app.url_map.iter_rules() if r.rule.startswith("/api/"))
cl = app.test_client()
def req(m, path):
    t0 = time.monotonic()
    r = cl.open(path, method=m)
    try:
        j = r.get_json()
    except Exception:
        j = None
    return r.status_code, j, time.monotonic() - t0
if mode in ("broken", "twice", "nomod", "fremd"):
    if mode == "nomod":
        c, j, dt = req("GET", "/api/download_test"); R["NM"] = [c, j]
    w(); sys.exit(0)
ds, st = g["data_store"], g["_st"]
c, j, dt = req("GET", "/api/download_test"); R["D1"] = [c, j.get("running"), j.get("ok"), j.get("poll"), dt, C["n"], isinstance(j.get("seit"), int)]
c, j, dt = req("GET", "/api/speedtest"); R["D2a"] = [c, j.get("running")]
time.sleep(C["delay"] + 0.4)
c, j, dt = req("GET", "/api/speedtest"); R["D2"] = [c, j.get("running"), (j.get("last") or {}).get("down"), ds.get("download"), g["last_download"].get("mbps"), g["_SA"]["ds_nach"], g["_SA"]["dl_offen"]]
c, j, dt = req("GET", "/api/download_test"); R["D3"] = [c, j.get("ok"), j.get("mbps"), j.get("cached"), C["n"], dt, sorted(j.keys())]
st.d["last"]["t"] -= 3600; C["down"] = 77.0; C["delay"] = 0.6
rs = [None] * 10
def one(i):
    rs[i] = req("GET", "/api/download_test")
ts = [threading.Thread(target=one, args=(i,)) for i in range(10)]
for t in ts: t.start()
for t in ts: t.join(20)
R["D4"] = [sorted(set(x[0] for x in rs)), max(x[2] for x in rs), C["n"], C["max"]]
time.sleep(1.0)
R["D4b"] = [ds.get("download"), C["max"]]
st.d["last"]["t"] -= 3600; C["delay"] = 0.5
c, j, dt = req("POST", "/api/speedtest?wait=1"); R["W1"] = [c, (j.get("run") or {}).get("running"), j.get("poll"), dt, C["n"]]
time.sleep(0.9)
c, j, dt = req("POST", "/api/speedtest?wait=1"); R["W2"] = [c, (j.get("run") or {}).get("cached"), dt, C["n"]]
c, j, dt = req("POST", "/api/speedtest"); R["W3"] = [c, (j.get("run") or {}).get("cached"), C["n"]]
c, j, dt = req("GET", "/api/speedtest"); R["W4"] = [c, j.get("ok"), "poll" in j]
st.d["last"]["t"] -= 3600; C["down"] = 66.0; dl5 = ds.get("download")
c, j, dt = req("POST", "/api/speedtest"); R["W5"] = [c, (j.get("run") or {}).get("running"), "poll" in j, dt, C["n"]]
time.sleep(0.9)
R["W5b"] = [ds.get("download") == dl5, (st.d.get("last") or {}).get("down"), g["_SA"]["wait_202"]]
st.d["last"]["t"] -= 3600; C["fail"] = True; C["delay"] = 0.3; dl0 = ds.get("download")
c, j, dt = req("GET", "/api/download_test"); time.sleep(0.6)
c2, j2, dt2 = req("GET", "/api/speedtest"); R["E1"] = [c, j.get("running"), c2, ((j2.get("last_error") or {}).get("msg") or "")[:13], ds.get("download") == dl0]
c, j, dt = req("GET", "/api/speedasync/status"); R["ST"] = j
R["C"] = C
w()
'''
JS_TEST = r'''// node: measureDownload() aus page_pi mit gefaelschtem fetch/DOM (kein Netz)
const fs = require("fs"); const src = fs.readFileSync(process.argv[2], "utf8"); const mode = process.argv[3];
const m = src.match(/<script>\s*(async function measureDownload\(\)\{[\s\S]*?\n\})\s*<\/script>/);
if (!m) { console.log(JSON.stringify({err: "kein measureDownload"})); process.exit(0); }
const el = {dlStatus: {style: {}, textContent: ""}, dlBtn: {disabled: false}};
const calls = []; let polls = 0;
global.document = {getElementById: (id) => el[id]};
global.setTimeout = (f, ms) => { calls.push("t" + ms); Promise.resolve().then(f); return 0; };
global.fetch = async (url, opt) => { calls.push(url + (opt && opt.method ? ":" + opt.method : ""));
  if (url === "/api/download_test") {
    if (mode === "alt") return {status: 200, json: async () => ({ok: true, mbps: 50.5, at: "08:00:00"})};
    return {status: 202, json: async () => ({ok: false, running: true, seit: 1000, poll: "/api/speedtest"})}; }
  if (url === "/api/speedtest") { polls++;
    if (mode === "nie") return {status: 200, json: async () => ({running: true})};
    if (polls < 3) return {status: 200, json: async () => ({running: true})};
    if (mode === "fehler") return {status: 200, json: async () => ({running: false, last: {down: 10, t: 999, at: "x"}, last_error: {msg: "x"}})};
    return {status: 200, json: async () => ({running: false, last: {down: 88.2, t: 1001, at: "31.10.2026 08:01:00"}})}; }
  return {status: 404, json: async () => ({})}; };
eval(m[1] + "\nglobalThis.measureDownload = measureDownload;");
measureDownload().then(() => console.log(JSON.stringify({txt: el.dlStatus.textContent, col: el.dlStatus.style.color, btn: el.dlBtn.disabled, polls: polls,
  calls: calls.filter(x => x[0] === "/").length, post: calls.some(x => x.indexOf(":") > 0)})));
'''
ANCH = '\n\nif __name__ == "__main__":\n'
FORBID = ("requests", "urlopen", "socket", "subprocess", "os.system", "send_", "mesh", "telegram", "open(", "systemctl", "eval(", "exec(", "__import__", "signal", "kill",
          "_exit", "sys.exit", "notify", "global ", "gain", "alarm", "sqlite", "globals", "setattr", "__dict__", "restore", "backup", "_measure", "_run_inner", "_exec", ".start(", "Thread(")
OWN = re.compile(r"^(_sa_\w*|_SA\w*|SA_[A-Z_]+|_selftest_speedasync|_SaFake)$")
USES = ("_st", "_st_feed", "_st_at", "_st_status", "_st_api", "_st_download_test", "_st_on_result", "data_store", "app")
KEEPF = ("_st_download_test", "_st_api", "_st_on_result", "_st_feed", "_st_at", "_st_status", "_st_pub", "fetch_download_mbps", "_st_uplink")
rd = lambda p: open(p, encoding="utf-8").read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"]


def load_lp(lp):
    g = {}
    exec(compile(rd(lp), lp, "exec"), g)
    return g["LP_OLD"], g["LP_NEW"]


def revert_text(s, B, E):
    B = B.rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block speedAsync nicht genau einmal"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in E:
        assert s.count(n) == 1, "Stelle nicht genau einmal: %r" % n[:50]
        s = s.replace(n, o, 1)
    return s


def revert_lp(s, lp):
    o, n = load_lp(lp)
    assert s.count(n) == 1 and s.count(o) == 0, "lage_pages.py: neue Stelle nicht genau einmal"
    return s.replace(n, o, 1)


def code_only(B):
    return " ".join(t.string for t in tokenize.generate_tokens(io.StringIO(B).readline) if t.type not in (tokenize.COMMENT, tokenize.STRING))


def run_child(mode, bp, np):
    with tempfile.TemporaryDirectory() as d:
        out, cp = os.path.join(d, "out"), os.path.join(d, "child.py")
        open(cp, "w", encoding="utf-8").write(CHILD_SRC)
        p = subprocess.run([sys.executable, cp, mode, out, bp, np, os.environ.get("SA_STMOD", "speedtest_run.py")], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        R = json.loads(rd(out)) if os.path.exists(out) else {}
        return R, p.stdout, p.returncode


def run_js(lpn, mode):
    node = None if os.environ.get("GUARD_NO_NODE") else (shutil.which("node") or shutil.which("nodejs"))
    if not node:
        return None
    with tempfile.TemporaryDirectory() as d:
        jp = os.path.join(d, "t.js")
        open(jp, "w", encoding="utf-8").write(JS_TEST)
        p = subprocess.run([node, jp, lpn, mode], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        try:
            return json.loads(p.stdout.strip().splitlines()[-1])
        except Exception:
            return {"err": p.stdout[-200:]}


def fdef(T, name):
    x = [s for s in T.body if isinstance(s, ast.FunctionDef) and s.name == name]
    return x[0] if len(x) == 1 else None


def check(alt, neu, bp, ep, lp, lpa=None, lpn=None):
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
        ok(revert_text(N, B, E) == A, "Rueckbau dashboard.py ungleich Basis")
    except AssertionError as e:
        ok(False, "Rueckbau: %s" % e)
    ok(E == [], "speedAsync aendert bestehende Zeilen in dashboard.py")
    ok("speedAsync" not in A and "_sa_" not in A, "Basis enthaelt speedAsync schon")
    Bs = B.rstrip("\n")
    ok(N.count("\n\n" + Bs + ANCH) == 1, "Block nicht direkt vor __main__")
    ok("# ===== /perf03Cache =====" in N and N.index("# ===== /perf03Cache =====") < N.index("# ===== speedAsync:"), "Block nicht nach perf03Cache")
    ok(B.startswith("# ===== speedAsync:") and B.rstrip().endswith("# ===== /speedAsync =====") and N.count("# ===== speedAsync:") == 1, "Marker")
    try:
        TN, TA, TB = ast.parse(N), ast.parse(A), ast.parse(B)
        ok(True, "")
    except SyntaxError as e:
        return n + 1, fails + ["Syntax: %s" % e]
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
            ok(all(isinstance(t, ast.Name) for t in s.targets), "Block weist auf Modulebene fremde Ziele zu: %s" % ast.unparse(s)[:60])
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
    for u in USES:
        ok(u in defsA, "Basis kennt %s nicht" % u)
    ok(re.search(r"^SA_START_WAIT = 0\.01\b", B, re.M) is not None, "Grundwert SA_START_WAIT != 0.01")
    runs = [x for x in ast.walk(TB) if isinstance(x, ast.Call) and ast.unparse(x.func).endswith(".run")]
    ok(len(runs) == 2 and all({k.arg: ast.unparse(k.value) for k in r.keywords} == {"manual": "True", "wait": "SA_START_WAIT"} and not r.args for r in runs), "run() nicht ueberall mit manual=True, wait=SA_START_WAIT: %s" % [ast.unparse(r) for r in runs])
    ok(sum(1 for r in runs if ast.unparse(r.func) == "_st.run") == 1, "_st.run nicht genau einmal (nur ?wait=1)")
    # Zuweisungen auf fremde Objekte nur: view_functions, _st.on_result, data_store download/download_at, _sa_*._sa_prev
    for t in ast.walk(TB):
        if isinstance(t, (ast.Assign, ast.AugAssign)):
            for tg in (t.targets if isinstance(t, ast.Assign) else [t.target]):
                for x in ([tg] if not isinstance(tg, ast.Tuple) else tg.elts):
                    if isinstance(x, ast.Name):
                        continue
                    s = ast.unparse(x)
                    ok(s in ("vf[eps['/api/download_test']]", "vf[eps['/api/speedtest']]", "_st.on_result", "data_store['download']", "data_store['download_at']",
                             "ds['download']", "ds['download_at']", "_sa_download_test._sa_prev", "_sa_api._sa_prev", "_SA['dl_offen']", "_SA[k]", "_SA['max_ms']", "_SA['aktiv']", "_SA['err']",
                             "eps[rule]", "out['run']", "out['poll']", "self.r, self.started_at, self.calls") or s.startswith("self."), "Zuweisung auf %s" % s)
    for nm in KEEPF:
        fa, fn = [ast.dump(s) for s in TA.body if isinstance(s, ast.FunctionDef) and s.name == nm], [ast.dump(s) for s in TN.body if isinstance(s, ast.FunctionDef) and s.name == nm]
        ok(fa and fa == fn, "%s veraendert" % nm)
    ok(len(re.findall(r'^@app\.route\("/api/backup/restore"', N, re.M)) == 1, "Route /api/backup/restore nicht genau einmal")
    ok(not re.search(r"view_functions\[[^\]]*\]\s*=\s*_sa_", A), "Basis haengt schon um")
    # ---- lage_pages.py ----
    if lpa and lpn:
        LA, LN = rd(lpa), rd(lpn)
        o, nw = load_lp(lp)
        try:
            ok(revert_lp(LN, lp) == LA, "Rueckbau lage_pages.py ungleich Basis")
        except AssertionError as e:
            ok(False, "Rueckbau lage_pages: %s" % e)
        tLA, tLN = ast.parse(LA), ast.parse(LN)
        da = {s.name: ast.dump(s) for s in tLA.body if isinstance(s, ast.FunctionDef)}
        dn = {s.name: ast.dump(s) for s in tLN.body if isinstance(s, ast.FunctionDef)}
        ok(sorted(da) == sorted(dn) and [k for k in da if da[k] != dn[k]] == ["page_pi"], "lage_pages.py: andere Funktion als page_pi geaendert: %s" % [k for k in da if da.get(k) != dn.get(k)])
        ok(nw.count('fetch("/api/download_test")') == 1 and nw.count('fetch("/api/speedtest")') == 1 and "method" not in nw and "POST" not in nw, "Seitenskript: Abrufe")
        ok("for(var k=0;k<50;k++){" in nw and "setTimeout(res,3000)" in nw and "(L.t||0)>=seit" in nw, "Seitenskript: Takt/Grenze/Zeitvergleich")
        ok("if(r.status===202 || d.running){" in nw and "if(s.running) continue;" in nw and nw.count("break;") == 1 and "d={ok:true,mbps:L.down,at:L.at};" in nw, "Seitenskript: 202-Zweig/Weiterfragen/Ergebnis (statisch, auch ohne node)")
        try:
            import jinja2
            env = jinja2.Environment()
            for t in (LA, LN):
                g = {}
                exec(compile(t, "lp", "exec"), g)
                env.parse(g["page_pi"]("NAVX"))
            ok(True, "")
        except Exception as e:
            ok(False, "lage_pages page_pi als Vorlage nicht lesbar: %s" % e)
        js = {m: run_js(lpn, m) for m in ("neu", "alt", "fehler", "nie")}
        if js["neu"] is not None:
            ok(js["neu"] == {"txt": "✓ 88.2 Mbit/s · 31.10.2026 08:01:00", "col": "#22c55e", "btn": False, "polls": 3, "calls": 4, "post": False}, "JS 202 + Status: %r" % js["neu"])
            ok(js["alt"] == {"txt": "✓ 50.5 Mbit/s · 08:00:00", "col": "#22c55e", "btn": False, "polls": 0, "calls": 1, "post": False}, "JS direktes Ergebnis wie bisher: %r" % js["alt"])
            ok(js["fehler"] == {"txt": "✗ Messung fehlgeschlagen", "col": "#ef4444", "btn": False, "polls": 3, "calls": 4, "post": False}, "JS alter Wert/Fehler: %r" % js["fehler"])
            ok(js["nie"] == {"txt": "✗ Messung fehlgeschlagen", "col": "#ef4444", "btn": False, "polls": 50, "calls": 51, "post": False}, "JS Grenze 50 Abfragen: %r" % js["nie"])
    # ---- Verhalten ----
    Rs = {}
    ths = [threading.Thread(target=lambda m=m: Rs.__setitem__(m, run_child(m, bp, neu))) for m in ("main", "twice", "broken", "nomod", "fremd")]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    R, so, rc = Rs["main"]
    ok(rc == 0 and R.get("orig_bleibt") == {"dl": False, "api": False} and R.get("prev_ok") == {"dl": True, "api": True} and R.get("status_regeln") == 1, "Kind/Umhaengen: rc %r %r %r %s" % (rc, R.get("orig_bleibt"), R.get("prev_ok"), so[-300:]))
    ok(R.get("on_result") == "_sa_on_result", "Ergebnis-Weitergabe nicht umgehaengt: %r" % R.get("on_result"))
    ok("speedAsync aktiv: speedAsync ok (/api/download_test und POST /api/speedtest?wait=1" in so and "FEHLER" not in so, "Journalzeile aktiv: %s" % so[-200:])
    d = R.get("D1") or [0, 0, 0, 0, 9, 0, 0]
    ok(d[0] == 202 and d[1] is True and d[2] is False and d[3] == "/api/speedtest" and d[4] < 0.2 and d[5] == 1 and d[6] is True, "D1 Start -> 202 sofort: %r" % d)
    ok(R.get("D2a") == [200, True], "D2a Status laeuft: %r" % R.get("D2a"))
    ok(R.get("D2") == [200, False, 91.5, 91.5, 91.5, 1, False], "D2 Ergebnis -> data_store/last_download wie bisher: %r" % R.get("D2"))
    d = R.get("D3") or [0] * 7
    ok(d[:5] == [200, True, 91.5, True, 1] and d[5] < 0.2 and d[6] == ["at", "cached", "error", "jitter", "mbps", "ok", "ping", "running", "server", "up", "uplink"], "D3 Ergebnis der letzten Minuten direkt (alte Felder): %r" % d)
    d = R.get("D4") or [[], 9, 0, 0]
    ok(d[0] == [202] and d[1] < 0.5 and d[2] == 2 and d[3] == 1, "D4 10 parallel -> 1 Messung, alle sofort 202: %r" % d)
    ok(R.get("D4b") == [77.0, 1], "D4b Ergebnis uebernommen, nie 2 gleichzeitig: %r" % R.get("D4b"))
    d = R.get("W1") or [0, 0, 0, 9, 0]
    ok(d[0] == 202 and d[1] is True and d[2] == "/api/speedtest" and d[3] < 0.2 and d[4] == 3, "W1 POST ?wait=1 -> 202 sofort: %r" % d)
    d = R.get("W2") or [0, 0, 9, 0]
    ok(d[0] == 200 and d[1] is True and d[2] < 0.2 and d[3] == 3, "W2 danach Ergebnis direkt: %r" % d)
    ok(R.get("W3") == [200, True, 3], "W3 POST ohne wait wie bisher: %r" % R.get("W3"))
    ok(R.get("W4") == [200, True, False], "W4 GET Status wie bisher: %r" % R.get("W4"))
    d = R.get("W5") or [0, 0, 0, 9, 0]
    ok(d[0] == 200 and d[1] is True and d[2] is False and d[3] < 0.2 and d[4] == 4, "W5 POST ohne wait (laufend) wie bisher 200: %r" % d)
    ok(R.get("W5b") == [True, 66.0, 1], "W5b Ergebnis ohne download_test aendert data_store nicht (wie bisher): %r" % R.get("W5b"))
    ok(R.get("E1") == [202, True, 200, "kein Ergebnis", True], "E1 Fehler: Status zeigt Fehler, data_store unveraendert: %r" % R.get("E1"))
    st = R.get("ST") or {}
    ok(st.get("aktiv") is True and st.get("dl_202") == 12 and st.get("wait_202") == 1 and st.get("ds_nach") == 2, "Status: %r" % st)
    c = R.get("C") or {}
    ok(c.get("send") == 0 and c.get("max") == 1 and c.get("n") == 5, "Senden/gleichzeitige Messungen: %r" % c)
    R, so, rc = Rs["twice"]
    ok(rc == 0 and R.get("prev_ok") == {"dl": True, "api": True} and R.get("status_regeln") == 1 and R.get("on_result") == "_sa_on_result" and so.count("speedAsync aktiv") == 2 and "FEHLER" not in so, "zweimal geladen: %r %s" % (R, so[-200:]))
    R, so, rc = Rs["broken"]
    ok(rc == 0 and R.get("orig_bleibt") == {"dl": True, "api": True} and R.get("on_result") == "_st_on_result" and "speedAsync Selbsttest FEHLER" in so and "speedAsync aktiv" not in so, "Selbsttest-Fehler -> wie bisher: %r %s" % (R.get("orig_bleibt"), so[-200:]))
    R, so, rc = Rs["nomod"]
    ok(rc == 0 and R.get("on_result") is None and R.get("NM") == [200, {"ok": False, "mbps": None, "at": None, "error": "Modul fehlt"}] and "speedAsync aktiv" in so, "ohne Speedtest-Modul: %r %s" % (R.get("NM"), so[-200:]))
    R, so, rc = Rs["fremd"]
    ok(rc == 0 and R.get("orig_bleibt") == {"dl": True, "api": True} and R.get("on_result") == "_st_on_result" and "speedAsync Selbsttest FEHLER" in so and "unerwartet" in so, "fremder Endpunkt -> nicht umhaengen: %r %s" % (R.get("orig_bleibt"), so[-200:]))
    return n, fails


MUT = [
    ("B", "SA_START_WAIT = 0.01 ", "SA_START_WAIT = 150 "),
    ("B", "    if r.get(\"running\"):\n        _SA[\"dl_offen\"] = True\n", "    if False:\n        _SA[\"dl_offen\"] = True\n"),
    ("B", "        return {\"ok\": False, \"running\": True, \"mbps\": None, \"at\": None, \"poll\": \"/api/speedtest\",", "        return {\"ok\": False, \"running\": True, \"mbps\": None, \"at\": None, \"poll\": \"/api/download_test\","),
    ("B", "\"hinweis\": \"Messung laeuft im Hintergrund - Ergebnis ueber /api/speedtest\"}, 202", "\"hinweis\": \"Messung laeuft im Hintergrund - Ergebnis ueber /api/speedtest\"}, 200"),
    ("B", "        ds[\"download\"] = rec.get(\"down\")\n", "        pass\n"),
    ("B", "        (feed or _st_feed)(rec)\n", "        pass\n"),
    ("B", "    if _SA[\"dl_offen\"] and rec and rec.get(\"manual\") and rec.get(\"down\") is not None:\n", "    if rec and rec.get(\"down\") is not None:\n"),
    ("B", "        _SA[\"dl_offen\"] = False\n        data_store", "        data_store"),
    ("B", "    _st_on_result(rec)\n    if _SA", "    if _SA"),
    ("B", "    if request.method == \"POST\" and request.args.get(\"wait\") == \"1\" and _st is not None:\n", "    if request.method == \"POST\" and _st is not None:\n"),
    ("B", "            return jsonify(out), 202\n", "            return jsonify(out)\n"),
    ("B", "    if _st is not None:\n        _st.on_result = _sa_on_result\n", ""),
    ("B", "    vf[eps[\"/api/speedtest\"]] = _sa_api\n", ""),
    ("B", "    _sa_install()\n", ""),
    ("B", "    if \"speedasync_status\" not in vf:\n", "    if True:\n"),
    ("B", "        assert cur is orig or getattr(cur, \"_sa_prev\", None) is orig,", "        assert True or cur is orig,"),
    ("B", "    \"\"\"Kern von /api/download_test: startet", "    st.run(manual=True, wait=SA_START_WAIT)\n    \"\"\"Kern von /api/download_test: startet"),
    ("B", "import time as _sa_time\n", "import time as _sa_time\nimport subprocess as _sa_sp\n"),
    ("B", "    _sa_inc(\"dl_start\")\n", "    _sa_inc(\"dl_start\")\n    send_meshtastic(\"speed\")\n"),
    ("B", "        \"seit\": int(st.started_at or t0),", "        \"seit\": int(t0) + 5,"),
    ("B", "    return _st_api()\n", "    return _st_download_test()\n"),
    ("B", "\"error\": err.get(\"msg\") if not rec and isinstance(err, dict) else None}", "\"error\": None}"),
    ("N", "    r = _st.run(manual=True, wait=100)\n", "    r = _st.run(manual=True, wait=99)\n"),
    ("N", "\n\nif __name__ == \"__main__\":\n    # sourceWatch final", "\napp.view_functions[\"st_api\"] = _st_api\n\nif __name__ == \"__main__\":\n    # sourceWatch final"),
    ("L", "      for(var k=0;k<50;k++){", "      for(var k=0;k<5000;k++){"),
    ("L", "          if(L.down!=null && (L.t||0)>=seit){", "          if(L.down!=null){"),
    ("L", "          if(s.running) continue;", "          if(s.running) break;"),
    ("L", "    if(r.status===202 || d.running){", "    if(d.running && false){"),
    ("L", "        await new Promise(function(res){ setTimeout(res,3000); });", "        await new Promise(function(res){ setTimeout(res,300); });"),
    ("LO", "  <div class=\"small\">Starlink = Ausfallschutz (ASN/ISP)", "  <div class=\"small\">Starlink = Ausfallschutz  (ASN/ISP)"),
]


def mutate(alt, neu, bp, ep, lp, lpa, lpn):
    B, N, LN = rd(bp), rd(neu), rd(lpn)
    Bs = B.rstrip("\n")
    lo, lnw = load_lp(lp)
    miss = 0
    for i, (where, o, nw) in enumerate(MUT, 1):
        cnt = {"B": lambda: B.count(o), "N": lambda: N.replace(Bs, "", 1).count(o), "L": lambda: lnw.count(o), "LO": lambda: LN.replace(lnw, "", 1).count(o)}[where]()
        if cnt != 1:
            print("UEBERSEHEN Mutation %d Stelle nicht eindeutig (%d): %r" % (i, cnt, o[:60]))
            miss += 1
            continue
        B2, N2, LN2, lp2t = B, N, LN, rd(lp)
        if where == "B":
            B2 = B.replace(o, nw, 1)
            N2 = N.replace(Bs, B2.rstrip("\n"), 1)
        elif where == "N":
            i0 = N.index(Bs)
            pre, post = N[:i0], N[i0 + len(Bs):]
            N2 = (pre.replace(o, nw, 1) + Bs + post) if o in pre else (pre + Bs + post.replace(o, nw, 1))
        elif where == "L":
            LN2 = LN.replace(lnw, lnw.replace(o, nw, 1), 1)
            lp2t = lp2t.replace(o, nw, 1)
        else:
            LN2 = LN.replace(o, nw, 1)
        with tempfile.TemporaryDirectory() as d:
            bp2, np2, lpn2, lpp2 = os.path.join(d, "blk.py"), os.path.join(d, "dash.py"), os.path.join(d, "lage_pages.py"), os.path.join(d, "edits_lp.py")
            open(bp2, "w", encoding="utf-8").write(B2)
            open(np2, "w", encoding="utf-8").write(N2)
            open(lpn2, "w", encoding="utf-8").write(LN2)
            open(lpp2, "w", encoding="utf-8").write(lp2t)
            try:
                n, f = check(alt, np2, bp2, ep, lpp2, lpa, lpn2)
            except Exception as e:
                f = ["Ausnahme %s: %s" % (type(e).__name__, e)]
        print("%s Mutation %2d: %s" % ("OK" if f else "UEBERSEHEN", i, (f[0] if f else o.strip()[:60])[:110]))
        miss += 0 if f else 1
    print("%s Mutationstest speedAsync: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", len(MUT), miss))
    return miss


if __name__ == "__main__":
    cmd = sys.argv[1]
    dp = lambda d, f="dashboard.py": os.path.join(d, f)
    if cmd == "revert":
        nd, ad, bp, ep, lp = sys.argv[2:7]
        open(dp(ad), "w", encoding="utf-8").write(revert_text(rd(dp(nd)), rd(bp), load_edits(ep)))
        open(dp(ad, "lage_pages.py"), "w", encoding="utf-8").write(revert_lp(rd(dp(nd, "lage_pages.py")), lp))
        print("OK Rueckbau speedAsync byte-genau erzeugt (dashboard.py, lage_pages.py)")
    elif cmd == "check":
        ad, nd, bp, ep, lp = sys.argv[2:7]
        n, f = check(dp(ad), dp(nd), bp, ep, lp, dp(ad, "lage_pages.py"), dp(nd, "lage_pages.py"))
        for x in f:
            print("FEHLER", x)
        print("%s Guard speedAsync: %d Pruefungen, %d Fehler (Rueckbau byte-genau, nur Block vor __main__ + measureDownload in page_pi, speedTest-Funktionen unveraendert, kein Netz/Senden im Block, Verhalten mit echtem speedtest_run: 202 sofort, 1 Messung, Ergebnis wie bisher uebernommen; Seitenskript per node)" % ("OK" if not f else "FEHLER", n, len(f)))
        sys.exit(1 if f else 0)
    elif cmd == "mutate":
        nd, bp, ep, lp = sys.argv[2:6]
        ad = os.environ["RH_ALT"]
        sys.exit(1 if mutate(dp(ad), dp(nd), bp, ep, lp, dp(ad, "lage_pages.py"), dp(nd, "lage_pages.py")) else 0)
MK_C47_RAG_EOF
EXPECT_RLP="b01bf749588603f6049cb83d2a8d8fc6f293ac56aada282e32e1b1e5460739d7"
cat > "$W/edits_lp.py" << 'MK_C47_RLP_EOF'
# speedAsync (commit47): lage_pages.py PAGE_PI - measureDownload() wartet nicht mehr auf eine blockierende Anfrage, sondern fragt den Status ab
LP_OLD = r'''  if(st){ st.style.color="#94a3b8"; st.textContent="Messe … (bis ~15s)"; }
  try{
    var r=await fetch("/api/download_test");
    var d=await r.json();
    if(st){
      if(d.ok){
        st.style.color="#22c55e";
        st.textContent="✓ "+d.mbps+" Mbit/s · "+(d.at||"");
        setTimeout(function(){ /* location.reload aus */ }, 800);
      } else {
        st.style.color="#ef4444";
        st.textContent="✗ Messung fehlgeschlagen";
      }
    }
  }catch(e){
    if(st){ st.style.color="#ef4444"; st.textContent="Netzwerkfehler"; }
  }
  if(btn) btn.disabled=false;
}
'''
LP_NEW = r'''  if(st){ st.style.color="#94a3b8"; st.textContent="Messe … (bis ~60s)"; }
  try{
    var r=await fetch("/api/download_test");
    var d=await r.json();
    if(r.status===202 || d.running){
      /* speedAsync: Messung laeuft im Hintergrund - Status abfragen (alle 3 s, hoechstens 150 s) */
      var seit=d.seit||0;
      d={ok:false};
      for(var k=0;k<50;k++){
        await new Promise(function(res){ setTimeout(res,3000); });
        try{
          var s=await (await fetch("/api/speedtest")).json();
          if(s.running) continue;
          var L=s.last||{};
          if(L.down!=null && (L.t||0)>=seit){ d={ok:true,mbps:L.down,at:L.at}; }
          else { d={ok:false,error:(s.last_error||{}).msg}; }
          break;
        }catch(e2){}
      }
    }
    if(st){
      if(d.ok){
        st.style.color="#22c55e";
        st.textContent="✓ "+d.mbps+" Mbit/s · "+(d.at||"");
        setTimeout(function(){ /* location.reload aus */ }, 800);
      } else {
        st.style.color="#ef4444";
        st.textContent="✗ Messung fehlgeschlagen";
      }
    }
  }catch(e){
    if(st){ st.style.color="#ef4444"; st.textContent="Netzwerkfehler"; }
  }
  if(btn) btn.disabled=false;
}
'''
MK_C47_RLP_EOF
EXPECT_RLQ="f8696a8e6304856b4cef607d745b390262e4afbe1714351d52b7ea81ce0ae5e9"
cat > "$W/lp.py" << 'MK_C47_RLQ_EOF'
"""Patcher speedAsync fuer lage_pages.py (commit47): ersetzt genau die Stelle measureDownload() (LP_OLD -> LP_NEW). Aufruf: lp.py QUELLE ZIEL EDITS.
Idempotent: schon neu -> Ziel = Quelle. Exit 0 ok, 2 Stelle nicht eindeutig/teilweise. Schreibt nur ZIEL."""
import sys
src, dst, ep = sys.argv[1:4]
g = {}
exec(compile(open(ep, encoding="utf-8").read(), ep, "exec"), g)
o, n = g["LP_OLD"], g["LP_NEW"]
s = open(src, encoding="utf-8").read()
co, cn = s.count(o), s.count(n)
if cn == 1 and co == 0:
    open(dst, "w", encoding="utf-8").write(s)
    print("lage_pages.py: speedAsync schon drin")
elif co == 1 and cn == 0:
    open(dst, "w", encoding="utf-8").write(s.replace(o, n, 1))
    print("lage_pages.py: 1 Stelle speedAsync (measureDownload)")
else:
    print("lage_pages.py: Stelle nicht eindeutig (alt %d, neu %d)" % (co, cn))
    raise SystemExit(2)
MK_C47_RLQ_EOF
EXPECT_RDS="c5084e5c3168b523286f9c05e8d3628172c4f02b666ad6b81c7065b7f1a3b7c9"
cat > "$W/deadsdr.py" << 'MK_C47_RDS_EOF'
"""deadSdr (commit41): entfernt in prepper_sdr.py genau drei nachweislich ueberdeckte Funktions-Erstfassungen (toter Code).
Nachweis je Name (AST): erste Fassung ist eine Top-Level-def ohne Dekorator; dieselbe Modulebene bindet den Namen spaeter neu (def oder Zuweisung);
zwischen beiden Stellen liest kein Modul-Code den Namen und es laeuft dort kein Modul-Code ausser re.compile/set (kann keine Funktion aufrufen);
keine Zeichenkette nennt den Namen (kein globals()/getattr-Zugriff). Damit ist die erste Fassung nie erreichbar - Verhalten unveraendert.
Aufruf: deadsdr.py patch ALT NEU | proof ALT | check ALT NEU | mutate ALT NEU"""
import ast, os, sys, tempfile

NAMES = ("stk_run_cmds", "stk_test_stick", "_at_start")
SAFE_CALLS = ("re.compile", "set")
rd = lambda p: open(p, encoding="utf-8").read()


def bindings(t, name):
    out = []
    for i, n in enumerate(t.body):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.name == name:
            out.append(i)
        elif isinstance(n, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            tg = n.targets if isinstance(n, ast.Assign) else [n.target]
            if any(isinstance(x, ast.Name) and x.id == name for t2 in tg for x in ast.walk(t2)):
                out.append(i)
        elif isinstance(n, (ast.Import, ast.ImportFrom)) and any((a.asname or a.name.split(".")[0]) == name for a in n.names):
            out.append(i)
        elif not isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if any(isinstance(x, ast.Name) and x.id == name and isinstance(x.ctx, ast.Store) for x in ast.walk(n)):
                out.append(i)
    return out


def proof(src):
    """-> (ok, Liste (name, start, end) der toten Erstfassungen, Befunde)"""
    t = ast.parse(src)
    res, bad = [], []
    strs = [n.value for n in ast.walk(t) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    for name in NAMES:
        b = bindings(t, name)
        if len(b) < 2:
            bad.append("%s: keine zweite Bindung (%d)" % (name, len(b)))
            continue
        a, z = b[0], b[1]
        n = t.body[a]
        if not isinstance(n, ast.FunctionDef) or n.decorator_list:
            bad.append("%s: Erstfassung keine schlichte def" % name)
            continue
        for d in n.args.defaults + [x for x in n.args.kw_defaults if x is not None]:
            if not isinstance(d, ast.Constant):
                bad.append("%s: Default-Wert nicht konstant" % name)
        for m in t.body[a + 1:z]:
            if isinstance(m, (ast.FunctionDef, ast.AsyncFunctionDef)):
                ex = m.decorator_list + m.args.defaults + [x for x in m.args.kw_defaults if x is not None]
                if m.returns is not None:
                    ex.append(m.returns)
                for x in ex:
                    for y in ast.walk(x):
                        if isinstance(y, (ast.Call, ast.Lambda)) or (isinstance(y, ast.Name) and y.id == name):
                            bad.append("%s: Dekorator/Default bei Z.%d fuehrt Code aus" % (name, m.lineno))
                            break
                continue
            for y in ast.walk(m):
                if isinstance(y, ast.Name) and y.id == name:
                    bad.append("%s: Modul-Code liest den Namen bei Z.%d" % (name, y.lineno))
                if isinstance(y, ast.Call) and ast.unparse(y.func) not in SAFE_CALLS:
                    bad.append("%s: Modul-Code ruft %s bei Z.%d" % (name, ast.unparse(y.func)[:40], y.lineno))
                if isinstance(y, (ast.Lambda, ast.ClassDef)):
                    bad.append("%s: Klasse/Lambda auf Modulebene bei Z.%d" % (name, y.lineno))
        if any(name in s for s in strs):
            bad.append("%s: Name steht in einer Zeichenkette (dynamischer Zugriff moeglich)" % name)
        res.append((name, n.lineno, n.end_lineno))
    return not bad, res, bad


def patch(src):
    t = ast.parse(src)
    done = all(len(bindings(t, n)) == 1 for n in NAMES)
    if done:
        return src, "schon drin"
    ok, res, bad = proof(src)
    if not ok:
        raise SystemExit("STOP Nachweis: " + "; ".join(bad))
    L = src.split("\n")
    drop = set()
    for name, a, z in res:
        for k in range(a - 1, z):
            drop.add(k)
        assert L[z] == "" and L[z + 1] == "", name
        drop.update((z, z + 1))
    out = "\n".join(l for k, l in enumerate(L) if k not in drop)
    return out, "%d Erstfassungen entfernt (%d Zeilen): %s" % (len(res), len(drop), ", ".join("%s Z.%d-%d" % r for r in res))


def check(alt, neu):
    A, N = rd(alt), rd(neu)
    fails, n = [], 0

    def ok(c, m):
        nonlocal n
        n += 1
        if not c:
            fails.append(m)
    pk, res, bad = proof(A)
    ok(pk and len(res) == 3, "Nachweis an der Basis: %s" % bad)
    try:
        tA, tN = ast.parse(A), ast.parse(N)
    except SyntaxError as e:
        return n + 1, fails + ["Syntax %s" % e]
    gone = {r[1] for r in res}
    exp = [ast.dump(x) for x in tA.body if x.lineno not in gone]
    ok([ast.dump(x) for x in tN.body] == exp, "AST: neu ist nicht genau Basis minus die 3 Erstfassungen")
    for name in NAMES:
        ok(len(bindings(tN, name)) == len(bindings(tA, name)) - 1 and len(bindings(tN, name)) >= 1, "Bindungen %s" % name)
        bA, bN = bindings(tA, name)[-1], bindings(tN, name)[-1]
        ok(ast.dump(tA.body[bA]) == ast.dump(tN.body[bN]), "letzte Fassung %s veraendert" % name)
    try:
        ok(patch(A)[0] == N, "Patcher ergibt nicht genau NEU")
    except SystemExit as e:
        ok(False, str(e))
    ok(N.count("\n\n\n\n") == A.count("\n\n\n\n"), "Leerzeilen-Struktur veraendert")
    ok(len(A.splitlines()) - len(N.splitlines()) == sum(z - a + 3 for _, a, z in res), "Zeilenzahl")
    return n, fails


def mutate(alt, neu):
    A, N = rd(alt), rd(neu)
    i0 = N.index("\ndef stk_write_atomic(")
    i1 = N.index("\ndef _at_finish(")
    MUT = [
        ("andere Funktion mit entfernt", N.replace("\n\ndef _fmt1(v):\n    return (\"%.1f\" % v) if isinstance(v, (int, float)) else \"–\"\n", "", 1)),
        ("Konstante geaendert", N.replace("STK_TOOLS = (\"rtl_433\"", "STK_TOOLS = (\"rtl_4330\"", 1)),
        ("Zeile in letzter Fassung", N.replace("_at_start = _ag_start", "_at_start = _ag_start or None", 1)),
        ("Aufruf zwischen eingefuegt", N[:i0] + "\nprint('x')" + N[i0:]),
        ("Kommentar statt Leerzeile", N[:i1] + "\n# x" + N[i1:]),
        ("Leerzeile zuviel", N[:i1] + "\n" + N[i1:]),
        ("nichts entfernt", A),
    ]
    PMUT = [  # Nachweis muss an manipulierter Basis scheitern
        ("Modul-Aufruf zwischen den Fassungen", A.replace("\nSTK_TOOLS = (", "\nselftest_sticktest()\nSTK_TOOLS = (", 1)),
        ("Name in Zeichenkette", A.replace("_STK_AUDIO = re.compile(", "_X = 'stk_run_cmds'\n_STK_AUDIO = re.compile(", 1)),
        ("Dekorator an Erstfassung", A.replace("\ndef stk_test_stick(pl,", "\n@staticmethod\ndef stk_test_stick(pl,", 1)),
        ("Namensbindung gelesen", A.replace("\ndef _at_finish(", "\n_keep = _at_start\n\n\ndef _at_finish(", 1)),
        ("keine Zweitfassung", A.replace("\n_at_start = _ag_start\n", "\n_at_start2 = _ag_start\n", 1)),
    ]
    miss = 0
    with tempfile.TemporaryDirectory() as d:
        for k, (nm, txt) in enumerate(MUT, 1):
            p = os.path.join(d, "n.py")
            open(p, "w", encoding="utf-8").write(txt)
            try:
                _, f = check(alt, p)
            except Exception as e:
                f = ["Ausnahme %s" % e]
            print("%s Mutation %2d (%s)%s" % ("OK" if f and txt != N else "UEBERSEHEN", k, nm, (": " + f[0][:90]) if f else ""))
            miss += 0 if (f and txt != N) else 1
        for k, (nm, txt) in enumerate(PMUT, len(MUT) + 1):
            try:
                pk, _, bad = proof(txt)
            except Exception as e:
                pk, bad = False, ["Ausnahme %s" % e]
            hit = (not pk) and txt != A
            print("%s Mutation %2d (Nachweis: %s)%s" % ("OK" if hit else "UEBERSEHEN", k, nm, (": " + bad[0][:90]) if bad else ""))
            miss += 0 if hit else 1
    tot = len(MUT) + len(PMUT)
    print("%s Mutationstest deadSdr: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", tot, miss))
    return miss


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "patch":
        out, msg = patch(rd(sys.argv[2]))
        open(sys.argv[3], "w", encoding="utf-8").write(out)
        print("prepper_sdr.py: deadSdr " + msg)
    elif c == "proof":
        pk, res, bad = proof(rd(sys.argv[2]))
        for r in res:
            print("tot: %s Z.%d-%d (%d Zeilen)" % (r[0], r[1], r[2], r[2] - r[1] + 1))
        for b in bad:
            print("BEFUND", b)
        sys.exit(0 if pk else 1)
    elif c == "check":
        n, f = check(sys.argv[2], sys.argv[3])
        for x in f:
            print("FEHLER", x)
        print("%s Guard deadSdr: %d Pruefungen, %d Fehler (Nachweis tot/ueberdeckt, AST = Basis minus 3 Erstfassungen, letzte Fassungen byte-gleich im AST)" % ("OK" if not f else "FEHLER", n, len(f)))
        sys.exit(1 if f else 0)
    elif c == "mutate":
        sys.exit(1 if mutate(sys.argv[2], sys.argv[3]) else 0)
MK_C47_RDS_EOF
EXPECT_RBA="597ba78a5d0ed71d73e7ef4b6cd563565811ae21065ade8903dffddffa732a4c"
cat > "$W/bakarch.py" << 'MK_C47_RBA_EOF'
"""bakArch (commit47): alte Sicherungsdateien (*.bak*) im Projektordner in einen datierten Archivordner VERSCHIEBEN (nie loeschen).
Bleiben liegen: je Ursprungsdatei UND Patch-Name (Teil zwischen ".bak-" und "-<Ziffer>", z. B. dashboard.py.bak-perf03cache-20261031-072307)
die 3 neuesten (nach Aenderungszeit) - genau die, die die Apply-Skripte selbst behalten (Rueckwege bleiben gueltig).
Nur oberste Ebene, nur normale Dateien (keine Links, keine Ordner). Zusaetzlich: ~ip-Reste (abgebrochenes pip-Update) aus venv site-packages ins Archiv.
Aufruf: bakarch.py plan DIR PLAN.tsv | move DIR ARCH PLAN.tsv | verify DIR ARCH | undo DIR ARCH | tilde VENV ARCH [dry] | tundo VENV ARCH | selftest | mutate"""
import os, re, stat, sys, tempfile, time

KEEP = 3
BAKRE = re.compile(r"^(.+?)\.bak(?:$|[-._~])")
TAGRE = re.compile(r"\.bak-([A-Za-z][A-Za-z0-9_.-]*?)-\d")
TILDE = re.compile(r"^~ip")


def tag(nm):
    m = TAGRE.search(nm)
    return m.group(1) if m else ""


def scan(d):
    groups = {}
    for nm in sorted(os.listdir(d)):
        m = BAKRE.match(nm)
        if not m:
            continue
        st = os.lstat(os.path.join(d, nm))
        if not stat.S_ISREG(st.st_mode):
            continue
        groups.setdefault((m.group(1), tag(nm)), []).append((nm, st.st_mtime, st.st_size))
    return groups


def plan(d):
    mv, keep = [], []
    for org, fs in sorted(scan(d).items()):
        rest = sorted(fs, key=lambda f: (f[1], f[0]), reverse=True)
        keep += [(org, f, "neueste") for f in rest[:KEEP]]
        mv += [(org, f) for f in rest[KEEP:]]
    return mv, keep


def write_plan(d, pf):
    mv, keep = plan(d)
    with open(pf, "w", encoding="utf-8") as f:
        for org, (nm, mt, sz) in mv:
            if "\t" in nm or "\n" in nm:
                raise SystemExit("STOP Dateiname mit Tab/Zeilenumbruch: %r" % nm)
            f.write("%s\t%d\t%d\n" % (nm, int(mt), sz))
    return mv, keep


def read_plan(pf):
    out = []
    for l in open(pf, encoding="utf-8"):
        nm, mt, sz = l.rstrip("\n").split("\t")
        out.append((nm, int(mt), int(sz)))
    return out


def move(d, arch, pf):
    files = os.path.join(arch, "files")
    os.makedirs(files, exist_ok=True)
    if os.stat(d).st_dev != os.stat(files).st_dev:
        raise SystemExit("STOP Archiv liegt auf einem anderen Dateisystem")
    man = os.path.join(arch, "MANIFEST.tsv")
    done = 0
    with open(man, "a", encoding="utf-8") as mf:
        for nm, mt, sz in read_plan(pf):
            src, dst = os.path.join(d, nm), os.path.join(files, nm)
            st = os.lstat(src)
            if int(st.st_mtime) != mt or st.st_size != sz:
                raise SystemExit("STOP %s hat sich seit dem Plan geaendert" % nm)
            if os.path.lexists(dst):
                raise SystemExit("STOP Ziel existiert schon: %s" % dst)
            os.rename(src, dst)
            mf.write("%s\t%d\t%d\n" % (nm, mt, sz))
            mf.flush()
            done += 1
    return done


def verify(d, arch):
    files = os.path.join(arch, "files")
    bad, n = [], 0
    for nm, mt, sz in read_plan(os.path.join(arch, "MANIFEST.tsv")):
        n += 1
        p = os.path.join(files, nm)
        if not os.path.isfile(p) or os.path.getsize(p) != sz or int(os.path.getmtime(p)) != mt:
            bad.append("im Archiv falsch: " + nm)
        if os.path.lexists(os.path.join(d, nm)):
            bad.append("noch im Projektordner: " + nm)
    extra = sorted(set(os.listdir(files)) - {x[0] for x in read_plan(os.path.join(arch, "MANIFEST.tsv"))})
    if extra:
        bad.append("unerwartet im Archiv: %s" % extra[:3])
    return n, bad


def undo(d, arch):
    files = os.path.join(arch, "files")
    n = 0
    for nm in sorted(os.listdir(files)):
        dst = os.path.join(d, nm)
        if os.path.lexists(dst):
            raise SystemExit("STOP Rueckweg: %s existiert im Projektordner schon" % nm)
        os.rename(os.path.join(files, nm), dst)
        n += 1
    return n


def _sp_dirs(venv):
    import glob
    return sorted(p for p in glob.glob(os.path.join(venv, "lib", "python3*", "site-packages")) if os.path.isdir(p) and not os.path.islink(p))


def tilde_plan(venv):
    """-> (zu verschieben [(site-packages, name)], Befunde). Nur ~ip*-Eintraege, nur eigene, nur wenn das echte pip daneben liegt."""
    out, notes = [], []
    for sp in _sp_dirs(venv):
        for nm in sorted(os.listdir(sp)):
            if not TILDE.match(nm):
                continue
            p = os.path.join(sp, nm)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                notes.append("Link uebersprungen: " + nm)
            elif st.st_uid != os.getuid():
                notes.append("fremder Besitzer uebersprungen: " + nm)
            elif not os.path.isdir(os.path.join(sp, "pip")):
                notes.append("pip fehlt neben %s - nicht angefasst" % nm)
            else:
                out.append((sp, nm))
    return out, notes


def tilde(venv, arch, dry=False):
    mv, notes = tilde_plan(venv)
    if dry:
        return len(mv), notes
    dst0 = os.path.join(arch, "venv-rest")
    os.makedirs(dst0, exist_ok=True)
    with open(os.path.join(arch, "VENV.tsv"), "a", encoding="utf-8") as mf:
        for sp, nm in mv:
            if os.stat(sp).st_dev != os.stat(dst0).st_dev:
                raise SystemExit("STOP Archiv liegt auf einem anderen Dateisystem")
            rel = os.path.relpath(sp, venv)
            dd = os.path.join(dst0, rel)
            os.makedirs(dd, exist_ok=True)
            if os.path.lexists(os.path.join(dd, nm)):
                raise SystemExit("STOP Ziel existiert schon: %s" % nm)
            os.rename(os.path.join(sp, nm), os.path.join(dd, nm))
            mf.write("%s\t%s\n" % (rel, nm))
            mf.flush()
    return len(mv), notes


def tundo(venv, arch):
    n = 0
    mp = os.path.join(arch, "VENV.tsv")
    if not os.path.exists(mp):
        return 0
    for l in open(mp, encoding="utf-8"):
        rel, nm = l.rstrip("\n").split("\t")
        src, dst = os.path.join(arch, "venv-rest", rel, nm), os.path.join(venv, rel, nm)
        if not os.path.lexists(src):
            continue
        if os.path.lexists(dst):
            raise SystemExit("STOP Rueckweg: %s existiert in site-packages schon" % nm)
        os.rename(src, dst)
        n += 1
    return n


def selftest():
    with tempfile.TemporaryDirectory() as t:
        d, arch = os.path.join(t, "proj"), os.path.join(t, "archiv", "x")
        os.makedirs(d)
        now = time.time()
        names = (["dashboard.py.bak-aa-202601%02d-000000" % (i + 1) for i in range(8)] + ["dashboard.py.bak-relstop-2026102%d-232356" % i for i in range(5)] +
                 ["dashboard.py.bak-sdr-stick3e-2026101%d-1" % i for i in range(4)] + ["prepper_docs.py.bak-docsver-20261028-1", "prepper_docs.py.bak-x",
                 "sdr_config.json.bak-swap-1", "sdr_config.json.bak-swap-2", "a.bak", "a.bak.1", "a.bak_2", "a.bak~", "a.bakery", "dashboard.py", "bak.txt"])
        for i, nm in enumerate(names):
            p = os.path.join(d, nm)
            open(p, "w").write(nm)
            os.utime(p, (now - 1000 + i, now - 1000 + i))
        os.makedirs(os.path.join(d, "x.bak-dir"))
        os.symlink("dashboard.py", os.path.join(d, "l.bak-1"))
        os.utime(os.path.join(d, "dashboard.py.bak-relstop-20261024-232356"), (now - 5000, now - 5000))
        assert tag("dashboard.py.bak-perf03cache-20261031-072307") == "perf03cache" and tag("x.bak-sdr-stick3e-1") == "sdr-stick3e" and tag("a.bak") == "", "Patch-Name"
        pf = os.path.join(t, "plan.tsv")
        mv, keep = write_plan(d, pf)
        mvn = sorted(f[0] for _, f in mv)
        exp = (["dashboard.py.bak-aa-202601%02d-000000" % (i + 1) for i in range(5)] + ["a.bak", "dashboard.py.bak-relstop-20261020-232356", "dashboard.py.bak-relstop-20261024-232356",
               "dashboard.py.bak-sdr-stick3e-20261010-1"])
        assert mvn == sorted(exp), mvn
        kept = sorted(f[0] for _, f, _ in keep)
        assert "dashboard.py.bak-relstop-20261023-232356" in kept and "prepper_docs.py.bak-docsver-20261028-1" in kept and "a.bak.1" in kept and "a.bak" not in kept and "sdr_config.json.bak-swap-1" in kept
        assert "a.bakery" not in kept and "bak.txt" not in kept and "l.bak-1" not in kept and "x.bak-dir" not in kept
        os.makedirs(os.path.join(arch, "files"))
        open(os.path.join(arch, "files", "a.bak"), "w").write("alt")
        try:
            move(d, arch, pf)
            raise AssertionError("Ziel im Archiv vorhanden: kein STOP")
        except SystemExit:
            pass
        assert open(os.path.join(arch, "files", "a.bak")).read() == "alt" and os.path.isfile(os.path.join(d, "a.bak")), "Archiv-Datei ueberschrieben"
        os.remove(os.path.join(arch, "files", "a.bak"))
        os.remove(os.path.join(arch, "MANIFEST.tsv"))
        assert move(d, arch, pf) == 9
        n, bad = verify(d, arch)
        assert n == 9 and not bad, bad
        open(os.path.join(d, "a.bak"), "w").write("neu")
        assert any("noch im Projektordner" in x for x in verify(d, arch)[1]), "verify erkennt Rest im Projektordner nicht"
        os.remove(os.path.join(d, "a.bak"))
        mv2, _ = write_plan(d, pf)
        assert mv2 == [], "nicht idempotent"
        assert undo(d, arch) == 9 and sorted(os.listdir(d)) == sorted(names + ["x.bak-dir", "l.bak-1"])
        v = os.path.join(t, "venv")
        sp = os.path.join(v, "lib", "python3.11", "site-packages")
        for x in ("pip", "~ip", "~ip-23.0.dist-info", "flask", "~lask"):
            os.makedirs(os.path.join(sp, x))
        open(os.path.join(sp, "~ip", "f.py"), "w").write("x")
        assert tilde(v, arch, dry=True)[0] == 2 and os.path.isdir(os.path.join(sp, "~ip")), "Trockenlauf aendert nichts"
        assert tilde(v, arch)[0] == 2 and sorted(os.listdir(sp)) == ["flask", "pip", "~lask"], os.listdir(sp)
        assert os.path.isfile(os.path.join(arch, "venv-rest", "lib", "python3.11", "site-packages", "~ip", "f.py")), "Archiv venv"
        assert tilde(v, arch)[0] == 0, "venv nicht idempotent"
        assert tundo(v, arch) == 2 and sorted(os.listdir(sp)) == ["flask", "pip", "~ip", "~ip-23.0.dist-info", "~lask"]
        os.rename(os.path.join(sp, "pip"), os.path.join(sp, "pip_x"))
        n2, notes = tilde(v, os.path.join(t, "a2"))
        assert n2 == 0 and os.path.isdir(os.path.join(sp, "~ip")) and any("pip fehlt" in x for x in notes), "ohne pip nichts anfassen"
    return "bakArch selftest ok (je Datei und Patch-Name die 3 neuesten bleiben, nur normale Dateien, verschieben/pruefen/zurueck, idempotent; ~ip-Rest nur mit pip daneben)"


MUT = [("KEEP = 3", "KEEP = 2"), ("if not stat.S_ISREG(st.st_mode):", "if False:"),
       ("(?:$|[-._~])", "(?:$|[-._~a-z])"), ("reverse=True)", "reverse=False)"), ("            os.rename(src, dst)\n", "            os.link(src, dst)\n"),
       ("            if os.path.lexists(dst):\n                raise SystemExit", "            if False:\n                raise SystemExit"),
       ("        if os.path.lexists(os.path.join(d, nm)):\n            bad.append", "        if False:\n            bad.append"),
       ("rest[KEEP:]", "rest[KEEP + 1:]"), ("        os.rename(os.path.join(files, nm), dst)\n", "        pass\n"),
       ("setdefault((m.group(1), tag(nm))", "setdefault((m.group(1), \"\")"), ("A-Za-z0-9_.-]*?)", "A-Za-z0-9_.]*?)"),
       ('TILDE = re.compile(r"^~ip")', 'TILDE = re.compile(r"^~")'), ("elif not os.path.isdir(os.path.join(sp, \"pip\")):", "elif False:"),
       ("    if dry:\n        return len(mv), notes", "    if False:\n        return len(mv), notes"), ("        os.rename(src, dst)\n        n += 1", "        n += 1")]


def mutate():
    import subprocess
    src = open(os.path.abspath(__file__), encoding="utf-8").read()
    miss = 0
    with tempfile.TemporaryDirectory() as t:
        for i, (o, n) in enumerate(MUT, 1):
            if src.count(o) < 1:
                print("UEBERSEHEN Mutation %d Stelle fehlt" % i); miss += 1; continue
            p = os.path.join(t, "m.py")
            open(p, "w", encoding="utf-8").write(src.replace(o, n, 1))
            r = subprocess.run([sys.executable, p, "selftest"], capture_output=True, text=True, timeout=60)
            hit = r.returncode != 0
            print("%s Mutation %2d: %s" % ("OK" if hit else "UEBERSEHEN", i, o.strip()[:50]))
            miss += 0 if hit else 1
    print("%s Mutationstest bakArch: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", len(MUT), miss))
    return miss


if __name__ == "__main__":
    c = sys.argv[1]
    if c == "mutate":
        sys.exit(1 if mutate() else 0)
    if c == "plan":
        mv, keep = write_plan(sys.argv[2], sys.argv[3])
        tot = sum(f[2] for _, f in mv)
        groups = {}
        for org, f in mv:
            groups.setdefault("%s [%s]" % (org[0], org[1] or "-"), []).append(f)
        for org in sorted(groups):
            fs = groups[org]
            print("  %-34s %3d Datei(en) %8.1f MB  (%s ... %s)" % (org, len(fs), sum(f[2] for f in fs) / 1e6,
                  time.strftime("%d.%m.%y", time.localtime(min(f[1] for f in fs))), time.strftime("%d.%m.%y", time.localtime(max(f[1] for f in fs)))))
        print("PLAN %d verschieben (%.1f MB), %d bleiben liegen (je Datei und Patch die %d neuesten)" % (len(mv), tot / 1e6, len(keep), KEEP))
    elif c == "move":
        print("MOVED %d" % move(sys.argv[2], sys.argv[3], sys.argv[4]))
    elif c == "verify":
        n, bad = verify(sys.argv[2], sys.argv[3])
        for b in bad[:10]:
            print("FEHLER", b)
        print("%s Archiv: %d Dateien laut MANIFEST, %d Fehler" % ("OK" if not bad else "FEHLER", n, len(bad)))
        sys.exit(1 if bad else 0)
    elif c == "undo":
        print("UNDONE %d" % undo(sys.argv[2], sys.argv[3]))
    elif c == "tilde":
        n, notes = tilde(sys.argv[2], sys.argv[3], dry=len(sys.argv) > 4 and sys.argv[4] == "dry")
        for x in notes:
            print("HINWEIS", x)
        print("TILDE %d" % n)
    elif c == "tundo":
        print("TUNDONE %d" % tundo(sys.argv[2], sys.argv[3]))
    elif c == "selftest":
        print(selftest())
MK_C47_RBA_EOF
EXPECT_RFC="192f3b9b1c0f6418378a21a5812385fe44ddd92eca19bcd8860c7a0c2e7237bb"
cat > "$W/fullcheck.sh" << 'MK_C47_RFC_EOF'
#!/usr/bin/env bash
# fullcheck.sh - Gesamtpruefung "Lage Pi" (BND-Prepper): Pi, Dienste, Dashboard, Patch-Stand (bis commit47), NINA-Zertifikatskette, Mesh, SDR, DB, Backups, Sicherheit, Journal
# Aufruf:  bash fullcheck.sh [--kurz] [--json] [--sudo] [--no-color] [--help] | --selftest | --version      (auch: bash ~/fullcheck.sh)
# Strikt nur lesend: aendert nichts am System, am Projekt, am Dashboard oder an der Datenbank, startet nichts neu, sendet nichts (kein Mesh, kein Telegram,
# keine Alarme, keine Mail, keine POSTs), oeffnet keine SDR-Sticks, scannt kein Netz, zeigt nie Schluessel/Passwoerter/Tokens, schreibt keine Dateien (auch keine temporaeren).
# Stufen: OK, HINWEIS (Abweichung/Beobachten), FEHLER (Handlungsbedarf), INFO, SKIP.   Exit-Code: 0 = alles OK, 1 = mindestens ein HINWEIS, 2 = mindestens ein FEHLER, 64 = falscher Aufruf.
# shellcheck disable=SC2015  # ok/warn/fail/info/skip liefern immer 0: "A && ok .. || warn .." ist hier exakt if-then-else
set -u
export LC_ALL=C.UTF-8
export TZ=Europe/Berlin
export PYTHONDONTWRITEBYTECODE=1
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin:/usr/local/bin"

FC_VERSION="2.0.2"
T0=$SECONDS

# ---------------------------------------------------------------- Konfiguration (Umgebungsvariablen FC_* nur fuer Tests/Sonderfaelle)
APP="${FC_APP:-/home/fmg/prepper-dashboard}"
BACKUPS="${FC_BACKUPS:-/home/fmg/prepper-backups}"
HOSTN="${FC_HOST:-127.0.0.1}"
PORT="${FC_PORT:-5000}"
BR1_PORT="${FC_BRIDGE1_PORT:-5001}"
BR2_PORT="${FC_BRIDGE2_PORT:-5002}"
NTP_HOST="${FC_NTP_HOST:-192.168.178.15}"
GPSD_PORT="${FC_GPSD_PORT:-2947}"
PROC="${FC_PROC:-/proc}"
SYS="${FC_SYS:-/sys}"
DROPIN_DIR="${FC_DROPIN_DIR:-/etc/systemd/system/prepper-dashboard.service.d}"
DASH_SHA16="${FC_DASH_SHA16:-74ac7bfd0eebd4e0}"   # Soll nach commit47 speedAsync (31.10.2026), 22340 Zeilen; vorher bb94f52af6e03c3b nach commit37
PYBIN="${FC_PY:-python3}"
VENV_PY="${FC_VENV_PY:-$APP/venv/bin/python}"
BUDGET_S="${FC_BUDGET_S:-50}"                      # nach so vielen Sekunden werden restliche Seitentests uebersprungen
QC_MAX_MB="${FC_QC_MAX_MB:-64}"                    # quick_check live nur bei kleinerer Datenbank (sonst Cache der DB-Wartung)
SLOT_MAX_S=$((3 * 3600 + 10 * 60))                 # Auto-Stempel Wetter: hoechstens 3 h 10 min alt

SERVICES=(prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern)
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte
       /api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events
       /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
MARKERS=(relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync)   # je genau 1x "# ===== <Name>:"
NINA_PEM_REL="certs/sectigo-e36.pem"; NINA_PEM_DER16="873f0ba8"   # DER-sha256 beginnt so (Sectigo Public Server Authentication CA DV E36)
# Referenz-sha16 weiterer Dateien laut AUDIT-STAND.md (NICHT als bestaetigt gefuehrt -> nur Anzeige): "Pfad:sha16"
REFS=(database.py:e7a7ef192c522480 lage_xml.py:f77305fc17ed2f77 mesh_bridge.py:3482f6e386cf26ce mesh_bridge_bayern.py:c1176b457346ae49
      mesh_bridge_core.py:ddc134f29a6a8949 luft.py:0ccae0834ab27f6d secret_util.py:ff8e2ac7049f4bde tools/backup.sh:5053f6b8a43a8638
      tools/restore.sh:c0e305b8ea4d9007 health_check.py:5a0156ff02d5960c prepper_docs.py:609f0a7f00ab586b lage_clock.py:c909aea1148518fe lage_disk.py:4b6b35ab7c97dfc7)
AIRSPY_VIDPID="1d50:60a1"; AIRSPY_SN="637862DC2E8092D7"; STICK1_SN="19348831"; STICK2_SN="72055505"; STICK3_SN="26102403"

# ---------------------------------------------------------------- Optionen
QUICK=0; JSON=0; SUDO=0; NOCOL=0; SELFTEST=0
[[ -n "${NO_COLOR:-}" ]] && NOCOL=1

usage() {
  cat <<'EOT'
fullcheck.sh - Gesamtpruefung der Lage Pi (strikt nur lesend: nichts wird veraendert, gesendet oder neu gestartet)

Aufruf:
  bash fullcheck.sh [Optionen]          (oder bash ~/fullcheck.sh)

Optionen:
  --kurz        ohne Seitentest der 26 Seiten/APIs und ohne langsame Pruefungen (quick_check, Archiv-Pruefsumme); Alias: --quick
  --json        Ausgabe maschinenlesbar (ein JSON-Dokument, ohne Secrets); Exit-Code wie sonst.
                Stufen-Schluessel im JSON: ok, warn (= HINWEIS), fail (= FEHLER), info, skip
  --sudo        zusaetzlich lesende Pruefungen mit sudo (nur journalctl und dmesg); fragt einmal nach dem Passwort
  --no-color    keine Farben (auch NO_COLOR=1 wird beachtet; ohne Terminal gibt es nie Farben)
  --selftest    interner Selbsttest der Hilfsfunktionen (ohne Zugriff auf das System)
  --version     Version anzeigen
  --help        diese Hilfe

Stufen: OK, HINWEIS (Abweichung, Beobachten), FEHLER (Handlungsbedarf), INFO (nur Anzeige), SKIP (nicht pruefbar, z. B. braucht sudo).
Der NINA-Zertifikatsketten-Rueckfall (ninaFix, gepinnte Zwischenstelle Sectigo E36) zaehlt als OK bzw. HINWEIS, nie als FEHLER; FEHLER nur, wenn die Kette auch mit dem Rueckfall nicht pruefbar ist.
Punkte: 100 minus 2 je HINWEIS minus 10 je FEHLER (mindestens 0). Exit-Code: 0 = OK, 1 = HINWEIS, 2 = FEHLER, 64 = falscher Aufruf.
Das Skript schreibt keine Dateien, startet nichts neu, sendet nichts und gibt keine Schluessel aus (Ausgaben werden maskiert).
EOT
}

while (( $# > 0 )); do
  case "$1" in
    --kurz|--quick) QUICK=1 ;;
    --json) JSON=1 ;;
    --sudo) SUDO=1 ;;
    --no-color) NOCOL=1 ;;
    --selftest) SELFTEST=1 ;;
    --version) echo "fullcheck.sh $FC_VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "fullcheck.sh: unbekannte Option: ${1:0:40}" >&2; echo "Hilfe: bash fullcheck.sh --help" >&2; exit 64 ;;
  esac
  shift
done

# ---------------------------------------------------------------- Ausgabe-Grundlagen
if [[ -t 1 && "$NOCOL" == 0 && "$JSON" == 0 && "${TERM:-dumb}" != "dumb" ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[1;31m'; C_INFO=$'\033[36m'; C_SKIP=$'\033[90m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_SKIP=""; C_B=""; C_0=""
fi

N_OK=0; N_WARN=0; N_FAIL=0; N_INFO=0; N_SKIP=0
declare -a R_SEC=() R_ST=() R_NAME=() R_DET=() R_HINT=()
CUR_SEC=""
declare -a SECRET_VALS=()

# Werte geheimer Umgebungsvariablen (nur im Speicher) - werden aus JEDER Ausgabe entfernt, falls sie je in einem Text auftauchen sollten
collect_secret_values() {
  local line name val
  while IFS= read -r line; do
    name="${line%%=*}"; val="${line#*=}"
    [[ "$name" =~ (KEY|TOKEN|SECRET|PASS|PWD|CREDENTIAL|AUTH) ]] || continue
    (( ${#val} >= 6 )) || continue
    SECRET_VALS+=("$val")
  done < <(env 2>/dev/null)
}

# einzeilig, ohne Steuerzeichen, Secrets (Umgebungswerte) entfernt, begrenzt
clean() {
  local v="$1" s
  v="${v//[^[:print:]]/ }"
  for s in "${SECRET_VALS[@]}"; do v="${v//"$s"/***}"; done
  [[ "$v" =~ [Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss]|[Pp][Ww][Dd]|[Aa][Uu][Tt][Hh]|[Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc]|[Ss][Ii][Gg] ]] && v="$(mask_keys "$v")"   # Sicherheitsnetz fuer jede Ausgabe
  (( ${#v} > 400 )) && v="${v:0:397}..."
  printf '%s' "$v"
}

# Freitext aus Logs/Diensten: bekannte Schluesselformen maskieren (Parameter, Header, lange Kennungen)
# Stufe 1 (sed): "Authorization: Bearer ...", key=..., token: ..., Bearer/Basic ..., /lange-Kennung in Pfaden, 32+ Zeichen Schluesselalphabet
# Stufe 2 (bash): jedes Wort ab 20 Zeichen aus Buchstaben UND Ziffern (Schluesselalphabet) wird ganz maskiert - auch ohne Schluesselwort davor
mask_keys() {
  printf '%s' "$1" | sed -E \
    -e 's/(authorization[=:] *)(Bearer|Basic) +[^&[:space:]"'"'"'<>,;]+/\1***/Ig' \
    -e 's/((api[_-]?key|apikey|key|token|secret|passwd|password|pwd|auth|authorization|bearer|signature|sig|access[_-]?token)[=:] *)[^&[:space:]"'"'"'<>,;]+/\1***/Ig' \
    -e 's/(Bearer|Basic) +[A-Za-z0-9._~+\/=-]+/\1 ***/Ig' \
    -e 's#/[A-Za-z0-9_-]{24,}#/***#g' \
    -e 's/[A-Za-z0-9+\/_=-]{32,}/***/g' 2>/dev/null
}
mask() {
  local t w out="" sp=""
  t="$(mask_keys "$1")"
  t="${t//$'\n'/ }"; t="${t//$'\t'/ }"
  local -a words=()
  read -r -a words < <(printf '%s' "$t")
  for w in "${words[@]}"; do
    if (( ${#w} >= 20 )) && [[ "$w" =~ [0-9] && "$w" =~ [A-Za-z] && "$w" != *"***"* ]]; then w="***"; fi
    out+="$sp$w"; sp=" "
  done
  printf '%s' "$out"
}

section() {
  CUR_SEC="$1"
  (( JSON )) || printf '\n%s== %s ==%s\n' "$C_B" "$1" "$C_0"
}

_emit() { # status name detail [hint]
  local st="$1" name="$2" det hint col lab
  det="$(clean "${3:-}")"; hint="$(clean "${4:-}")"
  R_SEC+=("$CUR_SEC"); R_ST+=("$st"); R_NAME+=("$name"); R_DET+=("$det"); R_HINT+=("$hint")
  case "$st" in
    ok) N_OK=$((N_OK + 1)); col="$C_OK"; lab="OK     " ;;
    warn) N_WARN=$((N_WARN + 1)); col="$C_WARN"; lab="HINWEIS" ;;
    fail) N_FAIL=$((N_FAIL + 1)); col="$C_FAIL"; lab="FEHLER " ;;
    skip) N_SKIP=$((N_SKIP + 1)); col="$C_SKIP"; lab="SKIP   " ;;
    *) N_INFO=$((N_INFO + 1)); col="$C_INFO"; lab="INFO   " ;;
  esac
  if (( ! JSON )); then
    printf '[%s%s%s] %-30s %s\n' "$col" "$lab" "$C_0" "$name" "$det"
    [[ -n "$hint" ]] && printf '         -> %s\n' "$hint"
  fi
  return 0
}
ok() { _emit ok "$@"; }
warn() { _emit warn "$@"; }
fail() { _emit fail "$@"; }
info() { _emit info "$1" "${2:-}" ""; }
skip() { _emit skip "$1" "${2:-}" ""; }

have() { command -v "$1" >/dev/null 2>&1; }
# grosse Texte nie per Here-String weitergeben (bash legt dafuer ab 64 KB eine temporaere Datei an): immer per Pipe
pf() { printf '%s\n' "$1"; }

# Gleitkomma-Vergleich: fcmp 1.5 '>' 1.2
fcmp() { awk -v a="$1" -v b="$3" "BEGIN{exit !(a $2 b)}" 2>/dev/null; }

# curl time_total ("0.191088") -> ganze Millisekunden
ms_of() {
  local t="$1" s f
  [[ "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo 0; return; }
  s="${t%%.*}"; f="0"; [[ "$t" == *.* ]] && f="${t#*.}"
  f="${f}000"
  echo $((10#$s * 1000 + 10#${f:0:3}))
}

# Sekunden -> "3 T 4 h" / "12 min" / "45 s"
dur() {
  local s="$1"
  [[ "$s" =~ ^-?[0-9]+$ ]] || { printf '?'; return; }
  (( s < 0 )) && s=0
  if (( s >= 172800 )); then printf '%d T %d h' $((s / 86400)) $(((s % 86400) / 3600))
  elif (( s >= 3600 )); then printf '%d h %d min' $((s / 3600)) $(((s % 3600) / 60))
  elif (( s >= 120 )); then printf '%d min' $((s / 60))
  else printf '%d s' "$s"; fi
}

# systemd-Dauer ("5min", "300s", "5min 30s", "300000000") -> Sekunden (ganzzahlig) oder leer
sd_seconds() {
  local v="$1" tot=0 num unit rest found=0
  [[ "$v" == infinity || "$v" == 0 || -z "$v" ]] && { echo 0; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then echo $((v >= 1000000 ? v / 1000000 : v)); return; fi
  rest="$v"
  while [[ "$rest" =~ ^[[:space:]]*([0-9]+)(us|ms|s|min|h|d|w)(.*)$ ]]; do
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"; found=1
    case "$unit" in
      us|ms) ;;
      s) tot=$((tot + num)) ;;
      min) tot=$((tot + num * 60)) ;;
      h) tot=$((tot + num * 3600)) ;;
      d) tot=$((tot + num * 86400)) ;;
      w) tot=$((tot + num * 604800)) ;;
    esac
  done
  (( found )) && echo "$tot" || echo ""
}

# Bytes -> MB mit einer Nachkommastelle
mbf() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

# Dateialter in Sekunden (leer, wenn nicht lesbar)
file_age() { local m; m="$(stat -c %Y -- "$1" 2>/dev/null)" || return 1; [[ "$m" =~ ^[0-9]+$ ]] || return 1; echo $((EPOCHSECONDS - m)); }
file_mode() { stat -c %a -- "$1" 2>/dev/null; }
sha16_of() { local h; h="$(sha256sum -- "$1" 2>/dev/null)" || return 1; echo "${h:0:16}"; }

# JSON-Dokument von stdin -> flache Tabelle J[pfad]=wert (Python3, nur lesend). Modus: flat | html <id>
declare -A J=()
read -r -d '' PYFLAT <<'PYEOF' || true
import sys, json, re
mode = sys.argv[1] if len(sys.argv) > 1 else "flat"
raw = sys.stdin.read()
if mode == "html":
    m = re.search(r'id="%s"[^>]*>(.*?)</script>' % re.escape(sys.argv[2]), raw, re.S)
    if not m:
        sys.exit(4)
    raw = m.group(1)
try:
    d = json.loads(raw)
except Exception:
    sys.exit(3)
out = []
def val(v):
    if v is None: return "null"
    if v is True: return "true"
    if v is False: return "false"
    return str(v).replace("\r", " ").replace("\n", " ").replace("\t", " ")[:200]
def walk(p, v, depth):
    if len(out) >= 700 or depth > 7:
        return
    if isinstance(v, dict):
        out.append("%s#=%d" % (p + "." if p else "", len(v)))
        out.append("%s@=%s" % (p + "." if p else "", " ".join(str(k).replace("=", "_").replace(" ", "_") for k in list(v)[:60])))
        for k, x in v.items():
            walk((p + "." if p else "") + str(k).replace("=", "_").replace(" ", "_"), x, depth + 1)
    elif isinstance(v, list):
        out.append("%s.#=%d" % (p, len(v)))
        for i, x in enumerate(v[:30]):
            walk("%s.%d" % (p, i), x, depth + 1)
    else:
        out.append("%s=%s" % (p, val(v)))
try:
    walk("", d, 0)
except Exception:
    sys.exit(5)
sys.stdout.write("\n".join(out) + "\n")
PYEOF

jload() {
  J=()
  local outp rc line
  have "$PYBIN" || return 2
  outp="$(timeout 10 "$PYBIN" -c "$PYFLAT" "$@" 2>/dev/null)"; rc=$?
  (( rc == 0 )) || return "$rc"
  while IFS= read -r line; do
    [[ "$line" == *=* ]] && J["${line%%=*}"]="${line#*=}"
  done <<<"$outp"
  return 0
}
# JSON aus einer Zeichenkette (nur kleine Antworten; Here-Strings ab 64 KB wuerden eine temporaere Datei anlegen)
jloads() {
  J=()
  (( ${#1} <= 60000 )) || return 6
  jload flat <<<"$1"
}
jv() { printf '%s' "${J[$1]:-}"; }   # Wert oder leer

# HTTP GET (nur GET, nur lokal): setzt HTTP_CODE, HTTP_TIME (s), HTTP_MS, HTTP_BODY, HTTP_RC
http_get() {
  local url="$1" to="${2:-8}" out tail
  HTTP_BODY=""; HTTP_CODE="000"; HTTP_TIME="0"; HTTP_MS=0; HTTP_RC=0
  have curl || { HTTP_RC=127; return 1; }
  out="$(timeout $((to + 3)) curl -s -m "$to" --connect-timeout 3 -w $'\n%{http_code} %{time_total}' -- "$url" 2>/dev/null)"; HTTP_RC=$?
  tail="${out##*$'\n'}"; HTTP_BODY="${out%$'\n'*}"
  [[ "$out" == *$'\n'* ]] || HTTP_BODY=""
  if [[ "$tail" =~ ^([0-9]{3})\ ([0-9.]+)$ ]]; then HTTP_CODE="${BASH_REMATCH[1]}"; HTTP_TIME="${BASH_REMATCH[2]}"; fi
  HTTP_MS="$(ms_of "$HTTP_TIME")"
  return 0
}

# sudo nur fuer lesende Befehle (journalctl, dmesg)
SUDO_OK=0
priv() {
  case "$1" in journalctl|dmesg) ;; *) echo "intern: priv erlaubt nur journalctl/dmesg" >&2; return 99 ;; esac
  if [[ "$(id -u)" == "0" ]]; then timeout 25 "$@"
  elif (( SUDO_OK )); then timeout 25 sudo -n -- "$@"
  else return 98; fi
}
can_journal() {
  local g; g=" $(id -nG 2>/dev/null) "
  [[ "$(id -u)" == "0" || "$g" == *" adm "* || "$g" == *" systemd-journal "* ]]
}

# ================================================================ Selbsttest (nur Hilfsfunktionen, kein Systemzugriff)
selftest() {
  local n=0 bad=0
  t() { n=$((n + 1)); if [[ "$2" == "$3" ]]; then :; else bad=$((bad + 1)); echo "SELFTEST FAIL $1: erwartet '$3' erhalten '$2'"; fi; }
  t ms1 "$(ms_of 0.191088)" 191
  t ms2 "$(ms_of 12.5)" 12500
  t ms3 "$(ms_of 7)" 7000
  t ms4 "$(ms_of abc)" 0
  t dur1 "$(dur 45)" "45 s"
  t dur2 "$(dur 600)" "10 min"
  t dur3 "$(dur 7500)" "2 h 5 min"
  t dur4 "$(dur 200000)" "2 T 7 h"
  t dur5 "$(dur x)" "?"
  t sd1 "$(sd_seconds 5min)" 300
  t sd2 "$(sd_seconds 300s)" 300
  t sd3 "$(sd_seconds 300000000)" 300
  t sd4 "$(sd_seconds '1min 30s')" 90
  t sd5 "$(sd_seconds infinity)" 0
  t sd6 "$(sd_seconds 0)" 0
  t sd7 "$(sd_seconds quatsch)" ""
  local old_vals=("${SECRET_VALS[@]}")
  SECRET_VALS=("GEHEIMWERT123")
  t cl1 "$(clean $'a\tGEHEIMWERT123 b\nc')" "a *** b c"
  SECRET_VALS=("${old_vals[@]}")
  t mk1 "$(mask 'GET /x?api_key=ABCDEF123456&b=1')" "GET /x?api_key=***&b=1"
  t mk2 "$(mask 'Authorization: Bearer abc.def-ghi')" "Authorization: ***"
  t mk3 "$(mask 'url https://h/v1/abcdefghijklmnopqrstuvwxyz0123/x')" "url https://h/v1/***/x"
  t mk4 "$(mask 'token=abc')" "token=***"
  t cl2 "$(clean 'Fehler api_key=ABCDEF1234 ende')" "Fehler api_key=*** ende"
  t cl3 "$(clean 'Authorization: Bearer abc.def-ghi')" "Authorization: ***"
  t cl4 "$(clean 'normaler Text ohne Schluessel')" "normaler Text ohne Schluessel"
  t mk5 "$(mask 'ok normal text 123')" "ok normal text 123"
  t mk6 "$(mask 'fehler k=SECRET_API_RESPONSE_c0ffee ende')" "fehler *** ende"
  t mk7 "$(mask 'unit prepper-dashboard.service gestartet')" "unit prepper-dashboard.service gestartet"
  t mk8 "$(mask 'a  b'$'\t''c')" "a b c"
  t mk9 "$(mask 'abcdefghijklmnopqrstuvwxyz nur Buchstaben')" "abcdefghijklmnopqrstuvwxyz nur Buchstaben"
  t mk10 "$(mask 'x*y ? [a]')" "x*y ? [a]"
  if fcmp 1.5 '>' 1.2; then t fc1 y y; else t fc1 n y; fi
  if fcmp 1.5 '<' 1.2; then t fc2 y n; else t fc2 n n; fi
  local s0=$N_OK; N_OK=0; N_WARN=0; N_FAIL=0
  t sc1 "$((100 - 2 * 3 - 10 * 1))" 84
  N_OK=$s0
  echo "SELFTEST: $n Pruefungen, $bad fehlerhaft"
  (( bad == 0 ))
}
if (( SELFTEST )); then collect_secret_values; selftest; exit $?; fi

collect_secret_values
trap 'echo >&2; echo "Abbruch durch Signal - keine Aenderungen am System (das Skript schreibt nichts)" >&2; exit 130' INT TERM

NOW_STR="$(date '+%d.%m.%Y %H:%M:%S %Z')"
if (( ! JSON )); then
  printf '%sfullcheck %s%s - Lage Pi %s - %s - Benutzer %s%s%s\n' "$C_B" "$FC_VERSION" "$C_0" "$(hostname 2>/dev/null || echo '?')" "$NOW_STR (Europe/Berlin)" "$(id -un 2>/dev/null || echo '?')" "$( (( QUICK )) && echo ' - Modus kurz')" "$( (( SUDO )) && echo ' - mit sudo (nur lesend)')"
  echo "Strikt nur lesend: nichts wird veraendert, gesendet oder neu gestartet."
fi

if (( SUDO )); then
  if [[ "$(id -u)" == "0" ]]; then SUDO_OK=1
  elif have sudo; then
    if [[ -t 0 ]]; then
      (( JSON )) || echo "sudo wird nur fuer journalctl und dmesg (lesend) genutzt - Passwort-Abfrage:"
      # shellcheck disable=SC2024  # nur Eingabe vom Terminal fuer die Passwort-Abfrage, keine Ausgabe-Umleitung
      sudo -v 2>/dev/null </dev/tty && SUDO_OK=1
    else
      sudo -n true 2>/dev/null && SUDO_OK=1
    fi
  fi
fi

# ================================================================ 1) System
section "System"
# Uptime
if read -r up _ < "$PROC/uptime" 2>/dev/null && [[ "${up%%.*}" =~ ^[0-9]+$ ]]; then
  US="${up%%.*}"
  if (( US < 600 )); then warn "Uptime" "erst $(dur "$US") seit dem Boot (kein RTC: Uhr erst nach chrony-Sync verlaesslich)" "Nach einem Neustart 10 Minuten warten, dann erneut pruefen."
  else ok "Uptime" "$(dur "$US") seit dem Boot"; fi
else skip "Uptime" "nicht lesbar ($PROC/uptime)"; fi

# Load
NCPU="$(nproc 2>/dev/null || echo 0)"; [[ "$NCPU" =~ ^[0-9]+$ && "$NCPU" -ge 1 ]] || NCPU=1
if read -r l1 l5 l15 _ < "$PROC/loadavg" 2>/dev/null && [[ "$l1" =~ ^[0-9.]+$ ]]; then
  if fcmp "$l5" '>' "$((NCPU * 3))"; then fail "Load" "1/5/15 min: $l1 $l5 $l15 bei $NCPU Kernen (5-min-Wert ueber ${NCPU}x3)" "Mit top pruefen, welcher Prozess die CPU blockiert (SDR, Dashboard, Backup)."
  elif fcmp "$l5" '>' "$(awk -v n="$NCPU" 'BEGIN{printf "%.1f", n*1.5}')"; then warn "Load" "1/5/15 min: $l1 $l5 $l15 bei $NCPU Kernen (5-min-Wert ueber 1,5 pro Kern)" "Mit top beobachten; kurzzeitig bei SDR-Last normal."
  else ok "Load" "1/5/15 min: $l1 $l5 $l15 bei $NCPU Kernen"; fi
else skip "Load" "nicht lesbar ($PROC/loadavg)"; fi

# CPU-Temperatur
TZ0="$SYS/class/thermal/thermal_zone0/temp"
if [[ -r "$TZ0" ]] && read -r tm < "$TZ0" && [[ "$tm" =~ ^-?[0-9]+$ ]]; then
  TC="$(awk -v t="$tm" 'BEGIN{printf "%.1f", t/1000}')"
  if (( tm >= 80000 )); then fail "CPU-Temperatur" "${TC} Grad C (ab 80 Grad drosselt der Pi)" "Luftzug/Kuehlkoerper pruefen, Gehaeuse nicht abdecken."
  elif (( tm >= 70000 )); then warn "CPU-Temperatur" "${TC} Grad C (ab 80 Grad drosselt der Pi)" "Belueftung pruefen."
  else ok "CPU-Temperatur" "${TC} Grad C"; fi
else skip "CPU-Temperatur" "$TZ0 nicht lesbar"; fi

# Drosselung / Unterspannung
THR=""
if have vcgencmd; then
  o="$(timeout 5 vcgencmd get_throttled 2>/dev/null)"; [[ "$o" =~ throttled=(0x[0-9a-fA-F]+) ]] && THR="${BASH_REMATCH[1]}"
fi
if [[ -z "$THR" ]]; then
  f="$SYS/devices/platform/soc/soc:firmware/get_throttled"
  if [[ -r "$f" ]] && read -r v < "$f" 2>/dev/null && [[ "$v" =~ ^[0-9a-fA-Fx]+$ ]]; then [[ "$v" == 0x* ]] || v="0x$v"; THR="$v"; fi
fi
if [[ -n "$THR" ]]; then
  TV=$((THR))
  NOWB=""; HISTB=""
  (( TV & 0x1 )) && NOWB+=" Unterspannung"
  (( TV & 0x2 )) && NOWB+=" Frequenz-Begrenzung"
  (( TV & 0x4 )) && NOWB+=" gedrosselt"
  (( TV & 0x8 )) && NOWB+=" Temperatur-Limit"
  (( TV & 0x10000 )) && HISTB+=" Unterspannung"
  (( TV & 0x20000 )) && HISTB+=" Frequenz-Begrenzung"
  (( TV & 0x40000 )) && HISTB+=" gedrosselt"
  (( TV & 0x80000 )) && HISTB+=" Temperatur-Limit"
  if (( TV & 0x5 )); then fail "Drosselung (vcgencmd)" "aktuell:$NOWB (get_throttled=$THR)" "Netzteil (5 V / 3 A) und Kabel pruefen; Kuehlung pruefen."
  elif (( TV & 0xA )); then warn "Drosselung (vcgencmd)" "aktuell:$NOWB (get_throttled=$THR)" "Kuehlung und Netzteil pruefen."
  elif [[ -n "$HISTB" ]]; then warn "Drosselung (vcgencmd)" "seit dem Boot aufgetreten:$HISTB (get_throttled=$THR)" "Netzteil/Kuehlung pruefen; Wert wird erst beim Neustart zurueckgesetzt."
  else ok "Drosselung (vcgencmd)" "keine Unterspannung/Drosselung (get_throttled=$THR)"; fi
else skip "Drosselung (vcgencmd)" "vcgencmd/get_throttled nicht verfuegbar"; fi

# RAM / Swap
MT=0
if [[ -r "$PROC/meminfo" ]]; then
  MT=0; MA=0; ST=0; SF=0
  while IFS=': ' read -r k v _; do
    case "$k" in MemTotal) MT="$v" ;; MemAvailable) MA="$v" ;; SwapTotal) ST="$v" ;; SwapFree) SF="$v" ;; esac
  done < "$PROC/meminfo"
  if (( MT > 0 )); then
    PA=$((MA * 100 / MT))
    DET="$((MA / 1024)) MB verfuegbar von $((MT / 1024)) MB ($PA %)"
    if (( PA < 5 )); then fail "RAM" "$DET" "Speicher fast voll: prepper-dashboard/prepper-sdr pruefen (top, ps)."
    elif (( PA < 15 )); then warn "RAM" "$DET" "Speicher wird knapp: Prozesse beobachten."
    else ok "RAM" "$DET"; fi
  else skip "RAM" "MemTotal nicht lesbar"; fi
  if (( ST > 0 )); then
    SU=$(((ST - SF) * 100 / ST)); DET="$(((ST - SF) / 1024)) MB von $((ST / 1024)) MB belegt ($SU %)"
    if (( SU > 90 )); then fail "Swap" "$DET" "Swap fast voll: Speicherfresser suchen."
    elif (( SU > 60 )); then warn "Swap" "$DET" "Hohe Swap-Nutzung: Dashboard-Speicher pruefen."
    else ok "Swap" "$DET"; fi
  else info "Swap" "kein Swap eingerichtet"; fi
else skip "RAM/Swap" "$PROC/meminfo nicht lesbar"; fi

# Dateisysteme: Fuellstand und Inodes
if have df; then
  TMPFS_SEEN=0
  DFOUT="$(timeout 10 df -PTl 2>/dev/null)"
  while read -r _ type blocks _ avail pct mnt; do
    [[ "$blocks" =~ ^[0-9]+$ ]] || continue
    case "$type" in
      ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat) WARNP=80; FAILP=92 ;;
      tmpfs) case "$mnt" in /tmp|/dev/shm|/run) ;; *) continue ;; esac; WARNP=70; FAILP=90; [[ "$mnt" == /tmp ]] && TMPFS_SEEN=1 ;;
      *) continue ;;
    esac
    p="${pct%\%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
    DET="$p % belegt, $((avail / 1024)) MB frei ($type)"
    nm="Disk $mnt"
    if (( p >= FAILP )); then fail "$nm" "$DET" "Platz schaffen (alte Backups/.bak/Logs); bei tmpfs: Dateien in $mnt pruefen."
    elif (( p >= WARNP )); then warn "$nm" "$DET" "Fuellstand beobachten, bald aufraeumen."
    else ok "$nm" "$DET"; fi
  done <<<"$DFOUT"
  (( TMPFS_SEEN )) || info "Disk /tmp" "kein eigener tmpfs-Mount fuer /tmp"
  DFI="$(timeout 10 df -PTil 2>/dev/null)"
  while read -r _ type inodes iused _ ipct mnt; do
    [[ "$inodes" =~ ^[0-9]+$ && "$inodes" -gt 0 ]] || continue
    case "$type" in ext2|ext3|ext4|xfs|f2fs) ;; *) continue ;; esac
    p="${ipct%\%}"; [[ "$p" =~ ^[0-9]+$ ]] || continue
    DET="$p % Inodes belegt ($iused von $inodes)"
    if (( p >= 95 )); then fail "Inodes $mnt" "$DET" "Sehr viele kleine Dateien: Ursache suchen (find | wc)."
    elif (( p >= 80 )); then warn "Inodes $mnt" "$DET" "Viele kleine Dateien: aufraeumen."
    else ok "Inodes $mnt" "$DET"; fi
  done <<<"$DFI"
else warn "Dateisysteme" "df fehlt" "Paket coreutils pruefen."; fi

# Dateisystem schreibgeschuetzt?
if [[ -r "$PROC/mounts" ]]; then
  RO_BAD=""; RO_ROOT=0
  while read -r _ mnt type opts _; do
    case "$type" in ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat) ;; *) continue ;; esac
    if [[ ",$opts," == *,ro,* ]]; then RO_BAD+=" $mnt"; [[ "$mnt" == / ]] && RO_ROOT=1; fi
  done < "$PROC/mounts"
  if (( RO_ROOT )); then fail "Dateisystem schreibbar" "/ ist schreibgeschuetzt (read-only)${RO_BAD:+ (auch:$RO_BAD)}" "Vermutlich Dateisystemfehler: dmesg lesen, ggf. fsck beim naechsten Boot; SD/SSD pruefen."
  elif [[ -n "$RO_BAD" ]]; then warn "Dateisystem schreibbar" "read-only eingehaengt:$RO_BAD" "Pruefen, ob gewollt (z. B. /boot/firmware)."
  else ok "Dateisystem schreibbar" "alle Datentraeger lesend+schreibend eingehaengt"; fi
else skip "Dateisystem schreibbar" "$PROC/mounts nicht lesbar"; fi
if [[ -d "$APP" ]]; then
  [[ -w "$APP" ]] && ok "Projektordner schreibbar" "$APP fuer $(id -un 2>/dev/null) schreibbar" || fail "Projektordner schreibbar" "$APP nicht beschreibbar" "Rechte/Eigentuemer pruefen (ls -ld)."
else fail "Projektordner" "$APP fehlt" "Pfad pruefen (FC_APP)."; fi

# Kernel-Meldungen (dmesg)
if have dmesg; then
  DM="$(timeout 10 dmesg 2>&1)"; DMRC=$?
  if [[ "$DM" == *"Operation not permitted"* || "$DM" == *"not permitted"* || $DMRC -ne 0 && -z "$DM" ]]; then
    if (( SUDO_OK )); then DM="$(priv dmesg 2>&1)"; DMRC=$?; else DM="__NOPERM__"; fi
  fi
  if [[ "$DM" == "__NOPERM__" ]]; then skip "Kernel-Meldungen (dmesg)" "braucht sudo (dmesg ist fuer Benutzer gesperrt) - Aufruf mit --sudo"
  else
    DMP='I/O error|EXT4-fs error|mmc[0-9:]+.*(error|timeout)|Under-voltage|Out of memory|oom-kill|blk_update_request|Buffer I/O|Remounting filesystem read-only|segfault|Call trace|hung task|nvme.*(timeout|reset)|usb.*(disconnect, error|device descriptor read.*error)'
    DMC="$(pf "$DM" | grep -Ec "$DMP")"; [[ "$DMC" =~ ^[0-9]+$ ]] || DMC=0
    if (( DMC > 0 )); then
      LASTL="$(pf "$DM" | grep -E "$DMP" | tail -1)"
      DMAGE=""
      DMTS=""; [[ "$LASTL" =~ ^\[\ *([0-9]+)\.[0-9]+\] ]] && DMTS="${BASH_REMATCH[1]}"
      if [[ -n "$DMTS" && "${US:-}" =~ ^[0-9]+$ ]]; then
        DMA=$((US - DMTS)); (( DMA < 0 )) && DMA=0
        DMAGE=" (Zeitstempel $DMTS s nach dem Boot, Uptime $(dur "$US"): letzte Meldung vor $(dur "$DMA")$( ((DMA > 3600)) && echo ', also alt' ))"
      fi
      warn "Kernel-Meldungen (dmesg)" "$DMC Zeile(n) mit Fehlerbezug seit dem Boot$DMAGE, zuletzt: $(mask "${LASTL:0:140}")" "Der Kernel-Puffer behaelt Meldungen bis zum Neustart: eine alte Meldung ist kein aktuelles Problem. dmesg lesen (journalctl -k); bei I/O-/Dateisystemfehlern Datentraeger sichern und pruefen."
    else ok "Kernel-Meldungen (dmesg)" "keine I/O-/Dateisystem-/Unterspannungs-/OOM-Fehler seit dem Boot"; fi
  fi
else skip "Kernel-Meldungen (dmesg)" "dmesg fehlt"; fi

# ================================================================ 2) Zeit
section "Zeit (Europe/Berlin, chrony)"
if have timedatectl; then
  declare -A TD=()
  while IFS= read -r line; do [[ "$line" == *=* ]] && TD["${line%%=*}"]="${line#*=}"; done < <(timeout 5 timedatectl show 2>/dev/null)
  if [[ -n "${TD[Timezone]:-}" ]]; then
    [[ "${TD[Timezone]}" == "Europe/Berlin" ]] && ok "Zeitzone" "Europe/Berlin" || warn "Zeitzone" "System steht auf ${TD[Timezone]:0:40}, erwartet Europe/Berlin" "Nur pruefen: timedatectl (Dashboard-Zeiten und Wetter-Slots rechnen in Berliner Zeit)."
  else skip "Zeitzone" "timedatectl liefert keine Zeitzone"; fi
  case "${TD[NTPSynchronized]:-}" in
    yes) ok "NTP synchronisiert" "timedatectl: NTPSynchronized=yes" ;;
    no) warn "NTP synchronisiert" "timedatectl: NTPSynchronized=no" "chrony pruefen (chronyc tracking, chronyc sources)." ;;
    *) skip "NTP synchronisiert" "kein Wert von timedatectl" ;;
  esac
else skip "Zeitzone / NTP" "timedatectl fehlt"; fi

if have chronyc; then
  TR="$(timeout 5 chronyc -n -c tracking 2>/dev/null)"; TRRC=$?
  if (( TRRC == 0 )) && [[ -n "$TR" ]]; then
    IFS=, read -r -a CF <<<"$TR"
    STR="${CF[2]:-}"; REFN="${CF[1]:-}"; OFFS="${CF[4]:-}"; RTM="${CF[3]:-0}"; LEAP="${CF[13]:-}"
    [[ -n "$REFN" ]] || REFN="${CF[0]:-?}"
    if [[ "$OFFS" =~ ^-?[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ && "$STR" =~ ^[0-9]+$ ]]; then
      OFFUS="$(awk -v o="$OFFS" 'BEGIN{v=o*1e6; if(v<0)v=-v; printf "%.1f", v}')"
      SIDE="$(awk -v o="$OFFS" 'BEGIN{print (o>0)?"Systemuhr geht nach":((o<0)?"Systemuhr geht vor":"exakt")}')"
      DET="Offset $OFFUS us ($SIDE), Stratum $STR, Referenz ${REFN:0:40}"
      if [[ "$LEAP" == *"Not synchronised"* || "$STR" == 0 || "$STR" -ge 16 ]]; then fail "chrony: Synchronisation" "nicht synchronisiert (Leap: ${LEAP:-?}, Stratum $STR)" "chronyc sources -v lesen; Quelle $NTP_HOST erreichbar? Uhr ohne RTC ist dann unzuverlaessig."
      elif fcmp "$OFFUS" '>=' 100000; then fail "chrony: Offset" "$DET (ueber 100 ms)" "chronyc sources/tracking lesen; Zeitquelle pruefen."
      elif fcmp "$OFFUS" '>=' 10000; then warn "chrony: Offset" "$DET (ueber 10 ms)" "Beobachten; bei Dauer Zeitquelle pruefen."
      else ok "chrony: Offset" "$DET"; fi
      if [[ "$STR" -gt 5 ]]; then warn "chrony: Stratum" "Stratum $STR (erwartet 2 bis 4)" "Zeitquelle pruefen."; else ok "chrony: Stratum" "Stratum $STR"; fi
      [[ "$LEAP" == "Normal" ]] && ok "chrony: Leap-Status" "Normal" || { [[ "$LEAP" == *"Not synchronised"* ]] || warn "chrony: Leap-Status" "${LEAP:-?}" "Nur Anzeige: Schaltsekunde angekuendigt."; }
      RTI="${RTM%%.*}"
      if [[ "$RTI" =~ ^[0-9]+$ && "$RTI" -gt 0 ]]; then
        RAGE=$((EPOCHSECONDS - RTI))
        if (( RAGE > 3600 )); then warn "chrony: letzte Messung" "vor $(dur "$RAGE") (erwartet < 1 h)" "Quelle $NTP_HOST erreichbar? chronyc sources lesen."
        else ok "chrony: letzte Messung" "vor $(dur "$RAGE")"; fi
      fi
    else fail "chrony: tracking" "Ausgabe nicht lesbar (Format)" "chronyc -c tracking von Hand pruefen."; fi
  else fail "chrony: tracking" "chronyc antwortet nicht (rc $TRRC)" "Dienst chrony pruefen: systemctl status chrony."; fi
  SRC="$(timeout 5 chronyc -n -c sources 2>/dev/null)"
  if [[ -n "$SRC" ]]; then
    FOUND=0; NSRC=0
    while IFS=, read -r mode state name rest; do
      [[ -n "$name" ]] || continue
      NSRC=$((NSRC + 1))
      [[ "$name" == "$NTP_HOST" ]] || continue
      FOUND=1
      IFS=, read -r -a SF <<<"$rest"
      REACH="${SF[2]:-?}"
      case "$state" in
        '*') ok "chrony: Quelle $NTP_HOST" "Status $mode$state (ausgewaehlt), Reach $REACH" ;;
        '+') ok "chrony: Quelle $NTP_HOST" "Status $mode$state (kombiniert), Reach $REACH" ;;
        x) fail "chrony: Quelle $NTP_HOST" "als falsch markiert (falseticker, Status $mode$state), Reach $REACH" "Zeitquelle pruefen: chronyc sources -v." ;;
        *) warn "chrony: Quelle $NTP_HOST" "Status $mode$state, Reach $REACH (nicht ausgewaehlt)" "Quelle erreichbar? chronyc sources -v lesen." ;;
      esac
    done <<<"$SRC"
    (( FOUND )) || warn "chrony: Quelle $NTP_HOST" "nicht unter den $NSRC Quellen" "Konfiguration der Zeitquelle pruefen (nur lesen: chronyc sources)."
  else warn "chrony: Quellen" "keine Quellen gelistet" "chronyc sources lesen."; fi
else warn "chrony" "chronyc fehlt - Zeitpruefung nicht moeglich" "Paket chrony pruefen."; fi

# gpsd auf der Zeitquelle: nur TCP-Verbindung testen (nichts senden, nichts lesen)
if [[ "$NTP_HOST" =~ ^[0-9A-Za-z.:-]+$ ]] && [[ "$GPSD_PORT" =~ ^[0-9]+$ ]]; then
  # shellcheck disable=SC2016  # $0/$1 sollen in der Unter-Shell expandieren, nicht hier
  if timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1" && exec 3>&-' "$NTP_HOST" "$GPSD_PORT" 2>/dev/null; then ok "gpsd $NTP_HOST:$GPSD_PORT" "Port erreichbar (nur Verbindung getestet)"
  else warn "gpsd $NTP_HOST:$GPSD_PORT" "Port nicht erreichbar" "gpsd auf $NTP_HOST laeuft? (nur auf dem Zeitgeber pruefen; Dashboard-Zeit nutzt chrony)"; fi
fi

# ================================================================ 3) Dienste
section "Dienste (systemd)"
declare -A S=()
sc_show() {
  S=(); local line
  while IFS= read -r line; do [[ "$line" == *=* ]] && S["${line%%=*}"]="${line#*=}"; done < <(timeout 10 systemctl show "$1" --no-pager -p LoadState -p ActiveState -p SubState -p UnitFileState -p NRestarts -p MainPID -p ExecMainStartTimestamp -p WatchdogUSec -p NotifyAccess -p NeedDaemonReload -p DropInPaths -p Result 2>/dev/null)
}
declare -A SVC_MAINPID=() SVC_START=()
if have systemctl; then
  for u in "${SERVICES[@]}"; do
    sc_show "$u"
    if [[ -z "${S[ActiveState]:-}" ]]; then skip "Dienst $u" "systemctl liefert nichts"; continue; fi
    if [[ "${S[LoadState]:-}" == "not-found" ]]; then fail "Dienst $u" "Unit nicht installiert" "Installation pruefen."; continue; fi
    SVC_MAINPID[$u]="${S[MainPID]:-0}"; SVC_START[$u]="${S[ExecMainStartTimestamp]:-}"
    if [[ "${S[ActiveState]}" == "active" && "${S[SubState]:-}" == "running" ]]; then ok "Dienst $u" "active (running), PID ${S[MainPID]:-?}"
    else fail "Dienst $u" "${S[ActiveState]}/${S[SubState]:-?}, Ergebnis ${S[Result]:-?}" "journalctl -u $u -n 50 lesen; Start nur nach Ursache (kein Neustart durch dieses Skript)."; fi
    case "${S[UnitFileState]:-}" in
      enabled|enabled-runtime|static|alias|generated) ok "Autostart $u" "${S[UnitFileState]}" ;;
      "") skip "Autostart $u" "Zustand unbekannt" ;;
      *) warn "Autostart $u" "${S[UnitFileState]} (startet nach einem Reboot nicht)" "systemctl enable $u (mit sudo, bewusst entscheiden)." ;;
    esac
    NR="${S[NRestarts]:-}"
    if [[ "$NR" =~ ^[0-9]+$ ]]; then
      if (( NR >= 5 )); then fail "Neustarts $u" "NRestarts=$NR seit dem letzten manuellen Start" "journalctl -u $u lesen: Absturzschleife?"
      elif (( NR >= 1 )); then warn "Neustarts $u" "NRestarts=$NR (automatische Neustarts seit dem letzten Start)" "journalctl -u $u --since -24h lesen: warum hat systemd neu gestartet?"
      else ok "Neustarts $u" "NRestarts=0"; fi
    else skip "Neustarts $u" "NRestarts nicht verfuegbar"; fi
  done
  # Watchdog des Dashboards
  sc_show prepper-dashboard
  WDS="$(sd_seconds "${S[WatchdogUSec]:-}")"
  if [[ "$WDS" == "300" ]]; then ok "Watchdog Dashboard" "WatchdogUSec=${S[WatchdogUSec]} (300 s), NotifyAccess=${S[NotifyAccess]:-?}"
  elif [[ -z "$WDS" ]]; then skip "Watchdog Dashboard" "WatchdogUSec nicht lesbar"
  else fail "Watchdog Dashboard" "WatchdogUSec=${S[WatchdogUSec]:-?} (erwartet 5min = 300 s)" "Drop-in zz-relwatch.conf pruefen (relWatch, commit30)."; fi
  DROPF="$DROPIN_DIR/zz-relwatch.conf"
  if [[ -r "$DROPF" || "${S[DropInPaths]:-}" == *zz-relwatch.conf* ]]; then
    ok "Drop-in zz-relwatch.conf" "vorhanden$([[ "${S[DropInPaths]:-}" == *zz-relwatch.conf* ]] && echo ', von systemd geladen')"
  else fail "Drop-in zz-relwatch.conf" "fehlt in $DROPIN_DIR" "relWatch (commit30) erneut anwenden."; fi
  if [[ "${S[NeedDaemonReload]:-}" == "yes" ]]; then warn "systemd: daemon-reload" "Unit-Dateien geaendert, daemon-reload steht aus" "sudo systemctl daemon-reload (bewusst entscheiden)."; fi
  # Laeuft der Prozess auf altem Programmstand?
  if [[ -n "${SVC_START[prepper-dashboard]:-}" && -f "$APP/dashboard.py" ]]; then
    ST_EP="$(date -d "${SVC_START[prepper-dashboard]}" +%s 2>/dev/null)"; DM_EP="$(stat -c %Y -- "$APP/dashboard.py" 2>/dev/null)"
    if [[ "$ST_EP" =~ ^[0-9]+$ && "$DM_EP" =~ ^[0-9]+$ ]]; then
      if (( DM_EP > ST_EP + 2 )); then warn "Dashboard-Prozess aktuell" "dashboard.py ist neuer als der laufende Prozess (Datei $(dur $((EPOCHSECONDS - DM_EP))) alt, Start vor $(dur $((EPOCHSECONDS - ST_EP))))" "Neustart noetig, damit der Stand wirkt (nicht in 20:55-21:59 und HH:55-HH:04 der Wetter-Slots)."
      else ok "Dashboard-Prozess aktuell" "laeuft seit $(dur $((EPOCHSECONDS - ST_EP))), Datei nicht neuer"; fi
    fi
  fi
  # Speicher der Dienste
  for u in "${SERVICES[@]}"; do
    pid="${SVC_MAINPID[$u]:-0}"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -r "$PROC/$pid/status" ]] || continue
    rss="$(awk '/^VmRSS:/{print $2}' "$PROC/$pid/status" 2>/dev/null)"
    [[ "$rss" =~ ^[0-9]+$ ]] || continue
    if (( MT > 0 && rss * 100 / MT > 40 )); then warn "Speicher $u" "RSS $((rss / 1024)) MB (ueber 40 % des RAM)" "Speicherleck? Dienst beobachten."
    else info "Speicher $u" "RSS $((rss / 1024)) MB"; fi
  done
  # Timer und fehlgeschlagene Units
  TS="$(timeout 5 systemctl is-active prepper-health.timer 2>/dev/null)"
  case "$TS" in active) ok "Timer prepper-health" "active (Health-Check alle 3 h)" ;; "") : ;; *) warn "Timer prepper-health" "$TS" "systemctl status prepper-health.timer lesen." ;; esac
  FU="$(timeout 10 systemctl --failed --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  if [[ -z "${FU// /}" ]]; then ok "Fehlgeschlagene Units" "keine"
  else
    SEV=warn; for u in "${SERVICES[@]}"; do [[ "$FU" == *"$u.service"* ]] && SEV=fail; done
    _emit "$SEV" "Fehlgeschlagene Units" "${FU:0:200}" "systemctl status <Unit> lesen; journalctl -u <Unit> -n 50."
  fi
else warn "Dienste" "systemctl fehlt - Dienstpruefung nicht moeglich" "Nur auf der Pi sinnvoll."; fi

# ================================================================ 4) Dashboard
section "Dashboard (Port $PORT)"
BASEURL="http://$HOSTN:$PORT"
DASH_UP=1; NINA_MODE=""; WD_ALL_LVL=""; WD_AIRSPY_LVL=""
if ! have curl; then
  warn "Dashboard" "curl fehlt - Seiten-/API-Pruefung nicht moeglich" "Paket curl pruefen."; DASH_UP=0
else
  http_get "$BASEURL/api/time" 5
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail "Dashboard erreichbar" "GET /api/time -> HTTP $HTTP_CODE (curl rc $HTTP_RC, ${HTTP_MS} ms)" "Dienst prepper-dashboard pruefen (journalctl -u prepper-dashboard -n 50); Start dauert nach Neustart bis ca. 1 min."
    DASH_UP=0
  fi
fi

if (( DASH_UP )); then
  # --- /api/time (leichte Seite, zugleich Uhrenvergleich)
  if jloads "$HTTP_BODY"; then
    DMS="$(jv ms)"; NOWMS="$(date +%s%3N 2>/dev/null)"
    if [[ "$DMS" =~ ^[0-9]+$ && "$NOWMS" =~ ^[0-9]+$ ]]; then
      D=$((NOWMS - DMS)); (( D < 0 )) && D=$((-D))
      if (( D > 10000 )); then fail "/api/time Uhrenvergleich" "Dashboard-Uhr weicht $((D / 1000)) s von der Systemuhr ab" "Dashboard neu geladen? Zeitquelle pruefen."
      elif (( D > 2000 )); then warn "/api/time Uhrenvergleich" "Abweichung $((D / 1000)) s" "Beobachten (Antwortzeit ${HTTP_MS} ms)."
      else ok "/api/time Uhrenvergleich" "Abweichung $D ms zur Systemuhr, Antwort $HTTP_MS ms, Dashboard-Zeit $(mask "$(jv str)")"; fi
    else warn "/api/time Uhrenvergleich" "Antwort ohne ms-Feld" "Dashboard-Version pruefen."; fi
  else warn "/api/time Uhrenvergleich" "Antwort ist kein JSON" "Dashboard pruefen."; fi

  # --- Seiten und APIs
  # Kurz nach einem Dashboard-Start ist /pi bekannt langsamer (Zwischenspeicher fuellt sich): dann hoechstens HINWEIS
  FRESH_S=-1
  if [[ -n "${SVC_START[prepper-dashboard]:-}" ]]; then
    FS_EP="$(date -d "${SVC_START[prepper-dashboard]}" +%s 2>/dev/null)"
    [[ "$FS_EP" =~ ^[0-9]+$ ]] && FRESH_S=$((EPOCHSECONDS - FS_EP))
  fi
  PAGE1_BODY=""
  if (( QUICK )); then
    skip "Seitentest (26 Seiten/APIs)" "mit --kurz uebersprungen"
  else
    NP=0; NPOK=0; NSKIPB=0
    for pg in "${PAGES[@]}"; do
      if (( SECONDS - T0 > BUDGET_S )); then NSKIPB=$((NSKIPB + 1)); continue; fi
      NP=$((NP + 1))
      http_get "$BASEURL$pg" 8
      [[ "$pg" == "/" && "$HTTP_CODE" == "200" ]] && PAGE1_BODY="$HTTP_BODY"
      if [[ "$HTTP_CODE" != "200" ]]; then
        if [[ "$HTTP_CODE" == "000" ]]; then fail "GET $pg" "keine Antwort (curl rc $HTTP_RC, nach ${HTTP_MS} ms; Timeout 8 s)" "Seite haengt oder Dienst weg: journalctl -u prepper-dashboard -n 80."
        else fail "GET $pg" "HTTP $HTTP_CODE in ${HTTP_MS} ms" "journalctl -u prepper-dashboard -n 80 lesen (Traceback?)."; fi
      elif [[ "$HTTP_BODY" == *'id="sbLoading"'* ]]; then
        warn "GET $pg" "HTTP 200, aber Ladehinweis (Dashboard startet noch), ${HTTP_MS} ms" "1 Minute warten und erneut pruefen."
      elif [[ "$pg" == /pi ]] && (( HTTP_MS >= 2500 && FRESH_S >= 0 && FRESH_S < 600 )); then
        warn "GET $pg" "HTTP 200 in ${HTTP_MS} ms, Dashboard erst vor $(dur "$FRESH_S") gestartet (nach einem Neustart kurz langsamer: Zwischenspeicher, bekannt)" "Nach ca. 10 Minuten erneut pruefen; dann sollte /pi wieder schnell sein."
      elif (( HTTP_MS >= 6000 )); then fail "GET $pg" "HTTP 200, aber sehr langsam: ${HTTP_MS} ms" "Last pruefen (Load, SDR); /api/sysboot/status zeigt langsame Anfragen."
      elif (( HTTP_MS >= 2500 )); then warn "GET $pg" "HTTP 200 in ${HTTP_MS} ms (langsam, ueber 2,5 s)" "Last beobachten; /api/sysboot/status -> slow."
      else ok "GET $pg" "HTTP 200 in ${HTTP_MS} ms"; NPOK=$((NPOK + 1)); fi
    done
    (( NSKIPB > 0 )) && warn "Seitentest Zeitbudget" "$NSKIPB Seite(n) nicht geprueft: Zeitbudget ${BUDGET_S} s ueberschritten" "Pi ist sehr langsam: Last pruefen, Skript erneut starten."
  fi

  # --- /pi: Kacheln und DB-Zeile (eine Anfrage)
  http_get "$BASEURL/pi" 8
  if [[ "$HTTP_CODE" == "200" ]]; then
    PI_BODY="$HTTP_BODY"
    [[ "$PI_BODY" == *doPrepperRestore* ]] && ok "/pi Kachel Sicherung" "vorhanden" || warn "/pi Kachel Sicherung" "nicht in der Seite gefunden" "Seite /pi und Patch-Stand pruefen."
    [[ "$PI_BODY" == *Projektbeschreibung* ]] && ok "/pi Kachel Projektbeschreibung" "vorhanden" || warn "/pi Kachel Projektbeschreibung" "nicht in der Seite gefunden" "Seite /pi und Patch-Stand pruefen."
    DBJ="${PI_BODY#*id=\"dbVisData\"}"; DBJ="${DBJ#*>}"; DBJ="${DBJ%%</script>*}"
    if [[ "$PI_BODY" == *'id="dbVisData"'* ]] && jloads "$DBJ"; then
      DBS="$(jv state)"; DBV="$(mask "$(jv val)")"
      case "$DBS" in
        ok) ok "/pi Datenbank-Zeile" "$DBV" ;;
        ausgefallen) fail "/pi Datenbank-Zeile" "$DBV" "Datenbank sichern (Backup), dann quick_check/Wartung pruefen; nichts loeschen." ;;
        alt) warn "/pi Datenbank-Zeile" "$DBV" "Datenbank-Wartung (relDb) pruefen; kein WAL oder veraltete Pruefung." ;;
        *) info "/pi Datenbank-Zeile" "${DBV:-ohne Wert} (Zustand ${DBS:-?})" ;;
      esac
    else warn "/pi Datenbank-Zeile" "dbVis-Daten nicht in /pi gefunden" "commit31 dbVis angewendet? (Marker dbVis)"; fi
  else skip "/pi Kacheln/DB-Zeile" "/pi lieferte HTTP $HTTP_CODE"; fi

  # --- /api/clock-off
  http_get "$BASEURL/api/clock-off" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    CSRC="$(jv src)"; CUS="$(jv us)"; CTXT="$(mask "$(jv text)")"
    case "$CSRC" in
      chrony) ok "/api/clock-off (Zeit-Offset-Kachel)" "Quelle chrony: $CTXT (${CUS:-?} us)" ;;
      ntplib) warn "/api/clock-off (Zeit-Offset-Kachel)" "nur ntplib-Rueckfall: $CTXT" "Dashboard kann chronyc nicht lesen: chronyc -c tracking als Benutzer fmg pruefen." ;;
      *) warn "/api/clock-off (Zeit-Offset-Kachel)" "kein Wert (Quelle ${CSRC:-?})" "chronyc pruefen." ;;
    esac
  else skip "/api/clock-off" "HTTP $HTTP_CODE oder kein JSON"; fi

  # --- /api/sysboot/status (rel, wx, alarm, Start)
  http_get "$BASEURL/api/sysboot/status" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    [[ "$(jv loading)" == "false" ]] && ok "sysBoot: Start" "Dashboard fertig geladen, ersten Voll-Update nach $(jv first_update_s) s, Laufzeit $(dur "$(jv up_s)")" || warn "sysBoot: Start" "Dashboard laedt noch (loading=$(jv loading))" "Nach ca. 1 Minute erneut pruefen."
    FE="$(jv first_err)"; [[ -z "$FE" || "$FE" == null ]] || warn "sysBoot: erstes Update" "Fehler beim ersten Update: $(mask "$FE")" "journalctl -u prepper-dashboard --since -1h lesen."
    ST_SELF="$(jv selftest)"
    if [[ "$ST_SELF" == *FEHLER* ]]; then fail "sysBoot: Selbsttest" "$(mask "$ST_SELF")" "Dashboard-Journal lesen; Patch-Stand pruefen."; elif [[ -n "$ST_SELF" && "$ST_SELF" != null ]]; then ok "sysBoot: Selbsttest" "$(mask "${ST_SELF:0:80}")"; fi
    SLN="$(jv slow_n)"
    if [[ "$SLN" =~ ^[0-9]+$ ]]; then
      SL0="$(jv slow.0.p)"
      if (( SLN > 10 )); then warn "sysBoot: langsame Anfragen" "$SLN Anfragen ueber 3 s seit dem Start${SL0:+ (zuletzt $(mask "$SL0"))}" "Last/SDR pruefen; journalctl -u prepper-dashboard | grep langsam."
      else ok "sysBoot: langsame Anfragen" "$SLN seit dem Start (Grenze 10)"; fi
    fi
    # relWatch
    if [[ -n "$(jv 'rel.threads.@')" || -n "$(jv rel.ticks)" ]]; then
      BAD=""; NTH=0
      for th in $(jv 'rel.threads.@'); do
        NTH=$((NTH + 1)); stt="$(jv "rel.threads.$th.state")"
        case "$stt" in ok) ;; stale) BAD+=" $th:stale(ohne Durchlauf $(dur "$(jv "rel.threads.$th.age_s")"))" ;; tot) BAD+=" $th:TOT" ;; *) BAD+=" $th:$stt" ;; esac
      done
      if [[ "$BAD" == *TOT* ]]; then fail "relWatch: Faeden" "Faden gestorben:$BAD" "journalctl -u prepper-dashboard lesen; der Watchdog startet bei Dauerfehler neu."
      elif [[ -n "$BAD" ]]; then warn "relWatch: Faeden" "Faden stockt:$BAD" "Beobachten; bei Dauer Dashboard-Journal lesen."
      else ok "relWatch: Faeden" "$NTH Hintergrundfaeden laufen ($(jv 'rel.threads.@'))"; fi
      RR="$(jv rel.red.#)"; [[ "$RR" == 0 || -z "$RR" ]] || warn "relWatch: rot" "$RR Eintrag/Eintraege rot: $(mask "$(jv rel.red.0)") $(mask "$(jv rel.red.1)")" "Dashboard-Journal lesen."
      [[ "$(jv rel.thread)" == true ]] && ok "relWatch: Waechterfaden" "laeuft ($(jv rel.ticks) Takte)" || warn "relWatch: Waechterfaden" "Waechterfaden laeuft nicht" "Dashboard neu starten lassen (REL-01)."
      RE="$(jv rel.err)"; [[ -z "$RE" || "$RE" == null ]] || warn "relWatch: Fehler" "$(mask "$RE")" "Dashboard-Journal lesen."
      if [[ "$(jv rel.wd.sock)" == true ]]; then
        BA="$(jv rel.wd.beat_age_s)"
        if [[ "$(jv rel.wd.brake)" == true ]]; then warn "Watchdog: Neustart-Bremse" "Bremse aktiv: $(mask "$(jv rel.wd.brake_why)") (Starts/h: $(jv rel.wd.starts_1h))" "Ursache im Journal suchen; die Bremse verhindert Neustartschleifen."
        elif [[ "$BA" =~ ^[0-9]+$ ]] && (( BA > 120 )); then warn "Watchdog: Herzschlag" "letzter Herzschlag vor $(dur "$BA")" "Dashboard-Faden haengt? Journal lesen."
        else ok "Watchdog: Herzschlag" "systemd-Socket aktiv, Takt vor ${BA:-?} s, Pruefalter $(jv rel.wd.probe_age_s) s, scharf: $(jv rel.wd.armed)"; fi
        FS_="$(jv rel.wd.fail_s)"; [[ -z "$FS_" || "$FS_" == null ]] || warn "Watchdog: Selbsttest-Anfrage" "Webserver antwortet seit $FS_ s nicht (Grenze $(jv rel.wd.fail_limit_s) s)" "Gleich Neustart durch Watchdog moeglich: journalctl -u prepper-dashboard lesen."
      else warn "Watchdog: Herzschlag" "Dienst laeuft ohne systemd-Watchdog-Socket" "Drop-in zz-relwatch.conf und Dashboard-Neustart (relWatch) pruefen."; fi
    else warn "sysBoot: rel-Abschnitt" "kein rel-Abschnitt in /api/sysboot/status" "relWatch (commit30) angewendet?"; fi
    # wxSlot
    if [[ -n "$(jv wx.installed)" ]]; then
      if [[ "$(jv wx.installed)" != true ]]; then fail "wxSlot: installiert" "wxSlot meldet nicht installiert" "commit34 pruefen."
      else
        WXE="$(jv wx.fehler)"
        [[ "$(jv wx.faden)" == true ]] && ok "wxSlot: Faden" "laeuft ($(jv wx.takte) Takte), Slot $(jv wx.slot)" || fail "wxSlot: Faden" "Wetter-Slot-Faden laeuft nicht" "Dashboard-Journal lesen; ohne Faden werden Slots nicht nachgeholt."
        [[ -z "$WXE" || "$WXE" == null ]] || warn "wxSlot: Fehler" "$(mask "$WXE")" "Dashboard-Journal: grep wxSlot."
        WR="$(jv wx.ergebnis)"; WV="$(jv wx.versuche)"
        if [[ "$WR" == aufgegeben* || "$WR" == verpasst* ]]; then warn "wxSlot: Slot-Ergebnis" "Slot $(jv wx.slot): $(mask "$WR"), Versuche ${WV:-0}" "Nur anzeigen: war das Dashboard in der Slot-Stunde neu gestartet? /mesh-Verlauf und Bridge-Zustand pruefen."
        else ok "wxSlot: Slot-Ergebnis" "Slot $(jv wx.slot): $(mask "${WR:-noch offen (Slot-Stunde nicht erreicht oder Stempel vorhanden)}"), Stempel im Slot=$(jv wx.stempel_im_slot), Versuche ${WV:-0}"; fi
        WSF="$(jv wx.strom.fehler)"
        if [[ -n "$WSF" && "$WSF" != null ]]; then warn "wxSlot: Stromausfall-Stand" "Fehler: $(mask "$WSF")" "Dashboard-Journal: grep wxSlot."
        else ok "wxSlot: Stromausfall-Stand" "Datei vorhanden=$(jv wx.strom.datei), geladen: $(mask "$(jv wx.strom.geladen)"), bekannte IDs: $(jv wx.strom.bekannt)"; fi
      fi
    else warn "sysBoot: wx-Abschnitt" "kein wx-Abschnitt in /api/sysboot/status" "wxSlot (commit34) angewendet?"; fi
    # Alarm-Faden
    if [[ -n "$(jv alarm.thread)" ]]; then
      AL_BAD=""
      [[ "$(jv alarm.thread)" == true ]] || AL_BAD+=" Alarm-Faden laeuft nicht;"
      AE="$(jv alarm.err)"; [[ -z "$AE" || "$AE" == null ]] || AL_BAD+=" Fehler: $(mask "$AE");"
      for w in nina dwd; do
        AG="$(jv "alarm.src.$w.age_s")"; AF="$(jv "alarm.src.$w.fails")"; PS="$(jv alarm.poll_s)"
        [[ "$AF" =~ ^[0-9]+$ && "$AF" -ge 3 ]] && AL_BAD+=" $w $AF Fehlversuche in Folge;"
        [[ "$AG" =~ ^[0-9]+$ && "$PS" =~ ^[0-9]+$ ]] && (( AG > PS * 3 )) && AL_BAD+=" $w letzter Abruf vor $(dur "$AG");"
      done
      if [[ -n "$AL_BAD" ]]; then warn "Alarm-Faden (NINA/DWD)" "$AL_BAD" "Internet/Quellen pruefen; Dashboard-Journal lesen."
      else ok "Alarm-Faden (NINA/DWD)" "laeuft, NINA vor $(jv alarm.src.nina.age_s) s, DWD vor $(jv alarm.src.dwd.age_s) s (Takt $(jv alarm.poll_s) s)"; fi
    fi
  else skip "/api/sysboot/status" "HTTP $HTTP_CODE oder kein JSON"; fi

  # --- NINA-Zertifikatskette (ninaFix, commit36): Rueckfall ueber gepinnte Zwischenstelle ist ERWARTET (OK/HINWEIS), nur eine nicht pruefbare Kette ist FEHLER
  http_get "$BASEURL/api/nina-cert" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    NINA_MODE="$(jv mode)"; NPINOK="$(jv pin_ok)"; NPDAYS="$(jv pin_days_left)"; NFBN="$(jv fallback_n)"; NFAGO="$(jv fallback_ago_s)"
    NFAILW="$(mask "$(jv fail.why)")"; NPINWHY="$(mask "$(jv pin_why)")"; NPLN="$(jv plain_n)"
    NDET="Abrufe normal ${NPLN:-?}x, ueber Rueckfall ${NFBN:-?}x"
    case "$NINA_MODE" in
      normal)
        ok "NINA Zertifikatskette" "normaler Abruf mit voller Pruefung (Server sendet die Kette vollstaendig oder Rueckfall nicht noetig); $NDET" ;;
      rueckfall)
        if [[ "$NPINOK" == true ]]; then
          ok "NINA Zertifikatskette (Rueckfall)" "Rueckfall ueber gepinnte Zwischenstelle (Sectigo E36) aktiv - erwartet, warnung.bund.de sendet die Zwischenstelle nicht; Pruefung bleibt voll, letzter Rueckfall vor $(dur "${NFAGO:-0}"); $NDET"
        else
          warn "NINA Zertifikatskette (Rueckfall)" "Rueckfall gemeldet, aber gepinnte Zwischenstelle nicht nutzbar (${NPINWHY:-?}); $NDET" "Datei certs/sectigo-e36.pem im Projekt pruefen (nur lesen); NINA kann sonst blind werden."
        fi ;;
      fehler)
        fail "NINA Zertifikatskette" "Kette auch mit dem Rueckfall nicht pruefbar: ${NFAILW:-?} (vor $(dur "$(jv fail.ago_s)")); NINA zeigt nur den letzten Stand" "Dashboard-Journal lesen (grep ninaFix); Zwischenstelle certs/sectigo-e36.pem und Systemzertifikate pruefen; kein verify=False einbauen." ;;
      *) warn "NINA Zertifikatskette" "/api/nina-cert meldet Zustand '${NINA_MODE:-?}'" "Dashboard-Journal lesen (grep ninaFix)." ;;
    esac
    if [[ "$NPINOK" == false ]] && [[ "$NINA_MODE" == normal ]]; then
      warn "NINA gepinnte Zwischenstelle" "Rueckfall waere ausgeschaltet: ${NPINWHY:-?}" "certs/sectigo-e36.pem im Projekt pruefen (nur lesen); solange der Server die Kette sendet, ist NINA nicht betroffen."
    fi
    if [[ "$NPDAYS" =~ ^-?[0-9]+$ ]]; then
      if (( NPDAYS < 0 )); then fail "NINA Zwischenstelle Ablauf" "gepinnte Zwischenstelle ist abgelaufen (vor $((-NPDAYS)) Tagen)" "Neue Zwischenstelle bereitstellen (Patch), sonst ist der Rueckfall unwirksam."
      elif (( NPDAYS < 90 )); then warn "NINA Zwischenstelle Ablauf" "gepinnte Zwischenstelle laeuft in $NPDAYS Tagen ab" "Neue Zwischenstelle rechtzeitig bereitstellen."
      else ok "NINA Zwischenstelle Ablauf" "gepinnte Zwischenstelle noch $NPDAYS Tage gueltig (bis 2036)"; fi
    fi
  elif [[ "$HTTP_CODE" == 404 ]]; then warn "NINA Zertifikatskette" "/api/nina-cert nicht vorhanden (HTTP 404)" "ninaFix (commit36) angewendet?"
  else skip "NINA Zertifikatskette" "/api/nina-cert lieferte HTTP $HTTP_CODE oder kein JSON"; fi

  # --- hideTexts (commit37): Lage-Seite ("/") ohne Zertifikatsketten-Hinweis (Rueckfall) und ohne SDR-Rollentext
  if [[ -z "$PAGE1_BODY" ]]; then http_get "$BASEURL/" 8; [[ "$HTTP_CODE" == 200 ]] && PAGE1_BODY="$HTTP_BODY"; fi
  if [[ -n "$PAGE1_BODY" && "$PAGE1_BODY" != *'id="sbLoading"'* ]]; then
    if [[ "$PAGE1_BODY" == *'id="nina-cert"'* ]]; then
      if [[ "$NINA_MODE" == rueckfall ]]; then warn "hideTexts: Ketten-Hinweis" "Lage-Seite zeigt den Zertifikatsketten-Hinweis trotz erwartetem Rueckfall" "hideTexts (commit37) angewendet? Marker hideTexts und sha16 pruefen."
      else info "hideTexts: Ketten-Hinweis" "Lage-Seite zeigt den Hinweis (Zustand ${NINA_MODE:-?}: Fehler oder Ablauf unter 90 Tagen bleiben bewusst sichtbar)"; fi
    else ok "hideTexts: Ketten-Hinweis" "Lage-Seite ohne Zertifikatsketten-Hinweis"; fi
    if [[ "$PAGE1_BODY" != *'id="lm1-js"'* ]]; then skip "hideTexts: SDR-Rollentext" "Lage-Skript (lm1-js) nicht in der Seite gefunden"
    elif [[ "$PAGE1_BODY" == *"A.note"* || "$PAGE1_BODY" == *"querySelector('.sdl-note')"* ]]; then warn "hideTexts: SDR-Rollentext" "Lage-Skript schreibt den SDR-Rollentext (bc_note) noch in die BR24-Kachel" "hideTexts (commit37) angewendet? Marker hideTexts und sha16 pruefen."
    else ok "hideTexts: SDR-Rollentext" "Lage-Skript schreibt den SDR-Rollentext nicht mehr in die Kachel"; fi
  else skip "hideTexts" "Lage-Seite nicht verfuegbar oder laedt noch"; fi

  # --- SDR-Watchdog (Datenlage der Sticks, nur lesen)
  http_get "$BASEURL/api/sdr/wd" 8
  if [[ "$HTTP_CODE" == 200 ]] && jloads "$HTTP_BODY"; then
    WL="$(jv lvl)"; WT="$(mask "$(jv short)")"; [[ -n "$WT" ]] || WT="$(mask "$(jv txt)")"
    case "$WL" in
      ok) ok "SDR-Daten-Watchdog" "$WT" ;;
      gelb) warn "SDR-Daten-Watchdog" "$WT" "Betroffenen Stick im Dashboard (/funk) ansehen." ;;
      rot) fail "SDR-Daten-Watchdog" "$WT" "Stick/Empfang pruefen (Dashboard /funk); prepper-sdr-Journal lesen." ;;
      *) info "SDR-Daten-Watchdog" "${WT:-keine Bewertung} (Stufe ${WL:-?})" ;;
    esac
    WD_ALL_LVL="$WL"
    NS="$(jv sticks.#)"
    if [[ "$NS" =~ ^[0-9]+$ ]]; then
      for ((i = 0; i < NS && i < 6; i++)); do
        SL="$(jv "sticks.$i.lvl")"; STX="$(mask "$(jv "sticks.$i.txt")")"
        # Benennung nach der Rolle im Watchdog-Text (nicht nach Listenplatz): Airspy 11D, Stick 1 5C, Stick 2 Hobby, Stick 3 Hobby2
        case "$STX" in
          *[Aa]irspy*|*11D*) RNAME="Airspy 11D"; WD_AIRSPY_LVL="${SL:-?}" ;;
          *"Stick 1"*|*5C*) RNAME="Stick 1 5C" ;;
          *"Stick 2"*) RNAME="Stick 2 Hobby" ;;
          *"Stick 3"*) RNAME="Stick 3 Hobby2" ;;
          *) RNAME="Eintrag $((i + 1))" ;;
        esac
        case "$SL" in gelb) warn "SDR $RNAME (Watchdog)" "$STX" "Stick im Dashboard ansehen." ;; rot) fail "SDR $RNAME (Watchdog)" "$STX" "Stick/Empfang pruefen." ;; *) info "SDR $RNAME (Watchdog)" "$STX" ;; esac
      done
    fi
  else skip "SDR-Daten-Watchdog" "/api/sdr/wd lieferte HTTP $HTTP_CODE"; fi
fi

# ================================================================ 5) Patch-Stand
section "Patch-Stand (Soll: AUDIT-STAND.md, nach commit47)"
DASHF="$APP/dashboard.py"
if [[ -r "$DASHF" ]]; then
  DSH="$(sha16_of "$DASHF")"
  if [[ "$DSH" == "$DASH_SHA16" ]]; then ok "dashboard.py sha16" "$DSH = Soll (Pi-Stand nach commit47), $(wc -l < "$DASHF") Zeilen"
  else warn "dashboard.py sha16" "$DSH, Soll $DASH_SHA16 (nach commit47)" "Neuer Patch seit commit47 oder Abweichung? Dann Soll im Skript (FC_DASH_SHA16) nachziehen; sonst Stand gegen AUDIT-STAND.md pruefen."; fi
  MKBAD=""; MKSUM=""
  for m in "${MARKERS[@]}"; do
    c="$(grep -c "# ===== $m:" "$DASHF" 2>/dev/null)"; [[ "$c" =~ ^[0-9]+$ ]] || c="?"
    MKSUM+=" $m=$c"; [[ "$c" == 1 ]] || MKBAD+=" $m=$c"
  done
  if [[ -z "$MKBAD" ]]; then ok "Patch-Marker in dashboard.py" "alle ${#MARKERS[@]} Marker genau 1x:$MKSUM"
  else fail "Patch-Marker in dashboard.py" "nicht genau 1x:$MKBAD (0 = Patch fehlt, 2 oder mehr = doppelt angewendet)" "Patch-Stand mit AUDIT-STAND.md vergleichen; nichts von Hand aendern, Patch-Reihenfolge pruefen."; fi
else fail "dashboard.py" "$DASHF nicht lesbar" "Pfad/Rechte pruefen."; fi
# NINA: gepinnte Zwischenstelle (ninaFix) - nur Datei lesen, DER-sha256 vergleichen (oeffentliches Zertifikat, kein Schluessel)
PEMF="$APP/$NINA_PEM_REL"
if [[ -r "$PEMF" ]]; then
  if have "$PYBIN"; then
    PEMR="$(timeout 10 "$PYBIN" - "$PEMF" 2>/dev/null <<'PYPEM'
import sys, re, ssl, hashlib
try:
    t = open(sys.argv[1], "r", errors="replace").read(200000)
    if "PRIVATE KEY" in t:
        print("private"); sys.exit(0)
    m = re.search(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", t, re.S)
    if not m:
        print("kein_zertifikat"); sys.exit(0)
    print("sha=" + hashlib.sha256(ssl.PEM_cert_to_DER_cert(m.group(0))).hexdigest())
except Exception:
    print("fehler")
PYPEM
)"
    case "$PEMR" in
      sha=*)
        PEMH="${PEMR#sha=}"
        if [[ "${PEMH:0:${#NINA_PEM_DER16}}" == "$NINA_PEM_DER16" ]]; then ok "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL vorhanden, DER-sha256 beginnt mit $NINA_PEM_DER16 (Sectigo E36, wie gepinnt)"
        else warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL vorhanden, DER-sha256 beginnt mit ${PEMH:0:8} statt $NINA_PEM_DER16" "Das Dashboard prueft den Pin selbst; Datei nicht von Hand aendern, Patch ninaFix pruefen."; fi ;;
      private) fail "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL enthaelt einen privaten Schluessel (darf nicht sein; Inhalt wird nicht angezeigt)" "Datei pruefen und durch die oeffentliche Zwischenstelle ersetzen (Patch ninaFix)." ;;
      kein_zertifikat) warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL enthaelt kein Zertifikat im PEM-Format" "Patch ninaFix erneut pruefen (nur lesen)." ;;
      *) warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL nicht auswertbar" "Datei nur ansehen; Dashboard-Journal grep ninaFix." ;;
    esac
  else info "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL vorhanden (python3 fehlt, Pruefsumme nicht berechnet)"; fi
  PEMM="$(file_mode "$PEMF")"
  [[ "$PEMM" =~ ^[0-7]{3,4}$ ]] && (( 8#$PEMM & 8#022 )) && warn "NINA Zwischenstelle Rechte" "$NINA_PEM_REL ist fuer Gruppe/andere schreibbar (Rechte $PEMM)" "chmod go-w (nur Rechte); die Datei ist die Vertrauensbasis fuer den Rueckfall."
else
  case "$NINA_MODE" in
    normal) warn "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL fehlt - Rueckfall nicht moeglich (NINA laeuft gerade ohne Rueckfall)" "ninaFix (commit36) erneut anwenden, falls warnung.bund.de die Kette wieder unvollstaendig sendet." ;;
    *) fail "NINA Zwischenstelle (Datei)" "$NINA_PEM_REL fehlt oder nicht lesbar - Rueckfall nicht moeglich" "ninaFix (commit36) erneut anwenden (Datei certs/sectigo-e36.pem)." ;;
  esac
fi
# weitere Dateien: nur Anzeige (Sollwerte der Stand-Datei gelten nicht als bestaetigt)
SAME=0; DIFF=""; MISS=""
for ref in "${REFS[@]}"; do
  rf="${ref%%:*}"; rs="${ref##*:}"
  if [[ ! -f "$APP/$rf" ]]; then MISS+=" $rf"; continue; fi
  h="$(sha16_of "$APP/$rf")"
  if [[ "${h:0:${#rs}}" == "$rs" ]]; then SAME=$((SAME + 1)); else DIFF+=" $rf=$h"; fi
done
info "weitere Dateien (nur Anzeige)" "$SAME von ${#REFS[@]} gleich der Referenz der Stand-Datei (Sollwerte dort unbestaetigt)${DIFF:+; abweichend:$DIFF}${MISS:+; fehlt:$MISS}"
for rf in prepper_sdr.py sdr_manager.py sdr_config.json; do [[ -f "$APP/$rf" ]] && info "sha16 $rf" "$(sha16_of "$APP/$rf")"; done

# ================================================================ 6) Mesh
section "Mesh (Bridges nur lesen)"
check_bridge() { # port name
  local port="$1" nm="$2"
  http_get "http://$HOSTN:$port/health" 5
  if [[ "$HTTP_CODE" != 200 ]]; then fail "Bridge $nm /health" "Port $port: HTTP $HTTP_CODE (curl rc $HTTP_RC)" "Dienst $nm pruefen: systemctl status; Dashboard sendet solange nichts (Meldungen werden nicht gesendet)."; return; fi
  if ! jloads "$HTTP_BODY"; then warn "Bridge $nm /health" "Antwort ist kein JSON" "Bridge-Journal lesen."; return; fi
  local conn sf so q held hl le qa qr
  conn="$(jv connected)"; sf="$(jv sent_fail)"; so="$(jv sent_ok)"; q="$(jv queued)"; held="$(jv held)"; hl="$(jv hold_left)"; le="$(jv last_error)"; qa="$(jv q_alarm)"; qr="$(jv q_routine)"
  if [[ "$conn" == true ]]; then ok "Bridge $nm: verbunden" "connected=true, gesendet ok=${so:-?} fail=${sf:-?}"
  else fail "Bridge $nm: verbunden" "connected=${conn:-?}${le:+, letzter Fehler: $(mask "${le:0:100}")}" "Funkgeraet/Verbindung der Bridge pruefen (Journal $nm); bis dahin gehen keine Mesh-Meldungen raus."; fi
  if [[ "$sf" =~ ^[0-9]+$ && "$so" =~ ^[0-9]+$ ]]; then
    if (( sf > 0 && sf * 5 > so + sf )); then warn "Bridge $nm: Sendefehler" "sent_fail=$sf bei sent_ok=$so (ueber 20 % Fehler)" "Mesh-Verbindung und Kanal-Auslastung pruefen."
    else ok "Bridge $nm: Sendefehler" "sent_fail=$sf bei sent_ok=$so"; fi
  fi
  if [[ "$q" =~ ^[0-9]+$ ]]; then
    if (( q > 20 )); then fail "Bridge $nm: Warteschlange" "queued=$q (alarm ${qa:-0}, routine ${qr:-0})" "Bridge steckt: Verbindung pruefen."
    elif (( q > 5 )); then warn "Bridge $nm: Warteschlange" "queued=$q (alarm ${qa:-0}, routine ${qr:-0})" "Beobachten; bei Dauer Bridge pruefen."
    else ok "Bridge $nm: Warteschlange" "queued=$q (alarm ${qa:-0}, routine ${qr:-0})"; fi
  fi
  if [[ "$held" == true ]]; then warn "Bridge $nm: Sendesperre" "gehalten (held=true, noch ${hl:-?} s)" "Gewollte Sendepause? Sonst im Dashboard fortsetzen (Pause nicht durch dieses Skript)."
  else ok "Bridge $nm: Sendesperre" "keine (held=false)"; fi
}
check_bridge "$BR1_PORT" "mesh-bridge"
check_bridge "$BR2_PORT" "mesh-bridge-bayern"

# Wetter-Auto-Stempel (Slot-Stunden 0,3,...,21)
WXF="$APP/mesh_weather_status.json"
if [[ -r "$WXF" ]]; then
  if jload flat < "$WXF"; then
    AUTO="$(jv auto)"
    if [[ "$AUTO" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})\ ([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then
      AEP="$(date -d "${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null)"
      if [[ "$AEP" =~ ^[0-9]+$ ]]; then
        AA=$((EPOCHSECONDS - AEP))
        if (( AA < 0 )); then warn "Mesh Wetter-Auto-Stempel" "Stempel $AUTO liegt in der Zukunft" "Systemuhr pruefen."
        elif (( AA > SLOT_MAX_S * 2 )); then fail "Mesh Wetter-Auto-Stempel" "letzter Auto-Versand $AUTO, vor $(dur "$AA") (erwartet hoechstens 3 h 10 min, mehrere Slots verpasst)" "/mesh-Verlauf und Journal (grep wxSlot, meshBootQuiet) lesen; Bridge-Zustand pruefen."
        elif (( AA > SLOT_MAX_S )); then warn "Mesh Wetter-Auto-Stempel" "letzter Auto-Versand $AUTO, vor $(dur "$AA") (erwartet hoechstens 3 h 10 min)" "Slot verpasst? wxSlot holt innerhalb der Slot-Stunde nach; /mesh-Verlauf lesen."
        else ok "Mesh Wetter-Auto-Stempel" "letzter Auto-Versand $AUTO, vor $(dur "$AA") (Grenze 3 h 10 min)"; fi
      else warn "Mesh Wetter-Auto-Stempel" "Stempel nicht auswertbar" "mesh_weather_status.json ansehen (nur lesen)."; fi
    else warn "Mesh Wetter-Auto-Stempel" "kein gueltiger auto-Stempel in der Datei" "mesh_weather_status.json ansehen (nur lesen)."; fi
  else warn "Mesh Wetter-Auto-Stempel" "mesh_weather_status.json ist kein gueltiges JSON" "Datei nur lesen/ansehen; Dashboard schreibt sie beim naechsten Versand neu."; fi
else warn "Mesh Wetter-Auto-Stempel" "mesh_weather_status.json fehlt" "Wird beim ersten Auto-Versand angelegt."; fi
OUTF="$APP/outage_mesh_state.json"
if [[ -r "$OUTF" ]]; then
  OAGE="$(file_age "$OUTF")"
  if jload flat < "$OUTF"; then
    ok "Stromausfall-Stand (Datei)" "outage_mesh_state.json vorhanden, geschrieben vor $(dur "${OAGE:-0}"), $(jv ids.#) bekannte Meldung(en)"
  else fail "Stromausfall-Stand (Datei)" "outage_mesh_state.json ist kein gueltiges JSON" "Datei nur ansehen; wxSlot ignoriert sie dann und beginnt neu (keine Sendung)."; fi
else warn "Stromausfall-Stand (Datei)" "outage_mesh_state.json fehlt" "Wird nach der ersten Beobachtung (wxSlot, commit34) angelegt."; fi

# ================================================================ 7) SDR
section "SDR (nur lesen, keine Sticks geoeffnet)"
declare -A USBSN=() USBID=() USBID_SN=()
# 2.0.2: Airspy meldet im sysfs "AIRSPY SN:637862DC2E8092D7" - Praefix bis "SN:" abschneiden, verglichen wird nur die Hex-Nummer
SN_RE='^[A-Z0-9_ .-]*SN:[[:space:]]*([0-9A-F]+)[[:space:]]*$'
for d in "$SYS"/bus/usb/devices/*; do
  [[ -d "$d" ]] || continue
  sn=""; [[ -r "$d/serial" ]] && { read -r sn < "$d/serial" 2>/dev/null || sn=""; }
  sn="${sn^^}"; [[ "$sn" =~ $SN_RE ]] && sn="${BASH_REMATCH[1]}"
  pr=""; [[ -r "$d/product" ]] && read -r pr < "$d/product" 2>/dev/null
  [[ -n "$sn" ]] && USBSN["${sn^^}"]="${pr:-?}"
  vid=""; pid=""
  [[ -r "$d/idVendor" ]] && read -r vid < "$d/idVendor" 2>/dev/null
  [[ -r "$d/idProduct" ]] && read -r pid < "$d/idProduct" 2>/dev/null
  if [[ -n "$vid" && -n "$pid" ]]; then USBID["${vid,,}:${pid,,}"]=$(( ${USBID["${vid,,}:${pid,,}"]:-0} + 1 )); USBID_SN["${vid,,}:${pid,,}"]="${sn^^}"; fi
done
# zusaetzlich lsusb (ohne Optionen = nur die Geraeteliste aus sysfs, oeffnet kein Geraet): "Bus 001 Device 003: ID 1d50:60a1 ..."
LSUSB_SEEN=0
if have lsusb; then
  LSU="$(timeout 10 lsusb 2>/dev/null)"
  while read -r _ _ _ _ _ lid _; do
    [[ "$lid" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || continue
    LSUSB_SEEN=$((LSUSB_SEEN + 1))
    [[ -n "${USBID[${lid,,}]:-}" ]] || USBID["${lid,,}"]=1
  done <<<"$LSU"
fi
sdr_dev() { # serial name severity-if-missing
  local sn="${1^^}"
  if [[ -n "${USBSN[$sn]:-}" ]]; then ok "$2 (SN $1)" "am USB-Bus gefunden: ${USBSN[$sn]:0:40}"
  else _emit "$3" "$2 (SN $1)" "nicht am USB-Bus gefunden" "Stick/USB-Kabel/Hub pruefen (lsusb); SDR-Zugriff nur ueber prepper-sdr."; fi
}
# Airspy R2: Erkennung ueber VID:PID 1d50:60a1 (Existenz = OK, auch ohne Seriennummer im sysfs); Seriennummer nur lesend aus sysfs verglichen
airspy_check() {
  local nm="Airspy R2 (11D fest)" got="${USBID_SN[$AIRSPY_VIDPID]:-}" exp="${AIRSPY_SN^^}" src="sysfs"
  [[ -n "${USBID[$AIRSPY_VIDPID]:-}" ]] || src=""
  if [[ -n "$src" ]]; then
    if [[ -n "${USBSN[$exp]:-}" ]]; then ok "$nm (SN $AIRSPY_SN)" "am USB-Bus gefunden (VID:PID $AIRSPY_VIDPID), Seriennummer passt"
    elif [[ -n "$got" ]]; then warn "$nm (SN $AIRSPY_SN)" "VID:PID $AIRSPY_VIDPID gefunden, aber Seriennummer weicht ab (gelesen: ${got:0:24}, erwartet: $AIRSPY_SN)" "Anderer Airspy angesteckt oder getauscht? Nur Anzeige - Empfang laeuft laut Watchdog separat (Dashboard /funk)."
    else ok "$nm (SN $AIRSPY_SN)" "am USB-Bus gefunden (VID:PID $AIRSPY_VIDPID); Seriennummer im sysfs nicht lesbar - nur die Existenz geprueft"; fi
    return
  fi
  if [[ -n "${USBSN[$exp]:-}" ]]; then ok "$nm (SN $AIRSPY_SN)" "ueber die Seriennummer am USB-Bus gefunden: ${USBSN[$exp]:0:40}"; return; fi
  if [[ "$WD_AIRSPY_LVL" == ok || ( -z "$WD_AIRSPY_LVL" && "$WD_ALL_LVL" == ok ) ]]; then
    warn "$nm (SN $AIRSPY_SN)" "Widerspruch: weder VID:PID $AIRSPY_VIDPID noch Seriennummer am USB-Bus gefunden, aber der Daten-Watchdog meldet Empfang ok" "lsusb als Benutzer fmg lesen (nur Anzeige); Skript/Rechte pruefen, Empfang laeuft offenbar."
  else
    fail "$nm (SN $AIRSPY_SN)" "nicht am USB-Bus gefunden (VID:PID $AIRSPY_VIDPID) und der Daten-Watchdog meldet keinen Empfang (${WD_AIRSPY_LVL:-${WD_ALL_LVL:-keine Angabe}})" "Airspy/USB-Kabel/Hub pruefen (lsusb); SDR-Zugriff nur ueber prepper-sdr."
  fi
}
if (( ${#USBSN[@]} > 0 || ${#USBID[@]} > 0 )); then
  airspy_check
  sdr_dev "$STICK1_SN" "Stick 1 (5C/10C)" fail
  sdr_dev "$STICK2_SN" "Stick 2 (hobby)" warn
  sdr_dev "$STICK3_SN" "Stick 3 (hobby2)" warn
else skip "SDR-Sticks am USB-Bus" "keine USB-Geraeteliste lesbar ($SYS/bus/usb/devices, lsusb)"; fi
AGF="$APP/sdr_autogain.json"
if [[ -r "$AGF" ]] && jload flat < "$AGF"; then
  CUR="$(jv cur)"; AMODE="$(jv mode)"; LK="$(jv lock.kind)"; FLT="$(jv fault)"
  if [[ "$CUR" == 16 ]]; then ok "Airspy Gain-Stufe" "Stufe 16 (autoGain-Modus ${AMODE:-?})"
  elif [[ -z "$CUR" || "$CUR" == null ]]; then info "Airspy Gain-Stufe" "noch keine Stufe gemerkt (autoGain-Modus ${AMODE:-?})"
  elif [[ "$AMODE" == auto ]]; then info "Airspy Gain-Stufe" "Stufe $CUR (autoGain hat gewechselt; nur die Automatik darf aendern)"
  else warn "Airspy Gain-Stufe" "Stufe $CUR statt 16 im festen Modus (${AMODE:-?})" "Nur autoGain darf die Stufe aendern: Ursache im Dashboard (/funk, Gain) ansehen."; fi
  [[ "$FLT" == true ]] && warn "autoGain Zustand" "autoGain meldet Fehler (fault=true, Sperre $(mask "${LK:-?}"))" "Dashboard /funk: Gain-Anzeige lesen; Rueckfall ist Stufe 16."
elif [[ -f "$AGF" ]]; then warn "Airspy Gain-Stufe" "sdr_autogain.json nicht lesbar/kein JSON" "Datei nur ansehen; Rueckfall ist Stufe 16."
else info "Airspy Gain-Stufe" "keine sdr_autogain.json (Stufe 16 gilt)"; fi
SSA="$(file_age "$APP/sdr_status.json")" && info "prepper-sdr Statusdatei" "sdr_status.json zuletzt geschrieben vor $(dur "$SSA")" || info "prepper-sdr Statusdatei" "sdr_status.json nicht vorhanden"

# ================================================================ 8) Datenbank
section "Datenbank (nur lesend)"
DBF="$APP/lagezentrum.db"
if [[ -r "$DBF" ]]; then
  DBSZ="$(stat -c %s -- "$DBF" 2>/dev/null)"; WALSZ="$(stat -c %s -- "$DBF-wal" 2>/dev/null || echo 0)"
  [[ "$DBSZ" =~ ^[0-9]+$ ]] || DBSZ=0; [[ "$WALSZ" =~ ^[0-9]+$ ]] || WALSZ=0
  if [[ -e "$DBF-wal" ]]; then
    if (( WALSZ > 268435456 )); then warn "DB: WAL-Datei" "WAL $(mbf "$WALSZ") MB (ueber 256 MB, Checkpoint haengt?)" "Dashboard-Wartung (relDb) pruefen; WAL nicht von Hand loeschen."
    else ok "DB: WAL-Datei" "WAL vorhanden, $(mbf "$WALSZ") MB"; fi
  else info "DB: WAL-Datei" "keine -wal-Datei (Datenbank gerade ohne offene Schreibvorgaenge oder nicht im WAL-Mode)"; fi
  info "DB: Groesse" "lagezentrum.db $(mbf "$DBSZ") MB"
  # journal_mode direkt aus dem Dateikopf (Byte 18/19 = 2: WAL) - ohne SQLite zu oeffnen
  HDR="$(od -An -tu1 -j0 -N20 -- "$DBF" 2>/dev/null)"; read -r -a HB <<<"${HDR//$'\n'/ }"
  if (( ${#HB[@]} >= 20 )) && [[ "${HB[0]}" == 83 && "${HB[1]}" == 81 && "${HB[2]}" == 76 ]]; then
    if [[ "${HB[18]}" == 2 && "${HB[19]}" == 2 ]]; then ok "DB: journal_mode" "WAL (Dateikopf)"
    else warn "DB: journal_mode" "kein WAL-Mode (Dateikopf ${HB[18]}/${HB[19]})" "Datenbank-Wartung (relDb) pruefen."; fi
  else fail "DB: Dateikopf" "kein gueltiger SQLite-Kopf (Datei beschaedigt oder keine Datenbank)" "Sofort Backup sichern (Dashboard /pi, Sicherung), dann pruefen; nichts loeschen."; fi
  # quick_check nur lesend (mode=ro), nur bei kleiner Datenbank, mit Zeitlimit; sonst gilt der Cache der DB-Wartung
  # nur wenn das Dashboard die Datenbank geoeffnet hat (WAL-Index -shm vorhanden): so legt der lesende Zugriff keine neue Datei an
  DOQC=0; (( ! QUICK && DBSZ <= QC_MAX_MB * 1048576 )) && [[ -e "$DBF-shm" ]] && DOQC=1
  if (( DOQC )); then
    if have "$PYBIN"; then
      DBR="$(timeout 40 "$PYBIN" - "$DBF" 2>&1 <<'PYDB'
import sqlite3, sys, os, time
from urllib.parse import quote
p = sys.argv[1]
try:
    con = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(p)), uri=True, timeout=2)
    con.execute("PRAGMA query_only=1")
    t0 = time.time()
    con.set_progress_handler(lambda: 1 if time.time() - t0 > 25 else 0, 20000)
    try:
        rows = [str(r[0]) for r in con.execute("PRAGMA quick_check").fetchall()]
        print("qc=" + ("ok" if rows == ["ok"] else "BEFUND " + "; ".join(rows[:2])[:100]))
    except sqlite3.OperationalError as e:
        print("qc=abgebrochen " + str(e)[:60])
    except sqlite3.DatabaseError as e:
        print("qc=BEFUND " + str(e)[:80])
    print("qcms=%d" % int((time.time() - t0) * 1000))
    con.close()
except sqlite3.DatabaseError as e:
    print("qc=BEFUND " + str(e)[:80])
except Exception as e:
    print("err=" + str(e)[:100])
PYDB
)"
      DQC=""; DQMS=""; DERR=""
      while IFS= read -r line; do
        case "$line" in qc=*) DQC="${line#qc=}" ;; qcms=*) DQMS="${line#qcms=}" ;; err=*) DERR="${line#err=}" ;; esac
      done <<<"$DBR"
      if [[ -n "$DERR" ]]; then warn "DB: quick_check (live, mode=ro)" "SQLite-Fehler: $(mask "$DERR")" "Datenbank-Datei/Rechte pruefen; Dashboard nicht neu starten, erst Backup sichern."
      else
        case "$DQC" in
          ok) ok "DB: quick_check (live, mode=ro)" "ok in ${DQMS:-?} ms" ;;
          BEFUND*) fail "DB: quick_check (live, mode=ro)" "$(mask "$DQC")" "Sofort Backup sichern (Dashboard /pi, Sicherung), dann Ursache pruefen; nichts loeschen." ;;
          *) warn "DB: quick_check (live, mode=ro)" "${DQC:-keine Antwort}" "Datenbank unter Last: spaeter erneut pruefen (Zeitlimit 25 s)." ;;
        esac
      fi
    else skip "DB: quick_check (live)" "python3 fehlt"; fi
  elif (( QUICK )); then skip "DB: quick_check (live)" "mit --kurz uebersprungen"
  elif [[ ! -e "$DBF-shm" ]]; then info "DB: quick_check (live)" "nicht gelaufen: Datenbank gerade nicht vom Dashboard geoeffnet (kein WAL-Index) - so wird nichts angelegt; es gilt der Cache der DB-Wartung"
  else info "DB: quick_check (live)" "nicht gelaufen: Datenbank ueber $QC_MAX_MB MB (Zeit- und I/O-Schutz) - es gilt der Cache der DB-Wartung"; fi
  # Cache der DB-Wartung (quick_check von relDb)
  if [[ -r "$DBF.maint.json" ]] && jload flat < "$DBF.maint.json"; then
    QOK="$(jv qc.ok)"; QT="$(jv qc.t)"; QT="${QT%%.*}"
    if [[ "$QOK" == false ]]; then fail "DB: Wartungs-quick_check (Cache)" "Befund: $(mask "$(jv qc.rows.0)")" "Sofort Backup sichern, dann Datenbank pruefen."
    elif [[ "$QOK" == true && "$QT" =~ ^[0-9]+$ ]]; then
      QA=$((EPOCHSECONDS - QT))
      if (( QA > 8 * 86400 )); then warn "DB: Wartungs-quick_check (Cache)" "ok, aber vor $(dur "$QA") (erwartet woechentlich)" "Wartungsfaden (relDb) im Dashboard-Journal pruefen."
      else ok "DB: Wartungs-quick_check (Cache)" "ok, vor $(dur "$QA")"; fi
    else info "DB: Wartungs-quick_check (Cache)" "noch kein Ergebnis (laeuft woechentlich im Hintergrund)"; fi
  else info "DB: Wartungs-quick_check (Cache)" "lagezentrum.db.maint.json noch nicht vorhanden"; fi
else fail "Datenbank" "$DBF nicht lesbar" "Pfad/Rechte pruefen."; fi

# ================================================================ 9) Backups
section "Backups"
if [[ -d "$BACKUPS" ]]; then
  NB=0; NEWF=""; NEWM=0
  for f in "$BACKUPS"/prepper-*.tgz; do
    [[ -f "$f" ]] || continue
    NB=$((NB + 1)); m="$(stat -c %Y -- "$f" 2>/dev/null)"; [[ "$m" =~ ^[0-9]+$ ]] || continue
    if (( m > NEWM )); then NEWM=$m; NEWF="$f"; fi
  done
  if (( NB == 0 )); then fail "Backups" "keine Sicherung in $BACKUPS" "Im Dashboard /pi eine Sicherung anlegen (Kachel Sicherung) oder tools/backup.sh M pruefen."
  else
    BAGE=$((EPOCHSECONDS - NEWM)); BSZ="$(stat -c %s -- "$NEWF" 2>/dev/null)"
    DET="$NB Sicherung(en), neueste $(basename "$NEWF") ($(mbf "${BSZ:-0}") MB), vor $(dur "$BAGE")"
    if (( BAGE > 10 * 86400 )); then fail "Backup: Alter" "$DET (aelter als 10 Tage)" "Neue Sicherung anlegen (Dashboard /pi, Kachel Sicherung)."
    elif (( BAGE > 3 * 86400 )); then warn "Backup: Alter" "$DET (aelter als 3 Tage)" "Neue Sicherung anlegen oder Zeitplan pruefen."
    else ok "Backup: Alter" "$DET"; fi
    MJ="${NEWF%.tgz}.json"
    if [[ -r "$MJ" ]] && jload flat < "$MJ"; then
      BOK="$(jv ok)"; BSHA="$(jv sha256)"
      [[ "$BOK" == true ]] && ok "Backup: Protokoll (.json)" "ok=true, ${BSHA:+sha256 vorhanden, }Mitglieder $(jv members), DB-Pruefung: $(mask "$(jv db.0.quick_check)")" || fail "Backup: Protokoll (.json)" "ok=${BOK:-?}, Fehler: $(mask "$(jv err)")" "Sicherung wiederholen; Ursache in backup.sh-Meldung."
      if (( ! QUICK )) && [[ -n "$BSHA" && "$BSHA" != null && ${BSZ:-0} -le 524288000 ]]; then
        CS="$(timeout 60 sha256sum -- "$NEWF" 2>/dev/null)"; CS="${CS%% *}"
        if [[ -z "$CS" ]]; then warn "Backup: Pruefsumme" "nicht berechenbar (Zeitlimit/Lesefehler)" "Spaeter erneut pruefen."
        elif [[ "$CS" == "$BSHA" ]]; then ok "Backup: Pruefsumme" "sha256 stimmt mit dem Protokoll ueberein"
        else fail "Backup: Pruefsumme" "sha256 der Datei weicht vom Protokoll ab (Archiv veraendert/defekt)" "Neue Sicherung anlegen; dieses Archiv nicht fuer Restore nutzen."; fi
      elif (( QUICK )); then skip "Backup: Pruefsumme" "mit --kurz uebersprungen"; fi
    else warn "Backup: Protokoll (.json)" "kein lesbares Protokoll zur neuesten Sicherung" "Sicherung mit tools/backup.sh pruefen; Archiv ggf. mit tar -tzf lesen."; fi
    BM="$(file_mode "$NEWF")"; [[ "$BM" == 600 ]] && ok "Backup: Rechte" "Archiv 600" || warn "Backup: Rechte" "Archiv hat Rechte ${BM:-?} (erwartet 600; enthaelt Konfiguration)" "chmod 600 auf das Archiv (nur Rechte)."
  fi
  BDM="$(file_mode "$BACKUPS")"; [[ "$BDM" == 700 ]] || warn "Backup: Ordnerrechte" "$BACKUPS hat Rechte ${BDM:-?} (erwartet 700)" "chmod 700 (nur Rechte)."
else fail "Backups" "Ordner $BACKUPS fehlt" "Sicherung anlegen (Dashboard /pi)."; fi
for tool in backup.sh restore.sh; do
  tf="$APP/tools/$tool"
  if [[ -f "$tf" ]]; then [[ -x "$tf" ]] && ok "Werkzeug tools/$tool" "vorhanden, ausfuehrbar (sha16 $(sha16_of "$tf"))" || warn "Werkzeug tools/$tool" "vorhanden, aber nicht ausfuehrbar" "Dashboard ruft es per bash auf; Rechte nur pruefen."
  else fail "Werkzeug tools/$tool" "fehlt" "relBackup (commit18/18b) erneut anwenden."; fi
done

# ================================================================ 10) Sicherheit (lesend, ohne Inhalte)
section "Sicherheit (nur Rechte und Vorhandensein, nie Inhalte)"
perm_check() { # pfad name erwartet-maximal-Oktal-Maske-Text
  local p="$1" nm="$2" want="$3" m
  [[ -e "$p" ]] || { info "$nm" "nicht vorhanden"; return; }
  m="$(file_mode "$p")"
  if [[ ! "$m" =~ ^[0-7]{3,4}$ ]]; then skip "$nm" "Rechte nicht lesbar"; return; fi
  if (( (8#$m & 8#077) == 0 )); then ok "$nm" "Rechte $m (nur Eigentuemer)"
  elif (( 8#$m & 8#007 )); then warn "$nm" "Rechte $m: fuer ALLE lesbar/zugaenglich (empfohlen $want)" "chmod $want darauf (nur Rechte; kein Schluesseltausch noetig)."
  else warn "$nm" "Rechte $m: Gruppe hat Zugriff (empfohlen $want)" "chmod $want darauf (nur Rechte)."; fi
}
perm_check "$APP/config.py" "Rechte config.py" 600
perm_check "$APP/secrets" "Rechte secrets/ (Ordner)" 700
perm_check "$APP/secrets/keys.env" "Rechte secrets/keys.env" 600
if [[ -n "${PREPPER_KEYS_FILE:-}" ]]; then perm_check "$PREPPER_KEYS_FILE" "Rechte PREPPER_KEYS_FILE" 600; fi
perm_check "${HOME:-/home/fmg}/.ssh" "Rechte ~/.ssh" 700
if [[ -d "$APP" ]]; then
  SECBAD=""; SECN=0
  while IFS= read -r f; do
    SECN=$((SECN + 1)); m="$(file_mode "$f")"
    [[ "$m" =~ ^[0-7]{3,4}$ ]] && (( 8#$m & 8#007 )) && SECBAD+=" ${f#"$APP"/}($m)"
  done < <(timeout 20 find "$APP" -maxdepth 3 \( -path "$APP/venv" -o -path "$APP/.git" -o -path "$APP/archive" \) -prune -o -type f \( -name '*.env' -o \( -name '*.pem' ! -path "$APP/certs/*" \) -o -name '*.key' -o -name '.netrc' -o -name 'id_rsa*' -o -name 'id_ed25519*' \) -print 2>/dev/null)
  if [[ -n "$SECBAD" ]]; then warn "Schluessel-/Env-Dateien im Projekt" "fuer alle lesbar:${SECBAD:0:200}" "chmod 600 (nur Rechte)."
  else ok "Schluessel-/Env-Dateien im Projekt" "$SECN Datei(en) gefunden, keine fuer alle lesbar (certs/ mit oeffentlichen Zertifikaten ausgenommen)"; fi
fi
# defusedxml (XML-Haertung secXml)
for py in "$VENV_PY" "$PYBIN"; do
  have "$py" || [[ -x "$py" ]] || continue
  lab="$([[ "$py" == "$VENV_PY" ]] && echo venv || echo system)"
  if timeout 15 "$py" -c 'import defusedxml' 2>/dev/null; then ok "defusedxml ($lab-Python)" "importierbar"
  elif [[ "$lab" == venv ]]; then fail "defusedxml (venv-Python)" "nicht importierbar im venv (das Dashboard laeuft damit)" "requirements/venv pruefen (secXml, commit31x); kein pip install durch dieses Skript."
  else info "defusedxml (system-Python)" "im System-Python nicht installiert (nur das venv zaehlt)"; fi
done
# offene Ports (nur Anzeige)
if have ss; then
  SSO="$(timeout 5 ss -H -ltn 2>/dev/null)"
  if [[ -n "$SSO" ]]; then
    EXPO=""; LOCP=""; P5000=0; BR_EXPO=""
    while read -r _ _ _ laddr _; do
      port="${laddr##*:}"; addr="${laddr%:*}"
      [[ "$port" =~ ^[0-9]+$ ]] || continue
      case "$addr" in 127.*|"[::1]"|::1) LOCP+=" $port" ;; *) EXPO+=" $port" ;; esac
      [[ "$port" == "$PORT" ]] && P5000=1
      if [[ "$port" == "$BR1_PORT" || "$port" == "$BR2_PORT" ]]; then case "$addr" in 127.*|"[::1]"|::1) ;; *) BR_EXPO+=" $port" ;; esac; fi
    done <<<"$SSO"
    (( P5000 )) && ok "Port $PORT lauscht" "Dashboard hoert auf Port $PORT" || fail "Port $PORT lauscht" "kein Listener auf Port $PORT" "Dienst prepper-dashboard pruefen."
    [[ -z "$BR_EXPO" ]] && ok "Bridge-Ports nur lokal" "Ports $BR1_PORT/$BR2_PORT nicht von aussen erreichbar" || warn "Bridge-Ports nur lokal" "Bridge-Port(s)$BR_EXPO lauschen auf allen Schnittstellen" "Bridge-Konfiguration pruefen (soll 127.0.0.1 sein); keine Firewall-Aenderung durch dieses Skript."
    info "Offene Ports (ss -ltn)" "von aussen erreichbar:${EXPO:- keine}; nur lokal:${LOCP:- keine} - Firewall/rpcbind bewusst offen (SEC-06/08), nur Information"
  else skip "Offene Ports" "ss lieferte nichts"; fi
else skip "Offene Ports" "ss fehlt"; fi

# ================================================================ 11) Journal (letzte 60 Minuten)
section "Journal (letzte 60 min, 4 Dienste)"
if ! have journalctl; then skip "Journal" "journalctl fehlt"
elif ! can_journal && (( ! SUDO_OK )); then skip "Journal der 4 Dienste" "braucht sudo (Benutzer nicht in Gruppe adm/systemd-journal) - Aufruf mit --sudo"
else
  jcmd() { if can_journal; then timeout 25 journalctl "$@"; else priv journalctl "$@"; fi; }
  for u in "${SERVICES[@]}"; do
    ERRS="$(jcmd -u "$u" --since "-60min" -p err --no-pager -q -o cat 2>/dev/null)"; ERC=$?
    ALLJ="$(jcmd -u "$u" --since "-60min" --no-pager -q -o cat 2>/dev/null)"
    if (( ERC > 1 )) && [[ -z "$ALLJ" ]]; then skip "Journal $u" "nicht lesbar (rc $ERC)"; continue; fi
    NERR=0; [[ -n "$ERRS" ]] && NERR="$(pf "$ERRS" | grep -c '')"
    NTB="$(pf "$ALLJ" | grep -c 'Traceback (most recent call last)')"; [[ "$NTB" =~ ^[0-9]+$ ]] || NTB=0
    LASTE="$(pf "$ALLJ" | grep -E '^[A-Za-z_.]*(Error|Exception)\b' | tail -1)"
    if [[ "$u" == prepper-dashboard ]]; then
      NNF="$(pf "$ALLJ" | grep -c '^ninaFix')"; [[ "$NNF" =~ ^[0-9]+$ ]] || NNF=0
      (( NNF > 0 )) && info "Journal ninaFix" "$NNF Meldung(en) in 60 min, zuletzt: $(mask "$(pf "$ALLJ" | grep '^ninaFix' | tail -1 | cut -c1-140)") (Rueckfall-Meldungen sind erwartet)"
    fi
    DET="$NTB Traceback(s), $NERR Zeile(n) mit Prioritaet err in 60 min"
    [[ -n "$LASTE" ]] && DET+=", letzte Ausnahme: $(mask "${LASTE:0:120}")"
    if (( NTB >= 5 || NERR >= 20 )); then fail "Journal $u" "$DET" "journalctl -u $u --since -60min -p err lesen; Ursache beheben."
    elif (( NTB >= 1 || NERR >= 1 )); then warn "Journal $u" "$DET" "journalctl -u $u --since -60min lesen (Einzelfaelle durch Quellen-Ausfaelle moeglich)."
    else ok "Journal $u" "keine Tracebacks, keine err-Zeilen in 60 min"; fi
  done
fi

# ================================================================ 12) Aufraeumen (nur Information)
section "Aufraeumen (nur Information)"
if [[ -d "$APP" ]]; then
  NBAK=0
  for f in "$APP"/*.bak "$APP"/*.bak-* "$APP"/tools/*.bak-*; do [[ -f "$f" ]] && NBAK=$((NBAK + 1)); done
  if (( NBAK > 100 )); then info ".bak-Dateien im Projekt" "$NBAK Stueck (Aufraeumen steht auf der Liste; Patches behalten je 3 eigene)"; else info ".bak-Dateien im Projekt" "$NBAK Stueck"; fi
  if [[ -d "$APP/venv" ]]; then
    NROOT="$(timeout 20 find "$APP/venv" ! -user "$(id -un 2>/dev/null)" 2>/dev/null | wc -l)"
    [[ "$NROOT" =~ ^[0-9]+$ ]] && { (( NROOT > 0 )) && info "venv: fremde Eigentuemer" "$NROOT Datei(en)/Ordner nicht von $(id -un) (root-eigenes ~ip, Aufraeumen braucht sudo; stoert nur pip)" || info "venv: fremde Eigentuemer" "keine"; }
  fi
fi

# ================================================================ Zusammenfassung
ELAPSED=$((SECONDS - T0))
SCORE=$((100 - 2 * N_WARN - 10 * N_FAIL)); (( SCORE < 0 )) && SCORE=0
EXITC=0; (( N_WARN > 0 )) && EXITC=1; (( N_FAIL > 0 )) && EXITC=2
END_STR="$(date '+%d.%m.%Y %H:%M:%S %Z')"

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//[^[:print:]]/ }"
  printf '%s' "$s"
}

if (( JSON )); then
  printf '{"tool":"fullcheck","version":"%s","host":"%s","user":"%s","time":"%s","tz":"Europe/Berlin","duration_s":%d,"mode":{"quick":%s,"sudo":%s},' \
    "$FC_VERSION" "$(json_esc "$(hostname 2>/dev/null || echo '?')")" "$(json_esc "$(id -un 2>/dev/null || echo '?')")" "$(date '+%Y-%m-%dT%H:%M:%S%:z')" "$ELAPSED" "$( ((QUICK)) && echo true || echo false)" "$( ((SUDO_OK)) && echo true || echo false)"
  printf '"summary":{"ok":%d,"warn":%d,"fail":%d,"info":%d,"skip":%d,"score":%d,"exit":%d},"checks":[' "$N_OK" "$N_WARN" "$N_FAIL" "$N_INFO" "$N_SKIP" "$SCORE" "$EXITC"
  for i in "${!R_NAME[@]}"; do
    (( i > 0 )) && printf ','
    printf '{"section":"%s","name":"%s","status":"%s","detail":"%s","hint":"%s"}' "$(json_esc "${R_SEC[$i]}")" "$(json_esc "${R_NAME[$i]}")" "${R_ST[$i]}" "$(json_esc "${R_DET[$i]}")" "$(json_esc "${R_HINT[$i]}")"
  done
  printf ']}\n'
else
  echo
  RC_COL="$C_OK"; (( N_WARN > 0 )) && RC_COL="$C_WARN"; (( N_FAIL > 0 )) && RC_COL="$C_FAIL"
  printf '%sErgebnis: %d OK, %d HINWEIS, %d FEHLER%s\n' "$RC_COL" "$N_OK" "$N_WARN" "$N_FAIL" "$C_0"
  printf 'Punkte: %d/100 (100 minus 2 je HINWEIS, 10 je FEHLER) - dazu %d INFO, %d uebersprungen\n' "$SCORE" "$N_INFO" "$N_SKIP"
  printf 'Stand: %s (Europe/Berlin), Laufzeit %d s, Exit-Code %d\n' "$END_STR" "$ELAPSED" "$EXITC"
  if (( N_FAIL > 0 )); then
    echo "FEHLER:"; for i in "${!R_NAME[@]}"; do [[ "${R_ST[$i]}" == fail ]] && printf '  - %s: %s\n' "${R_NAME[$i]}" "${R_DET[$i]}"; done
  fi
  if (( N_WARN > 0 )); then
    echo "HINWEIS:"; for i in "${!R_NAME[@]}"; do [[ "${R_ST[$i]}" == warn ]] && printf '  - %s: %s\n' "${R_NAME[$i]}" "${R_DET[$i]}"; done
  fi
  if (( N_SKIP > 0 && ! SUDO )); then echo "Hinweis: uebersprungene Pruefungen brauchen teils sudo - mit --sudo wiederholen (nur lesend)."; fi
fi
exit "$EXITC"
MK_C47_RFC_EOF
EMB="patch.py:$EXPECT_PAL edits.py:$EXPECT_RAE blk.py:$EXPECT_RAB guard.py:$EXPECT_RAG edits_lp.py:$EXPECT_RLP lp.py:$EXPECT_RLQ deadsdr.py:$EXPECT_RDS bakarch.py:$EXPECT_RBA fullcheck.sh:$EXPECT_RFC"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (9: Patcher, Block, Pruefprogramme, Aufraeumen, fullcheck.sh 2.0.2)"
s16() { sha256sum "$1" | cut -c1-16; }
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "$2"; return; }; shift 2; done; echo UNBEKANNT; }
# ---------- 1) Basis: alle drei Programmdateien gemeinsam alt oder neu ----------
for x in "$F" "$FL" "$FS"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS")
SD=$(lbl "$D16" "$KNOWN_D16" alt "$KNOWN_D16N" neu); SL=$(lbl "$L16" "$KNOWN_L16" alt "$KNOWN_L16N" neu); SS=$(lbl "$S16" "$KNOWN_S16" alt "$KNOWN_S16N" neu)
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach perf03Cache commit46, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 ($(wc -l < "$FL") Zeilen) - $SL (alt $KNOWN_L16, neu $KNOWN_L16N)"
echo "Basis prepper_sdr.py sha16 $S16 ($(wc -l < "$FS") Zeilen) - $SS (alt $KNOWN_S16, neu $KNOWN_S16N)"
for v in "dashboard.py:$SD:$D16" "lage_pages.py:$SL:$L16" "prepper_sdr.py:$SS:$S16"; do
  IFS=: read -r fn st h <<< "$v"
  if [[ "$st" == UNBEKANNT ]]; then
    echo "STOP: $fn weicht vom erwarteten Stand ab (sha16 $h) - nichts geaendert."
    echo "      commit47 passt nur auf den Stand nach commit46 perf03Cache. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
    exit 1
  fi
done
if [[ "$SD$SL$SS" != altaltalt && "$SD$SL$SS" != neuneuneu ]]; then
  echo "STOP: Mischstand (dashboard.py $SD, lage_pages.py $SL, prepper_sdr.py $SS) - erwartet alle alt oder alle neu - nichts geaendert."
  for x in "$F" "$FL" "$FS"; do LBX=$({ ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LBX" ]] && echo "      Sicherung vorhanden: $LBX ($(s16 "$LBX"))"; done
  echo "      Ein abgebrochener Lauf? Bitte diese Ausgabe an Grok schicken (nichts von Hand kopieren)."
  exit 1
fi
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" && -w "$FL" && -w "$FS" ]] || stop "Projektordner oder eine der drei Dateien ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug/jinja2 nicht"
[[ -f "$DASH_DIR/speedtest_run.py" ]] || stop "speedtest_run.py fehlt im Projektordner (Stand nach speedTest erwartet)"
FCS=fehlt
if [[ -e "$FCD" || -L "$FCD" ]]; then
  if [[ -L "$FCD" || ! -f "$FCD" ]]; then FCS=fremd
  else FC16=$(s16 "$FCD"); FCS=fremd; [[ "$FC16" == "$KNOWN_FCN" ]] && FCS=neu; for k in $KNOWN_FCA; do [[ "$FC16" == "$k" ]] && FCS=alt; done; fi
fi
case "$FCS" in
  fehlt) echo "fullcheck: $FCD fehlt - wird neu angelegt (2.0.2)";;
  alt) echo "fullcheck: $FCD ist $(sed -n 's/^FC_VERSION="\(.*\)"/\1/p' "$FCD" | head -1) (sha16 $FC16) - wird durch 2.0.2 ersetzt (Sicherung)";;
  neu) echo "fullcheck: $FCD ist schon 2.0.2";;
  fremd) echo "HINWEIS fullcheck: $FCD ist kein bekannter Stand (sha16 ${FC16:-?}) - wird NICHT angefasst; 2.0.2 laeuft am Ende aus $W/fullcheck.sh";;
esac
# ---- commit47: perfWsgi muss laufen (waitress, 8 Arbeitsfaeden) ----
wsst() { "${CURL[@]}" "$B/api/perfwsgi/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("server"), d.get("workers"))' 2>/dev/null || echo "? ?"; }
PCSV=$(wsst)
if [[ "$PCSV" == "waitress 8" ]]; then echo "OK perfWsgi laeuft (waitress, 8 Arbeitsfaeden)"
elif [[ "$DRY" == 1 ]]; then echo "HINWEIS perfWsgi-Status nicht lesbar ($PCSV) - im Trockenlauf unerheblich"
else stop "perfWsgi-Status $PCSV statt 'waitress 8' - Dashboard laeuft nicht wie nach commit45 erwartet"; fi
# ---- commit47: Neustart-Sperre HH:55-HH:04 (jede Stunde, Berlin-Zeit); geprueft jetzt, vor dem Ersetzen und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C47_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$C47_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$STATE" == neu ]]; then echo "OK Neustart-Sperre: commit47 ist schon installiert, es wird kein Neustart gebraucht"
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
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" || "$f" == "$FL" || "$f" == "$FS" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$W/patch.py" speedAsync dsh "$F" "$W/work/dashboard.py" "$W/blk.py" "$W/edits.py" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer speedAsync nicht eindeutig"; }
python3 "$W/lp.py" "$FL" "$W/work/lage_pages.py" "$W/edits_lp.py" > "$W/ql.log" || { cat "$W/ql.log"; stop "lage_pages.py: Stelle measureDownload nicht eindeutig"; }
python3 "$W/deadsdr.py" patch "$FS" "$W/work/prepper_sdr.py" > "$W/qs.log" 2>&1 || { cat "$W/qs.log"; stop "prepper_sdr.py: Nachweis toter Code nicht erbracht"; }
for v in "dashboard.py:$KNOWN_D16N" "lage_pages.py:$KNOWN_L16N" "prepper_sdr.py:$KNOWN_S16N"; do
  fn=${v%%:*}; [[ "$(s16 "$W/work/$fn")" == "${v#*:}" ]] || stop "Ergebnis $fn $(s16 "$W/work/$fn") statt ${v#*:} (Zielstand nicht erreicht)"
done
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(wc -l < "$W/work/dashboard.py") Zeilen; $(cat "$W/q.log")), lage_pages.py $KNOWN_L16N ($(cat "$W/ql.log")), prepper_sdr.py $KNOWN_S16N ($(wc -l < "$W/work/prepper_sdr.py") Zeilen; $(cut -c1-120 "$W/qs.log"))"
python3 "$W/patch.py" speedAsync dsh "$W/work/dashboard.py" "$W/work/x1" "$W/blk.py" "$W/edits.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
python3 "$W/lp.py" "$W/work/lage_pages.py" "$W/work/x2" "$W/edits_lp.py" > /dev/null && cmp -s "$W/work/lage_pages.py" "$W/work/x2" || stop "lage_pages.py nicht idempotent"
python3 "$W/deadsdr.py" patch "$W/work/prepper_sdr.py" "$W/work/x3" > /dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/x3" || stop "prepper_sdr.py nicht idempotent"
rm -f "$W/work/x1" "$W/work/x2" "$W/work/x3"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/work/prepper_sdr.py" "$W/patch.py" "$W/edits.py" "$W/blk.py" "$W/guard.py" "$W/edits_lp.py" "$W/lp.py" "$W/deadsdr.py" "$W/bakarch.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent (alle drei Dateien), py_compile ohne Warnung ($SPY und $VPY)"
bash -n "$W/fullcheck.sh" || stop "fullcheck.sh 2.0.2: Syntaxfehler"
FCV=$(bash "$W/fullcheck.sh" --version 2>/dev/null || true)
FCT=$(bash "$W/fullcheck.sh" --selftest 2>&1 | tail -1 || true)
[[ "$FCV" == "fullcheck.sh 2.0.2" && "$FCT" == *"0 fehlerhaft"* ]] && echo "OK fullcheck.sh 2.0.2: Syntax, Version, Selbsttest ($FCT)" || stop "fullcheck.sh 2.0.2: Version/Selbsttest ($FCV / $FCT)"
cp "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/neu/"
nice -n 10 "$VPY" "$W/guard.py" revert "$W/neu" "$W/alt" "$W/blk.py" "$W/edits.py" "$W/edits_lp.py" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: speedAsync im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" && "$(s16 "$W/alt/lage_pages.py")" == "$KNOWN_L16" ]] || stop "AST-Guard: Stand ohne speedAsync ist nicht die bekannte Basis"
export SA_STMOD="$DASH_DIR/speedtest_run.py"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt" "$W/neu" "$W/blk.py" "$W/edits.py" "$W/edits_lp.py" > "$W/g.log" 2>&1 || { grep -v "^speedAsync" "$W/g.log" | cut -c1-300; stop "AST-Guard speedAsync meldet Verstoss"; }
grep "Guard speedAsync" "$W/g.log" | cut -c1-260
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Seitenskript-Test laeuft nur in der Grok-Sandbox; hier statisch geprueft)"
MUTS=1; [[ -n "${C47_SIM_NOMUT:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && { MUTS=0; echo "SIM: Mutationstests uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || RH_ALT="$W/alt" nice -n 10 "$VPY" "$W/guard.py" mutate "$W/neu" "$W/blk.py" "$W/edits.py" "$W/edits_lp.py" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest speedAsync: eine Verfehlung wurde nicht erkannt"; }
[[ "$MUTS" == 0 ]] || grep -E "^OK Mutationstest" "$W/gm.log" | cut -c1-200
if [[ "$STATE" == neu ]]; then
  [[ "$(s16 "$FS")" == "$KNOWN_S16N" ]] || stop "prepper_sdr.py: Zustand neu, aber sha16 nicht Zielstand"
  echo "OK deadSdr: prepper_sdr.py ist schon Zielstand $KNOWN_S16N (Nachweis tot/ueberdeckt wurde beim ersten Lauf an der Basis erbracht; kein Rueckbau moeglich, nichts zu tun)"
else
cp "$FS" "$W/alt/prepper_sdr.py"; cp "$W/work/prepper_sdr.py" "$W/neu/prepper_sdr.py"
nice -n 10 python3 "$W/deadsdr.py" check "$W/alt/prepper_sdr.py" "$W/neu/prepper_sdr.py" > "$W/gs.log" 2>&1 || { cat "$W/gs.log"; stop "Guard deadSdr meldet Fehler"; }
cut -c1-220 "$W/gs.log"
[[ "$MUTS" == 0 ]] || nice -n 10 python3 "$W/deadsdr.py" mutate "$W/alt/prepper_sdr.py" "$W/neu/prepper_sdr.py" > "$W/gsm.log" 2>&1 || { grep -E "^UEBERSEHEN|Traceback" "$W/gsm.log" | cut -c1-200; stop "Mutationstest deadSdr: eine Verfehlung wurde nicht erkannt"; }
[[ "$MUTS" == 0 ]] || grep -E "^OK Mutationstest" "$W/gsm.log"
fi
python3 "$W/bakarch.py" selftest > "$W/gb.log" 2>&1 || { cat "$W/gb.log"; stop "bakArch Selbsttest"; }
[[ "$MUTS" == 0 ]] || python3 "$W/bakarch.py" mutate > "$W/gbm.log" 2>&1 || { grep -E "^UEBERSEHEN" "$W/gbm.log"; stop "Mutationstest bakArch: eine Verfehlung wurde nicht erkannt"; }
echo "OK $(cut -c1-120 "$W/gb.log"); $(grep -hE "^OK Mutationstest" "$W/gbm.log" 2>/dev/null)"
python3 "$W/bakarch.py" plan "$DASH_DIR" "$W/plan.tsv" > "$W/plan.log" 2>&1 || { cat "$W/plan.log"; stop "Aufraeumen: Plan der Sicherungsdateien nicht erstellbar"; }
NPLAN=$(wc -l < "$W/plan.tsv")
echo "Aufraeumen (Plan): $(tail -1 "$W/plan.log")"
{ head -12 "$W/plan.log" | grep -v "^PLAN" | head -10; } || true
TILDE_OK=1
if [[ -L "$VENV" || ! -d "$VENV" ]]; then TILDE_OK=0; echo "HINWEIS venv ist ein Link oder fehlt - ~ip-Rest wird nicht angefasst"
else python3 "$W/bakarch.py" tilde "$VENV" "$W/tilde-dry" dry > "$W/tl.log" 2>&1 || { cat "$W/tl.log"; TILDE_OK=0; }; fi
NTILDE=0; [[ "$TILDE_OK" == 1 ]] && NTILDE=$(sed -n 's/^TILDE //p' "$W/tl.log")
[[ "$TILDE_OK" == 1 ]] && { echo "Aufraeumen (Plan): ~ip-Reste in venv site-packages: ${NTILDE:-0}"; grep "^HINWEIS" "$W/tl.log" || true; }
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
# ---- commit47: Speedtest-Zustand vorher (nur Lesen; es wird keine Messung gestartet) ----
stst() { "${CURL[@]}" "$B/api/speedtest" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
l = d.get("last") or {}
print(d.get("ok"), d.get("running"), l.get("t") or 0, (l.get("at") or "-").replace(" ", "_"), l.get("down"))' 2>/dev/null || echo "FEHLER"; }
read -r S_OK S_RUN S_T S_AT S_DOWN <<< "$(stst)"
echo "Zustand vorher: /api/speedtest ok=$S_OK, laeuft=$S_RUN, letzte Messung $S_AT ($S_DOWN Mbit/s)"
[[ "$S_RUN" == True && "$DRY" != 1 && "$STATE" == alt ]] && echo "HINWEIS gerade laeuft eine Speedtest-Messung - der Neustart bricht sie ab (sie wird beim naechsten Takt wiederholt)"
rscheck "vor dem Neustart"
NEED=0; [[ "$STATE" == alt ]] && NEED=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet, nichts verschoben."
  if [[ "$NEED" == 0 ]]; then echo "  Zustand: speedAsync und deadSdr sind schon installiert - ein echter Lauf aendert an den Programmdateien nichts (Aufraeumen: $NPLAN Sicherungen, ${NTILDE:-0} ~ip-Reste; fullcheck: $FCS)."
  else echo "  Ein echter Lauf wuerde: dashboard.py, lage_pages.py, prepper_sdr.py ersetzen (Sicherung DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, pruefen; danach fullcheck 2.0.2 ($FCS), $NPLAN Sicherungen und ${NTILDE:-0} ~ip-Reste ins Archiv verschieben, fullcheck einmal laufen lassen (eine sudo-Passwortabfrage)."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
if [[ "$NEED" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren (Teil 1: Programmdateien) ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
INST=()
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "speedAsync|sdrFunk Modul|Traceback" | tail -6 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  echo "  Datenbank, fullcheck.sh, Sicherungsdateien und venv wurden nicht veraendert (Aufraeumen kommt erst nach der Pruefung)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED" == 0 ]]; then
  echo "OK speedAsync und deadSdr schon installiert - kein Neustart, keine Aenderung an den Programmdateien"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen"
  for x in "$F" "$FL" "$FS"; do
    cp -a "$x" "$x.bak-$NM-$TS"
    { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  for v in "$F:dashboard.py:$KNOWN_D16N" "$FL:lage_pages.py:$KNOWN_L16N" "$FS:prepper_sdr.py:$KNOWN_S16N"; do
    IFS=: read -r x fn h <<< "$v"
    INST+=("$x")
    cp "$W/work/$fn" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rb "$fn installieren"; exit 1; }
    [[ "$(s16 "$x")" == "$h" ]] || { rb "$fn nach dem Kopieren falsch ($(s16 "$x"))"; exit 1; }
  done
  echo "OK dashboard.py, lage_pages.py, prepper_sdr.py atomar ersetzt (Sicherungen *.bak-$NM-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst; prepper-sdr bleibt laufen) - warte auf HTTP 200 (max 240 s) und die Zeile 'speedAsync aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - speedAsync aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- commit47: speedAsync aktiv, Speedtest-Status lesbar (es wird keine Messung gestartet), perf03Cache/perfWsgi weiter aktiv ----
SAM=$(grep -c "^# ===== speedAsync:" "$F" || true)
[[ "$SAM" == 1 ]] && echo "OK Marker speedAsync 1x" || rbx "dashboard.py speedAsync-Marker ${SAM}x"
sast() { "${CURL[@]}" "$B/api/speedasync/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
print(d.get("aktiv"), d.get("start_wait_s"), d.get("dl_start"), d.get("err"))' 2>/dev/null || echo "FEHLER"; }
read -r A_AK A_SW A_DL A_ERR <<< "$(sast)"
[[ "$A_AK" == True && "$A_SW" == 0.01 ]] && echo "OK speedAsync aktiv (/api/speedasync/status: Start-Wartezeit ${A_SW} s, /api/download_test seit Neustart ${A_DL}x)" || rbx "speedAsync nicht aktiv (Status: $A_AK $A_SW $A_ERR)"
read -r S_OK2 S_RUN2 S_T2 S_AT2 S_DOWN2 <<< "$(stst)"
[[ "$S_OK2" == True ]] && echo "OK /api/speedtest lesbar wie bisher (letzte Messung $S_AT2, $S_DOWN2 Mbit/s; laeuft=$S_RUN2)" || rbx "/api/speedtest liefert keinen Status ($S_OK2)"
[[ "$S_T2" == "$S_T" || "$S_T2" -ge "$S_T" ]] || rbx "letzte Speedtest-Messung ist verschwunden ($S_AT -> $S_AT2)"
c=$(code "$B/api/perf03cache/status"); [[ "$c" == 200 ]] || rbx "/api/perf03cache/status HTTP $c"
PCWS=$(wsst)
[[ "$PCWS" == "waitress 8" ]] && echo "OK perfWsgi weiter aktiv (waitress, 8 Arbeitsfaeden)" || rbx "perfWsgi-Status nach dem Neustart: $PCWS"
"${CURL[@]}" "$B/pi" -o "$W/pi2.html" || true
grep -q 'fetch("/api/speedtest")' "$W/pi2.html" && grep -q 'k<50' "$W/pi2.html" && echo "OK /pi liefert das neue measureDownload (Status-Abfrage statt Warten)" || rbx "/pi ohne neues measureDownload (lage_pages.py nicht geladen?)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep speedAsync"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "speedAsync aktiv: speedAsync ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'speedAsync aktiv: speedAsync ok' ($(echo "$JD" | grep -F speedAsync | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten (auch kein Importfehler prepper_sdr)" || { echo "$JD" | grep -E 'speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein speedAsync-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)"); prepper-sdr laeuft unveraendert weiter"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"))" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Mesh, Gain-Waechter (Stufe 16, nur Automatik), /api/backup/restore und alle Dienste ausser prepper-dashboard unberuehrt"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) fullcheck.sh 2.0.2 (Teil 3) ----------
FCRUN="$FCD"
case "$FCS" in
  neu) echo "OK fullcheck.sh 2.0.2 schon installiert ($FCD)";;
  fremd) FCRUN="$W/fullcheck.sh"; echo "HINWEIS fullcheck.sh: $FCD unbekannter Stand - nicht ersetzt";;
  alt|fehlt)
    if [[ "$FCS" == alt ]]; then cp -a "$FCD" "$FCD.bak-$NM-$TS"; { ls -1t "$FCD.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done; fi
    cp "$W/fullcheck.sh" "$FCD.new" && chmod 755 "$FCD.new" && mv -f "$FCD.new" "$FCD"
    if [[ "$(s16 "$FCD")" == "$KNOWN_FCN" ]]; then echo "OK fullcheck.sh 2.0.2 installiert: $FCD ($KNOWN_FCN$([[ "$FCS" == alt ]] && echo ", Sicherung fullcheck.sh.bak-$NM-$TS"))"
    else echo "HINWEIS fullcheck.sh nicht wie erwartet ($(s16 "$FCD" 2>/dev/null)) - laeuft aus $W"; FCRUN="$W/fullcheck.sh"; fi;;
esac
# ---------- 9) Aufraeumen (Teil 2): Sicherungen und ~ip-Rest ins Archiv (verschieben, nie loeschen) ----------
python3 "$W/bakarch.py" plan "$DASH_DIR" "$W/plan.tsv" > "$W/plan.log" 2>&1
NPLAN=$(wc -l < "$W/plan.tsv" 2>/dev/null || echo 0)
ARCH="$DASH_DIR/bak-archiv/$TS"
NARCH=0
if [[ "${NPLAN:-0}" -gt 0 ]]; then
  if python3 "$W/bakarch.py" move "$DASH_DIR" "$ARCH" "$W/plan.tsv" > "$W/mv.log" 2>&1 && python3 "$W/bakarch.py" verify "$DASH_DIR" "$ARCH" > "$W/vf.log" 2>&1; then
    NARCH=$NPLAN
    echo "OK Aufraeumen: $(tail -1 "$W/plan.log" | sed 's/^PLAN //') - verschoben nach $ARCH/files ($(tail -1 "$W/vf.log"))"
  else
    cat "$W/mv.log" "$W/vf.log" 2>/dev/null | tail -4
    python3 "$W/bakarch.py" undo "$DASH_DIR" "$ARCH" > "$W/ud.log" 2>&1
    echo "HINWEIS Aufraeumen abgebrochen und zurueckgelegt ($(cat "$W/ud.log")) - Programmdateien davon unberuehrt"
  fi
else echo "OK Aufraeumen: keine alten Sicherungen zu verschieben (je Datei und Patch hoechstens $KEEP_LAST)"; fi
NBAK=$(find "$DASH_DIR" -maxdepth 1 -type f -name "*.bak*" | wc -l)
echo "  Sicherungen im Projektordner jetzt: $NBAK (je Datei und Patch die $KEEP_LAST neuesten)"
NTL=0
if [[ "$TILDE_OK" == 1 ]]; then
  python3 "$W/bakarch.py" tilde "$VENV" "$W/tilde-dry2" dry > "$W/tl2.log" 2>&1
  NTL=$(sed -n 's/^TILDE //p' "$W/tl2.log"); NTL=${NTL:-0}
  if [[ "$NTL" -gt 0 ]]; then
    if python3 "$W/bakarch.py" tilde "$VENV" "$ARCH" > "$W/tl3.log" 2>&1 && [[ -z "$(find "$VENV"/lib/python3*/site-packages -maxdepth 1 -name '~ip*' 2>/dev/null)" ]] && "$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null; then
      echo "OK ~ip-Rest: $NTL Eintrag/Eintraege aus venv site-packages nach $ARCH/venv-rest verschoben; venv-Python laedt flask weiter"
    else
      python3 "$W/bakarch.py" tundo "$VENV" "$ARCH" > "$W/tu.log" 2>&1
      echo "HINWEIS ~ip-Rest nicht sauber verschiebbar - zurueckgelegt ($(cat "$W/tu.log" "$W/tl3.log" 2>/dev/null | tail -2 | tr '\n' ' '))"; NTL=0
    fi
  else echo "OK ~ip-Rest: keiner (mehr) in venv site-packages$(grep -h "^HINWEIS" "$W/tl2.log" | sed 's/^HINWEIS/; Hinweis:/' | tr '\n' ' ')"; fi
fi
[[ -d "$ARCH" ]] && echo "  Archiv: $ARCH ($(du -sh "$ARCH" 2>/dev/null | cut -f1)) - Rueckweg: mv $ARCH/files/* $DASH_DIR/"
# ---------- 10) fullcheck einmal laufen lassen (nur lesend) ----------
echo "fullcheck 2.0.2 laeuft (nur lesend, bis 10 min) ..."
FC_APP="$DASH_DIR" FC_PORT="$PORT" timeout 600 bash "$FCRUN" --no-color > "$W/fc.txt" 2>&1; FCE=$?
sed -n '/^Ergebnis:/,$p' "$W/fc.txt" | head -30
grep -E "Airspy R2" "$W/fc.txt" | head -2 | cut -c1-200 || true
[[ "$FCE" -le 2 ]] && echo "OK fullcheck gelaufen (Exit $FCE; volle Ausgabe: $W/fc.txt)" || echo "HINWEIS fullcheck Exit $FCE (Zeitlimit?) - Ausgabe: $W/fc.txt"
# ---------- 11) Zusammenfassung ----------
for v in "$F" "$FL" "$FS"; do echo "  $(basename "$v") sha16 $(s16 "$v"), $(wc -c < "$v") Bytes, $(wc -l < "$v") Zeilen"; done
[[ -f "$FCD" ]] && echo "  fullcheck.sh sha16 $(s16 "$FCD"), $(sed -n 's/^FC_VERSION="\(.*\)"/\1/p' "$FCD" | head -1)"
RBL=""
for x in "$F" "$FL" "$FS"; do LB=$({ ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LB" ]] && RBL="$RBL cp -a $LB $x &&"; done
[[ -n "$RBL" ]] && echo "Rueckweg Programmdateien:$RBL sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine $NM-Sicherung vorhanden (Programmdateien nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c speedAsync /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/api/speedasync/status"
echo "  curl -s -o /dev/null -w %{http_code}_%{time_total} http://127.0.0.1:5000/api/speedtest"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep speedAsync"
echo "  ls /home/fmg/prepper-dashboard/bak-archiv"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme), keine Speedtest-Messung gestartet. Neue Docs-Version: bewusst nicht."
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
