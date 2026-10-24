#!/bin/bash
set -euo pipefail
# airTest: baut auf dabSql (live 24.10.: prepper_sdr d7036f7f1b00e23e, sdr_manager 3d1c2a8c0a258986, dashboard 385954809ef625da). Aendert prepper_sdr.py, sdr_manager.py und dashboard.py; Hilfsprogramm, sudoers, sdr_config.json, database.py bleiben.
#  - Gain-Test fuer den Airspy 11D: feste air_gain-Stufen 12, 19, 21 (je 5 Runden, wechselnd, 15 Messungen, je ein 60-s-DAB-Pruefblock, ca. 15-17 min), protokolliert SNR, FIC-Fehlerrate und Sync-Quote je Messung (Datei sdr_airtest.json).
#  - Startet NIE von selbst: nur per Knopf auf /funk (Karte Gain-Test, mit Rueckfrage) oder POST /api/sdr/airtest (nur von der Funk-Seite im Heimnetz); GET /api/sdr/airtest liefert Zustand, Tabelle und Empfehlung. prepper-sdr entscheidet beim naechsten Planerschritt.
#  - Nie bei Alarm, ASA-Fenster, PTY31, Antennentest, Meteor-Sperre, Stick-Uebernahme oder laufender USB-Neuverbindung; ein solcher Zustand waehrend des Tests bricht ihn ab. Zeitlimit 40 min, Abbruch auch per Knopf.
#  - Die Test-Stufe steht nur in der welle-cli-Kommandozeile des 11D-Blocks. Der gespeicherte Standard-Gain (Gain-Leiter, air_gain) wird nie geaendert; Rueckfall also nach Ende, Abbruch, Fehler, Dienst-Neustart und Reboot automatisch (Zustand persistent, beim Start geprueft: lief beim Start ein Test, wird er als abgebrochen vermerkt).
#  - Gain-Leiter (dabgain_step, _air_gain_state) und Watchdog-Funktionen bleiben unveraendert; waehrend eines Testblocks werden nur die Auswertungen umhuellt: kein Gain-Stufenwechsel durch Testbloecke und keine Watchdog-Eskalation durch Test-Fehlschlaege.
#  - Anzeige: Tabelle je Stufe (Messungen, Sync, SNR, FIC-Fehler), Empfehlung nur als Anzeige (Uebernahme entscheidet Frank, manuell per air_gain), Vergleichszeile Standard-Gain aus reception_log der letzten 24 h ohne Testfenster.
#  - Keine Gain-/Watchdog-/Geraete-Aenderung, nichts gesendet (kein Mesh, keine Meldung).
# Basis streng (sha16): dabSql-Stand oder airTest schon drin. Sonst Abbruch ohne Aenderung. Neustart prepper-sdr + prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
CF="$DASH_DIR/sdr_config.json"
WDJ="$DASH_DIR/sdr_wd.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
HDST="/usr/local/sbin/prepper-sdr-wdhelper"
SYSUSB="${SDR_SYSFS_USB:-/sys/bus/usb/devices}"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/airtest-apply
KEEP_LAST=3
KNOWN_D16="385954809ef625da"     # dashboard.py nach dabSql
KNOWN_D16N="fa85999c95634cea"     # dashboard.py nach airTest (Ziel)
KNOWN_SM16="3d1c2a8c0a258986"    # sdr_manager.py nach dabSql
KNOWN_SM16N="37de138290b9e47a"    # sdr_manager.py nach airTest (Ziel)
KNOWN_SDR16="d7036f7f1b00e23e"   # prepper_sdr.py nach dabSql
KNOWN_SDR16N="a88c93cfa8dacfbe"   # prepper_sdr.py nach airTest (Ziel)
KNOWN_HL16="01c19375256b05bc"    # Hilfsprogramm nach sdrAir (bleibt unveraendert)
KNOWN_DB16="431077d36822a090"    # database.py (bleibt unveraendert)
KNOWN_MR16="c5ffda3907b0dd51"    # mesh_router.py (bleibt unveraendert)
KNOWN_LG16="3788481354f47656"    # lagegeo.py (bleibt unveraendert)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== airTest apply (Gain-Test Airspy 11D 12/19/21 nur auf Knopfdruck, Standard-Gain bleibt, Rueckfall immer, Tabelle auf /funk + /api/sdr/airtest), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_PF="dd875ef5406a3155d7996f49701e46eebf189a38b39e3dcdaa1401f25c3ab7a4"
cat > "$W/patch-fu.py" << 'AIP_EOF'
"""Patcher fuer sdrLog/funkUI. Aufruf: patch-fu.py NAME ART QUELLE ZIEL BLOCK EDITS   (ART = sm | sdr | dash). Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E, ANCH = g["%s_EDITS" % kind.upper()], g["%s_ANCHOR" % kind.upper()]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
MARK = B.splitlines()[0]
name = {"sm": "sdr_manager", "sdr": "prepper_sdr", "dash": "dashboard", "dsh": "dashboard"}[kind]   # dsh = Dashboard-Block vor dem Hauptteil (nicht eingerueckt)
if MARK in s:
    rest = s.replace(B, "", 1)
    ok = s.count(B) == 1 and all(rest.count(n) == 1 for o, n in E)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if s.count(ANCH) != 1:
    print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
if kind == "dash":
    i = s.index(ANCH) + len(ANCH)
    s = s[:i] + B + s[i:]
else:
    i = s.index(ANCH)
    s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen + Block %s" % (name, len(E), label))
AIP_EOF
EXPECT_AE="daf5fd7ee7ea05bef891555f704e2c07dc8ca1888a943f2abc73ab319a84cef3"
cat > "$W/at_edits.py" << 'AE_EOF'
# airTest: Stellen (alt, neu) auf dem Stand nach dabSql. Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
('''        selftest_dabsql()
''', '''        selftest_dabsql()
        selftest_airtest()
'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SM_EDITS = [
('''    print(selftest_dabsql())
''', '''    print(selftest_dabsql())
    print(selftest_airtest())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
AE_EOF
EXPECT_ASD="6b49f181e03781db0986c1eaf39bf92ad3827ce6578e104b74e36f31d6af57b4"
cat > "$W/at_sdr_block.py" << 'ASD_EOF'
# ===== airTest: Gain-Test Airspy 11D auf Anforderung (Knopf/API), feste Stufen 12/19/21 wechselnd je 5 Runden, protokolliert SNR/FIC-Fehlerrate/Sync je Messung; der gespeicherte Standard-Gain (Gain-Leiter, _air_gain_state) wird NIE veraendert - der Test ueberschreibt nur die welle-cli-Kommandozeile der laufenden 11D-Pruefung und endet bei Fertig/Abbruch/Sperre/Zeitlimit/Fehler/Neustart/Reboot immer mit dem Standard; Watchdog meldet waehrend des Tests keinen 11D-Ausfall; sendet nichts =====
AT_FILE = "sdr_airtest.json"
AT_REQ = "sdr_airtest_req.json"
AT_LEVELS = (12, 19, 21)
AT_ROUNDS = 5
AT_LIMIT_S = 40 * 60            # Zeitlimit des ganzen Tests
AT_MIN_S = 20                   # Messung zaehlt erst nach so vielen Sekunden Laufzeit des Pruefblocks (wie dabGain)
AT_EXTRA = 6                    # hoechstens so viele ungueltige Bloecke zusaetzlich
AT_NOSYNC_N = 6                 # die ersten 6 Messungen alle ohne Sync = Abbruch (Airspy/Antenne pruefen), Watchdog wieder aktiv
AT_REQ_STALE_S = 120
AT_CHK_S = 180                  # Pruefblock mit Test-Stufe gilt hoechstens so lange als laufend
_AT = {"run": None, "chk": None, "boot": False, "req_t": 0.0, "dropped": 0, "err_t": 0.0}
_at_orig_cmd_dab = Planner._cmd_dab
_at_orig_sub_done = Planner.sub_done
_at_orig_step = Planner.step
_at_orig_wd_check = wd_check
_at_orig_dabgain_step = dabgain_step


def _at_err(what, e):
    if time.time() - _AT["err_t"] > 300:
        _AT["err_t"] = time.time()
        print("airTest %s: %s" % (what, e), flush=True)


def _at_is_air(pl):
    try:
        return pl.cfg.get("dev_kind") == "airspy" and _air_pl(pl) is not None
    except Exception:
        return False


def _at_chk_live(now):
    c = _AT["chk"]
    return bool(c) and 0 <= now - c["t"] < AT_CHK_S


def _at_load(base):
    d = load_json(p(AT_FILE, base), {})
    return d if isinstance(d, dict) else {}


def _at_save(base, d, now):
    d["t_upd"] = int(now)
    fn = p(AT_FILE, base)
    tmp = fn + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, fn)


def _at_req_take(base, now):
    """Neue Anforderung aus der Datei des Dashboards: start | stop | None. Aeltere/bereits gesehene/zu alte werden verworfen (kein Start durch Altlast)."""
    d = load_json(p(AT_REQ, base), None)
    if not isinstance(d, dict):
        return None
    t = d.get("t")
    if not isinstance(t, (int, float)) or isinstance(t, bool) or t <= _AT["req_t"]:
        return None
    _AT["req_t"] = float(t)
    if now - t > AT_REQ_STALE_S or d.get("cmd") not in ("start", "stop"):
        return None
    return d["cmd"]


def _at_refuse(pl, now):
    """Grund, warum der Test jetzt nicht starten darf, sonst None: Sperren wie beim Watchdog (Alarm, ASA, PTY31, Antennentest, Meteor, Uebernahme), USB-Neuverbindung, kein sicherer 11D-Empfang."""
    sn = cfg_serial(pl.cfg)
    if not sn:
        return "Airspy ohne Seriennummer"
    b = _wd_block(pl, now, sn, None)
    if b:
        return b
    if _WD.get("busy"):
        return "USB-Neuverbindung läuft"
    with _WD_LOCK:
        s = ((_wd_state(pl.base, now) or {}).get("sticks") or {}).get(sn) or {}
    if s.get("inc") or not isinstance(s.get("last_ok"), (int, float)) or now - s["last_ok"] > 900:
        return "11D hat gerade keinen sicheren Empfang (Daten-Watchdog) – Test erst danach"
    return None


def _at_start(pl, now):
    d0 = _at_load(pl.base)
    why = _at_refuse(pl, now)
    if why:
        d0["msg"] = {"t": int(now), "txt": "Start abgelehnt: %s" % why}
        _at_save(pl.base, d0, now)
        pl.log("airTest: Start abgelehnt - %s" % why)
        return False
    gs = _air_gain_state(pl)
    plan = [g for _ in range(AT_ROUNDS) for g in AT_LEVELS]
    run = {"v": 1, "state": "running", "id": int(now), "t0": int(now), "t_end": None, "deadline": int(now + AT_LIMIT_S), "levels": list(AT_LEVELS), "rounds": AT_ROUNDS,
           "plan": plan, "i": 0, "tries": 0, "default": {"cur": gs.get("cur"), "ok": gs.get("ok"), "fail_n": gs.get("fail_n"), "tried": list(gs.get("tried") or [])},
           "samples": [], "why": None, "msg": None, "windows": list(d0.get("windows") or [])[-4:]}
    _AT["run"] = run
    _at_save(pl.base, run, now)
    pl.log("airTest: gestartet - Airspy 11D, Stufen %s wechselnd je %d Runden (%d Messungen à ca. %d s), gespeicherter Standard-Gain Stufe %s bleibt unveraendert, Zeitlimit %d min" % (
        "/".join(str(g) for g in AT_LEVELS), AT_ROUNDS, len(plan), 60, run["default"]["cur"], AT_LIMIT_S // 60))
    return True


def _at_finish(pl, run, state, why, now):
    """Test beenden (fertig/abgebrochen): Ueberschreibung endet sofort, Standard-Gain geprueft (und bei Abweichung auf den Stand vom Teststart gesetzt)."""
    _AT["run"] = None
    run.update(state=state, why=why or None, t_end=int(now))
    run["windows"] = (list(run.get("windows") or []) + [[run.get("t0"), int(now)]])[-5:]
    note = ""
    try:
        gs = _air_gain_state(pl)
        df = run.get("default") or {}
        if gs.get("cur") != df.get("cur"):
            gs["cur"], gs["ok"], gs["fail_n"], gs["tried"] = df.get("cur"), df.get("ok"), df.get("fail_n"), list(df.get("tried") or [])
            note = " (Gain-Leiter war veraendert - auf Stand vom Teststart zurueckgesetzt)"
    except Exception as ex:
        _at_err("Standard-Gain pruefen", ex)
    try:
        _at_save(pl.base, run, now)
    except Exception as ex:
        _at_err("speichern", ex)
    pl.log("airTest: %s%s - %d Messungen, Standard-Gain Stufe %s gilt wieder%s" % ("fertig" if state == "done" else "abgebrochen", (": " + why) if why else "", len(run.get("samples") or []),
                                                                              (run.get("default") or {}).get("cur"), note))


def _at_boot(pl, now):
    """Einmal je Prozess: lief beim Beenden/Reboot ein Test, wird er als abgebrochen vermerkt (der Standard-Gain war nie veraendert, laeuft also schon); alte Anforderungen verwerfen."""
    d = _at_load(pl.base)
    r = load_json(p(AT_REQ, pl.base), None)
    if isinstance(r, dict) and isinstance(r.get("t"), (int, float)) and not isinstance(r.get("t"), bool):
        _AT["req_t"] = max(_AT["req_t"], float(r["t"]))
    if d.get("state") == "running":
        d.update(state="aborted", why="Dienst-Neustart oder Reboot waehrend des Tests – Standard-Gain aktiv", t_end=int(now))
        d["windows"] = (list(d.get("windows") or []) + [[d.get("t0"), int(now)]])[-5:]
        _at_save(pl.base, d, now)
        pl.log("airTest: Test aus dem letzten Lauf war nicht beendet - als abgebrochen vermerkt, Standard-Gain Stufe %s aktiv" % (d.get("default") or {}).get("cur"))
    try:
        pl.log("airTest: bereit - Start nur per Knopf/API auf /funk, Standard-Gain Stufe %s bleibt unveraendert" % _air_gain_state(pl).get("cur"))
    except Exception as ex:
        _at_err("Standard-Gain pruefen", ex)


def _at_tick(pl, now):
    if not _at_is_air(pl):
        return
    if not _AT["boot"]:
        _AT["boot"] = True
        _at_boot(pl, now)
    cmd = _at_req_take(pl.base, now)
    run = _AT["run"]
    if cmd == "stop" and run is not None:
        _at_finish(pl, run, "aborted", "Abbruch per Knopf/API", now)
        return
    if cmd == "start" and run is None:
        _at_start(pl, now)
    run = _AT["run"]
    if run is None:
        if _AT["chk"] and not _at_chk_live(now):
            _AT["chk"] = None
        return
    why = None
    if now > run["deadline"]:
        why = "Zeitlimit %d min erreicht" % (AT_LIMIT_S // 60)
    else:
        b = _wd_block(pl, now, cfg_serial(pl.cfg), None)
        if b:
            why = "gesperrt: %s" % b
        elif _WD.get("busy"):
            why = "gesperrt: USB-Neuverbindung läuft"
    sm = run.get("samples") or []
    if not why and len(sm) >= AT_NOSYNC_N and not any(x.get("sync") for x in sm):
        why = "kein Sync auf allen Stufen (%d Messungen) – Airspy/Antenne prüfen" % len(sm)
    if not why and run.get("tries", 0) > AT_EXTRA:
        why = "zu viele ungültige Pruefbloecke"
    if why:
        _at_finish(pl, run, "aborted", why, now)
        return
    if run["i"] >= len(run["plan"]):
        _at_finish(pl, run, "done", "", now)
        return
    if now - int(run.get("t_upd") or 0) >= 120:
        _at_save(pl.base, run, now)


def _at_step(self):
    r = _at_orig_step(self)
    try:
        _at_tick(self, time.time())
    except Exception as ex:
        _at_err("Tick", ex)
    return r


def _at_cmd_dab(self, ch):
    """welle-cli-Kommandozeile der 11D-Pruefung: waehrend des Tests die Test-Stufe (-g), sonst unveraendert (Standard-Gain aus der Gain-Leiter)."""
    r = _at_orig_cmd_dab(self, ch)
    try:
        if str(ch) == "11D" and _at_is_air(self):
            _AT["chk"] = None
            run, now = _AT["run"], time.time()
            if run and run.get("state") == "running" and run["i"] < len(run["plan"]) and now <= run["deadline"] and isinstance(r, list) and r and isinstance(r[0], list):
                g = int(run["plan"][run["i"]])
                a = list(r[0])
                val = str(AIR2_SOAPY_GAIN[g]) if "soapysdr" in a else str(g)
                if "-g" in a:
                    a[a.index("-g") + 1] = val
                else:
                    a += ["-g", val]
                self._dg_used = {"ch": "11D", "kind": "dab", "db": "Airspy-Stufe %d (Gain-Test)" % g, "idx": g, "since": None, "air": True, "test": True}
                _AT["chk"] = {"id": run["id"], "g": g, "i": run["i"], "t": now}
                return [a] + list(r[1:])
    except Exception as ex:
        _at_err("Befehl", ex)
    return r


def _at_record(pl, chk, ran, now):
    _AT["chk"] = None
    run = _AT["run"]
    if not run or run["id"] != chk["id"] or run["i"] != chk["i"]:
        return                                                 # Test inzwischen beendet/abgebrochen: Messung verwerfen
    if ran < AT_MIN_S:
        run["tries"] = int(run.get("tries") or 0) + 1
        return
    dm = ((pl.sbc.d.get("dab") or {}).get("11D") or {}).get("demod")
    dm = dm if isinstance(dm, dict) else {}
    fresh = isinstance(dm.get("t"), (int, float)) and 0 <= now - dm["t"] < 120 and dm["t"] >= chk["t"] - 1
    sync = bool(dm.get("sync")) if fresh else False
    num = lambda v: round(float(v), 4) if isinstance(v, (int, float)) and not isinstance(v, bool) else None
    run["samples"].append({"i": run["i"], "g": chk["g"], "t": int(now), "sync": sync, "snr": num(dm.get("snr")) if sync else None, "fic": num(dm.get("fic_rate")) if sync else None,
                           "ens": str(dm.get("ens_id") or "")[:12] or None, "ran": int(ran), "st": "ok" if fresh else "kein Status"})
    run["i"] += 1
    _at_save(pl.base, run, now)


def _at_sub_done(self, sp, now):
    pre = None
    try:
        chk = _AT["chk"]
        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") and 0 <= int(sp.get("i", 0)) < len(sp["queue"]) else ""
        if chk and job.startswith("dab:") and _at_is_air(self) and str(self.dab_list()[int(job[4:])]) == "11D":
            pre = (chk, now - float(self.since or now))
    except Exception:
        pre = None
    try:
        return _at_orig_sub_done(self, sp, now)
    finally:
        if pre:
            try:
                _at_record(self, pre[0], pre[1], now)
            except Exception as ex:
                _AT["chk"] = None
                _at_err("Messung", ex)


def _at_dabgain_step(st, sync, now, ch):
    """Ergebnis eines Test-Blocks darf die Gain-Leiter nicht weiterschalten (Standard-Gain bleibt)."""
    try:
        if isinstance(st, dict) and st.get("air") and _at_chk_live(time.time()):
            return None
    except Exception:
        pass
    return _at_orig_dabgain_step(st, sync, now, ch)


def _at_wd_check(pl, src, ok, now, ch=None, why=None):
    """Waehrend des Tests (und fuer den laufenden Test-Block) kein 11D-Ausfall an den Watchdog; erfolgreicher Empfang zaehlt wie immer."""
    try:
        if not ok and src == "dab" and str(ch or "") == "11D" and _at_is_air(pl) and (_AT["run"] is not None or _at_chk_live(time.time())):
            _AT["dropped"] += 1
            return None
    except Exception:
        pass
    return _at_orig_wd_check(pl, src, ok, now, ch, why)


Planner._cmd_dab = _at_cmd_dab
Planner.sub_done = _at_sub_done
Planner.step = _at_step
dabgain_step = _at_dabgain_step
wd_check = _at_wd_check


def selftest_airtest():
    import tempfile
    tmp = tempfile.mkdtemp(prefix="airtest-sdr-")
    now0 = time.time()
    logs = []

    class _Sbc:
        def __init__(self):
            self.d = {"fm": {}, "warn": [], "dab": {}}

    class _Pl:
        def __init__(self):
            self.base = tmp
            self.cfg = {"dev_kind": "airspy", "air_fe": "airspy", "air_gain": None, "serial": "44A42E4F2A5B1C83"}
            self.sbc = _Sbc()
            self.lock = threading.Lock()
            self.dev_sn = "TESTAIR"
            self.st_pause = False
            self.since = now0
            self.air = {"on": True, "role": "11D"}

        def log(self, *a):
            logs.append(" ".join(str(x) for x in a))

        def dab_list(self):
            return ["11D"]

    pl = _Pl()
    sv = {k: _AT[k] for k in _AT}
    wd0 = {k: _WD.get(k) for k in ("d", "base", "busy")}
    o = {k: globals()[k] for k in ("_at_orig_cmd_dab", "_at_orig_sub_done", "_at_orig_wd_check", "_at_orig_dabgain_step", "_wd_block", "_air_pl")}
    calls = []
    base_cmd = [["/usr/bin/welle-cli", "-c", "11D", "-C", "1", "-w", "7979", "-F", "airspy", "-g", "16"]]
    G = globals()
    try:
        G["_air_pl"] = lambda x: x.__dict__.get("air") if x.__dict__.get("air", {}).get("on") else None
        _WD["d"], _WD["base"], _WD["busy"] = _wd_new(), tmp, None
        _WD["d"]["sticks"]["44A42E4F2A5B1C83"] = {"last_ok": now0 - 30, "inc": None}
        G["_at_orig_cmd_dab"] = lambda self, ch: [list(base_cmd[0])]
        G["_at_orig_wd_check"] = lambda pl_, src, ok, now, ch=None, why=None: calls.append(("wd", ok)) or "orig"
        G["_at_orig_dabgain_step"] = lambda st, sync, now, ch: ("step", sync)
        G["_wd_block"] = lambda pl_, now, sn, act=None: None
        gs = _air_gain_state(pl)
        assert gs["cur"] == 16
        cmd_t = [0.0]

        def block(sync, ran=60.0, snr=12.0, fic=0.01, stale=False):
            """Ein Pruefblock: Kommandozeile, Ergebnis, sub_done wie im Dienst."""
            r = _at_cmd_dab(pl, "11D")
            g = int(r[0][r[0].index("-g") + 1])
            t = time.time()
            pl.since = t - ran
            if not stale:
                pl.sbc.d["dab"]["11D"] = {"demod": {"t": int(t), "sync": sync, "snr": snr if sync else None, "fic_rate": fic if sync else None, "ens_id": "0x10a5" if sync else None}}
            else:
                pl.sbc.d["dab"]["11D"] = {"demod": {"t": int(t) - 500, "sync": True, "snr": 1.0}}
            G["_at_orig_sub_done"] = lambda self, sp, now: calls.append(("sd", _at_dabgain_step(gs, sync, now, "11D"), _at_wd_check(pl, "dab", sync, now, "11D", "x")))
            _at_sub_done(pl, {"queue": ["dab:0"], "i": 0}, t)
            return g, calls[-1]

        # 1) ohne Test: Kommandozeile und Gain-Leiter unveraendert, Watchdog-Fehler gehen durch
        assert _at_cmd_dab(pl, "11D") == base_cmd and _AT["chk"] is None and _at_dabgain_step(gs, False, 1, "11D") == ("step", False)
        assert _at_wd_check(pl, "dab", False, 1, "11D", "x") == "orig"
        # 2) Anforderung -> Start; veraltete/gleiche Anforderung nie
        open(p(AT_REQ, tmp), "w").write(json.dumps({"cmd": "start", "t": now0 - 1000}))
        _at_tick(pl, now0)
        assert _AT["run"] is None and _AT["boot"] and not os.path.exists(p(AT_FILE, tmp))             # Boot verwirft alte Anforderung
        open(p(AT_REQ, tmp), "w").write(json.dumps({"cmd": "start", "t": now0 + 1}))
        G["_wd_block"] = lambda pl_, now, sn, act=None: "echter Alarm im Lagezentrum"
        _at_tick(pl, now0 + 2)
        d = _at_load(tmp)
        assert _AT["run"] is None and "echter Alarm" in d["msg"]["txt"] and d.get("state") is None, d    # Sperre -> abgelehnt
        G["_wd_block"] = lambda pl_, now, sn, act=None: None
        _WD["d"]["sticks"]["44A42E4F2A5B1C83"] = {"last_ok": now0 - 5000, "inc": None}
        open(p(AT_REQ, tmp), "w").write(json.dumps({"cmd": "start", "t": now0 + 3}))
        _at_tick(pl, now0 + 4)
        assert _AT["run"] is None and "keinen sicheren Empfang" in _at_load(tmp)["msg"]["txt"]
        _WD["d"]["sticks"]["44A42E4F2A5B1C83"] = {"last_ok": now0 - 30, "inc": None}
        open(p(AT_REQ, tmp), "w").write(json.dumps({"cmd": "start", "t": now0 + 5}))
        _at_tick(pl, now0 + 6)
        run = _AT["run"]
        assert run and run["state"] == "running" and run["plan"][:4] == [12, 19, 21, 12] and len(run["plan"]) == 15 and run["default"]["cur"] == 16 and _at_load(tmp)["state"] == "running"
        _at_tick(pl, now0 + 7)
        assert _AT["run"] is run                                                                         # gleiche Anforderung nicht zweimal
        # 3) Messungen: Stufe 12, 19, 21 ...; Leiter + Watchdog unberuehrt
        calls.clear()
        g, c = block(True, snr=10.0, fic=0.01)
        assert g == 12 and c[1] is None and gs["cur"] == 16 and _AT["chk"] is None and run["i"] == 1 and run["samples"][0]["snr"] == 10.0, (g, c)
        g, c = block(False)
        assert g == 19 and c[1] is None and c[2] is None and gs["cur"] == 16 and gs["fail_n"] == 0 and run["samples"][1]["sync"] is False, (g, c)    # Fehlschlag: Leiter bleibt, Watchdog bekommt nichts
        assert _AT["dropped"] >= 1
        g, c = block(True, ran=5.0)
        assert g == 21 and run["i"] == 2 and run["tries"] == 1, run["i"]                                  # zu kurz: nicht gezaehlt, gleiche Stufe wieder
        g, c = block(True, stale=True)
        assert g == 21 and run["i"] == 3 and run["samples"][2]["sync"] is False and run["samples"][2]["st"] == "kein Status"
        while run["i"] < 15:
            block(True, snr=14.0, fic=0.002)
        assert [x["g"] for x in run["samples"]][:6] == [12, 19, 21, 12, 19, 21]
        _at_tick(pl, time.time())
        d = _at_load(tmp)
        assert _AT["run"] is None and d["state"] == "done" and len(d["samples"]) == 15 and d["default"]["cur"] == 16 and gs["cur"] == 16 and d["windows"], d["state"]
        assert _at_cmd_dab(pl, "11D") == base_cmd and _AT["chk"] is None                                  # danach wieder Standard
        assert _at_wd_check(pl, "dab", False, 1, "11D", "x") == "orig" and _at_dabgain_step(gs, False, 1, "11D") == ("step", False)
        assert any("fertig" in x and "Stufe 16 gilt wieder" in x for x in logs), logs[-2:]
        # 4) Abbruch: Knopf, Sperre, Zeitlimit, kein Sync, Soapy-Gain, Gain-Leiter manipuliert
        def start(n):
            open(p(AT_REQ, tmp), "w").write(json.dumps({"cmd": "start", "t": time.time() + n}))
            _at_tick(pl, time.time() + n + 0.5)
            assert _AT["run"] is not None
            return _AT["run"]
        run = start(10)
        block(True)
        open(p(AT_REQ, tmp), "w").write(json.dumps({"cmd": "stop", "t": time.time() + 11}))
        _at_tick(pl, time.time() + 11.5)
        d = _at_load(tmp)
        assert _AT["run"] is None and d["state"] == "aborted" and "Knopf" in d["why"] and len(d["samples"]) == 1 and _at_cmd_dab(pl, "11D") == base_cmd
        run = start(20)
        block(True)
        G["_wd_block"] = lambda pl_, now, sn, act=None: "ASA-Warnung/Ansage auf 5C (letzte 2 h)"
        _at_tick(pl, time.time())
        assert _AT["run"] is None and "gesperrt: ASA" in _at_load(tmp)["why"] and _at_cmd_dab(pl, "11D") == base_cmd
        G["_wd_block"] = lambda pl_, now, sn, act=None: None
        run = start(30)
        _at_tick(pl, run["deadline"] + 1)
        assert _AT["run"] is None and "Zeitlimit" in _at_load(tmp)["why"]
        run = start(40)
        for _ in range(AT_NOSYNC_N):
            block(False)
        _at_tick(pl, time.time())
        assert _AT["run"] is None and "kein Sync auf allen Stufen" in _at_load(tmp)["why"]
        pl.cfg["air_fe"] = "soapy"
        G["_at_orig_cmd_dab"] = lambda self, ch: [["/usr/bin/welle-cli", "-c", "11D", "-F", "soapysdr", "-s", "driver=airspy,serial=x", "-g", "28"]]
        run = start(50)
        a = _at_cmd_dab(pl, "11D")[0]
        assert a[a.index("-g") + 1] == str(AIR2_SOAPY_GAIN[12]) and a[a.index("-F") + 1] == "soapysdr", a
        gs["cur"] = 9                                                                                      # Gain-Leiter waehrend des Tests veraendert -> Ende setzt auf Teststart zurueck
        _at_finish(pl, run, "aborted", "Test", time.time())
        assert gs["cur"] == 16 and any("zurueckgesetzt" in x for x in logs)
        G["_at_orig_cmd_dab"] = lambda self, ch: [list(base_cmd[0])]
        pl.cfg["air_fe"] = "airspy"
        # ohne -g (Leiter 'agc'): Test haengt -g an; Fremd-Planer und anderer Kanal unberuehrt
        G["_at_orig_cmd_dab"] = lambda self, ch: [["/usr/bin/welle-cli", "-c", "11D", "-F", "airspy"]]
        run = start(60)
        a = _at_cmd_dab(pl, "11D")[0]
        assert a[-2:] == ["-g", "12"], a
        class _Other:
            cfg = {"dev_kind": "rtl"}

        other = _Other()
        assert _at_cmd_dab(other, "11D")[0][-2:] == ["-F", "airspy"] and _at_cmd_dab(pl, "5C")[0][-2:] == ["-F", "airspy"]
        _at_finish(pl, run, "aborted", "Ende", time.time())
        # 5) Neustart waehrend des Tests: Zustand 'running' in der Datei -> beim Start abgebrochen
        d = _at_load(tmp)
        d.update(state="running", samples=[], t0=int(now0))
        open(p(AT_FILE, tmp), "w").write(json.dumps(d))
        _AT["boot"] = False
        _at_tick(pl, time.time())
        d = _at_load(tmp)
        assert _AT["run"] is None and d["state"] == "aborted" and "Neustart" in d["why"]
        open(p(AT_FILE, tmp), "w").write("{kaputt")
        assert _at_load(tmp) == {}
    finally:
        for k in ("_at_orig_cmd_dab", "_at_orig_sub_done", "_at_orig_wd_check", "_at_orig_dabgain_step", "_wd_block", "_air_pl"):
            G[k] = o[k]
        _AT.update(sv)
        _AT["run"], _AT["chk"] = None, None
        for k, v in wd0.items():
            _WD[k] = v
    assert Planner._cmd_dab is _at_cmd_dab and Planner.sub_done is _at_sub_done and Planner.step is _at_step and dabgain_step is _at_dabgain_step and wd_check is _at_wd_check
    print("selftest airTest ok (Start nur auf Anforderung, Sperren/Watchdog-Stand/Zeitlimit/Kein-Sync-Abbruch, Stufen 12/19/21 wechselnd nur in der Kommandozeile, Gain-Leiter und Watchdog waehrend des Tests unberuehrt, danach/bei Abbruch/Neustart immer Standard-Gain, Zustand persistent, Soapy-Abbildung)")
ASD_EOF
EXPECT_ASM="06e8a4b6135d7bc89668553ffa396fd19e3c32b9fbc4ed91b32fb954e7359f3b"
cat > "$W/at_sm_block.py" << 'ASM_EOF'
# ===== airTest: Gain-Test Airspy 11D (Stufen 12/19/21, mehrere Runden) - Anzeige-/Datenteil: Anforderung (Knopf/API) als Datei, Zustand lesen, Tabelle + Empfehlung NUR anzeigen; aendert nie eine Einstellung, sendet nichts =====
AT_FILE = "sdr_airtest.json"
AT_REQ = "sdr_airtest_req.json"
AT_LEVELS = (12, 19, 21)
AT_ROUNDS = 5
AT_LIMIT_MIN = 40
AT_MIN_N = 3                    # Empfehlung erst ab so vielen gueltigen Messungen je Stufe
AT_SYNC_OK = 80.0               # Sync-Quote (%) mindestens fuer eine Empfehlung
AT_TIE_PCT = 5.0                # Sync-Quoten innerhalb von 5 Punkten = gleichwertig -> FIC-Fehlerrate, dann SNR
AT_STALE_S = 300                # Zustand 'laeuft' ohne Lebenszeichen laenger -> unklar


def at_req_put(base, cmd, by="dashboard", now=None):
    """Anforderung start|stop fuer prepper-sdr als Datei (atomar). Der Test startet NUR so (Knopf/API), nie automatisch."""
    now = int(now or time.time())
    if cmd not in ("start", "stop"):
        return {"ok": False, "error": "ungueltig"}
    fn = os.path.join(base, AT_REQ)
    tmp = fn + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps({"v": 1, "cmd": cmd, "t": now, "by": str(by)[:20]}, separators=(",", ":")))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, fn)
    return {"ok": True, "cmd": cmd, "t": now}


def at_load(base):
    d = _load(os.path.join(base, AT_FILE), {}) or {}
    return d if isinstance(d, dict) else {}


def _atn(x):
    return float(x) if isinstance(x, (int, float)) and not isinstance(x, bool) else None


def at_stats(samples, levels=AT_LEVELS):
    """Je Stufe: Messungen, Sync-Quote, SNR (Mittel/min) und FIC-Fehlerrate (Mittel/max, in %) nur ueber Messungen mit Sync."""
    out = []
    for g in levels:
        sm = [x for x in samples or [] if isinstance(x, dict) and x.get("g") == g]
        sy = [x for x in sm if x.get("sync")]
        sn = [v for v in (_atn(x.get("snr")) for x in sy) if v is not None]
        fc = [v * 100.0 for v in (_atn(x.get("fic")) for x in sy) if v is not None]
        out.append({"g": g, "n": len(sm), "sync_n": len(sy), "sync_pct": round(100.0 * len(sy) / len(sm), 1) if sm else None,
                    "snr_mean": round(sum(sn) / len(sn), 1) if sn else None, "snr_min": round(min(sn), 1) if sn else None,
                    "fic_mean": round(sum(fc) / len(fc), 2) if fc else None, "fic_max": round(max(fc), 2) if fc else None})
    return out


def at_recommend(rows, default_txt=""):
    """Empfehlung nur zur Anzeige: hoechste Sync-Quote (Gleichstand innerhalb 5 Punkte: niedrigere FIC-Fehlerrate, dann hoeherer SNR). Zu wenig Daten oder Sync < 80 % = keine Empfehlung."""
    ok = [r for r in rows if r["n"] >= AT_MIN_N]
    if len(ok) < len(rows):
        return {"level": None, "txt": "Keine Empfehlung: noch zu wenig gültige Messungen (je Stufe mindestens %d)." % AT_MIN_N}
    top = max(r["sync_pct"] for r in ok)
    if top < AT_SYNC_OK:
        return {"level": None, "txt": "Keine Empfehlung: keine Stufe mit Sync-Quote von mindestens %d %%." % int(AT_SYNC_OK)}
    best = sorted([r for r in ok if r["sync_pct"] >= top - AT_TIE_PCT], key=lambda r: (r["fic_mean"] if r["fic_mean"] is not None else 99.0, -(r["snr_mean"] if r["snr_mean"] is not None else -99.0)))[0]
    return {"level": best["g"], "txt": "Empfehlung (nur Anzeige): Stufe %d – Sync %s %%, SNR %s dB, FIC-Fehler %s %%. %s Übernahme entscheidet Frank, hier wird nichts geändert." % (
        best["g"], best["sync_pct"], best["snr_mean"], best["fic_mean"], default_txt)}


def at_ref(base, now, windows):
    """Vergleichswerte Standard-Gain: letzte 24 h 11D aus reception_log (je Pruefung), ohne die Testfenster. Nur lesen, wirft nie."""
    try:
        p = os.path.join(base, "lagezentrum.db")
        if db is None or not os.path.isfile(p):
            return None
        con = db.connect(p)
        try:
            if not con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='reception_log'").fetchone():
                return None
            rows = con.execute("SELECT timestamp, MAX(sync), AVG(snr), AVG(fic_rate) FROM reception_log WHERE channel='11D' AND timestamp>=? GROUP BY timestamp", (int(now) - 86400,)).fetchall()
        finally:
            con.close()
        win = [(float(a) - 90, float(b) + 90) for a, b in (windows or []) if isinstance(a, (int, float)) and isinstance(b, (int, float))]
        rows = [r for r in rows if not any(a <= r[0] <= b for a, b in win)]
        if not rows:
            return None
        sy = [r for r in rows if r[1]]
        sn = [r[2] for r in sy if isinstance(r[2], (int, float))]
        fc = [r[3] * 100.0 for r in sy if isinstance(r[3], (int, float))]
        return {"n": len(rows), "sync_pct": round(100.0 * len(sy) / len(rows), 1), "snr_mean": round(sum(sn) / len(sn), 1) if sn else None, "fic_mean": round(sum(fc) / len(fc), 2) if fc else None}
    except Exception:
        return None


def at_view(base, now=None):
    """Zustand + Tabelle + Empfehlung fuer /funk und /api/sdr/airtest. Nur lesen, wirft nie."""
    now = int(now or time.time())
    out = {"ok": True, "t": now, "state": "idle", "running": False, "rows": [], "rec": None, "ref": None, "txt": "Gain-Test: noch nie gelaufen",
           "levels": list(AT_LEVELS), "rounds": AT_ROUNDS, "limit_min": AT_LIMIT_MIN, "default": None, "msg": None, "i": 0, "total": len(AT_LEVELS) * AT_ROUNDS}
    try:
        d = at_load(base)
        if not d:
            return out
        st = str(d.get("state") or "idle")
        sm = [x for x in d.get("samples") or [] if isinstance(x, dict)]
        lv = [g for g in d.get("levels") or AT_LEVELS if isinstance(g, int)] or list(AT_LEVELS)
        out.update(state=st, running=(st == "running"), i=len(sm), total=len(d.get("plan") or []) or out["total"], t0=d.get("t0"), t_end=d.get("t_end"), why=d.get("why"), msg=d.get("msg"),
                   default=d.get("default"), rows=at_stats(sm, lv))
        df = d.get("default") if isinstance(d.get("default"), dict) else {}
        dtxt = "Standard-Gain bleibt Stufe %s." % df.get("cur") if df.get("cur") is not None else ""
        if st == "running" and now - int(d.get("t_upd") or d.get("t0") or 0) > AT_STALE_S:
            out["state"], out["running"] = "unklar", False
            out["why"] = "Zustand läuft, aber seit %d min kein Lebenszeichen (Dienst neu gestartet?) – Standard-Gain gilt" % ((now - int(d.get("t_upd") or 0)) // 60)
        out["rec"] = at_recommend(out["rows"], dtxt) if sm else None
        out["ref"] = at_ref(base, now, d.get("windows"))
        nxt = (d.get("plan") or [None] * 99)[len(sm)] if st == "running" and len(sm) < len(d.get("plan") or []) else None
        out["next_g"] = nxt
        if st == "running":
            out["txt"] = "Gain-Test läuft: Messung %d von %d (jetzt Stufe %s) · Standard-Gain Stufe %s bleibt gespeichert, Rückfall automatisch" % (len(sm) + 1, out["total"], nxt, df.get("cur"))
        elif st == "done":
            out["txt"] = "Gain-Test fertig (%s): %d Messungen · Standard-Gain Stufe %s unverändert" % (_dq_age(now - int(d.get("t_end") or now)) + " her" if d.get("t_end") else "", len(sm), df.get("cur"))
        elif st in ("aborted", "unklar"):
            out["txt"] = "Gain-Test abgebrochen: %s · %d Messungen · Standard-Gain Stufe %s gilt" % (out.get("why") or "?", len(sm), df.get("cur"))
        else:
            out["txt"] = "Gain-Test: bereit (startet nur auf Knopfdruck)"
    except Exception as e:
        out.update(ok=False, error=str(e)[:120], txt="Gain-Test: Zustand nicht lesbar")
    return out


def selftest_airtest():
    import tempfile
    d = tempfile.mkdtemp(prefix="airtest-sm-")
    now = 1790000000
    assert at_req_put(d, "start", "dashboard", now)["ok"] and _load(os.path.join(d, AT_REQ))["cmd"] == "start" and at_req_put(d, "stop", "dashboard", now + 1)["ok"] and _load(os.path.join(d, AT_REQ))["cmd"] == "stop"
    assert at_req_put(d, "reboot")["ok"] is False and at_req_put(d, "start; rm")["ok"] is False and not os.path.exists(os.path.join(d, AT_REQ + ".tmp"))
    v = at_view(d, now)
    assert v["ok"] and v["state"] == "idle" and v["rows"] == [] and "startet nur auf Knopfdruck" not in v["txt"] and "noch nie" in v["txt"], v
    pl = [g for _ in range(5) for g in AT_LEVELS]
    sm = []
    for i, g in enumerate(pl):                                    # 12: Sync 4/5, SNR 10, FIC 1 %; 19: Sync 5/5, SNR 14, FIC 0.2 %; 21: Sync 5/5, SNR 14.5, FIC 0.9 %
        k = i // 3
        sy = not (g == 12 and k == 0)
        sm.append({"i": i, "g": g, "t": now + 60 * i, "sync": sy, "snr": {12: 10.0, 19: 14.0, 21: 14.5}[g] if sy else None, "fic": {12: 0.01, 19: 0.002, 21: 0.009}[g] if sy else None})
    open(os.path.join(d, AT_FILE), "w").write(json.dumps({"state": "done", "t0": now, "t_end": now + 900, "t_upd": now + 900, "default": {"cur": 16}, "levels": list(AT_LEVELS), "plan": pl, "samples": sm, "windows": [[now, now + 900]]}))
    v = at_view(d, now + 1000)
    r = {x["g"]: x for x in v["rows"]}
    assert v["state"] == "done" and v["i"] == 15 and r[12]["sync_pct"] == 80.0 and r[19]["sync_pct"] == 100.0 and r[19]["snr_mean"] == 14.0 and r[19]["fic_mean"] == 0.2 and r[12]["n"] == 5 and r[12]["sync_n"] == 4, v
    assert v["rec"]["level"] == 19 and "nur Anzeige" in v["rec"]["txt"] and "Stufe 16" in v["rec"]["txt"] and "unverändert" in v["txt"], v["rec"]
    sm2 = [dict(x, sync=(x["g"] != 19)) for x in sm]
    assert at_recommend(at_stats(sm2), "")["level"] in (12, 21)                                # 19 ohne Sync -> nie empfohlen
    assert at_recommend(at_stats([dict(x, sync=False) for x in sm]), "")["level"] is None
    assert at_recommend(at_stats(sm[:6]), "")["level"] is None                                # je Stufe nur 2 Messungen -> keine Empfehlung
    tie = [dict(x, snr=10.0, fic=(0.001 if x["g"] == 21 else 0.01)) for x in sm]
    assert at_recommend(at_stats(tie), "")["level"] == 21                                     # Gleichstand -> niedrigere FIC-Fehlerrate
    dd = dict(_load(os.path.join(d, AT_FILE)), state="running", t_upd=now)
    open(os.path.join(d, AT_FILE), "w").write(json.dumps(dd))
    v = at_view(d, now + 10)
    assert v["state"] == "running" and v["running"] and "läuft" in v["txt"] and v["next_g"] is None, v["txt"]
    v = at_view(d, now + AT_STALE_S + 10)
    assert v["state"] == "unklar" and not v["running"] and "Standard-Gain gilt" in v["why"], v
    open(os.path.join(d, AT_FILE), "w").write("{kaputt")
    assert at_view(d, now)["state"] == "idle" and at_view("/nonexistent/x", now)["ok"] is True
    assert at_ref(d, now, []) is None and at_ref("/nonexistent/x", now, []) is None
    p = os.path.join(d, "lagezentrum.db")
    dq_migrate(p)
    con = db.connect(p)
    try:
        with con:
            for k, (ts, sy, snr, fic) in enumerate(((now - 600, 1, 12.0, 0.01), (now - 500, 1, 14.0, 0.03), (now - 400, 0, None, None), (now - 100, 1, 99.0, 0.5))):
                for tii in ((None,) if not sy else ("08/18", "05/14")):
                    con.execute("INSERT INTO reception_log(timestamp, channel, tii, snr, errors, sync, fic_rate) VALUES(?,?,?,?,NULL,?,?)", (ts, "11D", tii, snr, sy, fic))
    finally:
        con.close()
    rf = at_ref(d, now, [[now - 150, now - 50]])                                              # letzte Zeile liegt im Testfenster -> ausgenommen
    assert rf == {"n": 3, "sync_pct": 66.7, "snr_mean": 13.0, "fic_mean": 2.0}, rf
    return "sdr_manager selftest airTest ok (Anforderung start/stop atomar als Datei, Tabelle je Stufe Sync/SNR/FIC, Empfehlung nur Anzeige mit Gleichstand-Regel und Mindestdaten, Zustand unklar/kaputt wirft nie, Vergleich Standard-Gain aus reception_log ohne Testfenster)"
ASM_EOF
EXPECT_AGD="02225ae39185b7fd0da5c51ae8b3c97fc37bdab534ddd76f771e872a3a81c56f"
cat > "$W/guard_at.py" << 'AGD_EOF'
"""AST-Guard airTest. Aufruf: guard_at.py EDITS  ART ALT NEU BLOCK ...  (ART = sdr | sm | dsh; ALT = Stand nach dabSql) -> 0 ok, 1 Verstoss.
Rueckbau (Block weg, Stellen zurueck) muss Byte fuer Byte ALT ergeben. Neuer Code: kein Prozess, kein Netz, kein shell, keine Sendewege, kein Hilfsprogramm, keine USB-/Neustart-Aktion, kein Faden, keine Einstellung (air_gain/sdr_config) geschrieben;
Dateischreiben nur in _at_save (sdr_airtest.json) und at_req_put (sdr_airtest_req.json), jeweils tmp + fsync + os.replace; einzige Route /api/sdr/airtest (GET/POST); einzige Aenderung der bestehenden Namen: Planner._cmd_dab/sub_done/step, dabgain_step, wd_check (umhuellt, Originale bleiben);
der Gain-Leiter-Stand (cur) wird nur in _at_finish zurueckgesetzt, Selbsttests duerfen Temp-Ordner anlegen."""
import ast
import re
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode", "reboot", "_wd_helper", "_wd_do", "_air_usb",
       "unlink", "remove", "rmtree", "chmod", "chown", "setpriority", "thread", "restart", "usb")
WRITE_FN = ("_at_save", "at_req_put")                           # einzige Stellen mit Dateischreiben
WRITE_NM = ("open", "write", "flush", "fsync", "fileno", "replace", "dumps")
TOP_ASSIGN_OK = ("Planner._cmd_dab", "Planner.sub_done", "Planner.step", "dabgain_step", "wd_check")
JSON_OK = ("sdr_airtest.json", "sdr_airtest_req.json", "lagezentrum.db")
err = []
a = sys.argv[2:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    if new.count(B.rstrip("\n")) != 1:
        err.append("%s: Block airTest fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if r != old:
        err.append("%s: anders geaendert als %d Stellen + Block airTest" % (kind, len(E)))
    for o, n in E:
        ol = set(o.splitlines())
        low = "\n".join(x for x in n.splitlines() if x not in ol and not x.strip().startswith("assert ")).lower()
        if any(not x.strip().startswith("selftest_airtest()") and not x.strip().startswith("print(selftest_airtest())") for x in n.splitlines() if x not in ol):
            err.append("%s Stelle: nur der Selbsttest-Aufruf darf dazukommen" % kind)
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread", "_wd_helper(", "_wd_do(",
                  "uhubctl", "unbind", "fetch(", "xmlhttprequest", "takeover_set(", "reboot", "kill(", "open("):
            if k in low:
                err.append("%s Stelle: %s" % (kind, k))
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        err.append("%s Block: Syntax %s" % (kind, e)); continue
    fn_of = {}
    for f in ast.walk(t):                                      # aeusserste Funktion gewinnt (verschachtelte Hilfen im Selbsttest zaehlen als Selbsttest)
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                fn_of.setdefault(id(x), f.name)
    for n in t.body:                                           # Ebene 0: nur Konstanten, Funktionen, die erlaubten Umhuellungen (und im dsh-Block die Registrierung)
        if isinstance(n, ast.Assign):
            tg = ast.unparse(n.targets[0])
            if tg.startswith("_at_orig_") or tg.startswith(("AT_", "_AT", "_ATD")) or tg in TOP_ASSIGN_OK:
                continue
            err.append("%s Block: Zuweisung auf Ebene 0: %s" % (kind, tg))
        elif isinstance(n, ast.Try) and kind == "dsh":
            continue
        elif not isinstance(n, (ast.FunctionDef, ast.Expr)):
            err.append("%s Block: Anweisung auf Ebene 0: %s" % (kind, type(n).__name__))
    for n in ast.walk(t):
        fn = fn_of.get(id(n), "?")
        st = fn.startswith(("selftest", "_selftest"))
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if not ((mod == "tempfile" and st) or (mod == "flask" and kind == "dsh" and fn in ("_at_api", "_at_after"))):
                    err.append("%s Block: Import %s" % (kind, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s Block: shell" % kind)
        if isinstance(n, (ast.Delete,)) and not st:
            err.append("%s Block: del in %s" % (kind, fn))
        if isinstance(n, ast.Assign) and not st:
            for tg in n.targets:                               # nur _at_finish darf den Gain-Leiter-Stand (cur) zuruecksetzen
                if isinstance(tg, ast.Subscript) and isinstance(tg.slice, ast.Constant) and tg.slice.value in ("cur", "ok", "fail_n", "tried") and fn != "_at_finish":
                    err.append("%s Block: Leiter-Feld %s geschrieben in %s" % (kind, tg.slice.value, fn))
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if st and nm in ("open", "makedirs", "rename", "close", "write", "mkdtemp"):
                continue                                       # Selbsttest: Temp-Ordner
            if fn in WRITE_FN and nm in WRITE_NM and (nm != "replace" or base == "os") and (nm != "open" or (len(n.args) >= 2 and isinstance(n.args[1], ast.Constant) and n.args[1].value == "w")):
                continue                                       # tmp schreiben, fsync, os.replace
            if nm == "add_url_rule" and kind == "dsh" and n.args and isinstance(n.args[0], ast.Constant) and n.args[0].value == "/api/sdr/airtest" \
                    and all(set(k.value.elts[x].value for x in range(len(k.value.elts))) <= {"GET", "POST"} for k in n.keywords if k.arg == "methods" and isinstance(k.value, ast.List)):
                continue                                       # einzige neue Route
            if nm == "after_request" and kind == "dsh" and n.args and getattr(n.args[0], "id", "") == "_at_after":
                continue                                       # nur die Funk-Seiten-Ergaenzung
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer", "open",
                                                           "rename", "makedirs", "write", "replace", "after_request") and not (nm == "replace" and base != "os") \
                    or base in ("subprocess", "requests", "socket", "multiprocessing", "shutil"):
                err.append("%s Block: Aufruf %s in %s" % (kind, nm, fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and any(k in n.value for k in ("uhubctl", "/unbind", "bind_ports", "power/control", "/usr/local/sbin", "sudo")):
            err.append("%s Block: verbotener Text %s" % (kind, n.value[:40]))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and not st and fn != "?" and any(k in n.value for k in ("sdr_config", "air_gain", "sdr_status", "broadcast_state", "alarm_state")):
            err.append("%s Block: Einstellungs-/Fremddatei-Name %s in %s" % (kind, n.value[:30], fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and re.search(r"\.(json|db|sqlite|txt|log)$", n.value) and n.value not in JSON_OK and not st:
            err.append("%s Block: unerwartete Datei %s" % (kind, n.value[:40]))
    for n in ast.walk(t):                                       # SQL: nur Lesen, nur reception_log/meta (Selbsttest darf in der Wegwerf-DB schreiben)
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and re.match(r"(?is)\s*(SELECT|INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|ATTACH|PRAGMA)\b", n.value):
            if re.search(r"(?i)\b(DROP|ALTER|ATTACH|PRAGMA)\b", n.value):
                err.append("%s Block: SQL DROP/ALTER/ATTACH/PRAGMA: %s" % (kind, n.value[:50]))
            isw = re.match(r"(?is)\s*(INSERT|UPDATE|DELETE|CREATE|REPLACE)", n.value)
            if isw and not str(fn_of.get(id(n), "")).startswith("selftest"):
                err.append("%s Block: SQL schreibt ausserhalb des Selbsttests: %s" % (kind, n.value[:50]))
            for tb in re.findall(r"(?i)\bFROM\s+(\w+)|\bINTO\s+(\w+)|\bUPDATE\s+(\w+)\s+SET\b", n.value):
                tb = next(x for x in tb if x)
                if tb not in ("reception_log", "sqlite_master"):
                    err.append("%s Block: SQL fremde Tabelle %s: %s" % (kind, tb, n.value[:50]))
    if kind == "sdr":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_wd_helper", "_wd_do", "wd_helper_state", "_wd_decide", "_wd_save", "_wd_emit", "_air_usb", "dabgain_step", "_air_gain_state", "wd_tick", "_wd_block", "_wd_eval", "wd_check",
                   "_air_cmd_dab", "_air2_cmd_dab", "_air2_start", "_dg_sub_done"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sdr: Original %s veraendert" % fn)
        if new.count('WD_HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"') != 1:
            err.append("sdr: WD_HELPER-Pfad")
        if 'AIR_LADDER = (16, 12, 19, 9, 21, "agc")' not in new:
            err.append("sdr: Airspy-Gain-Leiter veraendert")
        for nm in ("AIR_LADDER", "AIR2_SOAPY_GAIN", "WD_HELPER", "DABGAIN_LADDER", "DABGAIN_MIN_S"):
            m = [x for x in ast.parse(old).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            m2 = [x for x in ast.parse(new).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            if [ast.dump(x) for x in m] != [ast.dump(x) for x in m2]:
                err.append("sdr: Konstante %s veraendert" % nm)
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard airTest: nur %s Stellen (Selbsttest-Aufrufe) + Bloecke; kein Prozess/Netz/shell/Sendeweg/Faden/USB-/Neustart-Aktion im neuen Code, Dateischreiben nur sdr_airtest.json (prepper-sdr) bzw. sdr_airtest_req.json (Dashboard) per tmp+fsync+replace, einzige Route /api/sdr/airtest, keine Einstellung (air_gain/sdr_config) geschrieben; Watchdog-Aktionen, Gain-Leiter/-Logik (dabgain_step, _air_gain_state, AIR_LADDER), Watchdog-Funktionen und WD_HELPER unveraendert" % (
    "/".join("%d" % len(g["%s_EDITS" % a[i].upper()]) for i in range(0, len(a), 4))))
AGD_EOF
EXPECT_AC2="8e93c983cca56d6a4149db1210c42fd9fb262be0ba597e707c49fb3b55e29c20"
cat > "$W/air2check.py" << 'AC2_EOF'
"""sdrAir2 Pruefungen fuer apply-sdrair2.sh (nur lesen). proof DIR T0 | api JSON | state DIR | hobby DIR"""
import json
import os
import re
import sys
import time

hm = lambda t: time.strftime("%d.%m. %H:%M:%S", time.localtime(t)) if isinstance(t, (int, float)) else "–"


def newest(d, name, key):
    """sqlC: Stand primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
    best = {}
    try:
        import sqlite3
        c = sqlite3.connect("file:%s?mode=ro" % os.path.join(d, "lagezentrum.db"), uri=True, timeout=10)
        try:
            r = c.execute("SELECT json FROM state WHERE key=?", (key,)).fetchone()
            best = json.loads(r[0]) if r else {}
        finally:
            c.close()
    except Exception:
        best = {}
    try:
        j = json.load(open(os.path.join(d, name), encoding="utf-8"))
        if not best or float(j.get("t") or 0) > float(best.get("t") or 0):
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def devs(d):
    try:
        c = json.load(open(os.path.join(d, "sdr_config.json"), encoding="utf-8"))
    except Exception:
        return {}
    return {str(x.get("serial") or "").upper(): x for x in c.get("devs") or [] if isinstance(x, dict) and c.get("devs_on") is True}


def main(a):
    m = a[0]
    if m == "proof":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        a1 = next((x for x in st.get("devs") or [] if isinstance(x, dict) and x.get("role") == "11D"), {})
        sn = str(a1.get("serial") or "")
        e = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {})
        dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
        dev = st.get("dev") or {}
        cpu = dev.get("cpu") or {}
        ok = bool(sn) and e.get("rx") is True and float(e.get("t") or 0) >= t0 and dm.get("sn") == sn and float(dm.get("t") or 0) >= t0
        if not ok:
            print("11D-Sync vom Airspy noch nicht nachgewiesen (Airspy SN %s, 11D Empfang %s um %s, Messung von SN %s um %s, seit Start %s)" % (
                sn or "?", e.get("rx"), hm(e.get("t")), dm.get("sn"), hm(dm.get("t")), hm(t0)))
            return 1
        print("11D-Sync vom Airspy nachgewiesen: Empfang %s, SNR %s, FIC-Fehlerrate %s · %s · welle-cli CPU %s" % (
            hm(e.get("t")), dm.get("snr"), dm.get("fic_rate"), dev.get("fe") or "?", cpu.get("txt") or "noch nicht gemessen"))
        return 0
    if m == "api":
        w = json.load(open(a[1], encoding="utf-8"))
        ss = w.get("sticks") or []
        assert w.get("lvl") in ("ok", "gelb", "rot", "grau") and ss, str(w)[:200]
        assert all(s.get("name") for s in ss), "Geraet ohne Namen: %s" % [s.get("sn") for s in ss if not s.get("name")]
        reg = any(s.get("role") for s in ss)
        assert reg, "keine Rollen in /api/sdr/wd (sdr_manager alt?)"
        assert w.get("txt") != "alle Sticks mit echtem Empfang", "alte Sammelzeile"
        hb = [s for s in ss if s.get("watch")]
        assert all(s.get("role") == "hobby" for s in hb) and (not hb or isinstance(w.get("hobby"), dict)), "Hobby-Zeile fehlt"
        if w["lvl"] == "ok":
            assert not [s for s in ss if not s.get("watch") and not s.get("absent") and s.get("lvl") != "ok"], "Gesamt ok trotz ungepruefter Geraete"
        print("/api/sdr/wd (sdrAir2): %s · %s · %s" % (w["lvl"], (w.get("short") or w.get("txt") or "")[:140], " | ".join(
            "%s %s%s" % (s["name"], s.get("lvl"), " (Hobby, nur Beobachtung)" if s.get("watch") else "") for s in ss)))
        return 0
    if m in ("state", "hobby"):
        d = a[1]
        f = os.path.join(d, "sdr_wd.json")
        if not os.path.exists(f):
            print("sdr_wd.json: noch nicht vorhanden"); return 0 if m == "state" else 1
        w = json.load(open(f, encoding="utf-8"))
        dv = devs(d)
        out, bad = [], []
        for sn, v in sorted((w.get("sticks") or {}).items()):
            x = dv.get(sn.upper()) or {}
            nm = "%s%s" % (x.get("name") or "Gerät ohne Rolle", " (Hobby)" if x.get("role") == "hobby" else "")
            i = v.get("inc")
            if not i:
                out.append("%s SN %s ok" % (nm, sn))
            else:
                out.append("%s SN %s Vorfall %s seit %s%s" % (nm, sn, i.get("ch") or "?", hm(i.get("since")), (", nur Beobachtung" if x.get("role") == "hobby" else
                                                                                                                 ", Neustart %s, USB %s" % (i.get("restart_n", 0), i.get("usb_n", 0)))))
                if x.get("role") == "hobby" and (i.get("ch") != "RDS" or i.get("restart_n") or i.get("usb_n")):
                    bad.append(sn)
        if m == "hobby":
            if bad:
                print("Hobby-Vorfall alter Art noch offen: %s" % ", ".join(bad)); return 1
            print("Hobby: kein alter Vorfall offen (%s)" % "; ".join(o for o in out if "(Hobby)" in o)); return 0
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(w.get("reboots") or []), w.get("reboot_fail_n") or 0))
        return 0
    if m == "namestest":                               # Pruefung der Pruefung: echte HB-Beispieltexte duerfen nicht anschlagen, echte Platz-Namen schon
        return names_selftest()
    if m == "names":                                   # names DIR: gespeicherte Seiten/APIs (p_*.html / p_*.json) auf alte Platz-Namen pruefen
        return names_check(a[1])
    print("unbekannt"); return 2


SLOT_RE = re.compile(r"(\bSDR ?[123]\b|\bStick [1-9]\b(?! · (?:11D|5C|Hobby|ohne Rolle)\b))")
NAME_KEYS = ("name", "model", "dev_name", "name1", "name2", "name3", "names", "1", "2", "3", "label_plain")
SKIP_KEYS = ("hist", "ev", "events", "fig", "log", "techlog", "boot_msgs", "last_inc", "inc", "msgs", "err")
TS_RE = re.compile(r"^(\d\d\.\d\d\.( \d\d:\d\d)?|\d\d:\d\d)\b")
HB_RE = re.compile(r"\bHB \d\d:\d\d\b")                # schon gesendete Heartbeat-Texte ('HB 06:02 | Lage OK | ASA OK | SDR2 5C | ...'): Verlauf, keine Live-Anzeige


def _walk(o, path, out):
    if isinstance(o, dict):
        for k, v in o.items():
            k = str(k)
            if k in SKIP_KEYS:
                continue
            if k in NAME_KEYS and isinstance(v, str):
                continue
            _walk(v, path + "." + k, out)
    elif isinstance(o, list):
        for i, v in enumerate(o[:200]):
            _walk(v, "%s[%d]" % (path, i), out)
    elif isinstance(o, str) and SLOT_RE.search(o) and not TS_RE.match(o) and not HB_RE.search(o):
        out.append("%s = %s" % (path, o[:160]))


def names_check(d):
    import glob
    import html as H
    bad = []
    n = 0
    for f in sorted(glob.glob(os.path.join(d, "p_*"))):
        n += 1
        s = open(f, encoding="utf-8", errors="replace").read()
        b = os.path.basename(f)
        if b.endswith(".json"):
            try:
                j = json.loads(s)
            except Exception:
                bad.append("%s: kein JSON" % b)
                continue
            out = []
            _walk(j, "", out)
            bad += ["%s %s" % (b, x) for x in out]
            continue
        s = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", s)
        for t in (H.unescape(x).strip() for x in re.sub(r"(?s)<[^>]+>", "\n", s).split("\n")):
            if not t or TS_RE.match(t) or HB_RE.search(t) or not SLOT_RE.search(t):
                continue
            if "dabhist" in b and not re.fullmatch(r"(Stick [1-9]|SDR ?[123])", t):
                continue                               # /dabhist: Meldungs-Texte sind Verlauf; nur Quell-Etiketten pruefen
            bad.append("%s: %s" % (b, t[:160]))
    if not n:
        print("keine Seiten gespeichert"); return 1
    if bad:
        print("alte Platz-Namen (Stick N/SDR N ohne Rolle) in %d Stellen: %s" % (len(bad), " | ".join(bad[:12]))); return 1
    print("Anzeige-Namen: %d Seiten/APIs ohne alte Platz-Namen (Stick N / SDR N nur als 'Name · Rolle'; Verlauf ausgenommen)" % n)
    return 0


def names_selftest():
    import tempfile
    hb = "HB 06:02 | Lage OK | ASA OK | SDR2 5C | Wetter 12°C 8/15° Sonne 2.1h | Uplink Telekom | 50.01 Hz"
    hb2 = "HB 03:02 | Lage OK | ASA OK | SDR2 frei | Wetter 9°C"
    d = tempfile.mkdtemp(prefix="names-")
    w = lambda n, t: open(os.path.join(d, n), "w", encoding="utf-8").write(t)
    w("p_x_mesh.html", "<html><body><div class='m'>%s</div><div>%s</div><p>Stick 1 · 5C fest</p><p>Stick 2 · Hobby</p></body></html>" % (hb, hb2))
    w("p_x_api_t4_status.json", json.dumps({"hb": {"last": {"text": hb2, "t": 1}, "n": 3}, "sdr": {"s1": {"name": "Airspy R2 · 11D"}, "s2": {"name": "Stick 1 · 5C"}}}))
    if names_check(d) != 0:
        print("Namens-Pruefung schlaegt bei gesendeten HB-Texten an"); return 1
    for n, t in (("p_x_mesh.html", "<html><body><p>Lage: SDR 2 auf 5C gekapert</p></body></html>"), ("p_x_api_t4_status.json", json.dumps({"s2": {"state": "Stick 2 wartet"}}))):
        d2 = tempfile.mkdtemp(prefix="names-")
        open(os.path.join(d2, n), "w", encoding="utf-8").write(t)
        if names_check(d2) == 0:
            print("Namens-Pruefung uebersieht Platz-Namen in %s" % n); return 1
    print("OK Namens-Pruefung getestet: gesendete HB-Texte (SDR2 5C / SDR2 frei) in /mesh und .hb.last.text zaehlen nicht, Live-Platz-Namen schon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AC2_EOF
EXPECT_ADB="4b9694d9a13e58ddb6b3f7eeee48ff954aa6995ebc0a34c9f4b3497eb2d4fd0d"
cat > "$W/at_dash_block.py" << 'ADB_EOF'
# ===== airTest: Anzeige - Karte Gain-Test auf /funk (Knopf Start/Abbruch mit Rueckfrage, Tabelle je Stufe, Empfehlung nur als Anzeige) und /api/sdr/airtest (GET Zustand, POST start|stop nur von der Funk-Seite im Heimnetz); schreibt nur die Anforderungsdatei, aendert nie eine Einstellung, sendet nichts =====
_ATD = {"t": 0.0, "v": None, "selftest": None}
_AT_CSS = """#atCard .at-s{font-size:.88rem;margin:4px 0;color:#e2e8f0}
#atCard table{border-collapse:collapse;width:100%;margin:8px 0;font-size:.85rem;font-variant-numeric:tabular-nums}
#atCard th,#atCard td{padding:3px 6px;text-align:right;border-bottom:1px solid #1e293b;white-space:nowrap}
#atCard th:first-child,#atCard td:first-child{text-align:left}
#atCard tr.at-rec td{color:#86efac;font-weight:600}
#atCard tr.at-ref td{color:#94a3b8}
#atCard .at-n{font-size:.78rem;color:#94a3b8;margin-top:4px}
#atCard .at-r{font-size:.85rem;color:#86efac;margin-top:4px}
#atCard button{margin-top:8px;width:100%;border-radius:8px;padding:10px 12px;font-size:.95rem;border:1px solid #334155;background:#1e3a5f;color:#93c5fd}
#atCard button.at-stop{background:#3f1d1d;color:#fca5a5;border-color:#7f1d1d}"""
_AT_JS = r"""(function(){var V=null,BUSY=0,MSG='';try{V=JSON.parse(document.getElementById('at-data').textContent);}catch(e){V=null;}
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function fn(x,d){return (typeof x==='number')?x.toFixed(d).replace('.',','):'\u2013';}
function row(tb,cells,cls){var r=el('tr',cls);cells.forEach(function(c){r.appendChild(el('td',null,c));});tb.appendChild(r);}
function card(){var c=document.getElementById('atCard');
if(!c){var a=document.getElementById('sdrUiCard')||document.getElementById('fuLage');if(!a||!a.parentNode)return;c=el('div','card');c.id='atCard';a.parentNode.insertBefore(c,a.nextSibling);}
if(!V)return;var sig=JSON.stringify([V,MSG,BUSY]);if(c.dataset.sig===sig)return;c.dataset.sig=sig;c.textContent='';
c.appendChild(el('div','title','\ud83d\udcf6 Gain-Test \u00b7 '+(V.dev||'Airspy 11D')));
c.appendChild(el('div','at-s',V.txt||''));
var b=el('button',V.running?'at-stop':'',V.running?'Test abbrechen':'Gain-Test starten (ca. 15\u201320 min)');b.type='button';
b.addEventListener('click',function(){post(V.running?'stop':'start',V.running?'Gain-Test abbrechen? Der Standard-Gain gilt sofort wieder.':'Gain-Test auf dem '+(V.dev||'Airspy 11D')+' starten? Stufen '+(V.levels||[]).join('/')+', je '+V.rounds+' Runden, ca. 15\u201320 Minuten. Der Standard-Gain bleibt gespeichert und gilt danach automatisch wieder; bei Alarm/Sperre bricht der Test ab.');});
c.appendChild(b);
if(MSG)c.appendChild(el('div','at-n',MSG));
if(V.msg&&V.msg.txt&&!V.running)c.appendChild(el('div','at-n',V.msg.txt));
if((V.rows||[]).length&&V.i>0){var t=el('table'),h=el('tr');['Stufe','Messungen','Sync','SNR \u00d8 (min)','FIC-Fehler \u00d8 (max)'].forEach(function(x){h.appendChild(el('th',null,x));});t.appendChild(h);
V.rows.forEach(function(r){row(t,[(V.rec&&V.rec.level===r.g?'\u2605 ':'')+r.g,r.n+' ('+r.sync_n+' mit Sync)',r.sync_pct===null?'\u2013':fn(r.sync_pct,0)+' %',fn(r.snr_mean,1)+' dB ('+fn(r.snr_min,1)+')',fn(r.fic_mean,2)+' % ('+fn(r.fic_max,2)+')'],(V.rec&&V.rec.level===r.g)?'at-rec':'');});
if(V.ref){row(t,['Standard '+((V.default||{}).cur!==undefined?(V.default||{}).cur:'')+' (24 h)',V.ref.n+' Pr\u00fcfungen',fn(V.ref.sync_pct,0)+' %',fn(V.ref.snr_mean,1)+' dB',fn(V.ref.fic_mean,2)+' %'],'at-ref');}
c.appendChild(t);
if(V.rec)c.appendChild(el('div','at-r',V.rec.txt));}
c.appendChild(el('div','at-n','Nur Airspy 11D, nur auf Knopfdruck; Standard-Gain wird nie ge\u00e4ndert; Abbruch bei Alarm/ASA/Sperre, Neustart oder Zeitlimit.'));}
function post(action,ask){if(BUSY)return;if(!window.confirm(ask))return;BUSY=1;MSG='\u2026';card();
fetch('/api/sdr/airtest',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-T2':'1'},body:JSON.stringify({action:action,confirm:true})})
.then(function(r){return r.json();}).then(function(j){MSG=j.ok?(action==='start'?'Anforderung gesendet \u2013 der Test beginnt mit dem n\u00e4chsten Pr\u00fcfblock.':'Abbruch angefordert.'):('nicht erledigt: '+(j.error||'Fehler'));})
.catch(function(){MSG='nicht erledigt: Netzfehler';}).then(function(){BUSY=0;load();setTimeout(function(){if(!BUSY){MSG='';card();}},20000);});}
function load(){fetch('/api/sdr/airtest',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.ok!==undefined){V=j;card();}}).catch(function(){});}
function loop(){load();setTimeout(loop,(V&&V.running)?5000:30000);}
try{card();}catch(e){}setInterval(function(){try{card();}catch(e){}},1000);setTimeout(loop,(V&&V.running)?5000:30000);})();"""


def _at_view_now():
    now = _t4_time.time()
    if _ATD["v"] is not None and now - _ATD["t"] < 5:
        return _ATD["v"]
    v = {"ok": False, "txt": "Gain-Test: nicht verfuegbar", "rows": [], "running": False, "state": "idle"}
    try:
        if _lz_mgr is None or not hasattr(_lz_mgr, "at_view"):
            raise RuntimeError("sdr_manager.py ohne airTest")
        v = _lz_mgr.at_view(_SDR_BASE, int(now))
        v["dev"] = _dq_dev("11D") or "Airspy 11D"
    except Exception as e:
        v = dict(v, error=str(e)[:120])
        print("airTest Anzeige:", e, flush=True)
    _ATD.update(t=now, v=v)
    return v


def _at_api():
    from flask import jsonify, request as rq
    try:
        if rq.method != "POST":
            return jsonify(_at_view_now())
        err, j = _t2d_check(rq)
        if err:
            return jsonify({"ok": False, "error": err}), j
        act = j.get("action")
        if act not in ("start", "stop"):
            return jsonify({"ok": False, "error": "ungueltig"}), 400
        with _T2D_LOCK:
            r = _lz_mgr.at_req_put(_SDR_BASE, act, "dashboard")
        _ATD["t"] = 0.0
        print("airTest: Knopf -> %s angefordert (prepper-sdr entscheidet: Sperren/Zeitlimit/Rueckfall auf Standard-Gain)" % act, flush=True)
        return jsonify(r)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


def _at_after(resp):
    try:
        from flask import request as rq
        if rq.path != "/funk" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        j = body.rfind("</body>")
        if 'id="airtest-js"' in body or j < 0:
            return resp
        dj = json.dumps(_at_view_now(), ensure_ascii=False).replace("<", "\\u003c")
        resp.set_data(body[:j] + '<style id="airtest-css">' + _AT_CSS + '</style><script type="application/json" id="at-data">' + dj + '</script><script id="airtest-js">' + _AT_JS + '</script>' + body[j:])
    except Exception as e:
        print("airTest Seite:", e, flush=True)
    return resp


def _selftest_airtest_dash():
    for k in ("/api/sdr/airtest", "atCard", "sdrUiCard", "X-T2", "window.confirm", "textContent"):
        assert k in _AT_JS or k in "/api/sdr/airtest", k
    assert _AT_JS.count("fetch(") == 2 and "innerHTML" not in _AT_JS and "eval(" not in _AT_JS and "localStorage" not in _AT_JS and ".click()" not in _AT_JS
    assert "Standard-Gain wird nie" in _AT_JS and "bleibt gespeichert" in _AT_JS and "Test abbrechen" in _AT_JS
    v0 = _ATD["v"]
    try:
        _ATD["v"], _ATD["t"] = {"ok": True, "txt": "Gain-Test: bereit", "rows": [], "running": False, "state": "idle", "dev": "Airspy R2 · 11D"}, _t4_time.time()
        j = json.dumps(_at_view_now(), ensure_ascii=False).replace("<", "\\u003c")
        assert "Airspy R2 · 11D" in j and "<" not in j
    finally:
        _ATD["v"], _ATD["t"] = v0, 0.0
    return "airTest Anzeige ok (Karte Gain-Test auf /funk mit Tabelle, Empfehlung nur Anzeige, Knopf mit Rueckfrage; /api/sdr/airtest GET Zustand, POST nur von der Funk-Seite im Heimnetz; schreibt nur die Anforderungsdatei)"


try:
    _ATD["selftest"] = _selftest_airtest_dash()
    if "airtest_api" not in app.view_functions:
        app.add_url_rule("/api/sdr/airtest", endpoint="airtest_api", view_func=_at_api, methods=["GET", "POST"])
    if not any(getattr(f, "__name__", "") == "_at_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_at_after)
    print("airTest aktiv: %s" % _ATD["selftest"], flush=True)
except Exception as _at_e:
    print("airTest Anzeige FEHLER (Funk-Seite wie bisher):", _at_e, flush=True)
ADB_EOF
EXPECT_DCK="debff908a981f7571de0dc3d2c78b7c8b724a5baf50e4c7af080280bb5e040ea"
cat > "$W/dabcheck.py" << 'DCK_EOF'
"""Pruefhilfe dabSql (nur lesen). dabcheck.py db LZ_DB T0 | api JSON_DATEI | card HTML_DATEI | counts LZ_DB"""
import json
import os
import re
import sqlite3
import sys


def ro(p):
    return sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)


def main(a):
    m = a[0] if a else ""
    if m == "db":
        p, t0 = a[1], int(a[2])
        if not os.path.isfile(p):
            print("lagezentrum.db fehlt"); return 1
        c = ro(p)
        try:
            tb = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            miss = {"masts", "reception_log", "channel_status", "meta"} - tb
            if miss:
                print("Tabellen fehlen: %s" % ",".join(sorted(miss))); return 1
            imp = c.execute("SELECT v FROM meta WHERE k='dabsql_import'").fetchone()
            if not imp:
                print("Import-Marker fehlt (noch nicht importiert)"); return 1
            nm = c.execute("SELECT src_kind, COUNT(*) FROM masts WHERE status='known' GROUP BY src_kind").fetchall()
            kn = dict(nm)
            if kn.get("amtlich", 0) < 1 or kn.get("amtlich", 0) + kn.get("nicht_amtlich", 0) < 100:
                print("zu wenige Masten importiert: %s" % kn); return 1
            n = c.execute("SELECT COUNT(*) FROM reception_log WHERE timestamp>=?", (t0,)).fetchone()[0]
            if n < 1:
                print("noch keine Pruefung seit %d in reception_log" % t0); return 1
            r = c.execute("SELECT status, last_sync, note FROM channel_status WHERE channel='11D'").fetchone()
            if not r or r[0] != "active" or not r[1]:
                print("channel_status 11D: %s" % (r,)); return 1
            nu = c.execute("SELECT COUNT(*) FROM masts WHERE status='unknown'").fetchone()[0]
            tot = c.execute("SELECT COUNT(*) FROM reception_log").fetchone()[0]
        finally:
            c.close()
        print("dabSql-Datenbank: Import %s, bekannte Masten nach Herkunft %s, reception_log %d Zeilen (%d seit Neustart), channel_status 11D aktiv (%s), unbekannte Kennungen bisher %d" % (
            json.loads(imp[0]) if imp[0].startswith("{") else imp[0], kn, tot, n, r[2], nu)); return 0
    if m == "counts":
        if not os.path.isfile(a[1]):
            print("keine Datenbank"); return 0
        c = ro(a[1])
        try:
            tb = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            print(", ".join("%s %s" % (t, c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]) if t in tb else "%s (noch nicht da)" % t for t in ("masts", "reception_log", "channel_status")))
        finally:
            c.close()
        return 0
    if m == "api":
        try:
            j = json.load(open(a[1], encoding="utf-8"))
        except Exception as e:
            print("kein JSON: %s" % e); return 1
        if not (isinstance(j, dict) and j.get("ok") is True and len(j.get("channels") or []) == 3 and (j.get("known") or {}).get("total", 0) > 0 and j.get("txt")):
            print("/api/dabsql/status unvollstaendig: %s" % json.dumps(j, ensure_ascii=False)[:200]); return 1
        print("/api/dabsql/status: %s" % j["txt"]); return 0
    if m == "card":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        if s.count('id="dqCard"') != 1:
            print("/dabhist: Zusammenfassung %dx" % s.count('id="dqCard"')); return 1
        t = re.sub(r"(?s)<[^>]+>", " ", s[s.index('id="dqCard"'):][:3000])
        if "Kanäle:" not in t or "bekannte Masten" not in t:
            print("/dabhist: Zusammenfassung ohne Kanaele/Masten"); return 1
        print("/dabhist: Zusammenfassung oben (Kanaele aktiv/offline, bekannte/unbekannte Masten, Aktualisierung)"); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
DCK_EOF
EXPECT_ACK="885f6401a7cd359a08624c090f05675e1239ea36b956b01158be60015a97026f"
cat > "$W/atcheck.py" << 'ACK_EOF'
"""Pruefhilfe airTest (nur lesen). atcheck.py api JSON_DATEI | page HTML_DATEI | state DASH_DIR"""
import json
import os
import re
import sys

STATES = ("idle", "running", "done", "aborted", "unklar")


def main(a):
    m = a[0] if a else ""
    if m == "api":
        try:
            j = json.load(open(a[1], encoding="utf-8"))
        except Exception as e:
            print("kein JSON: %s" % e); return 1
        if not (isinstance(j, dict) and j.get("ok") is True and j.get("state") in STATES and j.get("levels") == [12, 19, 21] and j.get("rounds") == 5 and j.get("txt") and isinstance(j.get("rows"), list)
                and j.get("limit_min") == 40 and j.get("dev")):
            print("/api/sdr/airtest unvollstaendig: %s" % json.dumps(j, ensure_ascii=False)[:240]); return 1
        if j.get("running"):
            print("HINWEIS: ein Gain-Test laeuft gerade (state running) - nicht vom Apply gestartet")
        print("/api/sdr/airtest: %s (Geraet %s, Stufen 12/19/21, je 5 Runden, Zeitlimit 40 min)" % (j["txt"], j["dev"])); return 0
    if m == "page":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        if s.count('id="airtest-js"') != 1 or s.count('id="at-data"') != 1 or s.count('id="airtest-css"') != 1:
            print("/funk: airTest-Bloecke js %dx, daten %dx, css %dx" % (s.count('id="airtest-js"'), s.count('id="at-data"'), s.count('id="airtest-css"'))); return 1
        mm = re.search(r'id="at-data">(.*?)</script>', s, re.S)
        try:
            j = json.loads(mm.group(1))
        except Exception as e:
            print("/funk: at-data kein JSON: %s" % e); return 1
        js = s[s.index('id="airtest-js"'):]
        for k in ("/api/sdr/airtest", "window.confirm", "Gain-Test starten", "Standard-Gain wird nie"):
            if k not in js:
                print("/funk: JS ohne %s" % k); return 1
        if j.get("ok") is not True or j.get("state") not in STATES:
            print("/funk: at-data unvollstaendig"); return 1
        print("/funk: Karte Gain-Test (Daten state %s, Knopf mit Rueckfrage, Standard-Gain bleibt)" % j["state"]); return 0
    if m == "state":
        p = os.path.join(a[1], "sdr_airtest.json")
        if not os.path.isfile(p):
            print("sdr_airtest.json noch nicht da (noch nie ein Test - normal)"); return 0
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as e:
            print("sdr_airtest.json kaputt: %s" % e); return 1
        if not isinstance(d, dict) or d.get("state") not in STATES:
            print("sdr_airtest.json: state %r" % (d.get("state") if isinstance(d, dict) else d)); return 1
        print("sdr_airtest.json: state %s, %d Messungen" % (d["state"], len(d.get("samples") or []))); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
ACK_EOF
EXPECT_AC="18e60b32ea5f0d61a7f7f992e500699693731f734370ed3e411781ca840c66dc"
cat > "$W/aircheck.py" << 'AIC_EOF'
"""sdrAir Pruefungen fuer apply-sdrair.sh (nur lesen, ausser 'cfg' = sdr_config.json Geraete-Register schreiben, atomar).
airspy SYSFS | fe WELLE | cfg DIR AIRSN FE | status DIR T0 | funk HTML | ui JSON | t2 JSON | port N"""
import json
import os
import re
import subprocess
import sys
import time

AIR = ("1d50", "60a1")
RTL = (("0bda", "2838"), ("0bda", "2832"))
S1, S2 = "19348831", "72055505"


def rd(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def norm(s):
    s = (s or "").strip().upper()
    for pre in ("AIRSPY SN:", "0X"):
        if s.startswith(pre):
            s = s[len(pre):].strip()
    return s


def newest(d, name, key):
    """sqlC: Stand liegt primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
    best = {}
    try:
        import sqlite3
        c = sqlite3.connect("file:%s?mode=ro" % os.path.join(d, "lagezentrum.db"), uri=True, timeout=10)
        try:
            r = c.execute("SELECT json FROM state WHERE key=?", (key,)).fetchone()
            best = json.loads(r[0]) if r else {}
        finally:
            c.close()
    except Exception:
        best = {}
    try:
        j = json.load(open(os.path.join(d, name), encoding="utf-8"))
        if float(j.get("t") or 0) > float(best.get("t") or 0) or not best:
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def scan(root):
    air, rtl = [], []
    for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        p = os.path.join(root, d)
        v, i = rd(os.path.join(p, "idVendor")).lower(), rd(os.path.join(p, "idProduct")).lower()
        if (v, i) == AIR:
            air.append((d, norm(rd(os.path.join(p, "serial")))))
        elif (v, i) in RTL:
            rtl.append((d, rd(os.path.join(p, "serial"))))
    return air, rtl


def main(a):
    m = a[0]
    if m == "airspy":
        air, rtl = scan(a[1])
        info = "RTL: %s" % (", ".join("%s SN %s" % x for x in rtl) or "keiner")
        if not air:
            print("kein Airspy (USB 1d50:60a1) gefunden · %s" % info); return 2
        if len(air) > 1:
            print("mehrere Airspy gefunden (%s) - Rolle 11D nicht eindeutig · %s" % (", ".join("%s SN %s" % x for x in air), info)); return 3
        sn = air[0][1]
        if not re.fullmatch(r"[0-9A-F]{16}", sn):
            print("Airspy-Seriennummer unlesbar (%r) · %s" % (sn, info)); return 4
        print(sn)
        print("Airspy SN %s an %s · %s" % (sn, air[0][0], info), file=sys.stderr)
        return 0
    if m == "fe":
        w = a[1]
        try:
            l = subprocess.run(["ldd", w], capture_output=True, text=True, timeout=20).stdout
        except Exception as e:
            print("ldd %s: %s" % (w, e)); return 1
        if "libairspy" in l:
            print("airspy"); return 0
        if "libSoapySDR" in l:
            try:
                s = subprocess.run(["SoapySDRUtil", "--info"], capture_output=True, text=True, timeout=30)
                t = (s.stdout + s.stderr).lower()
            except Exception as e:
                print("welle-cli mit SoapySDR, aber SoapySDRUtil fehlt (%s) - Airspy-Modul nicht pruefbar" % e); return 1
            if "airspy" in t:
                print("soapy"); return 0
            print("welle-cli mit SoapySDR, aber kein SoapySDR-Airspy-Modul (soapysdr-module-airspy)"); return 1
        print("welle-cli ohne Airspy-Unterstuetzung (weder libairspy noch SoapySDR gelinkt)"); return 1
    if m == "cfg":
        d, sn, fe = a[1], a[2], a[3]
        assert re.fullmatch(r"[0-9A-F]{16}", sn) and fe in ("airspy", "soapy")
        p = os.path.join(d, "sdr_config.json")
        c = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
        devs = [{"name": "Airspy R2", "kind": "airspy", "usb": "1d50:60a1", "serial": sn, "role": "11D"},
                {"name": "Stick 1", "kind": "rtl", "usb": "0bda:2838", "serial": S1, "role": "5C", "ppm_sfx": ""},
                {"name": "Stick 2", "kind": "rtl", "usb": "0bda:2838", "serial": S2, "role": "hobby", "ppm_sfx": "2"}]
        old = [{k: x.get(k) for k in ("name", "kind", "usb", "serial", "role", "ppm_sfx") if k in x} for x in c.get("devs") or [] if isinstance(x, dict)]
        keep = [x for x in old if x.get("serial") not in (sn, S1, S2)]       # spaeter eingetragene Geraete (3. Stick) bleiben
        new = devs + keep
        if c.get("devs_on") is True and c.get("air_fe") == fe and old == new:
            print("unveraendert (devs_on, %d Geraete, air_fe %s)" % (len(new), fe)); return 0
        c.update(devs_on=True, devs=new, air_fe=fe)
        t = p + ".sdrair-tmp"
        with open(t, "w", encoding="utf-8") as f:
            json.dump(c, f, ensure_ascii=False, indent=1)
            f.flush(); os.fsync(f.fileno())
        if os.path.exists(p):
            st = os.stat(p)
            try:
                os.chown(t, st.st_uid, st.st_gid)
            except OSError:
                pass
            os.chmod(t, st.st_mode & 0o777)
        os.replace(t, p)
        print("geschrieben: devs_on, Airspy R2 %s = 11D, Stick 1 %s = 5C, Stick 2 %s = Hobby%s, air_fe %s" % (sn, S1, S2, (", %d weitere behalten" % len(keep)) if keep else "", fe)); return 0
    if m == "status":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        if not st:
            print("kein SDR-Status (DB/JSON)"); return 1
        if float(st.get("t") or 0) < t0:
            print("Status noch alt"); return 1
        du = st.get("dual") or {}
        if not du.get("reg"):
            print("Status ohne Geraete-Register (dual.reg)"); return 1
        dv = {x.get("role"): x for x in st.get("devs") or [] if isinstance(x, dict)}
        a1 = dv.get("11D") or {}
        dev = st.get("dev") or {}
        dm = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {}).get("demod") or {}
        m11 = dm.get("sn") == a1.get("serial") and float(dm.get("t") or 0) >= t0          # 11D-Messung nach dem Neustart vom Airspy
        ran = m11 or str(st.get("active") or "").startswith("dab")
        if not a1.get("present") or a1.get("state") != "aktiv" or not ran:
            print("Airspy 11D nicht aktiv (angesteckt %s, %s, jetzt %s, 11D-Messung %s SN %s, Fehler %s)" % (a1.get("present"), a1.get("state"), st.get("active"), dm.get("t"), dm.get("sn"), str(st.get("err") or st.get("pin_err") or "")[:120])); return 1
        cpu = (dev.get("cpu") or {})
        print("11D vom Airspy: %s · Geraete: %s · Airspy %s · welle-cli CPU %s" % ("Sync %s, SNR %s, %s" % (dm.get("sync"), dm.get("snr"), dm.get("gain_db")) if m11 else "laeuft (noch keine Messung)",", ".join("%s=%s(%s)" % (x.get("name"), x.get("role") or "ohne Rolle", x.get("state")) for x in st.get("devs") or []),
                                                          dev.get("fe"), ("%s %% (5 min Mittel %s %%)" % (cpu.get("pct"), cpu.get("avg"))) if cpu else "noch nicht gemessen"))
        return 0
    if m == "funk":
        h = rd(a[1])
        for k in ("var AIR=", "erkannt, ohne Rolle", "s2s.style.display=(D2&&D2.air)"):
            if k not in h:
                print("/funk ohne sdrAir-Anzeige (%s)" % k); return 1
        print("/funk mit sdrAir-Anzeige (Geraetenamen, ohne Rolle, kein Uebernahme-Knopf)"); return 0
    if m == "ui":
        u = (json.load(open(a[1], encoding="utf-8")).get("dual") or {})
        if not u.get("reg") or "Airspy" not in str(u.get("label1")):
            print("/api/sdr/ui ohne Geraete-Register (%s)" % str(u)[:160]); return 1
        print("/api/sdr/ui: %s · %s" % (u.get("label1"), u.get("mode"))); return 0
    if m == "t2":
        t = json.load(open(a[1], encoding="utf-8"))
        if not t.get("air") or (t.get("takeover") or {}).get("on"):
            print("/api/t2/status: air=%s Uebernahme an=%s" % (t.get("air"), (t.get("takeover") or {}).get("on"))); return 1
        print("/api/t2/status: Geraete-Register an, Uebernahme aus (%s)" % ((t.get("takeover") or {}).get("off_by") or "war aus")); return 0
    if m == "port":
        n = int(a[1])
        s = rd("/proc/net/tcp") + "\n" + rd("/proc/net/tcp6")
        if any(len(x.split()) > 3 and x.split()[1].endswith(":%04X" % n) and x.split()[3] == "0A" for x in s.splitlines()):
            print("Port %d lauscht" % n); return 0
        print("Port %d lauscht nicht" % n); return 1
    print(__doc__); return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AIC_EOF
EXPECT_FC="d570fbd0611aa288a86ac193f77a931efc373d5b1a2ce779416b2a06c9d446ba"
cat > "$W/fucheck.py" << 'WDF_EOF'
"""Pruefhilfen sdrLog/funkUI (nur lesen). fucheck.py funk|dabhist|meteor DATEI [W] | thumb BASIS | live DATEI | techlog BASIS | pil"""
import json, os, re, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="funkui-js"', 'id="funkui-css"', 'id="fu-meteor"', "#t2Tile,#t4Sdr{display:none", 'id="t4-data"', 'id="t2-data"', 'id="sdrui-data"', 'id="stickTestCard"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="funkui-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "funkui.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    import shutil
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: JavaScript fehlerhaft")
    print("/funk: Funk-Lage, Steuerung, Meteor-Kachel eingehaengt (1x), alte Kacheln Sticks/SDR-Status verborgen, Antennentest vorhanden")
elif a == "dabhist":
    s = rd(sys.argv[2])
    assert "fu-chips" in s and "<table" not in s and "Programm-Infos" in s and "Grenzwerte" in s, "/dabhist ohne Karten/Filter"
    print("/dabhist: Karten, 44-px-Filter (Programm-Infos aus), %d Eintraege angezeigt" % s.count('class="fu-ev '))
elif a == "meteor":
    s = rd(sys.argv[2])
    assert "fu-wrap" in s and "Überflüge" in s and "<table" not in s, "/meteor ohne neue Seite"
    print("/meteor: Karten-Seite, %d Bilder, %d Vorschau-Verweise" % (s.count('class="fu-th"'), s.count("/meteor/thumb/")))
elif a == "thumb":
    d = os.path.join(sys.argv[2], "meteor")
    r = re.compile(r"^[0-9]{8}-[0-9]{4}_[A-Za-z0-9]{1,8}_[A-Za-z0-9_-]{1,40}\.(jpg|png)$")
    fs = sorted((f for f in os.listdir(d) if r.match(f)), reverse=True) if os.path.isdir(d) else []
    print(fs[0] if fs else "")
elif a == "live":
    d = json.load(open(sys.argv[2]))
    w = d.get("watchdog") or {}
    print("/api/sdr/live: Status %s, Lebenszeichen %s%s" % (d.get("status"), w.get("src") or "DB", (" (%s)" % w.get("note_mem")) if w.get("note_mem") else ""))
elif a == "techlog":
    try:
        d = json.load(open(os.path.join(sys.argv[2], "sdr_techlog.json")))
        ev = d.get("ev") or []
        print("sdr_techlog.json: %d Eintraege%s" % (len(ev), (", zuletzt %s: %s" % (time.strftime("%d.%m. %H:%M", time.localtime(ev[-1]["t"])), str(ev[-1].get("text"))[:120])) if ev else ""))
    except FileNotFoundError:
        print("sdr_techlog.json: noch nicht vorhanden (entsteht beim ersten Technik-Ereignis)")
elif a == "pil":
    for py in sys.argv[2:]:
        r = subprocess.run([py, "-c", "import PIL; print(PIL.__version__)"], capture_output=True, text=True)
        print("  %s: PIL %s" % (py, r.stdout.strip() if r.returncode == 0 else "fehlt (Vorschaubilder aus, Seite zeigt Originale)"))
WDF_EOF
EXPECT_WC="5641abe55b10e371b440b0ff9b2a590041113b29ab490d3c8951264d0469d3bc"
cat > "$W/wdcheck.py" << 'WDK_EOF'
"""Pruefhilfen sdrWd (nur lesen). wdcheck.py helper DATEI | funk DATEI W | pi DATEI | api DATEI | state BASIS | sudoers DATEI NUTZER HELFER | masts DATEI N11 N5C N10C | tii DATEI | cfg BASIS | br24 DATEI"""
import ast, json, os, re, shutil, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "helper":
    s = rd(sys.argv[2])
    t = ast.parse(s)
    assert s.startswith("#!/usr/bin/python3 -I\n"), "Shebang"
    mods = {x.name.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.Import) for x in n.names} | {n.module.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.ImportFrom)}
    assert mods <= {"fcntl", "json", "os", "re", "stat", "subprocess", "sys", "syslog", "time", "tempfile"}, mods
    calls = [n for n in ast.walk(t) if isinstance(n, ast.Call)]
    nm = lambda f: f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
    bad = [nm(c.func) for c in calls if nm(c.func) in ("system", "popen", "Popen", "execv", "execvp", "check_output", "call", "spawn", "fork", "eval", "exec")]
    assert not bad, bad
    assert s.count("subprocess.run") == 1 and s.count("(run or subprocess.run)([sc, \"reboot\"]") == 1, "nur systemctl reboot"
    body = s.split('"""', 2)[2]
    for k in ("uhubctl", "unbind", "power/control", "bind_ports"):
        assert k not in body, k
    assert 'VIDPID = ("0bda", "2838")' in s and 'SN_RE = re.compile(r"^[0-9]{8}$")' in s and '== "09"' in s and "USBDEVFS_RESET = 0x5514" in s
    assert 'AIR_VIDPID = ("1d50", "60a1")' in s and 'AIR_SN_RE = re.compile(r"^[0-9A-F]{16}$")' in s
    print("Hilfsprogramm: nur 0bda:2838 mit 8-stelliger bzw. Airspy 1d50:60a1 mit 16-stelliger Hex-Seriennummer (keine Hubs/Interfaces), einziger Prozess systemctl reboot (gesperrt: 1 je 55 min, 6 je 24 h), kein uhubctl/Portstrom/unbind")
elif a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="sdrwd-js"', 'id="sdrwd-css"', 'id="wd-data"', 'id="funkui-js"', 'id="dh-js"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "sdrwd.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: sdrWd-JavaScript fehlerhaft")
    w = json.loads(re.search(r'<script type="application/json" id="wd-data">(.*?)</script>', s, re.S).group(1))
    assert "function rel(t)" in s and "x.title=full(r)" in s, "/funk: Empfaenger-Zeilen alt"
    print("/funk: Daten-Watchdog in Funk-Lage (%s: %s), Empfänger-Zeilen einzeilig, JS geprüft" % (w.get("lvl"), (w.get("short") or w.get("txt") or "")[:90]))
elif a == "pi":
    s = rd(sys.argv[2])
    i, j = s.find('id="wdPiBox"'), s.find('id="backupBox"')
    assert s.count('id="wdPiBox"') == 1 and 0 <= i < j, "/pi: Watchdog-Kachel fehlt oder nicht vor Sicherung"
    k = s.rfind("doPrepperRestore")
    last = k < 0 or (s.find('class="tile', max(k, j)) < 0 and s.find('class="card', j + 10) < 0)
    assert last, "/pi: Sicherung nicht mehr letzte Kachel"
    m = re.search(r'Pi-Neustarts heute: [0-9]+ · zuletzt [^<]*', s)
    print("/pi: Watchdog-Kachel vor Sicherung, Sicherung letzte Kachel; %s" % (m.group(0) if m else "?"))
elif a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and "reboot_line" in d, d
    print("/api/sdr/wd: %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:100], d.get("reboot_line")))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden (entsteht mit der ersten Prüfung)")
    else:
        d = json.load(open(f))
        st = d.get("sticks") or {}
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join("Stick %s SN %s %s" % (v.get("n"), k, ("Vorfall seit %s" % time.strftime("%d.%m. %H:%M", time.localtime(v["inc"]["since"]))) if v.get("inc") else "ok")
                                                                                     for k, v in sorted(st.items())) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "sudoers":
    f, u, h = sys.argv[2:5]
    s = rd(f)
    exp = "%s ALL=(root) NOPASSWD: %s check, %s usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], %s usb-reset-air %s, %s reboot\n" % (u, h, h, h, "[0-9A-F]" * 16, h)
    lines = [x for x in s.splitlines(True) if not x.startswith("#")]
    assert lines == [exp], (lines, exp)
    print("sudoers: genau eine Regel fuer %s: %s check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot" % (u, h))
elif a == "masts":
    d = json.load(open(sys.argv[2]))
    ms = d.get("masts") or {}
    want = dict(zip(("11D", "5C", "10C"), map(int, sys.argv[3:6])))
    got = {ch: len((ms.get(ch) or {}).get("tii") or []) for ch in want}
    if got != want:
        raise SystemExit("MASTS_DB noch nicht gemeldet: %s statt %s" % (got, want))
    nm = {}
    for ch, m in ms.items():
        for x in (m or {}).get("tii") or []:
            nm["%s %02d/%02d" % (ch, x["main"], x["sub"])] = x.get("mast")
    assert nm.get("11D 08/18") == nm.get("5C 12/11") == "Bamberg (Geisberg)" and nm.get("10C 07/01") == nm.get("11D 05/14") == "Nürnberg (Schweinau)", nm
    print("/api/t2/status MASTS_DB: 11D %(11D)d, 5C %(5C)d, 10C %(10C)d Sender (Namen je Standort gleich, z. B. 08/18 = 12/11 = Bamberg (Geisberg))" % got)
elif a == "tii":
    d = json.load(open(sys.argv[2]))
    assert d.get("ok") is not False and isinstance(d.get("masts"), list), str(d)[:200]
    n = {}
    for m in d["masts"]:
        for c in m.get("ch") or []:
            n[c.get("ch")] = n.get(c.get("ch"), 0) + 1
    print("/api/t4/tii Karte: %d Standorte mit Position, %d ohne; Kennungen je Kanal %s" % (len(d["masts"]), len(d.get("nopos") or []), ", ".join("%s %d" % kv for kv in sorted(n.items()))))
elif a == "cfg":
    D = {"wd_enable": True, "wd_yellow_min": 10, "wd_restart_min": 30, "wd_usb_min": 45, "wd_reboot_min": 60, "wd_reboot_min_interval_min": 60, "wd_reboot_max_fail": 3, "wd_usb_max": 2}
    try:
        c = json.load(open(os.path.join(sys.argv[2], "sdr_config.json")))
    except Exception:
        c = {}
    out = []
    for k, v in D.items():
        x = c.get(k, v) if isinstance(c, dict) else v
        out.append("%s=%s%s" % (k, ("an" if x else "aus") if k == "wd_enable" else x, "" if not isinstance(c, dict) or k not in c else " (gesetzt)"))
    print(" ".join(out))
elif a == "br24":
    d = json.load(open(sys.argv[2]))
    t = str(d.get("bc_note") or "")
    assert "abwechselnd" not in t and "Stick 1" in t, t
    print("/api/br24 Hinweis: %s" % t[:160])
WDK_EOF
EXPECT_WC2="fb2b6f1de50294433e16c3d52fd9f20ac4771bfd55bed95782a61a16cc09432f"
cat > "$W/wdcheck2.py" << 'WDK2_EOF'
"""Pruefhilfen sdrWd2 (nur lesen). wdcheck2.py api DATEI | state BASIS | dashok DASHBOARD BLOCK | funk HTML"""
import json, os, re, sys, time
a = sys.argv[1]
hm = lambda t: time.strftime("%d.%m. %H:%M", time.localtime(t)) if isinstance(t, (int, float)) else "–"
if a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and isinstance(d.get("sticks"), list), str(d)[:200]
    for s in d["sticks"]:
        assert all(k in s for k in ("short", "pre", "to")), "Stick %s ohne sdrWd2-Felder (short/pre/to): sdr_manager alt?" % s.get("n")
    print("/api/sdr/wd (sdrWd2): %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:110], " | ".join(
        "Stick %s %s%s%s" % (s.get("n"), s.get("lvl"), " Übernahme" if s.get("to") else "", " vor Start" if s.get("pre") else "") for s in d["sticks"])))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden"); raise SystemExit(0)
    d = json.load(open(f))
    out = []
    for sn, v in sorted((d.get("sticks") or {}).items()):
        i = v.get("inc")
        if not i:
            out.append("Stick %s SN %s ok" % (v.get("n"), sn)); continue
        out.append("Stick %s SN %s Vorfall %s seit %s%s%s, Eskalation ab %s, Neustart %s, USB %s%s" % (
            v.get("n"), sn, i.get("ch") or "?", hm(i.get("since")), " (vor Start)" if i.get("pre") else "", " Übernahme" if i.get("to") else "", hm(i.get("t0")),
            i.get("restart_n", 0), i.get("usb_n", 0), (" · 10C %s" % ("ok " + hm(i.get("fb_ok_t")) if i.get("fb_ok") else "ohne Sync")) if i.get("fb_t") else ""))
    print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "dashok":
    s = open(sys.argv[2], encoding="utf-8").read()
    def lit(name):
        i = s.index(name + ' = r"""') + len(name + ' = r"""')
        return s[i:s.index('"""', i)]
    g = {"_WD_CSS": lit("_WD_CSS"), "_WD_JS": lit("_WD_JS")}
    exec(compile(open(sys.argv[3], encoding="utf-8").read(), "wd2_dash_block", "exec"), g)
    assert g["_wd2_dash_ok"](), "sdrWd2-Anzeige fehlt in _WD_CSS/_WD_JS"
    assert s.count("# ===== sdrWd2:") == 1 and s.index("# ===== sdrWd2:") < s.index("# ===== sdrWd:"), "Block-Reihenfolge"
    print("dashboard.py sdrWd2: Watchdog-Zeilen einzeilig (CSS), Kopfzeile immer, Tooltip/aufklappbar (JS), kein POST")
elif a == "funk":
    s = open(sys.argv[2], encoding="utf-8", errors="replace").read()
    css = re.search(r'<style id="sdrwd-css">(.*?)</style>', s, re.S).group(1)
    js = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S).group(1)
    assert "/* sdrWd2: Watchdog-Zeilen einzeilig */" in css and "height:1.35em;white-space:nowrap" in css and "function fx(r,k,t)" in js, "/funk: Watchdog-Zeilen alt"
    print("/funk: Watchdog-Zeilen einzeilig (feste Höhe, Kurztext mit …, voller Text per Tipp)")
WDK2_EOF
EXPECT_CK="3a6213106b1d299dbce29f237b13cdcb255661460a7d12f15c5d6455bc06cc87"
cat > "$W/sqlccheck.py" << 'WDC_EOF'
"""sqlC Pruef-/Anzeigehilfe (nur lesen). Modi: counts DB | statusfresh DIR T0 | live F | dbok F | t4 F | observe DIR SEK | audit DIR"""
import json
import os
import sqlite3
import sys
import time

KEYS = (("sdr_status.json", "sdr_status"), ("broadcast_state.json", "broadcast_state"))


def ft(t):
    try:
        return time.strftime("%H:%M:%S", time.localtime(int(t)))
    except Exception:
        return "–"


def ro(p):
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
    c.execute("PRAGMA busy_timeout=10000")
    return c


def row(p, key):
    try:
        c = ro(p)
    except Exception:
        return None
    try:
        if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='state'").fetchone():
            return None
        return c.execute("SELECT ts, src_t, json, n FROM state WHERE key=?", (key,)).fetchone()
    finally:
        c.close()


def snap(base):
    p = os.path.join(base, "lagezentrum.db")
    out = {}
    for name, key in KEYS:
        r = row(p, key)
        f = os.path.join(base, name)
        out[name] = {"db_t": float(r[1] or r[0]) if r else None, "db_n": r[3] if r else None, "json_mt": os.path.getmtime(f) if os.path.exists(f) else None}
    w = row(p, "sqlb_writer")
    out["writer"] = json.loads(w[2]) if w else {}
    out["writer_t"] = float(w[1] or w[0]) if w else None
    return out


a = sys.argv[1]
now = time.time()
if a == "counts":
    c = ro(sys.argv[2])
    try:
        q = lambda s, *x: c.execute(s, x).fetchone()[0]
        st = q("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='state'")
        print("events %d (aktiv %d), telemetry %d, state %s" % (q("SELECT COUNT(*) FROM events"), q("SELECT COUNT(*) FROM events WHERE expires IS NULL OR expires >= ?", int(now)),
              q("SELECT COUNT(*) FROM telemetry"), ("%d Zeilen" % q("SELECT COUNT(*) FROM state")) if st else "fehlt"))
    finally:
        c.close()
elif a == "statusfresh":
    base, t0 = sys.argv[2], float(sys.argv[3])
    best = 0
    r = row(os.path.join(base, "lagezentrum.db"), "sdr_status")
    try:
        best = max(best, float(json.loads(r[2]).get("t") or 0)) if r else best
    except Exception:
        pass
    try:
        best = max(best, float(json.load(open(os.path.join(base, "sdr_status.json"))).get("t") or 0))
    except Exception:
        pass
    sys.exit(0 if best >= t0 else 1)
elif a == "live":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    assert t.get("line", "").startswith("Datenquelle:") and t.get("mode") in ("db", "dual", "json") and "mirror_age_s" in t and "fallback" in t, t
    w = t.get("writer") or {}
    print("/api/sdr/live Transport: Betriebsart %s, %s; Ersatz aktiv %s, JSON-Notkopie vor %s s; Schreibfaden ok %s, Fehler %s, verworfen %s, JSON-Schreibvorgaenge %s" % (
        t["mode"], t["line"], "ja" if t.get("fallback") else "nein", t.get("mirror_age_s"), w.get("ok"), w.get("err"), w.get("drop"), w.get("json_n")))
elif a == "dbok":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    bad = {k: v.get("why") for k, v in (t.get("items") or {}).items() if v.get("src") != "db"}
    assert t.get("mode") == "db" and not bad and not t.get("fallback") and t.get("ok"), "Betriebsart %s, nicht aus DB %s, Ersatz %s (%s)" % (t.get("mode"), bad, t.get("fallback"), t.get("line"))
    print("DB-primaer aktiv: beide aus der DB, kein JSON-Ersatz")
elif a == "t4":
    d = json.load(open(sys.argv[2]))
    t = d.get("tr") or {}
    assert t.get("line", "").startswith("Datenquelle:"), d.get("tr")
    print("/api/t4/status SDR-Status-Kachel: %s" % t["line"])
elif a == "observe":
    base, secs = sys.argv[2], int(sys.argv[3])
    s0 = snap(base)
    print("  Beobachtung %d s (nur lesen): Zeit | Status DB-Alter | Status JSON-Alter | Rundfunk DB-Alter | Rundfunk JSON-Alter | Ersatz" % secs)
    ok, n, chg = True, 0, {k: 0 for k, _ in KEYS}
    last = {k: s0[k]["json_mt"] for k, _ in KEYS}
    end = time.time() + secs
    while True:
        s = snap(base)
        t = time.time()
        ag = lambda v: ("%d s" % (t - v)) if v else "–"
        fb = (s["writer"] or {}).get("fallback")
        print("  %s | %s | %s | %s | %s | %s" % (ft(t), ag(s["sdr_status.json"]["db_t"]), ag(s["sdr_status.json"]["json_mt"]), ag(s["broadcast_state.json"]["db_t"]),
                                              ag(s["broadcast_state.json"]["json_mt"]), "JA" if fb else "nein"), flush=True)
        for k, _ in KEYS:
            if s[k]["json_mt"] != last[k]:
                chg[k] += 1
                last[k] = s[k]["json_mt"]
        if not s["sdr_status.json"]["db_t"] or t - s["sdr_status.json"]["db_t"] > 90:
            ok = False
        n += 1
        if time.time() >= end:
            break
        time.sleep(min(30, max(1, end - time.time())))
    s = snap(base)
    fb = (s["writer"] or {}).get("fallback")
    db_n = (s["sdr_status.json"]["db_n"] or 0) - (s0["sdr_status.json"]["db_n"] or 0)
    print("  Ergebnis: Status %d mal in die DB geschrieben, JSON-Dateien geaendert: sdr_status.json %dx, broadcast_state.json %dx (Notkopie alle 10 min), Ersatz %s" % (
        db_n, chg["sdr_status.json"], chg["broadcast_state.json"], "AKTIV" if fb else "aus"))
    good = ok and not fb and db_n >= 1 and chg["sdr_status.json"] <= 1
    print("  %s" % ("OK DB frisch, JSON-Notkopie altert, Ersatz aus" if good else "WARNUNG: DB nicht durchgehend frisch oder JSON wird laufend geschrieben (Ersatz/Anforderung?)"))
    sys.exit(0 if good else 1)
elif a == "audit":
    base = sys.argv[2]
    own = {"dashboard.py", "sdr_manager.py", "prepper_sdr.py", "database.py"}
    skip_d = {"venv", ".git", "__pycache__", "node_modules", ".cache", "archive", "mesh_inbox", "mesh_inbox_bayern", ".local", ".npm", ".mozilla", ".config"}
    hits = []
    roots = [os.path.dirname(base.rstrip("/")) or base, "/etc/systemd/system", "/etc/cron.d"]
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            dn[:] = [x for x in dn if x not in skip_d and not x.startswith("sqlb-") and dp.count(os.sep) - root.count(os.sep) < 4]
            for f in fn:
                if ".bak" in f or f.endswith((".json", ".jsonl", ".log", ".db", ".db-wal", ".db-shm", ".tmp", ".pyc", ".jpg", ".png", ".1")) or (dp.rstrip("/") == base.rstrip("/") and f in own):
                    continue
                fp = os.path.join(dp, f)
                try:
                    if os.path.getsize(fp) > 5 * 1024 * 1024:
                        continue
                    s = open(fp, encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                if "sdr_status.json" in s or "broadcast_state.json" in s:
                    hits.append(fp)
    pat = [h for h in hits if os.path.basename(h) in own or "/src/" in h or os.path.basename(h).startswith(("apply-", "patch-", "guard_", "edits", "sql", "kv", "tii", "body", "head", "build")) or "-apply" in h or "/sbx" in h]
    oth = [h for h in hits if h not in pat]
    if not oth:
        print("  keine weiteren Leser von sdr_status.json/broadcast_state.json gefunden (ausser dashboard.py, sdr_manager.py, prepper_sdr.py - alle auf DB zuerst umgestellt)")
    for h in oth[:30]:
        print("  liest/nennt JSON direkt (bekommt die Notkopie, max. 10 min alt; laufend nur im Ersatzfall): %s" % h)
    if pat:
        print("  dazu %d alte Patch-/Pruefskripte bzw. Kopien (nur beim Einspielen benutzt, unkritisch), z. B. %s" % (len(pat), ", ".join(os.path.basename(x) for x in pat[:4])))
WDC_EOF
PF="$W/patch-fu.py"; AE="$W/at_edits.py"; ASD="$W/at_sdr_block.py"; ASM="$W/at_sm_block.py"; AGD="$W/guard_at.py"; AC2="$W/air2check.py"; ADB="$W/at_dash_block.py"; DCK="$W/dabcheck.py"; ACK="$W/atcheck.py"
AC="$W/aircheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"; CK="$W/sqlccheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_AE $AE" "$EXPECT_ASD $ASD" "$EXPECT_ASM $ASM" "$EXPECT_AGD $AGD" "$EXPECT_AC2 $AC2" "$EXPECT_ADB $ADB" "$EXPECT_DCK $DCK" "$EXPECT_ACK $ACK" "$EXPECT_AC $AC" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2" "$EXPECT_CK $CK"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ "$1" == "$4" ]] && echo "bekannt ($5)" || echo "UNBEKANNT"; }; }
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "dabSql" "$KNOWN_SDR16N" "airTest schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "dabSql" "$KNOWN_SM16N" "airTest schon drin"))"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "dabSql" "$KNOWN_D16N" "airTest schon drin"))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
[[ "$SDR16" == "$KNOWN_SDR16" || "$SDR16" == "$KNOWN_SDR16N" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16 = dabSql oder $KNOWN_SDR16N = airTest);"
[[ "$SM16" == "$KNOWN_SM16" || "$SM16" == "$KNOWN_SM16N" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16 = dabSql oder $KNOWN_SM16N = airTest);"
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 = dabSql oder $KNOWN_D16N = airTest);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      airTest passt nur auf den dabSql-Stand vom 24.10. (prepper_sdr d7036f7f1b00e23e, sdr_manager 3d1c2a8c0a258986, dashboard 385954809ef625da) - nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = dabSql (bzw. airTest schon drin), alle sha16 bekannt"
grep -q '# ===== dabSql:' "$M" && grep -q '# ===== dabSql:' "$SMF" && grep -q '# ===== dabSql:' "$F" || { echo "STOP: dabSql fehlt - nichts geaendert"; exit 1; }
[[ -x "$HDST" ]] || { echo "STOP: Hilfsprogramm $HDST fehlt - nichts geaendert"; exit 1; }
HL16=$(s16 "$HDST")
[[ "$HL16" == "$KNOWN_HL16" ]] || { echo "STOP: Hilfsprogramm sha16 $HL16 statt $KNOWN_HL16 (sdrAir) - nichts geaendert"; exit 1; }
echo "OK Hilfsprogramm $HDST sha16 $HL16 (sdrAir, bleibt)"
for k in "sdr prepper_sdr $M $ASD $KNOWN_SDR16N" "sm sdr_manager $SMF $ASM $KNOWN_SM16N" "dsh dashboard $F $ADB $KNOWN_D16N"; do set -- $k
  if [[ "$(s16 "$3")" == "$5" ]]; then cp "$3" "$W/work/$2.py"; echo "$2.py: airTest schon drin" > "$W/q_$1.log"; continue; fi
  python3 "$PF" airTest "$1" "$3" "$W/work/$2.py" "$4" "$AE" > "$W/q_$1.log" || { cat "$W/q_$1.log"; echo "STOP: $2.py airTest-Stufe passt nicht - nichts geaendert"; exit 1; }
done
NP16=$(s16 "$W/work/prepper_sdr.py"); NS16=$(s16 "$W/work/sdr_manager.py"); ND16=$(s16 "$W/work/dashboard.py")
[[ "$NP16" == "$KNOWN_SDR16N" && "$NS16" == "$KNOWN_SM16N" && "$ND16" == "$KNOWN_D16N" ]] || { echo "STOP: Ergebnis prepper_sdr.py $NP16 / sdr_manager.py $NS16 / dashboard.py $ND16 statt $KNOWN_SDR16N / $KNOWN_SM16N / $KNOWN_D16N - nichts geaendert"; exit 1; }
echo "OK Ergebnis wie erwartet: prepper_sdr.py $NP16 ($(wc -l < "$W/work/prepper_sdr.py") Zeilen), sdr_manager.py $NS16 ($(wc -l < "$W/work/sdr_manager.py") Zeilen), dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen)"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
AIRSN=$(python3 "$AC" airspy "$SYSUSB" 2>"$W/air.log") || { echo "$AIRSN"; echo "STOP: Airspy nicht eindeutig - nichts geaendert"; exit 1; }
[[ "$AIRSN" =~ ^[0-9A-F]{16}$ ]] || { echo "STOP: Airspy-Seriennummer $AIRSN - nichts geaendert"; exit 1; }
echo "OK $(cat "$W/air.log")"
FE=$(python3 -c "import json,sys;c=json.load(open(sys.argv[1]));print(c.get('air_fe') or 'airspy')" "$CF" 2>/dev/null || echo "?")
echo "OK Airspy-Frontend laut sdr_config.json: air_fe $FE ($([[ "$FE" == soapy ]] && echo "SoapySDR gewuenscht, Rueckfall -F airspy automatisch" || echo "Standard welle-cli -F airspy, bleibt"))"
# ---------- 1b) sudo-Regel pruefen (ohne gemerktes Passwort, nur lesen/check) ----------
SU=$(systemctl show -p User --value prepper-sdr 2>/dev/null || true); [[ -z "$SU" ]] && SU=root
if ! [[ "$SU" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "STOP: Benutzer von prepper-sdr unklar ($SU) - nichts geaendert"; exit 1; fi
asu() { if [[ "$(id -un)" == "$SU" ]]; then setsid -w "$@" < /dev/null; else sudo -n -u "$SU" setsid -w "$@" < /dev/null; fi; }
slist() { if [[ "$(id -un)" == "$SU" ]]; then sudo -n -l "$@"; else sudo -n -l -U "$SU" "$@"; fi; }
WD_SUDO_ERR=""; WD_SUDO_OK=""
wd_sudo_verify() {
  local c out rc
  for c in "check" "usb-reset 19348831" "usb-reset-air $AIRSN" "reboot"; do
    rc=0; slist "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?
    [[ "$rc" == 0 ]] || { WD_SUDO_ERR="sudo -l: $HDST $c fuer $SU nicht erlaubt (rc $rc: $(head -c 200 "$W/sl.log" | tr '\n' ' '))"; return 1; }
  done
  # sudo -k: gemerktes Passwort (z. B. vom sudo -v dieses Skripts, Zeitstempel global) zaehlt nicht - nur die NOPASSWD-Regel
  rc=0; out=$(asu sudo -k -n "$HDST" check 2>&1) || rc=$?
  [[ "$rc" == 0 && "$out" == *"bereit (uid 0)"* ]] || { WD_SUDO_ERR="$SU kann $HDST check nicht ohne Passwort und ohne Terminal ausfuehren (rc $rc: $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200))"; return 1; }
  rc=0; asu sudo -k -n true > /dev/null 2>&1 || rc=$?
  slist > "$W/slall.log" 2>&1 || true
  if [[ "$rc" == 0 ]] && grep -qE 'NOPASSWD: *ALL *$' "$W/slall.log"; then
    WD_SUDO_OK="$HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot ohne Passwort geprueft (sudo -k, ohne Terminal); Hinweis: $SU hat laut sudo -l NOPASSWD: ALL - Gegenprobe entfaellt"; return 0
  fi
  for c in "selftest" "usb-reset 1234" "usb-reset 19348831 x" "usb-reset ../x" "usb-reset-air 1234" "usb-reset-air ${AIRSN,,}" "usb-reset-air $AIRSN x" "usb-reset-air ../x"; do
    rc=0; out=$(asu sudo -k -n "$HDST" $c 2>&1) || rc=$?
    [[ "$rc" != 0 && "$out" == sudo:* ]] || { WD_SUDO_ERR="sudo erlaubt zu viel ohne Passwort: $HDST $c (rc $rc)"; return 1; }
  done
  WD_SUDO_OK="nur $HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex gross> | reboot ohne Passwort (sudo -k, ohne Terminal wie im Dienst), andere Aufrufe verlangen Passwort; allgemeines sudo verlangt Passwort"
}
if [[ "$SU" != root ]]; then
  wd_sudo_verify || { echo "STOP: sudo-Regel: $WD_SUDO_ERR - nichts geaendert"; exit 1; }
  echo "OK sudo-Regel fuer $SU: $WD_SUDO_OK"
fi
# ---------- 2) Trockenlauf ----------
for k in "sdr prepper_sdr $ASD" "sm sdr_manager $ASM" "dsh dashboard $ADB"; do set -- $k
  python3 "$PF" airTest "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$AE" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/work/dashboard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$LG" ]] && cp "$LG" "$W/sbx/"
cp "$DBF" "$MR" "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/airtest-selftest timeout 300 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok" "sdr_manager selftest sdrWd ok" "sdr_manager selftest sdrWd2 ok" "sdr_manager selftest sdrAir ok" "sdr_manager selftest sdrAir2 ok" "sdr_manager selftest dabSql ok" "sdr_manager selftest airTest ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/airtest-selftest timeout 600 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok" "selftest sdrWd2 ok" "selftest sdrAir ok" "selftest sdrAir2 ok" "selftest dabSql ok" "selftest airTest ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum, Fake-Hilfsprogramm, Fake-SoapySDR-Modul; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet)"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest airTest ok' "$W/sdrt.log" | tail -1 | cut -c1-400)"
  echo "   $(grep -F 'sdr_manager selftest airTest ok' "$W/smt.log" | tail -1 | cut -c1-300)"
done
if [[ "$SDR16" == "$KNOWN_SDR16N" && "$SM16" == "$KNOWN_SM16N" && "$D16" == "$KNOWN_D16N" ]]; then
  echo "OK airTest schon drin - Guard-Rueckbau gegen Basis entfaellt (Inhalt = gepruefter Zielstand, sha16)"
else
  python3 "$AGD" "$AE" sdr "$M" "$W/work/prepper_sdr.py" "$ASD" sm "$SMF" "$W/work/sdr_manager.py" "$ASM" dsh "$F" "$W/work/dashboard.py" "$ADB" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard dabSql - nichts geaendert"; exit 1; }
  echo "$(cat "$W/g.log")"
fi
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
python3 "$AC2" namestest > "$W/nt.log" 2>&1 && echo "$(tail -1 "$W/nt.log")" || { cat "$W/nt.log"; echo "STOP: Namens-Pruefung selbst fehlerhaft - nichts geaendert"; exit 1; }
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
echo "Watchdog vorher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-360)"
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
ATREQ0=0; [[ -f "$DASH_DIR/sdr_airtest_req.json" ]] && ATREQ0=1
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert) ----------
trap '' INT
RESTARTED=0
ALL=("$M" "$SMF" "$F")
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK airTest schon installiert (prepper_sdr.py, sdr_manager.py, dashboard.py) - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    for u in prepper-sdr prepper-dashboard; do sudo journalctl -u "$u" --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrAir|sdrWd|Traceback" | tail -4 | cut -c1-200 || true; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-airtest-$TS" ]] && cp -a "$x.bak-airtest-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-airtest-$TS" ]] || continue; cmp -s "$x" "$x.bak-airtest-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Sicherungen von vorher: $LZ.bak-airtest-$TS, $WDJ.bak-airtest-$TS (nicht zurueckgespielt; Watchdog-Zustand bleibt)"
    echo "alter Stand (dabSql) wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$WDJ"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-airtest-$TS"
    { ls -1t "$x.bak-airtest-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-airtest-$TS" \
      || { rm -f "$LZ.bak-airtest-$TS"; for x in "${ALL[@]}" "$WDJ"; do rm -f "$x.bak-airtest-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-airtest-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "prepper_sdr $M" "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-airtest-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (max 240 s) und 11D-Sync vom Airspy (max 300 s; sendet nichts) ..."
  sudo systemctl restart prepper-sdr.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$AC" status "$DASH_DIR" "$T0" > "$W/ast.log" 2>&1 && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { cat "$W/ast.log"; rb "prepper-sdr: Airspy 11D laeuft nicht ($(head -c 200 "$W/ast.log"))"; exit 1; }
  pok=0; for i in $(seq 1 120); do python3 "$AC" port 7979 > "$W/port.log" 2>&1 && { pok=1; break; }; sleep 1; done
  [[ "$pok" == 1 ]] && echo "OK welle-cli (Airspy) $(cat "$W/port.log")" || { rb "Port 7979 (welle-cli Airspy) lauscht nicht"; exit 1; }
  sok=0; for i in $(seq 1 100); do python3 "$AC2" proof "$DASH_DIR" "$T0" > "$W/proof.log" 2>&1 && { sok=1; break; }; sleep 3; done
  [[ "$sok" == 1 ]] && echo "OK $(cut -c1-460 "$W/proof.log")" || { cat "$W/proof.log"; rb "11D-Sync vom Airspy nach 300 s nicht nachgewiesen"; exit 1; }
  echo "Neustart prepper-dashboard (laedt dashboard.py + sdr_manager.py neu) - warte auf HTTP (max 240 s) ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist /karte /api/sdr/wd /api/sdr/ui /api/t2/status /api/t4/status /api/t4/tii /api/br24; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
python3 "$FC" funk "$W/funk.html" "$W" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/funk ohne funkUI"; }
python3 "$WC" funk "$W/funk.html" "$W" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne Daten-Watchdog"; }
python3 "$WC2" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk Watchdog-Zeilen"; }
python3 "$AC" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne sdrAir-Anzeige"; }
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$WC" pi "$W/pi.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/pi Watchdog-Kachel"; }
"${CURL[@]}" "$B/dabhist" -o "$W/dabhist.html" || true
[[ -s "$W/dabhist.html" ]] && echo "OK /dabhist $(wc -c < "$W/dabhist.html") Bytes" || rbx "/dabhist leer"
uok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/ui" -o "$W/ui.json" || true; python3 "$AC" ui "$W/ui.json" > "$W/wc.log" 2>&1 && { uok=1; break; }; sleep 6; done
[[ "$uok" == 1 ]] && echo "OK $(cut -c1-300 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/ui ohne Geraete-Register"; }
tok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/t2/status" -o "$W/t2.json" || true; python3 "$AC" t2 "$W/t2.json" > "$W/wc.log" 2>&1 && { tok=1; break; }; sleep 6; done
[[ "$tok" == 1 ]] && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t2/status Register"; }
wok=0; for i in $(seq 1 30); do "${CURL[@]}" "$B/api/sdr/wd" -o "$W/wd.json" || true; python3 "$AC2" api "$W/wd.json" > "$W/wc.log" 2>&1 && { wok=1; break; }; sleep 6; done
[[ "$wok" == 1 ]] && echo "OK $(cut -c1-400 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/wd ohne sdrAir2-Zusammenfassung (Namen/Hobby/wird geprueft)"; }
hok=0; for i in $(seq 1 40); do python3 "$AC2" hobby "$DASH_DIR" > "$W/hb.log" 2>&1 && { hok=1; break; }; sleep 3; done
[[ "$hok" == 1 ]] && echo "OK $(cut -c1-300 "$W/hb.log")" || { cat "$W/hb.log"; rbx "alter Hobby-Vorfall nicht geschlossen"; }
"${CURL[@]}" "$B/api/t4/tii" -o "$W/tii.json" || true
python3 "$WC" tii "$W/tii.json" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t4/tii Karte"; }
dok=0; for i in $(seq 1 60); do python3 "$DCK" db "$LZ" "$T0" > "$W/dq.log" 2>&1 && { dok=1; break; }; sleep 5; done
[[ "$dok" == 1 ]] && echo "OK $(cut -c1-420 "$W/dq.log")" || { cat "$W/dq.log"; rbx "dabSql: Tabellen/Import/Aufzeichnung der Pruefungen fehlen"; }
aok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/dabsql/status" -o "$W/dqapi.json" || true; python3 "$DCK" api "$W/dqapi.json" > "$W/dqa.log" 2>&1 && { aok=1; break; }; sleep 6; done
[[ "$aok" == 1 ]] && echo "OK $(cut -c1-420 "$W/dqa.log")" || { cat "$W/dqa.log"; rbx "/api/dabsql/status"; }
python3 "$DCK" card "$W/dabhist.html" > "$W/dqc.log" 2>&1 && echo "OK $(cat "$W/dqc.log")" || { cat "$W/dqc.log"; rbx "/dabhist ohne dabSql-Zusammenfassung"; }
python3 "$ACK" page "$W/funk.html" > "$W/atp.log" 2>&1 && echo "OK $(cat "$W/atp.log")" || { cat "$W/atp.log"; rbx "/funk ohne airTest-Karte"; }
atok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/airtest" -o "$W/atapi.json" || true; python3 "$ACK" api "$W/atapi.json" > "$W/ata.log" 2>&1 && { atok=1; break; }; sleep 6; done
[[ "$atok" == 1 ]] && echo "OK $(cut -c1-300 "$W/ata.log")" || { cat "$W/ata.log"; rbx "/api/sdr/airtest"; }
python3 "$ACK" state "$DASH_DIR" > "$W/ats.log" 2>&1 && echo "OK $(cat "$W/ats.log")" || { cat "$W/ats.log"; rbx "sdr_airtest.json kaputt"; }
atc=$(curl -s --connect-timeout 3 --max-time 20 -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"action":"start","confirm":true}' "$B/api/sdr/airtest" || true)
[[ "$atc" == 403 ]] && echo "OK POST /api/sdr/airtest ohne Funk-Seiten-Herkunft abgelehnt (403) - es wurde kein Test angefordert" || rbx "POST /api/sdr/airtest ohne Herkunft nicht abgelehnt ($atc)"
[[ ! -f "$DASH_DIR/sdr_airtest_req.json" || "$ATREQ0" == 1 ]] && echo "OK keine Test-Anforderung durch den Rauchtest (Test startet nur per Knopf/API)" || rbx "Test-Anforderungsdatei durch Rauchtest entstanden"
nok=0; for i in $(seq 1 10); do
  rm -rf "$W/nm" && mkdir -p "$W/nm"
  for p in / /funk /pi /umwelt /dabhist /mesh; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').html" || true; done
  for p in /api/sdr/ui /api/sdr/wd /api/t2/status /api/t4/status /api/dabsql/status /api/sdr/airtest; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').json" || true; done
  python3 "$AC2" names "$W/nm" > "$W/nm.log" 2>&1 && { nok=1; break; }; sleep 6
done
[[ "$nok" == 1 ]] && echo "OK $(cut -c1-300 "$W/nm.log")" || { cat "$W/nm.log"; rbx "alte Platz-Namen auf Seiten/APIs"; }
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JP=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JS=$(echo "$JP" | grep -E "sdrTeil2: aktiv im Geraete-Register" | tail -1 || true)
  [[ -n "$JS" ]] && echo "OK Journal prepper-sdr: $(echo "$JS" | cut -c1-260)" || rbx "prepper-sdr meldet die Register-Rollen nicht (sdrTeil2-Zeile alt?)"
  if echo "$JP" | grep -q "Alarm-Uebernahme 5C"; then rbx "alte Zeile sdrTeil2 ... Alarm-Uebernahme 5C noch im Journal"; fi
  echo "OK Journal prepper-sdr: keine alte Zeile Alarm-Uebernahme 5C seit Neustart"
fi
R1='Traceback|airTest (Tick|Befehl|Messung|Fehler|Standard-Gain pruefen|speichern|Anzeige)|dabSql( Start| on_dab)|dabSql: (Schreibfehler|Tabellen|Lesen|kartevec-Import|Schreibfaden nicht)|^sdrAir2? [A-Za-z/ ]*:|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:'
E1=$(echo "$JP" | grep -c -E "$R1" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JP" | grep -E "$R1" | head -5 | cut -c1-240; rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"; }
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JA=$(echo "$JD" | grep -F "dabSql aktiv: dabSql Anzeige ok" | tail -1 || true)
  [[ -n "$JA" ]] && echo "OK Journal Dashboard: $(echo "$JA" | cut -c1-260)" || rbx "Dashboard meldet dabSql-Anzeige nicht (Selbsttest)"
  JA2=$(echo "$JD" | grep -F "airTest aktiv: airTest Anzeige ok" | tail -1 || true)
  [[ -n "$JA2" ]] && echo "OK Journal Dashboard: $(echo "$JA2" | cut -c1-260)" || rbx "Dashboard meldet airTest-Anzeige nicht (Selbsttest)"
  JB=$(echo "$JP" | grep -F "airTest: bereit" | tail -1 || true)
  [[ -n "$JB" ]] && echo "OK Journal prepper-sdr: $(echo "$JB" | cut -c1-200)" || rbx "prepper-sdr meldet airTest nicht (bereit)"
  JW=$(echo "$JP" | grep -F "dabSql: Schreibfaden laeuft" | tail -1 || true)
  [[ -n "$JW" ]] && echo "OK Journal prepper-sdr: $(echo "$JW" | cut -c1-200)" || rbx "prepper-sdr meldet den dabSql-Schreibfaden nicht"
fi
R2='Traceback|airTest (Anzeige(:| FEHLER)|Seite:)|dabSql Anzeige(:| FEHLER)|dabSql Karte:|dabSql: (Lesen|Tabellen|kartevec-Import)|sdrWd FEHLER|funkUI FEHLER|sdr_manager sdrWd|sdr_manager sdrAir2? [A-Za-z_ -]+:|sdrAir2? Anzeige(:| FEHLER)'
E2=$(echo "$JD" | grep -c -E "$R2" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JD" | grep -E "$R2" | head -5 | cut -c1-240; rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"; }
python3 "$AC2" proof "$DASH_DIR" 0 > "$W/proof.log" 2>&1 && echo "Geraete nachher: $(cut -c1-460 "$W/proof.log")" || echo "HINWEIS Geraete nachher: $(cut -c1-300 "$W/proof.log")"
echo "Watchdog nachher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-400)"
for x in "$DBF:$DB16" "$MR:$MR16" "$HDST:$HL16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
echo "OK guards airTest(sdr)=$(grep -c '# ===== airTest:' "$M" || true) airTest(sm)=$(grep -c '# ===== airTest:' "$SMF" || true) airTest(dash)=$(grep -c '# ===== airTest:' "$F" || true) dabSql(sdr)=$(grep -c '# ===== dabSql:' "$M" || true) dabSql(sm)=$(grep -c '# ===== dabSql:' "$SMF" || true) dabSql(dash)=$(grep -c '# ===== dabSql:' "$F" || true) sdrAir2(sdr)=$(grep -c '# ===== sdrAir2:' "$M" || true) sdrAir2(sm)=$(grep -c '# ===== sdrAir2:' "$SMF" || true) sdrAir(sdr)=$(grep -c '# ===== sdrAir:' "$M" || true) sdrAir(sm)=$(grep -c '# ===== sdrAir:' "$SMF" || true) sdrAir(dash)=$(grep -c '# ===== sdrAir:' "$F" || true) sdrAir2(dash)=$(grep -c '# ===== sdrAir2:' "$F" || true) sdrWd2(sdr)=$(grep -c '# ===== sdrWd2:' "$M" || true) sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sysBoot(dash)=$(grep -c '# ===== sysBoot' "$F" || true)"
[[ -f "$M.bak-airtest-$TS" ]] && echo "Backups: *.bak-airtest-$TS (prepper_sdr.py, sdr_manager.py, dashboard.py, sdr_wd.json, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF" "$HDST"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: prepper_sdr.py.bak-airtest-$TS, sdr_manager.py.bak-airtest-$TS und dashboard.py.bak-airtest-$TS zurueckkopieren, dann sudo systemctl restart prepper-sdr prepper-dashboard"
echo "SoapySDR testen (nur auf Wunsch): in sdr_config.json air_fe auf soapy, dann sudo systemctl restart prepper-sdr; Rueckfall auf -F airspy geschieht automatisch"
echo "COMMIT $COMMIT_ARG airtest=1 fertig"
