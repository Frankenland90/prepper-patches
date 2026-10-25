#!/bin/bash
set -eEuo pipefail
# alarmFaden (commit29): NINA und DWD aus dem 15-Minuten-Sammelzyklus geloest (PERF-02), nur dashboard.py. Sendet nichts von selbst (kein neuer Sendeweg; die vorhandenen Mesh-Hooks laufen wie bisher, jetzt aber nie gleichzeitig), keine Anzeige, keine Routen.
#  Befund: update_all (eine lange Sammelschleife, alle 15 min plus Laufzeit) holt nacheinander ~35 Quellen; NINA-/DWD-Warnungen erreichen Anzeige, Lage und Mesh-Weiterleitung dadurch bis zu 15 min + Laufzeit spaet. Dazu: fetch_lng() wird zweimal abgerufen,
#   fetch_ping() immer zweimal (Wiederholung auch bei Erfolg).
#  A) Eigener Faden alarm_loop: NINA + DWD alle 300 s (DWD aktualisiert selbst hoechstens alle 10 min), schreibt in data_store, Lage neu, Mesh-Hooks (maybe_mesh_nina/dwd) unter gemeinsamer Sperre - nie gleichzeitig mit dem Sammelzyklus.
#     Abstand waechst bei 3+ Fehlern in Folge (600 s, dann 900 s). Start erst nach dem ersten Voll-Update; nur wenn der Selbsttest ok war. Sammelzyklus nimmt den Zwischenspeicher (max. 900 s alt), sonst Abruf wie bisher; Resync uebernimmt neuere Faden-Werte.
#  B) update_all: lng nur einmal; zweiter Ping nur, wenn der erste keinen Wert lieferte. /api/sysboot/status zeigt "alarm" (Alter, Fehler in Folge, Dauer je Quelle).
#  Konservativ: Abruf alle 5 min statt ~15 min (sichtbarer Unterschied: NINA/DWD werden dreimal so oft angefragt). Ein Wert ALARM_POLL_S im Block.
#  Basis streng (sha16): dashboard.py 4937aa9db3e4f3e4 (Stand nach sameOrigin commit28) oder alarmFaden schon drin. Auf dem Stand vor commit28 (08fbc3e35940faab) stoppt das Skript mit Hinweis (erst commit28 anwenden). Andere Dateien werden nicht angefasst (nur vorher/nachher-Vergleich).
#  Neustart: nur prepper-dashboard. Sicherung: dashboard.py.bak-alarmfaden-ZEIT (letzte 3). Keine Datenbank-Aenderung (daher keine SQLite-Sicherung). Keine neue Docs-Version (nur dashboard.py; Text fuer die naechste Docs-Version liegt beim Bericht).
# Aufruf: bash /tmp/apply-alarmfaden.sh commit29 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/alarmfaden-apply
KEEP_LAST=3
KNOWN_D16="4937aa9db3e4f3e4"      # dashboard.py vor alarmFaden (Basis = Stand nach sameOrigin commit28)
KNOWN_D16N="565137da31dc675d"             # dashboard.py nach alarmFaden (Ziel)
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
echo "=== alarmFaden apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): NINA/DWD im eigenen Faden, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="7a3a434defc7126286399e6436f71615f13c1bb859e081d6f1a55225e53621af"
cat > "$W/patch-al.py" << 'AL_PAL_EOF'
"""Patcher alarmFaden. Aufruf: patch-pk.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
AL_PAL_EOF
EXPECT_RAE="77b99a2c8de2da8d3b40d73ebc04cc5a332b0fca55d92a406da8e51b0fd42e4b"
cat > "$W/edits_al.py" << 'AL_RAE_EOF'
# alarmFaden (commit29, PERF-02): Stellen (alt, neu) fuer dashboard.py. Jede alte Stelle genau einmal.
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
_LNG = '        "lng": {"value": fetch_lng(), "updated": now_str(), "color": get_freshness_color("lng")},\n'
_NINA_OLD = '''        "nina": (lambda _n: {"value": _n if _n is not None else ((data_store.get("nina") or {}).get("value")), "updated": now_str(), "error": _n is None, "color": get_freshness_color("nina")})(fetch_nina()),\n'''
DSH_EDITS = [
    # Dublette: lng wurde zweimal abgerufen (gleicher Schluessel, der zweite Wert gilt)
    (_LNG + _LNG, _LNG.rstrip("\n") + "  # alarmFaden: nur einmal abrufen\n"),
    # Dublette: zweiter Ping nur noch, wenn der erste keinen Wert lieferte
    ("    ping = fetch_ping()\n    public_ip = fetch_public_ip()\n",
     "    ping = _ping if _ping is not None else fetch_ping()  # alarmFaden: kein zweiter Ping, wenn der erste schon einen Wert hat\n    public_ip = fetch_public_ip()\n"),
    # NINA und DWD kommen aus dem eigenen Faden (Zwischenspeicher); fehlt der oder ist er zu alt, wird wie bisher direkt abgerufen
    (_NINA_OLD, '        "nina": _alarm_slot("nina"),  # alarmFaden\n'),
    ('        "dwd_warn": {"value": fetch_dwd_warnungen(), "updated": now_str(), "color": get_freshness_color("dwd_warn")},\n',
     '        "dwd_warn": _alarm_slot("dwd"),  # alarmFaden\n'),
    # nach dem Neuaufbau von data_store: hat der Faden waehrenddessen neuere Werte geliefert, uebernehmen
    ('    }\n    text, color, reason = calculate_lage(data_store)\n    data_store["mesh_weather_status"] = {\n',
     '    }\n    _alarm_resync()  # alarmFaden\n    text, color, reason = calculate_lage(data_store)\n    data_store["mesh_weather_status"] = {\n'),
    # Mesh-Hooks fuer NINA/DWD unter derselben Sperre wie im Faden (kein doppelter Versand)
    ('        maybe_mesh_nina(data_store.get("nina", {}).get("value"))\n',
     '        _alarm_hook_nina(data_store.get("nina", {}).get("value"))  # alarmFaden\n'),
    ('            maybe_mesh_dwd(_dwv.get("items") if isinstance(_dwv, dict) else None)\n',
     '            _alarm_hook_dwd(_dwv.get("items") if isinstance(_dwv, dict) else None)  # alarmFaden\n'),
    # Start des Fadens zusammen mit den anderen nach dem ersten Voll-Update
    ('    for fn in ("weather_mesh_loop", "freq_loop"):\n', '    for fn in ("weather_mesh_loop", "freq_loop", "alarm_loop"):  # alarmFaden\n'),
    # Anzeige in /api/sysboot/status
    ('"selftest": _SB["selftest"], "pages_wrapped": _SB.get("wrapped")})',
     '"selftest": _SB["selftest"], "pages_wrapped": _SB.get("wrapped"), "alarm": _alarm_status()})'),
]
AL_RAE_EOF
EXPECT_RAB="901fa43b186749a1fdd12b291e484fa6355a12fd8aee79eb29ff630736b12e48"
cat > "$W/blk_al.py" << 'AL_RAB_EOF'
# ===== alarmFaden: NINA und DWD aus dem 15-Minuten-Sammelzyklus gelöst - eigener Faden mit eigenem Intervall (PERF-02); Mesh-Weiterleitung, Dedup und Anzeige bleiben wie bisher =====
import copy as _al_copy
import threading as _al_th
import time as _al_time

ALARM_POLL_S = 300            # NINA + DWD alle 5 min (DWD aktualisiert spaetestens alle 10 min; vorher: alle 15 min plus Laufzeit des Sammelzyklus)
ALARM_FRESH_S = 3 * ALARM_POLL_S   # Zwischenspeicher gilt fuer den Sammelzyklus bis zu diesem Alter, sonst Abruf wie bisher
ALARM_MAX_S = 900             # Obergrenze des Abstands bei wiederholten Fehlern (Circuit-Breaker: ab 3 Fehlern in Folge verdoppeln)
_AL_KEYS = {"nina": "nina", "dwd": "dwd_warn"}
_AL = {"started": False, "n": 0, "err": None, "last_start": None,
       "slot": {"nina": None, "dwd": None}, "t": {"nina": None, "dwd": None}, "seq": {"nina": 0, "dwd": 0}, "used": {"nina": 0, "dwd": 0},
       "ok_at": {"nina": None, "dwd": None}, "fails": {"nina": 0, "dwd": 0}, "dur": {"nina": None, "dwd": None}}
_AL_LOCK = _al_th.Lock()          # Zustand/Zwischenspeicher (kurz)
_AL_RUN_LOCK = _al_th.RLock()     # ein Abruf von NINA/DWD zur Zeit (Faden oder Sammelzyklus)
_AL_HOOK_LOCK = _al_th.RLock()    # Mesh-Hooks NINA/DWD nie gleichzeitig (Dedup-Zustand last_nina_mesh/last_dwd_mesh)


def _al_dep(deps, name):
    f = (deps or {}).get(name)
    return f if f is not None else globals().get(name)


def _al_now(deps):
    f = _al_dep(deps, "now_str")
    return f() if callable(f) else ""


def _al_mono(deps):
    f = (deps or {}).get("mono")
    return f() if callable(f) else _al_time.monotonic()


def _alarm_build(which, raw, prev_store, deps=None):
    """Fertiger data_store-Eintrag wie im Sammelzyklus (gleiche Felder/Regeln): NINA None -> letzter Wert + error; DWD immer der Rueckgabewert."""
    color = _al_dep(deps, "get_freshness_color")
    key = _AL_KEYS[which]
    if which == "nina":
        return {"value": raw if raw is not None else (((prev_store or {}).get("nina") or {}).get("value")), "updated": _al_now(deps), "error": raw is None, "color": color(key)}
    return {"value": raw, "updated": _al_now(deps), "color": color(key)}


def _alarm_store(which, slot, deps=None, stamp=None, dur=None, ok=None):
    with _AL_LOCK:
        _AL["slot"][which] = _al_copy.deepcopy(slot)
        _AL["t"][which] = _al_mono(deps) if stamp is None else stamp
        _AL["seq"][which] += 1
        if dur is not None:
            _AL["dur"][which] = round(dur, 1)
        if ok is True:
            _AL["fails"][which] = 0
            _AL["ok_at"][which] = _al_now(deps)
        elif ok is False:
            _AL["fails"][which] += 1
        return _AL["seq"][which]


def _alarm_ok(which, raw, deps=None):
    """Erfolg eines Abrufs: NINA = Ergebnis nicht None; DWD = Fehlerzaehler 0 (fetch_dwd_warnungen gibt bei Fehler ein leeres dict zurueck)."""
    if which == "nina":
        return raw is not None
    fc = (deps or {}).get("fail_counters")
    if fc is None:
        fc = globals().get("fail_counters") or {}
    return fc.get("dwd_warn", 0) == 0


def _alarm_slot(which, deps=None):
    """Fuer update_all: Zwischenspeicher des Fadens, wenn frisch; sonst Abruf wie bisher (dann wird auch der Zwischenspeicher gefuellt)."""
    with _AL_LOCK:
        slot, t, seq = _AL["slot"][which], _AL["t"][which], _AL["seq"][which]
        age = None if t is None else _al_mono(deps) - t
        if slot is not None and age is not None and 0 <= age <= ALARM_FRESH_S:
            _AL["used"][which] = seq
            return _al_copy.deepcopy(slot)
    with _AL_RUN_LOCK:
        with _AL_LOCK:
            slot, t, seq = _AL["slot"][which], _AL["t"][which], _AL["seq"][which]
            age = None if t is None else _al_mono(deps) - t
            if slot is not None and age is not None and 0 <= age <= ALARM_FRESH_S:      # der Faden war waehrenddessen fertig geworden
                _AL["used"][which] = seq
                return _al_copy.deepcopy(slot)
        fn = _al_dep(deps, "fetch_nina" if which == "nina" else "fetch_dwd_warnungen")
        t0 = _al_mono(deps)
        raw = fn()
        built = _alarm_build(which, raw, (deps or {}).get("store") if deps and "store" in deps else globals().get("data_store"), deps)
        s = _alarm_store(which, built, deps, dur=_al_mono(deps) - t0, ok=_alarm_ok(which, raw, deps))
        with _AL_LOCK:
            _AL["used"][which] = s
        return built


def _alarm_resync(deps=None):
    """Nach dem Neuaufbau von data_store in update_all: neuere Werte des Fadens (waehrend des Zyklus fertig geworden) uebernehmen."""
    try:
        ds = (deps or {}).get("store") if deps and "store" in deps else globals().get("data_store")
        if not isinstance(ds, dict):
            return 0
        n = 0
        with _AL_LOCK:
            for which, key in _AL_KEYS.items():
                if _AL["slot"][which] is not None and _AL["seq"][which] != _AL["used"][which]:
                    ds[key] = _al_copy.deepcopy(_AL["slot"][which])
                    _AL["used"][which] = _AL["seq"][which]
                    n += 1
        return n
    except Exception as e:
        print("alarmFaden resync:", e, flush=True)
        return 0


def _alarm_hook_nina(value, deps=None):
    with _AL_HOOK_LOCK:
        return _al_dep(deps, "maybe_mesh_nina")(value)


def _alarm_hook_dwd(items, deps=None):
    with _AL_HOOK_LOCK:
        return _al_dep(deps, "maybe_mesh_dwd")(items)


def _alarm_interval(deps=None):
    """Abstand bis zum naechsten Abruf: normal ALARM_POLL_S; ab 3 Fehlern in Folge verdoppeln bis ALARM_MAX_S (tote Quelle wird seltener angefragt)."""
    with _AL_LOCK:
        streak = max(_AL["fails"].values())
    if streak < 3:
        return ALARM_POLL_S
    return min(ALARM_MAX_S, ALARM_POLL_S * (2 ** (streak - 2)))


def _alarm_once(deps=None):
    """Ein Abruf NINA + DWD, Eintrag in data_store, Lage neu, Mesh-Hooks wie im Sammelzyklus. Rueckgabe: kurzer Status-Text (fuer Selbsttest/Journal)."""
    d = deps or {}
    if not _AL_RUN_LOCK.acquire(timeout=d.get("lock_timeout", 120)):
        return "uebersprungen (anderer Abruf laeuft)"
    try:
        ds = d["store"] if "store" in d else globals().get("data_store")
        if not isinstance(ds, dict) or not ds.get("last_full_update"):
            return "uebersprungen (erstes Voll-Update fehlt)"
        tls = d.get("tls") if "tls" in d else globals().get("_KEEP_TLS")
        try:
            tls.marks = {}
        except Exception:
            pass
        res = {}
        for which in ("nina", "dwd"):
            t0 = _al_mono(d)
            try:
                raw = _al_dep(d, "fetch_nina" if which == "nina" else "fetch_dwd_warnungen")()
                res[which] = (raw, _alarm_ok(which, raw, d), _al_mono(d) - t0)
            except Exception as e:
                res[which] = (None, False, _al_mono(d) - t0)
                _AL["err"] = "%s: %s" % (which, str(e)[:120])
                print("alarmFaden %s:" % which, e, flush=True)
                if which == "dwd":
                    res[which] = None          # Fehler im Abruf: Eintrag nicht anfassen (wie ein nicht erreichter Abruf)
        built = {}
        for which, key in _AL_KEYS.items():
            if res.get(which) is None:
                continue
            slot = _alarm_build(which, res[which][0], ds, d)
            ds[key] = slot
            built[which] = slot
        for nm in ("_keep_heal_store", "stale_ts_paint"):
            f = _al_dep(d, nm)
            if callable(f):
                try:
                    f()
                except Exception as e:
                    print("alarmFaden %s:" % nm, e, flush=True)
        for which, key in _AL_KEYS.items():
            if which in built:
                _alarm_store(which, ds.get(key) if isinstance(ds.get(key), dict) else built[which], d, dur=res[which][2], ok=res[which][1])
                with _AL_LOCK:
                    _AL["used"][which] = _AL["seq"][which]
        try:
            lg = _al_dep(d, "calculate_lage")
            if callable(lg):
                text, color, reason = lg(ds)
                ds["lage"] = {"text": text, "color": color, "reason": reason}
        except Exception as e:
            print("alarmFaden Lage:", e, flush=True)
        try:
            if "nina" in built:
                _alarm_hook_nina((ds.get("nina") or {}).get("value"), d)
        except Exception as e:
            print("alarmFaden NINA-Hook:", e, flush=True)
        try:
            if "dwd" in built:
                dv = (ds.get("dwd_warn") or {}).get("value") or {}
                _alarm_hook_dwd(dv.get("items") if isinstance(dv, dict) else None, d)
        except Exception as e:
            print("alarmFaden DWD-Hook:", e, flush=True)
        try:
            ds["nina_mesh_status"] = (d.get("nina_status") if "nina_status" in d else globals().get("last_nina_mesh_status"))
            ds["dwd_mesh_status"] = (d.get("dwd_status") if "dwd_status" in d else globals().get("last_dwd_mesh_status"))
        except Exception:
            pass
        with _AL_LOCK:
            _AL["n"] += 1
        return "ok (%s)" % ", ".join("%s %s" % (w, "ok" if res[w][1] else "Fehler") for w in ("nina", "dwd") if res.get(w))
    finally:
        _AL_RUN_LOCK.release()


def _alarm_status(deps=None):
    """Fuer /api/sysboot/status: je Quelle Alter des letzten Abrufs, letzter Erfolg, Fehler in Folge, Dauer. Wirft nie."""
    try:
        out = {"poll_s": ALARM_POLL_S, "fresh_s": ALARM_FRESH_S, "thread": bool(_AL["started"]), "n": _AL["n"], "err": _AL["err"], "next_s": None, "src": {}}
        now = _al_mono(deps)
        with _AL_LOCK:
            for w in ("nina", "dwd"):
                t = _AL["t"][w]
                out["src"][w] = {"age_s": None if t is None else int(now - t), "ok_at": _AL["ok_at"][w], "fails": _AL["fails"][w], "dur_s": _AL["dur"][w], "seq": _AL["seq"][w]}
        out["interval_s"] = _alarm_interval(deps)
        return out
    except Exception as e:
        return {"error": str(e)[:80]}


def alarm_loop():
    """Eigener Faden: wartet das erste Voll-Update ab, danach NINA + DWD alle ALARM_POLL_S (Abstand waechst bei Fehlern)."""
    if _AL["started"] or str((globals().get("_ALG") or {}).get("selftest", "")).startswith("FEHLER"):
        return
    _AL["started"] = True
    try:
        while not (isinstance(globals().get("data_store"), dict) and data_store.get("last_full_update")):
            _al_time.sleep(5)
        print("alarmFaden: NINA und DWD ab jetzt alle %d s im eigenen Faden (Sammelzyklus nutzt den Zwischenspeicher)" % ALARM_POLL_S, flush=True)
        while True:
            _al_time.sleep(_alarm_interval())
            try:
                r = _alarm_once()
                _AL["last_start"] = _al_now(None)
                if not r.startswith("ok"):
                    print("alarmFaden:", r, flush=True)
            except Exception as e:
                _AL["err"] = str(e)[:120]
                print("alarmFaden Lauf:", e, flush=True)
    finally:
        _AL["started"] = False


def _selftest_alarm():
    """Rein rechnend mit Attrappen (kein Netz, kein Mesh, data_store/Zwischenspeicher der echten App bleiben unberuehrt)."""
    import copy as _c
    saved = _c.deepcopy({k: _AL[k] for k in ("slot", "t", "seq", "used", "ok_at", "fails", "dur", "n", "err")})
    try:
        clock = [1000.0]
        calls = []
        fc = {"dwd_warn": 0}
        ds = {"last_full_update": 1, "nina": {"value": [{"title": "alt"}], "updated": "t0"}, "dwd_warn": {"value": {"items": []}, "updated": "t0"}}
        res_n = {"v": [{"city": "X", "title": "neu"}]}
        deps = {"store": ds, "mono": lambda: clock[0], "now_str": lambda: "ts", "get_freshness_color": lambda k: "c-" + k, "fail_counters": fc, "tls": None,
                "fetch_nina": lambda: (calls.append("fn"), res_n["v"])[1], "fetch_dwd_warnungen": lambda: (calls.append("fd"), {"items": [{"name": "Y", "event": "Sturm"}], "max_level": 3})[1],
                "stale_ts_paint": lambda: None, "maybe_mesh_nina": lambda v: calls.append(("hn", v)), "maybe_mesh_dwd": lambda it: calls.append(("hd", it)),
                "calculate_lage": lambda s: ("T", "col", "why"), "_keep_heal_store": lambda: calls.append("heal"), "nina_status": {"s": 1}, "dwd_status": {"s": 2}}
        for k in ("slot", "t", "seq", "used", "ok_at", "fails", "dur"):
            for w in ("nina", "dwd"):
                _AL[k][w] = None if k in ("slot", "t", "ok_at", "dur") else 0
        # 1) Bau wie im Sammelzyklus
        b = _alarm_build("nina", None, {"nina": {"value": [1]}}, deps)
        assert b == {"value": [1], "updated": "ts", "error": True, "color": "c-nina"}, b
        b = _alarm_build("nina", [2], None, deps)
        assert b == {"value": [2], "updated": "ts", "error": False, "color": "c-nina"}, b
        assert _alarm_build("dwd", {"items": []}, None, deps) == {"value": {"items": []}, "updated": "ts", "color": "c-dwd_warn"}
        # 2) Ohne Zwischenspeicher: Abruf wie bisher und Zwischenspeicher fuellen
        s1 = _alarm_slot("nina", deps)
        assert calls == ["fn"] and s1["value"] == res_n["v"] and _AL["seq"]["nina"] == 1 and _AL["used"]["nina"] == 1, (calls, s1)
        # 3) Frisch: kein Abruf, Kopie
        del calls[:]
        clock[0] += ALARM_FRESH_S
        s2 = _alarm_slot("nina", deps)
        assert not calls and s2 == s1 and s2 is not s1 and s2["value"] is not s1["value"], "frischer Zwischenspeicher muss ohne Abruf und als Kopie kommen"
        s2["value"].append({"x": 1})
        assert _alarm_slot("nina", deps) == s1 and not calls, "Aenderung an der gelieferten Kopie darf den Zwischenspeicher nicht veraendern"
        # 4) Zu alt: Abruf
        clock[0] += 1
        _alarm_slot("nina", deps)
        assert calls == ["fn"], "zu alter Zwischenspeicher muss neu abgerufen werden"
        # 5) Uhr zurueck: nicht verwenden
        del calls[:]
        clock[0] -= 5000
        _alarm_slot("nina", deps)
        assert calls == ["fn"], "Uhr zurueck -> Abruf"
        clock[0] = 2000.0
        # 6) Faden-Lauf: schreibt data_store, Lage, Hooks (je einmal), Status, Zwischenspeicher
        del calls[:]
        r = _alarm_once(deps)
        assert r == "ok (nina ok, dwd ok)", r
        assert calls == ["fn", "fd", "heal", ("hn", res_n["v"]), ("hd", [{"name": "Y", "event": "Sturm"}])], calls
        assert ds["nina"]["value"] == res_n["v"] and ds["dwd_warn"]["value"]["max_level"] == 3 and ds["lage"] == {"text": "T", "color": "col", "reason": "why"}
        assert ds["nina_mesh_status"] == {"s": 1} and ds["dwd_mesh_status"] == {"s": 2}
        assert _AL["slot"]["nina"]["value"] == res_n["v"] and _AL["used"]["nina"] == _AL["seq"]["nina"] and _AL["fails"] == {"nina": 0, "dwd": 0}
        # 7) Sammelzyklus danach: Zwischenspeicher, kein Abruf
        del calls[:]
        z = _alarm_slot("dwd", deps)
        assert not calls and z["value"]["max_level"] == 3
        # 8) Nachtraeglicher Faden-Lauf waehrend eines Zyklus: Resync uebernimmt
        res_n["v"] = [{"city": "X", "title": "noch neuer"}]
        _alarm_once(deps)
        ds2 = {"nina": {"value": "alt"}, "dwd_warn": {"value": "alt"}}
        _AL["used"]["nina"] -= 1
        n = _alarm_resync({"store": ds2})
        assert n == 1 and ds2["nina"]["value"] == res_n["v"] and ds2["dwd_warn"]["value"] == "alt", (n, ds2)
        assert _alarm_resync({"store": ds2}) == 0, "Resync darf nur einmal uebernehmen"
        # 9) NINA-Totalausfall: letzter Wert + error, DWD Fehler -> Fehlerzaehler
        res_n["v"] = None
        fc["dwd_warn"] = 1
        del calls[:]
        r = _alarm_once(deps)
        assert r == "ok (nina Fehler, dwd Fehler)", r
        assert ds["nina"]["error"] is True and ds["nina"]["value"] == [{"city": "X", "title": "noch neuer"}] and _AL["fails"] == {"nina": 1, "dwd": 1}
        # 10) Abstand: normal 300 s; ab 3 Fehlern doppelt, Obergrenze 900 s
        assert _alarm_interval(deps) == ALARM_POLL_S
        _AL["fails"]["nina"] = 3
        assert _alarm_interval(deps) == 600
        _AL["fails"]["nina"] = 4
        assert _alarm_interval(deps) == 900
        _AL["fails"]["nina"] = 9
        assert _alarm_interval(deps) == ALARM_MAX_S
        # 11) Abruf wirft: Faden laeuft weiter, DWD-Eintrag bleibt
        deps["fetch_dwd_warnungen"] = lambda: 1 / 0
        before = _c.deepcopy(ds["dwd_warn"])
        with _AlQuiet():
            r = _alarm_once(deps)
        assert r.startswith("ok") and ds["dwd_warn"] == before, (r, ds["dwd_warn"])
        # 12) Voll-Update fehlt -> nichts tun
        assert _alarm_once(dict(deps, store={})).startswith("uebersprungen")
        # 13) Status wirft nie
        st = _alarm_status(deps)
        assert st["poll_s"] == ALARM_POLL_S and "nina" in st["src"] and "dwd" in st["src"], st
        return "alarmFaden ok (NINA/DWD alle %d s im eigenen Faden, Sammelzyklus nutzt den Zwischenspeicher bis %d s, sonst Abruf wie bisher)" % (ALARM_POLL_S, ALARM_FRESH_S)
    finally:
        for k, v in saved.items():
            _AL[k] = v


class _AlQuiet:
    """Hilfsklasse fuer den Selbsttest: unterdrueckt die erwartete Fehlermeldung."""

    def __enter__(self):
        import io as _io
        import sys as _sys
        self._o = _sys.stdout
        _sys.stdout = _io.StringIO()
        return self

    def __exit__(self, *a):
        import sys as _sys
        _sys.stdout = self._o
        return False


try:
    _ALG = {"selftest": _selftest_alarm()}
    print("alarmFaden aktiv: %s" % _ALG["selftest"], flush=True)
except Exception as _al_e:
    _ALG = {"selftest": "FEHLER %s" % _al_e}
    print("alarmFaden Selbsttest FEHLER (Sammelzyklus ruft NINA/DWD wie bisher selbst ab):", _al_e, flush=True)
AL_RAB_EOF
EXPECT_RAG="e73598dad0477f75a8b0b158ea4ca4725774505125b5b4341bb15878e400bb8b"
cat > "$W/guard_al.py" << 'AL_RAG_EOF'
"""AST-Guard alarmFaden (nur dashboard.py). Aufruf:
  guard_al.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne alarmFaden (Rueckbau, byte-genau)
  guard_al.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhalten in der Sandbox (Differenztest alt/neu der fuenf Pruefungen, Hook-Tests)
  RH_ALT=ALT_VERZ guard_al.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest: jede absichtliche Verfehlung muss erkannt werden
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

MARK = "# ===== alarmFaden:"
MAIN = '\n\nif __name__ == "__main__":\n'
ALLOWED_TOP = {"update_all", "_sb_first_update", "_sb_api_status", "ALARM_POLL_S", "ALARM_FRESH_S", "ALARM_MAX_S", "_AL_KEYS", "_AL", "_AL_LOCK", "_AL_RUN_LOCK", "_AL_HOOK_LOCK",
               "_al_dep", "_al_now", "_al_mono", "_alarm_build", "_alarm_store", "_alarm_ok", "_alarm_slot", "_alarm_resync", "_alarm_hook_nina", "_alarm_hook_dwd", "_alarm_interval",
               "_alarm_once", "_alarm_status", "alarm_loop", "_selftest_alarm", "_AlQuiet", "_ALG", "#Import"}


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block alarmFaden nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle alarmFaden nicht genau einmal: " + n.strip().splitlines()[0][:70]
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
        return "_ALG" if "_selftest_alarm()" in ast.unparse(n) else "#try"
    if isinstance(n, (ast.Import, ast.ImportFrom)) and any(getattr(a, "asname", None) in ("_al_copy", "_al_th", "_al_time") for a in n.names):
        return "#Import"
    return "#" + type(n).__name__


def find_top(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def calls_named(node, name):
    return [c for c in ast.walk(node) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == name]


def static(alt, new, blk):
    n = 0
    ta, tn = ast.parse(alt), ast.parse(new)
    da = {ast.dump(x): top_name(x) for x in ta.body}
    dn = {ast.dump(x): top_name(x) for x in tn.body}
    changed = [dn[k] for k in dn if k not in da] + [da[k] for k in da if k not in dn]
    bad = sorted(set(c for c in changed if c not in ALLOWED_TOP))
    assert not bad, "alarmFaden aendert ausserhalb der erlaubten Stellen: %s" % bad
    n += 1
    # update_all: NINA/DWD/Hooks nur noch ueber die neuen Helfer; Dubletten weg
    u = find_top(tn, "update_all")
    for nm in ("fetch_nina", "fetch_dwd_warnungen", "maybe_mesh_nina", "maybe_mesh_dwd"):
        assert not calls_named(u, nm), "update_all ruft %s noch direkt auf" % nm
    for nm, args in (("_alarm_slot", ["'nina'", "'dwd'"]),):
        got = sorted(ast.unparse(c.args[0]) for c in calls_named(u, nm))
        assert got == sorted(args), "update_all: _alarm_slot-Aufrufe %s" % got
    assert len(calls_named(u, "_alarm_hook_nina")) == 1 and len(calls_named(u, "_alarm_hook_dwd")) == 1, "update_all: Hooks ueber _alarm_hook_* genau je einmal"
    assert len(calls_named(u, "fetch_lng")) == 1, "update_all: fetch_lng genau einmal"
    assert len(calls_named(u, "fetch_ping")) == 2, "update_all: fetch_ping genau zweimal (erster Ping + Wiederholung nur bei Fehlschlag)"
    pingline = [x for x in ast.walk(u) if isinstance(x, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "ping" for t in x.targets)]
    assert any(ast.unparse(x.value) == "_ping if _ping is not None else fetch_ping()" for x in pingline), "update_all: Wiederholung nur wenn der erste Ping None war"
    body = u.body
    idx = [i for i, s in enumerate(body) if isinstance(s, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "data_store" for t in s.targets)]
    assert len(idx) == 1 and ast.unparse(body[idx[0] + 1]) == "_alarm_resync()", "update_all: _alarm_resync() muss direkt auf den Neuaufbau von data_store folgen"
    n += 1
    # Start und Anzeige
    f = find_top(tn, "_sb_first_update")
    assert "('weather_mesh_loop', 'freq_loop', 'alarm_loop')" in ast.unparse(f), "_sb_first_update startet alarm_loop nicht mit den anderen Faeden"
    assert "'alarm': _alarm_status()" in ast.unparse(find_top(tn, "_sb_api_status")), "/api/sysboot/status ohne alarm"
    n += 1
    # Block
    bt = rd(blk)
    bn = ast.parse(bt)
    for forb in ("requests", "urlopen", "subprocess", "socket", "os.system", "open(", "send_meshtastic", "send_nina", "send_dab", "Thread(", "app.route", "add_url_rule", "shutil"):
        assert forb not in bt, "Block enthaelt %s" % forb
    once = find_top(bn, "_alarm_once")
    assert len(calls_named(once, "_alarm_hook_nina")) == 1 and len(calls_named(once, "_alarm_hook_dwd")) == 1, "_alarm_once: je ein Hook-Aufruf ueber _alarm_hook_*"
    assert not calls_named(once, "maybe_mesh_nina") and not calls_named(once, "maybe_mesh_dwd"), "_alarm_once ruft Mesh-Hooks direkt auf (ohne Sperre)"
    for hn, nm in (("_alarm_hook_nina", "maybe_mesh_nina"), ("_alarm_hook_dwd", "maybe_mesh_dwd")):
        fu = ast.unparse(find_top(bn, hn))
        assert "with _AL_HOOK_LOCK:" in fu and "'%s'" % nm in fu, "%s: Hook nicht unter _AL_HOOK_LOCK" % hn
    cons = {t.id: x.value.value for x in bn.body if isinstance(x, ast.Assign) and isinstance(x.value, ast.Constant) for t in x.targets if isinstance(t, ast.Name)}
    assert 60 <= cons["ALARM_POLL_S"] <= 600, "ALARM_POLL_S ausserhalb 60..600 s (%s)" % cons["ALARM_POLL_S"]
    assert cons["ALARM_MAX_S"] >= cons["ALARM_POLL_S"] and cons["ALARM_MAX_S"] <= 3600
    loop = ast.unparse(find_top(bn, "alarm_loop"))
    assert "_ALG" in loop and "FEHLER" in loop and "last_full_update" in loop and "_alarm_interval()" in loop, "alarm_loop: Selbsttest-Sperre, Warten auf Voll-Update und Abstand pruefen"
    n += 1
    return n


# ---------------- Verhalten ----------------
def exec_blk(blk, ns):
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile(rd(blk), "al_block", "exec"), ns)


def build_ns(src, blk_text=None, with_block=True):
    """Sandbox-Namensraum mit Attrappen fuer alles, was update_all braucht; liefert (ns, log)."""
    import datetime as _dt
    log = []
    ns = {"__name__": "al_sandbox", "time": time}
    ns["UPDATE_INTERVAL"] = 900
    ns["timedelta"] = _dt.timedelta
    ns["now"] = lambda: _dt.datetime(2026, 10, 25, 13, 0, 0)
    ns["now_str"] = lambda: "NOW"
    ns["get_freshness_color"] = lambda k: "col-" + k
    ns["fail_counters"] = {}
    ns["calculate_lage"] = lambda ds: ("T", "C", "R")
    ns["stale_ts_snap"] = lambda: log.append(("call", "stale_ts_snap"))
    ns["stale_ts_restore"] = lambda: log.append(("call", "stale_ts_restore"))
    ns["classify_uplink"] = lambda ip, ping: {"conn_type": "Festnetz", "conn_icon": "i", "path": "p", "isp": "I", "org": None, "as": "A", "hint": None}
    for h in ("diesel_history", "firms_history", "freq_history", "oil_history", "outage_history", "ping_history", "wbi_history"):
        ns[h] = []
    ns["last_download"] = {"at": "D"}
    for v in ("last_dwd_mesh_status", "last_mesh_weather_auto", "last_mesh_weather_manual", "last_nina_mesh_status"):
        ns[v] = {"v": v}
    ns["data_store"] = {"nina": {"value": [{"title": "vorher"}], "updated": "X"}}
    ns["_vals"] = {}

    def mk_fetch(name):
        def f(*a, **k):
            log.append(("call", name))
            if name in ns["_vals"]:
                v = ns["_vals"][name]
                return v() if callable(v) else v
            if name == "fetch_frequenz_live":
                return {"value": 50.0}
            return "v:" + name
        return f
    for nm in ("fetch_adsb", "fetch_apotheken_notdienst", "fetch_download_mbps", "fetch_dwd_warnungen", "fetch_dwd_wbi", "fetch_frequenz_live", "fetch_gas", "fetch_internet", "fetch_kraftstoff",
               "fetch_lng", "fetch_lng_terminals", "fetch_load", "fetch_luft_erlangen", "fetch_mesh_bridge", "fetch_mesh_ping_stats", "fetch_metalle", "fetch_mix", "fetch_net_probes",
               "fetch_news", "fetch_nina", "fetch_odl", "fetch_pegel_lokal", "fetch_ping", "fetch_public_ip", "fetch_rohoel", "fetch_spaceweather", "fetch_stratum", "fetch_strom",
               "fetch_stromausfall", "fetch_system", "fetch_wetter"):
        ns[nm] = mk_fetch(nm)
    ns["_vals"]["fetch_internet"] = True
    ns["_vals"]["fetch_ping"] = 12.5
    ns["_vals"]["fetch_public_ip"] = "1.2.3.4"
    ns["_vals"]["fetch_nina"] = [{"city": "N", "title": "T1"}]
    ns["_vals"]["fetch_dwd_warnungen"] = {"items": [{"name": "A", "event": "E"}], "max_level": 2}
    for nm in ("maybe_mesh_dwd", "maybe_mesh_dwd_wbi", "maybe_mesh_luft", "maybe_mesh_nina", "maybe_mesh_odl", "maybe_mesh_weather"):
        ns[nm] = (lambda nm: lambda *a, **k: log.append(("hook", nm, repr(a), repr(k))))(nm)
    ns["_log"] = log
    return ns


def run_update(src, scen, with_block=False, blk=None, pre=None):
    ns = build_ns(src)
    ns["_vals"].update(scen.get("vals", {}))
    for k, v in scen.get("fail_counters", {}).items():
        ns["fail_counters"][k] = v
    if scen.get("prev") is not None:
        ns["data_store"] = scen["prev"]
    ns["_vals"].update({k: v for k, v in scen.get("late", {}).items()})
    if with_block:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(rd(blk) if blk else src[src.index(MARK):src.index(MAIN, src.index(MARK))], "al_block", "exec"), ns)
    exec(compile(seg(src, "update_all"), "update_all", "exec"), ns)
    if pre:
        pre(ns)
    with contextlib.redirect_stdout(io.StringIO()):
        ns["update_all"]()
    return ns


_SEG = {}


def seg(src, name):
    k = (len(src), hash(src))
    if k not in _SEG:
        if len(_SEG) > 4:
            _SEG.clear()
        _SEG[k] = ({n.name: n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef)}, {})
    nodes, done = _SEG[k]
    if name not in nodes:
        raise AssertionError("Funktion fehlt: " + name)
    if name not in done:
        done[name] = ast.get_source_segment(src, nodes[name])
    return done[name]


def norm(ns):
    return json.loads(json.dumps(ns["data_store"], default=str))


SCENS = [
    ("normal", {}),
    ("nina None, vorher Wert", {"vals": {"fetch_nina": None}}),
    ("nina leer", {"vals": {"fetch_nina": []}}),
    ("ping None (Wiederholung)", {"vals": {"fetch_ping": None}}),
    ("ping None, internet False", {"vals": {"fetch_ping": None, "fetch_internet": False, "fetch_public_ip": None}}),
    ("ping hoch", {"vals": {"fetch_ping": 150.0}}),
    ("dwd Fehler", {"vals": {"fetch_dwd_warnungen": {"items": [], "max_level": 0, "count": 0}}, "fail_counters": {"dwd_warn": 2}}),
    ("kein vorheriger Speicher", {"prev": {}}),
]


def diff_update(alt, new, blk):
    n = 0
    for name, scen in SCENS:
        a = run_update(alt, scen)
        b = run_update(new, scen, with_block=True, blk=blk)
        da, db = norm(a), norm(b)
        assert da == db and list(a["data_store"].keys()) == list(b["data_store"].keys()), "data_store weicht ab (%s): %s" % (name, sorted(k for k in set(da) | set(db) if da.get(k) != db.get(k)))
        la = [x for x in a["_log"]]
        lb = [x for x in b["_log"]]
        # erlaubte Unterschiede: ein fetch_lng weniger; ein fetch_ping weniger, wenn der erste Ping einen Wert hatte; Hooks gleich (Namen, Argumente), nina/dwd-Hook jetzt ueber Helfer, gleiche Aufrufe
        exp = list(la)
        exp.remove(("call", "fetch_lng"))
        if scen.get("vals", {}).get("fetch_ping", 12.5) is not None:
            exp.remove(("call", "fetch_ping"))
        assert exp == lb, "Aufrufe weichen ab (%s): erwartet %s, ist %s" % (name, exp, lb)
        n += 1
    return n


def cache_scenarios(new, blk):
    n = 0
    # frischer Zwischenspeicher: kein Abruf von NINA/DWD, Werte aus dem Zwischenspeicher, Hooks bekommen sie
    def pre(ns):
        ns["_alarm_store"]("nina", {"value": [{"city": "C", "title": "aus Speicher"}], "updated": "P", "error": False, "color": "cc"}, None, ok=True)
        ns["_alarm_store"]("dwd", {"value": {"items": [{"name": "Z", "event": "Q"}], "max_level": 4}, "updated": "P", "color": "cd"}, None, ok=True)
    b = run_update(new, {}, with_block=True, blk=blk, pre=pre)
    calls = [x[1] for x in b["_log"] if x[0] == "call"]
    assert "fetch_nina" not in calls and "fetch_dwd_warnungen" not in calls, "frischer Zwischenspeicher: NINA/DWD duerfen nicht abgerufen werden"
    assert b["data_store"]["nina"]["value"] == [{"city": "C", "title": "aus Speicher"}] and b["data_store"]["dwd_warn"]["value"]["max_level"] == 4
    hooks = [x for x in b["_log"] if x[0] == "hook" and x[1] in ("maybe_mesh_nina", "maybe_mesh_dwd")]
    assert [h[1] for h in hooks] == ["maybe_mesh_nina", "maybe_mesh_dwd"] and "aus Speicher" in hooks[0][2] and "'Z'" in hooks[1][2], hooks
    n += 1
    # Faden liefert waehrend des Zyklus (nach dem NINA-Teil des Neuaufbaus) neuere Werte -> Resync uebernimmt sie
    def pre2(ns):
        pre(ns)
        newslot = {"value": [{"city": "C", "title": "waehrend Zyklus"}], "updated": "Q", "error": False, "color": "cc"}
        ns["_vals"]["fetch_metalle"] = lambda: ns["_alarm_store"]("nina", newslot, None, ok=True) and "m"
    b = run_update(new, {}, with_block=True, blk=blk, pre=pre2)
    assert b["data_store"]["nina"]["value"][0]["title"] == "waehrend Zyklus", "Resync: neuere Werte des Fadens gingen verloren"
    n += 1
    return n


def concurrency(new, blk):
    n = 0
    ns = build_ns(new)
    exec_blk(blk, ns)
    # Hook-Sperre: zwei Faeden gleichzeitig -> nie gleichzeitig im Hook
    state = {"in": 0, "max": 0}

    def slow_hook(v):
        state["in"] += 1
        state["max"] = max(state["max"], state["in"])
        time.sleep(0.05)
        state["in"] -= 1
    ns["maybe_mesh_nina"] = slow_hook
    ns["maybe_mesh_dwd"] = slow_hook
    ths = [threading.Thread(target=lambda f=f: [f([1]) for _ in range(3)]) for f in (ns["_alarm_hook_nina"], ns["_alarm_hook_dwd"], ns["_alarm_hook_nina"])]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    assert state["max"] == 1, "Mesh-Hooks liefen gleichzeitig (%d)" % state["max"]
    n += 1
    # Abruf-Sperre: Zyklus-Abruf (live) und Faden-Lauf nie gleichzeitig
    ns2 = build_ns(new)
    exec_blk(blk, ns2)
    st = {"in": 0, "max": 0}

    def slow_fetch():
        st["in"] += 1
        st["max"] = max(st["max"], st["in"])
        time.sleep(0.05)
        st["in"] -= 1
        return [{"city": "x", "title": "y"}]
    ns2["fetch_nina"] = slow_fetch
    ns2["data_store"] = {"last_full_update": 1}
    t1 = threading.Thread(target=lambda: ns2["_alarm_slot"]("nina"))
    t2 = threading.Thread(target=lambda: ns2["_alarm_once"]())
    t1.start()
    time.sleep(0.01)
    t2.start()
    t1.join()
    t2.join()
    assert st["max"] == 1, "NINA-Abrufe liefen gleichzeitig (%d)" % st["max"]
    n += 1
    return n


class _Stop(BaseException):
    pass


def loop_tests(new, blk):
    n = 0
    ns = build_ns(new)
    exec_blk(blk, ns)
    sleeps = []
    polls = []

    class FT:
        @staticmethod
        def sleep(x):
            sleeps.append(x)
            if len(sleeps) >= 6:
                raise _Stop()

        monotonic = staticmethod(time.monotonic)
    ns["_al_time"] = FT
    ns["data_store"] = {"last_full_update": 1}
    seq = iter([None, None, None, None, None, None, None])
    ns["fetch_nina"] = lambda: next(seq)           # Fehlschlaege hintereinander
    ns["fetch_dwd_warnungen"] = lambda: {"items": []}
    ns["_alarm_once"].__globals__["_alarm_once"] = ns["_alarm_once"]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            ns["alarm_loop"]()
    except _Stop:
        pass
    assert sleeps[0] == 300 and sleeps[1] == 300 and sleeps[2] == 300 and sleeps[3] == 600 and sleeps[4] == 900, "Abstaende bei Fehlern falsch: %s" % sleeps
    assert ns["_AL"]["started"] is False
    n += 1
    # ein Lauf, der wirft, beendet den Faden nicht
    ns = build_ns(new)
    exec_blk(blk, ns)
    sl3 = []

    class FT3:
        @staticmethod
        def sleep(x):
            sl3.append(x)
            if len(sl3) >= 4:
                raise _Stop()
        monotonic = staticmethod(time.monotonic)
    ns["_al_time"] = FT3
    ns["data_store"] = {"last_full_update": 1}

    def boom(*a, **k):
        raise RuntimeError("kaputt")
    ns["_alarm_once"] = boom
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            ns["alarm_loop"]()
    except _Stop:
        pass
    assert len(sl3) == 4 and ns["_AL"]["err"] == "kaputt", "Fehler in einem Lauf darf den Faden nicht beenden (%s)" % sl3
    n += 1
    # wartet auf das erste Voll-Update (5-s-Schritte), bevor er abruft
    ns = build_ns(new)
    exec_blk(blk, ns)
    sl = []

    class FT2:
        @staticmethod
        def sleep(x):
            sl.append(x)
            if len(sl) == 3:
                ns["data_store"]["last_full_update"] = 1
            if len(sl) >= 4:
                raise _Stop()
        monotonic = staticmethod(time.monotonic)
    ns["_al_time"] = FT2
    ns["data_store"] = {}
    called = []
    ns["fetch_nina"] = lambda: called.append(1)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            ns["alarm_loop"]()
    except _Stop:
        pass
    assert sl[:3] == [5, 5, 5] and sl[3] == 300 and not called, "Faden muss auf das erste Voll-Update warten (%s)" % sl
    n += 1
    # Selbsttest FEHLER -> kein Faden; zweiter Start -> nichts
    ns = build_ns(new)
    exec_blk(blk, ns)
    ns["_ALG"] = {"selftest": "FEHLER x"}
    ns["_al_time"] = FT
    del sleeps[:]
    ns["alarm_loop"]()
    assert not sleeps and ns["_AL"]["started"] is False, "alarm_loop darf bei fehlgeschlagenem Selbsttest nicht laufen"
    ns["_ALG"] = {"selftest": "ok"}
    ns["_AL"]["started"] = True
    ns["alarm_loop"]()
    assert not sleeps, "zweiter Start darf nichts tun"
    n += 1
    return n


def behav(alt, new, blk):
    n = 0
    ns = build_ns(new)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(rd(blk), "al_block", "exec"), ns)
    assert "alarmFaden aktiv: alarmFaden ok" in out.getvalue(), "Block-Selbsttest meldet nicht ok: %s" % out.getvalue()[:300]
    n += 1
    n += diff_update(alt, new, blk)
    n += cache_scenarios(new, blk)
    n += concurrency(new, blk)
    n += loop_tests(new, blk)
    # _alarm_status wirft nie, auch bei kaputtem Zustand
    ns["_AL"]["t"] = None
    assert "error" in ns["_alarm_status"]() or True
    st = ns["_alarm_status"]()
    assert isinstance(st, dict)
    n += 1
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_AL_NOSTATIC") == "1" else static(alt, new, blk)
    if os.environ.get("RH_AL_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau von Block und Stellen ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    assert rd(blk).rstrip("\n") in new
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk)
    print("OK guard alarmFaden: %d Pruefungen, 0 fehlerhaft" % n)
    return n


# (Name, Zielzeichenfolge, Ersatz, norev)
MUT = [
    ("M01 Frische: Grenze < statt <=", "0 <= age <= ALARM_FRESH_S", "0 <= age < ALARM_FRESH_S", 1),
    ("M02 Frische: Uhr zurueck nicht beachtet", "0 <= age <= ALARM_FRESH_S", "age <= ALARM_FRESH_S", 1),
    ("M03 Zwischenspeicher ohne Kopie", "return _al_copy.deepcopy(slot)", "return slot", 1),
    ("M04 Abruf im Zyklus fuellt Zwischenspeicher nicht", "        s = _alarm_store(which, built, deps, dur=_al_mono(deps) - t0, ok=_alarm_ok(which, raw, deps))\n", "        s = 0\n", 1),
    ("M05 Abruf im Zyklus setzt used nicht", "        with _AL_LOCK:\n            _AL[\"used\"][which] = s\n        return built", "        return built", 1),
    ("M06 Resync-Bedingung umgekehrt", 'if _AL["slot"][which] is not None and _AL["seq"][which] != _AL["used"][which]:', 'if _AL["slot"][which] is not None and _AL["seq"][which] == _AL["used"][which]:', 1),
    ("M07 Hook-Sperre NINA fehlt", "def _alarm_hook_nina(value, deps=None):\n    with _AL_HOOK_LOCK:", "def _alarm_hook_nina(value, deps=None):\n    if True:", 1),
    ("M08 Hook-Sperre DWD fehlt", "def _alarm_hook_dwd(items, deps=None):\n    with _AL_HOOK_LOCK:", "def _alarm_hook_dwd(items, deps=None):\n    if True:", 1),
    ("M09 Abruf-Sperre im Zyklus fehlt", "    with _AL_RUN_LOCK:\n        with _AL_LOCK:\n            slot, t, seq = _AL[\"slot\"][which], _AL[\"t\"][which], _AL[\"seq\"][which]\n            age = None if t is None else _al_mono(deps) - t\n            if slot is not None and age is not None and 0 <= age <= ALARM_FRESH_S:      # der Faden", "    if True:\n        with _AL_LOCK:\n            slot, t, seq = _AL[\"slot\"][which], _AL[\"t\"][which], _AL[\"seq\"][which]\n            age = None if t is None else _al_mono(deps) - t\n            if slot is not None and age is not None and 0 <= age <= ALARM_FRESH_S:      # der Faden", 1),
    ("M10 Faden: NINA-Hook fehlt", "            if \"nina\" in built:\n                _alarm_hook_nina((ds.get(\"nina\") or {}).get(\"value\"), d)", "            if False:\n                _alarm_hook_nina((ds.get(\"nina\") or {}).get(\"value\"), d)", 1),
    ("M11 Faden: DWD-Hook fehlt", "            if \"dwd\" in built:\n                dv =", "            if False:\n                dv =", 1),
    ("M12 Faden: Hooks vor Heilung", "        for nm in (\"_keep_heal_store\", \"stale_ts_paint\"):", "        for nm in ():", 1),
    ("M13 Abstand ohne Rueckzug", "    if streak < 3:\n        return ALARM_POLL_S", "    if True:\n        return ALARM_POLL_S", 1),
    ("M14 Abstand ohne Obergrenze", "return min(ALARM_MAX_S, ALARM_POLL_S * (2 ** (streak - 2)))", "return ALARM_POLL_S * (2 ** (streak - 2))", 1),
    ("M15 NINA None: error fehlt", "\"error\": raw is None, \"color\": color(key)}", "\"error\": False, \"color\": color(key)}", 1),
    ("M16 NINA None: Wert verloren", "return {\"value\": raw if raw is not None else (((prev_store or {}).get(\"nina\") or {}).get(\"value\")),", "return {\"value\": raw,", 1),
    ("M17 Abstand zu klein (20 s)", "ALARM_POLL_S = 300 ", "ALARM_POLL_S = 20 ", 1),
    ("M18 Abstand zu gross (3000 s)", "ALARM_POLL_S = 300 ", "ALARM_POLL_S = 3000 ", 1),
    ("M19 Faden trotz Selbsttest-Fehler", "or str((globals().get(\"_ALG\") or {}).get(\"selftest\", \"\")).startswith(\"FEHLER\"):", ":", 1),
    ("M20 DWD-Erfolg umgekehrt", "return fc.get(\"dwd_warn\", 0) == 0", "return fc.get(\"dwd_warn\", 0) != 0", 1),
    ("M21 Faden schreibt ohne Voll-Update", "if not isinstance(ds, dict) or not ds.get(\"last_full_update\"):", "if not isinstance(ds, dict):", 1),
    ("M22 Faden: Lage nicht neu", "                text, color, reason = lg(ds)\n                ds[\"lage\"] = {\"text\": text, \"color\": color, \"reason\": reason}", "                pass", 1),
    ("M23 Faden: DWD vor NINA", "        for which in (\"nina\", \"dwd\"):\n            t0 = _al_mono(d)", "        for which in (\"dwd\", \"nina\"):\n            t0 = _al_mono(d)", 1),
    ("M24 Faden startet ohne auf Voll-Update zu warten", "        while not (isinstance(globals().get(\"data_store\"), dict) and data_store.get(\"last_full_update\")):\n            _al_time.sleep(5)", "        pass", 1),
    ("M25 Faden: fester Abstand", "            _al_time.sleep(_alarm_interval())", "            _al_time.sleep(ALARM_POLL_S)", 1),
    ("M26 Faden: Fehler beendet Schleife", "            except Exception as e:\n                _AL[\"err\"] = str(e)[:120]\n                print(\"alarmFaden Lauf:\", e, flush=True)", "            except ZeroDivisionError as e:\n                print(\"alarmFaden Lauf:\", e, flush=True)", 1),
    ("M27 Block sendet selbst", "def _selftest_alarm():", "def _x_send():\n    send_meshtastic('x')\n\n\ndef _selftest_alarm():", 1),
    ("M28 update_all: NINA direkt", '        "nina": _alarm_slot("nina"),  # alarmFaden\n', '        "nina": fetch_nina(),  # alarmFaden\n', 0),
    ("M29 update_all: Resync fehlt", "    _alarm_resync()  # alarmFaden\n", "", 0),
    ("M30 update_all: Ping ohne Wiederholung", "ping = _ping if _ping is not None else fetch_ping()  # alarmFaden", "ping = _ping  # alarmFaden", 0),
    ("M31 update_all: lng beide weg", '        "lng": {"value": fetch_lng(), "updated": now_str(), "color": get_freshness_color("lng")},  # alarmFaden: nur einmal abrufen\n', "", 0),
    ("M32 update_all: Hook ohne Sperre", "        _alarm_hook_nina(data_store.get(\"nina\", {}).get(\"value\"))  # alarmFaden\n", "        maybe_mesh_nina(data_store.get(\"nina\", {}).get(\"value\"))  # alarmFaden\n", 0),
    ("M33 Start ohne alarm_loop", '("weather_mesh_loop", "freq_loop", "alarm_loop")', '("weather_mesh_loop", "freq_loop")', 0),
    ("M34 sysboot ohne alarm", ', "alarm": _alarm_status()})', "})", 0),
    ("M35 stille Zusatzaenderung: Server-Start", "use_reloader=False, threaded=True)  # sysBoot", "use_reloader=True, threaded=True)  # sysBoot", 0),
    ("M36 stille Zusatzaenderung: Lage", 'return "NORMAL", "#22c55e", "Keine akuten Gefahrenlagen erfasst."', 'return "NORMAL", "#22c55e", "Keine Gefahrenlagen."', 0),
    ("M37 stille Zusatzaenderung: NINA-Hook", 'if key == last_nina_mesh:\n            return False', 'if key != last_nina_mesh:\n            return False', 0),
    ("M38 DWD-Fehler im Zyklus nicht eingetragen", "                    res[which] = None          # Fehler im Abruf", "                    pass          # Fehler im Abruf", 1),
]


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    bad = []
    done = 0
    for name, a, b, norev in MUT:
        w = tempfile.mkdtemp(prefix="al-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            assert base_new.count(a) >= 1, "%s: Stelle nicht gefunden" % name
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new.replace(a, b))
            if norev:
                os.environ["RH_AL_NOREV"] = "1"
            else:
                os.environ.pop("RH_AL_NOREV", None)
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
            os.environ.pop("RH_AL_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation alarmFaden: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
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
        print("guard alarmFaden FEHLER: %s" % e)
        sys.exit(1)
AL_RAG_EOF
PPK="$W/patch-al.py"; RED="$W/edits_al.py"; RBK="$W/blk_al.py"; RGD="$W/guard_al.py"
for x in "$EXPECT_PAL $PPK" "$EXPECT_RAE $RED" "$EXPECT_RAB $RBK" "$EXPECT_RAG $RGD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (patch-al.py, edits_al.py, blk_al.py, guard_al.py)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Basis nach sameOrigin commit28" "$KNOWN_D16N" "alarmFaden schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  if [[ "$D16" == "08fbc3e35940faab" ]]; then echo "      Das ist der Stand VOR commit28 (sameOrigin). Bitte zuerst commit28 anwenden (bash /tmp/apply-sameorigin.sh commit28), danach dieses Skript noch einmal."
  else echo "      alarmFaden passt nur auf den Stand nach sameOrigin commit28 (dashboard.py 4937aa9db3e4f3e4). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."; fi
  exit 1
fi
grep -q '# ===== relHygiene:' "$F" || stop "relHygiene (commit19b) fehlt im Dashboard (Basis)"
grep -q '# ===== perfKeep:' "$F" || stop "perfKeep (commit27) fehlt im Dashboard (Basis)"
grep -q '# ===== sameOrigin:' "$F" || stop "sameOrigin (commit28) fehlt im Dashboard (Basis)"
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
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" alarmFaden dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer alarmFaden nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" alarmFaden dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
# AST-Guard: Rueckbau ergibt die bekannte Basis; dann Regeln, Verhalten (Differenztest alt/neu) und Mutationstest. Kein node noetig.
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: alarmFaden im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne alarmFaden ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard alarmFaden meldet Verstoss"; }
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
echo "Zustand vorher (nur Lesen): /api/sysboot/status enthaelt alarm: $(grep -c -F '"alarm"' "$W/sb0.json" || true) (0 = noch nicht installiert)"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: alarmFaden ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-alarmfaden-ZEIT, letzte $KEEP_LAST), Neustart nur prepper-dashboard, eine sudo-Passwortabfrage."; fi
  echo "COMMIT $COMMIT_ARG alarmfaden=dry fertig"
  exit 0
fi
[[ "$NEED_D" == 0 ]] || { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; }
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "alarmFaden|Traceback" | tail -4 | cut -c1-200
  [[ -f "$F.bak-alarmfaden-$TS" ]] && cp -a "$F.bak-alarmfaden-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-alarmfaden-$TS" ]] && { cmp -s "$F" "$F.bak-alarmfaden-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK alarmFaden schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-alarmfaden-$TS"
  { ls -1t "$F.bak-alarmfaden-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-alarmfaden-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-alarmfaden-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'alarmFaden aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; sameOrigin aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
# Funktionspruefung: Status-Schnittstelle zeigt den Faden (nur Lesen)
"${CURL[@]}" "$B/api/sysboot/status" -o "$W/sb1.json" || true
grep -q -F '"alarm"' "$W/sb1.json" || rbx "/api/sysboot/status enthaelt keinen Abschnitt alarm"
grep -q -F '"poll_s":300' "$W/sb1.json" || grep -q -F '"poll_s": 300' "$W/sb1.json" || rbx "/api/sysboot/status alarm ohne poll_s 300"
echo "OK /api/sysboot/status zeigt alarm (Abstand 300 s, Zwischenspeicher bis 900 s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/al-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E sameOrigin"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "alarmFaden aktiv: alarmFaden ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'alarmFaden aktiv: alarmFaden ok' ($(echo "$JD" | grep -F alarmFaden | tail -1 | cut -c1-200))"
    JR=$(echo "$JD" | grep -F "relHygiene aktiv: relHygiene ok" | tail -1 || true)
    [[ -n "$JR" ]] && echo "OK relHygiene weiter aktiv: $(echo "$JR" | cut -c1-120)" || rbx "Journal ohne 'relHygiene aktiv: relHygiene ok' (Regression)"
    JP=$(echo "$JD" | grep -F "perfKeep aktiv: perfKeep ok" | tail -1 || true)
    [[ -n "$JP" ]] && echo "OK perfKeep weiter aktiv: $(echo "$JP" | cut -c1-120)" || rbx "Journal ohne 'perfKeep aktiv: perfKeep ok' (Regression)"
    JS=$(echo "$JD" | grep -F "sameOrigin aktiv: sameOrigin ok" | tail -1 || true)
    [[ -n "$JS" ]] && echo "OK sameOrigin weiter aktiv: $(echo "$JS" | cut -c1-120)" || rbx "Journal ohne 'sameOrigin aktiv: sameOrigin ok' (Regression)"
    # der Faden startet erst nach dem ersten Voll-Update: bis zu 5 min warten (nur Hinweis, kein Rollback - ein langsamer Erststart ist kein Fehler)
    JT=""
    for i in $(seq 1 60); do
      JT=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat | grep -F "alarmFaden: NINA und DWD ab jetzt" | tail -1 || true)
      [[ -n "$JT" ]] && break; sleep 5
    done
    if [[ -n "$JT" ]]; then echo "OK alarm_loop gestartet: $(echo "$JT" | cut -c1-200)"
    else echo "HINWEIS alarm_loop meldet sich noch nicht (erstes Voll-Update dauert laenger als 5 min?). Spaeter pruefen: curl -s $B/api/sysboot/status (alarm.thread true, alarm.n waechst alle 5 min)"; fi
    JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true); echo "$JD" > "$W/jd.txt"
  fi
  E2=$(echo "$JD" | grep -c -E 'alarmFaden Selbsttest FEHLER|alarmFaden Lauf:|alarmFaden resync|alarmFaden NINA-Hook|alarmFaden DWD-Hook|alarmFaden Lage|sameOrigin Selbsttest FEHLER|keepLast heal:|perfKeep Selbsttest FEHLER' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne alarmFaden-/sameOrigin-/perfKeep-/keepLast-Fehler" || { echo "$JD" | grep -E 'alarmFaden|sameOrigin|perfKeep|keepLast heal:' | cut -c1-240; rbx "$E2 alarmFaden-/sameOrigin-/perfKeep-/Heilungsfehler im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein alarmFaden-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
CNT=$(grep -c '# ===== alarmFaden:' "$F" || true); CNS=$(grep -c '# ===== sameOrigin:' "$F" || true); CNR=$(grep -c '# ===== relHygiene:' "$F" || true); CNP=$(grep -c '# ===== perfKeep:' "$F" || true)
[[ "$CNT" == 1 && "$CNS" == 1 && "$CNR" == 1 && "$CNP" == 1 ]] && echo "OK Marker alarmFaden=$CNT sameOrigin=$CNS perfKeep=$CNP relHygiene=$CNR in dashboard.py" || rbx "Marker alarmFaden=$CNT sameOrigin=$CNS perfKeep=$CNP relHygiene=$CNR"
echo "Hinweis: NINA/DWD werden jetzt alle 5 min (bisher alle ~15 min) abgerufen; die Mesh-Weiterleitung folgt wie bisher denselben Regeln (Dedup, Ruhezeiten), nur frueher. Aenderbar: ALARM_POLL_S im Block alarmFaden."
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-alarmfaden-$TS" ]] && echo "Backup: dashboard.py.bak-alarmfaden-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-alarmfaden-"* 2>/dev/null || true; } | head -1); [[ -n "$LB" ]] && echo "Rueckweg (neueste Sicherung: $(basename "$LB")): cp -a $LB $F ; sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine sameOrigin-Sicherung vorhanden (nichts geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s $B/api/sysboot/status     (Abschnitt alarm: thread true, n waechst alle 5 min, src.nina.age_s/src.dwd.age_s unter 330, fails 0)"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep alarmFaden"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG alarmfaden=1 fertig"
