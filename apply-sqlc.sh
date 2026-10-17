#!/bin/bash
set -euo pipefail
# sqlC (Teil C der SQLite-Umstellung, nach sqlB): lagezentrum.db (Tabelle state) wird Haupt-Transport fuer sdr_status / broadcast_state.
# prepper-sdr schreibt sdr_status.json und broadcast_state.json im Normalbetrieb nur noch als Notkopie alle 10 min (atomar wie bisher).
# Selbstheilend: sofort wieder laufend JSON bei DB-Schreibfehler, verworfenem Eintrag, haengendem/fehlendem Schreibfaden, letztem DB-Schreiben > 90 s,
# beim Start bis zum ersten DB-Schreiben und solange das Dashboard per sdr_json_request.json anfordert (Dashboard kann DB nicht lesen);
# zurueck zur Notkopie erst nach 180 s ohne Fehler und 3 guten DB-Schreibvorgaengen; beim Beenden/Neustart JSON immer aktuell.
# sdr_dabhist.json (Verlauf, /dabhist) und broadcast_events.jsonl bleiben unveraendert. Stick-Test-Kachel liest jetzt auch DB zuerst.
# Schalter db_transport in sdr_config.json: fehlt/db = DB-primaer (sqlC), on = beides wie sqlB, off = nur JSON (Datei wird NICHT geaendert).
# Aendert sdr_manager.py, prepper_sdr.py, dashboard.py; database.py, mesh_router.py, lagegeo.py bleiben unveraendert.
# Neustart prepper-sdr (warten auf frischen Status), dann prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
REQ="$DASH_DIR/sdr_json_request.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sqlc-apply
KEEP_LAST=3
OBS_S="${SQLC_OBS_S:-180}"
KNOWN_D16="42a4c46bb6586d6b"     # dashboard.py nach sqlB
KNOWN_SM16="8417b433aee6f1e2"    # sdr_manager.py nach sqlB
KNOWN_DB16="431077d36822a090"    # database.py nach sqlB (bleibt unveraendert)
KNOWN_SDR16="691cb914d17d0dac"   # prepper_sdr.py nach sqlB
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
echo "=== sqlC apply (DB-primaer: JSON nur Notkopie alle 10 min, selbstheilender JSON-Ersatz), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_P="f13a44bb366725df7fa1c31891039f913dde4f83a1e1371a89c9b5fe5fffa698"
cat > "$W/patch-sqlc.py" << 'SQP_EOF'
"""sqlC-Patcher. Aufruf: patch-sqla.py ART QUELLE ZIEL BLOCK EDITS   (ART = db | sm | sdr | dash). Idempotent: schon gepatcht -> Ziel = Quelle.
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
        print("%s: sqlC teilweise/anders vorhanden" % name); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: sqlC schon drin" % name); raise SystemExit(0)
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
print("%s: %d Stellen + Block sqlC" % (name, len(E)))
SQP_EOF
EXPECT_E="bfcee18d26b564af01bae66664da4d3545e41a2a0050d974c4cab96486a4cff5"
cat > "$W/edits.py" << 'SQE_EOF'
# sqlC: Stellen (alt, neu) je Datei. Jede alte Stelle muss genau einmal vorkommen.
DB_EDITS = []
DB_ANCHOR = None

SM_EDITS = [
('''    assert transport_status(d, now)["line"].startswith("Datenquelle: DB (Ersatz JSON bereit)")''',
 '''    assert transport_status(d, now)["line"].startswith("Datenquelle: DB (")   # sqlC: Text je Betriebsart'''),
('''        assert "JSON-Ersatz" in transport_status(d, now)["line"]''',
 '''        assert "JSON-ERSATZ" in transport_status(d, now)["line"].upper() or "NICHT LESBAR" in transport_status(d, now)["line"].upper()   # sqlC'''),
('''    print(selftest_sqlb())
''', '''    print(selftest_sqlb())
    print(selftest_sqlc())
'''),
]
SM_ANCHOR = '\n\nif __name__ == "__main__":\n'

SDR_EDITS = [
('''    s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(s)
''', '''    s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    w = globals().get("_SQLB_W")   # sqlC: Status/Rundfunk-Zustand DB-primaer, JSON nur Notkopie/Ersatz (SqlcWriter.write)
    if w is not None and hasattr(w, "write"):
        try:
            if w.write(path, s):
                return
        except Exception:
            pass
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(s)
'''),
('''        self.d = load_json(self.f, None) or {"v": V, "fm": {}, "dab": {}, "warn": []}''',
 '''        self.d = sqlc_load(self.f, None) or {"v": V, "fm": {}, "dab": {}, "warn": []}   # sqlC: neuerer Stand aus DB oder Datei'''),
('''    st = load_json(p("sdr_status.json", base), {}) or {}
    if not isinstance(st.get("t"), (int, float)) or time.time() - st["t"] > 180:''',
 '''    st = sqlc_load(p("sdr_status.json", base), {}) or {}   # sqlC
    if not isinstance(st.get("t"), (int, float)) or time.time() - st["t"] > 180:'''),
('''        print(json.dumps(load_json(p("sdr_status.json"), {}), indent=1, ensure_ascii=False))''',
 '''        print(json.dumps(sqlc_load(p("sdr_status.json"), {}), indent=1, ensure_ascii=False))   # sqlC'''),
('''                pl.flush(True)
                os.execv(''', '''                pl.flush(True)
                if hasattr(_SQLB_W, "flush_exit"):
                    _SQLB_W.flush_exit()   # sqlC: JSON vor Neustart aktuell
                os.execv('''),
('''        _SQLB_W.start(BASE)   # sqlB
        Planner(BASE).loop()''', '''        _SQLB_W.start(BASE)   # sqlB
        try:
            Planner(BASE).loop()
        finally:
            if hasattr(_SQLB_W, "flush_exit"):
                _SQLB_W.flush_exit()   # sqlC: beim Beenden JSON immer aktuell'''),
('''        selftest_sqlb()
    elif a in''', '''        selftest_sqlb()
        selftest_sqlc()
    elif a in'''),
]
SDR_ANCHOR = '\n\nif __name__ == "__main__":\n'

DASH_EDITS = [
('''def _stk_load(name):
    try:''', '''def _stk_load(name):
    if name in ("sdr_status.json", "broadcast_state.json") and "_sqb_load" in globals():   # sqlC: DB zuerst (JSON nur Notkopie)
        try:
            v = _sqb_load(name, {})
            return v if isinstance(v, dict) else {}
        except Exception:
            pass
    try:'''),
('''    assert tr["line"].startswith("Datenquelle: JSON-Ersatz") and tr["items"]["sdr_status.json"]["src"] == "json-fallback"   # ohne DB: Ersatz''',
 '''    assert not tr["ok"] and tr["items"]["sdr_status.json"]["src"] == "json-fallback"   # ohne DB: Ersatz (sqlC: Text je Betriebsart)'''),
]
DASH_ANCHOR = "# ===== /sqlB =====\n"
SQE_EOF
EXPECT_BSM="664fc19c46a871b06a963f9573f911ff75f15b9e26dddde29c2d85cbf1a937ef"
cat > "$W/sm_block.py" << 'SQBS_EOF'
# ---------------------------------------------------------------- sqlC
# lagezentrum.db (Tabelle state) ist der Haupt-Transport fuer sdr_status / broadcast_state; prepper-sdr schreibt die JSON-Dateien im
# Normalbetrieb nur noch als Notkopie (alle 10 min) und laufend nur im Ersatzfall. Schalter db_transport in sdr_config.json:
# fehlt/db = DB-primaer (sqlC), on = beides (sqlB), off = nur JSON. Lesen bleibt DB zuerst, JSON als Ersatz (sqlb_load); Herzschlag kommt aus
# dem Inhalt (t, pid): ist die DB nicht lesbar und die Notkopie alt, zeigt die Anzeige ehrlich veraltet/offline (orange).
# Kann das Dashboard die DB nicht lesen (Fehler/gesperrt/keine Zeile), legt es sdr_json_request.json an (bis jetzt + 10 min, hoechstens
# alle 60 s erneuert) -> prepper-sdr schreibt wieder laufend JSON. Nur diese eine Datei wird geschrieben; kein Netz, keine Sendewege.
SQLC_REQ = "sdr_json_request.json"
SQLC_REQ_S = 600
SQLC_REQ_EVERY_S = 60
SQLC_MIRROR_S = 600
SQLC_DUAL = ("on", "an", "dual", "1", "true", "ja", "yes", "beides")
_SQLB.setdefault("mode", {})
_SQLB.setdefault("req", {})


def sqlc_mode(base):
    """db_transport -> db | dual | json (fehlt/unbekannt = db). Nur lesen, nach mtime gepuffert."""
    f = os.path.join(base, "sdr_config.json")
    try:
        _s = os.stat(f)
        mt = (_s.st_mtime_ns, _s.st_size, _s.st_ino)
    except OSError:
        mt = None
    c = _SQLB["mode"].get(f)
    if c and c[0] == mt:
        return c[1]
    d = _load_json(f, {}) if mt else {}
    v = str(d.get("db_transport", "db") if isinstance(d, dict) else "db").strip().lower()
    m = "json" if v in SQLB_OFF else ("dual" if v in SQLC_DUAL else "db")
    _SQLB["mode"][f] = (mt, m)
    return m


def sqlb_flag(base):
    """DB lesen? (alles ausser db_transport off)"""
    return sqlc_mode(base) != "json"


def _sqlc_request(base, why, now=None):
    """Dashboard kann die DB nicht lesen -> prepper-sdr um laufendes JSON bitten (atomar, gedrosselt). -> geschrieben?"""
    now = time.time() if now is None else now
    try:
        if now - _SQLB["req"].get(base, 0) < SQLC_REQ_EVERY_S or not os.path.isdir(base):
            return False
        _SQLB["req"][base] = now
        _write_json(os.path.join(base, SQLC_REQ), {"t": int(now), "until": int(now + SQLC_REQ_S), "why": str(why or "?")[:120], "by": "dashboard", "pid": os.getpid()})
        return True
    except Exception as e:
        print("sqlC: Anforderung JSON nicht geschrieben:", e, flush=True)
        return False


def sqlc_request_until(base, now=None):
    now = time.time() if now is None else now
    d = _load_json(os.path.join(base, SQLC_REQ), {}) or {}
    u = d.get("until") if isinstance(d, dict) else None
    return int(u) if isinstance(u, (int, float)) and u > now else None


_sqlb_load_b = sqlb_load


def sqlb_load(path, default=None, now=None):
    """wie sqlB; zusaetzlich: DB nicht lesbar im DB-primaer-Betrieb -> Anforderung JSON an prepper-sdr."""
    v = _sqlb_load_b(path, default, now)
    try:
        name = os.path.basename(str(path))
        base = os.path.dirname(str(path)) or "."
        info = _SQLB["src"].get(name) or {}
        if info.get("src") == "json-fallback" and not str(info.get("why") or "").startswith("DB-Stand") and sqlc_mode(base) == "db":
            info["req"] = _sqlc_request(base, "%s: %s" % (name, info.get("why")), now) or bool(sqlc_request_until(base, now))
    except Exception:
        pass
    return v


def transport_status(base, now=None):
    """Anzeige: Betriebsart, Quelle je Datei (db / json-fallback / json), Alter DB/JSON-Notkopie, Ersatz aktiv, Zaehler des Schreibfadens."""
    now = time.time() if now is None else now
    out = {"on": True, "mode": None, "items": {}, "writer": None, "ok": False, "line": "", "fallback": False, "req_until": None,
           "mirror_s": SQLC_MIRROR_S, "mirror_age_s": None}
    try:
        m = sqlc_mode(base)
        out["mode"], out["on"] = m, m != "json"
        for name in SQLB_KEYS:
            _load(os.path.join(base, name), {})
            out["items"][name] = dict(_SQLB["src"].get(name) or {})
        out["mirror_age_s"] = out["items"]["sdr_status.json"].get("json_age_s")
        out["req_until"] = sqlc_request_until(base, now)
        r = _sqlb_row(os.path.join(base, "lagezentrum.db"), "sqlb_writer", now) if out["on"] else {"ok": False}
        if r.get("ok"):
            w = json.loads(r["text"]) if r.get("text") else {}
            w["age_s"] = int(now - float(r.get("src_t") or r.get("ts") or now))
            out["writer"] = w
        w = out["writer"] or {}
        err = w.get("err") or 0
        srcs = [i.get("src") for i in out["items"].values()]
        alldb = bool(srcs) and all(s == "db" for s in srcs)
        wfb = bool(w.get("fallback")) and (w.get("age_s") or 0) <= 150
        out["fallback"] = (m == "db") and (wfb or not alldb)
        bad = "; ".join("%s: %s" % ("Status" if n == "sdr_status.json" else "Rundfunk", i.get("why") or "?") for n, i in out["items"].items() if i.get("src") != "db")
        st = out["items"]["sdr_status.json"]
        if m == "json":
            out["ok"] = True
            out["line"] = "Datenquelle: JSON (DB-Transport aus, sdr_config.json db_transport)"
        elif m == "dual":
            out["ok"] = alldb
            out["line"] = ("Datenquelle: DB (Ersatz JSON bereit)" + (" · Schreibfehler %d" % err if err else "")) if alldb else "Datenquelle: JSON-ERSATZ AKTIV (%s)" % bad
        elif alldb and not wfb:
            out["ok"] = True
            out["line"] = "Datenquelle: DB (JSON-Notkopie alle %d min, Ersatz bereit)" % (SQLC_MIRROR_S // 60) + (" · Schreibfehler %d" % err if err else "")
        elif alldb:
            out["line"] = "Datenquelle: DB · JSON-ERSATZ AKTIV (%s)" % (w.get("why") or "prepper-sdr schreibt JSON")
        elif st.get("src") != "db" and not str(st.get("why") or "").startswith("DB-Stand") and (st.get("json_age_s") is None or st["json_age_s"] > STATUS_MAX_AGE_S):
            out["line"] = "Datenquelle: DB nicht lesbar (%s), JSON-Notkopie %s - SDR-Status veraltet, JSON bei prepper-sdr angefordert" % (
                str(st.get("why") or "?")[:50], ("%d min alt" % (st["json_age_s"] // 60)) if st.get("json_age_s") is not None else "fehlt")
        else:
            out["line"] = "Datenquelle: JSON-ERSATZ AKTIV (%s)" % bad
        if out["on"] and isinstance(w.get("age_s"), int) and w["age_s"] > 150:
            out["ok"] = False
            out["line"] += " · prepper-sdr schreibt nicht in die DB (seit %d min)" % (w["age_s"] // 60)
    except Exception as e:
        out["line"] = "Datenquelle: JSON (Anzeigefehler %s)" % str(e)[:60]
    return out


def selftest_sqlc():
    import tempfile
    d = tempfile.mkdtemp(prefix="sqlc-")
    p = os.path.join(d, "lagezentrum.db")
    now = int(time.time())
    assert db.migrate(p) and db.migrate_t2(p)
    cfg = os.path.join(d, "sdr_config.json")
    fs, fb = os.path.join(d, "sdr_status.json"), os.path.join(d, "broadcast_state.json")
    clear = lambda: (_SQLB["cache"].clear(), _SQLB["req"].clear())
    req = os.path.join(d, SQLC_REQ)
    assert sqlc_mode(d) == "db" and sqlb_flag(d)
    for v, m in (("db", "db"), ("on", "dual"), ("off", "json"), ("quatsch", "db")):
        _write_json(cfg, {"serial": "x", "db_transport": v})
        assert sqlc_mode(d) == m, (v, sqlc_mode(d))
    os.remove(cfg)
    bs = {"t": now, "fm": {}, "dab": {}, "t2": {"ev": []}}
    live = {"t": now, "pid": os.getpid(), "active": "dab"}
    # DB-primaer: DB frisch, JSON-Notkopie 8 min alt -> DB, Herzschlag da, kein Ersatz
    _write_json(fs, dict(live, t=now - 480))
    _write_json(fb, bs)
    os.utime(fs, (now - 480, now - 480))
    os.utime(fb, (now - 480, now - 480))
    assert db.state_put("sdr_status", json.dumps(live), now - 5, p) and db.state_put("broadcast_state", json.dumps(bs), now - 20, p)
    db.state_put("sqlb_writer", json.dumps({"ok": 5, "err": 0, "fallback": False, "mode": "db"}), now - 5, p)
    clear()
    assert _load(fs) == live and heartbeat_row(_load(fs), now) is not None
    tr = transport_status(d, now)
    assert tr["ok"] and tr["mode"] == "db" and tr["line"].startswith("Datenquelle: DB (JSON-Notkopie alle 10 min") and not tr["fallback"] and tr["mirror_age_s"] >= 470, tr
    assert not os.path.exists(req)
    # prepper-sdr tot (DB und Notkopie alt) -> offline in jedem Modus
    db.state_put("sdr_status", json.dumps(dict(live, t=now - 400)), now - 400, p)
    for v in ("db", "on", "off"):
        _write_json(cfg, {"db_transport": v})
        clear()
        assert heartbeat_row(_load(fs), now) is None, v
    os.remove(cfg)
    db.state_put("sdr_status", json.dumps(live), now - 5, p)
    # Dashboard kann DB nicht lesen -> JSON-Ersatz (alt -> offline/orange) + Anforderung an prepper-sdr
    real_get = db.state_get
    try:
        db.state_get = lambda *a, **k: {"ok": False, "err": "database is locked"}
        clear()
        v = _load(fs)
        assert v["t"] == now - 480 and heartbeat_row(v, now) is None                      # ehrlich: Notkopie zu alt -> kein Lebenszeichen
        rq = _load_json(req, {})
        assert rq.get("until", 0) > now and rq.get("by") == "dashboard", rq             # Anforderung geschrieben
        tr = transport_status(d, now)
        assert not tr["ok"] and tr["fallback"] and "veraltet" in tr["line"] and tr["req_until"], tr
        n0 = os.path.getmtime(req)
        _load(fs)
        assert os.path.getmtime(req) == n0                                                # gedrosselt (60 s)
        _write_json(fs, live)                                                            # prepper-sdr schreibt wieder JSON
        clear()
        v = _load(fs)
        assert heartbeat_row(v, now) is not None and "JSON-ERSATZ AKTIV" in transport_status(d, now)["line"]
        os.remove(req)
        _write_json(cfg, {"db_transport": "on"})                                          # beides: keine Anforderung (JSON laeuft ohnehin)
        clear()
        _load(fs)
        assert not os.path.exists(req)
        _write_json(cfg, {"db_transport": "off"})
        clear()
        assert _load(fs) == live and not os.path.exists(req) and transport_status(d, now)["line"].startswith("Datenquelle: JSON (DB-Transport aus")
    finally:
        db.state_get = real_get
    os.remove(cfg)
    # prepper-sdr meldet Ersatz aktiv (z. B. DB-Fehler beim Schreiben, aber Dashboard liest DB)
    db.state_put("sdr_status", json.dumps(live), now + 1, p)
    db.state_put("sqlb_writer", json.dumps({"ok": 5, "err": 2, "fallback": True, "why": "DB-Fehler vor 10 s", "mode": "db"}), now, p)
    clear()
    tr = transport_status(d, now + 2)
    assert not tr["ok"] and tr["fallback"] and "JSON-ERSATZ AKTIV" in tr["line"] and "DB-Fehler" in tr["line"], tr
    db.state_put("sqlb_writer", json.dumps({"ok": 5, "err": 0, "fallback": False, "mode": "db"}), now - 400, p)   # prepper-sdr tot: Schreiber still -> orange
    clear()
    tr = transport_status(d, now + 2)
    assert not tr["ok"] and "schreibt nicht" in tr["line"], tr
    # broadcast_state ueber DB vs. Notkopie: Rundfunk-Zustand (Alarm-Weg) kommt aus der DB, nicht aus der alten Datei
    bs2 = dict(bs, warn=[{"t": now, "k": "pty31", "src": "BR24"}])
    db.state_put("broadcast_state", json.dumps(bs2), now, p)
    clear()
    assert _load(fb) == bs2 and t2_status(d, p, now) is not None
    return "sdr_manager selftest sqlC ok (db/on/off, DB-primaer mit alter Notkopie -> DB + Herzschlag, prepper-sdr tot -> offline in jedem Modus, DB nicht lesbar -> ehrlich veraltet + Anforderung JSON (gedrosselt), Ersatz-Anzeige)"
SQBS_EOF
EXPECT_BSR="e4b99e8c7542403cdea410c4f6ed96cb730a1abcc322f69cb0ad248195578559"
cat > "$W/sdr_block.py" << 'SQBR_EOF'
# ===== sqlC: lagezentrum.db (Tabelle state) ist der Haupt-Transport fuer sdr_status.json / broadcast_state.json; die JSON-Dateien werden im Normalbetrieb nur noch als Notkopie alle 10 min geschrieben. Selbstheilend: JSON sofort wieder bei DB-Fehler, verworfenem Eintrag, haengendem/fehlendem Schreibfaden, letztem DB-Schreiben > 90 s, beim Start bis zum ersten DB-Schreiben und solange das Dashboard per sdr_json_request.json anfordert; zurueck erst nach 180 s ohne Fehler und 3 guten Schreibvorgaengen; beim Beenden JSON immer aktuell. Schalter db_transport: fehlt/db = DB-primaer, on = beides (sqlB), off = nur JSON. sdr_dabhist.json und broadcast_events.jsonl bleiben unveraendert; kein Netz, keine Prozesse =====
SQLC_FILES = {"sdr_status.json": "sdr_status", "broadcast_state.json": "broadcast_state"}
SQLC_MIRROR_S = 600          # Notkopie JSON
SQLC_HYST_S = 180            # nach Fehler: so lange fehlerfrei, bevor JSON wieder aufhoert
SQLC_OK_RUN = 3              # ... und so viele gute DB-Schreibvorgaenge
SQLC_OK_MAX_S = 90           # letztes gutes DB-Schreiben aelter -> JSON
SQLC_STUCK_S = 20            # Eintrag wartet laenger in der Warteschlange -> JSON
SQLC_REQ = "sdr_json_request.json"
SQLC_REQ_MAX_S = 3600
SQLC_DUAL = ("on", "an", "dual", "1", "true", "ja", "yes", "beides")


def sqlc_mode_of(d):
    """Wert db_transport -> db | dual | json (fehlt/unbekannt = db)."""
    v = str((d or {}).get("db_transport", "db") if isinstance(d, dict) else "db").strip().lower()
    return "json" if v in SQLB_OFF else ("dual" if v in SQLC_DUAL else "db")


def sqlc_load(path, default=None):
    """sdr_status.json / broadcast_state.json lesen: neuerer Stand aus DB-Zeile oder Datei (fuer Start, CLI). Nie werfen."""
    try:
        name = os.path.basename(path)
        key = SQLC_FILES.get(name)
        if key:
            d = os.path.dirname(os.path.abspath(path))
            if d not in sys.path:
                sys.path.insert(0, d)
            import database as _d
            r = _d.state_get(key, os.path.join(d, "lagezentrum.db"), timeout=1.0)
            if r.get("ok"):
                jt = os.path.getmtime(path) if os.path.exists(path) else 0
                if float(r.get("src_t") or r.get("ts") or 0) >= jt - 2:
                    v = json.loads(r["text"])
                    return v if v is not None else default
    except Exception:
        pass
    return load_json(path, default)


class _SqlcFakeThread:
    def is_alive(self):
        return True


class SqlcWriter(SqlbWriter):
    def __init__(self):
        SqlbWriter.__init__(self)
        self.mflag = (None, "db")
        self.rflag = (None, None)
        self.flock = threading.Lock()
        self.file_t = {n: 0.0 for n in SQLC_FILES}
        self.last_text = {}
        self.ok_t = None
        self.ok_run = 0
        self.fail_t = None
        self.pending_since = None
        self.busy = False
        self.fb_log = None
        self.st.update({"mode": None, "fallback": None, "why": None, "json_t": {n: None for n in SQLC_FILES}, "mirror_s": SQLC_MIRROR_S,
                        "hyst_s": SQLC_HYST_S, "req_until": None, "fb_n": 0, "fb_since": None, "json_n": 0})

    def mode(self):
        f = os.path.join(self.base or BASE, "sdr_config.json")
        try:
            _s = os.stat(f)
            mt = (_s.st_mtime_ns, _s.st_size, _s.st_ino)
        except OSError:
            mt = None
        if self.mflag[0] != mt:
            self.mflag = (mt, sqlc_mode_of(load_json(f, {}) if mt else {}))
        return self.mflag[1]

    def on(self):
        return self.mode() != "json"

    def req_until(self, now):
        """Anforderung des Dashboards (sdr_json_request.json, nach mtime gelesen) -> bis wann JSON, sonst None."""
        f = os.path.join(self.base, SQLC_REQ)
        try:
            _s = os.stat(f)
            mt = (_s.st_mtime_ns, _s.st_size)
        except OSError:
            self.rflag = (None, None)
            return None
        if self.rflag[0] != mt:
            d = load_json(f, {}) or {}
            u = d.get("until") if isinstance(d, dict) else None
            self.rflag = (mt, float(u) if isinstance(u, (int, float)) else _s.st_mtime + SQLC_MIRROR_S)
        u = self.rflag[1]
        return min(u, now + SQLC_REQ_MAX_S) if u and u > now else None

    def healthy(self, now):
        if self.th is None or not self.th.is_alive():
            return False, "Schreibfaden laeuft nicht"
        if self.ok_t is None:
            return False, "Start: noch kein DB-Schreiben"
        if self.fail_t is not None:
            if now - self.fail_t < SQLC_HYST_S:
                return False, "DB-Fehler vor %d s (%s)" % (now - self.fail_t, str(self.st.get("last_err") or "?")[:60])
            if self.ok_run < SQLC_OK_RUN:
                return False, "erst %d gute DB-Schreibvorgaenge nach Fehler" % self.ok_run
        if now - self.ok_t > SQLC_OK_MAX_S:
            return False, "letztes DB-Schreiben vor %d s" % (now - self.ok_t)
        if self.pending_since is not None and now - self.pending_since > SQLC_STUCK_S:
            return False, "Warteschlange haengt seit %d s" % (now - self.pending_since)
        return True, None

    def json_needed(self, name, now):
        """-> (JSON schreiben?, Grund, Ersatz aktiv?)"""
        u = self.req_until(now)
        self.st["req_until"] = int(u) if u else None
        ok, why = self.healthy(now)
        fb = (not ok) or bool(u)
        if u and ok:
            why = "Anforderung Dashboard bis %s" % time.strftime("%H:%M:%S", time.localtime(u))
        self._fb_state(fb, why, now)
        if fb:
            return True, why, True
        if now - self.file_t.get(name, 0) >= SQLC_MIRROR_S:
            return True, "Notkopie", False
        return False, None, False

    def _fb_state(self, fb, why, now):
        if fb != self.st["fallback"]:
            self.st["fallback"] = fb
            self.st["fb_since"] = int(now)
            if fb:
                self.st["fb_n"] += 1
            if True:                                    # Wechsel sind durch die Hysterese selten
                self.fb_log = now
                print(("sqlC: JSON-Ersatz AN (%s) - sdr_status.json/broadcast_state.json werden wieder laufend geschrieben" % why) if fb else
                      "sqlC: JSON-Ersatz AUS - DB gesund, JSON nur noch als Notkopie alle %d s" % SQLC_MIRROR_S, flush=True)
        self.st["why"] = why

    def _file(self, path, text, t, force=False):
        """JSON atomar wie bisher (tmp + os.replace); nie aelteren Stand ueber neueren."""
        name = os.path.basename(path)
        with self.flock:
            if not force and t < self.file_t.get(name, 0):
                return False
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, path)
            self.file_t[name] = t
            self.st["json_t"][name] = int(t)
            self.st["json_n"] += 1
            return True

    def offer(self, path, text, t=None):
        """Aus write_json: nie blockieren, nie werfen. -> in Warteschlange?"""
        try:
            if self.base is None or self.th is None:
                return False
            name = os.path.basename(path)
            if name not in SQLB_FILES or os.path.dirname(os.path.abspath(path)) != self.base or not self.on():
                return False
            if self.q.empty() and not self.busy:
                self.pending_since = time.time()
            self.q.put_nowait((name, text, t or time.time()))
            return True
        except _sqlb_queue.Full:
            self.st["drop"] += 1
            self._fail("Warteschlange voll (verworfen)")
            return False
        except Exception:
            return False

    def write(self, path, s):
        """sqlC-Weg in write_json. False = nicht zustaendig (alter Weg: Datei + offer)."""
        if self.base is None or self.th is None:
            return False
        name = os.path.basename(path)
        if name not in SQLC_FILES or os.path.dirname(os.path.abspath(path)) != self.base:
            return False
        m = self.mode()
        self.st["mode"] = m
        if m != "db":
            return False
        now = time.time()
        need, why, fb = self.json_needed(name, now)
        self.last_text[name] = (path, s, now)
        if need:
            self._file(path, s, now)
        if not self.offer(path, s, now) and not need:
            self._file(path, s, now)                            # verworfen -> sofort JSON
            need = True
        if need and fb:
            self._flush_others(name)
        return True

    def _flush_others(self, name):
        for n, (pth, s, t) in list(self.last_text.items()):
            if n != name and t > self.file_t.get(n, 0):
                try:
                    self._file(pth, s, t)
                except Exception:
                    pass

    def _fail(self, what):
        self.fail_t = time.time()
        self.ok_run = 0
        if what and not self.st.get("last_err"):
            self.st["last_err"] = str(what)[:160]

    def _process(self, item):
        name, text, t = item
        self.busy = True
        e0 = self.st["err"]
        try:
            self.handle(name, text, t)
            failed = self.st["err"] != e0
        except Exception as e:
            failed = True
            self.st["err"] += 1
            self.st["last_err"] = str(e)[:160]
            self.st["err_t"] = int(time.time())
            if time.time() - self.log_t > SQLB_LOG_S:
                self.log_t = time.time()
                print("sqlC: Fehler im Schreibfaden: %s" % e, flush=True)
        if failed:
            self._fail(None)
            if name in SQLC_FILES and self.mode() == "db":     # sofort JSON mit genau diesem Stand (wenn nicht schon neuer da)
                try:
                    self._file(os.path.join(self.base, name), text, t)
                    self._fb_state(True, "DB-Fehler: %s" % str(self.st.get("last_err") or "?")[:60], time.time())
                    self._flush_others(name)
                except Exception:
                    pass
        elif SQLB_FILES.get(name):
            self.ok_t = time.time()
            self.ok_run += 1
        self.busy = False
        self.pending_since = None if self.q.empty() else time.time()
        return not failed

    def _loop(self):
        while True:
            try:
                self._process(self.q.get())
            except Exception:
                self.busy = False

    def start(self, base):
        r = SqlbWriter.start(self, base)
        try:
            for n in SQLC_FILES:
                f = os.path.join(self.base or base, n)
                self.file_t[n] = os.path.getmtime(f) if os.path.exists(f) else 0.0
            m = self.mode()
            self.st["mode"] = m
            print("sqlC: Transport %s" % {"db": "DB-primaer (JSON-Notkopie alle %d s, Ersatz bei Fehler/Anforderung, bis erstes DB-Schreiben JSON)" % SQLC_MIRROR_S,
                                          "dual": "beides wie sqlB (db_transport on)", "json": "nur JSON (db_transport off)"}[m], flush=True)
        except Exception as e:
            print("sqlC: Start-Hinweis:", e, flush=True)
        return r

    def flush_exit(self, wait_s=3.0):
        """Beim Beenden: Warteschlange kurz abarbeiten lassen, dann JSON immer auf den letzten Stand."""
        try:
            end = time.time() + wait_s
            while time.time() < end and (not self.q.empty() or self.busy) and self.th is not None and self.th.is_alive():
                time.sleep(0.05)
            for n, (pth, s, t) in list(self.last_text.items()):
                self._file(pth, s, t)
        except Exception as e:
            print("sqlC: JSON beim Beenden:", e, flush=True)


_SQLB_W = SqlcWriter()


def selftest_sqlc():
    import tempfile
    d = os.path.abspath(tempfile.mkdtemp(prefix="sqlcsdr-"))
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    import database as _d
    pdb = os.path.join(d, "lagezentrum.db")
    assert _d.migrate(pdb) and _d.migrate_t2(pdb)
    fs, fb = os.path.join(d, "sdr_status.json"), os.path.join(d, "broadcast_state.json")
    assert sqlc_mode_of({}) == "db" and sqlc_mode_of({"db_transport": "on"}) == "dual" and sqlc_mode_of({"db_transport": "off"}) == "json" and sqlc_mode_of({"db_transport": "db"}) == "db"
    w = SqlcWriter()
    assert not w.write(fs, "{}")                                                   # nicht gestartet: alter Weg
    w.base, w.db, w.th = d, _d, _SqlcFakeThread()
    try:
        import sdr_manager as _s
        w.sm = _s
    except Exception:
        w.sm = None
    drain = lambda: [w._process(w.q.get()) for _ in range(w.q.qsize())]
    mt = lambda f: os.path.getmtime(f) if os.path.exists(f) else None
    s1 = json.dumps({"t": 1, "n": 1})
    assert w.write(fs, s1) and json.load(open(fs)) == {"t": 1, "n": 1} and w.st["fallback"]       # Start: bis erstes DB-Schreiben JSON
    drain()
    assert w.ok_t and json.loads(_d.state_get("sdr_status", pdb)["text"]) == {"t": 1, "n": 1}
    w.write(fs, json.dumps({"t": 2})); drain()
    assert json.load(open(fs)) == {"t": 1, "n": 1} and w.st["fallback"] is False                  # gesund: nur DB, Datei bleibt (Notkopie erst nach 10 min)
    assert json.loads(_d.state_get("sdr_status", pdb)["text"]) == {"t": 2}
    w.file_t["sdr_status.json"] -= SQLC_MIRROR_S + 1
    w.write(fs, json.dumps({"t": 3})); drain()
    assert json.load(open(fs)) == {"t": 3} and not w.st["fallback"]                               # Notkopie faellig -> einmal JSON
    w.write(fs, json.dumps({"t": 4})); drain()
    assert json.load(open(fs)) == {"t": 3}
    # DB gesperrt/Fehler -> JSON im selben Durchgang wieder
    real_put = _d.state_put
    try:
        _d.state_put = lambda *a, **k: False
        w.write(fb, json.dumps({"bc": 1}))
        w.write(fs, json.dumps({"t": 5})); drain()
        assert json.load(open(fs)) == {"t": 5} and json.load(open(fb)) == {"bc": 1} and w.st["fallback"], w.st   # sofort JSON (beide)
        w.write(fs, json.dumps({"t": 6})); drain()
        assert json.load(open(fs)) == {"t": 6}                                                    # bleibt JSON solange Fehler
    finally:
        _d.state_put = real_put
    for i in range(SQLC_OK_RUN + 1):                                                              # wieder gesund, aber Hysterese
        w.write(fs, json.dumps({"t": 7 + i})); drain()
    assert json.load(open(fs)) == {"t": 7 + SQLC_OK_RUN} and w.st["fallback"]                     # < 180 s nach Fehler: weiter JSON
    w.fail_t -= SQLC_HYST_S + 1
    w.write(fs, json.dumps({"t": 20})); drain()
    assert json.load(open(fs)) == {"t": 7 + SQLC_OK_RUN} and w.st["fallback"] is False            # nach Hysterese: nur DB
    # Anforderung des Dashboards -> JSON
    if w.sm is not None and hasattr(w.sm, "_sqlc_request"):
        assert w.sm._sqlc_request(d, "Test: DB nicht lesbar", time.time())
    else:
        write_json(os.path.join(d, SQLC_REQ), {"t": int(time.time()), "until": int(time.time()) + 600})
    w.write(fs, json.dumps({"t": 21})); drain()
    assert json.load(open(fs)) == {"t": 21} and w.st["fallback"] and w.st["req_until"]
    write_json(os.path.join(d, SQLC_REQ), {"t": int(time.time()) - 700, "until": int(time.time()) - 100})
    w.write(fs, json.dumps({"t": 22})); drain()
    assert json.load(open(fs)) == {"t": 21} and w.st["fallback"] is False                         # Anforderung abgelaufen
    # Warteschlange voll -> sofort JSON, nie blockieren
    for i in range(SQLB_Q_MAX):
        w.offer(fs, "{}")
    w.write(fs, json.dumps({"t": 23}))
    assert json.load(open(fs)) == {"t": 23} and w.st["drop"] >= 1
    drain()
    # Schreibfaden tot / letztes DB-Schreiben zu alt -> JSON
    w.fail_t -= SQLC_HYST_S + 1
    w.ok_run = SQLC_OK_RUN
    w.ok_t = time.time() - SQLC_OK_MAX_S - 5
    w.write(fs, json.dumps({"t": 24})); drain()
    assert json.load(open(fs)) == {"t": 24}
    # Start ueber DB: neuerer Stand aus DB
    assert sqlc_load(fs) == {"t": 24}
    _d.state_put("sdr_status", json.dumps({"t": 99}), time.time() + 5, pdb)
    assert sqlc_load(fs) == {"t": 99} and sqlc_load(os.path.join(d, "fehlt.json"), {"x": 1}) == {"x": 1}
    # Beenden: JSON immer aktuell
    w.last_text["sdr_status.json"] = (fs, json.dumps({"t": 25}), time.time() + 10)
    w.flush_exit(0.2)
    assert json.load(open(fs)) == {"t": 25}
    # Schalter: on = beides (alter Weg), off = nur JSON
    write_json(os.path.join(d, "sdr_config.json"), {"db_transport": "on"})
    assert not w.write(fs, "{}") and w.mode() == "dual" and w.on()
    write_json(os.path.join(d, "sdr_config.json"), {"db_transport": "off"})
    assert not w.write(fs, "{}") and w.mode() == "json" and not w.on() and not w.offer(fs, "{}")
    write_json(os.path.join(d, "sdr_config.json"), {"db_transport": "db"})
    assert w.mode() == "db"
    assert _SQLB_W.th is None and isinstance(_SQLB_W, SqlcWriter)                                 # Selbsttest startet den echten Faden nie
    print("selftest sqlC ok (DB-primaer, Notkopie 10 min, DB-Fehler/verworfen/Faden alt -> sofort JSON, Hysterese 180 s + 3 gute, Anforderung Dashboard -> JSON, Start ueber DB, Beenden JSON aktuell, Schalter db/on/off)")
    return True
SQBR_EOF
EXPECT_BDA="9c9e3e4e6f025695ecce33f7b0be422fc6ba5d923ef2643af0ecb185721670a4"
cat > "$W/dash_block.py" << 'SQBA_EOF'
# ===== sqlC: DB-primaer - sdr_status/broadcast_state kommen aus lagezentrum.db, JSON nur Notkopie (alle 10 min) bzw. Ersatz; Dashboard bittet prepper-sdr per sdr_json_request.json um laufendes JSON, wenn es die DB nicht lesen kann (sdr_manager.sqlb_load); Stick-Test-Kachel liest ebenfalls DB zuerst; nur lesen + diese eine Anforderungsdatei, sendet nichts =====
_SQC = {"selftest": None, "err": None}


def _sqc_selftest():
    assert _lz_mgr is not None and hasattr(_lz_mgr, "sqlc_mode") and hasattr(_lz_mgr, "_sqlc_request")
    assert "selftest sqlC ok" in _lz_mgr.selftest_sqlc()
    import tempfile
    d = tempfile.mkdtemp(prefix="sqc-")
    now = int(_sdr_time.time())
    b = {"t": now, "fm": {"BR24": {"name": "BR24", "f": "102.0M", "pi": "0xD315", "ps": "BR24", "t": now - 60, "pty": "News", "ta": False, "tp": True, "rt": ""}}, "dab": {}}
    p31 = [{"t": now - 10, "k": "pty31", "src": "BR24", "ps": "BR24", "persist": True}]
    fb = _sdr_os.path.join(d, "broadcast_state.json")
    pdb = _sdr_os.path.join(d, "lagezentrum.db")
    cfg = _sdr_os.path.join(d, "sdr_config.json")
    old = dict(b, fm={})                                                                         # alte Notkopie ohne BR24-Zeile
    _lz_mgr._write_json(fb, old)
    _sdr_os.utime(fb, (now - 500, now - 500))
    assert _lz_dbm.migrate(pdb) and _lz_dbm.state_put("broadcast_state", _lz_mgr.json.dumps(b), now - 5, pdb)
    seen = {}
    for v in ("db", "on"):                                                                       # DB-primaer / beides: Alarm aus der DB
        _lz_mgr._write_json(cfg, {"db_transport": v})
        _lz_mgr._SQLB["cache"].clear()
        x = _lz_mgr.sqlb_load(fb, {})
        seen[v] = _br24_eval(x, p31, now)["state"]
        assert x == b and seen[v] == "rot", (v, seen)
    _lz_mgr._write_json(fb, b)                                                                   # nur JSON (off) / Ersatz: Alarm aus der Datei
    _lz_mgr._write_json(cfg, {"db_transport": "off"})
    _lz_mgr._SQLB["cache"].clear()
    seen["off"] = _br24_eval(_lz_mgr.sqlb_load(fb, {}), p31, now)["state"]
    _sdr_os.remove(cfg)
    _sdr_os.remove(pdb)
    _lz_mgr._SQLB["cache"].clear()
    _lz_mgr._SQLB["req"].clear()
    seen["ersatz"] = _br24_eval(_lz_mgr.sqlb_load(fb, {}), p31, now)["state"]
    assert seen["off"] == "rot" and seen["ersatz"] == "rot" and _lz_mgr._SQLB["src"]["broadcast_state.json"]["src"] == "json-fallback", seen
    assert _lz_mgr.sqlc_request_until(d, now)                                                    # DB weg -> Anforderung JSON an prepper-sdr
    _lz_mgr._SQLB["cache"].clear()
    _lz_mgr._SQLB["req"].clear()
    assert "_sqb_load" in globals() and "_sqb_load" in _stk_load.__code__.co_names                     # Stick-Test-Kachel liest ueber DB zuerst
    return "sqlC selftest ok (Alarm PTY 31 erkannt bei db/on/off/Ersatz, DB weg -> Anforderung JSON, Stick-Test-Kachel DB zuerst)"


try:
    try:
        _SQC["selftest"] = _sqc_selftest()
    except Exception as _sqc_e1:
        _SQC["selftest"] = "sqlC selftest FEHLER: %s" % _sqc_e1
    if str(_SQC["selftest"]).startswith("sqlC selftest ok"):
        _sqc_tr = _lz_mgr.transport_status(_SDR_BASE)
        print("sqlC aktiv: %s; Betriebsart %s; %s" % (_SQC["selftest"], _sqc_tr.get("mode"), _sqc_tr.get("line")), flush=True)
    else:
        print("sqlC FEHLER: %s" % _SQC["selftest"], flush=True)
except Exception as _sqc_e:
    _SQC["err"] = str(_sqc_e)[:160]
    print("sqlC FEHLER:", _sqc_e, flush=True)
# ===== /sqlC =====
SQBA_EOF
EXPECT_G="1c5990bc85c058dca9966bd0ebe6e16e5a3891a8b1f39acb64c073061d129bb4"
cat > "$W/guard_sqlc.py" << 'SQG_EOF'
"""sqlC AST-Guard. Aufruf: guard_sqlb.py EDITS  ART ALT NEU BLOCK ... (ART = db | sm | sdr | dash) -> 0 ok, 1 Verstoss.
Ruecktausch (Block weg, Stellen zurueck) muss Byte fuer Byte die Basis ergeben (schon eingespielt: Basis = Ergebnis -> nur Struktur).
Neue Bloecke/Stellen: keine Prozesse, kein Netz, kein shell, keine Sendewege, keine Routen. prepper_sdr: nur der DB-Schreibfaden
(Importe threading/queue/json/os/sys/time/tempfile/database/sdr_manager), sonst nur threading/tempfile/os/time/json."""
import ast
import sys
rd = lambda f: open(f, encoding="utf-8").read()
g = {}
exec(compile(rd(sys.argv[1]), "edits", "exec"), g)
EDS = {"sm": g["SM_EDITS"], "sdr": g["SDR_EDITS"], "dash": g["DASH_EDITS"]}
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
        err.append("%s: Block sqlC fehlt oder doppelt" % kind)
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1) if kind != "dash" else new.replace(B, "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("%s: Stelle fehlt %s" % (kind, n.strip().splitlines()[0][:60]))
        r = r.replace(n, o, 1)
    if not done and r != old:
        err.append("%s: anders geaendert als %d Stellen + Block sqlC" % (kind, len(E)))
    new_code.append((kind, "Block", B))
    for o, n in E:
        ol = set(o.splitlines())
        new_code.append((kind, "Stelle", "\n".join(x for x in n.splitlines() if x not in ol)))   # nur hinzugefuegte Zeilen
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
print("OK AST-Guard sqlC: sdr_manager.py, prepper_sdr.py, dashboard.py nur die vorgesehenen Stellen + Block sqlC%s; prepper_sdr nur DB-Schreibfaden (keine Prozesse, kein Netz, kein shell); Dashboard ohne neue Sendewege/Routen" %
      (" (schon eingespielt)" if all(rd(a[i + 1]) == rd(a[i + 2]) for i in range(0, len(a), 4)) else ""))
SQG_EOF
EXPECT_C="3a6213106b1d299dbce29f237b13cdcb255661460a7d12f15c5d6455bc06cc87"
cat > "$W/sqlccheck.py" << 'SQC_EOF'
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
SQC_EOF
P="$W/patch-sqlc.py"; ED="$W/edits.py"; BSM="$W/sm_block.py"; BSR="$W/sdr_block.py"; BDA="$W/dash_block.py"; SG="$W/guard_sqlc.py"; CK="$W/sqlccheck.py"
for x in "$EXPECT_P $P" "$EXPECT_E $ED" "$EXPECT_BSM $BSM" "$EXPECT_BSR $BSR" "$EXPECT_BDA $BDA" "$EXPECT_G $SG" "$EXPECT_C $CK"; do set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }; done
# ---------- 1) Basis ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
kn() { [[ "$1" == "$2" ]] && echo "bekannt ($3)" || echo "neu, Erkennung ueber Guards"; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_D16" "sqlB"))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16" "sqlB"))"
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $(kn "$SDR16" "$KNOWN_SDR16" "sqlB"))"
echo "database.py sha16 $DB16 ($(wc -l < "$DBF") Zeilen, $(kn "$DB16" "$KNOWN_DB16" "sqlB")) - bleibt unveraendert"
echo "mesh_router.py sha16 $MR16 ($(wc -l < "$MR") Zeilen, $(kn "$MR16" "$KNOWN_MR16" "Teil 3")) - bleibt unveraendert"
echo "lagegeo.py sha16 $LG16 ($(kn "$LG16" "$KNOWN_LG16" "lageGeo")) - bleibt unveraendert"
grep -q '# ===== sqlB:' "$F" || { echo "STOP: sqlB fehlt in dashboard.py - bitte zuerst apply-sqlb.sh, nichts geaendert"; exit 1; }
grep -q 'def selftest_sqlb' "$SMF" || { echo "STOP: sqlB fehlt in sdr_manager.py - nichts geaendert"; exit 1; }
grep -q '# ===== sqlB:' "$M" || { echo "STOP: sqlB fehlt in prepper_sdr.py - nichts geaendert"; exit 1; }
grep -q 'def state_get' "$DBF" || { echo "STOP: sqlB fehlt in database.py - nichts geaendert"; exit 1; }
python3 "$P" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" "$ED" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: sdr_manager.py unbekannte Basis (sha16 $SM16) - nichts geaendert"; exit 1; }
python3 "$P" sdr "$M" "$W/work/prepper_sdr.py" "$BSR" "$ED" > "$W/p3.log" || { cat "$W/p3.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $SDR16) - nichts geaendert"; exit 1; }
python3 "$P" dash "$F" "$W/work/dashboard.py" "$BDA" "$ED" > "$W/p4.log" || { cat "$W/p4.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
echo "OK Basis erkannt: $(cat "$W/p2.log"); $(cat "$W/p3.log"); $(cat "$W/p4.log")"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
MODE=$(python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
v=str(d.get('db_transport','db') if isinstance(d,dict) else 'db').strip().lower()
print('json' if v in ('off','aus','0','false','nein','no') else ('dual' if v in ('on','an','dual','1','true','ja','yes','beides') else 'db'))" "$DASH_DIR/sdr_config.json" 2>/dev/null || echo db)
HASKEY=$(grep -c '"db_transport"' "$DASH_DIR/sdr_config.json" 2>/dev/null || true)
echo "Schalter db_transport in sdr_config.json: $([[ "${HASKEY:-0}" == 0 ]] && echo "fehlt" || echo "gesetzt") -> Betriebsart $MODE (db = DB-primaer, dual = beides wie sqlB, json = nur JSON; Datei wird nicht geaendert)"
# ---------- 2) Trockenlauf ----------
for k in "sm sdr_manager $BSM" "sdr prepper_sdr $BSR" "dash dashboard $BDA"; do set -- $k
  python3 "$P" "$1" "$W/work/$2.py" "$W/work/x.py" "$3" "$ED" >/dev/null && cmp -s "$W/work/$2.py" "$W/work/x.py" || { echo "STOP: $2 nicht idempotent - nichts geaendert"; exit 1; }
done
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/sdr_manager.py" "$W/work/prepper_sdr.py" "$W/work/dashboard.py" "$DBF"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
cp "$DBF" "$W/work/sdr_manager.py" "$W/work/prepper_sdr.py" "$MR" "$W/sbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 120 "$py" database.py > "$W/dbt.log" 2>&1) || { tail -12 "$W/dbt.log"; echo "STOP: Selbsttest database ($py) - nichts geaendert"; exit 1; }
  for k in "database selftest ok" "database selftest sqlA ok" "database selftest sqlB ok"; do
    grep -qF "$k" "$W/dbt.log" || { echo "STOP: Selbsttest database ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && timeout 180 "$py" sdr_manager.py > "$W/smt.log" 2>&1) || { tail -12 "$W/smt.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok" "sdr_manager selftest kartevec ok" "sdr_manager selftest sqlA ok" "sdr_manager selftest sqlB ok" "sdr_manager selftest sqlC ok"; do
    grep -qF "$k" "$W/smt.log" || { echo "STOP: Selbsttest sdr_manager ohne $k ($py) - nichts geaendert"; exit 1; }
  done
  (cd "$W/sbx" && timeout 300 "$py" prepper_sdr.py selftest > "$W/sdrt.log" 2>&1) || { tail -15 "$W/sdrt.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil2 ok" "selftest sdrTeil4 ok" "selftest rdsNotfall ok" "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest OK:" "selftest sqlB ok" "selftest sqlC ok"; do
    grep -qF "$k" "$W/sdrt.log" || { echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttests mit $SPY und $VPY (Sandbox, Test-DB, nichts gesendet):"
echo "  $(grep 'selftest sqlC' "$W/smt.log" | cut -c1-240)"
echo "  prepper_sdr $(grep 'selftest sqlC' "$W/sdrt.log" | cut -c1-240)"
python3 "$SG" "$ED" sm "$SMF" "$W/work/sdr_manager.py" "$BSM" sdr "$M" "$W/work/prepper_sdr.py" "$BSR" dash "$F" "$W/work/dashboard.py" "$BDA" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
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
echo "Leser von sdr_status.json/broadcast_state.json auf dem Pi (nur lesen):"
python3 "$CK" audit "$DASH_DIR" 2>/dev/null || echo "  Suche nicht moeglich"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
HADREQ=0; [[ -f "$REQ" ]] && HADREQ=1
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
ALL=("$SMF" "$M" "$F")
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/sdr_manager.py" "$SMF" && cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK sqlC schon installiert - kein Neustart"
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
      sudo journalctl -u "$u" --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sqlC|Traceback" | tail -6 | cut -c1-200 || true
    done
    for x in "${ALL[@]}"; do [[ -f "$x.bak-sqlc-$TS" ]] && cp -a "$x.bak-sqlc-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    [[ "$HADREQ" == 0 ]] && rm -f "$REQ"
    sudo systemctl restart prepper-sdr.service || true
    for i in $(seq 1 60); do sleep 3; systemctl is-active --quiet prepper-sdr && break; done
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 60); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-sqlc-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  sqlB-Stand (beides: JSON laufend + DB) wieder aktiv; Sicherung lagezentrum.db von vorher: $LZ.bak-sqlc-$TS"
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}"; do
    cp -a "$x" "$x.bak-sqlc-$TS"
    { ls -1t "$x.bak-sqlc-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$LZ" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$LZ" "$LZ.bak-sqlc-$TS" \
      || { rm -f "$LZ.bak-sqlc-$TS"; for x in "${ALL[@]}"; do rm -f "$x.bak-sqlc-$TS"; done; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$LZ.bak-sqlc-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  for k in "sdr_manager $SMF" "prepper_sdr $M" "dashboard $F"; do set -- $k
    cp "$W/work/$1.py" "$2.new" && chmod --reference="$2.bak-sqlc-$TS" "$2.new" && mv -f "$2.new" "$2" || { rb "installieren $1"; exit 1; }
  done
  sudo systemctl restart prepper-sdr.service
  echo "Neustart prepper-sdr - warte auf frischen SDR-Status (DB oder JSON, max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$CK" statusfresh "$DASH_DIR" "$T0" && { ok=1; break; }; done
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
for p in / /funk /dabhist /karte /api/sdr/live /api/sdr/map /api/sdr/sticktest /api/t2/status /api/t4/status /api/t4/tii; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
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
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "(sqlC|sqlB|sqlA|kartevec) (aktiv|FEHLER)" | tail -10 || true)
if [[ "$JD" == *"FEHLER"* ]]; then rbx "Dashboard: $(echo "$JD" | grep FEHLER | tail -2)"; fi
if [[ "$JD" == *"sqlC aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'sqlC aktiv' | tail -1 | cut -c1-240)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet sqlC nicht (Journal)"; fi
JS=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "sqlB: DB-Schreibfaden|sqlC: Transport" | tail -2 || true)
if [[ "$JS" == *"nicht gestartet"* ]]; then rbx "prepper-sdr: $JS"; fi
if [[ "$JS" == *"sqlC: Transport"* ]]; then echo "OK Journal prepper-sdr: $(echo "$JS" | grep 'sqlC: Transport' | tail -1 | cut -c1-230)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "prepper-sdr meldet sqlC nicht (Journal)"; fi
"${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true
python3 "$CK" live "$W/live.json" > "$W/live.log" 2>&1 && echo "OK $(cat "$W/live.log")" || { cat "$W/live.log"; rbx "/api/sdr/live ohne Transport-Anzeige (Betriebsart)"; }
if [[ "$MODE" == db ]]; then
  echo "Warte, bis prepper-sdr DB-primaer laeuft (erstes DB-Schreiben, Start-Ersatz endet; max 240 s) ..."
  DBOK=""
  for i in $(seq 1 48); do "${CURL[@]}" "$B/api/sdr/live" -o "$W/live.json" || true; DBOK=$(python3 "$CK" dbok "$W/live.json" 2>"$W/dbok.err" || true); [[ -n "$DBOK" ]] && break; sleep 5; done
  [[ -n "$DBOK" ]] && echo "OK $DBOK" || { cat "$W/dbok.err" | tail -2; rbx "DB-primaer nicht erreicht (240 s)"; }
  python3 "$CK" live "$W/live.json" > "$W/live.log" 2>&1 && echo "OK $(cat "$W/live.log")" || true
  [[ -n "$(python3 -c "
import json,sys,time
try: d=json.load(open(sys.argv[1]))
except Exception: d={}
print('aktiv' if isinstance(d.get('until'),(int,float)) and d['until']>time.time() else '')" "$REQ" 2>/dev/null)" ]] && echo "WARNUNG Dashboard hat JSON angefordert (sdr_json_request.json aktiv) - DB-Lesefehler im Dashboard?" || echo "OK keine aktive JSON-Anforderung des Dashboards"
else
  echo "Hinweis: Betriebsart $MODE (db_transport gesetzt) - JSON wird wie vorher laufend geschrieben"
fi
"${CURL[@]}" "$B/api/t4/status" -o "$W/t4.json" || true
python3 "$CK" t4 "$W/t4.json" > "$W/t4.log" 2>&1 && echo "OK $(cat "$W/t4.log")" || { cat "$W/t4.log"; rbx "/api/t4/status ohne Datenquelle"; }
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sqlC FEHLER|sqlB FEHLER|database is locked" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sqlC-Fehler/database is locked" || rbx "$E Traceback/sqlC-Fehlerzeilen im Journal Dashboard"
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sqlB: Schreibfehler|sqlC: Fehler im Schreibfaden" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/DB-Schreibfehler" || rbx "$E Traceback/DB-Fehlerzeilen im Journal prepper-sdr"
[[ "$(s16 "$DBF")" == "$DB16" ]] && echo "OK database.py unveraendert ($DB16)" || rbx "database.py hat sich veraendert"
[[ "$(s16 "$MR")" == "$MR16" ]] && echo "OK mesh_router.py unveraendert ($MR16)" || rbx "mesh_router.py hat sich veraendert"
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
echo "OK guards sqlC(dash)=$(grep -c '# ===== sqlC:' "$F" || true) sqlB(dash)=$(grep -c '# ===== sqlB:' "$F" || true) sqlA(dash)=$(grep -c '# ===== sqlA:' "$F" || true) sqlC(sdr_manager)=$(grep -c 'def selftest_sqlc' "$SMF" || true) sqlB(sdr_manager)=$(grep -c 'def selftest_sqlb' "$SMF" || true) sqlC(sdr)=$(grep -c '# ===== sqlC:' "$M" || true) sqlB(sdr)=$(grep -c '# ===== sqlB:' "$M" || true) tiiFix2(sdr)=$(grep -c '# tiiFix2' "$M" || true) sqlB(database)=$(grep -c 'def selftest_state' "$DBF" || true)"
[[ -f "$F.bak-sqlc-$TS" ]] && echo "Backups: *.bak-sqlc-$TS (sdr_manager.py, prepper_sdr.py, dashboard.py, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG sqlc=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, sqlC bleibt aktiv. COMMIT $COMMIT_ARG sqlc=1"; exit 0' INT
if [[ "$MODE" == db ]]; then
  echo "Abschlusspruefung (nur lesen): JSON-Dateien werden nicht mehr jede Minute geschrieben"
  python3 "$CK" observe "$DASH_DIR" "$OBS_S" || true
fi
echo "Was bleibt als Datei: sdr_dabhist.json (Verlauf /dabhist, alle 300 s), broadcast_events.jsonl, alle uebrigen prepper-sdr-Dateien unveraendert."
echo "Zurueck zu sqlB (beides laufend): in sdr_config.json \"db_transport\": \"on\" eintragen, dann sudo systemctl restart prepper-sdr. Nur JSON: \"off\"."
echo "COMMIT $COMMIT_ARG sqlc=1 fertig"
