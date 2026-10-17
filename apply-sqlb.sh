#!/bin/bash
set -euo pipefail
# sqlB (Teil B der SQLite-Umstellung, nach sqlA): prepper_sdr.py schreibt zusaetzlich (JSON bleibt exakt wie bisher) in lagezentrum.db:
# Tabelle state (je Schluessel eine Zeile: sdr_status, broadcast_state, sqlb_writer; Upsert, waechst nicht) und DAB-Ereignisse per Upsert mit
# derselben ext_id wie sdr_manager (keine Doppel). Eigener Schreibfaden, Warteschlange 8 (voll = verwerfen), DB-Timeout 2 s, Fehler gezaehlt/gedrosselt.
# Dashboard und sdr_manager lesen sdr_status/broadcast_state zuerst aus der DB, JSON als Ersatz (fehlt/zu alt/aelter als Datei/gesperrt/Fehler/Schalter aus).
# Schalter: "db_transport" in sdr_config.json; fehlt = an (sdr_config.json wird NICHT geaendert). Aus: "db_transport": "off" eintragen.
# Aendert database.py, sdr_manager.py, prepper_sdr.py, dashboard.py; mesh_router.py, lagegeo.py bleiben unveraendert.
# Neustart prepper-sdr (warten auf frischen Status) und prepper-dashboard. Sendet nichts.
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
W=/tmp/sqlb-apply
KEEP_LAST=3
KNOWN_D16="757db430a7b9317e"     # dashboard.py nach sqlA
KNOWN_SM16="b2fdd37ba92f8aa9"    # sdr_manager.py nach sqlA
KNOWN_DB16="02040ef5aaccea68"    # database.py nach sqlA
KNOWN_SDR16="de3fad568616ffb3"   # prepper_sdr.py nach tiiFix2
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
echo "=== sqlB apply (prepper-sdr schreibt zusaetzlich in lagezentrum.db, Dashboard liest DB zuerst, JSON als Ersatz), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_P="f1baca29d502a1b5fd399a66e5a452faee9275ace8270873419425abb6de1015"
cat > "$W/patch-sqlb.py" << 'SQP_EOF'
"""sqlB-Patcher. Aufruf: patch-sqla.py ART QUELLE ZIEL BLOCK EDITS   (ART = db | sm | sdr | dash). Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis."""
import sys
kind, src, dst, blk, edp = sys.argv[1:6]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E, ANCH = {"db": (g["DB_EDITS"], g["DB_ANCHOR"]), "sm": (g["SM_EDITS"], g["SM_ANCHOR"]), "sdr": (g["SDR_EDITS"], g["SDR_ANCHOR"]), "dash": (g["DASH_EDITS"], g["DASH_ANCHOR"])}[kind]
s = open(src, encoding="utf-8").read()
B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
MARK = B.splitlines()[0]
name = {"db": "database", "sm": "sdr_manager", "sdr": "prepper_sdr", "dash": "dashboard"}[kind]
if MARK in s:
    rest = s.replace(B, "", 1)
    ok = s.count(B) == 1 and all(rest.count(n) == 1 for o, n in E)
    if not ok:
        print("%s: sqlB teilweise/anders vorhanden" % name); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: sqlB schon drin" % name); raise SystemExit(0)
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
print("%s: %d Stellen + Block sqlB" % (name, len(E)))
SQP_EOF
EXPECT_E="cef84c64a6c90c3da965ceee09dc976fe903e4ae1d9ec39eb0db51e709fc4ff6"
cat > "$W/edits.py" << 'SQE_EOF'
# sqlB: Stellen (alt, neu) je Datei. Jede alte Stelle muss genau einmal vorkommen.
DB_EDITS = [
('''    print(selftest_retention())
''', '''    print(selftest_retention())
    print(selftest_state())
'''),
]
DB_ANCHOR = '\n\nif __name__ == "__main__":\n'

SM_EDITS = [
('''def _load(path, default=None):
    try:''', '''def _load(path, default=None):
    if os.path.basename(str(path)) in ("sdr_status.json", "broadcast_state.json") and "sqlb_load" in globals():   # sqlB: DB zuerst, JSON als Ersatz
        return sqlb_load(path, default)
    try:'''),
('''    print(selftest_sqla())
''', '''    print(selftest_sqla())
    print(selftest_sqlb())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'

SDR_EDITS = [
('''def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)
''', '''def write_json(path, obj):
    tmp = path + ".tmp"
    s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(s)
    os.replace(tmp, path)
    w = globals().get("_SQLB_W")   # sqlB: zusaetzlich in lagezentrum.db (nur im Dienst, eigener Faden, nie blockierend)
    if w is not None:
        w.offer(path, s)
'''),
('''    if a == "run":
        Planner(BASE).loop()''', '''    if a == "run":
        _SQLB_W.start(BASE)   # sqlB
        Planner(BASE).loop()'''),
('''        selftest_teil4()
    elif a in''', '''        selftest_teil4()
        selftest_sqlb()
    elif a in'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'

DASH_EDITS = [
('''"retention": _lz_dbm.retention_status() if hasattr(_lz_dbm, "retention_status") else None}}''',
 '''"retention": _lz_dbm.retention_status() if hasattr(_lz_dbm, "retention_status") else None,
                                                  "transport": _lz_mgr.transport_status(_SDR_BASE) if hasattr(_lz_mgr, "transport_status") else None}}'''),
('''"hist": _lz_mgr.t4_history(path, 10), "pre": dict(st["pre"]),''',
 '''"hist": _lz_mgr.t4_history(path, 10), "pre": dict(st["pre"]),
         "tr": _lz_mgr.transport_status(base) if hasattr(_lz_mgr, "transport_status") else None,'''),
("""t.appendChild(el('div','title','📡 SDR-Status'));t._l=[line(t),line(t),line(t),line(t),line(t),line(t)];""",
 """t.appendChild(el('div','title','📡 SDR-Status'));t._l=[line(t),line(t),line(t),line(t),line(t),line(t),line(t)];"""),
("""t._b.style.display=pre.on?'':'none';""",
 """var tr=D.tr||null;L[6].textContent=tr?(tr.line||''):'';L[6].style.color=(tr&&tr.ok)?'#64748b':'#fdba74';
t._b.style.display=pre.on?'':'none';"""),
]
DASH_ANCHOR = "# ===== /sqlA =====\n"
SQE_EOF
EXPECT_BDB="861a3c357cea0759487c436f8d6d5d59f2ae1b034a71d4cbe5d5deaa8bf9f3e6"
cat > "$W/db_block.py" << 'SQBD_EOF'
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
SQBD_EOF
EXPECT_BSM="9e45c5f500e92e822a6a9d4fe08b336a65bed99213dba14ca7adb63e8ba82ffc"
cat > "$W/sm_block.py" << 'SQBS_EOF'
# ---------------------------------------------------------------- sqlB (DB zuerst, JSON als Ersatz)
# sdr_status.json / broadcast_state.json: zuerst lagezentrum.db (Tabelle state, von prepper-sdr zusaetzlich geschrieben), JSON als Ersatz, wenn
# die DB-Zeile fehlt, zu alt ist (Status > 90 s, Rundfunk-Zustand > 150 s), aelter als die JSON-Datei, gesperrt/fehlerhaft oder der Schalter aus ist
# (sdr_config.json "db_transport": "off"; fehlt = an). Der Inhalt ist in beiden Faellen derselbe JSON-Text -> Herzschlag/pid, Rollen, TII, Alarme,
# Uebernahme und kartevec rechnen identisch. Nur lesen (mode=ro, Timeout 1 s), nie Anlegen.
SQLB_KEYS = {"sdr_status.json": ("sdr_status", 90), "broadcast_state.json": ("broadcast_state", 150)}
SQLB_CACHE_S = 2.0
SQLB_SLACK_S = 2.0
SQLB_OFF = ("off", "aus", "0", "false", "nein", "no")
_SQLB = {"cache": {}, "src": {}, "flag": {}}


def _load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if v is not None else default
    except Exception:
        return default


def sqlb_flag(base):
    """Schalter db_transport aus sdr_config.json (nur lesen; fehlt = an)."""
    f = os.path.join(base, "sdr_config.json")
    try:
        _s = os.stat(f)
        mt = (_s.st_mtime_ns, _s.st_size, _s.st_ino)
    except OSError:
        mt = None
    c = _SQLB["flag"].get(f)
    if c and c[0] == mt:
        return c[1]
    d = _load_json(f, {}) if mt else {}
    on = not (isinstance(d, dict) and "db_transport" in d and str(d.get("db_transport")).strip().lower() in SQLB_OFF)
    _SQLB["flag"][f] = (mt, on)
    return on


def _sqlb_row(dbp, key, now):
    c = _SQLB["cache"].get((dbp, key))
    if c and 0 <= now - c[0] < SQLB_CACHE_S:
        return c[1]
    r = db.state_get(key, dbp, 1.0) if db is not None and hasattr(db, "state_get") else {"ok": False, "err": "database.py ohne state"}
    _SQLB["cache"][(dbp, key)] = (now, r)
    return r


def sqlb_load(path, default=None, now=None):
    """DB zuerst, JSON als Ersatz (siehe oben). Merkt die Quelle je Datei fuer die Anzeige."""
    name = os.path.basename(str(path))
    key, max_age = SQLB_KEYS[name]
    base = os.path.dirname(str(path)) or "."
    now = time.time() if now is None else now
    info = {"src": "json", "why": None, "db_age_s": None, "json_age_s": None, "t": int(now)}
    try:
        try:
            mt = os.path.getmtime(path)
        except OSError:
            mt = None
        info["json_age_s"] = int(now - mt) if mt else None
        if not sqlb_flag(base):
            info.update(src="json", why="DB-Transport aus (sdr_config.json db_transport)")
        else:
            r = _sqlb_row(os.path.join(base, "lagezentrum.db"), key, now)
            why = None
            if not r.get("ok"):
                why = r.get("err") or "DB-Fehler"
            else:
                st = float(r.get("src_t") or r.get("ts") or 0)
                info["db_age_s"] = int(now - st)
                if now - st > max_age and (not mt or mt > st + SQLB_SLACK_S):
                    why = "DB-Stand zu alt (%d s > %d s)" % (now - st, max_age)   # zu alt UND Datei neuer/fehlt; beide gleich alt = gleicher Stand (prepper-sdr schreibt nur bei Aenderung)
                elif mt and st < mt - SQLB_SLACK_S:
                    why = "DB-Stand aelter als JSON-Datei"
                else:
                    v = json.loads(r["text"])
                    info["src"] = "db"
                    _SQLB["src"][name] = info
                    return v if v is not None else default
            info.update(src="json-fallback", why=why)
    except Exception as e:
        info.update(src="json-fallback", why=str(e)[:100])
    _SQLB["src"][name] = info
    return _load_json(path, default)


def t2_event_rows(bs):
    """DAB-Ereignisse aus broadcast_state t2.ev - genau dieselben Zeilen wie t2_sync (gleiche ext_id, keine Doppel)."""
    t2 = bs.get("t2") if isinstance(bs, dict) and isinstance(bs.get("t2"), dict) else {}
    out = []
    for e in (t2.get("ev") or [])[-T2_EV_SYNC:] if isinstance(t2.get("ev"), list) else []:
        if isinstance(e, dict) and e.get("id") and isinstance(e.get("t"), (int, float)):
            out.append({"source": "DAB", "type": str(e.get("k") or "fig"), "severity": "info", "headline": str(e.get("text") or "")[:160],
                        "text": e.get("text"), "created": int(e["t"]), "updated": int(e["t"]), "expires": int(e["t"]) + 24 * 3600, "ext_id": str(e["id"])[:80]})
    return out


def transport_status(base, now=None):
    """Anzeige: Quelle je Datei (db / json-fallback / json), Alter, Schreibzaehler aus prepper-sdr."""
    now = time.time() if now is None else now
    out = {"on": True, "items": {}, "writer": None, "ok": False, "line": ""}
    try:
        out["on"] = sqlb_flag(base)
        for name in SQLB_KEYS:
            _load(os.path.join(base, name), {})
            out["items"][name] = dict(_SQLB["src"].get(name) or {})
        r = _sqlb_row(os.path.join(base, "lagezentrum.db"), "sqlb_writer", now) if out["on"] else {"ok": False}
        if r.get("ok"):
            w = json.loads(r["text"]) if r.get("text") else {}
            w["age_s"] = int(now - float(r.get("src_t") or r.get("ts") or now))
            out["writer"] = w
        srcs = [i.get("src") for i in out["items"].values()]
        err = (out["writer"] or {}).get("err") or 0
        if not out["on"]:
            out["line"] = "Datenquelle: JSON (DB-Transport aus, sdr_config.json db_transport)"
            out["ok"] = True
        elif srcs and all(s == "db" for s in srcs):
            out["ok"] = True
            out["line"] = "Datenquelle: DB (Ersatz JSON bereit)" + (" · Schreibfehler %d" % err if err else "")
        else:
            bad = ["%s: %s" % ("Status" if n == "sdr_status.json" else "Rundfunk", i.get("why") or "?") for n, i in out["items"].items() if i.get("src") != "db"]
            out["line"] = "Datenquelle: JSON-Ersatz (%s)" % "; ".join(bad)
    except Exception as e:
        out["line"] = "Datenquelle: JSON (Anzeigefehler %s)" % str(e)[:60]
    return out


def selftest_sqlb():
    import tempfile
    d = tempfile.mkdtemp(prefix="sqlb-")
    p = os.path.join(d, "lagezentrum.db")
    now = int(time.time())
    assert db.migrate(p) and db.migrate_t2(p)
    fs, fb = os.path.join(d, "sdr_status.json"), os.path.join(d, "broadcast_state.json")
    st = {"t": now, "pid": os.getpid(), "active": "dab", "src": "json"}
    bs = {"t2": {"ev": [{"id": "tii:11D:0702:%d" % now, "t": now - 30, "k": "tii", "text": "11D TII 07/02 neu"}], "roles": {"s1": {"sn": "1"}}},
          "dab": {"11D": {"rx": True, "t": now, "demod": {"t": now, "snr": 11.0}}}}
    _write_json(fs, st)
    _write_json(fb, bs)
    mt = os.path.getmtime(fs)
    clear = lambda: _SQLB["cache"].clear()
    assert db.state_put("sdr_status", json.dumps(dict(st, src="db")), mt, p) and db.state_put("broadcast_state", json.dumps(bs), os.path.getmtime(fb), p)
    clear()
    assert _load(fs)["src"] == "db" and _SQLB["src"]["sdr_status.json"]["src"] == "db" and _load(fb) == bs
    ref = t2_status(d, p, now)
    ref.pop("now", None)
    assert transport_status(d, now)["line"].startswith("Datenquelle: DB (Ersatz JSON bereit)")
    real_get = db.state_get
    try:
        db.state_get = lambda *a, **k: {"ok": False, "err": "database is locked"}                         # gesperrt -> JSON
        clear()
        assert _load(fs)["src"] == "json" and _SQLB["src"]["sdr_status.json"]["why"] == "database is locked"
        r2 = t2_status(d, p, now)
        r2.pop("now", None)
        assert r2 == ref, "Ersatz JSON rechnet anders"                                                      # gleiche Rollen/TII/Alarme/Uebernahme
        assert heartbeat_row(_load(fs), now) is not None                                                   # Herzschlag/pid weiter erkannt
        assert "JSON-Ersatz" in transport_status(d, now)["line"]
        def boom(*a, **k):
            raise RuntimeError("kaputt")
        db.state_get = boom                                                                                 # Ausnahme -> JSON, nie leer
        clear()
        assert _load(fs)["src"] == "json" and _load(fb) == bs
    finally:
        db.state_get = real_get
    assert db.state_put("sdr_status", json.dumps(dict(st, src="db")), now - 200, p)                         # zu alt -> JSON
    clear()
    assert _load(fs)["src"] == "json" and "zu alt" in _SQLB["src"]["sdr_status.json"]["why"]
    assert db.state_put("sdr_status", json.dumps(dict(st, src="db")), mt - 30, p)                           # aelter als JSON-Datei -> JSON
    clear()
    assert _load(fs)["src"] == "json" and "aelter als JSON" in _SQLB["src"]["sdr_status.json"]["why"]
    os.utime(fs, (now - 300, now - 300))                                                                    # beide gleich alt (nichts geaendert) -> DB = gleicher Stand
    assert db.state_put("sdr_status", json.dumps(dict(st, src="db")), now - 300, p)
    clear()
    assert _load(fs)["src"] == "db"
    assert db.state_put("sdr_status", json.dumps(dict(st, src="db")), mt, p)
    _write_json(os.path.join(d, "sdr_config.json"), {"serial": "x", "db_transport": "off"})                # Schalter aus -> rein JSON
    clear()
    assert _load(fs)["src"] == "json" and transport_status(d, now)["line"].startswith("Datenquelle: JSON (DB-Transport aus")
    _write_json(os.path.join(d, "sdr_config.json"), {"serial": "x"})
    clear()
    assert _load(fs)["src"] == "db"
    assert _load(os.path.join(d, "fehlt", "sdr_status.json"), {"leer": 1}) == {"leer": 1}                  # ohne DB und Datei: Standardwert
    t2_sync(d, p, now)                                                                                      # keine Doppel: t2_sync + direkte Zeilen
    for e in t2_event_rows(bs):
        assert db.upsert_event(e, p)
    dh = {"ev": [{"t": now - 60, "ch": "11D", "src": "BR24", "text": "Warnung Hochwasser", "warn": True}]}
    for _ in range(2):
        for e in events_from_dabhist(dh, now):
            assert db.upsert_event(e, p)
    ev = db.recent_events(20, p)
    assert len([e for e in ev if e["source"] == "DAB"]) == 1 and len([e for e in ev if e["source"] == "BR24"]) == 1, ev
    return "sdr_manager selftest sqlB ok (DB zuerst; gesperrt/Fehler/zu alt/aelter als JSON/Schalter aus -> JSON mit gleichem Ergebnis, Herzschlag bleibt, keine doppelten Ereignisse)"
SQBS_EOF
EXPECT_BSR="81440f59b5c0f39154e39efaeccd6315dd787eb71c8b2a9e3cef261208dd7f82"
cat > "$W/sdr_block.py" << 'SQBR_EOF'
# ===== sqlB: zusaetzlich zu sdr_status.json / broadcast_state.json / sdr_dabhist.json in lagezentrum.db (Tabelle state je Schluessel eine Zeile, DAB-Ereignisse per Upsert mit derselben ext_id wie sdr_manager); eigener Schreibfaden mit begrenzter Warteschlange (voll = verwerfen), Timeout 2 s, Fehler nur gezaehlt/gedrosselt geloggt; JSON-Schreiben bleibt exakt wie bisher; nur im Dienst (run), Schalter sdr_config.json db_transport (fehlt = an); kein Netz, keine Prozesse =====
import queue as _sqlb_queue

SQLB_FILES = {"sdr_status.json": "sdr_status", "broadcast_state.json": "broadcast_state", "sdr_dabhist.json": None}
SQLB_Q_MAX = 8
SQLB_LOG_S = 300
SQLB_DB_TIMEOUT_S = 2.0
SQLB_OFF = ("off", "aus", "0", "false", "nein", "no")


class SqlbWriter:
    def __init__(self):
        self.base = None
        self.q = _sqlb_queue.Queue(maxsize=SQLB_Q_MAX)
        self.th = None
        self.db = self.sm = None
        self.flag = (None, True)
        self.seen = {}
        self.log_t = 0
        self.st = {"ok": 0, "err": 0, "drop": 0, "ev": 0, "last_err": None, "err_t": None, "t": None, "started": None, "sm": None}

    def on(self):
        f = os.path.join(self.base or BASE, "sdr_config.json")
        try:
            _s = os.stat(f)
            mt = (_s.st_mtime_ns, _s.st_size, _s.st_ino)
        except OSError:
            mt = None
        if self.flag[0] != mt:
            d = load_json(f, {}) if mt else {}
            self.flag = (mt, not (isinstance(d, dict) and "db_transport" in d and str(d.get("db_transport")).strip().lower() in SQLB_OFF))
        return self.flag[1]

    def start(self, base):
        try:
            self.base = os.path.abspath(base)
            if base not in sys.path:
                sys.path.insert(0, self.base)
            import database as _d
            _d.TIMEOUT_S = SQLB_DB_TIMEOUT_S          # nur in diesem Prozess: kurzer Timeout
            self.db = _d
            try:
                import sdr_manager as _s              # gleiche Ereignis-Zeilen wie das Dashboard (keine Doppel)
                self.sm = _s
                self.st["sm"] = True
            except Exception as e:
                self.st["sm"] = "sdr_manager fehlt: %s" % str(e)[:60]
            self.th = threading.Thread(target=self._loop, name="sqlb-writer", daemon=True)
            self.th.start()
            self.st["started"] = int(time.time())
            print("sqlB: DB-Schreibfaden laeuft (%s, Schalter %s, Ereignisse %s)" % (os.path.join(self.base, "lagezentrum.db"), "an" if self.on() else "AUS",
                  "ja" if self.sm else self.st["sm"]), flush=True)
            return True
        except Exception as e:
            self.base = None
            print("sqlB: DB-Schreibfaden nicht gestartet (nur JSON): %s" % e, flush=True)
            return False

    def offer(self, path, text):
        """Aus write_json: nie blockieren, nie werfen."""
        try:
            if self.base is None or self.th is None:
                return
            name = os.path.basename(path)
            if name not in SQLB_FILES or os.path.dirname(os.path.abspath(path)) != self.base or not self.on():
                return
            self.q.put_nowait((name, text, time.time()))
        except _sqlb_queue.Full:
            self.st["drop"] += 1
        except Exception:
            pass

    def _err(self, what):
        self.st["err"] += 1
        self.st["last_err"] = ("%s: %s" % (what, self.db.last_error() if self.db else "?"))[:160]
        self.st["err_t"] = int(time.time())
        if time.time() - self.log_t > SQLB_LOG_S:
            self.log_t = time.time()
            print("sqlB: Schreibfehler (%d bisher, JSON laeuft weiter): %s" % (self.st["err"], self.st["last_err"]), flush=True)

    def _events(self, rows, path):
        for e in rows:
            k = (e.get("ext_id"), e.get("updated"), e.get("expires"), e.get("severity"))
            if self.seen.get(e.get("ext_id")) == k:
                continue
            if self.db.upsert_event(e, path):
                self.seen[e.get("ext_id")] = k
                self.st["ev"] += 1
            else:
                self._err("Ereignis")
                return
        if len(self.seen) > 2000:
            self.seen = dict(list(self.seen.items())[-1000:])

    def handle(self, name, text, t):
        path = os.path.join(self.base, "lagezentrum.db")
        key = SQLB_FILES[name]
        if key:
            if not self.db.state_put(key, text, t, path):
                self._err(key)
                return
        if self.sm is not None and name in ("broadcast_state.json", "sdr_dabhist.json"):
            d = json.loads(text)
            rows = self.sm.t2_event_rows(d) if name == "broadcast_state.json" else self.sm.events_from_dabhist(d, int(t))
            self._events(rows, path)
        self.st["ok"] += 1
        self.st["t"] = int(t)
        self.db.state_put("sqlb_writer", json.dumps(self.st, ensure_ascii=False), time.time(), path)

    def _loop(self):
        while True:
            try:
                name, text, t = self.q.get()
                self.handle(name, text, t)
            except Exception as e:
                self.st["err"] += 1
                self.st["last_err"] = str(e)[:160]
                if time.time() - self.log_t > SQLB_LOG_S:
                    self.log_t = time.time()
                    print("sqlB: Fehler im Schreibfaden (JSON laeuft weiter): %s" % e, flush=True)


_SQLB_W = SqlbWriter()


def selftest_sqlb():
    import tempfile
    d = tempfile.mkdtemp(prefix="sqlbsdr-")
    w = SqlbWriter()
    w.offer(os.path.join(d, "sdr_status.json"), "{}")                     # nicht gestartet: nichts
    assert w.q.qsize() == 0
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import database as _d
    assert _d.migrate(os.path.join(d, "lagezentrum.db")) and _d.migrate_t2(os.path.join(d, "lagezentrum.db"))
    w.base, w.db = os.path.abspath(d), _d
    try:
        import sdr_manager as _s
        w.sm = _s
    except Exception:
        w.sm = None
    w.th = True                                                            # ohne Faden: handle() direkt pruefen
    now = int(time.time())
    for i in range(SQLB_Q_MAX + 3):                                        # Warteschlange voll -> verwerfen, nie blockieren
        w.offer(os.path.join(d, "sdr_status.json"), json.dumps({"t": now, "i": i}))
    assert w.q.qsize() == SQLB_Q_MAX and w.st["drop"] == 3
    w.offer(os.path.join(d, "anders.json"), "{}")
    w.offer(os.path.join(tempfile.mkdtemp(), "sdr_status.json"), "{}")     # anderes Verzeichnis: nichts
    assert w.q.qsize() == SQLB_Q_MAX
    while not w.q.empty():
        w.handle(*w.q.get())
    r = _d.state_get("sdr_status", os.path.join(d, "lagezentrum.db"))
    assert r["ok"] and json.loads(r["text"])["i"] == SQLB_Q_MAX - 1, r
    bs = {"t2": {"ev": [{"id": "tii:x:1", "t": now, "k": "tii", "text": "TII neu"}]}}
    w.handle("broadcast_state.json", json.dumps(bs), now)
    w.handle("broadcast_state.json", json.dumps(bs), now + 60)
    if w.sm is not None:
        assert len(_d.recent_events(10, os.path.join(d, "lagezentrum.db"))) == 1 and w.st["ev"] == 1
    write_json(os.path.join(d, "sdr_config.json"), {"db_transport": "off"})
    w.flag = (None, True)
    w.offer(os.path.join(d, "sdr_status.json"), "{}")                     # Schalter aus: nichts
    assert w.q.qsize() == 0
    w.db = None
    w.base = os.path.join(d, "nicht", "da")
    w.flag = (None, True)
    w.offer(os.path.join(w.base, "sdr_status.json"), "{}")                # nie werfen
    assert w.st["err"] == 0 and _SQLB_W.th is None                         # Selbsttest startet den echten Faden nie
    print("selftest sqlB ok (Warteschlange begrenzt, voll = verwerfen, nur Dienst-Verzeichnis, Schalter aus = nur JSON, Ereignisse ohne Doppel%s)" % (
        "" if w.sm else ", sdr_manager nicht da: nur state"))
    return True
SQBR_EOF
EXPECT_BDA="0611dab2f3e29c0e2c6b9d180cddc1ba016f73a2188eb8d69c2261a175c27fe0"
cat > "$W/dash_block.py" << 'SQBA_EOF'
# ===== sqlB: Dashboard liest sdr_status.json / broadcast_state.json zuerst aus lagezentrum.db (sdr_manager.sqlb_load), JSON als Ersatz (fehlt/zu alt/aelter als Datei/gesperrt/Fehler/Schalter aus); Anzeige Datenquelle auf der SDR-Status-Kachel und in /api/sdr/live; nur lesen, sendet nichts =====
_SQB = {"selftest": None, "err": None}
_sqb_json_load = _sd_orig_load


def _sqb_load(name, default):
    if name in ("sdr_status.json", "broadcast_state.json") and _lz_mgr is not None and hasattr(_lz_mgr, "sqlb_load"):
        try:
            v = _lz_mgr.sqlb_load(_sdr_os.path.join(_SDR_BASE, name), default)
            return v if v is not None else default
        except Exception as e:
            _SQB["err"] = str(e)[:120]
    return _sqb_json_load(name, default)


def _sqb_selftest():
    assert _lz_mgr is not None and _lz_dbm is not None and hasattr(_lz_dbm, "state_put") and hasattr(_lz_mgr, "sqlb_load") and hasattr(_lz_mgr, "transport_status")
    assert "selftest sqlB ok" in _lz_mgr.selftest_sqlb()
    import tempfile
    d = tempfile.mkdtemp(prefix="sqb-")
    tr = _lz_mgr.transport_status(d)
    assert tr["line"].startswith("Datenquelle: JSON-Ersatz") and tr["items"]["sdr_status.json"]["src"] == "json-fallback"   # ohne DB: Ersatz
    now = int(_sdr_time.time())
    b = {"t": now, "fm": {"BR24": {"name": "BR24", "f": "102.0M", "pi": "0xD315", "ps": "BR24", "t": now - 60, "pty": "News", "ta": False, "tp": True, "rt": ""}}, "dab": {}}
    p31 = [{"t": now - 10, "k": "pty31", "src": "BR24", "ps": "BR24", "persist": True}]
    fb = _sdr_os.path.join(d, "broadcast_state.json")
    _lz_mgr._write_json(fb, b)
    v = _lz_mgr.sqlb_load(fb, {})                                                                      # ohne DB -> Ersatz JSON
    assert _lz_mgr._SQLB["src"]["broadcast_state.json"]["src"] == "json-fallback" and _br24_eval(v, p31, now)["state"] == "rot"   # Alarm ueber Ersatz erkannt
    pdb = _sdr_os.path.join(d, "lagezentrum.db")
    assert _lz_dbm.migrate(pdb) and _lz_dbm.state_put("broadcast_state", _lz_mgr.json.dumps(b), _sdr_os.path.getmtime(fb), pdb)
    _lz_mgr._SQLB["cache"].clear()
    v = _lz_mgr.sqlb_load(fb, {})
    assert _lz_mgr._SQLB["src"]["broadcast_state.json"]["src"] == "db" and v == b and _br24_eval(v, p31, now)["state"] == "rot"   # Alarm ueber DB erkannt
    _lz_mgr._SQLB["cache"].clear()
    js = globals().get("_T4_JS") or ""
    assert "L[6].textContent=tr?(tr.line||'')" in js
    return "sqlB selftest ok (DB zuerst, Ersatz JSON, Alarm PTY 31 ueber DB und ueber Ersatz erkannt, Anzeige Datenquelle)"


try:
    try:
        _SQB["selftest"] = _sqb_selftest()
    except Exception as _sqb_e1:
        _SQB["selftest"] = "sqlB selftest FEHLER: %s" % _sqb_e1
    if str(_SQB["selftest"]).startswith("sqlB selftest ok"):
        _sd_orig_load = _sqb_load
        _sqb_tr = _lz_mgr.transport_status(_SDR_BASE)
        print("sqlB aktiv: %s; %s" % (_SQB["selftest"], _sqb_tr.get("line")), flush=True)
    else:
        print("sqlB FEHLER: %s - Dashboard liest weiter nur JSON" % _SQB["selftest"], flush=True)
except Exception as _sqb_e:
    _SQB["err"] = str(_sqb_e)[:160]
    print("sqlB FEHLER:", _sqb_e, flush=True)
# ===== /sqlB =====
SQBA_EOF
EXPECT_G="411a0f2794794aa8266420878d6198fbde1738372d37b85ccb96459b287821c6"
cat > "$W/guard_sqlb.py" << 'SQG_EOF'
"""sqlB AST-Guard. Aufruf: guard_sqlb.py EDITS  ART ALT NEU BLOCK ... (ART = db | sm | sdr | dash) -> 0 ok, 1 Verstoss.
Ruecktausch (Block weg, Stellen zurueck) muss Byte fuer Byte die Basis ergeben (schon eingespielt: Basis = Ergebnis -> nur Struktur).
Neue Bloecke/Stellen: keine Prozesse, kein Netz, kein shell, keine Sendewege, keine Routen. prepper_sdr: nur der DB-Schreibfaden
(Importe threading/queue/json/os/sys/time/tempfile/database/sdr_manager), sonst nur threading/tempfile/os/time/json."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
EDS = {"db": g["DB_EDITS"], "sm": g["SM_EDITS"], "sdr": g["SDR_EDITS"], "dash": g["DASH_EDITS"]}
OKMOD = {"db": {"threading", "tempfile", "os", "time", "json"}, "sm": {"threading", "tempfile", "os", "time", "json"},
         "dash": {"threading", "tempfile", "os", "time", "json"},
         "sdr": {"threading", "queue", "json", "os", "sys", "time", "tempfile", "database", "sdr_manager"}}
err, new_code = [], []
a = sys.argv[2:]
for i in range(0, len(a), 4):
    kind, old, new, blk = a[i], rd(a[i + 1]), rd(a[i + 2]), rd(a[i + 3])
    B = blk.rstrip("\n") + "\n"
    E = EDS[kind]
    done = old == new and B.splitlines()[0] in old
    if new.count(B) != 1:
        err.append("%s: Block sqlB fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1) if kind != "dash" else new.replace(B, "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sqlB" % (kind, len(E)))
    new_code.append((kind, "Block", B))
    for o, n in E:
        new_code.append((kind, "Stelle", n))
BAD = ("send", "popen", "urlopen", "socket", "post", "takeover_auto", "set_auto", "autosend", "fork", "spawn", "kill")
for kind, what, code in new_code:
    name = "%s %s" % (kind, what)
    try:
        t = ast.parse(code) if what == "Block" else None
    except SyntaxError as e:
        err.append("%s: Syntax %s" % (name, e)); continue
    if t is None:
        low = code.lower()
        for k in ("subprocess", "os.system", "requests.", "urlopen", "socket", "add_url_rule", "methods=", "send(", "_send", "popen", "fork", "execv"):
            if k in low:
                err.append("%s: %s" % (name, k))
        continue
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                full = getattr(n, "module", None) or x.name
                mod = full.split(".")[0]
                if mod not in OKMOD[kind] and full != "urllib.parse":   # urllib.parse nur fuer quote() des Dateipfads (kein Netz)
                    err.append("%s: Import %s" % (name, mod))
        if isinstance(n, ast.keyword) and n.arg == "shell":
            err.append("%s: shell" % name)
        if isinstance(n, ast.Call):
            f = n.func
            nm = f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
            base = getattr(getattr(f, "value", None), "id", "") if isinstance(f, ast.Attribute) else ""
            if any(k in nm.lower() for k in BAD) or nm in ("system", "exec", "eval", "check_output", "add_url_rule", "route", "execv", "Process", "run") \
                    or base in ("subprocess", "requests", "socket", "multiprocessing"):
                err.append("%s: Aufruf %s" % (name, nm))
            if kind == "sdr" and isinstance(f, ast.Attribute) and f.attr == "Thread":
                kw = {k.arg: k.value for k in n.keywords}
                if getattr(kw.get("name"), "value", None) != "sqlb-writer":
                    err.append("%s: Faden ausser sqlb-writer" % name)
if err:
    print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard sqlB: database.py, sdr_manager.py, prepper_sdr.py, dashboard.py nur die vorgesehenen Stellen + Block sqlB%s; prepper_sdr nur DB-Schreibfaden (keine Prozesse, kein Netz, kein shell); Dashboard ohne neue Sendewege/Routen" %
      (" (schon eingespielt)" if all(rd(a[i + 1]) == rd(a[i + 2]) for i in range(0, len(a), 4)) else ""))
SQG_EOF
EXPECT_C="bad02b2da5174f72105f1ade1705bc9ffff5e628b98517b57bed1732f9d06fcf"
cat > "$W/sqlbcheck.py" << 'SQC_EOF'
"""sqlB Pruef-/Anzeigehilfe. Nur lesen ausser 'drop' (Rollback: Tabelle state entfernen, nur wenn sqlB sie neu angelegt hat).
Modi: hastable DB | drop DB | counts DB | live F | srcdb F | statusdb F | t4 F | fresh DB MAXAGE | compare DIR | writer DB"""
import json
import os
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


def row(p, key):
    c = ro(p)
    try:
        if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='state'").fetchone():
            return None
        return c.execute("SELECT ts, src_t, json, n FROM state WHERE key=?", (key,)).fetchone()
    finally:
        c.close()


a = sys.argv[1]
now = time.time()
if a == "hastable":
    c = ro(sys.argv[2])
    try:
        print("1" if c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='state'").fetchone() else "0")
    finally:
        c.close()
elif a == "drop":
    c = sqlite3.connect(sys.argv[2], timeout=30)
    try:
        c.execute("PRAGMA busy_timeout=30000")
        c.execute("DROP TABLE IF EXISTS state")
        c.commit()
    finally:
        c.close()
    print("Tabelle state entfernt (war neu von sqlB)")
elif a == "counts":
    c = ro(sys.argv[2])
    try:
        q = lambda s, *x: c.execute(s, x).fetchone()[0]
        st = q("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='state'")
        print("events %d (aktiv %d), telemetry %d, state %s" % (q("SELECT COUNT(*) FROM events"), q("SELECT COUNT(*) FROM events WHERE expires IS NULL OR expires >= ?", int(now)),
              q("SELECT COUNT(*) FROM telemetry"), ("%d Zeilen" % q("SELECT COUNT(*) FROM state")) if st else "fehlt"))
    finally:
        c.close()
elif a == "live":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    assert t.get("line", "").startswith("Datenquelle:") and set(t.get("items") or {}) == {"sdr_status.json", "broadcast_state.json"}, t
    print("/api/sdr/live Transport: %s; %s" % (t["line"], ", ".join("%s %s (DB %s s, JSON %s s)" % (k.replace(".json", ""), v.get("src"), v.get("db_age_s"), v.get("json_age_s"))
                                                                      for k, v in t["items"].items())))
elif a == "srcdb":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    bad = {k: v.get("why") for k, v in (t.get("items") or {}).items() if v.get("src") != "db"}
    assert t.get("on") is not False and not bad and t.get("ok"), "nicht aus DB: %s" % bad
    w = t.get("writer") or {}
    print("beide aus DB gelesen; Schreibfaden prepper-sdr: ok %s, Fehler %s, verworfen %s, Ereignisse %s, Stand vor %s s" % (w.get("ok"), w.get("err"), w.get("drop"), w.get("ev"), w.get("age_s")))
elif a == "statusdb":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    assert ((t.get("items") or {}).get("sdr_status.json") or {}).get("src") == "db"
    print("ok")
elif a == "t4":
    d = json.load(open(sys.argv[2]))
    t = d.get("tr") or {}
    assert t.get("line", "").startswith("Datenquelle:"), d.get("tr")
    print("/api/t4/status SDR-Status-Kachel: %s" % t["line"])
elif a == "fresh":
    r = row(sys.argv[2], "sqlb_writer")
    m = float(sys.argv[3])
    s = row(sys.argv[2], "sdr_status")
    assert r and s, "noch keine DB-Zeile von prepper-sdr"
    assert now - float(r[1] or r[0]) <= m and now - float(s[1] or s[0]) <= m, "DB-Zeilen zu alt"
    w = json.loads(r[2])
    print("prepper-sdr schreibt in lagezentrum.db: sdr_status vor %d s (%d mal), Schreibfaden ok %s, Fehler %s, verworfen %s, DAB-Ereignisse %s" % (
        now - float(s[1] or s[0]), s[3] or 0, w.get("ok"), w.get("err"), w.get("drop"), w.get("ev")))
elif a == "writer":
    r = row(sys.argv[2], "sqlb_writer")
    if not r:
        print("  Schreibfaden: noch keine Zeile")
    else:
        w = json.loads(r[2])
        print("  Schreibfaden prepper-sdr (Stand %s): ok %s, Fehler %s, verworfen %s, DAB-Ereignisse %s, letzter Fehler %s" % (
            ft(r[1] or r[0]), w.get("ok"), w.get("err"), w.get("drop"), w.get("ev"), w.get("last_err") or "–"))
elif a == "compare":
    base = sys.argv[2]
    p = os.path.join(base, "lagezentrum.db")
    for name, key in (("sdr_status.json", "sdr_status"), ("broadcast_state.json", "broadcast_state")):
        try:
            r = row(p, key)
            f = os.path.join(base, name)
            ja = now - os.path.getmtime(f) if os.path.exists(f) else None
            jv = json.load(open(f, encoding="utf-8")) if ja is not None else None
            if not r:
                print("  %-21s DB: keine Zeile, JSON vor %s s" % (name, "%d" % ja if ja is not None else "–"))
                continue
            dv = json.loads(r[2])
            print("  %-21s DB vor %d s (%d mal geschrieben), JSON vor %s s, Inhalt gleich: %s" % (name, now - float(r[1] or r[0]), r[3] or 0,
                  "%d" % ja if ja is not None else "–", "ja" if dv == jv else "nein (Datei inzwischen neuer geschrieben)" if ja is not None and float(r[1] or 0) < now - ja - 0.5 else "nein"))
        except Exception as e:
            print("  %s: nicht lesbar (%s)" % (name, e))
SQC_EOF
P="$W/patch-sqlb.py"; ED="$W/edits.py"; BDB="$W/db_block.py"; BSM="$W/sm_block.py"; BSR="$W/sdr_block.py"; BDA="$W/dash_block.py"; SG="$W/guard_sqlb.py"; CK="$W/sqlbcheck.py"
for x in "$EXPECT_P $P" "$EXPECT_E $ED" "$EXPECT_BDB $BDB" "$EXPECT_BSM $BSM" "$EXPECT_BSR $BSR" "$EXPECT_BDA $BDA" "$EXPECT_G $SG" "$EXPECT_C $CK"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || echo "neu, Erkennung ueber Guards"; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sqlA"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sqlA"))"
echo "Basis database.py sha16 $DB16 ($(wc -l < "$DBF") Zeilen, $(kn "$DB16" "$KNOWN_DB16" "sqlA"))"
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "tiiFix2"))"
echo "mesh_router.py sha16 $MR16 ($(wc -l < "$MR") Zeilen, $(kn "$MR16" "$KNOWN_MR16" "Teil 3")) - bleibt unveraendert"
echo "lagegeo.py sha16 $LG16 ($(kn "$LG16" "$KNOWN_LG16" "lageGeo")) - bleibt unveraendert"
grep -q '# ===== sqlA:' "$F" || { echo "STOP: sqlA fehlt in dashboard.py - bitte zuerst apply-sqla.sh, nichts geaendert"; exit 1; }
grep -q 'def selftest_sqla' "$SMF" || { echo "STOP: sqlA fehlt in sdr_manager.py - nichts geaendert"; exit 1; }
grep -q 'def start_retention' "$DBF" || { echo "STOP: sqlA fehlt in database.py - nichts geaendert"; exit 1; }
grep -q '# tiiFix2' "$M" || { echo "STOP: tiiFix2 fehlt in prepper_sdr.py - nichts geaendert"; exit 1; }
python3 "$P" db "$DBF" "$W/work/database.py" "$BDB" "$ED" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: database.py unbekannte Basis (sha16 $DB16) - nichts geaendert"; exit 1; }
python3 "$P" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" "$ED" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: sdr_manager.py unbekannte Basis (sha16 $SM16) - nichts geaendert"; exit 1; }
python3 "$P" sdr "$M" "$W/work/prepper_sdr.py" "$BSR" "$ED" > "$W/p3.log" || { cat "$W/p3.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $SDR16) - nichts geaendert"; exit 1; }
python3 "$P" dash "$F" "$W/work/dashboard.py" "$BDA" "$ED" > "$W/p4.log" || { cat "$W/p4.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: $(cat "$W/p1.log"); $(cat "$W/p2.log"); $(cat "$W/p3.log"); $(cat "$W/p4.log")"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
FLAG=$(python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
v=d.get('db_transport') if isinstance(d,dict) else None
print('fehlt = an' if v is None else ('%s = aus' % v if str(v).strip().lower() in ('off','aus','0','false','nein','no') else '%s = an' % v))" "$DASH_DIR/sdr_config.json" 2>/dev/null || echo "nicht lesbar = an")
echo "Schalter db_transport in sdr_config.json: $FLAG (Datei wird nicht geaendert)"
# ---------- 2) Trockenlauf ----------
for k in "db database $BDB" "sm sdr_manager $BSM" "sdr prepper_sdr $BSR" "dash dashboard $BDA"; do set -- $k
  python3 "$P" "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$ED" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/database.py" "$W/work/sdr_manager.py" "$W/work/prepper_sdr.py" "$W/work/dashboard.py"; do
    "$py" -W error -m py_compile "$x" || { echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
cp "$W/work/database.py" "$W/work/sdr_manager.py" "$W/work/prepper_sdr.py" "$MR" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 120 "$py" database.py > "$W/dbt.log" 2>&1) || { tail -12 "$W/dbt.log"; echo "STOP: Selbsttest database ($py) - nichts geaendert"; exit 1; }
  for k in "database selftest ok" "database selftest Teil 2 ok" "database selftest Teil 3 ok" "database selftest sqlA ok" "database selftest sqlB ok"; do
    grep -qF "$k" "$W/dbt.log" || { echo "STOP: Selbsttest database ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && timeout 180 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlA ok" "sdr_manager selftest sqlB ok"; do
    grep -qF "$k" "$W/smt.log" || { echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && timeout 300 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest rdsNotfall ok" "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok"; do
    grep -qF "$k" "$W/sdrt.log" || { echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttests mit $SPY und $VPY (Sandbox, Test-DB, nichts gesendet):"
echo "  $(grep 'selftest sqlB' "$W/dbt.log" | cut -c1-200)"
echo "  $(grep 'selftest sqlB' "$W/smt.log" | cut -c1-220)"
echo "  prepper_sdr $(grep 'selftest sqlB' "$W/sdrt.log" | cut -c1-220)"
python3 "$SG" "$ED" db "$DBF" "$W/work/database.py" "$BDB" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" sdr "$M" "$W/work/prepper_sdr.py" "$BSR" dash "$F" "$W/work/dashboard.py" "$BDA" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
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
  echo "OK JavaScript (SDR-Status-Kachel) syntaktisch geprueft (node)"
fi
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
HADST=1; [[ -f "$LZ" ]] && HADST=$(python3 "$CK" hastable "$LZ" 2>/dev/null || echo 1)
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
ALL=("$DBF" "$SMF" "$M" "$F")
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/database.py" "$DBF" && cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK sqlB schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    for u in prepper-sdr prepper-dashboard; do
      sudo journalctl -u "$u" --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sqlB|Traceback|Error" | tail -6 | cut -c1-200 || true
    done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sqlb-$TS" ]] && cp -a "$x.bak-sqlb-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    sudo systemctl restart prepper-sdr.service || true
    for i in $(seq 1 60); do sleep 3; systemctl is-active --quiet prepper-sdr && break; done
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 60); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-sqlb-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    if [[ "$HADST" == 0 && -f "$LZ" ]]; then python3 "$CK" drop "$LZ" 2>&1 | sed 's/^/  /' || echo "  WARNUNG Tabelle state nicht entfernt (stoert alten Stand nicht)"; else echo "  Tabelle state war schon da - bleibt"; fi
    echo "  Sicherung lagezentrum.db von vorher: $LZ.bak-sqlb-$TS"
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-sqlb-$TS"
    { ls -1t "$x.bak-sqlb-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sqlb-$TS" \
      || { rm -f "$LZ.bak-sqlb-$TS"; for x in "${ALL[@]}"; do rm -f "$x.bak-sqlb-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sqlb-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "database $DBF" "sdr_manager $SMF" "prepper_sdr $M" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sqlb-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  sudo systemctl restart prepper-sdr.service
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr ohne frischen Status"; exit 1; }
  echo "OK prepper-sdr laeuft, SDR-Status frisch"
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart prepper-dashboard - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /dabhist /karte /api/sdr/live /api/sdr/map /api/t2/status /api/t4/status /api/t4/tii; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
grep -q "L\[6\].textContent=tr?(tr.line||'')" "$W/funk.html" && echo "OK /funk: SDR-Status-Kachel mit Zeile Datenquelle" || rbx "/funk ohne Zeile Datenquelle"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
L1=$(python3 -c "
import sys; s=open(sys.argv[1],encoding='utf-8',errors='replace').read(); i=s.rfind('doPrepperRestore'); print('ja' if i>=0 and s.find('class=\"tile', i) < 0 and s.find('class=\"card', i) < 0 else 'nein')" "$W/pi.html" 2>/dev/null || echo nein)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x), letzte Kachel: $L1" || rbx "/pi Sicherung veraendert ($R0/$R1)"
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(sqlB|sqlA|kartevec|teil[234]) (aktiv|FEHLER)" | tail -10 || true)
if [[ "$JD" == *"FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2)"; fi
if [[ "$JD" == *"sqlB aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'sqlB aktiv' | tail -1 | cut -c1-230)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet sqlB nicht (Journal)"; fi
JS=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sqlB: DB-Schreibfaden" | tail -1 || true)
if [[ "$JS" == *"nicht gestartet"* ]]; then rbx "prepper-sdr: $JS"; fi
if [[ -n "$JS" ]]; then echo "OK Journal prepper-sdr: $(echo "$JS" | cut -c1-230)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "prepper-sdr meldet sqlB nicht (Journal)"; fi
# erste DB-Zeilen von prepper-sdr (Status alle <= 60 s)
FR=""
if [[ "$FLAG" == *"= an" ]]; then
  for i in $(seq 1 40); do FR=$(python3 "$CK" fresh "$LZ" 90 2>/dev/null || true); [[ -n "$FR" ]] && break; sleep 4; done
  [[ -n "$FR" ]] && echo "OK $FR" || rbx "prepper-sdr schreibt nicht in lagezentrum.db (160 s)"
  SRC=""
  for i in $(seq 1 40); do "${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true; SRC=$(python3 "$CK" srcdb "$W/live.json" 2>/dev/null || true); [[ -n "$SRC" ]] && break; sleep 5; done
  python3 "$CK" live "$W/live.json" > "$W/live.log" 2>&1 && echo "OK $(cat "$W/live.log")" || { cat "$W/live.log"; rbx "/api/sdr/live ohne Transport-Anzeige"; }
  if [[ -n "$SRC" ]]; then echo "OK $SRC"; else
    python3 "$CK" statusdb "$W/live.json" >/dev/null 2>&1 && echo "WARNUNG Rundfunk-Zustand noch aus JSON-Ersatz (prepper-sdr schreibt ihn erst bei Aenderung) - Status kommt aus der DB" || rbx "Dashboard liest SDR-Status nicht aus der DB"
  fi
else
  echo "Hinweis: db_transport = $FLAG - DB-Transport aus, Dashboard liest nur JSON (wie vorher)"
  "${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
  python3 "$CK" live "$W/live.json" > "$W/live.log" 2>&1 && echo "OK $(cat "$W/live.log")" || { cat "$W/live.log"; rbx "/api/sdr/live ohne Transport-Anzeige"; }
fi
"${CURL[@]}" "$B/api/t4/status" -o "$W/t4.json" || true
python3 "$CK" t4 "$W/t4.json" > "$W/t4.log" 2>&1 && echo "OK $(cat "$W/t4.log")" || { cat "$W/t4.log"; rbx "/api/t4/status ohne Datenquelle"; }
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sqlB FEHLER|database is locked" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sqlB-Fehler/database is locked" || rbx "$E Traceback/sqlB-Fehlerzeilen im Journal Dashboard"
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sqlB: Schreibfehler|sqlB: Fehler im Schreibfaden" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sqlB-Schreibfehler" || rbx "$E Traceback/sqlB-Fehlerzeilen im Journal prepper-sdr"
[[ "$(s16 "$MR")" == "$MR16" ]] && echo "OK mesh_router.py unveraendert ($MR16)" || rbx "mesh_router.py hat sich veraendert"
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
echo "OK guards sqlB(dash)=$(grep -c '# ===== sqlB:' "$F" || true) sqlA(dash)=$(grep -c '# ===== sqlA:' "$F" || true) kartevec(dash)=$(grep -c '# ===== kartevec:' "$F" || true) sqlB(sdr_manager)=$(grep -c 'def selftest_sqlb' "$SMF" || true) sqlA(sdr_manager)=$(grep -c 'def selftest_sqla' "$SMF" || true) sqlB(database)=$(grep -c 'def selftest_state' "$DBF" || true) sqlA(database)=$(grep -c 'def start_retention' "$DBF" || true) sqlB(sdr)=$(grep -c '# ===== sqlB:' "$M" || true) tiiFix2(sdr)=$(grep -c '# tiiFix2' "$M" || true)"
[[ -f "$F.bak-sqlb-$TS" ]] && echo "Backups: *.bak-sqlb-$TS (database.py, sdr_manager.py, prepper_sdr.py, dashboard.py, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG sqlb=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, sqlB bleibt aktiv. COMMIT $COMMIT_ARG sqlb=1"; exit 0' INT
echo "Vergleich DB gegen JSON (nur lesen):"
python3 "$CK" compare "$DASH_DIR" || true
python3 "$CK" writer "$LZ" || true
echo "Schalter: db_transport in sdr_config.json (fehlt = an; zum Abschalten \"db_transport\": \"off\" eintragen, dann prepper-sdr neu starten - Dashboard merkt es sofort)"
echo "COMMIT $COMMIT_ARG sqlb=1 fertig"
