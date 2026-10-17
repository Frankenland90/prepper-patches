#!/bin/bash
set -euo pipefail
# sqlA (Teil A der SQLite-Umstellung, nach kartevec): Aufraeum-Faden in database.py (start_retention, einmal je Prozess, alle 10 min, Epoch-Sekunden):
# Ereignisse erst 7 Tage NACH Ablauf loeschen (aktiv bleibt nur expires >= jetzt; Historie zeigt abgelaufene markiert), mesh_log 24 h, Telemetrie 48 h,
# mesh_auto 30 d, asa_rx 14 d, mesh_queue 7 d, lageGeo-Cache; alte Ausloeser (Sync.tick, Teil 2/3, lageGeo) nur noch Rueckfall/Waechter.
# Jede Verbindung: rollback() vor close (offene Transaktion), PRAGMA-Fehler -> sofort schliessen. Stick-2-Anzeige: aus seit Ende der Uebernahme,
# alter Grund "Knopf auf der Lage-Seite" wird nur in der Anzeige als damals Lage-/jetzt Funk-Seite gezeigt (sdr_takeover.json bleibt unveraendert).
# Aendert database.py, sdr_manager.py, dashboard.py; prepper_sdr.py, mesh_router.py, lagegeo.py bleiben unveraendert. Neustart nur prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sqla-apply
KEEP_LAST=3
KNOWN_D16="9c2719d7dd77ed8f"     # dashboard.py nach kartevec
KNOWN_SM16="02d62b60a3565053"    # sdr_manager.py nach kartevec
KNOWN_DB16="c3b138fbe1080373"    # database.py (Teil 2/3)
KNOWN_SDR16="de3fad568616ffb3"   # prepper_sdr.py nach tiiFix2 (bleibt unveraendert)
KNOWN_MR16="c5ffda3907b0dd51"    # mesh_router.py (bleibt unveraendert)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== sqlA apply (Aufraeum-Faden lagezentrum.db, rollback vor close, Stick-2-Anzeige), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_P="748da6c1885a93e7d5c42a3148989d1ec7dfbc9bce82ca199cbc8fe0324d722a"
cat > "$W/patch-sqla.py" << 'SQP_EOF'
"""sqlA-Patcher. Aufruf: patch-sqla.py ART QUELLE ZIEL BLOCK EDITS   (ART = db | sm | dash). Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis."""
import sys
kind, src, dst, blk, edp = sys.argv[1:6]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E, ANCH = {"db": (g["DB_EDITS"], g["DB_ANCHOR"]), "sm": (g["SM_EDITS"], g["SM_ANCHOR"]), "dash": (g["DASH_EDITS"], g["DASH_ANCHOR"])}[kind]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
MARK = B.splitlines()[0]
name = {"db": "database", "sm": "sdr_manager", "dash": "dashboard"}[kind]
if MARK in s:
    rest = s.replace(B, "", 1)
    ok = s.count(B) == 1 and all(rest.count(n) == 1 for o, n in E)
    if not ok:
        print("%s: sqlA teilweise/anders vorhanden" % name); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: sqlA schon drin" % name); raise SystemExit(0)
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
print("%s: %d Stellen + Block sqlA" % (name, len(E)))
SQP_EOF
EXPECT_E="be3e24b8e191315d4671ea865d2570d0bd364f97fdb77ee443371b58049ca4ac"
cat > "$W/edits.py" << 'SQE_EOF'
# sqlA: Stellen (alt, neu) je Datei. Jede alte Stelle muss genau einmal vorkommen.
DB_EDITS = [
("""KEEP_TELEMETRY_S = 48 * 3600
""", """KEEP_TELEMETRY_S = 48 * 3600
KEEP_EVENTS_HIST_S = 7 * 86400   # sqlA: abgelaufene Ereignisse bleiben 7 Tage in der Historie (aktiv ist nur expires >= jetzt)
"""),
('''def connect(path=None):
    """Neue Verbindung (je Aufruf). WAL, busy_timeout, Row-Zugriff per Name."""
    con = sqlite3.connect(path or DB_PATH, timeout=TIMEOUT_S)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    return con
''', '''class _Con(sqlite3.Connection):
    """sqlA: close() macht vorher explizit rollback(), wenn noch eine Transaktion offen ist (nie halb geschrieben, keine haengende Sperre)."""

    def close(self):
        try:
            if self.in_transaction:
                self.rollback()
        except Exception:
            pass
        super().close()


def connect(path=None):
    """Neue Verbindung (je Aufruf). WAL, busy_timeout, Row-Zugriff per Name. sqlA: rollback vor close; Fehler in den PRAGMAs -> sofort schliessen."""
    con = sqlite3.connect(path or DB_PATH, timeout=TIMEOUT_S, factory=_Con)
    try:
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("PRAGMA synchronous=NORMAL")
    except Exception:
        con.close()
        raise
    return con
'''),
('''    """Abgelaufene Ereignisse, mesh_log > 24 h, Telemetrie > 48 h loeschen. -> {tabelle: anzahl}"""''',
 '''    """Ereignisse 7 Tage nach Ablauf (sqlA), mesh_log > 24 h, Telemetrie > 48 h loeschen (Epoch-Sekunden). -> {tabelle: anzahl}"""'''),
('''"DELETE FROM events WHERE expires IS NOT NULL AND expires < ?", (now,)''',
 '''"DELETE FROM events WHERE expires IS NOT NULL AND expires < ?", (now - KEEP_EVENTS_HIST_S,)'''),
('''{"source": "BR24", "ext_id": "old", "expires": now - 5}''', '''{"source": "BR24", "ext_id": "old", "expires": now - KEEP_EVENTS_HIST_S - 5}'''),
('''    print(selftest_t3())
''', '''    print(selftest_t3())
    print(selftest_retention())
'''),
]
DB_ANCHOR = '\n\nif __name__ == "__main__":\n'

SM_EDITS = [
('''            if now - self.last_clean >= 600:
                self.last_clean = now
                self.stat["cleanup"] = db.cleanup(now, self.path)''',
 '''            if now - self.last_clean >= 600:
                self.last_clean = now
                self.stat["cleanup"] = db.retention_watch(self.path, now) if hasattr(db, "retention_watch") else db.cleanup(now, self.path)   # sqlA: Faden, sonst Rueckfall'''),
('''        if now - _T2["clean"] >= 600:
            _T2["clean"] = now
            db.cleanup_t2(now, path)''',
 '''        if now - _T2["clean"] >= 600:
            _T2["clean"] = now
            if not (hasattr(db, "retention_owns") and db.retention_owns(path)):   # sqlA: macht sonst der Aufraeum-Faden
                db.cleanup_t2(now, path)'''),
('''        to.pop("seen", None)
        out["takeover"] = to''',
 '''        to.pop("seen", None)
        to["why_txt"], to["end_t"] = takeover_why_txt(to.get("why")), (None if to.get("on") else to.get("off_t"))   # sqlA: nur Anzeige
        out["takeover"] = to'''),
('''                  why=to.get("why"), fb=fb, fail=s2x.get("fail")''',
 '''                  why=takeover_why_txt(to.get("why")), fb=fb, fail=s2x.get("fail")'''),
('''        s2 = {"state": "FREI / BEREITSCHAFT", "takeover": False, "ch": None, "f_mhz": None, "fb": False, "mode": (roles.get("s2") or {}).get("mode")}
    s2["sn"]''',
 '''        s2 = {"state": "FREI / BEREITSCHAFT", "takeover": False, "ch": None, "f_mhz": None, "fb": False, "mode": (roles.get("s2") or {}).get("mode"),
              "off_t": to.get("off_t")}   # sqlA: Ende der letzten Uebernahme (Anzeige "aus seit")
    s2["sn"]'''),
('''            t = e.get("updated") or e.get("created")
            out.append({"t": t, "src": src, "sev": sev, "color": c, "line": ("%s %s · %s" % (_t4_fmt_t(t), src, " ".join(str(e.get("headline") or e.get("text") or "").split())))[:180]})''',
 '''            t = e.get("updated") or e.get("created")
            exp = bool(isinstance(e.get("expires"), (int, float)) and e["expires"] < time.time())   # sqlA: 7 Tage Historie nach Ablauf
            out.append({"t": t, "src": src, "sev": sev, "color": c, "exp": exp,
                        "line": ("%s %s · %s%s" % (_t4_fmt_t(t), src, "abgelaufen · " if exp else "", " ".join(str(e.get("headline") or e.get("text") or "").split())))[:180]})'''),
('''        out["history"] = [{k: e.get(k) for k in ("source", "type", "severity", "headline", "created", "updated", "expires", "lat", "lon")}
                          for e in db.recent_events(10, path)]''',
 '''        out["history"] = [dict({k: e.get(k) for k in ("source", "type", "severity", "headline", "created", "updated", "expires", "lat", "lon")},
                               expired=bool(isinstance(e.get("expires"), (int, float)) and e["expires"] < now)) for e in db.recent_events(10, path)]   # sqlA'''),
('''    print(selftest_kv())
''', '''    print(selftest_kv())
    print(selftest_sqla())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'

DASH_EDITS = [
('''        if now - _LG["t_clean"] > 3600:
            _LG["t_clean"] = now
            _lg_mod.cleanup(now, _LZ_PATH)''',
 '''        if now - _LG["t_clean"] > 3600:
            _LG["t_clean"] = now
            if not (hasattr(_lz_dbm, "retention_owns") and _lz_dbm.retention_owns(_LZ_PATH)):   # sqlA: macht sonst der Aufraeum-Faden
                _lg_mod.cleanup(now, _LZ_PATH)'''),
('''            if _t3_now() - _T3S["cleanup_t"] > 3600:
                _T3S["cleanup_t"] = _t3_now()
                _lz_dbm.cleanup_t3(None, _LZ_PATH)''',
 '''            if _t3_now() - _T3S["cleanup_t"] > 3600:
                _T3S["cleanup_t"] = _t3_now()
                if not (hasattr(_lz_dbm, "retention_owns") and _lz_dbm.retention_owns(_LZ_PATH)):   # sqlA: macht sonst der Aufraeum-Faden
                    _lz_dbm.cleanup_t3(None, _LZ_PATH)'''),
('''"db_err": _lz_dbm.last_error(), "selftest": _LZ["selftest"]}}''',
 '''"db_err": _lz_dbm.last_error(), "selftest": _LZ["selftest"],
                                                  "retention": _lz_dbm.retention_status() if hasattr(_lz_dbm, "retention_status") else None}}'''),
("""L[1].textContent=to.on?('Stick 2: ALARM – fest auf 5C seit '+fmt(to.since)+' ('+(to.src||'?')+(to.why?': '+to.why:'')+')'):('Stick 2'+(s2.sn?' SN '+s2.sn:'')+': '+(s2.mode||'–'));""",
 """L[1].textContent=to.on?('Stick 2: ALARM – fest auf 5C seit '+fmt(to.since)+' ('+(to.src||'?')+((to.why_txt||to.why)?': '+(to.why_txt||to.why):'')+')'):('Stick 2'+(s2.sn?' SN '+s2.sn:'')+': '+(s2.mode||'–')+(to.end_t?' · Übernahme aus seit '+fmt(to.end_t):''));"""),
("""(s2.takeover?' · seit '+fmt(s2.since)+' ('+(s2.src||'?')+')':'');""",
 """(s2.takeover?' · seit '+fmt(s2.since)+' ('+(s2.src||'?')+')':(s2.off_t?' · Übernahme aus seit '+fmt(s2.off_t):''));"""),
]
DASH_ANCHOR = "# ===== /kartevec =====\n"
SQE_EOF
EXPECT_BDB="c722ccc87cc4a5d124ce47deace928142651ccf663a994ec530ba9b75a253ce8"
cat > "$W/db_block.py" << 'SQBD_EOF'
# ---------------------------------------------------------------- sqlA (Aufraeumen im eigenen Faden)
# start_retention(): ein Daemon-Faden je Prozess (Sperre, doppelter Start = nichts), alle 10 min alle Aufraeumarbeiten mit Epoch-Sekunden
# (alle Zeitspalten sind Unix-Sekunden, UTC-neutral): events erst 7 Tage NACH Ablauf loeschen (Historie; aktiv ist nur expires >= jetzt),
# mesh_log > 24 h, telemetry > 48 h, mesh_auto 30 d, asa_rx 14 d, mesh_queue 7 d, dazu Zusatzarbeiten (z. B. lageGeo-Cache) vom Aufrufer.
# retention_owns(path): Faden laeuft gesund fuer diese DB -> alte Ausloeser (Sync.tick, Teil 2/3, lageGeo) tun nichts.
# retention_watch(path): Rueckfall fuer Sync.tick: Faden fuer diese DB gestartet aber tot -> neu starten; nie gestartet -> einmal direkt aufraeumen.
import threading as _ret_threading

RETENTION_S = 600
RETENTION_FIRST_S = 30


class _Retention:
    def __init__(self, every_s=RETENTION_S, first_s=RETENTION_FIRST_S, name="lz-retention"):
        self.every_s, self.first_s, self.name = every_s, first_s, name
        self.lock = _ret_threading.Lock()
        self.th = None
        self.quiet = False
        self.stop = False
        self.path = None
        self.extra = {}
        self.st = {"started": None, "restarts": 0, "n": 0, "t": None, "last": None, "err": None, "first": None}

    def run(self, now=None, path=None):
        path = path or self.path or DB_PATH
        now = int(now or time.time())
        t0 = time.time()
        out = {}
        try:
            out.update(cleanup(now, path))
        except Exception as e:
            out["err_base"] = str(e)[:80]
        for k, fn in (("t2", cleanup_t2), ("t3", cleanup_t3)):
            try:
                out.update(fn(now, path) or {})
            except Exception as e:
                out["err_" + k] = str(e)[:80]
        for k, fn in sorted(self.extra.items()):
            try:
                out[k] = fn(now, path)
            except Exception as e:
                out[k] = None
                out["err_" + k] = str(e)[:80]
        ms = int((time.time() - t0) * 1000)
        self.st.update(n=self.st["n"] + 1, t=now, last=out, err=None)
        if self.st["first"] is None:
            self.st["first"] = dict(out, t=now)
        keys = ("events", "mesh_log", "telemetry", "mesh_auto", "asa_rx", "mesh_queue") + tuple(sorted(self.extra))
        if not self.quiet:
            print("lagezentrum.db Aufraeumen (Faden, Lauf %d): %s (%d ms)" % (self.st["n"], ", ".join("%s %s" % (k, "–" if out.get(k) is None else out.get(k)) for k in keys), ms), flush=True)
        return out

    def _loop(self):
        time.sleep(self.first_s)
        while not self.stop:
            try:
                self.run()
            except Exception as e:
                self.st["err"] = str(e)[:160]
                print("lagezentrum.db Aufraeumen (Faden) Fehler:", e, flush=True)
            time.sleep(self.every_s)

    def alive(self):
        return bool(self.th is not None and self.th.is_alive())

    def start(self, path=None, extra=None):
        with self.lock:
            if extra:
                self.extra.update({str(k): v for k, v in extra.items() if callable(v)})
            if self.alive():
                return False
            if self.th is not None:
                self.st["restarts"] += 1
            self.path = path or self.path or DB_PATH
            self.th = _ret_threading.Thread(target=self._loop, name=self.name, daemon=True)
            self.th.start()
            self.st["started"] = int(time.time())
            return True

    def owns(self, path=None):
        try:
            if not self.alive() or self.path is None:
                return False
            if os.path.realpath(path or DB_PATH) != os.path.realpath(self.path):
                return False
            ref = self.st["t"] or self.st["started"] or 0
            return time.time() - ref <= self.first_s + 3 * self.every_s
        except Exception:
            return False

    def status(self):
        return {"alive": self.alive(), "path": self.path, "every_s": self.every_s, "keep_events_after_expiry_s": KEEP_EVENTS_HIST_S,
                "extra": sorted(self.extra), **{k: self.st[k] for k in ("started", "restarts", "n", "t", "last", "err", "first")}}


_RETX = _Retention()


def start_retention(path=None, extra=None):
    """Aufraeum-Faden starten (idempotent, doppelter Start = nichts). -> True = neu gestartet"""
    try:
        return _RETX.start(path, extra)
    except Exception as e:
        _log("Aufraeum-Faden:", e)
        return False


def retention_owns(path=None):
    return _RETX.owns(path)


def retention_status():
    try:
        return _RETX.status()
    except Exception as e:
        return {"alive": False, "err": str(e)[:120]}


def retention_watch(path=None, now=None):
    """Rueckfall (Sync.tick alle 10 min): Faden gesund -> nichts; fuer diese DB gestartet, aber tot/haengt -> neu starten; sonst direkt aufraeumen."""
    try:
        if _RETX.owns(path):
            return {"faden": "laeuft"}
        if _RETX.path is not None and os.path.realpath(path or DB_PATH) == os.path.realpath(_RETX.path):
            if not _RETX.alive():
                _RETX.start(path)
                print("lagezentrum.db Aufraeum-Faden war beendet - neu gestartet", flush=True)
                return {"faden": "neu gestartet"}
        out = cleanup(now, path)
        out.update(cleanup_t2(now, path) or {})
        return dict(out, faden="direkt")
    except Exception as e:
        _log("Aufraeumen (Rueckfall):", e)
        return {"err": str(e)[:120]}


def selftest_retention():
    import tempfile
    d = tempfile.mkdtemp(prefix="lzret-")
    p = os.path.join(d, "r.db")
    assert migrate(p) and migrate_t2(p) and migrate_t3(p)
    now = int(time.time())
    D = 86400
    for eid, exp in (("aktiv", now + 3600), ("alarm_zukunft", now + 30 * D), ("ab_1h", now - 3600), ("ab_6d", now - 6 * D), ("ab_8d", now - 8 * D), ("ohne", None)):
        assert upsert_event({"source": "NINA", "ext_id": eid, "severity": "warn", "headline": eid, "created": now - 9 * D, "updated": now - 9 * D, "expires": exp}, p)
    for h, t in (("m23", now - 23 * 3600), ("m25", now - 25 * 3600)):
        assert mesh_log_put(h, "m1:0", t, "NINA", h, True, "nina", p)
    for i, t in enumerate((now - 47 * 3600, now - 49 * 3600)):
        assert insert_telemetry({"ts": t, "serial": "1", "channel": "11D", "snr": 10.0, "src_t": t + i}, p)
    act = {e["ext_id"] for e in active_events(now, p)}
    assert act == {"aktiv", "alarm_zukunft", "ohne"}, act                         # abgelaufene sind sofort nicht mehr aktiv
    r = _Retention(every_s=3600, first_s=3600, name="lz-retention-test")
    r.quiet = True
    r.extra = {"geo_cache": lambda n, pp: 0}
    out = r.run(now, p)
    assert out["events"] == 1 and out["mesh_log"] == 1 and out["telemetry"] == 1 and out["geo_cache"] == 0, out
    left = {e["ext_id"] for e in recent_events(20, p)}
    assert left == {"aktiv", "alarm_zukunft", "ab_1h", "ab_6d", "ohne"}, left     # Alarm mit Zukunfts-Ablauf nie geloescht, < 7 d Historie bleibt, > 7 d weg
    assert {e["ext_id"] for e in active_events(now, p)} == act                     # Aufraeumen aendert nichts an aktiven Ereignissen
    assert mesh_hash_since("m23", now - 6 * 3600, p) is False and _rows("SELECT hash FROM mesh_log", (), p)[0]["hash"] == "m23"
    assert [x["ts"] for x in _rows("SELECT ts FROM telemetry", (), p)] == [now - 47 * 3600]
    assert r.run(now, p)["events"] == 0                                            # zweiter Lauf: nichts mehr
    assert r.start(p) is True and r.start(p) is False and r.alive() and r.owns(p) and not r.owns(os.path.join(d, "andere.db"))
    r.stop = True                                                                   # Test-Faden endet nach seiner Wartezeit ohne Lauf
    assert _Retention().owns(p) is False
    con = connect(p)
    con.execute("BEGIN")
    con.execute("INSERT INTO mesh_log(hash, channel, created) VALUES('rb', 'x', 1)")
    con.close()                                                                     # explizites rollback() vor close
    assert not _rows("SELECT hash FROM mesh_log WHERE hash='rb'", (), p)
    return "database selftest sqlA ok (Aufraeum-Faden: Alarm mit Zukunfts-Ablauf bleibt, abgelaufen < 7 d bleibt in der Historie, > 7 d weg, mesh_log 24 h, telemetry 48 h, doppelter Start = nichts, rollback vor close)"
SQBD_EOF
EXPECT_BSM="6fbbfdcba5abaa26dac933474266573c5165473c1e25d0bb379d3bc643513688"
cat > "$W/sm_block.py" << 'SQBS_EOF'
# ---------------------------------------------------------------- sqlA (Anzeige Stick-2-Uebernahme, Historie mit abgelaufenen Ereignissen)
# Der Knopf liegt seit kartevec auf der Funk-Seite; neue Eintraege schreiben "Knopf auf der Funk-Seite". Alte Eintraege in sdr_takeover.json
# bleiben unveraendert (damals richtig); nur die Anzeige ergaenzt "damals Lage-Seite, jetzt Funk-Seite". Aus-Zustand zeigt das Ende (off_t).
SQLA_OLD_WHY = "Knopf auf der Lage-Seite"


def takeover_why_txt(why):
    """Grund fuer die Anzeige (Datei bleibt unveraendert)."""
    try:
        w = str(why or "")
        return w.replace(SQLA_OLD_WHY, "Knopf (damals auf der Lage-Seite, jetzt Funk-Seite)") if SQLA_OLD_WHY in w else (w or None)
    except Exception:
        return None


def selftest_sqla():
    import tempfile
    d = tempfile.mkdtemp(prefix="sqla-")
    p = os.path.join(d, "lagezentrum.db")
    now = int(time.time())
    assert takeover_why_txt("Knopf auf der Lage-Seite") == "Knopf (damals auf der Lage-Seite, jetzt Funk-Seite)"
    assert takeover_why_txt("Knopf auf der Funk-Seite") == "Knopf auf der Funk-Seite" and takeover_why_txt(None) is None
    takeover_set(d, True, "manual", "Knopf auf der Lage-Seite", "dashboard", now=now - 3000)
    takeover_set(d, False, "manual", "", "dashboard", now=now - 100)
    raw = _load(os.path.join(d, TAKEOVER_FILE), {})
    assert raw["why"] == "Knopf auf der Lage-Seite" and "why_txt" not in raw and "end_t" not in raw                 # Datei unveraendert, keine Anzeigefelder
    st = t2_status(d, p, now)
    to = st["takeover"]
    assert to["on"] is False and to["end_t"] == now - 100 and to["since"] == now - 3000 and "jetzt Funk-Seite" in to["why_txt"], to
    assert t4_sdr(d, now)["s2"]["off_t"] == now - 100
    takeover_set(d, True, "manual", "Knopf auf der Funk-Seite", "dashboard", now=now - 50)
    to = t2_status(d, p, now)["takeover"]
    assert to["on"] and to["end_t"] is None and to["why_txt"] == "Knopf auf der Funk-Seite" and t4_sdr(d, now)["s2"]["why"] == "Knopf auf der Funk-Seite"
    assert db.upsert_event({"source": "NINA", "ext_id": "alt", "severity": "warn", "headline": "Unwetter vorbei", "updated": now - 7200, "expires": now - 3600}, p)
    assert db.upsert_event({"source": "NINA", "ext_id": "neu", "severity": "warn", "headline": "Unwetter aktiv", "updated": now - 60, "expires": now + 3600}, p)
    h = {x["line"].split(" · ", 1)[1]: x for x in t4_history(p)}
    assert h["abgelaufen · Unwetter vorbei"]["exp"] is True and h["Unwetter aktiv"]["exp"] is False, h
    lv = live(d, p)
    assert {x["headline"]: x["expired"] for x in lv["history"]} == {"Unwetter vorbei": True, "Unwetter aktiv": False}, lv["history"]
    assert [e["ext_id"] for e in db.active_events(now, p)] == ["neu"]                                                  # Alarme/Karte nur nicht abgelaufene
    assert [a for a in alarms_from(None, None, None, db.active_events(now, p), now, {}) if a.get("key") == "alt"] == []
    s = Sync(d, p)
    s.tick({"nina": None, "br24": None}, force=True)
    assert s.stat["err"] is None and s.stat["cleanup"].get("faden") == "direkt" and s.stat["cleanup"]["events"] == 0, s.stat     # ohne Faden: Rueckfall
    return "sdr_manager selftest sqlA ok (Uebernahme: aus seit Ende, Grund damals Lage-/jetzt Funk-Seite nur Anzeige, Datei unveraendert; Historie markiert abgelaufen, aktiv nur nicht abgelaufene, Sync-Rueckfall)"
SQBS_EOF
EXPECT_BDA="f2ba04c382c9d0dfe0481868d017021b369e26dea7882de7167f7bfd9044a07e"
cat > "$W/dash_block.py" << 'SQBA_EOF'
# ===== sqlA: Aufraeum-Faden der Lagezentrum-Datenbank (database.start_retention, einmal je Prozess, alle 10 min: Ereignisse 7 Tage nach Ablauf, mesh_log 24 h, Telemetrie 48 h, Teil 2/3, lageGeo-Cache); alte Ausloeser nur noch Rueckfall; Stick-2-Anzeige aus seit Ende; sendet nichts =====
_SQA = {"started": None, "err": None, "selftest": None}


def _sqa_extra():
    ex = {}
    if globals().get("_lg_mod") is not None and hasattr(_lg_mod, "cleanup"):
        ex["geo_cache"] = lambda now, path: _lg_mod.cleanup(now, path)
    return ex


def _sqa_selftest():
    assert _lz_dbm is not None and hasattr(_lz_dbm, "start_retention") and hasattr(_lz_dbm, "retention_watch")
    r = _lz_dbm.selftest_retention()
    assert "sqlA ok" in r, r
    assert "geo_cache" in _sqa_extra() or globals().get("_lg_mod") is None
    assert _lz_mgr is not None and _lz_mgr.takeover_why_txt("Knopf auf der Lage-Seite").endswith("jetzt Funk-Seite)")
    js2, js4 = globals().get("_T2D_JS") or "", globals().get("_T4_JS") or ""
    assert "Übernahme aus seit '+fmt(to.end_t)" in js2 and "Übernahme aus seit '+fmt(s2.off_t)" in js4
    return "sqlA selftest ok (Aufraeum-Faden auf Test-DB, Stick-2-Anzeige)"


try:
    try:
        _SQA["selftest"] = _sqa_selftest()
    except Exception as _sqa_e1:
        _SQA["selftest"] = "sqlA selftest FEHLER: %s" % _sqa_e1
    if _lz_dbm is not None and hasattr(_lz_dbm, "start_retention"):
        _SQA["started"] = _lz_dbm.start_retention(_LZ_PATH, _sqa_extra())
    st = _lz_dbm.retention_status() if _lz_dbm is not None and hasattr(_lz_dbm, "retention_status") else {}
    if str(_SQA["selftest"]).startswith("sqlA selftest ok") and st.get("alive"):
        print("sqlA aktiv: %s; Aufraeum-Faden laeuft (alle %d s, erster Lauf nach %d s, Zusatz: %s, Ereignisse bleiben %d Tage nach Ablauf)" % (
            _SQA["selftest"], st.get("every_s") or 0, getattr(_lz_dbm, "RETENTION_FIRST_S", 0), ", ".join(st.get("extra") or []) or "–",
            int((st.get("keep_events_after_expiry_s") or 0) // 86400)), flush=True)
    else:
        print("sqlA FEHLER: %s; Faden %s - alte Aufraeum-Ausloeser bleiben als Rueckfall aktiv" % (_SQA["selftest"], "laeuft" if st.get("alive") else "laeuft NICHT"), flush=True)
except Exception as _sqa_e:
    _SQA["err"] = str(_sqa_e)[:160]
    print("sqlA FEHLER:", _sqa_e, flush=True)
# ===== /sqlA =====
SQBA_EOF
EXPECT_G="d0f8ff72bd1e5439ed87e52caea22534d9ce60b40e93e6072b9f51c20ea1bcdb"
cat > "$W/guard_sqla.py" << 'SQG_EOF'
"""sqlA AST-Guard. Aufruf: guard_sqla.py EDITS  db ALT NEU BLOCK  sm ALT NEU BLOCK  dash ALT NEU BLOCK -> 0 ok, 1 Verstoss.
Ruecktausch (Block weg, Stellen zurueck) muss Byte fuer Byte die Basis ergeben (schon eingespielt: Basis = Ergebnis -> nur Struktur).
Neue Bloecke/Stellen: keine Prozesse, kein Netz, kein shell, keine Sendewege, keine Routen, nur Importe threading/tempfile/os/time."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
EDS = {"db": g["DB_EDITS"], "sm": g["SM_EDITS"], "dash": g["DASH_EDITS"]}
err, new_code = [], []
a = sys.argv[2:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = EDS[kind]
    done = old == new and B.splitlines()[0] in old
    if new.count(B) != 1:
        err.append("%s: Block sqlA fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1) if kind != "dash" else new.replace(B, "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sqlA" % (kind, len(E)))
    new_code.append((kind + " Block", B))
    for o, n in E:
        new_code.append((kind + " Stelle", n))
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover_auto", "set_auto", "autosend")
for name, code in new_code:
    try:
        t = ast.parse(code) if "Block" in name else None
    except SyntaxError as e:
        err.append("%s: Syntax %s" % (name, e)); continue
    if t is None:
        low = code.lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send"):
            if k in low:
                err.append("%s: %s" % (name, k))
        continue
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if mod not in ("threading", "tempfile", "os", "time"):
                    err.append("%s: Import %s" % (name, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s: shell" % name)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route") or base in ("subprocess", "requests", "socket"):
                err.append("%s: Aufruf %s" % (name, nm))
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard sqlA: database.py, sdr_manager.py, dashboard.py nur die vorgesehenen Stellen + Block sqlA%s; keine Prozesse, kein Netz, kein shell, keine Sendewege/Routen" %
      (" (schon eingespielt)" if all(rd(a[i + 1]) == rd(a[i + 2]) for i in range(0, len(a), 4)) else ""))
SQG_EOF
EXPECT_C="29180aaa25971ad212e1088728c781fd5f084ef28e17ccfb3768f9010a0f6377"
cat > "$W/sqlacheck.py" << 'SQC_EOF'
"""sqlA Pruef-/Anzeigehilfe (nur lesen). Modi: active DB OUT | still DB IN | counts DB | live F | t2 F | t4 F | takeover DIR"""
import json
import sqlite3
import sys
import time


def ft(t):
    try:
        return time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(int(t)))
    except Exception:
        return "–"


def ro(p):
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
    c.execute("PRAGMA busy_timeout=10000")
    return c


a = sys.argv[1]
if a == "active":
    now = int(time.time())
    c = ro(sys.argv[2])
    try:
        ids = [r[0] for r in c.execute("SELECT ext_id FROM events WHERE COALESCE(is_test,0)=0 AND (expires IS NULL OR expires > ?)", (now + 900,))]
    finally:
        c.close()
    json.dump(ids, open(sys.argv[3], "w"))
    print(len(ids))
elif a == "still":
    ids = json.load(open(sys.argv[3]))
    c = ro(sys.argv[2])
    try:
        have = {r[0] for r in c.execute("SELECT ext_id FROM events")}
    finally:
        c.close()
    miss = [i for i in ids if i not in have]
    assert not miss, "aktive Ereignisse fehlen: %s" % miss[:5]
    print("alle %d aktiven Ereignisse (Ablauf in > 15 min oder ohne Ablauf) nach dem Aufraeumen noch da" % len(ids))
elif a == "counts":
    now = int(time.time())
    c = ro(sys.argv[2])
    try:
        q = lambda s, *x: c.execute(s, x).fetchone()[0]
        print("events %d (aktiv %d, abgelaufen in Historie %d, aeltester Ablauf vor %s Tagen), mesh_log %d, telemetry %d (aelteste vor %s h)" % (
            q("SELECT COUNT(*) FROM events"), q("SELECT COUNT(*) FROM events WHERE expires IS NULL OR expires >= ?", now),
            q("SELECT COUNT(*) FROM events WHERE expires < ?", now),
            ("%.1f" % ((now - q("SELECT MIN(expires) FROM events WHERE expires < ?", now)) / 86400.0)) if q("SELECT COUNT(*) FROM events WHERE expires < ?", now) else "–",
            q("SELECT COUNT(*) FROM mesh_log"), q("SELECT COUNT(*) FROM telemetry"),
            ("%.1f" % ((now - q("SELECT MIN(ts) FROM telemetry")) / 3600.0)) if q("SELECT COUNT(*) FROM telemetry") else "–"))
    finally:
        c.close()
elif a == "live":
    d = json.load(open(sys.argv[2]))
    r = ((d.get("db") or {}).get("retention")) or {}
    assert r.get("alive") is True and r.get("every_s") == 600 and r.get("keep_events_after_expiry_s") == 7 * 86400, r
    assert all("expired" in h for h in d.get("history") or []), "history ohne expired"
    print("Aufraeum-Faden laeuft (alle %d s, Zusatz %s, Laeufe %s); /api/sdr/live Historie: %d Eintraege, davon %d abgelaufen markiert" % (
        r["every_s"], ",".join(r.get("extra") or []) or "–", r.get("n"), len(d.get("history") or []), sum(1 for h in d.get("history") or [] if h.get("expired"))))
elif a == "first":
    d = json.load(open(sys.argv[2]))
    r = ((d.get("db") or {}).get("retention")) or {}
    f = r.get("first") or r.get("last")
    assert f, "noch kein Lauf"
    print("Lauf %s um %s: %s" % (r.get("n"), ft(f.get("t") or r.get("t")), ", ".join("%s %s" % (k, f.get(k)) for k in ("events", "mesh_log", "telemetry", "mesh_auto", "asa_rx", "mesh_queue", "geo_cache") if k in f)))
elif a == "t2":
    d = json.load(open(sys.argv[2]))
    to = d.get("takeover") or {}
    assert d.get("ok") and "end_t" in to and "why_txt" in to, to
    print("/api/t2/status: Uebernahme %s" % (("AN seit %s" % ft(to.get("since"))) if to.get("on") else ("aus seit %s" % ft(to.get("end_t")) if to.get("end_t") else "aus")))
elif a == "t4":
    d = json.load(open(sys.argv[2]))
    h = d.get("hist") or []
    assert all("exp" in x for x in h), "hist ohne exp"
    s2 = (d.get("sdr") or {}).get("s2") or {}
    assert s2.get("takeover") or "off_t" in s2, s2
    print("/api/t4/status: Ereignis-Historie %d Zeilen, davon %d abgelaufen markiert; SDR 2 %s" % (len(h), sum(1 for x in h if x.get("exp")), s2.get("state")))
elif a == "takeover":
    try:
        d = json.load(open(sys.argv[2] + "/sdr_takeover.json"))
    except Exception as e:
        print("  sdr_takeover.json nicht lesbar: %s" % e); raise SystemExit(0)
    w = str(d.get("why") or "")
    wt = w.replace("Knopf auf der Lage-Seite", "Knopf (damals auf der Lage-Seite, jetzt Funk-Seite)")
    if d.get("on"):
        print("  jetzt: AN (Stick 2 fest auf 5C) seit %s, Quelle %s, Grund %s, von %s" % (ft(d.get("since")), d.get("src"), wt or "–", d.get("by")))
    else:
        print("  jetzt: aus seit %s (von %s); letzte Uebernahme %s bis %s, Quelle %s, Grund %s" % (ft(d.get("off_t")), d.get("off_by") or "–", ft(d.get("since")), ft(d.get("off_t")),
                                                                                            d.get("src") or "–", wt or "–"))
    for x in (d.get("hist") or [])[-6:]:
        print("  %s %s, Quelle %s%s, von %s" % (ft(x.get("t")), "AN" if x.get("on") else "aus", x.get("src"), (", Grund " + str(x.get("why")).replace(
            "Knopf auf der Lage-Seite", "Knopf (damals auf der Lage-Seite, jetzt Funk-Seite)")) if x.get("why") else "", x.get("by")))
SQC_EOF
P="$W/patch-sqla.py"; ED="$W/edits.py"; BDB="$W/db_block.py"; BSM="$W/sm_block.py"; BDA="$W/dash_block.py"; SG="$W/guard_sqla.py"; CK="$W/sqlacheck.py"
for x in "$EXPECT_P $P" "$EXPECT_E $ED" "$EXPECT_BDB $BDB" "$EXPECT_BSM $BSM" "$EXPECT_BDA $BDA" "$EXPECT_G $SG" "$EXPECT_C $CK"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || echo "neu, Erkennung ueber Guards"; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "kartevec"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "kartevec"))"
echo "Basis database.py sha16 $DB16 ($(wc -l < "$DBF") Zeilen, $(kn "$DB16" "$KNOWN_DB16" "Teil 2/3"))"
echo "prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "tiiFix2")) - bleibt unveraendert"
echo "mesh_router.py sha16 $MR16 ($(wc -l < "$MR") Zeilen, $(kn "$MR16" "$KNOWN_MR16" "Teil 3")) - bleibt unveraendert"
echo "lagegeo.py sha16 $LG16 - bleibt unveraendert"
grep -q '# ===== kartevec:' "$F" || { echo "STOP: kartevec fehlt in dashboard.py - bitte zuerst apply-kartevec.sh, nichts geaendert"; exit 1; }
grep -q 'def selftest_kv' "$SMF" || { echo "STOP: kartevec fehlt in sdr_manager.py - nichts geaendert"; exit 1; }
grep -q 'def cleanup_t3' "$DBF" || { echo "STOP: Teil 3 fehlt in database.py - nichts geaendert"; exit 1; }
python3 "$P" db "$DBF" "$W/work/database.py" "$BDB" "$ED" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: database.py unbekannte Basis (sha16 $DB16) - nichts geaendert"; exit 1; }
python3 "$P" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" "$ED" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: sdr_manager.py unbekannte Basis (sha16 $SM16) - nichts geaendert"; exit 1; }
python3 "$P" dash "$F" "$W/work/dashboard.py" "$BDA" "$ED" > "$W/p3.log" || { cat "$W/p3.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: $(cat "$W/p1.log"); $(cat "$W/p2.log"); $(cat "$W/p3.log")"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
for k in "db database $BDB" "sm sdr_manager $BSM" "dash dashboard $BDA"; do set -- $k
  python3 "$P" "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$ED" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/database.py" "$W/work/sdr_manager.py" "$W/work/dashboard.py"; do
    "$py" -W error -m py_compile "$x" || { echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp "$W/work/database.py" "$W/work/sdr_manager.py" "$MR" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 120 "$py" database.py > "$W/dbt.log" 2>&1) || { tail -12 "$W/dbt.log"; echo "STOP: Selbsttest database ($py) - nichts geaendert"; exit 1; }
  for k in "database selftest ok" "database selftest Teil 2 ok" "database selftest Teil 3 ok" "database selftest sqlA ok"; do
    grep -qF "$k" "$W/dbt.log" || { echo "STOP: Selbsttest database ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && timeout 180 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlA ok"; do
    grep -qF "$k" "$W/smt.log" || { echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttests mit $SPY und $VPY (Sandbox, Test-DB, nichts gesendet): $(grep 'selftest sqlA' "$W/dbt.log" | cut -c1-200)"
echo "OK $(grep 'selftest sqlA' "$W/smt.log" | cut -c1-220)"
python3 "$SG" "$ED" db "$DBF" "$W/work/database.py" "$BDB" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" dash "$F" "$W/work/dashboard.py" "$BDA" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
if command -v node >/dev/null 2>&1; then
  python3 - "$W/work/dashboard.py" "$W" << 'JSPY' || { echo "STOP: JavaScript fehlerhaft - nichts geaendert"; exit 1; }
import ast, subprocess, sys
for n in ast.parse(open(sys.argv[1], encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("_T2D_JS", "_T4_JS") and isinstance(n.value, ast.Constant):
        f = "%s/%s.js" % (sys.argv[2], n.targets[0].id)
        open(f, "w", encoding="utf-8").write(n.value.value)
        if subprocess.run(["node", "--check", f]).returncode:
            raise SystemExit(1)
JSPY
  echo "OK JavaScript (Sticks-Kachel, SDR-Kachel) syntaktisch geprueft (node)"
fi
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
NACT=""; [[ -f "$LZ" ]] && NACT=$(python3 "$CK" active "$LZ" "$W/active.json" 2>/dev/null || true)
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
ALL=("$DBF" "$SMF" "$F")
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/database.py" "$DBF"; then
  echo "OK sqlA schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sqlA|lagezentrum.db|Traceback|Error" | tail -8 | cut -c1-200 || true
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sqla-$TS" ]] && cp -a "$x.bak-sqla-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 60); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-sqla-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  lagezentrum.db bleibt (kein Schema geaendert; Sicherung von vorher: $LZ.bak-sqla-$TS)"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-sqla-$TS"
    { ls -1t "$x.bak-sqla-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sqla-$TS" \
      || { rm -f "$LZ.bak-sqla-$TS"; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sqla-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "database $DBF" "sdr_manager $SMF" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sqla-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-dashboard (prepper-sdr laeuft weiter, Sticks unberuehrt) - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /dabhist /api/sdr/live /api/sdr/map /api/t2/status /api/t4/status /api/t4/tii; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
c=$(code -X POST "$B/api/t2/stick2" -H 'Content-Type: application/json' -d '{"action":"alarm","confirm":true}'); [[ "$c" == 403 ]] && echo "OK Stick-2-Knopf ohne Funk-Seite abgewiesen ($c, nichts geschaltet)" || rbx "/api/t2/stick2 ohne Pruefung ($c)"
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
python3 "$CK" live "$W/live.json" > "$W/live.log" 2>&1 && echo "OK $(cat "$W/live.log")" || { cat "$W/live.log"; rbx "Aufraeum-Faden laeuft nicht / /api/sdr/live ohne Markierung"; }
"${CURL[@]}" "$B/api/t2/status" -o "$W/t2.json" || true
python3 "$CK" t2 "$W/t2.json" > "$W/t2.log" 2>&1 && echo "OK $(cat "$W/t2.log")" || { cat "$W/t2.log"; rbx "/api/t2/status ohne Anzeige-Felder"; }
"${CURL[@]}" "$B/api/t4/status" -o "$W/t4.json" || true
python3 "$CK" t4 "$W/t4.json" > "$W/t4.log" 2>&1 && echo "OK $(cat "$W/t4.log")" || { cat "$W/t4.log"; rbx "/api/t4/status ohne Markierung"; }
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
grep -q "Übernahme aus seit '+fmt(to.end_t)" "$W/funk.html" && grep -q "Übernahme aus seit '+fmt(s2.off_t)" "$W/funk.html" && echo "OK /funk: Sticks- und SDR-Kachel zeigen aus seit Ende der Uebernahme" || rbx "/funk ohne neue Stick-2-Anzeige"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
L1=$(python3 -c "
import sys; s=open(sys.argv[1],encoding='utf-8',errors='replace').read(); i=s.rfind('doPrepperRestore'); print('ja' if i>=0 and s.find('class=\"tile', i) < 0 and s.find('class=\"card', i) < 0 else 'nein')" "$W/pi.html" 2>/dev/null || echo nein)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x), letzte Kachel: $L1" || rbx "/pi Sicherung veraendert ($R0/$R1)"
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(sqlA|kartevec|teil[234]) (aktiv|FEHLER)" | tail -10 || true)
if [[ "$JD" == *"FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2)"; fi
if [[ "$JD" == *"sqlA aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'sqlA aktiv' | tail -1 | cut -c1-230)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet sqlA nicht (Journal)"; fi
# erster Lauf des Aufraeum-Fadens (30 s nach dem Start)
FR=""
for i in $(seq 1 30); do
  FR=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "lagezentrum.db Aufraeumen \(Faden, Lauf [0-9]+\)" | head -1 || true)
  [[ -n "$FR" ]] && break; sleep 4
done
if [[ -n "$FR" ]]; then echo "OK erster Aufraeum-Lauf: $(echo "$FR" | cut -c1-230)"; else
  "${CURL[@]}" "$B/api/sdr/live" -o "$W/live2.json" || true
  FR=$(python3 "$CK" first "$W/live2.json" 2>/dev/null || true)
  [[ -n "$FR" ]] && echo "OK Aufraeum-Lauf (aus /api/sdr/live): $FR" || rbx "kein Aufraeum-Lauf innerhalb 2 min"
fi
[[ -f "$LZ" && -f "$W/active.json" ]] && { python3 "$CK" still "$LZ" "$W/active.json" > "$W/still.log" 2>&1 && echo "OK $(cat "$W/still.log")" || rbx "$(cat "$W/still.log")"; }
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sqlA FEHLER|Aufraeumen \(Faden\) Fehler|database is locked" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sqlA-Fehler/database is locked" || rbx "$E Traceback/sqlA-Fehlerzeilen im Journal Dashboard"
[[ "$(s16 "$M")" == "$SDR16" ]] && echo "OK prepper_sdr.py unveraendert ($SDR16)" || rbx "prepper_sdr.py hat sich veraendert"
[[ "$(s16 "$MR")" == "$MR16" ]] && echo "OK mesh_router.py unveraendert ($MR16)" || rbx "mesh_router.py hat sich veraendert"
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
echo "OK guards sqlA(dash)=$(grep -c '# ===== sqlA:' "$F" || true) kartevec(dash)=$(grep -c '# ===== kartevec:' "$F" || true) teil4(dash)=$(grep -c '# ===== teil4:' "$F" || true) teil2(dash)=$(grep -c '# ===== teil2:' "$F" || true) sqlA(sdr_manager)=$(grep -c '# ---------------------------------------------------------------- sqlA' "$SMF" || true) kartevec(sdr_manager)=$(grep -c '# ---------------------------------------------------------------- kartevec' "$SMF" || true) sqlA(database)=$(grep -c '# ---------------------------------------------------------------- sqlA' "$DBF" || true) Teil3(database)=$(grep -c 'def cleanup_t3' "$DBF" || true) tiiFix2(sdr)=$(grep -c '# tiiFix2' "$M" || true)"
[[ -f "$F.bak-sqla-$TS" ]] && echo "Backups: *.bak-sqla-$TS (database.py, sdr_manager.py, dashboard.py, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG sqla=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, sqlA bleibt aktiv. COMMIT $COMMIT_ARG sqla=1"; exit 0' INT
echo "Stick 2 / Uebernahme (nur lesen, nichts geaendert):"
python3 "$CK" takeover "$DASH_DIR" || true
echo "COMMIT $COMMIT_ARG sqla=1 fertig"
