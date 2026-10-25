#!/bin/bash
set -eEuo pipefail
# relClock (commit25b = commit25 mit Reparatur): der Selbsttest von lage_disk.py haengt nicht mehr vom echten Speicher ab (auf dem Pi scheiterte er an einer kleinen /tmp-tmpfs), Fehlerpfad zeigt immer die volle Ausgabe, neue Option diagnose (nur lesend: bash apply-relclock2.sh commit25b diagnose).
# relClock (commit25): REL-06 + REL-05 des Audits. Aendert NUR database.py (baut auf relDb/commit23 auf) und legt neu an: lage_clock.py (zentrale Uhr-Plausibilitaet clock_ok()), lage_disk.py (Stufenplan fuer knappen Speicher, nur melden).
#  - Aufraeum-Faden (database.py): loescht NICHTS, solange die Uhr unplausibel ist (vor 1.10.2026, nach einem Zeitsprung 15 min Haltezeit); fehlt lage_clock.py oder wirft es, wird wie bisher aufgeraeumt.
#    Dauern, quick_check-Zeitlimit und owns() des Aufraeum-Fadens nutzen time.monotonic() (kein Zeitsprung kann sie verfaelschen). Keine Aenderung an Tabellen/SQL.
#  - lage_disk.py: status/write/plan melden Stufe ok/warn/tight/critical (Exit 0-3); loescht NIE etwas; Reservedatei .alarm_reserve nur mit --ja (nicht automatisch angelegt); release --ja entfernt nur sie.
#  - dashboard.py, Bridges, SDR bleiben unberuehrt. Es wird nichts gesendet (kein Mesh, kein Telegram, kein Alarm).
# Basis streng (sha16): database.py 3f3aa054076bf70b (= Ergebnis von relDb/commit23) oder schon die neue Fassung. Die Vor-relDb-Fassung 431077d36822a090 -> STOP "erst commit23". Anderes = STOP mit Diff.
# Neustart: nur prepper-dashboard (dort laeuft der Aufraeum-Faden). Sicherungen: database.py + neue Dateien (letzte 3), SQLite-Sicherung der Datenbank vor der Aenderung (letzte 3). Option "trocken": nur pruefen/testen, nichts aendern.
COMMIT_ARG="${1:-unbekannt}"
OPT="${2:-}"
NAME=relclock
DASH_DIR="/home/fmg/prepper-dashboard"
SPY=/usr/bin/python3
if [[ "${SYSTEM_TEST:-}" == 1 ]]; then DASH_DIR="${SY_DASH:?}"; fi    # nur fuer den Sandbox-Test dieses Skripts
VPY="$DASH_DIR/venv/bin/python"
DBF="$DASH_DIR/database.py"
CLKF="$DASH_DIR/lage_clock.py"
DSKF="$DASH_DIR/lage_disk.py"
LZ="$DASH_DIR/lagezentrum.db"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/relclock-apply
KEEP_LAST=3
PRE_RELDB16="431077d36822a090"
KNOWN_DB16="3f3aa054076bf70b"
NEW_DB16="01f7abf0c13b7acd"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
echo "=== relClock apply ($COMMIT_ARG)${OPT:+ [$OPT]}: Uhr-Plausibilitaet + Stufenplan Speicher (database.py, lage_clock.py, lage_disk.py), Dashboard-Port $PORT ==="
umask 077
rm -rf "$W" && mkdir -p "$W/base" "$W/sbx"
EXPECT_DB="01f7abf0c13b7acdeea24cf4fb1b47b71941bc508f3069e2e5d49abb6e0216fa"
cat > "$W/database.py" << 'RCK_DB_EOF'
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
RCK_DB_EOF
EXPECT_CLK="c909aea1148518fe288d25e997580e716ea11d4fd2123fa644e053b7fc763953"
cat > "$W/lage_clock.py" << 'RCK_CLK_EOF'
#!/usr/bin/env python3
"""lage_clock.py (relClock, REL-06): zentrale Uhr-Plausibilitaet fuer das Lagezentrum. Sendet nichts, schreibt nichts, startet keinen Faden.

  clock_ok()      True = Wanduhr darf fuer Loesch-/Ablauffristen benutzt werden (Aufraeumen ist erlaubt)
  clock_state()   (ok, Grund) - Grund ist ein kurzer deutscher Text
  status()        Dict fuer Anzeige/Journal (ok, Grund, Wanduhr, plausibel, chrony, letzter Sprung)
  mono()          time.monotonic() (fuer Intervalle/Haltezeiten, die nicht gespeichert werden)

Regeln (konservativ, "Fail-safe": im Zweifel NICHT loeschen, aber auch nicht dauerhaft blockieren):
  1. Wanduhr vor MIN_EPOCH (1.10.2026 UTC = Baudatum dieses Stands) -> nicht plausibel (Pi ohne RTC/ohne gespeicherte Zeit steht oft auf 1970 oder Kernel-Baudatum).
  2. Zeitsprung: weicht die Wanduhr gegenueber der monotonen Uhr um mehr als JUMP_TOL_S ab (z. B. chrony makestep, manuelles Stellen),
     gilt die Uhr HOLD_S (15 min) als nicht ok - danach wieder ok.
  3. Sonst ok. Ist chrony da und meldet "nicht synchronisiert", bleibt es ok (Grund "plausibel, nicht synchronisiert"), sonst wuerde das Aufraeumen
     im Krisenfall ohne Netz dauerhaft ausfallen und die Platte volllaufen (REL-05). Eine gespeicherte alte Zeit (fake-hwclock) ist "zu frueh":
     Fristen greifen dann spaeter, nicht frueher - das ist die sichere Richtung.
chrony wird hoechstens alle 60 s per chronyc -c tracking (Argumentliste, 3 s Zeitlimit, nur lesend) befragt; fehlt chronyc, ist der Zustand "unbekannt".
"""
import calendar
import subprocess
import threading
import time

MIN_EPOCH = calendar.timegm((2026, 10, 1, 0, 0, 0))   # 1790812800
MAX_EPOCH = calendar.timegm((2100, 1, 1, 0, 0, 0))
JUMP_TOL_S = 5.0
HOLD_S = 900.0
CHRONY_CACHE_S = 60.0

_now = time.time
_mono = time.monotonic
_lock = threading.Lock()
_st = {"w0": None, "m0": None, "jump_until": None, "jump_at": None, "jump_s": None, "chrony": None, "chrony_m": None, "last": None}


def mono():
    return _mono()


def _chrony_raw():
    """-> True (synchronisiert), False (nicht synchronisiert), None (unbekannt). Nur lesend, Argumentliste."""
    try:
        p = subprocess.run(["chronyc", "-c", "tracking"], capture_output=True, text=True, timeout=3)
        if p.returncode != 0 or not (p.stdout or "").strip():
            return None
        f = (p.stdout or "").strip().splitlines()[0].split(",")
        ref = f[0].strip()
        leap = f[-1].strip().lower()
        if ref in ("", "0", "00000000") or "not synchronised" in leap or "not synchronized" in leap:
            return False
        return True
    except Exception:
        return None


_chrony_fn = _chrony_raw


def _chrony(m):
    c = _st["chrony_m"]
    if c is None or m - c >= CHRONY_CACHE_S or m < c:
        _st["chrony"] = _chrony_fn()
        _st["chrony_m"] = m
    return _st["chrony"]


def clock_state():
    """(ok, Grund). Wirft nie."""
    try:
        with _lock:
            w, m = _now(), _mono()
            if _st["w0"] is not None:
                d = (w - _st["w0"]) - (m - _st["m0"])
                if abs(d) > JUMP_TOL_S:
                    _st["jump_until"], _st["jump_at"], _st["jump_s"] = m + HOLD_S, w, round(d, 1)
            _st["w0"], _st["m0"] = w, m
            if not (MIN_EPOCH <= w < MAX_EPOCH):
                r = (False, "Uhr unplausibel (Wanduhr %s, vor dem Baudatum oder zu weit in der Zukunft)" % time.strftime("%Y-%m-%d %H:%M", time.gmtime(max(0, min(w, 4e9)))))
            elif _st["jump_until"] is not None and m < _st["jump_until"]:
                r = (False, "Zeitsprung erkannt (%+.0f s), Haltezeit noch %d s" % (_st["jump_s"], int(_st["jump_until"] - m)))
            else:
                s = _chrony(m)
                r = (True, "plausibel, synchronisiert" if s is True else ("plausibel, nicht synchronisiert" if s is False else "plausibel (chrony unbekannt)"))
            _st["last"] = r
            return r
    except Exception as e:
        return (True, "Pruefung fehlgeschlagen (%s) - nicht blockieren" % str(e)[:60])   # nie wegen eines Fehlers im Pruefer das Aufraeumen/den Alarmpfad stoppen


def clock_ok():
    return clock_state()[0]


def status():
    ok, why = clock_state()
    w = _now()
    return {"ok": ok, "why": why, "wall": int(w), "plausible": MIN_EPOCH <= w < MAX_EPOCH, "min_epoch": MIN_EPOCH,
            "chrony": _st["chrony"], "jump_s": _st["jump_s"], "jump_at": (int(_st["jump_at"]) if _st["jump_at"] else None),
            "hold_s": HOLD_S, "jump_tol_s": JUMP_TOL_S}


def _reset():
    for k in _st:
        _st[k] = None


def selftest():
    global _now, _mono, _chrony_fn
    sv = (_now, _mono, _chrony_fn)
    t = {"w": float(MIN_EPOCH + 1000), "m": 1000.0, "ch": True}
    _now, _mono, _chrony_fn = (lambda: t["w"]), (lambda: t["m"]), (lambda: t["ch"])
    try:
        def adv(s, wall_extra=0.0):
            t["m"] += s
            t["w"] += s + wall_extra
        _reset()
        ok, why = clock_state()
        assert ok and "synchronisiert" in why, (ok, why)
        t["ch"] = False; adv(120)
        ok, why = clock_state()
        assert ok and "nicht synchronisiert" in why, (ok, why)               # plausibel, aber ohne Sync: weiter erlaubt (kein Dauerblock im Krisenfall)
        t["ch"] = None; adv(120)
        assert clock_state() == (True, "plausibel (chrony unbekannt)")
        # kleine Abweichung (Slew) = kein Sprung
        adv(600, 2.0)
        assert clock_ok() is True
        # Sprung nach vorn (makestep nach langem Ausfall)
        adv(60, 86400 * 3)
        ok, why = clock_state()
        assert not ok and "Zeitsprung" in why, (ok, why)
        adv(300)
        assert clock_ok() is False                                          # Haltezeit laeuft
        adv(HOLD_S)
        assert clock_ok() is True, clock_state()                            # danach wieder ok
        # Sprung nach hinten
        adv(60, -7200)
        assert clock_ok() is False
        adv(HOLD_S + 1)
        assert clock_ok() is True
        # Uhr vor dem Baudatum (Pi ohne RTC, 1970)
        t["w"] = 12345.0; adv(600)
        ok, why = clock_state()
        assert not ok and "unplausibel" in why, (ok, why)
        adv(HOLD_S + 1)
        assert clock_ok() is False                                          # bleibt unplausibel, auch ohne Sprung
        # Uhr wird gestellt (Sprung auf plausibel) -> erst nach Haltezeit ok
        t["w"] = float(MIN_EPOCH + 5000); t["m"] += 10
        ok, why = clock_state()
        assert not ok and "Zeitsprung" in why, (ok, why)
        adv(HOLD_S + 1)
        assert clock_ok() is True
        # Zukunft
        t["w"] = float(MAX_EPOCH + 10); t["m"] += 10
        assert clock_ok() is False
        # Fehler im chrony-Pruefer blockiert nichts
        _reset(); t["w"] = float(MIN_EPOCH + 1000)
        def boom():
            raise RuntimeError("x")
        _chrony_fn = boom
        ok, why = clock_state()
        assert ok is True, (ok, why)
        s = status()
        assert s["ok"] is True and s["plausible"] is True and "why" in s
    finally:
        _now, _mono, _chrony_fn = sv
        _reset()
    # echte Uhr dieses Rechners (nur Anzeige)
    r = clock_state()
    return "lage_clock selftest ok (Sprung vor/zurueck, unplausible Uhr, ohne chrony, Fehler im Pruefer); echte Uhr hier: %s" % ("ok" if r[0] else r[1])


if __name__ == "__main__":
    import json
    import sys
    if "--status" in sys.argv[1:]:
        print(json.dumps(status(), ensure_ascii=False))
    else:
        print(selftest())
RCK_CLK_EOF
EXPECT_DSK="9a5cbc0e3dbf9c139739cba988f820ea6034e2154d12501416dc52f430e133fa"
cat > "$W/lage_disk.py" << 'RCK_DSK_EOF'
#!/usr/bin/env python3
"""lage_disk.py (relClock, REL-05): Stufenplan fuer knappen Speicher. NUR MELDEN/ANZEIGEN - loescht nie etwas, sendet nichts (kein Mesh, kein Telegram, kein Alarm).

  python3 lage_disk.py status [--json]        Stufe (ok/warn/tight/critical), freier Platz, Inodes; Exit 0/1/2/3 = ok/warn/tight/critical
  python3 lage_disk.py write                  wie status, schreibt zusaetzlich lage_disk.json (atomar, im Projektordner) und meldet Stufenwechsel als Zeile
  python3 lage_disk.py plan                   zeigt den Stufenplan und die groessten Platzfresser (nur lesend, mit Zeitlimit)
  python3 lage_disk.py reserve [--mb 200] --ja   legt die Reservedatei .alarm_reserve an (echt belegter Platz), nur wenn danach noch Stufe ok/warn bleibt
  python3 lage_disk.py release --ja           entfernt NUR die Reservedatei (Notfall: gibt der Datenbank/dem Alarmpfad Luft)
Stufen (Schwellen aus freiem Platz und Belegung; grosse Platten melden nicht schon bei 80 % Belegung):
  critical: frei < 1 GiB oder freie Inodes < 2 %
  tight:    frei < 5 GiB (= Archiv-Pausengrenze MIN_FREE) oder (Belegung >= 90 % und frei < 32 GiB)
  warn:     frei < 15 GiB oder (Belegung >= 80 % und frei < 64 GiB)
Plan je Stufe (Beschluesse zum Loeschen trifft Frank - dieses Programm tut es nicht):
  warn      anzeigen/melden, Platzfresser ansehen (plan)
  tight     nicht-kritische Schreiber stoppen (jsonl-Verlaeufe, Debug-Logs, Archiv: archive_store pausiert schon < 5 GiB); Loesch-KANDIDATEN: rotierte Logs *.1,
            .bak-* ueber die letzten 3 hinaus, alte Sicherungen - nur nach ausdruecklicher Regel/Freigabe
  critical  nur noch Alarm-Datenbank und Alarm-Protokoll; Reservedatei freigeben (release --ja)
Umgebung: LAGE_DISK_DIR (Projektordner, Standard: Ordner dieser Datei), LAGE_DISK_PATH (Dateisystem-Pruefpfad, Standard: Projektordner).
"""
import json
import os
import sys
import time

GIB = 1024 ** 3
LEVELS = ("ok", "warn", "tight", "critical")
RESERVE_NAME = ".alarm_reserve"
DEFAULT_RESERVE_MB = 200
CACHE_S = 30.0
_cache = {"t": None, "v": None}
_SV = os.statvfs   # Dateisystem-Abfrage; nur der Selbsttest tauscht sie gegen eine Attrappe (der Selbsttest darf nie vom echten Speicher abhaengen)
EXT_DIRS = (("Sicherungen /home/fmg/prepper-backups", "/home/fmg/prepper-backups"), ("Journal /var/log/journal", "/var/log/journal"))


def level_for(free_b, total_b, ifree=None, itotal=None):
    """Reine Funktion: -> (Stufe, Gruende)."""
    pct = 100.0 * (total_b - free_b) / total_b if total_b else 0.0
    why = []
    lv = 0
    ipct = (100.0 * ifree / itotal) if (ifree is not None and itotal) else None
    if free_b < 1 * GIB or (ipct is not None and ipct < 2.0):
        lv = 3
        why.append("frei %.1f GiB" % (free_b / GIB) if free_b < 1 * GIB else "freie Inodes %.1f %%" % ipct)
    elif free_b < 5 * GIB or (pct >= 90 and free_b < 32 * GIB):
        lv = 2
        why.append("frei %.1f GiB, Belegung %.0f %%" % (free_b / GIB, pct))
    elif free_b < 15 * GIB or (pct >= 80 and free_b < 64 * GIB):
        lv = 1
        why.append("frei %.1f GiB, Belegung %.0f %%" % (free_b / GIB, pct))
    return LEVELS[lv], why


def project_dir():
    return os.path.abspath(os.environ.get("LAGE_DISK_DIR") or os.path.dirname(os.path.abspath(__file__)))


def reserve_path():
    return os.path.join(project_dir(), RESERVE_NAME)


def reserve_info():
    p = reserve_path()
    try:
        st = os.stat(p)
        return {"present": True, "mb": round(st.st_size / 1048576.0), "alloc_mb": round(st.st_blocks * 512 / 1048576.0)}
    except OSError:
        return {"present": False, "mb": 0, "alloc_mb": 0}


def read(path=None, _statvfs=None):
    path = path or os.environ.get("LAGE_DISK_PATH") or project_dir()
    s = (_statvfs or _SV)(path)
    free_b, total_b = s.f_bavail * s.f_frsize, s.f_blocks * s.f_frsize
    lv, why = level_for(free_b, total_b, s.f_favail, s.f_files)
    return {"t": int(time.time()), "level": lv, "why": why, "free_gib": round(free_b / GIB, 2), "total_gib": round(total_b / GIB, 1),
            "pct": round(100.0 * (total_b - free_b) / total_b, 1) if total_b else None,
            "inode_free_pct": round(100.0 * s.f_favail / s.f_files, 1) if s.f_files else None, "reserve": reserve_info(), "path": path}


def level(path=None):
    """Fuer andere Module: Stufe als Text, hoechstens alle 30 s neu gelesen (billig). Fehler -> 'ok' (nie den Aufrufer stoeren)."""
    try:
        m = time.monotonic()
        if _cache["t"] is None or m - _cache["t"] >= CACHE_S or m < _cache["t"]:
            _cache["v"] = read(path)["level"]
            _cache["t"] = m
        return _cache["v"]
    except Exception:
        return "ok"


def _du(path, budget_s=2.0, depth=2):
    """Groesse (Bytes) mit Zeitlimit und Tiefenbegrenzung, ohne Symlinks, nie Fehler."""
    end = time.monotonic() + budget_s
    total = 0
    stack = [(path, 0)]
    while stack and time.monotonic() < end:
        p, d = stack.pop()
        try:
            with os.scandir(p) as it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue
                        if e.is_file(follow_symlinks=False):
                            total += e.stat(follow_symlinks=False).st_blocks * 512
                        elif e.is_dir(follow_symlinks=False) and d < depth:
                            stack.append((e.path, d + 1))
                    except OSError:
                        pass
        except OSError:
            pass
    return total


def consumers(limit=8):
    d = project_dir()
    out = []
    try:
        with os.scandir(d) as it:
            for e in it:
                try:
                    if e.is_file(follow_symlinks=False):
                        out.append((e.stat(follow_symlinks=False).st_blocks * 512, e.name))
                except OSError:
                    pass
    except OSError:
        pass
    out.sort(reverse=True)
    res = [(n, b) for b, n in out[:limit]]
    bak = sum(b for b, n in out if ".bak-" in n)
    nbak = sum(1 for b, n in out if ".bak-" in n)
    ext = []
    for label, p in EXT_DIRS:
        if os.path.isdir(p):
            try:
                os.scandir(p).close()
                ext.append((label, _du(p)))
            except OSError:
                ext.append((label, None))
    return res, (nbak, bak), ext


def human(b):
    return "%.1f MiB" % (b / 1048576.0) if b < GIB else "%.2f GiB" % (b / GIB)


def cmd_status(js=False, write=False):
    r = read()
    prev = None
    jp = os.path.join(project_dir(), "lage_disk.json")
    if write:
        try:
            prev = json.load(open(jp)).get("level")
        except Exception:
            prev = None
        tmp = jp + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(r, f, ensure_ascii=False)
        os.replace(tmp, jp)
    if js:
        print(json.dumps(r, ensure_ascii=False))
    else:
        print("Speicher %s: Stufe %s - frei %.1f GiB von %.1f GiB (Belegung %s %%), freie Inodes %s %%, Reserve %s%s" % (
            r["path"], r["level"].upper(), r["free_gib"], r["total_gib"], r["pct"], r["inode_free_pct"],
            ("%d MB belegt" % r["reserve"]["alloc_mb"]) if r["reserve"]["present"] else "nicht angelegt", (" | " + "; ".join(r["why"])) if r["why"] else ""))
    if write and prev is not None and prev != r["level"]:
        print("STUFENWECHSEL %s -> %s (%s)" % (prev, r["level"], ", ".join(r["why"]) or "ok"))
    return LEVELS.index(r["level"])


def cmd_plan():
    r = read()
    print("Stufe jetzt: %s (frei %.1f GiB, Belegung %s %%)" % (r["level"].upper(), r["free_gib"], r["pct"]))
    print("Plan je Stufe" + __doc__.split("Plan je Stufe")[1].split("Umgebung:")[0].rstrip())
    res, bak, ext = consumers()
    print("Groesste Dateien im Projektordner (belegter Platz):")
    for n, b in res:
        print("  %-40s %s" % (n, human(b)))
    print("Sicherungsdateien *.bak-* im Projektordner: %d Stueck, %s (Kandidaten ueber die letzten 3 hinaus - nur nach Freigabe)" % (bak[0], human(bak[1])))
    for label, b in ext:
        print("%s: %s" % (label, "nicht lesbar (Rechte) - mit sudo du -sh pruefen" if b is None else human(b) + " (Tiefe 2, Zeitlimit 2 s)"))
    return 0


def cmd_reserve(mb, ja):
    p = reserve_path()
    if not ja:
        print("Nichts getan: ohne --ja wird keine Reservedatei angelegt. Waere: %s mit %d MB." % (p, mb))
        return 2
    if os.path.exists(p):
        print("Reservedatei gibt es schon: %s (%s)" % (p, reserve_info()))
        return 0
    r = read()
    after = r["free_gib"] - mb / 1024.0
    lv, _ = level_for(int(after * GIB), int(r["total_gib"] * GIB), None, None)
    if LEVELS.index(lv) >= 2:
        print("STOP: danach waeren nur noch %.1f GiB frei (Stufe %s) - Reserve wird nicht angelegt." % (after, lv))
        return 2
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        try:
            os.posix_fallocate(fd, 0, mb * 1048576)
        except (OSError, AttributeError):   # Dateisystem ohne fallocate: Platz mit echten Nullbytes belegen (der Platz soll wirklich reserviert sein)
            os.lseek(fd, 0, os.SEEK_SET)
            blk = b"\0" * 1048576
            for _ in range(mb):
                os.write(fd, blk)
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        os.unlink(p)
        raise
    os.close(fd)
    print("Reservedatei angelegt: %s (%s)" % (p, reserve_info()))
    return 0


def cmd_release(ja):
    p = reserve_path()
    if not ja:
        print("Nichts getan: ohne --ja wird nichts entfernt. Wuerde entfernen: %s" % p)
        return 2
    if os.path.basename(p) != RESERVE_NAME or not os.path.isfile(p) or os.path.islink(p):
        print("Keine Reservedatei: %s" % p)
        return 1
    os.unlink(p)
    print("Reservedatei entfernt: %s - Platz frei fuer Datenbank/Alarmpfad" % p)
    return 0


def selftest():
    """Selbsttest: haengt NICHT vom echten Rechner ab (Speicherstand, /tmp als kleine tmpfs, /home, Sicherungsordner, Journal) - Dateisystem und
    Zusatzordner sind durch Attrappen ersetzt, alle Dateien liegen in einem eigenen Temp-Ordner."""
    global _SV, EXT_DIRS
    import contextlib
    import io
    import tempfile
    out = io.StringIO()
    L = lambda f, t, i=None, it=None: level_for(int(f * GIB), int(t * GIB), i, it)[0]

    class V:
        def __init__(s, free, total, fav=1000, files=1000):
            s.f_bavail, s.f_frsize, s.f_blocks, s.f_favail, s.f_files = int(free * GIB / 4096), 4096, int(total * GIB / 4096), fav, files
    fake = {"free": 100.0, "total": 200.0}
    sv0, ext0 = _SV, EXT_DIRS
    assert L(500, 1000) == "ok" and L(200, 1000) == "ok"                # grosse Platte: 80 % Belegung bei 200 GiB frei = ok
    assert L(25, 100) == "ok" and L(70, 1000) == "ok"                   # 75 % belegt bzw. 93 % belegt mit 70 GiB frei
    assert L(14, 100) == "warn" and L(15.1, 100) == "warn"              # 86 %/85 % belegt, frei < 64 GiB
    assert L(40, 400) == "warn"                                         # 90 % belegt, aber 40 GiB frei (>= 32)
    assert L(30, 400) == "tight" and L(5.1, 100) == "tight" and L(4.9, 100) == "tight"
    assert L(0.9, 100) == "critical" and L(1.1, 100) == "tight"
    assert L(50, 100, 10, 1000) == "critical"                           # Inodes < 2 %
    assert L(50, 100, 100, 1000) == "ok"
    assert level_for(0, 0)[0] == "critical"
    d = tempfile.mkdtemp(prefix="lzdisk-")
    old = os.environ.get("LAGE_DISK_DIR")
    os.environ["LAGE_DISK_DIR"] = d
    _redir = contextlib.redirect_stdout(out)
    _redir.__enter__()
    try:
        _SV = lambda p: V(fake["free"], fake["total"])      # echtes statvfs nie benutzen (auf dem Pi ist /tmp oft eine kleine tmpfs: dort waere "frei" unter der Reserve-Grenze)
        EXT_DIRS = ()
        r = read(d, _statvfs=lambda p: V(3, 100))
        assert r["level"] == "tight" and r["pct"] == 97.0, r
        open(os.path.join(d, "big.json"), "wb").write(b"x" * 100000)
        open(os.path.join(d, "x.py.bak-t-1"), "wb").write(b"x" * 5000)
        res, bak, ext = consumers()
        assert res[0][0] == "big.json" and bak[0] == 1
        before = sorted(os.listdir(d))
        assert cmd_status(js=True) in (0, 1, 2, 3)
        assert sorted(os.listdir(d)) == before                           # status schreibt nichts
        cmd_status(write=True)
        assert os.path.isfile(os.path.join(d, "lage_disk.json")) and not os.path.exists(os.path.join(d, "lage_disk.json.tmp"))
        assert cmd_reserve(1, False) == 2 and not os.path.exists(reserve_path())      # ohne --ja nichts
        for fr, tot in ((3, 100), (6, 100), (0.5, 100), (30, 400)):                      # knapper Platz (tight/critical): Reserve wird verweigert, nichts angelegt
            fake["free"], fake["total"] = fr, tot
            assert cmd_reserve(1, True) == 2 and not os.path.exists(reserve_path()), (fr, tot)
        fake["free"], fake["total"] = 100.0, 200.0
        assert cmd_release(False) == 2
        assert cmd_reserve(1, True) == 0 and reserve_info()["present"] and reserve_info()["mb"] == 1
        assert cmd_reserve(1, True) == 0                                  # idempotent
        assert os.stat(reserve_path()).st_mode & 0o777 == 0o600
        assert cmd_release(True) == 0 and not reserve_info()["present"]
        assert cmd_release(True) == 1
        assert os.path.exists(os.path.join(d, "big.json"))                # nie andere Dateien angefasst
        _cache["t"] = None
        assert level() in LEVELS
        assert cmd_plan() == 0
    finally:
        _SV, EXT_DIRS = sv0, ext0
        _redir.__exit__(None, None, None)
        for n in os.listdir(d):
            os.unlink(os.path.join(d, n))
        os.rmdir(d)
        if old is None:
            os.environ.pop("LAGE_DISK_DIR", None)
        else:
            os.environ["LAGE_DISK_DIR"] = old
    return "lage_disk selftest ok (Stufen, Inodes, status schreibt nichts, Reserve nur mit --ja, release nur die Reservedatei)"


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        raise SystemExit(0 if a else 2)
    if a[0] == "--selftest":
        print(selftest())
    elif a[0] == "status":
        raise SystemExit(cmd_status(js="--json" in a))
    elif a[0] == "write":
        raise SystemExit(cmd_status(write=True))
    elif a[0] == "plan":
        raise SystemExit(cmd_plan())
    elif a[0] == "reserve":
        mb = DEFAULT_RESERVE_MB
        if "--mb" in a:
            mb = int(a[a.index("--mb") + 1])
        raise SystemExit(cmd_reserve(mb, "--ja" in a))
    elif a[0] == "release":
        raise SystemExit(cmd_release("--ja" in a))
    else:
        print(__doc__)
        raise SystemExit(2)
RCK_DSK_EOF
EXPECT_GUARD="1f981bf26f55db84714b3a31289586645bc4a1b376281bd4e2e4f54be2bf0797"
cat > "$W/guard_relclock.py" << 'RCK_GUARD_EOF'
#!/usr/bin/env python3
"""guard_relclock.py - AST-Pruefung fuer relClock (database.py, lage_clock.py, lage_disk.py) samt Mutationstest.
  check DATABASE_PY CLOCK_PY DISK_PY BASE_DB_PY     -> Exit 0 = alle Pruefungen ok
  mutate BASE_DB_PY EDITS_PY CLOCK_PY DISK_PY       -> jede Mutation einzeln, jede muss erkannt werden
"""
import ast
import importlib.util
import pathlib
import re
import sys

TOK = "VAC" + "UUM"
DML = re.compile(r"\b(DELETE|DROP|UPDATE|INSERT|ALTER|REPLACE INTO)\b", re.I)
BAD_MODS = {"socket", "requests", "urllib", "http", "ftplib", "smtplib", "shutil", "ctypes", "pickle", "marshal"}


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


def calls(node, attr_pairs=(), names=()):
    out = []
    for n in ast.walk(node):
        if isinstance(n, ast.Call):
            f = n.func
            if isinstance(f, ast.Name) and f.id in names:
                out.append(n)
            elif isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and (f.value.id, f.attr) in attr_pairs:
                out.append(n)
    return out


def parents(tree):
    p = {}
    for n in ast.walk(tree):
        for c in ast.iter_child_nodes(n):
            p[id(c)] = n
    return p


def guarded_by_ckok(fn, call, par):
    """Aufruf liegt unter 'if ck_ok:' ODER in einer Schleife, deren erste Anweisung 'if not ck_ok: break' ist."""
    n = call
    while id(n) in par:
        n = par[id(n)]
        if isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == "ck_ok":
            return True
        if isinstance(n, ast.For) and n.body and isinstance(n.body[0], ast.If):
            t = n.body[0].test
            if isinstance(t, ast.UnaryOp) and isinstance(t.op, ast.Not) and isinstance(t.operand, ast.Name) and t.operand.id == "ck_ok" \
                    and n.body[0].body and isinstance(n.body[0].body[0], ast.Break):
                return True
        if n is fn:
            break
    return False


def check_db(src, base_src):
    errs = []
    try:
        t = ast.parse(src)
        b = ast.parse(base_src)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    top = {n.name for n in t.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))}
    for f in ("_clock_state", "_clock_gate", "selftest_clock"):
        if f not in top:
            errs.append("fehlt: %s" % f)
    for n in b.body:
        if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name not in top:
            errs.append("Basis-Funktion entfernt: %s" % n.name)
    if "relClock" not in (ast.get_docstring(t) or ""):
        errs.append("Modul-Docstring ohne relClock")
    # Import von lage_clock nur im try/except Exception
    ok_imp = False
    for n in t.body:
        if isinstance(n, ast.Try) and any(isinstance(x, ast.Import) and any(a.name == "lage_clock" for a in x.names) for x in n.body) \
                and any(h.type is not None and isinstance(h.type, ast.Name) and h.type.id == "Exception" and any(isinstance(s, ast.Assign) and isinstance(s.value, ast.Constant) and s.value.value is None for s in h.body) for h in n.handlers):
            ok_imp = True
    if not ok_imp:
        errs.append("import lage_clock nicht als try/except Exception mit Rueckfall None")
    cs = seg(src, fdef(t, "_clock_state"))
    if 'return True, "lage_clock fehlt' not in cs or 'return True, "Uhr-Pruefer Fehler' not in cs or "_lclk.clock_state()" not in cs:
        errs.append("_clock_state: Rueckfall ohne Blockade (fehlender/defekter Pruefer = True) nicht wie vorgesehen")
    # Aufraeum-Faden: jedes Loeschen unter der Uhr-Pruefung
    run = fdef(t, "run", "_Retention")
    if run is None:
        return errs + ["_Retention.run fehlt"]
    rs = seg(src, run)
    if "_clock_gate(self)" not in rs or 'out["clock_pause"]' not in rs:
        errs.append("run: Uhr-Pruefung/Meldung fehlt")
    par = parents(run)
    dels = calls(run, names=("cleanup", "cleanup_t2", "cleanup_t3", "fn"))
    if len(dels) < 3:
        errs.append("run: weniger Aufraeum-Aufrufe als erwartet (%d)" % len(dels))
    for c in dels:
        if not guarded_by_ckok(run, c, par):
            errs.append("run: Aufruf %s (Zeile %d) nicht durch ck_ok geschuetzt" % (ast.unparse(c.func), c.lineno))
    if calls(run, attr_pairs=(("time", "time"),)) and len(calls(run, attr_pairs=(("time", "time"),))) != 1:
        errs.append("run: time.time() ausser fuer 'now' benutzt")
    if "t0 = time.monotonic()" not in rs or "self.mono_ref = time.monotonic()" not in rs:
        errs.append("run: Dauer/Lebenszeichen nicht monoton")
    # retention_watch: Pruefung vor dem direkten Aufraeumen
    w = fdef(t, "retention_watch")
    ws = seg(src, w)
    i_gate, i_clean = ws.find("_clock_state()"), ws.find("out = cleanup(now, path)")
    if not (0 <= i_gate < i_clean) or '"clock_pause"' not in ws:
        errs.append("retention_watch: Uhr-Pruefung fehlt oder steht nicht vor cleanup")
    # monotone Zeit
    for fn, cls in (("checkpoint", None), ("quick_check", None), ("owns", "_Retention")):
        f = fdef(t, fn, cls)
        if f is None or calls(f, attr_pairs=(("time", "time"),)):
            errs.append("%s: time.time() statt monotonic (oder fehlt)" % fn)
    if "time.monotonic() > deadline" not in seg(src, fdef(t, "quick_check")):
        errs.append("quick_check: Zeitlimit nicht monoton")
    if "time.monotonic() - self.mono_ref" not in seg(src, fdef(t, "owns", "_Retention")):
        errs.append("owns: nicht monoton")
    ini = seg(src, fdef(t, "__init__", "_Retention"))
    for a in ("self.clock_last = None", "self.clock_why = None", "self.mono_ref = time.monotonic()"):
        if a not in ini:
            errs.append("__init__: %s fehlt" % a)
    if "self.mono_ref = time.monotonic()" not in seg(src, fdef(t, "start", "_Retention")):
        errs.append("start: mono_ref nicht gesetzt")
    if '"clock"' not in seg(src, fdef(t, "status", "_Retention")):
        errs.append("status ohne clock")
    main = src.split('if __name__ == "__main__":')[-1]
    if "print(selftest_clock())" not in main:
        errs.append("selftest_clock nicht im __main__")
    # nichts Neues ausser lage_clock: keine Netz-/Prozess-Importe, keine neuen DML-Strings, kein VACUUM
    new_imp = set()
    for n in ast.walk(t):
        if isinstance(n, ast.Import):
            new_imp |= {a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom):
            new_imp.add((n.module or "").split(".")[0])
    old_imp = set()
    for n in ast.walk(b):
        if isinstance(n, ast.Import):
            old_imp |= {a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom):
            old_imp.add((n.module or "").split(".")[0])
    if new_imp - old_imp - {"lage_clock"}:
        errs.append("neue Importe: %s" % sorted(new_imp - old_imp))
    def dml(tree):
        doc = tree.body[0].value if tree.body and isinstance(tree.body[0], ast.Expr) else None   # Modul-Docstring ist Text, kein SQL
        return sorted(c.value for c in ast.walk(tree) if isinstance(c, ast.Constant) and c is not doc and isinstance(c.value, str) and DML.search(c.value))
    if dml(t) != dml(b):
        errs.append("SQL-Aenderungen (DELETE/UPDATE/...) gegenueber der Basis")
    for c in ast.walk(t):
        if isinstance(c, ast.Constant) and isinstance(c.value, str) and c.value.strip().split(" ")[0].upper() == TOK:
            errs.append("VACUUM-Anweisung gefunden")
    return errs


def check_clock(src):
    errs = []
    try:
        t = ast.parse(src)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    imp = set()
    for n in ast.walk(t):
        if isinstance(n, ast.Import):
            imp |= {a.name for a in n.names}
        elif isinstance(n, ast.ImportFrom):
            imp.add(n.module or "")
    if imp - {"calendar", "subprocess", "threading", "time", "json", "sys"}:
        errs.append("unerwartete Importe: %s" % sorted(imp))
    for c in ast.walk(t):
        if isinstance(c, ast.Call):
            f = c.func
            if isinstance(f, ast.Name) and f.id in ("open", "exec", "eval", "compile", "__import__"):
                errs.append("verbotener Aufruf %s in Zeile %d" % (f.id, c.lineno))
            if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "os":
                errs.append("os.* in Zeile %d" % c.lineno)
            for kw in c.keywords:
                if kw.arg == "shell":
                    errs.append("shell= in Zeile %d" % c.lineno)
    subs = [c for c in ast.walk(t) if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and isinstance(c.func.value, ast.Name) and c.func.value.id == "subprocess"]
    if len(subs) != 1 or ast.unparse(subs[0].args[0]) != "['chronyc', '-c', 'tracking']":
        errs.append("subprocess nur als chronyc -c tracking (Argumentliste) erlaubt")
    f = fdef(t, "_chrony_raw")
    if f is None or "timeout=3" not in seg(src, f):
        errs.append("chronyc ohne Zeitlimit 3 s")
    for const in ("MIN_EPOCH = calendar.timegm((2026, 10, 1, 0, 0, 0))", "JUMP_TOL_S = 5.0", "HOLD_S = 900.0", "CHRONY_CACHE_S = 60.0", "MAX_EPOCH = calendar.timegm((2100, 1, 1, 0, 0, 0))"):
        if const not in src:
            errs.append("Konstante geaendert/fehlt: %s" % const)
    cs = seg(src, fdef(t, "clock_state"))
    for need in ("abs(d) > JUMP_TOL_S", "MIN_EPOCH <= w < MAX_EPOCH", "m < _st[\"jump_until\"]", "m + HOLD_S", "return (True, \"Pruefung fehlgeschlagen", "_chrony(m)"):
        if need not in cs:
            errs.append("clock_state: %s fehlt" % need)
    if "selftest" not in {n.name for n in t.body if isinstance(n, ast.FunctionDef)}:
        errs.append("selftest fehlt")
    return errs


def check_disk(src):
    errs = []
    try:
        t = ast.parse(src)
    except SyntaxError as e:
        return ["Syntaxfehler: %s" % e]
    imp = set()
    for n in ast.walk(t):
        if isinstance(n, ast.Import):
            imp |= {a.name.split(".")[0] for a in n.names}
        elif isinstance(n, ast.ImportFrom):
            imp.add((n.module or "").split(".")[0])
    if imp - {"json", "os", "sys", "time", "contextlib", "io", "tempfile"}:
        errs.append("unerwartete Importe: %s" % sorted(imp))
    if imp & (BAD_MODS | {"subprocess"}):
        errs.append("verbotene Importe")
    allowed_unlink = {"cmd_reserve", "cmd_release", "selftest"}
    for fn in [n for n in t.body if isinstance(n, ast.FunctionDef)]:
        for c in ast.walk(fn):
            if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and isinstance(c.func.value, ast.Name) and c.func.value.id == "os":
                a = c.func.attr
                if a in ("remove", "rmdir", "removedirs", "rename", "system", "popen", "truncate", "chmod", "chown") and fn.name != "selftest":
                    errs.append("os.%s in %s (Zeile %d)" % (a, fn.name, c.lineno))
                if a == "unlink" and fn.name not in allowed_unlink:
                    errs.append("os.unlink in %s (Zeile %d)" % (fn.name, c.lineno))
                if a == "replace" and fn.name not in ("cmd_status",):
                    errs.append("os.replace in %s" % fn.name)
            if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id in ("exec", "eval"):
                errs.append("%s in %s" % (c.func.id, fn.name))
    for name in ("cmd_reserve", "cmd_release"):
        s = seg(src, fdef(t, name))
        i_ja = s.find("if not ja:")
        i_act = min([x for x in (s.find("os.open("), s.find("os.unlink(p)")) if x >= 0] or [10 ** 9])
        if i_ja < 0 or i_ja > i_act:
            errs.append("%s: --ja-Pruefung fehlt/zu spaet" % name)
    rs = seg(src, fdef(t, "cmd_reserve"))
    if "os.O_EXCL" not in rs or "if LEVELS.index(lv) >= 2:" not in rs:
        errs.append("cmd_reserve: O_EXCL/Stufenpruefung fehlt")
    rl = seg(src, fdef(t, "cmd_release"))
    if "os.path.basename(p) != RESERVE_NAME" not in rl or "os.path.islink(p)" not in rl:
        errs.append("cmd_release: nur die Reservedatei - Pruefung fehlt")
    ls = seg(src, fdef(t, "level_for"))
    for need in ("if free_b < 1 * GIB or (ipct is not None and ipct < 2.0):", "elif free_b < 5 * GIB or", "free_b < 5 * GIB", "pct >= 90 and free_b < 32 * GIB", "free_b < 15 * GIB", "pct >= 80 and free_b < 64 * GIB"):
        if need not in ls:
            errs.append("Schwelle geaendert/fehlt: %s" % need)
    if "level" not in {n.name for n in t.body if isinstance(n, ast.FunctionDef)}:
        errs.append("level() fehlt")
    # commit25b: der Selbsttest darf nie vom echten Rechner abhaengen (kleine tmpfs, /home, Journal) - Attrappen muessen da sein
    rd = seg(src, fdef(t, "read"))
    if "(_statvfs or _SV)(path)" not in rd or "os.statvfs(" in rd:
        errs.append("read(): Dateisystem-Abfrage muss ueber _SV laufen (Test-Attrappe)")
    st = seg(src, fdef(t, "selftest"))
    for need in ("_SV = lambda p: V(fake[\"free\"], fake[\"total\"])", "EXT_DIRS = ()", "_SV, EXT_DIRS = sv0, ext0", "assert cmd_reserve(1, True) == 2 and not os.path.exists(reserve_path()), (fr, tot)"):
        if need not in st:
            errs.append("selftest: Hermetik fehlt: %s" % need)
    if "os.statvfs(" in st:
        errs.append("selftest: echtes statvfs im Selbsttest")
    cr = seg(src, fdef(t, "consumers"))
    if "for label, p in EXT_DIRS:" not in cr or "/home/fmg" in cr:
        errs.append("consumers: Zusatzordner muessen ueber EXT_DIRS laufen")
    return errs


def check(db, clock, disk, base):
    e = ["database: " + x for x in check_db(db, base)]
    e += ["lage_clock: " + x for x in check_clock(clock)]
    e += ["lage_disk: " + x for x in check_disk(disk)]
    return e


def mutants(db, clock, disk, em, base):
    M = [
        ("M01 Loeschen ohne Uhr-Pruefung", "db", "            if ck_ok:\n                out.update(cleanup(now, path))", "            if True:\n                out.update(cleanup(now, path))"),
        ("M02 t2/t3 ohne Uhr-Pruefung", "db", "        for k, fn in ((\"t2\", cleanup_t2), (\"t3\", cleanup_t3)):\n            if not ck_ok:\n                break\n", "        for k, fn in ((\"t2\", cleanup_t2), (\"t3\", cleanup_t3)):\n"),
        ("M03 Zusatz-Aufraeumer ohne Pruefung", "db", "        for k, fn in sorted(self.extra.items()):\n            if not ck_ok:\n                break\n", "        for k, fn in sorted(self.extra.items()):\n"),
        ("M04 Rueckfall retention_watch ohne Pruefung", "db", "        if not ck_ok:\n            return {\"faden\": \"direkt\", \"clock_pause\": ck_why[:80]}\n", ""),
        ("M05 fehlender Pruefer blockiert", "db", 'return True, "lage_clock fehlt - Uhr nicht geprueft", False', 'return False, "lage_clock fehlt - Uhr nicht geprueft", False'),
        ("M06 quick_check wieder Wanduhr", "db", "return 1 if time.monotonic() > deadline else 0", "return 1 if time.time() > deadline else 0"),
        ("M07 owns wieder Wanduhr", "db", "return time.monotonic() - self.mono_ref <= self.first_s + 3 * self.every_s", "return time.time() - self.mono_ref <= self.first_s + 3 * self.every_s"),
        ("M08 checkpoint wieder Wanduhr", "db", "    t0 = time.monotonic()   # relClock: Dauer monoton (Zeitspruenge)\n", "    t0 = time.time()\n"),
        ("M09 import lage_clock ungeschuetzt", "db", "try:\n    import lage_clock as _lclk\nexcept Exception:   # noch nicht installiert oder defekt -> wie bisher, ehrlich im Status\n    _lclk = None\n", "import lage_clock as _lclk\n"),
        ("M10 subprocess-Import", "db", "def _clock_state():", "import subprocess\n\n\ndef _clock_state():"),
        ("M11 neues SQL DELETE", "db", "def _clock_gate(ret):", "_X = \"DELETE FROM events\"\n\n\ndef _clock_gate(ret):"),
        ("M12 clock_pause nicht gemeldet", "db", "            out[\"clock_pause\"] = ck_why[:80]\n        try:", "            pass\n        try:"),
        ("M13 VACUUM", "db", "def _clock_gate(ret):", "_V = \"VAC\" + \"UUM\"\n_VV = \"VACUUM\"\n\n\ndef _clock_gate(ret):"),
        ("M14 Basisfunktion umbenannt", "db", "def retention_owns(path=None):", "def retention_ownz(path=None):"),
        ("M15 Fehler im Pruefer blockiert", "db", 'return True, "Uhr-Pruefer Fehler: %s" % str(e)[:60], False', 'return False, "Uhr-Pruefer Fehler: %s" % str(e)[:60], False'),
        ("C01 MIN_EPOCH geaendert", "clock", "MIN_EPOCH = calendar.timegm((2026, 10, 1, 0, 0, 0))", "MIN_EPOCH = calendar.timegm((2020, 10, 1, 0, 0, 0))"),
        ("C02 Haltezeit 0", "clock", "HOLD_S = 900.0", "HOLD_S = 0.0"),
        ("C03 Sprungtoleranz", "clock", "JUMP_TOL_S = 5.0", "JUMP_TOL_S = 500.0"),
        ("C04 shell=True", "clock", 'subprocess.run(["chronyc", "-c", "tracking"], capture_output=True, text=True, timeout=3)', 'subprocess.run("chronyc -c tracking", shell=True, capture_output=True, text=True, timeout=3)'),
        ("C05 Pruefer-Fehler blockiert", "clock", 'return (True, "Pruefung fehlgeschlagen', 'return (False, "Pruefung fehlgeschlagen'),
        ("C06 Plausibilitaet entfernt", "clock", "if not (MIN_EPOCH <= w < MAX_EPOCH):", "if False:"),
        ("C07 Sprungerkennung entfernt", "clock", "if abs(d) > JUMP_TOL_S:", "if False:"),
        ("C08 os-Aufruf", "clock", "def mono():", "def mono():\n    os.system(\"true\")"),
        ("D01 --ja entfernt (release)", "disk", "    if not ja:\n        print(\"Nichts getan: ohne --ja wird nichts entfernt.", "    if False:\n        print(\"Nichts getan: ohne --ja wird nichts entfernt."),
        ("D02 --ja entfernt (reserve)", "disk", "    if not ja:\n        print(\"Nichts getan: ohne --ja wird keine Reservedatei", "    if False:\n        print(\"Nichts getan: ohne --ja wird keine Reservedatei"),
        ("D03 shutil", "disk", "import json\n", "import json\nimport shutil\n"),
        ("D04 os.remove in consumers", "disk", "    out = []\n    try:\n        with os.scandir(d) as it:", "    out = []\n    os.remove(os.path.join(d, 'x'))\n    try:\n        with os.scandir(d) as it:"),
        ("D05 O_EXCL entfernt", "disk", "os.O_WRONLY | os.O_CREAT | os.O_EXCL", "os.O_WRONLY | os.O_CREAT"),
        ("D06 Schwelle critical", "disk", "if free_b < 1 * GIB or (ipct", "if free_b < 0 * GIB or (ipct"),
        ("D07 release beliebige Datei", "disk", "os.path.basename(p) != RESERVE_NAME or ", ""),
        ("D08 Stufenpruefung Reserve", "disk", "if LEVELS.index(lv) >= 2:", "if False:"),
        ("D09 subprocess", "disk", "import json\n", "import json\nimport subprocess\n"),
        ("D10 Selbsttest ohne statvfs-Attrappe", "disk", "        _SV = lambda p: V(fake[\"free\"], fake[\"total\"])", "        pass"),
        ("D11 Selbsttest fasst echte Zusatzordner an", "disk", "        EXT_DIRS = ()\n        r = read(d", "        r = read(d"),
        ("D12 read() mit echtem statvfs", "disk", "    s = (_statvfs or _SV)(path)\n", "    s = (_statvfs or os.statvfs)(path)\n"),
        ("D13 Verweigerungstest Reserve entfernt", "disk", "            assert cmd_reserve(1, True) == 2 and not os.path.exists(reserve_path()), (fr, tot)\n", "            pass\n"),
        ("D14 Attrappe nicht zurueckgesetzt", "disk", "        _SV, EXT_DIRS = sv0, ext0\n", "        pass\n"),
    ]
    out = []
    for name, which, old, new in M:
        srcs = {"db": db, "clock": clock, "disk": disk}
        s = srcs[which]
        if s.count(old) != 1:
            out.append((name, None, "Muster passt %d-mal" % s.count(old)))
            continue
        srcs[which] = s.replace(old, new)
        out.append((name, check(srcs["db"], srcs["clock"], srcs["disk"], base), None))
    for en, _, _ in em.EDITS:
        try:
            d2 = em.build(base, skip=(en,))
        except SystemExit as e:
            out.append(("E-revert " + en, None, str(e)))
            continue
        out.append(("E-revert " + en, check(d2, clock, disk, base), None))
    return out


def main(argv):
    if argv[0] == "check":
        db, clock, disk, base = [pathlib.Path(p).read_text(encoding="utf-8") for p in argv[1:5]]
        errs = check(db, clock, disk, base)
        for e in errs:
            print("GUARD: " + e)
        if errs:
            return 1
        print("guard relClock ok: Loeschen nur bei plausibler Uhr, fehlender Pruefer blockiert nie, monotone Dauern, lage_clock nur lesend (chronyc -c tracking), lage_disk loescht nie ausser der eigenen Reservedatei mit --ja")
        return 0
    if argv[0] == "mutate":
        base = pathlib.Path(argv[1]).read_text(encoding="utf-8")
        spec = importlib.util.spec_from_file_location("edits", argv[2])
        em = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(em)
        db = em.build(base)
        clock = pathlib.Path(argv[3]).read_text(encoding="utf-8")
        disk = pathlib.Path(argv[4]).read_text(encoding="utf-8")
        e0 = check(db, clock, disk, base)
        assert not e0, e0
        res = mutants(db, clock, disk, em, base)
        miss = 0
        for name, errs, bad in res:
            if bad:
                print("MUTATION %-40s FEHLER im Test: %s" % (name, bad))
                miss += 1
            elif not errs:
                print("MUTATION %-40s UEBERSEHEN" % name)
                miss += 1
        print("mutation: %d Mutationen, %d erkannt, %d uebersehen" % (len(res), len(res) - miss, miss))
        return 1 if miss else 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
RCK_GUARD_EOF
EXPECT_EDITS="76be9f3f85851f7792f9855785e4bb777a9197059e8dacc5ad4c1f51f95c2516"
cat > "$W/edits_relclock.py" << 'RCK_EDITS_EOF'
"""relClock: database.py (Basis = relDb-Fassung, sha16 3f3aa054076bf70b) -> neue Fassung. Jede Ersetzung muss genau einmal passen (sonst Abbruch)."""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
BLOCK = (HERE / "block_relclock.py").read_text(encoding="utf-8")

EDITS = [
    ("C01_doc",
     "relDb: Wartung der Datenbank im Hintergrund (Checkpoint, quick_check, snapshot), WAL einmal je Prozess und Pfad (siehe Block relDb weiter unten).\n\"\"\"\n",
     "relDb: Wartung der Datenbank im Hintergrund (Checkpoint, quick_check, snapshot), WAL einmal je Prozess und Pfad (siehe Block relDb weiter unten).\n"
     "relClock: der Aufraeum-Faden loescht nichts, solange lage_clock.clock_ok() die Uhr fuer unplausibel haelt; Dauern/Zeitlimits/owns() in monotonic (siehe Block relClock).\n\"\"\"\n"),
    ("C02_checkpoint",
     "    out = {\"mode\": mode, \"busy\": None, \"log\": None, \"done\": None, \"wal_before\": wal_bytes(path), \"wal_after\": None, \"ms\": None, \"err\": None}\n"
     "    t0 = time.time()\n",
     "    out = {\"mode\": mode, \"busy\": None, \"log\": None, \"done\": None, \"wal_before\": wal_bytes(path), \"wal_after\": None, \"ms\": None, \"err\": None}\n"
     "    t0 = time.monotonic()   # relClock: Dauer monoton (Zeitspruenge)\n"),
    ("C03_checkpoint_ms",
     "    out[\"wal_after\"] = wal_bytes(path)\n"
     "    out[\"ms\"] = int((time.time() - t0) * 1000)\n",
     "    out[\"wal_after\"] = wal_bytes(path)\n"
     "    out[\"ms\"] = int((time.monotonic() - t0) * 1000)\n"),
    ("C04_qc_start",
     "    out = {\"ok\": None, \"rows\": [], \"ms\": None, \"err\": None, \"aborted\": False}\n"
     "    t0 = time.time()\n",
     "    out = {\"ok\": None, \"rows\": [], \"ms\": None, \"err\": None, \"aborted\": False}\n"
     "    t0 = time.monotonic()   # relClock: Zeitlimit und Dauer monoton - ein Zeitsprung darf den Test weder abbrechen noch endlos laufen lassen\n"),
    ("C05_qc_stop",
     "            return 1 if time.time() > deadline else 0\n",
     "            return 1 if time.monotonic() > deadline else 0\n"),
    ("C06_qc_ms",
     "    out[\"ms\"] = int((time.time() - t0) * 1000)\n"
     "    return out\n\n\ndef db_stats(",
     "    out[\"ms\"] = int((time.monotonic() - t0) * 1000)\n"
     "    return out\n\n\ndef db_stats("),
    ("C07_block",
     "class _Retention:\n    def __init__(self, every_s=RETENTION_S, first_s=RETENTION_FIRST_S, name=\"lz-retention\"):\n",
     BLOCK + "class _Retention:\n    def __init__(self, every_s=RETENTION_S, first_s=RETENTION_FIRST_S, name=\"lz-retention\"):\n"),
    ("C08_init",
     "        self.maint = _Maint()   # relDb: Checkpoint/quick_check im selben Faden (nicht bei Test-Instanzen: maint = None)\n",
     "        self.maint = _Maint()   # relDb: Checkpoint/quick_check im selben Faden (nicht bei Test-Instanzen: maint = None)\n"
     "        self.clock_last = None   # relClock: (ok, Pruefer) des letzten Laufs - Journalmeldung nur bei Wechsel\n"
     "        self.clock_why = None\n"
     "        self.mono_ref = time.monotonic()   # relClock: letzter Lebenszeichen-Zeitpunkt (monoton) fuer owns()\n"),
    ("C09_run",
     "        now = int(now or time.time())\n"
     "        t0 = time.time()\n"
     "        out = {}\n"
     "        try:\n"
     "            out.update(cleanup(now, path))\n"
     "        except Exception as e:\n"
     "            out[\"err_base\"] = str(e)[:80]\n"
     "        for k, fn in ((\"t2\", cleanup_t2), (\"t3\", cleanup_t3)):\n"
     "            try:\n"
     "                out.update(fn(now, path) or {})\n"
     "            except Exception as e:\n"
     "                out[\"err_\" + k] = str(e)[:80]\n"
     "        for k, fn in sorted(self.extra.items()):\n"
     "            try:\n"
     "                out[k] = fn(now, path)\n",
     "        now = int(now or time.time())\n"
     "        t0 = time.monotonic()\n"
     "        out = {}\n"
     "        ck_ok, ck_why = _clock_gate(self)   # relClock: Uhr unplausibel -> nichts loeschen (auch nicht die Zusatz-Aufraeumer)\n"
     "        if not ck_ok:\n"
     "            out[\"clock_pause\"] = ck_why[:80]\n"
     "        try:\n"
     "            if ck_ok:\n"
     "                out.update(cleanup(now, path))\n"
     "        except Exception as e:\n"
     "            out[\"err_base\"] = str(e)[:80]\n"
     "        for k, fn in ((\"t2\", cleanup_t2), (\"t3\", cleanup_t3)):\n"
     "            if not ck_ok:\n"
     "                break\n"
     "            try:\n"
     "                out.update(fn(now, path) or {})\n"
     "            except Exception as e:\n"
     "                out[\"err_\" + k] = str(e)[:80]\n"
     "        for k, fn in sorted(self.extra.items()):\n"
     "            if not ck_ok:\n"
     "                break\n"
     "            try:\n"
     "                out[k] = fn(now, path)\n"),
    ("C10_run_end",
     "        ms = int((time.time() - t0) * 1000)\n"
     "        self.st.update(n=self.st[\"n\"] + 1, t=now, last=out, err=None)\n",
     "        ms = int((time.monotonic() - t0) * 1000)\n"
     "        self.mono_ref = time.monotonic()\n"
     "        self.st.update(n=self.st[\"n\"] + 1, t=now, last=out, err=None)\n"),
    ("C11_start",
     "            self.st[\"started\"] = int(time.time())\n"
     "            return True\n",
     "            self.st[\"started\"] = int(time.time())\n"
     "            self.mono_ref = time.monotonic()\n"
     "            return True\n"),
    ("C12_owns",
     "            ref = self.st[\"t\"] or self.st[\"started\"] or 0\n"
     "            return time.time() - ref <= self.first_s + 3 * self.every_s\n",
     "            return time.monotonic() - self.mono_ref <= self.first_s + 3 * self.every_s   # relClock: monoton statt Wanduhr\n"),
    ("C13_status",
     "                \"extra\": sorted(self.extra), \"maint\": (self.maint.status() if self.maint is not None else None),\n",
     "                \"extra\": sorted(self.extra), \"maint\": (self.maint.status() if self.maint is not None else None),\n"
     "                \"clock\": {\"ok\": (self.clock_last[0] if self.clock_last else None), \"why\": self.clock_why, \"pruefer\": (self.clock_last[1] if self.clock_last else None)},\n"),
    ("C14_watch",
     "        out = cleanup(now, path)\n"
     "        out.update(cleanup_t2(now, path) or {})\n"
     "        return dict(out, faden=\"direkt\")\n",
     "        ck_ok, ck_why, _chk = _clock_state()   # relClock\n"
     "        if not ck_ok:\n"
     "            return {\"faden\": \"direkt\", \"clock_pause\": ck_why[:80]}\n"
     "        out = cleanup(now, path)\n"
     "        out.update(cleanup_t2(now, path) or {})\n"
     "        return dict(out, faden=\"direkt\")\n"),
    ("C15_main",
     "    print(selftest_maint())\n",
     "    print(selftest_maint())\n"
     "    print(selftest_clock())\n"),
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
RCK_EDITS_EOF
EXPECT_BLOCK="abdae7b1e0ca5509a1557dd80c17649a3b8cdcd3643f614d2b9fcaefe8fd3bae"
cat > "$W/block_relclock.py" << 'RCK_BLOCK_EOF'
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


RCK_BLOCK_EOF
EXPECT_BASE="3f3aa054076bf70b008212584aa401eca4490579d0e786cd13fa7187db970328"
cat > "$W/base_database.py" << 'RCK_BASE_EOF'
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
RCK_BASE_EOF
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
PAYLOADS=(database.py:DB lage_clock.py:CLK lage_disk.py:DSK guard_relclock.py:GUARD edits_relclock.py:EDITS block_relclock.py:BLOCK base_database.py:BASE)
verify_payloads
cp "$W/base_database.py" "$W/base/database.py"
sbx_new() { rm -rf "$W/sbx" || stop "Pruefordner $W/sbx liess sich nicht loeschen"; mkdir -p "$W/sbx" || stop "Pruefordner $W/sbx liess sich nicht anlegen"; }
show_out() { local f; for f in "$@"; do echo "--- Ausgabe $(basename "$f") (Anfang, max 3000 Zeichen) ---"; head -c 3000 "$f" 2>&1 || true; echo; done; return 0; }
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
cat > "$W/smallfs.py" << 'PYS'
# Hilfsprogramm fuer den Test "Selbsttest haengt nicht vom echten Speicher ab": gibt dem Prozess ein winziges Dateisystem (1.5 GiB frei von 2 GiB, wie eine kleine tmpfs)
import os, runpy, sys
real = os.statvfs
GIB = 1024 ** 3
class V:
    f_frsize = 4096; f_blocks = int(2 * GIB / 4096); f_bavail = int(1.5 * GIB / 4096); f_favail = 200000; f_files = 250000
os.statvfs = lambda p: V()
script = sys.argv[1]
sys.argv = sys.argv[1:]
runpy.run_path(script, run_name="__main__")
PYS
if [[ "$OPT" == diagnose ]]; then
  echo "=== relClock DIAGNOSE (nur lesend, am Projekt wird nichts geaendert) ==="
  echo "Benutzer $(id -un), umask $(umask), System-Python $SPY ($("$SPY" -V 2>&1)), venv-Python $VPY ($("$VPY" -V 2>&1))"
  echo "Dateisystem /tmp: $(df -P /tmp 2>/dev/null | tail -1 | cut -c1-110 || true)"
  echo "Dateisystem Projektordner: $(df -P "$DASH_DIR" 2>/dev/null | tail -1 | cut -c1-110 || true)"
  echo "chronyc: $(command -v chronyc || echo fehlt)"
  dbad=0
  for py in "$SPY" "$VPY"; do
    sbx_new; cp "$W/lage_clock.py" "$W/lage_disk.py" "$W/sbx/"
    st_run clk "$py" lage_clock.py; echo "lage_clock.py ($py): Exit $ST_RC"; [[ "$ST_RC" == 0 ]] || dbad=1; show_out "$ST_OUT"
    st_run dsk "$py" lage_disk.py --selftest; echo "lage_disk.py --selftest ($py): Exit $ST_RC"; [[ "$ST_RC" == 0 ]] || dbad=1; show_out "$ST_OUT"
    st_run dsm "$py" "$W/smallfs.py" lage_disk.py --selftest; echo "lage_disk.py --selftest bei winzigem Dateisystem ($py): Exit $ST_RC"; [[ "$ST_RC" == 0 ]] || dbad=1; show_out "$ST_OUT"
    sbx_new; cp "$W/database.py" "$W/lage_clock.py" "$W/sbx/"
    st_run dbs "$py" database.py; echo "database.py Selbsttest ($py): Exit $ST_RC"; [[ "$ST_RC" == 0 ]] || dbad=1; [[ "$ST_RC" == 0 ]] || show_out "$ST_OUT"
  done
  echo "Speicher jetzt (nur lesend): $(df -P / "$DASH_DIR" 2>/dev/null | tail -n +2 | cut -c1-110 | tr '\n' ';' || true)"
  rm -rf "$W/sbx"
  [[ "$dbad" == 0 ]] && echo "DIAGNOSE FERTIG: alle Selbsttests ok - nichts geaendert" || echo "DIAGNOSE FERTIG: mindestens ein Selbsttest ist fehlgeschlagen (siehe Ausgaben oben) - nichts geaendert"
  exit 0
fi
# ---------- 1) Zustand vorher (nur lesend) ----------
[[ -d "$DASH_DIR" ]] || stop "Projektordner fehlt: $DASH_DIR"
[[ "$(stat -c %U "$DASH_DIR")" == "$(id -un)" ]] || stop "$DASH_DIR gehoert $(stat -c %U "$DASH_DIR"), du bist $(id -un): bitte als Benutzer $(stat -c %U "$DASH_DIR") ausfuehren (nicht mit sudo/root)"
a=$(systemctl is-active prepper-dashboard 2>/dev/null || true); [[ "$a" == active ]] || stop "Dienst prepper-dashboard ist nicht aktiv ($a)"
[[ -f "$DBF" && "$(s16 "$DBF")" == "$PRE_RELDB16" ]] && stop "database.py ist noch die Fassung vor relDb (sha16 $PRE_RELDB16): bitte zuerst relDb anwenden (bash /tmp/apply-reldb.sh commit23), dann dieses Skript"
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
print("quick_check ok, journal_mode=%s, %.1f MB, Zeilen %s" % (jm, os.path.getsize(p) / 1048576.0, n))
PYQ
  echo "OK lagezentrum.db vorher: $(cat "$W/lz0.txt")"
else
  echo "HINWEIS $LZ gibt es nicht (wird vom Dashboard angelegt) - keine SQLite-Sicherung noetig"
fi
# ---------- 2) Pruefungen der Nutzlast (Sandbox, nichts Echtes angefasst) ----------
"$SPY" "$W/edits_relclock.py" "$W/base/database.py" "$W/rebuilt.py" || stop "Aufbau aus der Basis misslungen"
cmp -s "$W/rebuilt.py" "$W/database.py" && echo "OK die eingebettete database.py ist byte-genau das Ergebnis der geprueften Edits auf der Basis" || stop "eingebettete database.py ungleich Edits(Basis)"
"$SPY" "$W/guard_relclock.py" check "$W/database.py" "$W/lage_clock.py" "$W/lage_disk.py" "$W/base/database.py" || stop "Guard hat die Nutzlast beanstandet"
"$SPY" "$W/guard_relclock.py" mutate "$W/base/database.py" "$W/edits_relclock.py" "$W/lage_clock.py" "$W/lage_disk.py" || stop "Mutationstest: eine Mutation wurde uebersehen"
pycomp "$W/database.py" "$W/lage_clock.py" "$W/lage_disk.py" "$W/guard_relclock.py" "$W/edits_relclock.py" || stop "py_compile mit Warnung/Fehler"
echo "OK py_compile ohne Warnung (System-Python $("$SPY" -V 2>&1), venv-Python $("$VPY" -V 2>&1))"
for py in "$SPY" "$VPY"; do
  for mit in mit ohne; do
    sbx_new; cp "$W/database.py" "$W/sbx/"
    [[ "$mit" == mit ]] && cp "$W/lage_clock.py" "$W/sbx/"
    st_must dbs "$py" database.py
    cp "$ST_OUT" "$W/selftest.out"
    grep -q "database selftest relClock ok" "$W/selftest.out" && grep -q "database selftest relDb ok" "$W/selftest.out" || { show_out "$W/selftest.out"; stop "Selbsttest relClock/relDb meldet nicht ok ($mit lage_clock.py)"; }
  done
  sbx_new; cp "$W/lage_clock.py" "$W/lage_disk.py" "$W/sbx/"
  st_must clk "$py" lage_clock.py
  st_must dsk "$py" lage_disk.py --selftest
  # Der Selbsttest darf nicht vom echten Rechner abhaengen: winziges Dateisystem, kein chronyc, chronyc mit Fehler (so lief es auf dem Pi in die Irre: kleine /tmp-tmpfs)
  st_must dsm "$py" "$W/smallfs.py" lage_disk.py --selftest
  mkdir -p "$W/fakebin"; printf '#!/bin/bash\necho 506 Cannot talk to daemon >&2\nexit 1\n' > "$W/fakebin/chronyc"; chmod 755 "$W/fakebin/chronyc"
  sbx_new; cp "$W/lage_clock.py" "$W/lage_disk.py" "$W/sbx/"
  PATH="$W/fakebin:$PATH" st_must clk2 "$py" lage_clock.py
  PATH="/nonexistent" st_must clk3 "$(command -v "$py")" lage_clock.py
  echo "OK Selbsttests mit $("$py" -V 2>&1): database.py (mit und ohne lage_clock.py, $(grep -c "selftest" "$W/selftest.out") Gruppen), $(cut -c1-40 "$W/st-clk.out"), $(cut -c1-40 "$W/st-dsk.out"), auch bei winzigem Dateisystem/ohne chronyc/chronyc mit Fehler"
done
# Verhalten auf KOPIEN der echten Datenbank: neue Fassung (Uhr ok) loescht genau wie die alte (relDb); Uhr falsch -> nichts; alles nur auf Kopien in /tmp
if [[ -f "$LZ" ]]; then
  sbx_new; mkdir -p "$W/sbx/neu" "$W/sbx/alt" "$W/sbx/leer"
  sqlite_snapshot "$LZ" "$W/sbx/neu/lz.db" || stop "SQLite-Kopie fuer den Test fehlgeschlagen"
  cp "$W/sbx/neu/lz.db" "$W/sbx/alt/lz.db"; cp "$W/sbx/neu/lz.db" "$W/sbx/leer/lz.db"
  cp "$W/database.py" "$W/lage_clock.py" "$W/sbx/neu/"; cp "$W/base/database.py" "$W/sbx/alt/"; cp "$W/database.py" "$W/lage_clock.py" "$W/sbx/leer/"
  cat > "$W/copytest.py" << 'PYL'
import json, sqlite3, sys, os
import database as d
p = sys.argv[2]
mode = sys.argv[1]
def counts():
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
    r = {t: c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0] for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchall()}
    c.close()
    return r
assert d.migrate(p) and d.migrate_t2(p) and d.migrate_t3(p)
a = counts()
r = d._Retention(every_s=3600, first_s=3600)
r.quiet = True
r.maint = None
r.path = p
if mode == "leer":
    d._clock_state = lambda: (False, "Uhr unplausibel (Test)", True)
out = r.run(None, p)
b = counts()
print(json.dumps({"vorher": a, "nachher": b, "pause": bool(out.get("clock_pause"))}))
PYL
  for m in neu alt leer; do
    (cd "$W/sbx/$m" && PYTHONDONTWRITEBYTECODE=1 "$SPY" "$W/copytest.py" "$m" "$W/sbx/$m/lz.db" > "$W/ct-$m.out" 2>&1) || { cat "$W/ct-$m.out"; stop "Test auf der Kopie der echten Datenbank ($m) fehlgeschlagen"; }
  done
  "$SPY" - "$W/ct-neu.out" "$W/ct-alt.out" "$W/ct-leer.out" << 'PYC' || stop "Vergleich auf Kopien der echten Datenbank: alt/neu weichen ab oder Uhr-Sperre wirkt nicht"
import json, sys
n, a, l = [json.loads(open(f).read().strip().splitlines()[-1]) for f in sys.argv[1:4]]
assert n["nachher"] == a["nachher"], ("neu", n["nachher"], "alt", a["nachher"])        # Uhr ok: gleiche Loeschungen wie die alte Fassung
assert l["nachher"] == l["vorher"] and l["pause"] is True, l                            # Uhr falsch: nichts geloescht
assert n["pause"] is False
dif = {k: n["vorher"][k] - n["nachher"][k] for k in n["vorher"] if n["vorher"][k] != n["nachher"][k]}
print("Kopien der echten Datenbank: Uhr ok -> neu loescht wie alt (%s), Uhr falsch -> nichts geloescht (%d Tabellen unveraendert)" % (dif or "nichts faellig", len(l["vorher"])))
PYC
  echo "OK Kopien der echten Datenbank: neu/alt/Uhr falsch verglichen (siehe Zeile darueber)"
  rm -rf "$W/sbx"
fi
# Echte Uhr und echter Speicher (nur lesend)
sbx_new; cp "$W/lage_clock.py" "$W/lage_disk.py" "$W/sbx/"
(cd "$W/sbx" && PYTHONDONTWRITEBYTECODE=1 "$SPY" lage_clock.py --status > "$W/clk.out" 2>&1) || { cat "$W/clk.out"; stop "lage_clock.py --status fehlgeschlagen"; }
echo "OK Uhr jetzt (nur lesend): $(cut -c1-230 "$W/clk.out")"
rc=0; (cd "$W/sbx" && LAGE_DISK_DIR="$DASH_DIR" PYTHONDONTWRITEBYTECODE=1 "$SPY" lage_disk.py status > "$W/dsk.out" 2>&1) || rc=$?
[[ "$rc" -le 3 && -s "$W/dsk.out" ]] || { cat "$W/dsk.out"; stop "lage_disk.py status fehlgeschlagen (Exit $rc)"; }
echo "OK Speicher jetzt (nur lesend, Exit $rc = $(case $rc in 0) echo ok;; 1) echo warn;; 2) echo tight;; 3) echo critical;; esac)): $(cut -c1-230 "$W/dsk.out")"
[[ -z "$(ls "$W/sbx" | grep -v -E '^(lage_clock.py|lage_disk.py)$' || true)" ]] || stop "lage_clock/lage_disk haben beim Pruefen Dateien angelegt"
rm -rf "$W/sbx"
if [[ "$OPT" == "trocken" ]]; then
  echo "TROCKENLAUF FERTIG: alle Pruefungen ok, es wurde nichts geaendert (kein sudo, kein Neustart, keine Sicherung). Zum Installieren ohne 'trocken' aufrufen."
  exit 0
fi
# ---------- 3) Installieren ----------
declare -A NEED=()
same() { [[ -f "$2" ]] && cmp -s "$1" "$2"; }
same "$W/database.py" "$DBF" || NEED[db]=1
same "$W/lage_clock.py" "$CLKF" || NEED[clk]=1
same "$W/lage_disk.py" "$DSKF" || NEED[dsk]=1
if [[ "${#NEED[@]}" == 0 ]]; then
  echo "OK relClock schon installiert (database.py, lage_clock.py, lage_disk.py) - keine Aenderung, kein Neustart"
else
  [[ -n "${NEED[db]:-}" ]] && { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart von prepper-dashboard erforderlich"; }
  LZB=""
  if [[ -f "$LZ" && -n "${NEED[db]:-}" ]]; then
    LZB="$LZ.bak-$NAME-$TS"
    sqlite_snapshot "$LZ" "$LZB" || { rm -f "$LZB"; stop "SQLite-Sicherung lagezentrum.db fehlgeschlagen"; }
    prune_bak "$LZ"
    echo "OK SQLite-Sicherung $(basename "$LZB") ($(wc -c < "$LZB") Bytes, integrity_check ok), behalten: letzte $KEEP_LAST"
  fi
  trap '' INT
  PHASE=Installation
  declare -A WAS
  FILES=("db:$DBF" "clk:$CLKF" "dsk:$DSKF")
  RESTARTED_D=0
  T0D=$(date +%s)
  rb() {
    set +e +o pipefail
    trap - ERR
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat 2>/dev/null | grep -E "relClock|Traceback" | tail -4 | cut -c1-200
    local e k f
    for e in "${FILES[@]}"; do
      k="${e%%:*}"; f="${e#*:}"
      [[ -n "${NEED[$k]:-}" ]] || continue
      if [[ "${WAS[$k]:-0}" == 1 ]]; then [[ -f "$f.bak-$NAME-$TS" ]] && cp -a "$f.bak-$NAME-$TS" "$f.rb" && mv -f "$f.rb" "$f"; else rm -f "$f" "$f.new."*; fi
    done
    if [[ "$RESTARTED_D" == 1 ]]; then
      sudo systemctl restart prepper-dashboard.service
      for i in $(seq 1 "$WD_N"); do sleep "$WD_S"; [[ "$(code "$B/")" == 200 ]] && break; done
    fi
    [[ -f "$DBF.bak-$NAME-$TS" ]] && { cmp -s "$DBF" "$DBF.bak-$NAME-$TS" && echo "  database.py = Sicherung ($(s16 "$DBF"))" || echo "  WARNUNG database.py ungleich Sicherung"; }
    echo "  SQLite-Sicherung (nicht zurueckgespielt, die Datenbank wurde durch dieses Skript nicht veraendert): ${LZB:-keine}"
    echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), HTTP / = $(code "$B/")"
  }
  rbx() { rb "$1"; exit 1; }
  for e in "${FILES[@]}"; do
    k="${e%%:*}"; f="${e#*:}"
    WAS[$k]=0; [[ -f "$f" ]] && WAS[$k]=1
    if [[ -n "${NEED[$k]:-}" && "${WAS[$k]}" == 1 ]]; then cp -a "$f" "$f.bak-$NAME-$TS"; prune_bak "$f"; fi
  done
  [[ -n "${NEED[clk]:-}" ]] && { write_atomic "$W/lage_clock.py" "$CLKF" 644 || rbx "lage_clock.py nicht installierbar"; }
  [[ -n "${NEED[dsk]:-}" ]] && { write_atomic "$W/lage_disk.py" "$DSKF" 755 || rbx "lage_disk.py nicht installierbar"; }
  if [[ -n "${NEED[db]:-}" ]]; then
    MODE_DB=$(stat -c %a "$DBF.bak-$NAME-$TS")
    write_atomic "$W/database.py" "$DBF" "$MODE_DB" || rbx "database.py nicht installierbar"
  fi
  echo "OK Dateien atomar ersetzt (Sicherungen *.bak-$NAME-$TS, behalten: letzte $KEEP_LAST)"
  if [[ -n "${NEED[db]:-}" || -n "${NEED[clk]:-}" ]]; then
    RESTARTED_D=1
    T0D=$(date +%s)
    echo "Neustart prepper-dashboard (dort laeuft der Aufraeum-Faden) - warte auf HTTP 200 (max 240 s) ..."
    sudo systemctl restart prepper-dashboard.service
    wait_dash || rbx "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"
    PHASE=Pruefung
    wait_ready && echo "OK Dashboard fertig gestartet (erstes Voll-Update da)" || echo "HINWEIS Dashboard zeigt nach 200 s noch die Startseite - Pruefung laeuft trotzdem weiter"
    echo "warte auf die Uhr-Meldung des Aufraeum-Fadens im Journal (ca. 30 s nach dem Start, max 240 s) ..."
    jok=0
    for i in $(seq 1 "$JN"); do
      JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
      grep -qF "(relClock)" <<< "$JD" && grep -qF "Wartung (relDb): bereit" <<< "$JD" && { jok=1; break; }
      sleep "$JS"
    done
    [[ "$jok" == 1 ]] && echo "OK Journal: $(grep -F "(relClock)" <<< "$JD" | tail -1 | cut -c1-260)" || rbx "Journal ohne '(relClock)'-Meldung und 'Wartung (relDb): bereit' (Aufraeum-Faden meldet sich nicht)"
  fi
fi
PHASE=Pruefung
RESTARTED_D=${RESTARTED_D:-0}; LZB=${LZB:-}; T0D=${T0D:-$(( $(date +%s) - 3600 ))}
type rbx >/dev/null 2>&1 || rbx() { echo "FEHLER: $1"; exit 1; }
sleep 2
smoke_all || rbx "Rauchtest: eine Seite/API antwortet nicht mehr wie vorher"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0D" --no-pager -o cat 2>/dev/null || true)
E2=$(grep -c -E 'Traceback|Wartung \(relDb\).*(FEHLER|Fehler)|quick_check BEFUND|Aufraeum-Faden war beendet|Aufraeumen \(Faden\) Fehler' <<< "$JD" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal prepper-dashboard seit Neustart ohne Traceback, ohne Wartungs-/Aufraeumfehler" || { grep -E 'Traceback|Wartung|quick_check BEFUND|Aufraeum' <<< "$JD" | head -5 | cut -c1-240; rbx "$E2 Fehlerzeilen im Journal"; }
if grep -qF "Aufraeumen pausiert (relClock)" <<< "$JD"; then echo "HINWEIS Die Uhr dieses Systems gilt gerade als unplausibel: das Aufraeumen pausiert bewusst, bis sie plausibel ist ($(grep -F "pausiert (relClock)" <<< "$JD" | tail -1 | cut -c1-200))"; fi
if [[ -f "$LZ" ]]; then
  "$SPY" - "$LZ" << 'PYQ' > "$W/lz1.txt" 2>&1 && echo "OK lagezentrum.db nachher: $(cat "$W/lz1.txt")" || { cat "$W/lz1.txt"; rbx "lagezentrum.db nach dem Neustart nicht in Ordnung"; }
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
echo "OK guards: relClock(database.py)=$(grep -c 'relClock (REL-06)' "$DBF" || true)"
echo
echo "=== relClock FERTIG ($COMMIT_ARG) ==="
for x in "$DBF" "$CLKF" "$DSKF"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
[[ -f "$DBF.bak-$NAME-$TS" ]] && echo "Rueckgaengig: cp -p $DBF.bak-$NAME-$TS $DBF   (danach: sudo systemctl restart prepper-dashboard; neue Dateien optional: rm $CLKF $DSKF)"
[[ -n "${LZB:-}" ]] && echo "SQLite-Sicherung vor dem Patch: $LZB (wurde nicht gebraucht; die Datenbank hat dieses Skript nie veraendert)"
echo "Nur lesend pruefen: python3 $CLKF --status   |   python3 $DSKF status   |   python3 $DSKF plan"
echo "Die Reservedatei fuer den Alarmpfad wird NICHT automatisch angelegt: python3 $DSKF reserve --ja (200 MB, nur wenn danach noch Stufe ok/warn)"
