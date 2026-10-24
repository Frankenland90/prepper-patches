#!/bin/bash
set -euo pipefail
# dabSql: baut auf sdrAir2/sdrAir2b (live 24.10.: prepper_sdr b139eaf50abf4d36, sdr_manager 679fde6003d22ff7, dashboard b0712eafe3d2235d). Aendert prepper_sdr.py, sdr_manager.py und dashboard.py; Hilfsprogramm, sudoers, sdr_config.json, database.py bleiben.
#  - Neue Tabellen in lagezentrum.db: masts (tii, name, lat, lon, height, ensemble, last_seen, status + Kanal/Quelle), reception_log (timestamp, channel, tii, snr, errors, sync), channel_status (channel, last_sync, status, note).
#  - Einmaliger Import: erst T4_MASTS, dann MASTS_DB (nie ueberschreiben, Namen vor TII-Codes), dann kartevec tii_seen nur als unbekannt. Herkunft: belegt aus fmlist.org = amtlich, sonst nicht amtlich (Lage getrennt: pos_src). Unbekannte TII automatisch (status unknown), Anzeige erst bei mehr als 50 Sichtungen in 60 Tagen.
#  - Bekannte Masten werden erst nach 2 Empfaengen (Pruefungen mit Sync) in Folge angezeigt. reception_log 60 Tage, aeltere werden stuendlich geloescht.
#  - Jede DAB-/TII-Pruefung schreibt reception_log und aktualisiert channel_status (eigener Schreibfaden im Dienst prepper-sdr, nie blockierend). 10C (Rueckfallkanal) offline erst nach mehr als 7 Tagen ohne Sync (aus p10c, Hobby-Pruefung alle 6 h bleibt; Anzeige: zuletzt Sync vor X), 11D/5C nach 30 min.
#  - Zusammenfassung oben auf /dabhist + /api/dabsql/status (nur lesen): Kanaele aktiv/offline mit Geraetenamen aus dem Register, bekannte/unbekannte Masten, letzte Aktualisierung.
#  - Kleine Reste: Knopf-/Kacheltexte SDR-Status (Vor-Alarm) nennen im Register-Betrieb die Geraetenamen statt SDR 1/SDR 2.
#  - Schalter: sdr_config.json "dabsql": "off" schaltet das Schreiben ab. Keine Gain-/Watchdog-/Geraete-Aenderung, nichts gesendet.
# Basis streng (sha16): sdrAir2-Stand oder dabSql schon drin. Sonst Abbruch ohne Aenderung. Neustart prepper-sdr + prepper-dashboard. Sendet nichts.
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
W=/tmp/dabsql-apply
KEEP_LAST=3
KNOWN_D16="b0712eafe3d2235d"     # dashboard.py nach sdrAir2
KNOWN_D16N="385954809ef625da"     # dashboard.py nach dabSql (Ziel)
KNOWN_SM16="679fde6003d22ff7"    # sdr_manager.py nach sdrAir2
KNOWN_SM16N="3d1c2a8c0a258986"    # sdr_manager.py nach dabSql (Ziel)
KNOWN_SDR16="b139eaf50abf4d36"   # prepper_sdr.py nach sdrAir2
KNOWN_SDR16N="d7036f7f1b00e23e"   # prepper_sdr.py nach dabSql (Ziel)
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
echo "=== dabSql apply (Tabellen masts/reception_log/channel_status, Import amtliche Liste vor MASTS_DB, unbekannte TII, 10C-Offline aus p10c, Zusammenfassung /dabhist + /api/dabsql/status), Dashboard-Port $PORT ==="
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
EXPECT_DE="9640e944a13f7183abe1589808cb8696ec39335a6317f033b1f8e43e37d4ae54"
cat > "$W/dab_edits.py" << 'DE_EOF'
# dabSql: Stellen (alt, neu) auf dem Stand nach sdrAir2 (live 24.10.). Jede alte Stelle muss genau einmal vorkommen.
SDR_EDITS = [
('''        selftest_sdrair2()
''', '''        selftest_sdrair2()
        selftest_dabsql()
'''),
# Dienststart: Schreibfaden dabSql neben sqlB
('''        _SQLB_W.start(BASE)   # sqlB
''', '''        _SQLB_W.start(BASE)   # sqlB
        globals().get("_DQ_START", lambda b: None)(BASE)   # dabSql: Schreibfaden (wirft nie)
'''),
# sdrLog-Selbsttest: on_dab ist jetzt noch einmal umhuellt (dabSql)
('''    assert StateBC.on_dab is _sdrlog_on_dab and Planner.want in''', '''    assert StateBC.on_dab in (_sdrlog_on_dab, globals().get("_dq_on_dab")) and Planner.want in'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'
SM_EDITS = [
('''    print(selftest_sdrair2())
''', '''    print(selftest_sdrair2())
    print(selftest_dabsql())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
# Vor-Alarm-Knopf/Kachel SDR-Status (Teil 4): im Register-Betrieb Geraetenamen statt SDR 1/SDR 2 (sonst wie bisher)
(r"""if(!window.confirm('SDR 2 wirklich freigeben (zurück in den Hobby-Betrieb)?""",
 r"""if(!window.confirm(((D.sdr.air&&(D.sdr.s2||{}).name)||'SDR 2')+' wirklich freigeben (zurück in den Hobby-Betrieb)?"""),
(r"""L[0].textContent='SDR 1'+(s1.sn?' SN '+s1.sn:'')""", r"""L[0].textContent=((D.sdr.air&&s1.name)||'SDR 1')+(s1.sn?' SN '+s1.sn:'')"""),
(r"""L[2].textContent='SDR 2'+(s2.sn?' SN '+s2.sn:'')""", r"""L[2].textContent=((D.sdr.air&&s2.name)||'SDR 2')+(s2.sn?' SN '+s2.sn:'')"""),
(r"""t._b.textContent='✅ SDR 2 freigeben'""", r"""t._b.textContent='✅ '+((D.sdr.air&&s2.name)||'SDR 2')+' freigeben'"""),
]
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DE_EOF
EXPECT_DSD="7a3816d1f87cffcf8d882e7f910bc6783c90f4b58e5e792d4f5d6dea9e99c131"
cat > "$W/dab_sdr_block.py" << 'DSD_EOF'
# ===== dabSql: jede DAB-/TII-Pruefung (StateBC.on_dab) -> reception_log + masts + channel_status in lagezentrum.db; eigener Schreibfaden mit begrenzter Warteschlange (nie blockierend, nie werfend, Schalter sdr_config.json dabsql off), 10C-Sync aus p10c (Hobby-Pruefung alle 6 h); aendert weder Watchdog noch Gain noch Geraete-Auswahl =====
import queue as _dq_queue

DQ_Q_MAX = 32
DQ_TICK_S = 300
DQ_GAP_S = 20                    # gleiche Pruefung (Kanal) nicht doppelt zaehlen
DQ_P10_KEY = "p10c"


class DabsqlWriter:
    def __init__(self):
        self.base = None
        self.th = None
        self.q = _dq_queue.Queue(maxsize=DQ_Q_MAX)
        self.mod = None
        self.ready = False
        self.last = {}
        self.p10 = {}
        self.tick_t = 0.0
        self.st = {"ok": 0, "err": 0, "drop": 0, "last_err": None, "t": None, "started": None, "imported": None}

    def path(self):
        return os.path.join(self.base, "lagezentrum.db")

    def on(self):
        try:
            return self.base is not None and _SQLB_W.on() and self.mod.dq_on(self.base)
        except Exception:
            return False

    def start(self, base):
        try:
            self.base = os.path.abspath(base)
            if self.base not in sys.path:
                sys.path.insert(0, self.base)
            import sdr_manager as _m
            self.mod = _m
            if not hasattr(_m, "dq_ingest"):
                raise RuntimeError("sdr_manager.py ohne dabSql")
            self.th = threading.Thread(target=self._loop, name="dabsql-writer", daemon=True)
            self.th.start()
            self.st["started"] = int(time.time())
            print("dabSql: Schreibfaden laeuft (%s, Schalter %s)" % (self.path(), "an" if self.on() else "AUS"), flush=True)
            return True
        except Exception as e:
            self.base = None
            print("dabSql: Schreibfaden nicht gestartet (alles andere laeuft): %s" % e, flush=True)
            return False

    def offer(self, rec):
        """Aus on_dab: nie blockieren, nie werfen."""
        try:
            if self.base is None or self.th is None or not self.on():
                return False
            ch = str(rec.get("ch"))
            t = float(rec.get("t") or 0)
            if t - self.last.get(ch, 0) < DQ_GAP_S:
                return False
            self.last[ch] = t
            self.q.put_nowait(rec)
            return True
        except _dq_queue.Full:
            self.st["drop"] += 1
        except Exception:
            pass
        return False

    def _prepare(self):
        if self.ready:
            return True
        p = self.path()
        if not self.mod.dq_migrate(p):
            return False
        r = self.mod.dq_import(p, MASTS_DB)
        self.st["imported"] = r
        if not r.get("done"):
            print("dabSql: einmaliger Import: %d Masten (%d amtlich nach fmlist.org, %d nicht amtlich, %d unbekannt aus kartevec tii_seen)" % (r.get("n", 0), r.get("n_amtlich", 0), r.get("n_nicht_amtlich", 0), r.get("n_kartevec", 0)), flush=True)
        self.ready = True
        return True

    def handle(self, rec, now=None):
        """Eine Pruefung (rec) oder nur Takt (rec None). Wirft nie."""
        try:
            now = int(now or time.time())
            if not self._prepare():
                self.st["err"] += 1
                return False
            if isinstance(rec, dict):
                if isinstance(rec.get("p10c"), dict):
                    self.p10 = rec["p10c"]
                self.mod.dq_ingest(self.path(), rec, now)
                self.st["ok"] += 1
                self.st["t"] = now
            if rec is None or now - self.tick_t >= DQ_TICK_S:
                self.tick_t = now
                self.mod.dq_tick(self.path(), now, self.p10)
            return True
        except Exception as e:
            self.st["err"] += 1
            self.st["last_err"] = str(e)[:160]
            if self.st["err"] in (1, 10, 100) or self.st["err"] % 1000 == 0:
                print("dabSql: Schreibfehler (%d bisher, Anzeige/JSON laufen weiter): %s" % (self.st["err"], e), flush=True)
            return False

    def _loop(self):
        while True:
            try:
                try:
                    rec = self.q.get(timeout=DQ_TICK_S)
                except _dq_queue.Empty:
                    rec = None
                if rec is not None or self.on():
                    self.handle(rec)
            except Exception as e:
                self.st["err"] += 1
                self.st["last_err"] = str(e)[:160]
                time.sleep(5)


_DQW = DabsqlWriter()
_dq_orig_on_dab = StateBC.on_dab


def _dq_on_dab(self, ch, mux, now=None):
    r = _dq_orig_on_dab(self, ch, mux, now)
    try:
        if _DQW.th is not None and isinstance(r, dict):
            t = float(now or time.time())
            x = t2_fig_parse(mux, t, str(ch))
            dm = r.get("demod") if isinstance(r.get("demod"), dict) else {}
            sync = x is not None and r.get("rx") is not False
            p10 = self.d.get(DQ_P10_KEY) if isinstance(self.d.get(DQ_P10_KEY), dict) else {}
            _DQW.offer({"ch": str(ch), "t": int(t), "sync": bool(sync), "snr": dm.get("snr"), "fic_rate": dm.get("fic_rate"), "sn": dm.get("sn") or getattr(_T2_TLS, "sn", None),
                        "ens": (x or {}).get("ens") or r.get("ensemble") if sync else None, "tii_on": bool((x or {}).get("tii_on")),
                        "tii": [{"main": y.get("main"), "sub": y.get("sub"), "err": y.get("err"), "km": y.get("km")} for y in ((x or {}).get("tii") or [])[:8]] if sync else [],
                        "p10c": {k: p10.get(k) for k in ("t_sync", "t_check", "ok", "ens")} if p10 else None})
    except Exception as e:
        print("dabSql on_dab:", e, flush=True)
    return r


StateBC.on_dab = _dq_on_dab


def _DQ_START(base):
    try:
        _DQW.start(base)
    except Exception as e:
        print("dabSql Start:", e, flush=True)


def selftest_dabsql():
    import tempfile
    tmp = tempfile.mkdtemp(prefix="dabsql-sdr-")
    sys.path.insert(0, os.getcwd())
    import sdr_manager as _m
    w = DabsqlWriter()
    assert w.offer({"ch": "11D", "t": 1}) is False and _DQW.th is None and _DQW.q.qsize() == 0       # Selbsttest startet den echten Faden nie
    w.base, w.mod, w.th = tmp, _m, object()
    open(os.path.join(tmp, "sdr_config.json"), "w").write("{}")
    now = int(time.time())
    g0 = globals()["_DQW"]
    globals()["_DQW"] = w
    try:
        b = StateBC(tmp)
        mux = {"ensemble": {"label": {"label": "Bayern", "shortlabel": "BR"}, "id": "0x10A1"}, "services": [{"label": {"label": "BR24"}}],
               "demodulator": {"snr": 13.5, "fic": {"numcrcerrors": 3}},
               "tii": [{"comb": 18, "pattern": 8, "delay_km": 12.3, "error": 20.0}, {"comb": 77, "pattern": 7, "delay_km": 40.0, "error": 90.0}]}
        r = b.on_dab("11D", mux, now=now)
        assert isinstance(r, dict) and w.q.qsize() == 1
        b.on_dab("11D", mux, now=now + 5)                                            # < 20 s: nicht doppelt
        assert w.q.qsize() == 1
        b.on_dab("11D", mux, now=now + 60)
        b.on_dab("5C", {"ensemble": {"label": "", "id": "0x0000"}, "services": []}, now=now + 61)   # kein Sync
        assert w.q.qsize() == 3
        while w.q.qsize():
            assert w.handle(w.q.get_nowait(), now + 70)
        s = _m.dq_summary(os.path.join(tmp, "lagezentrum.db"), now + 71)
        assert s["ok"] and s["known"]["shown"] == 1 and s["unknown"]["collecting"] == 1 and s["channels"][0]["status"] == "active", s   # 08/18 nach 2 Empfaengen, 07/77 unbekannt
        assert [c["ch"] for c in s["channels"] if c["status"] == "unknown"] == ["5C", "10C"] and s["log_rows"] == 5, s["channels"]
        assert w.st["ok"] == 3 and w.st["err"] == 0 and w.st["imported"]["n"] > 0, w.st
        # Schalter aus / kaputter Pfad: nichts, nie werfen
        open(os.path.join(tmp, "sdr_config.json"), "w").write('{"dabsql": "off"}')
        assert w.offer({"ch": "11D", "t": now + 500}) is False
        open(os.path.join(tmp, "sdr_config.json"), "w").write("{}")
        w.base = "/nonexistent/dabsql"
        w.ready = False
        assert w.handle({"ch": "11D", "t": now + 600, "sync": True, "tii": []}, now + 600) is False and w.st["err"] >= 1
        w.base = tmp
        # 10C aus p10c (Hobby-Pruefung)
        w.ready = False
        assert w.handle({"ch": "10C", "t": now + 700, "sync": True, "tii": [], "ens": "Nuernberg", "p10c": {"t_sync": now + 700, "t_check": now + 700, "ok": True, "ens": "Nuernberg"}}, now + 700)
        assert _m.dq_summary(os.path.join(tmp, "lagezentrum.db"), now + 701)["channels"][2]["status"] == "active"
    finally:
        globals()["_DQW"] = g0
    print("selftest dabSql ok (jede on_dab-Pruefung -> Warteschlange, nicht doppelt innerhalb 20 s, Schreiben nur im Faden, Import einmalig, Schalter dabsql off, kaputter Pfad wirft nie, 10C aus p10c; Faden im Selbsttest nie gestartet)")
DSD_EOF
EXPECT_DSM="46b2cfba5087513488cb674a7913cbf24a8d0bcc2ffa6ac4ac8fee5436d2ce05"
cat > "$W/dab_sm_block.py" << 'DSM_EOF'
# ===== dabSql: SQLite-Tabellen masts / reception_log / channel_status in lagezentrum.db - einmaliger Import der Mastenlisten (amtliche Liste T4_MASTS vor MASTS_DB), unbekannte TII automatisch (status unknown, Anzeige erst bei > 50 Sichtungen in 60 Tagen), bekannte Masten erst nach 2 Empfaengen in Folge, reception_log 60 Tage, 10C offline nach > 24 h ohne Sync (p10c); Schreiben nur im Dienst prepper-sdr (eigener Faden), hier nur Datenschicht + Lesen =====
DQ_KEEP_S = 60 * 86400          # reception_log und alte automatische Kennungen: 60 Tage
DQ_UNK_MIN = 50                 # unbekannte TII: Anzeige erst bei MEHR als 50 Sichtungen in den letzten 60 Tagen
DQ_STREAK = 2                   # bekannte Masten: Anzeige erst nach 2 Empfaengen (Pruefungen mit Sync) in Folge
DQ_OFF_S = {"10C": 7 * 86400}   # 10C (Rueckfallkanal) offline erst nach > 7 Tagen ohne Sync; 6-h-Hobby-Pruefung auf Stick 2 bleibt
DQ_OFF_DEF_S = 30 * 60          # 11D/5C offline nach > 30 min ohne Sync
DQ_OFFS = ("off", "aus", "0", "false", "nein", "no")
DQ_CH = ("11D", "5C", "10C")
DQ_TII_MAX = 8                  # je Pruefung hoechstens 8 Kennungen (wie t2_fig_parse)
DQ_SQL = (
    "CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)",
    "CREATE TABLE IF NOT EXISTS masts (channel TEXT NOT NULL, tii TEXT NOT NULL, name TEXT, lat REAL, lon REAL, height REAL, ensemble TEXT, last_seen INTEGER, "
    "status TEXT NOT NULL DEFAULT 'unknown', src_kind TEXT NOT NULL DEFAULT 'auto', src TEXT, origin TEXT, pos_src TEXT, site_m REAL, erp_kw REAL, km REAL, first_seen INTEGER, "
    "n_seen INTEGER NOT NULL DEFAULT 0, streak INTEGER NOT NULL DEFAULT 0, max_streak INTEGER NOT NULL DEFAULT 0, confirmed INTEGER NOT NULL DEFAULT 0, "
    "PRIMARY KEY (channel, tii))",
    "CREATE TABLE IF NOT EXISTS reception_log (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, channel TEXT NOT NULL, tii TEXT, snr REAL, errors REAL, "
    "sync INTEGER NOT NULL, fic_rate REAL, sn TEXT)",
    "CREATE INDEX IF NOT EXISTS ix_rl_ts ON reception_log(timestamp)",
    "CREATE INDEX IF NOT EXISTS ix_rl_ch_tii ON reception_log(channel, tii, timestamp)",
    "CREATE TABLE IF NOT EXISTS channel_status (channel TEXT PRIMARY KEY, last_sync INTEGER, status TEXT, note TEXT, last_check INTEGER, ensemble TEXT, updated INTEGER)",
)
_DQ = {"err": None, "err_t": 0}


def dq_on(base=None):
    """Schalter: sdr_config.json dabsql off|aus|0|false|nein|no schaltet das Schreiben ab (Standard an)."""
    try:
        d = _load(os.path.join(base or ".", "sdr_config.json"), {}) or {}
        return not (isinstance(d, dict) and "dabsql" in d and str(d.get("dabsql")).strip().lower() in DQ_OFFS)
    except Exception:
        return True


def dq_code(main, sub):
    return "%02d/%02d" % (int(main), int(sub))


def _dq_err(what, e):
    _DQ["err"] = ("%s: %s" % (what, e))[:160]
    if time.time() - _DQ["err_t"] > 300:
        _DQ["err_t"] = time.time()
        print("dabSql: %s (Anzeige/JSON laufen weiter): %s" % (what, e), flush=True)


def dq_migrate(path):
    """Tabellen anlegen (idempotent). -> True/False"""
    try:
        con = db.connect(path)
        try:
            with con:
                for s in DQ_SQL:
                    con.execute(s)
        finally:
            con.close()
        return True
    except Exception as e:
        _dq_err("Tabellen", e)
        return False


def dq_kind(src):
    """Herkunft der Zuordnung TII -> Sender: belegt aus fmlist.org = amtlich (Frank 24.10.); sonst nicht amtlich (z. B. nur Wikipedia/OSM). Die Lage ist davon getrennt (pos_src)."""
    return "amtlich" if re.search(r"fmlist", str(src or ""), re.I) else "nicht_amtlich"


def dq_pos_src(src):
    """Herkunft der Koordinaten aus dem Quelltext (Lage ...): osm / wikipedia / osm+wikipedia / wie 11D (Kopie) / vorgabe / fmlist / unbekannt. Nichts erfinden."""
    t = str(src or "")
    low = t.lower()
    k = []
    if "osm" in low or "openstreetmap" in low or "nominatim" in low:
        k.append("osm")
    if "wikipedia" in low:
        k.append("wikipedia")
    if "helmuthzeitler" in low:
        k.append("helmuthzeitler.com")
    if "lage wie 11d" in low:
        k.append("wie 11D")
    if "vorgabe frank" in low and ("lage" in low or "koordinaten" in low):
        k.append("vorgabe")
    return "+".join(k) if k else "unbekannt"


def _dq_ins(con, ch, code, name, lat, lon, height, ens, kind, src, site_m, erp, km, origin=None, pos_src=None):
    return con.execute("INSERT OR IGNORE INTO masts(channel, tii, name, lat, lon, height, ensemble, status, src_kind, src, origin, pos_src, site_m, erp_kw, km, n_seen) "
                       "VALUES(?,?,?,?,?,?,?,'known',?,?,?,?,?,?,?,0)", (ch, code, name, lat, lon, height, ens, kind, src, origin, pos_src, site_m, erp, km)).rowcount


def dq_import(path, masts_db, now=None):
    """Einmaliger Import (Marker meta dabsql_import): erst T4_MASTS, dann MASTS_DB, dann (nur unbekannt) kartevec tii_seen - nur INSERT OR IGNORE, nie ueberschreiben (T4_MASTS vor MASTS_DB).
    src_kind amtlich = TII/Name aus fmlist.org belegt, nicht_amtlich = sonst; pos_src = Herkunft der Koordinaten. -> {done, n, n_amtlich, n_nicht_amtlich, n_kartevec}"""
    now = int(now or time.time())
    con = db.connect(path)
    try:
        with con:
            r = con.execute("SELECT v FROM meta WHERE k='dabsql_import'").fetchone()
            if r:
                return {"done": True, "n": 0, "was": str(r[0])[:120]}
            md = masts_db if isinstance(masts_db, dict) else {}
            ens = lambda ch: (md.get(ch) or {}).get("name") if isinstance(md.get(ch), dict) else None
            kt = dq_kind(T4_MAST_SRC)
            na = nn = nk = 0
            c4 = {"amtlich": 0, "nicht_amtlich": 0}
            for m in T4_MASTS:
                pos = "helmuthzeitler.com" if m.get("id") == "hersbruck" else "wikipedia (Teil-1-Liste)"
                for ch, code in (m.get("tii") or {}).items():
                    k = _dq_ins(con, ch, kv_txt(code), m.get("name"), m.get("lat"), m.get("lon"), m.get("ant_m"), ens(ch), kt,
                                "T4_MASTS: TII/Hoehe fmlist.org 17.10.2026; Koordinaten Wikipedia/helmuthzeitler.com", m.get("site_m"), None, None, "T4_MASTS", pos)
                    c4[kt] += k
            for ch, e in md.items():
                for x in (e.get("tii") if isinstance(e, dict) else None) or []:
                    try:
                        code = dq_code(x["main"], x["sub"])
                    except Exception:
                        continue
                    lat, lon = x.get("lat"), x.get("lon")
                    sx = str(x.get("src") or "MASTS_DB")
                    pos = dq_pos_src(sx)
                    g = KV_GEO_11D.get(kv_code(x["main"], x["sub"])) if ch == "11D" else None
                    if g and (lat is None or lon is None):
                        lat, lon = g[0], g[1]
                    if g and abs(float(lat) - g[0]) < 1e-4 and abs(float(lon) - g[1]) < 1e-4:
                        pos = dq_pos_src(g[2])                          # kartevec-Recherche: Quelle der Koordinate (OSM/Wikipedia)
                    k = _dq_ins(con, str(ch), code, str(x.get("mast") or "")[:80] or None, lat, lon, x.get("h_mast") if x.get("h_mast") is not None else x.get("ant_m"),
                                ens(ch), dq_kind(sx), sx[:200], x.get("site_m"), x.get("erp_kw"), x.get("km"), "MASTS_DB", pos)
                    nn += k if dq_kind(sx) == "nicht_amtlich" else 0
                    na += k if dq_kind(sx) == "amtlich" else 0
            na += c4["amtlich"]
            nn += c4["nicht_amtlich"]
            try:                                                   # kartevec tii_seen: nur als unbekannt, Sichtungen daraus zaehlen NICHT fuer die Anzeige (nur reception_log)
                if con.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='tii_seen'").fetchone():
                    for ch, code, f_t, l_t, n in con.execute("SELECT ch, code, first_t, last_t, n FROM tii_seen").fetchall():
                        c = str(code or "")
                        if str(ch) in DQ_CH and re.fullmatch(r"\d{4}", c) and not con.execute("SELECT 1 FROM masts WHERE channel=? AND tii=?", (str(ch), c[:2] + "/" + c[2:])).fetchone():
                            con.execute("INSERT OR IGNORE INTO masts(channel, tii, last_seen, status, src_kind, src, origin, first_seen, n_seen) VALUES(?,?,?,'unknown','kartevec',?,?,?,?)",
                                        (str(ch), c[:2] + "/" + c[2:], l_t, "kartevec tii_seen (nicht angezeigt vor > %d Sichtungen in %d Tagen)" % (DQ_UNK_MIN, DQ_KEEP_S // 86400), "kartevec", f_t, int(n or 0)))
                            nk += 1
            except Exception as e:
                _dq_err("kartevec-Import", e)
            con.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('dabsql_import', ?)", (json.dumps({"t": now, "amtlich": na, "nicht_amtlich": nn, "kartevec": nk}),))
            return {"done": False, "n": na + nn + nk, "n_amtlich": na, "n_nicht_amtlich": nn, "n_kartevec": nk}
    finally:
        con.close()


def _dq_age(s):
    s = int(max(0, s))
    return "%d s" % s if s < 90 else ("%d min" % (s // 60) if s < 5400 else ("%d h" % (s // 3600) if s < 172800 else "%d Tagen" % (s // 86400)))


def dq_chstat(ch, last_sync, now, p10c_sync=None, start=None):
    """-> (status, note, last_sync). 10C (Rueckfallkanal): letzter Sync = juengerer aus Datenbank und p10c (Hobby-Pruefung alle 6 h); offline erst nach > 7 Tagen ohne Sync;
    11D/5C nach > 30 min. Ohne jeden Sync: unbekannt, nach Ablauf der Grenze seit Beginn der Aufzeichnung (start) offline."""
    ls = last_sync
    if ch == "10C" and isinstance(p10c_sync, (int, float)) and p10c_sync > 0 and (ls is None or p10c_sync > ls):
        ls = int(p10c_sync)
    lim = DQ_OFF_S.get(ch, DQ_OFF_DEF_S)
    if ls is None:
        if isinstance(start, (int, float)) and start > 0 and now - start > lim:
            return "offline", "offline: seit Beginn der Aufzeichnung (vor %s) kein Sync (Grenze %s)" % (_dq_age(now - start), _dq_age(lim)), None
        return "unknown", "noch kein Sync seit Beginn der Aufzeichnung", None
    age = now - ls
    if age <= lim:
        return "active", "zuletzt Sync vor %s%s" % (_dq_age(age), " · Rückfallkanal, Hobby-Prüfung alle 6 h" if ch == "10C" else ""), int(ls)
    return "offline", "offline: zuletzt Sync vor %s (Grenze %s%s)" % (_dq_age(age), _dq_age(lim), " · Rückfallkanal, Hobby-Prüfung alle 6 h" if ch == "10C" else ""), int(ls)


def _dq_start(con):
    """Beginn der Aufzeichnung = Zeit des einmaligen Imports (meta dabsql_import) oder None."""
    try:
        r = con.execute("SELECT v FROM meta WHERE k='dabsql_import'").fetchone()
        t = json.loads(r[0]).get("t") if r else None
        return int(t) if isinstance(t, (int, float)) else None
    except Exception:
        return None


def dq_ingest(path, rec, now=None):
    """Eine TII-Pruefung: reception_log (je TII eine Zeile, ohne TII eine Zeile fuer die Pruefung), masts (unbekannte automatisch, Serie, zuletzt gesehen), channel_status. -> {rows, new_unknown}"""
    now = int(now or time.time())
    ch = str(rec.get("ch") or "")
    t = int(rec.get("t") or now)
    if ch not in DQ_CH and not ch:
        return {"rows": 0, "new_unknown": 0}
    sync = bool(rec.get("sync"))
    snr, fr, sn = _num(rec.get("snr")), _num(rec.get("fic_rate")), (str(rec.get("sn")) if rec.get("sn") else None)
    tii = {}
    for y in (rec.get("tii") or [])[:DQ_TII_MAX] if sync else []:
        try:
            c = dq_code(y.get("main"), y.get("sub"))
        except Exception:
            continue
        if c not in tii:
            tii[c] = {"err": _num(y.get("err")), "km": _num(y.get("km"))}
    p10 = rec.get("p10c") if isinstance(rec.get("p10c"), dict) else {}
    con = db.connect(path)
    rows = nu = 0
    try:
        with con:
            if sync and tii:
                for c, x in tii.items():
                    con.execute("INSERT INTO reception_log(timestamp, channel, tii, snr, errors, sync, fic_rate, sn) VALUES(?,?,?,?,?,1,?,?)", (t, ch, c, snr, x["err"], fr, sn))
                    rows += 1
            else:
                con.execute("INSERT INTO reception_log(timestamp, channel, tii, snr, errors, sync, fic_rate, sn) VALUES(?,?,NULL,?,NULL,?,?,?)", (t, ch, snr, 1 if sync else 0, fr, sn))
                rows += 1
            if sync and (tii or rec.get("tii_on")):
                for c, x in tii.items():
                    r = con.execute("SELECT status, streak, max_streak FROM masts WHERE channel=? AND tii=?", (ch, c)).fetchone()
                    if r is None:
                        con.execute("INSERT INTO masts(channel, tii, ensemble, last_seen, status, src_kind, origin, first_seen, n_seen, streak, max_streak, km) "
                                    "VALUES(?,?,?,?,'unknown','auto','auto',?,1,1,1,?)", (ch, c, rec.get("ens"), t, t, x["km"]))
                        nu += 1
                    else:
                        st = int(r[1] or 0) + 1
                        con.execute("UPDATE masts SET last_seen=?, n_seen=n_seen+1, streak=?, max_streak=?, confirmed=CASE WHEN ?>=? THEN 1 ELSE confirmed END, "
                                    "ensemble=COALESCE(ensemble, ?) WHERE channel=? AND tii=?", (t, st, max(int(r[2] or 0), st), st, DQ_STREAK, rec.get("ens"), ch, c))
                if tii:
                    con.execute("UPDATE masts SET streak=0 WHERE channel=? AND streak>0 AND tii NOT IN (%s)" % ",".join("?" * len(tii)), (ch,) + tuple(tii))
                else:
                    con.execute("UPDATE masts SET streak=0 WHERE channel=? AND streak>0", (ch,))
            old = con.execute("SELECT last_sync FROM channel_status WHERE channel=?", (ch,)).fetchone()
            ls = t if sync else (old[0] if old else None)
            stt, note, ls2 = dq_chstat(ch, ls, now, p10.get("t_sync"), _dq_start(con))
            if sync:
                note = "Sync%s%s" % (" %s" % rec["ens"] if rec.get("ens") else "", " · SNR %.1f" % snr if snr is not None else "")
            con.execute("INSERT INTO channel_status(channel, last_sync, status, note, last_check, ensemble, updated) VALUES(?,?,?,?,?,?,?) "
                        "ON CONFLICT(channel) DO UPDATE SET last_sync=excluded.last_sync, status=excluded.status, note=excluded.note, last_check=excluded.last_check, "
                        "ensemble=COALESCE(excluded.ensemble, channel_status.ensemble), updated=excluded.updated", (ch, ls2, stt, note, t, rec.get("ens") if sync else None, now))
    finally:
        con.close()
    return {"rows": rows, "new_unknown": nu}


def dq_tick(path, now=None, p10c=None, prune=True):
    """Status neu rechnen (offline entsteht durch Zeitablauf), 10C aus p10c nachfuehren, stuendlich Aufraeumen: reception_log > 60 Tage, alte automatische Kennungen ohne Sichtung. -> {pruned, masts_pruned}"""
    now = int(now or time.time())
    p10 = p10c if isinstance(p10c, dict) else {}
    out = {"pruned": 0, "masts_pruned": 0}
    con = db.connect(path)
    try:
        with con:
            have = {r[0]: r for r in con.execute("SELECT channel, last_sync, ensemble FROM channel_status")}
            if "10C" not in have and isinstance(p10.get("t_sync"), (int, float)) and p10["t_sync"] > 0:
                have["10C"] = ("10C", None, p10.get("ens"))
            for ch, r in have.items():
                stt, note, ls = dq_chstat(ch, r[1], now, p10.get("t_sync"), _dq_start(con))
                con.execute("INSERT INTO channel_status(channel, last_sync, status, note, last_check, ensemble, updated) VALUES(?,?,?,?,?,?,?) "
                            "ON CONFLICT(channel) DO UPDATE SET last_sync=excluded.last_sync, status=excluded.status, note=excluded.note, "
                            "last_check=COALESCE(excluded.last_check, channel_status.last_check), updated=excluded.updated",
                            (ch, ls, stt, note, int(p10.get("t_check")) if ch == "10C" and isinstance(p10.get("t_check"), (int, float)) else None, r[2], now))
            if prune:
                lt = con.execute("SELECT v FROM meta WHERE k='dabsql_prune'").fetchone()
                if not lt or now - int(float(lt[0] or 0)) >= 3600:
                    out["pruned"] = con.execute("DELETE FROM reception_log WHERE timestamp < ?", (now - DQ_KEEP_S,)).rowcount
                    out["masts_pruned"] = con.execute("DELETE FROM masts WHERE status='unknown' AND src_kind IN ('auto', 'kartevec') AND COALESCE(last_seen, 0) < ?", (now - DQ_KEEP_S,)).rowcount
                    con.execute("INSERT OR REPLACE INTO meta(k, v) VALUES('dabsql_prune', ?)", (str(now),))
    finally:
        con.close()
    return out


def dq_summary(path, now=None, lim=12):
    """Zusammenfassung fuer /dabhist und /api/dabsql/status: Kanaele aktiv/offline, bekannte/unbekannte Masten, letzte Aktualisierung. Nur lesen, nie werfen."""
    now = int(now or time.time())
    out = {"ok": False, "t": now, "channels": [], "known": {"total": 0, "shown": 0}, "unknown": {"total": 0, "shown": 0, "collecting": 0},
           "rule": {"unknown_min": DQ_UNK_MIN, "unknown_days": DQ_KEEP_S // 86400, "known_streak": DQ_STREAK, "off_10c_d": DQ_OFF_S["10C"] // 86400, "off_min": DQ_OFF_DEF_S // 60},
           "known_list": [], "unknown_list": [], "updated": None, "log_rows": None, "log_oldest": None, "txt": "dabSql: noch keine Daten"}
    try:
        if db is None or not os.path.isfile(path):
            return out
        con = db.connect(path)
        try:
            have = {r["name"] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if not {"masts", "reception_log", "channel_status"} <= have:
                return out
            cs = {r["channel"]: r for r in con.execute("SELECT * FROM channel_status")}
            for ch in DQ_CH:
                r = cs.get(ch)
                if r is None:
                    out["channels"].append({"ch": ch, "status": "unknown", "note": "noch keine Prüfung", "last_sync": None, "last_check": None, "ens": None})
                    continue
                stt, note, ls = dq_chstat(ch, r["last_sync"], now, None, _dq_start(con))
                out["channels"].append({"ch": ch, "status": stt, "note": note, "last_sync": ls,
                                        "last_check": r["last_check"], "ens": r["ensemble"]})
            since = now - DQ_KEEP_S
            sight = {(r[0], r[1]): r[2] for r in con.execute("SELECT channel, tii, COUNT(*) FROM reception_log WHERE sync=1 AND tii IS NOT NULL AND timestamp>=? GROUP BY channel, tii", (since,))}
            kn = ks = un = us = uc = 0
            for r in con.execute("SELECT * FROM masts ORDER BY last_seen DESC"):
                n60 = sight.get((r["channel"], r["tii"]), 0)
                if r["status"] == "known":
                    kn += 1
                    if r["confirmed"]:
                        ks += 1
                        if len(out["known_list"]) < lim:
                            out["known_list"].append({"ch": r["channel"], "tii": r["tii"], "name": r["name"] or r["tii"], "last_seen": r["last_seen"], "n60": n60, "src_kind": r["src_kind"], "pos_src": r["pos_src"]})
                else:
                    un += 1
                    if n60 > DQ_UNK_MIN:
                        us += 1
                        if len(out["unknown_list"]) < lim:
                            out["unknown_list"].append({"ch": r["channel"], "tii": r["tii"], "name": r["name"] or "unbekannt", "last_seen": r["last_seen"], "n60": n60, "src_kind": r["src_kind"]})
                    else:
                        uc += 1
            out["known"] = {"total": kn, "shown": ks}
            out["prov"] = {str(a or "?"): int(b) for a, b in con.execute("SELECT src_kind, COUNT(*) FROM masts GROUP BY src_kind")}
            out["unknown"] = {"total": un, "shown": us, "collecting": uc}
            out["unknown_list"].sort(key=lambda x: -x["n60"])
            r = con.execute("SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM reception_log").fetchone()
            out["log_rows"], out["log_oldest"] = int(r[0] or 0), r[1]
            ups = [x for x in [r[2]] + [c["last_check"] for c in out["channels"]] if isinstance(x, (int, float))]
            out["updated"] = int(max(ups)) if ups else None
        finally:
            con.close()
        a = [c for c in out["channels"] if c["status"] == "active"]
        o = [c for c in out["channels"] if c["status"] == "offline"]
        out["txt"] = "Kanäle: %s aktiv%s · bekannte Masten %d von %d empfangen · unbekannte Kennungen %d angezeigt (%d werden gesammelt)%s" % (
            ", ".join(c["ch"] for c in a) or "keiner", (", %s offline" % ", ".join(c["ch"] for c in o)) if o else "", out["known"]["shown"], out["known"]["total"],
            out["unknown"]["shown"], out["unknown"]["collecting"], (" · aktualisiert vor %s" % _dq_age(now - out["updated"])) if out["updated"] else "")
        out["ok"] = True
    except Exception as e:
        _dq_err("Lesen", e)
        out["error"] = str(e)[:120]
    return out


def selftest_dabsql():
    import tempfile
    d = tempfile.mkdtemp(prefix="dabsql-")
    p = os.path.join(d, "lagezentrum.db")
    now = 1790000000
    assert dq_migrate(p) and dq_migrate(p)                                           # idempotent
    md = {"11D": {"name": "BR Bayern", "tii": [{"main": 8, "sub": 18, "mast": "Falscher Name Bamberg", "lat": 1.0, "lon": 2.0, "src": "fmlist"},
                                              {"main": 5, "sub": 14, "mast": "Nürnberg (Schweinau)", "lat": 49.4, "lon": 11.0, "h_mast": 250, "src": "fmlist"},
                                              {"main": 9, "sub": 9, "mast": "Nur MASTS_DB", "src": "fmlist 10A5; Lage OSM Sender X", "km": 80},
                                              {"main": 9, "sub": 8, "mast": "Nur Wikipedia", "src": "Lage Wikipedia (de) Sender Y"}]},
          "5C": {"name": "DR Deutschland", "tii": [{"main": 12, "sub": 3, "mast": "Nürnberg 5C", "src": "x"}]}, "10C": {"name": "Lokal Nürnberg", "tii": []}}
    con = db.connect(p)
    try:
        with con:                                                                    # kartevec tii_seen wie auf dem Pi: 0818 (bekannt), 0766 (unbekannt, viele Sichtungen), 0999 (unbekannt), 7777 (ungueltiger Kanal ignoriert)
            for q in _KV_SQL:
                con.execute(q)
            for row in (("11D", "0818", 10, 20, 900), ("11D", "0766", 11, 21, 800), ("5C", "2299", 12, 22, 5), ("XX", "0101", 1, 2, 3), ("11D", "abcd", 1, 2, 3)):
                con.execute("INSERT INTO tii_seen(ch, code, first_t, last_t, n) VALUES(?,?,?,?,?)", row)
    finally:
        con.close()
    r = dq_import(p, md, now)
    n4 = len([1 for m in T4_MASTS for _c in m["tii"]])
    assert not r["done"] and r["n_amtlich"] == n4 + 1 and r["n_nicht_amtlich"] == 1 and r["n_kartevec"] == 2, r   # T4 amtlich (fmlist), 09/09 fmlist, 09/08 nur Wikipedia = nicht amtlich; 08/18, 05/14, 12/03 schon da
    r2 = dq_import(p, md, now + 5)
    assert r2["done"] and r2["n"] == 0                                               # einmalig
    con = db.connect(p)
    try:
        b = con.execute("SELECT name, lat, src_kind FROM masts WHERE channel='11D' AND tii='08/18'").fetchone()
        t4 = [m for m in T4_MASTS if m["tii"].get("11D") == "0818"][0]
        assert b["src_kind"] == "amtlich" and b["name"] == t4["name"] and b["lat"] == t4["lat"] and b["lat"] != 1.0, tuple(b)   # amtliche Liste vor MASTS_DB
        assert tuple(con.execute("SELECT src_kind, origin, pos_src FROM masts WHERE channel='11D' AND tii='09/09'").fetchone()) == ("amtlich", "MASTS_DB", "osm")
        assert tuple(con.execute("SELECT src_kind, origin, pos_src FROM masts WHERE channel='11D' AND tii='09/08'").fetchone()) == ("nicht_amtlich", "MASTS_DB", "wikipedia")   # nur Wikipedia = NICHT amtlich
        assert tuple(con.execute("SELECT src_kind, origin, status, n_seen FROM masts WHERE channel='11D' AND tii='07/66'").fetchone()) == ("kartevec", "kartevec", "unknown", 800)
        assert con.execute("SELECT COUNT(*) FROM masts WHERE tii IN ('01/01', 'ab/cd')").fetchone()[0] == 0
        assert con.execute("SELECT src_kind FROM masts WHERE channel='11D' AND tii='05/14'").fetchone()[0] == "amtlich"
        assert con.execute("SELECT status FROM masts WHERE channel='5C' AND tii='22/99'").fetchone()[0] == "unknown"
    finally:
        con.close()
    # Pruefung 1: bekannter Mast 08/18 + unbekannte 07/77; nicht angezeigt (1 Empfang)
    rec = lambda t, tii, sync=True, ch="11D": {"ch": ch, "t": t, "sync": sync, "snr": 14.0, "fic_rate": 0.01, "sn": "AAA", "ens": "Bayern", "tii_on": True,
                                                "tii": [{"main": a, "sub": b, "err": 40.0, "km": 5.0} for a, b in tii]}
    x = dq_ingest(p, rec(now, [(8, 18), (7, 77)]), now)
    assert x == {"rows": 2, "new_unknown": 1}, x
    s = dq_summary(p, now + 1)
    assert s["ok"] and s["known"]["shown"] == 0 and s["unknown"]["shown"] == 0 and s["unknown"]["collecting"] == 3 and s["channels"][0]["status"] == "active", s
    dq_ingest(p, rec(now + 60, [(7, 77)], ch="11D"), now + 60)                       # 08/18 fehlt -> Serie 0, bleibt unbestaetigt
    dq_ingest(p, rec(now + 120, [(8, 18), (7, 77)]), now + 120)
    s = dq_summary(p, now + 121)
    assert s["known"]["shown"] == 0, s["known"]                                      # nie 2 in Folge
    dq_ingest(p, rec(now + 180, [(8, 18)]), now + 180)                               # 2. in Folge
    s = dq_summary(p, now + 181)
    assert s["known"]["shown"] == 1 and s["known_list"][0]["name"] == "Bamberg (Geisberg)", s["known"]
    dq_ingest(p, rec(now + 200, [], sync=False), now + 200)                          # kein Sync: Zeile, Serie bleibt
    dq_ingest(p, rec(now + 240, [(8, 18)]), now + 240)
    assert dq_summary(p, now + 241)["known"]["shown"] == 1
    # unbekannt: erst ab > 50 Sichtungen
    for i in range(46):                                                              # 3 bisher + 46 = 49 Sichtungen
        dq_ingest(p, rec(now + 300 + i * 60, [(7, 77)]), now + 300 + i * 60)
    dq_ingest(p, rec(now + 4000, [(7, 77)]), now + 4000)                              # genau 50 = noch nicht angezeigt
    s = dq_summary(p, now + 4001)
    assert s["unknown"]["shown"] == 0 and s["unknown"]["collecting"] == 3, s["unknown"]
    dq_ingest(p, rec(now + 4060, [(7, 77)]), now + 4060)                              # 51 = mehr als 50
    s = dq_summary(p, now + 4061)
    assert s["unknown"]["shown"] == 1 and s["unknown_list"][0]["tii"] == "07/77" and s["unknown_list"][0]["n60"] == 51, s["unknown"]
    # channel_status / 10C aus p10c
    assert dq_summary(p, now + 4061)["channels"][2]["status"] == "unknown"
    dq_tick(p, now + 4062, {"t_sync": now + 3900, "t_check": now + 3900, "ens": "Nuernberg", "ok": True})
    c10 = dq_summary(p, now + 4063)["channels"][2]
    assert c10["status"] == "active" and c10["ens"] == "Nuernberg", c10
    c10 = dq_summary(p, now + 3900 + 7 * 86400 + 5)["channels"][2]
    assert c10["status"] == "offline" and "zuletzt Sync vor 7 Tagen" in c10["note"] and "Grenze 7 Tagen" in c10["note"], c10   # erst > 7 Tage ohne Sync
    c10 = dq_summary(p, now + 3900 + 7 * 86400 - 5)["channels"][2]
    assert c10["status"] == "active" and "zuletzt Sync vor 6 Tagen" in c10["note"], c10
    assert dq_summary(p, now + 3900 + 2 * 86400)["channels"][2]["status"] == "active"                     # nach 1-2 Tagen (frueher 24-h-Regel) weiter aktiv
    assert dq_chstat("10C", None, now + 8 * 86400, None, now)[0] == "offline" and dq_chstat("10C", None, now + 6 * 86400, None, now)[0] == "unknown"
    assert dq_chstat("5C", None, now + 3600, None, now)[0] == "offline" and dq_chstat("5C", now, now + 1700)[0] == "active" and dq_chstat("5C", now, now + 1900)[0] == "offline"
    c11 = dq_summary(p, now + 4060 + 31 * 60)["channels"][0]
    assert c11["status"] == "offline", c11                                           # 11D nach 30 min
    # Aufraeumen: reception_log 60 Tage
    dq_tick(p, now + 61 * 86400)
    con = db.connect(p)
    try:
        assert con.execute("SELECT COUNT(*) FROM reception_log").fetchone()[0] == 0
        assert con.execute("SELECT COUNT(*) FROM masts WHERE tii IN ('07/77', '07/66', '22/99')").fetchone()[0] == 0 and con.execute("SELECT COUNT(*) FROM masts WHERE tii='08/18'").fetchone()[0] == 1
    finally:
        con.close()
    # kaputt/fehlend: nie werfen
    assert dq_summary(os.path.join(d, "gibtsnicht.db"))["ok"] is False and dq_summary("/nonexistent/x/y.db")["ok"] is False
    open(os.path.join(d, "sdr_config.json"), "w").write('{"dabsql": "off"}')
    assert dq_on(d) is False and dq_on(os.path.join(d, "nix")) is True
    return "sdr_manager selftest dabSql ok (Tabellen masts/reception_log/channel_status, Import einmalig mit amtlicher Liste vor MASTS_DB, unbekannte TII automatisch + Anzeige erst > 50 Sichtungen/60 Tage, bekannte Masten nach 2 Empfaengen in Folge, 10C Rückfallkanal erst nach > 7 Tagen offline (zuletzt Sync vor X), 11D/5C nach 30 min, Herkunft amtlich = fmlist.org / nicht amtlich, kartevec tii_seen nur als unbekannt, 60-Tage-Aufraeumen, Lesen wirft nie)"
DSM_EOF
EXPECT_DG="f48b2344e73ce51d1b0b6be8a406de2a4096d2f49661721bcb162ce5fec53800"
cat > "$W/guard_dab.py" << 'DG_EOF'
"""AST-Guard dabSql. Aufruf: guard_dab.py EDITS  ART ALT NEU BLOCK ...  (ART = sdr | sm | dsh; ALT = Stand nach sdrAir2) -> 0 ok, 1 Verstoss.
Rueckbau (Block weg, Stellen zurueck) muss Byte fuer Byte ALT ergeben. Neuer Code: kein Prozess, kein Netz, kein shell, keine Sendewege, kein Hilfsprogramm, keine Aktion (kill/Neustart/USB/Pi-Neustart/Gain/Geraete-Auswahl);
einziger Faden: DabsqlWriter.start (Schreibfaden); Datenbank nur ueber database.connect und nur die Tabellen masts/reception_log/channel_status (+ meta-Schluessel dabsql_*), kein DROP/ALTER; Dateizugriff nur lesend, Schreiben nur im Selbsttest (tempfile)."""
import ast
import re
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover", "set_auto", "autosend", "fork", "spawn", "kill", "set_lage", "set_mode", "reboot", "_wd_helper", "_wd_do", "_air_usb",
       "unlink", "remove", "rmtree", "chmod", "chown", "setpriority", "thread", "restart", "usb")
err = []
a = sys.argv[2:]
done_all = True
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = g["%s_EDITS" % kind.upper()]
    if new.count(B.rstrip("\n")) != 1:
        err.append("%s: Block sdrAir2 fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sdrAir2" % (kind, len(E)))
    for o, n in E:
        ol = set(o.splitlines())
        low = "\n".join(x for x in n.splitlines() if x not in ol and not x.strip().startswith("assert ")).lower()   # Selbsttest-Zusicherungen ausgenommen
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv", "thread", "_wd_helper(", "_wd_do(",
                  "uhubctl", "unbind", "fetch(", "xmlhttprequest", "takeover_set(", "reboot", "kill(", "open("):
            if k in low:
                err.append("%s Stelle: %s" % (kind, k))
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        err.append("%s Block: Syntax %s" % (kind, e)); continue
    fn_of = {}
    for f in ast.walk(t):                                      # auch Methoden; innerste Funktion gewinnt (ast.walk: aeussere zuerst)
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                fn_of[id(x)] = f.name
    for n in ast.walk(t):
        fn = fn_of.get(id(n), "?")
        st = fn.startswith(("selftest", "_selftest"))
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if not ((mod == "tempfile" and st) or mod == "queue" or (mod == "sdr_manager" and (st or fn == "start")) or (mod == "flask" and kind == "dsh" and fn == "_dq_api")):
                    err.append("%s Block: Import %s" % (kind, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s Block: shell" % kind)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if st and nm in ("open", "makedirs", "rename", "close", "write", "mkdtemp"):
                continue                                       # Selbsttest: Fake-USB-Baum/Fake-Modul im Temp-Ordner
            if nm == "add_url_rule" and kind == "dsh" and n.args and isinstance(n.args[0], ast.Constant) and n.args[0].value == "/api/dabsql/status" \
                    and [k.value.elts[0].value for k in n.keywords if k.arg == "methods" and isinstance(k.value, ast.List) and len(k.value.elts) == 1] == ["GET"]:
                continue                                       # einzige neue Route: GET /api/dabsql/status (nur lesen)
            if fn == "start" and nm == "Thread" and base == "threading":
                continue                                       # dabSql: einziger Faden = Schreibfaden (daemon)
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run", "Thread", "Timer", "open",
                                                           "rename", "makedirs", "write", "replace") and not (nm == "replace" and kind in ("sdr", "sm", "dsh")) \
                    or base in ("subprocess", "requests", "socket", "multiprocessing", "shutil"):
                err.append("%s Block: Aufruf %s in %s" % (kind, nm, fn))
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and any(k in n.value for k in ("uhubctl", "/unbind", "bind_ports", "power/control", "/usr/local/sbin", "sudo")):
            err.append("%s Block: verbotener Text %s" % (kind, n.value[:40]))
    OKT = ("masts", "reception_log", "channel_status", "meta")
    for n in ast.walk(t):
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and re.match(r"(?is)\s*(INSERT\s+(OR\s+\w+\s+)?INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|DROP\s+(TABLE|INDEX)|ALTER\s+TABLE|CREATE\s+(TABLE|INDEX)|REPLACE\s+INTO)\b", n.value):
            if re.search(r"(?i)\b(DROP|ALTER|ATTACH|PRAGMA)\b", n.value):
                err.append("%s Block: SQL DROP/ALTER/ATTACH/PRAGMA: %s" % (kind, n.value[:50]))
            for tb in re.findall(r"(?i)\bINTO\s+(\w+)|\bUPDATE\s+(\w+)\s+SET\b|\bDELETE\s+FROM\s+(\w+)|\bTABLE(?: IF NOT EXISTS)?\s+(\w+)|\bINDEX(?: IF NOT EXISTS)?\s+\w+\s+ON\s+(\w+)", n.value):
                tb = next(x for x in tb if x)
                if tb not in OKT and not (tb == "tii_seen" and str(fn_of.get(id(n), "")).startswith("selftest")):   # tii_seen (kartevec) nur im Selbsttest in der Wegwerf-DB beschrieben
                    err.append("%s Block: SQL schreibt fremde Tabelle %s: %s" % (kind, tb, n.value[:50]))
            if re.search(r"(?i)\bmeta\b", n.value) and re.search(r"(?i)\b(INSERT|UPDATE|DELETE)\b", n.value) and "'dabsql_" not in n.value:
                err.append("%s Block: meta nur Schluessel dabsql_*: %s" % (kind, n.value[:50]))
    if kind == "sdr":
        def fdump(src, name):
            for x in ast.parse(src).body:
                if isinstance(x, ast.FunctionDef) and x.name == name:
                    return ast.dump(x)
            return None
        for fn in ("_wd_helper", "_wd_do", "wd_helper_state", "_wd_decide", "_wd_save", "_wd_emit", "_air_usb", "dabgain_step", "_air_gain_state"):
            if fdump(old, fn) is None or fdump(old, fn) != fdump(new, fn):
                err.append("sdr: Original %s veraendert" % fn)
        if new.count('WD_HELPER = "/usr/local/sbin/prepper-sdr-wdhelper"') != 1:
            err.append("sdr: WD_HELPER-Pfad")
        if 'AIR_LADDER = (16, 12, 19, 9, 21, "agc")' not in new:
            err.append("sdr: Airspy-Gain-Leiter veraendert")
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard dabSql: nur %s Stellen + Bloecke; kein Prozess/Netz/shell/Sendeweg/Hilfsprogramm/Aktion im neuen Code, nur ein Schreibfaden, SQL nur masts/reception_log/channel_status (+ meta dabsql_*), kein DROP/ALTER; Watchdog-Aktionen, Gain-Leiter/-Logik (dabgain_step, _air_gain_state) und WD_HELPER unveraendert" % (
    "/".join("%d" % len(g["%s_EDITS" % a[i].upper()]) for i in range(0, len(a), 4))))
DG_EOF
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
EXPECT_DDB="c74a3564c1253ac56ba089c4c7ac2b9e1ea8c39e14044a2b44894f2c33bde300"
cat > "$W/dab_dash_block.py" << 'DDB_EOF'
# ===== dabSql: Anzeige - /api/dabsql/status (nur lesen) und Zusammenfassung oben auf /dabhist (Kanaele aktiv/offline, bekannte/unbekannte Masten, letzte Aktualisierung) aus den Tabellen masts/reception_log/channel_status in lagezentrum.db; Geraetenamen aus dem Register; nichts wird gesendet oder geschaltet =====
_dq_orig_fu_dh_html = _fu_dh_html
_DQD = {"t": 0.0, "v": None, "err": None, "selftest": None}


def _dq_sum():
    """Zusammenfassung, 20 s zwischengespeichert; wirft nie."""
    now = _t4_time.time()
    if _DQD["v"] is not None and now - _DQD["t"] < 20:
        return _DQD["v"]
    v = {"ok": False, "txt": "dabSql: nicht verfuegbar", "channels": []}
    try:
        if _lz_mgr is None or not hasattr(_lz_mgr, "dq_summary"):
            raise RuntimeError("sdr_manager.py ohne dabSql")
        v = _lz_mgr.dq_summary(_t4_paths()[1], int(now))
    except Exception as e:
        v = dict(v, error=str(e)[:120])
        print("dabSql Anzeige:", e, flush=True)
    _DQD.update(t=now, v=v)
    return v


def _dq_api():
    from flask import jsonify
    try:
        return jsonify(_dq_sum())
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


def _dq_dev(ch):
    """Geraet je Kanal aus dem Register: 11D = Airspy, 5C = Stick 5C, 10C = Hobby-Stick (Pruefung alle 6 h); sonst ''."""
    try:
        st = _air2d_reg()
        if st:
            role = {"11D": "11D", "5C": "5C", "10C": "hobby"}.get(ch)
            for x in _air2d_devs(st):
                if x.get("role") == role:
                    return x.get("label") or ""
    except Exception:
        pass
    return ""


def _dq_card(v=None):
    e = _fu_e
    v = v if v is not None else _dq_sum()
    if not isinstance(v, dict) or not v.get("ok"):
        return ""
    pills = []
    for c in v.get("channels") or []:
        stt = c.get("status")
        cls, tx = ("ok", "aktiv") if stt == "active" else (("offline", "offline") if stt == "offline" else ("gelb", "noch keine Prüfung"))
        dev = _dq_dev(c.get("ch"))
        pills.append('<span class="fu-pill %s" title="%s">%s %s</span> <span style="font-size:.8rem;color:#94a3b8">%s%s</span>' % (
            cls, e(c.get("note") or ""), e(c.get("ch")), tx, e(dev), (" · " + str(c.get("note"))) if c.get("note") else ""))
    rows = []
    for x in (v.get("known_list") or [])[:6]:
        rows.append('<div style="font-size:.82rem;color:#cbd5e1">%s · %s %s · zuletzt %s%s</div>' % (e(x.get("name")), e(x.get("ch")), e(x.get("tii")), _fu_tm(x.get("last_seen")),
                                                                                                 " · nicht amtlich" if x.get("src_kind") == "nicht_amtlich" else ""))
    for x in (v.get("unknown_list") or [])[:6]:
        rows.append('<div style="font-size:.82rem;color:#fdba74">unbekannte Kennung %s %s · %d Sichtungen in %d Tagen · zuletzt %s</div>' % (
            e(x.get("ch")), e(x.get("tii")), int(x.get("n60") or 0), int((v.get("rule") or {}).get("unknown_days") or 60), _fu_tm(x.get("last_seen"))))
    pv = v.get("prov") or {}
    if pv:
        rows.insert(0, '<div style="font-size:.78rem;color:#94a3b8">Herkunft der Masten: %d amtlich (fmlist.org), %d nicht amtlich, %d nur beobachtet/unbekannt · Namen vor TII-Codes, amtliche Quellen vor MASTS_DB</div>' % (
            int(pv.get("amtlich") or 0), int(pv.get("nicht_amtlich") or 0), int(pv.get("auto") or 0) + int(pv.get("kartevec") or 0)))
    return ('<div class="card" id="dqCard"><div class="title">📡 DAB-Empfang · Masten (Datenbank)</div><div style="display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center">%s</div>'
            '<div style="font-size:.85rem;margin-top:8px;color:#e2e8f0">%s</div>%s</div>' % (" ".join('<span>%s</span>' % p for p in pills), e(v.get("txt") or ""), "".join(rows)))


def _fu_dh_html(items, cats, ch, skip, thr, now=None):
    h = _dq_orig_fu_dh_html(items, cats, ch, skip, thr, now)
    try:
        return _dq_card() + h
    except Exception as ex:
        if not _DQD.get("quiet"):
            print("dabSql Karte:", ex, flush=True)
        return h


def _selftest_dabsql_dash():
    v = {"ok": True, "t": 1790000000, "txt": "Kanäle: 11D, 5C aktiv, 10C offline · bekannte Masten 3 von 25 empfangen · unbekannte Kennungen 1 angezeigt (4 werden gesammelt) · aktualisiert vor 1 min",
         "channels": [{"ch": "11D", "status": "active", "note": "zuletzt Sync vor 10 s", "last_sync": 1789999990}, {"ch": "5C", "status": "active", "note": "zuletzt Sync vor 1 min", "last_sync": 1789999900},
                      {"ch": "10C", "status": "offline", "note": "offline: zuletzt Sync vor 8 Tagen (Grenze 7 Tagen · Rückfallkanal, Hobby-Prüfung alle 6 h)", "last_sync": 1789800000}],
         "known_list": [{"ch": "11D", "tii": "08/18", "name": "Bamberg <Geisberg>", "last_seen": 1789999990, "src_kind": "nicht_amtlich"}], "rule": {"unknown_days": 60},
         "prov": {"amtlich": 100, "nicht_amtlich": 2, "auto": 3, "kartevec": 1},
         "unknown_list": [{"ch": "5C", "tii": "07/77", "n60": 61, "last_seen": 1789999000}]}
    st = {"devs": [{"name": "Airspy R2", "role": "11D", "present": True}, {"name": "Stick 1", "role": "5C", "present": True}, {"name": "Stick 2", "role": "hobby", "present": True}]}
    g0, g1 = globals()["_air2d_reg"], globals()["_dq_sum"]
    globals()["_air2d_reg"] = lambda: st
    try:
        h = _dq_card(v)
        assert 'id="dqCard"' in h and "11D aktiv" in h and "10C offline" in h and "Airspy R2 · 11D" in h and "Stick 1 · 5C" in h and "Stick 2 · Hobby" in h, h
        assert "zuletzt Sync vor 10 s" in h and "zuletzt Sync vor 8 Tagen" in h and "100 amtlich (fmlist.org), 2 nicht amtlich, 4 nur beobachtet" in h and "· nicht amtlich</div>" in h, h
        assert "Bamberg &lt;Geisberg&gt;" in h and "unbekannte Kennung 5C 07/77 · 61 Sichtungen in 60 Tagen" in h and "<Geisberg>" not in h
        assert _dq_card({"ok": False}) == "" and _dq_card("x") == ""
        globals()["_dq_sum"] = lambda: v
        o = _fu_dh_html([], list(_FU_CAT_DEF), "", {}, "G", 1790000000)
        assert o.startswith('<div class="card" id="dqCard">') and o.count('id="dqCard"') == 1 and len(o) > len(h)
        globals()["_dq_sum"] = lambda: (_ for _ in ()).throw(RuntimeError("x"))
        _DQD["quiet"] = True                                                            # absichtlicher Fehler im Selbsttest: keine Fehlerzeile im Journal
        o2 = _fu_dh_html([], list(_FU_CAT_DEF), "", {}, "G", 1790000000)
        assert 'id="dqCard"' not in o2 and len(o2) > 100                                # Karte faellt aus -> Verlauf wie bisher
    finally:
        globals()["_air2d_reg"], globals()["_dq_sum"] = g0, g1
        _DQD["quiet"] = False
    return "dabSql Anzeige ok (Zusammenfassung oben auf /dabhist: Kanaele aktiv/offline mit Geraetenamen, bekannte/unbekannte Masten, Aktualisierung; Fehler = Verlauf wie bisher; /api/dabsql/status nur lesen)"


try:
    _DQD["selftest"] = _selftest_dabsql_dash()
    if "dq_status" not in app.view_functions:
        app.add_url_rule("/api/dabsql/status", endpoint="dq_status", view_func=_dq_api, methods=["GET"])
    print("dabSql aktiv: %s" % _DQD["selftest"], flush=True)
except Exception as _dq_e:
    print("dabSql Anzeige FEHLER (Verlauf wie bisher):", _dq_e, flush=True)
DDB_EOF
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
PF="$W/patch-fu.py"; DE="$W/dab_edits.py"; DSD="$W/dab_sdr_block.py"; DSM="$W/dab_sm_block.py"; DG="$W/guard_dab.py"; AC2="$W/air2check.py"; DDB="$W/dab_dash_block.py"; DCK="$W/dabcheck.py"
AC="$W/aircheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"; CK="$W/sqlccheck.py"
for x in "$EXPECT_PF $PF" "$EXPECT_DE $DE" "$EXPECT_DSD $DSD" "$EXPECT_DSM $DSM" "$EXPECT_DG $DG" "$EXPECT_AC2 $AC2" "$EXPECT_DDB $DDB" "$EXPECT_DCK $DCK" "$EXPECT_AC $AC" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2" "$EXPECT_CK $CK"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || { [[ "$1" == "$4" ]] && echo "bekannt ($5)" || echo "UNBEKANNT"; }; }
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sdrAir2" "$KNOWN_SDR16N" "dabSql schon drin"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sdrAir2" "$KNOWN_SM16N" "dabSql schon drin"))"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sdrAir2" "$KNOWN_D16N" "dabSql schon drin"))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
[[ "$SDR16" == "$KNOWN_SDR16" || "$SDR16" == "$KNOWN_SDR16N" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16 = sdrAir2 oder $KNOWN_SDR16N = dabSql);"
[[ "$SM16" == "$KNOWN_SM16" || "$SM16" == "$KNOWN_SM16N" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16 = sdrAir2 oder $KNOWN_SM16N = dabSql);"
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 = sdrAir2 oder $KNOWN_D16N = dabSql);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      dabSql passt nur auf den sdrAir2-Stand vom 24.10. (prepper_sdr b139eaf50abf4d36, sdr_manager 679fde6003d22ff7, dashboard b0712eafe3d2235d) - nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = sdrAir2 (bzw. dabSql schon drin), alle sha16 bekannt"
grep -q '# ===== sdrAir2:' "$M" && grep -q '# ===== sdrAir2:' "$SMF" && grep -q '# ===== sdrAir2:' "$F" || { echo "STOP: sdrAir2 fehlt - nichts geaendert"; exit 1; }
[[ -x "$HDST" ]] || { echo "STOP: Hilfsprogramm $HDST fehlt - nichts geaendert"; exit 1; }
HL16=$(s16 "$HDST")
[[ "$HL16" == "$KNOWN_HL16" ]] || { echo "STOP: Hilfsprogramm sha16 $HL16 statt $KNOWN_HL16 (sdrAir) - nichts geaendert"; exit 1; }
echo "OK Hilfsprogramm $HDST sha16 $HL16 (sdrAir, bleibt)"
for k in "sdr prepper_sdr $M $DSD $KNOWN_SDR16N" "sm sdr_manager $SMF $DSM $KNOWN_SM16N" "dsh dashboard $F $DDB $KNOWN_D16N"; do set -- $k
  if [[ "$(s16 "$3")" == "$5" ]]; then cp "$3" "$W/work/$2.py"; echo "$2.py: dabSql schon drin" > "$W/q_$1.log"; continue; fi
  python3 "$PF" dabSql "$1" "$3" "$W/work/$2.py" "$4" "$DE" > "$W/q_$1.log" || { cat "$W/q_$1.log"; echo "STOP: $2.py dabSql-Stufe passt nicht - nichts geaendert"; exit 1; }
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
for k in "sdr prepper_sdr $DSD" "sm sdr_manager $DSM" "dsh dashboard $DDB"; do set -- $k
  python3 "$PF" dabSql "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$DE" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
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
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/dabsql-selftest timeout 300 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlC ok" "sdr_manager selftest funkUI ok" "sdr_manager selftest sdrWd ok" "sdr_manager selftest sdrWd2 ok" "sdr_manager selftest sdrAir ok" "sdr_manager selftest sdrAir2 ok" "sdr_manager selftest dabSql ok"; do
    grep -qF "$k" "$W/smt.log" || { tail -6 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && SDR_WD_HELPER=/nonexistent/dabsql-selftest timeout 600 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok" "selftest sdrLog ok" "selftest sdrWd ok" "selftest sdrWd2 ok" "selftest sdrAir ok" "selftest sdrAir2 ok" "selftest dabSql ok"; do
    grep -qF "$k" "$W/sdrt.log" || { tail -6 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  echo "OK Selbsttests mit $py (Sandbox, Fake-Prozesse, Fake-USB-Baum, Fake-Hilfsprogramm, Fake-SoapySDR-Modul; nichts zurueckgesetzt, nichts neu gestartet, nichts gesendet)"
  [[ "$py" == "$VPY" ]] || continue
  echo "   $(grep -F 'selftest dabSql ok' "$W/sdrt.log" | tail -1 | cut -c1-300)"
  echo "   $(grep -F 'sdr_manager selftest dabSql ok' "$W/smt.log" | tail -1 | cut -c1-300)"
done
if [[ "$SDR16" == "$KNOWN_SDR16N" && "$SM16" == "$KNOWN_SM16N" && "$D16" == "$KNOWN_D16N" ]]; then
  echo "OK dabSql schon drin - Guard-Rueckbau gegen Basis entfaellt (Inhalt = gepruefter Zielstand, sha16)"
else
  python3 "$DG" "$DE" sdr "$M" "$W/work/prepper_sdr.py" "$DSD" sm "$SMF" "$W/work/sdr_manager.py" "$DSM" dsh "$F" "$W/work/dashboard.py" "$DDB" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard dabSql - nichts geaendert"; exit 1; }
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
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert) ----------
trap '' INT
RESTARTED=0
ALL=("$M" "$SMF" "$F")
if cmp -s "$W/work/prepper_sdr.py" "$M" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK dabSql schon installiert (prepper_sdr.py, sdr_manager.py, dashboard.py) - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    for u in prepper-sdr prepper-dashboard; do sudo journalctl -u "$u" --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sdrAir|sdrWd|Traceback" | tail -4 | cut -c1-200 || true; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-dabsql-$TS" ]] && cp -a "$x.bak-dabsql-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-dabsql-$TS" ]] || continue; cmp -s "$x" "$x.bak-dabsql-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  Sicherungen von vorher: $LZ.bak-dabsql-$TS, $WDJ.bak-dabsql-$TS (nicht zurueckgespielt; Watchdog-Zustand bleibt)"
    echo "alter Stand (sdrAir) wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$WDJ"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-dabsql-$TS"
    { ls -1t "$x.bak-dabsql-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-dabsql-$TS" \
      || { rm -f "$LZ.bak-dabsql-$TS"; for x in "${ALL[@]}" "$WDJ"; do rm -f "$x.bak-dabsql-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-dabsql-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "prepper_sdr $M" "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-dabsql-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
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
nok=0; for i in $(seq 1 10); do
  rm -rf "$W/nm" && mkdir -p "$W/nm"
  for p in / /funk /pi /umwelt /dabhist /mesh; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').html" || true; done
  for p in /api/sdr/ui /api/sdr/wd /api/t2/status /api/t4/status /api/dabsql/status; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').json" || true; done
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
R1='Traceback|dabSql( Start| on_dab)|dabSql: (Schreibfehler|Tabellen|Lesen|kartevec-Import|Schreibfaden nicht)|^sdrAir2? [A-Za-z/ ]*:|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:'
E1=$(echo "$JP" | grep -c -E "$R1" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JP" | grep -E "$R1" | head -5 | cut -c1-240; rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"; }
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JA=$(echo "$JD" | grep -F "dabSql aktiv: dabSql Anzeige ok" | tail -1 || true)
  [[ -n "$JA" ]] && echo "OK Journal Dashboard: $(echo "$JA" | cut -c1-260)" || rbx "Dashboard meldet dabSql-Anzeige nicht (Selbsttest)"
  JW=$(echo "$JP" | grep -F "dabSql: Schreibfaden laeuft" | tail -1 || true)
  [[ -n "$JW" ]] && echo "OK Journal prepper-sdr: $(echo "$JW" | cut -c1-200)" || rbx "prepper-sdr meldet den dabSql-Schreibfaden nicht"
fi
R2='Traceback|dabSql Anzeige(:| FEHLER)|dabSql Karte:|dabSql: (Lesen|Tabellen|kartevec-Import)|sdrWd FEHLER|funkUI FEHLER|sdr_manager sdrWd|sdr_manager sdrAir2? [A-Za-z_ -]+:|sdrAir2? Anzeige(:| FEHLER)'
E2=$(echo "$JD" | grep -c -E "$R2" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JD" | grep -E "$R2" | head -5 | cut -c1-240; rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"; }
python3 "$AC2" proof "$DASH_DIR" 0 > "$W/proof.log" 2>&1 && echo "Geraete nachher: $(cut -c1-460 "$W/proof.log")" || echo "HINWEIS Geraete nachher: $(cut -c1-300 "$W/proof.log")"
echo "Watchdog nachher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-400)"
for x in "$DBF:$DB16" "$MR:$MR16" "$HDST:$HL16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
echo "OK guards dabSql(sdr)=$(grep -c '# ===== dabSql:' "$M" || true) dabSql(sm)=$(grep -c '# ===== dabSql:' "$SMF" || true) dabSql(dash)=$(grep -c '# ===== dabSql:' "$F" || true) sdrAir2(sdr)=$(grep -c '# ===== sdrAir2:' "$M" || true) sdrAir2(sm)=$(grep -c '# ===== sdrAir2:' "$SMF" || true) sdrAir(sdr)=$(grep -c '# ===== sdrAir:' "$M" || true) sdrAir(sm)=$(grep -c '# ===== sdrAir:' "$SMF" || true) sdrAir(dash)=$(grep -c '# ===== sdrAir:' "$F" || true) sdrAir2(dash)=$(grep -c '# ===== sdrAir2:' "$F" || true) sdrWd2(sdr)=$(grep -c '# ===== sdrWd2:' "$M" || true) sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sysBoot(dash)=$(grep -c '# ===== sysBoot' "$F" || true)"
[[ -f "$M.bak-dabsql-$TS" ]] && echo "Backups: *.bak-dabsql-$TS (prepper_sdr.py, sdr_manager.py, dashboard.py, sdr_wd.json, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF" "$HDST"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Rueckweg: prepper_sdr.py.bak-dabsql-$TS, sdr_manager.py.bak-dabsql-$TS und dashboard.py.bak-dabsql-$TS zurueckkopieren, dann sudo systemctl restart prepper-sdr prepper-dashboard"
echo "SoapySDR testen (nur auf Wunsch): in sdr_config.json air_fe auf soapy, dann sudo systemctl restart prepper-sdr; Rueckfall auf -F airspy geschieht automatisch"
echo "COMMIT $COMMIT_ARG dabsql=1 fertig"
