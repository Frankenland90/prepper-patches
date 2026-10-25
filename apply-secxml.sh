#!/bin/bash
set -eEuo pipefail
# secXml (commit31x): SEC-10/SEC-11 + Alarm-Speicher. Entscheidungen Frank (t806u): (1) defusedxml JA (gepinnt, Hash, im venv des Projekts), XML-Grenze fest 2 MiB; (2) Alarmpfad der Datenbank mit synchronous=FULL.
#  - defusedxml 0.7.1 (Rad von PyPI, 25604 Bytes, sha256 a352e7e4...) ist EINGEBETTET und wird offline per pip --no-index --no-deps --require-hashes ins venv installiert (kein Netz, kein neuer Anbieter, kein Konto).
#  - lage_xml.py (neu gefasst): Grenze fest 2 MiB (nur verkleinerbar), Gesamtzeit je Abruf, defusedxml (Entities/extern abgelehnt, DTD erlaubt), ratenbegrenzte Journalmeldung je Quelle, Status. Wirkt erst, wenn dashboard.py es aufruft (Folgepatch, siehe REPORT).
#  - database.py: connect(path, sync=None); FULL nur fuer Alarm-Warteschlange (q_add, q_set), Dublettensperre (mesh_seen, mesh_log_put), Auto-Versuche (mesh_auto_reserve, mesh_auto_done) und Ereignisse mit Stufe ungleich info; Rest WAL + NORMAL wie bisher. Sichtbar in /api/sdr/live (db.retention.alarm_sync).
#  - tools/lage_reqs.py (Pin-Pruefung), requirements.txt.vorlage (echter Pin), requirements-defusedxml.txt (benutzbar, neu).
# NICHT angefasst: dashboard.py, Bridges, mesh_router.py, prepper_sdr.py, sdr_manager.py, Konfiguration, Firewall/rpcbind. Nichts wird gesendet (kein Mesh, kein Telegram, kein Alarm), keine Rotation, keine neuen Konten/Schluessel.
# Basis streng (sha16): database.py 01f7abf0c13b7acd (= Ergebnis relClock/commit25b), lage_xml.py c4db8c5c070afc3f, tools/lage_reqs.py a6bf962c0a3abdd8, requirements.txt.vorlage e6bb839311fc2502 (= commit24) - oder schon die neue Fassung (idempotent). Anderes = STOP mit Diff.
# Neustart: nur prepper-dashboard (laedt database.py). prepper-sdr laedt die neue database.py erst bei seinem naechsten Neustart (wird hier bewusst NICHT neu gestartet).
# Sicherungen: jede ersetzte Datei *.bak-secxml-ZEIT (letzte 3), SQLite-Sicherung (letzte 3). Option "trocken": nur pruefen/testen, nichts aendern.
COMMIT_ARG="${1:-unbekannt}"
OPT="${2:-}"
NAME=secxml
DASH_DIR="/home/fmg/prepper-dashboard"
SPY=/usr/bin/python3
if [[ "${SYSTEM_TEST:-}" == 1 ]]; then DASH_DIR="${SY_DASH:?}"; fi    # nur fuer den Sandbox-Test dieses Skripts
VPY="$DASH_DIR/venv/bin/python"
DBF="$DASH_DIR/database.py"
XMLF="$DASH_DIR/lage_xml.py"
TOOLD="$DASH_DIR/tools"
REQF="$TOOLD/lage_reqs.py"
VORF="$DASH_DIR/requirements.txt.vorlage"
RDXF="$DASH_DIR/requirements-defusedxml.txt"
LZ="$DASH_DIR/lagezentrum.db"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/secxml-apply
KEEP_LAST=3
PIN_VER="0.7.1"
PIN_WHL="defusedxml-0.7.1-py2.py3-none-any.whl"
PIN_SHA="a352e7e428770286cc899e2542b6cdaedb2b4953ff269a210103ec58f6198a61"
PIN_SIZE=25604
PRE_RELDB16="431077d36822a090"
OLD_RELDB16="3f3aa054076bf70b"
KNOWN_DB16="01f7abf0c13b7acd"
NEW_DB16="e7a7ef192c522480"
KNOWN_XML16="c4db8c5c070afc3f"
NEW_XML16="f77305fc17ed2f77"
KNOWN_REQ16="a6bf962c0a3abdd8"
NEW_REQ16="660be03bac621e1b"
KNOWN_VOR16="e6bb839311fc2502"
NEW_VOR16="a2546207159f3466"
NEW_RDX16="d0a3b9431d039c00"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
echo "=== secXml apply ($COMMIT_ARG)${OPT:+ [$OPT]}: defusedxml $PIN_VER (Hash-Pin), lage_xml.py (2 MiB fest), Alarmpfad synchronous=FULL (database.py), Dashboard-Port $PORT ==="
umask 077
rm -rf "$W" && mkdir -p "$W/base" "$W/sbx" "$W/whl" "$W/rq"
EXPECT_DB="e7a7ef192c5224805d850a40f354e71d8aa42b8584c627ff9d8d1b8b62a1dc81"
cat > "$W/database.py" << 'SXM_DB_EOF'
"""database.py - SQLite-Lagezentrum (lagezentrum.db) ZUSAETZLICH zu den JSON-Dateien.

Kaeswasser Lage Monitor, Teil 1. Nur Ablage/Abfrage, keine Netzwerkzugriffe, keine Sendewege.
- WAL-Modus, busy_timeout, eine Verbindung je Aufruf (thread-sicher ohne geteilte Verbindung)
- Schema-Migration idempotent (CREATE IF NOT EXISTS + fehlende Spalten per ALTER TABLE ADD COLUMN)
- jede Funktion faengt Fehler ab und liefert einen sicheren Standardwert (Seiten duerfen nie abstuerzen)

Tabellen:
  events     Lage-Ereignisse (NINA/MoWaS, DAB, ASA, BR24) - ext_id eindeutig (Upsert)
  mesh_log   md5-Hash gesehener Mesh-Texte je Kanal (nur Dublettenpruefung, kein Senden)
  telemetry  DAB-Empfangswerte je Stick/Kanal; 'ber' = FIC-CRC-Fehlerrate als Ersatz fuer die
             Bitfehlerrate (welle-cli liefert keine BER): numcrcerrors / (Messdauer_s * 125 FIB/s, DAB Mode I).
             kind 'dab' = echte Messung, kind 'hb' = Lebenszeichen aus sdr_status.json (Watchdog).
relDb: Wartung der Datenbank im Hintergrund (Checkpoint, quick_check, snapshot), WAL einmal je Prozess und Pfad (siehe Block relDb weiter unten).
relClock: der Aufraeum-Faden loescht nichts, solange lage_clock.clock_ok() die Uhr fuer unplausibel haelt; Dauern/Zeitlimits/owns() in monotonic (siehe Block relClock).
secXml: der Alarmpfad (mesh_queue, mesh_log, mesh_auto, Ereignisse mit Stufe ungleich info) schreibt ueber eine Verbindung mit synchronous=FULL, der Rest bleibt WAL + NORMAL (siehe Block secXml).
"""
import os
import sqlite3
import time

DB_PATH = "/home/fmg/prepper-dashboard/lagezentrum.db"
SCHEMA_VERSION = 1
TIMEOUT_S = 10.0

KEEP_MESH_S = 24 * 3600
KEEP_TELEMETRY_S = 48 * 3600
KEEP_EVENTS_HIST_S = 7 * 86400   # sqlA: abgelaufene Ereignisse bleiben 7 Tage in der Historie (aktiv ist nur expires >= jetzt)

_TABLES = {
    "events": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("source", "TEXT NOT NULL"),          # NINA | DAB | ASA | BR24
        ("type", "TEXT"),                      # z. B. Alert/Update/Cancel, dls, ann, warn
        ("severity", "TEXT"),                  # info | warn | alarm | probe | unknown
        ("headline", "TEXT"),
        ("text", "TEXT"),
        ("lat", "REAL"),
        ("lon", "REAL"),
        ("geojson", "TEXT"),
        ("sent_at", "INTEGER"),
        ("created", "INTEGER"),
        ("updated", "INTEGER"),
        ("expires", "INTEGER"),
        ("is_test", "INTEGER DEFAULT 0"),      # eigene TEST-Knopf-Meldungen -> zaehlen nie
        ("ext_id", "TEXT"),
    ],
    "mesh_log": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("hash", "TEXT NOT NULL"),
        ("channel", "TEXT"),
        ("created", "INTEGER"),
    ],
    "telemetry": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("ts", "INTEGER NOT NULL"),
        ("kind", "TEXT DEFAULT 'dab'"),        # dab | hb
        ("serial", "TEXT"),
        ("channel", "TEXT"),                   # 11D | 5C (hb: Rolle/aktiv)
        ("snr", "REAL"),
        ("ber", "REAL"),                       # FIC-CRC-Fehlerrate (siehe oben)
        ("fic_err", "INTEGER"),
        ("secs", "REAL"),
        ("ensemble", "TEXT"),
        ("mast", "TEXT"),                      # Ensemble + Kanal, z. B. "Bayern · 11D"
        ("rssi", "REAL"),                      # nur wenn verfuegbar (welle-cli: nein)
        ("src_t", "INTEGER"),                  # Zeitstempel der Quelle (Dedup)
    ],
}
_INDEXES = (
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_events_ext ON events(ext_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_upd ON events(updated)",
    "CREATE INDEX IF NOT EXISTS ix_events_exp ON events(expires)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_hash ON mesh_log(hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_created ON mesh_log(created)",
    "CREATE INDEX IF NOT EXISTS ix_tel_ts ON telemetry(ts)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_tel_src ON telemetry(kind, serial, channel, src_t)",
)
_migrated = set()
_last_err = [None]


def _log(*a):
    _last_err[0] = " ".join(str(x) for x in a)[:200]
    print("lagezentrum.db:", *a, flush=True)


def last_error():
    return _last_err[0]


class _Con(sqlite3.Connection):
    """sqlA: close() macht vorher explizit rollback(), wenn noch eine Transaktion offen ist (nie halb geschrieben, keine haengende Sperre)."""

    def close(self):
        try:
            if self.in_transaction:
                self.rollback()
        except Exception:
            pass
        super().close()


_wal_done = set()   # relDb (PERF-06): Pfade, fuer die in diesem Prozess journal_mode=WAL schon gesetzt und bestaetigt wurde


def _set_wal(con, path):
    """relDb: journal_mode=WAL steht dauerhaft in der Datei; je Prozess und Pfad genuegt EIN Setzen (migrate() bzw. erste Verbindung)."""
    r = con.execute("PRAGMA journal_mode=WAL").fetchone()
    if r is not None and str(r[0]).lower() == "wal":
        _wal_done.add(path)
        return True
    return False   # z. B. Dateisystem ohne WAL: nicht merken, naechste Verbindung prueft erneut


# ---------------------------------------------------------------- secXml: synchronous=FULL nur fuer den Alarmpfad (Entscheidung Frank, SEC/REL "Alarm-Speicher")
# PRAGMA synchronous gilt je Verbindung. Der Alarmpfad schreibt deshalb ueber eine eigene Verbindung mit FULL (SQLite meldet das Ende der Transaktion erst, wenn WAL
# und Datei physisch auf dem Datentraeger sind - ein Stromausfall mitten im Alarm verliert keinen bestaetigten Eintrag). Alles andere bleibt wie bisher WAL + NORMAL.
# Alarmpfad = Alarm-Warteschlange mesh_queue (q_add, q_set), Dublettensperre mesh_log (mesh_seen, mesh_log_put), Auto-Versuche mesh_auto (mesh_auto_reserve, mesh_auto_done)
# und Ereignisse, deren Stufe nicht "info" ist (upsert_event: warn, alarm, probe, unknown, fehlende Stufe). Lesen, Telemetrie, DAB-Infos, state, Aufraeumen: NORMAL.
# Kein neuer Ausfall: scheitert die Kontrolle (PRAGMA synchronous liest nicht 2), wird das hoechstens alle 10 min gemeldet und trotzdem geschrieben (Alarm vor Datenschutz).
import sys as _sx_sys

SYNC_NORMAL = "NORMAL"
SYNC_ALARM = "FULL"
_SYNC_CODE = {"NORMAL": 1, "FULL": 2}
_sx_stat = {"full": 0, "normal": 0, "mismatch": 0, "last_err": None}
_sx_log_t = [None]
ALARM_PFAD = "mesh_queue, mesh_log, mesh_auto, Ereignisse mit Stufe ungleich info"


def alarm_event(severity):
    """True, wenn ein Ereignis in den Alarmpfad gehoert (alles ausser ausdruecklich 'info'; fehlende Stufe zaehlt als Alarm = konservativ)."""
    return str("" if severity is None else severity).strip().lower() != "info"


def _sync_pick(sync):
    """None/'NORMAL' -> NORMAL; alles andere (auch Unbekanntes) -> FULL, nie eine Abschwaechung durch Tippfehler."""
    s = SYNC_NORMAL if sync is None else str(sync).strip().upper()
    return SYNC_NORMAL if s == SYNC_NORMAL else SYNC_ALARM


def _sync_apply(con, want):
    """PRAGMA synchronous setzen; bei FULL den Wert zurueckpruefen (Abweichung: zaehlen, ratenbegrenzt melden, trotzdem weiterarbeiten)."""
    con.execute("PRAGMA synchronous=%s" % want)
    if want == SYNC_NORMAL:
        _sx_stat["normal"] += 1
        return
    _sx_stat["full"] += 1
    try:
        r = con.execute("PRAGMA synchronous").fetchone()
        got = None if r is None else int(r[0])
    except Exception as e:
        got = None
        _sx_stat["last_err"] = ("Rueckpruefung: %s" % e)[:120]
    if got != _SYNC_CODE[SYNC_ALARM]:
        _sx_stat["mismatch"] += 1
        if _sx_stat["last_err"] is None or got is not None:
            _sx_stat["last_err"] = ("synchronous=FULL nicht bestaetigt (gelesen: %s)" % got)[:120]
        now = time.monotonic()
        if _sx_log_t[0] is None or now - _sx_log_t[0] >= 600:
            _sx_log_t[0] = now
            _log("secXml: synchronous=FULL fuer den Alarmpfad nicht bestaetigt (gelesen: %s) - es wird trotzdem geschrieben" % got)


def sync_status():
    """Fuer /api/sdr/live (retention.alarm_sync): Soll, ob bestaetigt, Zaehler seit Prozessstart."""
    return {"soll": SYNC_ALARM, "aktiv": _sx_stat["mismatch"] == 0, "voll": _sx_stat["full"], "normal": _sx_stat["normal"],
            "abweichungen": _sx_stat["mismatch"], "letzter_fehler": _sx_stat["last_err"], "pfad": ALARM_PFAD}


print("lagezentrum.db: secXml aktiv - Alarmpfad (%s) schreibt mit synchronous=%s, alles andere NORMAL" % (ALARM_PFAD, SYNC_ALARM), file=_sx_sys.stderr, flush=True)


def selftest_sync():
    import tempfile
    global connect
    real = connect
    seen = []

    def rec(path=None, sync=None):
        seen.append(_sync_pick(sync))
        return real(path, sync)

    d = tempfile.mkdtemp(prefix="lzsx-")
    p = os.path.join(d, "s.db")
    try:
        assert migrate(p) and migrate_t2(p) and migrate_t3(p)
        # 1. Das PRAGMA wirkt wirklich je Verbindung (1 = NORMAL, 2 = FULL); Unbekanntes wird nie abgeschwaecht
        for arg, want in ((None, 1), ("NORMAL", 1), ("FULL", 2), ("full", 2), ("unsinn", 2), ("OFF", 2)):
            c = real(p, arg)
            try:
                assert c.execute("PRAGMA synchronous").fetchone()[0] == want, (arg, want)
                assert str(c.execute("PRAGMA journal_mode").fetchone()[0]).lower() == "wal"
            finally:
                c.close()
        # 2. Welche Funktion nimmt welche Verbindung (genau eine Verbindung je Aufruf)
        connect = rec
        now = int(time.time())

        def kind(fn, *a, **k):
            del seen[:]
            r = fn(*a, **k)
            return r, list(seen)

        full = [
            ("mesh_seen", lambda: mesh_seen("h1", "m1:0", p, now)),
            ("mesh_log_put", lambda: mesh_log_put("h2", "m1:0", now, "NINA", "t", True, "nina", p)),
            ("mesh_auto_reserve", lambda: mesh_auto_reserve("A1", "h3", "ASA", "t", now, p)),
            ("mesh_auto_done", lambda: mesh_auto_done("A1", True, p)),
            ("q_add", lambda: q_add("m1", "nina", "t", "h4", now, now, None, None, p)),
            ("upsert_event warn", lambda: upsert_event({"source": "NINA", "ext_id": "w1", "severity": "warn", "headline": "w"}, p)),
            ("upsert_event alarm", lambda: upsert_event({"source": "ASA", "ext_id": "a1", "severity": "alarm", "headline": "a"}, p)),
            ("upsert_event ohne Stufe", lambda: upsert_event({"source": "BR24", "ext_id": "n1", "headline": "n"}, p)),
            ("upsert_event probe", lambda: upsert_event({"source": "ASA", "ext_id": "p1", "severity": "probe", "headline": "p"}, p)),
        ]
        for name, fn in full:
            r, s = kind(fn)
            assert s == ["FULL"], (name, s)
            assert r is not None, (name, r)
        qid = q_add("m1", "nina", "t", "h5", now, now, None, None, p)
        r, s = kind(q_set, qid, p, state="ok", done=now)
        assert r is True and s == ["FULL"], ("q_set", r, s)
        normal = [
            ("upsert_event info", lambda: upsert_event({"source": "DAB", "ext_id": "i1", "severity": "info", "headline": "i"}, p)),
            ("insert_telemetry", lambda: insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 1.0, "src_t": now}, p)),
            ("mesh_known", lambda: mesh_known("h1", p)),
            ("mesh_hash_since", lambda: mesh_hash_since("h1", now - 60, p)),
            ("mesh_auto_get", lambda: mesh_auto_get("A1", p)),
            ("mesh_auto_count", lambda: mesh_auto_count(now - 60, p)),
            ("q_open", lambda: q_open("m1", p)),
            ("q_get", lambda: q_get(qid, p)),
            ("mesh_count_since", lambda: mesh_count_since("m1:0", ("nina",), now - 60, p)),
            ("state_put", lambda: state_put("k", "{}", None, p)),
            ("cleanup", lambda: cleanup(now, p)),
            ("cleanup_t3", lambda: cleanup_t3(now, p)),
        ]
        for name, fn in normal:
            r, s = kind(fn)
            assert s and set(s) == {"NORMAL"}, (name, s)
        # 3. Verhalten unveraendert: Dublette, Reservierung, Warteschlange
        assert mesh_seen("h1", "m1:0", p, now) is True and mesh_seen("neu-h", "m1:0", p, now) is False
        assert mesh_auto_reserve("A1", "h3", "ASA", "t", now, p) is None and mesh_auto_get("A1", p)["ok"] == 1
        assert q_get(qid, p)["state"] == "ok" and q_add("m1", "nina", "t", "h5", now, now, None, None, p) == qid
    finally:
        connect = real
        for f in os.listdir(d):
            try:
                os.unlink(os.path.join(d, f))
            except OSError:
                pass
        try:
            os.rmdir(d)
        except OSError:
            pass
    # 4. Abweichung bei der Rueckpruefung: gezaehlt, nicht geworfen
    class _R:
        def __init__(self, v):
            self.v = v

        def fetchone(self):
            return (self.v,)

    class _C:
        def __init__(self, v):
            self.v = v

        def execute(self, sql):
            return _R(self.v)

    saved = dict(_sx_stat)
    t_saved = _sx_log_t[0]
    try:
        _sx_stat.update(full=0, normal=0, mismatch=0, last_err=None)
        _sync_apply(_C(2), SYNC_ALARM)
        assert sync_status()["aktiv"] is True and sync_status()["voll"] == 1
        import contextlib
        import io
        _sx_log_t[0] = None
        o1 = io.StringIO()
        with contextlib.redirect_stdout(o1):
            _sync_apply(_C(1), SYNC_ALARM)                     # Abweichung -> zaehlen, kein Wurf, erste Meldung kommt
        assert "secXml: synchronous=FULL" in o1.getvalue(), o1.getvalue()
        o2 = io.StringIO()
        with contextlib.redirect_stdout(o2):
            _sync_apply(_C(1), SYNC_ALARM)                     # zweite Abweichung: ratenbegrenzt, keine neue Zeile
        assert o2.getvalue() == "", o2.getvalue()
        st = sync_status()
        assert st["aktiv"] is False and st["abweichungen"] == 2 and "nicht bestaetigt" in st["letzter_fehler"], st
        _sync_apply(_C(1), SYNC_NORMAL)
        assert sync_status()["normal"] == 1 and sync_status()["soll"] == "FULL"
    finally:
        _sx_stat.update(saved)
        _sx_log_t[0] = t_saved
    assert alarm_event("warn") and alarm_event("ALARM") and alarm_event(None) and alarm_event("") and alarm_event("unknown") and not alarm_event("info") and not alarm_event(" Info ")
    return "database selftest secXml ok (Alarmpfad FULL: %d Schreibwege, Rest NORMAL: %d, Rueckpruefung, Abweichung wird gezaehlt statt geworfen)" % (len(full) + 1, len(normal))


def connect(path=None, sync=None):
    """Neue Verbindung (je Aufruf). busy_timeout, synchronous, Row-Zugriff per Name; WAL nur einmal je Prozess/Pfad (relDb). sqlA: rollback vor close; Fehler in den PRAGMAs -> sofort schliessen.
    secXml: sync=None -> synchronous=NORMAL wie bisher; sync=SYNC_ALARM (FULL) nur fuer den Alarmpfad (je Verbindung, mit Rueckpruefung)."""
    p = path or DB_PATH
    con = sqlite3.connect(p, timeout=TIMEOUT_S, factory=_Con)
    try:
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))
        if p not in _wal_done:
            _set_wal(con, p)
        _sync_apply(con, _sync_pick(sync))   # secXml: NORMAL wie bisher, FULL nur auf Anforderung des Alarmpfads
    except Exception:
        con.close()
        raise
    return con


def migrate(path=None):
    """Schema anlegen/ergaenzen (idempotent). Setzt journal_mode=WAL (relDb: hier, nicht mehr bei jeder Verbindung). -> True/False"""
    path = path or DB_PATH
    try:
        _wal_done.discard(path)   # relDb: connect() unten setzt WAL neu und merkt es sich
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        con = connect(path)
        try:
            with con:
                con.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
                for tb, cols in _TABLES.items():
                    con.execute("CREATE TABLE IF NOT EXISTS %s (%s)" % (tb, ", ".join("%s %s" % c for c in cols)))
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ.replace("PRIMARY KEY AUTOINCREMENT", "").replace("NOT NULL", "")))
                for sql in _INDEXES:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_version', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (str(SCHEMA_VERSION),))
        finally:
            con.close()
        _migrated.add(path)
        return True
    except Exception as e:
        _log("Migration:", e)
        return False


def _ensure(path):
    path = path or DB_PATH
    if path not in _migrated:
        migrate(path)
    return path


def upsert_event(ev, path=None):
    """Ereignis anlegen oder (gleiche ext_id) aktualisieren. -> True/False"""
    path = _ensure(path)
    try:
        now = int(time.time())
        row = {k: ev.get(k) for k in ("source", "type", "severity", "headline", "text", "lat", "lon", "geojson", "sent_at", "created", "updated", "expires", "is_test", "ext_id")}
        if not row["ext_id"] or not row["source"]:
            return False
        row["created"] = int(row["created"] or now)
        row["updated"] = int(row["updated"] or row["created"])
        row["is_test"] = 1 if row["is_test"] else 0
        for k in ("headline", "text"):
            if row[k] is not None:
                row[k] = str(row[k])[:2000]
        con = connect(path, SYNC_ALARM if alarm_event(row["severity"]) else None)   # secXml: Ereignis mit Stufe ungleich info = Alarmpfad; info (z. B. DAB-Texte) bleibt NORMAL
        try:
            with con:
                con.execute(
                    "INSERT INTO events(source,type,severity,headline,text,lat,lon,geojson,sent_at,created,updated,expires,is_test,ext_id) "
                    "VALUES(:source,:type,:severity,:headline,:text,:lat,:lon,:geojson,:sent_at,:created,:updated,:expires,:is_test,:ext_id) "
                    "ON CONFLICT(ext_id) DO UPDATE SET updated=MAX(COALESCE(events.updated,0), COALESCE(excluded.updated,0)), "
                    "expires=CASE WHEN excluded.expires IS NULL THEN events.expires ELSE MAX(COALESCE(events.expires,0), excluded.expires) END, "
                    "severity=COALESCE(excluded.severity, events.severity), text=COALESCE(excluded.text, events.text), "
                    "headline=COALESCE(excluded.headline, events.headline), type=COALESCE(excluded.type, events.type), "
                    "lat=COALESCE(excluded.lat, events.lat), lon=COALESCE(excluded.lon, events.lon), geojson=COALESCE(excluded.geojson, events.geojson)", row)
        finally:
            con.close()
        return True
    except Exception as e:
        _log("Ereignis:", e)
        return False


def insert_telemetry(t, path=None):
    """Telemetrie-Zeile (gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    path = _ensure(path)
    try:
        row = {k: t.get(k) for k in ("ts", "kind", "serial", "channel", "snr", "ber", "fic_err", "secs", "ensemble", "mast", "rssi", "src_t")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        row["kind"] = row["kind"] or "dab"
        row["src_t"] = int(row["src_t"] if isinstance(row["src_t"], (int, float)) else row["ts"])
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,snr,ber,fic_err,secs,ensemble,mast,rssi,src_t) "
                                  "VALUES(:ts,:kind,:serial,:channel,:snr,:ber,:fic_err,:secs,:ensemble,:mast,:rssi,:src_t)", row)
                return cur.rowcount > 0
        finally:
            con.close()
    except Exception as e:
        _log("Telemetrie:", e)
        return False


def mesh_seen(hash_hex, channel=None, path=None, now=None):
    """Hash merken; True wenn er schon bekannt war (Dublette). Fehler -> None (Aufrufer entscheidet)."""
    path = _ensure(path)
    try:
        con = connect(path, SYNC_ALARM)   # secXml: Dublettensperre = Alarmpfad
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_log(hash, channel, created) VALUES(?,?,?)", (str(hash_hex), channel, int(now or time.time())))
                return cur.rowcount == 0
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_known(hash_hex, path=None):
    """Nur pruefen, nicht merken. -> True/False/None(Fehler)"""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return con.execute("SELECT 1 FROM mesh_log WHERE hash=?", (str(hash_hex),)).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def _rows(sql, args=(), path=None):
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return [dict(r) for r in con.execute(sql, args).fetchall()]
        finally:
            con.close()
    except Exception as e:
        _log("Abfrage:", e)
        return []


def recent_events(n=10, path=None, include_test=False):
    return _rows("SELECT * FROM events %s ORDER BY COALESCE(updated, created) DESC, id DESC LIMIT ?" % ("" if include_test else "WHERE COALESCE(is_test,0)=0"),
                 (int(n),), path)


def active_events(now=None, path=None, since_s=None):
    now = int(now or time.time())
    q = "SELECT * FROM events WHERE COALESCE(is_test,0)=0 AND (expires IS NULL OR expires >= ?)"
    a = [now]
    if since_s:
        q += " AND COALESCE(updated, created) >= ?"
        a.append(now - int(since_s))
    return _rows(q + " ORDER BY COALESCE(updated, created) DESC LIMIT 500", tuple(a), path)


def newest_telemetry(kind=None, path=None):
    r = _rows("SELECT * FROM telemetry %s ORDER BY ts DESC, id DESC LIMIT 1" % ("WHERE kind=?" if kind else ""), (kind,) if kind else (), path)
    return r[0] if r else None


def telemetry_latest_per_channel(path=None):
    return _rows("SELECT t.* FROM telemetry t JOIN (SELECT channel, MAX(ts) m FROM telemetry WHERE kind='dab' GROUP BY channel) x "
                 "ON t.channel=x.channel AND t.ts=x.m WHERE t.kind='dab' ORDER BY t.ts DESC", (), path)


def cleanup(now=None, path=None):
    """Ereignisse 7 Tage nach Ablauf (sqlA), mesh_log > 24 h, Telemetrie > 48 h loeschen (Epoch-Sekunden). -> {tabelle: anzahl}"""
    path = _ensure(path)
    now = int(now or time.time())
    out = {}
    try:
        con = connect(path)
        try:
            with con:
                out["events"] = con.execute("DELETE FROM events WHERE expires IS NOT NULL AND expires < ?", (now - KEEP_EVENTS_HIST_S,)).rowcount
                out["mesh_log"] = con.execute("DELETE FROM mesh_log WHERE created < ?", (now - KEEP_MESH_S,)).rowcount
                out["telemetry"] = con.execute("DELETE FROM telemetry WHERE ts < ?", (now - KEEP_TELEMETRY_S,)).rowcount
        finally:
            con.close()
    except Exception as e:
        _log("Aufraeumen:", e)
    return out


def counts(path=None):
    out = {}
    for tb in _TABLES:
        r = _rows("SELECT COUNT(*) n FROM %s" % tb, (), path)
        out[tb] = r[0]["n"] if r else None
    return out


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "t.db")
    assert migrate(p) and migrate(p)  # idempotent
    con = connect(p)
    assert con.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    con.close()
    now = int(time.time())
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a", "expires": now + 60, "created": now - 10}, p)
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a2", "expires": now + 120, "updated": now}, p)
    ev = recent_events(5, p)
    assert len(ev) == 1 and ev[0]["headline"] == "a2" and ev[0]["expires"] == now + 120 and ev[0]["created"] == now - 10, ev
    assert upsert_event({"source": "BR24", "ext_id": "old", "expires": now - KEEP_EVENTS_HIST_S - 5}, p)
    assert upsert_event({"source": "BR24", "ext_id": "t", "is_test": True}, p) and len(recent_events(9, p)) == 2
    assert insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert not insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert insert_telemetry({"ts": now - 3 * 86400, "serial": "1", "channel": "5C", "src_t": now - 3 * 86400}, p)
    assert newest_telemetry(path=p)["snr"] == 12.5 and telemetry_latest_per_channel(p)[0]["channel"] == "11D"
    assert mesh_seen("h", "0", p, now - 2 * 86400) is False and mesh_seen("h", "0", p) is True and mesh_known("zz", p) is False
    c = cleanup(now, p)
    assert c == {"events": 1, "mesh_log": 1, "telemetry": 1}, c
    assert counts(p) == {"events": 2, "mesh_log": 0, "telemetry": 1}, counts(p)
    assert recent_events(5, "/proc/nicht/schreibbar/x.db") == []  # Fehler -> leer, kein Absturz
    return "database selftest ok"


# ---------------------------------------------------------------- Teil 2 (SDR-Steuerung, Parser, Resilienz)
# Zusaetzlich, idempotent (migrate_t2): telemetry.tii/ecc/lto/ens_id (kind 'fig' = FIG 0/9 + TII + Ensemble aus welle-cli mux.json),
# mesh_log.src/text/ok/kind (Protokoll des Auto-Versands), Tabelle mesh_auto (eine Meldung je Alarm, 30 Tage) und
# Tabelle asa_rx (Empfangszeitpunkte des ASA-Dienstes auf 5C, 14 Tage). Bestehende Tabellen/Funktionen bleiben unveraendert.
KEEP_MESH_AUTO_S = 30 * 86400
KEEP_ASA_RX_S = 14 * 86400
_T2_ADD = {
    "telemetry": [("tii", "TEXT"), ("ecc", "TEXT"), ("lto", "REAL"), ("ens_id", "TEXT")],
    "mesh_log": [("src", "TEXT"), ("text", "TEXT"), ("ok", "INTEGER"), ("kind", "TEXT")],
}
_T2_SQL = (
    "CREATE TABLE IF NOT EXISTS mesh_auto (id INTEGER PRIMARY KEY AUTOINCREMENT, akey TEXT NOT NULL, hash TEXT, src TEXT, text TEXT, "
    "created INTEGER, last_try INTEGER, tries INTEGER DEFAULT 0, ok INTEGER)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_auto_key ON mesh_auto(akey)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_auto_try ON mesh_auto(last_try)",
    "CREATE TABLE IF NOT EXISTS asa_rx (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, channel TEXT, serial TEXT)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_asa_rx ON asa_rx(channel, ts)",
)
AUTO_RETRY_S = 600            # fehlgeschlagener Auto-Versand fruehestens nach 10 min erneut
AUTO_TRIES_MAX = 3            # hoechstens 3 Versuche je Alarm
_migrated_t2 = set()


def migrate_t2(path=None):
    """Teil-2-Schema ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
        if not migrate(path):
            return False
        con = connect(path)
        try:
            with con:
                for tb, cols in _T2_ADD.items():
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ))
                for sql in _T2_SQL:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_t2', '1') ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        finally:
            con.close()
        _migrated_t2.add(path)
        return True
    except Exception as e:
        _log("Migration Teil 2:", e)
        return False


def _ensure_t2(path):
    path = path or DB_PATH
    if path not in _migrated_t2:
        migrate_t2(path)
    return path


def _exec(sql, args, path, what, sync=None):
    path = _ensure_t2(path)
    try:
        con = connect(path, sync)
        try:
            with con:
                return con.execute(sql, args).rowcount
        finally:
            con.close()
    except Exception as e:
        _log(what, e)
        return None


def _rows_t2(sql, args, path):
    _ensure_t2(path)
    return _rows(sql, args, path)


def insert_fig(t, path=None):
    """FIG 0/9 + TII + Ensemble einer DAB-Pruefung (kind 'fig'; gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    try:
        row = {k: t.get(k) for k in ("ts", "serial", "channel", "ensemble", "mast", "tii", "ecc", "lto", "ens_id")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        return (_exec("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,ensemble,mast,src_t,tii,ecc,lto,ens_id) "
                      "VALUES(:ts,'fig',:serial,:channel,:ensemble,:mast,:ts,:tii,:ecc,:lto,:ens_id)", row, path, "Telemetrie fig:") or 0) > 0
    except Exception as e:
        _log("Telemetrie fig:", e)
        return False


def newest_fig(channel, path=None):
    r = _rows_t2("SELECT * FROM telemetry WHERE kind='fig' AND channel=? ORDER BY ts DESC, id DESC LIMIT 1", (str(channel),), path)
    return r[0] if r else None


def asa_rx_add(ts, channel="5C", serial=None, path=None):
    """Empfangszeitpunkt ASA-Dienst merken. -> True wenn neu"""
    if not isinstance(ts, (int, float)):
        return False
    return (_exec("INSERT OR IGNORE INTO asa_rx(ts, channel, serial) VALUES(?,?,?)", (int(ts), str(channel), serial), path, "asa_rx:") or 0) > 0


def asa_rx_list(since, channel="5C", path=None):
    return [r["ts"] for r in _rows_t2("SELECT ts FROM asa_rx WHERE channel=? AND ts>=? ORDER BY ts", (str(channel), int(since)), path)]


def mesh_hash_since(hash_hex, since, path=None, ok_only=True):
    """Gleicher Inhalt (Hash) seit 'since' gesendet? ok_only: fehlgeschlagene Versuche zaehlen nicht. -> True/False/None(Fehler)"""
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            q = "SELECT 1 FROM mesh_log WHERE hash=? AND created>=?" + (" AND COALESCE(ok, 1)=1" if ok_only else "")
            return con.execute(q, (str(hash_hex), int(since))).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_log_put(hash_hex, channel, now, src=None, text=None, ok=None, kind="auto", path=None):
    """Versand protokollieren (gleicher Hash -> Zeit/Ergebnis aktualisiert). -> True/False"""
    n = _exec("INSERT INTO mesh_log(hash, channel, created, src, text, ok, kind) VALUES(?,?,?,?,?,?,?) "
              "ON CONFLICT(hash) DO UPDATE SET created=excluded.created, channel=excluded.channel, src=excluded.src, text=excluded.text, ok=excluded.ok, kind=excluded.kind",
              (str(hash_hex), None if channel is None else str(channel), int(now), src, (str(text)[:300] if text is not None else None),
               None if ok is None else (1 if ok else 0), kind), path, "mesh_log:", SYNC_ALARM)   # secXml: Versandprotokoll = Alarmpfad
    return bool(n)


def mesh_auto_get(akey, path=None):
    r = _rows_t2("SELECT * FROM mesh_auto WHERE akey=?", (str(akey),), path)
    return r[0] if r else None


def mesh_auto_reserve(akey, hash_hex, src, text, now, path=None):
    """Versuch fuer einen Alarm anmelden. -> 'neu' | 'wieder' (frueherer Versuch fehlgeschlagen) | None (schon gesendet/zu frueh/zu oft/Fehler)"""
    now = int(now)
    path = _ensure_t2(path)
    try:
        con = connect(path, SYNC_ALARM)   # secXml: Auto-Versuch anmelden = Alarmpfad
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_auto(akey, hash, src, text, created, last_try, tries, ok) VALUES(?,?,?,?,?,?,1,NULL)",
                                  (str(akey), str(hash_hex), src, str(text)[:300], now, now))
                if cur.rowcount > 0:
                    return "neu"
                r = con.execute("SELECT ok, tries, last_try FROM mesh_auto WHERE akey=?", (str(akey),)).fetchone()
                if r is None or r["ok"] != 0 or int(r["tries"] or 0) >= AUTO_TRIES_MAX or now - int(r["last_try"] or 0) < AUTO_RETRY_S:
                    return None
                con.execute("UPDATE mesh_auto SET tries=tries+1, last_try=?, ok=NULL, hash=?, text=? WHERE akey=?", (now, str(hash_hex), str(text)[:300], str(akey)))
                return "wieder"
        finally:
            con.close()
    except Exception as e:
        _log("mesh_auto:", e)
        return None


def mesh_auto_done(akey, ok, path=None):
    return bool(_exec("UPDATE mesh_auto SET ok=? WHERE akey=?", (1 if ok else 0, str(akey)), path, "mesh_auto:", SYNC_ALARM))   # secXml: Ergebnis des Versuchs = Alarmpfad


def mesh_auto_count(since, path=None):
    """Auto-Versuche seit 'since' (Ratenbegrenzung). Fehler -> None"""
    r = _rows_t2("SELECT COUNT(*) n FROM mesh_auto WHERE last_try>=?", (int(since),), path)
    return r[0]["n"] if r else None


def mesh_auto_recent(n=10, path=None):
    return _rows_t2("SELECT akey, src, text, created, last_try, tries, ok FROM mesh_auto ORDER BY last_try DESC, id DESC LIMIT ?", (int(n),), path)


def cleanup_t2(now=None, path=None):
    now = int(now or time.time())
    return {"mesh_auto": _exec("DELETE FROM mesh_auto WHERE COALESCE(last_try, created, 0) < ?", (now - KEEP_MESH_AUTO_S,), path, "Aufraeumen:"),
            "asa_rx": _exec("DELETE FROM asa_rx WHERE ts < ?", (now - KEEP_ASA_RX_S,), path, "Aufraeumen:")}


def selftest_t2():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "t2.db")
    assert migrate_t2(p) and migrate_t2(p)
    con = connect(p)
    cols = {r[1] for r in con.execute("PRAGMA table_info(telemetry)")} | {r[1] for r in con.execute("PRAGMA table_info(mesh_log)")}
    con.close()
    assert {"tii", "ecc", "lto", "ens_id", "src", "text", "ok", "kind"} <= cols, cols
    now = int(time.time())
    assert insert_fig({"ts": now, "serial": "19348831", "channel": "11D", "ensemble": "Bayern", "mast": "BR Bayern MainID 07 / SubID 02", "tii": "[]", "ecc": "0xE0", "lto": 2.0}, p)
    assert not insert_fig({"ts": now, "serial": "19348831", "channel": "11D"}, p) and newest_fig("11D", p)["ecc"] == "0xE0"
    assert insert_telemetry({"ts": now, "serial": "19348831", "channel": "11D", "snr": 9.0, "src_t": now}, p)   # alte Telemetrie unberuehrt
    assert asa_rx_add(now - 100, path=p) and not asa_rx_add(now - 100, path=p) and asa_rx_add(now, path=p) and asa_rx_list(now - 200, path=p) == [now - 100, now]
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now, p) == "neu" and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 1, p) is None
    assert mesh_auto_done("A1", False, p) and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 60, p) is None          # zu frueh
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + AUTO_RETRY_S, p) == "wieder" and mesh_auto_done("A1", True, p)
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + 9 * AUTO_RETRY_S, p) is None and mesh_auto_get("A1", p)["tries"] == 2   # einmal ok = nie wieder
    assert mesh_auto_count(now, p) == 1 and mesh_auto_count(now + 10 * AUTO_RETRY_S, p) == 0
    assert mesh_hash_since("h1", now - 10, p) is False and mesh_log_put("h1", "auto0", now, "ASA", "x", True, path=p) and mesh_hash_since("h1", now - 10, p) is True
    assert mesh_log_put("h1", "auto0", now + 5, "ASA", "x", False, path=p) and mesh_hash_since("h1", now + 1, p) is False and mesh_known("h1", p) is True
    assert mesh_hash_since("h1", now + 1, p, ok_only=False) is True
    c = cleanup_t2(now + KEEP_ASA_RX_S + 1, p)
    assert c["asa_rx"] == 2 and c["mesh_auto"] == 0, c
    assert asa_rx_list(0, path="/proc/nicht/schreibbar/x.db") == [] and mesh_auto_reserve("x", "h", "s", "t", now, "/proc/nicht/schreibbar/x.db") is None
    return "database selftest Teil 2 ok"


# ---------------------------------------------------------------- Teil 3 (Meshtastic-Routing und Priorisierung)
# Zusaetzlich, idempotent (migrate_t3): Tabelle mesh_queue = Warteschlange je Knoten (m1 = Mesh 1 192.168.178.141,
# m2 = Mesh 2 192.168.178.140) fuer NINA-Kurzmeldung und NINA-Details (Details erst nach der eigenen Kurzmeldung,
# 60 s Abstand, Kanal frei). Zustand: wait | ok | dup | fail | skip. Bestehende Tabellen/Funktionen bleiben unveraendert.
KEEP_QUEUE_S = 7 * 86400
_T3_SQL = (
    "CREATE TABLE IF NOT EXISTS mesh_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, node TEXT NOT NULL, kind TEXT NOT NULL, ref TEXT, text TEXT, "
    "hash TEXT, created INTEGER, not_before INTEGER, after_id INTEGER, tries INTEGER DEFAULT 0, last_try INTEGER, state TEXT DEFAULT 'wait', "
    "why TEXT, done INTEGER)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_queue_open ON mesh_queue(node, state, id)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_queue_hash ON mesh_queue(node, hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_log_ch ON mesh_log(channel, created)",
)
_Q_FIELDS = ("text", "hash", "not_before", "tries", "last_try", "state", "why", "done", "ref")
_migrated_t3 = set()


def migrate_t3(path=None):
    """Teil-3-Schema ergaenzen (idempotent, setzt Teil 2 voraus). -> True/False"""
    path = path or DB_PATH
    try:
        if not migrate_t2(path):
            return False
        con = connect(path)
        try:
            with con:
                for sql in _T3_SQL:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_t3', '1') ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        finally:
            con.close()
        _migrated_t3.add(path)
        return True
    except Exception as e:
        _log("Migration Teil 3:", e)
        return False


def _ensure_t3(path):
    path = path or DB_PATH
    if path not in _migrated_t3:
        migrate_t3(path)
    return path


def q_add(node, kind, text, hash_hex, now, not_before=None, after_id=None, ref=None, path=None, same_s=6 * 3600):
    """Eintrag anlegen; gleicher Knoten + gleicher Hash, der noch wartet oder in den letzten 6 h erledigt wurde -> vorhandene id. -> id | None"""
    now = int(now)
    path = _ensure_t3(path)
    try:
        con = connect(path, SYNC_ALARM)   # secXml: Alarm-Warteschlange = Alarmpfad
        try:
            with con:
                if hash_hex:
                    r = con.execute("SELECT id FROM mesh_queue WHERE node=? AND hash=? AND (state='wait' OR COALESCE(done, created, 0)>=?) "
                                    "ORDER BY id DESC LIMIT 1", (str(node), str(hash_hex), now - int(same_s))).fetchone()
                    if r is not None:
                        return int(r["id"])
                cur = con.execute("INSERT INTO mesh_queue(node, kind, ref, text, hash, created, not_before, after_id, tries, state) "
                                  "VALUES(?,?,?,?,?,?,?,?,0,'wait')",
                                  (str(node), str(kind), ref, None if text is None else str(text)[:300], hash_hex, now,
                                   int(now if not_before is None else not_before), after_id))
                return int(cur.lastrowid)
        finally:
            con.close()
    except Exception as e:
        _log("mesh_queue:", e)
        return None


def q_get(qid, path=None):
    r = _rows_t3("SELECT * FROM mesh_queue WHERE id=?", (int(qid),), path)
    return r[0] if r else None


def q_open(node, path=None):
    """Wartende Eintraege eines Knotens, aelteste zuerst (Kurzmeldungen vor Details)."""
    return _rows_t3("SELECT * FROM mesh_queue WHERE node=? AND state='wait' ORDER BY CASE kind WHEN 'nina' THEN 0 ELSE 1 END, id", (str(node),), path)


def q_set(qid, path=None, **kw):
    sets = [(k, v) for k, v in kw.items() if k in _Q_FIELDS]
    if not sets:
        return False
    sql = "UPDATE mesh_queue SET %s WHERE id=?" % ", ".join("%s=?" % k for k, _ in sets)
    return bool(_exec(sql, tuple(v for _, v in sets) + (int(qid),), _ensure_t3(path), "mesh_queue:", SYNC_ALARM))   # secXml: Zustand der Warteschlange (ok/skip/fail) = Alarmpfad


def q_recent(n=10, path=None):
    return _rows_t3("SELECT id, node, kind, text, created, not_before, after_id, tries, last_try, state, why, done FROM mesh_queue "
                    "ORDER BY id DESC LIMIT ?", (int(n),), path)


def mesh_count_since(channel, kinds, since, path=None):
    """Erfolgreiche Sendungen eines Kanals (Knoten) seit 'since' mit kind in kinds (Ratenbegrenzung). Fehler -> None"""
    kinds = tuple(kinds)
    r = _rows_t3("SELECT COUNT(*) n FROM mesh_log WHERE channel=? AND created>=? AND COALESCE(ok, 1)=1 AND kind IN (%s)" % ",".join("?" * len(kinds)),
                 (str(channel), int(since)) + kinds, path)
    return r[0]["n"] if r else None


def mesh_last(hash_hex, path=None):
    """Letzter Eintrag zu einem Hash (fuer Hinweis 'schon gesendet'). -> dict | None"""
    r = _rows_t3("SELECT hash, channel, created, src, ok, kind FROM mesh_log WHERE hash=?", (str(hash_hex),), path)
    return r[0] if r else None


def _rows_t3(sql, args, path):
    _ensure_t3(path)
    return _rows(sql, args, path)


def cleanup_t3(now=None, path=None):
    now = int(now or time.time())
    return {"mesh_queue": _exec("DELETE FROM mesh_queue WHERE state!='wait' AND COALESCE(done, last_try, created, 0) < ?", (now - KEEP_QUEUE_S,),
                                _ensure_t3(path), "Aufraeumen:")}


def selftest_t3():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "t3.db")
    assert migrate_t3(p) and migrate_t3(p)
    now = int(time.time())
    a = q_add("m1", "nina", "NINA: Nürnberg: Gefahr", "h1", now, path=p)
    assert a and q_add("m1", "nina", "NINA: Nürnberg: Gefahr", "h1", now + 5, path=p) == a          # wartet schon -> gleiche id
    b = q_add("m2", "nina", "NINA: Nürnberg: Gefahr", "h2", now, path=p)
    d = q_add("m1", "nina_detail", None, None, now, not_before=now + 60, after_id=a, ref='{"ids": []}', path=p)
    assert b != a and d and [r["id"] for r in q_open("m1", p)] == [a, d] and q_get(d, p)["after_id"] == a
    assert q_set(a, p, state="ok", done=now, tries=1, last_try=now) and [r["id"] for r in q_open("m1", p)] == [d]
    assert q_add("m1", "nina", "x", "h1", now + 100, path=p) == a and q_add("m1", "nina", "x", "h1", now + 7 * 3600, path=p) != a   # nach 6 h neu
    assert mesh_log_put("k1", "m1:0", now, "NINA", "x", True, "nina", p) and mesh_log_put("k2", "m1:0", now, "NINA", "y", False, "nina", p)
    assert mesh_log_put("k3", "m2:0", now, "NINA", "z", True, "nina", p) and mesh_log_put("k4", "m1:0", now, "x", "w", True, "manuell", p)
    assert mesh_count_since("m1:0", ("nina", "nina_detail"), now - 10, p) == 1 and mesh_count_since("m2:0", ("nina",), now - 10, p) == 1
    assert mesh_last("k4", p)["kind"] == "manuell" and mesh_last("nix", p) is None and not q_set(a, p, bogus=1)
    assert cleanup_t3(now + KEEP_QUEUE_S + 3 * 3600, p)["mesh_queue"] == 1
    assert q_add("m1", "nina", "x", "h", now, path="/proc/nicht/schreibbar/x.db") is None and q_open("m1", "/proc/nicht/schreibbar/x.db") == []
    return "database selftest Teil 3 ok"

# ---------------------------------------------------------------- relDb (REL-07 + PERF-06): Datenbank-Wartung im Hintergrund
# Zweck: lagezentrum.db (klein, WAL) dauerhaft gesund halten, OHNE den Alarmpfad zu stoerenden.
#  - journal_mode=WAL wird je Prozess und Pfad EINMAL gesetzt/geprueft (migrate() bzw. erste Verbindung), nicht mehr bei jeder Verbindung (PERF-06).
#  - Checkpoint: alle 6 h (monotonic, Zeitspruenge egal) oder wenn die -wal-Datei > 64 MiB ist: PRAGMA wal_checkpoint(TRUNCATE) mit 1 s Wartezeit,
#    aber nur wenn KEIN Alarm in Arbeit ist (wartender mesh_queue-Eintrag / Auto-Versuch ohne Ergebnis < 15 min) und tools/backup.sh nicht laeuft
#    (flock auf .backup.lock). Sonst nur PASSIVE (blockiert nie) und naechster Versuch beim naechsten Lauf des Aufraeum-Fadens (10 min).
#  - quick_check: in eigenem Faden (lz-quickcheck), nur lesend (mode=ro), 120 s nach Start und danach woechentlich, mit Zeitlimit; Ergebnis in
#    retention_status()["maint"] und in lagezentrum.db.maint.json. Bei Fehlern wird NUR gemeldet (Journal, Status) - nie eine Datei beiseitegelegt oder geloescht
#    (mehrere Prozesse haben die Datei offen); Vorgehen steht in tools/lage_db_maint.py und im Bericht.
#  - Kein VACUUM im laufenden Betrieb: nur manuell ueber tools/lage_db_maint.py vacuum (mit Sicherung, Pruefung, Platzbedarf).
#  - snapshot(): konsistente Kopie ueber die sqlite3-Backup-API (wie tools/backup.sh), mit quick_check der Kopie; ueberschreibt nie.
#  Alles faengt Fehler ab (wirft nie); aendert keine Daten; sendet nichts.
import errno as _rd_errno
import json as _rd_json
import threading as _rd_threading
try:
    import fcntl as _rd_fcntl
except Exception:                      # nicht Linux
    _rd_fcntl = None

CKPT_EVERY_S = 6 * 3600                # harter Checkpoint alle 6 h
WAL_MAX_BYTES = 64 * 1024 * 1024       # -wal groesser als das: nicht auf die 6 h warten
CKPT_BUSY_MS = 1000                    # hoechstens so lange auf Leser warten (blockiert Schreiber in dieser Zeit)
QC_FIRST_S = 120                       # erster quick_check 120 s nach dem ersten Lauf des Aufraeum-Fadens
QC_EVERY_S = 7 * 86400                 # danach woechentlich
QC_LIMIT_S = 120.0                     # quick_check abbrechen (kein Fehler der Datei), wenn er laenger dauert
ALARM_INFLIGHT_S = 900                 # Auto-Versuch ohne Ergebnis juenger als 15 min = Alarm in Arbeit
BACKUP_LOCK = "/home/fmg/prepper-backups/.backup.lock"   # tools/backup.sh haelt hier flock waehrend der Sicherung


def wal_bytes(path=None):
    """Groesse der -wal-Datei in Bytes (0 = keine)."""
    try:
        return os.path.getsize((path or DB_PATH) + "-wal")
    except OSError:
        return 0


def _ro(path, timeout=1.0):
    from urllib.parse import quote
    con = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(path)), uri=True, timeout=timeout)
    con.execute("PRAGMA busy_timeout=%d" % int(timeout * 1000))
    return con


def backup_running(lock=None):
    """True, wenn tools/backup.sh gerade laeuft (haelt flock auf .backup.lock). Keine Sperrdatei oder unklar -> False."""
    lock = lock or BACKUP_LOCK
    if _rd_fcntl is None:
        return False
    fd = None
    try:
        fd = os.open(lock, os.O_RDONLY)
    except OSError:
        return False
    try:
        try:
            _rd_fcntl.flock(fd, _rd_fcntl.LOCK_SH | _rd_fcntl.LOCK_NB)
        except OSError as e:
            return e.errno in (_rd_errno.EWOULDBLOCK, _rd_errno.EAGAIN)
        return False
    except Exception:
        return False
    finally:
        try:
            os.close(fd)                # gibt die kurze Lesesperre sofort wieder frei
        except OSError:
            pass


def alarm_pending(path=None, now=None):
    """Alarmpfad gerade in Arbeit? True: wartender mesh_queue-Eintrag oder Auto-Versuch (mesh_auto) ohne Ergebnis juenger als 15 min.
    Fehlende Tabellen = nichts in Arbeit; jeder andere Fehler -> True (vorsichtig: dann kein harter Checkpoint)."""
    path = path or DB_PATH
    now = int(now or time.time())
    con = None
    try:
        if not os.path.exists(path):
            return False
        con = _ro(path, 1.0)
        for sql, args in (("SELECT 1 FROM mesh_queue WHERE state='wait' LIMIT 1", ()),
                          ("SELECT 1 FROM mesh_auto WHERE ok IS NULL AND COALESCE(last_try, created, 0) >= ? LIMIT 1", (now - ALARM_INFLIGHT_S,))):
            try:
                if con.execute(sql, args).fetchone() is not None:
                    return True
            except sqlite3.OperationalError as e:
                if "no such table" in str(e):
                    continue
                raise
        return False
    except Exception:
        return True
    finally:
        try:
            con and con.close()
        except Exception:
            pass


def checkpoint(path=None, mode="PASSIVE", busy_ms=CKPT_BUSY_MS):
    """WAL-Checkpoint. mode PASSIVE (blockiert nie) oder TRUNCATE (wartet hoechstens busy_ms auf Leser). Wirft nie.
    -> {"mode", "busy", "log", "done", "wal_before", "wal_after", "ms", "err"}"""
    mode = "TRUNCATE" if str(mode).upper() == "TRUNCATE" else "PASSIVE"
    path = path or DB_PATH
    out = {"mode": mode, "busy": None, "log": None, "done": None, "wal_before": wal_bytes(path), "wal_after": None, "ms": None, "err": None}
    t0 = time.monotonic()   # relClock: Dauer monoton (Zeitspruenge)
    con = None
    try:
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        con = sqlite3.connect(path, timeout=max(0.1, busy_ms / 1000.0))
        con.execute("PRAGMA busy_timeout=%d" % int(busy_ms))
        r = con.execute("PRAGMA wal_checkpoint(%s)" % mode).fetchone()
        if r is not None:
            out["busy"], out["log"], out["done"] = int(r[0]), int(r[1]), int(r[2])
    except Exception as e:
        out["err"] = str(e)[:120]
    finally:
        try:
            con and con.close()
        except Exception:
            pass
    out["wal_after"] = wal_bytes(path)
    out["ms"] = int((time.monotonic() - t0) * 1000)
    return out


def quick_check(path=None, limit_s=QC_LIMIT_S, max_rows=5):
    """PRAGMA quick_check nur lesend (mode=ro), mit Zeitlimit. -> {"ok", "rows", "ms", "err", "aborted"}
    ok True = 'ok'; ok False + rows = Befund der Datei; ok None + err = nicht pruefbar (gesperrt, Zeitlimit, fehlt) - das ist KEIN Befund."""
    path = path or DB_PATH
    out = {"ok": None, "rows": [], "ms": None, "err": None, "aborted": False}
    t0 = time.monotonic()   # relClock: Zeitlimit und Dauer monoton - ein Zeitsprung darf den Test weder abbrechen noch endlos laufen lassen
    con = None
    try:
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        con = _ro(path, 2.0)
        deadline = t0 + float(limit_s)

        def _stop():
            return 1 if time.monotonic() > deadline else 0
        con.set_progress_handler(_stop, 20000)
        rows = [str(r[0])[:160] for r in con.execute("PRAGMA quick_check(%d)" % int(max_rows)).fetchall()]
        out["rows"] = rows[:max_rows]
        out["ok"] = rows == ["ok"]
    except sqlite3.Error as e:
        msg = str(e)
        code = getattr(e, "sqlite_errorcode", None)
        low = msg.lower()
        if code in (11, 26) or "malformed" in low or "not a database" in low:      # SQLITE_CORRUPT / SQLITE_NOTADB = Befund der Datei
            out["ok"] = False
            out["rows"] = [msg[:160]]
        elif code == 9 or "interrupt" in low:                                       # eigenes Zeitlimit = nicht pruefbar, KEIN Befund
            out["aborted"] = True
            out["err"] = "Zeitlimit"
        else:                                                                        # gesperrt, kein Zugriff usw. = nicht pruefbar, KEIN Befund
            out["err"] = msg[:120]
    except Exception as e:
        out["err"] = str(e)[:120]
    finally:
        try:
            con and con.close()
        except Exception:
            pass
    out["ms"] = int((time.monotonic() - t0) * 1000)
    return out


def db_stats(path=None):
    """Seitenzahl, freie Seiten, Dateigroessen (nur lesend). Fehler -> {"err"}"""
    path = path or DB_PATH
    con = None
    try:
        con = _ro(path, 1.0)
        ps = int(con.execute("PRAGMA page_size").fetchone()[0])
        pc = int(con.execute("PRAGMA page_count").fetchone()[0])
        fl = int(con.execute("PRAGMA freelist_count").fetchone()[0])
        out = {"page_size": ps, "pages": pc, "free_pages": fl, "bytes": ps * pc, "free_bytes": ps * fl, "wal_bytes": wal_bytes(path)}
        out["vacuum_hint"] = bool(out["free_bytes"] >= 50 * 1024 * 1024 and fl * 3 >= pc)   # nur ein Hinweis, nichts geschieht automatisch
        return out
    except Exception as e:
        return {"err": str(e)[:120]}
    finally:
        try:
            con and con.close()
        except Exception:
            pass


def snapshot(dest, path=None, check=True):
    """Konsistente Kopie ueber die sqlite3-Backup-API (auch im laufenden Betrieb), Rechte 600, ueberschreibt nie. -> {"ok", "bytes", "check", "err"}"""
    path = path or DB_PATH
    out = {"ok": False, "bytes": None, "check": None, "err": None}
    part = str(dest) + ".part"
    src = dst = None
    try:
        if os.path.exists(dest):
            raise RuntimeError("Ziel existiert schon")
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        if os.path.exists(part):
            os.unlink(part)
        src = _ro(path, 20.0)
        old_umask = os.umask(0o077)
        try:
            dst = sqlite3.connect(part)
        finally:
            os.umask(old_umask)
        src.backup(dst)
        dst.commit()
        if check:
            out["check"] = [str(r[0])[:160] for r in dst.execute("PRAGMA quick_check(5)").fetchall()]
            if out["check"] != ["ok"]:
                raise RuntimeError("quick_check der Kopie: %s" % out["check"][:1])
        dst.close()
        dst = None
        os.chmod(part, 0o600)
        os.replace(part, dest)
        out["bytes"] = os.path.getsize(dest)
        out["ok"] = True
    except Exception as e:
        out["err"] = str(e)[:140]
        try:
            os.path.exists(part) and os.unlink(part)
        except OSError:
            pass
    finally:
        for c in (dst, src):
            try:
                c and c.close()
            except Exception:
                pass
    return out


def _mb(n):
    return "%.1f MB" % ((n or 0) / 1048576.0)


class _Maint:
    """Wartungsplan (tick() vom Aufraeum-Faden alle 10 min, wirft nie). Zeiten mit time.monotonic()."""

    def __init__(self, ckpt_every_s=CKPT_EVERY_S, wal_max=WAL_MAX_BYTES, qc_first_s=QC_FIRST_S, qc_every_s=QC_EVERY_S, lock=None, quiet=False):
        self.ckpt_every_s, self.wal_max, self.qc_first_s, self.qc_every_s = ckpt_every_s, wal_max, qc_first_s, qc_every_s
        self.lock_path = lock
        self.quiet = quiet
        self.lock = _rd_threading.Lock()
        self.t0 = None
        self.last_ckpt = None
        self.th = None
        self.stop = False
        self.path = None
        self.st = {"ready": None, "ckpt": None, "ckpt_n": 0, "ckpt_ok_n": 0, "ckpt_skip": None, "qc": None, "qc_n": 0, "stats": None, "wal": None, "err": None, "alert": None}

    def _say(self, *a):
        if not self.quiet:
            print("lagezentrum.db Wartung (relDb):", *a, flush=True)

    def _write(self):
        try:
            p = (self.path or DB_PATH) + ".maint.json"
            tmp = p + ".tmp"
            with open(tmp, "w") as f:
                _rd_json.dump(self.status(), f, ensure_ascii=False, indent=1)
            os.replace(tmp, p)
        except Exception:
            pass

    def _ckpt(self, path, m, wal, why):
        if backup_running(self.lock_path):
            self.st["ckpt_skip"] = {"t": int(time.time()), "why": "Sicherung laeuft (backup.sh)"}
            return
        if alarm_pending(path):
            r = checkpoint(path, "PASSIVE")
            r["note"] = "Alarm in Arbeit - nur PASSIVE, harter Checkpoint beim naechsten Lauf"
        else:
            r = checkpoint(path, "TRUNCATE")
            if r["err"] is None and r["busy"] == 0:
                self.last_ckpt = m
                self.st["ckpt_ok_n"] += 1
            else:
                r["note"] = "Leser aktiv (busy) - PASSIVE-Versuch, naechster harter Versuch beim naechsten Lauf"
                r2 = checkpoint(path, "PASSIVE")
                r["passive"] = {"busy": r2["busy"], "err": r2["err"]}
        r["t"] = int(time.time())
        r["why"] = why
        self.st["ckpt"] = r
        self.st["ckpt_n"] += 1
        self.st["ckpt_skip"] = None
        self._say("Checkpoint %s %s (%s): WAL %s -> %s (%d ms)%s" % (r["mode"], "ok" if r["err"] is None and r["busy"] == 0 else "nicht vollstaendig", why,
                  _mb(r["wal_before"]), _mb(r["wal_after"]), r["ms"] or 0, (" - " + r["note"]) if r.get("note") else ""))

    def _qc_loop(self, path):
        t_end = time.monotonic() + self.qc_first_s
        while not self.stop and time.monotonic() < t_end:
            time.sleep(min(2.0, max(0.05, t_end - time.monotonic())))
        while not self.stop:
            tries = 0
            while backup_running(self.lock_path) and tries < 30 and not self.stop:
                tries += 1
                time.sleep(10)
            r = quick_check(path)
            r["t"] = int(time.time())
            self.st["qc"] = r
            self.st["qc_n"] += 1
            self.st["stats"] = db_stats(path)
            if r["ok"] is False:
                self.st["alert"] = "quick_check meldet einen Befund: %s" % "; ".join(r["rows"][:2])
                _log("quick_check BEFUND:", "; ".join(r["rows"][:2]), "- Datei NICHT veraendert; Sicherung pruefen (tools/lage_db_maint.py status), siehe Bericht")
                print("lagezentrum.db Wartung (relDb): quick_check BEFUND - %s" % "; ".join(r["rows"][:2]), flush=True)
            else:
                self.st["alert"] = None
                self._say("quick_check %s (%d ms)%s" % ("ok" if r["ok"] else "nicht pruefbar: %s" % r["err"], r["ms"] or 0,
                          " - Hinweis: viele freie Seiten, VACUUM nur manuell (tools/lage_db_maint.py vacuum)" if (self.st["stats"] or {}).get("vacuum_hint") else ""))
            self._write()
            t_end = time.monotonic() + self.qc_every_s
            while not self.stop and time.monotonic() < t_end:
                time.sleep(min(60.0, max(0.05, t_end - time.monotonic())))

    def tick(self, path=None, mono=None):
        """Ein Wartungsschritt. Wirft nie."""
        try:
            path = path or self.path or DB_PATH
            m = time.monotonic() if mono is None else mono
            with self.lock:
                self.path = path
                if self.t0 is None:
                    self.t0 = m
                    self.last_ckpt = m
                    self.st["ready"] = int(time.time())
                    self._say("bereit - Checkpoint alle %d h (TRUNCATE nur ohne Alarm in Arbeit und ohne laufende Sicherung, sonst PASSIVE), quick_check %d s nach Start und dann alle %d Tage, kein VACUUM im Betrieb"
                              % (self.ckpt_every_s // 3600, self.qc_first_s, self.qc_every_s // 86400))
                if self.th is None or not self.th.is_alive():
                    self.th = _rd_threading.Thread(target=self._qc_loop, args=(path,), name="lz-quickcheck", daemon=True)
                    self.th.start()
                wal = wal_bytes(path)
                self.st["wal"] = wal
                if wal > self.wal_max:
                    self._ckpt(path, m, wal, "WAL %s > %s" % (_mb(wal), _mb(self.wal_max)))
                elif m - self.last_ckpt >= self.ckpt_every_s:
                    self._ckpt(path, m, wal, "%d h" % (self.ckpt_every_s // 3600))
                self.st["err"] = None
            self._write()
        except Exception as e:
            self.st["err"] = str(e)[:120]
        return self.st

    def status(self):
        try:
            return dict(self.st, ckpt_every_s=self.ckpt_every_s, wal_max=self.wal_max, qc_first_s=self.qc_first_s, qc_every_s=self.qc_every_s,
                        qc_alive=bool(self.th is not None and self.th.is_alive()))
        except Exception as e:
            return {"err": str(e)[:100]}


def selftest_maint():
    import shutil
    import tempfile
    d = tempfile.mkdtemp(prefix="lzmaint-")
    p = os.path.join(d, "m.db")
    assert migrate(p) and migrate_t2(p) and migrate_t3(p)
    # PERF-06: WAL steht in der Datei und wird je Prozess/Pfad nur einmal gesetzt
    assert p in _wal_done
    n_before = len(_wal_done)
    for _ in range(5):
        connect(p).close()
    assert len(_wal_done) == n_before
    c = connect(p)
    assert c.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    c.close()
    # WAL wachsen lassen (Auto-Checkpoint aus), dann Checkpoint
    c = connect(p)
    c.execute("PRAGMA wal_autocheckpoint=0")
    for i in range(300):
        c.execute("INSERT INTO mesh_log(hash, channel, created) VALUES(?, 'x', ?)", ("h%d" % i, int(time.time())))
    c.commit()
    assert wal_bytes(p) > 0
    r = checkpoint(p, "PASSIVE")
    assert r["err"] is None and r["busy"] == 0, r
    r = checkpoint(p, "TRUNCATE")
    assert r["err"] is None and r["busy"] == 0 and wal_bytes(p) == 0, r
    c.close()
    # Leser blockiert TRUNCATE nicht endlos: nach busy_ms kommt busy=1 zurueck, kein Haengen, Daten bleiben
    rd = connect(p)
    rd.execute("BEGIN")
    rd.execute("SELECT COUNT(*) FROM mesh_log").fetchone()
    w = connect(p)
    w.execute("INSERT INTO mesh_log(hash, channel, created) VALUES('nach', 'x', 1)")
    w.commit()
    t0 = time.time()
    r = checkpoint(p, "TRUNCATE", busy_ms=300)
    assert time.time() - t0 < 5 and (r["busy"] == 1 or r["err"] is not None or wal_bytes(p) == 0), r
    rd.rollback()
    rd.close()
    w.close()
    assert mesh_known("nach", p) is True and mesh_known("h299", p) is True
    # Alarm in Arbeit
    assert alarm_pending(p) is False
    q = q_add("m1", "nina", "x", "ha", int(time.time()), path=p)
    assert q and alarm_pending(p) is True
    assert q_set(q, p, state="ok", done=1) and alarm_pending(p) is False
    assert mesh_auto_reserve("A9", "h", "ASA", "x", int(time.time()), p) == "neu" and alarm_pending(p) is True     # Versuch ohne Ergebnis
    assert mesh_auto_done("A9", True, p) and alarm_pending(p) is False
    assert alarm_pending(os.path.join(d, "fehlt.db")) is False and alarm_pending("/proc/nicht/da/x.db") is False
    # Sicherung laeuft (flock wie backup.sh)
    lk = os.path.join(d, ".backup.lock")
    assert backup_running(lk) is False
    fd = os.open(lk, os.O_WRONLY | os.O_CREAT, 0o600)
    assert backup_running(lk) is False
    _rd_fcntl.flock(fd, _rd_fcntl.LOCK_EX)
    assert backup_running(lk) is True
    os.close(fd)
    assert backup_running(lk) is False
    # quick_check: gesund = ok; kaputte Kopie = Befund; fehlend/gesperrt = nicht pruefbar (kein Befund)
    r = quick_check(p)
    assert r["ok"] is True and r["rows"] == ["ok"], r
    s = db_stats(p)
    assert s["pages"] > 0 and s["bytes"] == s["pages"] * s["page_size"], s
    bad = os.path.join(d, "bad.db")
    sn = snapshot(os.path.join(d, "snap.db"), p)
    assert sn["ok"] and sn["check"] == ["ok"] and (os.stat(os.path.join(d, "snap.db")).st_mode & 0o777) == 0o600, sn
    assert snapshot(os.path.join(d, "snap.db"), p)["ok"] is False                # ueberschreibt nie
    shutil.copy(os.path.join(d, "snap.db"), bad)
    with open(bad, "r+b") as f:                                                  # Kopfbereiche mehrerer B-Baum-Seiten zerstoeren
        for pg in range(2, 7):
            f.seek((pg - 1) * 4096)
            f.write(b"\xff" * 64)
    r = quick_check(bad)
    assert r["ok"] is False and r["rows"] and r["rows"] != ["ok"], r
    assert quick_check(os.path.join(d, "fehlt.db"))["ok"] is None
    assert not os.path.exists(os.path.join(d, "fehlt.db"))                      # legt nie eine Datei an
    # Wartungsplan: erster Lauf = bereit, kein Checkpoint; spaeter nach 6 h (monotonic) oder grosser WAL; wirft nie
    mt = _Maint(ckpt_every_s=100, wal_max=1 << 40, qc_first_s=0.05, qc_every_s=3600, lock=lk, quiet=True)
    st = mt.tick(p, mono=1000.0)
    assert st["ready"] and st["ckpt"] is None and mt.th is not None
    for _ in range(100):                                                        # erst den (kurzen) quick_check abwarten: ein Leser koennte sonst TRUNCATE bremsen
        if mt.st["qc"] is not None:
            break
        time.sleep(0.1)
    assert mt.st["qc"] is not None
    mt.tick(p, mono=1050.0)
    assert mt.st["ckpt"] is None
    c = connect(p)
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("INSERT INTO mesh_log(hash, channel, created) VALUES('w1', 'x', 1)")
    c.commit()
    c.close()
    mt.tick(p, mono=1101.0)
    assert mt.st["ckpt"] and mt.st["ckpt"]["mode"] == "TRUNCATE" and mt.st["ckpt"]["busy"] == 0 and mt.st["ckpt_ok_n"] == 1, mt.st["ckpt"]
    fd = os.open(lk, os.O_WRONLY | os.O_CREAT, 0o600)
    _rd_fcntl.flock(fd, _rd_fcntl.LOCK_EX)
    n0 = mt.st["ckpt_n"]
    mt.tick(p, mono=1300.0)                                                     # Sicherung laeuft -> kein Checkpoint
    assert mt.st["ckpt_n"] == n0 and mt.st["ckpt_skip"], mt.st
    os.close(fd)
    q = q_add("m1", "nina", "y", "hb", int(time.time()), path=p)
    c = connect(p)
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("INSERT INTO mesh_log(hash, channel, created) VALUES('w2', 'x', 1)")
    c.commit()
    c.close()
    mt.tick(p, mono=1400.0)                                                     # Alarm in Arbeit -> nur PASSIVE
    assert mt.st["ckpt"]["mode"] == "PASSIVE" and "Alarm" in mt.st["ckpt"]["note"], mt.st["ckpt"]
    for _ in range(100):
        if mt.st["qc"] is not None:
            break
        time.sleep(0.1)
    assert mt.st["qc"] and mt.st["qc"]["ok"] is True and mt.st["alert"] is None, mt.st["qc"]
    assert os.path.exists(p + ".maint.json") and _rd_json.load(open(p + ".maint.json"))["qc"]["ok"] is True
    mt.stop = True
    assert _Maint(quiet=True).tick("/proc/nicht/da/x.db", mono=5.0) is not None   # wirft nie
    # Schreiber laufen waehrend harter Checkpoints weiter (kein Fehler, keine lange Sperre)
    stop = [False]
    errs = []
    lat = []

    def _writer():
        i = 0
        while not stop[0]:
            t1 = time.time()
            try:
                if not mesh_log_put("wr%d" % i, "x", int(time.time()), "t", "t", True, path=p):
                    errs.append("put")
            except Exception as e:
                errs.append(str(e))
            lat.append(time.time() - t1)
            i += 1
            time.sleep(0.002)
    th = _rd_threading.Thread(target=_writer, daemon=True)
    th.start()
    for _ in range(8):
        checkpoint(p, "TRUNCATE", busy_ms=500)
        time.sleep(0.05)
    stop[0] = True
    th.join(5)
    assert not errs and lat and max(lat) < 3.0, (errs[:2], max(lat) if lat else None)
    # kein Aufraeum-Befehl dieser Art im Programmtext dieser Datei (nur manuell ueber tools/lage_db_maint.py)
    import ast as _ast
    tok = "VAC" + "UUM"
    src = open(__file__).read() if "__file__" in globals() else ""
    if src:
        for node in _ast.walk(_ast.parse(src)):
            if isinstance(node, _ast.Constant) and isinstance(node.value, str) and node.value.strip().upper().split()[:1] == [tok]:
                raise AssertionError("Platz-Aufraeumbefehl im Betrieb")
    shutil.rmtree(d, ignore_errors=True)
    return "database selftest relDb ok (WAL einmal je Pfad, Checkpoint PASSIVE/TRUNCATE mit Wartegrenze, Alarm-in-Arbeit-/Sicherungs-Sperre, quick_check ro mit Befund/nicht pruefbar, snapshot ueberschreibt nie, Schreiber laufen weiter, kein VACUUM)"


# ---------------------------------------------------------------- sqlA (Aufraeumen im eigenen Faden)
# start_retention(): ein Daemon-Faden je Prozess (Sperre, doppelter Start = nichts), alle 10 min alle Aufraeumarbeiten mit Epoch-Sekunden
# (alle Zeitspalten sind Unix-Sekunden, UTC-neutral): events erst 7 Tage NACH Ablauf loeschen (Historie; aktiv ist nur expires >= jetzt),
# mesh_log > 24 h, telemetry > 48 h, mesh_auto 30 d, asa_rx 14 d, mesh_queue 7 d, dazu Zusatzarbeiten (z. B. lageGeo-Cache) vom Aufrufer.
# retention_owns(path): Faden laeuft gesund fuer diese DB -> alte Ausloeser (Sync.tick, Teil 2/3, lageGeo) tun nichts.
# retention_watch(path): Rueckfall fuer Sync.tick: Faden fuer diese DB gestartet aber tot -> neu starten; nie gestartet -> einmal direkt aufraeumen.
import threading as _ret_threading

RETENTION_S = 600
RETENTION_FIRST_S = 30


# ---------------------------------------------------------------- relClock (REL-06): Uhr-Plausibilitaet vor dem Loeschen, monotone Zeit fuer Intervalle
# Das Aufraeumen loescht nach "jetzt minus Frist" (Wanduhr). Steht die Uhr falsch oder springt sie (Pi ohne RTC, chrony makestep), duerfen Fristen nicht greifen:
#  - lage_clock.clock_ok() False -> der Aufraeum-Faden loescht NICHTS (auch nicht die Zusatz-Aufraeumer), meldet das einmal je Wechsel im Journal und laeuft weiter
#    (Checkpoint/quick_check der Wartung brauchen keine Wanduhr). Nach plausibler Uhr (und 15 min Haltezeit nach einem Sprung) wird normal aufgeraeumt.
#  - fehlt lage_clock.py oder wirft es: es wird wie bisher aufgeraeumt (kein neuer Ausfall); das steht im Status ("pruefer").
#  - Dauern und Zeitlimits sowie owns() nutzen time.monotonic() statt der Wanduhr (ein Zeitsprung darf den Faden nicht fuer tot erklaeren oder quick_check abbrechen).
try:
    import lage_clock as _lclk
except Exception:   # noch nicht installiert oder defekt -> wie bisher, ehrlich im Status
    _lclk = None


def _clock_state():
    """-> (ok, Grund, Pruefer). Wirft nie. Ohne lage_clock: (True, 'lage_clock fehlt', False)."""
    if _lclk is None:
        return True, "lage_clock fehlt - Uhr nicht geprueft", False
    try:
        ok, why = _lclk.clock_state()
        return bool(ok), str(why)[:120], True
    except Exception as e:
        return True, "Uhr-Pruefer Fehler: %s" % str(e)[:60], False


def _clock_gate(ret):
    """Fuer den Aufraeum-Faden: (ok, Grund). Meldet jeden Wechsel einmal ins Journal (ausser ret.quiet)."""
    ok, why, chk = _clock_state()
    key = (ok, chk)
    if ret.clock_last != key:
        first = ret.clock_last is None
        ret.clock_last = key
        if not ok:
            if not ret.quiet:
                print("lagezentrum.db Aufraeumen pausiert (relClock): %s - es wird nichts geloescht, bis die Uhr plausibel ist" % why, flush=True)
        elif not first and not ret.quiet:
            print("lagezentrum.db Aufraeumen (relClock): Uhr wieder plausibel (%s) - es wird wieder aufgeraeumt" % why, flush=True)
        elif first and not ret.quiet:
            print("lagezentrum.db Uhr (relClock): %s - Aufraeumen erlaubt" % why, flush=True)
    ret.clock_why = why
    return ok, why


def selftest_clock():
    import tempfile
    d = tempfile.mkdtemp(prefix="lzclk-")
    p = os.path.join(d, "c.db")
    assert migrate(p) and migrate_t2(p) and migrate_t3(p)
    now = int(time.time())
    for eid, exp in (("ab_8d", now - 8 * 86400), ("aktiv", now + 3600)):
        assert upsert_event({"source": "NINA", "ext_id": eid, "severity": "warn", "headline": eid, "created": now - 9 * 86400, "updated": now - 9 * 86400, "expires": exp}, p)
    global _clock_state
    saved = _clock_state
    r = _Retention(every_s=3600, first_s=3600)
    r.quiet = True
    r.maint = None
    r.path = p
    n_before = counts(p)["events"]
    try:
        _clock_state = lambda: (False, "Uhr unplausibel (Test)", True)
        out = r.run(now, p)
        assert out.get("clock_pause") and counts(p)["events"] == n_before, (out, counts(p))   # Uhr falsch: nichts geloescht
        assert r.st["last"].get("clock_pause")
        _clock_state = lambda: (True, "plausibel (Test)", True)
        out = r.run(now, p)
        assert "clock_pause" not in out and counts(p)["events"] == n_before - 1, (out, counts(p))   # Uhr ok: abgelaufenes Ereignis (8 Tage) wird geloescht
        # fehlender/defekter Pruefer blockiert nicht
        _clock_state = lambda: (True, "lage_clock fehlt - Uhr nicht geprueft", False)
        assert r.run(now, p).get("clock_pause") is None
    finally:
        _clock_state = saved
        for f in os.listdir(d):
            try:
                os.unlink(os.path.join(d, f))
            except OSError:
                pass
        try:
            os.rmdir(d)
        except OSError:
            pass
    # owns() rechnet monotonic: ein Wanduhr-Sprung macht den gesunden Faden nicht "tot"
    q = _Retention(every_s=600, first_s=30)
    q.th = _ret_threading.Thread(target=lambda: time.sleep(2), daemon=True)
    q.th.start()
    q.path = DB_PATH
    q.st["t"] = int(time.time()) - 10 ** 7        # Wanduhr-Anzeige "uralt" (Sprung)
    q.mono_ref = time.monotonic()
    assert q.owns(DB_PATH) is True
    q.mono_ref = time.monotonic() - 10 ** 5       # wirklich lange nichts gelaufen
    assert q.owns(DB_PATH) is False
    st = _RETX.status()
    assert "clock" in st and "ok" in st["clock"], st
    return "database selftest relClock ok (Uhr falsch -> nichts geloescht, Uhr ok -> aufgeraeumt, ohne Pruefer wie bisher, owns monotonic)"


class _Retention:
    def __init__(self, every_s=RETENTION_S, first_s=RETENTION_FIRST_S, name="lz-retention"):
        self.every_s, self.first_s, self.name = every_s, first_s, name
        self.lock = _ret_threading.Lock()
        self.th = None
        self.quiet = False
        self.stop = False
        self.path = None
        self.extra = {}
        self.maint = _Maint()   # relDb: Checkpoint/quick_check im selben Faden (nicht bei Test-Instanzen: maint = None)
        self.clock_last = None   # relClock: (ok, Pruefer) des letzten Laufs - Journalmeldung nur bei Wechsel
        self.clock_why = None
        self.mono_ref = time.monotonic()   # relClock: letzter Lebenszeichen-Zeitpunkt (monoton) fuer owns()
        self.st = {"started": None, "restarts": 0, "n": 0, "t": None, "last": None, "err": None, "first": None}

    def run(self, now=None, path=None):
        path = path or self.path or DB_PATH
        now = int(now or time.time())
        t0 = time.monotonic()
        out = {}
        ck_ok, ck_why = _clock_gate(self)   # relClock: Uhr unplausibel -> nichts loeschen (auch nicht die Zusatz-Aufraeumer)
        if not ck_ok:
            out["clock_pause"] = ck_why[:80]
        try:
            if ck_ok:
                out.update(cleanup(now, path))
        except Exception as e:
            out["err_base"] = str(e)[:80]
        for k, fn in (("t2", cleanup_t2), ("t3", cleanup_t3)):
            if not ck_ok:
                break
            try:
                out.update(fn(now, path) or {})
            except Exception as e:
                out["err_" + k] = str(e)[:80]
        for k, fn in sorted(self.extra.items()):
            if not ck_ok:
                break
            try:
                out[k] = fn(now, path)
            except Exception as e:
                out[k] = None
                out["err_" + k] = str(e)[:80]
        if self.maint is not None:
            try:
                self.maint.tick(path)   # relDb: wirft nie; aendert keine Daten
            except Exception as e:
                out["err_maint"] = str(e)[:80]
        ms = int((time.monotonic() - t0) * 1000)
        self.mono_ref = time.monotonic()
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
            self.mono_ref = time.monotonic()
            return True

    def owns(self, path=None):
        try:
            if not self.alive() or self.path is None:
                return False
            if os.path.realpath(path or DB_PATH) != os.path.realpath(self.path):
                return False
            return time.monotonic() - self.mono_ref <= self.first_s + 3 * self.every_s   # relClock: monoton statt Wanduhr
        except Exception:
            return False

    def status(self):
        return {"alive": self.alive(), "path": self.path, "every_s": self.every_s, "keep_events_after_expiry_s": KEEP_EVENTS_HIST_S,
                "extra": sorted(self.extra), "maint": (self.maint.status() if self.maint is not None else None),
                "clock": {"ok": (self.clock_last[0] if self.clock_last else None), "why": self.clock_why, "pruefer": (self.clock_last[1] if self.clock_last else None)},
                "alarm_sync": sync_status(),   # secXml: sichtbar in /api/sdr/live (db.retention.alarm_sync)
                **{k: self.st[k] for k in ("started", "restarts", "n", "t", "last", "err", "first")}}


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
        ck_ok, ck_why, _chk = _clock_state()   # relClock
        if not ck_ok:
            return {"faden": "direkt", "clock_pause": ck_why[:80]}
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
    r.maint = None
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

# ---------------------------------------------------------------- sqlB (Transport prepper-sdr -> Dashboard ueber lagezentrum.db, zusaetzlich zu JSON)
# Tabelle state: je Schluessel genau eine Zeile (Upsert, waechst nicht): sdr_status, broadcast_state (Text = exakt der JSON-Inhalt der Datei),
# sqlb_writer (Zaehler des Schreibfadens in prepper-sdr). state_get liest nur (mode=ro, kurzer Timeout) und meldet Fehler statt zu werfen.
STATE_SQL = "CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, ts INTEGER NOT NULL, src_t REAL, json TEXT, writer TEXT, pid INTEGER, n INTEGER DEFAULT 0)"
_state_ok = set()


def state_put(key, text, src_t=None, path=None, writer="prepper-sdr"):
    """Eine Zeile je Schluessel schreiben (Upsert). -> True/False"""
    path = path or DB_PATH
    try:
        now = time.time()
        con = connect(path)
        try:
            with con:
                if path not in _state_ok:
                    con.execute(STATE_SQL)
                con.execute("INSERT INTO state(key, ts, src_t, json, writer, pid, n) VALUES(?, ?, ?, ?, ?, ?, 1) ON CONFLICT(key) DO UPDATE SET "
                            "ts=excluded.ts, src_t=excluded.src_t, json=excluded.json, writer=excluded.writer, pid=excluded.pid, n=state.n+1",
                            (str(key), int(now), float(src_t if src_t is not None else now), str(text), str(writer)[:20], os.getpid()))
        finally:
            con.close()
        _state_ok.add(path)
        return True
    except Exception as e:
        _log("state %s:" % key, e)
        return False


def state_get(key, path=None, timeout=1.0):
    """Nur lesen (mode=ro, kurzer Timeout). -> {"ok": True, "ts", "src_t", "text", "n"} | {"ok": False, "err"}"""
    path = path or DB_PATH
    try:
        if not os.path.exists(path):
            return {"ok": False, "err": "keine Datenbank"}
        from urllib.parse import quote
        con = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(path)), uri=True, timeout=timeout, factory=_Con)
        try:
            con.execute("PRAGMA busy_timeout=%d" % int(timeout * 1000))
            r = con.execute("SELECT ts, src_t, json, n FROM state WHERE key=?", (str(key),)).fetchone()
        finally:
            con.close()
        if not r:
            return {"ok": False, "err": "keine DB-Zeile"}
        return {"ok": True, "ts": r[0], "src_t": r[1], "text": r[2], "n": r[3]}
    except Exception as e:
        return {"ok": False, "err": str(e)[:100]}


def selftest_state():
    import tempfile
    d = tempfile.mkdtemp(prefix="lzstate-")
    p = os.path.join(d, "s.db")
    assert state_get("x", p)["err"] == "keine Datenbank" and not os.path.exists(p)          # Lesen legt nie eine DB an
    assert migrate(p) and state_get("x", p)["ok"] is False
    assert state_put("sdr_status", '{"t": 1}', 100.5, p) and state_put("sdr_status", '{"t": 2}', 101.5, p)
    r = state_get("sdr_status", p)
    assert r["ok"] and r["text"] == '{"t": 2}' and r["src_t"] == 101.5 and r["n"] == 2, r
    con = connect(p)
    assert con.execute("SELECT COUNT(*) FROM state").fetchone()[0] == 1                       # eine Zeile je Schluessel
    con.execute("BEGIN EXCLUSIVE")                                                            # DB gesperrt -> Lesen meldet Fehler, wirft nicht
    t0 = time.time()
    r2 = state_get("sdr_status", p, timeout=0.3)
    con.rollback()
    con.close()
    assert time.time() - t0 < 3, "Timeout zu lang"
    return "database selftest sqlB ok (state: eine Zeile je Schluessel, Lesen nur ro ohne Anlegen, gesperrt -> %s)" % ("Fehler gemeldet" if not r2["ok"] else "WAL-Lesen trotz Sperre")

if __name__ == "__main__":
    print(selftest())
    print(selftest_t2())
    print(selftest_t3())
    print(selftest_retention())
    print(selftest_state())
    print(selftest_maint())
    print(selftest_clock())
    print(selftest_sync())
SXM_DB_EOF
EXPECT_XML="f77305fc17ed2f770175308c6558e0ddd0932c1819e3da8056075cccb11a50e6"
cat > "$W/lage_xml.py" << 'SXM_XML_EOF'
#!/usr/bin/env python3
"""lage_xml.py (secHard commit24, secXml): gehaertetes Parsen externer XML-Feeds (Apotheken-Notdienst, Nachrichten-RSS). SEC-10/SEC-11.

Dieses Modul tut nichts von selbst: dashboard.py ruft es an den zwei XML-Stellen auf (Einbau: eigener Folgepatch der Dashboard-Serie, siehe REPORT-secxml.md).

  fetch_root(url, quelle, timeout, headers)   Abruf mit Obergrenze 2 MiB UND Gesamtzeit, Parsen mit defusedxml, ein Aufruf statt requests.get + ET.fromstring
  parse(roh, quelle)                          Bytes/Text -> Element (BOM weg, Obergrenze, defusedxml); wirft XmlRejected
  safe_fromstring(daten, max_bytes, quelle)   Ersatz fuer xml.etree.ElementTree.fromstring (gleiches Ergebnis, ein Element)
  limited_content(antwort, max_bytes, ...)    liest eine requests-Antwort (stream=True) mit Obergrenze statt r.content
  status()                                    ehrliche Statusmeldung: Parser, Version, Grenze, Zaehler abgelehnter Antworten

Festlegungen (Entscheidung Frank, 25.10.2026):
  - Obergrenze fest 2 MiB (MAX_BYTES). Eine Antwort darueber wird verworfen (auch entpackt: ein gzip-Paket, das darueber waechst, wird abgebrochen). Aufrufer duerfen die Grenze
    nur VERKLEINERN (Tests), nie vergroessern.
  - Mit defusedxml: Entity-Deklarationen und externe Verweise werden abgelehnt (DTD bleibt erlaubt, RSS hat oft eine). Ohne defusedxml: Rueckfall auf xml.etree MIT
    Groessenlimit und einer eigenen Sperre gegen <!ENTITY (auch UTF-16), und das steht in status() und einmal im Journal (kein stilles Weitermachen). Es wird nichts installiert.
  - Eine Ablehnung stuerzt nichts ab: XmlRejected ist eine Unterklasse von xml.etree.ElementTree.ParseError (also SyntaxError); die vorhandenen except-Bloecke der Aufrufer
    fangen sie wie jeden anderen Fehler (leere Liste/Rueckfall, der Wert vor dem Fehler bleibt ueber den vorhandenen Zwischenspeicher erhalten).
  - Meldungen im Journal sind je Quelle ratenbegrenzt (hoechstens eine alle 10 Minuten, dazu die Zahl der unterdrueckten); status() zaehlt alles.
"""
import sys
import threading
import time
import xml.etree.ElementTree as ET

try:
    import defusedxml as _DX
    from defusedxml import ElementTree as _DET
    from defusedxml import DefusedXmlException as _DXE
    HARD = True
except Exception:   # nicht installiert oder unbrauchbar -> Rueckfall (ehrlich gemeldet)
    _DX = None
    _DET = None
    _DXE = None
    HARD = False

MAX_BYTES = 2 * 1024 * 1024          # fest: 2 MiB (Entscheidung Frank); groesser wird verworfen
MAX_BYTES_DEFAULT = MAX_BYTES        # Name aus commit24 (Rueckwaertsverbindung)
MAX_SECONDS = 30.0                   # Gesamtzeit eines Abrufs (timeout= von requests gilt je Leseschritt, nicht insgesamt)
REPORT_EVERY_S = 600.0               # Journal: je Quelle hoechstens eine Meldung alle 10 Minuten
_noted = False
_lock = threading.Lock()
_rep = {}                            # quelle -> {"n": gezaehlt, "t": letzte Ausgabe (monotonic), "skip": seither unterdrueckt, "last": letzter Grund}


class XmlRejected(ET.ParseError):
    """XML abgelehnt (zu gross, zu langsam, gefaehrliche Konstrukte)."""


def _version():
    try:
        return str(_DX.__version__)
    except Exception:
        return None


def status():
    with _lock:
        rej = {k: {"n": v["n"], "last": v["last"]} for k, v in sorted(_rep.items())}
    return {
        "hard": HARD,
        "backend": "defusedxml" if HARD else "xml.etree (Rueckfall: defusedxml fehlt, nur Groessenlimit und Entity-Sperre)",
        "version": _version() if HARD else None,
        "max_bytes": MAX_BYTES,
        "abgelehnt": rej,
        "msg": ("defusedxml %s aktiv: Entity-Deklarationen und externe Verweise werden abgelehnt, Grenze %d KiB" % (_version(), MAX_BYTES // 1024) if HARD else
                "defusedxml ist nicht im venv: es gilt der bisherige Parser xml.etree mit Groessenlimit %d KiB und Entity-Sperre (kein weiterer Schutz ueber expat hinaus)" % (MAX_BYTES // 1024)),
    }


def _note_once():
    global _noted
    if not _noted:
        _noted = True
        print("lage_xml: " + status()["msg"], file=sys.stderr, flush=True)


def _reject(quelle, grund):
    """Zaehlt, meldet ratenbegrenzt (je Quelle), liefert die Ausnahme zum Werfen."""
    q = str(quelle or "?")[:40]
    now = time.monotonic()
    out = None
    with _lock:
        e = _rep.setdefault(q, {"n": 0, "t": None, "skip": 0, "last": None})
        e["n"] += 1
        e["last"] = str(grund)[:160]
        if e["t"] is None or now - e["t"] >= REPORT_EVERY_S:
            out = "lage_xml: %s abgelehnt: %s%s" % (q, e["last"], (" (+%d weitere seit der letzten Meldung)" % e["skip"]) if e["skip"] else "")
            e["t"] = now
            e["skip"] = 0
        else:
            e["skip"] += 1
    if out:
        print(out, file=sys.stderr, flush=True)
    return XmlRejected(str(grund))


def _limit(max_bytes):
    """Wirksame Grenze: nie groesser als MAX_BYTES, Aufrufer duerfen nur verkleinern."""
    if max_bytes is None:
        return MAX_BYTES
    return max(0, min(int(max_bytes), MAX_BYTES))


def _size(daten):
    return len(daten.encode("utf-8")) if isinstance(daten, str) else len(daten)


def _has_entity_decl(roh):
    """Rueckfall ohne defusedxml: Entity-Deklarationen gibt es nur als '<!ENTITY' (Gross), auch in UTF-16 (beide Byte-Reihenfolgen)."""
    b = roh.encode("utf-8") if isinstance(roh, str) else bytes(roh)
    return any(m in b for m in (b"<!ENTITY", "<!ENTITY".encode("utf-16-le"), "<!ENTITY".encode("utf-16-be")))


def safe_fromstring(daten, max_bytes=None, quelle=None):
    lim = _limit(max_bytes)
    n = _size(daten)
    if n > lim:
        raise _reject(quelle, "XML zu gross: %d Bytes (Grenze %d)" % (n, lim))
    if HARD:
        try:
            return _DET.fromstring(daten, forbid_dtd=False, forbid_entities=True, forbid_external=True)
        except _DXE as e:
            raise _reject(quelle, "XML abgelehnt (%s)" % type(e).__name__) from None
    _note_once()
    if _has_entity_decl(daten):
        raise _reject(quelle, "XML abgelehnt (Entity-Deklaration, Rueckfall ohne defusedxml)")
    return ET.fromstring(daten)


def parse(roh, quelle=None, max_bytes=None):
    """Bytes oder Text -> Element. UTF-8-BOM wird entfernt (wie bisher im Dashboard), Rest wie safe_fromstring."""
    if isinstance(roh, (bytes, bytearray)) and bytes(roh[:3]) == b"\xef\xbb\xbf":
        roh = bytes(roh[3:])
    return safe_fromstring(roh, max_bytes, quelle)


def limited_content(antwort, max_bytes=None, chunk=65536, quelle=None, max_seconds=None):
    """Bytes einer requests-Antwort (mit stream=True geholt) lesen; bricht bei Ueberschreitung der Groesse (entpackt!) oder der Gesamtzeit ab und schliesst die Antwort."""
    lim = _limit(max_bytes)
    secs = MAX_SECONDS if max_seconds is None else float(max_seconds)
    try:
        cl = int(antwort.headers.get("Content-Length") or 0)
    except Exception:
        cl = 0
    if cl > lim:
        antwort.close()
        raise _reject(quelle, "Antwort zu gross: Content-Length %d (Grenze %d)" % (cl, lim))
    t0 = time.monotonic()
    buf = bytearray()
    for part in antwort.iter_content(chunk_size=chunk):
        buf += part
        if len(buf) > lim:
            antwort.close()
            raise _reject(quelle, "Antwort zu gross: mehr als %d Bytes" % lim)
        if time.monotonic() - t0 > secs:
            antwort.close()
            raise _reject(quelle, "Antwort zu langsam: mehr als %.1f s" % secs)
    return bytes(buf)


def fetch_root(url, quelle, timeout=15, headers=None, max_bytes=None, getter=None):
    """Ersatz fuer 'r = requests.get(url, ...); r.raise_for_status(); ET.fromstring(r.content)': Abruf mit stream=True, Obergrenze, Gesamtzeit, defusedxml. -> Element.
    HTTP-Fehler/Netzfehler werden wie bei requests geworfen (der Aufrufer faengt sie wie bisher); Ablehnungen als XmlRejected (ParseError)."""
    if getter is None:
        import requests
        getter = requests.get
    r = getter(url, timeout=timeout, headers=headers or {}, stream=True)
    try:
        r.raise_for_status()
        raw = limited_content(r, max_bytes, quelle=quelle)
    finally:
        try:
            r.close()
        except Exception:
            pass
    return parse(raw, quelle, max_bytes)


def selftest():
    import contextlib
    import io
    with contextlib.redirect_stderr(io.StringIO()):   # die absichtlichen Ablehnungen des Tests sollen nicht ins Journal/auf den Bildschirm
        return _selftest()


def _selftest():
    global HARD, _noted
    assert issubclass(XmlRejected, ET.ParseError) and issubclass(XmlRejected, SyntaxError)   # die vorhandenen except-Bloecke der Aufrufer fangen sie
    assert MAX_BYTES == 2 * 1024 * 1024
    ok_xml = b'<?xml version="1.0"?><rss><channel><item><title>T\xc3\xa4st</title></item></channel></rss>'
    laughs = (b'<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">'
              b'<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><l>&c;</l>')
    quad = (b'<?xml version="1.0"?><!DOCTYPE q [<!ENTITY a "aaaaaaaaaa">]><q>&a;&a;&a;</q>')
    ext = b'<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><x>&e;</x>'
    doctype_only = b'<?xml version="1.0"?><!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" "http://my.netscape.com/publish/formats/rss-0.91.dtd"><rss version="0.91"><channel><title>x</title></channel></rss>'
    saved, saved_rep, saved_t = HARD, dict(_rep), REPORT_EVERY_S
    try:
        for mode in ([True, False] if saved else [False]):
            HARD = mode
            _noted = False
            r = safe_fromstring(ok_xml)
            assert r.tag == "rss" and r.find("channel/item/title").text == "T\u00e4st"
            assert safe_fromstring(ok_xml.decode("utf-8")).tag == "rss"    # Text statt Bytes geht (ohne encoding-Angabe im Kopf)
            assert parse(b"\xef\xbb\xbf" + ok_xml).tag == "rss"            # BOM wird entfernt
            try:
                safe_fromstring(b"x" * 1000, max_bytes=999)
                raise AssertionError("zu grosses XML nicht abgelehnt")
            except XmlRejected:
                pass
            assert safe_fromstring(b"<a/>" + b" " * 10, max_bytes=14).tag == "a"      # genau an der Grenze ok
            # die Grenze laesst sich nie vergroessern: ueber 2 MiB wird auch bei max_bytes=10**9 verworfen, genau 2 MiB geht
            big = b"<a>" + b"x" * (MAX_BYTES - 7) + b"</a>"
            assert len(big) == MAX_BYTES and safe_fromstring(big, max_bytes=10 ** 9).tag == "a"
            try:
                safe_fromstring(big + b" ", max_bytes=10 ** 9)
                raise AssertionError("2 MiB + 1 nicht abgelehnt")
            except XmlRejected:
                pass
            for bad in (laughs, quad, ext, laughs.decode("utf-8")):
                try:
                    safe_fromstring(bad)
                    raise AssertionError("Entity-Deklaration nicht abgelehnt (mode=%s)" % mode)
                except XmlRejected:
                    pass
            u16 = ('<?xml version="1.0" encoding="UTF-16"?>' + laughs.decode("utf-8").split("?>", 1)[1]).encode("utf-16")
            try:
                safe_fromstring(u16)
                raise AssertionError("UTF-16-Entity-Bombe nicht abgelehnt (mode=%s)" % mode)
            except XmlRejected:
                pass
            except ET.ParseError:
                pass   # auch ein Parserfehler ist eine Ablehnung (kein Element wird geliefert)
            assert safe_fromstring(doctype_only).tag == "rss"                           # DTD ohne Entities bleibt erlaubt
            if mode:
                assert status()["hard"] is True and status()["version"]
            else:
                assert status()["hard"] is False and "Rueckfall" in status()["backend"]
                assert _noted is True
        HARD = saved
        # Ratenbegrenzung: je Quelle eine Zeile, der Rest wird gezaehlt
        import io
        import contextlib
        _rep.clear()
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            for i in range(25):
                try:
                    safe_fromstring(b"x" * 50, max_bytes=10, quelle="testq")
                except XmlRejected:
                    pass
            try:
                safe_fromstring(b"y" * 50, max_bytes=10, quelle="andere")
            except XmlRejected:
                pass
        lines = [x for x in buf.getvalue().splitlines() if "abgelehnt" in x]
        assert len(lines) == 2 and "testq" in lines[0] and "andere" in lines[1], lines
        assert status()["abgelehnt"]["testq"]["n"] == 25 and status()["abgelehnt"]["andere"]["n"] == 1
        globals()["REPORT_EVERY_S"] = 0.0           # Frist abgelaufen -> naechste Meldung nennt die unterdrueckten
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            try:
                safe_fromstring(b"x" * 50, max_bytes=10, quelle="testq")
            except XmlRejected:
                pass
        assert "(+24 weitere seit der letzten Meldung)" in buf.getvalue(), buf.getvalue()
    finally:
        HARD = saved
        globals()["REPORT_EVERY_S"] = saved_t
        _rep.clear()
        _rep.update(saved_rep)

    class FakeResp:
        def __init__(self, parts, cl=None, status=200, delay=0.0):
            self._p = parts
            self.headers = {"Content-Length": str(cl)} if cl is not None else {}
            self.closed = False
            self.status = status
            self.delay = delay

        def iter_content(self, chunk_size=0):
            for p in self._p:
                if self.delay:
                    time.sleep(self.delay)
                yield p

        def close(self):
            self.closed = True

        def raise_for_status(self):
            if self.status >= 400:
                raise RuntimeError("HTTP %d" % self.status)

    assert limited_content(FakeResp([b"ab", b"cd"]), 4) == b"abcd"
    r = FakeResp([b"abc", b"def"])
    try:
        limited_content(r, 5)
        raise AssertionError("Grenze nicht erkannt")
    except XmlRejected:
        assert r.closed
    r = FakeResp([b"a"], cl=10 ** 9)
    try:
        limited_content(r, 100)
        raise AssertionError("Content-Length nicht erkannt")
    except XmlRejected:
        assert r.closed
    r = FakeResp([b"a"] * 50, delay=0.02)
    try:
        limited_content(r, 1000, max_seconds=0.2)
        raise AssertionError("Gesamtzeit nicht erkannt")
    except XmlRejected:
        assert r.closed
    # fetch_root: Erfolg, HTTP-Fehler (wie requests), zu gross, immer wird die Antwort geschlossen
    got = {}

    def getter(url, timeout=None, headers=None, stream=None):
        got.update(url=url, timeout=timeout, headers=headers, stream=stream)
        return got["resp"]

    got["resp"] = FakeResp([b"<rss><channel/>", b"</rss>"])
    assert fetch_root("http://x", "t", timeout=7, headers={"A": "b"}, getter=getter).tag == "rss"
    assert got["stream"] is True and got["timeout"] == 7 and got["headers"] == {"A": "b"} and got["resp"].closed
    got["resp"] = FakeResp([b"<a/>"], status=503)
    try:
        fetch_root("http://x", "t", getter=getter)
        raise AssertionError("HTTP-Fehler verschluckt")
    except RuntimeError:
        assert got["resp"].closed
    got["resp"] = FakeResp([b"x" * 100], cl=100)
    try:
        fetch_root("http://x", "t", max_bytes=10, getter=getter)
        raise AssertionError("zu grosse Antwort nicht abgelehnt")
    except XmlRejected:
        assert got["resp"].closed
    _rep.clear()
    _rep.update(saved_rep)
    return "lage_xml selftest ok (Parser: %s, Grenze %d KiB fest, Entity-Bomben/UTF-16/extern abgelehnt, Ratenbegrenzung, Gesamtzeit)" % (
        "defusedxml und Rueckfall" if saved else "nur Rueckfall, defusedxml nicht vorhanden", MAX_BYTES // 1024)


if __name__ == "__main__":
    if "--status" in sys.argv[1:]:
        print(status())
    else:
        print(selftest())
SXM_XML_EOF
EXPECT_REQS="660be03bac621e1b717f02f0bcb8368e7eab3037e51d0e6af5ea74decbd0b50c"
cat > "$W/lage_reqs.py" << 'SXM_REQS_EOF'
#!/usr/bin/env python3
"""lage_reqs.py (secHard, SEC-10): Abhaengigkeiten des Dashboards pruefen und requirements-Vorlage erzeugen. NUR LESEND - installiert nichts.

  python3 tools/lage_reqs.py check               Fremd-Importe der Projektdateien gegen das venv: installiert (Version) oder FEHLT
  python3 tools/lage_reqs.py vorlage             requirements-Text aus dem venv (Versionen), Hashes als gekennzeichnete Platzhalter
  python3 tools/lage_reqs.py hashes --netz       wie vorlage, Hashes aus PyPI (nur lesender Abruf von pypi.org; Paketname+Version werden uebertragen)
Optionen: --projekt ORDNER (Standard: Ordner ueber tools/), --venv ORDNER (Standard: PROJEKT/venv), --out DATEI (statt Bildschirm; ueberschreibt nie)
Ohne --out wird nur ausgegeben, nichts geschrieben. Die Datei requirements.txt wird nie von selbst angelegt oder ersetzt.
secXml: defusedxml ist gepinnt (PINNED, Version + sha256 des Rades von PyPI): check meldet Soll/Ist, vorlage/hashes schreiben fuer dieses Paket den echten Hash statt eines Platzhalters.
"""
import ast
import json
import os
import subprocess
import sys

SKIP_DIRS = {"venv", "__pycache__", "backups", ".git", "node_modules"}
# secXml (SEC-10/SEC-11): gepinnte Pakete {normalisierter Name: (Version, (sha256 ...))}. Hash = defusedxml-0.7.1-py2.py3-none-any.whl auf PyPI.
PINNED = {"defusedxml": ("0.7.1", ("a352e7e428770286cc899e2542b6cdaedb2b4953ff269a210103ec58f6198a61",))}
VENV_SCRIPT = r'''
import importlib.metadata as md, importlib.util, json, sys
mods = json.loads(sys.argv[1])
dists = []
for d in md.distributions():
    n = d.metadata["Name"] or ""
    if not n:
        continue
    direct = d.read_text("direct_url.json")
    dists.append({"name": n, "version": d.version, "direct": bool(direct)})
pd = md.packages_distributions()
res = {}
for m in mods:
    try:
        found = importlib.util.find_spec(m) is not None
    except Exception:
        found = False
    res[m] = {"found": found, "dists": sorted(set(pd.get(m, [])))}
print(json.dumps({"python": sys.version.split()[0], "dists": dists, "mods": res}))
'''


def py_files(root):
    out = []
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIRS and not d.startswith(".")]
        for f in fn:
            if f.endswith(".py"):
                out.append(os.path.join(dp, f))
    return sorted(out)


def local_names(root):
    names = set()
    for e in os.listdir(root):
        p = os.path.join(root, e)
        if e.endswith(".py"):
            names.add(e[:-3])
        elif os.path.isdir(p) and e not in SKIP_DIRS:
            names.add(e)
    return names


def scan_imports(root):
    """-> {top_level_name: {"optional": bool, "files": set}}; optional = nur innerhalb try/except ImportError bzw. in Funktionen mit try."""
    std = set(sys.stdlib_module_names) | {"__future__"}
    loc = local_names(root)
    found = {}
    for f in py_files(root):
        try:
            tree = ast.parse(open(f, encoding="utf-8", errors="replace").read())
        except SyntaxError:
            continue
        guarded = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.Try) and any(
                    (h.type is None) or any(isinstance(x, ast.Name) and x.id in ("ImportError", "ModuleNotFoundError", "Exception") for x in ast.walk(h.type))
                    for h in n.handlers):
                for b in n.body:
                    for x in ast.walk(b):
                        guarded.add(id(x))
        for n in ast.walk(tree):
            names = []
            if isinstance(n, ast.Import):
                names = [a.name.split(".")[0] for a in n.names]
            elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
                names = [n.module.split(".")[0]]
            for m in names:
                if m in std or m in loc:
                    continue
                e = found.setdefault(m, {"optional": True, "files": set()})
                if id(n) not in guarded:
                    e["optional"] = False
                e["files"].add(os.path.relpath(f, root))
    return found


def venv_info(venv, mods):
    py = os.path.join(venv, "bin", "python")
    if not os.access(py, os.X_OK):
        raise SystemExit("venv-Python nicht gefunden: %s (Option --venv ORDNER)" % py)
    p = subprocess.run([py, "-c", VENV_SCRIPT, json.dumps(sorted(mods))], capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise SystemExit("venv-Abfrage fehlgeschlagen: %s" % (p.stderr or p.stdout)[-300:])
    return json.loads(p.stdout)


def norm(n):
    return n.lower().replace("_", "-").replace(".", "-")


def pins(info):
    skip = {"pip", "setuptools", "wheel"}
    out, manual, seen = [], [], set()
    for d in sorted(info["dists"], key=lambda x: norm(x["name"])):
        if norm(d["name"]) in skip or norm(d["name"]) in seen:
            continue
        seen.add(norm(d["name"]))
        (manual if d["direct"] else out).append((d["name"], d["version"]))
    return out, manual


def cmd_check(root, venv):
    imp = scan_imports(root)
    info = venv_info(venv, imp.keys())
    print("Projekt: %s | venv: %s | venv-Python %s" % (root, venv, info["python"]))
    miss = 0
    for m in sorted(imp):
        r = info["mods"][m]
        ds = r["dists"]
        ver = ""
        if ds:
            vs = {norm(d["name"]): d["version"] for d in info["dists"]}
            ver = ", ".join("%s %s" % (d, vs.get(norm(d), "?")) for d in ds)
        art = "optional (try/except ImportError)" if imp[m]["optional"] else "direkt"
        if r["found"]:
            print("  OK     %-14s im venv (%s) | %s | %d Datei(en)" % (m, ver or "Paket unbekannt", art, len(imp[m]["files"])))
        else:
            miss += 1
            print("  FEHLT  %-14s NICHT im venv | %s | %s" % (m, art, ", ".join(sorted(imp[m]["files"]))[:120]))
    have = {norm(d["name"]): d["version"] for d in info["dists"]}
    for n_, (v_, hs_) in sorted(PINNED.items()):
        h_ = have.get(norm(n_))
        print("  Pin    %-14s gepinnt %s (sha256 %s...) - %s" % (n_, v_, hs_[0][:12], "FEHLT im venv" if h_ is None else ("installiert, Version stimmt" if h_ == v_ else "installiert %s (weicht vom Pin ab)" % h_)))
    print("Ergebnis: %d Fremdpakete im Quelltext, %d fehlen im venv. Es wurde nichts installiert." % (len(imp), miss))
    return 1 if miss else 0


def render(root, venv, hashes=None):
    imp = scan_imports(root)
    info = venv_info(venv, imp.keys())
    out, manual = pins(info)
    lines = ["# requirements aus dem venv %s (Python %s) - erzeugt mit tools/lage_reqs.py" % (venv, info["python"])]
    if hashes is None:
        lines.append("# ACHTUNG VORLAGE: Zeilen mit HIER-HASH-EINTRAGEN sind Platzhalter. So NICHT mit pip install --require-hashes benutzen.")
        lines.append("# Echte Hashes: python3 tools/lage_reqs.py hashes --netz --out requirements.neu")
    else:
        lines.append("# Installation (nur wenn noetig, als Benutzer fmg, nie als root): venv/bin/pip install --require-hashes -r requirements.txt")
    direct = {norm(d) for m in imp for d in info["mods"][m]["dists"]}
    for name, ver in out:
        tag = "  # direkt importiert" if norm(name) in direct else ""
        pin = PINNED.get(norm(name))
        if pin and pin[0] == ver:   # secXml: gepinnt, echter Hash aus dem Quelltext (kein Platzhalter, kein Netz)
            lines.append("%s==%s \\\n%s%s" % (name, ver, " \\\n".join("    --hash=sha256:%s" % h for h in pin[1]), tag + "  # gepinnt (secXml)"))
        elif hashes is None:
            lines.append("%s==%s \\\n    --hash=sha256:HIER-HASH-EINTRAGEN%s" % (name, ver, tag))
        else:
            hs = hashes.get((norm(name), ver))
            if hs:
                lines.append("%s==%s \\\n%s%s" % (name, ver, " \\\n".join("    --hash=sha256:%s" % h for h in hs), tag))
            else:
                lines.append("# KEIN HASH GEFUNDEN: %s==%s (nicht auf PyPI?) - manuell pruefen" % (name, ver))
    for name, ver in manual:
        lines.append("# manuell pruefen (lokal/URL installiert, nicht aus PyPI): %s==%s" % (name, ver))
    for m in sorted(imp):
        if not info["mods"][m]["found"]:
            lines.append("# FEHLT im venv: %s (importiert in %s)" % (m, ", ".join(sorted(imp[m]["files"]))[:100]))
    return "\n".join(lines) + "\n", out


def pypi_hashes(out, fetch=None):
    import urllib.request
    fetch = fetch or (lambda u: json.load(urllib.request.urlopen(u, timeout=20)))
    res = {}
    for name, ver in out:
        try:
            d = fetch("https://pypi.org/pypi/%s/%s/json" % (name, ver))
            hs = sorted({f["digests"]["sha256"] for f in d.get("urls", []) if f.get("digests", {}).get("sha256")})
            if hs:
                res[(norm(name), ver)] = hs
        except Exception:
            pass
    return res


def main(argv):
    a = list(argv)
    opts = {"--projekt": None, "--venv": None, "--out": None}
    netz = "--netz" in a
    if netz:
        a.remove("--netz")
    for k in list(opts):
        if k in a:
            i = a.index(k)
            opts[k] = a[i + 1] if i + 1 < len(a) else None
            del a[i:i + 2]
    cmd = a[0] if a else ""
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(opts["--projekt"] or os.path.dirname(here))
    venv = os.path.abspath(opts["--venv"] or os.path.join(root, "venv"))
    if cmd == "check":
        return cmd_check(root, venv)
    if cmd in ("vorlage", "hashes"):
        if cmd == "hashes" and not netz:
            print("hashes braucht --netz (ruft pypi.org lesend ab). Ohne Netz: vorlage.")
            return 2
        if cmd == "hashes":
            _, out = render(root, venv)
            text, _ = render(root, venv, pypi_hashes(out))
        else:
            text, _ = render(root, venv)
        if opts["--out"]:
            if os.path.exists(opts["--out"]):
                print("STOP: %s gibt es schon - es wird nie ueberschrieben." % opts["--out"])
                return 2
            with open(opts["--out"], "x", encoding="utf-8") as f:
                f.write(text)
            print("geschrieben: %s (%d Zeilen)" % (opts["--out"], text.count("\n")))
        else:
            sys.stdout.write(text)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
SXM_REQS_EOF
EXPECT_VORL="a2546207159f3466b509f56386eee6f99f7520dafb8f2e7470aec2ef48432435"
cat > "$W/requirements.txt.vorlage" << 'SXM_VORL_EOF'
# requirements.txt.VORLAGE (secHard, SEC-10) - KEINE benutzbare requirements.txt, nichts davon wird automatisch angewendet.
# Stand: Fremd-Importe aus dem Quelltext (Branch kaeswasser-lage-monitor); Versionen und Hashes gibt es nur im venv auf dem Pi.
# So wird daraus die echte Datei (alles nur lesend, nichts wird installiert):
#   1. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py check                     zeigt, was im venv fehlt (z. B. psutil, defusedxml)
#   2. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py vorlage                   Versionen aus dem venv, Hashes als Platzhalter
#   3. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py hashes --netz --out /home/fmg/requirements.neu     echte Hashes von PyPI (lesender Abruf)
#   4. Ergebnis pruefen und erst dann als requirements.txt einchecken. Pruefung ohne Installation: venv/bin/pip install --dry-run --require-hashes -r DATEI
# Zeilen mit HIER-... sind Platzhalter und duerfen NICHT mit pip install benutzt werden.
# secXml: defusedxml ist bereits echt gepinnt (Version + Hash von PyPI); als eigene benutzbare Datei: requirements-defusedxml.txt
#
# Direkte Importe (nach Haeufigkeit/Wichtigkeit):
Flask==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
requests==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
ntplib==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
psutil==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
numpy==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
meshtastic==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
PyPubSub==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
defusedxml==0.7.1 \
    --hash=sha256:a352e7e428770286cc899e2542b6cdaedb2b4953ff269a210103ec58f6198a61
# Optional (nur wenn im venv vorhanden; Importe sind mit try/except abgesichert):
#   Pillow (PIL), gpiozero, sgp4 (liegt auch als Quelltext in sdr_lib/)
#   (defusedxml: seit secXml Pflicht fuer lage_xml.py und oben gepinnt; ohne gilt nur der Rueckfall mit Groessenlimit und Entity-Sperre)
# Dazu kommen die abhaengigen Pakete (Werkzeug, Jinja2, urllib3, certifi, protobuf, ...): lage_reqs.py vorlage nimmt ALLE Pakete des venv auf.
# Hinweis: Die Bridges (mesh_bridge*.py) koennen eine andere Python-Umgebung nutzen als das Dashboard-venv - dann dafuer eine eigene Liste fuehren.
SXM_VORL_EOF
EXPECT_RDX="d0a3b9431d039c006faad18bcaa0d3b7d2cb1f965d87790ac7b82511973ce1f3"
cat > "$W/requirements-defusedxml.txt" << 'SXM_RDX_EOF'
# requirements-defusedxml.txt (secXml, SEC-10/SEC-11) - benutzbar mit --require-hashes. Nur dieses eine Paket, rein Python, ohne Abhaengigkeiten.
# Rad: defusedxml-0.7.1-py2.py3-none-any.whl (PyPI, 25604 Bytes). Der Apply secXml installiert es offline aus dem eingebetteten, per Hash geprueften Rad:
#   /home/fmg/prepper-dashboard/venv/bin/python -m pip install --no-index --no-deps --require-hashes --find-links ORDNER_MIT_DEM_RAD -r requirements-defusedxml.txt
# Mit Netz (PyPI) geht derselbe Pin ohne --no-index --find-links. Als Benutzer fmg, nie als root. Rueckgaengig: venv/bin/python -m pip uninstall -y defusedxml
defusedxml==0.7.1 \
    --hash=sha256:a352e7e428770286cc899e2542b6cdaedb2b4953ff269a210103ec58f6198a61
SXM_RDX_EOF
EXPECT_WHL="01d40056b184635427427466d884e473ffdcb9c9ea6ae2dd752a685772de6499"
cat > "$W/defusedxml.whl.b64" << 'SXM_WHL_EOF'
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
bWwvY0VsZW1lbnRUcmVlLnB5UEsBAhQDFAAAAAgATlZoUmOfdzSTBAAAxA8AABQAAAAAAAAAAAAA
ALSBEwsAAGRlZnVzZWR4bWwvY29tbW9uLnB5UEsBAhQDFAAAAAgA5KiRThaYzgkDBAAAlA4AABoA
AAAAAAAAAAAAALSB2A8AAGRlZnVzZWR4bWwvZXhwYXRidWlsZGVyLnB5UEsBAhQDFAAAAAgATlZo
UmIFlr3vAgAAlAgAABkAAAAAAAAAAAAAALSBExQAAGRlZnVzZWR4bWwvZXhwYXRyZWFkZXIucHlQ
SwECFAMUAAAACAAElixSUhurjwIGAABMEwAAEgAAAAAAAAAAAAAAtIE5FwAAZGVmdXNlZHhtbC9s
eG1sLnB5UEsBAhQDFAAAAAgANF6OTrEcXqMZAgAAXAcAABUAAAAAAAAAAAAAALSBax0AAGRlZnVz
ZWR4bWwvbWluaWRvbS5weVBLAQIUAxQAAAAIADRejk5VwJaZnQEAAJIEAAAVAAAAAAAAAAAAAAC0
gbcfAABkZWZ1c2VkeG1sL3B1bGxkb20ucHlQSwECFAMUAAAACAA0Xo5OqW5kAvIBAADFBQAAEQAA
AAAAAAAAAAAAtIGHIQAAZGVmdXNlZHhtbC9zYXgucHlQSwECFAMUAAAACABOVmhSClTiMiQGAAD0
FAAAFAAAAAAAAAAAAAAAtIGoIwAAZGVmdXNlZHhtbC94bWxycGMucHlQSwECFAMUAAAACABjV2hS
CC54HMYEAABpCQAAIgAAAAAAAAAAAAAAtIH+KQAAZGVmdXNlZHhtbC0wLjcuMS5kaXN0LWluZm8v
TElDRU5TRVBLAQIUAxQAAAAIAGNXaFI76KFECiwAAAZ/AAAjAAAAAAAAAAAAAAC0gQQvAABkZWZ1
c2VkeG1sLTAuNy4xLmRpc3QtaW5mby9NRVRBREFUQVBLAQIUAxQAAAAIAGNXaFLAp9NYXwAAAG4A
AAAgAAAAAAAAAAAAAAC0gU9bAABkZWZ1c2VkeG1sLTAuNy4xLmRpc3QtaW5mby9XSEVFTFBLAQIU
AxQAAAAIAGNXaFLfZJ9ZDQAAAAsAAAAoAAAAAAAAAAAAAAC0gexbAABkZWZ1c2VkeG1sLTAuNy4x
LmRpc3QtaW5mby90b3BfbGV2ZWwudHh0UEsBAhQDFAAAAAgAY1doUqdWJYjxAgAA9wQAACEAAAAA
AAAAAAAAALQBP1wAAGRlZnVzZWR4bWwtMC43LjEuZGlzdC1pbmZvL1JFQ09SRFBLBQYAAAAAEAAQ
AH8EAABvXwAAAAA=
SXM_WHL_EOF
EXPECT_GUARD="41cc5da9b2d6f4414d81183bd35343ac2c383cc16c01343346ee933d5007c388"
cat > "$W/guard_secxml.py" << 'SXM_GUARD_EOF'
#!/usr/bin/env python3
"""guard_secxml.py - Pruefung fuer secXml (database.py, lage_xml.py, tools/lage_reqs.py, requirements.txt.vorlage, requirements-defusedxml.txt) samt Mutationstest.
  check  DB_NEU DB_BASIS XML REQS VORLAGE REQFILE [--site DIR]   -> Exit 0 = alle Pruefungen ok (AST + Verhalten + Vergleich alt/neu + lokaler HTTP-Test)
  mutate DB_BASIS EDITS_DB XML REQS VORLAGE REQFILE [--site DIR] [--basereqs F] [--basevorlage F]  -> jede Mutation einzeln, jede muss erkannt werden
--site DIR: Ordner mit defusedxml (z. B. pip install --target), damit die harten Pruefungen (Entity-Bombe/extern) mit dem echten Parser laufen.
Alles in Wegwerf-Ordnern (tempfile), Sockets nur 127.0.0.1 auf einem freien Port (nie 5000), kein Zugriff auf echte Dateien.
"""
import ast
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ALARM_FUNCS = ["mesh_seen", "mesh_log_put", "mesh_auto_reserve", "mesh_auto_done", "q_add", "q_set", "upsert_event"]
ALLOWED_SYNC_USERS = set(ALARM_FUNCS) | {"_sync_apply", "_sync_pick", "selftest_sync", "sync_status", "alarm_event"}
PY = sys.executable


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def fdef(tree, name, cls=None):
    body = tree.body
    if cls:
        c = [n for n in body if isinstance(n, ast.ClassDef) and n.name == cls]
        if not c:
            return None
        body = c[0].body
    for n in body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    return None


def seg(src, n):
    return (ast.get_source_segment(src, n) or "") if n is not None else ""


def run(args, cwd, env=None, timeout=180):
    e = dict(os.environ)
    e["PYTHONDONTWRITEBYTECODE"] = "1"
    e.pop("PYTHONPATH", None)
    if env:
        e.update(env)
    p = subprocess.run(args, cwd=cwd, env=e, capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


# ------------------------------------------------------------------ database.py
OPS = r'''
import json, sqlite3, sys
sys.path.insert(0, sys.argv[2])
import database as d
p = sys.argv[1]
assert d.migrate(p) and d.migrate_t2(p) and d.migrate_t3(p)
now = 1800000000
res = {}
for i, sev in enumerate(("warn", "alarm", "info", None, "probe", "unknown")):
    res["ev%d" % i] = d.upsert_event({"source": "NINA", "ext_id": "e%d" % i, "severity": sev, "headline": "h%d" % i, "created": now, "updated": now, "expires": now + 3600}, p)
res["ev_upd"] = d.upsert_event({"source": "NINA", "ext_id": "e0", "severity": "warn", "headline": "neu", "created": now, "updated": now + 5, "expires": now + 7200}, p)
res["seen1"] = d.mesh_seen("a", "m1:0", p, now)
res["seen2"] = d.mesh_seen("a", "m1:0", p, now)
res["known"] = d.mesh_known("a", p)
res["put"] = d.mesh_log_put("b", "m1:0", now, "NINA", "t", True, "nina", p)
res["put2"] = d.mesh_log_put("b", "m1:0", now + 1, "NINA", "t2", False, "nina", p)
res["r1"] = d.mesh_auto_reserve("A1", "b", "ASA", "t", now, p)
res["done0"] = d.mesh_auto_done("A1", False, p)
res["r2"] = d.mesh_auto_reserve("A1", "b", "ASA", "t", now + 99999, p)
res["done1"] = d.mesh_auto_done("A1", True, p)
res["r3"] = d.mesh_auto_reserve("A1", "b", "ASA", "t", now + 199999, p)
q1 = d.q_add("m1", "nina", "t", "hq", now, now, None, None, p)
q2 = d.q_add("m1", "nina_detail", None, None, now, now + 30, q1, "{}", p)
res["q"] = [q1, q2, d.q_add("m1", "nina", "t", "hq", now + 5, now, None, None, p)]
res["qset"] = [d.q_set(q1, p, state="ok", why="gesendet", done=now + 9, tries=1, last_try=now + 9), d.q_set(q2, p, why="wartet"), d.q_set(q1, p)]
res["tel"] = d.insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 2.5, "src_t": now}, p)
res["cnt"] = d.counts(p)
c = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
dump = {}
for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall():
    dump[t] = [list(r) for r in c.execute("SELECT * FROM %s ORDER BY 1" % t).fetchall()]
print(json.dumps({"res": res, "dump": dump}, sort_keys=True, default=str))
'''


def check_db(src, base_src, base_sig=None):
    errs = []
    try:
        t = ast.parse(src)
        b = ast.parse(base_src)
    except SyntaxError as e:
        return ["database.py: Syntaxfehler: %s" % e]
    top = {n.name for n in t.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
    for f in ("alarm_event", "_sync_pick", "_sync_apply", "sync_status", "selftest_sync", "connect", "_exec"):
        if f not in top:
            errs.append("fehlt: %s" % f)
    for n in b.body:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name not in top:
            errs.append("Basis-Funktion entfernt: %s" % n.name)
    if "secXml" not in (ast.get_source_segment(src, t.body[0]) or ""):
        errs.append("Modul-Docstring ohne secXml")
    # Konstanten
    consts = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and isinstance(n.value, ast.Constant):
            consts[n.targets[0].id] = n.value.value
    if consts.get("SYNC_ALARM") != "FULL" or consts.get("SYNC_NORMAL") != "NORMAL":
        errs.append("SYNC_ALARM/SYNC_NORMAL nicht FULL/NORMAL (%r/%r)" % (consts.get("SYNC_ALARM"), consts.get("SYNC_NORMAL")))
    # connect
    cn = fdef(t, "connect")
    if cn is not None:
        a = [x.arg for x in cn.args.args]
        dflt = [getattr(d, "value", "?") for d in cn.args.defaults]
        if a != ["path", "sync"] or dflt != [None, None]:
            errs.append("connect: Signatur nicht (path=None, sync=None): %s %s" % (a, dflt))
        cs = seg(src, cn)
        body_nodes = cn.body[1:] if (cn.body and isinstance(cn.body[0], ast.Expr) and isinstance(getattr(cn.body[0], "value", None), ast.Constant)) else cn.body
        hard = [x for b_ in body_nodes for x in ast.walk(b_)
                if (isinstance(x, ast.Constant) and isinstance(x.value, str) and ("NORMAL" in x.value or "FULL" in x.value or "PRAGMA synchronous" in x.value))
                or (isinstance(x, ast.Name) and x.id in ("SYNC_NORMAL", "SYNC_ALARM"))]
        if "_sync_apply(con, _sync_pick(sync))" not in cs or hard:
            errs.append("connect: synchronous muss ueber _sync_apply(con, _sync_pick(sync)) laufen (kein festes NORMAL/PRAGMA im Rumpf)")
        for must in ("PRAGMA busy_timeout", "_set_wal(con, p)", "con.row_factory = sqlite3.Row", "con.close()", "raise"):
            if must not in cs:
                errs.append("connect: Basisverhalten fehlt: %s" % must)
    ex = fdef(t, "_exec")
    if ex is not None:
        a = [x.arg for x in ex.args.args]
        if a != ["sql", "args", "path", "what", "sync"] or "connect(path, sync)" not in seg(src, ex):
            errs.append("_exec: Signatur/Weitergabe von sync fehlt")
    sa = fdef(t, "_sync_apply")
    if sa is not None:
        s_ = seg(src, sa)
        if 'PRAGMA synchronous=%s" % want' not in s_ or 'con.execute("PRAGMA synchronous")' not in s_ or "_SYNC_CODE[SYNC_ALARM]" not in s_ or "raise" in s_:
            errs.append("_sync_apply: PRAGMA setzen + Rueckpruefung (ohne raise) fehlt")
        if "600" not in s_ or "_sx_log_t" not in s_:
            errs.append("_sync_apply: Meldung nicht ratenbegrenzt")
    sp = fdef(t, "_sync_pick")
    if sp is not None and "SYNC_NORMAL if s == SYNC_NORMAL else SYNC_ALARM" not in seg(src, sp):
        errs.append("_sync_pick: Unbekanntes darf nie zu NORMAL abschwaechen")
    ae = fdef(t, "alarm_event")
    if ae is not None and '!= "info"' not in seg(src, ae):
        errs.append('alarm_event: muss alles ausser "info" einschliessen')
    # Wer benutzt SYNC_ALARM?
    users = {}
    for n in t.body:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
            for x in ast.walk(n):
                if isinstance(x, ast.Name) and x.id == "SYNC_ALARM":
                    users.setdefault(n.name, 0)
                    users[n.name] += 1
    for f in ALARM_FUNCS:
        if users.get(f, 0) < 1:
            errs.append("Alarmpfad: %s benutzt SYNC_ALARM nicht" % f)
    for f in sorted(set(users) - ALLOWED_SYNC_USERS):
        errs.append("SYNC_ALARM ausserhalb des Alarmpfads benutzt: %s" % f)
    for f in ALARM_FUNCS:
        n = fdef(t, f)
        if n is not None:
            calls = [c for c in ast.walk(n) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id in ("connect", "_exec")]
            if not calls or not all(any(isinstance(y, ast.Name) and y.id == "SYNC_ALARM" for y in ast.walk(c)) for c in calls):
                errs.append("Alarmpfad: %s: jeder connect/_exec-Aufruf muss SYNC_ALARM tragen" % f)
    ue = seg(src, fdef(t, "upsert_event"))
    if 'SYNC_ALARM if alarm_event(row["severity"]) else None' not in ue:
        errs.append("upsert_event: FULL nur fuer alarm_event(severity), sonst NORMAL")
    # Status und Hauptprogramm
    if '"alarm_sync": sync_status()' not in seg(src, fdef(t, "status", "_Retention")):
        errs.append("_Retention.status ohne alarm_sync")
    main_src = src[src.rfind('if __name__ == "__main__":'):]
    if "print(selftest_sync())" not in main_src:
        errs.append("__main__ ruft selftest_sync nicht auf")
    # Importhinweis nur nach stderr
    if "file=_sx_sys.stderr" not in src:
        errs.append("Import-Hinweis muss nach stderr gehen (stdout-Ausgaben von Werkzeugen nicht stoeren)")
    if errs:
        return errs
    # Verhalten: Selbsttest, Vergleich alt/neu
    d = tempfile.mkdtemp(prefix="sxg-db-")
    try:
        for sub, text in (("neu", src), ("alt", base_src)):
            os.makedirs(os.path.join(d, sub))
            pathlib.Path(d, sub, "database.py").write_text(text, encoding="utf-8")
        rc, out = run([PY, "database.py"], os.path.join(d, "neu"))
        if rc != 0 or "database selftest secXml ok" not in out:
            return ["database.py Selbsttest (neu): Exit %d: %s" % (rc, out[-400:])]
        dumps = {}
        for sub in ("neu", "alt"):
            rc, out = run([PY, "-c", OPS, os.path.join(d, sub, "o.db"), os.path.join(d, sub)], d)
            if rc != 0:
                return ["Vergleichsprogramm (%s) Exit %d: %s" % (sub, rc, out[-400:])]
            dumps[sub] = json.loads([x for x in out.splitlines() if x.startswith("{")][-1])
        if dumps["neu"] != dumps["alt"]:
            diff = [k for k in dumps["neu"]["dump"] if dumps["neu"]["dump"][k] != dumps["alt"]["dump"].get(k)]
            return ["Vergleich alt/neu: Ergebnisse/Tabellen weichen ab (res gleich: %s, Tabellen: %s)" % (dumps["neu"]["res"] == dumps["alt"]["res"], diff)]
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return errs


# ------------------------------------------------------------------ lage_xml.py
NET = r'''
import gzip, http.server, io, json, socketserver, sys, threading, time
sys.path.insert(0, sys.argv[1])
import lage_xml, requests
MB = 1024 * 1024
OK = b'<?xml version="1.0"?><rss version="2.0"><channel><title>x</title><item><title>T\xc3\xa4st</title><link>http://a</link></item></channel></rss>'
BOMB = (b'<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><l>&c;</l>')
BIG = b"<a>" + b"x" * (3 * MB) + b"</a>"
EXACT = b"<a>" + b"x" * (2 * MB - 7) + b"</a>"
GZBOMB = gzip.compress(b"<a>" + b"x" * (6 * MB) + b"</a>")          # klein im Netz (~6 KB), 6 MiB entpackt
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path
        if p == "/503":
            self.send_response(503); self.end_headers(); return
        body, hdr = {"/ok": (OK, {}), "/bomb": (BOMB, {}), "/big": (BIG, {}), "/exact": (EXACT, {}), "/gzbomb": (GZBOMB, {"Content-Encoding": "gzip"}),
                     "/bom": (b"\xef\xbb\xbf" + OK, {}), "/bigchunked": (BIG, {"X-Chunked": "1"}), "/drip": (OK, {"X-Drip": "1"})}.get(p, (None, {}))
        if body is None:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        for k, v in hdr.items():
            if k.startswith("Content-"): self.send_header(k, v)
        if "X-Chunked" in hdr or "X-Drip" in hdr:
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            step = 65536 if "X-Chunked" in hdr else 10
            try:
                for i in range(0, len(body), step):
                    ch = body[i:i + step]
                    self.wfile.write(b"%x\r\n" % len(ch) + ch + b"\r\n"); self.wfile.flush()
                    if "X-Drip" in hdr: time.sleep(0.3)
                self.wfile.write(b"0\r\n\r\n")
            except Exception: pass
            return
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        try: self.wfile.write(body)
        except Exception: pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
srv = S(("127.0.0.1", 0), H); port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
U = "http://127.0.0.1:%d" % port
out = {}
def t(name, fn):
    try: out[name] = fn()
    except lage_xml.XmlRejected as e: out[name] = "REJ"
    except requests.exceptions.HTTPError: out[name] = "HTTP"
    except Exception as e: out[name] = "EXC:%s" % type(e).__name__
t("ok", lambda: lage_xml.fetch_root(U + "/ok", "n", timeout=5).findall(".//item")[0].find("title").text)
t("bom", lambda: lage_xml.fetch_root(U + "/bom", "n", timeout=5).tag)
t("exact", lambda: lage_xml.fetch_root(U + "/exact", "n", timeout=5).tag)
t("bomb", lambda: lage_xml.fetch_root(U + "/bomb", "n", timeout=5).tag)
t("big", lambda: lage_xml.fetch_root(U + "/big", "n", timeout=5).tag)
t("bigchunked", lambda: lage_xml.fetch_root(U + "/bigchunked", "n", timeout=5).tag)
t("gzbomb", lambda: lage_xml.fetch_root(U + "/gzbomb", "n", timeout=5).tag)
t("503", lambda: lage_xml.fetch_root(U + "/503", "n", timeout=5).tag)
lage_xml.MAX_SECONDS = 1.0
t0 = time.time(); t("drip", lambda: lage_xml.fetch_root(U + "/drip", "n", timeout=5).tag); out["drip_s"] = round(time.time() - t0, 1)
out["backend"] = lage_xml.status()["backend"]
out["abgelehnt"] = sorted(lage_xml.status()["abgelehnt"].get("n", {}).keys()) and lage_xml.status()["abgelehnt"]["n"]["n"]
print(json.dumps(out, sort_keys=True))
'''
NET_EXPECT_HARD = {"ok": "Täst", "bom": "rss", "exact": "a", "bomb": "REJ", "big": "REJ", "bigchunked": "REJ", "gzbomb": "REJ", "503": "HTTP", "drip": "REJ"}


def check_xml(xml_src, site=None):
    errs = []
    try:
        t = ast.parse(xml_src)
    except SyntaxError as e:
        return ["lage_xml.py: Syntaxfehler: %s" % e]
    consts = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
            try:
                consts[n.targets[0].id] = ast.literal_eval(n.value) if not isinstance(n.value, ast.BinOp) else eval(compile(ast.Expression(n.value), "x", "eval"))
            except Exception:
                pass
    if consts.get("MAX_BYTES") != 2 * 1024 * 1024:
        errs.append("MAX_BYTES ist nicht fest 2 MiB (%r)" % consts.get("MAX_BYTES"))
    if consts.get("MAX_BYTES_DEFAULT") is None and "MAX_BYTES_DEFAULT = MAX_BYTES" not in xml_src:
        errs.append("MAX_BYTES_DEFAULT fehlt")
    cls = [n for n in t.body if isinstance(n, ast.ClassDef) and n.name == "XmlRejected"]
    if not cls or not any(ast.unparse(b) == "ET.ParseError" for b in cls[0].bases):
        errs.append("XmlRejected ist keine Unterklasse von ET.ParseError")
    sf = seg(xml_src, fdef(t, "safe_fromstring"))
    for must in ("forbid_dtd=False", "forbid_entities=True", "forbid_external=True", "_limit(max_bytes)", "_has_entity_decl(daten)"):
        if must not in sf:
            errs.append("safe_fromstring: %s fehlt" % must)
    lm = seg(xml_src, fdef(t, "_limit"))
    if "min(int(max_bytes), MAX_BYTES)" not in lm:
        errs.append("_limit: Grenze darf nur verkleinert werden (min(..., MAX_BYTES))")
    lc = seg(xml_src, fdef(t, "limited_content"))
    for must in ("cl > lim", "len(buf) > lim", "time.monotonic() - t0 > secs", "antwort.close()", "iter_content"):
        if must not in lc:
            errs.append("limited_content: %s fehlt" % must)
    fr = seg(xml_src, fdef(t, "fetch_root"))
    for must in ("stream=True", "raise_for_status()", "finally:", "r.close()", "limited_content(r, max_bytes, quelle=quelle)", "parse(raw, quelle, max_bytes)"):
        if must not in fr:
            errs.append("fetch_root: %s fehlt" % must)
    rj = seg(xml_src, fdef(t, "_reject"))
    for must in ('e["n"] += 1', "REPORT_EVERY_S", 'e["skip"] += 1', "file=sys.stderr"):
        if must not in rj:
            errs.append("_reject: %s fehlt" % must)
    pr = seg(xml_src, fdef(t, "parse"))
    if 'b"\\xef\\xbb\\xbf"' not in pr:
        errs.append("parse: BOM-Behandlung fehlt")
    if 'REPORT_EVERY_S = 600' not in xml_src:
        errs.append("Meldeabstand nicht 600 s")
    if errs:
        return errs
    d = tempfile.mkdtemp(prefix="sxg-xml-")
    try:
        pathlib.Path(d, "lage_xml.py").write_text(xml_src, encoding="utf-8")
        env = {"PYTHONPATH": site} if site else {}
        rc, out = run([PY, "lage_xml.py"], d, env)
        if rc != 0 or "lage_xml selftest ok" not in out:
            return ["lage_xml Selbsttest: Exit %d: %s" % (rc, out[-500:])]
        if site and "defusedxml und Rueckfall" not in out:
            return ["lage_xml Selbsttest mit defusedxml lief nicht im harten Modus: %s" % out[-300:]]
        rc, out = run([PY, "-c", "import sys; sys.modules['defusedxml'] = None; import lage_xml; assert lage_xml.HARD is False; print(lage_xml.selftest())"], d)
        if rc != 0 or "nur Rueckfall" not in out:
            return ["lage_xml Selbsttest ohne defusedxml: Exit %d: %s" % (rc, out[-500:])]
        rc, out = run([PY, "-c", "import requests"], d)
        if rc != 0:
            return errs + ["HINWEIS-NET: requests nicht vorhanden (HTTP-Test uebersprungen)"] if False else errs
        for label, env2, extra in (("hart", {"PYTHONPATH": site} if site else None, "defusedxml"), ("Rueckfall", None, "xml.etree")):
            if label == "hart" and not site:
                continue
            code = NET if label == "hart" else NET.replace("import lage_xml, requests", "sys.modules['defusedxml'] = None\nimport lage_xml, requests")
            rc, out = run([PY, "-c", code, d], d, env2, timeout=240)
            if rc != 0:
                return ["lage_xml HTTP-Test (%s) Exit %d: %s" % (label, rc, out[-500:])]
            res = json.loads([x for x in out.splitlines() if x.startswith("{")][-1])
            exp = dict(NET_EXPECT_HARD)
            for k, v in exp.items():
                if res.get(k) != v:
                    errs.append("HTTP-Test (%s): %s = %r (erwartet %r)" % (label, k, res.get(k), v))
            if label == "hart" and "defusedxml" not in res.get("backend", ""):
                errs.append("HTTP-Test (hart): Backend ist %s" % res.get("backend"))
            if res.get("drip_s", 99) > 6:
                errs.append("HTTP-Test (%s): Tropf-Antwort brauchte %s s (Gesamtzeit greift nicht)" % (label, res.get("drip_s")))
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return errs


# ------------------------------------------------------------------ lage_reqs.py / Vorlage / requirements-defusedxml.txt
def check_reqs(reqs_src, vorlage_src, reqfile_src, site=None):
    errs = []
    eq = _load("edits_reqs_g", HERE / "edits_reqs.py")
    try:
        ast.parse(reqs_src)
    except SyntaxError as e:
        return ["lage_reqs.py: Syntaxfehler: %s" % e]
    m = re.search(r'^PINNED = \{"defusedxml": \("([^"]+)", \("([0-9a-f]+)",\)\)\}$', reqs_src, re.M)
    if not m or m.group(1) != eq.DX_VER or m.group(2) != eq.DX_SHA:
        errs.append("lage_reqs.py: PINNED stimmt nicht mit Version/Hash der Nutzlast ueberein")
    if "gepinnt" not in reqs_src or "Pin    %-14s" not in reqs_src:
        errs.append("lage_reqs.py: check meldet den Pin nicht")
    if "defusedxml==%s \\\n    --hash=sha256:%s\n" % (eq.DX_VER, eq.DX_SHA) not in vorlage_src:
        errs.append("requirements.txt.vorlage: echter Pin fuer defusedxml fehlt/falsch")
    for kopf, wo, src in (("secXml: defusedxml ist gepinnt (PINNED", "lage_reqs.py (Kopf-Doku)", reqs_src), ("# secXml: defusedxml ist bereits echt gepinnt", "requirements.txt.vorlage (Kopf)", vorlage_src),
                          ("defusedxml: seit secXml Pflicht fuer lage_xml.py", "requirements.txt.vorlage (Hinweis optional)", vorlage_src)):
        if kopf not in src:
            errs.append("%s: Dokumentationszeile fehlt: %s" % (wo, kopf))
    if reqfile_src != eq.REQ_FILE:
        errs.append("requirements-defusedxml.txt weicht von der Nutzlast-Vorgabe ab")
    lines = [x for x in reqfile_src.splitlines() if x and not x.startswith("#")]
    if lines != ["defusedxml==%s \\" % eq.DX_VER, "    --hash=sha256:%s" % eq.DX_SHA]:
        errs.append("requirements-defusedxml.txt: Pin-Zeilen falsch: %r" % lines)
    if errs:
        return errs
    d = tempfile.mkdtemp(prefix="sxg-rq-")
    try:
        os.makedirs(os.path.join(d, "tools"))
        os.makedirs(os.path.join(d, "venv", "bin"))
        os.symlink(PY, os.path.join(d, "venv", "bin", "python"))
        pathlib.Path(d, "tools", "lage_reqs.py").write_text(reqs_src, encoding="utf-8")
        pathlib.Path(d, "dashboard.py").write_text("import os\ntry:\n    import defusedxml\nexcept ImportError:\n    pass\nimport nichtvorhandenespaket\n", encoding="utf-8")
        env = {"PYTHONPATH": site} if site else {}
        rc, out = run([PY, "tools/lage_reqs.py", "check"], d, env)
        if "Es wurde nichts installiert" not in out or "FEHLT  nichtvorhandenespaket" not in out or "Pin    defusedxml" not in out:
            errs.append("lage_reqs check (Sandbox): %s" % out[-300:])
        elif site and "installiert, Version stimmt" not in out:
            errs.append("lage_reqs check meldet den Pin bei vorhandenem defusedxml nicht als stimmend: %s" % out[-300:])
        if site:
            rc, out = run([PY, "tools/lage_reqs.py", "vorlage"], d, env)
            if rc != 0 or "defusedxml==%s \\\n    --hash=sha256:%s" % (eq.DX_VER, eq.DX_SHA) not in out:
                errs.append("lage_reqs vorlage: echter defusedxml-Hash fehlt: %s" % out[-300:])
            rc, out = run([PY, "tools/lage_reqs.py", "hashes"], d, env)
            if rc != 2:
                errs.append("lage_reqs hashes ohne --netz muss Exit 2 liefern (%d)" % rc)
        rc, out = run([PY, "tools/lage_reqs.py", "vorlage", "--out", os.path.join(d, "r.neu")], d, env)
        rc2, out2 = run([PY, "tools/lage_reqs.py", "vorlage", "--out", os.path.join(d, "r.neu")], d, env)
        if rc != 0 or rc2 == 0:
            errs.append("lage_reqs --out: ueberschreibt oder schreibt nicht")
        extra = set(os.listdir(d)) - {"tools", "venv", "dashboard.py", "r.neu"}
        if extra:
            errs.append("lage_reqs hat unerwartete Dateien angelegt: %s" % sorted(extra))
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return errs


def check_all(db_src, base_src, xml_src, reqs_src, vorl_src, reqfile_src, site=None, quick=False):
    errs = check_db(db_src, base_src)
    errs += check_xml(xml_src, site)
    errs += check_reqs(reqs_src, vorl_src, reqfile_src, site)
    return errs


# ------------------------------------------------------------------ Mutationstest
def mutants(base_src, edits_py, xml_src, reqs_src, vorl_src, reqfile_src, db_new, base_reqs=None, base_vorl=None):
    """Liefert (name, (db, xml, reqs, vorl, reqfile)) fuer jede Mutation."""
    out = []
    ed = _load("edits_secxml_g", edits_py)

    def one(name, text, old, new, cnt=1):
        if text.count(old) != cnt:
            raise SystemExit("Mutation %s: %d Treffer (erwartet %d)" % (name, text.count(old), cnt))
        return text.replace(old, new)
    # 1) jeder Edit einzeln zurueckgebaut
    for name, _, _ in ed.EDITS:
        out.append(("Edit-Rueckbau %s" % name, (ed.build(base_src, skip=(name,)), xml_src, reqs_src, vorl_src, reqfile_src)))
    eq = _load("edits_reqs_m", HERE / "edits_reqs.py")
    if base_reqs is not None:
        for name, _, _ in eq.REQS:
            out.append(("Edit-Rueckbau %s" % name, (db_new, xml_src, eq.build(base_reqs, eq.REQS, skip=(name,)), vorl_src, reqfile_src)))
    if base_vorl is not None:
        for name, _, _ in eq.VORLAGE:
            out.append(("Edit-Rueckbau %s" % name, (db_new, xml_src, reqs_src, eq.build(base_vorl, eq.VORLAGE, skip=(name,)), reqfile_src)))
    # 2) Textmutationen database.py
    D = db_new
    dm = [
        ("D01 SYNC_ALARM=NORMAL", 'SYNC_ALARM = "FULL"', 'SYNC_ALARM = "NORMAL"'),
        ("D02 SYNC_ALARM=OFF", 'SYNC_ALARM = "FULL"', 'SYNC_ALARM = "OFF"'),
        ("D03 mesh_seen ohne FULL", 'con = connect(path, SYNC_ALARM)   # secXml: Dublettensperre', 'con = connect(path)   # secXml: Dublettensperre'),
        ("D04 mesh_log_put ohne FULL", '"mesh_log:", SYNC_ALARM)', '"mesh_log:")'),
        ("D05 mesh_auto_reserve ohne FULL", 'con = connect(path, SYNC_ALARM)   # secXml: Auto-Versuch anmelden', 'con = connect(path)   # secXml: Auto-Versuch anmelden'),
        ("D06 mesh_auto_done ohne FULL", '"mesh_auto:", SYNC_ALARM))', '"mesh_auto:"))'),
        ("D07 q_add ohne FULL", 'con = connect(path, SYNC_ALARM)   # secXml: Alarm-Warteschlange', 'con = connect(path)   # secXml: Alarm-Warteschlange'),
        ("D08 q_set ohne FULL", '"mesh_queue:", SYNC_ALARM))', '"mesh_queue:"))'),
        ("D09 upsert_event nie FULL", 'SYNC_ALARM if alarm_event(row["severity"]) else None', 'None'),
        ("D10 upsert_event immer FULL", 'SYNC_ALARM if alarm_event(row["severity"]) else None', 'SYNC_ALARM'),
        ("D11 connect festes NORMAL", '_sync_apply(con, _sync_pick(sync))', '_sync_apply(con, SYNC_NORMAL)'),
        ("D12 Unbekanntes -> NORMAL", 'return SYNC_NORMAL if s == SYNC_NORMAL else SYNC_ALARM', 'return SYNC_ALARM if s == SYNC_ALARM else SYNC_NORMAL'),
        ("D13 ohne Rueckpruefung", '    _sx_stat["full"] += 1\n    try:\n        r = con.execute("PRAGMA synchronous").fetchone()', '    _sx_stat["full"] += 1\n    return\n    try:\n        r = con.execute("PRAGMA synchronous").fetchone()'),
        ("D14 Abweichung wirft", '        _sx_stat["mismatch"] += 1\n', '        _sx_stat["mismatch"] += 1\n        raise RuntimeError("sync")\n'),
        ("D15 alarm_event nur alarm", 'return str("" if severity is None else severity).strip().lower() != "info"', 'return str("" if severity is None else severity).strip().lower() == "alarm"'),
        ("D16 _exec reicht sync nicht weiter", 'con = connect(path, sync)', 'con = connect(path)'),
        ("D17 Telemetrie FULL", '        con = connect(path)\n        try:\n            with con:\n                cur = con.execute("INSERT OR IGNORE INTO telemetry', '        con = connect(path, SYNC_ALARM)\n        try:\n            with con:\n                cur = con.execute("INSERT OR IGNORE INTO telemetry'),
        ("D18 mesh_known FULL", '        con = connect(path)\n        try:\n            return con.execute("SELECT 1 FROM mesh_log WHERE hash=?"', '        con = connect(path, SYNC_ALARM)\n        try:\n            return con.execute("SELECT 1 FROM mesh_log WHERE hash=?"'),
        ("D19 state_put FULL", '        now = time.time()\n        con = connect(path)\n', '        now = time.time()\n        con = connect(path, SYNC_ALARM)\n'),
        ("D20 Status ohne alarm_sync", '                "alarm_sync": sync_status(),', '                "alarm_sync_x": 1,'),
        ("D21 PRAGMA fest NORMAL", 'con.execute("PRAGMA synchronous=%s" % want)', 'con.execute("PRAGMA synchronous=NORMAL")'),
        ("D22 Importhinweis nach stdout", ', file=_sx_sys.stderr, flush=True)', ', flush=True)'),
        ("D23 aktiv immer True", '"aktiv": _sx_stat["mismatch"] == 0', '"aktiv": True'),
        ("D24 selftest_sync nicht im Hauptprogramm", '    print(selftest_sync())\n', ''),
        ("D25 busy_timeout entfernt", '        con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))\n        if p not in _wal_done:', '        if p not in _wal_done:'),
        ("D26 connect ohne sync-Parameter", 'def connect(path=None, sync=None):', 'def connect(path=None):'),
        ("D27 Meldung nicht ratenbegrenzt", 'if _sx_log_t[0] is None or now - _sx_log_t[0] >= 600:', 'if True:'),
        ("D28 q_set Zustand ohne FULL und q_add FULL (nur q_add)", 'tuple(v for _, v in sets) + (int(qid),), _ensure_t3(path), "mesh_queue:", SYNC_ALARM))', 'tuple(v for _, v in sets) + (int(qid),), _ensure_t3(path), "mesh_queue:", "NORMAL"))'),
        ("D29 _sync_pick liefert immer NORMAL", 'return SYNC_NORMAL if s == SYNC_NORMAL else SYNC_ALARM', 'return SYNC_NORMAL'),
        ("D30 Zaehler FULL fehlt", '    _sx_stat["full"] += 1\n', ''),
    ]
    for name, old, new in dm:
        out.append((name, (one(name, D, old, new), xml_src, reqs_src, vorl_src, reqfile_src)))
    X = xml_src
    xm = [
        ("X01 Grenze 4 MiB", 'MAX_BYTES = 2 * 1024 * 1024 ', 'MAX_BYTES = 4 * 1024 * 1024 '),
        ("X02 Grenze vergroesserbar", 'return max(0, min(int(max_bytes), MAX_BYTES))', 'return max(0, int(max_bytes))'),
        ("X03 Entities erlaubt", 'forbid_entities=True', 'forbid_entities=False'),
        ("X04 extern erlaubt", 'forbid_external=True', 'forbid_external=False'),
        ("X05 Content-Length ignoriert", '    if cl > lim:\n', '    if False:\n'),
        ("X06 Streamgroesse ungeprueft", '        if len(buf) > lim:\n', '        if False:\n'),
        ("X07 Gesamtzeit ungeprueft", '        if time.monotonic() - t0 > secs:\n', '        if False:\n'),
        ("X08 Meldung nicht ratenbegrenzt", 'if e["t"] is None or now - e["t"] >= REPORT_EVERY_S:', 'if True:'),
        ("X09 Ablehnungen nicht gezaehlt", '        e["n"] += 1\n', ''),
        ("X10 stream=False", 'r = getter(url, timeout=timeout, headers=headers or {}, stream=True)', 'r = getter(url, timeout=timeout, headers=headers or {}, stream=False)'),
        ("X11 Antwort nie geschlossen", '        try:\n            r.close()\n        except Exception:\n            pass\n', '        pass\n'),
        ("X12 HTTP-Fehler verschluckt", '        r.raise_for_status()\n        raw = limited_content', '        raw = limited_content'),
        ("X13 BOM bleibt", '    if isinstance(roh, (bytes, bytearray)) and bytes(roh[:3]) == b"\\xef\\xbb\\xbf":\n        roh = bytes(roh[3:])\n', ''),
        ("X14 Rueckfall ohne Entity-Sperre", '    if _has_entity_decl(daten):\n', '    if False:\n'),
        ("X15 XmlRejected keine ParseError", 'class XmlRejected(ET.ParseError):', 'class XmlRejected(Exception):'),
        ("X16 Groesse nicht geprueft", '    if n > lim:\n        raise _reject(quelle, "XML zu gross', '    if False:\n        raise _reject(quelle, "XML zu gross'),
        ("X17 genau 2 MiB abgelehnt", '    if n > lim:\n        raise _reject(quelle, "XML zu gross', '    if n >= lim:\n        raise _reject(quelle, "XML zu gross'),
        ("X18 DTD verboten", 'forbid_dtd=False', 'forbid_dtd=True'),
        ("X19 UTF-16-Sperre fehlt", 'any(m in b for m in (b"<!ENTITY", "<!ENTITY".encode("utf-16-le"), "<!ENTITY".encode("utf-16-be")))', 'b"<!ENTITY" in b'),
        ("X20 Meldeabstand 0", 'REPORT_EVERY_S = 600.0 ', 'REPORT_EVERY_S = 0.0 '),
    ]
    for name, old, new in xm:
        out.append((name, (db_new, one(name, X, old, new), reqs_src, vorl_src, reqfile_src)))
    Q = reqs_src
    eq = _load("edits_reqs_m2", HERE / "edits_reqs.py")
    h = eq.DX_SHA
    bad = h[:-1] + ("0" if h[-1] != "0" else "1")
    qm = [
        ("Q01 PINNED-Hash falsch", (one("Q01", Q, h, bad), vorl_src, reqfile_src)),
        ("Q02 PINNED-Version falsch", (one("Q02", Q, 'PINNED = {"defusedxml": ("0.7.1"', 'PINNED = {"defusedxml": ("0.7.0"'), vorl_src, reqfile_src)),
        ("Q03 check ohne Pin-Zeile", (one("Q03", Q, 'print("  Pin    %-14s', 'print("  Xin    %-14s'), vorl_src, reqfile_src)),
        ("Q04 vorlage ohne gepinnten Zweig", (one("Q04", Q, 'if pin and pin[0] == ver:', 'if False:'), vorl_src, reqfile_src)),
        ("Q05 Vorlage-Hash falsch", (Q, one("Q05", vorl_src, h, bad), reqfile_src)),
        ("Q06 requirements-defusedxml Hash falsch", (Q, vorl_src, one("Q06", reqfile_src, h, bad))),
        ("Q07 requirements-defusedxml Version falsch", (Q, vorl_src, one("Q07", reqfile_src, "defusedxml==0.7.1", "defusedxml==0.7.0"))),
    ]
    for name, (r_, v_, f_) in qm:
        out.append((name, (db_new, xml_src, r_, v_, f_)))
    return out


def main(argv):
    a = list(argv)
    site = None
    if "--site" in a:
        i = a.index("--site")
        site = a[i + 1]
        del a[i:i + 2]
    breq = bvor = None
    for flag in ("--basereqs", "--basevorlage"):
        if flag in a:
            i = a.index(flag)
            val = pathlib.Path(a[i + 1]).read_text(encoding="utf-8")
            del a[i:i + 2]
            if flag == "--basereqs":
                breq = val
            else:
                bvor = val
    cmd = a[0] if a else ""
    rd = lambda p: pathlib.Path(p).read_text(encoding="utf-8")
    if cmd == "check":
        db, base, xml, rq, vo, rf = [rd(x) for x in a[1:7]]
        errs = check_all(db, base, xml, rq, vo, rf, site)
        for e in errs:
            print("GUARD FEHLER: %s" % e)
        print("guard secXml: %s" % ("alle Pruefungen ok" if not errs else "%d Beanstandung(en)" % len(errs)))
        return 1 if errs else 0
    if cmd == "mutate":
        base = rd(a[1])
        edits_py = pathlib.Path(a[2])
        xml, rq, vo, rf = [rd(x) for x in a[3:7]]
        ed = _load("edits_secxml_g0", edits_py)
        db_new = ed.build(base)
        if check_all(db_new, base, xml, rq, vo, rf, site):
            print("Mutationstest: schon die unveraenderte Nutzlast besteht die Pruefung nicht")
            return 1
        ms = mutants(base, edits_py, xml, rq, vo, rf, db_new, breq, bvor)
        missed = []
        for name, (db_m, xml_m, rq_m, vo_m, rf_m) in ms:
            errs = check_all(db_m, base, xml_m, rq_m, vo_m, rf_m, site)
            if not errs:
                missed.append(name)
        print("mutation secXml: %d Mutationen, %d erkannt, %d uebersehen%s" % (len(ms), len(ms) - len(missed), len(missed), (" -> " + ", ".join(missed)) if missed else ""))
        return 1 if missed else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
SXM_GUARD_EOF
EXPECT_EDITS="206de859883c63171b5a2b6a4809163f8f19956ab04bf8ac2ea9ef1b27eff475"
cat > "$W/edits_secxml.py" << 'SXM_EDITS_EOF'
"""secXml: database.py (Basis = relClock-Fassung, sha16 01f7abf0c13b7acd) -> neue Fassung. Jede Ersetzung muss genau einmal passen (sonst Abbruch)."""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
BLOCK = (HERE / "block_secxml.py").read_text(encoding="utf-8")

EDITS = [
    ("X01_doc",
     "relClock: der Aufraeum-Faden loescht nichts, solange lage_clock.clock_ok() die Uhr fuer unplausibel haelt; Dauern/Zeitlimits/owns() in monotonic (siehe Block relClock).\n\"\"\"\n",
     "relClock: der Aufraeum-Faden loescht nichts, solange lage_clock.clock_ok() die Uhr fuer unplausibel haelt; Dauern/Zeitlimits/owns() in monotonic (siehe Block relClock).\n"
     "secXml: der Alarmpfad (mesh_queue, mesh_log, mesh_auto, Ereignisse mit Stufe ungleich info) schreibt ueber eine Verbindung mit synchronous=FULL, der Rest bleibt WAL + NORMAL (siehe Block secXml).\n\"\"\"\n"),
    ("X02_block_und_connect_kopf",
     "def connect(path=None):\n"
     "    \"\"\"Neue Verbindung (je Aufruf). busy_timeout, synchronous, Row-Zugriff per Name; WAL nur einmal je Prozess/Pfad (relDb). sqlA: rollback vor close; Fehler in den PRAGMAs -> sofort schliessen.\"\"\"\n",
     BLOCK +
     "def connect(path=None, sync=None):\n"
     "    \"\"\"Neue Verbindung (je Aufruf). busy_timeout, synchronous, Row-Zugriff per Name; WAL nur einmal je Prozess/Pfad (relDb). sqlA: rollback vor close; Fehler in den PRAGMAs -> sofort schliessen.\n"
     "    secXml: sync=None -> synchronous=NORMAL wie bisher; sync=SYNC_ALARM (FULL) nur fuer den Alarmpfad (je Verbindung, mit Rueckpruefung).\"\"\"\n"),
    ("X03_connect_pragma",
     "        con.execute(\"PRAGMA synchronous=NORMAL\")\n"
     "    except Exception:\n"
     "        con.close()\n"
     "        raise\n",
     "        _sync_apply(con, _sync_pick(sync))   # secXml: NORMAL wie bisher, FULL nur auf Anforderung des Alarmpfads\n"
     "    except Exception:\n"
     "        con.close()\n"
     "        raise\n"),
    ("X04_exec",
     "def _exec(sql, args, path, what):\n"
     "    path = _ensure_t2(path)\n"
     "    try:\n"
     "        con = connect(path)\n",
     "def _exec(sql, args, path, what, sync=None):\n"
     "    path = _ensure_t2(path)\n"
     "    try:\n"
     "        con = connect(path, sync)\n"),
    ("X05_mesh_seen",
     "        con = connect(path)\n"
     "        try:\n"
     "            with con:\n"
     "                cur = con.execute(\"INSERT OR IGNORE INTO mesh_log(hash, channel, created) VALUES(?,?,?)\"",
     "        con = connect(path, SYNC_ALARM)   # secXml: Dublettensperre = Alarmpfad\n"
     "        try:\n"
     "            with con:\n"
     "                cur = con.execute(\"INSERT OR IGNORE INTO mesh_log(hash, channel, created) VALUES(?,?,?)\""),
    ("X06_mesh_log_put",
     "               None if ok is None else (1 if ok else 0), kind), path, \"mesh_log:\")\n",
     "               None if ok is None else (1 if ok else 0), kind), path, \"mesh_log:\", SYNC_ALARM)   # secXml: Versandprotokoll = Alarmpfad\n"),
    ("X07_mesh_auto_reserve",
     "        con = connect(path)\n"
     "        try:\n"
     "            with con:\n"
     "                cur = con.execute(\"INSERT OR IGNORE INTO mesh_auto(akey,",
     "        con = connect(path, SYNC_ALARM)   # secXml: Auto-Versuch anmelden = Alarmpfad\n"
     "        try:\n"
     "            with con:\n"
     "                cur = con.execute(\"INSERT OR IGNORE INTO mesh_auto(akey,"),
    ("X08_mesh_auto_done",
     "    return bool(_exec(\"UPDATE mesh_auto SET ok=? WHERE akey=?\", (1 if ok else 0, str(akey)), path, \"mesh_auto:\"))\n",
     "    return bool(_exec(\"UPDATE mesh_auto SET ok=? WHERE akey=?\", (1 if ok else 0, str(akey)), path, \"mesh_auto:\", SYNC_ALARM))   # secXml: Ergebnis des Versuchs = Alarmpfad\n"),
    ("X09_q_add",
     "        con = connect(path)\n"
     "        try:\n"
     "            with con:\n"
     "                if hash_hex:\n",
     "        con = connect(path, SYNC_ALARM)   # secXml: Alarm-Warteschlange = Alarmpfad\n"
     "        try:\n"
     "            with con:\n"
     "                if hash_hex:\n"),
    ("X10_q_set",
     "    return bool(_exec(sql, tuple(v for _, v in sets) + (int(qid),), _ensure_t3(path), \"mesh_queue:\"))\n",
     "    return bool(_exec(sql, tuple(v for _, v in sets) + (int(qid),), _ensure_t3(path), \"mesh_queue:\", SYNC_ALARM))   # secXml: Zustand der Warteschlange (ok/skip/fail) = Alarmpfad\n"),
    ("X11_upsert_event",
     "        con = connect(path)\n"
     "        try:\n"
     "            with con:\n"
     "                con.execute(\n"
     "                    \"INSERT INTO events(source,",
     "        con = connect(path, SYNC_ALARM if alarm_event(row[\"severity\"]) else None)   # secXml: Ereignis mit Stufe ungleich info = Alarmpfad; info (z. B. DAB-Texte) bleibt NORMAL\n"
     "        try:\n"
     "            with con:\n"
     "                con.execute(\n"
     "                    \"INSERT INTO events(source,"),
    ("X12_status",
     "                \"clock\": {\"ok\": (self.clock_last[0] if self.clock_last else None), \"why\": self.clock_why, \"pruefer\": (self.clock_last[1] if self.clock_last else None)},\n",
     "                \"clock\": {\"ok\": (self.clock_last[0] if self.clock_last else None), \"why\": self.clock_why, \"pruefer\": (self.clock_last[1] if self.clock_last else None)},\n"
     "                \"alarm_sync\": sync_status(),   # secXml: sichtbar in /api/sdr/live (db.retention.alarm_sync)\n"),
    ("X13_main",
     "    print(selftest_clock())\n",
     "    print(selftest_clock())\n"
     "    print(selftest_sync())\n"),
]


def build(base, skip=()):
    out = base
    for name, old, new in EDITS:
        if name in skip:
            continue
        if out.count(old) != 1:
            raise SystemExit("Edit %s: %d Treffer (erwartet 1)" % (name, out.count(old)))
        out = out.replace(old, new)
    return out


if __name__ == "__main__":
    src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    pathlib.Path(sys.argv[2]).write_text(build(src), encoding="utf-8")
SXM_EDITS_EOF
EXPECT_BLOCK="de729d83916e1f2c6b3af2d1737364e1a6f6ba46dd24a284e530f1cb99debfed"
cat > "$W/block_secxml.py" << 'SXM_BLOCK_EOF'
# ---------------------------------------------------------------- secXml: synchronous=FULL nur fuer den Alarmpfad (Entscheidung Frank, SEC/REL "Alarm-Speicher")
# PRAGMA synchronous gilt je Verbindung. Der Alarmpfad schreibt deshalb ueber eine eigene Verbindung mit FULL (SQLite meldet das Ende der Transaktion erst, wenn WAL
# und Datei physisch auf dem Datentraeger sind - ein Stromausfall mitten im Alarm verliert keinen bestaetigten Eintrag). Alles andere bleibt wie bisher WAL + NORMAL.
# Alarmpfad = Alarm-Warteschlange mesh_queue (q_add, q_set), Dublettensperre mesh_log (mesh_seen, mesh_log_put), Auto-Versuche mesh_auto (mesh_auto_reserve, mesh_auto_done)
# und Ereignisse, deren Stufe nicht "info" ist (upsert_event: warn, alarm, probe, unknown, fehlende Stufe). Lesen, Telemetrie, DAB-Infos, state, Aufraeumen: NORMAL.
# Kein neuer Ausfall: scheitert die Kontrolle (PRAGMA synchronous liest nicht 2), wird das hoechstens alle 10 min gemeldet und trotzdem geschrieben (Alarm vor Datenschutz).
import sys as _sx_sys

SYNC_NORMAL = "NORMAL"
SYNC_ALARM = "FULL"
_SYNC_CODE = {"NORMAL": 1, "FULL": 2}
_sx_stat = {"full": 0, "normal": 0, "mismatch": 0, "last_err": None}
_sx_log_t = [None]
ALARM_PFAD = "mesh_queue, mesh_log, mesh_auto, Ereignisse mit Stufe ungleich info"


def alarm_event(severity):
    """True, wenn ein Ereignis in den Alarmpfad gehoert (alles ausser ausdruecklich 'info'; fehlende Stufe zaehlt als Alarm = konservativ)."""
    return str("" if severity is None else severity).strip().lower() != "info"


def _sync_pick(sync):
    """None/'NORMAL' -> NORMAL; alles andere (auch Unbekanntes) -> FULL, nie eine Abschwaechung durch Tippfehler."""
    s = SYNC_NORMAL if sync is None else str(sync).strip().upper()
    return SYNC_NORMAL if s == SYNC_NORMAL else SYNC_ALARM


def _sync_apply(con, want):
    """PRAGMA synchronous setzen; bei FULL den Wert zurueckpruefen (Abweichung: zaehlen, ratenbegrenzt melden, trotzdem weiterarbeiten)."""
    con.execute("PRAGMA synchronous=%s" % want)
    if want == SYNC_NORMAL:
        _sx_stat["normal"] += 1
        return
    _sx_stat["full"] += 1
    try:
        r = con.execute("PRAGMA synchronous").fetchone()
        got = None if r is None else int(r[0])
    except Exception as e:
        got = None
        _sx_stat["last_err"] = ("Rueckpruefung: %s" % e)[:120]
    if got != _SYNC_CODE[SYNC_ALARM]:
        _sx_stat["mismatch"] += 1
        if _sx_stat["last_err"] is None or got is not None:
            _sx_stat["last_err"] = ("synchronous=FULL nicht bestaetigt (gelesen: %s)" % got)[:120]
        now = time.monotonic()
        if _sx_log_t[0] is None or now - _sx_log_t[0] >= 600:
            _sx_log_t[0] = now
            _log("secXml: synchronous=FULL fuer den Alarmpfad nicht bestaetigt (gelesen: %s) - es wird trotzdem geschrieben" % got)


def sync_status():
    """Fuer /api/sdr/live (retention.alarm_sync): Soll, ob bestaetigt, Zaehler seit Prozessstart."""
    return {"soll": SYNC_ALARM, "aktiv": _sx_stat["mismatch"] == 0, "voll": _sx_stat["full"], "normal": _sx_stat["normal"],
            "abweichungen": _sx_stat["mismatch"], "letzter_fehler": _sx_stat["last_err"], "pfad": ALARM_PFAD}


print("lagezentrum.db: secXml aktiv - Alarmpfad (%s) schreibt mit synchronous=%s, alles andere NORMAL" % (ALARM_PFAD, SYNC_ALARM), file=_sx_sys.stderr, flush=True)


def selftest_sync():
    import tempfile
    global connect
    real = connect
    seen = []

    def rec(path=None, sync=None):
        seen.append(_sync_pick(sync))
        return real(path, sync)

    d = tempfile.mkdtemp(prefix="lzsx-")
    p = os.path.join(d, "s.db")
    try:
        assert migrate(p) and migrate_t2(p) and migrate_t3(p)
        # 1. Das PRAGMA wirkt wirklich je Verbindung (1 = NORMAL, 2 = FULL); Unbekanntes wird nie abgeschwaecht
        for arg, want in ((None, 1), ("NORMAL", 1), ("FULL", 2), ("full", 2), ("unsinn", 2), ("OFF", 2)):
            c = real(p, arg)
            try:
                assert c.execute("PRAGMA synchronous").fetchone()[0] == want, (arg, want)
                assert str(c.execute("PRAGMA journal_mode").fetchone()[0]).lower() == "wal"
            finally:
                c.close()
        # 2. Welche Funktion nimmt welche Verbindung (genau eine Verbindung je Aufruf)
        connect = rec
        now = int(time.time())

        def kind(fn, *a, **k):
            del seen[:]
            r = fn(*a, **k)
            return r, list(seen)

        full = [
            ("mesh_seen", lambda: mesh_seen("h1", "m1:0", p, now)),
            ("mesh_log_put", lambda: mesh_log_put("h2", "m1:0", now, "NINA", "t", True, "nina", p)),
            ("mesh_auto_reserve", lambda: mesh_auto_reserve("A1", "h3", "ASA", "t", now, p)),
            ("mesh_auto_done", lambda: mesh_auto_done("A1", True, p)),
            ("q_add", lambda: q_add("m1", "nina", "t", "h4", now, now, None, None, p)),
            ("upsert_event warn", lambda: upsert_event({"source": "NINA", "ext_id": "w1", "severity": "warn", "headline": "w"}, p)),
            ("upsert_event alarm", lambda: upsert_event({"source": "ASA", "ext_id": "a1", "severity": "alarm", "headline": "a"}, p)),
            ("upsert_event ohne Stufe", lambda: upsert_event({"source": "BR24", "ext_id": "n1", "headline": "n"}, p)),
            ("upsert_event probe", lambda: upsert_event({"source": "ASA", "ext_id": "p1", "severity": "probe", "headline": "p"}, p)),
        ]
        for name, fn in full:
            r, s = kind(fn)
            assert s == ["FULL"], (name, s)
            assert r is not None, (name, r)
        qid = q_add("m1", "nina", "t", "h5", now, now, None, None, p)
        r, s = kind(q_set, qid, p, state="ok", done=now)
        assert r is True and s == ["FULL"], ("q_set", r, s)
        normal = [
            ("upsert_event info", lambda: upsert_event({"source": "DAB", "ext_id": "i1", "severity": "info", "headline": "i"}, p)),
            ("insert_telemetry", lambda: insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 1.0, "src_t": now}, p)),
            ("mesh_known", lambda: mesh_known("h1", p)),
            ("mesh_hash_since", lambda: mesh_hash_since("h1", now - 60, p)),
            ("mesh_auto_get", lambda: mesh_auto_get("A1", p)),
            ("mesh_auto_count", lambda: mesh_auto_count(now - 60, p)),
            ("q_open", lambda: q_open("m1", p)),
            ("q_get", lambda: q_get(qid, p)),
            ("mesh_count_since", lambda: mesh_count_since("m1:0", ("nina",), now - 60, p)),
            ("state_put", lambda: state_put("k", "{}", None, p)),
            ("cleanup", lambda: cleanup(now, p)),
            ("cleanup_t3", lambda: cleanup_t3(now, p)),
        ]
        for name, fn in normal:
            r, s = kind(fn)
            assert s and set(s) == {"NORMAL"}, (name, s)
        # 3. Verhalten unveraendert: Dublette, Reservierung, Warteschlange
        assert mesh_seen("h1", "m1:0", p, now) is True and mesh_seen("neu-h", "m1:0", p, now) is False
        assert mesh_auto_reserve("A1", "h3", "ASA", "t", now, p) is None and mesh_auto_get("A1", p)["ok"] == 1
        assert q_get(qid, p)["state"] == "ok" and q_add("m1", "nina", "t", "h5", now, now, None, None, p) == qid
    finally:
        connect = real
        for f in os.listdir(d):
            try:
                os.unlink(os.path.join(d, f))
            except OSError:
                pass
        try:
            os.rmdir(d)
        except OSError:
            pass
    # 4. Abweichung bei der Rueckpruefung: gezaehlt, nicht geworfen
    class _R:
        def __init__(self, v):
            self.v = v

        def fetchone(self):
            return (self.v,)

    class _C:
        def __init__(self, v):
            self.v = v

        def execute(self, sql):
            return _R(self.v)

    saved = dict(_sx_stat)
    t_saved = _sx_log_t[0]
    try:
        _sx_stat.update(full=0, normal=0, mismatch=0, last_err=None)
        _sync_apply(_C(2), SYNC_ALARM)
        assert sync_status()["aktiv"] is True and sync_status()["voll"] == 1
        import contextlib
        import io
        _sx_log_t[0] = None
        o1 = io.StringIO()
        with contextlib.redirect_stdout(o1):
            _sync_apply(_C(1), SYNC_ALARM)                     # Abweichung -> zaehlen, kein Wurf, erste Meldung kommt
        assert "secXml: synchronous=FULL" in o1.getvalue(), o1.getvalue()
        o2 = io.StringIO()
        with contextlib.redirect_stdout(o2):
            _sync_apply(_C(1), SYNC_ALARM)                     # zweite Abweichung: ratenbegrenzt, keine neue Zeile
        assert o2.getvalue() == "", o2.getvalue()
        st = sync_status()
        assert st["aktiv"] is False and st["abweichungen"] == 2 and "nicht bestaetigt" in st["letzter_fehler"], st
        _sync_apply(_C(1), SYNC_NORMAL)
        assert sync_status()["normal"] == 1 and sync_status()["soll"] == "FULL"
    finally:
        _sx_stat.update(saved)
        _sx_log_t[0] = t_saved
    assert alarm_event("warn") and alarm_event("ALARM") and alarm_event(None) and alarm_event("") and alarm_event("unknown") and not alarm_event("info") and not alarm_event(" Info ")
    return "database selftest secXml ok (Alarmpfad FULL: %d Schreibwege, Rest NORMAL: %d, Rueckpruefung, Abweichung wird gezaehlt statt geworfen)" % (len(full) + 1, len(normal))


SXM_BLOCK_EOF
EXPECT_EDQ="ea58e46952f0a3c41170767207d6a5757e6e14a632d409a34f1f6baaac217804"
cat > "$W/edits_reqs.py" << 'SXM_EDQ_EOF'
"""secXml: tools/lage_reqs.py (Basis sha16 a6bf962c0a3abdd8) -> neue Fassung (defusedxml mit echtem Pin und Hash statt Platzhalter) und requirements.txt.vorlage (Basis e6bb839311fc2502).
Jede Ersetzung muss genau einmal passen (sonst Abbruch). Aufruf: edits_reqs.py reqs BASIS ZIEL | vorlage BASIS ZIEL"""
import pathlib
import sys

DX_VER = "0.7.1"
DX_SHA = "a352e7e428770286cc899e2542b6cdaedb2b4953ff269a210103ec58f6198a61"   # defusedxml-0.7.1-py2.py3-none-any.whl (PyPI, 25604 Bytes)

REQS = [
    ("R01_doc",
     "Ohne --out wird nur ausgegeben, nichts geschrieben. Die Datei requirements.txt wird nie von selbst angelegt oder ersetzt.\n\"\"\"\n",
     "Ohne --out wird nur ausgegeben, nichts geschrieben. Die Datei requirements.txt wird nie von selbst angelegt oder ersetzt.\n"
     "secXml: defusedxml ist gepinnt (PINNED, Version + sha256 des Rades von PyPI): check meldet Soll/Ist, vorlage/hashes schreiben fuer dieses Paket den echten Hash statt eines Platzhalters.\n\"\"\"\n"),
    ("R02_pinned",
     "SKIP_DIRS = {\"venv\", \"__pycache__\", \"backups\", \".git\", \"node_modules\"}\n",
     "SKIP_DIRS = {\"venv\", \"__pycache__\", \"backups\", \".git\", \"node_modules\"}\n"
     "# secXml (SEC-10/SEC-11): gepinnte Pakete {normalisierter Name: (Version, (sha256 ...))}. Hash = defusedxml-%s-py2.py3-none-any.whl auf PyPI.\n"
     "PINNED = {\"defusedxml\": (\"%s\", (\"%s\",))}\n" % (DX_VER, DX_VER, DX_SHA)),
    ("R03_check",
     "    print(\"Ergebnis: %d Fremdpakete im Quelltext, %d fehlen im venv. Es wurde nichts installiert.\" % (len(imp), miss))\n",
     "    have = {norm(d[\"name\"]): d[\"version\"] for d in info[\"dists\"]}\n"
     "    for n_, (v_, hs_) in sorted(PINNED.items()):\n"
     "        h_ = have.get(norm(n_))\n"
     "        print(\"  Pin    %-14s gepinnt %s (sha256 %s...) - %s\" % (n_, v_, hs_[0][:12], \"FEHLT im venv\" if h_ is None else (\"installiert, Version stimmt\" if h_ == v_ else \"installiert %s (weicht vom Pin ab)\" % h_)))\n"
     "    print(\"Ergebnis: %d Fremdpakete im Quelltext, %d fehlen im venv. Es wurde nichts installiert.\" % (len(imp), miss))\n"),
    ("R04_render",
     "        if hashes is None:\n"
     "            lines.append(\"%s==%s \\\\\\n    --hash=sha256:HIER-HASH-EINTRAGEN%s\" % (name, ver, tag))\n",
     "        pin = PINNED.get(norm(name))\n"
     "        if pin and pin[0] == ver:   # secXml: gepinnt, echter Hash aus dem Quelltext (kein Platzhalter, kein Netz)\n"
     "            lines.append(\"%s==%s \\\\\\n%s%s\" % (name, ver, \" \\\\\\n\".join(\"    --hash=sha256:%s\" % h for h in pin[1]), tag + \"  # gepinnt (secXml)\"))\n"
     "        elif hashes is None:\n"
     "            lines.append(\"%s==%s \\\\\\n    --hash=sha256:HIER-HASH-EINTRAGEN%s\" % (name, ver, tag))\n"),
]

VORLAGE = [
    ("V01_kopf",
     "# Zeilen mit HIER-... sind Platzhalter und duerfen NICHT mit pip install benutzt werden.\n",
     "# Zeilen mit HIER-... sind Platzhalter und duerfen NICHT mit pip install benutzt werden.\n"
     "# secXml: defusedxml ist bereits echt gepinnt (Version + Hash von PyPI); als eigene benutzbare Datei: requirements-defusedxml.txt\n"),
    ("V02_defusedxml_echt",
     "PyPubSub==HIER-VERSION-AUS-DEM-VENV \\\n    --hash=sha256:HIER-HASH-EINTRAGEN\n",
     "PyPubSub==HIER-VERSION-AUS-DEM-VENV \\\n    --hash=sha256:HIER-HASH-EINTRAGEN\n"
     "defusedxml==%s \\\n    --hash=sha256:%s\n" % (DX_VER, DX_SHA)),
    ("V03_optional",
     "#   defusedxml  - fuer lage_xml.py (SEC-11); fehlt es, gilt der Rueckfall mit Groessenlimit\n",
     "#   (defusedxml: seit secXml Pflicht fuer lage_xml.py und oben gepinnt; ohne gilt nur der Rueckfall mit Groessenlimit und Entity-Sperre)\n"),
]


def build(base, edits, skip=()):
    out = base
    for name, old, new in edits:
        if name in skip:
            continue
        if out.count(old) != 1:
            raise SystemExit("Edit %s: %d Treffer (erwartet 1)" % (name, out.count(old)))
        out = out.replace(old, new)
    return out


REQ_FILE = ("# requirements-defusedxml.txt (secXml, SEC-10/SEC-11) - benutzbar mit --require-hashes. Nur dieses eine Paket, rein Python, ohne Abhaengigkeiten.\n"
            "# Rad: defusedxml-%s-py2.py3-none-any.whl (PyPI, 25604 Bytes). Der Apply secXml installiert es offline aus dem eingebetteten, per Hash geprueften Rad:\n"
            "#   /home/fmg/prepper-dashboard/venv/bin/python -m pip install --no-index --no-deps --require-hashes --find-links ORDNER_MIT_DEM_RAD -r requirements-defusedxml.txt\n"
            "# Mit Netz (PyPI) geht derselbe Pin ohne --no-index --find-links. Als Benutzer fmg, nie als root. Rueckgaengig: venv/bin/python -m pip uninstall -y defusedxml\n"
            "defusedxml==%s \\\n    --hash=sha256:%s\n" % (DX_VER, DX_VER, DX_SHA))

if __name__ == "__main__":
    mode = sys.argv[1]
    src = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
    pathlib.Path(sys.argv[3]).write_text(build(src, REQS if mode == "reqs" else VORLAGE), encoding="utf-8")
SXM_EDQ_EOF
EXPECT_BDB="01f7abf0c13b7acdeea24cf4fb1b47b71941bc508f3069e2e5d49abb6e0216fa"
cat > "$W/base_database.py" << 'SXM_BDB_EOF'
"""database.py - SQLite-Lagezentrum (lagezentrum.db) ZUSAETZLICH zu den JSON-Dateien.

Kaeswasser Lage Monitor, Teil 1. Nur Ablage/Abfrage, keine Netzwerkzugriffe, keine Sendewege.
- WAL-Modus, busy_timeout, eine Verbindung je Aufruf (thread-sicher ohne geteilte Verbindung)
- Schema-Migration idempotent (CREATE IF NOT EXISTS + fehlende Spalten per ALTER TABLE ADD COLUMN)
- jede Funktion faengt Fehler ab und liefert einen sicheren Standardwert (Seiten duerfen nie abstuerzen)

Tabellen:
  events     Lage-Ereignisse (NINA/MoWaS, DAB, ASA, BR24) - ext_id eindeutig (Upsert)
  mesh_log   md5-Hash gesehener Mesh-Texte je Kanal (nur Dublettenpruefung, kein Senden)
  telemetry  DAB-Empfangswerte je Stick/Kanal; 'ber' = FIC-CRC-Fehlerrate als Ersatz fuer die
             Bitfehlerrate (welle-cli liefert keine BER): numcrcerrors / (Messdauer_s * 125 FIB/s, DAB Mode I).
             kind 'dab' = echte Messung, kind 'hb' = Lebenszeichen aus sdr_status.json (Watchdog).
relDb: Wartung der Datenbank im Hintergrund (Checkpoint, quick_check, snapshot), WAL einmal je Prozess und Pfad (siehe Block relDb weiter unten).
relClock: der Aufraeum-Faden loescht nichts, solange lage_clock.clock_ok() die Uhr fuer unplausibel haelt; Dauern/Zeitlimits/owns() in monotonic (siehe Block relClock).
"""
import os
import sqlite3
import time

DB_PATH = "/home/fmg/prepper-dashboard/lagezentrum.db"
SCHEMA_VERSION = 1
TIMEOUT_S = 10.0

KEEP_MESH_S = 24 * 3600
KEEP_TELEMETRY_S = 48 * 3600
KEEP_EVENTS_HIST_S = 7 * 86400   # sqlA: abgelaufene Ereignisse bleiben 7 Tage in der Historie (aktiv ist nur expires >= jetzt)

_TABLES = {
    "events": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("source", "TEXT NOT NULL"),          # NINA | DAB | ASA | BR24
        ("type", "TEXT"),                      # z. B. Alert/Update/Cancel, dls, ann, warn
        ("severity", "TEXT"),                  # info | warn | alarm | probe | unknown
        ("headline", "TEXT"),
        ("text", "TEXT"),
        ("lat", "REAL"),
        ("lon", "REAL"),
        ("geojson", "TEXT"),
        ("sent_at", "INTEGER"),
        ("created", "INTEGER"),
        ("updated", "INTEGER"),
        ("expires", "INTEGER"),
        ("is_test", "INTEGER DEFAULT 0"),      # eigene TEST-Knopf-Meldungen -> zaehlen nie
        ("ext_id", "TEXT"),
    ],
    "mesh_log": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("hash", "TEXT NOT NULL"),
        ("channel", "TEXT"),
        ("created", "INTEGER"),
    ],
    "telemetry": [
        ("id", "INTEGER PRIMARY KEY AUTOINCREMENT"),
        ("ts", "INTEGER NOT NULL"),
        ("kind", "TEXT DEFAULT 'dab'"),        # dab | hb
        ("serial", "TEXT"),
        ("channel", "TEXT"),                   # 11D | 5C (hb: Rolle/aktiv)
        ("snr", "REAL"),
        ("ber", "REAL"),                       # FIC-CRC-Fehlerrate (siehe oben)
        ("fic_err", "INTEGER"),
        ("secs", "REAL"),
        ("ensemble", "TEXT"),
        ("mast", "TEXT"),                      # Ensemble + Kanal, z. B. "Bayern · 11D"
        ("rssi", "REAL"),                      # nur wenn verfuegbar (welle-cli: nein)
        ("src_t", "INTEGER"),                  # Zeitstempel der Quelle (Dedup)
    ],
}
_INDEXES = (
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_events_ext ON events(ext_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_upd ON events(updated)",
    "CREATE INDEX IF NOT EXISTS ix_events_exp ON events(expires)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_hash ON mesh_log(hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_created ON mesh_log(created)",
    "CREATE INDEX IF NOT EXISTS ix_tel_ts ON telemetry(ts)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_tel_src ON telemetry(kind, serial, channel, src_t)",
)
_migrated = set()
_last_err = [None]


def _log(*a):
    _last_err[0] = " ".join(str(x) for x in a)[:200]
    print("lagezentrum.db:", *a, flush=True)


def last_error():
    return _last_err[0]


class _Con(sqlite3.Connection):
    """sqlA: close() macht vorher explizit rollback(), wenn noch eine Transaktion offen ist (nie halb geschrieben, keine haengende Sperre)."""

    def close(self):
        try:
            if self.in_transaction:
                self.rollback()
        except Exception:
            pass
        super().close()


_wal_done = set()   # relDb (PERF-06): Pfade, fuer die in diesem Prozess journal_mode=WAL schon gesetzt und bestaetigt wurde


def _set_wal(con, path):
    """relDb: journal_mode=WAL steht dauerhaft in der Datei; je Prozess und Pfad genuegt EIN Setzen (migrate() bzw. erste Verbindung)."""
    r = con.execute("PRAGMA journal_mode=WAL").fetchone()
    if r is not None and str(r[0]).lower() == "wal":
        _wal_done.add(path)
        return True
    return False   # z. B. Dateisystem ohne WAL: nicht merken, naechste Verbindung prueft erneut


def connect(path=None):
    """Neue Verbindung (je Aufruf). busy_timeout, synchronous, Row-Zugriff per Name; WAL nur einmal je Prozess/Pfad (relDb). sqlA: rollback vor close; Fehler in den PRAGMAs -> sofort schliessen."""
    p = path or DB_PATH
    con = sqlite3.connect(p, timeout=TIMEOUT_S, factory=_Con)
    try:
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))
        if p not in _wal_done:
            _set_wal(con, p)
        con.execute("PRAGMA synchronous=NORMAL")
    except Exception:
        con.close()
        raise
    return con


def migrate(path=None):
    """Schema anlegen/ergaenzen (idempotent). Setzt journal_mode=WAL (relDb: hier, nicht mehr bei jeder Verbindung). -> True/False"""
    path = path or DB_PATH
    try:
        _wal_done.discard(path)   # relDb: connect() unten setzt WAL neu und merkt es sich
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        con = connect(path)
        try:
            with con:
                con.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
                for tb, cols in _TABLES.items():
                    con.execute("CREATE TABLE IF NOT EXISTS %s (%s)" % (tb, ", ".join("%s %s" % c for c in cols)))
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ.replace("PRIMARY KEY AUTOINCREMENT", "").replace("NOT NULL", "")))
                for sql in _INDEXES:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_version', ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (str(SCHEMA_VERSION),))
        finally:
            con.close()
        _migrated.add(path)
        return True
    except Exception as e:
        _log("Migration:", e)
        return False


def _ensure(path):
    path = path or DB_PATH
    if path not in _migrated:
        migrate(path)
    return path


def upsert_event(ev, path=None):
    """Ereignis anlegen oder (gleiche ext_id) aktualisieren. -> True/False"""
    path = _ensure(path)
    try:
        now = int(time.time())
        row = {k: ev.get(k) for k in ("source", "type", "severity", "headline", "text", "lat", "lon", "geojson", "sent_at", "created", "updated", "expires", "is_test", "ext_id")}
        if not row["ext_id"] or not row["source"]:
            return False
        row["created"] = int(row["created"] or now)
        row["updated"] = int(row["updated"] or row["created"])
        row["is_test"] = 1 if row["is_test"] else 0
        for k in ("headline", "text"):
            if row[k] is not None:
                row[k] = str(row[k])[:2000]
        con = connect(path)
        try:
            with con:
                con.execute(
                    "INSERT INTO events(source,type,severity,headline,text,lat,lon,geojson,sent_at,created,updated,expires,is_test,ext_id) "
                    "VALUES(:source,:type,:severity,:headline,:text,:lat,:lon,:geojson,:sent_at,:created,:updated,:expires,:is_test,:ext_id) "
                    "ON CONFLICT(ext_id) DO UPDATE SET updated=MAX(COALESCE(events.updated,0), COALESCE(excluded.updated,0)), "
                    "expires=CASE WHEN excluded.expires IS NULL THEN events.expires ELSE MAX(COALESCE(events.expires,0), excluded.expires) END, "
                    "severity=COALESCE(excluded.severity, events.severity), text=COALESCE(excluded.text, events.text), "
                    "headline=COALESCE(excluded.headline, events.headline), type=COALESCE(excluded.type, events.type), "
                    "lat=COALESCE(excluded.lat, events.lat), lon=COALESCE(excluded.lon, events.lon), geojson=COALESCE(excluded.geojson, events.geojson)", row)
        finally:
            con.close()
        return True
    except Exception as e:
        _log("Ereignis:", e)
        return False


def insert_telemetry(t, path=None):
    """Telemetrie-Zeile (gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    path = _ensure(path)
    try:
        row = {k: t.get(k) for k in ("ts", "kind", "serial", "channel", "snr", "ber", "fic_err", "secs", "ensemble", "mast", "rssi", "src_t")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        row["kind"] = row["kind"] or "dab"
        row["src_t"] = int(row["src_t"] if isinstance(row["src_t"], (int, float)) else row["ts"])
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,snr,ber,fic_err,secs,ensemble,mast,rssi,src_t) "
                                  "VALUES(:ts,:kind,:serial,:channel,:snr,:ber,:fic_err,:secs,:ensemble,:mast,:rssi,:src_t)", row)
                return cur.rowcount > 0
        finally:
            con.close()
    except Exception as e:
        _log("Telemetrie:", e)
        return False


def mesh_seen(hash_hex, channel=None, path=None, now=None):
    """Hash merken; True wenn er schon bekannt war (Dublette). Fehler -> None (Aufrufer entscheidet)."""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_log(hash, channel, created) VALUES(?,?,?)", (str(hash_hex), channel, int(now or time.time())))
                return cur.rowcount == 0
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_known(hash_hex, path=None):
    """Nur pruefen, nicht merken. -> True/False/None(Fehler)"""
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return con.execute("SELECT 1 FROM mesh_log WHERE hash=?", (str(hash_hex),)).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def _rows(sql, args=(), path=None):
    path = _ensure(path)
    try:
        con = connect(path)
        try:
            return [dict(r) for r in con.execute(sql, args).fetchall()]
        finally:
            con.close()
    except Exception as e:
        _log("Abfrage:", e)
        return []


def recent_events(n=10, path=None, include_test=False):
    return _rows("SELECT * FROM events %s ORDER BY COALESCE(updated, created) DESC, id DESC LIMIT ?" % ("" if include_test else "WHERE COALESCE(is_test,0)=0"),
                 (int(n),), path)


def active_events(now=None, path=None, since_s=None):
    now = int(now or time.time())
    q = "SELECT * FROM events WHERE COALESCE(is_test,0)=0 AND (expires IS NULL OR expires >= ?)"
    a = [now]
    if since_s:
        q += " AND COALESCE(updated, created) >= ?"
        a.append(now - int(since_s))
    return _rows(q + " ORDER BY COALESCE(updated, created) DESC LIMIT 500", tuple(a), path)


def newest_telemetry(kind=None, path=None):
    r = _rows("SELECT * FROM telemetry %s ORDER BY ts DESC, id DESC LIMIT 1" % ("WHERE kind=?" if kind else ""), (kind,) if kind else (), path)
    return r[0] if r else None


def telemetry_latest_per_channel(path=None):
    return _rows("SELECT t.* FROM telemetry t JOIN (SELECT channel, MAX(ts) m FROM telemetry WHERE kind='dab' GROUP BY channel) x "
                 "ON t.channel=x.channel AND t.ts=x.m WHERE t.kind='dab' ORDER BY t.ts DESC", (), path)


def cleanup(now=None, path=None):
    """Ereignisse 7 Tage nach Ablauf (sqlA), mesh_log > 24 h, Telemetrie > 48 h loeschen (Epoch-Sekunden). -> {tabelle: anzahl}"""
    path = _ensure(path)
    now = int(now or time.time())
    out = {}
    try:
        con = connect(path)
        try:
            with con:
                out["events"] = con.execute("DELETE FROM events WHERE expires IS NOT NULL AND expires < ?", (now - KEEP_EVENTS_HIST_S,)).rowcount
                out["mesh_log"] = con.execute("DELETE FROM mesh_log WHERE created < ?", (now - KEEP_MESH_S,)).rowcount
                out["telemetry"] = con.execute("DELETE FROM telemetry WHERE ts < ?", (now - KEEP_TELEMETRY_S,)).rowcount
        finally:
            con.close()
    except Exception as e:
        _log("Aufraeumen:", e)
    return out


def counts(path=None):
    out = {}
    for tb in _TABLES:
        r = _rows("SELECT COUNT(*) n FROM %s" % tb, (), path)
        out[tb] = r[0]["n"] if r else None
    return out


def selftest():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "t.db")
    assert migrate(p) and migrate(p)  # idempotent
    con = connect(p)
    assert con.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    con.close()
    now = int(time.time())
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a", "expires": now + 60, "created": now - 10}, p)
    assert upsert_event({"source": "ASA", "ext_id": "x1", "headline": "a2", "expires": now + 120, "updated": now}, p)
    ev = recent_events(5, p)
    assert len(ev) == 1 and ev[0]["headline"] == "a2" and ev[0]["expires"] == now + 120 and ev[0]["created"] == now - 10, ev
    assert upsert_event({"source": "BR24", "ext_id": "old", "expires": now - KEEP_EVENTS_HIST_S - 5}, p)
    assert upsert_event({"source": "BR24", "ext_id": "t", "is_test": True}, p) and len(recent_events(9, p)) == 2
    assert insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert not insert_telemetry({"ts": now, "serial": "1", "channel": "11D", "snr": 12.5, "src_t": now}, p)
    assert insert_telemetry({"ts": now - 3 * 86400, "serial": "1", "channel": "5C", "src_t": now - 3 * 86400}, p)
    assert newest_telemetry(path=p)["snr"] == 12.5 and telemetry_latest_per_channel(p)[0]["channel"] == "11D"
    assert mesh_seen("h", "0", p, now - 2 * 86400) is False and mesh_seen("h", "0", p) is True and mesh_known("zz", p) is False
    c = cleanup(now, p)
    assert c == {"events": 1, "mesh_log": 1, "telemetry": 1}, c
    assert counts(p) == {"events": 2, "mesh_log": 0, "telemetry": 1}, counts(p)
    assert recent_events(5, "/proc/nicht/schreibbar/x.db") == []  # Fehler -> leer, kein Absturz
    return "database selftest ok"


# ---------------------------------------------------------------- Teil 2 (SDR-Steuerung, Parser, Resilienz)
# Zusaetzlich, idempotent (migrate_t2): telemetry.tii/ecc/lto/ens_id (kind 'fig' = FIG 0/9 + TII + Ensemble aus welle-cli mux.json),
# mesh_log.src/text/ok/kind (Protokoll des Auto-Versands), Tabelle mesh_auto (eine Meldung je Alarm, 30 Tage) und
# Tabelle asa_rx (Empfangszeitpunkte des ASA-Dienstes auf 5C, 14 Tage). Bestehende Tabellen/Funktionen bleiben unveraendert.
KEEP_MESH_AUTO_S = 30 * 86400
KEEP_ASA_RX_S = 14 * 86400
_T2_ADD = {
    "telemetry": [("tii", "TEXT"), ("ecc", "TEXT"), ("lto", "REAL"), ("ens_id", "TEXT")],
    "mesh_log": [("src", "TEXT"), ("text", "TEXT"), ("ok", "INTEGER"), ("kind", "TEXT")],
}
_T2_SQL = (
    "CREATE TABLE IF NOT EXISTS mesh_auto (id INTEGER PRIMARY KEY AUTOINCREMENT, akey TEXT NOT NULL, hash TEXT, src TEXT, text TEXT, "
    "created INTEGER, last_try INTEGER, tries INTEGER DEFAULT 0, ok INTEGER)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_mesh_auto_key ON mesh_auto(akey)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_auto_try ON mesh_auto(last_try)",
    "CREATE TABLE IF NOT EXISTS asa_rx (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, channel TEXT, serial TEXT)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ux_asa_rx ON asa_rx(channel, ts)",
)
AUTO_RETRY_S = 600            # fehlgeschlagener Auto-Versand fruehestens nach 10 min erneut
AUTO_TRIES_MAX = 3            # hoechstens 3 Versuche je Alarm
_migrated_t2 = set()


def migrate_t2(path=None):
    """Teil-2-Schema ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
        if not migrate(path):
            return False
        con = connect(path)
        try:
            with con:
                for tb, cols in _T2_ADD.items():
                    have = {r[1] for r in con.execute("PRAGMA table_info(%s)" % tb)}
                    for name, typ in cols:
                        if name not in have:
                            con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (tb, name, typ))
                for sql in _T2_SQL:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_t2', '1') ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        finally:
            con.close()
        _migrated_t2.add(path)
        return True
    except Exception as e:
        _log("Migration Teil 2:", e)
        return False


def _ensure_t2(path):
    path = path or DB_PATH
    if path not in _migrated_t2:
        migrate_t2(path)
    return path


def _exec(sql, args, path, what):
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            with con:
                return con.execute(sql, args).rowcount
        finally:
            con.close()
    except Exception as e:
        _log(what, e)
        return None


def _rows_t2(sql, args, path):
    _ensure_t2(path)
    return _rows(sql, args, path)


def insert_fig(t, path=None):
    """FIG 0/9 + TII + Ensemble einer DAB-Pruefung (kind 'fig'; gleiche Quelle/Zeit wird ignoriert). -> True wenn neu"""
    try:
        row = {k: t.get(k) for k in ("ts", "serial", "channel", "ensemble", "mast", "tii", "ecc", "lto", "ens_id")}
        if not isinstance(row["ts"], (int, float)):
            return False
        row["ts"] = int(row["ts"])
        return (_exec("INSERT OR IGNORE INTO telemetry(ts,kind,serial,channel,ensemble,mast,src_t,tii,ecc,lto,ens_id) "
                      "VALUES(:ts,'fig',:serial,:channel,:ensemble,:mast,:ts,:tii,:ecc,:lto,:ens_id)", row, path, "Telemetrie fig:") or 0) > 0
    except Exception as e:
        _log("Telemetrie fig:", e)
        return False


def newest_fig(channel, path=None):
    r = _rows_t2("SELECT * FROM telemetry WHERE kind='fig' AND channel=? ORDER BY ts DESC, id DESC LIMIT 1", (str(channel),), path)
    return r[0] if r else None


def asa_rx_add(ts, channel="5C", serial=None, path=None):
    """Empfangszeitpunkt ASA-Dienst merken. -> True wenn neu"""
    if not isinstance(ts, (int, float)):
        return False
    return (_exec("INSERT OR IGNORE INTO asa_rx(ts, channel, serial) VALUES(?,?,?)", (int(ts), str(channel), serial), path, "asa_rx:") or 0) > 0


def asa_rx_list(since, channel="5C", path=None):
    return [r["ts"] for r in _rows_t2("SELECT ts FROM asa_rx WHERE channel=? AND ts>=? ORDER BY ts", (str(channel), int(since)), path)]


def mesh_hash_since(hash_hex, since, path=None, ok_only=True):
    """Gleicher Inhalt (Hash) seit 'since' gesendet? ok_only: fehlgeschlagene Versuche zaehlen nicht. -> True/False/None(Fehler)"""
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            q = "SELECT 1 FROM mesh_log WHERE hash=? AND created>=?" + (" AND COALESCE(ok, 1)=1" if ok_only else "")
            return con.execute(q, (str(hash_hex), int(since))).fetchone() is not None
        finally:
            con.close()
    except Exception as e:
        _log("mesh_log:", e)
        return None


def mesh_log_put(hash_hex, channel, now, src=None, text=None, ok=None, kind="auto", path=None):
    """Versand protokollieren (gleicher Hash -> Zeit/Ergebnis aktualisiert). -> True/False"""
    n = _exec("INSERT INTO mesh_log(hash, channel, created, src, text, ok, kind) VALUES(?,?,?,?,?,?,?) "
              "ON CONFLICT(hash) DO UPDATE SET created=excluded.created, channel=excluded.channel, src=excluded.src, text=excluded.text, ok=excluded.ok, kind=excluded.kind",
              (str(hash_hex), None if channel is None else str(channel), int(now), src, (str(text)[:300] if text is not None else None),
               None if ok is None else (1 if ok else 0), kind), path, "mesh_log:")
    return bool(n)


def mesh_auto_get(akey, path=None):
    r = _rows_t2("SELECT * FROM mesh_auto WHERE akey=?", (str(akey),), path)
    return r[0] if r else None


def mesh_auto_reserve(akey, hash_hex, src, text, now, path=None):
    """Versuch fuer einen Alarm anmelden. -> 'neu' | 'wieder' (frueherer Versuch fehlgeschlagen) | None (schon gesendet/zu frueh/zu oft/Fehler)"""
    now = int(now)
    path = _ensure_t2(path)
    try:
        con = connect(path)
        try:
            with con:
                cur = con.execute("INSERT OR IGNORE INTO mesh_auto(akey, hash, src, text, created, last_try, tries, ok) VALUES(?,?,?,?,?,?,1,NULL)",
                                  (str(akey), str(hash_hex), src, str(text)[:300], now, now))
                if cur.rowcount > 0:
                    return "neu"
                r = con.execute("SELECT ok, tries, last_try FROM mesh_auto WHERE akey=?", (str(akey),)).fetchone()
                if r is None or r["ok"] != 0 or int(r["tries"] or 0) >= AUTO_TRIES_MAX or now - int(r["last_try"] or 0) < AUTO_RETRY_S:
                    return None
                con.execute("UPDATE mesh_auto SET tries=tries+1, last_try=?, ok=NULL, hash=?, text=? WHERE akey=?", (now, str(hash_hex), str(text)[:300], str(akey)))
                return "wieder"
        finally:
            con.close()
    except Exception as e:
        _log("mesh_auto:", e)
        return None


def mesh_auto_done(akey, ok, path=None):
    return bool(_exec("UPDATE mesh_auto SET ok=? WHERE akey=?", (1 if ok else 0, str(akey)), path, "mesh_auto:"))


def mesh_auto_count(since, path=None):
    """Auto-Versuche seit 'since' (Ratenbegrenzung). Fehler -> None"""
    r = _rows_t2("SELECT COUNT(*) n FROM mesh_auto WHERE last_try>=?", (int(since),), path)
    return r[0]["n"] if r else None


def mesh_auto_recent(n=10, path=None):
    return _rows_t2("SELECT akey, src, text, created, last_try, tries, ok FROM mesh_auto ORDER BY last_try DESC, id DESC LIMIT ?", (int(n),), path)


def cleanup_t2(now=None, path=None):
    now = int(now or time.time())
    return {"mesh_auto": _exec("DELETE FROM mesh_auto WHERE COALESCE(last_try, created, 0) < ?", (now - KEEP_MESH_AUTO_S,), path, "Aufraeumen:"),
            "asa_rx": _exec("DELETE FROM asa_rx WHERE ts < ?", (now - KEEP_ASA_RX_S,), path, "Aufraeumen:")}


def selftest_t2():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "t2.db")
    assert migrate_t2(p) and migrate_t2(p)
    con = connect(p)
    cols = {r[1] for r in con.execute("PRAGMA table_info(telemetry)")} | {r[1] for r in con.execute("PRAGMA table_info(mesh_log)")}
    con.close()
    assert {"tii", "ecc", "lto", "ens_id", "src", "text", "ok", "kind"} <= cols, cols
    now = int(time.time())
    assert insert_fig({"ts": now, "serial": "19348831", "channel": "11D", "ensemble": "Bayern", "mast": "BR Bayern MainID 07 / SubID 02", "tii": "[]", "ecc": "0xE0", "lto": 2.0}, p)
    assert not insert_fig({"ts": now, "serial": "19348831", "channel": "11D"}, p) and newest_fig("11D", p)["ecc"] == "0xE0"
    assert insert_telemetry({"ts": now, "serial": "19348831", "channel": "11D", "snr": 9.0, "src_t": now}, p)   # alte Telemetrie unberuehrt
    assert asa_rx_add(now - 100, path=p) and not asa_rx_add(now - 100, path=p) and asa_rx_add(now, path=p) and asa_rx_list(now - 200, path=p) == [now - 100, now]
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now, p) == "neu" and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 1, p) is None
    assert mesh_auto_done("A1", False, p) and mesh_auto_reserve("A1", "h1", "ASA", "x", now + 60, p) is None          # zu frueh
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + AUTO_RETRY_S, p) == "wieder" and mesh_auto_done("A1", True, p)
    assert mesh_auto_reserve("A1", "h1", "ASA", "x", now + 9 * AUTO_RETRY_S, p) is None and mesh_auto_get("A1", p)["tries"] == 2   # einmal ok = nie wieder
    assert mesh_auto_count(now, p) == 1 and mesh_auto_count(now + 10 * AUTO_RETRY_S, p) == 0
    assert mesh_hash_since("h1", now - 10, p) is False and mesh_log_put("h1", "auto0", now, "ASA", "x", True, path=p) and mesh_hash_since("h1", now - 10, p) is True
    assert mesh_log_put("h1", "auto0", now + 5, "ASA", "x", False, path=p) and mesh_hash_since("h1", now + 1, p) is False and mesh_known("h1", p) is True
    assert mesh_hash_since("h1", now + 1, p, ok_only=False) is True
    c = cleanup_t2(now + KEEP_ASA_RX_S + 1, p)
    assert c["asa_rx"] == 2 and c["mesh_auto"] == 0, c
    assert asa_rx_list(0, path="/proc/nicht/schreibbar/x.db") == [] and mesh_auto_reserve("x", "h", "s", "t", now, "/proc/nicht/schreibbar/x.db") is None
    return "database selftest Teil 2 ok"


# ---------------------------------------------------------------- Teil 3 (Meshtastic-Routing und Priorisierung)
# Zusaetzlich, idempotent (migrate_t3): Tabelle mesh_queue = Warteschlange je Knoten (m1 = Mesh 1 192.168.178.141,
# m2 = Mesh 2 192.168.178.140) fuer NINA-Kurzmeldung und NINA-Details (Details erst nach der eigenen Kurzmeldung,
# 60 s Abstand, Kanal frei). Zustand: wait | ok | dup | fail | skip. Bestehende Tabellen/Funktionen bleiben unveraendert.
KEEP_QUEUE_S = 7 * 86400
_T3_SQL = (
    "CREATE TABLE IF NOT EXISTS mesh_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, node TEXT NOT NULL, kind TEXT NOT NULL, ref TEXT, text TEXT, "
    "hash TEXT, created INTEGER, not_before INTEGER, after_id INTEGER, tries INTEGER DEFAULT 0, last_try INTEGER, state TEXT DEFAULT 'wait', "
    "why TEXT, done INTEGER)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_queue_open ON mesh_queue(node, state, id)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_queue_hash ON mesh_queue(node, hash)",
    "CREATE INDEX IF NOT EXISTS ix_mesh_log_ch ON mesh_log(channel, created)",
)
_Q_FIELDS = ("text", "hash", "not_before", "tries", "last_try", "state", "why", "done", "ref")
_migrated_t3 = set()


def migrate_t3(path=None):
    """Teil-3-Schema ergaenzen (idempotent, setzt Teil 2 voraus). -> True/False"""
    path = path or DB_PATH
    try:
        if not migrate_t2(path):
            return False
        con = connect(path)
        try:
            with con:
                for sql in _T3_SQL:
                    con.execute(sql)
                con.execute("INSERT INTO meta(k, v) VALUES('schema_t3', '1') ON CONFLICT(k) DO UPDATE SET v=excluded.v")
        finally:
            con.close()
        _migrated_t3.add(path)
        return True
    except Exception as e:
        _log("Migration Teil 3:", e)
        return False


def _ensure_t3(path):
    path = path or DB_PATH
    if path not in _migrated_t3:
        migrate_t3(path)
    return path


def q_add(node, kind, text, hash_hex, now, not_before=None, after_id=None, ref=None, path=None, same_s=6 * 3600):
    """Eintrag anlegen; gleicher Knoten + gleicher Hash, der noch wartet oder in den letzten 6 h erledigt wurde -> vorhandene id. -> id | None"""
    now = int(now)
    path = _ensure_t3(path)
    try:
        con = connect(path)
        try:
            with con:
                if hash_hex:
                    r = con.execute("SELECT id FROM mesh_queue WHERE node=? AND hash=? AND (state='wait' OR COALESCE(done, created, 0)>=?) "
                                    "ORDER BY id DESC LIMIT 1", (str(node), str(hash_hex), now - int(same_s))).fetchone()
                    if r is not None:
                        return int(r["id"])
                cur = con.execute("INSERT INTO mesh_queue(node, kind, ref, text, hash, created, not_before, after_id, tries, state) "
                                  "VALUES(?,?,?,?,?,?,?,?,0,'wait')",
                                  (str(node), str(kind), ref, None if text is None else str(text)[:300], hash_hex, now,
                                   int(now if not_before is None else not_before), after_id))
                return int(cur.lastrowid)
        finally:
            con.close()
    except Exception as e:
        _log("mesh_queue:", e)
        return None


def q_get(qid, path=None):
    r = _rows_t3("SELECT * FROM mesh_queue WHERE id=?", (int(qid),), path)
    return r[0] if r else None


def q_open(node, path=None):
    """Wartende Eintraege eines Knotens, aelteste zuerst (Kurzmeldungen vor Details)."""
    return _rows_t3("SELECT * FROM mesh_queue WHERE node=? AND state='wait' ORDER BY CASE kind WHEN 'nina' THEN 0 ELSE 1 END, id", (str(node),), path)


def q_set(qid, path=None, **kw):
    sets = [(k, v) for k, v in kw.items() if k in _Q_FIELDS]
    if not sets:
        return False
    sql = "UPDATE mesh_queue SET %s WHERE id=?" % ", ".join("%s=?" % k for k, _ in sets)
    return bool(_exec(sql, tuple(v for _, v in sets) + (int(qid),), _ensure_t3(path), "mesh_queue:"))


def q_recent(n=10, path=None):
    return _rows_t3("SELECT id, node, kind, text, created, not_before, after_id, tries, last_try, state, why, done FROM mesh_queue "
                    "ORDER BY id DESC LIMIT ?", (int(n),), path)


def mesh_count_since(channel, kinds, since, path=None):
    """Erfolgreiche Sendungen eines Kanals (Knoten) seit 'since' mit kind in kinds (Ratenbegrenzung). Fehler -> None"""
    kinds = tuple(kinds)
    r = _rows_t3("SELECT COUNT(*) n FROM mesh_log WHERE channel=? AND created>=? AND COALESCE(ok, 1)=1 AND kind IN (%s)" % ",".join("?" * len(kinds)),
                 (str(channel), int(since)) + kinds, path)
    return r[0]["n"] if r else None


def mesh_last(hash_hex, path=None):
    """Letzter Eintrag zu einem Hash (fuer Hinweis 'schon gesendet'). -> dict | None"""
    r = _rows_t3("SELECT hash, channel, created, src, ok, kind FROM mesh_log WHERE hash=?", (str(hash_hex),), path)
    return r[0] if r else None


def _rows_t3(sql, args, path):
    _ensure_t3(path)
    return _rows(sql, args, path)


def cleanup_t3(now=None, path=None):
    now = int(now or time.time())
    return {"mesh_queue": _exec("DELETE FROM mesh_queue WHERE state!='wait' AND COALESCE(done, last_try, created, 0) < ?", (now - KEEP_QUEUE_S,),
                                _ensure_t3(path), "Aufraeumen:")}


def selftest_t3():
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), "t3.db")
    assert migrate_t3(p) and migrate_t3(p)
    now = int(time.time())
    a = q_add("m1", "nina", "NINA: Nürnberg: Gefahr", "h1", now, path=p)
    assert a and q_add("m1", "nina", "NINA: Nürnberg: Gefahr", "h1", now + 5, path=p) == a          # wartet schon -> gleiche id
    b = q_add("m2", "nina", "NINA: Nürnberg: Gefahr", "h2", now, path=p)
    d = q_add("m1", "nina_detail", None, None, now, not_before=now + 60, after_id=a, ref='{"ids": []}', path=p)
    assert b != a and d and [r["id"] for r in q_open("m1", p)] == [a, d] and q_get(d, p)["after_id"] == a
    assert q_set(a, p, state="ok", done=now, tries=1, last_try=now) and [r["id"] for r in q_open("m1", p)] == [d]
    assert q_add("m1", "nina", "x", "h1", now + 100, path=p) == a and q_add("m1", "nina", "x", "h1", now + 7 * 3600, path=p) != a   # nach 6 h neu
    assert mesh_log_put("k1", "m1:0", now, "NINA", "x", True, "nina", p) and mesh_log_put("k2", "m1:0", now, "NINA", "y", False, "nina", p)
    assert mesh_log_put("k3", "m2:0", now, "NINA", "z", True, "nina", p) and mesh_log_put("k4", "m1:0", now, "x", "w", True, "manuell", p)
    assert mesh_count_since("m1:0", ("nina", "nina_detail"), now - 10, p) == 1 and mesh_count_since("m2:0", ("nina",), now - 10, p) == 1
    assert mesh_last("k4", p)["kind"] == "manuell" and mesh_last("nix", p) is None and not q_set(a, p, bogus=1)
    assert cleanup_t3(now + KEEP_QUEUE_S + 3 * 3600, p)["mesh_queue"] == 1
    assert q_add("m1", "nina", "x", "h", now, path="/proc/nicht/schreibbar/x.db") is None and q_open("m1", "/proc/nicht/schreibbar/x.db") == []
    return "database selftest Teil 3 ok"

# ---------------------------------------------------------------- relDb (REL-07 + PERF-06): Datenbank-Wartung im Hintergrund
# Zweck: lagezentrum.db (klein, WAL) dauerhaft gesund halten, OHNE den Alarmpfad zu stoerenden.
#  - journal_mode=WAL wird je Prozess und Pfad EINMAL gesetzt/geprueft (migrate() bzw. erste Verbindung), nicht mehr bei jeder Verbindung (PERF-06).
#  - Checkpoint: alle 6 h (monotonic, Zeitspruenge egal) oder wenn die -wal-Datei > 64 MiB ist: PRAGMA wal_checkpoint(TRUNCATE) mit 1 s Wartezeit,
#    aber nur wenn KEIN Alarm in Arbeit ist (wartender mesh_queue-Eintrag / Auto-Versuch ohne Ergebnis < 15 min) und tools/backup.sh nicht laeuft
#    (flock auf .backup.lock). Sonst nur PASSIVE (blockiert nie) und naechster Versuch beim naechsten Lauf des Aufraeum-Fadens (10 min).
#  - quick_check: in eigenem Faden (lz-quickcheck), nur lesend (mode=ro), 120 s nach Start und danach woechentlich, mit Zeitlimit; Ergebnis in
#    retention_status()["maint"] und in lagezentrum.db.maint.json. Bei Fehlern wird NUR gemeldet (Journal, Status) - nie eine Datei beiseitegelegt oder geloescht
#    (mehrere Prozesse haben die Datei offen); Vorgehen steht in tools/lage_db_maint.py und im Bericht.
#  - Kein VACUUM im laufenden Betrieb: nur manuell ueber tools/lage_db_maint.py vacuum (mit Sicherung, Pruefung, Platzbedarf).
#  - snapshot(): konsistente Kopie ueber die sqlite3-Backup-API (wie tools/backup.sh), mit quick_check der Kopie; ueberschreibt nie.
#  Alles faengt Fehler ab (wirft nie); aendert keine Daten; sendet nichts.
import errno as _rd_errno
import json as _rd_json
import threading as _rd_threading
try:
    import fcntl as _rd_fcntl
except Exception:                      # nicht Linux
    _rd_fcntl = None

CKPT_EVERY_S = 6 * 3600                # harter Checkpoint alle 6 h
WAL_MAX_BYTES = 64 * 1024 * 1024       # -wal groesser als das: nicht auf die 6 h warten
CKPT_BUSY_MS = 1000                    # hoechstens so lange auf Leser warten (blockiert Schreiber in dieser Zeit)
QC_FIRST_S = 120                       # erster quick_check 120 s nach dem ersten Lauf des Aufraeum-Fadens
QC_EVERY_S = 7 * 86400                 # danach woechentlich
QC_LIMIT_S = 120.0                     # quick_check abbrechen (kein Fehler der Datei), wenn er laenger dauert
ALARM_INFLIGHT_S = 900                 # Auto-Versuch ohne Ergebnis juenger als 15 min = Alarm in Arbeit
BACKUP_LOCK = "/home/fmg/prepper-backups/.backup.lock"   # tools/backup.sh haelt hier flock waehrend der Sicherung


def wal_bytes(path=None):
    """Groesse der -wal-Datei in Bytes (0 = keine)."""
    try:
        return os.path.getsize((path or DB_PATH) + "-wal")
    except OSError:
        return 0


def _ro(path, timeout=1.0):
    from urllib.parse import quote
    con = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(path)), uri=True, timeout=timeout)
    con.execute("PRAGMA busy_timeout=%d" % int(timeout * 1000))
    return con


def backup_running(lock=None):
    """True, wenn tools/backup.sh gerade laeuft (haelt flock auf .backup.lock). Keine Sperrdatei oder unklar -> False."""
    lock = lock or BACKUP_LOCK
    if _rd_fcntl is None:
        return False
    fd = None
    try:
        fd = os.open(lock, os.O_RDONLY)
    except OSError:
        return False
    try:
        try:
            _rd_fcntl.flock(fd, _rd_fcntl.LOCK_SH | _rd_fcntl.LOCK_NB)
        except OSError as e:
            return e.errno in (_rd_errno.EWOULDBLOCK, _rd_errno.EAGAIN)
        return False
    except Exception:
        return False
    finally:
        try:
            os.close(fd)                # gibt die kurze Lesesperre sofort wieder frei
        except OSError:
            pass


def alarm_pending(path=None, now=None):
    """Alarmpfad gerade in Arbeit? True: wartender mesh_queue-Eintrag oder Auto-Versuch (mesh_auto) ohne Ergebnis juenger als 15 min.
    Fehlende Tabellen = nichts in Arbeit; jeder andere Fehler -> True (vorsichtig: dann kein harter Checkpoint)."""
    path = path or DB_PATH
    now = int(now or time.time())
    con = None
    try:
        if not os.path.exists(path):
            return False
        con = _ro(path, 1.0)
        for sql, args in (("SELECT 1 FROM mesh_queue WHERE state='wait' LIMIT 1", ()),
                          ("SELECT 1 FROM mesh_auto WHERE ok IS NULL AND COALESCE(last_try, created, 0) >= ? LIMIT 1", (now - ALARM_INFLIGHT_S,))):
            try:
                if con.execute(sql, args).fetchone() is not None:
                    return True
            except sqlite3.OperationalError as e:
                if "no such table" in str(e):
                    continue
                raise
        return False
    except Exception:
        return True
    finally:
        try:
            con and con.close()
        except Exception:
            pass


def checkpoint(path=None, mode="PASSIVE", busy_ms=CKPT_BUSY_MS):
    """WAL-Checkpoint. mode PASSIVE (blockiert nie) oder TRUNCATE (wartet hoechstens busy_ms auf Leser). Wirft nie.
    -> {"mode", "busy", "log", "done", "wal_before", "wal_after", "ms", "err"}"""
    mode = "TRUNCATE" if str(mode).upper() == "TRUNCATE" else "PASSIVE"
    path = path or DB_PATH
    out = {"mode": mode, "busy": None, "log": None, "done": None, "wal_before": wal_bytes(path), "wal_after": None, "ms": None, "err": None}
    t0 = time.monotonic()   # relClock: Dauer monoton (Zeitspruenge)
    con = None
    try:
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        con = sqlite3.connect(path, timeout=max(0.1, busy_ms / 1000.0))
        con.execute("PRAGMA busy_timeout=%d" % int(busy_ms))
        r = con.execute("PRAGMA wal_checkpoint(%s)" % mode).fetchone()
        if r is not None:
            out["busy"], out["log"], out["done"] = int(r[0]), int(r[1]), int(r[2])
    except Exception as e:
        out["err"] = str(e)[:120]
    finally:
        try:
            con and con.close()
        except Exception:
            pass
    out["wal_after"] = wal_bytes(path)
    out["ms"] = int((time.monotonic() - t0) * 1000)
    return out


def quick_check(path=None, limit_s=QC_LIMIT_S, max_rows=5):
    """PRAGMA quick_check nur lesend (mode=ro), mit Zeitlimit. -> {"ok", "rows", "ms", "err", "aborted"}
    ok True = 'ok'; ok False + rows = Befund der Datei; ok None + err = nicht pruefbar (gesperrt, Zeitlimit, fehlt) - das ist KEIN Befund."""
    path = path or DB_PATH
    out = {"ok": None, "rows": [], "ms": None, "err": None, "aborted": False}
    t0 = time.monotonic()   # relClock: Zeitlimit und Dauer monoton - ein Zeitsprung darf den Test weder abbrechen noch endlos laufen lassen
    con = None
    try:
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        con = _ro(path, 2.0)
        deadline = t0 + float(limit_s)

        def _stop():
            return 1 if time.monotonic() > deadline else 0
        con.set_progress_handler(_stop, 20000)
        rows = [str(r[0])[:160] for r in con.execute("PRAGMA quick_check(%d)" % int(max_rows)).fetchall()]
        out["rows"] = rows[:max_rows]
        out["ok"] = rows == ["ok"]
    except sqlite3.Error as e:
        msg = str(e)
        code = getattr(e, "sqlite_errorcode", None)
        low = msg.lower()
        if code in (11, 26) or "malformed" in low or "not a database" in low:      # SQLITE_CORRUPT / SQLITE_NOTADB = Befund der Datei
            out["ok"] = False
            out["rows"] = [msg[:160]]
        elif code == 9 or "interrupt" in low:                                       # eigenes Zeitlimit = nicht pruefbar, KEIN Befund
            out["aborted"] = True
            out["err"] = "Zeitlimit"
        else:                                                                        # gesperrt, kein Zugriff usw. = nicht pruefbar, KEIN Befund
            out["err"] = msg[:120]
    except Exception as e:
        out["err"] = str(e)[:120]
    finally:
        try:
            con and con.close()
        except Exception:
            pass
    out["ms"] = int((time.monotonic() - t0) * 1000)
    return out


def db_stats(path=None):
    """Seitenzahl, freie Seiten, Dateigroessen (nur lesend). Fehler -> {"err"}"""
    path = path or DB_PATH
    con = None
    try:
        con = _ro(path, 1.0)
        ps = int(con.execute("PRAGMA page_size").fetchone()[0])
        pc = int(con.execute("PRAGMA page_count").fetchone()[0])
        fl = int(con.execute("PRAGMA freelist_count").fetchone()[0])
        out = {"page_size": ps, "pages": pc, "free_pages": fl, "bytes": ps * pc, "free_bytes": ps * fl, "wal_bytes": wal_bytes(path)}
        out["vacuum_hint"] = bool(out["free_bytes"] >= 50 * 1024 * 1024 and fl * 3 >= pc)   # nur ein Hinweis, nichts geschieht automatisch
        return out
    except Exception as e:
        return {"err": str(e)[:120]}
    finally:
        try:
            con and con.close()
        except Exception:
            pass


def snapshot(dest, path=None, check=True):
    """Konsistente Kopie ueber die sqlite3-Backup-API (auch im laufenden Betrieb), Rechte 600, ueberschreibt nie. -> {"ok", "bytes", "check", "err"}"""
    path = path or DB_PATH
    out = {"ok": False, "bytes": None, "check": None, "err": None}
    part = str(dest) + ".part"
    src = dst = None
    try:
        if os.path.exists(dest):
            raise RuntimeError("Ziel existiert schon")
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        if os.path.exists(part):
            os.unlink(part)
        src = _ro(path, 20.0)
        old_umask = os.umask(0o077)
        try:
            dst = sqlite3.connect(part)
        finally:
            os.umask(old_umask)
        src.backup(dst)
        dst.commit()
        if check:
            out["check"] = [str(r[0])[:160] for r in dst.execute("PRAGMA quick_check(5)").fetchall()]
            if out["check"] != ["ok"]:
                raise RuntimeError("quick_check der Kopie: %s" % out["check"][:1])
        dst.close()
        dst = None
        os.chmod(part, 0o600)
        os.replace(part, dest)
        out["bytes"] = os.path.getsize(dest)
        out["ok"] = True
    except Exception as e:
        out["err"] = str(e)[:140]
        try:
            os.path.exists(part) and os.unlink(part)
        except OSError:
            pass
    finally:
        for c in (dst, src):
            try:
                c and c.close()
            except Exception:
                pass
    return out


def _mb(n):
    return "%.1f MB" % ((n or 0) / 1048576.0)


class _Maint:
    """Wartungsplan (tick() vom Aufraeum-Faden alle 10 min, wirft nie). Zeiten mit time.monotonic()."""

    def __init__(self, ckpt_every_s=CKPT_EVERY_S, wal_max=WAL_MAX_BYTES, qc_first_s=QC_FIRST_S, qc_every_s=QC_EVERY_S, lock=None, quiet=False):
        self.ckpt_every_s, self.wal_max, self.qc_first_s, self.qc_every_s = ckpt_every_s, wal_max, qc_first_s, qc_every_s
        self.lock_path = lock
        self.quiet = quiet
        self.lock = _rd_threading.Lock()
        self.t0 = None
        self.last_ckpt = None
        self.th = None
        self.stop = False
        self.path = None
        self.st = {"ready": None, "ckpt": None, "ckpt_n": 0, "ckpt_ok_n": 0, "ckpt_skip": None, "qc": None, "qc_n": 0, "stats": None, "wal": None, "err": None, "alert": None}

    def _say(self, *a):
        if not self.quiet:
            print("lagezentrum.db Wartung (relDb):", *a, flush=True)

    def _write(self):
        try:
            p = (self.path or DB_PATH) + ".maint.json"
            tmp = p + ".tmp"
            with open(tmp, "w") as f:
                _rd_json.dump(self.status(), f, ensure_ascii=False, indent=1)
            os.replace(tmp, p)
        except Exception:
            pass

    def _ckpt(self, path, m, wal, why):
        if backup_running(self.lock_path):
            self.st["ckpt_skip"] = {"t": int(time.time()), "why": "Sicherung laeuft (backup.sh)"}
            return
        if alarm_pending(path):
            r = checkpoint(path, "PASSIVE")
            r["note"] = "Alarm in Arbeit - nur PASSIVE, harter Checkpoint beim naechsten Lauf"
        else:
            r = checkpoint(path, "TRUNCATE")
            if r["err"] is None and r["busy"] == 0:
                self.last_ckpt = m
                self.st["ckpt_ok_n"] += 1
            else:
                r["note"] = "Leser aktiv (busy) - PASSIVE-Versuch, naechster harter Versuch beim naechsten Lauf"
                r2 = checkpoint(path, "PASSIVE")
                r["passive"] = {"busy": r2["busy"], "err": r2["err"]}
        r["t"] = int(time.time())
        r["why"] = why
        self.st["ckpt"] = r
        self.st["ckpt_n"] += 1
        self.st["ckpt_skip"] = None
        self._say("Checkpoint %s %s (%s): WAL %s -> %s (%d ms)%s" % (r["mode"], "ok" if r["err"] is None and r["busy"] == 0 else "nicht vollstaendig", why,
                  _mb(r["wal_before"]), _mb(r["wal_after"]), r["ms"] or 0, (" - " + r["note"]) if r.get("note") else ""))

    def _qc_loop(self, path):
        t_end = time.monotonic() + self.qc_first_s
        while not self.stop and time.monotonic() < t_end:
            time.sleep(min(2.0, max(0.05, t_end - time.monotonic())))
        while not self.stop:
            tries = 0
            while backup_running(self.lock_path) and tries < 30 and not self.stop:
                tries += 1
                time.sleep(10)
            r = quick_check(path)
            r["t"] = int(time.time())
            self.st["qc"] = r
            self.st["qc_n"] += 1
            self.st["stats"] = db_stats(path)
            if r["ok"] is False:
                self.st["alert"] = "quick_check meldet einen Befund: %s" % "; ".join(r["rows"][:2])
                _log("quick_check BEFUND:", "; ".join(r["rows"][:2]), "- Datei NICHT veraendert; Sicherung pruefen (tools/lage_db_maint.py status), siehe Bericht")
                print("lagezentrum.db Wartung (relDb): quick_check BEFUND - %s" % "; ".join(r["rows"][:2]), flush=True)
            else:
                self.st["alert"] = None
                self._say("quick_check %s (%d ms)%s" % ("ok" if r["ok"] else "nicht pruefbar: %s" % r["err"], r["ms"] or 0,
                          " - Hinweis: viele freie Seiten, VACUUM nur manuell (tools/lage_db_maint.py vacuum)" if (self.st["stats"] or {}).get("vacuum_hint") else ""))
            self._write()
            t_end = time.monotonic() + self.qc_every_s
            while not self.stop and time.monotonic() < t_end:
                time.sleep(min(60.0, max(0.05, t_end - time.monotonic())))

    def tick(self, path=None, mono=None):
        """Ein Wartungsschritt. Wirft nie."""
        try:
            path = path or self.path or DB_PATH
            m = time.monotonic() if mono is None else mono
            with self.lock:
                self.path = path
                if self.t0 is None:
                    self.t0 = m
                    self.last_ckpt = m
                    self.st["ready"] = int(time.time())
                    self._say("bereit - Checkpoint alle %d h (TRUNCATE nur ohne Alarm in Arbeit und ohne laufende Sicherung, sonst PASSIVE), quick_check %d s nach Start und dann alle %d Tage, kein VACUUM im Betrieb"
                              % (self.ckpt_every_s // 3600, self.qc_first_s, self.qc_every_s // 86400))
                if self.th is None or not self.th.is_alive():
                    self.th = _rd_threading.Thread(target=self._qc_loop, args=(path,), name="lz-quickcheck", daemon=True)
                    self.th.start()
                wal = wal_bytes(path)
                self.st["wal"] = wal
                if wal > self.wal_max:
                    self._ckpt(path, m, wal, "WAL %s > %s" % (_mb(wal), _mb(self.wal_max)))
                elif m - self.last_ckpt >= self.ckpt_every_s:
                    self._ckpt(path, m, wal, "%d h" % (self.ckpt_every_s // 3600))
                self.st["err"] = None
            self._write()
        except Exception as e:
            self.st["err"] = str(e)[:120]
        return self.st

    def status(self):
        try:
            return dict(self.st, ckpt_every_s=self.ckpt_every_s, wal_max=self.wal_max, qc_first_s=self.qc_first_s, qc_every_s=self.qc_every_s,
                        qc_alive=bool(self.th is not None and self.th.is_alive()))
        except Exception as e:
            return {"err": str(e)[:100]}


def selftest_maint():
    import shutil
    import tempfile
    d = tempfile.mkdtemp(prefix="lzmaint-")
    p = os.path.join(d, "m.db")
    assert migrate(p) and migrate_t2(p) and migrate_t3(p)
    # PERF-06: WAL steht in der Datei und wird je Prozess/Pfad nur einmal gesetzt
    assert p in _wal_done
    n_before = len(_wal_done)
    for _ in range(5):
        connect(p).close()
    assert len(_wal_done) == n_before
    c = connect(p)
    assert c.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    c.close()
    # WAL wachsen lassen (Auto-Checkpoint aus), dann Checkpoint
    c = connect(p)
    c.execute("PRAGMA wal_autocheckpoint=0")
    for i in range(300):
        c.execute("INSERT INTO mesh_log(hash, channel, created) VALUES(?, 'x', ?)", ("h%d" % i, int(time.time())))
    c.commit()
    assert wal_bytes(p) > 0
    r = checkpoint(p, "PASSIVE")
    assert r["err"] is None and r["busy"] == 0, r
    r = checkpoint(p, "TRUNCATE")
    assert r["err"] is None and r["busy"] == 0 and wal_bytes(p) == 0, r
    c.close()
    # Leser blockiert TRUNCATE nicht endlos: nach busy_ms kommt busy=1 zurueck, kein Haengen, Daten bleiben
    rd = connect(p)
    rd.execute("BEGIN")
    rd.execute("SELECT COUNT(*) FROM mesh_log").fetchone()
    w = connect(p)
    w.execute("INSERT INTO mesh_log(hash, channel, created) VALUES('nach', 'x', 1)")
    w.commit()
    t0 = time.time()
    r = checkpoint(p, "TRUNCATE", busy_ms=300)
    assert time.time() - t0 < 5 and (r["busy"] == 1 or r["err"] is not None or wal_bytes(p) == 0), r
    rd.rollback()
    rd.close()
    w.close()
    assert mesh_known("nach", p) is True and mesh_known("h299", p) is True
    # Alarm in Arbeit
    assert alarm_pending(p) is False
    q = q_add("m1", "nina", "x", "ha", int(time.time()), path=p)
    assert q and alarm_pending(p) is True
    assert q_set(q, p, state="ok", done=1) and alarm_pending(p) is False
    assert mesh_auto_reserve("A9", "h", "ASA", "x", int(time.time()), p) == "neu" and alarm_pending(p) is True     # Versuch ohne Ergebnis
    assert mesh_auto_done("A9", True, p) and alarm_pending(p) is False
    assert alarm_pending(os.path.join(d, "fehlt.db")) is False and alarm_pending("/proc/nicht/da/x.db") is False
    # Sicherung laeuft (flock wie backup.sh)
    lk = os.path.join(d, ".backup.lock")
    assert backup_running(lk) is False
    fd = os.open(lk, os.O_WRONLY | os.O_CREAT, 0o600)
    assert backup_running(lk) is False
    _rd_fcntl.flock(fd, _rd_fcntl.LOCK_EX)
    assert backup_running(lk) is True
    os.close(fd)
    assert backup_running(lk) is False
    # quick_check: gesund = ok; kaputte Kopie = Befund; fehlend/gesperrt = nicht pruefbar (kein Befund)
    r = quick_check(p)
    assert r["ok"] is True and r["rows"] == ["ok"], r
    s = db_stats(p)
    assert s["pages"] > 0 and s["bytes"] == s["pages"] * s["page_size"], s
    bad = os.path.join(d, "bad.db")
    sn = snapshot(os.path.join(d, "snap.db"), p)
    assert sn["ok"] and sn["check"] == ["ok"] and (os.stat(os.path.join(d, "snap.db")).st_mode & 0o777) == 0o600, sn
    assert snapshot(os.path.join(d, "snap.db"), p)["ok"] is False                # ueberschreibt nie
    shutil.copy(os.path.join(d, "snap.db"), bad)
    with open(bad, "r+b") as f:                                                  # Kopfbereiche mehrerer B-Baum-Seiten zerstoeren
        for pg in range(2, 7):
            f.seek((pg - 1) * 4096)
            f.write(b"\xff" * 64)
    r = quick_check(bad)
    assert r["ok"] is False and r["rows"] and r["rows"] != ["ok"], r
    assert quick_check(os.path.join(d, "fehlt.db"))["ok"] is None
    assert not os.path.exists(os.path.join(d, "fehlt.db"))                      # legt nie eine Datei an
    # Wartungsplan: erster Lauf = bereit, kein Checkpoint; spaeter nach 6 h (monotonic) oder grosser WAL; wirft nie
    mt = _Maint(ckpt_every_s=100, wal_max=1 << 40, qc_first_s=0.05, qc_every_s=3600, lock=lk, quiet=True)
    st = mt.tick(p, mono=1000.0)
    assert st["ready"] and st["ckpt"] is None and mt.th is not None
    for _ in range(100):                                                        # erst den (kurzen) quick_check abwarten: ein Leser koennte sonst TRUNCATE bremsen
        if mt.st["qc"] is not None:
            break
        time.sleep(0.1)
    assert mt.st["qc"] is not None
    mt.tick(p, mono=1050.0)
    assert mt.st["ckpt"] is None
    c = connect(p)
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("INSERT INTO mesh_log(hash, channel, created) VALUES('w1', 'x', 1)")
    c.commit()
    c.close()
    mt.tick(p, mono=1101.0)
    assert mt.st["ckpt"] and mt.st["ckpt"]["mode"] == "TRUNCATE" and mt.st["ckpt"]["busy"] == 0 and mt.st["ckpt_ok_n"] == 1, mt.st["ckpt"]
    fd = os.open(lk, os.O_WRONLY | os.O_CREAT, 0o600)
    _rd_fcntl.flock(fd, _rd_fcntl.LOCK_EX)
    n0 = mt.st["ckpt_n"]
    mt.tick(p, mono=1300.0)                                                     # Sicherung laeuft -> kein Checkpoint
    assert mt.st["ckpt_n"] == n0 and mt.st["ckpt_skip"], mt.st
    os.close(fd)
    q = q_add("m1", "nina", "y", "hb", int(time.time()), path=p)
    c = connect(p)
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("INSERT INTO mesh_log(hash, channel, created) VALUES('w2', 'x', 1)")
    c.commit()
    c.close()
    mt.tick(p, mono=1400.0)                                                     # Alarm in Arbeit -> nur PASSIVE
    assert mt.st["ckpt"]["mode"] == "PASSIVE" and "Alarm" in mt.st["ckpt"]["note"], mt.st["ckpt"]
    for _ in range(100):
        if mt.st["qc"] is not None:
            break
        time.sleep(0.1)
    assert mt.st["qc"] and mt.st["qc"]["ok"] is True and mt.st["alert"] is None, mt.st["qc"]
    assert os.path.exists(p + ".maint.json") and _rd_json.load(open(p + ".maint.json"))["qc"]["ok"] is True
    mt.stop = True
    assert _Maint(quiet=True).tick("/proc/nicht/da/x.db", mono=5.0) is not None   # wirft nie
    # Schreiber laufen waehrend harter Checkpoints weiter (kein Fehler, keine lange Sperre)
    stop = [False]
    errs = []
    lat = []

    def _writer():
        i = 0
        while not stop[0]:
            t1 = time.time()
            try:
                if not mesh_log_put("wr%d" % i, "x", int(time.time()), "t", "t", True, path=p):
                    errs.append("put")
            except Exception as e:
                errs.append(str(e))
            lat.append(time.time() - t1)
            i += 1
            time.sleep(0.002)
    th = _rd_threading.Thread(target=_writer, daemon=True)
    th.start()
    for _ in range(8):
        checkpoint(p, "TRUNCATE", busy_ms=500)
        time.sleep(0.05)
    stop[0] = True
    th.join(5)
    assert not errs and lat and max(lat) < 3.0, (errs[:2], max(lat) if lat else None)
    # kein Aufraeum-Befehl dieser Art im Programmtext dieser Datei (nur manuell ueber tools/lage_db_maint.py)
    import ast as _ast
    tok = "VAC" + "UUM"
    src = open(__file__).read() if "__file__" in globals() else ""
    if src:
        for node in _ast.walk(_ast.parse(src)):
            if isinstance(node, _ast.Constant) and isinstance(node.value, str) and node.value.strip().upper().split()[:1] == [tok]:
                raise AssertionError("Platz-Aufraeumbefehl im Betrieb")
    shutil.rmtree(d, ignore_errors=True)
    return "database selftest relDb ok (WAL einmal je Pfad, Checkpoint PASSIVE/TRUNCATE mit Wartegrenze, Alarm-in-Arbeit-/Sicherungs-Sperre, quick_check ro mit Befund/nicht pruefbar, snapshot ueberschreibt nie, Schreiber laufen weiter, kein VACUUM)"


# ---------------------------------------------------------------- sqlA (Aufraeumen im eigenen Faden)
# start_retention(): ein Daemon-Faden je Prozess (Sperre, doppelter Start = nichts), alle 10 min alle Aufraeumarbeiten mit Epoch-Sekunden
# (alle Zeitspalten sind Unix-Sekunden, UTC-neutral): events erst 7 Tage NACH Ablauf loeschen (Historie; aktiv ist nur expires >= jetzt),
# mesh_log > 24 h, telemetry > 48 h, mesh_auto 30 d, asa_rx 14 d, mesh_queue 7 d, dazu Zusatzarbeiten (z. B. lageGeo-Cache) vom Aufrufer.
# retention_owns(path): Faden laeuft gesund fuer diese DB -> alte Ausloeser (Sync.tick, Teil 2/3, lageGeo) tun nichts.
# retention_watch(path): Rueckfall fuer Sync.tick: Faden fuer diese DB gestartet aber tot -> neu starten; nie gestartet -> einmal direkt aufraeumen.
import threading as _ret_threading

RETENTION_S = 600
RETENTION_FIRST_S = 30


# ---------------------------------------------------------------- relClock (REL-06): Uhr-Plausibilitaet vor dem Loeschen, monotone Zeit fuer Intervalle
# Das Aufraeumen loescht nach "jetzt minus Frist" (Wanduhr). Steht die Uhr falsch oder springt sie (Pi ohne RTC, chrony makestep), duerfen Fristen nicht greifen:
#  - lage_clock.clock_ok() False -> der Aufraeum-Faden loescht NICHTS (auch nicht die Zusatz-Aufraeumer), meldet das einmal je Wechsel im Journal und laeuft weiter
#    (Checkpoint/quick_check der Wartung brauchen keine Wanduhr). Nach plausibler Uhr (und 15 min Haltezeit nach einem Sprung) wird normal aufgeraeumt.
#  - fehlt lage_clock.py oder wirft es: es wird wie bisher aufgeraeumt (kein neuer Ausfall); das steht im Status ("pruefer").
#  - Dauern und Zeitlimits sowie owns() nutzen time.monotonic() statt der Wanduhr (ein Zeitsprung darf den Faden nicht fuer tot erklaeren oder quick_check abbrechen).
try:
    import lage_clock as _lclk
except Exception:   # noch nicht installiert oder defekt -> wie bisher, ehrlich im Status
    _lclk = None


def _clock_state():
    """-> (ok, Grund, Pruefer). Wirft nie. Ohne lage_clock: (True, 'lage_clock fehlt', False)."""
    if _lclk is None:
        return True, "lage_clock fehlt - Uhr nicht geprueft", False
    try:
        ok, why = _lclk.clock_state()
        return bool(ok), str(why)[:120], True
    except Exception as e:
        return True, "Uhr-Pruefer Fehler: %s" % str(e)[:60], False


def _clock_gate(ret):
    """Fuer den Aufraeum-Faden: (ok, Grund). Meldet jeden Wechsel einmal ins Journal (ausser ret.quiet)."""
    ok, why, chk = _clock_state()
    key = (ok, chk)
    if ret.clock_last != key:
        first = ret.clock_last is None
        ret.clock_last = key
        if not ok:
            if not ret.quiet:
                print("lagezentrum.db Aufraeumen pausiert (relClock): %s - es wird nichts geloescht, bis die Uhr plausibel ist" % why, flush=True)
        elif not first and not ret.quiet:
            print("lagezentrum.db Aufraeumen (relClock): Uhr wieder plausibel (%s) - es wird wieder aufgeraeumt" % why, flush=True)
        elif first and not ret.quiet:
            print("lagezentrum.db Uhr (relClock): %s - Aufraeumen erlaubt" % why, flush=True)
    ret.clock_why = why
    return ok, why


def selftest_clock():
    import tempfile
    d = tempfile.mkdtemp(prefix="lzclk-")
    p = os.path.join(d, "c.db")
    assert migrate(p) and migrate_t2(p) and migrate_t3(p)
    now = int(time.time())
    for eid, exp in (("ab_8d", now - 8 * 86400), ("aktiv", now + 3600)):
        assert upsert_event({"source": "NINA", "ext_id": eid, "severity": "warn", "headline": eid, "created": now - 9 * 86400, "updated": now - 9 * 86400, "expires": exp}, p)
    global _clock_state
    saved = _clock_state
    r = _Retention(every_s=3600, first_s=3600)
    r.quiet = True
    r.maint = None
    r.path = p
    n_before = counts(p)["events"]
    try:
        _clock_state = lambda: (False, "Uhr unplausibel (Test)", True)
        out = r.run(now, p)
        assert out.get("clock_pause") and counts(p)["events"] == n_before, (out, counts(p))   # Uhr falsch: nichts geloescht
        assert r.st["last"].get("clock_pause")
        _clock_state = lambda: (True, "plausibel (Test)", True)
        out = r.run(now, p)
        assert "clock_pause" not in out and counts(p)["events"] == n_before - 1, (out, counts(p))   # Uhr ok: abgelaufenes Ereignis (8 Tage) wird geloescht
        # fehlender/defekter Pruefer blockiert nicht
        _clock_state = lambda: (True, "lage_clock fehlt - Uhr nicht geprueft", False)
        assert r.run(now, p).get("clock_pause") is None
    finally:
        _clock_state = saved
        for f in os.listdir(d):
            try:
                os.unlink(os.path.join(d, f))
            except OSError:
                pass
        try:
            os.rmdir(d)
        except OSError:
            pass
    # owns() rechnet monotonic: ein Wanduhr-Sprung macht den gesunden Faden nicht "tot"
    q = _Retention(every_s=600, first_s=30)
    q.th = _ret_threading.Thread(target=lambda: time.sleep(2), daemon=True)
    q.th.start()
    q.path = DB_PATH
    q.st["t"] = int(time.time()) - 10 ** 7        # Wanduhr-Anzeige "uralt" (Sprung)
    q.mono_ref = time.monotonic()
    assert q.owns(DB_PATH) is True
    q.mono_ref = time.monotonic() - 10 ** 5       # wirklich lange nichts gelaufen
    assert q.owns(DB_PATH) is False
    st = _RETX.status()
    assert "clock" in st and "ok" in st["clock"], st
    return "database selftest relClock ok (Uhr falsch -> nichts geloescht, Uhr ok -> aufgeraeumt, ohne Pruefer wie bisher, owns monotonic)"


class _Retention:
    def __init__(self, every_s=RETENTION_S, first_s=RETENTION_FIRST_S, name="lz-retention"):
        self.every_s, self.first_s, self.name = every_s, first_s, name
        self.lock = _ret_threading.Lock()
        self.th = None
        self.quiet = False
        self.stop = False
        self.path = None
        self.extra = {}
        self.maint = _Maint()   # relDb: Checkpoint/quick_check im selben Faden (nicht bei Test-Instanzen: maint = None)
        self.clock_last = None   # relClock: (ok, Pruefer) des letzten Laufs - Journalmeldung nur bei Wechsel
        self.clock_why = None
        self.mono_ref = time.monotonic()   # relClock: letzter Lebenszeichen-Zeitpunkt (monoton) fuer owns()
        self.st = {"started": None, "restarts": 0, "n": 0, "t": None, "last": None, "err": None, "first": None}

    def run(self, now=None, path=None):
        path = path or self.path or DB_PATH
        now = int(now or time.time())
        t0 = time.monotonic()
        out = {}
        ck_ok, ck_why = _clock_gate(self)   # relClock: Uhr unplausibel -> nichts loeschen (auch nicht die Zusatz-Aufraeumer)
        if not ck_ok:
            out["clock_pause"] = ck_why[:80]
        try:
            if ck_ok:
                out.update(cleanup(now, path))
        except Exception as e:
            out["err_base"] = str(e)[:80]
        for k, fn in (("t2", cleanup_t2), ("t3", cleanup_t3)):
            if not ck_ok:
                break
            try:
                out.update(fn(now, path) or {})
            except Exception as e:
                out["err_" + k] = str(e)[:80]
        for k, fn in sorted(self.extra.items()):
            if not ck_ok:
                break
            try:
                out[k] = fn(now, path)
            except Exception as e:
                out[k] = None
                out["err_" + k] = str(e)[:80]
        if self.maint is not None:
            try:
                self.maint.tick(path)   # relDb: wirft nie; aendert keine Daten
            except Exception as e:
                out["err_maint"] = str(e)[:80]
        ms = int((time.monotonic() - t0) * 1000)
        self.mono_ref = time.monotonic()
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
            self.mono_ref = time.monotonic()
            return True

    def owns(self, path=None):
        try:
            if not self.alive() or self.path is None:
                return False
            if os.path.realpath(path or DB_PATH) != os.path.realpath(self.path):
                return False
            return time.monotonic() - self.mono_ref <= self.first_s + 3 * self.every_s   # relClock: monoton statt Wanduhr
        except Exception:
            return False

    def status(self):
        return {"alive": self.alive(), "path": self.path, "every_s": self.every_s, "keep_events_after_expiry_s": KEEP_EVENTS_HIST_S,
                "extra": sorted(self.extra), "maint": (self.maint.status() if self.maint is not None else None),
                "clock": {"ok": (self.clock_last[0] if self.clock_last else None), "why": self.clock_why, "pruefer": (self.clock_last[1] if self.clock_last else None)},
                **{k: self.st[k] for k in ("started", "restarts", "n", "t", "last", "err", "first")}}


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
        ck_ok, ck_why, _chk = _clock_state()   # relClock
        if not ck_ok:
            return {"faden": "direkt", "clock_pause": ck_why[:80]}
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
    r.maint = None
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

# ---------------------------------------------------------------- sqlB (Transport prepper-sdr -> Dashboard ueber lagezentrum.db, zusaetzlich zu JSON)
# Tabelle state: je Schluessel genau eine Zeile (Upsert, waechst nicht): sdr_status, broadcast_state (Text = exakt der JSON-Inhalt der Datei),
# sqlb_writer (Zaehler des Schreibfadens in prepper-sdr). state_get liest nur (mode=ro, kurzer Timeout) und meldet Fehler statt zu werfen.
STATE_SQL = "CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, ts INTEGER NOT NULL, src_t REAL, json TEXT, writer TEXT, pid INTEGER, n INTEGER DEFAULT 0)"
_state_ok = set()


def state_put(key, text, src_t=None, path=None, writer="prepper-sdr"):
    """Eine Zeile je Schluessel schreiben (Upsert). -> True/False"""
    path = path or DB_PATH
    try:
        now = time.time()
        con = connect(path)
        try:
            with con:
                if path not in _state_ok:
                    con.execute(STATE_SQL)
                con.execute("INSERT INTO state(key, ts, src_t, json, writer, pid, n) VALUES(?, ?, ?, ?, ?, ?, 1) ON CONFLICT(key) DO UPDATE SET "
                            "ts=excluded.ts, src_t=excluded.src_t, json=excluded.json, writer=excluded.writer, pid=excluded.pid, n=state.n+1",
                            (str(key), int(now), float(src_t if src_t is not None else now), str(text), str(writer)[:20], os.getpid()))
        finally:
            con.close()
        _state_ok.add(path)
        return True
    except Exception as e:
        _log("state %s:" % key, e)
        return False


def state_get(key, path=None, timeout=1.0):
    """Nur lesen (mode=ro, kurzer Timeout). -> {"ok": True, "ts", "src_t", "text", "n"} | {"ok": False, "err"}"""
    path = path or DB_PATH
    try:
        if not os.path.exists(path):
            return {"ok": False, "err": "keine Datenbank"}
        from urllib.parse import quote
        con = sqlite3.connect("file:%s?mode=ro" % quote(os.path.abspath(path)), uri=True, timeout=timeout, factory=_Con)
        try:
            con.execute("PRAGMA busy_timeout=%d" % int(timeout * 1000))
            r = con.execute("SELECT ts, src_t, json, n FROM state WHERE key=?", (str(key),)).fetchone()
        finally:
            con.close()
        if not r:
            return {"ok": False, "err": "keine DB-Zeile"}
        return {"ok": True, "ts": r[0], "src_t": r[1], "text": r[2], "n": r[3]}
    except Exception as e:
        return {"ok": False, "err": str(e)[:100]}


def selftest_state():
    import tempfile
    d = tempfile.mkdtemp(prefix="lzstate-")
    p = os.path.join(d, "s.db")
    assert state_get("x", p)["err"] == "keine Datenbank" and not os.path.exists(p)          # Lesen legt nie eine DB an
    assert migrate(p) and state_get("x", p)["ok"] is False
    assert state_put("sdr_status", '{"t": 1}', 100.5, p) and state_put("sdr_status", '{"t": 2}', 101.5, p)
    r = state_get("sdr_status", p)
    assert r["ok"] and r["text"] == '{"t": 2}' and r["src_t"] == 101.5 and r["n"] == 2, r
    con = connect(p)
    assert con.execute("SELECT COUNT(*) FROM state").fetchone()[0] == 1                       # eine Zeile je Schluessel
    con.execute("BEGIN EXCLUSIVE")                                                            # DB gesperrt -> Lesen meldet Fehler, wirft nicht
    t0 = time.time()
    r2 = state_get("sdr_status", p, timeout=0.3)
    con.rollback()
    con.close()
    assert time.time() - t0 < 3, "Timeout zu lang"
    return "database selftest sqlB ok (state: eine Zeile je Schluessel, Lesen nur ro ohne Anlegen, gesperrt -> %s)" % ("Fehler gemeldet" if not r2["ok"] else "WAL-Lesen trotz Sperre")

if __name__ == "__main__":
    print(selftest())
    print(selftest_t2())
    print(selftest_t3())
    print(selftest_retention())
    print(selftest_state())
    print(selftest_maint())
    print(selftest_clock())
SXM_BDB_EOF
EXPECT_BXML="c4db8c5c070afc3f0bb9504b315c8c7cc5f53fac879de42f217cdaba7dd2456b"
cat > "$W/base_lage_xml.py" << 'SXM_BXML_EOF'
#!/usr/bin/env python3
"""lage_xml.py (secHard, SEC-11): gehaertetes Parsen externer XML-Feeds (Notdienst, Nachrichten-RSS).

Nicht von selbst aktiv: dashboard.py muss es aufrufen (Einbindungstext in INTEGRATION.md). Bis dahin aendert diese Datei nichts.

  safe_fromstring(daten, max_bytes=None)  Ersatz fuer xml.etree.ElementTree.fromstring (gleiches Ergebnis, ein Element)
  limited_content(antwort, max_bytes)     liest eine requests-Antwort (stream=True) mit Obergrenze statt r.content
  status()                                ehrliche Statusmeldung: welcher Parser, welche Grenze

Mit defusedxml (falls im venv vorhanden): Entity-Deklarationen und externe Verweise werden abgelehnt (DTD bleibt erlaubt, RSS
hat oft eine). Ohne defusedxml: Rueckfall auf den bisherigen Parser xml.etree MIT Groessenlimit, und das wird einmal im Journal
gemeldet und in status() ausgewiesen (kein stilles Weitermachen). Es wird nichts installiert.
Fehler: XmlRejected (Unterklasse von xml.etree.ElementTree.ParseError, also von SyntaxError) bei abgelehntem oder zu grossem XML.
"""
import sys
import xml.etree.ElementTree as ET

try:
    from defusedxml import ElementTree as _DET
    from defusedxml import DefusedXmlException as _DXE
    HARD = True
except Exception:   # nicht installiert oder unbrauchbar -> Rueckfall (ehrlich gemeldet)
    _DET = None
    _DXE = None
    HARD = False

MAX_BYTES_DEFAULT = 4 * 1024 * 1024   # 4 MiB; Aufrufer duerfen eine kleinere/groessere Grenze nach den beobachteten Feedgroessen waehlen
_noted = False


class XmlRejected(ET.ParseError):
    """XML abgelehnt (zu gross oder gefaehrliche Konstrukte)."""


def status():
    return {
        "hard": HARD,
        "backend": "defusedxml" if HARD else "xml.etree (Rueckfall: defusedxml fehlt, nur Groessenlimit)",
        "max_bytes": MAX_BYTES_DEFAULT,
        "msg": ("defusedxml aktiv: Entity-Deklarationen und externe Verweise werden abgelehnt" if HARD else
                "defusedxml ist nicht im venv: es gilt der bisherige Parser xml.etree mit Groessenlimit (kein zusaetzlicher Entity-Schutz ueber expat hinaus)"),
    }


def _note_once():
    global _noted
    if not _noted:
        _noted = True
        print("lage_xml: " + status()["msg"], file=sys.stderr, flush=True)


def _size(daten):
    return len(daten.encode("utf-8")) if isinstance(daten, str) else len(daten)


def safe_fromstring(daten, max_bytes=None):
    lim = MAX_BYTES_DEFAULT if max_bytes is None else int(max_bytes)
    n = _size(daten)
    if n > lim:
        raise XmlRejected("XML zu gross: %d Bytes (Grenze %d)" % (n, lim))
    if HARD:
        try:
            return _DET.fromstring(daten, forbid_dtd=False, forbid_entities=True, forbid_external=True)
        except _DXE as e:
            raise XmlRejected("XML abgelehnt (%s)" % type(e).__name__) from None
    _note_once()
    return ET.fromstring(daten)


def limited_content(antwort, max_bytes=None, chunk=65536):
    """Bytes einer requests-Antwort (mit stream=True geholt) lesen; bricht bei Ueberschreitung ab und schliesst die Antwort."""
    lim = MAX_BYTES_DEFAULT if max_bytes is None else int(max_bytes)
    try:
        cl = int(antwort.headers.get("Content-Length") or 0)
    except Exception:
        cl = 0
    if cl > lim:
        antwort.close()
        raise XmlRejected("Antwort zu gross: Content-Length %d (Grenze %d)" % (cl, lim))
    buf = bytearray()
    for part in antwort.iter_content(chunk_size=chunk):
        buf += part
        if len(buf) > lim:
            antwort.close()
            raise XmlRejected("Antwort zu gross: mehr als %d Bytes" % lim)
    return bytes(buf)


def selftest():
    global HARD, _noted
    ok_xml = b'<?xml version="1.0"?><rss><channel><item><title>T\xc3\xa4st</title></item></channel></rss>'
    laughs = (b'<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">'
              b'<!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><l>&c;</l>')
    doctype_only = b'<?xml version="1.0"?><!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" "http://my.netscape.com/publish/formats/rss-0.91.dtd"><rss version="0.91"><channel><title>x</title></channel></rss>'
    saved = HARD
    try:
        for mode in ([True, False] if saved else [False]):
            HARD = mode
            _noted = False
            r = safe_fromstring(ok_xml)
            assert r.tag == "rss" and r.find("channel/item/title").text == "T\u00e4st"
            assert safe_fromstring(ok_xml.decode("utf-8")).tag == "rss"    # Text statt Bytes geht (ohne encoding-Angabe im Kopf)
            try:
                safe_fromstring(b"x" * 1000, max_bytes=999)
                raise AssertionError("zu grosses XML nicht abgelehnt")
            except XmlRejected:
                pass
            assert safe_fromstring(b"<a/>" + b" " * 10, max_bytes=14).tag == "a"      # genau an der Grenze ok
            if mode:
                for bad in (laughs,):
                    try:
                        safe_fromstring(bad)
                        raise AssertionError("Entity-Bombe nicht abgelehnt")
                    except XmlRejected:
                        pass
                assert safe_fromstring(doctype_only).tag == "rss"                       # DTD ohne Entities bleibt erlaubt
                assert status()["hard"] is True
            else:
                assert status()["hard"] is False and "Rueckfall" in status()["backend"]
                assert _noted is True
    finally:
        HARD = saved

    class FakeResp:
        def __init__(self, parts, cl=None):
            self._p = parts
            self.headers = {"Content-Length": str(cl)} if cl is not None else {}
            self.closed = False

        def iter_content(self, chunk_size=0):
            for p in self._p:
                yield p

        def close(self):
            self.closed = True

    assert limited_content(FakeResp([b"ab", b"cd"]), 4) == b"abcd"
    r = FakeResp([b"abc", b"def"])
    try:
        limited_content(r, 5)
        raise AssertionError("Grenze nicht erkannt")
    except XmlRejected:
        assert r.closed
    r = FakeResp([b"a"], cl=10 ** 9)
    try:
        limited_content(r, 100)
        raise AssertionError("Content-Length nicht erkannt")
    except XmlRejected:
        assert r.closed
    return "lage_xml selftest ok (Parser: %s)" % ("defusedxml und Rueckfall" if saved else "nur Rueckfall, defusedxml nicht vorhanden")


if __name__ == "__main__":
    if "--status" in sys.argv[1:]:
        print(status())
    else:
        print(selftest())
SXM_BXML_EOF
EXPECT_BREQ="a6bf962c0a3abdd8df7eeaf76fbf2f1cc822bfd4d863df2e5ac8353f330e14f1"
cat > "$W/base_lage_reqs.py" << 'SXM_BREQ_EOF'
#!/usr/bin/env python3
"""lage_reqs.py (secHard, SEC-10): Abhaengigkeiten des Dashboards pruefen und requirements-Vorlage erzeugen. NUR LESEND - installiert nichts.

  python3 tools/lage_reqs.py check               Fremd-Importe der Projektdateien gegen das venv: installiert (Version) oder FEHLT
  python3 tools/lage_reqs.py vorlage             requirements-Text aus dem venv (Versionen), Hashes als gekennzeichnete Platzhalter
  python3 tools/lage_reqs.py hashes --netz       wie vorlage, Hashes aus PyPI (nur lesender Abruf von pypi.org; Paketname+Version werden uebertragen)
Optionen: --projekt ORDNER (Standard: Ordner ueber tools/), --venv ORDNER (Standard: PROJEKT/venv), --out DATEI (statt Bildschirm; ueberschreibt nie)
Ohne --out wird nur ausgegeben, nichts geschrieben. Die Datei requirements.txt wird nie von selbst angelegt oder ersetzt.
"""
import ast
import json
import os
import subprocess
import sys

SKIP_DIRS = {"venv", "__pycache__", "backups", ".git", "node_modules"}
VENV_SCRIPT = r'''
import importlib.metadata as md, importlib.util, json, sys
mods = json.loads(sys.argv[1])
dists = []
for d in md.distributions():
    n = d.metadata["Name"] or ""
    if not n:
        continue
    direct = d.read_text("direct_url.json")
    dists.append({"name": n, "version": d.version, "direct": bool(direct)})
pd = md.packages_distributions()
res = {}
for m in mods:
    try:
        found = importlib.util.find_spec(m) is not None
    except Exception:
        found = False
    res[m] = {"found": found, "dists": sorted(set(pd.get(m, [])))}
print(json.dumps({"python": sys.version.split()[0], "dists": dists, "mods": res}))
'''


def py_files(root):
    out = []
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIRS and not d.startswith(".")]
        for f in fn:
            if f.endswith(".py"):
                out.append(os.path.join(dp, f))
    return sorted(out)


def local_names(root):
    names = set()
    for e in os.listdir(root):
        p = os.path.join(root, e)
        if e.endswith(".py"):
            names.add(e[:-3])
        elif os.path.isdir(p) and e not in SKIP_DIRS:
            names.add(e)
    return names


def scan_imports(root):
    """-> {top_level_name: {"optional": bool, "files": set}}; optional = nur innerhalb try/except ImportError bzw. in Funktionen mit try."""
    std = set(sys.stdlib_module_names) | {"__future__"}
    loc = local_names(root)
    found = {}
    for f in py_files(root):
        try:
            tree = ast.parse(open(f, encoding="utf-8", errors="replace").read())
        except SyntaxError:
            continue
        guarded = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.Try) and any(
                    (h.type is None) or any(isinstance(x, ast.Name) and x.id in ("ImportError", "ModuleNotFoundError", "Exception") for x in ast.walk(h.type))
                    for h in n.handlers):
                for b in n.body:
                    for x in ast.walk(b):
                        guarded.add(id(x))
        for n in ast.walk(tree):
            names = []
            if isinstance(n, ast.Import):
                names = [a.name.split(".")[0] for a in n.names]
            elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
                names = [n.module.split(".")[0]]
            for m in names:
                if m in std or m in loc:
                    continue
                e = found.setdefault(m, {"optional": True, "files": set()})
                if id(n) not in guarded:
                    e["optional"] = False
                e["files"].add(os.path.relpath(f, root))
    return found


def venv_info(venv, mods):
    py = os.path.join(venv, "bin", "python")
    if not os.access(py, os.X_OK):
        raise SystemExit("venv-Python nicht gefunden: %s (Option --venv ORDNER)" % py)
    p = subprocess.run([py, "-c", VENV_SCRIPT, json.dumps(sorted(mods))], capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise SystemExit("venv-Abfrage fehlgeschlagen: %s" % (p.stderr or p.stdout)[-300:])
    return json.loads(p.stdout)


def norm(n):
    return n.lower().replace("_", "-").replace(".", "-")


def pins(info):
    skip = {"pip", "setuptools", "wheel"}
    out, manual, seen = [], [], set()
    for d in sorted(info["dists"], key=lambda x: norm(x["name"])):
        if norm(d["name"]) in skip or norm(d["name"]) in seen:
            continue
        seen.add(norm(d["name"]))
        (manual if d["direct"] else out).append((d["name"], d["version"]))
    return out, manual


def cmd_check(root, venv):
    imp = scan_imports(root)
    info = venv_info(venv, imp.keys())
    print("Projekt: %s | venv: %s | venv-Python %s" % (root, venv, info["python"]))
    miss = 0
    for m in sorted(imp):
        r = info["mods"][m]
        ds = r["dists"]
        ver = ""
        if ds:
            vs = {norm(d["name"]): d["version"] for d in info["dists"]}
            ver = ", ".join("%s %s" % (d, vs.get(norm(d), "?")) for d in ds)
        art = "optional (try/except ImportError)" if imp[m]["optional"] else "direkt"
        if r["found"]:
            print("  OK     %-14s im venv (%s) | %s | %d Datei(en)" % (m, ver or "Paket unbekannt", art, len(imp[m]["files"])))
        else:
            miss += 1
            print("  FEHLT  %-14s NICHT im venv | %s | %s" % (m, art, ", ".join(sorted(imp[m]["files"]))[:120]))
    print("Ergebnis: %d Fremdpakete im Quelltext, %d fehlen im venv. Es wurde nichts installiert." % (len(imp), miss))
    return 1 if miss else 0


def render(root, venv, hashes=None):
    imp = scan_imports(root)
    info = venv_info(venv, imp.keys())
    out, manual = pins(info)
    lines = ["# requirements aus dem venv %s (Python %s) - erzeugt mit tools/lage_reqs.py" % (venv, info["python"])]
    if hashes is None:
        lines.append("# ACHTUNG VORLAGE: Zeilen mit HIER-HASH-EINTRAGEN sind Platzhalter. So NICHT mit pip install --require-hashes benutzen.")
        lines.append("# Echte Hashes: python3 tools/lage_reqs.py hashes --netz --out requirements.neu")
    else:
        lines.append("# Installation (nur wenn noetig, als Benutzer fmg, nie als root): venv/bin/pip install --require-hashes -r requirements.txt")
    direct = {norm(d) for m in imp for d in info["mods"][m]["dists"]}
    for name, ver in out:
        tag = "  # direkt importiert" if norm(name) in direct else ""
        if hashes is None:
            lines.append("%s==%s \\\n    --hash=sha256:HIER-HASH-EINTRAGEN%s" % (name, ver, tag))
        else:
            hs = hashes.get((norm(name), ver))
            if hs:
                lines.append("%s==%s \\\n%s%s" % (name, ver, " \\\n".join("    --hash=sha256:%s" % h for h in hs), tag))
            else:
                lines.append("# KEIN HASH GEFUNDEN: %s==%s (nicht auf PyPI?) - manuell pruefen" % (name, ver))
    for name, ver in manual:
        lines.append("# manuell pruefen (lokal/URL installiert, nicht aus PyPI): %s==%s" % (name, ver))
    for m in sorted(imp):
        if not info["mods"][m]["found"]:
            lines.append("# FEHLT im venv: %s (importiert in %s)" % (m, ", ".join(sorted(imp[m]["files"]))[:100]))
    return "\n".join(lines) + "\n", out


def pypi_hashes(out, fetch=None):
    import urllib.request
    fetch = fetch or (lambda u: json.load(urllib.request.urlopen(u, timeout=20)))
    res = {}
    for name, ver in out:
        try:
            d = fetch("https://pypi.org/pypi/%s/%s/json" % (name, ver))
            hs = sorted({f["digests"]["sha256"] for f in d.get("urls", []) if f.get("digests", {}).get("sha256")})
            if hs:
                res[(norm(name), ver)] = hs
        except Exception:
            pass
    return res


def main(argv):
    a = list(argv)
    opts = {"--projekt": None, "--venv": None, "--out": None}
    netz = "--netz" in a
    if netz:
        a.remove("--netz")
    for k in list(opts):
        if k in a:
            i = a.index(k)
            opts[k] = a[i + 1] if i + 1 < len(a) else None
            del a[i:i + 2]
    cmd = a[0] if a else ""
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(opts["--projekt"] or os.path.dirname(here))
    venv = os.path.abspath(opts["--venv"] or os.path.join(root, "venv"))
    if cmd == "check":
        return cmd_check(root, venv)
    if cmd in ("vorlage", "hashes"):
        if cmd == "hashes" and not netz:
            print("hashes braucht --netz (ruft pypi.org lesend ab). Ohne Netz: vorlage.")
            return 2
        if cmd == "hashes":
            _, out = render(root, venv)
            text, _ = render(root, venv, pypi_hashes(out))
        else:
            text, _ = render(root, venv)
        if opts["--out"]:
            if os.path.exists(opts["--out"]):
                print("STOP: %s gibt es schon - es wird nie ueberschrieben." % opts["--out"])
                return 2
            with open(opts["--out"], "x", encoding="utf-8") as f:
                f.write(text)
            print("geschrieben: %s (%d Zeilen)" % (opts["--out"], text.count("\n")))
        else:
            sys.stdout.write(text)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
SXM_BREQ_EOF
EXPECT_BVOR="e6bb839311fc250252dc3aff87a718bb11aaecb1e7794e360b5a931e501a3f4c"
cat > "$W/base_requirements.txt.vorlage" << 'SXM_BVOR_EOF'
# requirements.txt.VORLAGE (secHard, SEC-10) - KEINE benutzbare requirements.txt, nichts davon wird automatisch angewendet.
# Stand: Fremd-Importe aus dem Quelltext (Branch kaeswasser-lage-monitor); Versionen und Hashes gibt es nur im venv auf dem Pi.
# So wird daraus die echte Datei (alles nur lesend, nichts wird installiert):
#   1. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py check                     zeigt, was im venv fehlt (z. B. psutil, defusedxml)
#   2. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py vorlage                   Versionen aus dem venv, Hashes als Platzhalter
#   3. python3 /home/fmg/prepper-dashboard/tools/lage_reqs.py hashes --netz --out /home/fmg/requirements.neu     echte Hashes von PyPI (lesender Abruf)
#   4. Ergebnis pruefen und erst dann als requirements.txt einchecken. Pruefung ohne Installation: venv/bin/pip install --dry-run --require-hashes -r DATEI
# Zeilen mit HIER-... sind Platzhalter und duerfen NICHT mit pip install benutzt werden.
#
# Direkte Importe (nach Haeufigkeit/Wichtigkeit):
Flask==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
requests==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
ntplib==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
psutil==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
numpy==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
meshtastic==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
PyPubSub==HIER-VERSION-AUS-DEM-VENV \
    --hash=sha256:HIER-HASH-EINTRAGEN
# Optional (nur wenn im venv vorhanden; Importe sind mit try/except abgesichert):
#   Pillow (PIL), gpiozero, sgp4 (liegt auch als Quelltext in sdr_lib/)
#   defusedxml  - fuer lage_xml.py (SEC-11); fehlt es, gilt der Rueckfall mit Groessenlimit
# Dazu kommen die abhaengigen Pakete (Werkzeug, Jinja2, urllib3, certifi, protobuf, ...): lage_reqs.py vorlage nimmt ALLE Pakete des venv auf.
# Hinweis: Die Bridges (mesh_bridge*.py) koennen eine andere Python-Umgebung nutzen als das Dashboard-venv - dann dafuer eine eigene Liste fuehren.
SXM_BVOR_EOF
# ===================== gemeinsame Funktionen (Apply-Skripte der Serie "system") =====================
ERRLN=""; ERRCMD=""; PHASE=vorher
WD_N=80; WD_S=3; JN=48; JS=5; RD_N=40
if [[ "${SYSTEM_TEST:-}" == 1 ]]; then WD_N=${SY_WD_N:-80}; WD_S=${SY_WD_S:-3}; JN=${SY_JN:-48}; JS=${SY_JS:-5}; RD_N=${SY_RD_N:-40}; fi   # nur Sandbox-Test: kuerzere Wartezeiten
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
trap 'ec=$?; if [[ $ec -ne 0 && -n "$ERRLN" ]]; then echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE$([[ "$PHASE" == vorher ]] && echo " - es wurde nichts geaendert")"; fi' EXIT
stop() { echo "STOP: $1 - nichts geaendert"; exit 1; }
s16() { sha256sum "$1" | cut -c1-16; }
code() { curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 40 "$1" || true; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || { VPY=python3; echo "HINWEIS venv-Python fehlt ($DASH_DIR/venv/bin/python) - Pruefung nur mit System-Python"; }
[[ -x "$SPY" ]] || SPY=python3
declare -A BSTATE
# check_base NAME PFAD "alt16 alt16 ..." NEU16 -> BSTATE[NAME]=alt|neu, sonst STOP mit Diff gegen die eingebettete Basis
check_base() {
  local n="$1" f="$2" olds="$3" new="$4" h o
  [[ -f "$f" ]] || stop "$n fehlt: $f"
  h=$(s16 "$f")
  if [[ "$h" == "$new" ]]; then BSTATE[$n]=neu; echo "OK Basis $n sha16 $h (schon die neue Fassung)"; return 0; fi
  for o in $olds; do
    if [[ "$h" == "$o" ]]; then BSTATE[$n]=alt; echo "OK Basis $n sha16 $h ($(wc -l < "$f") Zeilen, bekannt)"; return 0; fi
  done
  echo "Basis $n sha16 $h ($(wc -l < "$f") Zeilen) ist unbekannt (erwartet: $olds oder neu $new)"
  [[ -f "$W/base/$n" ]] && { echo "--- Unterschied zur erwarteten Basis (erste 60 Zeilen) ---"; diff -u "$W/base/$n" "$f" | head -60 || true; }
  stop "$n hat einen unbekannten Stand"
}
prune_bak() { { ls -1t "$1.bak-$NAME-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done; }
verify_payloads() { # PAYLOADS=("datei:VAR" ...) -> EXPECT_<VAR> enthaelt die erwartete sha256
  local e n v
  for e in "${PAYLOADS[@]}"; do
    n="${e%%:*}"; v="EXPECT_${e##*:}"; [[ -f "$W/$n" ]] || stop "Nutzlast $n fehlt"
    [[ "$(sha256sum "$W/$n" | cut -d' ' -f1)" == "${!v}" ]] || stop "Nutzlast $n: Pruefsumme stimmt nicht (Skript veraendert oder beschaedigt)"
  done
  echo "OK ${#PAYLOADS[@]} eingebettete Dateien: sha256 stimmt"
}
pycomp() { # DATEI... : System-Python und venv-Python, ohne Bytecode ins Ziel zu schreiben
  local f py
  for py in "$SPY" "$VPY"; do
    for f in "$@"; do "$py" - "$f" << 'PYC' || return 1
import sys
src = open(sys.argv[1], encoding="utf-8").read()
import warnings
with warnings.catch_warnings():
    warnings.simplefilter("error")
    compile(src, sys.argv[1], "exec")
PYC
    done
  done
}
sqlite_snapshot() { # QUELLE ZIEL: Backup-Schnittstelle, nur lesend gelesen, integrity_check der Kopie
  "$SPY" - "$1" "$2" << 'PYE'
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=20)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
n = dst.execute("PRAGMA integrity_check").fetchone()[0]
assert n == "ok", n
dst.close(); src.close()
PYE
}
dash_get_codes() { # ARRAYNAME: Codes aller 26 Seiten/APIs
  local -n _arr="$1"; local p
  for p in "${PAGES[@]}" "${APIS[@]}"; do _arr[$p]=$(code "$B$p"); done
}
wait_dash() { # wartet auf aktiv + HTTP 200 (max 240 s)
  local i
  for i in $(seq 1 "$WD_N"); do sleep "$WD_S"; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && return 0; done
  return 1
}
wait_ready() { # wartet, bis die Startseite "Dashboard startet" weg ist (max 200 s) - nur Hinweis
  local i p ok2
  for i in $(seq 1 "$RD_N"); do
    ok2=1; for p in /umwelt /energie /; do "${CURL[@]}" "$B$p" -o "$W/pg.html" || true; grep -q "<title>Dashboard startet" "$W/pg.html" 2>/dev/null && ok2=0; done
    [[ "$ok2" == 1 ]] && return 0
    sleep 5
  done
  return 1
}
smoke_all() { # vergleicht mit CODE0; Rueckgabe 1 bei Abweichung
  declare -A c1; local p bad=0 n=0
  dash_get_codes c1
  for p in "${PAGES[@]}" "${APIS[@]}"; do
    n=$((n + 1))
    if [[ "${CODE0[$p]}" == 200 && "${c1[$p]}" != 200 ]]; then echo "  FEHLER $p = ${c1[$p]} (vorher 200)"; bad=1; fi
    [[ "${CODE0[$p]}" != 200 ]] && echo "  HINWEIS $p war vorher schon ${CODE0[$p]} (jetzt ${c1[$p]})"
  done
  [[ "$bad" == 0 ]] && echo "OK Rauchtest: $n Seiten/APIs wie vorher ($(for p in "${PAGES[@]}" "${APIS[@]}"; do echo -n "$p=${c1[$p]} "; done | cut -c1-900))"
  return $bad
}
write_atomic() { # QUELLE ZIEL MODUS
  cp "$1" "$2.new.$$" && chmod "$3" "$2.new.$$" && mv -f "$2.new.$$" "$2"
}
PAYLOADS=(database.py:DB lage_xml.py:XML lage_reqs.py:REQS requirements.txt.vorlage:VORL requirements-defusedxml.txt:RDX defusedxml.whl.b64:WHL guard_secxml.py:GUARD edits_secxml.py:EDITS block_secxml.py:BLOCK edits_reqs.py:EDQ base_database.py:BDB base_lage_xml.py:BXML base_lage_reqs.py:BREQ base_requirements.txt.vorlage:BVOR)
verify_payloads
cp "$W/base_database.py" "$W/base/database.py"; cp "$W/base_lage_xml.py" "$W/base/lage_xml.py"; cp "$W/base_lage_reqs.py" "$W/base/lage_reqs.py"; cp "$W/base_requirements.txt.vorlage" "$W/base/requirements.txt.vorlage"
sbx_new() { rm -rf "$W/sbx" || stop "Pruefordner $W/sbx liess sich nicht loeschen"; mkdir -p "$W/sbx" || stop "Pruefordner $W/sbx liess sich nicht anlegen"; }
show_out() { local f; for f in "$@"; do echo "--- Ausgabe $(basename "$f") (komplett) ---"; cat "$f" 2>&1 || true; echo; done; return 0; }
st_run() { # LABEL PYTHON ARGS... : fuehrt im Pruefordner aus, liefert ST_RC/ST_OUT, scheitert nie (der Aufrufer entscheidet)
  local lbl="$1" py="$2"; shift 2
  ST_OUT="$W/st-$lbl.out"; ST_RC=0
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$py" "$@") > "$ST_OUT" 2>&1 || ST_RC=$?
  return 0
}
st_must() { # LABEL PYTHON ARGS... : wie st_run, bei Fehler STOP mit der vollstaendigen Ausgabe
  st_run "$@"
  [[ "$ST_RC" == 0 ]] || { echo "Selbsttest $1 ($2 $3 ${4:-}) endete mit Exit $ST_RC:"; show_out "$ST_OUT"; echo "Umgebung: Benutzer $(id -un), umask $(umask), /tmp: $(df -P /tmp 2>/dev/null | tail -1 | cut -c1-100 || true)"; stop "Selbsttest $1 mit $2 fehlgeschlagen"; }
}
# ---------- 1) Zustand vorher (nur lesend) ----------
[[ -d "$DASH_DIR" ]] || stop "Projektordner fehlt: $DASH_DIR"
[[ "$(stat -c %U "$DASH_DIR")" == "$(id -un)" ]] || stop "$DASH_DIR gehoert $(stat -c %U "$DASH_DIR"), du bist $(id -un): bitte als Benutzer $(stat -c %U "$DASH_DIR") ausfuehren (nicht mit sudo/root)"
a=$(systemctl is-active prepper-dashboard 2>/dev/null || true); [[ "$a" == active ]] || stop "Dienst prepper-dashboard ist nicht aktiv ($a)"
if [[ -f "$DBF" ]]; then
  h_=$(s16 "$DBF")
  [[ "$h_" == "$PRE_RELDB16" ]] && stop "database.py ist noch die Fassung vor relDb (sha16 $PRE_RELDB16): bitte zuerst commit23 (apply-reldb.sh) und commit25b (apply-relclock2.sh) anwenden"
  [[ "$h_" == "$OLD_RELDB16" ]] && stop "database.py ist noch die Fassung vor relClock (sha16 $OLD_RELDB16): bitte zuerst commit25b (apply-relclock2.sh) anwenden, dann dieses Skript"
fi
for x in "$XMLF" "$REQF" "$VORF"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt: bitte zuerst commit24 (apply-sechard.sh) anwenden"; done
check_base database.py "$DBF" "$KNOWN_DB16" "$NEW_DB16"
check_base lage_xml.py "$XMLF" "$KNOWN_XML16" "$NEW_XML16"
check_base lage_reqs.py "$REQF" "$KNOWN_REQ16" "$NEW_REQ16"
check_base requirements.txt.vorlage "$VORF" "$KNOWN_VOR16" "$NEW_VOR16"
if [[ -f "$RDXF" ]]; then
  [[ "$(s16 "$RDXF")" == "$NEW_RDX16" ]] && echo "OK requirements-defusedxml.txt ist schon die neue Fassung" || stop "requirements-defusedxml.txt gibt es schon, aber mit anderem Inhalt (sha16 $(s16 "$RDXF")) - bitte nicht ueberschreiben, melden"
else
  echo "OK requirements-defusedxml.txt gibt es noch nicht (wird neu angelegt)"
fi
declare -A SHA0
for x in dashboard.py prepper_sdr.py sdr_manager.py prepper_docs.py mesh_router.py lagegeo.py health_check.py lage_clock.py lage_disk.py config.py mesh_bridge.py mesh_bridge_bayern.py; do [[ -f "$DASH_DIR/$x" ]] && SHA0[$x]=$(s16 "$DASH_DIR/$x"); done
declare -A SVC0
for s in prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern; do SVC0[$s]=$(systemctl is-active "$s" 2>/dev/null || true); done
echo "Dienste vorher: $(for s in prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern; do echo -n "$s=${SVC0[$s]} "; done)"
declare -A CODE0; dash_get_codes CODE0
n200=0; for p in "${PAGES[@]}" "${APIS[@]}"; do [[ "${CODE0[$p]}" == 200 ]] && n200=$((n200 + 1)); done
echo "vorher HTTP: $n200 von $(( ${#PAGES[@]} + ${#APIS[@]} )) Seiten/APIs = 200 ($(for p in "${PAGES[@]}" "${APIS[@]}"; do echo -n "$p=${CODE0[$p]} "; done | cut -c1-700))"
[[ "$n200" -ge 1 ]] || stop "das Dashboard antwortet nicht (Port $PORT)"
# venv: Python, pip, Schreibrecht, defusedxml-Bestand (nur lesend)
[[ -x "$VPY" ]] || stop "venv-Python fehlt: $VPY (defusedxml gehoert ins venv des Projekts)"
PIPV=$(PYTHONDONTWRITEBYTECODE=1 "$VPY" -m pip --version 2>/dev/null | cut -c1-90 || true)
PURE=$(PYTHONDONTWRITEBYTECODE=1 "$VPY" -c "import sysconfig; print(sysconfig.get_paths()['purelib'])" 2>/dev/null || true)
[[ -n "$PURE" && -d "$PURE" ]] || stop "site-packages des venv nicht ermittelbar ($VPY)"
DXV=$(PYTHONDONTWRITEBYTECODE=1 "$VPY" -c "import importlib.metadata as m; print(m.version('defusedxml'))" 2>/dev/null || true)
DXOK=0; PYTHONDONTWRITEBYTECODE=1 "$VPY" -c "import defusedxml.ElementTree" >/dev/null 2>&1 && DXOK=1
echo "venv: $("$VPY" -V 2>&1), pip: ${PIPV:-FEHLT}, site-packages: $PURE (Besitzer $(stat -c %U "$PURE"), $([[ -w "$PURE" ]] && echo schreibbar || echo NICHT schreibbar)), defusedxml: ${DXV:-nicht installiert}"
DXSTATE=none
if [[ -n "$DXV" ]]; then
  if [[ "$DXV" == "$PIN_VER" && "$DXOK" == 1 ]]; then DXSTATE=pinned; else DXSTATE=other; fi
fi
case "$DXSTATE" in
  none)
    [[ -n "$PIPV" ]] || stop "pip fehlt im venv ($VPY -m pip): defusedxml kann nicht installiert werden - bitte melden"
    [[ -w "$PURE" ]] || stop "kein Schreibrecht in $PURE (Besitzer $(stat -c %U "$PURE")): defusedxml kann als $(id -un) nicht installiert werden - bitte melden"
    FREEKB=$(df -Pk "$PURE" | tail -1 | tr -s ' ' | cut -d' ' -f4)
    [[ "${FREEKB:-0}" -gt 20000 ]] || stop "zu wenig freier Platz im venv-Dateisystem (${FREEKB:-?} KiB)"
    echo "OK defusedxml fehlt im venv und wird aus dem eingebetteten Rad installiert (Pin $PIN_VER, Hash geprueft)";;
  pinned) echo "OK defusedxml $DXV ist schon im venv (= Pin) - es wird nichts installiert";;
  other) echo "HINWEIS defusedxml $DXV ist schon im venv (Pin waere $PIN_VER, importierbar: $DXOK) - es wird NICHT angefasst; lage_xml.py nutzt die vorhandene Fassung";;
esac
if [[ -f "$LZ" ]]; then
  "$SPY" - "$LZ" << 'PYQ' > "$W/lz0.txt" 2>&1 || stop "lagezentrum.db nicht lesbar: $(cat "$W/lz0.txt")"
import os, sqlite3, sys
p = sys.argv[1]
c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
q = c.execute("PRAGMA quick_check").fetchall()
assert [r[0] for r in q] == ["ok"], q
jm = c.execute("PRAGMA journal_mode").fetchone()[0]
sy = c.execute("PRAGMA synchronous").fetchone()[0]
n = {t: c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0] for t in ("events", "mesh_log", "mesh_auto", "mesh_queue", "telemetry") if c.execute("SELECT 1 FROM sqlite_master WHERE name=?", (t,)).fetchone()}
print("quick_check ok, journal_mode=%s, %.1f MB, Zeilen %s" % (jm, os.path.getsize(p) / 1048576.0, n))
PYQ
  echo "OK lagezentrum.db vorher: $(cat "$W/lz0.txt")"
else
  echo "HINWEIS $LZ gibt es nicht (wird vom Dashboard angelegt) - keine SQLite-Sicherung noetig"
fi
# ---------- 2) Pruefungen der Nutzlast (Sandbox, nichts Echtes angefasst) ----------
base64 -d "$W/defusedxml.whl.b64" > "$W/whl/$PIN_WHL" 2> "$W/b64.err" || { cat "$W/b64.err"; stop "eingebettetes Rad nicht dekodierbar"; }
[[ "$(wc -c < "$W/whl/$PIN_WHL")" == "$PIN_SIZE" ]] || stop "eingebettetes Rad hat nicht $PIN_SIZE Bytes"
[[ "$(sha256sum "$W/whl/$PIN_WHL" | cut -d' ' -f1)" == "$PIN_SHA" ]] || stop "eingebettetes Rad: sha256 stimmt nicht mit dem Pin (PyPI) ueberein"
"$SPY" - "$W/whl/$PIN_WHL" << 'PYZ' || stop "eingebettetes Rad ist kein gueltiges defusedxml-Rad"
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert z.testzip() is None
n = set(z.namelist())
assert "defusedxml/ElementTree.py" in n and "defusedxml/__init__.py" in n and any(x.endswith(".dist-info/RECORD") for x in n), sorted(n)[:12]
assert not any(x.startswith("/") or ".." in x.split("/") for x in n)
PYZ
cp "$W/requirements-defusedxml.txt" "$W/rq/"
grep -q "^defusedxml==$PIN_VER \\\\$" "$W/rq/requirements-defusedxml.txt" && grep -q "^    --hash=sha256:$PIN_SHA\$" "$W/rq/requirements-defusedxml.txt" || stop "requirements-defusedxml.txt passt nicht zum Pin"
echo "OK eingebettetes Rad: $PIN_SIZE Bytes, sha256 = PyPI-Hash $PIN_SHA, gueltiges Zip mit defusedxml/ElementTree.py"
"$SPY" "$W/edits_secxml.py" "$W/base/database.py" "$W/rebuilt_db.py" || stop "Aufbau database.py aus der Basis misslungen"
cmp -s "$W/rebuilt_db.py" "$W/database.py" && echo "OK die eingebettete database.py ist byte-genau das Ergebnis der geprueften Edits auf der Basis" || stop "eingebettete database.py ungleich Edits(Basis)"
"$SPY" "$W/edits_reqs.py" reqs "$W/base/lage_reqs.py" "$W/rebuilt_rq.py" && "$SPY" "$W/edits_reqs.py" vorlage "$W/base/requirements.txt.vorlage" "$W/rebuilt_vo.py" || stop "Aufbau lage_reqs.py/Vorlage aus der Basis misslungen"
cmp -s "$W/rebuilt_rq.py" "$W/lage_reqs.py" && cmp -s "$W/rebuilt_vo.py" "$W/requirements.txt.vorlage" && echo "OK lage_reqs.py und requirements.txt.vorlage sind byte-genau das Ergebnis der Edits auf der Basis" || stop "eingebettete lage_reqs.py/Vorlage ungleich Edits(Basis)"
pycomp "$W/database.py" "$W/lage_xml.py" "$W/lage_reqs.py" "$W/guard_secxml.py" "$W/edits_secxml.py" "$W/edits_reqs.py" "$W/block_secxml.py" || stop "py_compile mit Warnung/Fehler"
echo "OK py_compile ohne Warnung (System-Python $("$SPY" -V 2>&1), venv-Python $("$VPY" -V 2>&1))"
# Installation im Pruefordner: derselbe pip-Aufruf wie spaeter im venv, aber --target (nichts Echtes angefasst)
mkdir -p "$W/site"
if [[ -n "$PIPV" ]]; then
  PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$VPY" -m pip install --no-index --no-deps --require-hashes --no-cache-dir --find-links "$W/whl" --target "$W/site" -r "$W/rq/requirements-defusedxml.txt" > "$W/pipt.out" 2>&1 || { show_out "$W/pipt.out"; stop "Probe-Installation (pip, --target im Pruefordner) fehlgeschlagen"; }
  echo "OK Probe-Installation im Pruefordner: $(tail -1 "$W/pipt.out" | cut -c1-120)"
else
  "$SPY" - "$W/whl/$PIN_WHL" "$W/site" << 'PYX' || stop "Rad liess sich im Pruefordner nicht entpacken"
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PYX
  echo "HINWEIS kein pip im venv: Pruefordner aus dem Rad entpackt (die echte Installation wuerde STOP melden)"
fi
# Hash-Pin wirkt wirklich: ein falscher Hash muss pip ablehnen
if [[ -n "$PIPV" ]]; then
  sed "s/$PIN_SHA/0000000000000000000000000000000000000000000000000000000000000000/" "$W/rq/requirements-defusedxml.txt" > "$W/rq/falsch.txt"
  if PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$VPY" -m pip install --no-index --no-deps --require-hashes --no-cache-dir --find-links "$W/whl" --target "$W/site_falsch" -r "$W/rq/falsch.txt" > "$W/pipf.out" 2>&1; then
    show_out "$W/pipf.out"; stop "pip hat einen FALSCHEN Hash akzeptiert - der Pin schuetzt nicht"
  fi
  grep -qi "hash" "$W/pipf.out" && echo "OK Hash-Pin: ein absichtlich falscher Hash wird von pip abgelehnt" || { show_out "$W/pipf.out"; stop "pip lehnte den falschen Hash ab, aber nicht wegen des Hashes"; }
  [[ ! -e "$W/site_falsch" ]] || stop "Probe mit falschem Hash hat trotzdem Dateien angelegt"
fi
# Guard (AST + Verhalten + Vergleich alt/neu + lokaler HTTP-Test) und Mutationstest, mit System- und venv-Python; defusedxml aus dem Pruefordner
for py in "$SPY" "$VPY"; do
  nice -n 19 "$py" "$W/guard_secxml.py" check "$W/database.py" "$W/base/database.py" "$W/lage_xml.py" "$W/lage_reqs.py" "$W/requirements.txt.vorlage" "$W/requirements-defusedxml.txt" --site "$W/site" > "$W/guard.out" 2>&1 || { show_out "$W/guard.out"; stop "Guard hat die Nutzlast beanstandet ($py)"; }
  echo "OK guard ($("$py" -V 2>&1)): $(tail -1 "$W/guard.out")"
done
if [[ "${SYSTEM_TEST:-}" == 1 && "${SY_NOMUT:-}" == 1 ]]; then echo "OK (Sandbox-Test: Mutationstest uebersprungen)"; else
echo "Mutationstest laeuft (nice 19, dauert je nach Pi einige Minuten) ..."
nice -n 19 "$VPY" "$W/guard_secxml.py" mutate "$W/base/database.py" "$W/edits_secxml.py" "$W/lage_xml.py" "$W/lage_reqs.py" "$W/requirements.txt.vorlage" "$W/requirements-defusedxml.txt" --site "$W/site" --basereqs "$W/base/lage_reqs.py" --basevorlage "$W/base/requirements.txt.vorlage" > "$W/mut.out" 2>&1 || { show_out "$W/mut.out"; stop "Mutationstest: eine Mutation wurde uebersehen"; }
echo "OK $(tail -1 "$W/mut.out")"
fi
# Selbsttests mit beiden Pythons (database.py mit und ohne lage_clock.py; lage_xml mit defusedxml aus dem Pruefordner und ohne)
for py in "$SPY" "$VPY"; do
  for mit in mit ohne; do
    sbx_new; cp "$W/database.py" "$W/sbx/"
    [[ "$mit" == mit && -f "$DASH_DIR/lage_clock.py" ]] && cp "$DASH_DIR/lage_clock.py" "$W/sbx/"
    st_must dbs "$py" database.py
    cp "$ST_OUT" "$W/selftest.out"
    grep -q "database selftest secXml ok" "$W/selftest.out" && grep -q "database selftest relClock ok" "$W/selftest.out" && grep -q "database selftest relDb ok" "$W/selftest.out" || { show_out "$W/selftest.out"; stop "Selbsttest secXml/relClock/relDb meldet nicht ok ($mit lage_clock.py)"; }
  done
  sbx_new; cp "$W/lage_xml.py" "$W/sbx/"
  PYTHONPATH="$W/site" st_must xmlh "$py" lage_xml.py
  grep -q "defusedxml und Rueckfall" "$W/st-xmlh.out" || { show_out "$W/st-xmlh.out"; stop "lage_xml Selbsttest lief nicht im harten Modus ($py)"; }
  st_must xmlr "$py" -c "import sys; sys.modules['defusedxml'] = None; import lage_xml; assert lage_xml.HARD is False; print(lage_xml.selftest())"
  grep -q "nur Rueckfall" "$W/st-xmlr.out" || stop "lage_xml ohne defusedxml: Rueckfall nicht bestaetigt ($py)"
  echo "OK Selbsttests mit $("$py" -V 2>&1): database.py (mit und ohne lage_clock.py), lage_xml (defusedxml $(PYTHONPATH="$W/site" "$py" -c "import defusedxml; print(defusedxml.__version__)" 2>/dev/null || echo "?") und Rueckfall)"
done
# lage_reqs-Werkzeug in einem Sandbox-Projekt (nur lesend)
rm -rf "$W/sbx" && mkdir -p "$W/sbx/tools" "$W/sbx/venv/bin" && cp "$W/lage_reqs.py" "$W/sbx/tools/"
ln -s "$(command -v "$SPY")" "$W/sbx/venv/bin/python"
printf 'import os\ntry:\n    import defusedxml\nexcept ImportError:\n    pass\nimport nichtvorhandenespaket\n' > "$W/sbx/dashboard.py"
(cd "$W/sbx" && PYTHONPATH="$W/site" PYTHONDONTWRITEBYTECODE=1 "$SPY" tools/lage_reqs.py check > "$W/rq1.out" 2>&1) || true
grep -q "FEHLT  nichtvorhandenespaket" "$W/rq1.out" && grep -q "Pin    defusedxml .*installiert, Version stimmt" "$W/rq1.out" && grep -q "Es wurde nichts installiert" "$W/rq1.out" || { cat "$W/rq1.out"; stop "lage_reqs check (Sandbox) liefert nicht das Erwartete"; }
(cd "$W/sbx" && PYTHONPATH="$W/site" PYTHONDONTWRITEBYTECODE=1 "$SPY" tools/lage_reqs.py vorlage > "$W/rq2.out" 2>&1) || { cat "$W/rq2.out"; stop "lage_reqs vorlage (Sandbox) fehlgeschlagen"; }
grep -q "^defusedxml==$PIN_VER" "$W/rq2.out" && grep -q "sha256:$PIN_SHA" "$W/rq2.out" || { cat "$W/rq2.out"; stop "lage_reqs vorlage ohne den echten defusedxml-Hash"; }
rc=0; (cd "$W/sbx" && "$SPY" tools/lage_reqs.py hashes > "$W/rq3.out" 2>&1) || rc=$?
[[ "$rc" == 2 ]] || stop "lage_reqs hashes ohne --netz muss mit Exit 2 abbrechen (Exit $rc)"
echo "OK tools/lage_reqs.py in der Sandbox: check meldet den Pin, vorlage nennt den echten Hash, hashes ohne --netz bricht ab"
rm -rf "$W/sbx"
# Vergleich alt/neu der Datenbankfunktionen auf KOPIEN der echten Datenbank (nur Kopien in /tmp, gleiche Aufrufe, gleiche Zeilen; nur Alarm-Zeilen zaehlen als Vergleich)
cat > "$W/copyops.py" << 'PYL'
import hashlib, json, sqlite3, sys, time
sys.path.insert(0, sys.argv[2])
import database as d
p = sys.argv[1]
assert d.migrate(p) and d.migrate_t2(p) and d.migrate_t3(p)
now = 1900000000
r = {}
for i, sev in enumerate(("warn", "alarm", "info", None, "probe")):
    r["ev%d" % i] = d.upsert_event({"source": "SXT", "ext_id": "sxt-%d" % i, "severity": sev, "headline": "h%d" % i, "created": now, "updated": now, "expires": now + 3600}, p)
r["seen"] = [d.mesh_seen("sxt-a", "SXT", p, now), d.mesh_seen("sxt-a", "SXT", p, now)]
r["put"] = d.mesh_log_put("sxt-b", "SXT", now, "SXT", "t", True, "nina", p)
r["res"] = [d.mesh_auto_reserve("SXT:1", "sxt-b", "SXT", "t", now, p), d.mesh_auto_done("SXT:1", False, p), d.mesh_auto_reserve("SXT:1", "sxt-b", "SXT", "t", now + 99999, p), d.mesh_auto_done("SXT:1", True, p)]
q1 = d.q_add("sxt", "nina", "t", "sxt-q", now, now, None, None, p)
q2 = d.q_add("sxt", "nina_detail", None, None, now, now + 30, q1, "{}", p)
r["q"] = [q1 > 0, q2 > q1, d.q_add("sxt", "nina", "t", "sxt-q", now + 5, now, None, None, p) == q1, d.q_set(q1, p, state="ok", why="x", done=now + 9, tries=1, last_try=now + 9), d.q_set(q2, p, why="w")]
r["tel"] = d.insert_telemetry({"ts": now, "serial": "SXT", "channel": "SXT", "snr": 1.0, "src_t": now}, p)
c = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
h = hashlib.sha256()
for sql in ("SELECT source,type,severity,headline,created,updated,expires,ext_id FROM events WHERE ext_id LIKE 'sxt-%' ORDER BY ext_id", "SELECT hash,channel,created,src,ok,kind FROM mesh_log WHERE hash LIKE 'sxt-%' ORDER BY hash",
            "SELECT akey,hash,src,created,last_try,tries,ok FROM mesh_auto WHERE akey LIKE 'SXT:%' ORDER BY akey", "SELECT node,kind,ref,text,hash,created,not_before,after_id,tries,state,why,done FROM mesh_queue WHERE node='sxt' ORDER BY id"):
    for row in c.execute(sql).fetchall():
        h.update(repr(tuple(row)).encode())
cnt = {t: c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0] for t in ("events", "mesh_log", "mesh_auto", "mesh_queue", "telemetry")}
print(json.dumps({"res": r, "rows": h.hexdigest()[:16], "cnt": cnt}, sort_keys=True))
PYL
USE_COPY=0
if [[ -f "$LZ" ]]; then
  LZKB=$(( $(stat -c %s "$LZ") / 1024 + 1 )); TMPFREE=$(df -Pk /tmp | tail -1 | tr -s ' ' | cut -d' ' -f4)
  if [[ "$(( LZKB * 3 + 20000 ))" -lt "${TMPFREE:-0}" ]]; then USE_COPY=1; else echo "HINWEIS Datenbank ($((LZKB / 1024)) MB) zu gross fuer drei Kopien in /tmp (frei $((${TMPFREE:-0} / 1024)) MB): Vergleich alt/neu laeuft auf einer leeren Test-Datenbank"; fi
fi
sbx_new; mkdir -p "$W/sbx/neu" "$W/sbx/alt"
cp "$W/database.py" "$W/sbx/neu/"; cp "$W/base/database.py" "$W/sbx/alt/"
if [[ "$USE_COPY" == 1 ]]; then
  sqlite_snapshot "$LZ" "$W/sbx/neu/lz.db" || stop "SQLite-Kopie fuer den Test fehlgeschlagen"
  cp "$W/sbx/neu/lz.db" "$W/sbx/alt/lz.db"
fi
for m in neu alt; do
  (cd "$W/sbx/$m" && PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/copyops.py" "$W/sbx/$m/lz.db" "$W/sbx/$m" > "$W/co-$m.out" 2>&1) || { show_out "$W/co-$m.out"; stop "Vergleichslauf der Datenbankfunktionen ($m) fehlgeschlagen"; }
done
"$SPY" - "$W/co-neu.out" "$W/co-alt.out" << 'PYC' || stop "Vergleich alt/neu der Datenbankfunktionen: Ergebnisse oder Zeilen weichen ab"
import json, sys
n, a = [json.loads([x for x in open(f).read().splitlines() if x.startswith("{")][-1]) for f in sys.argv[1:3]]
assert n == a, ("neu", n, "alt", a)
print("Vergleich alt/neu: %d Aufrufe, gleiche Ergebnisse, gleiche Alarm-Zeilen (sha16 %s), gleiche Zeilenzahlen %s" % (sum(len(v) if isinstance(v, list) else 1 for v in n["res"].values()), n["rows"], n["cnt"]))
PYC
echo "OK $([[ "$USE_COPY" == 1 ]] && echo "Kopie der echten Datenbank" || echo "leere Test-Datenbank"): neue und alte database.py liefern dieselben Ergebnisse und Zeilen"
rm -rf "$W/sbx"
# Messung auf dem echten Datentraeger: was kostet FULL je Schreibvorgang? (kleine Wegwerf-Datenbank neben dem Projekt, danach geloescht; 40 Alarm-Schreibvorgaenge je Fassung)
cat > "$W/fsynctime.py" << 'PYT'
import sys, time
sys.path.insert(0, sys.argv[2])
import database as d
p = sys.argv[1]
assert d.migrate(p) and d.migrate_t2(p) and d.migrate_t3(p)
now = 1900000000
t0 = time.monotonic()
for i in range(40):
    q = d.q_add("t", "nina", "x", "z%d" % i, now, now, None, None, p)
    d.q_set(q, p, state="ok", done=now)
print("%.1f" % ((time.monotonic() - t0) * 1000.0 / 80))
PYT
MEAS=""
FST=$(mktemp -d "$DASH_DIR/.secxml-fsync.XXXXXX" 2>/dev/null || true)
if [[ -n "$FST" && -d "$FST" ]]; then
  mkdir -p "$FST/neu" "$FST/alt"; cp "$W/database.py" "$FST/neu/"; cp "$W/base/database.py" "$FST/alt/"
  M_N=$(cd "$FST/neu" && PYTHONDONTWRITEBYTECODE=1 nice -n 19 "$SPY" "$W/fsynctime.py" "$FST/neu/m.db" "$FST/neu" 2>/dev/null | tail -1 || true)
  M_A=$(cd "$FST/alt" && PYTHONDONTWRITEBYTECODE=1 nice -n 19 "$SPY" "$W/fsynctime.py" "$FST/alt/m.db" "$FST/alt" 2>/dev/null | tail -1 || true)
  rm -rf "$FST"
  [[ ! -e "$FST" ]] || echo "HINWEIS Wegwerf-Ordner $FST liess sich nicht loeschen - bitte von Hand: rm -rf $FST"
  [[ -n "$M_N" && -n "$M_A" ]] && { MEAS="$M_N ms je Alarm-Schreibvorgang mit FULL gegen $M_A ms mit NORMAL (alte Fassung)"; echo "OK Messung auf dem Datentraeger des Projekts (40 Eintraege + 40 Statuswechsel je Fassung): $MEAS"; } || echo "HINWEIS Messung nicht moeglich"
else
  echo "HINWEIS Wegwerf-Ordner im Projekt nicht anlegbar - FULL-Kosten nicht gemessen"
fi
if [[ "$OPT" == "trocken" ]]; then
  echo "TROCKENLAUF FERTIG: alle Pruefungen ok, es wurde nichts geaendert (kein sudo, kein Neustart, nichts installiert, keine Sicherung). Zum Installieren ohne 'trocken' aufrufen."
  exit 0
fi
# ---------- 3) Installieren ----------
declare -A NEED=()
same() { [[ -f "$2" ]] && cmp -s "$1" "$2"; }
same "$W/database.py" "$DBF" || NEED[db]=1
same "$W/lage_xml.py" "$XMLF" || NEED[xml]=1
same "$W/lage_reqs.py" "$REQF" || NEED[reqs]=1
same "$W/requirements.txt.vorlage" "$VORF" || NEED[vorl]=1
same "$W/requirements-defusedxml.txt" "$RDXF" || NEED[rdx]=1
[[ "$DXSTATE" == none ]] && NEED[dx]=1
RESTARTED_D=0; LZB=""; T0D=$(date +%s); DX_INSTALLED=0
if [[ "${#NEED[@]}" == 0 ]]; then
  echo "OK secXml schon installiert (database.py, lage_xml.py, tools/lage_reqs.py, requirements.txt.vorlage, requirements-defusedxml.txt, defusedxml $DXV) - keine Aenderung, kein Neustart"
else
  [[ -n "${NEED[db]:-}" ]] && { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart von prepper-dashboard erforderlich"; }
  if [[ -f "$LZ" && -n "${NEED[db]:-}" ]]; then
    LZB="$LZ.bak-$NAME-$TS"
    sqlite_snapshot "$LZ" "$LZB" || { rm -f "$LZB"; stop "SQLite-Sicherung lagezentrum.db fehlgeschlagen"; }
    prune_bak "$LZ"
    echo "OK SQLite-Sicherung $(basename "$LZB") ($(wc -c < "$LZB") Bytes, integrity_check ok), behalten: letzte $KEEP_LAST"
  fi
  trap '' INT
  PHASE=Installation
  declare -A WAS
  FILES=("db:$DBF" "xml:$XMLF" "reqs:$REQF" "vorl:$VORF" "rdx:$RDXF")
  rb() {
    set +e +o pipefail
    trap - ERR
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat 2>/dev/null | grep -E "secXml|Traceback" | tail -4 | cut -c1-200
    local e k f
    for e in "${FILES[@]}"; do
      k="${e%%:*}"; f="${e#*:}"
      [[ -n "${NEED[$k]:-}" ]] || continue
      if [[ "${WAS[$k]:-0}" == 1 ]]; then [[ -f "$f.bak-$NAME-$TS" ]] && cp -a "$f.bak-$NAME-$TS" "$f.rb" && mv -f "$f.rb" "$f"; else rm -f "$f" "$f.new."*; fi
    done
    if [[ "${DX_INSTALLED:-0}" == 1 ]]; then
      PYTHONDONTWRITEBYTECODE=1 "$VPY" -m pip uninstall -y defusedxml > "$W/pipu.out" 2>&1 && echo "  defusedxml wieder aus dem venv entfernt" || { echo "  WARNUNG defusedxml liess sich nicht entfernen (von Hand: $VPY -m pip uninstall -y defusedxml):"; cat "$W/pipu.out"; }
    fi
    if [[ "${RESTARTED_D:-0}" == 1 ]]; then
      sudo systemctl restart prepper-dashboard.service
      for i in $(seq 1 "$WD_N"); do sleep "$WD_S"; [[ "$(code "$B/")" == 200 ]] && break; done
    fi
    [[ -f "$DBF.bak-$NAME-$TS" ]] && { cmp -s "$DBF" "$DBF.bak-$NAME-$TS" && echo "  database.py = Sicherung ($(s16 "$DBF"))" || echo "  WARNUNG database.py ungleich Sicherung"; }
    echo "  SQLite-Sicherung (nicht zurueckgespielt, die Datenbank wurde durch dieses Skript nicht veraendert): ${LZB:-keine}"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
  }
  rbx() { rb "$1"; exit 1; }
  mkdir -p "$TOOLD" || { echo "FEHLER: $TOOLD nicht anlegbar"; exit 1; }
  for e in "${FILES[@]}"; do
    k="${e%%:*}"; f="${e#*:}"
    WAS[$k]=0; [[ -f "$f" ]] && WAS[$k]=1
    if [[ -n "${NEED[$k]:-}" && "${WAS[$k]}" == 1 ]]; then cp -a "$f" "$f.bak-$NAME-$TS"; prune_bak "$f"; fi
  done
  # a) defusedxml ins venv (offline, nur mit dem Hash-Pin); danach pruefen
  if [[ -n "${NEED[dx]:-}" ]]; then
    DX_INSTALLED=1
    PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 "$VPY" -m pip install --no-index --no-deps --require-hashes --no-cache-dir --find-links "$W/whl" -r "$W/rq/requirements-defusedxml.txt" > "$W/pipi.out" 2>&1 || { show_out "$W/pipi.out"; DX_INSTALLED=$([[ -n "$(PYTHONDONTWRITEBYTECODE=1 "$VPY" -c "import importlib.metadata as m; print(m.version('defusedxml'))" 2>/dev/null || true)" ]] && echo 1 || echo 0); rbx "pip install defusedxml fehlgeschlagen"; }
    DXN=$(PYTHONDONTWRITEBYTECODE=1 "$VPY" -c "import importlib.metadata as m, defusedxml, defusedxml.ElementTree; print(m.version('defusedxml'))" 2>/dev/null || true)
    [[ "$DXN" == "$PIN_VER" ]] || rbx "defusedxml nach der Installation nicht importierbar oder falsche Version (${DXN:-keine})"
    echo "OK defusedxml $DXN im venv installiert (offline, Hash-Pin $PIN_SHA)"
  fi
  # b) Dateien atomar
  [[ -n "${NEED[xml]:-}" ]] && { write_atomic "$W/lage_xml.py" "$XMLF" 644 || rbx "lage_xml.py nicht installierbar"; }
  [[ -n "${NEED[reqs]:-}" ]] && { write_atomic "$W/lage_reqs.py" "$REQF" 755 || rbx "tools/lage_reqs.py nicht installierbar"; }
  [[ -n "${NEED[vorl]:-}" ]] && { write_atomic "$W/requirements.txt.vorlage" "$VORF" 644 || rbx "requirements.txt.vorlage nicht installierbar"; }
  [[ -n "${NEED[rdx]:-}" ]] && { write_atomic "$W/requirements-defusedxml.txt" "$RDXF" 644 || rbx "requirements-defusedxml.txt nicht installierbar"; }
  if [[ -n "${NEED[db]:-}" ]]; then
    MODE_DB=$(stat -c %a "$DBF.bak-$NAME-$TS")
    write_atomic "$W/database.py" "$DBF" "$MODE_DB" || rbx "database.py nicht installierbar"
  fi
  echo "OK Dateien atomar ersetzt (Sicherungen *.bak-$NAME-$TS, behalten: letzte $KEEP_LAST)"
  PHASE=Pruefung
  mkdir -p "$W/sbx"
  [[ "${SYSTEM_TEST:-}" == 1 && "${SY_BREAK:-}" == post ]] && echo "# Testfehler" >> "$XMLF"    # nur Sandbox-Test: Rollback-Pfad
  for p_ in "database.py:$DBF" "lage_xml.py:$XMLF" "lage_reqs.py:$REQF" "requirements.txt.vorlage:$VORF" "requirements-defusedxml.txt:$RDXF"; do cmp -s "$W/${p_%%:*}" "${p_#*:}" || rbx "${p_%%:*} im Ziel ungleich Nutzlast"; done
  # Selbsttests mit den INSTALLIERTEN Dateien und dem venv-Python (jetzt mit dem echten defusedxml im venv)
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$VPY" "$XMLF" > "$W/st5.out" 2>&1) && grep -q "defusedxml und Rueckfall" "$W/st5.out" || { show_out "$W/st5.out"; rbx "Selbsttest der installierten lage_xml.py im venv fehlgeschlagen (harter Modus erwartet)"; }
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$VPY" "$DBF" > "$W/st6.out" 2>&1) && grep -q "database selftest secXml ok" "$W/st6.out" || { show_out "$W/st6.out"; rbx "Selbsttest der installierten database.py fehlgeschlagen"; }
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$VPY" "$XMLF" --status > "$W/st7.out" 2>&1) && grep -q "'hard': True" "$W/st7.out" || { show_out "$W/st7.out"; rbx "lage_xml --status meldet nicht hart"; }
  pycomp "$DBF" "$XMLF" "$REQF" || rbx "py_compile der installierten Dateien mit Warnung/Fehler"
  echo "OK installierte Dateien: Selbsttests im venv, lage_xml hart (defusedxml $(PYTHONDONTWRITEBYTECODE=1 "$VPY" -c 'import defusedxml; print(defusedxml.__version__)' 2>/dev/null)), py_compile"
  # c) Neustart nur wenn database.py neu ist (nur dieser Dienst)
  if [[ -n "${NEED[db]:-}" ]]; then
    RESTARTED_D=1
    T0D=$(date +%s)
    echo "Neustart prepper-dashboard (laedt database.py; nur dieser Dienst) - warte auf HTTP 200 (max 240 s) ..."
    sudo systemctl restart prepper-dashboard.service
    wait_dash || rbx "prepper-dashboard antwortet nach dem Neustart nicht ($((WD_N * WD_S)) s)"
    PHASE=Pruefung
    wait_ready && echo "OK Dashboard fertig gestartet (erstes Voll-Update da)" || echo "HINWEIS Dashboard zeigt nach 200 s noch die Startseite - Pruefung laeuft trotzdem weiter"
    cat > "$W/alsync.py" << 'PYA'
import json, sys
d = json.load(open(sys.argv[1]))
def find(o):
    if isinstance(o, dict):
        if "alarm_sync" in o and isinstance(o["alarm_sync"], dict):
            return o["alarm_sync"]
        for v in o.values():
            r = find(v)
            if r is not None:
                return r
    elif isinstance(o, list):
        for v in o:
            r = find(v)
            if r is not None:
                return r
    return None
r = find(d)
assert r is not None, "kein alarm_sync in /api/sdr/live"
assert r.get("soll") == "FULL" and r.get("aktiv") is True and r.get("abweichungen") == 0, r
print("alarm_sync: soll=%s aktiv=%s FULL-Verbindungen=%s NORMAL=%s Abweichungen=%s" % (r["soll"], r["aktiv"], r.get("voll"), r.get("normal"), r.get("abweichungen")))
PYA
    aok=0
    for i in $(seq 1 "$JN"); do
      "${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
      "$SPY" "$W/alsync.py" "$W/live.json" > "$W/als.out" 2>&1 && { aok=1; break; }
      sleep "$JS"
    done
    [[ "$aok" == 1 ]] && echo "OK /api/sdr/live im laufenden Dashboard: $(cat "$W/als.out")" || { tail -3 "$W/als.out" | cut -c1-200; rbx "/api/sdr/live zeigt kein alarm_sync mit FULL/aktiv (neue database.py wird im Dashboard nicht benutzt)"; }
    JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
    grep -qF "secXml aktiv - Alarmpfad" <<< "$JD" && echo "OK Journal: $(grep -F "secXml aktiv" <<< "$JD" | tail -1 | cut -c1-200)" || rbx "Journal ohne die secXml-Zeile (database.py nicht neu geladen?)"
  fi
fi
PHASE=Pruefung
type rbx >/dev/null 2>&1 || rbx() { echo "FEHLER: $1"; exit 1; }
[[ "${SYSTEM_TEST:-}" == 1 && "${SY_BREAK:-}" == dash ]] && kill "$(cat "$FAKE_ST/dash.pid")" 2>/dev/null    # nur Sandbox-Test: Rollback-Pfad nach dem Rauchtest
sleep 2
smoke_all || rbx "Rauchtest: eine Seite/API antwortet nicht mehr wie vorher"
for s in prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern; do
  n_=$(systemctl is-active "$s" 2>/dev/null || true)
  [[ "$n_" == "${SVC0[$s]}" ]] || rbx "Dienst $s ist jetzt $n_ (vorher ${SVC0[$s]})"
done
echo "OK Dienste nachher wie vorher: $(for s in prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern; do echo -n "$s=$(systemctl is-active "$s" 2>/dev/null || true) "; done)- nur prepper-dashboard wurde ggf. neu gestartet"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
E2=$(grep -c -E 'Traceback|secXml: synchronous=FULL fuer den Alarmpfad nicht bestaetigt|lage_xml: .*(Fehler|Traceback)' <<< "$JD" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal prepper-dashboard seit Neustart ohne Traceback und ohne secXml-Warnung" || { grep -E 'Traceback|secXml|lage_xml' <<< "$JD" | head -5 | cut -c1-240; rbx "$E2 Fehlerzeilen im Journal"; }
if [[ -f "$LZ" ]]; then
  "$SPY" - "$LZ" << 'PYQ' > "$W/lz1.txt" 2>&1 && echo "OK lagezentrum.db nachher: $(cat "$W/lz1.txt")" || { cat "$W/lz1.txt"; rbx "lagezentrum.db nach dem Patch nicht in Ordnung"; }
import os, sqlite3, sys
p = sys.argv[1]
c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
q = c.execute("PRAGMA quick_check").fetchall()
assert [r[0] for r in q] == ["ok"], q
jm = c.execute("PRAGMA journal_mode").fetchone()[0]
assert str(jm).lower() == "wal", jm
print("quick_check ok, journal_mode=%s, %.1f MB" % (jm, os.path.getsize(p) / 1048576.0))
PYQ
fi
for x in "${!SHA0[@]}"; do [[ "$(s16 "$DASH_DIR/$x")" == "${SHA0[$x]}" ]] && echo "OK $x unveraendert (${SHA0[$x]})" || rbx "$x hat sich veraendert"; done
echo "OK guards: secXml(database.py)=$(grep -c 'secXml' "$DBF" || true) lage_xml 2 MiB fest=$(grep -c '^MAX_BYTES = 2 \* 1024 \* 1024' "$XMLF" || true)"
echo
echo "=== secXml FERTIG ($COMMIT_ARG) ==="
for x in "$DBF" "$XMLF" "$REQF" "$VORF" "$RDXF"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "  defusedxml im venv: $(PYTHONDONTWRITEBYTECODE=1 "$VPY" -c 'import defusedxml; print(defusedxml.__version__)' 2>/dev/null || echo nein)"
[[ -n "$MEAS" ]] && echo "  Kosten FULL gemessen: $MEAS"
echo "Rueckgaengig (alles, in dieser Reihenfolge):"
for x in "$DBF" "$XMLF" "$REQF" "$VORF"; do [[ -f "$x.bak-$NAME-$TS" ]] && echo "  cp -p $x.bak-$NAME-$TS $x"; done
[[ -f "$RDXF" && -n "${NEED[rdx]:-}" ]] && echo "  rm -f $RDXF   (neue Datei)"
[[ "${DX_INSTALLED:-0}" == 1 ]] && echo "  $VPY -m pip uninstall -y defusedxml   (nur falls auch defusedxml zurueck soll; lage_xml.py faellt dann auf den Rueckfall zurueck)"
[[ -f "$DBF.bak-$NAME-$TS" ]] && echo "  sudo systemctl restart prepper-dashboard   (danach laedt das Dashboard wieder die alte database.py)"
[[ -n "${LZB:-}" ]] && echo "SQLite-Sicherung vor dem Patch: $LZB (wurde nicht gebraucht; die Datenbank hat dieses Skript nie veraendert)"
echo "Hinweis: lage_xml.py wirkt erst, wenn dashboard.py es aufruft (Folgepatch der Dashboard-Serie). prepper-sdr schreibt ASA-Ereignisse bis zu seinem naechsten Neustart noch mit NORMAL (bewusst nicht neu gestartet)."
echo "Nur lesend pruefen:"
echo "  curl -s http://127.0.0.1:$PORT/api/sdr/live | grep -o '\"alarm_sync\"[^}]*}'"
echo "  $VPY $XMLF --status"
echo "  python3 $REQF check"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep -E 'secXml|lage_xml'"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme)."
