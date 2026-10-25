#!/bin/bash
set -eEuo pipefail
# dbVis (commit31): Datenbank-Check auf /pi: eine Zeile 'SQLite DB: HEALTHY (WAL-Mode)' bzw. WARNUNG/FEHLER mit Grund neben dem Dach-GPS-Eintrag der Datenquellen (REL-DB quick_check aus dem Zwischenspeicher/der maint.json plus echtes journal_mode, alle 5 min lesend, kein quick_check in der Anfrage). Nur dashboard.py (ein neuer Block, keine Aenderung bestehender Stellen), nur Anzeige.
# Aufruf: bash /tmp/apply-dbvis.sh commit31 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 874452e6491a74c5 (Stand nach relWatch commit30) oder dbVis schon drin (3a933125227fb89b); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-dbvis-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/dbvis-apply
KEEP_LAST=3
KNOWN_D16="874452e6491a74c5"      # dashboard.py vor dbVis (Basis: Stand nach relWatch commit30)
KNOWN_D16N="3a933125227fb89b"             # dashboard.py nach dbVis (Ziel)
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
echo "=== dbVis apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Datenbank-Check auf /pi, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="b3c17d7b7574a6313bb9afb5327709d4710ca4823f6c56ca73d342be000daf86"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher dbVis. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
EXPECT_RAE="356521e7eca7bfa9de96daad5648bbdfdfb47ec82d836e1d86379ffa7127abc8"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer dbVis: keine Aenderung an bestehendem Code - nur der neue Block vor dem Server-Start (Basis 874452e6491a74c5)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_RAE_EOF
EXPECT_RAB="09cf336d5104469a7ca39ed6f720dee000fe252ef13dc315811b8a52e405e29e"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== dbVis: SQLite-Zustand auf /pi - eine Zeile in der Datenquellen-Kachel (direkt nach der GPS-Zeile): HEALTHY (WAL-Mode) / WARNUNG / FEHLER mit Grund. Liest nur Zwischenspeicher: das quick_check-Ergebnis der DB-Wartung (relDb, im Speicher bzw. lagezentrum.db.maint.json) und den echten journal_mode (eine schreibgeschuetzte Abfrage je 5 min). Nie ein quick_check in der Seite; sendet nichts =====
import json as _dbv_json
import os as _dbv_os
import sqlite3 as _dbv_sql
import threading as _dbv_th
import time as _dbv_time

DBV_JM_TTL_S = 300             # journal_mode hoechstens alle 5 min neu lesen
DBV_JM_RETRY_S = 60            # nach einem Lesefehler fruehestens nach 60 s wieder versuchen
DBV_JM_KEEP_S = 3600           # letzter gelesener journal_mode gilt bei Lesefehlern (gesperrt) bis zu 1 h
DBV_STALE_S = 8 * 86400        # quick_check laeuft wöchentlich; aelter als 8 Tage = veraltet
DBV_FILE_MAX = 65536
_DBV = {"lock": _dbv_th.Lock(), "jm": None, "jm_ok_m": None, "jm_try_m": None, "jm_err": None, "file_key": None, "file": None, "n": 0, "err": None, "selftest": None}
_DBV_COL = {"ok": "#22c55e", "alt": "#eab308", "ausgefallen": "#ef4444", "unbekannt": "#64748b"}


def _dbv_path():
    return globals().get("_LZ_PATH") or ""


def _dbv_jm(path, deps=None):
    """Echter journal_mode der Datenbankdatei (schreibgeschuetzt, 0,5 s Wartezeit), zwischengespeichert. -> (modus oder None, Fehlertext oder None). Wirft nie, blockiert hoechstens 0,7 s (bei gleichzeitigem Erstaufruf; sonst Zwischenwert)."""
    d = deps or {}
    m = d["mono"]() if "mono" in d else _dbv_time.monotonic()
    got = _DBV["lock"].acquire(True, 0.7)
    try:
        if not got:
            return _DBV["jm"], _DBV["jm_err"]
        last = _DBV["jm_try_m"]
        wait = DBV_JM_TTL_S if _DBV["jm_err"] is None else DBV_JM_RETRY_S
        if last is not None and m - last < wait:
            return _DBV["jm"], _DBV["jm_err"]
        _DBV["jm_try_m"] = m
        con = None
        try:
            if not path or not _dbv_os.path.exists(path):
                raise RuntimeError("keine Datenbank")
            from urllib.parse import quote
            con = _dbv_sql.connect("file:%s?mode=ro" % quote(_dbv_os.path.abspath(path)), uri=True, timeout=0.5)
            con.execute("PRAGMA busy_timeout=500")
            _DBV["jm"] = str(con.execute("PRAGMA journal_mode").fetchone()[0]).lower()
            _DBV["jm_ok_m"] = m
            _DBV["jm_err"] = None
        except Exception as e:
            _DBV["jm_err"] = str(e)[:80]
            if _DBV["jm_ok_m"] is None or m - _DBV["jm_ok_m"] > DBV_JM_KEEP_S:
                _DBV["jm"] = None
        finally:
            try:
                if con is not None:
                    con.close()
            except Exception:
                pass
        return _DBV["jm"], _DBV["jm_err"]
    finally:
        if got:
            _DBV["lock"].release()


def _dbv_file_qc(path):
    """quick_check-Ergebnis aus lagezentrum.db.maint.json (von der DB-Wartung geschrieben); nur gelesen, nach Aenderungsstand zwischengespeichert. -> dict oder None"""
    p = (path or "") + ".maint.json"
    try:
        st = _dbv_os.stat(p)
        key = (st.st_mtime_ns, st.st_size)
        if _DBV["file_key"] == key:
            return _DBV["file"]
        if st.st_size > DBV_FILE_MAX:
            raise ValueError("zu gross")
        with open(p, encoding="utf-8") as f:
            v = _dbv_json.load(f)
        qc = v.get("qc") if isinstance(v, dict) else None
        qc = qc if isinstance(qc, dict) else None
        _DBV["file_key"], _DBV["file"] = key, qc
        return qc
    except Exception:
        return None


def _dbv_age_txt(s):
    s = int(s)
    return "%d min" % max(1, s // 60) if s < 3600 else ("%d h" % (s // 3600) if s < 172800 else "%d T" % (s // 86400))


def _dbv_eval(qc, jm, jm_err, now, stats=None):
    """Reine Bewertung. Rangfolge: FEHLER (quick_check-Befund) > WARNUNG (kein WAL / nicht prüfbar / veraltet / journal_mode unlesbar) > ungeprüft (grau) > HEALTHY. -> {"state","name","val","tip"}"""
    qt = qc.get("t") if isinstance(qc, dict) else None
    age = max(0, now - qt) if isinstance(qt, (int, float)) and not isinstance(qt, bool) else None
    jm_t = ("journal_mode=%s" % jm) if jm else "journal_mode unbekannt"
    parts = ["lagezentrum.db"]
    if qc is None:
        parts.append("quick_check: noch nicht gelaufen (erster Lauf kurz nach dem Start, danach wöchentlich)")
    elif qc.get("ok") is True:
        parts.append("quick_check ok%s%s" % ((" (%s ms)" % qc.get("ms")) if isinstance(qc.get("ms"), (int, float)) else "", (", vor %s" % _dbv_age_txt(age)) if age is not None else ""))
    elif qc.get("ok") is False:
        parts.append("quick_check BEFUND: %s" % "; ".join(str(x)[:100] for x in (qc.get("rows") or [])[:2]))
    else:
        parts.append("quick_check nicht prüfbar: %s (kein Befund der Datei)" % str(qc.get("err") or "?")[:60])
    parts.append(jm_t + ((" (Lesefehler: %s)" % jm_err) if jm_err else ""))
    if isinstance(stats, dict) and isinstance(stats.get("bytes"), (int, float)):
        parts.append("Größe %.1f MB, WAL %.1f MB" % (stats["bytes"] / 1048576.0, (stats.get("wal_bytes") or 0) / 1048576.0))
    parts.append("Prüfung läuft im Hintergrund (relDb), nie in der Seite")
    tip = " · ".join(parts)
    if isinstance(qc, dict) and qc.get("ok") is False:
        rows = [str(x) for x in (qc.get("rows") or [])]
        return {"state": "ausgefallen", "name": "SQLite DB:", "val": "FEHLER: quick_check-Befund (%s)" % (rows[0][:50] if rows else "?"), "tip": tip}
    if jm and jm != "wal":
        return {"state": "alt", "name": "SQLite DB:", "val": "WARNUNG: kein WAL-Mode (journal_mode=%s)" % jm[:12], "tip": tip}
    if qc is None:
        return {"state": "unbekannt", "name": "SQLite DB:", "val": "noch ungeprüft (%s)" % ("WAL-Mode" if jm == "wal" else jm_t), "tip": tip}
    if not jm:
        return {"state": "alt", "name": "SQLite DB:", "val": "WARNUNG: journal_mode nicht lesbar", "tip": tip}
    if qc.get("ok") is not True:
        return {"state": "alt", "name": "SQLite DB:", "val": "WARNUNG: quick_check nicht prüfbar (%s)" % str(qc.get("err") or "?")[:30], "tip": tip}
    if age is None or age > DBV_STALE_S:
        return {"state": "alt", "name": "SQLite DB:", "val": "WARNUNG: Prüfung veraltet%s" % ((" (%s)" % _dbv_age_txt(age)) if age is not None else ""), "tip": tip}
    return {"state": "ok", "name": "SQLite DB:", "val": "HEALTHY (WAL-Mode)", "tip": tip}


def _dbv_view(deps=None):
    """Daten fuer die /pi-Zeile. Nur Speicher und kleine Dateien - kein quick_check. Wirft nie."""
    d = deps or {}
    try:
        now = d["now"]() if "now" in d else _dbv_time.time()
        path = d["path"] if "path" in d else _dbv_path()
        rs = d["rs"]() if "rs" in d else (globals().get("_lz_dbm").retention_status() if globals().get("_lz_dbm") is not None and hasattr(globals().get("_lz_dbm"), "retention_status") else {})
        mt = rs.get("maint") if isinstance(rs, dict) else None
        mt = mt if isinstance(mt, dict) else {}
        qc = mt.get("qc") if isinstance(mt.get("qc"), dict) else None
        if qc is None:
            qc = d["fileqc"](path) if "fileqc" in d else _dbv_file_qc(path)
        jm, jm_err = d["jm"]() if "jm" in d else _dbv_jm(path, d)
        _DBV["n"] += 1
        return _dbv_eval(qc, jm, jm_err, now, mt.get("stats"))
    except Exception as e:
        _DBV["err"] = str(e)[:100]
        return {"state": "unbekannt", "name": "SQLite DB:", "val": "keine Daten", "tip": "dbVis: %s" % str(e)[:100]}


_DBV_JS = """<script id="dbvis-js">
(function(){function go(){var g=document.querySelector('#srcCard .pp-grid');var d;try{d=JSON.parse(document.getElementById('dbVisData').textContent);}catch(e){return;}
if(!g||!d)return;var col={ok:'#22c55e',alt:'#eab308',ausgefallen:'#ef4444'}[d.state]||'#64748b';var r=document.getElementById('dbVisRow');
if(!r){r=document.createElement('div');r.className='pp-row';r.id='dbVisRow';r.style.gridColumn='1 / -1';r.title=d.tip||'';
var a=document.createElement('span');a.className='pp-dot';a.style.background=col;var b=document.createElement('span');b.className='pp-name';b.textContent=d.name||'SQLite DB:';
var c=document.createElement('span');c.className='pp-val';c.textContent=d.val||'';c.style.color=({alt:'#eab308',ausgefallen:'#ef4444'})[d.state]||'';r.appendChild(a);r.appendChild(b);r.appendChild(c);g.appendChild(r);}
var p=document.getElementById('sdrGpsRow')||document.getElementById('sdrPiRow');if(p&&p.parentNode===g&&r.previousElementSibling!==p)g.insertBefore(r,p.nextSibling);}
document.addEventListener('DOMContentLoaded',go);setTimeout(go,1500);setTimeout(go,3200);})();
</script>"""


def _dbv_after(resp):
    try:
        from flask import request as _dbv_req
        if _dbv_req.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="dbvis-js"' in body:
            return resp
        blk = ('<script type="application/json" id="dbVisData">%s</script>' % _dbv_json.dumps(_dbv_view(), ensure_ascii=False).replace("<", "\\u003c")) + _DBV_JS
        j = body.rfind("</body>")
        body = (body[:j] + blk + body[j:]) if j >= 0 else (body + blk)
        resp.set_data(body)
    except Exception as e:
        print("dbVis /pi:", e, flush=True)
    return resp


def _selftest_dbvis():
    """Reine Bewertung mit Attrappen (keine Datei, kein Netz); Zustand der echten App bleibt unberuehrt."""
    NOW = 2_000_000_000
    ok = {"ok": True, "rows": ["ok"], "ms": 80, "err": None, "t": NOW - 7200}
    e = _dbv_eval
    r = e(ok, "wal", None, NOW)
    assert r["state"] == "ok" and r["val"] == "HEALTHY (WAL-Mode)" and r["name"] == "SQLite DB:" and "vor 2 h" in r["tip"], r
    r = e({"ok": False, "rows": ["database disk image is malformed"], "ms": 5, "err": None, "t": NOW - 60}, "wal", None, NOW)
    assert r["state"] == "ausgefallen" and r["val"].startswith("FEHLER: quick_check-Befund") and "malformed" in r["val"], r
    r = e({"ok": False, "rows": ["x"], "t": NOW}, "delete", None, NOW)
    assert r["state"] == "ausgefallen", "Befund hat Vorrang vor kein WAL"
    r = e(ok, "delete", None, NOW)
    assert r["state"] == "alt" and "kein WAL-Mode (journal_mode=delete)" in r["val"], r
    r = e(None, "wal", None, NOW)
    assert r["state"] == "unbekannt" and r["val"] == "noch ungeprüft (WAL-Mode)", r
    r = e(None, "delete", None, NOW)
    assert r["state"] == "alt", "kein WAL auch ohne quick_check eine Warnung"
    r = e(ok, None, "gesperrt", NOW)
    assert r["state"] == "alt" and "journal_mode nicht lesbar" in r["val"] and "gesperrt" in r["tip"], r
    r = e({"ok": None, "rows": [], "ms": None, "err": "Zeitlimit", "aborted": True, "t": NOW - 5}, "wal", None, NOW)
    assert r["state"] == "alt" and "nicht prüfbar (Zeitlimit)" in r["val"] and "kein Befund" in r["tip"], r
    r = e(dict(ok, t=NOW - 9 * 86400), "wal", None, NOW)
    assert r["state"] == "alt" and "veraltet (9 T)" in r["val"], r
    r = e(dict(ok, t=NOW - 7 * 86400), "wal", None, NOW)
    assert r["state"] == "ok", "7 Tage sind noch in Ordnung (wöchentlicher Lauf)"
    r = e(dict(ok, t=None), "wal", None, NOW)
    assert r["state"] == "alt" and "veraltet" in r["val"], "ohne Zeitstempel kein HEALTHY"
    r = e(dict(ok, t=NOW + 5000), "wal", None, NOW)
    assert r["state"] == "ok" and "vor 1 min" in r["tip"], "Zeit in der Zukunft = Alter 0"
    r = e(ok, "wal", None, NOW, {"bytes": 8 * 1048576, "wal_bytes": 1048576})
    assert "Größe 8.0 MB, WAL 1.0 MB" in r["tip"], r
    assert e(ok, "wal", None, NOW)["val"] == "HEALTHY (WAL-Mode)" and "<" not in e(ok, "wal", None, NOW)["val"]
    # Ansicht: Speicher vor Datei; Datei nur wenn Speicher leer; Fehler -> keine Daten, kein Wurf
    v = _dbv_view({"now": lambda: NOW, "path": "/x", "rs": lambda: {"maint": {"qc": ok}}, "fileqc": lambda p: (_ for _ in ()).throw(AssertionError("Datei nicht lesen")), "jm": lambda: ("wal", None)})
    assert v["state"] == "ok", v
    v = _dbv_view({"now": lambda: NOW, "path": "/x", "rs": lambda: {"maint": None}, "fileqc": lambda p: dict(ok, t=NOW - 100), "jm": lambda: ("wal", None)})
    assert v["state"] == "ok", v
    v = _dbv_view({"now": lambda: NOW, "path": "/x", "rs": lambda: {}, "fileqc": lambda p: None, "jm": lambda: ("wal", None)})
    assert v["state"] == "unbekannt", v
    v = _dbv_view({"now": lambda: NOW, "path": "/x", "rs": lambda: (_ for _ in ()).throw(RuntimeError("kaputt")), "jm": lambda: ("wal", None)})
    assert v["state"] == "unbekannt" and v["val"] == "keine Daten", v
    _DBV["err"] = None
    _DBV["n"] = 0
    return "dbVis ok (HEALTHY nur mit gelaufenem quick_check ok, WAL und Alter bis 8 Tage; Befund = FEHLER; kein WAL, nicht prüfbar, veraltet = WARNUNG; Zwischenspeicher, nie ein quick_check in der Seite)"


app.after_request(_dbv_after)
try:
    _DBV["selftest"] = _selftest_dbvis()
    print("dbVis aktiv: %s" % _DBV["selftest"], flush=True)
except Exception as _dbv_e:
    _DBV["selftest"] = "dbVis Selbsttest FEHLER: %s" % _dbv_e
    print("dbVis Selbsttest FEHLER (Zeile bleibt ohne Bewertung 'keine Daten' moeglich, Seite unberuehrt):", _dbv_e, flush=True)
# ===== /dbVis =====
MK_RAB_EOF
EXPECT_RAG="7562defc18dafc55005e8a4cd0f07f75ebb1bbcd1be22c9840813d1377687ac5"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-Guard dbVis (nur dashboard.py, nur ein neuer Block). Aufruf:
  guard_db.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne dbVis (Rueckbau, byte-genau)
  guard_db.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhalten in der Sandbox
  RH_ALT=ALT_VERZ guard_db.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest: jede absichtliche Verfehlung muss erkannt werden
Kein node, kein Netz, keine echten Dateien des Dashboards: alles in temporaeren Ordnern (Flask-Test nur wenn flask importierbar - auf dem Pi in der venv)."""
import ast
import contextlib
import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import time
import types

MARK = "# ===== dbVis:"
ALLOWED_PREFIX = ("DBV_", "_DBV", "_dbv_", "_selftest_dbvis")


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block dbVis nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle dbVis nicht genau einmal: " + n.strip().splitlines()[0][:70]
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
        return "_DBVG" if "_selftest_dbvis()" in ast.unparse(n) else "#try"
    if isinstance(n, (ast.Import, ast.ImportFrom)) and all((getattr(a, "asname", None) or "").startswith("_dbv_") for a in n.names):
        return "_dbv_import"
    if isinstance(n, ast.Expr) and ast.unparse(n) == "app.after_request(_dbv_after)":
        return "_dbv_hook"
    return "#" + type(n).__name__


def top_ok(nm):
    return nm in ("_DBVG", "_dbv_import", "_dbv_hook") or nm.startswith(ALLOWED_PREFIX)


def find_top(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def calls_named(node, name):
    return [c for c in ast.walk(node) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == name]


def numconsts(tree):
    out = {}
    for x in tree.body:
        if isinstance(x, ast.Assign) and len(x.targets) == 1 and isinstance(x.targets[0], ast.Name) and x.targets[0].id.startswith("DBV_"):
            out[x.targets[0].id] = eval(compile(ast.Expression(x.value), "c", "eval"), {})
    return out


def static(alt, new, blk):
    n = 0
    ta, tn = ast.parse(alt), ast.parse(new)
    da = {ast.dump(x): top_name(x) for x in ta.body}
    dn = {ast.dump(x): top_name(x) for x in tn.body}
    gone = [da[k] for k in da if k not in dn]
    assert not gone, "dbVis aendert/entfernt bestehende Stellen: %s" % sorted(set(gone))
    added = sorted(set(dn[k] for k in dn if k not in da and not top_ok(dn[k])))
    assert not added, "dbVis fuegt ausserhalb des Blocks hinzu: %s" % added
    n += 1
    bt = rd(blk)
    bn = ast.parse(bt)
    for forb in ("requests", "urlopen", "subprocess", "os.system", "Popen", "shutil", "socket", "send_meshtastic", "send_nina", "send_dab", "app.route", "add_url_rule", "telegram", "systemctl",
                 "pkill", "Thread", "sleep(", "integrity_check", "PRAGMA quick_check", "PRAGMA wal", "PRAGMA journal_mode=", "PRAGMA journal_mode =", "executescript", "commit(", "innerHTML", "fetch(", "XMLHttp"):
        assert forb not in bt, "Block enthaelt %s" % forb
    import re
    assert not re.search(r"(?<![A-Za-z_])(eval|exec|kill)\(", bt), "Block enthaelt eval/exec/kill"
    mods = sorted(set(a.name for x in bn.body if isinstance(x, ast.Import) for a in x.names))
    assert mods == ["json", "os", "sqlite3", "threading", "time"], "Block importiert nur json/os/sqlite3/threading/time: %s" % mods
    n += 1
    # SQL: ausschliesslich zwei feste Anweisungen, nur lesend
    sql = sorted(set(c.args[0].value if c.args and isinstance(c.args[0], ast.Constant) else "<dyn>" for c in ast.walk(bn) if isinstance(c, ast.Call) and isinstance(c.func, ast.Attribute) and c.func.attr == "execute"))
    assert sql == ["PRAGMA busy_timeout=500", "PRAGMA journal_mode"], "Block fuehrt nur zwei feste Abfragen aus: %s" % sql
    conns = [f.name for f in bn.body if isinstance(f, ast.FunctionDef) for c in ast.walk(f) if isinstance(c, ast.Call) and ast.unparse(c.func).endswith("connect")]
    assert conns == ["_dbv_jm"], "sqlite3.connect nur in _dbv_jm: %s" % conns
    jm = ast.unparse(find_top(bn, "_dbv_jm"))
    assert "mode=ro" in jm and "uri=True" in jm and "timeout=0.5" in jm, "_dbv_jm: nur lesend (mode=ro), Wartezeit 0,5 s"
    opens = {f.name for f in bn.body if isinstance(f, ast.FunctionDef) and calls_named(f, "open")}
    assert opens == {"_dbv_file_qc"}, "open() nur in _dbv_file_qc: %s" % sorted(opens)
    for c in calls_named(find_top(bn, "_dbv_file_qc"), "open"):
        assert len(c.args) == 1 and [k.arg for k in c.keywords] == ["encoding"], "open() nur lesend (kein Modus)"
    hooks = [x for x in ast.walk(bn) if isinstance(x, ast.Call) and ast.unparse(x.func) == "app.after_request"]
    assert len(hooks) == 1, "genau ein after_request-Haken"
    af = ast.unparse(find_top(bn, "_dbv_after"))
    for must in ("_dbv_req.path != '/pi'", "resp.status_code != 200", "resp.direct_passthrough", "Content-Encoding", "text/html", 'id="dbvis-js"', "except Exception"):
        assert must in af.replace('\\"', '"') or must in bt, "_dbv_after: %s fehlt" % must
    vw = ast.unparse(find_top(bn, "_dbv_view"))
    assert "quick_check(" not in vw and "retention_status" in vw and "_dbv_file_qc" in vw and "_dbv_jm" in vw and "except Exception" in vw, "_dbv_view: nur Zwischenspeicher, Fehler gefangen"
    n += 1
    c = numconsts(bn)
    assert 60 <= c["DBV_JM_TTL_S"] <= 900 and 10 <= c["DBV_JM_RETRY_S"] <= 300 and 600 <= c["DBV_JM_KEEP_S"] <= 86400, "journal_mode-Fristen ausserhalb der Grenzen"
    assert 7 * 86400 < c["DBV_STALE_S"] <= 14 * 86400, "DBV_STALE_S muss ueber der Wochenfrist liegen (8..14 Tage)"
    for must in ("sdrGpsRow", "dbVisRow", "#srcCard .pp-grid", "gridColumn", "pp-row", "pp-dot", "pp-name", "pp-val", "textContent", "dbVisData"):
        assert must in bt, "JS: %s fehlt" % must
    n += 1
    return n


# ---------------- Verhalten ----------------
class FakeApp:
    def __init__(self):
        self.hooks = []

    def after_request(self, f):
        self.hooks.append(f)
        return f


def run_block(blk, lzpath="", extra=None):
    ns = {"__name__": "db_sandbox", "app": FakeApp(), "_LZ_PATH": lzpath}
    ns.update(extra or {})
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(rd(blk), "db_block", "exec"), ns)
    return ns, out.getvalue()


def mkdb(path, mode):
    c = sqlite3.connect(path)
    c.execute("PRAGMA journal_mode=%s" % mode)
    c.execute("CREATE TABLE IF NOT EXISTS t(a)")
    c.execute("INSERT INTO t VALUES(1)")
    c.commit()
    c.close()


def jm_tests(blk):
    n = 0
    tmp = tempfile.mkdtemp(prefix="db-jm-")
    try:
        ns, _ = run_block(blk)
        jm = ns["_dbv_jm"]
        clock = [1000.0]
        d = {"mono": lambda: clock[0]}
        pw, pd_ = os.path.join(tmp, "w.db"), os.path.join(tmp, "d.db")
        mkdb(pw, "WAL")
        mkdb(pd_, "DELETE")
        assert jm(pw, d) == ("wal", None), "WAL-Datei -> wal"
        n += 1
        ns["_DBV"]["jm_try_m"] = None
        assert jm(pd_, d) == ("delete", None), "DELETE-Datei -> delete"
        n += 1
        # Zwischenspeicher: innerhalb der Frist keine neue Verbindung
        calls = []
        real = sqlite3.connect
        ns["_dbv_sql"] = types.SimpleNamespace(connect=lambda *a, **k: (calls.append(1), real(*a, **k))[1])
        ns["_DBV"]["jm_try_m"] = None
        jm(pw, d)
        assert len(calls) == 1
        clock[0] += 299
        assert jm(pd_, d)[0] == "wal" and len(calls) == 1, "innerhalb von 5 min aus dem Zwischenspeicher (kein neuer Zugriff)"
        clock[0] += 2
        assert jm(pd_, d)[0] == "delete" and len(calls) == 2, "nach 5 min neu gelesen"
        n += 1
        # Lesefehler: letzter Wert bleibt bis 1 h, danach unbekannt; Wiederholung erst nach 60 s
        gone = os.path.join(tmp, "weg.db")
        with open(gone, "wb") as fh:
            fh.write(b"das ist keine Datenbank" * 50)
        clock[0] += 400
        r = jm(gone, d)
        assert r[0] == "delete" and r[1] and len(calls) == 3, "Lesefehler: letzter gelesener Wert bleibt, Fehler vermerkt: %s" % (r,)
        c0 = len(calls)
        clock[0] += 30
        jm(gone, d)
        assert len(calls) == c0, "nach einem Fehler frueestens nach 60 s wieder"
        clock[0] += 4000
        r = jm(gone, d)
        assert r[0] is None and r[1], "nach 1 h Lesefehler: journal_mode unbekannt: %s" % (r,)
        n += 1
        # fehlender Pfad / leerer Pfad
        ns2, _ = run_block(blk)
        assert ns2["_dbv_jm"]("", d) == (None, "keine Datenbank") and ns2["_dbv_jm"](os.path.join(tmp, "nix.db"), {"mono": lambda: 5000.0})[0] is None
        n += 1
        # gesperrte Datenbank (Schreiber haelt EXKLUSIV): kein Haengen, kein Wurf
        pl = os.path.join(tmp, "l.db")
        mkdb(pl, "DELETE")
        lk = sqlite3.connect(pl, isolation_level=None)
        lk.execute("BEGIN EXCLUSIVE")
        try:
            ns3, _ = run_block(blk)
            t0 = time.time()
            r = ns3["_dbv_jm"](pl, {"mono": lambda: 1.0})
            dt = time.time() - t0
            assert dt < 2.5 and isinstance(r, tuple), "gesperrte DB: Antwort in %.2f s" % dt
        finally:
            lk.execute("ROLLBACK")
            lk.close()
        n += 1
        # parallel: zweiter Aufrufer bekommt den Zwischenwert, kein zweiter Zugriff
        ns4, _ = run_block(blk)
        ns4["_DBV"]["jm"], ns4["_DBV"]["jm_try_m"] = "wal", 1.0
        assert ns4["_dbv_jm"](pw, {"mono": lambda: 2.0}) == ("wal", None)
        n += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return n


def file_tests(blk):
    n = 0
    tmp = tempfile.mkdtemp(prefix="db-file-")
    try:
        ns, _ = run_block(blk)
        f = ns["_dbv_file_qc"]
        p = os.path.join(tmp, "l.db")
        assert f(p) is None, "Datei fehlt -> None"
        qc = {"ok": True, "rows": ["ok"], "ms": 10, "err": None, "t": 12345}
        with open(p + ".maint.json", "w") as fh:
            json.dump({"qc": qc, "ckpt": None}, fh)
        r = f(p)
        assert r == qc, r
        assert f(p) is r, "unveraendert: aus dem Zwischenspeicher (gleiches Objekt)"
        time.sleep(0.02)
        with open(p + ".maint.json", "w") as fh:
            json.dump({"qc": dict(qc, ok=False, rows=["x"])}, fh, indent=1)
        assert f(p)["ok"] is False, "geaenderte Datei wird neu gelesen"
        n += 1
        with open(p + ".maint.json", "w") as fh:
            fh.write("{kaputt")
        assert f(p) is None, "kaputtes JSON -> None"
        with open(p + ".maint.json", "w") as fh:
            json.dump(["liste"], fh)
        assert f(p) is None
        with open(p + ".maint.json", "w") as fh:
            json.dump({"qc": "text"}, fh)
        assert f(p) is None, "qc kein dict -> None"
        with open(p + ".maint.json", "w") as fh:
            json.dump({"qc": qc, "pad": "x" * 70000}, fh)
        assert f(p) is None, "ueber 64 KB wird nicht gelesen"
        os.unlink(p + ".maint.json")
        assert f(p) is None
        n += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return n


class FakeResp:
    def __init__(self, body, status=200, mime="text/html", enc=None, passthrough=False):
        self.body, self.status_code, self.mimetype, self.direct_passthrough = body, status, mime, passthrough
        self.headers = {"Content-Encoding": enc} if enc else {}
        self.set_calls = 0

    def get_data(self, as_text=False):
        return self.body

    def set_data(self, b):
        self.body = b
        self.set_calls += 1


def after_tests(blk):
    n = 0
    old = sys.modules.get("flask")
    path = {"p": "/pi"}
    fl = types.ModuleType("flask")
    class _Req:
        @property
        def path(self):
            return path["p"]
    fl.request = _Req()
    sys.modules["flask"] = fl
    try:
        qc_bad = {"ok": False, "rows": ["</script><b>x"], "ms": 1, "err": None, "t": int(time.time())}
        ns, _ = run_block(blk, "/nonexistent.db", {"_lz_dbm": types.SimpleNamespace(retention_status=lambda: {"maint": {"qc": qc_bad}})})
        after = ns["app"].hooks[0]
        assert after is ns["_dbv_after"]
        html = "<html><body><div id='srcCard'></div></body></html>"
        r = after(FakeResp(html))
        assert r.set_calls == 1 and r.body.count('id="dbVisData"') == 1 and r.body.count('id="dbvis-js"') == 1 and r.body.index("dbVisData") < r.body.rindex("</body>"), "Einbau vor </body>"
        m = r.body[r.body.index('id="dbVisData">') + 15:]
        data = json.loads(m[:m.index("</script>")].replace("\\u003c", "<"))
        assert data["state"] == "ausgefallen" and data["name"] == "SQLite DB:" and data["val"].startswith("FEHLER"), data
        assert "</script><b>" not in r.body, "kein rohes </script> aus Daten im Seitentext"
        b1 = r.body
        r = after(FakeResp(b1))
        assert r.set_calls == 0 and r.body == b1, "zweimal nichts"
        r = after(FakeResp("<p>ohne Ende</p>"))
        assert r.body.startswith("<p>ohne Ende</p>") and 'id="dbVisData"' in r.body, "ohne </body> angehaengt"
        n += 1
        for kw, label in (({"status": 404}, "404"), ({"mime": "application/json"}, "JSON"), ({"enc": "gzip"}, "gzip"), ({"passthrough": True}, "Stream")):
            r = after(FakeResp(html, **kw))
            assert r.set_calls == 0 and r.body == html, "keine Aenderung bei %s" % label
        for pth in ("/", "/funk", "/api/time", "/pi/x", "/pi2"):
            path["p"] = pth
            r = after(FakeResp(html))
            assert r.set_calls == 0, "nur /pi: %s" % pth
        path["p"] = "/pi"
        n += 1
        # Fehler in der Ansicht: Seite bleibt unveraendert (kein Wurf)
        ns["_dbv_view"] = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            r = after(FakeResp(html))
        assert r.body == html and "dbVis /pi" in out.getvalue(), "Fehler -> Seite unberuehrt"
        n += 1
    finally:
        if old is None:
            sys.modules.pop("flask", None)
        else:
            sys.modules["flask"] = old
    return n


def e2e_tests(blk):
    n = 0
    tmp = tempfile.mkdtemp(prefix="db-e2e-")
    try:
        p = os.path.join(tmp, "lagezentrum.db")
        mkdb(p, "WAL")
        now = int(time.time())
        qc = {"ok": True, "rows": ["ok"], "ms": 80, "err": None, "t": now - 3600}
        calls = {"n": 0}

        def rs():
            calls["n"] += 1
            return {"maint": {"qc": None, "stats": {"bytes": 8388608, "wal_bytes": 0}}}
        ns, _ = run_block(blk, p, {"_lz_dbm": types.SimpleNamespace(retention_status=rs)})
        v = ns["_dbv_view"]()
        assert v["state"] == "unbekannt" and v["val"] == "noch ungeprüft (WAL-Mode)", "ohne Prüfergebnis nicht HEALTHY: %s" % v
        with open(p + ".maint.json", "w") as fh:
            json.dump({"qc": qc}, fh)
        v = ns["_dbv_view"]()
        assert v["state"] == "ok" and v["val"] == "HEALTHY (WAL-Mode)", "echte DB (WAL) + Datei mit quick_check ok -> HEALTHY: %s" % v
        with open(p + ".maint.json", "w") as fh:
            json.dump({"qc": dict(qc, ok=False, rows=["database disk image is malformed"])}, fh)
        v = ns["_dbv_view"]()
        assert v["state"] == "ausgefallen" and "malformed" in v["val"], v
        # kein WAL (echte Datei im DELETE-Modus)
        p2 = os.path.join(tmp, "d.db")
        mkdb(p2, "DELETE")
        ns2, _ = run_block(blk, p2, {"_lz_dbm": types.SimpleNamespace(retention_status=lambda: {"maint": {"qc": qc}})})
        v = ns2["_dbv_view"]()
        assert v["state"] == "alt" and "kein WAL-Mode (journal_mode=delete)" in v["val"], v
        n += 1
        # Geschwindigkeit: mit Zwischenspeicher weit unter 1 ms je Aufruf (die Seite wird nicht langsamer)
        with open(p + ".maint.json", "w") as fh:
            json.dump({"qc": qc}, fh)
        ns["_dbv_view"]()
        t0 = time.perf_counter()
        for _ in range(2000):
            ns["_dbv_view"]()
        per = (time.perf_counter() - t0) / 2000
        assert per < 0.002, "Ansicht zu langsam: %.3f ms" % (per * 1000)
        n += 1
        # Wartung nicht vorhanden (alte database.py): keine Daten statt Wurf
        ns3, _ = run_block(blk, p, {})
        v = ns3["_dbv_view"]()
        assert v["state"] in ("ok", "unbekannt", "alt"), v
        n += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return n


def flask_test(blk):
    try:
        import flask
    except Exception:
        return 0
    tmp = tempfile.mkdtemp(prefix="db-flask-")
    try:
        p = os.path.join(tmp, "lagezentrum.db")
        mkdb(p, "WAL")
        qc = {"ok": True, "rows": ["ok"], "ms": 80, "err": None, "t": int(time.time()) - 60}
        app = flask.Flask("dbvtest")

        @app.route("/pi")
        def pi():
            return "<html><body><div id='srcCard'><div class='pp-grid'></div></div></body></html>"

        @app.route("/funk")
        def funk():
            return "<html><body>x</body></html>"
        ns = {"__name__": "db_flask", "app": app, "_LZ_PATH": p, "_lz_dbm": types.SimpleNamespace(retention_status=lambda: {"maint": {"qc": qc}})}
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(rd(blk), "db_block", "exec"), ns)
        c = app.test_client()
        h = c.get("/pi").get_data(as_text=True)
        assert 'id="dbVisData"' in h and "HEALTHY (WAL-Mode)" in h and h.count('id="dbvis-js"') == 1, "Flask: /pi enthaelt die Zeile"
        assert 'id="dbVisData"' not in c.get("/funk").get_data(as_text=True), "Flask: /funk unberuehrt"
        return 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def behav(alt, new, blk):
    n = 0
    ns, out = run_block(blk)
    assert "dbVis aktiv: dbVis ok" in out, "Block-Selbsttest meldet nicht ok: %s" % out[:300]
    assert len(ns["app"].hooks) == 1 and ns["_DBV"]["n"] == 0 and ns["_DBV"]["err"] is None, "Selbsttest hinterlaesst Zustand / genau ein Haken"
    n += 1
    n += jm_tests(blk)
    n += file_tests(blk)
    n += after_tests(blk)
    n += e2e_tests(blk)
    n += flask_test(blk)
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_DB_NOSTATIC") == "1" else static(alt, new, blk)
    if os.environ.get("RH_DB_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau des Blocks ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    assert rd(blk).rstrip("\n") in new
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk)
    print("OK guard dbVis: %d Pruefungen, 0 fehlerhaft" % n)
    return n


# (Name, Zielzeichenfolge, Ersatz, norev)
MUT = [
    ("D1 quick_check in der Seite", 'str(con.execute("PRAGMA journal_mode").fetchone()[0]).lower()', 'str(con.execute("PRAGMA quick_check").fetchone()[0]).lower()', 0),
    ("D2 Verbindung nicht schreibgeschuetzt", '"file:%s?mode=ro"', '"file:%s?mode=rw"', 0),
    ("D3 journal_mode setzen", 'con.execute("PRAGMA journal_mode").fetchone()', 'con.execute("PRAGMA journal_mode=WAL").fetchone()', 0),
    ("D4 Wartezeit 5 s", "timeout=0.5)", "timeout=5)", 0),
    ("D5 Frist journal_mode 1 s", "DBV_JM_TTL_S = 300 ", "DBV_JM_TTL_S = 1 ", 0),
    ("D6 Alterstoleranz 30 Tage", "DBV_STALE_S = 8 * 86400", "DBV_STALE_S = 30 * 86400", 0),
    ("D7 Alterstoleranz 3 Tage", "DBV_STALE_S = 8 * 86400", "DBV_STALE_S = 3 * 86400", 0),
    ("D8 Befund wird nur gelb", 'return {"state": "ausgefallen", "name": "SQLite DB:", "val": "FEHLER: quick_check-Befund', 'return {"state": "alt", "name": "SQLite DB:", "val": "FEHLER: quick_check-Befund', 0),
    ("D9 kein WAL bleibt gruen", 'if jm and jm != "wal":', 'if jm and jm != "wal" and False:', 0),
    ("D10 ohne Pruefung HEALTHY", 'if qc is None:\n        return {"state": "unbekannt"', 'if qc is None and False:\n        return {"state": "unbekannt"', 0),
    ("D11 nicht pruefbar gilt als gesund", 'if qc.get("ok") is not True:', 'if False:', 0),
    ("D12 veraltet ignoriert", 'if age is None or age > DBV_STALE_S:', 'if False:', 0),
    ("D13 Zeitstempel fehlt gilt als frisch", 'if age is None or age > DBV_STALE_S:', 'if age is not None and age > DBV_STALE_S:', 0),
    ("D14 journal_mode unbekannt gilt als gesund", "if not jm:\n        return", "if False:\n        return", 0),
    ("D15 Befund hinter kein-WAL", 'if isinstance(qc, dict) and qc.get("ok") is False:\n        rows', 'if isinstance(qc, dict) and qc.get("ok") is False and jm == "wal":\n        rows', 0),
    ("D16 Datei vor Speicher", 'qc = mt.get("qc") if isinstance(mt.get("qc"), dict) else None\n        if qc is None:\n            qc = d["fileqc"](path) if "fileqc" in d else _dbv_file_qc(path)', 'qc = d["fileqc"](path) if "fileqc" in d else _dbv_file_qc(path)\n        if qc is None:\n            qc = mt.get("qc") if isinstance(mt.get("qc"), dict) else None', 0),
    ("D17 Datei ohne Groessengrenze", "if st.st_size > DBV_FILE_MAX:", "if False:", 0),
    ("D18 Datei ohne Zwischenspeicher", "if _DBV[\"file_key\"] == key:\n            return _DBV[\"file\"]", "if False:\n            return _DBV[\"file\"]", 0),
    ("D19 Lesefehler gilt ewig", "m - _DBV[\"jm_ok_m\"] > DBV_JM_KEEP_S", "False", 0),
    ("D20 Lesefehler loescht sofort", "if _DBV[\"jm_ok_m\"] is None or m - _DBV[\"jm_ok_m\"] > DBV_JM_KEEP_S:", "if True:", 0),
    ("D21 nach Fehler sofort wiederholen", "wait = DBV_JM_TTL_S if _DBV[\"jm_err\"] is None else DBV_JM_RETRY_S", "wait = DBV_JM_TTL_S if _DBV[\"jm_err\"] is None else 0", 0),
    ("D22 Zwischenspeicher aus", "if last is not None and m - last < wait:", "if False:", 0),
    ("D23 Haken auch auf anderen Seiten", 'if _dbv_req.path != "/pi" or', 'if _dbv_req.path not in ("/pi", "/funk") or', 0),
    ("D24 Status nicht geprueft", "or resp.status_code != 200", "or False", 0),
    ("D25 gzip nicht geprueft", 'if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":', 'if (resp.mimetype or "") != "text/html":', 0),
    ("D26 doppelter Einbau moeglich", "if 'id=\"dbvis-js\"' in body:", "if False:", 0),
    ("D27 JSON ohne Maskierung", '.replace("<", "\\\\u003c")', "", 0),
    ("D28 Fehler wird nicht gefangen", 'except Exception as e:\n        print("dbVis /pi:", e, flush=True)', 'except ZeroDivisionError as e:\n        print("dbVis /pi:", e, flush=True)', 0),
    ("D29 Ansicht wirft", 'except Exception as e:\n        _DBV["err"] = str(e)[:100]', 'except ZeroDivisionError as e:\n        _DBV["err"] = str(e)[:100]', 0),
    ("D30 Selbsttest hinterlaesst Zustand", '    _DBV["err"] = None\n    _DBV["n"] = 0\n', "", 0),
    ("D31 Haken doppelt", "app.after_request(_dbv_after)\ntry:", "app.after_request(_dbv_after)\napp.after_request(_dbv_after)\ntry:", 0),
    ("D32 Zeile nicht ueber die ganze Breite", "r.style.gridColumn='1 / -1';", "", 0),
    ("D33 Zeile nicht hinter der GPS-Zeile", "document.getElementById('sdrGpsRow')||document.getElementById('sdrPiRow')", "document.getElementById('sdrPiRow')", 0),
    ("D34 stille Zusatzaenderung: Seite /pi", "def page_pi():\n    data_store[\"health\"]", "def page_pi():\n    data_store[\"healthx\"]", 1),
    ("D36 Name ohne Doppelpunkt", '"name": "SQLite DB:", "val": "HEALTHY (WAL-Mode)"', '"name": "SQLite DB", "val": "HEALTHY (WAL-Mode)"', 0),
    ("D37 HEALTHY-Text falsch", '"val": "HEALTHY (WAL-Mode)"', '"val": "HEALTHY"', 0),
    ("D38 sqlite3 schreibend importiert/Prozess", "import threading as _dbv_th", "import threading as _dbv_th\nimport subprocess as _dbv_sp", 0),
]


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    bad = []
    done = 0
    for name, a, b, norev in MUT:
        w = tempfile.mkdtemp(prefix="db-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            B = rd(blk).rstrip("\n")
            assert (a in B) or norev, "%s: Stelle nicht im Block" % name
            if a in B:
                assert base_new.count(B) == 1
                mnew = base_new.replace(B, B.replace(a, b))
            else:
                assert base_new.count(a) == 1, "%s: Stelle nicht eindeutig" % name
                mnew = base_new.replace(a, b)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(mnew)
            if norev:
                os.environ["RH_DB_NOREV"] = "1"
            else:
                os.environ.pop("RH_DB_NOREV", None)
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
            os.environ.pop("RH_DB_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation dbVis: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
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
        print("guard dbVis FEHLER: %s" % e)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach relWatch commit30" "$KNOWN_D16N" "dbVis schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      dbVis passt nur auf den Stand Stand nach relWatch commit30 (dashboard.py 874452e6491a74c5). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
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
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" dbVis dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer dbVis nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" dbVis dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: dbVis im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne dbVis ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard dbVis meldet Verstoss"; }
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

NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: dbVis ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-dbvis-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG dbvis=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "dbVis|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-dbvis-$TS" ]] && cp -a "$F.bak-dbvis-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-dbvis-$TS" ]] && { cmp -s "$F" "$F.bak-dbvis-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK dbVis schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-dbvis-$TS"
  { ls -1t "$F.bak-dbvis-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-dbvis-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-dbvis-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'dbVis aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; dbVis aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- dbVis: /pi zeigt die Zeile (nur aus dem Zwischenspeicher), Kachelreihenfolge unveraendert ----
DBV=$("${CURL[@]}" "$B/pi" 2>/dev/null | python3 -c '
import sys, re, json
h = sys.stdin.read()
o0 = open(sys.argv[1], encoding="utf-8", errors="replace").read()
toks = ("doPrepperRestore", "Projektbeschreibung", "srcCard")
sig = lambda t: [k for k in sorted(toks, key=lambda k: t.find(k) if k in t else 10**9) if k in t]
if sig(h) != sig(o0):
    print("REIHENFOLGE %s -> %s" % (sig(o0), sig(h))); sys.exit(0)
if h.count("id=\"dbVisData\"") != 1 or h.count("id=\"dbvis-js\"") != 1:
    print("FEHLT daten=%d js=%d" % (h.count("id=\"dbVisData\""), h.count("id=\"dbvis-js\""))); sys.exit(0)
m = re.search(r"id=\"dbVisData\">(.*?)</script>", h, re.S)
try:
    d = json.loads(m.group(1))
    assert d["name"] == "SQLite DB:" and d["val"] and d["state"] in ("ok", "alt", "ausgefallen", "unbekannt")
except Exception as e:
    print("DATEN-FEHLER %s" % str(e)[:80]); sys.exit(0)
if h.rfind("</body>") < 0 or h.rfind("dbvis-js") > h.rfind("</body>") or h.rfind("dbVisData") > h.rfind("</body>") or h.find("sdrGpsRow") < 0:
    print("SKRIPT-LAGE"); sys.exit(0)
print("OK state=%s val=%s" % (d["state"], d["val"]))
' "$W/pi0.html" || echo "FEHLER python")
case "$DBV" in
  OK*) echo "OK /pi zeigt die Zeile: SQLite DB: ${DBV#OK state=} (Kachelreihenfolge unveraendert, Daten und Skript innerhalb der Seite vor dem Seitenende, Ankerzeile sdrGpsRow vorhanden)";;
  *) rbx "/pi-Pruefung dbVis fehlgeschlagen: $DBV";;
esac
case "$DBV" in *state=ok*) ;; *) echo "HINWEIS dbVis: Zustand nicht gruen ($DBV) - das ist die echte Aussage der Pruefung (z. B. noch keine quick_check-Pruefung in dieser Laufzeit/Datei oder echter Befund), kein Fehler des Patches";; esac
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E dbVis"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "dbVis aktiv: dbVis ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'dbVis aktiv: dbVis ok' ($(echo "$JD" | grep -F dbVis | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein dbVis-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-dbvis-$TS" ]] && echo "Backup: dashboard.py.bak-dbvis-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-dbvis-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine dbvis-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s http://127.0.0.1:5000/pi | grep -o dbVisData"
echo "  curl -s http://127.0.0.1:5000/pi | grep -o 'SQLite DB:'"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep dbVis"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG dbvis=1 fertig"
