#!/bin/bash
set -eEuo pipefail
# relDb (commit23): Datenbank-Wartung fuer lagezentrum.db (REL-07 + PERF-06 des Audits). Aendert NUR database.py (neuer Block relDb) und legt tools/lage_db_maint.py neu an.
#  - journal_mode=WAL wird je Prozess und Pfad einmal gesetzt (migrate()/erste Verbindung) statt bei jeder Verbindung (PERF-06). busy_timeout/synchronous bleiben je Verbindung.
#  - Aufraeum-Faden des Dashboards (alle 10 min) fuehrt zusaetzlich die Wartung aus: Checkpoint TRUNCATE alle 6 h (oder bei -wal > 64 MiB) nur ohne Alarm in Arbeit und ohne laufende
#    tools/backup.sh (flock .backup.lock), sonst nur PASSIVE; quick_check im eigenen Faden (nur lesend, 120 s nach Start, dann woechentlich, mit Zeitlimit); Status in retention_status()["maint"]
#    und lagezentrum.db.maint.json. Bei einem Befund wird NUR gemeldet, nichts verschoben oder geloescht. KEIN VACUUM im Betrieb (nur von Hand: tools/lage_db_maint.py vacuum --ja, mit Sicherung).
#  - database.snapshot(): konsistente Kopie ueber die sqlite3-Backup-API wie in tools/backup.sh. Keine Python-Datei ausser database.py, kein dashboard.py, keine Bridges.
# Basis streng (sha16): database.py 431077d36822a090 (oder schon die neue Fassung = idempotent). Anderes = STOP mit Diff, nichts geaendert.
# Neustart: nur prepper-dashboard (dort laeuft der Aufraeum-Faden). prepper-sdr und die Bridges behalten ihr geladenes database.py bis zu ihrem naechsten Neustart (kompatibel, kein Neustart noetig).
# Sicherungen: database.py und tools/lage_db_maint.py (letzte 3), SQLite-Sicherung lagezentrum.db.bak-reldb-ZEIT vor jeder Aenderung (letzte 3). Option "trocken": nur pruefen/testen, nichts aendern, kein sudo.
COMMIT_ARG="${1:-unbekannt}"
OPT="${2:-}"
NAME=reldb
DASH_DIR="/home/fmg/prepper-dashboard"
SPY=/usr/bin/python3
if [[ "${SYSTEM_TEST:-}" == 1 ]]; then DASH_DIR="${SY_DASH:?}"; fi    # nur fuer den Sandbox-Test dieses Skripts
VPY="$DASH_DIR/venv/bin/python"
DBF="$DASH_DIR/database.py"
LZ="$DASH_DIR/lagezentrum.db"
TOOLD="$DASH_DIR/tools"
TOOLF="$TOOLD/lage_db_maint.py"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/reldb-apply
KEEP_LAST=3
KNOWN_DB16="431077d36822a090"
NEW_DB16="3f3aa054076bf70b"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
echo "=== relDb apply ($COMMIT_ARG)${OPT:+ [$OPT]}: Datenbank-Wartung (database.py + tools/lage_db_maint.py), Dashboard-Port $PORT ==="
umask 077
rm -rf "$W" && mkdir -p "$W/base" "$W/sbx"
EXPECT_DB="3f3aa054076bf70b008212584aa401eca4490579d0e786cd13fa7187db970328"
cat > "$W/database.py" << 'RDB_DB_EOF'
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
    t0 = time.time()
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
    out["ms"] = int((time.time() - t0) * 1000)
    return out


def quick_check(path=None, limit_s=QC_LIMIT_S, max_rows=5):
    """PRAGMA quick_check nur lesend (mode=ro), mit Zeitlimit. -> {"ok", "rows", "ms", "err", "aborted"}
    ok True = 'ok'; ok False + rows = Befund der Datei; ok None + err = nicht pruefbar (gesperrt, Zeitlimit, fehlt) - das ist KEIN Befund."""
    path = path or DB_PATH
    out = {"ok": None, "rows": [], "ms": None, "err": None, "aborted": False}
    t0 = time.time()
    con = None
    try:
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        con = _ro(path, 2.0)
        deadline = t0 + float(limit_s)

        def _stop():
            return 1 if time.time() > deadline else 0
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
    out["ms"] = int((time.time() - t0) * 1000)
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
        if self.maint is not None:
            try:
                self.maint.tick(path)   # relDb: wirft nie; aendert keine Daten
            except Exception as e:
                out["err_maint"] = str(e)[:80]
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
                "extra": sorted(self.extra), "maint": (self.maint.status() if self.maint is not None else None),
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
RDB_DB_EOF
EXPECT_TOOL="01efa8bd033e8efc78ce194017f14764b6d0a2ab1d4fc0fbc6b2377b5fdb4e64"
cat > "$W/lage_db_maint.py" << 'RDB_TOOL_EOF'
#!/usr/bin/env python3
"""tools/lage_db_maint.py - Wartung von lagezentrum.db von Hand (relDb). Die automatische Wartung laeuft im Dashboard (database.py, Block relDb).

Aufruf (als Benutzer fmg, ohne sudo):
  python3 tools/lage_db_maint.py status                  nur lesend: Groessen, WAL, freie Seiten, Alarm in Arbeit?, Sicherung laeuft?, quick_check
  python3 tools/lage_db_maint.py quickcheck              nur lesend: PRAGMA quick_check
  python3 tools/lage_db_maint.py checkpoint [--truncate] WAL-Checkpoint (Standard PASSIVE; TRUNCATE nur ohne Alarm in Arbeit und ohne laufende Sicherung)
  python3 tools/lage_db_maint.py snapshot ZIEL           konsistente Kopie (Backup-Schnittstelle) + quick_check; ueberschreibt nie
  python3 tools/lage_db_maint.py vacuum --ja             NUR von Hand, Plan siehe unten (verdichtet die Datei, braucht freien Platz)

VACUUM-Plan (nie automatisch): (1) nur wenn "status" viele freie Seiten zeigt (vacuum_hint) UND kein Alarm in Arbeit ist; (2) freier Platz >= 2 x Datenbank;
(3) Sicherung der Datenbank daneben (<db>.bak-vacuum-ZEIT, mit quick_check) - ohne gueltige Sicherung wird nichts verdichtet;
(4) VACUUM mit 5 s Wartezeit; waehrenddessen sind Schreiber kurz blockiert (Sekunden bei ~10 MB); (5) danach quick_check; bei Fehler bleibt die Sicherung liegen.
Sendet nichts, aendert keine Daten ausser beim ausdruecklichen Befehl vacuum --ja.
"""
import os
import shutil
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.dirname(HERE), HERE):
    if os.path.exists(os.path.join(_p, "database.py")):
        sys.path.insert(0, _p)
        break
import database as db  # noqa: E402


def _path():
    return os.environ.get("LAGE_DB") or db.DB_PATH


def cmd_status(p):
    st = db.db_stats(p)
    print("Datenbank:", p)
    print("Groesse (Seiten): %s, davon frei: %s, WAL: %s" % (db._mb(st.get("bytes")), db._mb(st.get("free_bytes")), db._mb(st.get("wal_bytes"))) if "err" not in st else "Statistik: %s" % st["err"])
    print("Hinweis Verdichten (vacuum_hint):", st.get("vacuum_hint"))
    print("Alarm in Arbeit:", "ja (nichts Hartes jetzt)" if db.alarm_pending(p) else "nein")
    print("Sicherung laeuft:", "ja" if db.backup_running() else "nein")
    q = db.quick_check(p)
    print("quick_check:", "ok" if q["ok"] else ("BEFUND: %s" % "; ".join(q["rows"][:2]) if q["ok"] is False else "nicht pruefbar: %s" % q["err"]), "(%s ms)" % q["ms"])
    return 0 if q["ok"] else 1


def cmd_quickcheck(p):
    q = db.quick_check(p)
    print("ok" if q["ok"] else ("BEFUND: %s" % "; ".join(q["rows"][:3]) if q["ok"] is False else "nicht pruefbar: %s" % q["err"]))
    return 0 if q["ok"] else 1


def cmd_checkpoint(p, truncate):
    if truncate:
        if db.backup_running():
            print("STOP: Sicherung laeuft - spaeter erneut")
            return 2
        if db.alarm_pending(p):
            print("STOP: Alarm in Arbeit - harter Checkpoint jetzt nicht; PASSIVE ist erlaubt")
            return 2
    r = db.checkpoint(p, "TRUNCATE" if truncate else "PASSIVE")
    print("Checkpoint %s: busy=%s, WAL %s -> %s, %s ms%s" % (r["mode"], r["busy"], db._mb(r["wal_before"]), db._mb(r["wal_after"]), r["ms"], (", Fehler: " + r["err"]) if r["err"] else ""))
    return 0 if r["err"] is None and r["busy"] == 0 else 1


def cmd_snapshot(p, dest):
    r = db.snapshot(dest, p)
    print(("OK %s (%s Bytes, quick_check %s, Rechte 600)" % (dest, r["bytes"], r["check"])) if r["ok"] else "FEHLER: %s" % r["err"])
    return 0 if r["ok"] else 1


def cmd_vacuum(p, ja):
    if not ja:
        print("Nichts getan. Zum Verdichten ausdruecklich: vacuum --ja (Plan: siehe Kopf dieser Datei)")
        return 2
    if not os.path.exists(p):
        print("STOP: keine Datenbank")
        return 1
    if db.alarm_pending(p):
        print("STOP: Alarm in Arbeit")
        return 2
    if db.backup_running():
        print("STOP: Sicherung laeuft")
        return 2
    size = os.path.getsize(p) + db.wal_bytes(p)
    free = shutil.disk_usage(os.path.dirname(os.path.abspath(p))).free
    if free < 2 * size + 256 * 1024 * 1024:
        print("STOP: zu wenig freier Platz (%s frei, gebraucht >= %s)" % (db._mb(free), db._mb(2 * size + 256 * 1024 * 1024)))
        return 1
    dest = "%s.bak-vacuum-%s" % (p, time.strftime("%Y%m%d-%H%M%S"))
    s = db.snapshot(dest, p)
    if not s["ok"]:
        print("STOP: Sicherung fehlgeschlagen (%s) - nichts verdichtet" % s["err"])
        return 1
    print("OK Sicherung", dest, "(quick_check", s["check"], ")")
    cmd = "VAC" + "UUM"
    con = None
    try:
        con = sqlite3.connect(p, timeout=5.0, isolation_level=None)
        con.execute("PRAGMA busy_timeout=5000")
        t0 = time.time()
        con.execute(cmd)
        print("Verdichtet in %.1f s" % (time.time() - t0))
    except Exception as e:
        print("FEHLER beim Verdichten: %s - Datei unveraendert gueltig? Sicherung bleibt: %s" % (e, dest))
        return 1
    finally:
        try:
            con and con.close()
        except Exception:
            pass
    q = db.quick_check(p)
    print("quick_check danach:", "ok" if q["ok"] else q["rows"] or q["err"])
    return 0 if q["ok"] else 1


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    p = _path()
    c = argv[0]
    if c == "status":
        return cmd_status(p)
    if c == "quickcheck":
        return cmd_quickcheck(p)
    if c == "checkpoint":
        return cmd_checkpoint(p, "--truncate" in argv[1:])
    if c == "snapshot" and len(argv) == 2:
        return cmd_snapshot(p, argv[1])
    if c == "vacuum":
        return cmd_vacuum(p, "--ja" in argv[1:])
    print("Unbekannter Befehl. Hilfe: python3 tools/lage_db_maint.py --help")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
RDB_TOOL_EOF
EXPECT_GUARD="c0709e438875ddeeb21c58e67b8b4fca2e22ecbe99118431f36940f28c21023f"
cat > "$W/guard_reldb.py" << 'RDB_GUARD_EOF'
#!/usr/bin/env python3
"""guard_reldb.py - AST-Pruefung fuer relDb (database.py + tools/lage_db_maint.py) samt Mutationstest.
  check DATABASE_PY TOOL_PY BASE_PY   -> Exit 0 = alle Pruefungen ok
  mutate BASE_PY EDITS_PY TOOL_PY     -> baut die neue Fassung, wendet jede Mutation einzeln an, jede muss von check erkannt werden
"""
import ast
import importlib.util
import pathlib
import re
import sys

TOK = "VAC" + "UUM"
NEW_FUNCS = ["_set_wal", "wal_bytes", "_ro", "backup_running", "alarm_pending", "checkpoint", "quick_check", "db_stats", "snapshot", "_mb", "selftest_maint"]
DML = re.compile(r"\b(DELETE|DROP|UPDATE|INSERT|ALTER|REPLACE INTO)\b", re.I)


def consts(node):
    return [n.value for n in ast.walk(node) if isinstance(n, ast.Constant) and isinstance(n.value, str)]


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


def seg(src, node):
    return ast.get_source_segment(src, node) or ""


def check_db(src, base_src):
    errs = []
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    try:
        btree = ast.parse(base_src)
    except SyntaxError:
        btree = None
    top = {n.name for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
    for f in NEW_FUNCS + ["_Maint"]:
        if f not in top:
            errs.append("fehlt: %s" % f)
    if btree is not None:
        for n in btree.body:
            if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name not in top:
                errs.append("Basis-Funktion entfernt: %s" % n.name)
    doc = ast.get_docstring(tree) or ""
    if "relDb" not in doc:
        errs.append("Modul-Docstring ohne relDb")
    # WAL einmalig
    con = fdef(tree, "connect")
    if con is None:
        errs.append("connect fehlt")
    else:
        if any(c == "PRAGMA journal_mode=WAL" for c in consts(con)):
            errs.append("connect setzt journal_mode=WAL bei jeder Verbindung")
        s = seg(src, con)
        if "_wal_done" not in s or "_set_wal(" not in s:
            errs.append("connect: WAL nicht einmalig (_wal_done/_set_wal)")
        if "synchronous=NORMAL" not in " ".join(consts(con)) or "busy_timeout" not in " ".join(consts(con)):
            errs.append("connect: busy_timeout/synchronous fehlen")
    sw = fdef(tree, "_set_wal")
    if sw is not None and "PRAGMA journal_mode=WAL" not in consts(sw):
        errs.append("_set_wal setzt WAL nicht")
    mig = fdef(tree, "migrate")
    if mig is None or "_wal_done.discard(" not in seg(src, mig):
        errs.append("migrate: WAL nicht neu bestaetigt (_wal_done.discard)")
    # kein Platz-Aufraeumbefehl
    for c in consts(tree):
        if c.strip().upper().split()[:1] == [TOK]:
            errs.append("Platz-Aufraeumbefehl im Programmtext")
            break
        if re.search(r"auto_vacuum|incremental_vacuum", c, re.I):
            errs.append("auto_vacuum/incremental im Programmtext")
            break
    # nur lesend / Wartung ohne Datenaenderung (Block-Funktionen)
    ro_funcs = ["wal_bytes", "_ro", "backup_running", "alarm_pending", "checkpoint", "quick_check", "db_stats", "snapshot"]
    for f in ro_funcs:
        fn = fdef(tree, f)
        if fn is None:
            continue
        for c in consts(fn):
            if DML.search(c) and f != "snapshot":
                errs.append("%s: Datenaenderung im Text (%s)" % (f, c[:30]))
        if f != "snapshot":
            for n in ast.walk(fn):
                if isinstance(n, ast.Attribute) and n.attr in ("unlink", "remove", "rmtree", "rename"):
                    errs.append("%s: loescht/benennt Dateien" % f)
    mt = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "_Maint"]
    if mt:
        for n in ast.walk(mt[0]):
            if isinstance(n, ast.Attribute) and n.attr in ("unlink", "remove", "rmtree", "rename"):
                errs.append("_Maint loescht/benennt Dateien")
        for c in consts(mt[0]):
            if DML.search(c):
                errs.append("_Maint: Datenaenderung im Text")
    # lesende Verbindungen
    ro = fdef(tree, "_ro")
    if ro is not None and not any("mode=ro" in c for c in consts(ro)):
        errs.append("_ro nicht mode=ro")
    for f in ("alarm_pending", "quick_check", "db_stats", "snapshot"):
        fn = fdef(tree, f)
        if fn is not None and "_ro(" not in seg(src, fn):
            errs.append("%s nutzt keine read-only-Verbindung" % f)
    # Checkpoint nur PASSIVE/TRUNCATE
    cp = fdef(tree, "checkpoint")
    if cp is not None:
        s = seg(src, cp)
        if '"TRUNCATE" if str(mode).upper() == "TRUNCATE" else "PASSIVE"' not in s:
            errs.append("checkpoint: Modus nicht auf PASSIVE/TRUNCATE begrenzt")
        if re.search(r"\b(FULL|RESTART)\b", s):
            errs.append("checkpoint: FULL/RESTART")
        if "wal_checkpoint(%s)" not in s:
            errs.append("checkpoint: PRAGMA fehlt")
    # snapshot ueberschreibt nie
    sn = fdef(tree, "snapshot")
    if sn is not None:
        s = seg(src, sn)
        if "Ziel existiert schon" not in s or "os.replace(part, dest)" not in s or "0o600" not in s:
            errs.append("snapshot: Schutz (nie ueberschreiben/.part/600) fehlt")
        if s.index("os.path.exists(dest)") > s.index("sqlite3.connect(part)") if ("os.path.exists(dest)" in s and "sqlite3.connect(part)" in s) else True:
            errs.append("snapshot: Pruefung Ziel nach dem Anlegen")
    # Wartungsplan: Reihenfolge der Sperren
    ck = fdef(tree, "_ckpt", "_Maint")
    if ck is None:
        errs.append("_Maint._ckpt fehlt")
    else:
        s = seg(src, ck)
        i_bk, i_al, i_tr = s.find("backup_running("), s.find("alarm_pending("), s.find('"TRUNCATE"')
        if min(i_bk, i_al, i_tr) < 0 or not (i_bk < i_al < i_tr):
            errs.append("_ckpt: Reihenfolge Sicherung -> Alarm -> TRUNCATE verletzt")
        if "if backup_running(" not in s or "if alarm_pending(" not in s:
            errs.append("_ckpt: Bedingungen fehlen")
    tk = fdef(tree, "tick", "_Maint")
    if tk is None:
        errs.append("_Maint.tick fehlt")
    else:
        tries = [n for n in tk.body if isinstance(n, ast.Try)]
        if not tries or not any(h.type is not None and isinstance(h.type, ast.Name) and h.type.id == "Exception" for h in tries[0].handlers):
            errs.append("tick faengt nicht alle Fehler")
        if "time.monotonic()" not in seg(src, tk):
            errs.append("tick ohne monotonic")
    ql = fdef(tree, "_qc_loop", "_Maint")
    if ql is None or "quick_check(path)" not in seg(src, ql) or "daemon" not in seg(src, fdef(tree, "tick", "_Maint") or tree):
        errs.append("quick_check nicht im eigenen Daemon-Faden")
    # Konstanten
    vals = {}
    for n in tree.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
            try:
                vals[n.targets[0].id] = eval(compile(ast.Expression(n.value), "", "eval"), {"__builtins__": {}}, {})
            except Exception:
                pass
    want = {"CKPT_EVERY_S": 6 * 3600, "WAL_MAX_BYTES": 64 * 1024 * 1024, "CKPT_BUSY_MS": 1000, "QC_FIRST_S": 120, "QC_EVERY_S": 7 * 86400, "ALARM_INFLIGHT_S": 900,
            "BACKUP_LOCK": "/home/fmg/prepper-backups/.backup.lock", "TIMEOUT_S": 10.0}
    for k, v in want.items():
        if vals.get(k) != v:
            errs.append("Konstante %s = %r (erwartet %r)" % (k, vals.get(k), v))
    # Einbindung Aufraeum-Faden
    rt = [n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "_Retention"]
    if rt:
        s = seg(src, rt[0])
        for must in ("self.maint = _Maint()", "self.maint.tick(path)", '"maint": (self.maint.status()'):
            if must not in s:
                errs.append("_Retention: %s fehlt" % must)
    else:
        errs.append("_Retention fehlt")
    st = fdef(tree, "selftest_retention")
    if st is None or "r.maint = None" not in seg(src, st):
        errs.append("selftest_retention: r.maint = None fehlt")
    if "print(selftest_maint())" not in src:
        errs.append("__main__ ohne selftest_maint")
    # keine Netz-/Prozess-Importe
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                if a.name.split(".")[0] in ("socket", "subprocess", "requests", "urllib", "http", "smtplib", "ctypes"):
                    if a.name != "urllib.parse":
                        errs.append("Import %s" % a.name)
        if isinstance(n, ast.ImportFrom) and (n.module or "").split(".")[0] in ("socket", "subprocess", "requests", "http", "smtplib"):
            errs.append("Import aus %s" % n.module)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("system", "popen", "Popen", "call", "check_output") and isinstance(n.func.value, ast.Name) and n.func.value.id in ("os", "subprocess"):
            errs.append("Prozessstart")
    return errs


def check_tool(src):
    errs = []
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        return ["Tool Syntaxfehler: %s" % e]
    cv = fdef(tree, "cmd_vacuum")
    if cv is None:
        return ["cmd_vacuum fehlt"]
    s = seg(src, cv)
    first = cv.body[0] if cv.body else None
    if not (isinstance(first, ast.If) and "not ja" in seg(src, first.test)):
        errs.append("vacuum: erste Pruefung nicht 'not ja'")
    for must in ("alarm_pending(", "backup_running(", "disk_usage(", "db.snapshot(", "2 * size"):
        if must not in s:
            errs.append("vacuum: %s fehlt" % must)
    if "db.snapshot(" in s and 'VAC" + "UUM' in s and s.index("db.snapshot(") > s.index('VAC" + "UUM'):
        errs.append("vacuum: Sicherung nach dem Verdichten")
    if 'if not s["ok"]' not in s:
        errs.append("vacuum: ohne Abbruch bei fehlgeschlagener Sicherung")
    if "--ja" not in src.split("def main", 1)[-1]:
        errs.append("main: --ja fehlt")
    for n in ast.walk(tree):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("system", "popen", "Popen", "call", "check_output", "run"):
            errs.append("Tool startet Prozesse")
        if isinstance(n, ast.keyword) and n.arg == "shell":
            errs.append("shell=")
    cc = fdef(tree, "cmd_checkpoint")
    if cc is None or "backup_running(" not in seg(src, cc) or "alarm_pending(" not in seg(src, cc):
        errs.append("checkpoint --truncate ohne Sperren")
    return errs


def check(db_src, tool_src, base_src):
    return check_db(db_src, base_src) + check_tool(tool_src)


def mutants(new_db, tool_src, edits):
    out = []
    for name, old, new in edits:                     # jede Aenderung einzeln zurueckdrehen
        if name == "E04_block":
            continue
        assert new_db.count(new) == 1, name
        out.append(("revert " + name, new_db.replace(new, old), tool_src))
    blk = [e for e in edits if e[0] == "E04_block"][0]
    def mk(label, a, b, text=None, tool=False):
        t = tool_src if tool else new_db
        assert t.count(a) >= 1, label
        out.append((label, new_db if tool else new_db.replace(a, b, 1), tool_src.replace(a, b, 1) if tool else tool_src))
    mk("M10 Checkpoint-Modus frei", '"TRUNCATE" if str(mode).upper() == "TRUNCATE" else "PASSIVE"', 'str(mode).upper()')
    mk("M11 Alarm-Pruefung entfernt", "        if alarm_pending(path):\n            r = checkpoint(path, \"PASSIVE\")", "        if False:\n            r = checkpoint(path, \"PASSIVE\")")
    mk("M12 Sicherungs-Pruefung entfernt", "        if backup_running(self.lock_path):\n            self.st[\"ckpt_skip\"]", "        if False:\n            self.st[\"ckpt_skip\"]")
    mk("M13 read-only aus", 'file:%s?mode=ro', 'file:%s?mode=rw')
    mk("M14 Platz-Aufraeumbefehl", '"PRAGMA wal_checkpoint(%s)" % mode', '"' + TOK + '"')
    mk("M15 tick faengt nicht alles", 'except Exception as e:\n            self.st["err"] = str(e)[:120]\n        return self.st', 'except KeyError as e:\n            self.st["err"] = str(e)[:120]\n        return self.st')
    mk("M16 Datenaenderung im Lesepfad", "SELECT 1 FROM mesh_queue WHERE state='wait' LIMIT 1", "DELETE FROM mesh_queue WHERE state='wait'")
    mk("M17 snapshot ueberschreibt", 'raise RuntimeError("Ziel existiert schon")', 'pass')
    mk("M18 subprocess-Import", "import errno as _rd_errno\n", "import errno as _rd_errno\nimport subprocess as _rd_sp\n")
    mk("M19 WAL je Verbindung", "        if p not in _wal_done:\n            _set_wal(con, p)\n", '        con.execute("PRAGMA journal_mode=WAL")\n')
    mk("M20 6h -> 6 min", "CKPT_EVERY_S = 6 * 3600", "CKPT_EVERY_S = 6 * 60")
    mk("M21 Checkpoint FULL", 'if str(mode).upper() == "TRUNCATE" else "PASSIVE"', 'if str(mode).upper() == "TRUNCATE" else "FULL"')
    mk("M22 Reihenfolge vertauscht", "        if backup_running(self.lock_path):", "        if alarm_pending(path) and backup_running(self.lock_path):")
    mk("M23 quick_check ohne Faden", 'name="lz-quickcheck", daemon=True)', 'name="lz-quickcheck")')
    mk("M24 Datei loeschen in _Maint", "        except Exception:\n            pass\n\n    def _ckpt", "        except Exception:\n            os.unlink(self.path)\n\n    def _ckpt")
    mk("M25 migrate ohne WAL-Neubestaetigung", "        _wal_done.discard(path)   # relDb: connect() unten setzt WAL neu und merkt es sich\n", "")
    # Werkzeug
    mk("T01 vacuum ohne --ja-Pruefung", "    if not ja:\n", "    if False:\n", tool=True)
    mk("T02 vacuum ohne Sicherung", "    s = db.snapshot(dest, p)\n    if not s[\"ok\"]:", "    s = {\"ok\": True, \"check\": 0}\n    if not s[\"ok\"]:", tool=True)
    mk("T03 vacuum ohne Alarm-Pruefung", "    if db.alarm_pending(p):\n        print(\"STOP: Alarm in Arbeit\")\n        return 2\n    if db.backup_running():\n        print(\"STOP: Sicherung laeuft\")\n        return 2\n    size", "    size", tool=True)
    mk("T04 Werkzeug mit shell", "def main(argv):", "import subprocess\nsubprocess.call('x', shell=True)\n\n\ndef main(argv):", tool=True)
    return out


def main(argv):
    if argv[0] == "check":
        db_src = pathlib.Path(argv[1]).read_text(encoding="utf-8")
        tool_src = pathlib.Path(argv[2]).read_text(encoding="utf-8")
        base_src = pathlib.Path(argv[3]).read_text(encoding="utf-8")
        e = check(db_src, tool_src, base_src)
        n = 0
        if e:
            print("GUARD FEHLER:\n  " + "\n  ".join(e))
            return 1
        print("OK guard relDb: Pruefgruppen bestanden (WAL einmalig, kein VACUUM, nur lesend/PASSIVE/TRUNCATE, Sperren Alarm+Sicherung, snapshot ueberschreibt nie, Faden, Konstanten, Einbindung, keine Netz-/Prozess-Importe, Werkzeug)")
        return 0
    if argv[0] == "mutate":
        base = pathlib.Path(argv[1]).read_text(encoding="utf-8")
        spec = importlib.util.spec_from_file_location("edits", argv[2])
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        tool_src = pathlib.Path(argv[3]).read_text(encoding="utf-8")
        new_db = m.build(base)
        assert check(new_db, tool_src, base) == [], check(new_db, tool_src, base)
        miss = []
        ms = mutants(new_db, tool_src, m.EDITS)
        for label, d, t in ms:
            if not check(d, t, base):
                miss.append(label)
        print("OK mutation: %d Mutationen, %d erkannt, %d uebersehen%s" % (len(ms), len(ms) - len(miss), len(miss), (": " + ", ".join(miss)) if miss else ""))
        return 1 if miss else 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
RDB_GUARD_EOF
EXPECT_EDITS="5f05b0603d9e14c1d8a9cccedc39e2cbbcfa93494373b94322829084ffa16fd2"
cat > "$W/edits_reldb.py" << 'RDB_EDITS_EOF'
"""relDb: database.py (Basis 431077d36822a090) -> neue Fassung. Jede Ersetzung muss genau einmal passen (sonst Abbruch)."""
import sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent
BLOCK = (HERE / "block_reldb.py").read_text(encoding="utf-8")

SQLA_HDR = "# ---------------------------------------------------------------- sqlA (Aufraeumen im eigenen Faden)\n"

EDITS = [
    ("E01_doc",
     "             kind 'dab' = echte Messung, kind 'hb' = Lebenszeichen aus sdr_status.json (Watchdog).\n\"\"\"\n",
     "             kind 'dab' = echte Messung, kind 'hb' = Lebenszeichen aus sdr_status.json (Watchdog).\n"
     "relDb: Wartung der Datenbank im Hintergrund (Checkpoint, quick_check, snapshot), WAL einmal je Prozess und Pfad (siehe Block relDb weiter unten).\n\"\"\"\n"),
    ("E02_connect",
     'def connect(path=None):\n'
     '    """Neue Verbindung (je Aufruf). WAL, busy_timeout, Row-Zugriff per Name. sqlA: rollback vor close; Fehler in den PRAGMAs -> sofort schliessen."""\n'
     '    con = sqlite3.connect(path or DB_PATH, timeout=TIMEOUT_S, factory=_Con)\n'
     '    try:\n'
     '        con.row_factory = sqlite3.Row\n'
     '        con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))\n'
     '        con.execute("PRAGMA journal_mode=WAL")\n'
     '        con.execute("PRAGMA synchronous=NORMAL")\n'
     '    except Exception:\n'
     '        con.close()\n'
     '        raise\n'
     '    return con\n',
     '_wal_done = set()   # relDb (PERF-06): Pfade, fuer die in diesem Prozess journal_mode=WAL schon gesetzt und bestaetigt wurde\n'
     '\n'
     '\n'
     'def _set_wal(con, path):\n'
     '    """relDb: journal_mode=WAL steht dauerhaft in der Datei; je Prozess und Pfad genuegt EIN Setzen (migrate() bzw. erste Verbindung)."""\n'
     '    r = con.execute("PRAGMA journal_mode=WAL").fetchone()\n'
     '    if r is not None and str(r[0]).lower() == "wal":\n'
     '        _wal_done.add(path)\n'
     '        return True\n'
     '    return False   # z. B. Dateisystem ohne WAL: nicht merken, naechste Verbindung prueft erneut\n'
     '\n'
     '\n'
     'def connect(path=None):\n'
     '    """Neue Verbindung (je Aufruf). busy_timeout, synchronous, Row-Zugriff per Name; WAL nur einmal je Prozess/Pfad (relDb). sqlA: rollback vor close; Fehler in den PRAGMAs -> sofort schliessen."""\n'
     '    p = path or DB_PATH\n'
     '    con = sqlite3.connect(p, timeout=TIMEOUT_S, factory=_Con)\n'
     '    try:\n'
     '        con.row_factory = sqlite3.Row\n'
     '        con.execute("PRAGMA busy_timeout=%d" % int(TIMEOUT_S * 1000))\n'
     '        if p not in _wal_done:\n'
     '            _set_wal(con, p)\n'
     '        con.execute("PRAGMA synchronous=NORMAL")\n'
     '    except Exception:\n'
     '        con.close()\n'
     '        raise\n'
     '    return con\n'),
    ("E03_migrate",
     '    """Schema anlegen/ergaenzen (idempotent). -> True/False"""\n'
     '    path = path or DB_PATH\n'
     '    try:\n'
     '        d = os.path.dirname(path)\n',
     '    """Schema anlegen/ergaenzen (idempotent). Setzt journal_mode=WAL (relDb: hier, nicht mehr bei jeder Verbindung). -> True/False"""\n'
     '    path = path or DB_PATH\n'
     '    try:\n'
     '        _wal_done.discard(path)   # relDb: connect() unten setzt WAL neu und merkt es sich\n'
     '        d = os.path.dirname(path)\n'),
    ("E04_block", SQLA_HDR, BLOCK + SQLA_HDR),
    ("E05_init",
     '        self.extra = {}\n'
     '        self.st = {"started": None, "restarts": 0, "n": 0, "t": None, "last": None, "err": None, "first": None}\n',
     '        self.extra = {}\n'
     '        self.maint = _Maint()   # relDb: Checkpoint/quick_check im selben Faden (nicht bei Test-Instanzen: maint = None)\n'
     '        self.st = {"started": None, "restarts": 0, "n": 0, "t": None, "last": None, "err": None, "first": None}\n'),
    ("E06_run",
     '                out[k] = None\n'
     '                out["err_" + k] = str(e)[:80]\n'
     '        ms = int((time.time() - t0) * 1000)\n',
     '                out[k] = None\n'
     '                out["err_" + k] = str(e)[:80]\n'
     '        if self.maint is not None:\n'
     '            try:\n'
     '                self.maint.tick(path)   # relDb: wirft nie; aendert keine Daten\n'
     '            except Exception as e:\n'
     '                out["err_maint"] = str(e)[:80]\n'
     '        ms = int((time.time() - t0) * 1000)\n'),
    ("E07_status",
     '                "extra": sorted(self.extra), **{k: self.st[k] for k in ("started", "restarts", "n", "t", "last", "err", "first")}}\n',
     '                "extra": sorted(self.extra), "maint": (self.maint.status() if self.maint is not None else None),\n'
     '                **{k: self.st[k] for k in ("started", "restarts", "n", "t", "last", "err", "first")}}\n'),
    ("E08_selftest",
     '    r = _Retention(every_s=3600, first_s=3600, name="lz-retention-test")\n'
     '    r.quiet = True\n',
     '    r = _Retention(every_s=3600, first_s=3600, name="lz-retention-test")\n'
     '    r.quiet = True\n'
     '    r.maint = None\n'),
    ("E09_main",
     '    print(selftest_retention())\n'
     '    print(selftest_state())\n',
     '    print(selftest_retention())\n'
     '    print(selftest_state())\n'
     '    print(selftest_maint())\n'),
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
RDB_EDITS_EOF
EXPECT_BLOCK="8834d3f929c24203df3eac76103b9582cbb441b6ee2504783091ad55ab221513"
cat > "$W/block_reldb.py" << 'RDB_BLOCK_EOF'
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
    t0 = time.time()
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
    out["ms"] = int((time.time() - t0) * 1000)
    return out


def quick_check(path=None, limit_s=QC_LIMIT_S, max_rows=5):
    """PRAGMA quick_check nur lesend (mode=ro), mit Zeitlimit. -> {"ok", "rows", "ms", "err", "aborted"}
    ok True = 'ok'; ok False + rows = Befund der Datei; ok None + err = nicht pruefbar (gesperrt, Zeitlimit, fehlt) - das ist KEIN Befund."""
    path = path or DB_PATH
    out = {"ok": None, "rows": [], "ms": None, "err": None, "aborted": False}
    t0 = time.time()
    con = None
    try:
        if not os.path.exists(path):
            raise RuntimeError("keine Datenbank")
        con = _ro(path, 2.0)
        deadline = t0 + float(limit_s)

        def _stop():
            return 1 if time.time() > deadline else 0
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
    out["ms"] = int((time.time() - t0) * 1000)
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


RDB_BLOCK_EOF
EXPECT_BASE="431077d36822a09028d7b0787cd79dc582c6103bceb861ad5ec73b8211c6b155"
cat > "$W/base_database.py" << 'RDB_BASE_EOF'
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


def migrate(path=None):
    """Schema anlegen/ergaenzen (idempotent). -> True/False"""
    path = path or DB_PATH
    try:
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
RDB_BASE_EOF
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
PAYLOADS=(database.py:DB lage_db_maint.py:TOOL guard_reldb.py:GUARD edits_reldb.py:EDITS block_reldb.py:BLOCK base_database.py:BASE)
verify_payloads
cp "$W/base_database.py" "$W/base/database.py"
# ---------- 1) Zustand vorher (nur lesend) ----------
[[ -d "$DASH_DIR" ]] || stop "Projektordner fehlt: $DASH_DIR"
a=$(systemctl is-active prepper-dashboard 2>/dev/null || true); [[ "$a" == active ]] || stop "Dienst prepper-dashboard ist nicht aktiv ($a)"
check_base database.py "$DBF" "$KNOWN_DB16" "$NEW_DB16"
declare -A SHA0
for x in dashboard.py prepper_sdr.py sdr_manager.py prepper_docs.py mesh_router.py lagegeo.py health_check.py config.py; do [[ -f "$DASH_DIR/$x" ]] && SHA0[$x]=$(s16 "$DASH_DIR/$x"); done
declare -A CODE0; dash_get_codes CODE0
n200=0; for p in "${PAGES[@]}" "${APIS[@]}"; do [[ "${CODE0[$p]}" == 200 ]] && n200=$((n200 + 1)); done
echo "vorher HTTP: $n200 von $(( ${#PAGES[@]} + ${#APIS[@]} )) Seiten/APIs = 200 ($(for p in "${PAGES[@]}" "${APIS[@]}"; do echo -n "$p=${CODE0[$p]} "; done | cut -c1-700))"
[[ "$n200" -ge 1 ]] || stop "das Dashboard antwortet nicht (Port $PORT)"
if [[ -f "$LZ" ]]; then
  "$SPY" - "$LZ" << 'PYQ' > "$W/lz0.txt" 2>&1 || stop "lagezentrum.db nicht lesbar: $(head -c 200 "$W/lz0.txt")"
import os, sqlite3, sys
p = sys.argv[1]
c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
q = c.execute("PRAGMA quick_check").fetchall()
assert [r[0] for r in q] == ["ok"], q
jm = c.execute("PRAGMA journal_mode").fetchone()[0]
n = {t: c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0] for t in ("events", "mesh_log", "telemetry") if c.execute("SELECT 1 FROM sqlite_master WHERE name=?", (t,)).fetchone()}
w = os.path.getsize(p + "-wal") if os.path.exists(p + "-wal") else 0
print("quick_check ok, journal_mode=%s, %.1f MB, WAL %.1f MB, Zeilen %s" % (jm, os.path.getsize(p) / 1048576.0, w / 1048576.0, n))
PYQ
  echo "OK lagezentrum.db vorher: $(cat "$W/lz0.txt")"
else
  echo "HINWEIS $LZ gibt es nicht (wird vom Dashboard angelegt) - keine SQLite-Sicherung noetig"
fi
# ---------- 2) Pruefungen der Nutzlast (Sandbox, nichts Echtes angefasst) ----------
"$SPY" "$W/edits_reldb.py" "$W/base/database.py" "$W/rebuilt.py" || stop "Aufbau aus der Basis misslungen"
cmp -s "$W/rebuilt.py" "$W/database.py" && echo "OK die eingebettete database.py ist byte-genau das Ergebnis der geprueften Edits auf der Basis" || stop "eingebettete database.py ungleich Edits(Basis)"
"$SPY" "$W/guard_reldb.py" check "$W/database.py" "$W/lage_db_maint.py" "$W/base/database.py" || stop "Guard hat die Nutzlast beanstandet"
"$SPY" "$W/guard_reldb.py" mutate "$W/base/database.py" "$W/edits_reldb.py" "$W/lage_db_maint.py" || stop "Mutationstest: eine Mutation wurde uebersehen"
pycomp "$W/database.py" "$W/lage_db_maint.py" "$W/guard_reldb.py" "$W/edits_reldb.py" || stop "py_compile mit Warnung/Fehler"
echo "OK py_compile ohne Warnung (System-Python $("$SPY" -V 2>&1), venv-Python $("$VPY" -V 2>&1))"
for py in "$SPY" "$VPY"; do
  rm -rf "$W/sbx" && mkdir -p "$W/sbx/tools" && cp "$W/database.py" "$W/sbx/" && cp "$W/lage_db_maint.py" "$W/sbx/tools/"
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$py" database.py > "$W/selftest.out" 2>&1) || { tail -8 "$W/selftest.out"; stop "Selbsttest database.py ($py) fehlgeschlagen"; }
  grep -q "database selftest relDb ok" "$W/selftest.out" || { tail -5 "$W/selftest.out"; stop "Selbsttest relDb meldet nicht ok"; }
  echo "OK Selbsttests database.py mit $("$py" -V 2>&1) ($(grep -c "selftest" "$W/selftest.out") Gruppen, darunter relDb; Sandbox-Datenbanken in /tmp, nichts Echtes angefasst)"
done
# Werkzeug in der Sandbox
rm -rf "$W/sbx" && mkdir -p "$W/sbx/tools" && cp "$W/database.py" "$W/sbx/" && cp "$W/lage_db_maint.py" "$W/sbx/tools/"
cat > "$W/mkfix.py" << 'PYT'
import database as d
p = "t.db"
assert d.migrate(p) and d.migrate_t2(p) and d.migrate_t3(p)
PYT
(cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/mkfix.py") || stop "Werkzeug-Test: Fixture-Datenbank nicht anlegbar"
for c in "status" "checkpoint" "checkpoint --truncate" "quickcheck" "snapshot $W/sbx/snap.db"; do
  (cd "$W/sbx" && LAGE_DB="$W/sbx/t.db" PYTHONDONTWRITEBYTECODE=1 "$SPY" tools/lage_db_maint.py $c > "$W/tool.out" 2>&1) || { cat "$W/tool.out"; stop "Werkzeug lage_db_maint.py $c: Sandbox-Test fehlgeschlagen"; }
done
rc=0; (cd "$W/sbx" && LAGE_DB="$W/sbx/t.db" PYTHONDONTWRITEBYTECODE=1 "$SPY" tools/lage_db_maint.py vacuum > "$W/tool.out" 2>&1) || rc=$?
[[ "$rc" == 2 ]] && grep -q "Nichts getan" "$W/tool.out" || stop "Werkzeug: vacuum ohne --ja muss mit Exit 2 nichts tun (Exit $rc)"
echo "OK tools/lage_db_maint.py in der Sandbox: status, checkpoint, checkpoint --truncate, quickcheck, snapshot, vacuum ohne --ja (tut nichts)"
# Verhalten auf einer KOPIE der echten Datenbank (Backup-Schnittstelle, nur lesend gelesen, Kopie nur in /tmp mit Rechten 600, danach geloescht)
if [[ -f "$LZ" ]]; then
  sqlite_snapshot "$LZ" "$W/dbcopy.db" || stop "SQLite-Kopie fuer den Test fehlgeschlagen"
  rm -rf "$W/sbx" && mkdir -p "$W/sbx" && cp "$W/database.py" "$W/sbx/"
  (cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$SPY" - "$W/dbcopy.db" << 'PYL' > "$W/dbcopy.out" 2>&1) || { cat "$W/dbcopy.out"; stop "Test auf der Kopie der echten Datenbank fehlgeschlagen"; }
import sqlite3, sys, time
import database as d
p = sys.argv[1]
def counts():
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
    r = {t: c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0] for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchall()}
    c.close()
    return r
a = counts()
assert d.migrate(p) and d.migrate_t2(p) and d.migrate_t3(p)
assert p in d._wal_done
for _ in range(3):
    d.connect(p).close()
q = d.quick_check(p)
assert q["ok"] is True, q
s = d.db_stats(p)
assert "err" not in s, s
r = d.checkpoint(p, "TRUNCATE")
assert r["err"] is None and r["busy"] == 0 and d.wal_bytes(p) == 0, r
b = counts()
assert a == b, (a, b)
sn = d.snapshot(p + ".snap", p)
assert sn["ok"], sn
mt = d._Maint(qc_first_s=0.05, quiet=True, lock=p + ".nolock")
mt.tick(p, mono=10.0)
for _ in range(100):
    if mt.st["qc"] is not None:
        break
    time.sleep(0.1)
mt.stop = True
assert mt.st["qc"] and mt.st["qc"]["ok"] is True, mt.st
print("Kopie der echten Datenbank: migrate idempotent, Tabellenzeilen unveraendert (%d Tabellen), quick_check ok (%d ms), TRUNCATE ok (%.1f MB, %d ms), snapshot ok, Wartungsplan ok" % (len(a), q["ms"], s["bytes"] / 1048576.0, r["ms"]))
PYL
  echo "OK $(tail -1 "$W/dbcopy.out")"
  rm -f "$W/dbcopy.db" "$W/dbcopy.db-wal" "$W/dbcopy.db-shm" "$W/dbcopy.db.snap" "$W/dbcopy.db.maint.json"
fi
if [[ "$OPT" == "trocken" ]]; then
  echo "TROCKENLAUF FERTIG: alle Pruefungen ok, es wurde nichts geaendert (kein sudo, kein Neustart, keine Sicherung). Zum Installieren ohne 'trocken' aufrufen."
  exit 0
fi
# ---------- 3) Installieren ----------
NEED_DB=0; NEED_TOOL=0
[[ "${BSTATE[database.py]}" == alt ]] && NEED_DB=1
{ [[ -f "$TOOLF" ]] && cmp -s "$W/lage_db_maint.py" "$TOOLF"; } || NEED_TOOL=1
if [[ "$NEED_DB$NEED_TOOL" == 00 ]]; then
  echo "OK relDb schon installiert (database.py und tools/lage_db_maint.py) - keine Aenderung, kein Neustart"
else
  [[ "$NEED_DB" == 1 ]] && { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart von prepper-dashboard erforderlich"; }
  LZB=""
  if [[ -f "$LZ" && "$NEED_DB" == 1 ]]; then
    LZB="$LZ.bak-$NAME-$TS"
    sqlite_snapshot "$LZ" "$LZB" || { rm -f "$LZB"; stop "SQLite-Sicherung lagezentrum.db fehlgeschlagen"; }
    prune_bak "$LZ"
    echo "OK SQLite-Sicherung $(basename "$LZB") ($(wc -c < "$LZB") Bytes, integrity_check ok), behalten: letzte $KEEP_LAST"
  fi
  trap '' INT
  PHASE=Installation
  RESTARTED_D=0; TOOL_WAS=0; [[ -f "$TOOLF" ]] && TOOL_WAS=1
  T0D=$(date +%s)
  rb() {
    set +e +o pipefail
    trap - ERR
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat 2>/dev/null | grep -E "relDb|Traceback" | tail -4 | cut -c1-200
    [[ -f "$DBF.bak-$NAME-$TS" ]] && cp -a "$DBF.bak-$NAME-$TS" "$DBF.rb" && mv -f "$DBF.rb" "$DBF"
    if [[ "$TOOL_WAS" == 1 ]]; then [[ -f "$TOOLF.bak-$NAME-$TS" ]] && cp -a "$TOOLF.bak-$NAME-$TS" "$TOOLF.rb" && mv -f "$TOOLF.rb" "$TOOLF"; else rm -f "$TOOLF"; fi
    if [[ "$RESTARTED_D" == 1 ]]; then
      sudo systemctl restart prepper-dashboard.service
      for i in $(seq 1 "$WD_N"); do sleep "$WD_S"; [[ "$(code "$B/")" == 200 ]] && break; done
    fi
    [[ -f "$DBF.bak-$NAME-$TS" ]] && { cmp -s "$DBF" "$DBF.bak-$NAME-$TS" && echo "  database.py = Sicherung ($(s16 "$DBF"))" || echo "  WARNUNG database.py ungleich Sicherung"; }
    echo "  SQLite-Sicherung (nicht zurueckgespielt, die Datenbank wurde durch dieses Skript nicht veraendert): ${LZB:-keine}"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
  }
  rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_DB" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
  mkdir -p "$TOOLD" || { echo "FEHLER: $TOOLD nicht anlegbar"; exit 1; }
  if [[ "$NEED_DB" == 1 ]]; then cp -a "$DBF" "$DBF.bak-$NAME-$TS"; prune_bak "$DBF"; fi
  if [[ "$NEED_TOOL" == 1 && "$TOOL_WAS" == 1 ]]; then cp -a "$TOOLF" "$TOOLF.bak-$NAME-$TS"; prune_bak "$TOOLF"; fi
  if [[ "$NEED_TOOL" == 1 ]]; then write_atomic "$W/lage_db_maint.py" "$TOOLF" 755 || { rb "tools/lage_db_maint.py nicht installierbar"; exit 1; }; fi
  if [[ "$NEED_DB" == 1 ]]; then
    MODE_DB=$(stat -c %a "$DBF.bak-$NAME-$TS")
    write_atomic "$W/database.py" "$DBF" "$MODE_DB" || { rb "database.py nicht installierbar"; exit 1; }
  fi
  echo "OK Dateien atomar ersetzt (Sicherungen *.bak-$NAME-$TS, behalten: letzte $KEEP_LAST)"
  if [[ "$NEED_DB" == 1 ]]; then
    RESTARTED_D=1
    T0D=$(date +%s)
    echo "Neustart prepper-dashboard (dort laeuft der Aufraeum-Faden mit der Wartung) - warte auf HTTP 200 (max 240 s) ..."
    sudo systemctl restart prepper-dashboard.service
    wait_dash || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
    PHASE=Pruefung
    wait_ready && echo "OK Dashboard fertig gestartet (erstes Voll-Update da)" || echo "HINWEIS Dashboard zeigt nach 200 s noch die Startseite - Pruefung laeuft trotzdem weiter"
    echo "warte auf die Meldung der Wartung im Journal (der Aufraeum-Faden meldet sich ca. 30 s nach dem Start, max 240 s) ..."
    jok=0
    for i in $(seq 1 "$JN"); do
      JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
      grep -qF "Wartung (relDb): bereit" <<< "$JD" && { jok=1; break; }
      sleep "$JS"
    done
    [[ "$jok" == 1 ]] && echo "OK Journal: $(grep -F "Wartung (relDb): bereit" <<< "$JD" | tail -1 | cut -c1-260)" || rbx "Journal ohne 'Wartung (relDb): bereit' (Aufraeum-Faden meldet sich nicht)"
  fi
fi
PHASE=Pruefung
RESTARTED_D=${RESTARTED_D:-0}; LZB=${LZB:-}; TOOL_WAS=${TOOL_WAS:-0}; T0D=${T0D:-$(( $(date +%s) - 3600 ))}
type rbx >/dev/null 2>&1 || rbx() { echo "FEHLER: $1"; exit 1; }
sleep 2
smoke_all || rbx "Rauchtest: eine Seite/API antwortet nicht mehr wie vorher"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
E2=$(grep -c -E 'Traceback|Wartung \(relDb\).*(FEHLER|Fehler)|quick_check BEFUND|Aufraeum-Faden war beendet' <<< "$JD" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal prepper-dashboard seit Neustart ohne Traceback, ohne Wartungsfehler, ohne quick_check-Befund" || { grep -E 'Traceback|Wartung \(relDb\)|quick_check BEFUND' <<< "$JD" | head -5 | cut -c1-240; rbx "$E2 Fehlerzeilen im Journal"; }
if [[ -f "$LZ" ]]; then
  "$SPY" - "$LZ" << 'PYQ' > "$W/lz1.txt" 2>&1 && echo "OK lagezentrum.db nachher: $(cat "$W/lz1.txt")" || { cat "$W/lz1.txt"; rbx "lagezentrum.db nach dem Neustart nicht in Ordnung"; }
import os, sqlite3, sys
p = sys.argv[1]
c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
q = c.execute("PRAGMA quick_check").fetchall()
assert [r[0] for r in q] == ["ok"], q
jm = c.execute("PRAGMA journal_mode").fetchone()[0]
assert str(jm).lower() == "wal", jm
v = c.execute("SELECT v FROM meta WHERE k='schema_version'").fetchone()
w = os.path.getsize(p + "-wal") if os.path.exists(p + "-wal") else 0
print("quick_check ok, journal_mode=%s, schema_version=%s, %.1f MB, WAL %.1f MB" % (jm, v[0] if v else "?", os.path.getsize(p) / 1048576.0, w / 1048576.0))
PYQ
  [[ -f "$LZ.maint.json" ]] && echo "OK Statusdatei $(basename "$LZ").maint.json vorhanden: $("$SPY" -c "import json,sys;d=json.load(open(sys.argv[1]));print('bereit seit', d.get('ready'), '| Checkpoints', d.get('ckpt_n'), '| quick_check', (d.get('qc') or {}).get('ok'))" "$LZ.maint.json" 2>/dev/null || echo "?")" || echo "HINWEIS Statusdatei $(basename "$LZ").maint.json noch nicht da (entsteht nach dem ersten quick_check, ca. 2 min nach dem Start)"
fi
for x in "${!SHA0[@]}"; do [[ "$(s16 "$DASH_DIR/$x")" == "${SHA0[$x]}" ]] && echo "OK $x unveraendert (${SHA0[$x]})" || rbx "$x hat sich veraendert"; done
echo "OK guards: relDb(database.py)=$(grep -c 'relDb (REL-07 + PERF-06)' "$DBF" || true)"
echo
echo "=== relDb FERTIG ($COMMIT_ARG) ==="
for x in "$DBF" "$TOOLF"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
[[ -f "$DBF.bak-$NAME-$TS" ]] && { echo "Rueckgaengig: cp -p $DBF.bak-$NAME-$TS $DBF   (danach: sudo systemctl restart prepper-dashboard)"; [[ "$TOOL_WAS" == 1 ]] || echo "              rm $TOOLF   (neues Werkzeug, optional)"; }
[[ -n "${LZB:-}" ]] && echo "SQLite-Sicherung vor dem Patch: $LZB (wurde nicht gebraucht; die Datenbank hat dieses Skript nie veraendert)"
echo "Wartung per Hand (lesend): python3 $TOOLF status"
echo "Die laufende Wartung zeigt retention_status()[maint] (z. B. in /api/sdr/live unter db.retention) und $(basename "$LZ").maint.json"
