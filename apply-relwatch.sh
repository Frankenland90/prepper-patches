#!/bin/bash
set -eEuo pipefail
# relWatch (commit30): systemd-Herzschlag + Aufseher fuer das Dashboard (REL-01 + REL-02): dashboard.py (3 Stellen + Block relWatch) und ein systemd-Drop-in fuer prepper-dashboard. Sendet nichts nach aussen (kein Mesh, kein Telegram, keine Alarme), keine Anzeige, keine Routen.
#  Befund: haengt der Webserver (alle Threads blockiert), merkt das nur der separate Wachhund (watchdog.py); das Dashboard selbst meldet systemd nichts. Haengende oder tote Hintergrundfaeden (Teil2/3/4, NINA/DWD, Sammelzyklus, Wetter, Frequenz) blieben unbemerkt.
#  A) Fruehes Modul am Dateianfang (nach den Importen): Faden relWatchBeat sendet alle 15 s WATCHDOG=1 an systemd - nur wenn systemd NOTIFY_SOCKET/WATCHDOG_USEC setzt, unabhaengig vom langen Erst-Update; Import und erstes Voll-Update (auch ueber 90 s) koennen daher keinen Neustart ausloesen.
#  B) Block relWatch (REL-02): Aufseher-Faden (Takt 15 s, Start in _sb_start_updates). Meldet haengende/tote Faeden nur (Journal + /api/sysboot/status, Abschnitt rel; kein Neustart von Faeden). Der Webserver wird erst NACH dem ersten Voll-Update ueber /api/time geprueft; erst wenn er 180 s
#     lang nicht antwortet (und die Pruefung vorher mindestens einmal gelungen war), loest der Aufseher EINEN kontrollierten Neustart ueber systemd aus (WATCHDOG=trigger), nur mit gespeichertem Zaehler (dash_halt.json) und Schleifenbremse (ab 4 Neustarts je Stunde kein weiterer Neustart).
#  C) Drop-in /etc/systemd/system/prepper-dashboard.service.d/zz-relwatch.conf: WatchdogSec=300 (grosszuegig: alle 15 s ein Takt), NotifyAccess=main, und nur falls die Unit keinen Neustart bei Watchdog-Ausfall kennt (Restart=no/on-success/on-abort): Restart=on-failure, RestartSec=5. Die Haupt-Unit bleibt unveraendert; nichts anderes wird angefasst.
#     Mit sudo, mit Rueckweg: bei jedem Fehler zuerst Drop-in zurueck (alte Datei oder entfernen), daemon-reload, dann dashboard.py zurueck, Neustart. Das Skript wartet nach dem Neustart WatchdogSec + 45 s (345 s) und bricht mit Rollback ab, wenn systemd das Dashboard in dieser Zeit neu startet (= Herzschlag kommt nicht an).
#  Konservativ: Faeden-Wiederbelebung bewusst nicht (offene Entscheidung); nur Meldung. Basis streng (sha16): dashboard.py 565137da31dc675d (Stand nach alarmFaden commit29) oder relWatch schon drin; sonst STOP mit Werten. Andere Dateien werden nicht angefasst.
#  Sicherung: dashboard.py.bak-relwatch-ZEIT und Drop-in-Sicherung (letzte 3). Keine Datenbank-Aenderung (daher keine SQLite-Sicherung). Keine neue Docs-Version (nur dashboard.py; Text fuer die naechste Docs-Version liegt beim Bericht).
# Aufruf: bash /tmp/apply-relwatch.sh commit30 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/relwatch-apply
KEEP_LAST=3
KNOWN_D16="565137da31dc675d"      # dashboard.py vor relWatch (Basis = Stand nach alarmFaden commit29)
KNOWN_D16N="874452e6491a74c5"             # dashboard.py nach relWatch (Ziel)
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
echo "=== relWatch apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): systemd-Herzschlag und Aufseher, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
UNITN=prepper-dashboard
DROPDIR="${DASH_DROPIN_DIR:-/etc/systemd/system/prepper-dashboard.service.d}"
DROPF="$DROPDIR/zz-relwatch.conf"
WDS=300            # WatchdogSec im Drop-in
HOLD_S=$((WDS + 45))   # so lange nach dem Neustart beobachten, ob systemd den Dienst neu startet
EXPECT_PAL="bd09cbc2a3746a3abf27e842ea62e27c4889866dda71e7437a4f8239693f51a7"
cat > "$W/patch-rw.py" << 'RW_PAL_EOF'
"""Patcher relWatch. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
RW_PAL_EOF
EXPECT_RAE="45217f7e68d95cc5c2646cda81fca81996ea6201ef04866a29f65daa4dfb855c"
cat > "$W/edits_rw.py" << 'RW_RAE_EOF'
# Stellen fuer relWatch (alt, neu): jede alte Stelle genau einmal in dashboard.py (Basis 565137da31dc675d); neuer Text nie Teilstueck des alten (sonst "teilweise vorhanden")
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
_EARLY_OLD = "import threading, time, subprocess\nfrom collections import deque\n"
_EARLY_NEW = _EARLY_OLD + '''
# ===== relWatch (Start): systemd-Herzschlag vom ersten Takt an (REL-01) - sendet ausschliesslich WATCHDOG=1 an systemd, nur wenn der Dienst unter systemd mit WatchdogSec laeuft; unabhaengig vom Rest =====
_RWB = {"n": 0, "err": None, "t": None, "stop": False, "started": False}
RWB_TICK_S = 15


def _rwb_notify(msg):
    a = os.environ.get("NOTIFY_SOCKET") or ""
    if not a or a[0] not in "/@":
        return False
    import socket as _rwb_sock
    s = _rwb_sock.socket(_rwb_sock.AF_UNIX, _rwb_sock.SOCK_DGRAM)
    try:
        s.settimeout(2)
        s.connect(("\\0" + a[1:]) if a[0] == "@" else a)
        s.sendall(msg.encode())
        return True
    except OSError as e:
        _RWB["err"] = str(e)[:80]
        return False
    finally:
        s.close()


def _rwb_loop():
    try:
        tick = max(1.0, min(float(RWB_TICK_S), int(os.environ.get("WATCHDOG_USEC") or 0) / 4e6 or float(RWB_TICK_S)))
    except Exception:
        tick = float(RWB_TICK_S)
    while not _RWB["stop"]:
        try:
            if _rwb_notify("WATCHDOG=1"):
                _RWB["n"] += 1
                _RWB["t"] = time.monotonic()
                if _RWB["n"] == 1:
                    print("relWatch: systemd-Herzschlag laeuft (alle %d s, WatchdogSec %s s)" % (tick, round(int(os.environ.get("WATCHDOG_USEC") or 0) / 1e6)), flush=True)
        except Exception as e:
            _RWB["err"] = str(e)[:80]
        time.sleep(tick)


if os.environ.get("NOTIFY_SOCKET") and os.environ.get("WATCHDOG_USEC") and os.environ.get("WATCHDOG_PID", str(os.getpid())) == str(os.getpid()):
    try:
        threading.Thread(target=_rwb_loop, name="relWatchBeat", daemon=True).start()
        _RWB["started"] = True
    except Exception as _rwb_e:
        print("relWatch Herzschlag nicht gestartet:", _rwb_e, flush=True)
# ===== /relWatch (Start) =====
'''
DSH_EDITS = [
    (_EARLY_OLD, _EARLY_NEW),
    ('def _sb_start_updates():\n    try:\n        _sb_thr.Thread(target=_sb_first_update, daemon=True, name="sysBootFirst").start()',
     'def _sb_start_updates():\n    _rw_start()  # relWatch\n    try:\n        _sb_thr.Thread(target=_sb_first_update, daemon=True, name="sysBootFirst").start()'),
    ('"selftest": _SB["selftest"], "pages_wrapped": _SB.get("wrapped"), "alarm": _alarm_status()})',
     '"selftest": _SB["selftest"], "pages_wrapped": _SB.get("wrapped"), "alarm": _alarm_status(), "rel": _rw_status()})'),
]
RW_RAE_EOF
EXPECT_RAB="63cc83b3f3cde241be7dcdb8d11b7377e49ba243e2b60f094e915fbb122bc3b7"
cat > "$W/blk_rw.py" << 'RW_RAB_EOF'
# ===== relWatch: Aufseher fuer die Alarm-Faeden (REL-02) und Prozess-Waechter fuer systemd (REL-01) - meldet im Status und im Journal; kontrollierter Neustart nur wenn der Webserver nach dem ersten Voll-Update 3 min lang nicht antwortet (hoechstens 3 je Stunde, Schleifenbremse); sendet nichts nach aussen =====
import http.client as _rw_http
import json as _rw_json
import os as _rw_os
import threading as _rw_th
import time as _rw_time

RW_TICK_S = 15                # Takt des Aufsehers
RW_FAIL_S = 180               # Webserver (eigene Adresse) so lange ohne Antwort -> kontrollierter Neustart (nur nach dem ersten Voll-Update)
RW_PROBE_S = 8                # Zeitlimit einer Pruefung
RW_PROBE_PATH = "/api/time"
RW_STALE_MIN_S = 300          # ein Faden gilt erst nach mindestens 5 min ohne Durchlauf als haengend
RW_STALE_X = 3                # ... und fruehestens nach 3 Intervallen
RW_BRAKE_N = 4                # ab so vielen Starts in einer Stunde nur noch melden (Schleifenbremse)
RW_KEEP_S = 86400
RW_FILE = "dash_halt.json"
_RW = {"th": None, "started": False, "err": None, "n": 0, "hb": {}, "red": [], "probe_ok": None, "fail_since": None, "trig": False, "brake": False, "brake_why": None,
       "starts_1h": 0, "armed": False, "tick_t": None, "t_start": None, "log_t": {}}
_RW_SPEC = {
    "teil2": ("teil2", lambda g: g["_T2D"]["n"], lambda g: g["T2D_TICK_S"]),
    "teil3": ("teil3", lambda g: g["_T3S"]["n"], lambda g: g["T3_TICK_S"]),
    "teil4": ("teil4", lambda g: g["_T4"]["n"], lambda g: g["T4_TICK_S"]),
    "alarm": ("alarm_loop", lambda g: g["_AL"]["n"], lambda g: g["ALARM_MAX_S"]),
    "zyklus": ("sysBootFirst", lambda g: str(g["data_store"].get("last_full_update")), lambda g: g["UPDATE_INTERVAL"]),
    "wetter": ("weather_mesh_loop", None, None),
    "freq": ("freq_loop", None, None),
}


def _rw_say(deps, *a):
    f = (deps or {}).get("say")
    (f if callable(f) else print)(*a, **({} if callable(f) else {"flush": True}))


def _rw_trans(label, old, new, e, deps=None):
    if new == "ok":
        if old != "unbekannt":
            _rw_say(deps, "relWatch: Faden %s wieder in Ordnung (vorher %s)" % (label, old))
    elif new == "stale":
        _rw_say(deps, "relWatch: Faden %s ohne Durchlauf seit %s s (Grenze %s s) - nur gemeldet, kein Eingriff" % (label, e.get("age"), round(e.get("limit") or 0)))
    elif new == "tot":
        _rw_say(deps, "relWatch: Faden %s laeuft nicht mehr - nur gemeldet, kein Eingriff" % label)


def _rw_eval(mono, alive, g, hb, log=None, spec=None):
    """Zustand je Faden: ok / stale (Zaehler bewegt sich nicht mehr) / tot (war da, jetzt weg) / unbekannt (nie gesehen). Uhrzeit-unabhaengig (monotone Zeit, eigene Beobachtung des Zaehlers)."""
    red = []
    for label, (tname, getc, getiv) in (spec or _RW_SPEC).items():
        e = hb.setdefault(label, {"seen": False, "n": None, "t": None, "state": "unbekannt", "age": None, "limit": None})
        up = tname in alive
        if up:
            e["seen"] = True
        cnt = None
        if getc is not None:
            try:
                cnt = getc(g)
            except Exception:
                cnt = None
        if not e["seen"]:
            new = "unbekannt"
        elif not up:
            new = "tot"
        else:
            if e["t"] is None or (cnt is not None and cnt != e["n"]):
                e["n"], e["t"] = cnt, mono
            e["age"] = int(mono - e["t"])
            limit = None
            if getiv is not None and cnt is not None:
                try:
                    limit = max(RW_STALE_MIN_S, RW_STALE_X * float(getiv(g)))
                except Exception:
                    limit = float(RW_STALE_MIN_S)
            e["limit"] = limit
            new = "stale" if (limit is not None and mono - e["t"] > limit) else "ok"
        if new != e["state"]:
            if log is not None:
                try:
                    log(label, e["state"], new, e)
                except Exception:
                    pass
            e["state"] = new
        if new in ("tot", "stale"):
            red.append(label)
    return red


def _rw_path(deps=None):
    base = (deps or {}).get("base") or _rw_os.path.dirname(_rw_os.path.abspath(globals().get("__file__") or "."))
    return _rw_os.path.join(base, RW_FILE)


def _rw_load(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = _rw_json.load(f)
    except Exception:
        d = None
    d = d if isinstance(d, dict) else {}
    out = {"v": 1, "starts": [], "triggers": []}
    for k in ("starts", "triggers"):
        for x in d.get(k) or []:
            if isinstance(x, dict) and isinstance(x.get("t"), (int, float)) and not isinstance(x.get("t"), bool):
                out[k].append({"t": int(x["t"]), **({"why": str(x.get("why"))[:160]} if x.get("why") else {})})
    return out


def _rw_prune(d, now):
    for k in ("starts", "triggers"):
        d[k] = [x for x in d[k] if (now - x["t"]) <= RW_KEEP_S][-40:]
    return d


def _rw_save(path, d):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(_rw_json.dumps(d, ensure_ascii=False))
        f.flush()
        _rw_os.fsync(f.fileno())
    _rw_os.replace(tmp, path)


def _rw_count_1h(entries, now):
    """Eintraege der letzten Stunde; Eintraege 'aus der Zukunft' (Uhr gesprungen) zaehlen mit - im Zweifel bremsen."""
    return sum(1 for x in entries if (now - x["t"]) <= 3600)


def _rw_probe(deps=None):
    d = deps or {}
    if callable(d.get("probe")):
        return d["probe"]()
    c = None
    try:
        c = _rw_http.HTTPConnection("127.0.0.1", int(d.get("port") or globals().get("PORT") or 5000), timeout=RW_PROBE_S)
        c.request("GET", RW_PROBE_PATH, headers={"Connection": "close"})
        r = c.getresponse()
        r.read(64)
        return True
    except (OSError, _rw_http.HTTPException):
        return False
    finally:
        if c is not None:
            c.close()


def _rw_logrl(key, deps, text, every=600):
    t = _rw_time.monotonic() if not (deps or {}).get("mono") else deps["mono"]()
    last = _RW["log_t"].get(key)
    if last is None or t - last >= every:
        _RW["log_t"][key] = t
        _rw_say(deps, text)


def _rw_trigger(why, deps=None):
    """Kontrollierter Neustart ueber systemd (WATCHDOG=trigger): zuerst im Zaehler festhalten - ohne gespeicherten Eintrag kein Neustart."""
    d = deps or {}
    now = d["now"]() if "now" in d else _rw_time.time()
    path = _rw_path(d)
    load, save = d.get("load") or _rw_load, d.get("save") or _rw_save
    try:
        st = _rw_prune(load(path), now)
        st["triggers"].append({"t": int(now), "why": why})
        save(path, st)
    except Exception as e:
        _rw_logrl("trig_save", d, "relWatch: Neustart-Zaehler nicht gespeichert (%s) - kein Neustart" % e)
        return False
    _RW["trig"] = True
    _rw_say(d, "relWatch: %s - kontrollierter Neustart ueber systemd (WATCHDOG=trigger)" % why)
    nf = d.get("notify") or globals().get("_rwb_notify")
    nf("STATUS=relWatch: Webserver antwortet nicht - kontrollierter Neustart")
    nf("WATCHDOG=trigger")
    return True


def _rw_tick(deps=None):
    d = deps or {}
    mono = d["mono"]() if "mono" in d else _rw_time.monotonic()
    alive = d["alive"]() if "alive" in d else {t.name for t in _rw_th.enumerate() if t.is_alive()}
    g = d["g"] if "g" in d else globals()
    _RW["red"] = _rw_eval(mono, alive, g, _RW["hb"], lambda *a: _rw_trans(*a, deps=d))
    _RW["tick_t"] = mono
    _RW["n"] += 1
    first_done = d["first_done"]() if "first_done" in d else (globals().get("_SB") or {}).get("first_done_t")
    sock = d["sock"] if "sock" in d else bool(_rw_os.environ.get("NOTIFY_SOCKET") and _rw_os.environ.get("WATCHDOG_USEC"))
    _RW["armed"] = bool(first_done) and bool(sock)
    if not first_done:
        _RW["fail_since"] = None          # vor dem ersten Voll-Update nie eine Pruefung, nie ein Neustart
        return "nicht scharf (erstes Voll-Update laeuft)"
    if _rw_probe(d):
        _RW["probe_ok"] = mono
        _RW["fail_since"] = None
        return "ok"
    if _RW["fail_since"] is None:
        _RW["fail_since"] = mono
    fs = mono - _RW["fail_since"]
    if fs < RW_FAIL_S or _RW["trig"]:
        return "antwortet nicht seit %d s" % fs
    if _RW["probe_ok"] is None:
        _rw_logrl("noprobe", d, "relWatch: Webserver antwortete seit dem Start nie auf die eigene Pruefung (%d s) - kein Neustart (Pruefung selbst unzuverlaessig?)" % fs)
        return "keine Aktion (Pruefung nie erfolgreich)"
    if not sock:
        _rw_logrl("nosock", d, "relWatch: Webserver antwortet seit %d s nicht, aber kein systemd-Watchdog (NOTIFY_SOCKET/WATCHDOG_USEC fehlen) - keine Aktion" % fs)
        return "keine Aktion (kein systemd-Watchdog)"
    if _RW["brake"]:
        _rw_logrl("brake", d, "relWatch: Webserver antwortet seit %d s nicht, Schleifenbremse aktiv (%s) - kein Neustart, nur Meldung" % (fs, _RW["brake_why"]))
        return "keine Aktion (Schleifenbremse)"
    if not _rw_trigger("Webserver antwortet seit %d s nicht auf die eigene Pruefung %s" % (fs, RW_PROBE_PATH), d):
        return "keine Aktion (Zaehler nicht speicherbar)"
    return "Neustart angefordert"


def _rw_loop():
    while True:
        try:
            _rw_tick()
        except Exception as e:
            _RW["err"] = str(e)[:120]
            _rw_logrl("loop", None, "relWatch Aufseher: %s" % e)
        _rw_time.sleep(RW_TICK_S)


def _rw_start(deps=None):
    d = deps or {}
    try:
        if _RW["started"] or str((globals().get("_RWG") or {}).get("selftest", "")).startswith("FEHLER"):
            return False
        _RW["started"] = True
        now = d["now"]() if "now" in d else _rw_time.time()
        path = _rw_path(d)
        load, save = d.get("load") or _rw_load, d.get("save") or _rw_save
        st = _rw_prune(load(path), now)
        st["starts"].append({"t": int(now)})
        n1h = _rw_count_1h(st["starts"], now)
        _RW["starts_1h"] = n1h
        if n1h >= RW_BRAKE_N:
            _RW["brake"], _RW["brake_why"] = True, "%d Starts in der letzten Stunde" % n1h
        try:
            save(path, st)
        except Exception as e:
            _RW["brake"], _RW["brake_why"] = True, "Start-Zaehler nicht speicherbar (%s)" % str(e)[:60]
        _RW["t_start"] = _rw_time.monotonic()
        _rw_say(d, "relWatch: Aufseher gestartet - Faeden %s, Webserver-Pruefung erst nach dem ersten Voll-Update, Neustart nach %d s ohne Antwort%s" % (
            "/".join(_RW_SPEC), RW_FAIL_S, " (Schleifenbremse aktiv: %s - nur Meldung)" % _RW["brake_why"] if _RW["brake"] else ""))
        if "no_thread" not in d:
            _RW["th"] = _rw_th.Thread(target=_rw_loop, name="relWatch", daemon=True)
            _RW["th"].start()
        return True
    except Exception as e:
        _RW["err"] = str(e)[:120]
        print("relWatch Start:", e, flush=True)
        return False


def _rw_status(deps=None):
    """Fuer /api/sysboot/status: je Faden Zustand/Alter, Waechter-Zustand. Wirft nie."""
    try:
        now = _rw_time.monotonic() if not (deps or {}).get("mono") else deps["mono"]()
        b = globals().get("_RWB") or {}
        pa = _RW["probe_ok"]
        return {"threads": {k: {"state": v["state"], "age_s": v["age"], "limit_s": None if v["limit"] is None else int(v["limit"])} for k, v in _RW["hb"].items()},
                "red": list(_RW["red"]),
                "wd": {"sock": bool(_rw_os.environ.get("NOTIFY_SOCKET") and _rw_os.environ.get("WATCHDOG_USEC")), "beats": b.get("n"), "beat_age_s": None if not b.get("t") else int(now - b["t"]),
                       "armed": _RW["armed"], "probe_age_s": None if pa is None else int(now - pa), "fail_s": None if _RW["fail_since"] is None else int(now - _RW["fail_since"]),
                       "fail_limit_s": RW_FAIL_S, "brake": _RW["brake"], "brake_why": _RW["brake_why"], "starts_1h": _RW["starts_1h"], "trigger_sent": _RW["trig"]},
                "ticks": _RW["n"], "thread": bool(_RW["th"] is not None and _RW["th"].is_alive()), "err": _RW["err"]}
    except Exception as e:
        return {"error": str(e)[:80]}


def _selftest_relwatch():
    """Rein rechnend mit Attrappen (kein Netz, keine Datei, kein Faden, kein systemd); Zustand der echten App bleibt unberuehrt."""
    import copy as _c
    saved = {k: _c.copy(v) for k, v in _RW.items() if k not in ("th",)}
    try:
        clock = [1000.0]
        wall = [1_000_000.0]
        sent, said, files = [], [], {}
        probe = {"ok": True, "n": 0}
        first = {"v": None}
        T2 = {"n": 0}
        G = {"_T2D": T2, "_T3S": {"n": 0}, "_T4": {"n": 0}, "_AL": {"n": 0}, "T2D_TICK_S": 20, "T3_TICK_S": 5, "T4_TICK_S": 2, "ALARM_MAX_S": 900, "UPDATE_INTERVAL": 900, "data_store": {}}
        alive = {"teil2", "teil3", "teil4", "alarm_loop", "sysBootFirst"}

        def fprobe():
            probe["n"] += 1
            if probe["ok"] == "boom":
                raise AssertionError("Pruefung darf nicht laufen")
            return probe["ok"]

        def fsave(p, d):
            if files.get("fail"):
                raise OSError("voll")
            files[p] = _c.deepcopy(d)

        deps = {"mono": lambda: clock[0], "now": lambda: wall[0], "alive": lambda: set(alive), "g": G, "probe": fprobe, "first_done": lambda: first["v"], "sock": True,
                "load": lambda p: _c.deepcopy(files.get(p) or {"v": 1, "starts": [], "triggers": []}), "save": fsave, "notify": lambda m: sent.append(m), "say": lambda *a: said.append(" ".join(str(x) for x in a)),
                "base": "/nonexistent-relwatch"}
        for k in ("hb", "log_t"):
            _RW[k] = {}
        for k, v in (("red", []), ("probe_ok", None), ("fail_since", None), ("trig", False), ("brake", False), ("brake_why", None), ("starts_1h", 0), ("armed", False), ("n", 0), ("err", None)):
            _RW[k] = v
        # 1) Faeden: ok / stale / ok / tot / unbekannt (nie gesehen)
        _rw_tick(dict(deps, first_done=lambda: None, probe=lambda: (_ for _ in ()).throw(AssertionError("vor dem ersten Voll-Update keine Pruefung"))))
        st = {k: v["state"] for k, v in _RW["hb"].items()}
        assert st["teil2"] == "ok" and st["alarm"] == "ok" and st["zyklus"] == "ok" and st["wetter"] == "unbekannt" and st["freq"] == "unbekannt", st
        assert _RW["red"] == [], _RW["red"]
        assert not any("wieder in Ordnung" in s for s in said), "erste Sichtung meldet nichts (kein Fehlalarm beim Start): %s" % said
        clock[0] += 299
        _rw_tick(dict(deps, first_done=lambda: None))
        assert _RW["hb"]["teil2"]["state"] == "ok", "unter 300 s ohne Durchlauf darf nichts gemeldet werden"
        clock[0] += 2
        _rw_tick(dict(deps, first_done=lambda: None))
        assert _RW["hb"]["teil2"]["state"] == "stale" and "teil2" in _RW["red"] and any("teil2 ohne Durchlauf" in s for s in said), (_RW["hb"]["teil2"], said)
        assert _RW["hb"]["alarm"]["state"] == "ok" and _RW["hb"]["alarm"]["limit"] == 2700, "Alarm-Faden: Grenze 3 x 900 s"
        T2["n"] += 1
        _rw_tick(dict(deps, first_done=lambda: None))
        assert _RW["hb"]["teil2"]["state"] == "ok" and "teil2" not in _RW["red"] and any("wieder in Ordnung" in s for s in said)
        alive.discard("teil3")
        _rw_tick(dict(deps, first_done=lambda: None))
        assert _RW["hb"]["teil3"]["state"] == "tot" and "teil3" in _RW["red"] and any("teil3 laeuft nicht mehr" in s for s in said)
        alive.add("teil3")
        G["_T3S"]["n"] += 1
        alive.add("freq_loop")
        _rw_tick(dict(deps, first_done=lambda: None))
        assert _RW["hb"]["teil3"]["state"] == "ok" and _RW["hb"]["freq"]["state"] == "ok"
        assert not sent and files == {} and probe["n"] == 0, "vor dem ersten Voll-Update nichts senden/speichern/pruefen"
        # 2) Zeit springt zurueck: nie falscher Alarm durch die Uhr (monotone Zeit, nur eigene Beobachtung)
        wall[0] -= 7200
        # 3) scharf: Pruefung ok -> kein Neustart; ausfallend < 180 s -> keiner; 180 s -> genau einer
        first["v"] = 1
        r = _rw_tick(deps)
        assert r == "ok" and _RW["probe_ok"] is not None and _RW["armed"] is True
        probe["ok"] = False
        r = _rw_tick(deps)
        assert r.startswith("antwortet nicht seit 0") and not sent
        clock[0] += 179
        T2["n"] += 1
        r = _rw_tick(deps)
        assert not sent and files == {}, "unter 180 s kein Neustart"
        clock[0] += 1
        r = _rw_tick(deps)
        assert r == "Neustart angefordert" and sent == ["STATUS=relWatch: Webserver antwortet nicht - kontrollierter Neustart", "WATCHDOG=trigger"], (r, sent)
        tf = files["/nonexistent-relwatch/dash_halt.json"]
        assert len(tf["triggers"]) == 1 and tf["triggers"][0]["t"] == int(wall[0]), tf
        clock[0] += 30
        r = _rw_tick(deps)
        assert len(sent) == 2 and len(files["/nonexistent-relwatch/dash_halt.json"]["triggers"]) == 1, "nur einmal je Prozess"
        # 4) Pruefung kam wieder: Zaehler der Ausfallzeit zurueck
        _RW["trig"] = False
        sent.clear()
        probe["ok"] = True
        _rw_tick(deps)
        assert _RW["fail_since"] is None
        probe["ok"] = False
        _rw_tick(deps)
        clock[0] += 100
        probe["ok"] = True
        _rw_tick(deps)
        probe["ok"] = False
        clock[0] += 100
        _rw_tick(deps)
        clock[0] += 100
        _rw_tick(deps)
        assert not sent, "Unterbrechungen duerfen die 180 s nicht aufaddieren"
        # 5) Keine Aktion: Pruefung nie gelungen / kein systemd / Schleifenbremse / Zaehler nicht speicherbar
        for label, tweak in (("nie", lambda: _RW.update(probe_ok=None)), ("sock", lambda: deps.update(sock=False)), ("brake", lambda: _RW.update(brake=True, brake_why="Test")), ("save", lambda: files.update(fail=True))):
            _RW.update(trig=False, fail_since=None, brake=False, probe_ok=1.0)
            deps["sock"] = True
            files.pop("fail", None)
            tweak()
            probe["ok"] = False
            _rw_tick(deps)
            clock[0] += 200
            r = _rw_tick(deps)
            assert not sent and r.startswith("keine Aktion"), (label, r, sent)
            clock[0] += 1000
        files.pop("fail", None)
        deps["sock"] = True
        # 6) Start: Zaehler, Schleifenbremse bei 4 Starts in der Stunde, kein Zaehler -> Bremse
        files.clear()
        for k in ("started", "brake"):
            _RW[k] = False
        _RW["brake_why"] = None
        assert _rw_start(dict(deps, no_thread=1)) is True
        assert _RW["starts_1h"] == 1 and _RW["brake"] is False and len(files["/nonexistent-relwatch/dash_halt.json"]["starts"]) == 1
        pth = "/nonexistent-relwatch/dash_halt.json"
        files[pth] = {"v": 1, "starts": [{"t": int(wall[0]) - 100}, {"t": int(wall[0]) - 200}, {"t": int(wall[0]) - 300}], "triggers": []}
        _RW.update(started=False, brake=False, brake_why=None)
        _rw_start(dict(deps, no_thread=1))
        assert _RW["starts_1h"] == 4 and _RW["brake"] is True, (_RW["starts_1h"], _RW["brake"])
        files[pth] = {"v": 1, "starts": [{"t": int(wall[0]) - 3601}, {"t": int(wall[0]) - 4000}, {"t": int(wall[0]) - 5000}], "triggers": []}
        _RW.update(started=False, brake=False, brake_why=None)
        _rw_start(dict(deps, no_thread=1))
        assert _RW["starts_1h"] == 1 and _RW["brake"] is False, "Starts aelter als eine Stunde zaehlen nicht"
        files[pth] = {"v": 1, "starts": [{"t": int(wall[0]) + 10 ** 6}], "triggers": []}
        _RW.update(started=False, brake=False, brake_why=None)
        _rw_start(dict(deps, no_thread=1))
        assert _RW["starts_1h"] == 2 and _RW["brake"] is False, "Eintrag aus der Zukunft (Uhr gesprungen) zaehlt als Start der letzten Stunde"
        files["fail"] = True
        _RW.update(started=False, brake=False, brake_why=None)
        _rw_start(dict(deps, no_thread=1))
        assert _RW["brake"] is True and "nicht speicherbar" in _RW["brake_why"], "ohne speicherbaren Zaehler keine Neustarts"
        files.pop("fail")
        # 7) Status wirft nie und hat die erwarteten Felder
        s = _rw_status(deps)
        assert set(s) >= {"threads", "red", "wd", "ticks", "thread", "err"} and s["wd"]["fail_limit_s"] == RW_FAIL_S and s["wd"]["brake"] is True, s
        return "relWatch ok (Faeden teil2/teil3/teil4/alarm/zyklus/wetter/freq: ok/stale/tot; Webserver-Pruefung erst nach dem ersten Voll-Update, Neustart nach %d s, nie in Schleife)" % RW_FAIL_S
    finally:
        for k, v in saved.items():
            _RW[k] = v


try:
    _RWG = {"selftest": _selftest_relwatch()}
    print("relWatch aktiv: %s" % _RWG["selftest"], flush=True)
except Exception as _rw_e:
    _RWG = {"selftest": "FEHLER %s" % _rw_e}
    print("relWatch Selbsttest FEHLER (Aufseher bleibt aus, systemd-Herzschlag laeuft weiter):", _rw_e, flush=True)
RW_RAB_EOF
EXPECT_RAG="40fd0990dc801a6ac1f616c325bc0d0446a9fb66edbad675c7bfe61d71e29f94"
cat > "$W/guard_rw.py" << 'RW_RAG_EOF'
"""AST-Guard relWatch (nur dashboard.py). Aufruf:
  guard_rw.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne relWatch (Rueckbau, byte-genau)
  guard_rw.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhalten in der Sandbox (Differenztest alt/neu der fuenf Pruefungen, Hook-Tests)
  RH_ALT=ALT_VERZ guard_rw.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest: jede absichtliche Verfehlung muss erkannt werden
Kein node, kein Netz, keine echten Dateien des Dashboards: alles in temporaeren Ordnern (benoetigt flask/werkzeug, auf dem Pi in der venv)."""
import ast
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import time

MARK = "# ===== relWatch:"
MAIN = '\n\nif __name__ == "__main__":\n'
ALLOWED_TOP = {"_sb_start_updates", "_sb_api_status", "_RWB", "RWB_TICK_S", "_rwb_notify", "_rwb_loop", "_RW", "_RW_SPEC", "_RWG", "#Import", "#If"}
ALLOWED_PREFIX = ("RW_", "_rw_", "_selftest_relwatch")


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block relWatch nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle relWatch nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def top_name(n):
    if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
        return n.name
    if isinstance(n, ast.Assign):
        return ",".join(t.id for t in n.targets if isinstance(t, ast.Name)) or "#assign"
    if isinstance(n, ast.Try):
        return "_RWG" if "_selftest_relwatch()" in ast.unparse(n) else "#try"
    if isinstance(n, (ast.Import, ast.ImportFrom)) and any((getattr(a, "asname", None) or "").startswith("_rw_") for a in n.names):
        return "#Import"
    if isinstance(n, ast.If):
        return "#If"
    return "#" + type(n).__name__


def top_ok(nm):
    return nm in ALLOWED_TOP or nm.startswith(ALLOWED_PREFIX)


def find_top(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def calls_named(node, name):
    return [c for c in ast.walk(node) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == name]


def consts(blk_tree):
    return {t.id: x.value.value for x in blk_tree.body if isinstance(x, ast.Assign) and isinstance(x.value, ast.Constant) for t in x.targets if isinstance(t, ast.Name)}


def early_text(src):
    i = src.index("# ===== relWatch (Start):")
    j = src.index("# ===== /relWatch (Start) =====", i)
    return src[i:j]


def static(alt, new, blk):
    n = 0
    ta, tn = ast.parse(alt), ast.parse(new)
    da = {ast.dump(x): top_name(x) for x in ta.body}
    dn = {ast.dump(x): top_name(x) for x in tn.body}
    changed = [dn[k] for k in dn if k not in da] + [da[k] for k in da if k not in dn]
    bad = sorted(set(c for c in changed if not top_ok(c)))
    assert not bad, "relWatch aendert ausserhalb der erlaubten Stellen: %s" % bad
    n += 1
    f = find_top(tn, "_sb_start_updates")
    assert ast.unparse(f.body[0]) == "_rw_start()" and isinstance(f.body[1], ast.Try), "_sb_start_updates: _rw_start() muss die erste Anweisung sein, danach unveraendert"
    assert "'rel': _rw_status()" in ast.unparse(find_top(tn, "_sb_api_status")), "/api/sysboot/status ohne rel"
    n += 1
    # frueher Herzschlag: nur WATCHDOG=1, nur unter systemd mit Watchdog, nur im Hauptprozess
    e = early_text(new)
    et = ast.parse(e.replace("# ===== relWatch (Start):", "#"))
    sent = [ast.unparse(c.args[0]) for c in ast.walk(et) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == "_rwb_notify"]
    assert sent == ["'WATCHDOG=1'"], "fruehe Herzschlag-Schleife darf nur WATCHDOG=1 senden: %s" % sent
    for must in ('os.environ.get("NOTIFY_SOCKET")', 'os.environ.get("WATCHDOG_USEC")', "WATCHDOG_PID", 'a[0] not in "/@"', "daemon=True", "relWatchBeat"):
        assert must in e, "fruehe Herzschlag-Schleife: %s fehlt" % must
    for forb in ("subprocess", "requests", "open(", "system(", "WATCHDOG=trigger", "STATUS="):
        assert forb not in e, "fruehe Herzschlag-Schleife enthaelt %s" % forb
    cs = consts(et)
    assert 5 <= cs["RWB_TICK_S"] <= 60, "RWB_TICK_S ausserhalb 5..60 s"
    assert ast.unparse(find_top(et, "_rwb_loop")).count("while not _RWB['stop']") == 1
    n += 1
    # Block
    bt = rd(blk)
    bn = ast.parse(bt)
    for forb in ("requests", "urlopen", "subprocess", "os.system", "Popen", "shutil", "socket", "send_meshtastic", "send_nina", "send_dab", "app.route", "add_url_rule", "telegram", "systemctl", "pkill", "kill("):
        assert forb not in bt, "Block enthaelt %s" % forb
    threads = [x for x in ast.walk(bn) if isinstance(x, ast.Call) and ast.unparse(x.func).endswith("Thread")]
    assert len(threads) == 1 and "_rw_start" in ast.unparse(find_top(bn, "_rw_start")) and any(x in ast.walk(find_top(bn, "_rw_start")) for x in threads), "genau ein Faden, in _rw_start"
    opens = {f.name for f in bn.body if isinstance(f, ast.FunctionDef) and calls_named(f, "open")}
    assert opens == {"_rw_load", "_rw_save"}, "open() nur in _rw_load/_rw_save: %s" % sorted(opens)
    wmsgs = sorted(set(x.value for x in ast.walk(bn) if isinstance(x, ast.Constant) and isinstance(x.value, str) and x.value.startswith("WATCHDOG=")))
    assert wmsgs == ["WATCHDOG=trigger"], "Block sendet nur WATCHDOG=trigger: %s" % wmsgs
    users = {f.name for f in bn.body if isinstance(f, ast.FunctionDef) and "_rwb_notify" in ast.unparse(f)}
    assert users == {"_rw_trigger"}, "_rwb_notify nur in _rw_trigger: %s" % sorted(users)
    callers = {f.name for f in bn.body if isinstance(f, ast.FunctionDef) and calls_named(f, "_rw_trigger")}
    assert callers == {"_rw_tick"} and len(calls_named(find_top(bn, "_rw_tick"), "_rw_trigger")) == 1, "_rw_trigger nur aus _rw_tick, einmal: %s" % sorted(callers)
    tk = ast.unparse(find_top(bn, "_rw_tick"))
    pos = [tk.find(x) for x in ("not first_done", "_rw_probe(d)", "RW_FAIL_S", "probe_ok'] is None", "not sock", "_RW['brake']", "_rw_trigger(")]
    assert all(p >= 0 for p in pos) and pos == sorted(pos), "_rw_tick: Reihenfolge erst-Voll-Update, Pruefung, Frist, Pruefung-nie-gelungen, kein-systemd, Bremse, Neustart: %s" % pos
    tr = ast.unparse(find_top(bn, "_rw_trigger"))
    assert tr.index("save(path, st)") < tr.index("nf('WATCHDOG=trigger')") and "return False" in tr, "_rw_trigger: erst speichern, dann Neustart"
    st = ast.unparse(find_top(bn, "_rw_start"))
    assert "RW_BRAKE_N" in st and "nicht speicherbar" in st and "_selftest" not in st and "_RWG" in st, "_rw_start: Bremse, Zaehler-Fehler, Selbsttest-Sperre"
    c = consts(bn)
    assert 120 <= c["RW_FAIL_S"] <= 900, "RW_FAIL_S ausserhalb 120..900 s (%s)" % c["RW_FAIL_S"]
    assert 2 <= c["RW_BRAKE_N"] <= 10 and c["RW_STALE_MIN_S"] >= 120 and 5 <= c["RW_TICK_S"] <= 60 and c["RW_STALE_X"] >= 2 and c["RW_PROBE_S"] <= 30, "Konstanten ausserhalb der Grenzen"
    assert c["RW_PROBE_PATH"] == "/api/time" and c["RW_FILE"] == "dash_halt.json"
    rl = ast.unparse(find_top(bn, "_rw_loop"))
    assert "except Exception" in rl and "sleep(RW_TICK_S)" in rl and "while True" in rl, "_rw_loop: Fehler fangen, Takt"
    n += 1
    return n


# ---------------- Verhalten ----------------
def exec_blk(blk, ns):
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(rd(blk), "rw_block", "exec"), ns)


def block_ns(blk):
    ns = {"__name__": "rw_sandbox", "__file__": "/nonexistent/dashboard.py", "os": os, "time": time, "threading": threading, "PORT": 5000}
    ns["_RWB"] = {"n": 0, "err": None, "t": None, "stop": False, "started": False}
    ns["_rwb_notify"] = lambda m: True
    exec_blk(blk, ns)
    return ns


_EARLY_DONE = {}


def early_tests(new):
    n = 0
    if early_text(new) in _EARLY_DONE:
        return _EARLY_DONE[early_text(new)]
    import socket
    tmp = tempfile.mkdtemp(prefix="rw-early-")
    env0 = {k: os.environ.get(k) for k in ("NOTIFY_SOCKET", "WATCHDOG_USEC", "WATCHDOG_PID")}
    try:
        sp = os.path.join(tmp, "notify.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        srv.bind(sp)
        srv.settimeout(0.5)
        txt = early_text(new)

        def run(env):
            old = {k: os.environ.get(k) for k in ("NOTIFY_SOCKET", "WATCHDOG_USEC", "WATCHDOG_PID")}
            for k in old:
                os.environ.pop(k, None)
            os.environ.update(env)
            ns = {"__name__": "early", "os": os, "threading": threading, "time": time}
            with contextlib.redirect_stdout(io.StringIO()):
                exec(compile(txt, "rw_early", "exec"), ns)
                time.sleep(0.05)
            return ns

        def drain(sec):
            got = []
            t0 = time.time()
            while time.time() - t0 < sec:
                try:
                    got.append(srv.recv(256).decode())
                except socket.timeout:
                    pass
            return got
        ns = run({"NOTIFY_SOCKET": sp, "WATCHDOG_USEC": "4000000"})
        got = drain(3.2)
        ns["_RWB"]["stop"] = True
        assert ns["_RWB"]["started"] and len(got) >= 2 and set(got) == {"WATCHDOG=1"}, "fruehe Schleife: mindestens 2 x WATCHDOG=1 und sonst nichts erwartet: %s" % got
        assert ns["_RWB"]["n"] >= 2 and ns["_RWB"]["t"] is not None
        n += 1
        time.sleep(1.2)
        drain(0.3)
        for env, label in (({}, "ohne systemd"), ({"NOTIFY_SOCKET": sp}, "ohne WATCHDOG_USEC"), ({"NOTIFY_SOCKET": sp, "WATCHDOG_USEC": "4000000", "WATCHDOG_PID": str(os.getpid() + 1)}, "fremde WATCHDOG_PID")):
            ns = run(env)
            got = drain(1.3)
            assert not ns["_RWB"]["started"] and not got, "fruehe Schleife darf %s nicht starten/senden: %s" % (label, got)
        n += 1
        ns = run({"NOTIFY_SOCKET": os.path.join(tmp, "gibtsnicht.sock"), "WATCHDOG_USEC": "4000000", "WATCHDOG_PID": str(os.getpid())})
        time.sleep(1.5)
        ns["_RWB"]["stop"] = True
        assert ns["_RWB"]["n"] == 0 and ns["_RWB"]["err"], "ohne Empfaenger: kein Absturz, Fehler vermerkt"
        n += 1
        srv.close()
        _EARLY_DONE[early_text(new)] = n
    finally:
        for k, v in env0.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(tmp, ignore_errors=True)
    return n


def file_tests(blk):
    n = 0
    ns = block_ns(blk)
    tmp = tempfile.mkdtemp(prefix="rw-file-")
    try:
        p = os.path.join(tmp, "dash_halt.json")
        assert ns["_rw_load"](p) == {"v": 1, "starts": [], "triggers": []}
        d = {"v": 1, "starts": [{"t": 1000}, {"t": 2000}], "triggers": [{"t": 1500, "why": "x"}]}
        ns["_rw_save"](p, d)
        assert ns["_rw_load"](p) == d and not os.path.exists(p + ".tmp"), "Speichern: Rundlauf ohne Rest-Datei"
        with open(p, "w") as f:
            f.write("{kaputt")
        assert ns["_rw_load"](p) == {"v": 1, "starts": [], "triggers": []}, "kaputte Datei -> leer"
        with open(p, "w") as f:
            json.dump({"starts": [{"t": "x"}, {"t": True}, 5, {"t": 77}], "triggers": "nein"}, f)
        assert ns["_rw_load"](p) == {"v": 1, "starts": [{"t": 77}], "triggers": []}, "ungueltige Eintraege werden verworfen"
        big = {"v": 1, "starts": [{"t": 100000 - i} for i in range(100)] + [{"t": 1}], "triggers": []}
        pr = ns["_rw_prune"](big, 100000)
        assert len(pr["starts"]) == 40 and all(100000 - x["t"] <= 86400 for x in pr["starts"]), "Pruefen: hoechstens 40, nicht aelter als 24 h"
        assert ns["_rw_count_1h"]([{"t": 1000}, {"t": 4600}, {"t": 5000}, {"t": 99999}], 5000) == 3, "Stunde: 1000 s alt, 400 s alt, jetzt, Zukunft"
        os.chmod(tmp, 0o500)
        if os.geteuid() != 0:
            try:
                ns["_rw_save"](p, d)
                raise AssertionError("Speichern in schreibgeschuetzten Ordner muss Fehler melden")
            except OSError:
                pass
        os.chmod(tmp, 0o700)
        assert ns["_rw_path"]({"base": tmp}) == p and ns["_rw_path"]().endswith("/nonexistent/dash_halt.json")
        n += 1
    finally:
        os.chmod(tmp, 0o700)
        shutil.rmtree(tmp, ignore_errors=True)
    return n


def probe_tests(blk):
    import http.server
    import socket
    n = 0
    ns = block_ns(blk)
    ns["RW_PROBE_S"] = 1.0

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"ms": 1}')

        def log_message(self, *a):
            pass
    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    port = srv.server_address[1]
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    try:
        assert ns["_rw_probe"]({"port": port}) is True, "Pruefung gegen laufenden Server"
    finally:
        srv.shutdown()
        srv.server_close()
    assert ns["_rw_probe"]({"port": port}) is False, "Pruefung gegen geschlossenen Port"
    n += 1
    # haengender Server: nimmt an, antwortet nie
    ls = socket.socket()
    ls.bind(("127.0.0.1", 0))
    ls.listen(5)
    t0 = time.time()
    r = ns["_rw_probe"]({"port": ls.getsockname()[1]})
    dt = time.time() - t0
    ls.close()
    assert r is False and dt < 4, "haengender Server: False nach dem Zeitlimit (%.1f s)" % dt
    n += 1
    return n


def loop_tests(blk):
    n = 0
    ns = block_ns(blk)

    class Stop(BaseException):
        pass
    cnt = {"n": 0}

    def boom(*a, **k):
        cnt["n"] += 1
        raise RuntimeError("kaputt")

    class FT:
        calls = 0

        @staticmethod
        def sleep(x):
            FT.calls += 1
            assert x == ns["RW_TICK_S"], "Takt"
            if FT.calls >= 4:
                raise Stop()
        monotonic = staticmethod(time.monotonic)
        time = staticmethod(time.time)
    ns["_rw_time"] = FT
    ns["_rw_tick"] = boom
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            ns["_rw_loop"]()
    except Stop:
        pass
    assert cnt["n"] == 4 and ns["_RW"]["err"] == "kaputt", "ein Fehler im Takt darf den Aufseher nicht beenden (%s)" % cnt
    n += 1
    # Selbsttest FEHLER -> kein Start, kein Faden
    ns = block_ns(blk)
    ns["_RWG"] = {"selftest": "FEHLER x"}
    assert ns["_rw_start"]({"no_thread": 1, "base": "/nonexistent", "load": lambda p: {"v": 1, "starts": [], "triggers": []}, "save": lambda p, d: None}) is False and not ns["_RW"]["started"]
    n += 1
    # zweiter Start im selben Prozess: nichts
    ns = block_ns(blk)
    dd = {"no_thread": 1, "base": "/nonexistent", "load": lambda p: {"v": 1, "starts": [], "triggers": []}, "save": lambda p, d: None, "say": lambda *a: None}
    assert ns["_rw_start"](dd) is True and ns["_rw_start"](dd) is False, "zweiter Start im selben Prozess muss nichts tun"
    n += 1
    return n


def trigger_e2e(new, blk):
    """Echter Weg ohne Attrappe: fruehes Modul + Block im selben Namensraum, echter Unix-Datagram-Socket: _rw_trigger speichert zuerst den Zaehler und sendet dann STATUS und WATCHDOG=trigger."""
    import socket
    tmp = tempfile.mkdtemp(prefix="rw-e2e-")
    env0 = {k: os.environ.get(k) for k in ("NOTIFY_SOCKET", "WATCHDOG_USEC", "WATCHDOG_PID")}
    try:
        sp = os.path.join(tmp, "n.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        srv.bind(sp)
        srv.settimeout(1.0)
        for k in env0:
            os.environ.pop(k, None)
        os.environ["NOTIFY_SOCKET"] = sp
        ns = {"__name__": "e2e", "__file__": "/nonexistent/dashboard.py", "os": os, "time": time, "threading": threading, "PORT": 5000}
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(early_text(new), "rw_early", "exec"), ns)
        assert not ns["_RWB"]["started"], "ohne WATCHDOG_USEC darf der fruehe Faden nicht laufen"
        exec_blk(blk, ns)
        r = ns["_rw_trigger"]("Test", {"base": tmp, "say": lambda *a: None, "now": lambda: 5_000_000.0})
        got = [srv.recv(256).decode(), srv.recv(256).decode()]
        assert r is True and got[0].startswith("STATUS=relWatch") and got[1] == "WATCHDOG=trigger", "echter Weg: erst STATUS, dann WATCHDOG=trigger: %s %s" % (r, got)
        st = ns["_rw_load"](ns["_rw_path"]({"base": tmp}))
        assert len(st["triggers"]) == 1 and st["triggers"][0]["t"] == 5_000_000, "Zaehler vor dem Neustart gespeichert: %s" % st
        srv.close()
        return 1
    finally:
        for k, v in env0.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(tmp, ignore_errors=True)


def sim_tests(blk):
    """Echte Zaehler-Datei, virtuelle Zeit: lange erste Aktualisierung (nie Neustart), haengender Webserver (Neustarts hoechstens 3 je Stunde), Erholung nach einer Stunde."""
    n = 0
    tmp = tempfile.mkdtemp(prefix="rw-sim-")
    try:
        # A) erstes Voll-Update dauert 40 min, Webserver antwortet nicht: kein einziger Neustart
        ns = block_ns(blk)
        clock, wall, sent = [0.0], [2_000_000.0], []
        first = {"v": None}
        base = dict(mono=lambda: clock[0], now=lambda: wall[0], alive=lambda: {"teil2"}, g={"_T2D": {"n": 0}, "T2D_TICK_S": 20, "data_store": {}}, probe=lambda: False,
                    first_done=lambda: first["v"], sock=True, base=tmp, notify=lambda m: sent.append(m), say=lambda *a: None)
        ns["_rw_start"](dict(base, no_thread=1))
        for _ in range(160):
            clock[0] += 15
            ns["_rw_tick"](base)
        assert not sent and ns["_RW"]["fail_since"] is None, "waehrend des ersten Voll-Updates nie ein Neustart (40 min)"
        n += 1
        # B) Schleife: Webserver nach dem Start kurz ok, dann tot - 8 Starts in der Stunde: hoechstens 3 Neustarts
        trig = 0
        for k in range(8):
            ns = block_ns(blk)
            sent = []
            ok = {"v": True}
            clock, first = [0.0], {"v": 1}
            wall = [3_000_000.0 + k * 300]
            b = dict(mono=lambda: clock[0], now=lambda: wall[0], alive=lambda: set(), g={"data_store": {}}, probe=lambda: ok["v"], first_done=lambda: first["v"], sock=True, base=tmp, notify=lambda m: sent.append(m), say=lambda *a: None)
            ns["_rw_start"](dict(b, no_thread=1))
            ns["_rw_tick"](b)
            ok["v"] = False
            for _ in range(20):
                clock[0] += 15
                ns["_rw_tick"](b)
            if "WATCHDOG=trigger" in sent:
                trig += 1
        d = ns["_rw_load"](os.path.join(tmp, "dash_halt.json"))
        assert trig == 3 and len(d["triggers"]) == 3 and len(d["starts"]) == 8, "Schleife: genau 3 Neustarts in einer Stunde, dann Bremse (%d, %s)" % (trig, {k: len(v) for k, v in d.items() if isinstance(v, list)})
        n += 1
        # C) eine Stunde spaeter wieder erlaubt
        ns = block_ns(blk)
        sent = []
        ok = {"v": True}
        clock, first = [0.0], {"v": 1}
        wall = [3_000_000.0 + 7200]
        b = dict(mono=lambda: clock[0], now=lambda: wall[0], alive=lambda: set(), g={"data_store": {}}, probe=lambda: ok["v"], first_done=lambda: first["v"], sock=True, base=tmp, notify=lambda m: sent.append(m), say=lambda *a: None)
        ns["_rw_start"](dict(b, no_thread=1))
        assert ns["_RW"]["brake"] is False, "nach einer Stunde ohne Starts keine Bremse mehr"
        ns["_rw_tick"](b)
        ok["v"] = False
        for _ in range(20):
            clock[0] += 15
            ns["_rw_tick"](b)
        assert "WATCHDOG=trigger" in sent, "nach der Pause ist ein Neustart wieder moeglich"
        n += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return n


def behav(alt, new, blk):
    n = 0
    ns = {"__name__": "rw_sandbox", "__file__": "/nonexistent/dashboard.py", "os": os, "time": time, "threading": threading, "PORT": 5000}
    ns["_RWB"] = {"n": 0, "err": None, "t": None, "stop": False, "started": False}
    ns["_rwb_notify"] = lambda m: True
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(rd(blk), "rw_block", "exec"), ns)
    assert "relWatch aktiv: relWatch ok" in out.getvalue(), "Block-Selbsttest meldet nicht ok: %s" % out.getvalue()[:300]
    n += 1
    n += early_tests(new)
    n += file_tests(blk)
    n += probe_tests(blk)
    n += loop_tests(blk)
    n += sim_tests(blk)
    n += trigger_e2e(new, blk)
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_RW_NOSTATIC") == "1" else static(alt, new, blk)
    if os.environ.get("RH_RW_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau von Block und Stellen ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    assert rd(blk).rstrip("\n") in new
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk)
    print("OK guard relWatch: %d Pruefungen, 0 fehlerhaft" % n)
    return n

# (Name, Zielzeichenfolge, Ersatz, norev)
MUT = [
    ("E1 Herzschlag sendet trigger", '_rwb_notify("WATCHDOG=1")', '_rwb_notify("WATCHDOG=trigger")', 1),
    ("E2 Herzschlag ohne WATCHDOG_PID-Pruefung", ' and os.environ.get("WATCHDOG_PID", str(os.getpid())) == str(os.getpid())', "", 1),
    ("E3 Herzschlag ohne Adress-Pruefung", 'if not a or a[0] not in "/@":', "if not a:", 1),
    ("E4 Herzschlag zu selten", "        time.sleep(tick)\n", "        time.sleep(600)\n", 1),
    ("E5 Herzschlag ohne Stopp", 'while not _RWB["stop"]:', "while True:", 1),
    ("E6 Herzschlag-Faden nicht Daemon", 'name="relWatchBeat", daemon=True', 'name="relWatchBeat"', 1),
    ("E7 Herzschlag auch ohne systemd", 'if os.environ.get("NOTIFY_SOCKET") and os.environ.get("WATCHDOG_USEC") and', "if True and", 1),
    ("E8 Herzschlag-Takt 120 s", "RWB_TICK_S = 15", "RWB_TICK_S = 120", 1),
    ("E9 Herzschlag zaehlt nicht", '                _RWB["n"] += 1\n', "                pass\n", 1),
    ("B1 Frist 20 s", "RW_FAIL_S = 180 ", "RW_FAIL_S = 20 ", 1),
    ("B2 Frist 5000 s", "RW_FAIL_S = 180 ", "RW_FAIL_S = 5000 ", 1),
    ("B3 Pruefung auch vor dem ersten Voll-Update", '    if not first_done:\n        _RW["fail_since"] = None          # vor dem ersten Voll-Update nie eine Pruefung, nie ein Neustart\n        return "nicht scharf (erstes Voll-Update laeuft)"\n', "", 1),
    ("B4 Frist ignoriert", 'if fs < RW_FAIL_S or _RW["trig"]:', 'if fs < 1 or _RW["trig"]:', 1),
    ("B5 Neustart mehrfach je Prozess", 'if fs < RW_FAIL_S or _RW["trig"]:', "if fs < RW_FAIL_S:", 1),
    ("B6 Pruefung-nie-gelungen ignoriert", 'if _RW["probe_ok"] is None:', "if False:", 1),
    ("B7 Schleifenbremse ignoriert", 'if _RW["brake"]:', "if False:", 1),
    ("B8 kein systemd ignoriert", "    if not sock:\n", "    if False:\n", 1),
    ("B9 Neustart ohne Zaehler-Eintrag", "        save(path, st)\n    except Exception as e:\n        _rw_logrl(\"trig_save\"", "        pass\n    except Exception as e:\n        _rw_logrl(\"trig_save\"", 1),
    ("B10 ohne STATUS-Zeile", '    nf("STATUS=relWatch: Webserver antwortet nicht - kontrollierter Neustart")\n', "", 1),
    ("B11 Zaehler-Fehler ohne Wirkung", '        return False\n    _RW["trig"] = True', '        pass\n    _RW["trig"] = True', 1),
    ("B12 Bremse erst ab 5 Starts", "if n1h >= RW_BRAKE_N:", "if n1h > RW_BRAKE_N:", 1),
    ("B13 Zaehler-Fehler ohne Bremse", '            _RW["brake"], _RW["brake_why"] = True, "Start-Zaehler nicht speicherbar (%s)" % str(e)[:60]\n', "            pass\n", 1),
    ("B14 Zukunfts-Eintraege zaehlen nicht", 'sum(1 for x in entries if (now - x["t"]) <= 3600)', 'sum(1 for x in entries if 0 <= (now - x["t"]) <= 3600)', 1),
    ("B15 Aufbewahrung 10 s", "RW_KEEP_S = 86400", "RW_KEEP_S = 10", 1),
    ("B16 nur 4 Eintraege behalten", "[-40:]", "[-4:]", 1),
    ("B17 Haengend-Grenze x100", 'mono - e["t"] > limit', 'mono - e["t"] > limit * 100', 1),
    ("B18 Zaehler-Aenderung ohne Wirkung", '(cnt is not None and cnt != e["n"])', "(cnt is not None and False)", 1),
    ("B19 tot nicht erkannt", 'elif not up:\n            new = "tot"', 'elif False:\n            new = "tot"', 1),
    ("B41 erste Sichtung meldet auch", '        if old != "unbekannt":\n            _rw_say(deps, "relWatch: Faden %s wieder', '        if True:\n            _rw_say(deps, "relWatch: Faden %s wieder', 1),
    ("B20 nie gesehen gilt als tot", 'if not e["seen"]:\n            new = "unbekannt"', 'if not e["seen"]:\n            new = "tot"', 1),
    ("B21 Mindestgrenze fehlt", "limit = max(RW_STALE_MIN_S, RW_STALE_X * float(getiv(g)))", "limit = RW_STALE_X * float(getiv(g))", 1),
    ("B22 Alarm-Faden-Grenze falsch", 'lambda g: g["ALARM_MAX_S"]', 'lambda g: g["ALARM_POLL_S"]', 1),
    ("B23 Pruefung immer False", "        r.read(64)\n        return True", "        r.read(64)\n        return False", 1),
    ("B24 Pruefung ohne Zeitlimit", "timeout=RW_PROBE_S)", "timeout=6)", 1),
    ("B25 zweiter Start moeglich", '        _RW["started"] = True\n        now =', "        now =", 1),
    ("B26 Fehler im Takt beendet Aufseher", "        except Exception as e:\n            _RW[\"err\"] = str(e)[:120]\n            _rw_logrl(\"loop\"", "        except ZeroDivisionError as e:\n            _RW[\"err\"] = str(e)[:120]\n            _rw_logrl(\"loop\"", 1),
    ("B27 Block hat subprocess", "import os as _rw_os\n", "import os as _rw_os\nimport subprocess\n", 1),
    ("B28 Pruefpfad /", 'RW_PROBE_PATH = "/api/time"', 'RW_PROBE_PATH = "/"', 1),
    ("B29 Mindestgrenze 10 s", "RW_STALE_MIN_S = 300 ", "RW_STALE_MIN_S = 10 ", 1),
    ("B30 Bremse erst ab 40 Starts", "RW_BRAKE_N = 4 ", "RW_BRAKE_N = 40 ", 1),
    ("B31 Starts zaehlen 10 h", "<= 3600)", "<= 36000)", 1),
    ("B32 Frist <= statt <", "if fs < RW_FAIL_S or", "if fs <= RW_FAIL_S or", 1),
    ("B33 Ausfallzeit wird nie zurueckgesetzt", '        _RW["probe_ok"] = mono\n        _RW["fail_since"] = None\n', '        _RW["probe_ok"] = mono\n', 1),
    ("B34 trig-Merker fehlt", '    _RW["trig"] = True\n    _rw_say', "    _rw_say", 1),
    ("B35 _rw_start nicht in _sb_start_updates", "    _rw_start()  # relWatch\n", "", 0),
    ("B36 sysboot ohne rel", ', "rel": _rw_status()})', "})", 0),
    ("B37 stille Zusatzaenderung: Server-Start", "use_reloader=False, threaded=True)  # sysBoot", "use_reloader=True, threaded=True)  # sysBoot", 0),
    ("B38 stille Zusatzaenderung: Lage", 'return "NORMAL", "#22c55e", "Keine akuten Gefahrenlagen erfasst."', 'return "NORMAL", "#22c55e", "Keine Gefahrenlagen."', 0),
    ("B39 stille Zusatzaenderung: sysboot threaded", '"threaded": True,', '"threaded": False,', 0),
    ("B40 Faden-Liste ohne alarm_loop-Name", '"alarm": ("alarm_loop",', '"alarm": ("alarm_loopX",', 1),
]


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    bad = []
    done = 0
    for name, a, b, norev in MUT:
        w = tempfile.mkdtemp(prefix="rw-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            assert base_new.count(a) >= 1, "%s: Stelle nicht gefunden" % name
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new.replace(a, b))
            if norev:
                os.environ["RH_RW_NOREV"] = "1"
            else:
                os.environ.pop("RH_RW_NOREV", None)
            bf = os.path.join(w, "blk.py")
            bt = rd(blk)
            if a in bt:
                bt = bt.replace(a, b)
            with open(bf, "w", encoding="utf-8") as f:
                f.write(bt)
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    check(altdir, nd, bf, ep)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            os.environ.pop("RH_RW_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation relWatch: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a[0] == "revert":
            revert(*a[1:5])
        elif a[0] == "check":
            check(*a[1:5])
        elif a[0] == "mutate":
            sys.exit(mutate(*a[1:4]))
        else:
            print(__doc__)
            sys.exit(2)
    except AssertionError as e:
        print("guard relWatch FEHLER: %s" % e)
        sys.exit(1)
RW_RAG_EOF
PPK="$W/patch-rw.py"; RED="$W/edits_rw.py"; RBK="$W/blk_rw.py"; RGD="$W/guard_rw.py"
for x in "$EXPECT_PAL $PPK" "$EXPECT_RAE $RED" "$EXPECT_RAB $RBK" "$EXPECT_RAG $RGD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (patch-rw.py, edits_rw.py, blk_rw.py, guard_rw.py)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Basis nach alarmFaden commit29" "$KNOWN_D16N" "relWatch schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      relWatch passt nur auf den Stand nach alarmFaden commit29 (dashboard.py 565137da31dc675d). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
grep -q '# ===== relHygiene:' "$F" || stop "relHygiene (commit19b) fehlt im Dashboard (Basis)"
grep -q '# ===== perfKeep:' "$F" || stop "perfKeep (commit27) fehlt im Dashboard (Basis)"
grep -q '# ===== sameOrigin:' "$F" || stop "sameOrigin (commit28) fehlt im Dashboard (Basis)"
grep -q '# ===== alarmFaden:' "$F" || stop "alarmFaden (commit29) fehlt im Dashboard (Basis)"
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
# andere Programmdateien: nur Vorher/Nachher-Vergleich
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 1b) systemd-Unit (nur Lesen) ----------
systemctl cat "$UNITN" > "$W/unit.txt" 2> "$W/unit.err" || { cat "$W/unit.err"; stop "systemctl cat $UNITN scheitert"; }
grep -qE '^ExecStart=.*dashboard\.py' "$W/unit.txt" || { cat "$W/unit.txt"; stop "Unit $UNITN startet dashboard.py nicht (ExecStart)"; }
UTYPE=$(systemctl show -p Type --value "$UNITN" 2>/dev/null || true)
[[ "$UTYPE" == simple || "$UTYPE" == exec || -z "$UTYPE" ]] || stop "Unit $UNITN hat Type=$UTYPE (erwartet simple oder exec)"
WD0=$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || echo "?")
if [[ ! -f "$DROPF" ]] && [[ "$WD0" != 0 && "$WD0" != "?" && "$WD0" != "infinity" && -n "$WD0" ]]; then stop "Unit $UNITN hat schon WatchdogSec ($WD0) aus anderer Quelle"; fi
REST0=$(systemctl show -p Restart --value "$UNITN" 2>/dev/null || echo "?")
ADD_R=0
case "$REST0" in always|on-failure|on-abnormal|on-watchdog) ;; *) ADD_R=1;; esac
[[ -f "$DROPF" ]] && grep -q '^Restart=' "$DROPF" && ADD_R=1
{
  echo "# relWatch: Drop-in fuer prepper-dashboard (die Haupt-Unit bleibt unveraendert). Rueckweg: diese Datei loeschen (oder die .bak-relwatch-Sicherung zurueckkopieren), sudo systemctl daemon-reload, sudo systemctl restart prepper-dashboard"
  echo "[Service]"
  echo "WatchdogSec=$WDS"
  echo "NotifyAccess=main"
  if [[ "$ADD_R" == 1 ]]; then echo "Restart=on-failure"; echo "RestartSec=5"; fi
} > "$W/zz-relwatch.conf"
echo "OK Unit $UNITN: $(grep -m1 '^ExecStart=' "$W/unit.txt" | cut -c1-160) | vorher Type=${UTYPE:-?}, Restart=$REST0, WatchdogSec=$WD0, NotifyAccess=$(systemctl show -p NotifyAccess --value "$UNITN" 2>/dev/null || echo ?)"
if [[ "$ADD_R" == 1 ]]; then echo "  Hinweis: die Unit startet bei Watchdog-Ausfall nicht neu (Restart=$REST0) - das Drop-in setzt deshalb zusaetzlich Restart=on-failure, RestartSec=5"; else echo "  Die Unit startet bei Watchdog-Ausfall schon neu (Restart=$REST0) - das Drop-in setzt nur WatchdogSec=$WDS und NotifyAccess=main"; fi
[[ -f "$DROPF" ]] && cmp -s "$DROPF" "$W/zz-relwatch.conf" && echo "OK Drop-in $DROPF schon vorhanden (gleicher Inhalt)" || echo "Drop-in $DROPF wird neu angelegt (nur diese Datei, Haupt-Unit bleibt), Inhalt:"
[[ -f "$DROPF" ]] && cmp -s "$DROPF" "$W/zz-relwatch.conf" || sed 's/^/   | /' "$W/zz-relwatch.conf"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" relWatch dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer relWatch nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" relWatch dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
# AST-Guard: Rueckbau ergibt die bekannte Basis; dann Regeln, Verhalten (Differenztest alt/neu) und Mutationstest. Kein node noetig.
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: relWatch im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne relWatch ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard relWatch meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" nice -n 10 "$VPY" "$RGD" mutate "$W/neu" "$RBK" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^aequivalent|^OK" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-?}"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
pcode() { code -X POST "$@"; }
"${CURL[@]}" "$B/api/sysboot/status" -o "$W/sb0.json" || true
echo "Zustand vorher (nur Lesen): /api/sysboot/status enthaelt rel: $(grep -c -F '"rel"' "$W/sb0.json" || true) (0 = noch nicht installiert)"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
DROP_OK=0
if [[ -f "$DROPF" ]] && cmp -s "$DROPF" "$W/zz-relwatch.conf" && [[ "$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || true)" == 5min ]] && [[ "$(systemctl show -p NotifyAccess --value "$UNITN" 2>/dev/null || true)" == main ]]; then DROP_OK=1; fi
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 && "$DROP_OK" == 1 ]]; then echo "  Zustand: relWatch ist schon installiert (dashboard.py und Drop-in, vom Dienst geladen) - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: $([[ "$NEED_D" == 1 ]] && echo "dashboard.py ersetzen (Sicherung dashboard.py.bak-relwatch-ZEIT, letzte $KEEP_LAST), ")$([[ "$DROP_OK" == 0 ]] && echo "das Drop-in $DROPF anlegen (mit sudo; alte Datei wird gesichert), daemon-reload, ")Neustart nur prepper-dashboard, danach $HOLD_S s beobachten (bei Neustart durch systemd: Rollback), eine sudo-Passwortabfrage."; fi
  echo "COMMIT $COMMIT_ARG relwatch=dry fertig"
  exit 0
fi
if [[ "$NEED_D" == 1 || "$DROP_OK" == 0 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer Drop-in, Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
DROP_NEW=0
T0D=$(date +%s)
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "relWatch|Traceback" | tail -6 | cut -c1-240
  if [[ "$DROP_NEW" == 1 ]]; then   # zuerst das Drop-in zurueck (sonst wuerde der Dienst ohne Herzschlag vom Watchdog beendet)
    if [[ -f "$DROPF.bak-relwatch-$TS" ]]; then sudo cp -a "$DROPF.bak-relwatch-$TS" "$DROPF"; else sudo rm -f "$DROPF"; fi
    sudo systemctl daemon-reload
    echo "  Drop-in zurueck: $([[ -f "$DROPF" ]] && echo "alter Stand wiederhergestellt" || echo "entfernt")"
  fi
  [[ -f "$F.bak-relwatch-$TS" ]] && cp -a "$F.bak-relwatch-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 || "$DROP_NEW" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-relwatch-$TS" ]] && { cmp -s "$F" "$F.bak-relwatch-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), WatchdogSec=$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 || "$DROP_NEW" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 && "$DROP_OK" == 1 ]]; then
  echo "OK relWatch schon installiert (dashboard.py und Drop-in, vom Dienst geladen) - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  if [[ "$NEED_D" == 1 ]]; then
    cp -a "$F" "$F.bak-relwatch-$TS"
    { ls -1t "$F.bak-relwatch-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
    cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-relwatch-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
    [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
    echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-relwatch-$TS, behalten: letzte $KEEP_LAST)"
  fi
  if [[ "$DROP_OK" == 0 ]]; then
    if [[ -f "$DROPF" ]]; then
      sudo cp -a "$DROPF" "$DROPF.bak-relwatch-$TS"
      { ls -1t "$DROPF.bak-relwatch-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do sudo rm -f -- "$o"; done
    fi
    DROP_NEW=1
    sudo mkdir -p "$DROPDIR" && sudo install -m 0644 "$W/zz-relwatch.conf" "$DROPF" || { rb "Drop-in anlegen"; exit 1; }
    sudo systemctl daemon-reload || { rb "daemon-reload"; exit 1; }
    [[ "$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || true)" == 5min && "$(systemctl show -p NotifyAccess --value "$UNITN" 2>/dev/null || true)" == main ]] || { rb "Drop-in von systemd nicht geladen (WatchdogUSec=$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || true), NotifyAccess=$(systemctl show -p NotifyAccess --value "$UNITN" 2>/dev/null || true))"; exit 1; }
    echo "OK Drop-in $DROPF angelegt, daemon-reload ok, systemd zeigt WatchdogUSec=5min und NotifyAccess=main (wirksam erst mit dem Neustart)"
    [[ -f "$DROPF.bak-relwatch-$TS" ]] && echo "   (alte Drop-in-Datei gesichert: $DROPF.bak-relwatch-$TS)"
  fi
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeilen 'relWatch aktiv' und 'Herzschlag' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; relWatch aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
# Funktionspruefung: Status-Schnittstelle (nur Lesen)
relq() { "${CURL[@]}" "$B/api/sysboot/status" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get("rel")
    if not isinstance(r, dict) or "wd" not in r:
        print("KEIN-REL"); sys.exit(0)
    w = r["wd"]; t = r.get("threads") or {}
    print("OK thread=%s sock=%s beats=%s beat_age_s=%s armed=%s probe_age_s=%s fail_s=%s brake=%s starts_1h=%s trigger=%s ticks=%s err=%s first_update_s=%s faeden=%s" % (r.get("thread"), w.get("sock"), w.get("beats"), w.get("beat_age_s"), w.get("armed"), w.get("probe_age_s"), w.get("fail_s"), w.get("brake"), w.get("starts_1h"), w.get("trigger_sent"), r.get("ticks"), r.get("err"), d.get("first_update_s"), ",".join("%s:%s" % (k, v.get("state")) for k, v in sorted(t.items()))))
except Exception as e:
    print("FEHLER %s" % str(e)[:80])
' || echo "FEHLER python"; }
RQ=$(relq)
[[ "$RQ" == OK* ]] || { sleep 10; RQ=$(relq); }
[[ "$RQ" == OK* ]] || rbx "/api/sysboot/status enthaelt keinen Abschnitt rel ($RQ)"
echo "$RQ" | grep -q 'thread=True' || rbx "relWatch-Aufseher laeuft nicht (thread=False) - Selbsttest fehlgeschlagen? ($RQ)"
echo "OK /api/sysboot/status zeigt rel: $RQ"
# systemd-Herzschlag muss ankommen: sock=True und mindestens ein gesendeter Herzschlag (nur wenn systemd wirklich neu gestartet hat)
if [[ "$RESTARTED_D" == 1 ]]; then
  echo "$RQ" | grep -q 'sock=True' || rbx "Dienst laeuft ohne NOTIFY_SOCKET/WATCHDOG_USEC - Drop-in vom Dienst nicht uebernommen ($RQ)"
  hb=0; for i in 1 2 3 4 5 6; do RQ=$(relq); echo "$RQ" | grep -qE 'beats=[1-9]' && { hb=1; break; }; sleep 5; done
  [[ "$hb" == 1 ]] || rbx "kein einziger systemd-Herzschlag gesendet (beats=0) - Notify-Socket nicht erreichbar? ($RQ)"
  echo "OK systemd-Herzschlag laeuft: $(echo "$RQ" | grep -oE 'beats=[0-9]+ beat_age_s=[0-9A-Za-z]+')"
fi
[[ "$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || true)" == 5min ]] || rbx "systemd zeigt WatchdogUSec nicht 5min ($(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || true))"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/rw-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E relWatch"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "relWatch aktiv: relWatch ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'relWatch aktiv: relWatch ok' ($(echo "$JD" | grep -F relWatch | tail -1 | cut -c1-200))"
    JH=$(echo "$JD" | grep -F "relWatch: systemd-Herzschlag laeuft" | tail -1 || true)
    [[ -n "$JH" ]] && echo "OK Journal: $(echo "$JH" | cut -c1-200)" || rbx "Journal ohne 'relWatch: systemd-Herzschlag laeuft'"
    JG=$(echo "$JD" | grep -F "relWatch: Aufseher gestartet" | tail -1 || true)
    [[ -n "$JG" ]] && echo "OK Journal: $(echo "$JG" | cut -c1-240)" || rbx "Journal ohne 'relWatch: Aufseher gestartet'"
    JR=$(echo "$JD" | grep -F "relHygiene aktiv: relHygiene ok" | tail -1 || true)
    [[ -n "$JR" ]] && echo "OK relHygiene weiter aktiv: $(echo "$JR" | cut -c1-120)" || rbx "Journal ohne 'relHygiene aktiv: relHygiene ok' (Regression)"
    JP=$(echo "$JD" | grep -F "perfKeep aktiv: perfKeep ok" | tail -1 || true)
    [[ -n "$JP" ]] && echo "OK perfKeep weiter aktiv: $(echo "$JP" | cut -c1-120)" || rbx "Journal ohne 'perfKeep aktiv: perfKeep ok' (Regression)"
    JS=$(echo "$JD" | grep -F "sameOrigin aktiv: sameOrigin ok" | tail -1 || true)
    [[ -n "$JS" ]] && echo "OK sameOrigin weiter aktiv: $(echo "$JS" | cut -c1-120)" || rbx "Journal ohne 'sameOrigin aktiv: sameOrigin ok' (Regression)"
    JL=$(echo "$JD" | grep -F "alarmFaden aktiv: alarmFaden ok" | tail -1 || true)
    [[ -n "$JL" ]] && echo "OK alarmFaden weiter aktiv: $(echo "$JL" | cut -c1-120)" || rbx "Journal ohne 'alarmFaden aktiv: alarmFaden ok' (Regression)"
  fi
  E2=$(echo "$JD" | grep -c -E 'relWatch Selbsttest FEHLER|relWatch Start:|relWatch Herzschlag nicht gestartet|relWatch Aufseher:|relWatch: Neustart-Zaehler nicht gespeichert|kontrollierter Neustart ueber systemd|alarmFaden Selbsttest FEHLER|alarmFaden Lauf:|sameOrigin Selbsttest FEHLER|keepLast heal:|perfKeep Selbsttest FEHLER' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne relWatch-/alarmFaden-/sameOrigin-/perfKeep-/keepLast-Fehler" || { echo "$JD" | grep -E 'relWatch|alarmFaden|sameOrigin|perfKeep|keepLast heal:' | cut -c1-240; rbx "$E2 relWatch-/alarmFaden-/sameOrigin-/perfKeep-/Heilungsfehler im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein relWatch-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
  JQ=$(echo "$JD" | grep -E 'relWatch: Faden ' | cut -c1-200 | head -5 || true)
  [[ -z "$JQ" ]] || { echo "HINWEIS relWatch meldet Faeden (nur Meldung, kein Eingriff):"; echo "$JQ" | sed 's/^/   | /'; }
fi
# ---------- 6b) Beobachtung: kommt der Herzschlag bei systemd an? (nur nach einem Neustart durch dieses Skript) ----------
if [[ "$RESTARTED_D" == 1 ]]; then
  PID1=$(systemctl show -p MainPID --value "$UNITN" 2>/dev/null || echo 0)
  NR1=$(systemctl show -p NRestarts --value "$UNITN" 2>/dev/null || echo 0); [[ -n "$NR1" ]] || NR1=0
  echo "Beobachtung: $HOLD_S s nach dem Neustart pruefen, dass systemd den Dienst nicht neu startet (MainPID $PID1, NRestarts $NR1; alle 10 s, Meldung alle 60 s) - bitte warten ..."
  LASTP=0
  while (( $(date +%s) - T0D < HOLD_S )); do
    sleep 10
    sudo -n -v >/dev/null 2>&1 || true
    systemctl is-active --quiet "$UNITN" || rbx "prepper-dashboard ist waehrend der Beobachtung nicht mehr aktiv (Watchdog-Neustart?)"
    PIDN=$(systemctl show -p MainPID --value "$UNITN" 2>/dev/null || echo 0)
    NRN=$(systemctl show -p NRestarts --value "$UNITN" 2>/dev/null || echo 0); [[ -n "$NRN" ]] || NRN=0
    [[ "$PIDN" == "$PID1" ]] || rbx "MainPID $PID1 -> $PIDN: systemd hat das Dashboard waehrend der Beobachtung neu gestartet - der Herzschlag kommt nicht an"
    [[ "$NRN" == "$NR1" ]] || rbx "NRestarts $NR1 -> $NRN: systemd hat das Dashboard waehrend der Beobachtung neu gestartet - der Herzschlag kommt nicht an"
    el=$(( $(date +%s) - T0D ))
    if (( el - LASTP >= 60 )); then LASTP=$el; echo "  ... $el s von $HOLD_S s, MainPID $PIDN, NRestarts $NRN, $(relq | cut -c1-150)"; fi
  done
  echo "OK Beobachtung: $HOLD_S s ohne Neustart durch systemd (MainPID $PID1 unveraendert, NRestarts $NR1; WatchdogSec $WDS s waere mehr als einmal abgelaufen)"
  RQ=$(relq); echo "Aufseher-Zustand am Ende: $RQ"
  echo "$RQ" | grep -q 'armed=True' && echo "OK Aufseher scharf: erstes Voll-Update ist durch, Webserver-Pruefung laeuft" || echo "HINWEIS Aufseher noch nicht scharf (armed=False): das erste Voll-Update laeuft noch (sehr lang?). Der systemd-Herzschlag laeuft unabhaengig davon; die Webserver-Pruefung beginnt erst danach. Spaeter pruefen: curl -s $B/api/sysboot/status (rel.wd.armed true)"
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
CNW=$(grep -c '# ===== relWatch:' "$F" || true); CNE=$(grep -c '# ===== relWatch (Start):' "$F" || true); CNT=$(grep -c '# ===== alarmFaden:' "$F" || true); CNS=$(grep -c '# ===== sameOrigin:' "$F" || true); CNR=$(grep -c '# ===== relHygiene:' "$F" || true); CNP=$(grep -c '# ===== perfKeep:' "$F" || true)
[[ "$CNW" == 1 && "$CNE" == 1 && "$CNT" == 1 && "$CNS" == 1 && "$CNR" == 1 && "$CNP" == 1 ]] && echo "OK Marker relWatch=$CNW relWatch(Start)=$CNE alarmFaden=$CNT sameOrigin=$CNS perfKeep=$CNP relHygiene=$CNR in dashboard.py" || rbx "Marker relWatch=$CNW relWatch(Start)=$CNE alarmFaden=$CNT sameOrigin=$CNS perfKeep=$CNP relHygiene=$CNR"
echo "Hinweis: haengende oder tote Hintergrundfaeden werden nur gemeldet (Journal, /api/sysboot/status rel), nicht neu gestartet (offene Entscheidung). Ein kontrollierter Neustart des Dashboards erfolgt nur, wenn der Webserver nach dem ersten Voll-Update 180 s lang nicht antwortet (hoechstens 3 je Stunde, danach Bremse)."
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt; nur Drop-in $DROPF (WatchdogSec/NotifyAccess$([[ "$ADD_R" == 1 ]] && echo "/Restart")) neu"
[[ -f "$F.bak-relwatch-$TS" ]] && echo "Backup: dashboard.py.bak-relwatch-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-relwatch-"* 2>/dev/null || true; } | head -1)
if [[ -f "$DROPF.bak-relwatch-$TS" ]]; then DB1="sudo cp -a $DROPF.bak-relwatch-$TS $DROPF"; else DB1="sudo rm $DROPF"; fi
[[ -n "$LB" ]] && echo "Rueckweg (Reihenfolge wichtig): 1) $DB1  2) sudo systemctl daemon-reload  3) cp -a $LB $F  4) sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine relWatch-Sicherung vorhanden (dashboard.py nicht geaendert); Drop-in: $DB1, sudo systemctl daemon-reload, sudo systemctl restart prepper-dashboard"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s $B/api/sysboot/status     (Abschnitt rel: thread true, wd.sock true, wd.beats waechst alle 15 s, nach dem ersten Voll-Update wd.armed true und probe_age_s unter 60)"
echo "  systemctl show prepper-dashboard -p WatchdogUSec -p NotifyAccess -p Restart -p NRestarts -p MainPID"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep relWatch"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG relwatch=1 fertig"
