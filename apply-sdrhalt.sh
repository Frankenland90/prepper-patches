#!/bin/bash
set -euo pipefail
# sdrHalt: baut auf airTest (live 24.10.: prepper_sdr a88c93cfa8dacfbe, sdr_manager 37de138290b9e47a, dashboard fa85999c95634cea). Aendert NUR prepper_sdr.py und legt ein systemd-Drop-in fuer prepper-sdr an; die Haupt-Unit, Hilfsprogramm, sudoers, sdr_config.json, sdr_manager.py, dashboard.py bleiben.
#  - Drop-in /etc/systemd/system/prepper-sdr.service.d/zz-sdrhalt.conf: Restart=always, RestartSec=20, StartLimitIntervalSec=0 (kein Start-Limit), WatchdogSec=300, NotifyAccess=main, LimitCORE=0. Vorher: systemctl cat der echten Unit (ExecStart prepper_sdr.py run, Type simple, kein fremdes WatchdogSec), danach daemon-reload; wirksam mit dem Neustart von prepper-sdr (den die neue prepper_sdr.py ohnehin braucht).
#  - Planer-Waechter (Faden im Dienst prepper-sdr): sendet alle 20 s WATCHDOG=1 an systemd (sd_notify, ohne neue sudo-Rechte), solange jeder Planer-Faden in den letzten 10 min einen Schritt gemacht hat ODER eine Sperre gilt (echter Alarm, ASA-Warnung auf 5C (2 h), PTY31, Antennentest, Meteor-Aufnahme, Stick-2-Uebernahme, USB-Neuverbindung, airTest aktiv, Hobby-10C-Pruefung; Sperren schuetzen hoechstens 2 h).
#  - Haengt ein Planer-Faden > 10 min ohne Schritt und keine Sperre gilt: Protokollzeile (sdrHalt: ... kontrollierter Neustart n von 3), Eintrag in sdr_halt.json, dann WATCHDOG=trigger - systemd beendet den Dienst und startet ihn nach 20 s neu (Restart=always). Hoechstens 3 kontrollierte Neustarts je Stunde (persistent ueber Neustarts), danach nur noch Protokollzeile. Ohne systemd-Watchdog (NOTIFY_SOCKET fehlt) nie eine Aktion.
#  - Hilfsprogramm-Pruefung (nur check, aendert nichts): stuendlich im Waechter-Faden und vor jeder Eskalation USB-Neuverbindung/Pi-Neustart (statt nur beim Start).
#  - Keine Gain-/Stick-/Watchdog-Stufenlogik geaendert (nur Planner.step und _wd_do umhuellt), nichts gesendet.
# Basis streng (sha16): airTest-Stand oder sdrHalt schon drin. Sonst Abbruch ohne Aenderung. Neustart nur prepper-sdr (Dashboard bleibt). Sendet nichts.
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
W=/tmp/sdrhalt-apply
KEEP_LAST=3
KNOWN_D16="fa85999c95634cea"     # dashboard.py nach airTest
KNOWN_D16N="fa85999c95634cea"     # dashboard.py bleibt (airTest)
KNOWN_SM16="37de138290b9e47a"    # sdr_manager.py nach airTest
KNOWN_SM16N="37de138290b9e47a"    # sdr_manager.py bleibt (airTest)
KNOWN_SDR16="a88c93cfa8dacfbe"   # prepper_sdr.py nach airTest
KNOWN_SDR16N="c347f0145c0e19e0"   # prepper_sdr.py nach airTest (Ziel)
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
echo "=== sdrHalt apply (Drop-in prepper-sdr Restart=always/WatchdogSec, Planer-Waechter mit kontrolliertem Neustart bei Hang ausserhalb von Sperren, Hilfsprogramm-Pruefung stuendlich), Dashboard-Port $PORT ==="
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
EXPECT_HE="0a770a938aa2a53c4776cf08761bfee5970dffa12eebfe53e251ece2c61b17e8"
cat > "$W/sh_edits.py" << 'HE_EOF'
# sdrHalt: Stellen (alt, neu) auf dem Stand nach airTest. Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
('''        selftest_airtest()
''', '''        selftest_airtest()
        selftest_sdrhalt()
'''),
# Dienststart: Waechter-Faden nach dem dabSql-Schreibfaden
('''        globals().get("_DQ_START", lambda b: None)(BASE)   # dabSql: Schreibfaden (wirft nie)
''', '''        globals().get("_DQ_START", lambda b: None)(BASE)   # dabSql: Schreibfaden (wirft nie)
        globals().get("_SH_START", lambda b: None)(BASE)   # sdrHalt: Waechter-Faden (wirft nie)
'''),
# airTest-Selbsttest: Planner.step ist jetzt noch einmal umhuellt (sdrHalt)
('''Planner.step is _at_step and dabgain_step is _at_dabgain_step''', '''Planner.step in (_at_step, globals().get("_sh_step")) and dabgain_step is _at_dabgain_step'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
HE_EOF
EXPECT_HSD="8e8b1c844a78ebfbd178236d16b8c4d11bf670d08316b2a24a45000a2eec9884"
cat > "$W/sh_sdr_block.py" << 'HSD_EOF'
# ===== sdrHalt: Planer-Waechter - haengt ein Planer-Faden (kein Planer-Schritt seit 10 min) und ist keine Sperre aktiv (Alarm, ASA, PTY31, Antennentest, Meteor, Uebernahme, USB-Reset, airTest, Hobby-10C-Fenster), laesst der Dienst systemd per sd_notify (WATCHDOG=trigger) kontrolliert neu starten; hoechstens 3 je Stunde (persistent), nie in Sperren, Protokollzeile; ohne systemd-Watchdog (NOTIFY_SOCKET) keine Aktion. Dazu stuendliche Hilfsprogramm-Pruefung (nur check) und vor jeder Eskalation USB/Pi-Neustart. Gain-/Stick-/Watchdog-Logik unveraendert =====
SH_FILE = "sdr_halt.json"
SH_STALE_S = 600            # kein Planer-Schritt so lange = haengt (Schritte kommen alle <= 15 s)
SH_BLOCK_CAP_S = 7200       # Sperren schuetzen hoechstens so lange vor dem Neustart (ASA-Fenster 2 h)
SH_MAX_H = 3                # hoechstens 3 kontrollierte Neustarts je Stunde
SH_TICK_S = 20              # Takt des Waechter-Fadens (WatchdogSec im Drop-in 300 s)
SH_HELPER_S = 3600          # Hilfsprogramm-Pruefung hoechstens alle 1 h
SH_LOG_S = 600
_SH = {"hb": {}, "t0": 0.0, "trig": False, "log_t": {}, "helper_t": 0.0, "beat": False, "th": None}


def _sh_log(key, txt, every=SH_LOG_S):
    n = time.time()
    if n - _SH["log_t"].get(key, 0.0) >= every:
        _SH["log_t"][key] = n
        print("sdrHalt: " + txt, flush=True)


def _sh_mark(pl, enter):
    e = _SH["hb"].setdefault(id(pl), {"pl": pl, "t": 0.0, "blk": None, "hob": False, "bt": -1e9})
    e["t"] = time.monotonic()                          # Alter nur monoton (Uhr-Sprung beim Pi-Start ohne RTC/NTP darf keinen Hang vortaeuschen)
    e["in"] = enter
    return e


def _sh_step(self):
    _sh_mark(self, True)
    r = _sh_orig_step(self)
    e = _sh_mark(self, False)
    try:
        if e["t"] - e["bt"] >= 10:                    # Sperrgrund im Planer-Faden zwischenspeichern (kein Sperren des Waechter-Fadens)
            now = time.time()
            b = _wd_block(self, now, cfg_serial(self.cfg), None)
            e["blk"] = None if b == AIR2_HOBBY_BLOCK else b
            t = self.__dict__.get("_air2_p10t")
            e["hob"] = bool(t and 0 <= now - t < AIR2_P10_WIN_S)
            e["bt"] = e["t"]
    except Exception as ex:
        _sh_log("step", "Sperrgrund merken: %s" % ex)
    return r


def _sh_do(pl, act, sn, ctx, now):
    """Vor jeder Eskalation USB-Neuverbindung/Pi-Neustart: Hilfsprogramm-Zustand frisch pruefen (nur check, aendert nichts), dann die unveraenderte Aktion."""
    if act in ("usb", "reboot") and _SH.get("th") is not None:    # nur im Dienst (Waechter-Faden laeuft); Selbsttests der Eskalation zaehlen Hilfsprogramm-Aufrufe
        try:
            h = wd_helper_state(True)
            _SH["helper_t"] = time.time()
            if not h.get("ok"):
                print("sdrHalt: Hilfsprogramm vor Stufe %s: %s" % (act, h.get("txt")), flush=True)
        except Exception as ex:
            _sh_log("helper", "Hilfsprogramm-Pruefung vor Eskalation: %s" % ex)
    return _sh_orig_do(pl, act, sn, ctx, now)


def sh_decide(now, pls, live):
    """-> (urteil, text, alter_s): 'ok' (alle Planer lebendig), 'sperre' (haengt, aber gesperrt) oder 'haengt'."""
    old = [x for x in pls if now - x["t"] > SH_STALE_S]
    if not old:
        return "ok", "", 0
    age = int(max(now - x["t"] for x in old))
    for k in ("pause", "busy", "airtest", "alarm"):
        if live.get(k):
            return "sperre", str(live[k]), age
    for x in old:
        if x.get("hob") and now - x["t"] <= SH_BLOCK_CAP_S:
            return "sperre", "Hobby-Pruefung 10C", age
        if x.get("blk") and now - x["t"] <= SH_BLOCK_CAP_S:
            return "sperre", str(x["blk"])[:100], age
    return "haengt", ", ".join(str(x.get("name")) for x in old), age


def _sh_live(base, now):
    pls = [e["pl"] for e in list(_SH["hb"].values())]
    out = {"pause": None, "busy": None, "airtest": None, "alarm": None}
    try:
        for pl in pls:
            m = getattr(pl, "main", None) or pl
            if getattr(m, "st_pause", False) or getattr(pl, "st_pause", False):
                out["pause"] = "Antennentest laeuft"
        if _WD.get("busy"):
            out["busy"] = "USB-Neuverbindung laeuft"
        r = _AT.get("run")
        if r and now <= float(r.get("deadline") or 0) + 300:
            out["airtest"] = "airTest aktiv"
        g = load_json(p(WD_GATE, base), {}) or {}
        if isinstance(g, dict) and g.get("alarm") is True and isinstance(g.get("t"), (int, float)) and -60 <= now - g["t"] <= 900:
            out["alarm"] = "echter Alarm im Lagezentrum"
        elif t2_takeover(base).get("on"):
            out["alarm"] = "Alarm-Uebernahme Stick 2 aktiv"
    except Exception as ex:
        out["alarm"] = "Sperrpruefung fehlgeschlagen (%s)" % str(ex)[:60]
    return out


def _sh_notify(msg):
    a = os.environ.get("NOTIFY_SOCKET") or ""
    if not a or a[0] not in "/@":
        return False
    import socket as _sh_sock
    s = _sh_sock.socket(_sh_sock.AF_UNIX, _sh_sock.SOCK_DGRAM)
    try:
        s.settimeout(2)
        s.connect(("\0" + a[1:]) if a[0] == "@" else a)
        s.sendall(msg.encode())
        return True
    except OSError:
        return False
    finally:
        s.close()


def _sh_load(base):
    d = load_json(p(SH_FILE, base), None)
    if not isinstance(d, dict) or not isinstance(d.get("restarts"), list):
        d = {"v": 1, "restarts": []}
    d["restarts"] = [r for r in d["restarts"] if isinstance(r, dict) and isinstance(r.get("t"), (int, float))][-20:]
    return d


def _sh_save(base, d, now):
    fn = p(SH_FILE, base)
    d["t_upd"] = int(now)
    tmp = fn + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(d, ensure_ascii=False))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, fn)


def _sh_tick(base, now, mono=None):
    mono = time.monotonic() if mono is None else mono
    pls = [{"name": "Stick %s" % (getattr(e["pl"], "stickno", 1) or 1), "t": e["t"], "blk": e["blk"], "hob": e["hob"]} for e in list(_SH["hb"].values())]
    if not pls:
        pls = [{"name": "Planer", "t": _SH["t0"], "blk": None, "hob": False}]
    v, txt, age = sh_decide(mono, pls, _sh_live(base, now))
    if now - _SH["helper_t"] >= SH_HELPER_S and _WD.get("live"):
        _SH["helper_t"] = now
        try:
            h = wd_helper_state(True)
            _sh_log("helper_ok", "Hilfsprogramm-Pruefung (stuendlich): %s" % h.get("txt"), 3300)
        except Exception as ex:
            _sh_log("helper", "Hilfsprogramm-Pruefung: %s" % ex)
    if v == "haengt":
        d = _sh_load(base)
        n = len([r for r in d["restarts"] if now - r["t"] < 3600])
        if _SH["trig"]:
            return
        if n >= SH_MAX_H:
            _sh_log("limit", "Planer-Faden %s haengt seit %d s, aber %d kontrollierte Neustarts in der letzten Stunde sind verbraucht - kein weiterer Neustart" % (txt, age, n))
            _sh_notify("WATCHDOG=1")
            return
        if not (os.environ.get("NOTIFY_SOCKET") or "")[:1] in ("/", "@"):
            _sh_log("nosock", "Planer-Faden %s haengt seit %d s, aber kein systemd-Watchdog (NOTIFY_SOCKET fehlt, Drop-in sdrHalt nicht aktiv) - keine Aktion" % (txt, age))
            return
        d["restarts"].append({"t": int(now), "why": "Planer-Faden %s ohne Schritt seit %d s" % (txt, age), "n": n + 1})
        try:
            _sh_save(base, d, now)
        except Exception as ex:
            _sh_log("save", "Neustart-Zaehler nicht gespeichert (%s) - kein Neustart" % ex)
            return
        print("sdrHalt: Planer-Faden %s haengt (%d s ohne Schritt, keine Sperre) - kontrollierter Neustart %d von %d in der letzten Stunde (WATCHDOG=trigger, systemd Restart=always)" % (txt, age, n + 1, SH_MAX_H), flush=True)
        _SH["trig"] = True
        _sh_notify("STATUS=Planer haengt - kontrollierter Neustart")
        _sh_notify("WATCHDOG=trigger")
        return
    if v == "sperre":
        _sh_log("sperre", "Planer-Faden ohne Schritt seit %d s, aber gesperrt (%s) - kein Neustart" % (age, txt))
    ok = _sh_notify("WATCHDOG=1")
    if ok and not _SH["beat"]:
        _SH["beat"] = True
        print("sdrHalt: Watchdog-Takt an systemd gesendet (WatchdogSec %s s, alle %d s)" % (round(int(os.environ.get("WATCHDOG_USEC") or 0) / 1e6), SH_TICK_S), flush=True)


def _sh_loop(base):
    _SH["t0"] = time.monotonic()
    try:
        d = _sh_load(base)
        n = len([r for r in d["restarts"] if time.time() - r["t"] < 3600])
        print("sdrHalt: bereit - Waechter-Faden, haengender Planer (> %d min ohne Schritt, ohne Sperre) -> kontrollierter Neustart, hoechstens %d je Stunde (bisher %d), systemd-Watchdog %s" % (
            SH_STALE_S // 60, SH_MAX_H, n, "aktiv (NOTIFY_SOCKET + WATCHDOG_USEC)" if (os.environ.get("NOTIFY_SOCKET") and os.environ.get("WATCHDOG_USEC")) else "nicht aktiv (Drop-in fehlt: keine Aktion)"), flush=True)
    except Exception as ex:
        print("sdrHalt Start:", ex, flush=True)
    while True:
        try:
            _sh_tick(base, time.time(), time.monotonic())
        except Exception as ex:
            _sh_log("tick", "Waechter: %s" % ex)
        time.sleep(SH_TICK_S)


def _SH_START(base):
    try:
        if _SH["th"] is None:
            _SH["th"] = threading.Thread(target=_sh_loop, args=(base,), name="sdrhalt", daemon=True)
            _SH["th"].start()
    except Exception as ex:
        print("sdrHalt Start:", ex, flush=True)


_sh_orig_step = Planner.step
_sh_orig_do = _wd_do
_sh_keep_step = _sh_orig_step
_sh_keep_do = _sh_orig_do
Planner.step = _sh_step
_wd_do = _sh_do


def selftest_sdrhalt():
    import tempfile
    import socket as _st_sock
    tmp = tempfile.mkdtemp(prefix="sdrhalt-")
    fake_helper = []
    real_whs = wd_helper_state
    globals()["wd_helper_state"] = lambda force=False: fake_helper.append(force) or {"ok": True, "txt": "bereit (Fake)", "t": time.time()}
    sv = (dict(_SH), dict(_SH["hb"]), dict(_SH["log_t"]), os.environ.get("NOTIFY_SOCKET"), os.environ.get("WATCHDOG_USEC"), dict(_AT), _WD.get("busy"), _WD.get("live"))
    now = 1790000000.0
    quiet = {"pause": None, "busy": None, "airtest": None, "alarm": None}
    old = {"name": "Stick 1", "t": now - 700, "blk": None, "hob": False}
    new = {"name": "Stick 2", "t": now - 5, "blk": None, "hob": False}
    try:
        assert Planner.step is _sh_step and _wd_do is _sh_do and _sh_orig_step is not _sh_step
        assert sh_decide(now, [new], quiet)[0] == "ok" and sh_decide(now, [], quiet)[0] == "ok"
        assert sh_decide(now, [old, new], quiet)[0] == "haengt" and sh_decide(now, [dict(old, t=now - 590)], quiet)[0] == "ok"
        for k, tx in (("pause", "Antennentest"), ("busy", "USB"), ("airtest", "airTest"), ("alarm", "Alarm")):
            r = sh_decide(now, [old], dict(quiet, **{k: tx}))
            assert r[0] == "sperre" and tx in r[1], (k, r)
        assert sh_decide(now, [dict(old, blk="Meteor-Aufnahme läuft")], quiet)[0] == "sperre"
        assert sh_decide(now, [dict(old, blk="ASA", t=now - SH_BLOCK_CAP_S - 5)], quiet)[0] == "haengt"       # Sperre schuetzt hoechstens 2 h
        assert sh_decide(now, [dict(old, hob=True)], quiet)[0] == "sperre" and sh_decide(now, [dict(old, hob=True, t=now - SH_BLOCK_CAP_S - 5)], quiet)[0] == "haengt"
        # Planer-Schritt merkt Herzschlag + Sperrgrund (Hobby-Geraete-Sperre zaehlt nicht)

        class _Sbc:
            d = {"fm": {}, "warn": []}

        class _Pl:
            base = tmp
            cfg = {"dev_kind": "airspy", "serial": "44A42E4F2A5B1C83"}
            lock = threading.Lock()
            sbc = _Sbc()
            st_pause = False
            main = None
            stickno = 1
            pmeteor = None

        pl = _Pl()
        _SH["hb"].clear()
        globals()["_sh_orig_step"] = lambda s: (2, {})
        try:
            assert _sh_step(pl) == (2, {}) and _SH["hb"][id(pl)]["in"] is False and _SH["hb"][id(pl)]["blk"] is None
        finally:
            globals()["_sh_orig_step"] = _sh_keep_step
        pl.st_pause = True
        _SH["hb"][id(pl)]["t"] = now - 900
        assert _sh_live(tmp, now)["pause"] and sh_decide(now, [dict(old)], _sh_live(tmp, now))[0] == "sperre"
        pl.st_pause = False
        _AT["run"] = {"deadline": now + 100}
        assert _sh_live(tmp, now)["airtest"] and _sh_live(tmp, now + 500)["airtest"] is None
        _AT["run"] = None
        _WD["busy"] = "X"
        assert _sh_live(tmp, now)["busy"]
        _WD["busy"] = None
        json.dump({"alarm": True, "t": now - 10}, open(os.path.join(tmp, WD_GATE), "w"))
        assert _sh_live(tmp, now)["alarm"]
        os.remove(os.path.join(tmp, WD_GATE))
        # Tick mit Fake-Notify-Socket
        sp = os.path.join(tmp, "notify.sock")
        srv = _st_sock.socket(_st_sock.AF_UNIX, _st_sock.SOCK_DGRAM)
        srv.bind(sp)
        srv.settimeout(1)
        os.environ["NOTIFY_SOCKET"], os.environ["WATCHDOG_USEC"] = sp, "300000000"
        def drain():
            out = []
            srv.settimeout(0.2)
            try:
                while True:
                    out.append(srv.recv(200).decode())
            except Exception:
                return out

        _SH["hb"].clear()
        _SH.update(trig=False, beat=False, t0=now - 5, helper_t=now)
        e = _sh_mark(pl, False)
        e.update(t=now, blk=None, hob=False)
        _sh_tick(tmp, now, now)
        assert drain() == ["WATCHDOG=1"] and _SH["beat"]                                          # lebendig: Takt
        _sh_tick(tmp, now + 10 ** 6, now)
        assert drain() == ["WATCHDOG=1"] and not os.path.exists(os.path.join(tmp, SH_FILE))      # Uhr springt (Pi ohne RTC): Alter nur monoton, kein Hang
        e["t"] = now - 700
        _AT["run"] = {"deadline": now + 600}
        _sh_tick(tmp, now, now)
        assert drain() == ["WATCHDOG=1"] and not os.path.exists(os.path.join(tmp, SH_FILE)) and not _SH["trig"]   # gesperrt (airTest): Takt, kein Neustart
        _AT["run"] = None
        _sh_tick(tmp, now, now)
        m = drain()
        d = json.load(open(os.path.join(tmp, SH_FILE)))
        assert m == ["STATUS=Planer haengt - kontrollierter Neustart", "WATCHDOG=trigger"] and len(d["restarts"]) == 1 and _SH["trig"], (m, d)      # haengt: ein Neustart, danach kein Takt mehr
        _sh_tick(tmp, now + 20, now + 20)
        assert drain() == []
        _SH["trig"] = False                                                                       # (neuer Prozess) 2. und 3. in der Stunde erlaubt, 4. nicht
        for k in (1, 2):
            e["t"] = now + 100 * k - 700
            _sh_tick(tmp, now + 100 * k, now + 100 * k)
            assert drain()[-1] == "WATCHDOG=trigger"
            _SH["trig"] = False
        e["t"] = now + 300 - 700
        _sh_tick(tmp, now + 300, now + 300)
        assert drain() == ["WATCHDOG=1"] and len(json.load(open(os.path.join(tmp, SH_FILE)))["restarts"]) == 3 and not _SH["trig"]
        e["t"] = now + 3700 - 700
        _sh_tick(tmp, now + 3700, now + 3700)                                                                   # nach 1 h wieder erlaubt
        assert drain()[-1] == "WATCHDOG=trigger"
        _SH["trig"] = False
        os.environ.pop("NOTIFY_SOCKET")                                                             # ohne systemd-Watchdog nie eine Aktion
        d0 = open(os.path.join(tmp, SH_FILE)).read()
        e["t"] = now + 9000 - 700
        _sh_tick(tmp, now + 9000, now + 9000)
        assert open(os.path.join(tmp, SH_FILE)).read() == d0 and not _SH["trig"] and _sh_notify("WATCHDOG=1") is False
        # Eskalation USB/Pi-Neustart: Hilfsprogramm frisch, dann Original unveraendert; stuendliche Pruefung
        calls = []
        globals()["_sh_orig_do"] = lambda *a: calls.append(a[1]) or "orig"
        try:
            _SH["th"] = None
            assert _sh_do(pl, "usb", "1", None, now) == "orig" and fake_helper == []                # Selbsttests/ohne Dienst: unveraendert, kein Zusatzaufruf
            _SH["th"] = object()
            calls.clear()
            assert _sh_do(pl, "usb", "1", None, now) == "orig" and _sh_do(pl, "restart", "1", None, now) == "orig" and calls == ["usb", "restart"]
        finally:
            globals()["_sh_orig_do"] = _sh_keep_do
        assert _SH["helper_t"] > 0 and fake_helper == [True]                                        # nur vor usb, nicht vor restart
        _WD["live"] = True
        _SH["th"] = None
        _SH["helper_t"] = now - SH_HELPER_S - 1
        _sh_tick(tmp, now + 10000, now + 10000)
        assert _SH["helper_t"] == now + 10000 and fake_helper == [True, True]
        # kaputte Datei / Fehler werfen nie
        open(os.path.join(tmp, SH_FILE), "w").write("{kaputt")
        assert _sh_load(tmp)["restarts"] == []
        srv.close()
    finally:
        globals()["wd_helper_state"] = real_whs
        _SH.clear()
        _SH.update(sv[0])
        _SH["hb"] = sv[1]
        _SH["log_t"] = sv[2]
        for k, v in (("NOTIFY_SOCKET", sv[3]), ("WATCHDOG_USEC", sv[4])):
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        _AT.clear()
        _AT.update(sv[5])
        _WD["busy"], _WD["live"] = sv[6], sv[7]
    print("selftest sdrHalt ok (Herzschlag je Planer-Schritt, Sperren Alarm/ASA/PTY31/Antennentest/Meteor/Uebernahme/USB-Reset/airTest/Hobby-10C gedeckelt, haengt = ein kontrollierter Neustart per WATCHDOG=trigger, hoechstens 3 je Stunde persistent, ohne Notify-Socket nie eine Aktion, Takt nur wenn lebendig oder gesperrt, Hilfsprogramm stuendlich und vor USB/Pi-Neustart, Gain-/Stick-/Watchdog-Logik unveraendert)")
HSD_EOF
EXPECT_HGD="e2e41740df5f08c407a8a1418895876b96326fae586c1de4e68fd22df7d2f24d"
cat > "$W/guard_sh.py" << 'HGD_EOF'
"""AST-Guard sdrHalt. Aufruf: guard_sh.py EDITS  ART ALT NEU BLOCK ...  (ART = sdr | sm | dsh; ALT = Stand nach airTest) -> 0 ok, 1 Verstoss.
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
WRITE_FN = ("_sh_save",)                           # einzige Stellen mit Dateischreiben
WRITE_NM = ("open", "write", "flush", "fsync", "fileno", "replace", "dumps")
TOP_ASSIGN_OK = ("Planner.step", "_wd_do")
JSON_OK = ("sdr_halt.json",)
err = []
a = sys.argv[2:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    if new.count(B.rstrip("\n")) != 1:
        err.append("%s: Block sdrHalt fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sdrHalt" % (kind, len(E)))
    for o, n in E:
        ol = set(o.splitlines())
        low = "\n".join(x for x in n.splitlines() if x not in ol and not x.strip().startswith("assert ")).lower()
        if any(not (x.strip().startswith(("selftest_sdrhalt()", "assert ", 'Planner.step in (_at_step, globals().get("_sh_step")) and dabgain_step is _at_dabgain_step')) or x.strip().startswith('globals().get("_SH_START", lambda b: None)(BASE)')) for x in n.splitlines() if x not in ol):
            err.append("%s Stelle: nur Selbsttest-Aufruf, Start-Hook und Selbsttest-Zusicherung duerfen dazukommen" % kind)
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
            if tg.startswith("_at_orig_") or tg.startswith(("SH_", "_SH", "_sh_")) or tg in TOP_ASSIGN_OK:
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
                if not ((mod in ("tempfile", "socket") and st) or (mod == "socket" and fn == "_sh_notify")):
                    err.append("%s Block: Import %s" % (kind, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s Block: shell" % kind)
        if isinstance(n, (ast.Delete,)) and not st:
            err.append("%s Block: del in %s" % (kind, fn))
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if st and nm in ("open", "makedirs", "rename", "close", "write", "mkdtemp", "socket", "bind", "recv", "remove", "clear", "settimeout"):
                continue                                       # Selbsttest: Temp-Ordner
            if fn in WRITE_FN and nm in WRITE_NM and (nm != "replace" or base == "os") and (nm != "open" or (len(n.args) >= 2 and isinstance(n.args[1], ast.Constant) and n.args[1].value == "w")):
                continue                                       # tmp schreiben, fsync, os.replace
            if fn == "_sh_notify" and nm in ("socket", "settimeout", "connect", "sendall", "close", "encode"):
                continue                                       # sd_notify: Unix-Datagramm an NOTIFY_SOCKET
            if fn == "_sh_live" and nm == "t2_takeover":
                continue                                       # nur lesen (Stick-2-Uebernahme als Sperre)
            if fn == "_SH_START" and nm == "Thread" and base == "threading":
                continue                                       # sdrHalt: einziger Faden = Waechter (daemon)
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
    for n in ast.walk(t):
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and re.match(r"(?is)\s*(SELECT|INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|ATTACH|PRAGMA)\s", n.value):
            err.append("%s Block: SQL im Waechter nicht vorgesehen: %s" % (kind, n.value[:50]))
    if kind == "sdr":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_wd_helper", "_wd_do", "wd_helper_state", "_wd_decide", "_wd_save", "_wd_emit", "_air_usb", "dabgain_step", "_air_gain_state", "wd_tick", "_wd_block", "_wd_eval", "wd_check",
                   "_air_cmd_dab", "_air2_cmd_dab", "_air2_start", "_dg_sub_done", "_wd_do", "_wd_helper", "wd_helper_state", "_at_step", "_at_tick", "_at_start", "_at_finish", "_at_cmd_dab", "_at_refuse", "_at_record", "_at_sub_done"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sdr: Original %s veraendert" % fn)
        if new.count('WD_HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"') != 1:
            err.append("sdr: WD_HELPER-Pfad")
        if 'AIR_LADDER = (16, 12, 19, 9, 21, "agc")' not in new:
            err.append("sdr: Airspy-Gain-Leiter veraendert")
        for nm in ("AIR_LADDER", "AIR2_SOAPY_GAIN", "WD_HELPER", "DABGAIN_LADDER", "DABGAIN_MIN_S", "WD_GATE", "AT_LIMIT_S", "AT_LEVELS"):
            m = [x for x in ast.parse(old).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            m2 = [x for x in ast.parse(new).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            if [ast.dump(x) for x in m] != [ast.dump(x) for x in m2]:
                err.append("sdr: Konstante %s veraendert" % nm)
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard sdrHalt: nur %s Stellen (Selbsttest-Aufruf, Start-Hook, eine Zusicherung) + Block; kein Prozess/Netz/shell/Sendeweg, einziger Faden = Waechter, einziges Dateischreiben sdr_halt.json per tmp+fsync+replace, sd_notify nur an NOTIFY_SOCKET, keine Einstellung (air_gain/sdr_config), kein SQL; Gain-Leiter/-Logik, Watchdog-Funktionen, _wd_do/_wd_helper/wd_helper_state und airTest-Funktionen unveraendert (nur umhuellt: Planner.step, _wd_do)" % (
    "/".join("%d" % len(g["%s_EDITS" % a[i].upper()]) for i in range(0, len(a), 4))))
HGD_EOF
EXPECT_HCK="79eae218cec6e169ceffac4b761478c303bea624d437035d9d737bbb6b2f3bf9"
cat > "$W/shcheck.py" << 'HCK_EOF'
"""Pruefhilfe sdrHalt (nur lesen). shcheck.py unit SHOW_DATEI | state DASH_DIR
unit: Ausgabe von systemctl show -p Restart -p RestartUSec -p StartLimitIntervalUSec -p WatchdogUSec -p NotifyAccess -p NRestarts prepper-sdr"""
import json
import os
import sys


def main(a):
    m = a[0] if a else ""
    if m == "unit":
        kv = {}
        for ln in open(a[1], encoding="utf-8", errors="replace").read().splitlines():
            if "=" in ln:
                k, v = ln.split("=", 1)
                kv[k.strip()] = v.strip()
        want = {"Restart": ("always",), "RestartUSec": ("20s", "20000000"), "StartLimitIntervalUSec": ("0", "infinity"), "WatchdogUSec": ("5min", "300s", "300000000"), "NotifyAccess": ("main",)}
        bad = ["%s=%s (erwartet %s)" % (k, kv.get(k), "/".join(v)) for k, v in want.items() if kv.get(k) not in v]
        if bad:
            print("Unit-Werte: " + "; ".join(bad)); return 1
        print("Unit prepper-sdr: Restart=always, RestartSec 20 s, StartLimitIntervalSec=0 (kein Start-Limit), WatchdogSec 5 min, NotifyAccess=main, bisherige Auto-Neustarts %s" % kv.get("NRestarts", "?")); return 0
    if m == "state":
        p = os.path.join(a[1], "sdr_halt.json")
        if not os.path.isfile(p):
            print("sdr_halt.json noch nicht da (noch nie ein Neustart durch den Waechter - normal)"); return 0
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as e:
            print("sdr_halt.json kaputt: %s" % e); return 1
        if not isinstance(d, dict) or not isinstance(d.get("restarts"), list):
            print("sdr_halt.json: restarts fehlt"); return 1
        print("sdr_halt.json: %d Waechter-Neustarts gespeichert" % len(d["restarts"])); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
HCK_EOF
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
PF="$W/patch-fu.py"; HE="$W/sh_edits.py"; HSD="$W/sh_sdr_block.py"; HGD="$W/guard_sh.py"; HCK="$W/shcheck.py"; AC2="$W/air2check.py"; DCK="$W/dabcheck.py"; ACK="$W/atcheck.py"
AC="$W/aircheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"; CK="$W/sqlccheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_HE $HE" "$EXPECT_HSD $HSD" "$EXPECT_HGD $HGD" "$EXPECT_HCK $HCK" "$EXPECT_AC2 $AC2" "$EXPECT_DCK $DCK" "$EXPECT_ACK $ACK" "$EXPECT_AC $AC" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2" "$EXPECT_CK $CK"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ "$1" == "$4" ]] && echo "bekannt ($5)" || echo "UNBEKANNT"; }; }
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "airTest" "$KNOWN_SDR16N" "sdrHalt schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "airTest" "$KNOWN_SM16N" "unveraendert (sdrHalt aendert nur prepper_sdr.py)"))"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "airTest" "$KNOWN_D16N" "unveraendert (sdrHalt aendert nur prepper_sdr.py)"))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
[[ "$SDR16" == "$KNOWN_SDR16" || "$SDR16" == "$KNOWN_SDR16N" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16 = airTest oder $KNOWN_SDR16N = sdrHalt);"
[[ "$SM16" == "$KNOWN_SM16" || "$SM16" == "$KNOWN_SM16N" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16 = airTest);"
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 = airTest);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      sdrHalt passt nur auf den airTest-Stand vom 24.10. (prepper_sdr a88c93cfa8dacfbe, sdr_manager 37de138290b9e47a, dashboard fa85999c95634cea) - nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = airTest (bzw. sdrHalt schon drin), alle sha16 bekannt"
grep -q '# ===== airTest:' "$M" && grep -q '# ===== airTest:' "$SMF" && grep -q '# ===== airTest:' "$F" || { echo "STOP: airTest fehlt - nichts geaendert"; exit 1; }
[[ -x "$HDST" ]] || { echo "STOP: Hilfsprogramm $HDST fehlt - nichts geaendert"; exit 1; }
HL16=$(s16 "$HDST")
[[ "$HL16" == "$KNOWN_HL16" ]] || { echo "STOP: Hilfsprogramm sha16 $HL16 statt $KNOWN_HL16 (sdrAir) - nichts geaendert"; exit 1; }
echo "OK Hilfsprogramm $HDST sha16 $HL16 (sdrAir, bleibt)"
for k in "sdr prepper_sdr $M $HSD $KNOWN_SDR16N" "sm sdr_manager $SMF $HSD $KNOWN_SM16N" "dsh dashboard $F $HSD $KNOWN_D16N"; do set -- $k
  if [[ "$(s16 "$3")" == "$5" ]]; then cp "$3" "$W/work/$2.py"; echo "$2.py: sdrHalt schon drin bzw. unveraendert" > "$W/q_$1.log"; continue; fi
  python3 "$PF" sdrHalt "$1" "$3" "$W/work/$2.py" "$4" "$HE" > "$W/q_$1.log" || { cat "$W/q_$1.log"; echo "STOP: $2.py sdrHalt-Stufe passt nicht - nichts geaendert"; exit 1; }
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
# ---------- 1c) Unit prepper-sdr pruefen (nur lesen) und Drop-in vorbereiten ----------
UNITN=prepper-sdr
DROPDIR="${SDR_DROPIN_DIR:-/etc/systemd/system/prepper-sdr.service.d}"
DROPF="$DROPDIR/zz-sdrhalt.conf"
systemctl cat "$UNITN" > "$W/unit.txt" 2> "$W/unit.err" || { cat "$W/unit.err"; echo "STOP: systemctl cat $UNITN scheitert - nichts geaendert"; exit 1; }
grep -qE '^ExecStart=.*prepper_sdr\.py run' "$W/unit.txt" || { head -20 "$W/unit.txt"; echo "STOP: Unit $UNITN startet prepper_sdr.py run nicht (ExecStart) - nichts geaendert"; exit 1; }
UTYPE=$(systemctl show -p Type --value "$UNITN" 2>/dev/null || true)
[[ "$UTYPE" == simple || "$UTYPE" == exec || -z "$UTYPE" ]] || { echo "STOP: Unit $UNITN hat Type=$UTYPE (erwartet simple) - nichts geaendert"; exit 1; }
cat > "$W/zz-sdrhalt.conf" << 'DROPEOF'
# sdrHalt: Drop-in fuer prepper-sdr (die Haupt-Unit bleibt unveraendert). Rueckweg: diese Datei loeschen, sudo systemctl daemon-reload, sudo systemctl restart prepper-sdr
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=20
WatchdogSec=300
NotifyAccess=main
LimitCORE=0
DROPEOF
WD0=$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || echo "?")
if [[ ! -f "$DROPF" ]] && [[ "$WD0" != 0 && "$WD0" != "?" && "$WD0" != "infinity" ]]; then echo "STOP: Unit $UNITN hat schon WatchdogSec ($WD0) aus anderer Quelle - nichts geaendert"; exit 1; fi
echo "OK Unit $UNITN: $(grep -m1 '^ExecStart=' "$W/unit.txt" | cut -c1-160) | vorher Restart=$(systemctl show -p Restart --value "$UNITN" 2>/dev/null || echo ?), RestartSec=$(systemctl show -p RestartUSec --value "$UNITN" 2>/dev/null || echo ?), StartLimitIntervalSec=$(systemctl show -p StartLimitIntervalUSec --value "$UNITN" 2>/dev/null || echo ?), WatchdogSec=$WD0"
[[ -f "$DROPF" ]] && cmp -s "$DROPF" "$W/zz-sdrhalt.conf" && echo "OK Drop-in $DROPF schon vorhanden (gleicher Inhalt)" || echo "Drop-in $DROPF wird neu angelegt (nur diese Datei, Haupt-Unit bleibt)"
# ---------- 2) Trockenlauf ----------
for k in "sdr prepper_sdr $HSD"; do set -- $k
  python3 "$PF" sdrHalt "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$HE" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
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
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok" "selftest sdrWd2 ok" "selftest sdrAir ok" "selftest sdrAir2 ok" "selftest dabSql ok" "selftest airTest ok" "selftest sdrHalt ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum, Fake-Hilfsprogramm, Fake-SoapySDR-Modul; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet)"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest sdrHalt ok' "$W/sdrt.log" | tail -1 | cut -c1-500)"
done
if [[ "$SDR16" == "$KNOWN_SDR16N" && "$SM16" == "$KNOWN_SM16N" && "$D16" == "$KNOWN_D16N" ]]; then
  echo "OK sdrHalt schon drin - Guard-Rueckbau gegen Basis entfaellt (Inhalt = gepruefter Zielstand, sha16)"
else
  python3 "$HGD" "$HE" sdr "$M" "$W/work/prepper_sdr.py" "$HSD" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard sdrHalt - nichts geaendert"; exit 1; }
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
ALL=("$M")
DROP_OK=0; [[ -f "$DROPF" ]] && cmp -s "$DROPF" "$W/zz-sdrhalt.conf" && [[ "$(systemctl show -p WatchdogUSec --value "$UNITN" 2>/dev/null || true)" == 5min ]] && DROP_OK=1
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/dashboard.py" "$F" && [[ "$DROP_OK" == 1 ]]; then
  echo "OK sdrHalt schon installiert (prepper_sdr.py + Drop-in, vom Dienst geladen) - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  DROP_NEW=0
  rb() {
    echo "ROLLBACK: $1"
    if [[ "$DROP_NEW" == 1 ]]; then   # zuerst das Drop-in zurueck (sonst wuerde der alte Dienst ohne Takt vom Watchdog beendet)
      if [[ -f "$DROPF.bak-sdrhalt-$TS" ]]; then sudo cp -a "$DROPF.bak-sdrhalt-$TS" "$DROPF" || true; else sudo rm -f "$DROPF" || true; fi
      sudo systemctl daemon-reload || true
      echo "  Drop-in zurueck: $([[ -f "$DROPF" ]] && echo "alter Stand wiederhergestellt" || echo "entfernt")"
    fi
    for u in prepper-sdr prepper-dashboard; do sudo journalctl -u "$u" --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrAir|sdrWd|Traceback" | tail -4 | cut -c1-200 || true; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sdrhalt-$TS" ]] && cp -a "$x.bak-sdrhalt-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sdrhalt-$TS" ]] || continue; cmp -s "$x" "$x.bak-sdrhalt-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Sicherungen von vorher: $LZ.bak-sdrhalt-$TS, $WDJ.bak-sdrhalt-$TS (nicht zurueckgespielt; Watchdog-Zustand bleibt)"
    echo "alter Stand (airTest, ohne Drop-in) wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$WDJ"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-sdrhalt-$TS"
    { ls -1t "$x.bak-sdrhalt-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sdrhalt-$TS" \
      || { rm -f "$LZ.bak-sdrhalt-$TS"; for x in "${ALL[@]}" "$WDJ"; do rm -f "$x.bak-sdrhalt-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sdrhalt-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "prepper_sdr $M"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sdrhalt-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  [[ -f "$DROPF" ]] && sudo cp -a "$DROPF" "$DROPF.bak-sdrhalt-$TS"
  DROP_NEW=1
  sudo mkdir -p "$DROPDIR" && sudo install -m 0644 "$W/zz-sdrhalt.conf" "$DROPF" || { rb "Drop-in anlegen"; exit 1; }
  sudo systemctl daemon-reload || { rb "daemon-reload"; exit 1; }
  echo "Drop-in $DROPF angelegt, daemon-reload ok (Haupt-Unit unveraendert; wirksam erst mit dem Neustart von prepper-sdr)"
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (max 240 s) und 11D-Sync vom Airspy (max 300 s; sendet nichts) ..."
  sudo systemctl restart prepper-sdr.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$AC" status "$DASH_DIR" "$T0" > "$W/ast.log" 2>&1 && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { cat "$W/ast.log"; rb "prepper-sdr: Airspy 11D laeuft nicht ($(head -c 200 "$W/ast.log"))"; exit 1; }
  pok=0; for i in $(seq 1 120); do python3 "$AC" port 7979 > "$W/port.log" 2>&1 && { pok=1; break; }; sleep 1; done
  [[ "$pok" == 1 ]] && echo "OK welle-cli (Airspy) $(cat "$W/port.log")" || { rb "Port 7979 (welle-cli Airspy) lauscht nicht"; exit 1; }
  sok=0; for i in $(seq 1 100); do python3 "$AC2" proof "$DASH_DIR" "$T0" > "$W/proof.log" 2>&1 && { sok=1; break; }; sleep 3; done
  [[ "$sok" == 1 ]] && echo "OK $(cut -c1-460 "$W/proof.log")" || { cat "$W/proof.log"; rb "11D-Sync vom Airspy nach 300 s nicht nachgewiesen"; exit 1; }
  AET=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
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
python3 "$HCK" state "$DASH_DIR" > "$W/hs.log" 2>&1 && echo "OK $(cat "$W/hs.log")" || { cat "$W/hs.log"; rbx "sdr_halt.json kaputt"; }
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
R1='Traceback|sdrHalt( Start:|: (Waechter|Sperrgrund merken|Hilfsprogramm-Pruefung:|Neustart-Zaehler|Planer-Faden))|airTest (Tick|Befehl|Messung|Fehler|Standard-Gain pruefen|speichern|Anzeige)|dabSql( Start| on_dab)|dabSql: (Schreibfehler|Tabellen|Lesen|kartevec-Import|Schreibfaden nicht)|^sdrAir2? [A-Za-z/ ]*:|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:'
E1=$(echo "$JP" | grep -c -E "$R1" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JP" | grep -E "$R1" | head -5 | cut -c1-240; rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"; }
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JH=$(echo "$JP" | grep -F "sdrHalt: bereit" | tail -1 || true)
  [[ -n "$JH" && "$JH" == *"systemd-Watchdog aktiv"* ]] && echo "OK Journal prepper-sdr: $(echo "$JH" | cut -c1-300)" || rbx "prepper-sdr meldet sdrHalt nicht bereit mit systemd-Watchdog ($JH)"
  JT=$(echo "$JP" | grep -F "sdrHalt: Watchdog-Takt an systemd gesendet" | tail -1 || true)
  [[ -n "$JT" ]] && echo "OK Journal prepper-sdr: $(echo "$JT" | cut -c1-200)" || rbx "sdrHalt: Takt an systemd nicht nachgewiesen (Notify-Socket?)"
  systemctl show -p Restart -p RestartUSec -p StartLimitIntervalUSec -p WatchdogUSec -p NotifyAccess -p NRestarts "$UNITN" > "$W/ushow.log" 2>&1 || true
  python3 "$HCK" unit "$W/ushow.log" > "$W/hc.log" 2>&1 && echo "OK $(cat "$W/hc.log")" || { cat "$W/hc.log"; rbx "Unit prepper-sdr: Drop-in nicht wirksam"; }
  AET2=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ "$AET2" == "$AET" ]] && echo "OK prepper-sdr seit dem Neustart nicht vom Watchdog beendet (Start $AET2)" || rbx "prepper-sdr wurde nach dem Neustart erneut gestartet (Start $AET -> $AET2)"
  [[ "$(grep -c '^Restart=always' "$W/ushow.log" || true)" == 1 && "$(grep -E '^NRestarts=' "$W/ushow.log" | cut -d= -f2)" == 0 ]] || rbx "NRestarts nicht 0 (Dienst nach Neustart automatisch neu gestartet)"
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
echo "OK guards sdrHalt(sdr)=$(grep -c '# ===== sdrHalt:' "$M" || true) airTest(sdr)=$(grep -c '# ===== airTest:' "$M" || true) airTest(sm)=$(grep -c '# ===== airTest:' "$SMF" || true) airTest(dash)=$(grep -c '# ===== airTest:' "$F" || true) dabSql(sdr)=$(grep -c '# ===== dabSql:' "$M" || true) dabSql(sm)=$(grep -c '# ===== dabSql:' "$SMF" || true) dabSql(dash)=$(grep -c '# ===== dabSql:' "$F" || true) sdrAir2(sdr)=$(grep -c '# ===== sdrAir2:' "$M" || true) sdrAir2(sm)=$(grep -c '# ===== sdrAir2:' "$SMF" || true) sdrAir(sdr)=$(grep -c '# ===== sdrAir:' "$M" || true) sdrAir(sm)=$(grep -c '# ===== sdrAir:' "$SMF" || true) sdrAir(dash)=$(grep -c '# ===== sdrAir:' "$F" || true) sdrAir2(dash)=$(grep -c '# ===== sdrAir2:' "$F" || true) sdrWd2(sdr)=$(grep -c '# ===== sdrWd2:' "$M" || true) sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sysBoot(dash)=$(grep -c '# ===== sysBoot' "$F" || true)"
[[ -f "$M.bak-sdrhalt-$TS" ]] && echo "Backups: *.bak-sdrhalt-$TS (prepper_sdr.py, sdr_wd.json, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF" "$HDST"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg (Reihenfolge wichtig): 1) sudo rm $DROPF (Drop-in entfernen)  2) sudo systemctl daemon-reload  3) prepper_sdr.py.bak-sdrhalt-$TS zurueckkopieren  4) sudo systemctl restart prepper-sdr (kein Dashboard-Neustart noetig)"
echo "SoapySDR testen (nur auf Wunsch): in sdr_config.json air_fe auf soapy, dann sudo systemctl restart prepper-sdr; Rueckfall auf -F airspy geschieht automatisch"
echo "COMMIT $COMMIT_ARG sdrhalt=1 fertig"
