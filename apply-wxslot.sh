#!/bin/bash
set -eEuo pipefail
# wxSlot (commit34): Neustarts verschlucken keine Auto-Meldungen mehr: (a) Der laufende 3-h-Wetter-Slot gilt nach Neustart/Anlaufruhe nur als erledigt, wenn mesh_weather_status.json einen Auto-Stempel im Slot hat; sonst wird er in der Slot-Stunde HH:00-HH:59 nachgeholt (sofort, wenn die Anlaufruhe den Slot-Beginn ueberspannt; sonst nach der Anlaufruhe), je Slot 1 Versuch + 3 Wiederholungen im Abstand 120 s, nie doppelt (Stempel, Sperre, Bridge-Dublettensperre); Pegel und Heartbeat haengen wie bisher am erfolgreichen Auto-Wetter; Ergebnis je Slot im Journal und in /api/sysboot/status (wx). (b) Der Stromausfall-Stand (last_outage_ids) liegt atomar in outage_mesh_state.json und ueberlebt Neustarts: Entwarnung nach Neustart bei offen -> leer, neue Ausfaelle nach Neustart werden gesendet; die Anlaufruhe stellt den Abgleich nur zurueck (kein Verwerfen). Dedup 6 h, 3/h, Probe/Test nie ins Mesh und 2-h-Halt unveraendert. Nur dashboard.py (7 Stellen + Block). Neustart-Sperre: nie HH:55-HH:04 um die Slots und HH:55-HH:59 der Slot-Stunden.
# Aufruf: bash /tmp/apply-wxslot.sh commit34 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 1574109c8609cf26 (Stand nach secXmlDash commit33) oder wxSlot schon drin (03ee294d6e4ed56f); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-wxslot-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/wxslot-apply
KEEP_LAST=3
KNOWN_D16="1574109c8609cf26"      # dashboard.py vor wxSlot (Basis: Stand nach secXmlDash commit33)
KNOWN_D16N="03ee294d6e4ed56f"             # dashboard.py nach wxSlot (Ziel)
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
echo "=== wxSlot apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Wetter-Slot nachholen, Stromausfall-Stand in Datei, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="46c09c304c399c8009f69506f22cd4a7b6100268924453a2b503f0bdd92733c0"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher wxSlot. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
EXPECT_RAE="4aadd58549d88b88e373ce13658046357dbd5fcc6c6f4c19eb42817f8e9b3eae"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer wxSlot (commit34): Basis 1574109c8609cf26 (Stand nach secXmlDash commit33)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    ('# Wetter: kein Nachholen - laufender Slot gilt als erledigt, erst naechster Slot sendet.\n',
     '# Wetter: laufender Slot gilt nur dann als erledigt, wenn ein Auto-Stempel im Slot steht (mesh_weather_status.json);\n#         sonst holt wxSlot ihn in der Slot-Stunde HH:00-HH:59 nach (nach der Ruhezeit, bzw. sofort wenn die Ruhezeit den Slot-Beginn ueberspannt).\n'),
    ('        if _mbq_is_force(orig, a, kw):\n            return orig(*a, **kw)\n        if _mbq_quiet():\n',
     '        if _mbq_is_force(orig, a, kw):\n            return orig(*a, **kw)\n        if _mbq_quiet() and not (name == "maybe_mesh_weather" and globals().get("_wx_spans", lambda: False)()):  # wxSlot: Ruhezeit ueber den Slot-Beginn -> Wetter sofort\n'),
    ('                    return False  # Slot lief in der Ruhezeit: kein Nachholen\n',
     '                    return False  # Auto-Stempel im Slot schon da: kein zweites Senden\n'),
    ('def _mbq_q_weather(*a, **kw):\n    try:\n        slot = _mbq_slot_now()\n        _mbq_state["wx_done"].add(slot)\n',
     '_MBQ_WX_STATUS = "/home/fmg/prepper-dashboard/mesh_weather_status.json"  # wxSlot: wie save_mesh_weather_status\n\n\ndef _mbq_stamp_in_slot(slot, path=None, mem=None):\n    """True, wenn ein Auto-Stempel (Datei mesh_weather_status.json oder Speicherstand) im 3-h-Slot steht. Wirft nie."""\n    try:\n        import datetime as _mbq_dt\n        vals = []\n        try:\n            with open(path or _MBQ_WX_STATUS) as f:\n                d = _mbq_json.load(f)\n            vals.append(d.get("auto") if isinstance(d, dict) else None)\n        except Exception:\n            pass\n        vals.append(globals().get("last_mesh_weather_auto") if mem is None else mem)\n        for v in vals:\n            if not v:\n                continue\n            try:\n                t = _mbq_dt.datetime.strptime(str(v).strip(), "%d.%m.%Y %H:%M:%S")\n            except Exception:\n                continue\n            if t.replace(hour=t.hour - (t.hour % 3), minute=0, second=0, microsecond=0).strftime("%Y-%m-%d-%H") == slot:\n                return True\n    except Exception:\n        pass\n    return False\n\n\ndef _mbq_q_weather(*a, **kw):\n    try:\n        slot = _mbq_slot_now()\n        if not _mbq_stamp_in_slot(slot):  # wxSlot: ohne Auto-Stempel im Slot NICHT als erledigt markieren\n            if _mbq_state.get("wx_open") != slot:\n                _mbq_state["wx_open"] = slot\n                print("meshBootQuiet: Wetter-Slot %s ohne Auto-Stempel - %s" % (slot, "bleibt offen (wxSlot holt nach)" if now().hour % 3 == 0 else "Slot-Stunde vorbei, nicht nachholbar"))\n            return\n        _mbq_state["wx_done"].add(slot)\n'),
    ('    _mbq_q_weather()  # laufender Slot sofort erledigt (kein Nachholen)\n',
     '    _mbq_q_weather()  # laufender Slot nur mit Auto-Stempel im Slot erledigt, sonst bleibt er fuer wxSlot offen\n'),
    ('    ids = frozenset(str(x.get("id")) for x in (items or []) if x.get("id") is not None)\n    if last_outage_ids is None:\n        last_outage_ids = ids\n        return False\n    if ids == last_outage_ids:\n        return False\n    prev = last_outage_ids\n    last_outage_ids = ids\n',
     '    ids = frozenset(str(x.get("id")) for x in (items or []) if x.get("id") is not None)\n    if globals().get("_wxo_skip", lambda i: False)(ids):  # wxSlot: Anlaufruhe -> Stand bleibt, spaeter wird verglichen und gesendet\n        return False\n    if last_outage_ids is None:\n        last_outage_ids = ids\n        globals().get("_wxo_keep", lambda i: None)(ids)  # wxSlot: Stand in Datei\n        return False\n    if ids == last_outage_ids:\n        globals().get("_wxo_keep", lambda i: None)(ids)  # wxSlot: Datei hoechstens stuendlich auffrischen\n        return False\n    prev = last_outage_ids\n    last_outage_ids = ids\n    globals().get("_wxo_keep", lambda i: None)(ids)  # wxSlot: Stand in Datei\n'),
    ('"alarm": _alarm_status(), "rel": _rw_status()})',
     '"alarm": _alarm_status(), "rel": _rw_status(), "wx": globals().get("_wx_status", lambda: None)()})'),
]
MK_RAE_EOF
EXPECT_RAB="cdc4e66b7d40d4dc11c48315449856bb077d0b2047693dc976a14659fed909b7"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== wxSlot: Wetter-Slot nachholen (Slot-Stunde HH:00-HH:59, 3-h-Takt), Stromausfall-Stand in Datei, Ergebnis je Slot im Journal und in /api/sysboot/status =====
# Wetter: laeuft ein Neustart/Ruhezeit ueber den Slot, wird er in der Slot-Stunde nachgeholt, wenn in mesh_weather_status.json KEIN Auto-Stempel im Slot steht
#         (nach der Ruhezeit, sofort wenn die Ruhezeit den Slot-Beginn ueberspannt). Je Slot 1 Versuch + 3 Wiederholungen im Abstand 120 s, nie doppelt (Sperre + Stempel).
#         Pegel und Heartbeat haengen wie bisher am erfolgreichen Auto-Wetter (darunterliegende Schichten unveraendert).
# Strom:  last_outage_ids steht in outage_mesh_state.json (atomar); nach dem Neustart wird verglichen (neu -> senden, offen -> leer -> Entwarnung),
#         in der Ruhezeit nur zurueckgestellt (nicht verworfen). Bestehende Regeln (Dedup 6 h, 3/h, Probe/Test nie ins Mesh, 2-h-Halt) bleiben in den Schichten darunter.
import threading as _wx_th
import time as _wx_time
import os as _wx_os
import json as _wx_json
import collections as _wx_col

WX_MAX_ATTEMPTS = 4      # 1. Versuch + 3 Wiederholungen
WX_RETRY_GAP = 120       # Sekunden zwischen den Versuchen (Bridge-Dublettensperre 120 s)
WX_TICK_S = 15           # Takt des Nachhol-Fadens
WX_FIRST_DELAY = 20      # Sekunden nach Slot-Beginn: davor hat der Wetter-Faden (:05) Vorrang
WXO_MAX_AGE = 86400      # gespeicherter Stromausfall-Stand gilt hoechstens 24 h
WXO_TOUCH_S = 3600       # unveraenderten Stand hoechstens stuendlich neu schreiben
_WX = {"slots": {}, "recent": _wx_col.deque(maxlen=12), "lock": _wx_th.RLock(), "ticks": 0, "err": None, "noted": {}, "thread": None, "installed": False}
_WXO = {"file": _wx_os.path.join(_wx_os.path.dirname(_wx_os.path.abspath(__file__)), "outage_mesh_state.json"), "loaded": None, "saved_ids": None, "saved_t": 0.0,
        "n_save": 0, "err": None, "err_t": 0.0, "skipped": 0, "quiet_noted": False}


def _wx_now():
    return now()


def _wx_slot_id(n):
    return n.replace(hour=n.hour - (n.hour % 3), minute=0, second=0, microsecond=0).strftime("%Y-%m-%d-%H")


def _wx_quiet():
    f = globals().get("_mbq_quiet")
    try:
        return bool(f()) if callable(f) else False
    except Exception:
        return False


def _wx_spans(n=None, t0=None):
    """True, wenn die Anlaufruhe (t0 .. t0+Ruhezeit) den Beginn der laufenden Slot-Stunde ueberspannt (Neustart kurz vor dem Slot)."""
    try:
        n = n or _wx_now()
        if n.hour % 3 != 0:
            return False
        t0 = globals()["_mbq_t0"] if t0 is None else t0
        s = n.replace(minute=0, second=0, microsecond=0).timestamp()
        return t0 <= s <= t0 + globals()["MESH_BOOT_QUIET_SEC"]
    except Exception:
        return False


def _wx_decide(hour, stamp_ok, st, now_ts, quiet, spans):
    """Reine Entscheidung fuer den laufenden Slot -> (Aktion, Grund). Aktion: off | done | wait | giveup | send."""
    if hour % 3 != 0:
        return "off", "keine Slot-Stunde"
    if stamp_ok:
        return "done", "Auto-Stempel im Slot"
    if quiet and not spans:
        return "wait", "Anlaufruhe"
    a = int(st.get("attempts") or 0)
    if a >= WX_MAX_ATTEMPTS:
        return "giveup", "%d Versuche ohne Erfolg" % a
    left = WX_RETRY_GAP - (now_ts - float(st.get("last_try") or 0))
    if a > 0 and left > 0:
        return "wait", "Wiederholung in %d s" % int(left + 0.999)
    return "send", ("erster Versuch" if a == 0 else "Wiederholung %d von %d" % (a, WX_MAX_ATTEMPTS - 1))


def _wx_log(slot, msg, key=None):
    if _WX.get("mute"):
        return
    if key is not None:
        if _WX["noted"].get(slot) == key:
            return
        _WX["noted"][slot] = key
    line = "wxSlot: Slot %s: %s" % (slot, msg)
    _WX["recent"].append("%s %s" % (_wx_time.strftime("%H:%M:%S"), line[8:]))
    print(line, flush=True)


def _wx_slot(slot):
    st = _WX["slots"].get(slot)
    if st is None:
        if len(_WX["slots"]) > 12:
            for k in sorted(_WX["slots"])[:-8]:
                _WX["slots"].pop(k, None)
        st = _WX["slots"][slot] = {"attempts": 0, "last_try": 0.0, "result": None, "t_result": None}
    return st


def _wx_make(prev, now_fn, ts_fn, stamp_fn, quiet_fn, spans_fn):
    """Huelle um maybe_mesh_weather: nur Auto-Aufrufe (force=False) in der Slot-Stunde werden gesteuert, alles andere geht 1:1 durch."""
    def maybe_mesh_weather(*a, **kw):  # wxSlot
        force = kw.get("force") is True or (len(a) > 0 and a[0] is True)
        if force:
            return prev(*a, **kw)
        try:
            n = now_fn()
            if n.hour % 3 != 0:
                return prev(*a, **kw)
        except Exception:
            return prev(*a, **kw)
        slot = _wx_slot_id(n)
        if not _WX["lock"].acquire(timeout=150):
            _wx_log(slot, "Sperre nicht frei (anderer Versand laeuft laenger als 150 s) - kein Versuch", "lock")
            return False
        try:
            st = _wx_slot(slot)
            ts = ts_fn()
            act, why = _wx_decide(n.hour, bool(stamp_fn(slot)), st, ts, bool(quiet_fn()), bool(spans_fn(n)))
            if act == "wait" and why == "Anlaufruhe":
                return prev(*a, **kw)
            if act == "done":
                if st["result"] is None:
                    st["result"], st["t_result"] = "Auto-Stempel vorhanden", ts
                    _wx_log(slot, "Auto-Stempel im Slot vorhanden - nichts zu senden", "stempel")
                return False
            if act == "giveup":
                if not str(st["result"] or "").startswith("aufgegeben"):
                    st["result"], st["t_result"] = "aufgegeben (%s)" % why, ts
                    _wx_log(slot, "NICHT gesendet - aufgegeben (%s)" % why)
                return False
            if act != "send":
                return False
            slot_start = n.replace(minute=0, second=0, microsecond=0).timestamp()
            r = prev(*a, **kw)
            st["attempts"] += 1
            st["last_try"] = ts_fn()
            if r:
                late = ts - slot_start
                st["result"] = ("gesendet (Versuch %d)" % st["attempts"]) if st["attempts"] == 1 and late <= 180 else "nachgeholt (Versuch %d, %d s nach Slot-Beginn)" % (st["attempts"], late)
                st["t_result"] = ts
                _wx_log(slot, st["result"])
            else:
                if st["attempts"] >= WX_MAX_ATTEMPTS:
                    st["result"], st["t_result"] = "aufgegeben (%d Versuche ohne Erfolg)" % st["attempts"], ts
                    _wx_log(slot, "NICHT gesendet - aufgegeben (%d Versuche ohne Erfolg)" % st["attempts"])
                else:
                    _wx_log(slot, "Versuch %d von %d fehlgeschlagen - naechster in %d s" % (st["attempts"], WX_MAX_ATTEMPTS, WX_RETRY_GAP))
            return r
        finally:
            _WX["lock"].release()
    maybe_mesh_weather.__dict__.update(getattr(prev, "__dict__", {}))
    maybe_mesh_weather.__wrapped__ = prev
    maybe_mesh_weather._wx = True
    return maybe_mesh_weather


def _wx_finalize(n):
    """Slots, die in dieser Laufzeit offen waren und deren Stunde vorbei ist: Ergebnis 'verpasst' (einmal)."""
    cur = _wx_slot_id(n) if n.hour % 3 == 0 else None
    for slot, st in list(_WX["slots"].items()):
        if st["result"] is None and slot != cur:
            st["result"], st["t_result"] = "verpasst (Slot-Stunde vorbei, kein Auto-Stempel)", _wx_time.time()
            _wx_log(slot, "NICHT gesendet - " + st["result"])


def _wx_tick(n=None):
    """Ein Takt des Nachhol-Fadens. Gibt die Aktion zurueck (fuer Tests)."""
    n = n or _wx_now()
    _WX["ticks"] += 1
    _wx_finalize(n)
    if n.hour % 3 != 0:
        return "off"
    slot = _wx_slot_id(n)
    ts = _wx_time.time()
    if ts - n.replace(minute=0, second=0, microsecond=0).timestamp() < WX_FIRST_DELAY:
        return "frueh"
    st = _wx_slot(slot)
    act, why = _wx_decide(n.hour, _mbq_stamp_in_slot(slot), st, ts, _wx_quiet(), _wx_spans(n))
    if act == "wait" and why == "Anlaufruhe":
        _wx_log(slot, "Auto-Stempel fehlt - wird nach der Anlaufruhe nachgeholt", "ruhe")
    elif act == "send":
        f = globals().get("maybe_mesh_weather")
        if callable(f):
            f(force=False)
    elif act == "done" or act == "giveup":
        f = globals().get("maybe_mesh_weather")
        if callable(f):
            f(force=False)  # Huelle traegt Ergebnis ein (kein Versand)
    return act


def _wx_loop():
    while True:
        try:
            _wx_tick()
        except Exception as e:
            if _WX["err"] != str(e)[:100]:
                print("wxSlot Takt:", e, flush=True)
            _WX["err"] = str(e)[:100]
        _wx_time.sleep(WX_TICK_S)


def _wx_status():
    """Fuer /api/sysboot/status (Schluessel 'wx'). Wirft nie."""
    try:
        n = _wx_now()
        slot = _wx_slot_id(n)
        st = _WX["slots"].get(slot) or {}
        q = 0
        try:
            q = max(0, int(globals()["_mbq_t0"] + globals()["MESH_BOOT_QUIET_SEC"] - _wx_time.time()))
        except Exception:
            pass
        th = _WX.get("thread")
        return {"v": 1, "installed": bool(_WX["installed"]), "slot": slot, "slot_stunde": n.hour % 3 == 0, "stempel_im_slot": bool(_mbq_stamp_in_slot(slot)),
                "versuche": st.get("attempts", 0), "ergebnis": st.get("result"), "ruhe_rest_s": q, "ruhe_ueberspannt_slot": bool(_wx_spans(n)),
                "faden": bool(th is not None and th.is_alive()), "takte": _WX["ticks"], "fehler": _WX["err"], "letzte": list(_WX["recent"]),
                "strom": {"datei": _wx_os.path.exists(_WXO["file"]), "geladen": _WXO["loaded"], "bekannt": (None if globals().get("last_outage_ids") is None else len(globals().get("last_outage_ids"))),
                          "gespeichert_vor_s": (int(_wx_time.time() - _WXO["saved_t"]) if _WXO["saved_t"] else None), "schreibvorgaenge": _WXO["n_save"], "zurueckgestellt": _WXO["skipped"], "fehler": _WXO["err"]}}
    except Exception as e:
        return {"v": 1, "fehler": str(e)[:100]}


# ---------------- Stromausfall-Stand ----------------
def _wxo_read(path, now_ts):
    """-> (frozenset | None, Grund). Datei fehlt/kaputt/zu alt -> None (dann gilt die erste Beobachtung wie bisher)."""
    try:
        with open(path) as f:
            d = _wx_json.load(f)
        ids = d.get("ids")
        t = float(d.get("t"))
        if not isinstance(ids, list):
            return None, "Format"
        if now_ts - t > WXO_MAX_AGE:
            return None, "zu alt (%d h)" % ((now_ts - t) // 3600)
        if t - now_ts > 3600:
            return None, "Zeitstempel in der Zukunft"
        return frozenset(str(x) for x in ids), "ok"
    except FileNotFoundError:
        return None, "keine Datei"
    except Exception as e:
        return None, "unlesbar (%s)" % type(e).__name__


def _wxo_write(path, ids, now_ts):
    tmp = "%s.tmp-%d-%d" % (path, _wx_os.getpid(), _wx_th.get_ident())
    try:
        with open(tmp, "w") as f:
            _wx_json.dump({"v": 1, "ids": sorted(ids), "n": len(ids), "t": now_ts}, f)
            f.flush()
            try:
                _wx_os.fsync(f.fileno())
            except Exception:
                pass
        _wx_os.replace(tmp, path)
        return True
    finally:
        try:
            if _wx_os.path.exists(tmp):
                _wx_os.unlink(tmp)
        except Exception:
            pass


def _wxo_keep(ids):
    """Stand in Datei halten (bei Aenderung sofort, sonst hoechstens stuendlich)."""
    try:
        ts = _wx_time.time()
        if _WXO["saved_ids"] == ids and ts - _WXO["saved_t"] < WXO_TOUCH_S:
            return
        _wxo_write(_WXO["file"], ids, ts)
        _WXO["saved_ids"], _WXO["saved_t"] = ids, ts
        _WXO["n_save"] += 1
        _WXO["err"] = None
    except Exception as e:
        _WXO["err"] = "%s: %s" % (type(e).__name__, str(e)[:60])
        if _wx_time.time() - _WXO["err_t"] > 600:
            _WXO["err_t"] = _wx_time.time()
            print("wxSlot Stromausfall-Stand nicht gespeichert:", _WXO["err"], flush=True)


def _wxo_skip(ids):
    """True in der Anlaufruhe: Abgleich zurueckstellen (Stand bleibt unveraendert, spaeter wird verglichen und gesendet)."""
    if _wx_quiet():
        _WXO["skipped"] += 1
        if not _WXO["quiet_noted"]:
            _WXO["quiet_noted"] = True
            print("wxSlot: Stromausfall-Abgleich in der Anlaufruhe zurueckgestellt (%d offene IDs jetzt, Stand aus Datei: %s) - danach wird verglichen" % (
                len(ids), "ja" if globals().get("last_outage_ids") is not None else "nein"), flush=True)
        return True
    return False


def _wxo_init():
    ts = _wx_time.time()
    ids, why = _wxo_read(_WXO["file"], ts)
    _WXO["loaded"] = why
    if ids is None:
        print("wxSlot: Stromausfall: kein gespeicherter Stand (%s) - die erste Beobachtung nach der Ruhezeit wird gespeichert, ohne zu senden" % why, flush=True)
        return None
    globals()["last_outage_ids"] = ids
    _WXO["saved_ids"] = ids
    try:
        _WXO["saved_t"] = float(_wx_json.load(open(_WXO["file"])).get("t") or 0)
    except Exception:
        _WXO["saved_t"] = ts
    f2 = globals().get("_fh2")
    if ids and isinstance(f2, dict) and isinstance(f2.get("strom"), dict):
        f2["strom"]["nonempty"] = True  # Entwarnung wie im Dauerbetrieb erst bei 2. leerer Abfrage
    print("wxSlot: Stromausfall-Stand aus Datei: %d offene IDs" % len(ids), flush=True)
    return ids


def _selftest_wxslot():
    import datetime as _d
    import shutil as _sh
    import tempfile as _tf
    D = _d.datetime
    # 1) Entscheidung
    s0 = {"attempts": 0, "last_try": 0.0}
    assert _wx_decide(14, False, s0, 1000.0, False, False)[0] == "off"
    assert _wx_decide(15, True, s0, 1000.0, False, False)[0] == "done"
    assert _wx_decide(15, False, s0, 1000.0, True, False) == ("wait", "Anlaufruhe")
    assert _wx_decide(15, False, s0, 1000.0, True, True)[0] == "send"
    assert _wx_decide(15, False, s0, 1000.0, False, False)[0] == "send"
    assert _wx_decide(15, False, {"attempts": 1, "last_try": 950.0}, 1000.0, False, False) == ("wait", "Wiederholung in 70 s")
    assert _wx_decide(15, False, {"attempts": 1, "last_try": 870.0}, 1000.0, False, False)[0] == "send"
    assert _wx_decide(15, False, {"attempts": WX_MAX_ATTEMPTS, "last_try": 0.0}, 1000.0, False, False)[0] == "giveup"
    assert _wx_decide(0, False, s0, 1000.0, False, False)[0] == "send" and _wx_decide(23, False, s0, 1000.0, False, False)[0] == "off"
    # 2) Stempel im Slot (Datei/Speicher)
    for stamp, slot, want in (("25.10.2026 15:00:05", "2026-10-25-15", True), ("25.10.2026 12:00:05", "2026-10-25-15", False), ("25.10.2026 17:59:59", "2026-10-25-15", True),
                              ("25.10.2026 18:00:00", "2026-10-25-15", False), ("kaputt", "2026-10-25-15", False), (None, "2026-10-25-15", False), ("26.10.2026 00:00:01", "2026-10-26-00", True)):
        assert _mbq_stamp_in_slot(slot, path="/nonexistent/x.json", mem=stamp) == want, (stamp, slot)
    d0 = _tf.mkdtemp(prefix="wx-st-")
    try:
        p0 = _wx_os.path.join(d0, "mesh_weather_status.json")
        open(p0, "w").write('{"auto": "25.10.2026 15:00:05", "manual": "23.10.2026 18:48:52"}')
        assert _mbq_stamp_in_slot("2026-10-25-15", path=p0, mem="") and not _mbq_stamp_in_slot("2026-10-25-18", path=p0, mem="")
        open(p0, "w").write("{kaputt")
        assert not _mbq_stamp_in_slot("2026-10-25-15", path=p0, mem="")
    finally:
        _sh.rmtree(d0, ignore_errors=True)
    # 3) Ruhezeit ueberspannt den Slot-Beginn
    t = lambda *x: D(*x).timestamp()
    assert _wx_spans(D(2026, 10, 25, 15, 0, 5), t(2026, 10, 25, 14, 59, 12))
    assert _wx_spans(D(2026, 10, 25, 15, 1, 0), t(2026, 10, 25, 14, 56, 0))
    assert not _wx_spans(D(2026, 10, 25, 15, 20, 0), t(2026, 10, 25, 15, 20, 0))
    assert not _wx_spans(D(2026, 10, 25, 15, 0, 5), t(2026, 10, 25, 15, 0, 3))
    assert not _wx_spans(D(2026, 10, 25, 14, 59, 30), t(2026, 10, 25, 14, 59, 12))
    # 4) Huelle mit Attrappen: Neustart HH:59, kein Doppelversand, Wiederholungen, Aufgeben, Stempel, force
    sent = []
    st = {"now": D(2026, 10, 25, 15, 0, 5), "stamp": set(), "quiet": True, "spans": True, "ok": [True]}
    clock = lambda: st["now"]
    ts = lambda: st["now"].timestamp()

    def prev(force=False):
        if not force and st["quiet"] and not st["spans"]:
            sent.append((st["now"], "ruhe", False))  # wie die Ruhezeit-Schicht: nichts senden
            return False
        ok = st["ok"].pop(0) if len(st["ok"]) > 1 else st["ok"][0]
        sent.append((st["now"], force, ok))
        if ok and not force:
            st["stamp"].add(_wx_slot_id(st["now"]))
        return ok
    w = _wx_make(prev, clock, ts, lambda s: s in st["stamp"], lambda: st["quiet"], lambda n: st["spans"])
    snap = dict(_WX["slots"])
    _WX["slots"].clear()
    _WX["mute"] = True
    try:
        assert w(force=False) is True and len(sent) == 1 and st["quiet"], "HH:59 -> sofort im Slot"
        assert w(force=False) is False and len(sent) == 1, "zweiter Aufruf (update_all) sendet nicht doppelt"
        assert "gesendet" in _WX["slots"]["2026-10-25-15"]["result"]
        # Neustart mitten im Slot, Ruhezeit laeuft: warten, danach nachholen
        sent.clear(); _WX["slots"].clear(); st.update(now=D(2026, 10, 25, 15, 20, 0), stamp=set(), quiet=True, spans=False, ok=[True])
        assert w(force=False) is False and sent == [(D(2026, 10, 25, 15, 20, 0), "ruhe", False)], "in der Ruhezeit geht der Aufruf nur nach unten, es wird nichts gesendet"
        assert not st["stamp"] and "2026-10-25-15" not in _WX["slots"] or _WX["slots"]["2026-10-25-15"]["attempts"] == 0
        sent.clear(); st["quiet"] = False
        assert w(force=False) is True and len(sent) == 1 and "nachgeholt" in _WX["slots"]["2026-10-25-15"]["result"], "nach der Ruhezeit wird nachgeholt"
        # Fehlschlaege: 120 s Abstand, 4 Versuche, dann aufgeben, nie ueber die Slot-Stunde
        sent.clear(); _WX["slots"].clear(); st.update(now=D(2026, 10, 25, 18, 0, 10), stamp=set(), quiet=False, spans=False, ok=[False])
        assert w(force=False) is False and len(sent) == 1
        st["now"] = D(2026, 10, 25, 18, 1, 0)
        assert w(force=False) is False and len(sent) == 1, "vor 120 s keine Wiederholung"
        for mm, ss in ((2, 15), (4, 30), (6, 45)):
            st["now"] = D(2026, 10, 25, 18, mm, ss)
            w(force=False)
        assert len(sent) == 4, len(sent)
        st["now"] = D(2026, 10, 25, 18, 9, 0)
        w(force=False)
        assert len(sent) == 4 and _WX["slots"]["2026-10-25-18"]["result"].startswith("aufgegeben"), "nach 4 Versuchen Schluss"
        # Wiederholung klappt
        sent.clear(); _WX["slots"].clear(); st.update(now=D(2026, 10, 25, 21, 0, 10), stamp=set(), ok=[False, True])
        assert w(force=False) is False
        st["now"] = D(2026, 10, 25, 21, 2, 30)
        assert w(force=False) is True and len(sent) == 2 and "Versuch 2" in _WX["slots"]["2026-10-25-21"]["result"]
        # Stempel da: nie senden; Nicht-Slot-Stunde und force gehen durch
        sent.clear(); _WX["slots"].clear(); st.update(now=D(2026, 10, 25, 12, 30, 0), stamp={"2026-10-25-12"}, ok=[True])
        assert w(force=False) is False and not sent
        st["now"] = D(2026, 10, 25, 13, 30, 0)
        assert w(force=False) is True and len(sent) == 1 and sent[0][1] is False
        sent.clear()
        assert w(force=True) is True and sent[0][1] is True
        # Folgeslot ohne Stempel, Slot-Stunde vorbei -> verpasst, nie spaeter nachgeholt
        _WX["slots"].clear(); st.update(now=D(2026, 10, 25, 15, 5, 0), stamp=set(), quiet=True, spans=False, ok=[True])
        _wx_slot("2026-10-25-15")
        _wx_finalize(D(2026, 10, 25, 16, 0, 5))
        assert _WX["slots"]["2026-10-25-15"]["result"].startswith("verpasst")
    finally:
        _WX["mute"] = False
        _WX["slots"].clear()
        _WX["slots"].update(snap)
    # 5) Stromausfall-Stand: Rundlauf, Alter, kaputt, atomar
    d1 = _tf.mkdtemp(prefix="wx-ou-")
    try:
        pf = _wx_os.path.join(d1, "outage_mesh_state.json")
        assert _wxo_read(pf, 5000.0) == (None, "keine Datei")
        _wxo_write(pf, frozenset({"b", "a", "7"}), 4000.0)
        assert _wxo_read(pf, 5000.0) == (frozenset({"a", "b", "7"}), "ok")
        assert _wxo_read(pf, 4000.0 + WXO_MAX_AGE + 1)[0] is None and _wxo_read(pf, 100.0)[0] is None
        _wxo_write(pf, frozenset(), 4500.0)
        assert _wxo_read(pf, 5000.0) == (frozenset(), "ok"), "leerer Stand ist ein gueltiger Stand"
        open(pf, "w").write("{kaputt")
        assert _wxo_read(pf, 5000.0)[0] is None
        open(pf, "w").write('{"ids": "x", "t": 4000}')
        assert _wxo_read(pf, 5000.0)[0] is None
        assert [x for x in _wx_os.listdir(d1) if ".tmp-" in x] == [], "keine Temp-Reste"
    finally:
        _sh.rmtree(d1, ignore_errors=True)
    return "wxSlot ok (Slot-Entscheidung, Stempel im Slot, HH:59 sofort, Nachholen nach Ruhezeit, 4 Versuche/120 s, kein Doppelversand, Stromausfall-Stand atomar)"


try:
    _WX_ST = _selftest_wxslot()
except Exception as _wx_e:
    _WX_ST = None
    print("wxSlot Selbsttest FEHLER (%s)" % _wx_e, flush=True)
if _WX_ST:
    try:
        _wx_prev = globals().get("maybe_mesh_weather")
        if callable(_wx_prev) and not getattr(_wx_prev, "_wx", False):
            globals()["maybe_mesh_weather"] = _wx_make(_wx_prev, _wx_now, _wx_time.time, _mbq_stamp_in_slot, _wx_quiet, _wx_spans)
            _WX["installed"] = True
        _wxo_init()
        if __name__ == "__main__":
            _WX["thread"] = _wx_th.Thread(target=_wx_loop, daemon=True, name="wxSlot")
            _WX["thread"].start()
        _wx_n = _wx_now()
        if _wx_n.hour % 3 != 0 and not _mbq_stamp_in_slot(_wx_slot_id(_wx_n)):
            print("wxSlot: letzter Slot %s ohne Auto-Stempel und die Slot-Stunde ist vorbei - nicht nachholbar (naechster Slot normal)" % _wx_slot_id(_wx_n), flush=True)
        print("wxSlot aktiv: %s" % _WX_ST, flush=True)
    except Exception as _wx_e2:
        print("wxSlot Selbsttest FEHLER (Einbau: %s)" % _wx_e2, flush=True)
# ===== /wxSlot =====
MK_RAB_EOF
EXPECT_RAG="5a1324a0eb43e0cee21c141f5a710ca15d23fbc308a5e0303df817d5e0366eff"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-/Verhaltens-Guard wxSlot (nur dashboard.py: 7 Stellen + Block wxSlot). Aufruf:
  guard_wx.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne wxSlot (Rueckbau, byte-genau)
  guard_wx.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhaltenstests (Entscheidungstabelle, Stempel im Slot, Wetter-Huelle mit Attrappen,
                                                           Stromausfall-Stand/Abgleich mit der echten Funktion) - ohne node, ohne Netz, ohne Dienste
  RH_ALT=ALT_VERZ guard_wx.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest"""
import ast
import contextlib
import datetime as dtm
import io
import json
import os
import shutil
import sys
import tempfile
import time

FORBID = ("subprocess", "requests", "urlopen", "socket", "Popen", "os.system", "send_meshtastic", "eval(", "exec(", "__import__", "curl", "sudo", "systemctl")
BLOCK_NODES = ["Import:", "Import:", "Import:", "Import:", "Import:"] + ["Assign:"] * 8 + [
    "FunctionDef:" + x for x in ("_wx_now", "_wx_slot_id", "_wx_quiet", "_wx_spans", "_wx_decide", "_wx_log", "_wx_slot", "_wx_make", "_wx_finalize", "_wx_tick",
                                  "_wx_loop", "_wx_status", "_wxo_read", "_wxo_write", "_wxo_keep", "_wxo_skip", "_wxo_init", "_selftest_wxslot")] + ["Try:", "If:"]
OPEN_OK = {"_wxo_read", "_wxo_write", "_wxo_init", "_selftest_wxslot"}
CHANGED = ["_MBQ_WX_STATUS", "_mbq_q_weather", "_mbq_stamp_in_slot", "_mbq_wrap", "_sb_api_status", "maybe_mesh_stromausfall"]


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block wxSlot nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle wxSlot nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def fn_node(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def check_block_text(B):
    t = ast.parse(B)
    kinds = [type(n).__name__ + ":" + getattr(n, "name", "") for n in t.body]
    assert kinds == BLOCK_NODES, "Blockaufbau weicht ab: %s" % [k for k in kinds if k not in BLOCK_NODES]
    for w in FORBID:
        assert w not in B, "Block enthaelt verbotenes Wort: " + w
    for n in t.body:
        for x in ast.walk(n):
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Name) and x.func.id in ("eval", "exec", "__import__", "compile"):
                raise AssertionError("Block ruft " + x.func.id)
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Name) and x.func.id == "open" and getattr(n, "name", "") not in OPEN_OK:
                raise AssertionError("open() ausserhalb der erlaubten Funktionen: " + getattr(n, "name", "?"))
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Attribute) and x.func.attr in ("system", "popen", "kill", "remove", "rmdir") and getattr(n, "name", "") != "_wxo_write" :
                raise AssertionError("Block ruft " + x.func.attr)
    assert B.splitlines()[0].startswith("# ===== wxSlot:") and B.rstrip().splitlines()[-1] == "# ===== /wxSlot =====", "Block ohne Marker"
    consts = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Constant):
            consts[n.targets[0].id] = n.value.value
    assert consts.get("WX_MAX_ATTEMPTS") == 4 and consts.get("WX_RETRY_GAP") == 120 and consts.get("WXO_MAX_AGE") == 86400, "Konstanten weichen von der Vorgabe ab: %s" % consts
    assert 5 <= consts.get("WX_TICK_S", 0) <= 30 and 10 <= consts.get("WX_FIRST_DELAY", 0) <= 60, "Takt/Vorrang des Wetter-Fadens unplausibel"


def static(alt, new, blk, edits):
    n = 0
    B = rd(blk).rstrip("\n")
    check_block_text(B)
    assert new.count("\n\n" + B + "\n\nif __name__ == \"__main__\":\n") == 1, "Block nicht direkt vor dem __main__-Block"
    n += 2
    assert len(edits) == 7, "erwartet genau 7 Stellen"
    for o, nw in edits:
        assert alt.count(o) == 1, "Stelle nicht genau einmal im alten Stand"
    n += 1
    bs = new.count("\n", 0, new.index(B)) + 1
    be = bs + B.count("\n")
    ta, tn = ast.parse(alt), ast.parse(new)
    N = [x for x in tn.body if not (bs <= x.lineno <= be)]
    assert len(tn.body) - len(N) == len(BLOCK_NODES), "Block hat nicht %d Knoten" % len(BLOCK_NODES)
    da = {ast.dump(x) for x in ta.body}
    ch = sorted((getattr(x, "name", None) or (x.targets[0].id if isinstance(x, ast.Assign) else "?")) for x in N if ast.dump(x) not in da)
    assert ch == sorted(CHANGED), "geaenderte/neue Knoten ausserhalb des Blocks: %s" % ch
    dn = {ast.dump(x) for x in N}
    gone = [getattr(x, "name", "?") for x in ta.body if ast.dump(x) not in dn]
    assert sorted(gone) == sorted(x for x in CHANGED if x not in ("_MBQ_WX_STATUS", "_mbq_stamp_in_slot")), "entfallene Knoten: %s" % gone
    n += 3
    # Stromausfall: genau je ein Haken an der richtigen Stelle
    f = fn_node(tn, "maybe_mesh_stromausfall")
    src = ast.unparse(f)
    assert src.count("_wxo_skip") == 1 and src.count("_wxo_keep") == 3, "Haken in maybe_mesh_stromausfall: skip %d keep %d" % (src.count("_wxo_skip"), src.count("_wxo_keep"))
    st = f.body[1:]  # nach Docstring
    kinds = [ast.unparse(x).splitlines()[0][:48] for x in st[:4]]
    assert kinds[0] == "global last_outage_ids" and kinds[1].startswith("ids = frozenset(") and "_wxo_skip" in ast.unparse(st[2]) and kinds[3].startswith("if last_outage_ids is None"), "Reihenfolge in maybe_mesh_stromausfall: %s" % kinds
    assert "send_meshtastic" in src and "build_mesh_strom_d" in src
    n += 3
    # meshBootQuiet: Huelle und Wetter-Markierung
    w = ast.unparse(fn_node(tn, "_mbq_wrap"))
    assert w.count("_wx_spans") == 1 and "name == 'maybe_mesh_weather' and" in w, "Huelle: Umgehung nur fuer das Wetter und nur ueber _wx_spans"
    q = ast.unparse(fn_node(tn, "_mbq_q_weather"))
    assert q.index("_mbq_stamp_in_slot(slot)") < q.index("wx_done"), "wx_done wird vor der Stempel-Pruefung gesetzt"
    sbs = ast.unparse(fn_node(tn, "_sb_api_status"))
    assert "'wx'" in sbs and "_wx_status" in sbs
    n += 3
    return n


# ---------- Verhaltenstests ----------
def now_fn(h, m, s=0):
    return lambda: dtm.datetime(2026, 10, 25, h, m, s)


def mk_ns(new, tmp, clock, quiet=False, with_weather=False):
    """Namensraum mit den echten Funktionen (Stempel, Weiterleitung, Stromausfall) aus dem NEUEN Programm und Attrappen fuer den Rest."""
    tree = ast.parse(new)
    pick = []
    for x in tree.body:
        if (isinstance(x, ast.FunctionDef) and x.name in ("_mbq_stamp_in_slot", "_mbq_q_weather", "maybe_mesh_stromausfall")) or (isinstance(x, ast.Assign) and getattr(x.targets[0], "id", "") == "_MBQ_WX_STATUS"):
            pick.append(x)
    sent = []
    g = {"__name__": "dash_test", "__file__": os.path.join(tmp, "dashboard.py"), "_mbq_json": json, "now": clock, "_mbq_quiet": lambda: quiet,
         "_mbq_t0": 0, "MESH_BOOT_QUIET_SEC": 300, "last_outage_ids": None, "last_mesh_weather_auto": None, "sent": sent,
         "send_meshtastic": lambda t: (sent.append(t) or True), "build_mesh_strom_b": lambda i: "B", "build_mesh_strom_c": lambda i, n: "C%d" % n,
         "build_mesh_strom_d": lambda: "D", "build_mesh_strom_e": lambda i: "E", "_mbq_state": {"wx_done": set()},
         "_mbq_slot_now": lambda: clock().replace(hour=clock().hour - clock().hour % 3, minute=0, second=0, microsecond=0).strftime("%Y-%m-%d-%H")}
    exec(compile(ast.Module(body=pick, type_ignores=[]), "dash", "exec"), g)
    g["_MBQ_WX_STATUS"] = os.path.join(tmp, "mesh_weather_status.json")
    return g


def run_block(B, g):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(B, "blk", "exec"), g)
    return buf.getvalue()


def behav(alt, new, blk):
    B = rd(blk)
    tmp = tempfile.mkdtemp(prefix="wx-guard-")
    n = 0
    try:
        # --- A: Stempel im Slot (echte Funktion aus dem neuen Programm) ---
        g = mk_ns(new, tmp, now_fn(15, 20))
        stf = g["_MBQ_WX_STATUS"]

        def put(v):
            with open(stf, "w") as f:
                json.dump({"auto": v, "manual": "23.10.2026 18:48:52"}, f)
        S = "2026-10-25-15"
        put("25.10.2026 15:00:05"); assert g["_mbq_stamp_in_slot"](S) is True, "Stempel 15:00:05 zaehlt nicht fuer Slot 15"
        put("25.10.2026 12:00:05"); assert g["_mbq_stamp_in_slot"](S) is False, "Stempel 12:00:05 zaehlt faelschlich fuer Slot 15"
        put("25.10.2026 14:59:59"); assert g["_mbq_stamp_in_slot"](S) is False, "Stempel 14:59:59 zaehlt faelschlich fuer Slot 15"
        put("24.10.2026 15:00:05"); assert g["_mbq_stamp_in_slot"](S) is False, "Stempel von gestern zaehlt faelschlich"
        os.unlink(stf); assert g["_mbq_stamp_in_slot"](S) is False, "ohne Datei und ohne Speicherstand muss False kommen"
        assert g["_mbq_stamp_in_slot"](S, mem="25.10.2026 15:00:06") is True, "Speicherstand im Slot zaehlt nicht"
        with open(stf, "w") as f:
            f.write("{kaputt")
        assert g["_mbq_stamp_in_slot"](S) is False, "kaputte Datei muss False geben (kein Wurf)"
        n += 7
        # --- B: meshBootQuiet markiert den Slot nur mit Stempel ---
        for stamp, expect in (("25.10.2026 12:00:05", False), ("25.10.2026 15:00:05", True)):
            g = mk_ns(new, tmp, now_fn(15, 20))
            put(stamp)
            g["maybe_mesh_weather"] = type("F", (), {})()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                g["_mbq_q_weather"]()
            got = S in g["_mbq_state"]["wx_done"]
            assert got is expect and (getattr(g["maybe_mesh_weather"], "_last_slot", None) == S) is expect, "meshBootQuiet: Slot erledigt=%s bei Stempel %s (erwartet %s)" % (got, stamp, expect)
        n += 2
        # --- C: Block im Namensraum: Selbsttest, Einbau, Entscheidungstabelle ---
        g = mk_ns(new, tmp, now_fn(15, 20))
        base_calls = []
        g["maybe_mesh_weather"] = lambda *a, **k: base_calls.append(1) or True
        o = run_block(B, g)
        assert "wxSlot aktiv: wxSlot ok" in o and "FEHLER" not in o, "Block-Selbsttest im sauberen Namensraum: " + o[:200]
        assert getattr(g["maybe_mesh_weather"], "_wx", False) is True, "Huelle nicht eingebaut"
        n += 2
        D = g["_wx_decide"]
        st0 = {"attempts": 0, "last_try": 0.0}
        T = 1000000.0
        cases = [((14, True, st0, T, False, False), "off"), ((15, True, st0, T, False, False), "done"), ((15, False, st0, T, True, False), "wait"),
                 ((15, False, st0, T, True, True), "send"), ((15, False, st0, T, False, False), "send"),
                 ((15, False, {"attempts": 1, "last_try": T - 10}, T, False, False), "wait"), ((15, False, {"attempts": 1, "last_try": T - 121}, T, False, False), "send"),
                 ((15, False, {"attempts": 3, "last_try": T - 121}, T, False, False), "send"), ((15, False, {"attempts": 4, "last_try": T - 500}, T, False, False), "giveup"),
                 ((0, False, st0, T, False, False), "send"), ((21, False, st0, T, False, False), "send"), ((22, False, st0, T, False, False), "off"), ((23, True, st0, T, False, False), "off")]
        for a, want in cases:
            got = D(*a)[0]
            assert got == want, "Entscheidung %s: %s statt %s" % (a[:2] + a[3:], got, want)
        n += len(cases)
        # --- D: Huelle mit Attrappen: Neustart um HH:59 / mitten im Slot / Fehlschlag / kein Doppelversand / force ---
        class Clk:
            t = 0.0
        wx = g["_wx_make"]
        calls = []
        res = {"ok": True}

        def prev(*a, **k):
            calls.append((a, k))
            return res["ok"]
        cur = {"n": dtm.datetime(2026, 10, 25, 15, 0, 5), "stamp": False, "quiet": False, "spans": False}
        ts = {"t": cur["n"].timestamp()}
        g["_WX"]["mute"] = True
        g["_WX"]["slots"].clear()

        def mkw():
            return wx(prev, lambda: cur["n"], lambda: ts["t"], lambda s: cur["stamp"], lambda: cur["quiet"], lambda n: cur["spans"])
        w = mkw()
        cur.update(quiet=True, spans=True)  # Neustart um HH:59: Ruhezeit ueberspannt den Slot-Beginn -> sofort senden
        assert w(force=False) is True and len(calls) == 1, "HH:59-Neustart: Wetter nicht sofort gesendet"
        cur["stamp"] = True
        assert w(force=False) is False and len(calls) == 1, "Doppelversand trotz Stempel"
        cur.update(stamp=False, quiet=True, spans=False)  # neuer Slot, Ruhezeit laeuft (Neustart mitten im Slot)
        cur["n"] = dtm.datetime(2026, 10, 25, 18, 10, 0); ts["t"] = cur["n"].timestamp(); w = mkw(); calls.clear()
        w(force=False)
        assert calls and w.__wrapped__ is prev, "in der Ruhezeit wird nach unten durchgereicht (dort schweigt meshBootQuiet), nicht selbst gesendet"
        calls.clear(); cur["quiet"] = False  # Ruhezeit vorbei -> nachholen, genau einmal
        assert w(force=False) is True and len(calls) == 1, "Nachholen nach der Ruhezeit"
        cur["stamp"] = True
        assert w(force=False) is False and len(calls) == 1, "zweites Senden im Slot"
        cur.update(stamp=False); cur["n"] = dtm.datetime(2026, 10, 25, 21, 0, 30); ts["t"] = cur["n"].timestamp(); w = mkw(); calls.clear()
        res["ok"] = False
        assert not w(force=False) and len(calls) == 1
        assert not w(force=False) and len(calls) == 1, "Wiederholung vor 120 s"
        for i in range(3):
            ts["t"] += 121
            assert not w(force=False)
        assert len(calls) == 4, "genau 4 Versuche erwartet, waren %d" % len(calls)
        ts["t"] += 121
        w(force=False); assert len(calls) == 4, "5. Versuch"
        cur["n"] = dtm.datetime(2026, 10, 25, 22, 5, 0)  # Stunde ausserhalb des Slots: durchreichen, nie selbst steuern
        calls.clear(); w(force=False); assert len(calls) == 1, "Stunde ausserhalb des Slots: nicht durchgereicht"
        res["ok"] = True; calls.clear(); cur["n"] = dtm.datetime(2026, 10, 25, 21, 30, 0); cur["quiet"] = True
        w(force=True); assert len(calls) == 1, "force wird nicht durchgereicht"
        cur["stamp"] = True; calls.clear()
        w(force=True); assert len(calls) == 1, "force bei vorhandenem Stempel (manuelles Senden) wird gesteuert statt durchgereicht"
        w(True); assert len(calls) == 2, "force als Positionsargument wird nicht durchgereicht"
        n += 10
        # --- E: Stromausfall mit der echten Funktion ---
        def strom(pre_ids, quiet_now, steps, age=600):
            d = tempfile.mkdtemp(prefix="wx-s-", dir=tmp)
            gg = mk_ns(new, d, now_fn(13, 36), quiet=quiet_now)
            gg["_fh2"] = {"strom": {"nonempty": False}}
            if pre_ids is not None:
                with open(os.path.join(d, "outage_mesh_state.json"), "w") as f:
                    json.dump({"v": 1, "ids": pre_ids, "n": len(pre_ids), "t": time.time() - age}, f)
            o2 = run_block(B, gg)
            assert "wxSlot aktiv" in o2, o2[:200]
            assert gg["_fh2"]["strom"]["nonempty"] is bool(pre_ids and age < 86400), "Entwarnung nach Neustart: _fh2['strom']['nonempty'] falsch (%s)" % gg["_fh2"]
            outs = []
            for q, items in steps:
                gg["_mbq_quiet"] = (lambda v=q: v)
                with contextlib.redirect_stdout(io.StringIO()):
                    gg["maybe_mesh_stromausfall"](items)
                outs.append((list(gg["sent"]), None if gg["last_outage_ids"] is None else sorted(gg["last_outage_ids"])))
                del gg["sent"][:]
            fl = os.path.join(d, "outage_mesh_state.json")
            saved = json.load(open(fl))["ids"] if os.path.exists(fl) else None
            assert not [x for x in os.listdir(d) if ".tmp-" in x], "Rest einer Zwischendatei"
            return outs, saved
        I = lambda *ids: [{"id": i, "local": False} for i in ids]
        o, sv = strom(["1", "2", "3", "4"], True, [(True, []), (False, [])])
        assert o[0] == ([], ["1", "2", "3", "4"]), "Ruhezeit: Stand verworfen/gesendet: %s" % (o[0],)
        assert o[1][0] == ["D"] and sv == [], "Entwarnung nach Neustart (offen -> leer) nicht gesendet: %s / %s" % (o[1], sv)
        o, sv = strom(["1"], True, [(True, I("1", "2")), (False, I("1", "2"))])
        assert o[0][0] == [] and o[1][0] == ["B"] and sv == ["1", "2"], "neuer Ausfall nach Neustart: %s / %s" % (o, sv)
        o, sv = strom(["1", "2"], False, [(False, I("1", "2"))])
        assert o[0][0] == [] and sv == ["1", "2"], "gleicher Stand sendet: %s" % (o,)
        o, sv = strom(["1"], False, [(False, I("1"))], age=100000)
        assert o[0][0] == [] and o[0][1] == ["1"], "uralter Stand (> 24 h) darf nichts senden"
        o, sv = strom(None, True, [(True, I("1")), (False, I("1"))])
        assert o[0] == ([], None) and o[1][0] == [] and sv == ["1"], "ohne Datei: erste Beobachtung nur speichern: %s / %s" % (o, sv)
        o, sv = strom(["1", "2"], False, [(False, I("1", "2", "3", "4"))])
        assert o[0][0] == ["C2"] and sv == ["1", "2", "3", "4"], "mehrere neue: %s" % (o,)
        n += 6
        # --- F: Selbsttest erkennt eine kaputte Umgebung ---
        g2 = mk_ns(new, tmp, now_fn(15, 20))
        g2["_wx_quiet"] = None
        g2["now"] = lambda: (_ for _ in ()).throw(RuntimeError("x"))
        o = run_block(B, g2)
        assert "FEHLER" in o and "aktiv" not in o, "Selbsttest erkennt kaputte Uhr nicht: " + o[:160]
        n += 1
        g3 = mk_ns(new, tmp, now_fn(15, 20))
        real_json = sys.modules["json"]
        broken = type(sys)("json")
        broken.load = broken.dump = lambda *a, **k: (_ for _ in ()).throw(ValueError("kaputt"))
        sys.modules["json"] = broken
        try:
            o = run_block(B, g3)
        finally:
            sys.modules["json"] = real_json
        assert "wxSlot Selbsttest FEHLER (" in o and "aktiv" not in o, "ein fehlgeschlagener Selbsttest wird nicht gemeldet: " + o[:160]
        assert getattr(g3.get("maybe_mesh_weather"), "_wx", False) is not True, "Einbau trotz Selbsttest-Fehler"
        n += 2
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_WX_NOSTATIC") == "1" else static(alt, new, blk, edits)
    if os.environ.get("RH_WX_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk)
    print("OK guard wxSlot: %d Pruefungen, 0 fehlerhaft" % n)
    return n


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    B = rd(blk).rstrip("\n")
    edits, anch = load_edits(ep)
    pre, post = base_new[:base_new.index(B)], base_new[base_new.index(B):]

    def rep(s, a, b):
        assert s.count(a) == 1, "%s: %d" % (a[:60], s.count(a))
        return s.replace(a, b, 1)
    M = []  # (Name, neu, block, norev)
    for i, nm in enumerate(["Kommentar Wetter", "Huelle meshBootQuiet", "Kommentar Stempel", "_mbq_q_weather", "Kommentar install", "maybe_mesh_stromausfall", "sysboot-Status"]):
        if i in (0, 2, 4):
            continue
        M.append(("M%d Edit %s zurueckgenommen" % (i, nm), rep(pre, edits[i][1], edits[i][0]) + post, B, 1))
    M.append(("M10 Huelle: Umgehung fuer alle Funktionen", rep(pre, 'name == "maybe_mesh_weather" and globals().get("_wx_spans"', 'globals().get("_wx_spans"') + post, B, 1))
    M.append(("M11 Slot sofort erledigt (Stempelpruefung weg)", rep(pre, "        if not _mbq_stamp_in_slot(slot):  # wxSlot", "        if False:  # wxSlot") + post, B, 1))
    M.append(("M12 Stempel: Slot ignoriert", rep(pre, "strftime(\"%Y-%m-%d-%H\") == slot:\n                return True", "strftime(\"%Y-%m-%d-%H\") != slot:\n                return True") + post, B, 1))
    M.append(("M13 Stempel: Stunde nicht auf 3 h gerundet", rep(pre, "t.replace(hour=t.hour - (t.hour % 3), minute=0", "t.replace(hour=t.hour, minute=0") + post, B, 1))
    M.append(("M14 Stromausfall: skip-Haken ohne Rueckgabe", rep(pre, "(ids):  # wxSlot: Anlaufruhe -> Stand bleibt, spaeter wird verglichen und gesendet\n        return False", "(ids):  # wxSlot: Anlaufruhe -> Stand bleibt, spaeter wird verglichen und gesendet\n        pass") + post, B, 1))
    M.append(("M15 stille Zusatzaenderung", rep(pre, "def _fnum(x):\n", "def _fnum(x): \n") + post, B, 0))
    for nm, a, b in (("B1 Versuche 40", "WX_MAX_ATTEMPTS = 4 ", "WX_MAX_ATTEMPTS = 40 "),
                     ("B2 Abstand 0", "WX_RETRY_GAP = 120 ", "WX_RETRY_GAP = 0 "),
                     ("B3 Slot-Stunde ignoriert", '    if hour % 3 != 0:\n        return "off", "keine Slot-Stunde"\n', ""),
                     ("B4 Stempel zaehlt nicht", '    if stamp_ok:\n        return "done", "Auto-Stempel im Slot"\n', ""),
                     ("B5 Ruhezeit ohne Ueberspannung sendet", "    if quiet and not spans:\n", "    if False:\n"),
                     ("B6 Ruhezeit-Ueberspannung ignoriert", "    if quiet and not spans:\n", "    if quiet:\n"),
                     ("B7 Wiederholung ohne Wartezeit", "    if a > 0 and left > 0:\n", "    if False:\n"),
                     ("B8 force wird gesteuert", '        if force:\n            return prev(*a, **kw)\n', ""),
                     ("B9 Sperre fehlt", "        if not _WX[\"lock\"].acquire(timeout=150):", "        if False:"),
                     ("B10 Alter des Stands nicht geprueft", "        if now_ts - t > WXO_MAX_AGE:", "        if False:"),
                     ("B11 Stand nicht atomar", "        _wx_os.replace(tmp, path)\n", "        _wx_os.rename(tmp, path)\n        open(path, 'w').write('x')\n"),
                     ("B12 Entwarnung ohne 2. Abfrage nicht vorbereitet", '        f2["strom"]["nonempty"] = True', "        pass"),
                     ("B13 skip sendet nie als Ruhezeit", "    if _wx_quiet():\n        _WXO[\"skipped\"] += 1", "    if False:\n        _WXO[\"skipped\"] += 1"),
                     ("B14 Block mit subprocess", "def _wx_now():\n", "import subprocess\n\n\ndef _wx_now():\n"),
                     ("B15 Block ohne Ende-Marker", "# ===== /wxSlot =====", ""),
                     ("B16 Selbsttest schluckt Fehler still", '    print("wxSlot Selbsttest FEHLER (%s)" % _wx_e, flush=True)\n', "    pass\n"),
                     ("B17 Erfolg wird nicht verbucht", '                st["result"] = ("gesendet', '                st["resultx"] = ("gesendet'),
                     ("B18 Stand wird bei Aenderung nicht geschrieben", '        if _WXO["saved_ids"] == ids and ts - _WXO["saved_t"] < WXO_TOUCH_S:\n            return\n', "        return\n"),
                     ("B19 Stand zu alt wird geladen", "        if t - now_ts > 3600:", "        if now_ts < 0:")):
        assert B.count(a) == 1, nm + " (%d)" % B.count(a)
        nb = B.replace(a, b)
        M.append((nm, pre + nb + post[len(B):], nb, 1))
    bad = []
    done = 0
    for name, mnew, mblk, norev in M:
        w = tempfile.mkdtemp(prefix="wx-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(mnew)
            bf = os.path.join(w, "blk.py")
            with open(bf, "w", encoding="utf-8") as f:
                f.write(mblk if mblk.endswith("\n") else mblk + "\n")
            if norev:
                os.environ["RH_WX_NOREV"] = "1"
            else:
                os.environ.pop("RH_WX_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, bf, ep)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            os.environ.pop("RH_WX_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)

    def edmut(name, fn):
        nonlocal done
        e2 = fn([tuple(x) for x in edits])
        w = tempfile.mkdtemp(prefix="wx-mut-")
        try:
            ef = os.path.join(w, "edits.py")
            with open(ef, "w", encoding="utf-8") as f:
                f.write("DSH_ANCHOR = %r\nDSH_EDITS = %r\n" % (anch, e2))
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new)
            os.environ.pop("RH_WX_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, blk, ef)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            shutil.rmtree(w, ignore_errors=True)
    edmut("E1 eine Stelle fehlt", lambda e: e[1:])
    edmut("E2 Stelle mit falschem Alttext (Rueckbau ungenau)", lambda e: [(e[0][0] + "# x\n", e[0][1])] + e[1:])
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation wxSlot: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
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
        print("guard wxSlot FEHLER: %s" % e)
        sys.exit(1)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach secXmlDash commit33" "$KNOWN_D16N" "wxSlot schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      wxSlot passt nur auf den Stand Stand nach secXmlDash commit33 (dashboard.py 1574109c8609cf26). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash meshBootQuiet funkHarden2 kartevec; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- wxSlot: Neustart-Fenster rund um die Wetter-Slots (3-h-Takt 0,3,...,21 Uhr, Berlin) ----
# Gesperrt: HH:55-HH:59 jeder Stunde vor einem Slot (z. B. 14:55-14:59), die ersten 5 Minuten der Slot-Stunde (15:00-15:04) und HH:55-HH:59 der Slot-Stunde selbst.
# (Neustart um HH:59 kann die Slot-Meldung verzoegern; wxSlot holt sie dann nach, aber der Apply soll nie selbst in dieses Fenster fallen.)
wxwin() { local s=$1 h m r; h=$(( s / 3600 % 24 )); m=$(( s / 60 % 60 )); r=$(( h % 3 ))
  if [[ $r == 2 && $m -ge 55 ]]; then return 0; fi
  if [[ $r == 0 && ( $m -lt 5 || $m -ge 55 ) ]]; then return 0; fi
  return 1; }
wxsec() { local hm
  if [[ -n "${WXSLOT_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$WXSLOT_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) + $1 )); }
wxfree() { local k s; for k in $(seq 0 240); do s=$(wxsec $(( k * 60 ))); wxwin "$s" || { printf '%02d:%02d' $(( s / 3600 % 24 )) $(( s / 60 % 60 )); return; }; done; echo "?"; }
wxcheck() { local when=$1 s0 s1
  s0=$(wxsec 0); s1=$(wxsec 150)
  if wxwin "$s0" || wxwin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Fenster: jetzt ($when, Berlin-Zeit $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 )))) waere ein echter Lauf gesperrt (Slot-Zeit des Wetters) - frei ab ca. $(wxfree) Uhr; der Trockenlauf aendert nichts"
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Fenster: wxSlot ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Fenster: es ist $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 ))) Uhr (Berlin) - kurz vor/in/nach einer 3-h-Wetter-Slot-Zeit (0,3,...,21 Uhr; gesperrt HH:55-HH:04 um die Slots und HH:55-HH:59 der Slot-Stunde). Ein Neustart jetzt koennte die Slot-Meldung verzoegern. Bitte ab ca. $(wxfree) Uhr neu starten (Bridge und andere Dienste wurden nicht beruehrt)"; fi
  else echo "OK Neustart-Fenster: $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 ))) Uhr (Berlin) liegt ausserhalb der Wetter-Slot-Zeit (gesperrt HH:55-HH:04 um 0,3,...,21 Uhr und HH:55-HH:59 der Slot-Stunden)"; fi; }
wxcheck "Vorpruefung"
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
python3 "$PPK" wxSlot dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer wxSlot nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" wxSlot dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: wxSlot im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne wxSlot ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard wxSlot meldet Verstoss"; }
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
# ---- wxSlot: Fenster direkt vor dem Neustart noch einmal pruefen (die Guard-Laeufe dauern) ----
wxcheck "vor dem Neustart"
WXS0=$("${CURL[@]}" "$B/api/sysboot/status" 2>/dev/null | python3 -c "import sys,json; j=json.load(sys.stdin); w=j.get('wx'); print('mit wx' if w else 'ohne wx')" 2>/dev/null || echo "unlesbar")
echo "Zustand vorher: /api/sysboot/status $WXS0 (ohne wx ist vor dem Patch normal)"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: wxSlot ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-wxslot-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG wxslot=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "wxSlot|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-wxslot-$TS" ]] && cp -a "$F.bak-wxslot-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-wxslot-$TS" ]] && { cmp -s "$F" "$F.bak-wxslot-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK wxSlot schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-wxslot-$TS"
  { ls -1t "$F.bak-wxslot-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-wxslot-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-wxslot-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'wxSlot aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; wxSlot aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- wxSlot: Marker einmal, Status mit wx, Stromausfall-Datei, Journal ----
WXM=$(grep -c "^# ===== wxSlot:" "$F" || true); WXH=$(grep -c "_wxo_skip\|_wxo_keep" "$F" || true)
[[ "$WXM" == 1 ]] && echo "OK Marker wxSlot 1x im Programm (Haken-Zeilen: $WXH)" || rbx "Marker wxSlot falsch ($WXM)"
WXJ=$("${CURL[@]}" "$B/api/sysboot/status" 2>/dev/null || true)
echo "$WXJ" > "$W/sb.json"
WXR=$(python3 - "$W/sb.json" <<'PY' 2>/dev/null || echo "NOK unlesbar"
import sys, json
j = json.load(open(sys.argv[1])); w = j.get("wx") or {}
ok = bool(w) and w.get("v") == 1 and w.get("installed") is True and not w.get("fehler") and isinstance(w.get("strom"), dict)
print(("OK" if ok else "NOK"), "slot=%s slot_stunde=%s stempel=%s versuche=%s ergebnis=%s ruhe_rest_s=%s faden=%s strom_geladen=%s strom_bekannt=%s" % (
    w.get("slot"), w.get("slot_stunde"), w.get("stempel_im_slot"), w.get("versuche"), w.get("ergebnis"), w.get("ruhe_rest_s"), w.get("faden"), (w.get("strom") or {}).get("geladen"), (w.get("strom") or {}).get("bekannt")))
PY
)
case "$WXR" in OK*) echo "OK /api/sysboot/status enthaelt wx: ${WXR#OK }" ;; *) rbx "/api/sysboot/status ohne gueltiges wx ($WXR)" ;; esac
WXL=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null | grep -E "wxSlot|meshBootQuiet: Wetter-Slot" | tail -8 | cut -c1-200 || true)
[[ -n "$WXL" ]] && echo "Journal wxSlot (Auszug):" && echo "$WXL" | sed 's/^/    /'
echo "HINWEIS Der Apply sendet selbst nichts. Fehlt in der laufenden Slot-Stunde der Auto-Stempel, holt das Dashboard die Wetter-Meldung nach der Anlaufruhe selbst nach (gewollt, Ergebnis: /api/sysboot/status -> wx.ergebnis und Journal 'wxSlot: Slot ...')."
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E wxSlot"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "wxSlot aktiv: wxSlot ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'wxSlot aktiv: wxSlot ok' ($(echo "$JD" | grep -F wxSlot | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'wxSlot Selbsttest FEHLER|wxSlot Takt:|wxSlot Stromausfall-Stand nicht gespeichert|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'wxSlot Selbsttest FEHLER|wxSlot Takt:|wxSlot Stromausfall-Stand nicht gespeichert|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein wxSlot-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash meshBootQuiet funkHarden2 kartevec wxSlot; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-wxslot-$TS" ]] && echo "Backup: dashboard.py.bak-wxslot-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-wxslot-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine wxslot-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c 'wxSlot' /home/fmg/prepper-dashboard/dashboard.py"
echo "  ls -l /home/fmg/prepper-dashboard/outage_mesh_state.json"
echo "  curl -s http://127.0.0.1:5000/api/sysboot/status | python3 -m json.tool | grep -A12 '\"wx\"'"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep wxSlot"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG wxslot=1 fertig"
