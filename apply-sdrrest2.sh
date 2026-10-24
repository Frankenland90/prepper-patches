#!/bin/bash
set -euo pipefail
# sdrRest2: baut auf sdrRest (live 24.10.: prepper_sdr 22e52c6c9c46620f, sdr_manager 2463e66656883d46, dashboard fd9528e4ebe2330e). Aendert prepper_sdr.py, sdr_manager.py und dashboard.py; Hilfsprogramm, sudoers, systemd-Drop-in, sdr_config.json, database.py bleiben.
#  - (1) Stick-Index/Seriennummern im Lauf nur LESEND geprueft (sysfs/USB-Systemdateien, hoechstens 1x je Minute im vorhandenen Waechter-Faden; kein Stick wird geoeffnet, Stick 3 nie, keine Stick-Liste per Programm). Bei Abweichung: Journalzeile; beim naechsten regulaeren Start wird frisch aufgeloest (bestehende Aufloesung). Keine Gain-Aenderung.
#  - (3) dabSql 10C: 7-Tage-Regel bleibt (kein Sonderfall fuer 433/APRS). Ist der Hobby-Stick (Stick 2) belegt, zeigt die Karte den Kanal 10C als 'nicht geprueft' (gelb) statt 'offline'.
#  - (4) Uhr: Aufraeumen von reception_log pausiert bei unsynchroner Uhr; die Offline-Rechnung laeuft nach 6 h unsynchroner, aber plausibler Uhr weiter, mit Hinweiszeile 'Uhr ungeprueft' auf /dabhist und API-Feld clock (state/offline_calc/cleanup).
#  - Alle Gain-Sperren, Mesh-Regeln (nichts ans Mesh gesendet) und Namen-Regeln bleiben. Kein neuer Faden, kein sudo-Recht, keine Secrets.
# Basis streng (sha16): sdrRest-Stand oder sdrRest2 schon drin. Sonst Abbruch ohne Aenderung. Neustart prepper-sdr + prepper-dashboard (Dienst-Neustart, kein Reboot). Sendet nichts.
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
W=/tmp/sdrrest2-apply
KEEP_LAST=3
KNOWN_D16="fd9528e4ebe2330e"     # dashboard.py nach sdrRest
KNOWN_D16N="e3a6163a3df2b8ba"     # dashboard.py nach sdrRest2 (Ziel)
KNOWN_SM16="2463e66656883d46"    # sdr_manager.py nach sdrRest
KNOWN_SM16N="002f6c5cad4bc1cb"    # sdr_manager.py nach sdrRest2 (Ziel)
KNOWN_SDR16="22e52c6c9c46620f"   # prepper_sdr.py nach sdrRest
KNOWN_SDR16N="9e2c598c99671a76"   # prepper_sdr.py nach sdrRest2 (Ziel)
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
echo "=== sdrRest2 apply (USB-Stand im Lauf nur lesend, dabSql: 10C nicht geprueft bei belegtem Hobby-Stick, Uhr ungeprueft nach 6 h), Dashboard-Port $PORT ==="
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
EXPECT_AE="534270c2f31853dd129fadc5e440e4ac56af554382136e00465287af37289fa8"
cat > "$W/r2_edits.py" << 'AE_EOF'
# sdrRest2: Stellen (alt, neu) auf dem Stand nach sdrRest. Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
('        selftest_sdrrest()\n', '        selftest_sdrrest()\n        selftest_sdrrest2()\n'),
('                        "p10c": {k: p10.get(k) for k in ("t_sync", "t_check", "ok", "ens")} if p10 else None})\n', '                        "p10c": _rs2_p10c(p10)})\n'),
('                self.mod.dq_ingest(self.path(), rec, now, True, _rs_ntp_state())      # sdrRest: Uhr-Schutz\n', '                self.mod.dq_ingest(self.path(), rec, now, True, _rs_ntp_state(), _rs2_unsync_s())      # sdrRest2: Uhr-Schutz\n'),
('                self.mod.dq_tick(self.path(), now, self.p10, True, True, _rs_ntp_state())      # sdrRest: Uhr-Schutz\n', '                self.mod.dq_tick(self.path(), now, self.p10, True, True, _rs_ntp_state(), _rs2_unsync_s())      # sdrRest2: Uhr-Schutz\n'),
('        assert s["clock"]["ok"] is False and "Hinweis" in s["txt"], s["clock"]\n', '        assert s["clock"]["ok"] is False and "Hinweis" in s["clock"]["txt"], s["clock"]                  # sdrRest2: Hinweis steht im Feld clock (Karte zeigt ihn als eigene Zeile)\n'),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SM_EDITS = [
('    print(selftest_sdrrest())\n', '    print(selftest_sdrrest())\n    print(selftest_sdrrest2())\n'),
('def dq_ingest(path, rec, now=None, guard=False, ntp=None):\n', 'def dq_ingest(path, rec, now=None, guard=False, ntp=None, unsync_s=0):\n'),
('            stt, note, ls2 = dq_chstat(ch, ls, now, p10.get("t_sync"), _dq_start(con)) if (sync or not guard or rs_clock(con, now, ntp)["ok"]) else rs_stored(con, ch, ls)   # sdrRest\n', '            rs2_p10busy(con, now, p10)                                                                  # sdrRest2: Hobby-Stick belegt merken\n            stt, note, ls2 = rs2_chstat(ch, ls, now, p10.get("t_sync"), _dq_start(con), p10.get("busy")) if (sync or not guard or rs2_clock(con, now, ntp, unsync_s)["calc"]) else rs_stored(con, ch, ls)   # sdrRest2\n'),
('def dq_tick(path, now=None, p10c=None, prune=True, guard=False, ntp=None):\n', 'def dq_tick(path, now=None, p10c=None, prune=True, guard=False, ntp=None, unsync_s=0):\n'),
('                out["clock"] = rs_clock(con, now, ntp)\n                if not out["clock"]["ok"]:\n                    return out\n', '                out["clock"] = rs2_clock(con, now, ntp, unsync_s)             # sdrRest2: pausiert = nichts, ungeprueft = nur Offline-Rechnung, ok = alles\n                if not out["clock"]["calc"]:\n                    return out\n            rs2_p10busy(con, now, p10)                                        # sdrRest2: Hobby-Stick belegt merken\n'),
('                stt, note, ls = dq_chstat(ch, r[1], now, p10.get("t_sync"), _dq_start(con))\n', '                stt, note, ls = rs2_chstat(ch, r[1], now, p10.get("t_sync"), _dq_start(con), p10.get("busy"))   # sdrRest2\n'),
('            if prune:\n', '            if prune and (not guard or out["clock"]["prune"]):                # sdrRest2: Aufraeumen nur bei synchroner, plausibler Uhr\n'),
('            ck = rs_clock_view(con, now) if guard else {"ok": True, "why": "", "txt": ""}                       # sdrRest: Uhr-Schutz\n            out["clock"] = {"ok": ck["ok"], "txt": ck["txt"]}\n', '            ck = rs2_clock_view(con, now) if guard else {"ok": True, "state": "ok", "calc": True, "prune": True, "why": "", "txt": ""}                       # sdrRest2: Uhr-Zustand\n            out["clock"] = {"ok": ck["ok"], "txt": ck["txt"], "state": ck["state"], "offline_calc": ck["calc"], "cleanup": ck["prune"]}\n            busy10 = rs2_busy_view(con, now)                                                                    # sdrRest2: Hobby-Stick belegt (frischer Merker)\n'),
('                stt, note, ls = dq_chstat(ch, r["last_sync"], now, None, _dq_start(con)) if ck["ok"] else ((r["status"] or "unknown"), (r["note"] or ""), r["last_sync"])   # sdrRest\n', '                stt, note, ls = rs2_chstat(ch, r["last_sync"], now, None, _dq_start(con), busy10) if ck["calc"] else ((r["status"] or "unknown"), (r["note"] or ""), r["last_sync"])   # sdrRest2\n'),
('        if not ck["ok"]:\n            out["txt"] += " · " + ck["txt"]                                                                     # sdrRest: Hinweiszeile\n', '        u10 = [c["ch"] for c in out["channels"] if c["status"] == "unchecked"]                                  # sdrRest2: nicht geprueft statt offline\n        if u10:\n            out["txt"] += " · %s nicht geprüft (Hobby-Stick belegt)" % ", ".join(u10)                           # Uhr-Hinweis steht im Feld clock (Karte zeigt ihn als eigene Zeile)\n'),
('    assert s.get("clock") == {"ok": True, "txt": ""}\n', '    assert s.get("clock", {}).get("ok") is True and s["clock"]["txt"] == ""                       # sdrRest2: Feld clock hat weitere Schluessel\n'),
('    assert sv["clock"]["ok"] is False and "NTP" in sv["clock"]["txt"] and "Hinweis" in sv["txt"] and sv["channels"][0]["status"] == "active"', '    assert sv["clock"]["ok"] is False and "NTP" in sv["clock"]["txt"] and sv["channels"][0]["status"] == "active"'),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
('        cls, tx = ("ok", "aktiv") if stt == "active" else (("offline", "offline") if stt == "offline" else ("gelb", "noch keine Prüfung"))\n', '        cls, tx = ("ok", "aktiv") if stt == "active" else (("offline", "offline") if stt == "offline" else (("gelb", "nicht geprüft") if stt == "unchecked" else ("gelb", "noch keine Prüfung")))   # sdrRest2\n'),
]
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
AE_EOF
EXPECT_ASD="7e1d22e0a30473bedf5bb0c4470b50cc12b3ee9009399d8558e4a871527670bc"
cat > "$W/r2_sdr_block.py" << 'ASD_EOF'
# ===== sdrRest2: prepper-sdr - (1) Stick-Index/Seriennummern im Lauf nur LESEND pruefen (sysfs, kein Stick geoeffnet, Stick 3 nie), bei Abweichung Journalzeile und frische Aufloesung beim naechsten regulaeren Start (vorhandene resolve-Aufloesung), keine Gain-Aenderung; (3) Hobby-Stick belegt-Merker fuer dabSql (10C nicht geprueft statt offline); (4) Dauer der unsynchronen Uhr fuer die 6-h-Regel der Offline-Rechnung =====
RS2_SYS_S = 60                  # sysfs-Pruefung hoechstens einmal je Minute (im vorhandenen Waechter-Faden, nur lesen)
RS2_LOG_S = 120                 # Journalzeile je Art hoechstens alle 2 min
_RS2 = {"snap": None, "t": -1e9, "chg": set(), "logt": {}, "unsync0": None, "ready": False}


def _rs2_log(key, txt, every=RS2_LOG_S):
    n = time.monotonic()
    if n - _RS2["logt"].get(key, -1e9) >= every:
        _RS2["logt"][key] = n
        print("sdrRest2: " + txt, flush=True)


def _rs2_unsync_s():
    """Sekunden, seit die Pi-Uhr als nicht NTP-synchron gesehen wird (monoton, seit Dienststart bzw. seit dem Verlust der Synchronisation); 0 = synchron oder nicht feststellbar."""
    v = _rs_ntp_state()
    n = time.monotonic()
    if v is False:
        if _RS2["unsync0"] is None:
            _RS2["unsync0"] = n
        return int(n - _RS2["unsync0"])
    _RS2["unsync0"] = None
    return 0


def _rs2_busy(base):
    """Ist der Hobby-Stick belegt (manueller Modus 433/APRS/Netz/Aus, Preset ausserhalb von Rundfunk, alte Alarm-Uebernahme)? Nur lesen; Fehler = nicht belegt."""
    try:
        m = get_mode(base)
        if m.get("mode") in ("433", "aprs", "tcp", "off"):
            return True
        if m.get("mode") == "preset" and (preset(m.get("preset")) or {}).get("kind") not in ("fm", "dab"):
            return True
        return bool(t2_takeover(base).get("on"))
    except Exception:
        return False


def _rs2_p10c(p10):
    """p10c-Teil des dabSql-Satzes wie bisher, plus busy = Hobby-Stick belegt."""
    d = {k: p10.get(k) for k in ("t_sync", "t_check", "ok", "ens")} if p10 else {}
    try:
        if _DQW.base and _rs2_busy(_DQW.base):
            d["busy"] = True
    except Exception:
        pass
    return d or None


def _rs2_read(fn):
    with open(fn) as f:
        return f.read(64)


def _rs2_sysfs_snap():
    """{Seriennummer: [(Bus-Pfad, devnum), ...]} aller bekannten USB-Funkgeraete - nur sysfs-Dateien lesen (stick_info), kein Geraet oeffnen, keine Stick-Liste per Programm."""
    ids = tuple(x for v in DEV_KIND_USB.values() for x in v)
    root = os.environ.get("SDR_SYSFS_USB", "/sys/bus/usb/devices")
    out = {}
    for x in stick_info(ids)[:32]:
        try:
            dn = _rs2_read(os.path.join(root, x["bus"], "devnum")).strip()
        except Exception:
            dn = "?"
        out.setdefault(x.get("serial") or ("ohne SN @" + x["bus"]), []).append((x["bus"], dn))
    return out


def _rs2_diff(old, new):
    """-> (Texte, geaenderte Seriennummern). Nur Unterschiede zum letzten gemerkten Stand."""
    t, sns = [], set()
    for sn in sorted(set(old) | set(new)):
        o, n = old.get(sn), new.get(sn)
        if o == n:
            continue
        sns.add(sn)
        if o is None:
            t.append("SN %s neu (%s)" % (sn, ", ".join("%s/devnum %s" % x for x in n)))
        elif n is None:
            t.append("SN %s weg (war %s)" % (sn, ", ".join("%s/devnum %s" % x for x in o)))
        else:
            t.append("SN %s: %s -> %s" % (sn, ", ".join("%s/devnum %s" % x for x in o), ", ".join("%s/devnum %s" % x for x in n)))
    for sn, v in sorted(new.items()):
        if len(v) > 1 and not sn.startswith("ohne SN"):
            t.append("SN %s doppelt (%d Geraete)" % (sn, len(v)))
    return t, sns


def _rs2_sysfs_tick(base=None, mono=None):
    """Aus dem Waechter-Faden: hoechstens einmal je Minute den USB-Stand (sysfs) lesen; Abweichung = Journalzeile, naechster regulaerer Start loest frisch auf. Aendert nichts."""
    n = time.monotonic() if mono is None else mono
    if n - _RS2["t"] < RS2_SYS_S:
        return None
    _RS2["t"] = n
    cur = _rs2_sysfs_snap()
    old = _RS2["snap"]
    _RS2["snap"] = cur
    if old is None:
        if not _RS2["ready"]:
            _RS2["ready"] = True
            print("sdrRest2: USB-Pruefung im Lauf bereit - nur sysfs gelesen (kein Stick geoeffnet, Stick 3 nie), %d Geraete gemerkt; bei Abweichung Journalzeile und frische Aufloesung beim naechsten Start" % len(cur), flush=True)
        return None
    txt, sns = _rs2_diff(old, cur)
    if not txt:
        return None
    _RS2["chg"].update(sns or {"*"})
    _rs2_log("usb", "USB-Stand geaendert (nur sysfs gelesen, kein Stick geoeffnet): %s - beim naechsten regulaeren Start wird frisch aufgeloest; keine Gain-Aenderung" % "; ".join(txt)[:300])
    return txt


_rs2_orig_resolve = Planner.resolve
_rs2_orig_sh_tick = _sh_tick


def _rs2_resolve(self):
    r = _rs2_orig_resolve(self)
    try:
        if _RS2["chg"]:
            sn = str(getattr(self, "dev_sn", "") or cfg_serial(self.cfg) or "")
            if sn in _RS2["chg"] or "*" in _RS2["chg"]:
                _RS2["chg"].discard(sn)
                _RS2["chg"].discard("*")
                _rs2_log("res", "SN %s nach USB-Aenderung frisch aufgeloest: Index %s (vorhandene Aufloesung, kein Gain-Eingriff)" % (sn, getattr(self, "dev_idx", "?")), 0)
    except Exception:
        pass
    return r


def _sh_tick(base, now, mono=None):
    r = _rs2_orig_sh_tick(base, now, mono)
    try:
        _rs2_sysfs_tick(base)
    except Exception as ex:
        _rs2_log("tick", "USB-Pruefung: %s" % ex)
    return r


Planner.resolve = _rs2_resolve


def selftest_sdrrest2():
    import tempfile
    sys.path.insert(0, os.getcwd())
    import sdr_manager as _m
    assert hasattr(_m, "rs2_clock") and hasattr(_m, "rs2_chstat")
    tmp = tempfile.mkdtemp(prefix="sdrrest2-sdr-")
    sysfs = os.path.join(tmp, "usb")
    os.makedirs(sysfs)

    def dev(bus, vid, pid, sn, dn):
        d = os.path.join(sysfs, bus)
        os.makedirs(d, exist_ok=True)
        for k, v in (("idVendor", vid), ("idProduct", pid), ("serial", sn), ("devnum", dn), ("manufacturer", "x"), ("product", "y")):
            with open(os.path.join(d, k), "w") as f:
                f.write(v + "\n")

    dev("1-1.1", "0bda", "2838", "19348831", "5")
    dev("1-1.2", "0bda", "2838", "72055505", "6")
    dev("1-1.3", "1d50", "60a1", "44A42E4F2A5B1C83", "7")
    dev("1-1.4", "0bda", "2838", "00000003", "8")             # Stick 3 (unbekannt): nur im Snapshot, nie geoeffnet
    dev("1-1.5", "046d", "c52b", "KEYB", "9")                # fremdes Geraet: ignoriert
    old_env = os.environ.get("SDR_SYSFS_USB")
    os.environ["SDR_SYSFS_USB"] = sysfs
    g = globals()
    out = []
    import builtins
    pr0 = builtins.print
    builtins.print = lambda *a, **k: out.append(" ".join(str(x) for x in a))
    opened = []
    try:
        s = _rs2_sysfs_snap()
        assert sorted(s) == ["00000003", "19348831", "44A42E4F2A5B1C83", "72055505"] and s["19348831"] == [("1-1.1", "5")], s
        assert _rs2_diff(s, s) == ([], set())
        _RS2.update(snap=None, t=-1e9, chg=set(), logt={}, ready=False)
        assert _rs2_sysfs_tick(tmp, 1000.0) is None and any("USB-Pruefung im Lauf bereit" in x and "4 Geraete" in x for x in out)    # erster Lauf: nur merken
        assert _rs2_sysfs_tick(tmp, 1010.0) is None                                          # Drosselung: nicht oefter als je Minute
        dev("1-1.2", "0bda", "2838", "72055505", "11")                                     # Stick neu enumeriert (devnum)
        assert _rs2_sysfs_tick(tmp, 1020.0) is None                                          # noch gedrosselt
        t = _rs2_sysfs_tick(tmp, 1061.0)
        assert t and "SN 72055505: 1-1.2/devnum 6 -> 1-1.2/devnum 11" in t[0] and _RS2["chg"] == {"72055505"}, (t, _RS2["chg"])
        assert any("USB-Stand geaendert (nur sysfs gelesen, kein Stick geoeffnet)" in x and "keine Gain-Aenderung" in x for x in out), out
        assert _rs2_sysfs_tick(tmp, 1130.0) is None                                          # nichts Neues = keine Zeile
        dev("1-1.1", "dead", "beef", "19348831", "5")                                      # Stick weg (andere USB-ID = nicht mehr ein Funkgeraet)
        dev("1-1.6", "0bda", "2838", "72055505", "12")                                     # doppelte SN
        t = _rs2_sysfs_tick(tmp, 1200.0)
        assert t and any("SN 19348831 weg" in x for x in t) and any("SN 72055505 doppelt (2 Geraete)" in x for x in t), t
        # resolve: nach Abweichung frisch aufgeloest, Zeile mit Index; ohne Abweichung nichts
        class _P:
            cfg = {"serial": "72055505"}
            dev_sn = "72055505"
            dev_idx = 1
        res0 = g["_rs2_orig_resolve"]
        g["_rs2_orig_resolve"] = lambda self: self.dev_idx
        try:
            _RS2["chg"] = {"72055505"}
            out.clear()
            assert _rs2_resolve(_P()) == 1 and any("SN 72055505 nach USB-Aenderung frisch aufgeloest: Index 1" in x for x in out) and not _RS2["chg"]
            out.clear()
            assert _rs2_resolve(_P()) == 1 and not out
        finally:
            g["_rs2_orig_resolve"] = res0
        # Waechter: _sh_tick ruft die Pruefung auf und wirft nie
        n0 = _RS2["t"]
        sh0 = g["_rs2_orig_sh_tick"]
        g["_rs2_orig_sh_tick"] = lambda base, now, mono=None: "sh"
        try:
            _RS2["t"] = -1e9
            assert _sh_tick(tmp, 1.0, 2.0) == "sh" and _RS2["t"] > -1e9
            s0 = g["_rs2_sysfs_snap"]
            g["_rs2_sysfs_snap"] = lambda: (_ for _ in ()).throw(RuntimeError("kaputt"))
            _RS2["t"] = -1e9
            assert _sh_tick(tmp, 1.0, 2.0) == "sh"
            g["_rs2_sysfs_snap"] = s0
        finally:
            g["_rs2_orig_sh_tick"] = sh0
        # Dauer der unsynchronen Uhr (monoton): ab dem ersten Sehen; synchron/unbekannt = 0
        _RS.update(t=time.monotonic(), v=False)
        _RS2["unsync0"] = None
        assert _rs2_unsync_s() == 0
        _RS2["unsync0"] = time.monotonic() - 7 * 3600
        assert 7 * 3600 <= _rs2_unsync_s() < 7 * 3600 + 5
        _RS["v"] = True
        assert _rs2_unsync_s() == 0 and _RS2["unsync0"] is None
        _RS["v"] = None
        assert _rs2_unsync_s() == 0
        # Hobby-Stick belegt: nur lesen (sdr_mode.json / Uebernahme-Datei), Fehler = nicht belegt
        b = os.path.join(tmp, "base")
        os.makedirs(b)
        assert _rs2_busy(b) is False
        with open(os.path.join(b, "sdr_mode.json"), "w") as f:
            json.dump({"mode": "433", "until": int(time.time()) + 600, "at": int(time.time())}, f)
        assert _rs2_busy(b) is True
        with open(os.path.join(b, "sdr_mode.json"), "w") as f:
            json.dump({"mode": "auto"}, f)
        assert _rs2_busy(b) is False and _rs2_busy(os.path.join(tmp, "gibtsnicht")) is False
        d0 = g["_DQW"]
        w = DabsqlWriter()
        w.base = b
        g["_DQW"] = w
        try:
            assert _rs2_p10c({}) is None and _rs2_p10c({"t_sync": 5, "t_check": 6, "ok": True, "ens": "N", "extra": 1}) == {"t_sync": 5, "t_check": 6, "ok": True, "ens": "N"}
            with open(os.path.join(b, "sdr_mode.json"), "w") as f:
                json.dump({"mode": "aprs", "until": int(time.time()) + 600, "at": int(time.time())}, f)
            assert _rs2_p10c({}) == {"busy": True} and _rs2_p10c({"t_sync": 5})["busy"] is True
        finally:
            g["_DQW"] = d0
    finally:
        builtins.print = pr0
        if old_env is None:
            os.environ.pop("SDR_SYSFS_USB", None)
        else:
            os.environ["SDR_SYSFS_USB"] = old_env
        _RS2.update(snap=None, t=-1e9, chg=set(), logt={}, unsync0=None, ready=False)
        _RS["t"], _RS["v"] = -1e9, None
    print("selftest sdrRest2 ok (USB-Stand im Lauf nur ueber sysfs gelesen, keine Stick-Liste per Programm, Stick 3 nie geoeffnet, 1x je Minute im Waechter-Faden; Abweichung = Journalzeile + frische Aufloesung beim naechsten Start, keine Gain-Aenderung; Hobby-Stick-belegt-Merker fuer dabSql; Dauer der unsynchronen Uhr fuer die 6-h-Regel)")
ASD_EOF
EXPECT_ASM="2d4e31780f9b90fcd9f86b7d045a9e7ec3f777f544c5e861a9204e0c9c4b7493"
cat > "$W/r2_sm_block.py" << 'ASM_EOF'
# ===== sdrRest2: dabSql-Datenschicht - Uhr-Schutz verfeinert (Aufraeumen pausiert bei unsynchroner Uhr; Offline-Rechnung laeuft nach 6 h unsynchroner, aber plausibler Uhr weiter, Hinweis Uhr ungeprueft) und 10C nicht geprueft statt offline, solange der Hobby-Stick belegt ist (7-Tage-Regel bleibt) =====
RS2_UNSYNC_S = 6 * 3600           # so lange unsynchron (Pi-Uhr ohne NTP), dann rechnet dabSql Offline auf der plausiblen Uhr weiter; Aufraeumen (60 Tage) bleibt pausiert
RS2_BUSY_FRESH_S = 1800           # der vom Schreibfaden gemerkte Zustand Hobby-Stick belegt (meta dabsql_p10busy) gilt so lange


def rs2_clock_calc(con, now, ntp, unsync_s=0):
    """Uhr-Zustand: ok (synchron/NTP nicht feststellbar, plausibel) | ungeprueft (nicht synchron seit >= 6 h, aber plausibel: Offline-Rechnung laeuft, Aufraeumen pausiert) | pausiert (nichts loeschen, Offline nicht neu rechnen). -> dict state/calc/prune/why"""
    ok, why = rs_clock_calc(con, now, None)                                     # Plausibilitaet: nach Build-Datum, keine Messzeit in der Zukunft
    if not ok:
        return {"state": "pausiert", "calc": False, "prune": False, "why": why}
    if ntp is False:
        u = int(unsync_s or 0)
        if u >= RS2_UNSYNC_S:
            return {"state": "ungeprueft", "calc": True, "prune": False, "why": "Pi-Uhr seit %s nicht mit NTP synchron (Zeit plausibel)" % _dq_age(u)}
        return {"state": "pausiert", "calc": False, "prune": False,
                "why": "Pi-Uhr nicht mit NTP synchron (Offline-Rechnung läuft nach %s unsynchroner, plausibler Uhr weiter, noch %s)" % (_dq_age(RS2_UNSYNC_S), _dq_age(RS2_UNSYNC_S - u))}
    return {"state": "ok", "calc": True, "prune": True, "why": ""}


def rs2_txt(c):
    if c["state"] == "ok":
        return ""
    if c["state"] == "ungeprueft":
        return "Uhr ungeprüft: %s - Offline-Rechnung läuft weiter (Alter kann abweichen), Aufräumen (60 Tage) pausiert" % c["why"]
    return "Hinweis: %s - Aufräumen (60 Tage) und Offline-Rechnung pausieren, bis die Uhr stimmt" % c["why"]


def rs2_clock(con, now, ntp, unsync_s=0):
    """Schreibfaden: Uhr-Zustand rechnen und fuer die Anzeige in meta dabsql_clock merken (eine Zeile, im selben Schreibvorgang). -> {ok, state, calc, prune, why, txt}"""
    c = rs2_clock_calc(con, now, ntp, unsync_s)
    try:
        con.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('dabsql_clock', ?)", (json.dumps({"t": int(now), "ok": c["state"] == "ok", "state": c["state"], "calc": c["calc"], "prune": c["prune"],
                                                                                              "why": c["why"], "ntp": ntp, "unsync_s": int(unsync_s or 0)}),))
    except Exception as e:
        _dq_err("Uhr-Merker", e)
    c["ok"] = c["state"] == "ok"
    c["txt"] = rs2_txt(c)
    return c


def rs2_clock_view(con, now):
    """Anzeige (Dashboard-Prozess): Plausibilitaet selbst, NTP-Zustand aus dem Merker des Schreibfadens (nur wenn frisch; alter Merker ohne state = pausiert). Nur lesen."""
    c = rs2_clock_calc(con, now, None)
    if c["state"] == "ok":
        try:
            r = con.execute("SELECT v FROM meta WHERE k='dabsql_clock'").fetchone()
            m = json.loads(r[0]) if r else None
            if isinstance(m, dict) and abs(now - int(m.get("t") or 0)) <= RS_FRESH_S:
                st = m.get("state") if m.get("state") in ("ok", "ungeprueft", "pausiert") else ("ok" if m.get("ok") is not False else "pausiert")
                if st != "ok":
                    c = {"state": st, "calc": st == "ungeprueft", "prune": False, "why": str(m.get("why") or "Pi-Uhr nicht synchron")[:120]}
        except Exception:
            pass
    c["ok"] = c["state"] == "ok"
    c["txt"] = rs2_txt(c)
    return c


def rs2_chstat(ch, last_sync, now, p10c_sync=None, start=None, busy=False):
    """dq_chstat wie bisher (10C: 7-Tage-Regel); ist 10C offline, waehrend der Hobby-Stick belegt ist (manueller Modus 433/APRS/Netz/Aus, Alarm-Uebernahme), steht 'nicht geprueft' statt 'offline'."""
    stt, note, ls = dq_chstat(ch, last_sync, now, p10c_sync, start)
    if ch == "10C" and busy and stt == "offline":
        return "unchecked", "nicht geprüft: Hobby-Stick ist belegt (manueller Modus oder Übernahme)%s" % ((" · zuletzt Sync vor %s" % _dq_age(now - ls)) if ls else " · noch kein Sync"), ls
    return stt, note, ls


def rs2_p10busy(con, now, p10):
    """Schreibfaden: ob der Hobby-Stick belegt ist, fuer die Anzeige merken (meta dabsql_p10busy; nur bei Aenderung oder alle 10 min)."""
    b = bool(p10.get("busy")) if isinstance(p10, dict) else False
    try:
        r = con.execute("SELECT v FROM meta WHERE k='dabsql_p10busy'").fetchone()
        m = json.loads(r[0]) if r else None
        if not isinstance(m, dict) or bool(m.get("busy")) != b or abs(now - int(m.get("t") or 0)) >= 600:
            con.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('dabsql_p10busy', ?)", (json.dumps({"t": int(now), "busy": b}),))
    except Exception as e:
        _dq_err("Hobby-Merker", e)


def rs2_busy_view(con, now):
    """Anzeige: Hobby-Stick belegt laut frischem Merker. Nur lesen."""
    try:
        r = con.execute("SELECT v FROM meta WHERE k='dabsql_p10busy'").fetchone()
        m = json.loads(r[0]) if r else None
        return bool(isinstance(m, dict) and m.get("busy") and abs(now - int(m.get("t") or 0)) <= RS2_BUSY_FRESH_S)
    except Exception:
        return False


def selftest_sdrrest2():
    import sqlite3
    import tempfile
    d = tempfile.mkdtemp(prefix="sdrrest2-")
    p = os.path.join(d, "lagezentrum.db")
    assert dq_migrate(p)
    now = RS_BUILD_T + 20 * 86400
    DAY = 86400
    con = db.connect(p)
    try:
        with con:
            con.execute("INSERT INTO channel_status(channel, last_sync, status, note, last_check, ensemble, updated) VALUES('11D', ?, 'active', 'zuletzt Sync vor 5 s', ?, 'BR', ?)", (now - 5, now - 5, now - 5))
            con.execute("INSERT INTO channel_status(channel, last_sync, status, note, last_check, ensemble, updated) VALUES('10C', ?, 'active', 'zuletzt Sync vor 1 h', ?, 'Nbg', ?)", (now - 8 * DAY, now - 8 * DAY, now - 8 * DAY))
            con.execute("INSERT INTO reception_log(timestamp, channel, tii, snr, errors, sync, fic_rate, sn) VALUES(?, '11D', NULL, 1, NULL, 0, NULL, NULL)", (now - 70 * DAY,))
    finally:
        con.close()
    n_old = lambda: sqlite3.connect(p).execute("SELECT COUNT(*) FROM reception_log WHERE timestamp < ?", (now - 60 * DAY,)).fetchone()[0]
    st = lambda ch: tuple(sqlite3.connect(p).execute("SELECT status, note FROM channel_status WHERE channel=?", (ch,)).fetchone())
    # --- Uhr: Zustaende
    c = db.connect(p)
    assert rs2_clock_calc(c, now, True)["state"] == "ok" and rs2_clock_calc(c, now, None)["state"] == "ok"
    a = rs2_clock_calc(c, now, False, 0)
    assert a["state"] == "pausiert" and not a["calc"] and not a["prune"] and "noch 6 h" in a["why"], a
    a = rs2_clock_calc(c, now, False, RS2_UNSYNC_S - 1)
    assert a["state"] == "pausiert" and not a["calc"]
    a = rs2_clock_calc(c, now, False, RS2_UNSYNC_S)
    assert a["state"] == "ungeprueft" and a["calc"] and not a["prune"] and "seit 6 h" in a["why"], a
    assert rs2_clock_calc(c, RS_BUILD_T - 100, False, 99999)["state"] == "pausiert"           # vor Build-Datum: auch nach 6 h nicht plausibel -> pausiert
    assert "Uhr ungeprüft" in rs2_txt(a) and "Offline-Rechnung läuft weiter" in rs2_txt(a) and rs2_txt({"state": "ok"}) == ""
    c.close()
    # --- Tick: unsynchron < 6 h = pausiert (nichts loeschen, Status eingefroren); >= 6 h = Offline wird gerechnet, aber nichts geloescht; synchron = alles
    o = dq_tick(p, now, {}, True, True, False, 100)
    assert o["clock"]["state"] == "pausiert" and o["pruned"] == 0 and n_old() == 1 and st("11D")[0] == "active", o
    o = dq_tick(p, now + 4000, {}, True, True, False, RS2_UNSYNC_S + 5)
    assert o["clock"]["state"] == "ungeprueft" and o["pruned"] == 0 and n_old() == 1, o
    assert st("11D")[0] == "offline" and st("10C")[0] == "offline", (st("11D"), st("10C"))     # Offline wurde auf der plausiblen Uhr gerechnet
    sv = dq_summary(p, now + 4100, guard=True)
    assert sv["clock"]["state"] == "ungeprueft" and sv["clock"]["ok"] is False and sv["clock"]["offline_calc"] is True and sv["clock"]["cleanup"] is False and "Uhr ungeprüft" in sv["clock"]["txt"], sv["clock"]
    assert sv["channels"][0]["status"] == "offline" and "Uhr ungeprüft" not in sv["txt"], sv["txt"]    # Hinweis steht nur im Feld clock (die Karte zeigt ihn als eigene Zeile)
    o = dq_tick(p, now + 4200, {}, True, True, True, 0)                                        # synchron: Aufraeumen laeuft
    assert o["clock"]["state"] == "ok" and o["pruned"] == 1 and n_old() == 0, o
    sv = dq_summary(p, now + 4300, guard=True)
    assert sv["clock"] == {"ok": True, "txt": "", "state": "ok", "offline_calc": True, "cleanup": True}, sv["clock"]
    # --- Aufnahme: pausiert = Status bleibt gespeichert, ungeprueft = wird gerechnet
    dq_tick(p, now + 5000, {}, True, True, True, 0)
    with db.connect(p) as c2:
        c2.execute("UPDATE channel_status SET status='active', note='zuletzt Sync vor 5 s', last_sync=? WHERE channel='11D'", (now - 3 * 3600,))
    dq_ingest(p, {"ch": "11D", "t": now + 5100, "sync": False}, now + 5100, True, False, 60)
    assert st("11D") == ("active", "zuletzt Sync vor 5 s"), st("11D")                           # pausiert: nichts neu gerechnet
    dq_ingest(p, {"ch": "11D", "t": now + 5200, "sync": False}, now + 5200, True, False, RS2_UNSYNC_S)
    assert st("11D")[0] == "offline", st("11D")                                                 # nach 6 h unsynchron: Offline-Rechnung laeuft
    # --- 10C: 7-Tage-Regel bleibt, Hobby-Stick belegt -> nicht geprueft
    with db.connect(p) as c2:
        c2.execute("UPDATE channel_status SET status='active', note='x', last_sync=? WHERE channel='10C'", (now + 5300 - 6 * DAY,))
    assert rs2_chstat("10C", now - 6 * DAY, now, None, None, True)[0] == "active"               # 6 Tage: weder offline noch nicht geprueft
    assert rs2_chstat("10C", now - 8 * DAY, now, None, None, False)[0] == "offline"             # 8 Tage, Stick frei: offline wie bisher
    s8 = rs2_chstat("10C", now - 8 * DAY, now, None, None, True)
    assert s8[0] == "unchecked" and "nicht geprüft" in s8[1] and "zuletzt Sync vor 8 Tagen" in s8[1] and s8[2] == now - 8 * DAY, s8
    assert rs2_chstat("11D", now - 3 * 3600, now, None, None, True)[0] == "offline"             # nur 10C hat den Sonderfall
    assert rs2_chstat("10C", None, now, None, now - 9 * DAY, True)[0] == "unchecked" and rs2_chstat("10C", None, now, None, now - 9 * DAY, False)[0] == "offline"
    assert rs2_chstat("10C", None, now, None, now - 1 * DAY, True)[0] == "unknown"
    with db.connect(p) as c2:
        c2.execute("UPDATE channel_status SET last_sync=? WHERE channel='10C'", (now + 6000 - 8 * DAY,))
    dq_tick(p, now + 6000, {"t_sync": None, "busy": True}, True, True, True, 0)
    assert st("10C")[0] == "unchecked", st("10C")
    sv = dq_summary(p, now + 6100, guard=True)
    c10 = [x for x in sv["channels"] if x["ch"] == "10C"][0]
    assert c10["status"] == "unchecked" and "10C nicht geprüft (Hobby-Stick belegt)" in sv["txt"] and "10C offline" not in sv["txt"], (c10, sv["txt"])
    dq_tick(p, now + 6200, {"t_sync": None}, True, True, True, 0)                               # Stick wieder frei -> offline wie bisher
    assert st("10C")[0] == "offline"
    sv = dq_summary(p, now + 6300, guard=True)
    assert [x for x in sv["channels"] if x["ch"] == "10C"][0]["status"] == "offline"
    dq_tick(p, now + 6400, {"busy": True}, True, True, True, 0)
    assert rs2_busy_view(db.connect(p), now + 6400 + RS2_BUSY_FRESH_S - 5) is True and rs2_busy_view(db.connect(p), now + 6400 + RS2_BUSY_FRESH_S + 60) is False   # Merker veraltet = nicht belegt
    sv = dq_summary(p, now + 6400 + RS2_BUSY_FRESH_S + 60, guard=True)
    assert [x for x in sv["channels"] if x["ch"] == "10C"][0]["status"] == "offline"
    assert db.connect(p).execute("SELECT COUNT(*) FROM channel_status WHERE channel='10C'").fetchone()[0] == 1
    return "sdr_manager selftest sdrRest2 ok (Uhr: unsynchron < 6 h = pausiert, >= 6 h plausibel = Offline-Rechnung laeuft + Hinweis Uhr ungeprueft, Aufraeumen nur bei synchroner Uhr; 10C: 7-Tage-Regel bleibt, Hobby-Stick belegt = nicht geprueft statt offline, nur 10C, Merker veraltet = wie bisher)"
ASM_EOF
EXPECT_AGD="b6b4f661fe7ebe287e377e089b417fefc95395a060bc4b98e0b35f06f4509799"
cat > "$W/guard_rs2.py" << 'AGD_EOF'
"""AST-Guard sdrRest2. Aufruf: guard_rs2.py EDITS  ART ALT NEU BLOCK ...  (ART = sdr | sm | dsh; ALT = Stand nach sdrRest) -> 0 ok, 1 Verstoss.
Rueckbau (Block weg, Stellen zurueck) muss Byte fuer Byte ALT ergeben. Neuer Code: kein Netz, kein shell, keine Sendewege, kein Hilfsprogramm, keine USB-/Neustart-Aktion, kein Faden, keine Route, keine Einstellung geschrieben,
keine Gain-/Stick-Logik, kein Prozessaufruf (nur sysfs-Dateien lesen: open nur in _rs2_read mit einem Argument), einzige neue SQL-Schreibzeilen ausserhalb des Selbsttests: INSERT OR REPLACE INTO meta (dabsql_clock in rs2_clock, dabsql_p10busy in rs2_p10busy); SQL nur auf meta, reception_log, channel_status, masts, sqlite_master; Dateischreiben nur im Selbsttest (Temp-Ordner)."""
import ast
import re
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode", "reboot", "_wd_helper", "_wd_do", "_air_usb",
       "unlink", "remove", "rmtree", "chmod", "chown", "setpriority", "thread", "restart", "usb", "gain", "notify")
TOP_OK = {"sdr": ("RS2_", "_RS2", "_rs2_orig_"), "sm": ("RS2_",), "dsh": ("_RS2D",)}
REDEF_OK = {"sdr": ("_sh_tick",), "sm": (), "dsh": ()}
TABLES = ("reception_log", "channel_status", "masts", "meta", "sqlite_master")
FIXED_CMDS = (("timedatectl", "show", "-p", "NTPSynchronized", "--value"), ("chronyc", "-c", "tracking"))
err = []
a = sys.argv[2:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    if new.count(B.rstrip("\n")) != 1:
        err.append("%s: Block sdrRest2 fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sdrRest2" % (kind, len(E)))
    for o, n in E:                                              # neue Zeilen in den Stellen: nichts Gefaehrliches
        ol = set(o.splitlines())
        low = "\n".join(x for x in n.splitlines() if x not in ol).lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread", "_wd_helper(", "_wd_do(", "uhubctl", "unbind",
                  "fetch(", "xmlhttprequest", "takeover_set(", "reboot", "kill(", "open(", "innerhtml", "eval(", "delete ", "drop ", "insert ", "update ", ".click()", "sudo", "air_gain", "sdr_config"):
            if k in low:
                err.append("%s Stelle: %s" % (kind, k))
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        err.append("%s Block: Syntax %s" % (kind, e)); continue
    for n in ast.walk(ast.parse(new)):                          # die Stellen duerfen keine neuen Aufrufe ausser den erwarteten anlegen
        pass
    fn_of = {}
    for f in ast.walk(t):                                      # aeusserste Funktion gewinnt
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                fn_of.setdefault(id(x), f.name)
    olds = set(x.name for x in ast.parse(old).body if isinstance(x, ast.FunctionDef))
    for n in t.body:
        if isinstance(n, ast.Assign):
            tg = ast.unparse(n.targets[0])
            if tg.startswith(TOP_OK[kind]):
                continue
            if kind == "sdr" and tg == "Planner.resolve" and ast.unparse(n.value) == "_rs2_resolve":
                continue
            err.append("%s Block: Zuweisung auf Ebene 0: %s" % (kind, tg))
        elif isinstance(n, ast.Try) and kind == "dsh":
            continue
        elif isinstance(n, ast.FunctionDef):
            if n.name in olds and n.name not in REDEF_OK[kind]:
                err.append("%s Block: ueberschreibt vorhandene Funktion %s" % (kind, n.name))
        elif not isinstance(n, ast.Expr):
            err.append("%s Block: Anweisung auf Ebene 0: %s" % (kind, type(n).__name__))
    consts = None
    for n in ast.walk(t):
        fn = fn_of.get(id(n), "?")
        st = fn.startswith(("selftest", "_selftest"))
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if not (mod in ("tempfile", "sqlite3", "io", "contextlib", "sdr_manager", "builtins") and st):
                    err.append("%s Block: Import %s" % (kind, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s Block: shell" % kind)
        if isinstance(n, ast.Delete) and not st:
            err.append("%s Block: del in %s" % (kind, fn))
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if st and nm in ("open", "makedirs", "close", "write", "mkdtemp"):
                continue
            if nm == "open" and fn == "_rs2_read" and kind == "sdr" and len(n.args) == 1 and not n.keywords:
                continue
            if nm == "t2_takeover" and fn == "_rs2_busy" and kind == "sdr":
                continue
            if nm in ("list_sticks", "pick_stick", "stick_open", "rtl_test"):
                err.append("%s Block: Aufruf %s (oeffnet/listet Sticks) in %s" % (kind, nm, fn))
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer", "open", "rename", "makedirs", "write",
                                                           "after_request", "executemany", "executescript") or base in ("subprocess", "requests", "socket", "multiprocessing", "shutil", "os") and not (st and base == "os"):
                if not (kind == "dsh" and nm == "_air2d_devs"):
                    err.append("%s Block: Aufruf %s in %s" % (kind, nm, fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and any(k in n.value for k in ("uhubctl", "/unbind", "bind_ports", "power/control", "/usr/local/sbin", "sudo", "add_url_rule", "rtl_", "welle-cli", "soapy")):
            err.append("%s Block: verbotener Text %s" % (kind, n.value[:40]))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and not st and fn != "?" and any(k in n.value for k in ("sdr_config", "air_gain", "sdr_status", "broadcast_state", "alarm_state")):
            err.append("%s Block: Einstellungs-/Fremddatei-Name %s in %s" % (kind, n.value[:30], fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and re.search(r"\.(json|db|sqlite|txt|log)$", n.value) and not st:
            err.append("%s Block: unerwartete Datei %s" % (kind, n.value[:40]))
    for n in ast.walk(t):                                       # SQL
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and re.match(r"(?is)\s*(SELECT|INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|ATTACH|PRAGMA)\b", n.value):
            fnn = str(fn_of.get(id(n), ""))
            if re.search(r"(?i)\b(DROP|ALTER|ATTACH|PRAGMA)\b", n.value):
                err.append("%s Block: SQL DROP/ALTER/ATTACH/PRAGMA: %s" % (kind, n.value[:50]))
            isw = re.match(r"(?is)\s*(INSERT|UPDATE|DELETE|CREATE|REPLACE)", n.value)
            if isw and not fnn.startswith("selftest") and not ((fnn == "rs2_clock" and n.value.startswith("INSERT OR REPLACE INTO meta(k, v) VALUES('dabsql_clock', ?)")) or (fnn == "rs2_p10busy" and n.value.startswith("INSERT OR REPLACE INTO meta(k, v) VALUES('dabsql_p10busy', ?)"))):
                err.append("%s Block: SQL schreibt ausserhalb des Selbsttests: %s" % (kind, n.value[:50]))
            for tb in re.findall(r"(?i)\bFROM\s+(\w+)|\bINTO\s+(\w+)|\bUPDATE\s+(\w+)\s+SET\b", n.value):
                tb = next(x for x in tb if x)
                if tb not in TABLES:
                    err.append("%s Block: SQL fremde Tabelle %s: %s" % (kind, tb, n.value[:50]))
    if kind == "sdr":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_wd_helper", "_wd_do", "wd_helper_state", "_wd_decide", "_wd_save", "_wd_emit", "_air_usb", "dabgain_step", "_air_gain_state", "wd_tick", "_wd_block", "_wd_eval", "wd_check",
                   "_air_cmd_dab", "_air2_cmd_dab", "_air2_start", "_dg_sub_done", "_sh_tick", "_sh_do", "sh_decide", "_sh_step", "_sh_loop", "_at_finish", "_at_dabgain_step", "_at_wd_check", "pick_stick", "_rs_ntp_read", "_rs_ntp_state", "stick_info", "list_sticks", "get_mode", "t2_takeover"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sdr: Original %s veraendert" % fn)
        for nm in ("AIR_LADDER", "AIR2_SOAPY_GAIN", "WD_HELPER", "DABGAIN_LADDER", "DABGAIN_MIN_S", "SH_MAX_H", "SH_STALE_S", "DQ_TICK_S", "DQ_GAP_S", "SH_TICK_S", "RS_NTP_S", "RS_NTP_CMDS"):
            m = [x for x in ast.parse(old).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            m2 = [x for x in ast.parse(new).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            if [ast.dump(x) for x in m] != [ast.dump(x) for x in m2]:
                err.append("sdr: Konstante %s veraendert" % nm)
    if kind == "sm":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("dq_chstat", "dq_kind", "dq_pos_src", "dq_import", "_dq_ins", "dq_migrate", "_dq_start", "dq_code", "at_stats", "at_recommend", "rs_clock_calc", "rs_clock", "rs_clock_view", "rs_stored", "dq_pos_label", "rs_pos_extra"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sm: Original %s veraendert" % fn)
        for nm in ("DQ_KEEP_S", "DQ_UNK_MIN", "DQ_STREAK", "DQ_OFF_S", "DQ_OFF_DEF_S", "DQ_CH", "DQ_SQL", "RS_BUILD_T", "RS_BEHIND_S", "RS_FRESH_S"):
            m = [x for x in ast.parse(old).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            m2 = [x for x in ast.parse(new).body if isinstance(x, ast.Assign) and ast.unparse(x.targets[0]) == nm]
            if [ast.dump(x) for x in m] != [ast.dump(x) for x in m2]:
                err.append("sm: Konstante %s veraendert" % nm)
    if kind == "dsh":
        for k in ("add_url_rule", "after_request", "fetch(", "jsonify", "flask", "request"):
            if k in B:
                err.append("dsh Block: %s" % k)
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_air2d_label", "_air2d_devs", "_air2d_relabel", "_dq_sum", "_dq_api", "_t4_release_state", "_t2d_check", "_at_api", "_at_after", "_dq_dev"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                if fn not in ("_dq_sum",):
                    err.append("dsh: Original %s veraendert" % fn)
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard sdrRest2: nur %s Stellen (Text-/Aufruf-/Parameterstellen) + Bloecke; neuer Code ohne Netz/shell/Prozessaufruf/Sendeweg/Route/neuen Faden/USB-Oeffnen/Neustart-Aktion/Einstellungsschreiben (open nur lesend in _rs2_read, sysfs), einzige SQL-Schreibzeilen INSERT OR REPLACE INTO meta (dabsql_clock, dabsql_p10busy), Original-Gain-/Stick-/Watchdog-/sdrHalt-/Aufloesungs-Funktionen und DQ-Grenzen unveraendert, Rueckbau = Byte fuer Byte Basis" %
      "/".join("%d" % len(g["%s_EDITS" % a[i].upper()]) for i in range(0, len(a), 4)))
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
EXPECT_ADB="2b85ed9da6fe91486c3624f1a6447f0ba599787b7d43abf251cc03cee7c10c5c"
cat > "$W/r2_dash_block.py" << 'ADB_EOF'
# ===== sdrRest2: Anzeige - dabSql-Karte: Kanal 10C 'nicht geprueft' (gelb) statt 'offline', solange der Hobby-Stick belegt ist; Uhr-Hinweis 'Uhr ungeprueft' als eigene Zeile (aus dem API-Feld clock.state); nur Anzeige =====
def _selftest_sdrrest2_dash():
    v = {"ok": True, "t": 1790000000, "txt": "Kanäle: 11D aktiv · 10C nicht geprüft (Hobby-Stick belegt)",
         "channels": [{"ch": "11D", "status": "active", "note": "zuletzt Sync vor 10 s", "last_sync": 1789999990},
                      {"ch": "10C", "status": "unchecked", "note": "nicht geprüft: Hobby-Stick ist belegt (manueller Modus oder Übernahme) · zuletzt Sync vor 8 Tagen", "last_sync": 1789300000}],
         "known_list": [], "rule": {"unknown_days": 60}, "prov": {"amtlich": 100}, "unknown_list": [], "pos_prov": {}, "pos_wiki": [],
         "clock": {"ok": False, "state": "ungeprueft", "offline_calc": True, "cleanup": False, "txt": "Uhr ungeprüft: Pi-Uhr seit 7 h nicht mit NTP synchron (Zeit plausibel) - Offline-Rechnung läuft weiter (Alter kann abweichen), Aufräumen (60 Tage) pausiert"}}
    h = _dq_card(v)
    assert h.startswith('<div class="card" id="dqCard">') and h.endswith("</div>") and h.count('id="dqCard"') == 1, h
    assert "10C nicht geprüft" in h and "10C offline" not in h and "noch keine Prüfung" not in h and 'fu-pill gelb' in h, h
    assert "⏱ Uhr ungeprüft: Pi-Uhr seit 7 h nicht mit NTP synchron" in h and h.count("⏱") == 1, h
    v2 = dict(v, txt="Kanäle: 10C offline", channels=[{"ch": "10C", "status": "offline", "note": "offline: zuletzt Sync vor 8 Tagen", "last_sync": 1789300000}], clock={"ok": True, "state": "ok", "txt": ""})
    h2 = _dq_card(v2)
    assert "10C offline" in h2 and "nicht geprüft" not in h2 and "⏱" not in h2, h2
    return "sdrRest2 Anzeige ok (dabSql-Karte: 10C nicht geprueft statt offline bei belegtem Hobby-Stick, Hinweiszeile Uhr ungeprueft bei unsynchroner, plausibler Uhr; offline und Uhr ok wie bisher; nur Anzeige)"


try:
    _RS2D = {"selftest": _selftest_sdrrest2_dash()}
    print("sdrRest2 aktiv: %s" % _RS2D["selftest"], flush=True)
except Exception as _rs2_e:
    print("sdrRest2 Anzeige FEHLER (Karte wie bisher):", _rs2_e, flush=True)
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
EXPECT_RCK="29ef240d57904b338ecd1d2a6e4aab49bc433b392a2ed7d7c45a68aa68ac700e"
cat > "$W/rscheck.py" << 'RCK_EOF'
"""Pruefhilfe sdrRest/sdrRest2 (nur lesen). rscheck.py api JSON | card HTML JSON | dbcmp LZ_DB JSON | clock LZ_DB T0 | funk HTML"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import time


def load(p):
    return json.load(open(p, encoding="utf-8"))


def main(a):
    m = a[0] if a else ""
    if m == "api":
        try:
            j = load(a[1])
        except Exception as e:
            print("kein JSON: %s" % e); return 1
        pp, pw = j.get("pos_prov"), j.get("pos_wiki_n")
        ck = j.get("clock")
        if not (isinstance(j, dict) and j.get("ok") is True and isinstance(pp, dict) and isinstance(pw, int) and isinstance(ck, dict) and isinstance(ck.get("ok"), bool) and ck.get("state") in ("ok", "ungeprueft", "pausiert") and isinstance(ck.get("offline_calc"), bool) and isinstance(ck.get("cleanup"), bool) and isinstance(j.get("pos_wiki"), list)):
            print("/api/dabsql/status ohne pos_prov/pos_wiki/clock: %s" % json.dumps(j, ensure_ascii=False)[:240]); return 1
        if sum(int(v) for v in pp.values()) != int((j.get("known") or {}).get("total", -1)):
            print("pos_prov-Summe %s != bekannte Masten %s" % (sum(int(v) for v in pp.values()), (j.get("known") or {}).get("total"))); return 1
        if pw != sum(int(v) for k, v in pp.items() if "Wikipedia" in k):
            print("pos_wiki_n %s passt nicht zu pos_prov %s" % (pw, pp)); return 1
        bad = [x for x in j.get("known_list") or [] if "pos" not in x]
        if bad:
            print("known_list ohne pos-Label: %s" % bad[:1]); return 1
        pv = j.get("prov") or {}
        print("/api/dabsql/status: Koordinaten-Herkunft %s (davon %d Wikipedia), amtlich/nicht amtlich unveraendert %s, Uhr %s%s" % (
            ", ".join("%s %d" % (k, v) for k, v in pp.items()), pw, pv, "synchron/plausibel" if ck["ok"] else "NICHT synchron [%s, Offline-Rechnung %s, Aufräumen %s]" % (ck["state"], "an" if ck["offline_calc"] else "pausiert", "an" if ck["cleanup"] else "pausiert"), "" if ck["ok"] else " (%s)" % ck.get("txt"))); return 0
    if m == "card":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        j = load(a[2])
        if s.count('id="dqCard"') != 1:
            print("/dabhist: dabSql-Karte %dx" % s.count('id="dqCard"')); return 1
        if "Herkunft der Koordinaten (nur Anzeige, ändert nichts an amtlich/nicht amtlich)" not in s:
            print("/dabhist: Zeile Herkunft der Koordinaten fehlt"); return 1
        n = int(j.get("pos_wiki_n") or 0)
        if n and ("Position aus Wikipedia (%d Einträge" % n) not in s:
            print("/dabhist: Liste Position aus Wikipedia (%d Einträge) fehlt" % n); return 1
        cj = j.get("clock") or {}
        ck = cj.get("ok", True)
        if ck is False and "⏱" not in s:
            print("/dabhist: Uhr unsynchron, aber ohne Hinweiszeile"); return 1
        if ck is True and "⏱" in s:
            print("/dabhist: Hinweiszeile obwohl Uhr ok"); return 1
        if (cj.get("state") == "ungeprueft") != ("Uhr ungeprüft" in s):
            print("/dabhist: 'Uhr ungeprüft' passt nicht zum Uhr-Zustand %s" % cj.get("state")); return 1
        for ch in j.get("channels") or []:
            if ch.get("status") == "unchecked" and "nicht geprüft" not in s:
                print("/dabhist: Kanal %s nicht geprueft, aber ohne Pille" % ch.get("ch")); return 1
        print("/dabhist: Karte mit Herkunft der Koordinaten, %d Wikipedia-Positionen in der Liste, Positions-Labels an %d Mast-Zeilen, Hinweiszeile %s, Kanal nicht geprueft: %d" % (
            n, s.count("Position: "), "da (Uhr %s)" % cj.get("state") if ck is False else "aus (Uhr ok)", sum(1 for c in (j.get("channels") or []) if c.get("status") == "unchecked"))); return 0
    if m == "dbcmp":
        con = sqlite3.connect("file:%s?mode=ro" % a[1], uri=True)
        db = con.execute("SELECT COUNT(*) FROM masts WHERE status='known' AND lower(COALESCE(pos_src,'')) LIKE '%wikipedia%'").fetchone()[0]
        j = load(a[2])
        if db != j.get("pos_wiki_n"):
            print("Wikipedia-Positionen: Datenbank %d, API %s" % (db, j.get("pos_wiki_n"))); return 1
        am = con.execute("SELECT src_kind, COUNT(*) FROM masts GROUP BY src_kind").fetchall()
        if {str(k or "?"): v for k, v in am} != {str(k): v for k, v in (j.get("prov") or {}).items()}:
            print("amtlich/nicht amtlich: Datenbank %s, API %s" % (am, j.get("prov"))); return 1
        print("Datenbank = API: %d Wikipedia-Positionen, amtlich/nicht amtlich %s unveraendert" % (db, {str(k or "?"): v for k, v in am})); return 0
    if m == "clock":
        con = sqlite3.connect("file:%s?mode=ro" % a[1], uri=True)
        r = con.execute("SELECT v FROM meta WHERE k='dabsql_clock'").fetchone()
        if not r:
            print("meta dabsql_clock noch nicht geschrieben"); return 1
        d = json.loads(r[0])
        if int(d.get("t") or 0) < int(a[2]):
            print("meta dabsql_clock alt (t=%s)" % d.get("t")); return 1
        try:
            o = subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"], capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            o = "?"
        print("Uhr-Merker dabsql_clock: state=%s ok=%s%s, ntp=%s (timedatectl NTPSynchronized=%s)%s" % (d.get("state", "?"), d.get("ok"), (" (%s)" % d.get("why")) if d.get("why") else "", d.get("ntp"), o,
                                                                                           "" if d.get("ok") else " - HINWEIS: Aufräumen pausiert, bis die Uhr synchron ist; Offline-Rechnung %s" % ("läuft (Uhr ungeprüft)" if d.get("calc") else "pausiert"))); return 0
    if m == "funk":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        for k in ("function nm(k,d)", "function nmx(k,d)", "nm('s2','Stick 2')", "nmx('s2','Stick 2')"):
            if k not in s:
                print("/funk: JS ohne %s" % k); return 1
        print("/funk: Alarm-/Voralarm-Knopf-Texte mit Registernamen (nm/nmx, Rueckfall unveraendert ohne Register)"); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
RCK_EOF
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
PF="$W/patch-fu.py"; RE="$W/r2_edits.py"; RSD="$W/r2_sdr_block.py"; RSM="$W/r2_sm_block.py"; RGD="$W/guard_rs2.py"; AC2="$W/air2check.py"; RDB="$W/r2_dash_block.py"; DCK="$W/dabcheck.py"; ACK="$W/atcheck.py"; RCK="$W/rscheck.py"; HCK="$W/shcheck.py"
AC="$W/aircheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"; CK="$W/sqlccheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_AE $RE" "$EXPECT_ASD $RSD" "$EXPECT_ASM $RSM" "$EXPECT_AGD $RGD" "$EXPECT_AC2 $AC2" "$EXPECT_ADB $RDB" "$EXPECT_DCK $DCK" "$EXPECT_ACK $ACK" "$EXPECT_RCK $RCK" "$EXPECT_HCK $HCK" "$EXPECT_AC $AC" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2" "$EXPECT_CK $CK"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ "$1" == "$4" ]] && echo "bekannt ($5)" || echo "UNBEKANNT"; }; }
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sdrRest" "$KNOWN_SDR16N" "sdrRest2 schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sdrRest" "$KNOWN_SM16N" "sdrRest2 schon drin"))"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sdrRest" "$KNOWN_D16N" "sdrRest2 schon drin"))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
[[ "$SDR16" == "$KNOWN_SDR16" || "$SDR16" == "$KNOWN_SDR16N" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16 = sdrRest oder $KNOWN_SDR16N = sdrRest2);"
[[ "$SM16" == "$KNOWN_SM16" || "$SM16" == "$KNOWN_SM16N" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16 = sdrRest oder $KNOWN_SM16N = sdrRest2);"
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 = sdrRest oder $KNOWN_D16N = sdrRest2);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      sdrRest2 passt nur auf den sdrRest-Stand vom 24.10. (prepper_sdr 22e52c6c9c46620f, sdr_manager 2463e66656883d46, dashboard fd9528e4ebe2330e) - nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = sdrRest (bzw. sdrRest2 schon drin), alle sha16 bekannt"
grep -q '# ===== dabSql:' "$M" && grep -q '# ===== dabSql:' "$SMF" && grep -q '# ===== dabSql:' "$F" || { echo "STOP: dabSql fehlt - nichts geaendert"; exit 1; }
grep -q '# ===== airTest:' "$M" && grep -q '# ===== sdrHalt:' "$M" || { echo "STOP: airTest/sdrHalt fehlt - nichts geaendert"; exit 1; }
grep -q '# ===== sdrRest:' "$M" && grep -q '# ===== sdrRest:' "$SMF" && grep -q '# ===== sdrRest:' "$F" || { echo "STOP: sdrRest fehlt - nichts geaendert"; exit 1; }
[[ -x "$HDST" ]] || { echo "STOP: Hilfsprogramm $HDST fehlt - nichts geaendert"; exit 1; }
HL16=$(s16 "$HDST")
[[ "$HL16" == "$KNOWN_HL16" ]] || { echo "STOP: Hilfsprogramm sha16 $HL16 statt $KNOWN_HL16 (sdrAir) - nichts geaendert"; exit 1; }
echo "OK Hilfsprogramm $HDST sha16 $HL16 (sdrAir, bleibt)"
for k in "sdr prepper_sdr $M $RSD $KNOWN_SDR16N" "sm sdr_manager $SMF $RSM $KNOWN_SM16N" "dsh dashboard $F $RDB $KNOWN_D16N"; do set -- $k
  if [[ "$(s16 "$3")" == "$5" ]]; then cp "$3" "$W/work/$2.py"; echo "$2.py: sdrRest2 schon drin" > "$W/q_$1.log"; continue; fi
  python3 "$PF" sdrRest2 "$1" "$3" "$W/work/$2.py" "$4" "$RE" > "$W/q_$1.log" || { cat "$W/q_$1.log"; echo "STOP: $2.py sdrRest2-Stufe passt nicht - nichts geaendert"; exit 1; }
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
for k in "sdr prepper_sdr $RSD" "sm sdr_manager $RSM" "dsh dashboard $RDB"; do set -- $k
  python3 "$PF" sdrRest2 "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$RE" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
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
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrrest-selftest timeout 300 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok" "sdr_manager selftest sdrWd ok" "sdr_manager selftest sdrWd2 ok" "sdr_manager selftest sdrAir ok" "sdr_manager selftest sdrAir2 ok" "sdr_manager selftest dabSql ok" "sdr_manager selftest airTest ok" "sdr_manager selftest sdrRest ok" "sdr_manager selftest sdrRest2 ok" "sdr_manager selftest sdrRest ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/sdrrest-selftest timeout 600 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok" "selftest sdrWd2 ok" "selftest sdrAir ok" "selftest sdrAir2 ok" "selftest dabSql ok" "selftest airTest ok" "selftest sdrHalt ok" "selftest sdrRest ok" "selftest sdrRest2 ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum, Fake-Hilfsprogramm, Fake-SoapySDR-Modul; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet)"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest sdrRest2 ok' "$W/sdrt.log" | tail -1 | cut -c1-400)"
  echo "   $(grep -F 'sdr_manager selftest sdrRest2 ok' "$W/smt.log" | tail -1 | cut -c1-400)"
done
if [[ "$SDR16" == "$KNOWN_SDR16N" && "$SM16" == "$KNOWN_SM16N" && "$D16" == "$KNOWN_D16N" ]]; then
  echo "OK sdrRest2 schon drin - Guard-Rueckbau gegen Basis entfaellt (Inhalt = gepruefter Zielstand, sha16)"
else
  python3 "$RGD" "$RE" sdr "$M" "$W/work/prepper_sdr.py" "$RSD" sm "$SMF" "$W/work/sdr_manager.py" "$RSM" dsh "$F" "$W/work/dashboard.py" "$RDB" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard sdrRest2 - nichts geaendert"; exit 1; }
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
  echo "OK sdrRest2 schon installiert (prepper_sdr.py, sdr_manager.py, dashboard.py) - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    for u in prepper-sdr prepper-dashboard; do sudo journalctl -u "$u" --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrAir|sdrWd|Traceback" | tail -4 | cut -c1-200 || true; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sdrrest2-$TS" ]] && cp -a "$x.bak-sdrrest2-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sdrrest2-$TS" ]] || continue; cmp -s "$x" "$x.bak-sdrrest2-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Sicherungen von vorher: $LZ.bak-sdrrest2-$TS, $WDJ.bak-sdrrest2-$TS (nicht zurueckgespielt; Watchdog-Zustand bleibt)"
    echo "alter Stand (dabSql) wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$WDJ"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-sdrrest2-$TS"
    { ls -1t "$x.bak-sdrrest2-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sdrrest2-$TS" \
      || { rm -f "$LZ.bak-sdrrest2-$TS"; for x in "${ALL[@]}" "$WDJ"; do rm -f "$x.bak-sdrrest2-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sdrrest2-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "prepper_sdr $M" "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sdrrest2-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (max 240 s) und 11D-Sync vom Airspy (max 300 s; sendet nichts) ..."
  sudo systemctl restart prepper-sdr.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$AC" status "$DASH_DIR" "$T0" > "$W/ast.log" 2>&1 && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { cat "$W/ast.log"; rb "prepper-sdr: Airspy 11D laeuft nicht ($(head -c 200 "$W/ast.log"))"; exit 1; }
  pok=0; for i in $(seq 1 120); do python3 "$AC" port 7979 > "$W/port.log" 2>&1 && { pok=1; break; }; sleep 1; done
  [[ "$pok" == 1 ]] && echo "OK welle-cli (Airspy) $(cat "$W/port.log")" || { rb "Port 7979 (welle-cli Airspy) lauscht nicht"; exit 1; }
  sok=0; for i in $(seq 1 100); do python3 "$AC2" proof "$DASH_DIR" "$T0" > "$W/proof.log" 2>&1 && { sok=1; break; }; sleep 3; done
  [[ "$sok" == 1 ]] && echo "OK $(cut -c1-460 "$W/proof.log")" || { cat "$W/proof.log"; rb "11D-Sync vom Airspy nach 300 s nicht nachgewiesen"; exit 1; }
  AET=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
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
python3 "$HCK" state "$DASH_DIR" > "$W/hs.log" 2>&1 && echo "OK $(cat "$W/hs.log")" || { cat "$W/hs.log"; rbx "sdr_halt.json kaputt"; }
# --- sdrRest (bleibt) + sdrRest2: Herkunft der Koordinaten, Uhr (Zustand), Kanal nicht geprueft ---
rok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/dabsql/status" -o "$W/rsapi.json" || true; python3 "$RCK" api "$W/rsapi.json" > "$W/rsa.log" 2>&1 && { rok=1; break; }; sleep 6; done
[[ "$rok" == 1 ]] && echo "OK $(cut -c1-520 "$W/rsa.log")" || { cat "$W/rsa.log"; rbx "/api/dabsql/status ohne Koordinaten-Herkunft/Uhr-Feld"; }
"${CURL[@]}" "$B/dabhist" -o "$W/dabhist2.html" || true
python3 "$RCK" card "$W/dabhist2.html" "$W/rsapi.json" > "$W/rsc.log" 2>&1 && echo "OK $(cat "$W/rsc.log")" || { cat "$W/rsc.log"; rbx "/dabhist ohne Koordinaten-Herkunft"; }
[[ -f "$LZ" ]] && { python3 "$RCK" dbcmp "$LZ" "$W/rsapi.json" > "$W/rsd.log" 2>&1 && echo "OK $(cat "$W/rsd.log")" || { cat "$W/rsd.log"; rbx "Herkunft der Koordinaten: Datenbank und API passen nicht zusammen"; }; }
python3 "$RCK" funk "$W/funk.html" > "$W/rsf.log" 2>&1 && echo "OK $(cat "$W/rsf.log")" || { cat "$W/rsf.log"; rbx "/funk ohne Registernamen in den Knopf-Texten"; }
if [[ "$RESTARTED" == 1 && -f "$LZ" ]]; then
  cok=0; for i in $(seq 1 60); do python3 "$RCK" clock "$LZ" "$T0" > "$W/rsk.log" 2>&1 && { cok=1; break; }; sleep 5; done
  [[ "$cok" == 1 ]] && echo "OK $(cat "$W/rsk.log")" || { cat "$W/rsk.log"; rbx "Uhr-Merker dabsql_clock wird nicht geschrieben"; }
fi
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
R1='Traceback|airTest (Tick|Befehl|Messung|Fehler|Standard-Gain pruefen|speichern|Anzeige)|sdrHalt( Start:|: (Waechter|Sperrgrund merken|Hilfsprogramm-Pruefung:|Neustart-Zaehler|Planer-Faden))|sdrRest (Karte|Anzeige)|sdrRest2 (Karte|Anzeige)|dabSql( Start| on_dab)|dabSql: (Schreibfehler|Tabellen|Lesen|kartevec-Import|Schreibfaden nicht)|^sdrAir2? [A-Za-z/ ]*:|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:'
E1=$(echo "$JP" | grep -c -E "$R1" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JP" | grep -E "$R1" | head -5 | cut -c1-240; rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"; }
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JA=$(echo "$JD" | grep -F "dabSql aktiv: dabSql Anzeige ok" | tail -1 || true)
  [[ -n "$JA" ]] && echo "OK Journal Dashboard: $(echo "$JA" | cut -c1-260)" || rbx "Dashboard meldet dabSql-Anzeige nicht (Selbsttest)"
  JA2=$(echo "$JD" | grep -F "airTest aktiv: airTest Anzeige ok" | tail -1 || true)
  [[ -n "$JA2" ]] && echo "OK Journal Dashboard: $(echo "$JA2" | cut -c1-260)" || rbx "Dashboard meldet airTest-Anzeige nicht (Selbsttest)"
  JA4=$(echo "$JD" | grep -F "sdrRest2 aktiv: sdrRest2 Anzeige ok" | tail -1 || true)
  [[ -n "$JA4" ]] && echo "OK Journal Dashboard: $(echo "$JA4" | cut -c1-260)" || rbx "Dashboard meldet sdrRest2-Anzeige nicht (Selbsttest)"
  JA3=$(echo "$JD" | grep -F "sdrRest aktiv: sdrRest Anzeige ok" | tail -1 || true)
  [[ -n "$JA3" ]] && echo "OK Journal Dashboard: $(echo "$JA3" | cut -c1-260)" || rbx "Dashboard meldet sdrRest-Anzeige nicht (Selbsttest)"
  JB=$(echo "$JP" | grep -F "airTest: bereit" | tail -1 || true)
  [[ -n "$JB" ]] && echo "OK Journal prepper-sdr: $(echo "$JB" | cut -c1-200)" || rbx "prepper-sdr meldet airTest nicht (bereit)"
  JH=$(echo "$JP" | grep -F "sdrHalt: bereit" | tail -1 || true)
  [[ -n "$JH" && "$JH" == *"systemd-Watchdog aktiv"* ]] && echo "OK Journal prepper-sdr: $(echo "$JH" | cut -c1-300)" || rbx "prepper-sdr meldet sdrHalt nicht bereit mit systemd-Watchdog ($JH)"
  JT=$(echo "$JP" | grep -F "sdrHalt: Watchdog-Takt an systemd gesendet" | tail -1 || true)
  [[ -n "$JT" ]] && echo "OK Journal prepper-sdr: $(echo "$JT" | cut -c1-200)" || rbx "sdrHalt: Takt an systemd nicht nachgewiesen (Notify-Socket?)"
  systemctl show -p Restart -p RestartUSec -p StartLimitIntervalUSec -p WatchdogUSec -p NotifyAccess -p NRestarts prepper-sdr > "$W/ushow.log" 2>&1 || true
  python3 "$HCK" unit "$W/ushow.log" > "$W/hc.log" 2>&1 && echo "OK $(cat "$W/hc.log")" || { cat "$W/hc.log"; rbx "Unit prepper-sdr: Drop-in nicht wirksam"; }
  AET2=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ "$AET2" == "$AET" ]] && echo "OK prepper-sdr seit dem Neustart nicht vom Watchdog beendet (Start $AET2)" || rbx "prepper-sdr wurde nach dem Neustart erneut gestartet (Start $AET -> $AET2)"
  [[ "$(grep -c '^Restart=always' "$W/ushow.log" || true)" == 1 && "$(grep -E '^NRestarts=' "$W/ushow.log" | cut -d= -f2)" == 0 ]] || rbx "NRestarts nicht 0 (Dienst nach Neustart automatisch neu gestartet)"
  JW=$(echo "$JP" | grep -F "dabSql: Schreibfaden laeuft" | tail -1 || true)
  [[ -n "$JW" ]] && echo "OK Journal prepper-sdr: $(echo "$JW" | cut -c1-200)" || rbx "prepper-sdr meldet den dabSql-Schreibfaden nicht"
  ju=0; for i in $(seq 1 40); do JP2=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null || true); JU=$(echo "$JP2" | grep -F "sdrRest2: USB-Pruefung im Lauf bereit" | tail -1 || true); [[ -n "$JU" ]] && { ju=1; break; }; sleep 3; done
  [[ "$ju" == 1 ]] && echo "OK Journal prepper-sdr: $(echo "$JU" | cut -c1-260)" || rbx "prepper-sdr meldet die lesende USB-Pruefung im Lauf nicht (sdrRest2)"
  JV=$(echo "$JP2" | grep -E "^sdrRest2: SN " | tail -2 || true)
  [[ -z "$JV" ]] && echo "OK keine USB-Abweichung seit Neustart (Seriennummern/devnum wie beim Start)" || echo "HINWEIS USB-Abweichung im Lauf gemeldet (nur lesend; frische Aufloesung beim naechsten Start): $(echo "$JV" | cut -c1-240 | tr '\n' '|')"
fi
R2='Traceback|airTest (Anzeige(:| FEHLER)|Seite:)|sdrRest (Anzeige(:| FEHLER)|Karte:)|sdrRest2 (Anzeige(:| FEHLER)|Karte:)|dabSql Anzeige(:| FEHLER)|dabSql Karte:|dabSql: (Lesen|Tabellen|kartevec-Import)|sdrWd FEHLER|funkUI FEHLER|sdr_manager sdrWd|sdr_manager sdrAir2? [A-Za-z_ -]+:|sdrAir2? Anzeige(:| FEHLER)'
E2=$(echo "$JD" | grep -c -E "$R2" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JD" | grep -E "$R2" | head -5 | cut -c1-240; rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"; }
python3 "$AC2" proof "$DASH_DIR" 0 > "$W/proof.log" 2>&1 && echo "Geraete nachher: $(cut -c1-460 "$W/proof.log")" || echo "HINWEIS Geraete nachher: $(cut -c1-300 "$W/proof.log")"
echo "Watchdog nachher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-400)"
for x in "$DBF:$DB16" "$MR:$MR16" "$HDST:$HL16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
echo "OK guards sdrRest2(sdr)=$(grep -c '# ===== sdrRest2:' "$M" || true) sdrRest2(sm)=$(grep -c '# ===== sdrRest2:' "$SMF" || true) sdrRest2(dash)=$(grep -c '# ===== sdrRest2:' "$F" || true) sdrRest(sdr)=$(grep -c '# ===== sdrRest:' "$M" || true) sdrHalt(sdr)=$(grep -c '# ===== sdrHalt:' "$M" || true) airTest(sdr)=$(grep -c '# ===== airTest:' "$M" || true) airTest(dash)=$(grep -c '# ===== airTest:' "$F" || true) sdrRest(sm)=$(grep -c '# ===== sdrRest:' "$SMF" || true) sdrRest(dash)=$(grep -c '# ===== sdrRest:' "$F" || true) dabSql(sdr)=$(grep -c '# ===== dabSql:' "$M" || true) dabSql(sm)=$(grep -c '# ===== dabSql:' "$SMF" || true) dabSql(dash)=$(grep -c '# ===== dabSql:' "$F" || true) sdrAir2(sdr)=$(grep -c '# ===== sdrAir2:' "$M" || true) sdrAir2(sm)=$(grep -c '# ===== sdrAir2:' "$SMF" || true) sdrAir(sdr)=$(grep -c '# ===== sdrAir:' "$M" || true) sdrAir(sm)=$(grep -c '# ===== sdrAir:' "$SMF" || true) sdrAir(dash)=$(grep -c '# ===== sdrAir:' "$F" || true) sdrAir2(dash)=$(grep -c '# ===== sdrAir2:' "$F" || true) sdrWd2(sdr)=$(grep -c '# ===== sdrWd2:' "$M" || true) sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sysBoot(dash)=$(grep -c '# ===== sysBoot' "$F" || true)"
[[ -f "$M.bak-sdrrest2-$TS" ]] && echo "Backups: *.bak-sdrrest2-$TS (prepper_sdr.py, sdr_manager.py, dashboard.py, sdr_wd.json, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF" "$HDST"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: prepper_sdr.py.bak-sdrrest2-$TS, sdr_manager.py.bak-sdrrest2-$TS und dashboard.py.bak-sdrrest2-$TS zurueckkopieren, dann sudo systemctl restart prepper-sdr prepper-dashboard"
echo "SoapySDR testen (nur auf Wunsch): in sdr_config.json air_fe auf soapy, dann sudo systemctl restart prepper-sdr; Rueckfall auf -F airspy geschieht automatisch"
echo "COMMIT $COMMIT_ARG sdrrest2=1 fertig"
