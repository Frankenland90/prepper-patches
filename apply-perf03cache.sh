#!/bin/bash
set -eEuo pipefail
# perf03Cache (commit46): PERF-03 Rest: /api/frequenz aus data_store (hoechstens 60 s alt, sonst genau ein Live-Abruf mit Sperre) und /pegel Stale-While-Revalidate (hoechstens 10 min alt sofort, sonst alter Stand mit staleTs-Farbe und genau ein Hintergrund-Abruf; ohne Daten direkt wie bisher); ein Block vor __main__, keine geaenderte Zeile; freq_loop, maybe_mesh_frequenz, maybe_mesh_pegel, build_mesh_pegel_text unveraendert; neu nur lesend /api/perf03cache/status
# Aufruf: bash /tmp/apply-perf03cache.sh commit46 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py d0f34851146d65b5 (nach perfWsgi commit45) oder perf03Cache schon drin (4594deab53d8ce7b); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-perf03cache-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/perf03cache-apply
KEEP_LAST=3
KNOWN_D16="d0f34851146d65b5"      # dashboard.py vor perf03Cache (Basis: nach perfWsgi commit45)
KNOWN_D16N="4594deab53d8ce7b"             # dashboard.py nach perf03Cache (Ziel)
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
echo "=== perf03Cache apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): /api/frequenz aus data_store, /pegel Stale-While-Revalidate, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="abe82fa3049c87167054c49c5eef5421c7f386576eb9c4298a89e6aa2162c9a9"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher perf03Cache (generisch wie relStop). Aufruf: patch-pw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
EXPECT_RAE="bf3cdbf9bc136c44852c836688c15dd745ecfdf85d62416b5df063ff7610d6c9"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer perf03Cache (commit46): Basis d0f34851146d65b5 (Stand nach perfWsgi commit45); nur ein Block vor __main__, keine Aenderung an bestehenden Zeilen
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_RAE_EOF
EXPECT_RAB="4d7174273a9c7d8f4c0178bbeb29fe1e0c0e7ff32d7927d57ef09dd6f1a03223"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== perf03Cache: PERF-03 (Rest) - /api/frequenz aus dem Zwischenspeicher (data_store, hoechstens 60 s alt; sonst genau ein Live-Abruf mit Sperre) und /pegel Stale-While-Revalidate (hoechstens 10 min alt sofort, sonst alter Stand mit staleTs-Farbe und genau ein Hintergrund-Abruf; ohne Daten direkt wie bisher); freq_loop, maybe_mesh_frequenz, maybe_mesh_pegel und build_mesh_pegel_text unveraendert; sendet nichts =====
import threading as _pc_th
import time as _pc_time

PC_FREQ_MAX_AGE = 60       # s: data_store["frequenz"] (freq_loop alle 25 s) gilt bis 60 s als frisch
PC_FREQ_LIVE_TTL = 10      # s: Ergebnis des letzten Live-Abrufs fuer Wartende und dichte Folgeanfragen
PC_FREQ_WAIT = 8           # s: hoechstens so lange auf einen laufenden Live-Abruf warten (Quelle hat 5 s Zeitlimit)
PC_PEGEL_MAX_AGE = 600     # s: Pegel-Seite bis 10 min alt sofort aus dem Zwischenspeicher
PC_PEGEL_RETRY = 60        # s: nach einem fehlgeschlagenen Hintergrund-Abruf fruehestens nach 60 s ein neuer
_PC = {"fq_cache": 0, "fq_live": 0, "fq_wait": 0, "fq_busy": 0, "fq_t": None, "fq_d": None,
       "pg_fresh": 0, "pg_stale": 0, "pg_direct": 0, "pg_bg_start": 0, "pg_bg_ok": 0, "pg_bg_fail": 0, "pg_bg_run": 0, "pg_bg_max": 0,
       "pg_items": None, "pg_upd": None, "pg_fail_t": None, "pg_err": None, "prev_fq": None, "prev_pg": None, "err": None, "aktiv": False}
_PC_FQ_LOCK = _pc_th.Lock()
_PC_PG_LOCK = _pc_th.Lock()
_PC_N_LOCK = _pc_th.Lock()


def _pc_inc(k):
    with _PC_N_LOCK:
        _PC[k] += 1


def _pc_age(upd):
    """Alter in s aus dem Stempel 'updated' (wie staleTs: TT.MM.JJJJ HH:MM:SS oder HH:MM:SS); None = unbekannt."""
    try:
        a = _stale_age(upd)
    except Exception:
        return None
    if a is None:
        return None
    return max(0.0, float(a))


def _pc_fq_fresh():
    d = data_store.get("frequenz") if isinstance(data_store, dict) else None
    if isinstance(d, dict) and d.get("value") is not None:
        a = _pc_age(d.get("updated"))
        if a is not None and a <= PC_FREQ_MAX_AGE:
            return dict(d)
    return None


def _pc_fq_recent():
    t, d = _PC["fq_t"], _PC["fq_d"]
    if t is not None and isinstance(d, dict) and _pc_time.monotonic() - t <= PC_FREQ_LIVE_TTL:
        return dict(d)
    return None


def _pc_api_frequenz():
    """/api/frequenz: frischer Wert aus freq_loop (data_store) ohne Netz; sonst genau ein Live-Abruf (bisherige Funktion) gleichzeitig."""
    from flask import jsonify
    d = _pc_fq_fresh()
    if d is not None:
        _pc_inc("fq_cache")
        return jsonify(d)
    if not _PC_FQ_LOCK.acquire(timeout=PC_FREQ_WAIT):
        _pc_inc("fq_busy")
        p = data_store.get("frequenz") if isinstance(data_store, dict) else None
        if isinstance(p, dict) and p.get("value") is not None:
            d = dict(p)
            d["kept"] = True
        else:
            d = {"value": None, "color": "#6b7280", "status": "Keine Quelle", "updated": "–"}
        return jsonify(d)
    try:
        d = _pc_fq_fresh() or _pc_fq_recent()
        if d is not None:
            _pc_inc("fq_wait")
            return jsonify(d)
        _pc_inc("fq_live")
        resp = _PC["prev_fq"]()
        try:
            j = resp.get_json(silent=True)
            if isinstance(j, dict):
                _PC["fq_d"], _PC["fq_t"] = j, _pc_time.monotonic()
        except Exception:
            pass
        return resp
    finally:
        _PC_FQ_LOCK.release()


def _pc_pg_valid(items):
    """Seitenformat (fetch_pegel: mit 'series') und mindestens ein Messwert; das Lage-Format aus update_all zaehlt nicht."""
    return isinstance(items, list) and any(isinstance(x, dict) and "series" in x and x.get("cm") is not None for x in items)


def _pc_pg_current():
    """(items, updated, alter) des neuesten Seiten-Stands: eigener Zwischenspeicher oder data_store['pegel'] im Seitenformat."""
    best = None
    if _pc_pg_valid(_PC["pg_items"]):
        best = (_PC["pg_items"], _PC["pg_upd"], _pc_age(_PC["pg_upd"]))
    slot = data_store.get("pegel") if isinstance(data_store, dict) else None
    if isinstance(slot, dict) and _pc_pg_valid(slot.get("value")):
        a = _pc_age(slot.get("updated"))
        if a is not None and (best is None or best[2] is None or a < best[2]):
            best = (slot.get("value"), slot.get("updated"), a)
    return best


def _pc_pg_bg():
    """Hintergrund-Abruf (Faden perf03Pegel): bei Erfolg wie bisher die Seite stale_ts_put_pegel (frischer Stempel); bei Fehler oder keepLast-Ersatz (alter Wert mit _keepLastTs) bleibt der alte Stand mit altem Stempel."""
    ok = False
    try:
        items = fetch_pegel()
        kept = isinstance(items, list) and any(isinstance(x, dict) and "_keepLastTs" in x for x in items)
        if _pc_pg_valid(items) and not kept:
            upd = now_str()
            stale_ts_put_pegel(items)
            _PC["pg_items"], _PC["pg_upd"] = items, upd
            ok = True
        else:
            _PC["pg_err"] = "keepLast-Ersatz, Quelle gestoert" if kept else "kein Messwert"
    except Exception as e:
        _PC["pg_err"] = "%s: %s" % (type(e).__name__, str(e)[:120])
    finally:
        with _PC_PG_LOCK:
            _PC["pg_bg_run"] -= 1
            if ok:
                _PC["pg_bg_ok"] += 1
                _PC["pg_fail_t"] = None
            else:
                _PC["pg_bg_fail"] += 1
                _PC["pg_fail_t"] = _pc_time.monotonic()
    if not ok:
        print("perf03Cache: Pegel-Hintergrundabruf ohne Messwert (%s) - Seite zeigt weiter den alten Stand, neuer Versuch fruehestens in %d s" % (_PC["pg_err"], PC_PEGEL_RETRY), flush=True)


def _pc_pg_kick():
    """Startet genau einen Hintergrund-Abruf (nie zwei gleichzeitig; nach Fehler Pause PC_PEGEL_RETRY)."""
    with _PC_PG_LOCK:
        if _PC["pg_bg_run"] > 0:
            return False
        ft = _PC["pg_fail_t"]
        if ft is not None and _pc_time.monotonic() - ft < PC_PEGEL_RETRY:
            return False
        _PC["pg_bg_run"] += 1
        _PC["pg_bg_start"] += 1
        _PC["pg_bg_max"] = max(_PC["pg_bg_max"], _PC["pg_bg_run"])
    try:
        _pc_th.Thread(target=_pc_pg_bg, name="perf03Pegel", daemon=True).start()
        return True
    except Exception as e:
        with _PC_PG_LOCK:
            _PC["pg_bg_run"] -= 1
        _PC["pg_err"] = "Start: %s" % e
        return False


def _pc_pg_render(items, upd):
    """Wie page_pegel nach dem Abruf: Slot im Seitenformat (Stempel bleibt der des Abrufs, staleTs-Farbe nach Alter) und Vorlage."""
    slot = {"value": items, "updated": upd, "color": "#94a3b8"}
    col = stale_ts_color("pegel", upd)
    if col:
        slot["color"] = col

    def work():
        data_store["pegel"] = slot
    _stale_locked(work)
    try:
        data_store["pegel_mesh_status"] = last_pegel_mesh_status
    except Exception:
        data_store["pegel_mesh_status"] = {"auto": None, "manual": None}
    return render_template_string(PAGE_PEGEL, **data_store)


def _pc_page_pegel():
    """/pegel: bis 10 min alt sofort; aelter -> alter Stand (staleTs-Farbe) + genau ein Hintergrund-Abruf; ohne Daten wie bisher direkt."""
    cur = _pc_pg_current()
    if cur is None:
        _pc_inc("pg_direct")
        r = _PC["prev_pg"]()
        slot = data_store.get("pegel") if isinstance(data_store, dict) else None
        if isinstance(slot, dict) and _pc_pg_valid(slot.get("value")):
            _PC["pg_items"], _PC["pg_upd"] = slot.get("value"), slot.get("updated")
        return r
    items, upd, age = cur
    if age is not None and age <= PC_PEGEL_MAX_AGE:
        _pc_inc("pg_fresh")
    else:
        _pc_inc("pg_stale")
        _pc_pg_kick()
    return _pc_pg_render(items, upd)


def _pc_status():
    from flask import jsonify
    try:
        cur = _pc_pg_current()
        fq = data_store.get("frequenz") if isinstance(data_store, dict) else None
        return jsonify({"aktiv": _PC["aktiv"], "err": _PC["err"],
                        "frequenz": {"aus_speicher": _PC["fq_cache"], "live": _PC["fq_live"], "nach_warten": _PC["fq_wait"], "belegt": _PC["fq_busy"],
                                     "alter_s": _pc_age(fq.get("updated")) if isinstance(fq, dict) else None, "max_alter_s": PC_FREQ_MAX_AGE},
                        "pegel": {"frisch": _PC["pg_fresh"], "alt": _PC["pg_stale"], "direkt": _PC["pg_direct"], "hg_start": _PC["pg_bg_start"],
                                  "hg_ok": _PC["pg_bg_ok"], "hg_fehler": _PC["pg_bg_fail"], "hg_laeuft": _PC["pg_bg_run"], "hg_max_gleichzeitig": _PC["pg_bg_max"],
                                  "alter_s": None if cur is None or cur[2] is None else int(cur[2]), "stempel": None if cur is None else cur[1],
                                  "max_alter_s": PC_PEGEL_MAX_AGE, "letzter_fehler": _PC["pg_err"]}})
    except Exception as e:
        return jsonify({"error": str(e)[:120]})


def _pc_install():
    """Haengt die beiden Endpunkte um (einmalig; bei erneutem Laden wird die urspruengliche Funktion behalten)."""
    vf = app.view_functions
    prev = {}
    for rule, ep in (("/api/frequenz", "api_frequenz"), ("/pegel", "page_pegel")):
        rs = [r for r in app.url_map.iter_rules() if r.rule == rule]
        assert len(rs) == 1 and rs[0].endpoint == ep, "%s: %s" % (rule, [r.endpoint for r in rs])
        cur = vf[ep]
        prev[ep] = getattr(cur, "_pc_prev", cur)
    _PC["prev_fq"], _PC["prev_pg"] = prev["api_frequenz"], prev["page_pegel"]
    _pc_api_frequenz._pc_prev = prev["api_frequenz"]
    _pc_page_pegel._pc_prev = prev["page_pegel"]
    vf["api_frequenz"] = _pc_api_frequenz
    vf["page_pegel"] = _pc_page_pegel
    if "perf03cache_status" not in vf:
        app.add_url_rule("/api/perf03cache/status", "perf03cache_status", _pc_status, methods=["GET"])


def _selftest_perf03cache():
    from datetime import datetime as _pc_dt, timedelta as _pc_td
    n = _pc_dt.now()
    assert _pc_age(n.strftime("%H:%M:%S")) < 5 and 85 <= _pc_age((n - _pc_td(seconds=90)).strftime("%H:%M:%S")) <= 95, "Alter HH:MM:SS"
    assert 1195 <= _pc_age((n - _pc_td(seconds=1200)).strftime("%d.%m.%Y %H:%M:%S")) <= 1205 and _pc_age("–") is None and _pc_age(None) is None, "Alter Datum"
    good = [{"id": "1", "cm": 120, "series": []}]
    assert _pc_pg_valid(good) and not _pc_pg_valid([{"id": "1", "cm": None, "series": []}]) and not _pc_pg_valid([{"name": "Lauf", "cm": 120}]) and not _pc_pg_valid({"cm": 1}), "Seitenformat"
    assert stale_ts_color("pegel", (n - _pc_td(seconds=1600)).strftime("%d.%m.%Y %H:%M:%S")) == "#eab308", "staleTs-Farbe"
    assert PC_FREQ_MAX_AGE == 60 and PC_PEGEL_MAX_AGE == 600 and callable(fetch_pegel) and callable(stale_ts_put_pegel) and isinstance(PAGE_PEGEL, str), "Grundwerte"
    return "perf03Cache ok (/api/frequenz aus data_store bis %d s, sonst 1 Live-Abruf mit Sperre; /pegel bis %d s sofort, sonst alter Stand mit staleTs-Farbe + 1 Hintergrund-Abruf, Pause nach Fehler %d s; Mesh/Alarm unberuehrt)" % (PC_FREQ_MAX_AGE, PC_PEGEL_MAX_AGE, PC_PEGEL_RETRY)


try:
    _PC_ST = _selftest_perf03cache()
    _pc_install()
    _PC["aktiv"] = True
except Exception as _pc_e:
    _PC_ST = None
    _PC["err"] = "%s: %s" % (type(_pc_e).__name__, _pc_e)
    print("perf03Cache Selbsttest FEHLER (%s: %s) - /api/frequenz und /pegel wie bisher" % (type(_pc_e).__name__, _pc_e), flush=True)
if _PC_ST:
    print("perf03Cache aktiv: %s" % _PC_ST, flush=True)
# ===== /perf03Cache =====
MK_RAB_EOF
EXPECT_RAG="fe4b945e3cdfd03910b03e5be9f60a976915debb5e9f23dd7d4ecb8a98ef05cf"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""Guard perf03Cache (nur dashboard.py: ein Block vor __main__, keine geaenderten Zeilen). Aufruf:
  guard_pc.py revert NEU_VERZ ALT_VERZ BLOCK EDITS   -> ALT_VERZ/dashboard.py = NEU ohne perf03Cache (byte-genau)
  guard_pc.py check  ALT_VERZ NEU_VERZ BLOCK EDITS   -> Rueckbau = ALT, Lage, statische Regeln, Verhaltenstests (echte Funktionen api_frequenz, page_pegel und staleTs aus NEU in Kindprozessen, Quellen gefaelscht, kein Netz)
  RH_ALT=ALT_VERZ guard_pc.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest (jede Mutation muss check scheitern lassen)
Braucht flask im ausfuehrenden Python (venv)."""
import ast, io, json, os, re, subprocess, sys, tempfile, threading, tokenize

CHILD_SRC = r'''# Kindprozess fuer guard_pc.py: echte Funktionen aus dashboard.py (NEU) + perf03Cache-Block, gefaelschte Quellen, nur Flask-Testclient (kein Netz, kein Socket)
import ast, json, sys, threading, time
mode, out, bp, np = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
blk = open(bp, encoding="utf-8").read()
N = open(np, encoding="utf-8").read()
R = {}
def w():
    open(out, "w").write(json.dumps(R))
T = ast.parse(N)
WANT = {"now", "now_str", "STALE_CADENCE", "_STALE_PAINT", "_stale_locked", "_stale_age", "stale_ts_color", "_stale_can_restore", "stale_ts_put_pegel", "api_frequenz", "page_pegel"}
parts, got = [], set()
for s in T.body:
    nm = s.name if isinstance(s, ast.FunctionDef) else (s.targets[0].id if isinstance(s, ast.Assign) and isinstance(s.targets[0], ast.Name) else None)
    if nm in WANT:
        if isinstance(s, ast.FunctionDef):
            s.decorator_list = []
        parts.append(ast.unparse(s)); got.add(nm)
R["extrahiert"] = sorted(got)
from flask import Flask, jsonify, render_template_string, request
from datetime import datetime, timedelta
app = Flask("pctest")
C = {"fq": 0, "fq_delay": 0.0, "fq_val": 49.99, "pg": 0, "pg_delay": 0.0, "pg_mode": "ok", "pg_cm": 150, "pg_run": 0, "pg_max": 0, "send": 0, "mesh": 0}
L = threading.Lock()
def fetch_frequenz_live():
    C["fq"] += 1
    time.sleep(C["fq_delay"])
    if C["fq_val"] is None:
        return {"value": None, "color": "#6b7280", "status": "Keine Quelle", "updated": "–"}
    return {"value": C["fq_val"], "color": "#22c55e", "status": "Im Normalbereich", "updated": datetime.now().strftime("%H:%M:%S")}
def fetch_pegel():
    with L:
        C["pg"] += 1; C["pg_run"] += 1; C["pg_max"] = max(C["pg_max"], C["pg_run"])
    try:
        time.sleep(C["pg_delay"])
        if C["pg_mode"] == "raise":
            raise RuntimeError("gkd weg")
        cm = None if C["pg_mode"] == "offline" else C["pg_cm"]
        out = [{"id": "24228009", "name": "Schnaittach", "cm": cm, "series": []}, {"id": "24224008", "name": "Lauf / Pegnitz", "cm": cm, "series": []}]
        if C["pg_mode"] == "kept":
            out[0]["_keepLastTs"] = "31.10.2026 01:00:00"
        return out
    finally:
        with L:
            C["pg_run"] -= 1
def send_meshtastic(*a, **k):
    C["send"] += 1
    return False
def maybe_mesh_pegel(*a, **k):
    C["mesh"] += 1
def maybe_mesh_frequenz(*a, **k):
    C["mesh"] += 1
g = {"__name__": "__main__", "app": app, "jsonify": jsonify, "render_template_string": render_template_string, "request": request, "datetime": datetime, "timedelta": timedelta,
     "fetch_frequenz_live": fetch_frequenz_live, "fetch_pegel": fetch_pegel, "send_meshtastic": send_meshtastic, "maybe_mesh_pegel": maybe_mesh_pegel, "maybe_mesh_frequenz": maybe_mesh_frequenz,
     "last_pegel_mesh_status": {"auto": "A1", "manual": None}, "data_store": {},
     "PAGE_PEGEL": "P|{{ pegel.updated }}|{{ pegel.color }}|{% for x in pegel.value %}{{ x.id }}:{{ x.cm }};{% endfor %}|{{ pegel_mesh_status.auto }}"}
exec(compile("\n\n".join(parts), "auszug", "exec"), g)
app.add_url_rule("/api/frequenz", "api_frequenz", g["api_frequenz"])
app.add_url_rule("/pegel", "page_pegel", g["page_pegel"])
ORIG = {k: app.view_functions[k] for k in ("api_frequenz", "page_pegel")}
if mode == "broken":
    g["PAGE_PEGEL"] = None
exec(compile(blk, "perf03Cache-Block", "exec"), g)
if mode == "twice":
    exec(compile(blk, "perf03Cache-Block", "exec"), g)
vf = app.view_functions
R["orig_bleibt"] = {k: vf[k] is ORIG[k] for k in ORIG}
R["prev_ok"] = {k: getattr(vf[k], "_pc_prev", None) is ORIG[k] for k in ORIG}
R["status_regeln"] = sum(1 for r in app.url_map.iter_rules() if r.endpoint == "perf03cache_status")
if mode in ("broken", "twice"):
    w(); sys.exit(0)
def get(path):
    c = app.test_client()
    t0 = time.monotonic()
    r = c.get(path)
    return r.status_code, r.get_data(as_text=True), time.monotonic() - t0
def par(path, n):
    res = [None] * n
    def one(i):
        res[i] = get(path)
    ts = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in ts: t.start()
    for t in ts: t.join(30)
    return res
ds = g["data_store"]
hms = lambda s: (datetime.now() - timedelta(seconds=s)).strftime("%H:%M:%S")
dts = lambda s: (datetime.now() - timedelta(seconds=s)).strftime("%d.%m.%Y %H:%M:%S")
PC = g["_PC"]
# ---- Frequenz ----
ds["frequenz"] = {"value": 50.012, "color": "#22c55e", "status": "Im Normalbereich", "updated": hms(5)}
c, b, dt = get("/api/frequenz"); R["F1"] = [c, json.loads(b).get("value"), C["fq"], dt]
R["F1c"] = [PC["fq_cache"], PC["fq_wait"], PC["fq_live"]]
ds["frequenz"]["updated"] = hms(55); c, b, dt = get("/api/frequenz"); R["F1b"] = [json.loads(b).get("value"), C["fq"]]
ds["frequenz"]["updated"] = hms(120); C["fq_delay"] = 0.3
rs = par("/api/frequenz", 12); R["F2"] = [sorted(set(json.loads(x[1]).get("value") for x in rs)), C["fq"], sorted(set(x[0] for x in rs))]
c, b, dt = get("/api/frequenz"); R["F3"] = [json.loads(b).get("value"), C["fq"]]
PC["fq_t"] = None; C["fq_val"] = None; C["fq_delay"] = 0.0
c, b, dt = get("/api/frequenz"); R["F4"] = [json.loads(b).get("value"), json.loads(b).get("kept"), C["fq"]]
PC["fq_t"] = None; C["fq_val"] = 49.98; C["fq_delay"] = 0.8; g["PC_FREQ_WAIT"] = 0.3
rs = par("/api/frequenz", 2); R["F5"] = [sorted((json.loads(x[1]).get("value"), bool(json.loads(x[1]).get("kept"))) for x in rs), C["fq"], PC["fq_busy"]]
g["PC_FREQ_WAIT"] = 8
R["Fcnt"] = [PC["fq_cache"], PC["fq_live"], PC["fq_wait"]]
# ---- Pegel ----
ds["pegel"] = {"value": [{"name": "Lauf", "cm": 400}], "updated": dts(10), "color": "#94a3b8"}
c, b, dt = get("/pegel"); R["P1"] = [c, b.split("|")[3], C["pg"], PC["pg_direct"], "series" in str(ds["pegel"]["value"]), b.split("|")[4]]
c, b, dt = get("/pegel"); R["P2"] = [b.split("|")[3], C["pg"], PC["pg_fresh"], dt]
ds["pegel"] = {"value": [{"name": "Lauf", "cm": 401}], "updated": dts(1), "color": "#94a3b8"}
c, b, dt = get("/pegel"); R["P2b"] = [b.split("|")[3], C["pg"], "series" in str(ds["pegel"]["value"])]
keep_i, keep_u = PC["pg_items"], PC["pg_upd"]
PC["pg_upd"] = dts(1800); ds["pegel"] = {"value": [{"id": "24228009", "cm": 160, "series": []}], "updated": dts(30), "color": "#94a3b8"}
c, b, dt = get("/pegel"); R["P2c"] = [b.split("|")[3], C["pg"], PC["pg_bg_start"]]
PC["pg_items"], PC["pg_upd"] = keep_i, keep_u; ds["pegel"] = {"value": keep_i, "updated": keep_u, "color": "#94a3b8"}
old = dts(1800); PC["pg_upd"] = old; ds["pegel"]["updated"] = old
C["pg_delay"] = 0.6; C["pg_cm"] = 170
rs = par("/pegel", 20)
R["P3"] = [sorted(set(x[1].split("|")[3] for x in rs)), sorted(set(x[1].split("|")[2] for x in rs)), max(x[2] for x in rs), PC["pg_bg_start"], C["pg"]]
time.sleep(1.0)
R["P3b"] = [PC["pg_bg_ok"], C["pg_max"], ds["pegel"]["value"][0]["cm"]]
c, b, dt = get("/pegel"); R["P3c"] = [b.split("|")[3], b.split("|")[2], C["pg"], PC["pg_bg_start"]]
old = dts(1800); PC["pg_upd"] = old; ds["pegel"] = {"value": PC["pg_items"], "updated": old, "color": "#94a3b8"}
C["pg_delay"] = 0.2; C["pg_mode"] = "offline"
c, b, dt = get("/pegel"); time.sleep(0.4)
c2, b2, dt2 = get("/pegel"); time.sleep(0.4)
R["P4"] = [b.split("|")[3], b2.split("|")[3], dt, PC["pg_bg_start"], PC["pg_bg_fail"], C["pg"], ds["pegel"]["value"][0]["cm"]]
g["PC_PEGEL_RETRY"] = 0.3; time.sleep(0.4); C["pg_mode"] = "kept"; C["pg_cm"] = 99
old = dts(1800); PC["pg_upd"] = old; ds["pegel"]["updated"] = old
c, b, dt = get("/pegel"); time.sleep(0.4)
R["P4k"] = [b.split("|")[3], PC["pg_bg_start"], PC["pg_bg_fail"], PC["pg_upd"] == old, ds["pegel"]["value"][0]["cm"], (PC["pg_err"] or "")[:15]]
time.sleep(0.4); C["pg_mode"] = "raise"
c, b, dt = get("/pegel"); time.sleep(0.4)
R["P5"] = [c, PC["pg_bg_start"], PC["pg_bg_fail"], C["pg"], PC["pg_bg_run"], (PC["pg_err"] or "")[:30]]
c, b, dt = get("/api/perf03cache/status"); R["ST"] = json.loads(b) if c == 200 else None
PC["pg_items"] = None; ds.pop("pegel", None); C["pg_mode"] = "offline"; C["pg_delay"] = 0.0
c, b, dt = get("/pegel"); R["P6"] = [c, b.split("|")[3], C["pg"], PC["pg_direct"]]
R["C"] = C
R["threads"] = [t.name for t in threading.enumerate()]
w()
'''
ANCH = '\n\nif __name__ == "__main__":\n'
FORBID = ("requests", "urlopen", "socket", "subprocess", "os.system", "send_", "maybe_mesh", "build_mesh", "freq_loop", "fetch_frequenz_live", "telegram", "open(",
          "systemctl", "eval(", "exec(", "__import__", "signal", "kill", "_exit", "sys.exit", "notify", "global ", "gain", "alarm", "sqlite", "update_fail_counter", "globals", "setattr", "__dict__")
OWN = re.compile(r"^(_pc_\w*|_PC\w*|PC_[A-Z_]+|_selftest_perf03cache)$")
USES = ("data_store", "_stale_age", "stale_ts_color", "stale_ts_put_pegel", "_stale_locked", "fetch_pegel", "now_str", "last_pegel_mesh_status", "PAGE_PEGEL", "render_template_string", "app")
CONST = {"PC_FREQ_MAX_AGE": 60, "PC_FREQ_LIVE_TTL": 10, "PC_FREQ_WAIT": 8, "PC_PEGEL_MAX_AGE": 600, "PC_PEGEL_RETRY": 60}
rd = lambda p: open(p, encoding="utf-8").read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"]


def revert_text(s, B, E):
    B = B.rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block perf03Cache nicht genau einmal"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in E:
        assert s.count(n) == 1, "Stelle nicht genau einmal: %r" % n[:50]
        s = s.replace(n, o, 1)
    return s


def code_only(B):
    return " ".join(t.string for t in tokenize.generate_tokens(io.StringIO(B).readline) if t.type not in (tokenize.COMMENT, tokenize.STRING))


def run_child(mode, bp, np):
    with tempfile.TemporaryDirectory() as d:
        out, cp = os.path.join(d, "out"), os.path.join(d, "child.py")
        open(cp, "w", encoding="utf-8").write(CHILD_SRC)
        p = subprocess.run([sys.executable, cp, mode, out, bp, np], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        R = json.loads(rd(out)) if os.path.exists(out) else {}
        return R, p.stdout, p.returncode


def fdef(T, name):
    x = [s for s in T.body if isinstance(s, ast.FunctionDef) and s.name == name]
    return x[0] if len(x) == 1 else None


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
    ok(E == [], "perf03Cache aendert bestehende Zeilen")
    ok("perf03Cache" not in A and "_pc_" not in A, "Basis enthaelt perf03Cache schon")
    Bs = B.rstrip("\n")
    ok(N.count("\n\n" + Bs + ANCH) == 1, "Block nicht direkt vor __main__")
    ok("# ===== /perfWsgi =====" in N and N.index("# ===== /perfWsgi =====") < N.index("# ===== perf03Cache:"), "Block nicht nach perfWsgi")
    ok(B.startswith("# ===== perf03Cache:") and B.rstrip().endswith("# ===== /perf03Cache =====") and N.count("# ===== perf03Cache:") == 1, "Marker")
    try:
        TN, TA, TB = ast.parse(N), ast.parse(A), ast.parse(B)
        ok(True, "")
    except SyntaxError as e:
        return n + 1, fails + ["Syntax: %s" % e]
    C = code_only(B)
    for f in FORBID:
        ok(f not in C, "verboten im Block: " + f)
    ids = {x.id for x in ast.walk(TB) if isinstance(x, ast.Name)} | {x.attr for x in ast.walk(TB) if isinstance(x, ast.Attribute)}
    ok(sorted(i for i in ids if "mesh" in i.lower()) == ["last_pegel_mesh_status"], "Mesh-Namen im Block: %s" % sorted(i for i in ids if "mesh" in i.lower()))
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
    for k, v in CONST.items():
        ok(re.search(r"^%s = %d\b" % (k, v), B, re.M) is not None, "Grundwert %s != %d" % (k, v))
    calls = [ast.unparse(x.func) for x in ast.walk(TB) if isinstance(x, ast.Call)]
    ok(calls.count("fetch_pegel") == 1 and calls.count("stale_ts_put_pegel") == 1, "fetch_pegel/stale_ts_put_pegel nicht genau einmal (nur Hintergrund-Abruf)")
    ok(calls.count("_PC['prev_fq']") == 1 and calls.count("_PC['prev_pg']") == 1, "Originalfunktionen nicht genau einmal aufgerufen")
    ok(calls.count("_pc_th.Thread") == 1 and "name = perf03Pegel" not in C and re.search(r'Thread\(target=_pc_pg_bg, name="perf03Pegel", daemon=True\)', B) is not None, "Hintergrundfaden")
    fb = fdef(TB, "_pc_pg_bg")
    ok(fb is not None and any(isinstance(x, ast.Call) and ast.unparse(x.func) == "fetch_pegel" for x in ast.walk(fb)), "fetch_pegel ausserhalb des Hintergrund-Abrufs")
    # Vorlage wie page_pegel: letzte beiden Anweisungen (pegel_mesh_status + render) identisch
    pp, pr = fdef(TA, "page_pegel"), fdef(TB, "_pc_pg_render")
    ok(pp is not None and pr is not None and [ast.dump(x) for x in pp.body[-2:]] == [ast.dump(x) for x in pr.body[-2:]], "_pc_pg_render weicht vom Ende von page_pegel ab")
    sp = fdef(TA, "stale_ts_put_pegel")
    ok(sp is not None and "stale_ts_color('pegel'" in ast.unparse(sp) and "stale_ts_color('pegel', upd)" in ast.unparse(pr), "staleTs-Farbe wie stale_ts_put_pegel")
    for nm in ("maybe_mesh_pegel", "build_mesh_pegel_text", "freq_loop", "maybe_mesh_frequenz", "fetch_pegel", "fetch_frequenz_live", "api_frequenz", "page_pegel", "stale_ts_put_pegel"):
        fa, fn = [ast.dump(s) for s in TA.body if isinstance(s, ast.FunctionDef) and s.name == nm], [ast.dump(s) for s in TN.body if isinstance(s, ast.FunctionDef) and s.name == nm]
        ok(fa and fa == fn, "%s veraendert" % nm)
    ok(len(re.findall(r'^@app\.route\("/pegel"\)', N, re.M)) == 1 and len(re.findall(r'^@app\.route\("/api/frequenz"\)', N, re.M)) == 1, "Routen /pegel, /api/frequenz nicht genau einmal")
    ok(not re.search(r'view_functions\[["\'](api_frequenz|page_pegel)', A), "Basis haengt die Endpunkte schon um")
    Rs = {}
    ths = [threading.Thread(target=lambda m=m: Rs.__setitem__(m, run_child(m, bp, neu))) for m in ("main", "twice", "broken")]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    R, so, rc = Rs["main"]
    ok(rc == 0 and len(R.get("extrahiert") or []) == 11, "Kind: rc %r, %s, %s" % (rc, R.get("extrahiert"), so[-300:]))
    ok(R.get("orig_bleibt") == {"api_frequenz": False, "page_pegel": False} and R.get("prev_ok") == {"api_frequenz": True, "page_pegel": True} and R.get("status_regeln") == 1, "Umhaengen: %r %r" % (R.get("orig_bleibt"), R.get("prev_ok")))
    ok("perf03Cache aktiv: perf03Cache ok (/api/frequenz aus data_store bis 60 s" in so and "FEHLER" not in so, "Journalzeile aktiv: %s" % so[-200:])
    f = R.get("F1") or [0, 0, 9, 9]
    ok(f[0] == 200 and f[1] == 50.012 and f[2] == 0 and f[3] < 0.05, "F1 frischer Wert aus data_store: %r" % f)
    ok(R.get("F1c") == [1, 0, 0], "F1c frischer Wert ohne Sperre direkt aus data_store: %r" % R.get("F1c"))
    ok(R.get("F1b") == [50.012, 0], "F1b 55 s alt noch aus data_store: %r" % R.get("F1b"))
    ok(R.get("F2") == [[49.99], 1, [200]], "F2 12 parallel, Wert 120 s alt -> genau 1 Live-Abruf: %r" % R.get("F2"))
    ok(R.get("F3") == [49.99, 1], "F3 Folgeanfrage nutzt Live-Ergebnis (10 s): %r" % R.get("F3"))
    ok(R.get("F4") == [50.012, True, 2], "F4 Quelle weg -> alter Wert kept wie bisher: %r" % R.get("F4"))
    f5 = R.get("F5") or []
    ok(f5 == [[(49.98, False), (50.012, True)], 3, 1] or f5 == [[[49.98, False], [50.012, True]], 3, 1], "F5 Sperre belegt -> kept statt zweitem Abruf: %r" % f5)
    p = R.get("P1") or []
    ok(p[:5] == [200, "24228009:150;24224008:150;", 1, 1, True] and p[5] == "A1", "P1 ohne Seitendaten direkt wie bisher: %r" % p)
    p = R.get("P2") or [0, 0, 0, 9]
    ok(p[:3] == ["24228009:150;24224008:150;", 1, 1] and p[3] < 0.05, "P2 frisch aus Zwischenspeicher: %r" % p)
    ok(R.get("P2b") == ["24228009:150;24224008:150;", 1, True], "P2b Lage-Format aus update_all verdraengt die Seite nicht: %r" % R.get("P2b"))
    ok(R.get("P2c") == ["24228009:160;", 1, 0], "P2c neuerer Seiten-Stand aus data_store (z. B. Wetter-Slot) wird genommen: %r" % R.get("P2c"))
    p = R.get("P3") or [[], [], 9, 0, 0]
    ok(p[0] == ["24228009:150;24224008:150;"] and p[1] == ["#eab308"] and p[2] < 0.5 and p[3] == 1, "P3 alt -> sofort alter Stand gelb + genau 1 Hintergrund-Abruf: %r" % p)
    ok(R.get("P3b") == [1, 1, 170], "P3b Hintergrund ok, nie 2 gleichzeitig: %r" % R.get("P3b"))
    ok(R.get("P3c") == ["24228009:170;24224008:170;", "#94a3b8", 2, 1], "P3c danach frisch: %r" % R.get("P3c"))
    p = R.get("P4") or []
    ok(len(p) == 7 and p[0] == p[1] == "24228009:170;24224008:170;" and p[2] < 0.2 and p[3] == 2 and p[4] == 1 and p[5] == 3 and p[6] == 170, "P4 gkd weg: alter Stand bleibt, 1 Versuch, Pause: %r" % p)
    ok(R.get("P4k") == ["24228009:170;24224008:170;", 3, 2, True, 170, "keepLast-Ersatz"], "P4k keepLast-Ersatz zaehlt als Fehler, alter Stempel bleibt: %r" % R.get("P4k"))
    p = R.get("P5") or []
    ok(p[:5] == [200, 4, 3, 5, 0] and p[5].startswith("RuntimeError"), "P5 Ausnahme im Hintergrund: %r" % p)
    st = R.get("ST") or {}
    ok(st.get("aktiv") is True and (st.get("pegel") or {}).get("hg_max_gleichzeitig") == 1 and (st.get("frequenz") or {}).get("live") == 3, "Status: %r" % st)
    ok(R.get("P6") == [200, "24228009:None;24224008:None;", 6, 2], "P6 ohne Daten und gkd weg: direkt wie bisher: %r" % R.get("P6"))
    c = R.get("C") or {}
    ok(c.get("send") == 0 and c.get("mesh") == 0 and c.get("pg_max") == 1, "Senden/Mesh/gleichzeitige Abrufe: %r" % {k: c.get(k) for k in ("send", "mesh", "pg_max")})
    R, so, rc = Rs["twice"]
    ok(rc == 0 and R.get("prev_ok") == {"api_frequenz": True, "page_pegel": True} and R.get("status_regeln") == 1 and so.count("perf03Cache aktiv") == 2 and "FEHLER" not in so, "zweimal geladen: %r %s" % (R, so[-200:]))
    R, so, rc = Rs["broken"]
    ok(rc == 0 and R.get("orig_bleibt") == {"api_frequenz": True, "page_pegel": True} and "perf03Cache Selbsttest FEHLER" in so and "perf03Cache aktiv" not in so, "Selbsttest-Fehler -> Endpunkte wie bisher: %r %s" % (R.get("orig_bleibt"), so[-200:]))
    return n, fails


MUT = [
    ("B", "PC_FREQ_MAX_AGE = 60 ", "PC_FREQ_MAX_AGE = 30 "),
    ("B", "        if a is not None and a <= PC_FREQ_MAX_AGE:\n", "        if a is not None:\n"),
    ("B", "    if not _PC_FQ_LOCK.acquire(timeout=PC_FREQ_WAIT):\n", "    if not True:\n"),
    ("B", "        d = _pc_fq_fresh() or _pc_fq_recent()\n", "        d = None\n"),
    ("B", "    if t is not None and isinstance(d, dict) and _pc_time.monotonic() - t <= PC_FREQ_LIVE_TTL:\n", "    if False:\n"),
    ("B", '            d["kept"] = True\n', ""),
    ("B", "                _PC[\"fq_d\"], _PC[\"fq_t\"] = j, _pc_time.monotonic()\n", "                pass\n"),
    ("B", 'any(isinstance(x, dict) and "series" in x and x.get("cm") is not None for x in items)', 'any(isinstance(x, dict) and x.get("cm") is not None for x in items)'),
    ("B", "    if age is not None and age <= PC_PEGEL_MAX_AGE:\n", "    if True:\n"),
    ("B", "        if _PC[\"pg_bg_run\"] > 0:\n            return False\n", ""),
    ("B", "        if ft is not None and _pc_time.monotonic() - ft < PC_PEGEL_RETRY:\n", "        if False:\n"),
    ("B", "        _pc_pg_kick()\n", "        _pc_pg_bg()\n"),
    ("B", "    col = stale_ts_color(\"pegel\", upd)\n", "    col = None\n"),
    ("B", "            stale_ts_put_pegel(items)\n", "            pass\n"),
    ("B", "        if _pc_pg_valid(items) and not kept:\n", "        if _pc_pg_valid(items):\n"),
    ("B", "    slot = {\"value\": items, \"updated\": upd, \"color\": \"#94a3b8\"}\n", "    slot = {\"value\": items, \"updated\": now_str(), \"color\": \"#94a3b8\"}\n"),
    ("B", "        if a is not None and (best is None or best[2] is None or a < best[2]):\n", "        if a is not None and best is None:\n"),
    ("B", "    if cur is None:\n        _pc_inc(\"pg_direct\")\n", "    if cur is None:\n        return _pc_pg_render([], now_str())\n        _pc_inc(\"pg_direct\")\n"),
    ("B", "            _PC[\"pg_bg_run\"] -= 1\n            if ok:", "            if ok:"),
    ("B", "    _pc_install()\n", ""),
    ("B", "        prev[ep] = getattr(cur, \"_pc_prev\", cur)\n", "        prev[ep] = cur\n"),
    ("B", "    if \"perf03cache_status\" not in vf:\n", "    if True:\n"),
    ("B", "        data_store[\"pegel_mesh_status\"] = last_pegel_mesh_status\n    except", "        data_store[\"pegel_mesh_status\"] = {\"auto\": None, \"manual\": None}\n    except"),
    ("B", "    _stale_locked(work)\n", ""),
    ("B", "PC_PEGEL_MAX_AGE = 600 ", "PC_PEGEL_MAX_AGE = 6000 "),
    ("B", "import time as _pc_time\n", "import time as _pc_time\nimport requests as _pc_rq\n"),
    ("B", "        items = fetch_pegel()\n", "        items = fetch_pegel()\n        send_meshtastic(\"x\")\n"),
    ("B", "    vf[\"page_pegel\"] = _pc_page_pegel\n", "    vf[\"page_pegel\"] = _pc_page_pegel\n    globals()[\"fetch_pegel\"] = lambda: []\n"),
    ("B", "    from flask import jsonify\n    d = _pc_fq_fresh()\n", "    from flask import jsonify\n    d = _pc_fq_recent()\n"),
    ("N", "        _pv = fetch_pegel()\n    except Exception as _pe:\n        print(\"page_pegel:\", _pe)", "        _pv = []\n    except Exception as _pe:\n        print(\"page_pegel:\", _pe)"),
    ("N", "            f = fetch_frequenz_live()\n            if f.get(\"value\") is not None:\n                try:\n                    maybe_mesh_frequenz", "            f = _pc_api_frequenz() and fetch_frequenz_live()\n            if f.get(\"value\") is not None:\n                try:\n                    maybe_mesh_frequenz"),
    ("N", "\n\nif __name__ == \"__main__\":\n    # sourceWatch final", "\napp.view_functions[\"api_frequenz\"] = api_frequenz\n\nif __name__ == \"__main__\":\n    # sourceWatch final"),
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
    print("%s Mutationstest perf03Cache: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", len(MUT), miss))
    return miss


if __name__ == "__main__":
    cmd = sys.argv[1]
    dp = lambda d: os.path.join(d, "dashboard.py") if os.path.isdir(d) else d
    if cmd == "revert":
        open(dp(sys.argv[3]), "w", encoding="utf-8").write(revert_text(rd(dp(sys.argv[2])), rd(sys.argv[4]), load_edits(sys.argv[5])))
        print("OK Rueckbau perf03Cache byte-genau erzeugt")
    elif cmd == "check":
        n, f = check(dp(sys.argv[2]), dp(sys.argv[3]), sys.argv[4], sys.argv[5])
        for x in f:
            print("FEHLER", x)
        print("%s Guard perf03Cache: %d Pruefungen, %d Fehler (Rueckbau byte-genau, nur Block vor __main__, Mesh-/Frequenz-/Pegel-Funktionen unveraendert, kein Netz/Senden im Block, Verhalten mit echten Funktionen: Frequenz aus data_store/1 Live-Abruf, Pegel frisch/alt + 1 Hintergrund-Abruf/direkt ohne Daten)" % ("OK" if not f else "FEHLER", n, len(f)))
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "nach perfWsgi commit45" "$KNOWN_D16N" "perf03Cache schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      perf03Cache passt nur auf den Stand nach perfWsgi commit45 (dashboard.py d0f34851146d65b5). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- perf03Cache: lage_pages.py bleibt unberuehrt (Vorlage PAGE_PEGEL), perfWsgi muss laufen ----
[[ -f "$DASH_DIR/lage_pages.py" ]] || stop "lage_pages.py fehlt (Stand nach pegelSplit erwartet)"
PCL=$(s16 "$DASH_DIR/lage_pages.py")
[[ "$PCL" == 7f9fc0cf17d52644 ]] || stop "lage_pages.py sha16 $PCL statt 7f9fc0cf17d52644 (Stand nach pegelSplit) - bitte diese Ausgabe an Grok schicken"
echo "OK lage_pages.py 7f9fc0cf17d52644 (wird nicht angefasst)"
PCSV=$("${CURL[@]}" "$B/api/perfwsgi/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("server"), d.get("workers"))' 2>/dev/null || echo "? ?")
if [[ "$PCSV" == "waitress 8" ]]; then echo "OK perfWsgi laeuft (waitress, 8 Arbeitsfaeden)"
elif [[ "$DRY" == 1 ]]; then echo "HINWEIS perfWsgi-Status nicht lesbar ($PCSV) - im Trockenlauf unerheblich"
else stop "perfWsgi-Status $PCSV statt 'waitress 8' - Dashboard laeuft nicht wie nach commit45 erwartet"; fi
# ---- perf03Cache: Neustart-Sperre HH:55-HH:04 (jede Stunde, Berlin-Zeit); geprueft jetzt und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${PC_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$PC_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Sperre: perf03Cache ist schon installiert, es wird kein Neustart gebraucht"
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
python3 "$PPK" perf03Cache dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer perf03Cache nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" perf03Cache dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: perf03Cache im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne perf03Cache ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard perf03Cache meldet Verstoss"; }
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
# ---- perf03Cache: Zustand vorher (nur Lesen): Antwortzeiten /pegel und /api/frequenz ----
PCPG0=$(tm "$B/pegel"); PCFQ0=$(tmed "$B/api/frequenz")
echo "Zustand vorher: /pegel ${PCPG0} s (ein Aufruf), /api/frequenz Median ${PCFQ0} s (5 Aufrufe)"
rscheck "vor dem Neustart"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: perf03Cache ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-perf03cache-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG perf03cache=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "perf03Cache|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-perf03cache-$TS" ]] && cp -a "$F.bak-perf03cache-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-perf03cache-$TS" ]] && { cmp -s "$F" "$F.bak-perf03cache-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK perf03Cache schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-perf03cache-$TS"
  { ls -1t "$F.bak-perf03cache-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-perf03cache-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-perf03cache-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'perf03Cache aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; perf03Cache aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- perf03Cache: Endpunkte umgehaengt, Frequenz aus data_store, Pegel aus dem Zwischenspeicher ----
PCM=$(grep -c "^# ===== perf03Cache:" "$F" || true)
[[ "$PCM" == 1 ]] && echo "OK Marker perf03Cache 1x" || rbx "dashboard.py perf03Cache-Marker ${PCM}x"
pcst() { "${CURL[@]}" "$B/api/perf03cache/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
f = d.get("frequenz") or {}; p = d.get("pegel") or {}
a = f.get("alter_s")
print(d.get("aktiv"), "-" if a is None else int(a), f.get("aus_speicher"), f.get("live"), p.get("frisch"), p.get("alt"), p.get("direkt"), p.get("hg_start"), p.get("hg_max_gleichzeitig"), p.get("alter_s"))' 2>/dev/null || echo "FEHLER"; }
PCW=0
while [[ "$PCW" -lt 40 ]]; do
  read -r C_AK C_FA C_FS C_FL C_PF C_PA C_PD C_PS C_PM C_PAL <<< "$(pcst)"
  [[ "$C_AK" == True && "$C_FA" =~ ^[0-9]+$ && "$C_FA" -le 60 ]] && break
  PCW=$(( PCW + 1 )); sleep 3
done
[[ "$C_AK" == True ]] && echo "OK perf03Cache aktiv (/api/perf03cache/status)" || rbx "perf03Cache nicht aktiv (Status: $C_AK)"
if [[ "$C_FA" =~ ^[0-9]+$ && "$C_FA" -le 60 ]]; then
  PCFQ1=$(tmed "$B/api/frequenz")
  read -r C_AK C_FA2 C_FS2 C_FL2 X <<< "$(pcst)"
  [[ "$C_FL2" == "$C_FL" && "$C_FS2" -ge $(( C_FS + 5 )) ]] && echo "OK /api/frequenz aus data_store (Wert ${C_FA2} s alt, 5 Aufrufe ohne Netz): Median ${PCFQ1} s (vorher ${PCFQ0} s)" || rbx "/api/frequenz nicht aus data_store (aus_speicher $C_FS -> $C_FS2, live $C_FL -> $C_FL2)"
else
  echo "HINWEIS /api/frequenz: data_store-Wert nach $(( PCW * 3 )) s nicht frisch (Alter ${C_FA}) - Quelle gestoert? Dann Live-Abruf mit Sperre wie vorgesehen; Handpruefung spaeter: curl -s $B/api/perf03cache/status"
fi
c=$(code "$B/api/frequenz"); [[ "$c" == 200 ]] || rbx "/api/frequenz HTTP $c"
c=$(code "$B/pegel"); [[ "$c" == 200 ]] || rbx "/pegel HTTP $c"
PCPG1=$(tmed "$B/pegel")
read -r C_AK C_FA C_FS C_FL C_PF C_PA C_PD C_PS C_PM C_PAL <<< "$(pcst)"
if [[ "${C_PF:-0}" =~ ^[0-9]+$ && "$C_PF" -ge 4 ]]; then
  echo "OK /pegel aus dem Zwischenspeicher (Stand ${C_PAL} s alt): Median ${PCPG1} s (vorher ${PCPG0} s); direkt ${C_PD}x, Hintergrund-Abrufe ${C_PS}, nie mehr als ${C_PM} gleichzeitig"
  awk -v b="$PCPG1" 'BEGIN{exit !(b > 2.0)}' && rbx "/pegel trotz Zwischenspeicher langsam (${PCPG1} s)"
else
  echo "HINWEIS /pegel: noch keine Seiten-Daten im Zwischenspeicher (frisch ${C_PF}, direkt ${C_PD}) - gkd gestoert? Dann wie bisher direkter Abruf; Median ${PCPG1} s"
fi
[[ "${C_PM:-0}" =~ ^[01]$ ]] || rbx "mehr als ein Pegel-Hintergrund-Abruf gleichzeitig ($C_PM)"
PCWS=$("${CURL[@]}" "$B/api/perfwsgi/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("server"), d.get("workers"))' 2>/dev/null || echo "? ?")
[[ "$PCWS" == "waitress 8" ]] && echo "OK perfWsgi weiter aktiv (waitress, 8 Arbeitsfaeden)" || rbx "perfWsgi-Status nach dem Neustart: $PCWS"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep -E perf03Cache"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "perf03Cache aktiv: perf03Cache ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'perf03Cache aktiv: perf03Cache ok' ($(echo "$JD" | grep -F perf03Cache | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein perf03Cache-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-perf03cache-$TS" ]] && echo "Backup: dashboard.py.bak-perf03cache-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-perf03cache-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine perf03cache-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c perf03Cache /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/api/perf03cache/status"
echo "  curl -s -w %{time_total}_ -o /dev/null http://127.0.0.1:5000/pegel -o /dev/null http://127.0.0.1:5000/api/frequenz"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep perf03Cache"
echo "  sudo journalctl -u prepper-dashboard -n 500 --no-pager | grep relStop"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG perf03cache=1 fertig"
