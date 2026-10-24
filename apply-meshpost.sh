#!/bin/bash
set -euo pipefail
# meshPost (commit14): GET sendet nie mehr ins Mesh. /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_spaceweather, /api/mesh_luft und /api/mesh_test senden nur noch per POST von der eigenen Seite
# (Origin/Referer = eigene Adresse, Kopf X-Mesh-Post: 1, JSON; kein PIN, wie bei den bestehenden Sende-Knoepfen). GET auf diese Wege = Vorschau-JSON ohne Senden (sent=false; /api/mesh_test: 405). Die 6 Aufruferstellen im Dashboard-JavaScript
# werden auf POST umgestellt. Neu: GET /api/meshpost/status (nur lesen). Bestehende Sende-Logik (Dedup, Raten, Kanal 0, funkHarden2) bleibt unveraendert.
# Baut auf dem projDoc-Stand (live: dashboard d383771a011d82cd, prepper_docs f0d04208dd9b1d20, prepper_sdr f709b303d33a61c5, sdr_manager 002f6c5cad4bc1cb, database 431077d36822a090, mesh_router c5ffda3907b0dd51, lagegeo 3788481354f47656).
# Aendert dashboard.py (ein angehaengter Block meshPost + 6 Aufruferstellen) und prepper_docs.py (Beschreibung: Sende-Wege nur POST), erzeugt eine neue Version in docs/ (alte bleiben). Neustart nur prepper-dashboard (Dienst, kein Reboot, prepper-sdr bleibt).
# Sendet nichts (kein Mesh, kein Telegram, keine Alarme) und ruft die sechs Wege nie auf (weder GET noch POST); nichts aus config.py/secrets/ gelesen ausser der Zeile PORT = n.
# Basis streng (sha16): projDoc-Stand oder meshPost schon drin. Sonst Abbruch ohne Aenderung. Sicherungen: letzte 3 (dashboard.py, prepper_docs.py) + SQLite-Sicherung lagezentrum.db.
COMMIT_ARG="${1:-unbekannt}"
unset PRDOCS_NOW PRDOCS_SYSTEMCTL PRDOCS_SBIN PRDOCS_SUDOERS PRDOCS_UNITDIR PRDOCS_BASE PRDOCS_OUT PRDOCS_PORT
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
PD="$DASH_DIR/prepper_docs.py"
DOCS="$DASH_DIR/docs"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
CF="$DASH_DIR/sdr_config.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/meshpost-apply
KEEP_LAST=3
KNOWN_D16="d383771a011d82cd"     # dashboard.py nach projDoc (Basis)
KNOWN_D16N="f5b5cd5059b8ff0d"            # dashboard.py nach meshPost (Ziel)
KNOWN_PD16O="f0d04208dd9b1d20"    # prepper_docs.py nach projDoc (Basis)
KNOWN_PD16="3584d11bc2c365a3"            # prepper_docs.py nach meshPost (Ziel)
KNOWN_SDR16="f709b303d33a61c5"   # prepper_sdr.py (bleibt)
KNOWN_SM16="002f6c5cad4bc1cb"    # sdr_manager.py (bleibt)
KNOWN_CF16="476d8ad4b930c558"    # sdr_config.json (bleibt; nur Hinweis, weil andere Arbeitsschritte die Konfiguration anpassen koennen)
KNOWN_DB16="431077d36822a090"    # database.py (bleibt)
KNOWN_MR16="c5ffda3907b0dd51"    # mesh_router.py (bleibt)
KNOWN_LG16="3788481354f47656"    # lagegeo.py (bleibt)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== meshPost apply (GET sendet nie mehr ins Mesh: Senden nur per POST von der eigenen Seite; Beschreibung und neue Version in docs/), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx" "$W/fk"

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
EXPECT_AE="2fff328ab111c56d05a8a48648d00519ba23d4bd68b78b7b5fa72f92fd17a619"
cat > "$W/mp_edits.py" << 'AE_EOF'
# meshPost: Aufrufer der sechs Routen von GET auf POST (gleicher Ursprung + X-Mesh-Post). Basis = projDoc-Stand (dashboard d383771a011d82cd).
_H = '{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"}'
_HS = _H.replace('"', "'")
DSH_EDITS = [
    ('fetch("/api/mesh_test",{method:"POST"})', 'fetch("/api/mesh_test",' + _H + ')'),
    ('fetch("/api/mesh_spaceweather")', 'fetch("/api/mesh_spaceweather",' + _H + ')'),
    ('fetch("/api/mesh_odl")', 'fetch("/api/mesh_odl",' + _H + ')'),
    ('fetch("/api/mesh_weather")', 'fetch("/api/mesh_weather",' + _H + ')'),
    ('fetch("/api/mesh_pegel")', 'fetch("/api/mesh_pegel",' + _H + ')'),
    ("fetch('/api/mesh_luft')", "fetch('/api/mesh_luft'," + _HS + ")"),
]
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
AE_EOF
EXPECT_ABK="6228a4882a693663a8d81f35e717e6e476c41e12f70eb904a9ca0aa782baca36"
cat > "$W/mp_block.py" << 'ABK_EOF'
# ===== meshPost: GET sendet nie mehr ins Mesh - /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_spaceweather, /api/mesh_luft, /api/mesh_test senden nur noch per POST (gleicher Ursprung, Kopf X-Mesh-Post), GET liefert eine Vorschau ohne Senden (mesh_test: 405); GET /api/meshpost/status (nur lesen). Bestehende Sende-Logik (maybe_mesh_*, Dedup, Raten, Kanal 0) bleibt unveraendert; sendet selbst nichts. =====
_MP_PATHS = (
    ("/api/mesh_weather", "weather"),
    ("/api/mesh_odl", "odl"),
    ("/api/mesh_pegel", "pegel"),
    ("/api/mesh_spaceweather", "spaceweather"),
    ("/api/mesh_luft", "luft"),
    ("/api/mesh_test", "test"),
)
_MP_STAT = {"get_preview": 0, "post_ok": 0, "post_denied": 0, "last": None}
_MP_CACHE = {}
_MP_WEATHER_TTL = 300


def _mp_same_origin(rq):
    """Gleiche Herkunftspruefung wie beim Knopf 'An Mesh 1 senden' (_lm1_same_origin): Origin/Referer/Sec-Fetch-Site muessen die eigene Seite sein, dazu Kopf X-Mesh-Post: 1 und JSON."""
    base = rq.host_url.rstrip("/")
    o = rq.headers.get("Origin")
    if o is not None and o.rstrip("/") != base:
        return False
    ref = rq.headers.get("Referer") or ""
    if o is None and not (ref == base or ref.startswith(base + "/")):
        return False
    sfs = rq.headers.get("Sec-Fetch-Site")
    if sfs is not None and sfs != "same-origin":
        return False
    return rq.headers.get("X-Mesh-Post") == "1" and (rq.mimetype or "") == "application/json"


def _mp_preview_text(key):
    """Text, den der Knopf senden wuerde - nur aus Zwischenspeicher/Textbauern, ohne Senden und ohne Status zu schreiben (Wetter: Open-Meteo-Abfrage, 5 Minuten gepuffert). None = nicht verfuegbar."""
    g = globals()
    ds = g.get("data_store")
    ds = ds if isinstance(ds, dict) else {}

    def val(k):
        b = ds.get(k)
        return b.get("value") if isinstance(b, dict) else None
    if key == "test":
        return "NINA Test"
    if key == "weather":
        import time
        c = _MP_CACHE.get("weather")
        if c and time.time() - c[0] < _MP_WEATHER_TTL:
            return c[1]
        f = g.get("build_mesh_weather_text")
        t = f() if callable(f) else None
        if t:
            _MP_CACHE["weather"] = (time.time(), t)
        return t
    src = {"odl": ("odl", "build_mesh_odl_text"), "pegel": ("pegel", "build_mesh_pegel_text"),
           "spaceweather": ("spaceweather", "build_mesh_spaceweather_text"), "luft": ("luft", "build_mesh_luft_text")}.get(key)
    if not src:
        return None
    d = val(src[0])
    f = g.get(src[1])
    if not d or not callable(f):
        return None
    return f(d)


def _mp_get(key):
    """GET: nie senden. Vorschau-JSON (ok false, sent false); fuer /api/mesh_test 405."""
    from flask import jsonify
    text, err = None, None
    try:
        if key != "test":
            text = _mp_preview_text(key)
    except Exception as e:
        err = str(e)[:80]
    _MP_STAT["get_preview"] += 1
    _MP_STAT["last"] = key
    body = {"ok": False, "sent": False, "preview": True, "text": text if key != "test" else None,
            "error": "GET sendet nichts - Senden nur per POST (Knopf auf der Seite)"}
    if err:
        body["preview_error"] = err
    r = jsonify(body)
    if key == "test":
        r.status_code = 405
        r.headers["Allow"] = "POST"
    r.headers["Cache-Control"] = "no-store"
    r.headers["X-MeshPost"] = "get-no-send"
    return r


def _mp_make(key, vf):
    def v(*a, **kw):
        from flask import request as rq, jsonify
        if rq.method != "POST":
            return _mp_get(key)
        if not _mp_same_origin(rq):
            _MP_STAT["post_denied"] += 1
            r = jsonify({"ok": False, "sent": False, "error": "nur von der Seite (gleicher Ursprung, POST)"})
            r.status_code = 403
            return r
        _MP_STAT["post_ok"] += 1
        _MP_STAT["last"] = key
        if rq.path.startswith("/api/"):
            print("meshPost: POST %s von der Seite -> bestehender Sendeweg" % rq.path, flush=True)
        return vf(*a, **kw)
    v.__name__ = getattr(vf, "__name__", "meshpost_view")
    v.__doc__ = getattr(vf, "__doc__", None)
    v._mp = True
    v.__wrapped__ = vf
    return v


def _mp_deny(*a, **kw):
    """Sicherer Zustand, falls meshPost beim Start scheitert: die sechs Routen senden dann gar nicht (503)."""
    from flask import jsonify
    r = jsonify({"ok": False, "sent": False, "error": "meshPost nicht aktiv - Route gesperrt (sicherer Zustand)"})
    r.status_code = 503
    return r


def _mp_status():
    from flask import jsonify
    rows = {}
    for p, k in _MP_PATHS:
        ms, g = set(), False
        for r in app.url_map.iter_rules():
            if r.rule == p:
                ms |= set(m for m in (r.methods or ()) if m not in ("HEAD", "OPTIONS"))
                g = g or bool(getattr(app.view_functions.get(r.endpoint), "_mp", False))
        rows[p] = {"key": k, "guarded": g, "methods": sorted(ms)}
    return jsonify({"meshPost": 1, "paths": rows, "stat": dict(_MP_STAT)})


def _mp_selftest():
    """Fake-Sender in einer Wegwerf-App: GET sendet nie, POST nur mit gleichem Ursprung. Nichts Echtes wird aufgerufen."""
    from flask import Flask
    saved = dict(_MP_STAT)
    try:
        calls = []

        def fake():
            calls.append(1)
            return "gesendet"
        t = Flask("mp-selftest")
        t.add_url_rule("/x", endpoint="x", view_func=_mp_make("odl", fake), methods=["GET", "POST"])
        t.add_url_rule("/y", endpoint="y", view_func=_mp_make("test", fake), methods=["GET", "POST"])
        c = t.test_client()
        ok_h = {"X-Mesh-Post": "1", "Origin": "http://localhost"}
        for p in ("/x", "/y"):
            r = c.get(p)
            assert not calls and r.status_code == (405 if p == "/y" else 200), (p, r.status_code)
            assert r.get_json()["sent"] is False and r.headers.get("X-MeshPost") == "get-no-send"
            for h in ({"X-Mesh-Post": "1"}, {"Origin": "http://localhost"}, {"X-Mesh-Post": "1", "Origin": "http://evil.example"},
                      {"X-Mesh-Post": "1", "Origin": "http://localhost", "Sec-Fetch-Site": "cross-site"}, {"X-Mesh-Post": "0", "Origin": "http://localhost"}):
                assert c.post(p, json={}, headers=h).status_code == 403 and not calls, (p, h)
            assert c.post(p, data="{}", headers=ok_h, content_type="text/plain").status_code == 403 and not calls
            assert c.head(p).status_code in (200, 405) and not calls
            assert c.delete(p).status_code == 405 and c.put(p).status_code == 405 and not calls
        r = c.post("/x", json={}, headers=ok_h)
        assert r.status_code == 200 and calls == [1], (r.status_code, calls)
        r = c.post("/y", json={}, headers={"X-Mesh-Post": "1", "Referer": "http://localhost/mesh"})
        assert r.status_code == 200 and len(calls) == 2
        assert _mp_preview_text("test") == "NINA Test"
    finally:
        _MP_STAT.update(saved)
    return "meshPost selftest ok (GET sendet nie, POST nur mit gleichem Ursprung + X-Mesh-Post, Fake-Sender 2 Aufrufe nur bei gueltigem POST)"


try:
    from flask import request as _mp_rq_probe  # noqa: F401  (Flask-Kontext ist hier vorhanden)
    _mp_n = {"wrapped": 0, "post_rules": 0, "missing": []}
    for _mp_path, _mp_key in _MP_PATHS:
        _mp_eps = sorted(set(r.endpoint for r in app.url_map.iter_rules() if r.rule == _mp_path))
        if not _mp_eps:
            _mp_n["missing"].append(_mp_path)
            continue
        for _mp_ep in _mp_eps:
            _mp_vf = app.view_functions.get(_mp_ep)
            if _mp_vf is None:
                continue
            if not getattr(_mp_vf, "_mp", False):
                app.view_functions[_mp_ep] = _mp_make(_mp_key, _mp_vf)
                _mp_n["wrapped"] += 1
            if not any(r.rule == _mp_path and "POST" in (r.methods or ()) for r in app.url_map.iter_rules()):
                app.add_url_rule(_mp_path, endpoint=_mp_ep, view_func=app.view_functions[_mp_ep], methods=["POST"])
                _mp_n["post_rules"] += 1
    if "mp_status" not in app.view_functions and not any(r.rule == "/api/meshpost/status" for r in app.url_map.iter_rules()):
        app.add_url_rule("/api/meshpost/status", endpoint="mp_status", view_func=_mp_status, methods=["GET"])
    print("meshPost aktiv: %s | Pfade geschuetzt=%d, POST-Regeln neu=%d, nicht gefunden=%s" % (_mp_selftest(), _mp_n["wrapped"], _mp_n["post_rules"], _mp_n["missing"] or "keine"), flush=True)
except Exception as _mp_e:
    for _mp_path, _mp_key in _MP_PATHS:
        try:
            for _mp_ep in set(r.endpoint for r in app.url_map.iter_rules() if r.rule == _mp_path):
                app.view_functions[_mp_ep] = _mp_deny
        except Exception:
            pass
    print("meshPost FEHLER (die sechs Routen sind jetzt gesperrt, sicherer Zustand):", _mp_e, flush=True)
# ===== /meshPost =====
ABK_EOF
EXPECT_AGD="f2907fcdafa4a21459dd0730ca9454e67f62117af340919168383ba2db46db6a"
cat > "$W/guard_meshpost.py" << 'AGD_EOF'
"""AST-Guard meshPost.
Aufruf:  guard_meshpost.py check ALT NEU BLOCK EDITS   -> 0 ok, 1 Verstoss  (ALT = dashboard.py nach projDoc, NEU = danach)
         guard_meshpost.py mutate BLOCK EDITS         -> Mutationstest: jede eingebaute Verfehlung MUSS erkannt werden (0 = alle erkannt)
Regeln: Rueckbau (Block weg, die 6 Aufruferstellen zurueck) ergibt ALT Byte fuer Byte. Der Block sendet selbst nie (kein Sendebezeichner, kein Netz/Prozess/Datei/DB/Faden),
ruft die bestehende View-Funktion (vf) genau einmal und nur NACH Methodenpruefung (nur POST) und Herkunftspruefung; GET geht immer in _mp_get. Genau 6 Pfade, POST-Regeln nur ["POST"],
Status-Route nur ["GET"]. Aufruferstellen: nur fetch(<Pfad>, {method POST + gleicher Ursprung + X-Mesh-Post}). Zusaetzlich laeuft der Selbsttest des Blocks (Fake-Sender) in einer Wegwerf-Umgebung."""
import ast
import re
import sys

PATHS = ["/api/mesh_weather", "/api/mesh_odl", "/api/mesh_pegel", "/api/mesh_spaceweather", "/api/mesh_luft", "/api/mesh_test"]
STATUS = "/api/meshpost/status"
FUNCS = {"_mp_same_origin", "_mp_preview_text", "_mp_get", "_mp_make", "_mp_deny", "_mp_status", "_mp_selftest"}
ASSIGNS = {"_MP_PATHS", "_MP_STAT", "_MP_CACHE", "_MP_WEATHER_TTL"}
BAD = ("subprocess", "popen", "socket", "requests", "urlopen", "urllib", "smtplib", "paramiko", "thread", "fork", "spawn", "execv", "kill", "sudo", "systemctl", "reboot", "chmod", "chown",
       "mesh", "telegram", "send", "outbox", "takeover", "sqlite", "eval", "exec", "pickle", "base64", "environ", "getenv", "system", "lagezentrum", "secret", "open", "compile", "import_module",
       "shutil", "tempfile", "api_mesh", "maybe_", "nina", "funk", "bridge", "alarm")
GET_ATTR_ST = {"post", "put", "delete", "head", "test_client"}          # nur im Selbsttest (Flask-Testclient der Wegwerf-App)
IMPORT_FN_OK = {"flask", "time"}


def _fn_of(tree):
    m = {}
    for f in ast.walk(tree):
        if isinstance(f, ast.FunctionDef):
            for x in ast.walk(f):
                m.setdefault(id(x), f.name)
    return m


def _same(a, b):
    return ast.dump(a) == ast.dump(b)


def check_block(B):
    err = []
    try:
        t = ast.parse(B)
    except SyntaxError as e:
        return ["Block: Syntax %s" % e]
    fn = _fn_of(t)
    ids = set()
    for n in ast.walk(t):
        if isinstance(n, ast.Name):
            ids.add(n.id.lower())
        elif isinstance(n, ast.Attribute):
            ids.add(n.attr.lower())
        elif isinstance(n, (ast.FunctionDef, ast.alias)):
            ids.add(n.name.lower())
        elif isinstance(n, ast.ImportFrom) and n.module:
            ids.add(n.module.lower())
        elif isinstance(n, ast.arg):
            ids.add(n.arg.lower())
    for w in BAD:
        hit = sorted(c for c in ids if w in c)
        if hit:
            err.append("Block: verbotener Bezeichner '%s' (%s)" % (w, ",".join(hit[:3])))
    names = {x.name for x in t.body if isinstance(x, ast.FunctionDef)}
    if names != FUNCS:
        err.append("Block: Funktionen %s statt %s" % (sorted(names), sorted(FUNCS)))
    tries = 0
    for n in t.body:
        if isinstance(n, ast.Assign):
            if ast.unparse(n.targets[0]) not in ASSIGNS:
                err.append("Block: Zuweisung auf Ebene 0: %s" % ast.unparse(n.targets[0]))
        elif isinstance(n, ast.FunctionDef):
            if n.decorator_list:
                err.append("Block: Dekorator an %s" % n.name)
        elif isinstance(n, ast.Try):
            tries += 1
        else:
            err.append("Block: Anweisung auf Ebene 0: %s" % type(n).__name__)
    if tries != 1:
        err.append("Block: %d Registrierungs-try statt 1" % tries)
    vf_calls = 0
    add_rules = []
    for n in ast.walk(t):
        f = fn.get(id(n), "?")
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for x in n.names:
                mod = (getattr(n, "module", None) or x.name).split(".")[0]
                if mod not in IMPORT_FN_OK:
                    err.append("Block: Import %s in %s" % (mod, f))
                if mod == "time" and f != "_mp_preview_text":
                    err.append("Block: time ausserhalb Vorschau")
        if isinstance(n, (ast.Delete, ast.Global, ast.Nonlocal, ast.Await, ast.AsyncFunctionDef, ast.ClassDef, ast.With)):
            err.append("Block: %s in %s" % (type(n).__name__, f))
        if isinstance(n, ast.Attribute) and n.attr in GET_ATTR_ST and f != "_mp_selftest":
            err.append("Block: Attribut %s ausserhalb des Selbsttests (%s)" % (n.attr, f))
        if isinstance(n, ast.Call):
            c = n.func
            nm = c.attr if isinstance(c, ast.Attribute) else getattr(c, "id", "")
            if nm == "vf":
                vf_calls += 1
            if nm == "globals" and f != "_mp_preview_text":
                err.append("Block: globals() in %s" % f)
            if nm in ("setattr", "delattr", "__import__", "locals", "vars", "input", "breakpoint"):
                err.append("Block: Aufruf %s in %s" % (nm, f))
            if nm == "getattr":
                ok = len(n.args) == 3 and isinstance(n.args[1], ast.Constant) and n.args[1].value in ("__name__", "__doc__", "_mp")
                if not ok:
                    err.append("Block: getattr nur mit __name__/__doc__/_mp (%s)" % f)
            if nm == "add_url_rule" and f == "_mp_selftest":
                if not (n.args and ast.unparse(n.args[0]) in ("'/x'", "'/y'") and isinstance(c.value, ast.Name) and c.value.id == "t"):
                    err.append("Block: add_url_rule im Selbsttest nur auf der Wegwerf-App t")
            elif nm == "add_url_rule":
                ms = [k for k in n.keywords if k.arg == "methods"]
                p0 = ast.unparse(n.args[0]) if n.args else "?"
                add_rules.append((p0, ast.unparse(ms[0].value) if ms else None, [k.arg for k in n.keywords]))
    if vf_calls != 1:
        err.append("Block: Aufruf der bestehenden View-Funktion vf %dx statt genau 1x" % vf_calls)
    # Registrierung: erste Regel POST (Pfadvariable), zweite Status-GET
    pm = sorted(a for a in add_rules if a[1] == "['POST']")
    gm = sorted(a for a in add_rules if a[1] == "['GET']")
    other = [a for a in add_rules if a[1] not in ("['POST']", "['GET']")]
    if len(pm) != 1 or len(gm) != 1 or other:
        err.append("Block: add_url_rule nicht genau 1x POST (Pfadschleife) + 1x GET (Status): %s" % add_rules)
    if gm and gm[0][0] != "'" + STATUS + "'":
        err.append("Block: GET-Regel nicht %s" % STATUS)
    if pm and pm[0][0] != "_mp_path":
        err.append("Block: POST-Regel nicht ueber die Pfadliste")
    # _MP_PATHS exakt
    got = None
    for n in t.body:
        if isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == "_MP_PATHS":
            try:
                got = [x[0] for x in ast.literal_eval(n.value)]
            except Exception:
                got = None
    if got != PATHS:
        err.append("Block: _MP_PATHS %s statt %s" % (got, PATHS))
    found = set(x for x in re.findall(r'"(/api/[A-Za-z0-9_/]+)"', B))
    if found != set(PATHS) | {STATUS}:
        err.append("Block: Pfad-Literale %s" % sorted(found))
    # Wrapper-Struktur: erst Methode, dann Herkunft, erst danach vf
    mk = [x for x in t.body if isinstance(x, ast.FunctionDef) and x.name == "_mp_make"]
    ok_struct = False
    if mk:
        inner = [x for x in mk[0].body if isinstance(x, ast.FunctionDef) and x.name == "v"]
        if inner:
            b = inner[0].body
            def ifx(s, test):
                return isinstance(s, ast.If) and ast.unparse(s.test) == test and not s.orelse and bool(s.body) and isinstance(s.body[-1], ast.Return)
            ig = [i for i, s in enumerate(b) if ifx(s, "rq.method != 'POST'") and ast.unparse(s.body[-1]) == "return _mp_get(key)"]
            io = [i for i, s in enumerate(b) if ifx(s, "not _mp_same_origin(rq)")]
            iv = [i for i, s in enumerate(b) if isinstance(s, ast.Return) and s.value is not None and ast.unparse(s.value) == "vf(*a, **kw)"]
            if len(ig) == 1 and len(io) == 1 and len(iv) == 1 and ig[0] < io[0] < iv[0] and iv[0] == len(b) - 1:
                if not any(isinstance(x, ast.Call) and getattr(x.func, "id", "") == "vf" for s in b[:iv[0]] for x in ast.walk(s)):
                    ok_struct = True
    if not ok_struct:
        err.append("Block: Wrapper _mp_make.v muss lauten: if rq.method != 'POST': return _mp_get(key) / if not _mp_same_origin(rq): ... return / return vf(*a, **kw)")
    # Herkunftspruefung enthaelt alle Bausteine
    so = [x for x in t.body if isinstance(x, ast.FunctionDef) and x.name == "_mp_same_origin"]
    if so:
        src = ast.unparse(so[0])
        for k in ("'Origin'", "'Referer'", "'Sec-Fetch-Site'", "'same-origin'", "'X-Mesh-Post'", "'application/json'", "host_url"):
            if k not in src:
                err.append("Block: _mp_same_origin ohne %s" % k)
    # _mp_get: nie vf, nie Statusfreigabe
    gt = [x for x in t.body if isinstance(x, ast.FunctionDef) and x.name == "_mp_get"]
    if gt and any(isinstance(x, ast.Name) and x.id == "vf" for x in ast.walk(gt[0])):
        err.append("Block: _mp_get beruehrt vf")
    # Marker
    if not B.startswith("# ===== meshPost:") or not B.rstrip("\n").endswith("# ===== /meshPost ====="):
        err.append("Block: Marker meshPost fehlen")
    # Selbsttest in Wegwerf-Umgebung
    if not err:                      # nur ein statisch sauberer Block wird ueberhaupt ausgefuehrt (nie ein Block mit Sende-/Netz-/Dateicode)
        e = run_selftest(B)
        if e:
            err.append("Block: Selbsttest schlaegt fehl: %s" % e)
    return err


class _FakeApp:
    class _M:
        @staticmethod
        def iter_rules():
            return []
    url_map = _M()
    view_functions = {}

    @staticmethod
    def add_url_rule(*a, **k):
        return None


def run_selftest(B):
    import builtins
    import io
    import contextlib
    import logging
    import socket
    c0, o0 = socket.socket.connect, builtins.open

    def _no(*a, **k):
        raise OSError("meshPost-Guard: Netz/Datei im Selbsttest gesperrt")

    def _open(f, mode="r", *a, **k):
        if any(x in str(mode) for x in "wax+"):
            _no()
        return o0(f, mode, *a, **k)
    try:
        socket.socket.connect = _no
        builtins.open = _open
        logging.disable(logging.CRITICAL)
        ns = {"app": _FakeApp, "__name__": "mp_guard"}
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(B, "meshpost_block", "exec"), ns)
            ns["_mp_selftest"]()
        return None
    except BaseException as e:
        return "%s: %s" % (type(e).__name__, str(e)[:80])
    finally:
        socket.socket.connect, builtins.open = c0, o0
        logging.disable(logging.NOTSET)


_H_RE = re.compile(r"""^fetch\((?P<q>["'])(?P<p>/api/mesh_[a-z]+)(?P=q),\{method:(?P=q)POST(?P=q),credentials:(?P=q)same-origin(?P=q),headers:\{(?P=q)Content-Type(?P=q):(?P=q)application/json(?P=q),(?P=q)X-Mesh-Post(?P=q):(?P=q)1(?P=q)\},body:(?P=q)\{\}(?P=q)\}\)$""")


def check_edits(E):
    err = []
    seen = []
    for o, n in E:
        m = _H_RE.match(n)
        if not m or m.group("p") not in PATHS:
            err.append("Aufrufer: neue Stelle nicht im erlaubten Muster: %s" % n[:60]); continue
        seen.append(m.group("p"))
        if not (o.startswith("fetch(") and m.group("p") in o):
            err.append("Aufrufer: alte Stelle passt nicht: %s" % o[:50])
        if o == n:
            err.append("Aufrufer: unveraendert: %s" % o[:50])
    if sorted(seen) != sorted(PATHS):
        err.append("Aufrufer: Pfade %s statt je einmal %s" % (sorted(seen), PATHS))
    return err


def check(old_f, new_f, blk_f, edp_f):
    rd = lambda f: open(f, encoding="utf-8").read()
    old, new, blk = rd(old_f), rd(new_f), rd(blk_f)
    g = {}
    exec(compile(rd(edp_f), edp_f, "exec"), g)
    E = g["DSH_EDITS"]
    B = blk.rstrip("\n") + "\n"
    err = []
    if new.count(B.rstrip("\n")) != 1:
        err.append("Block meshPost fehlt oder doppelt")
    r = new.replace("\n\n" + B.rstrip("\n"), "", 1)
    for o, n in E:
        if r.count(n) != 1:
            err.append("Aufrufer-Stelle fehlt/doppelt: %s" % n[:50])
        r = r.replace(n, o, 1)
    if r != old:
        err.append("dashboard.py: anders geaendert als nur durch Block meshPost + 6 Aufruferstellen (Rueckbau ergibt nicht die Basis)")
    err += check_block(B) + check_edits(E)
    try:
        ast.parse(new)
    except SyntaxError as e:
        err.append("dashboard.py Syntax: %s" % e)
    return err, len(B.splitlines())


def _ins(B, add):
    i = B.rindex("# ===== /meshPost =====")
    return B[:i] + add.lstrip("\n") + "\n" + B[i:]


def mutants(B):
    R = lambda a, b: B.replace(a, b, 1)
    M = [
        ("Methodenpruefung entfernt", R("        if rq.method != \"POST\":\n            return _mp_get(key)\n", "")),
        ("Herkunftspruefung entfernt", R("        if not _mp_same_origin(rq):", "        if False:")),
        ("GET ruft vf", R("            return _mp_get(key)\n        if not", "            return vf(*a, **kw)\n        if not")),
        ("Reihenfolge vertauscht", R("        if rq.method != \"POST\":\n            return _mp_get(key)\n", "") .replace("        _MP_STAT[\"post_ok\"] += 1", "        if rq.method != \"POST\":\n            return _mp_get(key)\n        _MP_STAT[\"post_ok\"] += 1", 1)),
        ("Herkunft immer wahr", R("    return rq.headers.get(\"X-Mesh-Post\") == \"1\" and (rq.mimetype or \"\") == \"application/json\"", "    return True")),
        ("Sec-Fetch-Site entfernt", R("sfs != \"same-origin\"", "False")),
        ("Referer-Pruefung entfernt", R("if o is None and not (ref == base or ref.startswith(base + \"/\")):", "if False:")),
        ("zweiter vf-Aufruf", _ins(B, "def _mp_x(vf):\n    return vf()\n").replace("def _mp_x", "def _mp_get2", 1)),
        ("Sendebezeichner", R("    from flask import jsonify\n    text, err = None, None", "    from flask import jsonify\n    send_meshtastic('x')\n    text, err = None, None")),
        ("maybe_mesh", R("    text, err = None, None", "    maybe_mesh_odl(force=True)\n    text, err = None, None")),
        ("requests", R("    text, err = None, None", "    import requests\n    requests.post('http://127.0.0.1:5001/send', json={})\n    text, err = None, None")),
        ("open", R("    text, err = None, None", "    open('/tmp/x', 'w')\n    text, err = None, None")),
        ("subprocess", R("    text, err = None, None", "    import subprocess\n    text, err = None, None")),
        ("Thread", R("    text, err = None, None", "    import threading\n    text, err = None, None")),
        ("sqlite", R("    text, err = None, None", "    import sqlite3\n    text, err = None, None")),
        ("7. Pfad", R("    (\"/api/mesh_test\", \"test\"),\n", "    (\"/api/mesh_test\", \"test\"),\n    (\"/api/mesh_send\", \"send\"),\n")),
        ("Pfad entfernt", R("    (\"/api/mesh_luft\", \"luft\"),\n", "")),
        ("Methoden GET+POST", R("methods=[\"POST\"]", "methods=[\"GET\", \"POST\"]")),
        ("POST-Status", R("methods=[\"GET\"]", "methods=[\"POST\"]")),
        ("Dekorator-Route", _ins(B, "@app.route('/api/x')\ndef _mp_x():\n    return 1\n")),
        ("Ebene-0-Aufruf", _ins(B, "print('x')\n")),
        ("Ebene-0-Import", _ins(B, "import os\n")),
        ("fremde Funktion", _ins(B, "def helper():\n    return 1\n")),
        ("Marker Ende", R("# ===== /meshPost =====", "# ===== /meshPostX =====")),
        ("Marker Anfang", R("# ===== meshPost:", "# ===== meshPostX:")),
        ("_mp_get beruehrt vf", R("def _mp_get(key):", "def _mp_get(key, vf=None):").replace("    _MP_STAT[\"get_preview\"] += 1", "    _MP_STAT[\"get_preview\"] += 1\n    vf and vf()", 1)),
        ("Selbsttest kaputt", R("assert not calls and r.status_code", "assert calls == [] and r.status_code == 999 and r.status_code")),
        ("globals ausserhalb", R("    text, err = None, None", "    globals()\n    text, err = None, None")),
        ("getattr beliebig", R("    text, err = None, None", "    getattr(app, 'secret', None)\n    text, err = None, None")),
        ("Test-Client ausserhalb", R("    text, err = None, None", "    app.test_client().post('/x')\n    text, err = None, None")),
    ]
    return M


def mutate(blk_f, edp_f):
    B = open(blk_f, encoding="utf-8").read().rstrip("\n") + "\n"
    if check_block(B):
        print("Mutationstest: Ausgangsblock schon beanstandet: %s" % check_block(B)[:3]); return 1
    miss = []
    n = 0
    for name, M in mutants(B):
        if M == B:
            print("Mutation %s: Ersetzung hat nichts geaendert" % name); return 1
        try:
            ast.parse(M)
        except SyntaxError as e:
            print("Mutation %s: eigener Syntaxfehler %s" % (name, e)); return 1
        n += 1
        if not check_block(M):
            miss.append(name)
    g = {}
    exec(compile(open(edp_f, encoding="utf-8").read(), edp_f, "exec"), g)
    E = g["DSH_EDITS"]
    if check_edits(E):
        print("Mutationstest: Ausgangs-Aufrufer beanstandet"); return 1
    em = [("Aufrufer entfernt", E[1:]), ("Aufrufer GET", [(o, o) if i == 0 else (o, n_) for i, (o, n_) in enumerate(E)]),
          ("Aufrufer ohne X-Mesh-Post", [(o, n_.replace(",\"X-Mesh-Post\":\"1\"", "").replace(",'X-Mesh-Post':'1'", "")) for o, n_ in E]),
          ("Aufrufer fremder Pfad", [(o, n_.replace("/api/mesh_odl", "/api/mesh_send")) for o, n_ in E]),
          ("Aufrufer doppelt", E + [E[0]])]
    for name, EE in em:
        n += 1
        if not check_edits(EE):
            miss.append(name)
    if miss:
        print("Mutationstest FEHLER: nicht erkannt: %s" % ", ".join(miss)); return 1
    print("OK AST-Guard meshPost: Mutationstest %d/%d Verfehlungen erkannt (Methoden-/Herkunftspruefung, GET->vf, Sendebezeichner, Netz/Datei/DB/Faden, Pfade, Marker, Aufrufer, Selbsttest)" % (n, n))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 5 and a[0] == "check":
        e, nl = check(a[1], a[2], a[3], a[4])
        if e:
            print("AST-Guard meshPost VERSTOSS:\n  " + "\n  ".join(e)); raise SystemExit(1)
        print("OK AST-Guard meshPost: Rueckbau = Basis (Byte fuer Byte), Block %d Zeilen, Block sendet nie, vf nur nach POST+Herkunft, 6 Pfade, 6 Aufrufer auf POST, Selbsttest ok" % nl)
        raise SystemExit(0)
    if len(a) == 3 and a[0] == "mutate":
        raise SystemExit(mutate(a[1], a[2]))
    print("Aufruf: check ALT NEU BLOCK EDITS | mutate BLOCK EDITS"); raise SystemExit(2)
AGD_EOF
EXPECT_AMC="23b322393f507ceebec93687d8add0337d261e2902765e0d7c157a47f2f8e329"
cat > "$W/mpcheck.py" << 'AMC_EOF'
"""Pruefungen meshPost (nur lesen, sendet nie). Aufruf: mpcheck.py MODUS ARGS ...
  blocktest DASHBOARD BLOCK    Block in einer Flask-Sandbox (eigene App, Fake-Sender, Netz/Dateien gesperrt): GET/HEAD senden nie, POST ohne Herkunft 403, POST mit Herkunft ruft genau die Fake-Funktion
  callers DASHBOARD            alle Fundstellen der sechs Pfade im Dashboard: nur @app.route, Block oder fetch mit POST + X-Mesh-Post; kein GET-Aufrufer (fetch/XHR/href/action) mehr
  extscan ORDNER               Hinweis: Dateien im Projektordner (ausser dashboard.py/prepper_docs.py/Sicherungen/docs/venv), die die Pfade nennen (nur Datei:Zeile:Pfad)
  status JSON                  live /api/meshpost/status: alle 6 Pfade geschuetzt, GET und POST
  routes JSON                  live /api/docs/routes: die 5 Knopf-Wege + mesh_test haben POST und GET, plus /api/meshpost/status
  tamper                       Selbsttest der Pruefungen (muss Fehler erkennen)"""
import json
import os
import re
import sys

PATHS = ["/api/mesh_weather", "/api/mesh_odl", "/api/mesh_pegel", "/api/mesh_spaceweather", "/api/mesh_luft", "/api/mesh_test"]
PRE = re.compile(r"/api/mesh_(?:weather|odl|pegel|spaceweather|luft|test|freq)\b")
POSTF = re.compile(r"fetch\((?P<q>[\"'])/api/mesh_[a-z]+(?P=q),\{method:(?P=q)POST(?P=q),credentials:(?P=q)same-origin(?P=q),headers:\{(?P=q)Content-Type(?P=q):(?P=q)application/json(?P=q),(?P=q)X-Mesh-Post(?P=q):(?P=q)1(?P=q)\},body:(?P=q)\{\}(?P=q)\}\)")
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()


def block_of(s):
    a = s.index("# ===== meshPost:")
    e = "# ===== /meshPost ====="
    b = s.index(e, a) + len(e)
    return s[a:b]


def blocktest(dash, blk):
    import builtins
    import socket
    import contextlib
    import io
    s = rd(dash)
    B = block_of(s)
    ref = rd(blk).rstrip("\n")
    assert B == ref, "Block im Dashboard ist nicht der gepruefte Block"
    c0, o0 = socket.socket.connect, builtins.open

    def _no(*a, **k):
        raise OSError("blocktest: Netz gesperrt")
    socket.socket.connect = _no
    try:
        from flask import Flask, jsonify
        app = Flask("mp-blocktest")
        calls = []
        T3 = []

        def mk(n):
            def f():
                calls.append(n)
                return jsonify({"ok": True, "fake": n})
            f.__name__ = "api_" + n
            return f
        for p in PATHS:
            n = p.rsplit("/", 1)[1]
            app.add_url_rule(p, endpoint="api_" + n, view_func=mk(n), methods=["GET"])
        app.add_url_rule("/api/mesh_test", endpoint="api_mesh_test", view_func=app.view_functions["api_mesh_test"], methods=["POST"])   # wie funkHarden2: mesh_test hat schon POST
        ds = {k: {"value": v} for k, v in {"odl": {"avg": 1, "stations": []}, "pegel": [{"id": "1"}], "spaceweather": {"kp": 1}, "luft": {"n_hotspots": 0}}.items()}
        ns = {"app": app, "data_store": ds, "__name__": "mp_blocktest",
              "build_mesh_odl_text": lambda d=None: "ODL TEXT", "build_mesh_pegel_text": lambda i=None: "PEGEL TEXT",
              "build_mesh_spaceweather_text": lambda d=None: "SPACE TEXT", "build_mesh_luft_text": lambda d=None: "LUFT TEXT",
              "build_mesh_weather_text": lambda: "WETTER TEXT"}
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            exec(compile(B, "meshpost_block", "exec"), ns)
        out = buf.getvalue()
        assert "meshPost aktiv: meshPost selftest ok" in out and "geschuetzt=6" in out and "nicht gefunden=keine" in out, out[-300:]
        assert not calls, "Selbsttest/Start hat eine Fake-Funktion gerufen"
        c = app.test_client()
        BH = {"Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Origin": "http://localhost"}
        ok_h = {"X-Mesh-Post": "1", "Origin": "http://localhost"}
        want = {"/api/mesh_odl": "ODL TEXT", "/api/mesh_pegel": "PEGEL TEXT", "/api/mesh_spaceweather": "SPACE TEXT", "/api/mesh_luft": "LUFT TEXT", "/api/mesh_weather": "WETTER TEXT"}
        for p in PATHS:
            for m, kw in (("get", {}), ("get", {"headers": BH}), ("head", {"headers": BH})):
                r = getattr(c, m)(p, **kw)
                assert not calls, "%s %s hat gesendet" % (m, p)
                if p == "/api/mesh_test":
                    assert r.status_code == 405 and "POST" in r.headers.get("Allow", ""), (p, r.status_code)
                else:
                    assert r.status_code == 200, (p, r.status_code)
                    if m == "get":
                        j = r.get_json()
                        assert j["sent"] is False and j["preview"] is True and j["text"] == want[p], (p, j)
            for kw in ({}, {"json": {}}, {"json": {}, "headers": {"X-Mesh-Post": "1"}}, {"json": {}, "headers": {"X-Mesh-Post": "1", "Origin": "http://evil.example"}},
                       {"json": {}, "headers": dict(ok_h, **{"Sec-Fetch-Site": "cross-site"})}, {"data": "{}", "headers": ok_h, "content_type": "text/plain"}):
                assert c.post(p, **kw).status_code == 403 and not calls, (p, kw)
            assert c.put(p, json={}, headers=ok_h).status_code == 405 and c.delete(p, headers=ok_h).status_code == 405 and not calls
        for i, p in enumerate(PATHS, 1):
            r = c.post(p, json={}, headers=ok_h)
            assert r.status_code == 200 and calls == [q.rsplit("/", 1)[1] for q in PATHS[:i]], (p, calls)
        st = c.get("/api/meshpost/status").get_json()
        assert st["meshPost"] == 1 and all(v["guarded"] and v["methods"] == ["GET", "POST"] for v in st["paths"].values()), st
        assert c.post("/api/meshpost/status", json={}, headers=ok_h).status_code == 405
        # sicherer Zustand: schlaegt die Registrierung fehl, sind die Routen gesperrt (503), nie offen
        app2 = Flask("mp-blocktest2")
        calls2 = []
        for p in PATHS:
            app2.add_url_rule(p, endpoint="x" + str(PATHS.index(p)), view_func=(lambda p=p: (calls2.append(p), "gesendet")[1]), methods=["GET"])
        ns2 = dict(ns, app=app2)
        ns2["_mp_selftest"] = None
        B2 = B.replace("def _mp_selftest():", "def _mp_selftest():\n    raise RuntimeError('Test: Selbsttest faellt')", 1)
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(B2, "meshpost_block2", "exec"), ns2)
        c2 = app2.test_client()
        for p in PATHS:
            assert c2.get(p).status_code == 503 and c2.post(p, json={}).status_code in (503, 405) and not calls2, ("fail-closed", p)
    finally:
        socket.socket.connect = c0
    print("meshPost Block-Test ok: 6 Pfade, GET/HEAD senden nie (0 Fake-Aufrufe), 6 Ablehnungen je Pfad -> 403, gueltiger POST ruft je Pfad genau 1x die Fake-Funktion, mesh_test GET 405, Selbsttest-Fehler -> alle 6 gesperrt (503)")


def callers(dash):
    s = rd(dash)
    B = block_of(s)
    rest = s.replace(B, "")
    bad, info, okn = [], 0, 0
    for i, l in enumerate(rest.split("\n"), 1):
        for m in PRE.finditer(l):
            p = m.group(0)
            if p == "/api/mesh_freq":
                continue
            if "@app.route(" in l:
                info += 1
            elif POSTF.search(l):
                okn += 1
            elif re.search(r"fetch\(|XMLHttpRequest|\.open\(|href=|action=|sendBeacon|requests\.(get|post)|urlopen|curl ", l):
                bad.append("Zeile %d: %s" % (i, l.strip()[:110]))
            else:
                info += 1
    assert not bad, "Aufrufer ohne POST/X-Mesh-Post:\n  " + "\n  ".join(bad)
    assert okn == 6, "umgestellte Aufrufer %d statt 6" % okn
    print("Aufrufer: 6 fetch-Stellen auf POST + gleicher Ursprung + X-Mesh-Post, %d weitere Fundstellen sind nur Routen/Text (kein GET-Aufrufer)" % info)


def extscan(d):
    skip = ("dashboard.py", "prepper_docs.py")
    n = 0
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x not in ("venv", "docs", "__pycache__", ".git", "node_modules", "archive", "mesh_inbox", "mesh_inbox_bayern")]
        for f in sorted(files):
            if f in skip or ".bak-" in f or f.endswith((".db", ".db-wal", ".db-shm", ".pyc", ".png", ".jpg", ".gz", ".zip", ".bin", ".img")):
                continue
            p = os.path.join(root, f)
            try:
                if os.path.getsize(p) > 4 * 1024 * 1024:
                    continue
                for i, l in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
                    for m in PRE.finditer(l):
                        print("  %s:%d: %s" % (os.path.relpath(p, d), i, m.group(0)))
                        n += 1
            except Exception:
                pass
    print("extscan: %d Fundstellen ausserhalb dashboard.py" % n)


def status(js):
    j = json.load(open(js, encoding="utf-8"))
    assert j.get("meshPost") == 1 and set(j["paths"]) == set(PATHS), str(j)[:120]
    bad = [p for p, v in j["paths"].items() if not (v["guarded"] and v["methods"] == ["GET", "POST"])]
    assert not bad, "nicht geschuetzt: %s" % bad
    print("/api/meshpost/status: 6 Pfade geschuetzt (GET+POST), Zaehler seit Start: %s" % json.dumps(j["stat"]))


def routes(js):
    j = json.load(open(js, encoding="utf-8"))
    assert j.get("ok") and j.get("n", 0) > 50, str(j)[:100]
    m = {}
    for r in j["routes"]:
        m.setdefault(r["rule"], set()).update(r["methods"])
    bad = [p for p in PATHS if not {"GET", "POST"} <= m.get(p, set())]
    assert not bad and "/api/meshpost/status" in m, "routes: %s" % bad
    print("/api/docs/routes: 6 Sende-Wege GET+POST, /api/meshpost/status da")


def tamper():
    import tempfile
    t = tempfile.mkdtemp()
    f = os.path.join(t, "s.json")
    good = {"meshPost": 1, "paths": {p: {"key": "k", "guarded": True, "methods": ["GET", "POST"]} for p in PATHS}, "stat": {}}
    for name, mut in (("ok", lambda j: j), ("ungeschuetzt", lambda j: j["paths"][PATHS[0]].update(guarded=False)), ("GET fehlt", lambda j: j["paths"][PATHS[1]].update(methods=["POST"])),
                      ("POST fehlt", lambda j: j["paths"][PATHS[2]].update(methods=["GET"])), ("Pfad fehlt", lambda j: j["paths"].pop(PATHS[3]))):
        j = json.loads(json.dumps(good))
        mut(j)
        json.dump(j, open(f, "w"))
        try:
            status(f)
            r = "ok"
        except (AssertionError, KeyError):
            r = "fehler"
        assert (r == "ok") == (name == "ok"), "Selbsttest status: %s -> %s" % (name, r)
    g = 'x = fetch("/api/mesh_odl",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"})\n'
    blk = "# ===== meshPost: x =====\npass\n# ===== /meshPost =====\n"
    for name, txt in (("ok", g * 6), ("GET-fetch", g * 5 + 'x = fetch("/api/mesh_odl")\n'), ("href", g * 6 + '<a href="/api/mesh_luft">\n'), ("zu wenige", g * 5)):
        p = os.path.join(t, "d.py")
        open(p, "w").write(blk + txt)
        try:
            callers(p)
            r = "ok"
        except AssertionError:
            r = "fehler"
        assert (r == "ok") == (name == "ok"), "Selbsttest callers: %s -> %s" % (name, r)
    print("OK mpcheck Selbsttest: ungeschuetzter/fehlender Pfad, fehlende Methode, GET-fetch, href, fehlende Umstellung werden erkannt")


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a and a[0] == "blocktest" and len(a) == 3:
            blocktest(a[1], a[2])
        elif a and a[0] == "callers" and len(a) == 2:
            callers(a[1])
        elif a and a[0] == "extscan" and len(a) == 2:
            extscan(a[1])
        elif a and a[0] == "status" and len(a) == 2:
            status(a[1])
        elif a and a[0] == "routes" and len(a) == 2:
            routes(a[1])
        elif a == ["tamper"]:
            tamper()
        else:
            print(__doc__); raise SystemExit(2)
    except AssertionError as e:
        print("FEHLER: %s" % e); raise SystemExit(1)
AMC_EOF
EXPECT_APC="e263d2221c2c3525dd742176dfd7e65793b78b4685efa5de597858932e4b4777"
cat > "$W/pdcheck.py" << 'APC_EOF'
"""Pruefungen projDoc (nur lesen). Aufruf: pdcheck.py MODUS ARGS ...
  pi HTML DOCSDIR            /pi: Kachel Projektbeschreibung Lage Pi nach der Sicherung, ganz unten, Version = neueste Datei, Sicherung unveraendert (doPrepperRestore-Zaehler gibt der Aufrufer)
  list JSON DOCSDIR          /api/docs/list = Verzeichnis docs/
  dl HDR BODY DOCSDIR VER FMT   Download: Kopfzeilen (Content-Disposition mit filename* + ASCII-Rueckfall), Inhalt = Datei
  routes JSON PFAD...        /api/docs/routes enthaelt alle Pfade
  docs DOCSDIR               Dateien: je Version TXT+MD, Namensmuster, Kopf der TXT mit gleicher Version, Kapitel, keine Schluessel/Passwoerter
  blocktest DASHBOARD BLOCK WORKDIR  Block projDoc in einer Flask-Sandbox (eigene App, Temp-Ordner, nichts gesendet): Selbsttest, Routen, Kachel hinter Sicherung, Download, Pfad-Traversal
  tamper                     Selbsttest der Pruefungen (muss Fehler erkennen)"""
import json
import os
import re
import sys
from urllib.parse import quote

STEM = "Projektbeschreibung Lage Pi v"
FRE = re.compile(r"^Projektbeschreibung Lage Pi v([0-9]{8}-[0-9]{4})\.(txt|md)$")
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()


def versions(d):
    out = {}
    for nm in os.listdir(d):
        m = FRE.match(nm)
        if m and os.path.isfile(os.path.join(d, nm)) and not os.path.islink(os.path.join(d, nm)):
            out.setdefault(m.group(1), {})[m.group(2)] = nm
    return out


def newest(d):
    v = versions(d)
    ok = sorted((k for k in v if "txt" in v[k]), reverse=True)
    assert ok, "keine Version in %s" % d
    return ok[0], v


SECRET = re.compile(r"(?i)(ghp_[A-Za-z0-9]{20,}|github_pat_|-----BEGIN [A-Z ]*PRIVATE|AKIA[0-9A-Z]{12,}|xox[bap]-[0-9A-Za-z-]{10,}|[0-9]{8,10}:[A-Za-z0-9_-]{30,}|(?:api[_-]?key|token|passwort|password|secret)\s*[:=]\s*[\"']?[A-Za-z0-9_\-/+=]{8,})")


def pi(html, d):
    s = rd(html)
    ver, _ = newest(d)
    b, p = s.find('id="backupBox"'), s.find('id="projDocBox"')
    w = s.find('id="wdPiBox"')
    assert w < 0 or w < b, "/pi: Watchdog-Kachel nicht mehr vor der Sicherung"
    assert s.count('id="projDocBox"') == 1, "/pi: Kachel projDocBox %dx statt 1x" % s.count('id="projDocBox"')
    assert s.count('id="backupBox"') == 1 and 0 <= b < p, "/pi: Sicherung fehlt oder Kachel nicht hinter der Sicherung"
    assert 'data-ver="%s"' % ver in s[p:p + 300], "/pi: Kachel zeigt nicht die neueste Version %s" % ver
    assert "Projektbeschreibung Lage Pi" in s[p:p + 400] and ("Version v%s" % ver) in s[p:p + 900], "/pi: Titel oder sichtbare Version fehlen"
    assert ("fmt=txt&amp;v=%s" % ver) in s[p:] and ('download="%s%s.txt"' % (STEM, ver)) in s[p:], "/pi: TXT-Download-Knopf mit Versionsnamen fehlt"
    tail = s[b + 10:]
    cards = [m.start() for m in re.finditer(r'class="(?:card|tile)', tail)]
    assert not cards, "/pi: nach der Sicherung steht noch eine card/tile (%d)" % len(cards)
    last = max((m.start() for m in re.finditer(r'class="(?:card|tile|pd-card)', s)), default=-1)
    assert last >= p and s.find('class="pd-card"', last) == last, "/pi: Kachel ist nicht die letzte Kachel"
    assert "pd-js" in s and s.count("projDocBox") >= 2
    print("/pi: Kachel Projektbeschreibung Lage Pi ganz unten (hinter der Sicherung, Klasse pd-card), Version v%s, TXT-Knopf %s%s.txt" % (ver, STEM, ver))


def lst(js, d):
    j = json.load(open(js, encoding="utf-8"))
    ver, v = newest(d)
    assert j.get("ok") is True and j.get("current") == ver, "/api/docs/list: current %s statt %s" % (j.get("current"), ver)
    vs = [x["ver"] for x in j["versions"]]
    assert vs == sorted(vs, reverse=True) and set(vs) == set(k for k in v if v[k]), "/api/docs/list: Versionen %s != Ordner %s" % (vs, sorted(v))
    for x in j["versions"]:
        for f in ("txt", "md"):
            if x.get(f):
                assert os.path.getsize(os.path.join(d, x[f])) == x["size_" + f], "/api/docs/list: Groesse %s" % x[f]
    print("/api/docs/list: aktuell v%s, %d Versionen (= Ordner docs/)" % (ver, len(vs)))


def dl(hdr, body, d, ver, fmt):
    h = rd(hdr)
    st = re.search(r"HTTP/[0-9.]+ ([0-9]+)", h).group(1)
    assert st == "200", "Download HTTP %s" % st
    if ver in ("", "latest"):
        ver = newest(d)[0]
    nm = "%s%s.%s" % (STEM, ver, fmt)
    cd = re.search(r"(?im)^content-disposition:\s*(.*?)\r?$", h)
    assert cd, "Content-Disposition fehlt"
    cd = cd.group(1)
    assert cd.startswith("attachment;"), cd
    assert 'filename="%s"' % nm in cd, "ASCII-Dateiname fehlt/falsch: %s" % cd
    assert "filename*=UTF-8''%s" % quote(nm, safe="") in cd, "filename* (RFC 5987) fehlt/falsch: %s" % cd
    ct = re.search(r"(?im)^content-type:\s*(.*?)\r?$", h).group(1).lower()
    assert ct.startswith({"txt": "text/plain", "md": "text/markdown"}[fmt]) and "utf-8" in ct, ct
    assert "nosniff" in h.lower() and "no-store" in h.lower()
    a = open(body, "rb").read()
    b = open(os.path.join(d, nm), "rb").read()
    assert a == b and len(a) > 1000, "Download-Inhalt != Datei %s" % nm
    print("Download %s: HTTP 200, %s, Content-Disposition mit filename* + ASCII-Rueckfall, %d Bytes = Datei in docs/" % (fmt.upper(), ct, len(a)))


def routes(js, *paths):
    j = json.load(open(js, encoding="utf-8"))
    assert j.get("ok") and j.get("n", 0) > 50, "routes: %s" % str(j)[:100]
    have = set(r["rule"] for r in j["routes"])
    miss = [p for p in paths if p not in have]
    assert not miss, "/api/docs/routes: fehlen %s" % miss
    print("/api/docs/routes: %d Routen, alle %d geforderten Pfade da" % (j["n"], len(paths)))


def docs(d):
    ver, v = newest(d)
    for k, e in v.items():
        assert "txt" in e and "md" in e, "Version %s: TXT und MD muessen beide da sein (%s)" % (k, sorted(e))
    t = rd(os.path.join(d, v[ver]["txt"]))
    m = rd(os.path.join(d, v[ver]["md"]))
    head = "\n".join(t.splitlines()[:10])
    assert "PROJEKTBESCHREIBUNG LAGE PI" in head and ("Version: v" + ver) in head, "TXT-Kopf ohne Titel/Version %s" % ver
    mh = "\n".join(m.splitlines()[:8])
    assert mh.startswith("# Projektbeschreibung Lage Pi") and ("v" + ver) in mh, "MD-Kopf ohne Titel/Version %s" % ver
    chap = re.findall(r"(?m)^={20,}\n([0-9]{1,2})\. [A-ZÄÖÜ]", t)
    assert "INHALTSVERZEICHNIS" in "\n".join(t.splitlines()[:12]), "TXT ohne Inhaltsverzeichnis im Kopf"
    assert len(chap) >= 18, "Kapitel: %d" % len(chap)
    for nm, tx in (("TXT", t), ("MD", m)):
        mm = SECRET.search(tx)
        assert not mm, "%s: moegliches Geheimnis: %s" % (nm, mm.group(0)[:30])
    print("docs/: neueste v%s, TXT %d Bytes / MD %d Bytes, %d Kapitel, %d Versionen, kein Schluessel-Muster" % (ver, len(t.encode()), len(m.encode()), len(chap), len(v)))


def tamper():
    import tempfile
    t = tempfile.mkdtemp()
    nm = lambda e: os.path.join(t, "%s20261024-1830.%s" % (STEM, e))
    open(nm("txt"), "w").write("PROJEKTBESCHREIBUNG LAGE PI\nVersion: v20261024-1830\nINHALTSVERZEICHNIS\n" + "".join("=" * 30 + "\n%d. KAPITEL\n" % i for i in range(1, 19)) + "x" * 2000)
    open(nm("md"), "w").write("# Projektbeschreibung Lage Pi\n\n- Version: **v20261024-1830**\n")
    docs(t)
    open(nm("txt"), "a").write("\ntoken: ABCDEF1234567890\n")
    try:
        docs(t)
    except AssertionError:
        pass
    else:
        raise SystemExit("Selbsttest: Geheimnis nicht erkannt")
    good = '<div class="card" id="backupBox"><div>doPrepperRestore</div></div><div id="projDocBox" class="pd-card" data-ver="20261024-1830"><div class="title">Projektbeschreibung Lage Pi</div><div>Version v20261024-1830</div><a href="/api/docs/download?fmt=txt&amp;v=20261024-1830" download="Projektbeschreibung Lage Pi v20261024-1830.txt">x</a></div><script id="pd-js">projDocBox</script>'
    open(nm("txt"), "w").write("PROJEKTBESCHREIBUNG LAGE PI\nVersion: v20261024-1830\nINHALTSVERZEICHNIS\n" + "".join("=" * 30 + "\n%d. KAPITEL\n" % i for i in range(1, 19)) + "x" * 2000)
    for name, h in (("ok", good), ("Kachel vor Sicherung", good.replace('id="backupBox"', 'id="xx"')), ("card danach", good.replace("<script id=\"pd-js\">", "<div class=\"card\">y</div><script id=\"pd-js\">")),
                    ("alte Version", good.replace('data-ver="20261024-1830"', 'data-ver="20250101-0000"')), ("kein Download", good.replace("fmt=txt", "fmt=md"))):
        f = os.path.join(t, "pi.html")
        open(f, "w").write(h)
        try:
            pi(f, t)
            r = "ok"
        except AssertionError:
            r = "fehler"
        assert (r == "ok") == (name == "ok"), "Selbsttest pi: %s -> %s" % (name, r)
    print("OK pdcheck Selbsttest: Geheimnis, Kachel vor Sicherung, card danach, falsche Version, fehlender Download werden erkannt")


def blocktest(dash, blk, work):
    """Fuehrt den Block in einer eigenen Flask-App aus (Python mit Flask noetig). Nimmt aus dashboard.py nur _PP2_TOK/_PP2_START/_pp2_block (Quelltext per AST)."""
    import ast
    import tempfile
    from flask import Flask
    src = rd(dash)
    t = ast.parse(src)
    seg = ["import re as _pp2_re"]
    for n in t.body:
        if isinstance(n, ast.Assign) and any(getattr(x, "id", "") in ("_PP2_TOK", "_PP2_START") for x in n.targets):
            seg.append(ast.get_source_segment(src, n))
        if isinstance(n, ast.FunctionDef) and n.name == "_pp2_block":
            seg.append(ast.get_source_segment(src, n))
    assert len(seg) == 4, "piPolish2-Hilfen nicht gefunden (%d)" % len(seg)
    d = tempfile.mkdtemp(prefix="pd-blocktest-", dir=work)
    app = Flask("pdtest")
    page = '<html><body><div class="card" id="wdPiBox">w</div><div class="card" id="backupBox" style="margin-top:16px"><div class="title">Sicherung</div><div><div>doPrepperRestore</div></div></div><script>1</script></body></html>'

    @app.route("/pi")
    def _pi():
        return page
    g = {"app": app, "__file__": os.path.join(d, "dashboard.py"), "__name__": "pdtest"}
    exec(compile("\n".join(seg), "pp2", "exec"), g)
    os.makedirs(os.path.join(d, "docs"))
    mk = lambda n, c: open(os.path.join(d, "docs", n), "wb").write(c)
    mk(STEM + "20261024-1830.txt", b"T" * 3000)
    mk(STEM + "20261024-1830.md", b"M" * 2000)
    mk(STEM + "20261001-0900.txt", b"o" * 500)
    mk("passwoerter.txt", b"x")
    exec(compile(rd(blk), "block", "exec"), g)
    c = app.test_client()
    r = c.get("/api/docs/list")
    j = r.get_json()
    assert r.status_code == 200 and j["current"] == "20261024-1830" and [v["ver"] for v in j["versions"]] == ["20261024-1830", "20261001-0900"], j
    r = c.get("/api/docs/download?fmt=txt")
    assert r.status_code == 200 and r.data == b"T" * 3000, r.status_code
    cd = r.headers["Content-Disposition"]
    assert 'filename="Projektbeschreibung Lage Pi v20261024-1830.txt"' in cd and "filename*=UTF-8''Projektbeschreibung%20Lage%20Pi%20v20261024-1830.txt" in cd, cd
    assert c.get("/api/docs/download?fmt=txt&v=20261001-0900").data == b"o" * 500
    assert c.get("/api/docs/download?fmt=md&v=20261001-0900").status_code == 404
    for q in ("v=../../etc/passwd", "v=20261024-1830/../../x", "v=..%2f..%2fetc%2fpasswd", "fmt=exe", "fmt=txt/../x", "v=" + "9" * 300, "fmt=txt&v=passwoerter"):
        rr = c.get("/api/docs/download?" + q)
        assert rr.status_code in (400, 404) and b"root:" not in rr.data and len(rr.data) < 100, (q, rr.status_code)
    assert c.post("/api/docs/list").status_code == 405 and c.post("/api/docs/download").status_code == 405
    r = c.get("/api/docs/routes")
    rj = r.get_json()
    assert rj["ok"] and {"/pi", "/api/docs/list", "/api/docs/download", "/api/docs/routes"} <= set(x["rule"] for x in rj["routes"])
    r = c.get("/pi")
    h = r.get_data(as_text=True)
    b, p = h.find('id="backupBox"'), h.find('id="projDocBox"')
    assert 0 < b < p and h.count("doPrepperRestore") == 1 and h.count('id="projDocBox"') == 1, (b, p)
    assert 'class="card' not in h[b + 10:] and "Version v20261024-1830" in h and "<script id=\"pd-js\">" in h
    assert c.get("/pi").get_data(as_text=True) == h, "nicht deterministisch"
    open(os.path.join(work, "pi_blocktest.html"), "w", encoding="utf-8").write(h)
    pi(os.path.join(work, "pi_blocktest.html"), os.path.join(d, "docs"))
    import shutil
    shutil.rmtree(d, ignore_errors=True)
    print("OK Block projDoc in Flask-Sandbox: Selbsttest, 3 GET-Routen (POST = 405), Kachel hinter der Sicherung, Download mit Content-Disposition, 7 Pfad-Traversal-Versuche abgewiesen")


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        {"pi": lambda: pi(*a[1:3]), "list": lambda: lst(*a[1:3]), "dl": lambda: dl(*a[1:6]), "routes": lambda: routes(*a[1:]), "docs": lambda: docs(a[1]), "blocktest": lambda: blocktest(*a[1:4]), "tamper": tamper}[a[0]]()
    except AssertionError as e:
        print("pdcheck FEHLER: %s" % e); raise SystemExit(1)
    except KeyError:
        print(__doc__); raise SystemExit(2)
APC_EOF
EXPECT_APD="3584d11bc2c365a3ff9c9244af14e8741bd6a464255b1b2cd2683f76121484b4"
cat > "$W/prepper_docs.py" << 'APD_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""prepper_docs.py - erzeugt die "Projektbeschreibung Lage Pi" (TXT = Hauptformat, Markdown) im Ordner docs/ neben diesem Skript.

Aufruf (auf dem Pi, Ordner /home/fmg/prepper-dashboard):
    python3 prepper_docs.py                 neue Version YYYYMMDD-HHMM (Berlin-Zeit) erzeugen, TXT + MD schreiben, alte Versionen rotieren (keepLast 10)
    python3 prepper_docs.py --check         nur erzeugen und pruefen, nichts schreiben (Trockenlauf, Pruefbericht)
    python3 prepper_docs.py --force         auch dann neue Version, wenn sich gegenueber der neuesten Version nichts geaendert hat
    python3 prepper_docs.py --no-live       keine HTTP-Abfragen an das laufende Dashboard (Routen/Kacheln dann nur statisch aus dashboard.py)
    python3 prepper_docs.py --keep N        N Versionen behalten (Standard 10, Minimum 3)
Die Kachel auf /pi (ganz unten, unter der Sicherung) zeigt immer die neueste Version in docs/ und bietet den Download an.

Aufbau: statischer Textkern (CORE, von Hand geschrieben, Abschnitte mit @@AUTO name@@-Marken) + automatisch ermittelte Abschnitte
(Routen vom laufenden Dashboard bzw. per AST aus dashboard.py, Dateien mit sha16/Zeilen, Patch-Schichten (Marker "# ===== name:"), systemd-Units,
Datenbank-Tabellen, Hilfsprogramme, Patch-Stand). Danach Validierung: alles Gefundene (Routen, Kachel-Ueberschriften, Kachel-IDs, Units, Dateien,
Marker) muss im redaktionellen Text vorkommen, sonst wird es automatisch als Nachtrag angehaengt; Sensibles wird geschwaerzt.
Nur lesend: kein Schreiben ausser docs/, keine Secrets (config.py, secrets/ werden nie gelesen ausser der Zeile PORT = n), nichts wird gesendet.
Nur Standardbibliothek. Python >= 3.9."""
import ast
import datetime
import hashlib
import html as _html
import json
import os
import platform
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import urllib.request

BASE = os.environ.get("PRDOCS_BASE") or os.path.dirname(os.path.abspath(__file__))
DOCS = os.environ.get("PRDOCS_OUT") or os.path.join(BASE, "docs")
STEM = "Projektbeschreibung Lage Pi v"
KEEP_DEFAULT = 10
GEN_VERSION = "1"
SYSTEMCTL = os.environ.get("PRDOCS_SYSTEMCTL") or "systemctl"
SBIN_DIRS = [x for x in (os.environ.get("PRDOCS_SBIN") or "/usr/local/sbin:/usr/local/bin").split(":") if x]
SUDOERS_DIR = os.environ.get("PRDOCS_SUDOERS") or "/etc/sudoers.d"
UNIT_DIR = os.environ.get("PRDOCS_UNITDIR") or "/etc/systemd/system"
WIDTH = 100
NOTES = []            # Hinweise/Fehler der Sammler (landen im Pruefbericht, nie als Abbruch)
SMOKE_PAGES = ["/", "/funk", "/pi", "/umwelt", "/funk433", "/aprs", "/meteor", "/rundfunk", "/energie", "/dabhist", "/mesh", "/karte"]
SMOKE_APIS = ["/api/sdr/ui", "/api/sdr/wd", "/api/br24", "/api/sdr/sticktest", "/api/sdr/live", "/api/sdr/map", "/api/broadcast/events", "/api/t2/status",
              "/api/t3/status", "/api/t4/status", "/api/t4/map", "/api/t4/tii", "/api/meteor", "/api/sdr/status"]
LIVE_PAGES = ["/", "/energie", "/lokale-energie", "/speicher", "/umwelt", "/luft", "/pegel", "/adsb", "/zuhause", "/mesh", "/mesh2", "/news", "/funk", "/karte", "/pi",
              "/medizin", "/funk433", "/aprs", "/meteor", "/rundfunk", "/dabhist", "/umwelt2"]
IP_OK = {"127.0.0.1", "0.0.0.0", "192.168.178.15", "1.1.1.1", "9.9.9.9", "8.8.8.8"}
UNIT_RE = re.compile(r"(prepper|mesh|sdr|gpsd|chrony|kiwix|openwebrx|rtl|welle|tar1090|readsb|dump1090|direwolf|mosquitto|lagezentrum|watchdog|health|backup|clone|dashboard|aprs|meteor|satdump|ntp|timesyncd|ssh)", re.I)

# ----------------------------------------------------------------------------------------------------------------------------------------------
CORE = r'''
# Kurzfassung fuer KIs und neue Entwickler

## Was ist das hier?

Dies ist die Projektbeschreibung "Lage Pi" des Prepper-Dashboards ("Kaeswasser Lage Monitor") von Frank. Das System laeuft auf einem Raspberry Pi 4 mit dem Hostnamen BND-Prepper (Linux-Benutzer fmg, Projektordner /home/fmg/prepper-dashboard). Es ist ein privates Lagebild fuer Haus, Familie und Region (Kalchreuth/Schnaittach bei Nuernberg, Mittelfranken): Warnungen (NINA/MoWaS, DWD, DAB+/UKW-Rundfunk, ASA), Energie- und Versorgungslage, Pegel, Luft, Funkempfang per SDR und Meshtastic-Funknetze. Ein Flask-Webserver liefert die Seiten, mehrere kleine systemd-Dienste und Python-Module liefern die Daten.

Zweck dieser Datei: Eine andere KI oder ein neuer Entwickler soll das Projekt allein aus diesem Text verstehen und weiterentwickeln koennen, ohne Rueckfragen an Frank. Die Datei wird auf dem Pi automatisch erzeugt (python3 prepper_docs.py) und enthaelt neben dem redaktionellen Text automatisch ermittelte Abschnitte (Routen, Dateien mit sha16 und Zeilenzahl, Units, Datenbank, Patch-Schichten), damit sie zum Stand der laufenden Dateien passt.

## In 12 Saetzen

- Das Dashboard ist ein einziges grosses Flask-Programm (dashboard.py, rund 23000 Zeilen), das ueber viele nachtraeglich eingefuegte Patch-Schichten ("# ===== name: ... =====") gewachsen ist. Es gibt keinen Build-Schritt, keine Frontend-Frameworks; HTML/JS steckt in Python-Strings und wird von after_request-Hooks erweitert.
- Daten kommen aus oeffentlichen Quellen (Abrufe in Hintergrundfaeden), aus lokalen Diensten (chrony, gpsd, tar1090, Kiwix, Meshtastic-Bridges) und aus dem SDR-Dienst prepper-sdr.
- prepper-sdr ist der einzige Dienst, der die USB-SDR-Geraete besitzt. Er empfaengt nur (nie Senden ueber Funk) und schreibt Zustand in lagezentrum.db (SQLite) und Notkopie-JSON-Dateien.
- Das Dashboard und alle Hilfsmodule sind "nur lesen/anzeigen", ausser an klar benannten, einzelnen Sendestellen (Mesh-Knoepfe, Mesh-Auto-Meldungen). Alles andere sendet nichts.
- Automatische Mesh-Meldungen echter Alarme gehen nur an Mesh 1, nie bei Probe/Test, je Alarm einmal, gleicher Inhalt nicht innerhalb 6 Stunden, hoechstens 3 pro Stunde; der Schalter mesh_auto.json ist ein Kill-Switch (fehlt/kaputt = aus).
- Aenderungen am Pi werden nur als "apply-Patch" ausgeliefert: ein Shell-Skript mit sha16-Basispruefung, Trockenlauf, Idempotenz, Backups (keepLast 3), AST-Wache, py_compile mit beiden Pythons, Selbsttests, minimalem Neustart (nur das Dashboard), Rauchtest (26 Pruefungen) und automatischem Rollback.
- Frank arbeitet ohne Git-Klon: Patches kommen per curl -o /tmp/... aus dem OEFFENTLICHEN Repo Frankenland90/prepper-patches (festgenagelter Commit) auf den Pi und werden mit sha256 geprueft (Kapitel 12).
- Das Arbeits-Repo Frankenland90/kaeswasser-lage-monitor (Branch kaeswasser-lage-monitor) ist PRIVAT: der Roh-Link liefert ohne Token HTTP 404; der Pi greift nie darauf zu.
- Sicherheit zuerst: keine Secrets in dieser Datei, keine Sendewege ohne Freigabe, kein Pi-Neustart durch Patches, rechtlich nur Empfang erlaubter Dienste (Rundfunk, ISM, Amateurfunk, Wettersatellit).
- Der Stand der Weiterentwicklung steht in Kapitel 16, die Regeln fuer Weiterentwickler in Kapitel 17.
- Unbekanntes ist in dieser Datei ausdruecklich als "nicht dokumentiert/zu pruefen" markiert und nicht geraten.
- Die Version steht im Dateinamen: Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt (Berlin-Zeit), identisch zur Kachel auf /pi.

## Leseanleitung

- Neu im Projekt: Kapitel 1 bis 4, dann 13 bis 15 und 17.
- Eine Seite oder Kachel aendern: Kapitel 5 (Seitenkatalog), 4 (Architektur) und die Tabelle "Patch-Schichten" in Kapitel 11.
- SDR/Funk: Kapitel 6 und 7. Alarmierung/Mesh: Kapitel 7 und 8.
- Ein Patch ausliefern: Kapitel 11 und 12.
- Automatische Abschnitte erkennt man an der Zeile "automatisch erzeugt" bzw. an Tabellen mit Hashes; sie gelten fuer den Zeitpunkt der Erzeugung (Kopf der Datei).

## Kopfdaten dieser Ausgabe

@@AUTO meta@@

## Die zehn goldenen Regeln

- (1) Nie Secrets lesen, ausgeben oder in Dateien/Chat schreiben (config.py-Werte, secrets/, Schluessel, Passwoerter, Tokens, sudo-Passwort).
- (2) Nichts senden, was nicht ausdruecklich freigegeben ist: kein Mesh, keine Alarme in Tests, Simulationen und Rauchtests.
- (3) Bestehende Logik nicht kaputt machen: neue Funktionen als zusaetzliche Patch-Schicht, alles in try/except, Seiten duerfen nie abstuerzen.
- (4) Alte apply-Skripte der Vergangenheit bleiben unveraendert (sie sind historisch und pruefen sha16 des damaligen Stands).
- (5) Jede Auslieferung: sha16-Basispruefung, Trockenlauf, Idempotenz, keepLast 3, atomar schreiben, AST-Wache, py_compile mit /usr/bin/python3 und venv, Selbsttests, Rauchtest, Rollback.
- (6) Nur das Dashboard neu starten (prepper-dashboard). Kein Neustart von prepper-sdr oder des Pi durch Patches; kein USB-Reset aus Patches.
- (7) Keine PIN-Sperre auf den Mesh-Sende-Knoepfen (Entscheidung von Frank); stattdessen Bestaetigungsdialog und Sende-Schutz.
- (8) Sticks/SDR: nur Empfang. Nur Bereiche, die rechtlich zulaessig sind (Rundfunk, Wettersatellit, ISM, Amateurfunk-APRS). Keine Pager-/BOS-Dekodierung.
- (9) Kein Git-Klon beim Betreiber: Patches per curl -o /tmp/... aus prepper-patches (festgenagelter Commit) holen, mit sha256 pruefen (Kapitel 12).
- (10) Nichts erfinden: was nicht belegt ist, als "nicht dokumentiert/zu pruefen" kennzeichnen.

# Zweck, Zielgruppe, Leitprinzipien

## Zweck

- Ein einziges, ruhiges, handytaugliches Lagebild fuer den Haushalt: "Ist etwas los, das mich betrifft?" - Warnlage (Behoerden und Rundfunk), Strom/Netz, Wasser/Pegel, Luft/Brand, Wetter/Strahlung, Funk/Mesh-Zustand.
- Unabhaengigkeit vom Internet soweit moeglich: lokale Quellen (DAB+/UKW-Rundfunk-Warnungen per SDR, Meshtastic-LoRa-Funk, Offline-Wikipedia Kiwix, ADS-B, Zeit per Stratum-1/GPS) ergaenzen die Internetquellen (NINA, DWD, energy-charts, GIE, BfS, ...).
- Eigene, nachvollziehbare Alarmlogik mit Schutz gegen Fehlalarme: Probe/Test-Meldungen werden erkannt und nie als echter Alarm weitergegeben.
- Kein Dienstleistungsprodukt: das System ist ein privates Hobby-/Vorsorgeprojekt, kein amtliches Warnsystem. Die Anzeige ist Orientierung, keine Garantie.

## Zielgruppe

- Betreiber und Nutzer: Frank (Haushalt Kalchreuth, Landkreis Erlangen-Hoechstadt ERH). Bedienung vorwiegend am Handy; die Seiten sind schmal/kompakt gebaut.
- Entwickler/KI-Assistenten, die Patches schreiben: sie arbeiten ohne direkten Zugriff auf den Pi, mit Sandbox-Simulation und Lieferung per GitHub-Patchrepo (Kapitel 11/12).
- Nicht Zielgruppe: oeffentliche Nutzer. Das Dashboard ist nur im Heimnetz (LAN) gedacht und nicht fuer das offene Internet gehaertet.

## Leitprinzipien

- Empfangen statt senden: SDR sendet nie. Mesh-Sendungen nur an eindeutig benannten Stellen (Kapitel 8).
- Anzeige darf nie abstuerzen: jede Funktion faengt Fehler ab und liefert einen sicheren Standardwert; fehlende Quelle = "–" oder "Keine Quelle", nie ein Fehler 500.
- Datenquellen ehrlich kennzeichnen: BER gibt es bei welle-cli nicht (angezeigt wird die FIC-Fehlerrate als Ersatz); Platzhalter und Schaetzungen sind als solche beschriftet.
- Kleine, geschichtete, rueckrollbare Aenderungen statt grosser Umbauten: neue Funktion = neue Patch-Schicht + Selbsttest + Rauchtest.
- Ruhe statt Alarmismus: Entprellung, Dedup, Vorlaufzeiten (zum Beispiel 5 Minuten Mesh-Ruhe nach Dashboard-Start, 6 Stunden Dedup, max. 3 Auto-Meldungen je Stunde).
- Dauerhaft lauffaehig: der Pi startet ohne Warten, Hintergrundfaeden uebernehmen Abrufe; Watchdogs ueberwachen die Daten (nicht nur Prozesse).

# Hardware und Netz

## Rechner

- Raspberry Pi 4 (aarch64) mit Hostname BND-Prepper, Betriebssystem Debian 13 "trixie" (Stand Bestandsaufnahme 12.10.2026: Kernel 6.18.x), Linux-Benutzer fmg. RAM-Ausbau und genaues Gehaeuse/Kuehlung: nicht dokumentiert/zu pruefen (die Kachel "Systemstatus" zeigt CPU, RAM, Temperatur, Uptime live).
- Master-Laufwerk: SSD (Boot-Laufwerk; smartctl wird laut Code auch mit -d sat aufgerufen, also USB-SATA-Adapter moeglich; Kachel "SSD · Master" auf /pi mit SMART, Temperatur, Betriebsstunden, Schreiblast, Fehlerzaehlern und Boot-Reihenfolge). SSD-Hersteller/Groesse werden live aus smartctl gelesen und sind hier nicht festgeschrieben.
- Fallback: SD-Karte (Kachel "SD · Fallback"). Die SD wird nur auf Knopfdruck von der SSD geklont (Programm /usr/local/bin/prepper-clone-ssd-to-sd, Dashboard-Seite zeigt "Jetzt von SSD auf SD klonen" mit Sperre, wenn keine Karte steckt). Es gibt keinen automatischen Klon (Entscheidung Frank).
- Boot-Ampel: SSD gruen / SD gelb. Die Boot-Reihenfolge wird nur angezeigt (read-only). Die Kachel "SD-Gesundheit" liest sd_health.json, das der root-Timer prepper-sd-health schreibt; "Quittieren & neu pruefen" schreibt nur sd_health_ack.json.
- Persistentes Journal (200 MB) ist eingerichtet (Entscheidung 23.10.2026), damit Fehler nach einem Neustart nachvollziehbar bleiben.
- Echtzeituhr (RTC, z. B. DS3231), Anzeigen wie ein TFT-Display ohne WLAN: nicht dokumentiert/zu pruefen.
- Zeit: Der Pi nutzt chrony. Als Stratum-1-Quelle dient der separate Server raspberrypi2 im LAN (192.168.178.15, chrony mit GPS + PPS von gpsd). Die Lage-Seite zeigt "Stratum Offset"; der Health-Check prueft "chrony tracking OK".

## SDR-Empfaenger (nur Empfang)

Die USB-SDR-Geraete gehoeren ausschliesslich dem Dienst prepper-sdr. Rollen sind seit 23.10.2026 fest nach Seriennummer vergeben (Geraete-Register in sdr_config.json, Schluessel devs):

| Anzeigename | Geraet | USB-ID | Seriennummer | Rolle |
|---|---|---|---|---|
| Airspy R2 · 11D | Airspy R2 | 1d50:60a1 | 637862DC2E8092D7 | fest DAB 11D (BR Bayern, 222,064 MHz), BR24-Warnungen; welle-cli mit -F airspy, Port 7979, Gain-Leiter |
| Stick 1 · 5C | Nooelec NESDR SMArt v5 (RTL2832U) | 0bda:2838 | 19348831 | fest DAB 5C (178,352 MHz, 1. Bundesmux, ASA DE = amtliche Warnungen), Rueckfall 10C (Lokal Nuernberg, 213,360 MHz) |
| Stick 2 · Hobby | Nooelec NESDR SMArt v5 | 0bda:2838 | 72055505 | Hobby: UKW-RDS (BR24, Bayern 3, Bayern 1 im Wechsel), 10C-Pruefung alle 6 h, QRM-Messung, Kalibrierung, 433 MHz, APRS; nur Beobachtung, kein Eingriff durch Watchdog/Neustart |
| Stick 3 · Hobby | Realtek RTL2838UHIDIR (Werks-SN 00000001) | 0bda:2838 | 26102403 (geplant/neu per rtl_eeprom) | zweiter Hobby-Stick, nur Register/Anzeige/Journal, kein Planer, wird von prepper-sdr nie geoeffnet (Stand: Patch sdrStick3/sdrStick3c, Umsetzung siehe Kapitel 16) |

- Der Spyverter bleibt vorerst draussen (Entscheidung 23.10.2026). Ein Splitter wird nicht verwendet.
- Die frueher geplante Uebernahme von Stick 2 auf 5C bei Vor-Alarm ist entfallen (Patch sdrAir): Stick 1 hoert 5C fest, der Airspy 11D fest.
- USB-Portzuordnung (welcher Stick an welchem Pi-Port steckt): nicht dokumentiert/zu pruefen; prepper-sdr bindet die Sticks ausschliesslich ueber die Seriennummer, nicht ueber den Port. Nach dem Umstecken wird der Stick-Index beim naechsten regulaeren Start neu aufgeloest.
- Der Pi sendet ueber SDR nichts. Rechtlich erlaubt sind nur Empfang von Rundfunk (UKW, DAB+), Wettersatellit (Meteor-M LRPT), ISM (433/868 MHz) und Amateurfunk-APRS. Keine Pager-/BOS-Dekodierung (multimon-ng/POCSAG bewusst ausgeschlossen).

## Antennen

- Dachantenne: AE-Skyscan Mag 1300 auf dem Dachfirst, gehoert ausschliesslich zum Airspy R2 (ohne Splitter) fuer DAB 11D.
- Antennen der Nooelec-Sticks (Typ, Standort, Kabel) sowie Meteor-/APRS-/433-Antennen: nicht dokumentiert/zu pruefen. Das Antennentest-Programm (Kachel "Antennentest" auf /funk) misst nur und gibt Empfehlungen.
- Dach-GPS-Empfaenger haengt am Stratum-1-Server (nicht am Pi BND-Prepper); der Pi liest ihn nur ueber gpsd (192.168.178.15:2947).

## Meshtastic-Knoten (LoRa-Funknetze)

- Mesh 1 = Knoten "Kalchreuth G2" (Meshtastic TCP-API Port 4403; die Adresse steht in mesh_rules.py bzw. mesh_rules.json und wird hier bewusst nicht genannt). Hauptweg fuer manuelle Knoepfe und automatische Alarmmeldungen. Kanal 0 (LongFast) ist der Standardkanal fuer die Sendungen; in Anweisungen von Frank bedeutet "Mesh-Kanal 1" Mesh 1.
- Mesh 2 = Knoten "Bayern G2" (Firmware 2.7.26, Stand 10.10.2026; Adresse siehe mesh_rules.py, hier nicht genannt). Bekommt automatisch nur NINA (Routing Teil 3; der NINA-Auto-Weg fuer Mesh 2 ist ueber den Schalter nina_bayern_auto.json zusaetzlich freizugeben, Standard AUS). DAB+-Meldungen duerfen diese Adresse nie ansprechen. MQTT ist am Knoten aus (Ursache frueherer 4-Minuten-Abbrueche); ein optionales lokales Mosquitto fuer Mesh 2 ist eingeplant, aber aus.
- Je Knoten haelt genau EINE Bridge die TCP-Session (mesh_bridge.py fuer Mesh 1, Port 127.0.0.1:5001; mesh_bridge_bayern.py fuer Mesh 2, Port 127.0.0.1:5002). Ein zweiter Client wuerde die Bridge aus der Session werfen; deshalb oeffnet das Dashboard nie selbst eine Verbindung (mesh_session.py prueft nur per ss -tnp).
- Auto-Antworten auf "ping"/"test": mesh_ping_reply.py (Mesh 1), mesh_ping_reply2.py und mesh_ping_reply_bayern.py (Mesh 2); Station-Label in den Antworten ist "Station Kalchreuth".
- Ob der Knoten WLAN-/LAN-Verbindung oder andere Anbindung hat und die genauen Standorte: nicht dokumentiert/zu pruefen.

## Netz und Hilfsserver

- Heimnetz mit Fritz-Box (privater Adressraum). Als feste Adresse wird hier nur 192.168.178.15 genannt (Stratum-1/GPS/ADS-B-Server raspberrypi2); die Adressen der Mesh-Knoten und der Kiwix-Seite stehen im Code (mesh_rules.py, Kachel-Links) und werden in dieser Datei bewusst nicht genannt. Alle anderen Adressen werden in dieser Datei geschwaerzt.
- Internetpfade: Telekom (Festnetz) und Starlink als Ausfallschutz; die Erkennung (uplink_detect.py) wertet Hop 2, Rueckwaerts-DNS, Starlink-Schuessel (Standardadresse der Starlink-Schnittstelle) und ASN aus; mindestens 2 uebereinstimmende Merkmale, sonst "Pfad unklar".
- Weitere lokale Dienste: Kiwix (Offline-Wikipedia, Port 8080, Seite /medizin), ADS-B-Feeder mit tar1090/readsb auf dem Stratum-1-Server 192.168.178.15 (Quelle der Seite /adsb: /tar1090/data/aircraft.json und stats.json), gpsd (Stratum-1-Server), optional OpenWebRX (nicht festgeschrieben).

# Software-Architektur

## Ueberblick

```
Internet-Quellen --(requests, Hintergrundfaeden)--> dashboard.py (Flask, data_store im Speicher + JSON-Dateien)
                                                          |  ^                      |
 lokale Dienste (chrony, gpsd, tar1090, kiwix) -----------+  |                      +--> Browser (Handy/PC im LAN)
 Meshtastic-Bridges (127.0.0.1:5001/5002)  <--- Sendestellen -+                      |
 SDR-Geraete --> prepper_sdr.py (Dienst prepper-sdr) --> lagezentrum.db (SQLite, Tabelle state u. a.) + JSON-Notkopie
                                                          |
                         sdr_manager.py / database.py / mesh_router.py / lagegeo.py (Module im Dashboard-Prozess)
```

- Ein Rechner, ein Projektordner: /home/fmg/prepper-dashboard. Alles Wesentliche liegt dort flach (Python-Module, JSON-Zustandsdateien, lagezentrum.db, static/, archive/, docs/, backups/).
- Python 3.13.x. Zwei Interpreter muessen den Code uebersetzen koennen: /usr/bin/python3 und das venv (Ordner venv im Projektordner, venv/bin/python). Jeder Patch prueft py_compile mit beiden.
- Flask (Web), requests (Abrufe), ntplib (Stratum-Abfrage), sqlite3 (Standardbibliothek); SDR-Werkzeuge ausserhalb von Python: rtl_433, rtl_fm, redsea, direwolf, welle-cli, rtl_tcp, rtl_power, satdump, soapy/airspy-Pakete.
- Konfiguration steht in config.py (Rechte 600; enthaelt API-Schluessel, Koordinaten, Intervalle, Mesh-Hosts, Pegelstationen). Inhalte werden nie ausgegeben oder kopiert; der Generator liest daraus ausschliesslich die Zeile PORT.
- Das Dashboard lauscht auf dem Port aus config.py (PORT; Standard 5000). Neustart: sudo systemctl restart prepper-dashboard (nur diesen Dienst, nie den ganzen Pi).

## Das Dashboard-Monolith-Muster

- dashboard.py ist ueber viele Monate in Schichten gewachsen. Jede Schicht beginnt mit einem Marker-Kommentar der Form "# ===== name: Beschreibung =====" und steht vor dem Block if __name__ == "__main__": am Dateiende. Neue Funktionen werden nie in alten Code hineineditiert, sondern als neue Schicht angehaengt; kleine Ersetzungen alter Textstellen sind die Ausnahme und werden mit eindeutigen Ankern und AST-Wache abgesichert.
- Seiten sind Python-Strings (PAGE1 ... PAGE4, PAGE_ENERGIE, PAGE_LUFT, PAGE_ADSB, ...) und werden per render_template_string mit data_store gerendert. Viele Kacheln werden nachtraeglich per after_request-Hooks in das ausgelieferte HTML eingefuegt. Wichtig: Flask fuehrt after_request-Funktionen in UMGEKEHRTER Listenreihenfolge aus (die zuletzt registrierte zuerst); eine neue Schicht, die nach einer anderen laufen soll, muss deshalb an der passenden Listenposition eingefuegt werden.
- Routen: normale @app.route-Dekoratoren, dazu add_url_rule in Schleifen (zum Beispiel die SDR-APIs). Deshalb kann man die Routenliste nicht nur per Textsuche finden; der Generator nimmt die laufende Routenliste (/api/docs/routes) und gleicht per AST ab.
- Kachel = HTML-Block mit class="card" (oder Seiten-eigene Klassen) und meist einer id wie fooCard/fooBox/fooTile; JavaScript aktualisiert Kacheln per fetch auf die /api/...-Endpunkte.
- Jede Schicht hat Kennzeichnungs-Kommentare der Form /* name */ im HTML/JS, damit Patches ihren eigenen Code wiederfinden (Idempotenz).
- Hintergrundfaeden: Voll-Update alle UPDATE_INTERVAL (15 Minuten, Anzeige "Update in n min"), schnelle Frequenzabfrage alle FREQ_INTERVAL, Mesh-Wetter-/Frequenz-Faeden, Uplink-Erkennung alle 60 s, Retention-Faden der Datenbank alle 10 min. Seit sysBoot lauscht der Server sofort; das erste Voll-Update laeuft danach im Hintergrund ("laed"-Hinweis auf der Startseite).
- Fehlerphilosophie: jede Abfrage mit Timeout, jede Funktion mit try/except und sicherem Standardwert; fehlende Quelle = "–"/"Keine Quelle"; Ruecksprung auf zuletzt guten Wert wird gekennzeichnet.

## Module (Python-Dateien im Projektordner)

Die vollstaendige, automatisch ermittelte Dateiliste mit sha16 und Zeilenzahl steht im Abschnitt 4.5 (Dateien im Projektordner); hier die Rollen:

| Datei | Rolle |
|---|---|
| dashboard.py | Flask-Monolith: alle Seiten, APIs, Abrufe, Patch-Schichten (Marker) |
| config.py | Konfiguration/Schluessel (Rechte 600, nie lesen/ausgeben) |
| prepper_sdr.py | SDR-Dienst: besitzt alle Sticks/den Airspy, Planer je Geraet, Decoder, Watchdog, schreibt Zustand |
| sdr_manager.py | Lagezentrum-Logik im Dashboard: sdr_status/broadcast_state in die DB, Status SDR_OFFLINE/OK/PROBEALARM/ECHTALARM, Lebenszeichen 'hb' |
| database.py | SQLite-Zugriff lagezentrum.db: Schema, Migration, Retention; jede Funktion faengt Fehler ab |
| mesh_router.py | Dublettenpruefung der Mesh-Texte (md5, 24 h) und automatischer Versand echter Alarme an Mesh 1 (Kill-Switch mesh_auto.json) |
| lagegeo.py | Warngebiete (GeoJSON-Polygone) der NINA-Warnungen vereinfachen und cachen (Tabelle geo_cache) |
| prepper_sdr_net.py | einzige Netzzugriffe des SDR-Planers: Bahndaten (celestrak.org) und lokales welle-cli-JSON |
| prepper_evlog.py | Ereignis-Log fuer Stoersender/QRM, Gewitter, Dach-GPS, Trend und KFZ-Sensoren (nur Auswerten) |
| prepper_gps.py | Dach-GPS aus gpsd des Stratum-1-Servers lesen (nur lesen), GPS/GLONASS getrennt bewerten |
| mesh_bridge.py, mesh_bridge_bayern.py | je eine TCP-Session zum Mesh-Knoten, Queue, Pong, Inbox (Dienste mesh-bridge, mesh-bridge-bayern) |
| mesh_ping_reply.py, mesh_ping_reply2.py, mesh_ping_reply_bayern.py | Auto-Antwort auf ping/test (Dienste mesh-ping-reply, mesh-ping-reply-2) |
| mesh_rules.py | Regeln (mesh_rules.json): Hosts, Cooldown (20 s), welche Meldungsart auf welchen Knoten darf |
| mesh_chutil.py | Kanalauslastung (DeviceMetrics) je Knoten sammeln/lesen, Schwellen 25 % gelb / 40 % rot, Verlauf (mesh1_chutil.json, mesh2_chutil.json) |
| mesh_hang_watchdog.py (+ Units mesh-hang-watchdog.service/.timer) | Hang-Erkennung der Mesh-Verbindungen, Status mesh_hang_status.json, optionaler Neustart per Freigabe-Datei |
| mesh_reply_watch.py | letzte Ping/Test-Antwort (last_rx/last_tx) je Mesh in mesh1_reply.json/mesh2_reply.json |
| mesh_node_label.py | Knoten-Namen/Labels fuer Mesh-Meldungen (nicht naeher dokumentiert) |
| mesh_session.py, mesh_inbox_util.py | TCP-Sessions pruefen (ss -tnp) bzw. Inbox-Hilfen; oeffnen keine eigene Verbindung |
| funk_health.py, funk_page.py | Funk-Seite: Mesh-Status, Kanalauslastung Mesh 1/2, Seitenaufbau |
| nina_calm.py | NINA-Kachel/Mesh ruhig halten: Ablauf, Entwarnung 2 h, jede Meldungs-ID hoechstens einmal an Mesh |
| luft.py | Luftlage: FIRMS (Braende), Sensor.community (Feinstaub), Wind (Open-Meteo) |
| zuhause.py | Seite Zuhause: Abfall ERH, Apotheken-Notdienst, Tierkliniken, Notrufe |
| tiles_sources.py | Datenquellen-Liste der Kachel "Datenquellen" auf /pi |
| archive_store.py | Langzeitarchiv unter archive/ (nur lesen aus data_store, schreibt nur archive/) |
| speedtest_run.py | Ookla-Speedtest (alle 3 h zu :41 plus manuell), Ergebnis je Uplink |
| uplink_detect.py | Telekom/Starlink erkennen (alle 60 s) |
| watchdog.py | schlanker Dashboard-Watchdog: Dienst + GET / -> optional Neustart (Cooldown 30 min) |
| health_check.py | 12-h-Health-Report -> health_status.json (nie systemctl restart) |
| prepper_docs.py | Dieser Generator: erzeugt die Projektbeschreibung (TXT+MD) in docs/ |
| patch-mesh-hang-bridges.py, patch-mesh-traceroute-bridge.py, patch-mesh-traceroute-remove.py, patch-mesh-traceroute-remove-guard.py | aeltere Patcher-Skripte der Mesh-Familie (Hang-Erkennung in den Bridges; Traceroute-Funktion eingebaut und wieder entfernt); historisch, nicht erneut ausfuehren |
| tools/backup.sh | Backup-Skript fuer die Sicherung (Kachel "Sicherung") |

## Dienste (systemd) und Zeitsteuerung

- prepper-dashboard (Flask-Dashboard; einziger Dienst, den Patches neu starten), prepper-sdr (SDR-Dienst; nie durch Patches neu gestartet), mesh-bridge und mesh-bridge-bayern (Mesh-Sessions), mesh-ping-reply und mesh-ping-reply-2, kiwix (Offline-Wikipedia), chrony (Zeit), prepper-sd-health (.timer/.path, root, schreibt sd_health.json), mesh-hang-watchdog (.service/.timer), Watchdog- und Health-Timer des Dashboards, optional Speedtest-/Backup-Timer. Welche Units auf dem Pi wirklich existieren und laufen, ermittelt der Generator selbst (systemctl list-units/list-unit-files, nur lesend) und listet sie im Abschnitt 4.6.
- Systemeigene Units, die auf dem Pi ebenfalls auftauchen koennen (nicht Teil des Projekts): ssh.service, chrony.service (Zeit), systemd-timesyncd.service (nur Debian-Standard, nicht die Zeitquelle des Projekts), dpkg-db-backup.service/.timer (Debian-Paketdatenbank-Sicherung).
- Zeitplan der Hintergrundlogik (Auszug): Voll-Update alle 15 min; Speedtest alle 3 h (01:41, 04:41, ...); Rundfunk-Block von prepper-sdr alle 30 min (UKW-RDS und DAB+, Messzeiten fm_s/dab_s in sdr_config.json); Health-Check automatisch 09:00 und 21:00 (zusaetzlich Watchdog alle 5 min); Mesh-Wetter 0/3/6/9/12/15/18/21 Uhr; Datenbank-Aufraeumen alle 10 min; JSON-Notkopie von sdr_status/broadcast_state alle 10 min.

## Dateien im Projektordner (automatisch)

@@AUTO files@@

## Units und Hilfsprogramme (automatisch)

@@AUTO units@@

@@AUTO unitstate@@

@@AUTO external@@

## Verzeichnisse (automatisch)

@@AUTO dirs@@

# Seiten und Kacheln (seitenweise)

Das Hauptmenue hat 16 Eintraege (Reihenfolge): Lage (/), Energie, Lokale Energie, Speicher, Umwelt, Luft, Pegel, ADSB, Zuhause, Mesh 1, Mesh 2, News, Funk, Karte, System (= /pi), Medizin. Alle Seiten sind GET-Seiten ohne Anmeldung (nur Heimnetz). Zusaetzlich gibt es Seiten ausserhalb des Menues: /funk433, /aprs, /meteor, /rundfunk, /dabhist (Unterseiten der Funk-SDR-Kachel), /umwelt2 (aeltere Luft/Pegel-Seite) sowie die Weiterleitungen /scanner und /decoder (auf /), den Alias /lokal (= Lokale Energie) und /system (= /umwelt). Die Rauchtest-Liste jedes apply-Skripts prueft 12 Seiten und 14 APIs (26 Pruefungen, alle muessen HTTP 200 liefern; Liste im API-Katalog unten).

Die automatische Tabelle der Seiten mit Vorlage und Kachel-Ueberschriften folgt am Ende dieses Kapitels. Ein Kachel-Eintrag bedeutet: Titel, Zweck, Quelle, Besonderheit.

## / Lage (Startseite, "Seite 1 von 4")

- Kopf "KAESWASSER LAGE MONITOR" mit "Seite 1 von 4 · Update in n min" (Voll-Update alle 15 min) und die Menueleiste.
- Lage-Ampel (Patch teil4): gruen = OK, gelb = Probealarm, rot blinkend = Echtalarm, orange blinkend = SDR_OFFLINE (und Vor-Alarm), darunter eine Grund-Zeile ("Warnungen vorhanden", naechste Voll-Bewertung) und der SDR-Status (zum Beispiel "Status: SDR_OFFLINE - keine frische Telemetrie von prepper-sdr (Watchdog 15 s)"). Quelle: sdr_manager.py (Status aus lagezentrum.db).
- Uhrzeit, "Stratum Offset" (Zeitabweichung zum Stratum-1-Server, ntplib, STRATUM_IP aus config.py).
- Kachel "INTERNET": Haus/Welt/DE-Punkte, ONLINE/Stabil, Pfad Telekom/Starlink/unklar (uplink_detect.py), Latenz.
- Kachel "NETZFREQUENZ": Netzfrequenz in Hz (Quelle Netzfrequenzmessung; Nominal 50,000 Hz), "Keine Quelle" bei Ausfall; Mesh-Sendung bei Stufen siehe Kapitel 8.
- Kachel "NINA WARNUNGEN": aktive Warnungen fuer die Region (NINA/MoWaS; ninaCalm: abgelaufene weg, Entwarnung grau 2 h), je Meldung Status "Empfangen · Zeit", "Rücknahme Mesh", "Mesh gesendet"; Knopf "An Mesh 1 senden" (nur bei Klick, mit Bestaetigung; Patch lageMesh1). NINA-Warngebiete als Polygone aus lagegeo.py (fuer /karte).
- Kachel "BR24 WARNUNGEN" (#br24Tile; direkt unter NINA, Patch lageMesh1/br24Warn2): Zeilen "BR24 empfangen · DAB 11D + UKW 102,0" und "ASA DE · DAB 5C · keine Warnung" mit Zeitangaben, Hinweis zu den Sticks, Knopf "An Mesh 1 senden"; Warn-Score (stark/mittel/Anweisung, Entwarnung, Test); nur Empfang.

## /energie Energie

- "STROMPREIS AKTUELL": Day-Ahead-Strompreis (energy-charts, Fraunhofer ISE) mit Verlauf (strom_history.json).
- "ROHOEL": Brent in Euro (Quelle EuroOilWatch), 14-Tage-Verlauf (oil_history.json), Hoch/Tief seit Aufzeichnung (priceAllTime, price_alltime.json).
- "DIESEL REGIONAL": Dieselpreis regional (Tankerkoenig-API, Station aus config.py ELO_STATION_ID), Verlauf fuel_history.json.
- "NETZLAST DEUTSCHLAND": Last in GW und Differenz (energy-charts).
- "ERZEUGUNGSMISCHUNG (DE)": Anteile Wind/Solar/Gas/Kohle usw. (energy-charts).
- "EDELMETALLE & KRYPTO": Gold/Silber, Bitcoin, Ethereum (Metall-/Krypto-Quelle), Verlauf price_history.json.

## /lokale-energie Lokale Energie (Alias /lokal)

- "Lokale Energie · N-ERGIE" / "Strom N-ERGIE · Mittelfranken": Kachel "Status" mit offenen Ausfaellen in Mittelfranken (Kalchreuth/Schnaittach hervorgehoben), 14-Tage-Verlauf (outage_history.json), Quelle Stoerungsauskunft/N-ERGIE. Bei neuem Ausfall in der Naehe: Mesh-Meldung (Auto, mit Cooldown).

## /speicher Speicher

- Kopf "Gas- & LNG-Speicher"; Kacheln "Gasspeicher Deutschland" (GIE AGSI, Fuellstand, Trend), "LNG-Speicher Deutschland" und "LNG Ausspeise-Auslastung (Terminals)" (GIE ALSI). API-Schluessel API_KEY_GIE in config.py.

## /umwelt Umwelt ("Seite 3 von 4", Alias /system)

- "WETTER KALCHREUTH (90562)": aktuelle Temperatur, Sonnenstunden, 5-Tage-Vorhersage (Open-Meteo).
- "DWD WARNUNGEN": Warnungen fuer Kalchreuth, Forst, Erlangen, Kreis ERH, Schnaittach nach Stufe; Mesh-Status (analog NINA, bei Aenderung/Entwarnung).
- "DWD WBI · Waldbrand": Waldbrandgefahrenindex Station Nuernberg (3668), Stufe 1-5, kurzer Verlauf (dwd_wbi_status.json).
- "Wetter an Mesh": manueller Knopf und Auto-Sendung 0/3/6/9/12/15/18/21 Uhr an Mesh 1 (Status "A ·" = Auto, "M ·" = manuell).
- "SONNENAKTIVITAET": Kp-Index, 24-h-Maximum, G/R/S-Skalen (NOAA SWPC); Knopf "Sonnenaktivitaet an Mesh senden".
- "STRAHLUNG (ODL) · UMGEBUNG": BfS-Ortsdosisleistung Nuernberg, Lauf a.d. Pegnitz, Graefenberg, Mittelwert; Ampel gruen <= 0,25 µSv/h, gelb <= 0,60, darueber rot (Orientierung); Auto-Mesh bei Ampelwechsel, Knopf "ODL an Mesh senden".
- "STOERSENDER / QRM" (SDR, prepper-sdr): Rauschboden je Band (GPS/GLONASS ueber Dach-GPS, 2 m, UKW, DAB, PMR, 433, 868, MW, KW) gegen 7-Tage-Grundlinie (Median + MAD; gelb ab max(5 dB, 4xMAD), rot ab max(10 dB, 6xMAD)), Trend, neue Dauertraeger, 24 h/14 Tage-Kurve; nur Leistungsmessung, kein Inhalt. Zeilen "GPS"/"GLO" lernen zunaechst die Grundlinie ("lernt", grau).
- "EREIGNISSE (letzte 10)": Ereignis-Log der QRM-/GPS-Zustaende (prepper_evlog.py, Ring sdr_events.json + archive/evlog).
- "GEWITTER-HINWEIS": grober Hinweis aus breitbandigem Rauschen (nur Orientierung, kein Blitzortungsdienst).
- "Waldbrand"-Kacheln und weitere Kacheln sind auf voller Breite (Patch umweltWide, nur CSS/Klasse).

## /luft Luft

- "LAGE LUFT": Zusammenfassung; "FEINSTAUB": Sensor.community-Feinstaubsensoren der Umgebung mit Wind (Open-Meteo, Forecast); "BRAENDE FIRMS": NASA-FIRMS-Hotspots in der Naehe (firms_history.json, laedt beim Start); "MESH 1": Sendestatus Luft (Mesh 1; Feinstaub gelb/rot bzw. Entwarnung, Brand neu/weg; Knopf manuell, Auto bei Aenderung). Module: luft.py.

## /pegel Pegel

- "Schnaittach · 24228009" und "Lauf / Pegnitz · 24224008": Wasserstand (cm), 3-h-Trend (Patch pegelTrend, aus GKD-Rohwerten), Hochwasser-Meldestufen als Linien (config.py PEGEL_STATIONS), Quelle Gewaesserkundlicher Dienst Bayern (GKD).
- "Pegel an Mesh senden": manuell (M) und automatisch (A, Mesh-Wetter + 60 s) an Mesh 1.

## /adsb ADSB

- "Lokaler ADS-B Feeder" (tar1090/readsb auf 192.168.178.15: aktuelle Flugzeuge und Statistik), "Verlauf 14 Tage · Erkennung" (adsb_history.json), "Militaer (tar1090 dbFlags)", "Squawk / Notlage" (7500/7600/7700), "Sonder-Squawks (DE)", "Karten & Verlauf" (Links zu tar1090-Karte und Graphen). Nur Anzeige, nichts wird gesendet.

## /zuhause Zuhause

- "Muellabfuhr" (Abfallkalender Landkreis ERH, Kaeswasser), "Apotheken-Notdienst" (BLAK, naechste Notdienstapotheken), "Tierkliniken", "Notrufe & Wichtige Nummern" (Notrufnummern und wichtige Kontakte). Modul zuhause.py; Daten werden gecacht.

## /mesh Mesh 1 und /mesh2 Mesh 2

- "Verlauf · Kalchreuth G2" (Mesh 1) bzw. "Verlauf · Bayern G2" (Mesh 2): empfangene und gesendete Mesh-Texte (Inbox je Knoten, mesh_inbox*.json), Zaehler, Status.
- "Senden": Textfeld und Knopf (An Mesh 1/2 senden) fuer manuelle Nachrichten; Bestaetigung, Sende-Schutz funkHarden2, Cooldown 20 s (mesh_rules.json). Keine PIN-Sperre (Entscheidung Frank).
- Hold/Resume-APIs (/api/mesh_hold, /api/mesh_resume, /api/mesh2_hold, /api/mesh2_resume) pausieren bzw. setzen die Bridge-Verbindung fort (Wartung).

## /news News

- "Polizei Mittelfranken" (Pressemeldungen), "Deutschlandfunk", "Tagesschau", "NZZ · Blick von aussen" (RSS-Feeds; Knopf aktualisieren: /api/news_refresh). Nur Anzeige.

## /funk Funk (Funk-Lage und SDR-Steuerung)

Die groesste Seite (Patches funkUI, sdrUi, sdrAir/sdrAir2, sdrWd/sdrWd2, airTest, stickTest u. v. m.). Kacheln und Bereiche von oben nach unten:

- Banner "Mesh-Verbindungen OK · je eine TCP-Session" (funkHarden, mesh_session.py).
- "MESH-STATUS" je Knoten (Mesh 1, Mesh 2): LAN/Funk/TCP/Dienst, CLOSE-WAIT, Node-DB, lastHeard, Ping RX/Antwort, TX gesamt.
- "KANALAUSLASTUNG · MESH 1" und "Kanalauslastung · Mesh 2" (Air-TX, Mittel/Spitze 24 h/7 d, Telemetrie).
- "FUNK-LAGE": Gesamtstatus (OK/OFFLINE/Warnung), je Geraet eine Zeile mit Anzeigename "Name · Rolle" (zum Beispiel "Airspy R2 · 11D", "Stick 1 · 5C", "Stick 2 · Hobby", Stick 3), Ebene (REGIONAL-EBENE 11D, BUNDES-EBENE 5C), RSSI, BER (FIC) als Ersatzwert, SNR, Ensemble, ECC, LTO, TII/Mast, Alter der Daten; "ASA-Dienst" (ASA_INTERRUPTED: Dienst seit n s nicht empfangen, Soll 37 s, Grenze 55 s), "Vor-Alarm" (DSL/Netzfrequenz), "Auto-Versand Mesh 1 AN/AUS, letzte Stunde n/3", "Alarm", "Datenquelle" (DB primaer, JSON Notkopie).
- "Daten-Watchdog": Ampel und je Geraet eine ruhige Zeile; Stufen und Aktionen siehe Kapitel 6; "Pi-Neustarts heute".
- Links "Karte: Masten, Funkhorizont, Gefahrenzonen" (-> /karte) und "DAB-Meldungen und Technik-Verlauf" (-> /dabhist).
- Kachel "EMPFAENGER" (Funk-SDR-Kachel #sdrCard bzw. #sdrUiCard): Zeilen 433,92 MHz, APRS, UKW/DAB, ASA 5C, Meteor, Aktivitaet, QRM-Messung, Dach-GPS, Kalibrierung mit je AN/AUTO/AUS-Schalter (Quellen-Schalter, sdrLage), Status "läuft/nächst/vor n min", Lage-Profil, Zeitanteile je Geraet, Krisenzeile, Zeile "Geräte" (Register inkl. "erkannt, ohne Rolle"), Einzelempfang-Presets (sdrPreset, 30/60/120 min, Whitelist aus prepper_sdr.PRESETS), "Rundfunk", "BR24 (DAB 11D)", "ASA DE (DAB 5C)", "Stoerer/QRM", "Gewitter", "Dach-GPS".
- "STEUERUNG": Lage-Profil (zum Beispiel "Warnlage (angepasst)"), Modus Automatik; Knopf Gain-Test (Kachel "Gain-Test", airTest: Stufen 12/19/21 je 5 Runden, nur Anzeige/Empfehlung, aendert keinen Gain), Kachel "Antennentest - im Geraete-Register-Betrieb" (#stickTestCard; stickTest: Stick-Zuordnungstest, Grundlinien neu lernen, Rollen-Tausch nur auf Befehl) ganz unten im Raster.
- "EREIGNIS-HISTORIE (LETZTE 10)": Ereignisse aus NINA, BR24, DAB, SDR (Watchdog, Vorfaelle, Uebernahmen).
- Meteor-Kachel und die Unterseiten-Links (433 MHz, APRS, Rundfunk, Meteor).

## /funk433 Funk 433 MHz

- "SDR-Empfaenger (Nooelec NESDR SMArt v5)" (Kopf der SDR-Seiten, #sdrHead), "433-MHz-Sensoren" (rtl_433-Telegramme, ISM, Zaehler, letztes Telegramm), "KFZ-Sensoren (TPMS)" (letzte 10, Sichtungen/Sensoren heute; IDs in voller Laenge, fremde nach 30 Tagen entfernt; nur Beobachtung). Daten: rtl433.jsonl, funk433_state.json, sdr_kfz.json.

## /aprs APRS

- "APRS-Stationen", "APRS-Wetterstationen", "APRS-Nachrichten & Bulletins": APRS auf 144,800 MHz (rtl_fm | direwolf), nur Empfang, Daten aprs.jsonl/aprs_state.json.

## /meteor Meteor-M

- "Meteor-M Wettersatellit" (Meteor-M LRPT 137,9 MHz, satdump; Empfang bei Ueberfluegen >= 20 Grad hat Vorrang), "Naechste Ueberfluege" (TLE von celestrak.org, im Cache auch offline), "Bilder" (Galerie mit Vorschaubildern /meteor/thumb/<name>, Original /meteor/img/<name>).

## /rundfunk Rundfunk

- Hinweis "TA ist nur ein Kennzeichen 'Verkehrsdurchsage laeuft' im Audio" (kein Text), "Ereignisse letzte 48 h" (TA, Ansagen, DLS-Texte, Warn-Score; /api/broadcast/events), "UKW-Sender (RDS)" (PS, Radiotext, PI, TA, PTY), "DAB+-Dienste" (welle-cli: Ensembles, Dienste, DLS). Nur BR24-Texte (+ ASA DE) werden als Warntexte bewertet (Patch br24Warn2).

## /dabhist DAB-Meldungen

- "DAB-Empfang · Masten (Datenbank)" (dqCard, dabSql: Kanaele aktiv/offline/nicht geprueft, bekannte/unbekannte Masten, Herkunft der Koordinaten), "DAB-Meldungen und Technik" (Verlauf aller DAB-Textmeldungen und Ansagen von 11D und 5C, gleiche Folgemeldung nur zuletzt/Anzahl; Technik-Verlauf: Sync verloren/wieder da, Ensemble-ID-Wechsel, Mast gesehen/weg, FIG 0/9), Tageskarten.

## /karte Karte

- Eigene Seite (kartevec, nach Funk im Menue, Raster 4x4): Leaflet-Karte (lokal unter static/leaflet, Kartenkacheln werden nicht aus dem Internet gebraucht, soweit konfiguriert; sonst: nicht dokumentiert/zu pruefen) mit DAB-Masten, Funkhorizont, Gefahrenzonen (NINA-Polygone aus lagegeo.py) und TII-Vektorlinien je Mast (alle 5 s: /api/t4/tii, tii_seen). Die Kacheln sind rein JavaScript; serverseitig gibt es nur das Geruest (/karte/res/<path> liefert Dateien).

## /medizin Medizin ("Seite 4 von 4")

- "WikiMed offline · Vollbild oeffnen": Kiwix (Offline-Wikipedia/Medizin) eingebettet per iframe (Port 8080; Link "Vollbild oeffnen"). Ist der Dienst kiwix aus, bleibt die Seite leer.

## /pi System (Pi und Internet, Menue "System")

Von oben nach unten (die Reihenfolge ist durch Patch piPolish/piPolish2 und projDoc festgelegt; "Sicherung" ist bis zum Patch projDoc die letzte Kachel, danach kommt als allerletzte Kachel die Projektbeschreibung):

- "HEALTH CHECK": Gesamtampel (zum Beispiel OK 19/19), Pruefungen compile, svc_*, page_*, kiwix, mesh, disk, ram, temp, throttle, chrony, apt; Auto 09:00/21:00, Watchdog 5 min. Quelle health_status.json (health_check.py).
- "DATENQUELLEN": je Quelle Name, Herkunft und Zeit des letzten Abrufs (gruen ok, gelb 1-4 Fehler, rot 5+); Knopf "Update manuell" (/api/sources/update). Liste aus tiles_sources.py.
- "INTERNET": Verbindung (Telekom/Starlink/unklar), Ping 8.8.8.8, oeffentliche IP (nur Anzeige), Latenz.
- "SPEEDTEST (OOKLA)" (Box #stBox im Internet-Kachel): Ergebnisse je Uplink, Diagramm 14 Tage (Telekom/Starlink, gestrichelt = Upload), Starlink-Wechsel gesamt, Knopf "Speedtest jetzt" (/api/speedtest). Fester Server Nuernberg, alle 3 h.
- "SYSTEMSTATUS (PREPPER-PI)": CPU, RAM, Temperatur, Uptime, Festplatte, Boot-Laufwerk.
- "DIENSTE": Mesh (G2) und Kiwix mit Erreichbarkeit.
- "SDR-DATEN-WATCHDOG" (#wdPiBox): Ampel je Geraet (Airspy R2 · 11D, Stick 1 · 5C, Stick 2 · Hobby nur Beobachtung), Stufen: gelb ab 10 min, Neustart von welle-cli/rtl_tcp des Sticks ab 30 min, USB-Neuverbindung ab 45 min (max 2), Pi-Neustart ab 60 min (max 1 je 60 min, Stopp nach 3 ohne Erfolg). Patches duerfen diese Aktionen nie ausloesen.
- "SSD · MASTER" (#ssdCard; Titel zeigt zusaetzlich den Zustand, zum Beispiel "Fehler - Backup pruefen!"): Boot-Ampel, Boot-Reihenfolge, Laufwerk, SMART, Belegung, Schreiblast, Fehler (Kernel/ext4), letzter Klon, Knopf "Quittieren & neu pruefen".
- "SD · FALLBACK": Karte vorhanden, Klon bereit, letztes Ergebnis, Knopf "Jetzt von SSD auf SD klonen" (gesperrt ohne Karte; Hintergrundjob /api/clone/start, /api/clone/status), Liste der letzten Klone (nur auf Knopfdruck).
- "ARCHIV" (#archCard): Zustand des Langzeitarchivs (Reihen, Punkte, Ereignisse, Groesse, frei, Reichweite; Rohdaten 90 Tage, danach Tageswerte) aus archive_store.py.
- "SICHERUNG" (#backupBox): Sicherung der Projektdateien/DB (tools/backup.sh), Liste der 5 neuesten, Knopf "Sicherung jetzt" und Wiederherstellung (doPrepperRestore). Muss unveraendert bleiben; die Kachel steht vor der Projektbeschreibung.
- "PROJEKTBESCHREIBUNG LAGE PI" (#projDocBox, Patch projDoc; allerletzte Kachel): Version "vJJJJMMTT-HHMM", Erzeugungszeit (Berlin), Groesse, Knopf "TXT herunterladen" (Dateiname "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt"), Markdown-Download, Liste aelterer Versionen, Hinweis "Neue Version: auf dem Pi python3 prepper_docs.py".

## /umwelt2 (aelter, nicht im Menue)

- "Luftqualitaet · Erlangen" und "Pegel · Pegnitz und Umgebung": aeltere kombinierte Seite; wird weiter ausgeliefert, damit alte Links gehen.

## API-Katalog (alle Endpunkte, redaktionell)

Wichtig vorab (Stand nach Patch meshPost): Diese Endpunkte SENDEN an das Mesh, und zwar ausschliesslich per POST von der eigenen Seite: /api/mesh_send, /api/mesh2_send, /api/mesh_test, /api/lage_mesh1/send sowie die fuenf Knopf-Wege /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather (vor meshPost waren diese fuenf GET und sendeten beim blossen Aufruf, mit force=True). Seit meshPost sendet ein GET auf diese Wege nie: er liefert eine Vorschau (HTTP 200, JSON mit ok=false, sent=false, preview=true und dem Text, den der Knopf senden wuerde; nur aus dem Zwischenspeicher, beim Wetter mit gepufferter Open-Meteo-Abfrage) bzw. bei /api/mesh_test HTTP 405 mit Allow: POST. Ein POST wird nur angenommen, wenn er von der eigenen Seite kommt (Origin/Referer = eigene Adresse, Sec-Fetch-Site nicht fremd, Kopf X-Mesh-Post: 1, Inhaltstyp JSON), sonst HTTP 403 ohne Senden; kein PIN. /api/mesh_freq ist seit lageMesh1 abgeschaltet (HTTP 410). Auch mit diesem Schutz gilt: Tests, Rauchtests, Simulationen, Monitoring, Crawler und Link-Pruefer duerfen diese Wege nie per POST aufrufen. Weitere Schalter: /api/nina_bayern_auto (POST schaltet den NINA-Auto-Weg fuer Mesh 2) und /api/t2/autosend (POST schaltet den Auto-Versand echter Alarme). Der Rauchtest ruft nur die 14 lesenden APIs unten auf; die Vorschau-Wege ruft er nicht auf (/api/meshpost/status zeigt stattdessen nur lesend, ob alle sechs Wege geschuetzt sind).

Die 26 Rauchtest-Pruefungen: 12 Seiten (/, /funk, /pi, /umwelt, /funk433, /aprs, /meteor, /rundfunk, /energie, /dabhist, /mesh, /karte) und 14 APIs (/api/sdr/ui, /api/sdr/wd, /api/br24, /api/sdr/sticktest, /api/sdr/live, /api/sdr/map, /api/broadcast/events, /api/t2/status, /api/t3/status, /api/t4/status, /api/t4/map, /api/t4/tii, /api/meteor, /api/sdr/status). Alle muessen HTTP 200 liefern; jeder Patch fuegt eigene Pruefungen hinzu (zum Beispiel die Reihenfolge der Kacheln auf /pi).

| Pfad | Methode | Zweck |
|---|---|---|
| /api/sdr/ui | GET | Daten der SDR-Kachel /funk (Chips, Modus, Schalter, Presets, Zeitanteile) |
| /api/sdr/wd | GET | Daten-Watchdog je Geraet (Stufe, ohne Empfang seit, USB-Resets, Pi-Neustarts) |
| /api/sdr/live | GET | Lagezentrum-Status (SDR_OFFLINE/OK/PROBEALARM/ECHTALARM) und Telemetrie je Geraet |
| /api/sdr/lage | POST | Lage-Profil und Quellen-Schalter AN/AUTO/AUS setzen (schreibt nur Konfigurationsdatei); Lesen ueber /api/sdr/ui |
| /api/sdr/status | GET | rohes sdr_status (aus der DB, JSON als Ersatz) |
| /api/sdr/map | GET | Masten, Funkhorizont, Gefahrenzonen fuer /karte |
| /api/sdr/mode, /api/sdr/preset, /api/sdr/presets, /api/sdr/release | POST/GET | Betriebsart setzen (schreibt sdr_mode.json), Preset waehlen (nur Whitelist), Presets lesen, Stick freigeben (Datei sdr_release_req); schreiben nur Anforderungsdateien, senden nichts |
| /api/sdr/activity, /api/sdr/noise, /api/sdr/evlog | GET | Aktivitaet, Stoer-/Rauschwerte (QRM, Gewitter, GPS), Ereignis-Log |
| /api/sdr/airtest | GET/POST | Gain-Test Airspy 11D (Status lesen bzw. Start/Abbruch anfordern, nur Empfang) |
| /api/sdr/sticktest | GET/POST | Antennentest/Stick-Zuordnungstest (Status; Start, Neu lernen, Rollen-Tausch nur auf Befehl) |
| /api/br24 | GET | BR24-/ASA-Warnstand (Warn-Score, Text, Zeit) fuer Lage-Seite und Funk |
| /api/broadcast, /api/broadcast/events | GET | Rundfunkzustand (UKW/DAB) und Ereignisse der letzten 48 h |
| /api/aprs, /api/funk433, /api/meteor | GET | APRS-Stationen, 433-MHz-Sensoren, Meteor-Zustand/Ueberfluege/Bilder |
| /api/kfz/own | POST | eigenen KFZ-Sensor markieren (nur von der eigenen Seite: Origin/Referer + Header X-Evl, maximal 512 Byte) |
| /api/dabsql/status | GET | DAB-Datenbankzusammenfassung (Kanaele, Masten, Herkunft der Koordinaten) |
| /api/t2/status, /api/t3/status, /api/t4/status | GET | Teil-2/3/4-Status (Alarmuebernahme historisch, Routing, Lage-Ampel/SDR-Kacheln) |
| /api/t4/map, /api/t4/tii | GET | Kartendaten bzw. TII-Vektorlinien je Mast (alle 5 s) |
| /api/t2/stick2, /api/t4/sdr2 | POST | historische Stick-2-Uebernahme-Schalter; seit sdrAir ohne Wirkung auf Sticks (Register entscheidet) |
| /api/t2/autosend | POST | Schalter "Auto-Versand echter Alarme an Mesh 1" AN/AUS (mit Rueckfrage; Kill-Switch mesh_auto.json) |
| /api/lage_mesh1, /api/lage_mesh1/send | GET/POST | Lage-Seite: Knopf "An Mesh 1 senden" (GET Status; POST sendet NINA/BR24 nur bei Klick mit Bestaetigung) |
| /api/mesh_send, /api/mesh2_send | POST | manuelle Textnachricht an Mesh 1 bzw. 2 (Seiten /mesh, /mesh2) |
| /api/mesh_hold, /api/mesh_resume, /api/mesh2_hold, /api/mesh2_resume | POST | Bridge-Verbindung pausieren/fortsetzen (Wartung) |
| /api/mesh_inbox | GET | letzte Mesh-Nachrichten (src=local oder bayern) |
| /api/mesh_watch | GET | Bridge-Zustand, Alter der Inbox, letzter Versand je Knoten |
| /api/mesh_test | POST (GET = 405) | manueller NINA-Test an beide G2 (sendet "NINA Test" auf Kanal 0); nur POST von der eigenen Seite (meshPost), hoechstens 1x pro Minute (funkHarden2) |
| /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather | POST (GET = Vorschau) | Knoepfe "Wetter/ODL/Pegel/Luft/Sonnenaktivitaet an Mesh senden": POST von der eigenen Seite sendet (bestehende Logik, force=True); GET zeigt nur den Text und sendet nichts (Patch meshPost) |
| /api/mesh_freq | GET (HTTP 410) | Knopf Netzfrequenz an Mesh: seit lageMesh1 abgeschaltet, sendet nie |
| /api/meshpost/status | GET | nur lesen: Pfad, Methoden und Schutz-Zustand der sechs Sende-Wege, Zaehler (GET-Vorschauen, abgelehnte/angenommene POST) seit Start (Patch meshPost) |
| /api/nina_bayern_auto | GET/POST | Zustand/Schalter (nina_bayern_auto.json, Standard AUS) des automatischen NINA-Wegs fuer Mesh 2 |
| /api/funk/atomic, /api/funk/harden, /api/funk/chutil, /api/funk/mesh_session | GET | Funk-Seite: atomare Dateien, Sende-Schutz-Status, Kanalauslastung, Mesh-Sessions |
| /api/frequenz, /api/ping, /api/time, /api/uplink | GET | Netzfrequenz live, letzter Ping, Serverzeit, Uplink-Erkennung |
| /api/speedtest, /api/speedtest/history, /api/download_test | GET/POST | Ookla-Speedtest starten/lesen, Verlauf; aelterer Download-Test |
| /api/news_refresh (GET), /api/sources/update (POST) | GET/POST | News bzw. alle Quellen manuell neu abrufen (nur Abrufe, keine Sendung) |
| /api/archive/status, /api/archive/<series> | GET | Langzeitarchiv: Status und Reihen |
| /api/sd_health, /api/sd_health/ack | GET/POST | SD-/Laufwerk-Ampel lesen bzw. quittieren (schreibt sd_health_ack.json) |
| /api/sysboot/status, /api/sysboot/disk | GET | Boot-/Laufwerk-Zustand (SSD/SD, SMART) |
| /api/clone/start, /api/clone/status | POST/GET | SD-Klon auf Knopfdruck starten bzw. Stand lesen |
| /api/backup, /api/backup/restore | POST | Sicherung jetzt bzw. Wiederherstellung (Kachel Sicherung) |
| /api/scanner_mode | GET/POST | veralteter Scanner-Modus (Weiterleitung /scanner, /decoder auf /) |
| /api/docs/list, /api/docs/download, /api/docs/routes | GET | Projektbeschreibung (Patch projDoc): Versionsliste, Download (fmt=txt|md, v=JJJJMMTT-HHMM), Routenliste fuer den Generator; nur Lesen aus docs/ |

## Automatische Seitenkarte

@@AUTO pagemap@@

## Kachel-IDs im HTML/JS (automatisch)

@@AUTO ids@@

# SDR-Subsystem (prepper-sdr)

## Grundprinzip

- prepper_sdr.py ist ein eigener Dienst (prepper-sdr; Aufruf run | selftest | status). Er besitzt alle SDR-Geraete, teilt die Zeit auf und ist der einzige Prozess, der Sticks oeffnet. Das Dashboard liest nur: Zustand kommt ueber lagezentrum.db (Tabelle state, Schluessel zum Beispiel sdr_status, broadcast_state) und JSON-Notkopien (sdr_status.json, broadcast_state.json, sdr_dabhist.json, sdr_events.json, sdr_kfz.json, sdr_techlog.json, sdr_wd.json u. a.).
- Betriebsart und Schalter: sdr_mode.json (schreibt das Dashboard), sdr_config.json (Geraete-Register devs, Rollen, Messzeiten, Schalter wie dabsql, devs_on, air_fe), Anforderungsdateien fuer Antennentest/Gain-Test (sdr_req_*, sdr_airtest_req.json). Das Dashboard schreibt nur diese kleinen Anforderungen, nie Steuerbefehle direkt an die Geraete.
- Nur Empfang: Rundfunk (UKW-RDS, DAB+), Wettersatellit (Meteor-M LRPT 137,9 MHz), ISM (433,92 und 868,3 MHz) und Amateurfunk-APRS (144,800 MHz). Fehlt ein Stick, wartet der Planer ruhig (kein Neustart-Karussell).
- Ein Planer je Geraet in einem Prozess (Patch sdrDual): Airspy fest 11D, Stick 1 fest 5C, Stick 2 Hobby. Die Zuordnung steht im Geraete-Register (sdrAir) und wird ueber die Seriennummer aufgeloest, nicht ueber Port oder Index.

## Planer und Betriebsarten

- Bloecke: 433 (rtl_433 -> rtl433.jsonl + funk433_state.json), aprs (rtl_fm | direwolf -> aprs.jsonl + aprs_state.json), tcp (rtl_tcp Port 1234 fuer SDR-Apps im LAN, Decoder pausiert, endet automatisch), bc (Rundfunk-Block alle 30 min: UKW-RDS ueber rtl_fm | redsea mit PS/Radiotext/TA/PTY und DAB+ ueber welle-cli mit DLS/Ansagen), meteor (satdump bei Ueberfluegen >= 20 Grad, hat dann Vorrang).
- Presets (Einzelempfang, Whitelist PRESETS in prepper_sdr.py, nie freie Eingabe): 433, 868, APRS, UKW-Sender (BR24 102,0; Bayern 3 97,9; Bayern 1 88,9; Bayern 2 92,3; BR-Klassik 87,6; Gong 97,1; Charivari 98,6; Hit Radio N1 92,9; UKW 98,0), DAB-Kanaele (zum Beispiel 10D BDR-Testkanal fuer ASA-Tests). Dauer 30/60/120 min, danach zurueck zur Automatik.
- Quellen-Schalter AN (laeuft fest) / AUTO (nach Plan) / AUS (pausiert) je Quelle; Lage-Profile ("Warnlage (angepasst)" u. a.) verschieben die Zeitanteile (Patch sdrLage).
- Rundfunk-Rotation des Hobby-Sticks: UKW-RDS BR24 / Bayern 3 / Bayern 1 im Wechsel; alle 6 Stunden zusaetzlich eine 10C-Pruefung (Lokal Nuernberg, 213,360 MHz); dazu QRM-Messung (rtl_power, alle 15 min, Fenster mit Zuschlag, SIGINT statt Abschuss), Kalibrierung (ppm je Stick), 433 und APRS.

## DAB+ Empfang

- 11D (222,064 MHz, Ensemble BR Bayern, ECC 0xe0, LTO +2 h): Airspy R2 mit welle-cli -F airspy, Port 7979. Der Gain wird ueber eine Gain-Leiter (feste Stufen) gefuehrt; Standard-Gain wird nie von Tests veraendert (airTest: Stufen 12/19/21 je 5 Runden, nur auf Anforderung, endet immer mit dem Standard-Gain).
- 5C (178,352 MHz, 1. Bundesmux, DR Deutschland): Stick 1 fest. Dient der ASA-DE-Warnung (Automatic Safety Alert). Rueckfall 10C (Lokal Nuernberg), solange 5C nach 2 Pruefungen keinen Sync hat; 5C wird alle 10 min erneut versucht und bei Sync wieder gewaehlt (sdrTeil4, jetzt vom Geraete-Register gefuehrt; Rueckfall-Meldung nur vom 5C-Planer, Entprellung 60 s, je Richtung hoechstens 1 Ereignis je Stunde: sdrFall).
- DAB ueber rtl_tcp mit fester Verstaerkung statt der Software-AGC von welle-cli (dabGain), Sync zaehlt nur bei echtem Ensemble (dabFix), bekannte Rundfunktraeger werden nicht als Stoerer gewertet.
- Empfangsguete: welle-cli liefert keine Bitfehlerrate. Angezeigt wird deshalb die FIC-Fehlerrate (FIC-CRC-Fehler / (Messdauer x 125 FIB/s, DAB Mode I)) als "BER (FIC)"-Ersatz, dazu SNR, Sync, Ensemble, TII. Das steht auch an den Kacheln, damit niemand eine echte BER annimmt.
- Masten/TII: dabSql schreibt jede Pruefung in reception_log, masts und channel_status (lagezentrum.db; Mastenliste aus T4_MASTS importiert, unbekannte TII werden automatisch angelegt, Koordinatenherkunft pos_src als Label: Wikipedia/OSM/Frank/Kopie); Uhr-Schutz: Aufraeumen und Offline-Rechnung nur bei plausibler synchroner Uhr (sdrRest/sdrRest2). Kanal 10C zeigt "nicht geprueft" statt "offline", solange der Hobby-Stick belegt ist.
- Verlauf aller DAB-Textmeldungen und Ansagen (dabHist): gleiche Folgemeldung nur zuletzt/Anzahl; Ring sdr_dabhist.json und Archiv archive/dabhist/JJJJ-MM/*.jsonl. Technik-Verlauf (sdrLog): sdr_techlog.json + archive/techlog.
- UKW-RDS: Notfall ("RDS Notfall") nur bei echten Kennzeichen (rdsNotfall): PTY 31 (Alarm), Gruppe 9A (EWS, mindestens 3 mal in 60 s, nicht als ODA belegt) oder Warnwoerter im RadioText; PTY 30 (Alarmtest) gilt nur als Test; TA, PTY Finance und 1A-EWS-Kennungen allein sind kein Notfall.

## Daten-Watchdog (je Geraet)

- Misst die Zeit seit dem letzten ECHTEN Empfang (DAB-Sync mit Ensemble, RDS-Gruppen). Stufe 1 ab 10 min gelb (Gain-Leiter laeuft weiter), Stufe 2 ab 30 min Neustart von welle-cli und rtl_tcp dieses Sticks, Stufe 3 ab 45 min USB-Neuverbindung nur dieses Sticks (per Seriennummer, USB-ID 0bda:2838, root-Hilfsprogramm, maximal 2 je Vorfall), Stufe 4 ab 60 min Pi-Neustart (maximal 1 je Stunde; nach 3 erfolglosen keine weiteren: Stick/Antenne pruefen).
- Stufen 2-4 laufen nie bei Alarm, ASA-Warnung, PTY 31, Antennentest, Meteor und analogen Sperren. Das Hobby-Geraet wird nur beobachtet (kein Neustart/USB/Pi-Neustart) und zaehlt nicht in die Gesamtstufe (sdrAir2). Zustand: lagezentrum.db (state sdr_wd) + sdr_wd.json (ueberlebt Neustart); Schwellen und Schalter in sdr_config.json.
- Planer-Waechter sdrHalt: haengt ein Planer-Faden (kein Planer-Schritt seit 10 min) und ist keine Sperre aktiv, laesst der Dienst sich per sd_notify (WATCHDOG=trigger) kontrolliert neu starten; hoechstens 3 je Stunde, nie in Sperren, mit Protokollzeile; ohne systemd-Watchdog keine Aktion. Dazu stuendliche Pruefung des root-Hilfsprogramms (nur check). Das ist der EINZIGE Selbstneustart von prepper-sdr.
- Stick-Index und Seriennummern werden im Lauf nur lesend geprueft (sysfs, kein Stick geoeffnet, Stick 3 nie); bei Abweichung Journalzeile und frische Aufloesung beim naechsten regulaeren Start (sdrRest2).

## Stoerer, Gewitter, GPS, Ereignisse

- QRM/Stoersender (sdrNoise/sdrNoise2): Rauschboden je Band gegen 7-Tage-Grundlinie (Median + MAD, MW/KW je Tagesstunde); gelb ab max(5 dB, 4xMAD), rot ab max(10 dB, 6xMAD); langsamer Anstieg als Trend; neue Dauertraeger; Gewitter-Hinweis aus breitbandigem Rauschen. Nur Leistungsmessung, kein Inhalt, keine Peilung; eigene Geraete (Netzteile, Pi, LED) stoeren oft selbst.
- Dach-GPS (prepper_gps.py, gpsLearn): TCP-Client zu 192.168.178.15:2947, sendet nur das feste ?WATCH, liest einige Sekunden TPV/SKY; GPS (gnssid 0) und GLONASS (gnssid 6) getrennt, Signalstaerke je Hoehenband gegen die 7-Tage-Grundlinie; gelb/rot wie QRM oder bei Fix-Verlust; Anlernphase "lernt (noch ~n h)".
- Ereignis-Log (prepper_evlog.py, evLog): Ereignis oeffnet, wenn ein Band/System nicht mehr gruen ist, schliesst bei gruen; Luecken < 5 min werden zusammengefasst. KFZ-Sensoren (TPMS aus dem rtl_433-Strom): Ring sdr_kfz.json, Archiv archive/evlog/*/kfz.jsonl.
- welle-cli-Faehigkeiten: prepper-sdr durchsucht das Programm nur lesend nach Alarmflag (FIG 0/0), Ansagen (FIG 0/18-19) und ASA/EWS; Ergebnis: welle-cli liefert weder Alarmflag noch Ansagen noch ASA als Datenfeld, nur den DLS-Text ist auswertbar. Deshalb basiert die ASA-Erkennung auf dem Dienst-Label "ASA" im Ensemble 5C (ASA_RE) und dem Text.

# Alarmlogik und Lage-Ampel

## Warnquellen

- NINA/MoWaS (warnung.bund.de, Region Nuernberg/ERH; Anzeige per ninaCalm): aktive Warnungen mit Schweregrad (Minor bis Extreme), Entwarnungen (msgType Cancel oder Titel "Entwarnung") nur 2 h grau; abgelaufene Meldungen verschwinden.
- DWD-Warnungen (Kalchreuth, Forst, Erlangen, Kreis ERH, Schnaittach) und DWD-Waldbrandindex (Station Nuernberg).
- BR24 ueber DAB 11D und UKW 102,0 (Rundfunktexte, Warn-Score stark/mittel/Anweisung, Entwarnung, Test, Ausschluesse; Patch br24Warn2) sowie ASA DE ueber DAB 5C (Dienst-Label ASA; der Dienst allein ist kein Alarm).
- RDS-Notfall (PTY 31, Gruppe 9A EWS, Warnwoerter): nur bei echten Kennzeichen, PTY 30 nur Test.
- Weitere Lagequellen (ohne Bezug zu mesh_router.py; eigene Mesh-Meldungen siehe Kapitel 8): Netzfrequenz, Stromausfall, Pegel, Luft/Brand (FIRMS), ODL-Strahlung, Weltraumwetter, ADS-B-Notlagen (nur Anzeige).

## Status des Lagezentrums (sdr_manager.py, /api/sdr/live, /api/sdr/lage)

- SDR_OFFLINE: neueste Telemetrie aelter als WATCHDOG_S (15 s). Da prepper-sdr DAB nur im Wechsel misst und sdr_status.json nur bei Aenderung oder alle 60 s schreibt, gibt es keinen echten 15-s-Takt: jede Synchronisierung (hoechstens alle 10 s) schreibt eine Lebenszeichen-Zeile (kind 'hb'), aber NUR wenn sdr_status.json hoechstens 90 s alt ist und der prepper-sdr-Prozess lebt (Patch funkUI: Lebenszeichen auch im Speicher, damit eine DB-Sperre kein falsches SDR_OFFLINE erzeugt).
- ECHTALARM: aktive ASA-DE-Warnung (DAB 5C), deren Text nicht ausdruecklich Probe/Test sagt. PROBEALARM: nur wenn ASA- oder MoWaS/NINA-Text ausdruecklich Probe/Test/Warntag sagt. OK: sonst. Eigene TEST-Knopf-Meldungen ("TEST ... keine echte Warnung") zaehlen nie.
- Lage-Ampel (teil4) auf der Lage-Seite und /funk: gruen OK, gelb Probealarm, rot blinkend Echtalarm, orange blinkend SDR_OFFLINE; Vor-Alarm (DSL/Netzfrequenz) wird als Hinweis gezeigt. "LAGE: AUFFAELLIG" erscheint bei vorhandenen Warnungen.
- Vor-Alarm: Ausloesung ueber Netzfrequenz/DSL-Auffaelligkeit; seit sdrAir schaltet der Vor-Alarm nichts mehr um (keine Stick-Uebernahme mehr), er wird nur angezeigt.

## Regeln fuer Alarme (verbindlich, von Frank freigegeben)

- Probe-/Test-Alarme gehen NIE ans Mesh (Probealarm, Test/Uebung/Warntag im Text, eigene TEST-Meldungen, RDS PTY 30).
- Echte Alarme (ASA-Echtalarm, NINA, echter BR24-Notfall) werden automatisch an Mesh 1 gesendet, wenn der Schalter mesh_auto.json AN ist (Kill-Switch; fehlt oder kaputt = AUS). Der aktuelle Schaltzustand steht im Funk-Bereich "Auto-Versand Mesh 1 AN/AUS" und ist nicht in dieser Datei festgeschrieben.
- Eine Meldung je Alarm (Tabelle mesh_auto), gleicher Inhalt nicht innerhalb von 6 Stunden (Dedup), hoechstens 3 Auto-Meldungen je Stunde; jeder Versuch wird in mesh_log protokolliert (Hash, Kanal auto0, Quelle, Text, Ergebnis).
- Die einzige Sendestelle im Modul mesh_router.py ist _tx(); gesendet wird nur ueber die uebergebene Funktion send_fn (im Dashboard dieselbe send_meshtastic wie der Knopf "An Mesh 1 senden", Bridge 127.0.0.1:5001). Das Modul oeffnet keine eigene Verbindung.
- Nach dem Start des Dashboards gelten 5 Minuten Ruhe (Patch meshBootQuiet): in dieser Zeit keine Auto-Mesh-Sendungen.
- Tests, Simulationen, Patches und Rauchtests senden und loesen NICHTS aus (kein Mesh, kein Telegram, keine Alarme).
- Es gibt keine PIN-Sperre auf den Sende-Knoepfen (Entscheidung Frank); Schutz durch Bestaetigungsdialog, Sende-Schutz (funkHarden2), Cooldown 20 s und Dedup.
- Alarmweg Hobby/Stick 2: keiner mehr; die fruehere Stick-2-Uebernahme (Patch teil2) ist durch sdrAir entfallen.

# Mesh (Meshtastic) und Sendewege

## Sendestellen im Dashboard (einzige Orte, an denen etwas gesendet wird)

| Funktion | Ziel | Ausloeser |
|---|---|---|
| send_meshtastic(text, channel=0) | Mesh 1 (Bridge 127.0.0.1:5001, Knoten .141) | Knopf, Auto-Meldungen (Wetter, Luft, ODL, Pegel, Frequenz, Sonne, DWD, NINA), mesh_router._tx (Echtalarme) |
| send_meshtastic_to(text, host), send_chunks_bayern(chunks) | Mesh 2 (Bridge 127.0.0.1:5002, Knoten .140) | NINA automatisch, sonst nur manuelle Knoepfe |
| send_dab_to_private_mesh(text, channel=0) | nur Mesh 1 (.141) | DAB+/BR24/ASA-Meldungen; darf Mesh 2 (.140) nie ansprechen |
| mesh_ping_reply*.py | gleicher Knoten | Auto-Antwort auf "ping"/"test" |

- Knoepfe und Aufrufwege (Patch meshPost): Die Knoepfe Wetter, ODL, Pegel, Luft, Sonnenaktivitaet und NINA-Test senden per POST (fetch mit Herkunftspruefung: Header X-Mesh-Post: 1, Inhaltstyp JSON, gleiche Herkunft); ein GET auf dieselben Adressen liefert nur die Vorschau (NINA-Test: 405) und sendet nichts. Die Sende-Logik dahinter (Dublettenpruefung, hoechstens 3 pro Stunde bei echten Alarmen, Kanal 0, Sende-Schutz funkHarden2) ist unveraendert; Probe- und Testalarme gehen nie ins Mesh.
- Routing (Patch teil3, mesh_rules.json, Standardregeln): NINA ist fuer beide Knoten automatisch erlaubt (fuer Mesh 2 entscheidet zusaetzlich der Schalter nina_bayern_auto.json, nach Patch/Neustart Standard AUS, Zustand ueber /api/nina_bayern_auto pruefen); Wetter, Luft, FIRMS, ODL, Sonne, Pegel, Frequenz gehen automatisch nur an Mesh 1 und sind fuer Mesh 2 nur manuell erlaubt; "ping" (Auto-Antwort) beide. Ohne mesh_rules.json gelten diese Standardwerte; eine kaputte Datei faellt auf die Standardwerte zurueck. Cooldown zwischen Sendungen 20 s.
- Kanal: automatische Sendungen und Knoepfe nutzen Kanal 0 (LongFast) von Mesh 1. Bei Frank bedeutet "Mesh-Kanal 1" den Knoten Mesh 1; die Kanalnummer 0 ist der Funkkanal-Index. Falls sich das aendert, steht es in mesh_rules/send-Funktionen; genaue Funkkanal-Konfiguration der Knoten: nicht dokumentiert/zu pruefen.
- Alle Mesh-Sendungen laufen durch Sende-Schutz (funkHarden2), Dublettenpruefung (mesh_log, md5 je Kanal, 24 h; Patch lageDB/mesh_router Teil 1) und werden protokolliert.
- Boot-Ruhe: 5 Minuten nach Dashboard-Start keine Auto-Mesh-Sendungen (meshBootQuiet, Datei mesh_boot_quiet.json).
- NINA-Mesh (ninaCalm): jede Meldungs-ID hoechstens einmal (Warnung, Update, Entwarnung); Verschwinden/Ablaufen sendet nichts; eine wieder auftauchende ID wird nicht erneut gesendet; gesendete IDs stehen 7 Tage in nina_mesh_sent.json; Erststart ohne Datei: alles im Feed gilt als schon gesendet. NINA Bayern (mesh2_nina_seen.txt, nina_bayern_auto.json) ist der Mesh-2-Pfad.
- Auto-Meldungen mit eigener Logik: Wetter und Pegel alle 3 h (0/3/6/9/12/15/18/21 Uhr, Pegel 60 s spaeter), Netzfrequenz nach Stufen (Stufe 1 nur Entwarnung, Meldung ab hoeherer Stufe), Stromausfall, DWD und DWD-WBI bei Aenderung/Entwarnung, Luft/FIRMS bei Aenderung (Feinstaub gelb/rot, Brand neu/weg), ODL bei Ampelwechsel, Weltraumwetter. Status je Art in *_status.json (nina_mesh_status.json, dwd_mesh_status.json, mesh_weather_status.json, ...).
- Echtalarme (ASA/NINA/BR24-Notfall) zusaetzlich ueber mesh_router.py mit den Regeln aus Kapitel 7 (Dedup 6 h, max. 3/h, Kill-Switch).

## Bridges und Sessions

- Je Knoten eine Bridge (Dienste mesh-bridge und mesh-bridge-bayern): genau EINE TCP-Session zum Knoten, interne Queue, Pong auf Ping, Inbox (mesh_inbox*.json). Die Bridge schreibt Node-DB, lastHeard und ch_util selbst (funkHarden). Ein zweiter Client wuerde die Bridge aus der Session werfen.
- Das Dashboard prueft Sessions nur mit ss -tnp/systemctl show (mesh_session.py, Ergebnis 20 s gecacht) und oeffnet nie selbst eine Verbindung, solange eine Session besteht.
- Hang-Watchdog (mesh_hang_watchdog.py, Units mesh-hang-watchdog.service + .timer): erkennt "stuck" Telemetrie (gleicher Wert zu lange) und "stumme" Antworten (Ping empfangen, keine Antwort; Daten aus mesh_chutil.py und mesh_reply_watch.py) und schreibt mesh_hang_status.json. Aktion erst nach 45 min stuck (STUCK_ACTION_SEC); ein automatischer Neustart der betroffenen Bridge/des Dienstes passiert nur, wenn die Freigabe-Datei mesh_hang_autorestart (im Ordner secrets/) existiert; danach Cooldown 2 h (bei Zweitversuchen 25 min, bis zu 4 schnelle Wiederholungen je stuck-Episode). Ergebnis sichtbar im Banner der Funk-Seite und in mesh_hang_watchdog.log.
- Auto-Antworten (mesh-ping-reply, mesh-ping-reply-2): antworten auf ping/test im selben Kanal; Text wird in mesh_bridge.py on_receive gebaut ("von !nodeid", Stationsname "Station Kalchreuth").
- Mesh 2: MQTT am Knoten aus; ein optionales lokales Mosquitto fuer Mesh 2 ist moeglich, aber derzeit aus.

## Was nie passiert

- Keine automatische Sendung bei Probe/Test; keine Sendung durch Tests/Simulationen/Rauchtests/Patches; keine Sendung ueber SDR; keine PIN-Sperre (Entscheidung Frank); der Messenger Telegram kommt im Code nicht vor (das Wort steht nur in 'Telegramme' der 433-MHz-Anzeige).

# Datenfluesse (Quellen -> Verarbeitung -> Anzeige/Speicher)

| Quelle | Weg | Verarbeitung | Anzeige / Speicher |
|---|---|---|---|
| NINA/MoWaS (warnung.bund.de) | requests im Voll-Update (15 min) | ninaCalm (Ablauf, Entwarnung), lagegeo (Polygone) | Kachel NINA WARNUNGEN, /karte; events + geo_cache in lagezentrum.db; Mesh bei neuer ID |
| DWD Warnungen/WBI | Voll-Update | Filter auf Kalchreuth/Forst/Erlangen/ERH/Schnaittach | /umwelt; dwd_*status.json; Mesh bei Aenderung |
| Open-Meteo (Wetter, Wind) | Voll-Update | Vorhersage 5 Tage, Sonne | /umwelt, /luft; Mesh-Wetter alle 3 h |
| BfS ODL | Voll-Update | Ampel (0,25 / 0,60 µSv/h) | /umwelt; Mesh bei Ampelwechsel |
| NOAA SWPC | Voll-Update | Kp, G/R/S | /umwelt; Mesh manuell/Auto |
| energy-charts (Preis, Last, Mix) | Voll-Update | Reihen | /energie; strom_history.json, archive/ |
| EuroOilWatch (Brent), Tankerkoenig (Diesel), Metall-/Krypto-Quelle | Voll-Update | Hoch/Tief seit Aufzeichnung | /energie; oil_history.json, fuel_history.json, price_*.json |
| GIE AGSI/ALSI | Voll-Update (API-Schluessel in config.py) | Fuellstand | /speicher |
| GKD Bayern (Pegel) | Voll-Update | 3-h-Trend | /pegel; Mesh Pegel |
| Stoerungsauskunft/N-ERGIE | Voll-Update | Ausfaelle Mittelfranken | /lokale-energie; outage_history.json; Mesh |
| FIRMS, Sensor.community | luft.py | Naehe, Schwellen | /luft; firms_history.json; Mesh |
| RSS-Feeds | /api/news_refresh bzw. Update | Liste | /news |
| Netzfrequenz-Quelle | FREQ_INTERVAL | Stufen | Lage-Kachel; Mesh nach Stufen |
| Stratum-1 (NTP) | ntplib | Offset | Kopf der Lage-Seite |
| tar1090 (192.168.178.15) | HTTP JSON | Statistik, Squawk, Militaer | /adsb; adsb_history.json |
| gpsd (192.168.178.15:2947) | prepper_gps.py (nur lesen) | GPS/GLONASS-Bewertung | Kachel STOERSENDER/QRM, sdr_noise_hist |
| SDR-Geraete | prepper_sdr.py (Planer, Decoder) | Block-Ergebnisse, Watchdog | lagezentrum.db (state), JSON-Notkopie, archive/ |
| lagezentrum.db | Dashboard (sdr_manager) | Status SDR_OFFLINE/OK/PROBEALARM/ECHTALARM | Lage-Ampel, /funk, /rundfunk, /dabhist, /karte |
| Mesh-Knoten | Bridges | Inbox, Node-DB | /mesh, /mesh2, /funk |
| Systemzustand (systemctl, smartctl, df) | Dashboard (nur lesend, lokale Befehle) | Boot/SMART/Belegung | /pi |

- Voll-Update: ein Hintergrundfaden alle UPDATE_INTERVAL (15 min) ruft alle Internetquellen nacheinander ab (mit Timeout), schreibt data_store (Speicher) und die JSON-Zustandsdateien. Jede Kachel hat einen Zeitstempel "Aktualisiert/Abruf". Ausfall einer Quelle zeigt "–"/"Keine Quelle", der letzte gute Wert bleibt, wo sinnvoll, gekennzeichnet.
- Langzeitarchiv (archive_store.py): archive/JJJJ-MM/<reihe>.jsonl Rohpunkte 90 Tage, archive/daily/<reihe>.jsonl Tageswerte (dauerhaft), archive/events/<liste>.jsonl Ereignisse (dauerhaft, dedupliziert), archive/state.json (atomar). Kein Netz, keine Sendungen, schreibt nur unter archive/.
- DB primaer (sqlC): sdr_status und broadcast_state kommen aus lagezentrum.db, die JSON-Dateien sind im Normalbetrieb nur Notkopie (alle 10 min) bzw. Ersatz, wenn die DB fehlt/gesperrt ist; selbstheilend.
- Einfluss der Anzeige auf Sendungen: ausschliesslich ueber die Sendestellen aus Kapitel 8; die Anzeige selbst sendet nie.

# Datenbank und Zustandsdateien

## Datenbank lagezentrum.db (SQLite, WAL)

- Eine Verbindung je Aufruf (thread-sicher), WAL, busy_timeout; Schema-Migration idempotent (CREATE IF NOT EXISTS, fehlende Spalten per ALTER TABLE). Jede Funktion in database.py faengt Fehler ab. Aufraeum-Faden (sqlA, database.start_retention, einmal je Prozess, erster Lauf nach 30 s, dann alle 10 min): Ereignisse 7 Tage nach Ablauf, Empfangs-/Telemetriedaten nach den Fristen in database.py; dabSql-Daten nach 60 Tagen (nur bei plausibler Uhr).
- Backup: jede Auslieferung sichert zusaetzlich die DB per sqlite3 .backup (konsistent, auch im laufenden Betrieb).
- Tabellen und Spalten (automatisch aus dem Schema, nur lesend) und Zeilenzahlen:

@@AUTO db@@

@@AUTO dbcounts@@

- Rolle der Tabellen: events (Lageereignisse NINA/MoWaS, DAB, ASA, BR24; ext_id eindeutig, Upsert, is_test), mesh_log (md5 gesehener/gesendeter Mesh-Texte je Kanal, auch Auto-Versuche), mesh_auto (Echtalarm je akey), mesh_queue (Warteschlange), telemetry (DAB-Empfangswerte je Stick/Kanal; kind dab/hb), reception_log/masts/channel_status/tii_seen/tii_seen_meta (dabSql, TII), geo_cache (Warngebiete), asa_rx, state (Schluessel-Wert-Transport), meta.

## Zustandsdateien (JSON/JSONL im Projektordner, Auszug)

- sdr_status.json, broadcast_state.json, sdr_dabhist.json, sdr_events.json, sdr_kfz.json, sdr_techlog.json, sdr_wd.json, sdr_wd_gate.json, sdr_lage.json, sdr_takeover.json, sdr_airtest.json, sdr_noise_hist.json, noise_state.json, funk433_state.json, rtl433.jsonl, aprs*.json, broadcast_events.jsonl, teil4_state.json: SDR/Funk.
- nina_*.json/txt, dwd_*status.json, mesh_*.json, mesh_rules.json, mesh_auto.json (Kill-Switch), mesh_boot_quiet.json: Warn- und Mesh-Zustand.
- strom/oil/fuel/price/outage/adsb/firms *_history.json, ping_stats.json, speedtest.json: Verlaeufe.
- health_status.json, health_check.log, last_dashboard_restart.txt, sd_health.json (root-Timer), keep-last.json: Betrieb.
- Alle Zustandsdateien werden atomar geschrieben (tmp + fsync + os.replace; Patch funkHarden3). Sie sind Laufzeitdaten und gehoeren nicht ins Git-Repo (.gitignore).

# Patch-Auslieferung und Qualitaetssicherung

## Grundregeln

- Keine direkte Bearbeitung der Live-Dateien durch Entwickler. Jede Aenderung kommt als apply-Skript (apply-NAME.sh) mit einer Commit-Nummer (zum Beispiel "commit13"): bash /tmp/apply-NAME.sh commitN. Das Skript enthaelt die geaenderten Dateien eingebettet (oder per Patcher) und weiss, auf welchem Dateistand es aufsetzt.
- Der Standard jedes apply-Skripts (verbindlich):
  - Basispruefung: sha16 (erste 16 Hex-Zeichen von sha256) jeder Zieldatei muss dem erwarteten Stand entsprechen, sonst Abbruch VOR jeder Aenderung (0 Backups). Idempotente Neuanwendung (Zielstand schon da) wird erkannt ("UNVERAENDERT").
  - Trockenlauf (--dry-run): zeigt, was passieren wuerde, ohne zu schreiben.
  - Backups: Zeitstempel-Kopien der Zieldateien (*.bak-NAME-JJJJMMTT-HHMMSS), keepLast 3 je Name, plus SQLite-Backup von lagezentrum.db (sqlite3 .backup).
  - Atomares Schreiben (Datei.tmp, fsync, os.replace), Rechte der Datei bleiben erhalten.
  - AST-Wache: ein Programm vergleicht den Syntaxbaum des neuen Stands mit dem alten; neue Schichten duerfen nur erlaubte Konstrukte enthalten (keine subprocess/os.system/socket/Threads/Sendeaufrufe ohne Freigabe). Die Wache wird mit Mutationstests geprueft (absichtlich verbotener Code muss abgelehnt werden).
  - py_compile mit /usr/bin/python3 und dem venv-Python; Selbsttests der neuen Schicht.
  - Minimaler Neustart: nur prepper-dashboard; prepper-sdr und Pi werden nie von Patches neu gestartet (Ausnahme: ausdrueckliche Freigabe fuer einen konkreten Patch).
  - Rauchtest nach dem Neustart: 26 Pruefungen (12 Seiten + 14 APIs, alle HTTP 200) plus patchspezifische Pruefungen (zum Beispiel DOM-Reihenfolge auf /pi). Es wird dabei nichts gesendet/ausgeloest.
  - Rollback: bei jedem Fehler stellt das Skript Dateien (und Dienststand) aus den Backups wieder her und beendet mit Fehlercode.
  - Ausgabe: Wachen-Ergebnisse, sha16 und Zeilenzahlen aller geaenderten Dateien, Zeile "COMMIT commitN ...".
  - Manipulationstest (Tamper): ein veraenderter eingebetteter oder installierter Stand fuehrt zum Abbruch vor jeder Aenderung.
- Alte apply-Skripte bleiben unveraendert und wirken nur auf den damaligen Stand. Neue Patches duerfen alte Pruefungen nicht kaputt machen (siehe /pi: "Sicherung letzte Kachel").
- Simulation: vor der Lieferung laeuft jeder Patch in einer Sandbox (Kopie der Projektdateien, eigener Port, Stubs fuer systemctl/sudo/Netz, kein Zugriff auf echte Geraete, nichts wird gesendet), inklusive Rollback- und Tamper-Szenarien.

## Reihenfolge der Patches (Auszug, juengste zuletzt; Stand siehe Kapitel 16)

- Vorgaenger-Bloecke (2026): ninaCalm, uplinkDetect, funkHarden/2/3, pegelTrend, priceAllTime, longArchive, sdHealth, piPolish/2, speedTest/speedTile, sdrFunk ... sdrPlus ... (SDR-Familie), lageDB, lageGeo, teil2/3/4 (modularer Umbau, 17.10.), sysBoot/diskTiles2 (SSD/SD, 23.10.), sqlA/B/C, sdrAir/sdrAir2/sdrWd/dabSql (23./24.10.), airTest, sdrRest/sdrRest2, sdrHalt, sdrStick3, sdrFall, projDoc (diese Datei). Einzelne Patches sind unten in der Tabelle der Schichten erklaert; den echten Verlauf (Backups *.bak-NAME) liefert der automatische Abschnitt "Patch-Historie".

## Patch-Schichten (Marker "# ===== name: ... =====") und ihr Zweck

| Schicht | Zweck (kurz) |
|---|---|
| ninaCalm | NINA-Anzeige beruhigen, Mesh je Meldungs-ID einmal (nina_calm.py) |
| meshBootQuiet | 5 min nach Dashboard-Start keine Auto-Mesh-Sendungen |
| uplinkDetect | Telekom/Starlink erkennen (Lage-Kachel Internet, /pi, /api/uplink) |
| funkHarden2 | Sende-Schutz im Dashboard |
| funkHarden3 | Status-/Verlaufsdateien atomar schreiben |
| pegelTrend | 3-h-Trend je Pegel aus GKD-Rohwerten |
| priceAllTime | Hoechst/Tiefst seit Aufzeichnung fuer Diesel und Brent |
| longArchive | Langzeitarchiv (archive_store.py), nur lesen |
| firmsKeep | Waldbrand-Historie beim Start laden |
| sourceWatch | Quellen-Ueberwachung (ausgelagert nach tiles_sources.py) |
| sourcesManual | manuelles Voll-Update (Knopf auf /pi) |
| sdHealth | SD-Karten-Ampel aus sd_health.json |
| piPolish | einheitliche kompakte Karten auf /pi, Sicherung zuletzt |
| piPolish2 | Sicherung (#backupBox) als letzte Karte, nur 5 neueste Sicherungen |
| speedTest | Ookla-Speedtest je Uplink |
| speedTile | Speedtest-Box im Internet-Tile (Diagramm 14 Tage) |
| sdrFunk | SDR-Planer-Seiten /funk433 und /aprs, Lage-Kachel |
| sdrFunk2 | SDR-Kachel unten auf /funk, kompakt |
| sdAck | "Quittieren & neu pruefen" der SD-/Laufwerk-Karte |
| sdrPlus | Rundfunk-Warntexte (UKW-RDS, DAB+) + Meteor-M LRPT |
| sdrPreset | feste Empfangs-Presets (Whitelist, 30/60/120 min) |
| sdrAct | Aktivitaets-Zeile (nur Pegel/Belegung) |
| sdrStick | Kachel zeigt gebundenen Stick (Seriennummer) und Anzahl |
| sdrRds | Rundfunk-Zeile zaehlt UKW-Sender mit PI, letzter guter Stand mit Alter |
| sdrRf | Seite /rundfunk und /api/broadcast/events |
| sdrNoise | Kacheln Stoersender/QRM und Gewitter-Hinweis, Kalibrierung |
| sdrGps | Dach-GPS (gpsd) in der Kachel Stoersender/QRM |
| sdrNoise2 | robuste Schwellen (Median + MAD), Stundengrundlinie, Trend |
| umweltWide | /umwelt alle Kacheln volle Breite |
| gpsLearn | GPS/GLO getrennt: lernt/keine Daten/bewertet |
| evLog | Ereignis-Log QRM/Gewitter/GPS/Trend + KFZ-Sensoren |
| br24Warn2 | nur BR24-Texte (+ ASA DE), Warn-Score |
| lageMesh1 | Lage-Seite: BR24-Kachel unter NINA, Knopf "An Mesh 1 senden" |
| sdrQrmFix | SDR-Kachel im Raster, Handy ohne Ueberlauf, QRM-Messung |
| sdrUi | SDR-Kachel /funk neu (Status-Chips, Modus, Einzelempfang) |
| sdrLage | Quellen-Schalter AN/AUTO/AUS, Lage-Profile, Zeitanteile |
| sdrDual | zwei Sticks: Zeitanteile je Stick, Einzelbetrieb |
| stickTest | Kachel Antennentest, Stick-Zuordnungstest |
| stickTestFix | Antennentest als letzte Kachel im Raster |
| dabHist | BR24 (11D) und ASA DE (5C) als Zeilen in der SDR-Kachel; DAB-Verlauf |
| lageDB | Lagezentrum-Datenbank lagezentrum.db zusaetzlich zu JSON |
| sysBoot | Start ohne Warten (Server lauscht sofort), lzKick, Boot-Disk-Kacheln |
| lageGeo | echte NINA-Warngebiete (Polygone) |
| rdsNotfall | RDS-Notfall nur bei bestaetigter 9A-Notfallgruppe/PTY 31 |
| teil2 | Teil 2 von 4: (fruehere) Stick-2-Uebernahme 5C bei Echtalarm (durch sdrAir abgeloest) |
| teil3 | Meshtastic-Routing und Priorisierung (Mesh 2 nur NINA) |
| teil4 | Teil 4 von 4: Lage-Ampel mit Grund-Zeile, SDR-Status, Vor-Alarm |
| diskTiles2 | /pi "SSD · Master" und "SD · Fallback" (Boot-Ampel, SMART, Klon) |
| kartevec | /karte als eigene Seite, TII-Vektorlinien |
| sqlA | Aufraeum-Faden der Datenbank |
| sqlB | Dashboard liest sdr_status/broadcast_state zuerst aus der DB |
| sqlC | DB primaer, JSON nur Notkopie |
| funkUI | /funk Funk-Lage und Steuerung, /dabhist, /meteor-Galerie |
| sdrAir | Geraete-Register (Airspy 11D, Stick 1 5C, Stick 2 Hobby) |
| sdrAir2 | Anzeigenamen "Name · Rolle" auf allen Seiten |
| sdrWd | Daten-Watchdog je Stick (Anzeige/Dienst) |
| sdrWd2 | Watchdog-Kasten ruhig, je Zeile eine Zeile |
| dabSql | DAB/TII-Datenschicht in der DB, /api/dabsql/status |
| airTest | Gain-Test Airspy 11D |
| sdrRest | Herkunft der Koordinaten, Uhr-Schutz |
| sdrRest2 | Kanal 10C "nicht geprueft", Uhr-Hinweise, Stick-Pruefung |
| sdrStick3 | Stick 3 als zweiter Hobby-Stick im Register |
| sdrFall | Rueckfall-10C-Meldung nur vom 5C-Planer |
| sdrHalt | Planer-Waechter (kontrollierter Dienst-Neustart bei Haengen) |
| sdrTeil2 | prepper-sdr Teil 2 (Stick 1 fest 11D; Stick 2 Hobby/Bereitschaft) |
| sdrTeil4 | prepper-sdr Teil 4 (Rueckfall 10C, jetzt vom Register gefuehrt) |
| sdrLog | Technik-Verlauf sdr_techlog.json |
| dabFix | DAB-Empfangsguete richtig lesen, bekannte Rundfunktraeger nicht als Stoerer |
| dabGain | DAB ueber rtl_tcp mit fester Verstaerkung |
| projDoc | Projektbeschreibung: Kachel #projDocBox ganz unten auf /pi, /api/docs/list, /api/docs/download, /api/docs/routes |
| meshPost | GET sendet nie ins Mesh: /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather, /api/mesh_test nur noch per POST von der eigenen Seite (Herkunftspruefung, Kopf X-Mesh-Post), GET = Vorschau bzw. 405; 6 Aufruferstellen im Dashboard-JavaScript umgestellt; /api/meshpost/status (commit14) |

- Dateien ausserhalb der Schichten-Marker (Module) haben eigene Kennzeichen /* name */ im Code, zum Beispiel chutilFunk, meshHangFunk, mesh2OneSession in funk_health.py/mesh_session.py, zuhausePage/zuhauseJinjaFix/zuhauseCacheFix/zuhausePolizeiPI/apoZuhause in zuhause.py.
- Der automatische Abschnitt "Marker" unten listet die tatsaechlich gefundenen Schichten je Datei mit Zeilennummer.

@@AUTO markers@@

@@AUTO history@@

# GitHub-Dateistruktur und Austausch zwischen Pi und GitHub

## Zwei Repos mit verschiedenen Aufgaben

| Repo | Sichtbarkeit | Zweck | Zugriff |
|---|---|---|---|
| Frankenland90/prepper-patches | oeffentlich (Roh-Link ohne Token: HTTP 200) | Auslieferung: apply-NAME.sh, patch-*.py, *.zb64, Hilfsmodule, mesh-hang-watchdog.service/.timer, README.md | Pi holt per curl, immer ueber einen festgenagelten Commit |
| Frankenland90/kaeswasser-lage-monitor | PRIVAT (Roh-Link ohne Token: HTTP 404) | Kopie/Arbeitsstand von /home/fmg/prepper-dashboard (Quellcode, Doku in docs/) | nur ueber das GitHub-Konnektor-Tool/der KI mit Frank-Freigabe; der Pi greift nie darauf zu |

- Wichtig: prepper-patches ist oeffentlich. Dort darf NIE ein Schluessel, Passwort, Token, config.py-Inhalt oder secrets/-Inhalt liegen. Alles, was fuer den Pi bestimmt ist, ist dort lesbar fuer jeden.
- Branches im privaten Repo: kaeswasser-lage-monitor (EINZIGER Arbeitsbranch; hier wird gearbeitet und gepusht), main (Ursprung), krisenfunk-erweiterung (aelterer Stand; Repo-Aufraeumen dort steht auf Eis, siehe Kapitel 16). Gepusht wird nur auf kaeswasser-lage-monitor. Kein Klon beim Betreiber, kein git auf dem Pi.
- Beobachtung am 24.10.2026 (nur Dateinamen gelesen, keine Inhalte): Das Wurzelverzeichnis des Branches kaeswasser-lage-monitor enthaelt neben dem Quellcode noch Laufzeitdateien (json/jsonl/log, *.bak-*-Sicherungen) und einen Ordner secrets/ sowie config.py. Das Aufraeumen (.gitignore, secrets/ und config.py mit API-Schluesseln entfernen) steht auf Eis. Folge: das Repo privat lassen, keine Dateien aus secrets/ oder config.py kopieren, anzeigen oder in oeffentliche Repos legen; vor einer Veroeffentlichung muss erst aufgeraeumt werden.

## Dateistruktur im Repo kaeswasser-lage-monitor (Branch kaeswasser-lage-monitor)

- Wurzel = Spiegel von /home/fmg/prepper-dashboard. Quellcode: dashboard.py, prepper_sdr.py, sdr_manager.py, database.py, mesh_router.py, lagegeo.py, mesh_rules.py, mesh_session.py, mesh_bridge.py, mesh_bridge_bayern.py, mesh_ping_reply*.py, mesh_chutil.py, mesh_hang_watchdog.py, mesh_reply_watch.py, mesh_node_label.py, nina_calm.py, luft.py, zuhause.py, funk_health.py, funk_page.py, health_check.py, watchdog.py, speedtest_run.py, uplink_detect.py, tiles_sources.py, archive_store.py, prepper_gps.py, prepper_evlog.py, prepper_sdr_net.py, prepper_docs.py (neu), smoke.sh, .gitignore.
- Unterordner: tools/ (backup.sh, restore.sh, prepper-clone-ssd-to-sd, ookla/), systemd/sysboot/ (Dateien des Patches sysBoot; Inhalt nicht naeher dokumentiert), static/ (Leaflet u. a.), sdr_lib/, docs/ (diese Projektbeschreibung, Dateien "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt/.md").
- Nicht ins Repo gehoeren (soll per .gitignore ausgeschlossen sein): config.py (Schluessel), secrets/, lagezentrum.db, Laufzeit-JSONs, Logs, archive/, backups/, __pycache__/, *.bak-*.
- Die Zuordnung Funktion -> Datei -> Marker (mit aktuellem sha16 und Zeilenzahl jeder Datei) steht in der folgenden Tabelle; sie wird beim Erzeugen aus den Live-Dateien befuellt.

| Funktion / Feature | Datei(en) | Marker / Kennzeichen | Stand (sha16 · Zeilen) |
|---|---|---|---|
| Lage-Seite, Lage-Ampel, Vor-Alarm | dashboard.py, sdr_manager.py | teil4, lageMesh1, funkUI | @@FI dashboard.py;sdr_manager.py@@ |
| NINA ruhig/Mesh je ID | nina_calm.py, dashboard.py | ninaCalm | @@FI nina_calm.py@@ |
| NINA-Warngebiete (Polygone) | lagegeo.py, dashboard.py | lageGeo | @@FI lagegeo.py@@ |
| Mesh-Routing/Regeln | mesh_rules.py, dashboard.py | teil3 (mesh_rules.json) | @@FI mesh_rules.py@@ |
| Auto-Echtalarm an Mesh 1 | mesh_router.py | (Modul; Schalter mesh_auto.json) | @@FI mesh_router.py@@ |
| Mesh-Bridges und Sessions | mesh_bridge.py, mesh_bridge_bayern.py, mesh_session.py | funkHarden, mesh2OneSession | @@FI mesh_bridge.py;mesh_bridge_bayern.py;mesh_session.py@@ |
| Mesh-Hang-Watchdog | mesh_hang_watchdog.py, mesh_chutil.py, mesh_reply_watch.py | meshHang | @@FI mesh_hang_watchdog.py;mesh_chutil.py;mesh_reply_watch.py@@ |
| Sende-Schutz, atomare Dateien | dashboard.py | funkHarden2, funkHarden3 | @@FI dashboard.py@@ |
| Datenbank | database.py, sdr_manager.py, dashboard.py, prepper_sdr.py | lageDB, sqlA, sqlB, sqlC, dabSql | @@FI database.py;sdr_manager.py@@ |
| SDR-Dienst (Planer, Register, DAB, RDS) | prepper_sdr.py | sdrLage, sdrDual, sdrAir, sdrAir2, sdrTeil2, sdrTeil4, dabGain, dabFix, rdsNotfall | @@FI prepper_sdr.py@@ |
| Daten-Watchdog, Planer-Waechter | prepper_sdr.py, dashboard.py | sdrWd, sdrWd2, sdrHalt, sdrRest, sdrRest2 | @@FI prepper_sdr.py@@ |
| Gain-Test, Antennentest | prepper_sdr.py, dashboard.py, sdr_manager.py | airTest, stickTest, stickTestFix | @@FI prepper_sdr.py;sdr_manager.py@@ |
| Funk-Seite und Unterseiten | dashboard.py, funk_page.py, funk_health.py | funkUI, sdrUi, sdrFunk, sdrRf, dabHist, sdrPlus | @@FI funk_page.py;funk_health.py@@ |
| BR24/ASA-Warnlogik | dashboard.py, prepper_sdr.py | br24Warn2, rdsNotfall | @@FI dashboard.py@@ |
| QRM, Gewitter, Dach-GPS, Ereignisse | prepper_gps.py, prepper_evlog.py, dashboard.py | sdrNoise, sdrNoise2, sdrGps, gpsLearn, evLog | @@FI prepper_gps.py;prepper_evlog.py@@ |
| Karte | dashboard.py | kartevec | @@FI dashboard.py@@ |
| /pi: SSD/SD, Sicherung, Archiv | dashboard.py, tools/backup.sh, archive_store.py | diskTiles2, sysBoot, sdHealth, sdAck, piPolish, piPolish2, longArchive | @@FI archive_store.py;tools/backup.sh@@ |
| Speedtest, Uplink | speedtest_run.py, uplink_detect.py, dashboard.py | speedTest, speedTile, uplinkDetect | @@FI speedtest_run.py;uplink_detect.py@@ |
| Luft, Zuhause | luft.py, zuhause.py | zuhausePage, apoZuhause | @@FI luft.py;zuhause.py@@ |
| Health, Watchdog | health_check.py, watchdog.py | health3h | @@FI health_check.py;watchdog.py@@ |
| Projektbeschreibung (diese Datei) | prepper_docs.py, dashboard.py | projDoc, meshPost | @@FI prepper_docs.py;dashboard.py@@ |

## Weg 1: GitHub -> Pi (Patch holen und anwenden)

Der Pi holt Patches nur aus dem oeffentlichen Repo prepper-patches und nur ueber einen festgenagelten Commit (40 Hex-Zeichen), damit der Inhalt nicht nachtraeglich veraendert werden kann. Frank bekommt drei einzelne Textzeilen (je eine Chat-Nachricht, reiner Text ohne Nummerierung oder Etiketten, sonst meldet bash "Kommando nicht gefunden"):

```
curl -o /tmp/apply-NAME.sh https://raw.githubusercontent.com/Frankenland90/prepper-patches/<COMMIT-SHA-40>/apply-NAME.sh
echo <SHA256-64>  /tmp/apply-NAME.sh | sha256sum -c
bash /tmp/apply-NAME.sh commitN
```

- Zwischen dem sha256 und dem Dateinamen stehen zwei Leerzeichen. Die zweite Zeile muss "OK" ausgeben; sonst nicht ausfuehren. Das Argument commitN (zum Beispiel commit13) wird nur in die Ausgabe/das Protokoll uebernommen. Den Trockenlauf macht das Skript selbst: es patcht zuerst Kopien, prueft sie (AST-Wache, py_compile mit beiden Pythons, Selbsttests, Idempotenz) und schreibt erst danach die Live-Dateien.
- Das Skript prueft sha16 aller Zieldateien, legt Backups an, patcht, kompiliert, startet nur das Dashboard neu, fuehrt den Rauchtest aus und rollt bei Fehlern zurueck. Am Ende steht eine Zeile "COMMIT commitN ..." mit den neuen sha16/Zeilenzahlen.
- Die Kette ist bewusst ohne git-Klon: Lesen = curl, Pruefen = sha256sum, Ausfuehren = bash. Roh-Links des PRIVATEN Repos liefern ohne Token 404 und gehen deshalb nicht.
- Kleine Textdateien (zum Beispiel eine Unit-Datei) koennen alternativ per Copy & Paste eingefuegt werden (cat > datei << 'EOF' ... EOF) und danach mit sha256sum -c gegen den genannten Wert geprueft werden.

## Weg 2: Pi -> GitHub (Stand sichern)

- Der Pi pusht nie selbst (kein git, kein Token). Nach einer erfolgreichen Anwendung uebertraegt die KI mit Frank-Freigabe dieselben Dateien, die das Skript eingebettet hatte (sha-geprueft), als Commit auf den Branch kaeswasser-lage-monitor des privaten Repos. Die Commit-Nachricht nennt Patch, Commit des Patch-Repos und die Ziel-sha16, zum Beispiel "sdrFall (prepper-patches 461ab753): ...". So bleibt Repo = Pi nachweisbar.
- Abgleich Pi gegen Repo ohne Klon: auf dem Pi sha16 bilden und mit der Angabe im Commit/Patch-Ausgabe vergleichen:

```
cd /home/fmg/prepper-dashboard
sha256sum dashboard.py prepper_sdr.py sdr_manager.py database.py mesh_router.py lagegeo.py | cut -c1-16
wc -l dashboard.py prepper_sdr.py sdr_manager.py
```

- Dateien, die nur auf dem Pi existieren (zum Beispiel die Projektbeschreibung, die auf dem Pi erzeugt wird), kommen per Copy & Paste in den Chat (cat docs/DATEI | ... bzw. Download ueber die Kachel auf /pi) oder werden von der KI aus dem Patch-Stand rekonstruiert. Grosse Dateien (dashboard.py > 1 MB) werden nie gepastet, sondern ueber den Patch-Weg synchron gehalten.
- Die Projektbeschreibung selbst: Pi erzeugt sie (python3 prepper_docs.py -> /home/fmg/prepper-dashboard/docs/); das Repo-Exemplar im Ordner docs/ des Branches wird bei jeder Auslieferung mitgepusht und stammt aus dem Repo-Stand (Auto-Abschnitte koennen sich vom Pi-Exemplar unterscheiden, massgeblich fuer den Pi ist das Pi-Exemplar).

## Weg 3: Dokumentation neu erzeugen und verteilen

- Auf dem Pi: cd /home/fmg/prepper-dashboard && python3 prepper_docs.py (neue Version, nur wenn sich Text oder Live-Stand geaendert haben; --force erzwingt eine neue Version; --check prueft nur; --keep N behaelt N Versionen, Standard 10).
- Danach zeigt die Kachel auf /pi die neueste Version; der Download-Knopf liefert "Projektbeschreibung Lage Pi vJJJJMMTT-HHMM.txt". Markdown-Version daneben.
- Fuer die Weitergabe an eine andere KI: TXT herunterladen (oder auf dem Pi mit cat anzeigen und kopieren) und der KI geben; sie braucht dann keine Rueckfragen.

# Entscheidungen und bekannte Einschraenkungen

## Entscheidungen (von Frank getroffen oder bestaetigt)

| Entscheidung | Inhalt |
|---|---|
| Keine PIN auf Sende-Knoepfen | Mesh-Knoepfe sind nicht PIN-geschuetzt; Schutz durch Bestaetigung, Sende-Schutz, Cooldown, Dedup |
| Kein Git-Klon | Dateien per curl -o /tmp/... holen, sha256 pruefen, bash ausfuehren; Repo privat, Pi greift nicht darauf zu |
| Einziger Arbeitsbranch | kaeswasser-lage-monitor im privaten Repo Frankenland90/kaeswasser-lage-monitor |
| Auslieferung ueber prepper-patches | oeffentliches Repo, festgenagelter Commit, drei Einzeiler fuer Frank |
| Rollen der SDR-Geraete fest (23.10.2026) | Airspy R2 = 11D, Stick 1 = 5C (Rueckfall 10C), Stick 2 = Hobby (nur Beobachtung); Stick-2-Uebernahme entfallen; Spyverter draussen; kein Splitter |
| Auto-Mesh nur fuer echte Alarme an Mesh 1 | 6 h Dedup, max. 3/h, Kill-Switch mesh_auto.json; Probe/Test nie |
| Mesh 2 nur NINA automatisch | NINA-Auto-Weg fuer Mesh 2 nur bei Schalter nina_bayern_auto.json = AN (Standard AUS); DAB+ darf .140 nie ansprechen; Mesh 2 hat MQTT aus; optional lokales Mosquitto fuer Mesh 2 (aus) |
| DB primaer, JSON als Notkopie | lagezentrum.db haelt sdr_status/broadcast_state; JSON nur Ersatz alle 10 min |
| SSD Master / SD Fallback | SD-Klon nur auf Knopfdruck, kein automatischer Klon |
| Persistentes Journal 200 MB | seit 23.10.2026 |
| Watchdog-Stufen | Pi-Neustart nur durch den Daten-Watchdog (60 min ohne Empfang, max 1/h, Stopp nach 3); Patches loesen nie einen Neustart aus |
| sdrHalt | einziger kontrollierter Selbstneustart von prepper-sdr (Planer haengt >= 10 min, nie in Sperren, max 3/h) |
| Anzeige-Namen | alle Seiten benutzen "Name · Rolle" aus dem Geraete-Register ("Airspy R2 · 11D", "Stick 1 · 5C", "Stick 2 · Hobby", "Stick 3 · Hobby") statt Platznummern |
| Projektbeschreibung | Kachel ganz unten auf /pi unter der Sicherung; Version = Zeitstempel (Berlin); Download nur aus docs/ |

## Technische Entwurfsentscheidungen

- Monolith statt Microservices: ein Prozess ist auf dem Pi robuster zu betreiben; Aufteilung nur dort, wo ein Dienst Hardware besitzt (prepper-sdr) oder eine Verbindung exklusiv halten muss (Mesh-Bridges).
- Schichtweises Patchen mit Markern statt Refactoring: jede Auslieferung ist klein, pruefbar und rueckrollbar; der Preis ist eine sehr grosse Datei.
- Strings statt Vorlagendateien: Seiten sind Python-Strings; deshalb gibt es keine getrennte Frontend-Pipeline. Wiedererkennung ueber Kommentar-Marker /* name */.
- HTML-Injektion per after_request: erlaubt Erweiterung ohne Eingriff in alte Seitenstrings; Reihenfolge beachten (Flask fuehrt die Hooks umgekehrt aus).
- Ehrliche Anzeige statt schoener Zahlen: fehlende Werte "–", Ersatzwerte benannt, Alter der Daten sichtbar, "lernt" statt falscher Ampel.
- Probe-/Test-Erkennung konservativ: lieber ein echter Alarm wird nicht automatisch weitergegeben (manuell per Knopf immer moeglich) als ein Probealarm ans Mesh.
- Ein Stick gehoert einem Planer: keine zwei Programme gleichzeitig auf einem Stick; Planer sperren sich zeitlich.
- Alle Zustandsdateien atomar; Datenbank im WAL-Modus; jede Funktion mit try/except.

## Bekannte Einschraenkungen

- welle-cli liefert keine Bitfehlerrate, keinen Alarmflag (FIG 0/0), keine Ansagen (FIG 0/19) und kein ASA-Datenfeld: Warnerkennung nutzt DLS-Text und das Dienst-Label "ASA" im Ensemble 5C; BER wird durch die FIC-Fehlerrate ersetzt.
- Der Rundfunk-Block misst DAB nur im Wechsel; daher gibt es keinen echten 15-s-Takt der Telemetrie (Lebenszeichen 'hb', Watchdog 15 s).
- ASA-Dienst: wenn der Dienst laenger als 55 s nicht empfangen wird, zeigt die Funk-Seite ASA_INTERRUPTED (Soll 37 s).
- Hobby-Stick: nur Beobachtung; ohne Sync auf 10C wird "nicht geprueft" statt "offline" gezeigt.
- Dach-GPS haengt am Stratum-1-Server; faellt der gpsd aus, zeigt die Zeile "nicht erreichbar" (grau) und die QRM-Bewertung der GPS-Zeilen lernt neu.
- Grundlinien (QRM, GPS) brauchen mehrere Tage Lernzeit ("lernt"); in dieser Zeit keine Alarmfarbe.
- Netzfrequenzquelle, Strompreise, Krypto etc. sind Internetdienste Dritter; Ausfall = "Keine Quelle".
- Kein Login, keine Verschluesselung (HTTP im LAN). Nicht aus dem Internet erreichbar machen.
- Die Kachel-Reihenfolge auf /pi haengt an JavaScript/Hooks; Aenderungen an der Seite muessen die Checks "Sicherung letzte Kachel" und "/pi: Sicherung unveraendert (11x)" der bisherigen Patches beachten (die neue Projektbeschreibung nutzt deshalb die Klasse pd-card statt card).
- /karte und /medizin brauchen JavaScript bzw. den Dienst kiwix; ohne diese erscheinen leere Seiten.
- Uhr: ohne NTP-Sync pausieren Aufraeum- und Offline-Rechnung der DAB-Datenbank (Uhr-Schutz).
- Mesh: Funkreichweite/Knotenanzahl sind nicht garantiert; "gesendet" heisst "an den Knoten uebergeben", nicht "bei jemandem angekommen".

# Nicht-Ziele

- Kein Senden ueber SDR (Funk). Kein Mesh-Versand aus Tests/Simulationen/Smoke.
- Keine Pager-/BOS-/Behoerdenfunk-Dekodierung (rechtlich ausgeschlossen); nur Rundfunk, Wettersatellit, ISM, APRS.
- Kein offizielles Warnsystem, keine Garantie, kein Ersatz fuer Sirenen/Warn-Apps.
- Kein Zugriff aus dem Internet, keine Nutzerverwaltung, keine Cloud, keine Telemetrie an Dritte.
- Kein automatischer SD-Klon, kein automatischer Pi-Neustart durch Patches.
- Kein MQTT-Betrieb (hoechstens optionales lokales Mosquitto fuer Mesh 2, derzeit aus).
- Keine PIN auf den Sende-Knoepfen (Frank hat sich dagegen entschieden).
- Kein Git auf dem Pi, kein Klon.
- Kein Veroeffentlichen von Schluesseln, Konfiguration oder Betreiberdaten.

# Betrieb und Diagnose (nur lesend)

## Haeufige Prueffragen (ohne Aenderungen am System)

```
systemctl is-active prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern kiwix chrony
journalctl -u prepper-dashboard -n 80 --no-pager
journalctl -u prepper-sdr -n 80 --no-pager
curl -s http://127.0.0.1:5000/api/sdr/live
curl -s http://127.0.0.1:5000/api/sdr/wd
curl -s http://127.0.0.1:5000/api/docs/list
ls -l /home/fmg/prepper-dashboard/docs
cd /home/fmg/prepper-dashboard && python3 prepper_docs.py --check
```

- Der Port steht in config.py (PORT; Standard 5000). Werte aus config.py nie ausgeben.
- Der Neustart des Dashboards (sudo systemctl restart prepper-dashboard) braucht das sudo-Passwort des Betreibers; dieses wird nie im Chat genannt. Normalerweise macht das der Patch selbst.
- Dashboard-Antwort "laedt": nach einem Neustart dauert das erste Voll-Update etwa 1-2 Minuten; die Seiten sind sofort erreichbar.
- Rauchtest (smoke.sh im Projektordner) ruft die Seiten/APIs ab, sendet nichts.

## Fehlersuche (Faustregeln)

- Lage-Ampel orange blinkend = SDR_OFFLINE: prepper-sdr laeuft nicht oder schreibt nicht (Funk-Seite "Datenquelle"/Daten-Watchdog ansehen, journalctl -u prepper-sdr).
- "ASA_INTERRUPTED": 5C-Dienst nicht empfangen; Antenne/Empfang des Sticks 1 pruefen, Rueckfall 10C beobachten.
- 11D ohne Empfang: Airspy/Antenne/Gain; Gain-Test-Kachel auf /funk (nur Anzeige) nutzen.
- Mesh "Dienst aus"/"TCP zu": Bridge-Dienst und Knoten-Erreichbarkeit pruefen; Hang-Watchdog-Banner auf /funk.
- Kachel zeigt "–": Quelle ausgefallen (Datenquellen-Kachel auf /pi zeigt die Fehlerzaehler) oder noch nicht abgerufen.
- Uhr falsch: chrony und Stratum-1 pruefen; DAB-Datenbank pausiert dann das Aufraeumen.
- Nach jeder Aenderung: Rauchtest und /pi ansehen (Reihenfolge der Kacheln).

## Wiederherstellung

- Jeder Patch legt Backups an (*.bak-NAME-JJJJMMTT-HHMMSS, keepLast 3) plus ein SQLite-Backup. Die Sicherung auf /pi (tools/backup.sh) sichert Projektdateien/DB; Wiederherstellung ueber die Kachel "Sicherung" (doPrepperRestore) oder per Hand aus den Backups.
- Bei Boot-Problemen: SD-Fallback (geklont auf Knopfdruck) nutzen; Boot-Reihenfolge im Kachel "SSD · Master" ansehen.

# Aktueller Stand und offene Punkte

## Stand der Entwicklung (Auszug, Berlin-Zeit der Branch-Commits)

- Die juengste Patch-Familie rund um SDR (23./24.10.2026): sdrAir (Geraete-Register, feste Rollen), sdrAir2 (Anzeigenamen, Hobby nur Beobachtung; Branch-Commit 02:00), dabSql (Datenbankschicht fuer DAB/TII; 08:30), airTest (Gain-Test; 09:35), sdrHalt (Planer-Waechter; 10:10), sdrRest (Koordinaten-Herkunft, Uhr-Schutz; 12:06), sdrRest2 (USB-Stand nur lesend, 10C "nicht geprueft"; 13:21), sdrStick3 (Stick 3 im Register; 15:00), sdrFall (Rueckfall-10C-Meldung nur vom 5C-Planer; 17:21 am 24.10.2026).
- Basisstand dieser Beschreibung = Stand nach sdrFall, projDoc und meshPost. Die genauen sha16 und Zeilenzahlen aller Dateien stehen im Abschnitt "Dateien im Projektordner" (Kapitel 4) und in der Tabelle in Kapitel 12.
- Danach kam der Patch projDoc (Kachel + Generator prepper_docs.py + Ordner docs/; commit13) und als juengster Schritt der Patch meshPost (commit14): GET auf die Sende-Wege Wetter/ODL/Pegel/Luft/Sonnenaktivitaet/NINA-Test sendet nie mehr; Senden nur per POST von der eigenen Seite. Beide aendern nur dashboard.py (meshPost zusaetzlich prepper_docs.py und die docs-Version).
- Parallel in Arbeit: sdrStick3c (Stick 3 bekommt die eindeutige Seriennummer 26102403 per rtl_eeprom; danach einmal neu einstecken). Dieser Patch aendert keine Programmdateien dieses Standes; projDoc ist davon unabhaengig.

## Funktioniert (Stand der Erzeugung)

- Alle 26 Rauchtest-Pruefungen (12 Seiten + 14 APIs) im Standardlauf; /pi mit Sicherung als letzter Standard-Kachel, darunter die Projektbeschreibung.
- Warnlage (NINA, DWD, BR24/ASA), Lage-Ampel, Funk-Seite mit Geraete-Register, Daten-Watchdog, Mesh-Anzeige, Energie-/Pegel-/Luft-/ADS-B-Seiten, Zuhause, News.
- Mesh-Auto-Meldungen nach den Regeln aus Kapitel 7/8; der Zustand des Echtalarm-Schalters steht live auf /funk.

## Offene Punkte (priorisiert nach Dringlichkeit, nicht nach Reihenfolge der Umsetzung)

- sdrStick3c: Seriennummer fuer Stick 3 (26102403) per rtl_eeprom schreiben und Stick umstecken (geplant, in Arbeit).
- Gain-Test (airTest) auf /funk: Ergebnisse stehen aus bzw. sind noch nicht ausgewertet; die Empfehlung ist nur Anzeige und aendert nichts am Standard-Gain.
- chronyc-Ausgaben (tracking/sources) des Stratum-1-Servers und des Pi: nicht dokumentiert/zu pruefen (Ausgaben stehen aus).
- 11D laeuft dauerhaft ueber welle-cli (Airspy, Port 7979): Langzeitverhalten (CPU-Last, Stabilitaet ueber Tage) beobachten; dazu gibt es noch keine dokumentierte Auswertung.
- Echtzeituhr (zum Beispiel DS3231), TFT-Display ohne WLAN, USB-Portzuordnung, Antennen der Sticks: nicht dokumentiert/zu pruefen.
- Zustand des Schalters mesh_auto.json (Auto-Versand echter Alarme an Mesh 1) pruefen: Funk-Seite "Auto-Versand Mesh 1".
- Repo-Aufraeumen: .gitignore-Bereinigung sowie Entfernung von secrets/ und config.py (API-Schluessel) auf dem Branch krisenfunk-erweiterung steht AUF EIS (nichts anfassen, bis Frank es freigibt). Bis dahin: Repo privat lassen und keine Schluesseldateien kopieren/ausgeben.
- Ochsenkopf-Feinabstimmung (Empfang der dortigen Sender stabilisieren): steht AUF EIS (nichts anfassen, bis Frank es freigibt).
- Optional: lokales Mosquitto fuer Mesh 2 (derzeit aus; MQTT am Knoten ebenfalls aus).
- Dokumentationspflege: die Projektbeschreibung wird bei jeder Auslieferung neu erzeugt (python3 prepper_docs.py); der redaktionelle Text (Kern im Skript) muss bei neuen Kacheln/Diensten ergaenzt werden, sonst erscheinen sie im Nachtrag am Ende.

## Wie sich dieses Dokument aktuell haelt

- prepper_docs.py liest beim Lauf die echten Dateien (Routen vom laufenden Dashboard, Dateien mit sha16/Zeilen, Marker, Units, Datenbank) und gleicht sie mit dem redaktionellen Text ab. Was im Code oder System vorhanden, aber im Text nicht beschrieben ist, wird automatisch im Kapitel "Nachtrag" angehaengt (und im Pruefbericht unten gezaehlt). Ein leerer Nachtrag heisst: alles Gefundene ist redaktionell beschrieben.
- Der redaktionelle Kern liegt im Skript prepper_docs.py (Variable CORE). Aenderungen am Text = Aenderung am Skript = neue Auslieferung.

# Regeln fuer KIs und Entwickler, die hier weiterarbeiten

## Checkliste fuer jede Aenderung

- 1. Lies Kapitel 1, 4, 5 und 11. Pruefe, ob die Aenderung bestehende Logik beruehrt; falls ja, kleinste moegliche Aenderung mit eindeutigem Anker.
- 2. Neue Funktion = neue Schicht "# ===== name: Beschreibung =====" vor if __name__ == "__main__":. Alles in try/except. Keine Netzwerk-/Sende-/Prozess-Aufrufe ohne ausdrueckliche Freigabe.
- 3. Neue Kachel: eigene id (zum Beispiel fooBox), Titel im Stil der anderen, Aktualisierung per fetch auf einen GET-Endpunkt; Handy-Layout pruefen; Eintrag in diese Beschreibung (Kern) ergaenzen.
- 4. Auf /pi: die Kachel "Sicherung" muss unveraendert bleiben (Reihenfolge, doPrepperRestore-Zaehler, #backupBox); nach ihr steht nur die Projektbeschreibung. Neue Kacheln gehoeren VOR die Sicherung.
- 5. after_request-Hooks laufen in umgekehrter Reihenfolge: neue Hooks an die richtige Listenposition setzen.
- 6. Baue das apply-Skript nach dem Standard (Kapitel 11): sha16-Basis, Trockenlauf, Idempotenz, keepLast 3, atomar, AST-Wache (mutationsgetestet), py_compile mit beiden Pythons, Selbsttests, Neustart nur Dashboard, Rauchtest 26 + eigene Pruefungen, Rollback, Tamper-Test.
- 7. Teste in einer Sandbox mit Stubs (systemctl/sudo/Netz), eigenem Port und OHNE Prozesse anderer Arbeitsstroeme zu beenden (kein pkill -f auf fremde Namen). Keine Sendungen, keine echten Geraete.
- 8. Lies keine Secrets (config.py-Werte, secrets/, Schluessel, Passwoerter, Tokens, sudo-Passwort) und schreibe keine in Dateien, Chat oder Patches (prepper-patches ist oeffentlich!).
- 9. Liefere an Frank nur reine Textzeilen (curl -o /tmp/..., echo SHA  datei | sha256sum -c, bash ...), je Zeile eine Nachricht, ohne Nummerierung.
- 10. Pushe auf das private Repo nur auf den Branch kaeswasser-lage-monitor und nur mit Freigabe; Commit-Nachricht mit Patch-Name, prepper-patches-Commit und sha16.

## Stolpersteine (aus der Praxis)

- Sende-Endpunkte (seit Patch meshPost nur per POST): /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_luft, /api/mesh_spaceweather und /api/mesh_test senden nur noch per POST von der eigenen Seite (Origin/Referer, Kopf X-Mesh-Post: 1, JSON). Ein GET darauf sendet nie (Vorschau bzw. 405). Vor meshPost (Stand projDoc und davor) sendeten die fuenf Knopf-Wege beim blossen GET-Aufruf (force=True); wer eine aeltere Version dieser Beschreibung oder einen alten Link/Lesezeichen/Skript kennt, die diese URLs per GET holen: das sendet nicht mehr und liefert nur noch die Vorschau. Nie per POST in Tests, Rauchtests, Crawlern oder Monitoring aufrufen; auch /api/mesh_send, /api/mesh2_send und /api/lage_mesh1/send senden. Neue Sende-Knoepfe immer als POST mit Herkunftspruefung bauen, nie als GET.
- Flask fuehrt after_request-Funktionen in umgekehrter Reihenfolge aus.
- piPolish2 haelt #backupBox per Seiten-JavaScript als letzte ".card"; Elemente nach der Sicherung duerfen nicht class="card" haben, sonst verschiebt das Skript die Sicherung.
- Mesh-Sessions: nie selbst eine zweite TCP-Verbindung zu einem Knoten oeffnen.
- Sticks: nie zwei Programme auf einen Stick; Stick 3 wird von prepper-sdr nie geoeffnet.
- Probealarm-Texte nie als echte Alarme behandeln; im Zweifel nicht automatisch senden.
- Simulationen: Dashboard-Sims warten auf das erste Voll-Update (bis ca. 2 Minuten); /medizin laedt in der Sim nicht (kiwix).
- Alte apply-Skripte nie aendern; ihre Pruefungen gelten dem damaligen Stand.
- Dateinamen mit Umlauten/Leerzeichen (Projektbeschreibung ...) immer in Anfuehrungszeichen bzw. ueber die API/Kachel ausliefern.

## Frank-Format fuer Befehle

- Reiner Text, keine Markdown-Codebloecke im Chat, eine Zeile je Nachricht, keine Nummern/Labels. Reihenfolge: curl -o, sha256sum -c, bash.

# Anhang

## Glossar

| Begriff | Bedeutung |
|---|---|
| NINA / MoWaS | Warn-App/Warnsystem des Bundes (Modulares Warnsystem) |
| DWD / WBI | Deutscher Wetterdienst / Waldbrandgefahrenindex |
| BR24 | Nachrichten-/Informationsprogramm des BR, hier ueber DAB 11D und UKW 102,0 |
| ASA DE | Automatic Safety Alert, Warndienst im 1. Bundesmux (DR Deutschland, DAB 5C) |
| DAB+ / DLS / FIC / FIG | digitaler Hoerfunk / Dynamic Label (Text) / Fast Information Channel / Fast Information Group |
| TII | Transmitter Identification Information (Senderkennung, Mast-Zuordnung) |
| ECC / LTO | Extended Country Code / Local Time Offset |
| RDS / PI / PS / PTY / TA / EWS | Radio Data System / Programmkennung / Sendername / Programmtyp / Verkehrsdurchsage-Kennzeichen / Emergency Warning System (Gruppe 9A) |
| ODL | Ortsdosisleistung (BfS) |
| FIRMS | NASA-Feuerdaten (Hotspots) |
| GKD | Gewaesserkundlicher Dienst Bayern (Pegel) |
| LRPT | Low Rate Picture Transmission (Meteor-M) |
| QRM | Stoerungen im Funkempfang |
| MAD | Median Absolute Deviation (robuste Streuung) |
| TPMS | Reifendruck-Sensoren (433 MHz) |
| ISM | Industrial, Scientific, Medical (433/868 MHz) |
| APRS | Amateurfunk-Positions-/Wetterdaten (144,800 MHz) |
| LongFast | Standard-Funkprofil von Meshtastic |
| sha16 | die ersten 16 Zeichen des sha256 einer Datei (Stand-Kennung) |
| Schicht / Marker | Patch-Block "# ===== name: ... =====" im Code |
| Rauchtest | 26 Pruefungen (12 Seiten + 14 APIs) nach jedem Patch |

## Pruefbericht dieser Ausgabe (automatisch)

Abgleich des redaktionellen Textes mit dem Code und dem laufenden System. Was fehlt, steht im Kapitel "Nachtrag" am Ende.

@@VALIDATION@@

Stand-Hash (nur stabile Teile; aendert sich, wenn Text, Routen, Dateien, Marker oder Units sich aendern): @@STANDHASH@@
'''
# ----------------------------------------------------------------------------------------------------------------------------------------------

FILE_ROLES = {
    "dashboard.py": "Flask-Monolith: alle Seiten, APIs, Abrufe, Patch-Schichten",
    "prepper_sdr.py": "SDR-Dienst prepper-sdr: Planer, Geraete-Register, DAB/RDS/433/APRS/Meteor, Watchdog, Planer-Waechter",
    "sdr_manager.py": "Lagezentrum-Logik: SDR-Status, DB-Abgleich, Lebenszeichen",
    "database.py": "SQLite-Zugriff lagezentrum.db: Schema, Migration, Retention",
    "mesh_router.py": "Mesh-Dublettenpruefung + automatischer Versand echter Alarme an Mesh 1 (Kill-Switch)",
    "lagegeo.py": "NINA-Warngebiete (GeoJSON) vereinfachen und cachen",
    "mesh_rules.py": "Mesh-Routing-Regeln (mesh_rules.json): Hosts, Cooldown, Art je Knoten",
    "mesh_session.py": "Mesh-Sessions pruefen (genau eine TCP-Session je Knoten)",
    "mesh_bridge.py": "Bridge Mesh 1: eine TCP-Session, Queue, Pong, Inbox",
    "mesh_bridge_bayern.py": "Bridge Mesh 2: eine TCP-Session, Queue, Pong, Inbox",
    "mesh_ping_reply.py": "Auto-Antwort auf ping/test (Mesh 1)",
    "mesh_ping_reply2.py": "Auto-Antwort auf ping/test (Mesh 2)",
    "mesh_ping_reply_bayern.py": "Auto-Antwort auf ping/test (Mesh 2, Bayern)",
    "mesh_inbox_util.py": "Hilfen fuer die Mesh-Inbox",
    "mesh_chutil.py": "Kanalauslastung (DeviceMetrics) sammeln/lesen",
    "mesh_hang_watchdog.py": "Hang-Erkennung der Mesh-Verbindungen, optionaler Neustart",
    "mesh_reply_watch.py": "letzte Ping/Test-Antwort je Mesh",
    "mesh_node_label.py": "Knoten-Labels fuer Mesh-Meldungen",
    "nina_calm.py": "NINA-Kachel/Mesh ruhig halten (jede ID hoechstens einmal)",
    "luft.py": "Luftlage: FIRMS, Sensor.community, Wind",
    "zuhause.py": "Seite Zuhause: Abfall, Apotheken-Notdienst, Tierkliniken, Notrufe",
    "funk_health.py": "Funk-Seite: Mesh-Status und Kanalauslastung",
    "funk_page.py": "Funk-Seite: Seitenaufbau",
    "health_check.py": "Health-Report health_status.json (nie Neustart)",
    "watchdog.py": "schlanker Dashboard-Watchdog mit Cooldown",
    "speedtest_run.py": "Ookla-Speedtest (alle 3 h, manuell)",
    "uplink_detect.py": "Telekom/Starlink-Erkennung",
    "tiles_sources.py": "Datenquellen-Liste fuer /pi",
    "archive_store.py": "Langzeitarchiv unter archive/",
    "prepper_gps.py": "Dach-GPS (gpsd) nur lesen, GPS/GLONASS bewerten",
    "prepper_evlog.py": "Ereignis-Log QRM/Gewitter/GPS und KFZ-Sensoren",
    "prepper_sdr_net.py": "Netzzugriffe des SDR-Planers (TLE, welle-cli lokal)",
    "prepper_docs.py": "Generator dieser Projektbeschreibung (TXT+MD in docs/)",
    "smoke.sh": "Rauchtest-Skript (liest nur)",
    "config.py": "Konfiguration/Schluessel (Rechte 600; nie lesen/ausgeben)",
    "lagezentrum.db": "SQLite-Datenbank des Lagezentrums",
    "sdr_config.json": "Geraete-Register und SDR-Einstellungen",
    "mesh_rules.json": "Mesh-Routing-Regeln (Datei zu mesh_rules.py)",
    "mesh_auto.json": "Kill-Switch fuer den Auto-Versand echter Alarme (fehlt/kaputt = AUS)",
    "archive/": "Langzeitarchiv: Rohpunkte 90 Tage, Tageswerte, Ereignisse; dabhist/techlog/evlog",
    "docs/": "Projektbeschreibung Lage Pi (TXT + Markdown, Versionsdateien)",
    "mesh_inbox/": "Inbox-Dateien Mesh 1",
    "mesh_inbox_bayern/": "Inbox-Dateien Mesh 2",
    "static/": "statische Dateien (Leaflet-Karte, Bilder)",
    "tools/": "backup.sh, restore.sh, prepper-clone-ssd-to-sd, ookla/",
    "backups/": "Sicherungen der Sicherung-Kachel (tools/backup.sh); nicht ins Repo",
    "secrets/": "Schluessel und Freigabe-Dateien: Inhalt nie lesen oder ausgeben",
    "sdr_lib/": "SDR-Hilfsbibliothek (nicht naeher dokumentiert)",
    "systemd/": "Unit-Dateien (Patch sysBoot; nicht naeher dokumentiert)",
    "sdr_status.json": "SDR-Zustand (Notkopie; primaer lagezentrum.db)",
    "broadcast_state.json": "Rundfunkzustand UKW/DAB (Notkopie)",
    "sdr_dabhist.json": "Ring der DAB-Textmeldungen",
    "sdr_events.json": "Ereignis-Ring QRM/Gewitter/GPS",
    "sdr_kfz.json": "KFZ-Sensoren (TPMS) Ring",
    "sdr_techlog.json": "Technik-Verlauf (Sync, Ensemble, Masten)",
    "sdr_wd.json": "Daten-Watchdog-Zustand (ueberlebt Neustart)",
    "sdr_mode.json": "Betriebsart des SDR-Planers (schreibt das Dashboard)",
    "health_status.json": "Health-Check-Ergebnis",
    "mesh_boot_quiet.json": "Boot-Ruhe fuer Auto-Mesh",
    "nina_mesh_sent.json": "gesendete NINA-IDs (7 Tage)",
    "speedtest.json": "Ergebnisse des Ookla-Speedtests",
    "keep-last.json": "letzte gute Datenstaende der Quellen",
}


def note(msg):
    NOTES.append(str(msg)[:300])


def rd(p, binary=False, limit=40 * 1024 * 1024):
    with open(p, "rb" if binary else "r", **({} if binary else {"encoding": "utf-8", "errors": "replace"})) as f:
        return f.read(limit)


def sha16(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for ch in iter(lambda: f.read(1 << 20), b""):
            h.update(ch)
    return h.hexdigest()[:16]


def nlines(p):
    n = 0
    with open(p, "rb") as f:
        for ch in iter(lambda: f.read(1 << 20), b""):
            n += ch.count(b"\n")
    return n


def now_berlin():
    fixed = os.environ.get("PRDOCS_NOW")
    if fixed:
        return datetime.datetime.strptime(fixed, "%Y%m%d-%H%M")
    try:
        from zoneinfo import ZoneInfo
        return datetime.datetime.now(ZoneInfo("Europe/Berlin")).replace(tzinfo=None)
    except Exception:
        return datetime.datetime.now()


def run(cmd, timeout=20):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, universal_newlines=True)
        return r.returncode, r.stdout
    except Exception as e:
        note("%s: %s" % (" ".join(cmd[:3]), e))
        return 99, ""


def cell(x):
    return re.sub(r"\s+", " ", str(x if x is not None else "")).replace("|", "/").strip()


def table(head, rows):
    out = ["| " + " | ".join(cell(h) for h in head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    for r in rows:
        out.append("| " + " | ".join(cell(c) for c in r) + " |")
    return "\n".join(out)


def port():
    p = os.environ.get("PRDOCS_PORT")
    if p and p.isdigit():
        return int(p)
    try:                                              # nur die Zeile PORT = n (wie die apply-Skripte), sonst nichts aus config.py
        with open(os.path.join(BASE, "config.py"), encoding="utf-8", errors="replace") as f:
            for ln in f:
                m = re.match(r"\s*PORT\s*=\s*([0-9]{2,5})\b", ln)
                if m:
                    return int(m.group(1))
    except Exception:
        pass
    return 5000


def http_get(path, timeout=8, maxb=3 * 1024 * 1024):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port(), path), timeout=timeout) as r:
            return r.status, r.read(maxb).decode("utf-8", "replace")
    except Exception as e:
        return 0, str(e)[:120]


# ---------------------------------------------------------------- Sammler ----------------------------------------------------------------
def collect_ast_routes(src):
    """Routen aus dashboard.py ohne Import: @app.route, app.add_url_rule (Literale, Tupel-Schleifen, einfache Namen)."""
    out = {}
    try:
        t = ast.parse(src)
    except Exception as e:
        note("AST dashboard.py: %s" % e)
        return out
    consts = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str):
            for x in n.targets:
                if isinstance(x, ast.Name):
                    consts[x.id] = n.value.value
    parents = {}
    for n in ast.walk(t):
        for c in ast.iter_child_nodes(n):
            parents[id(c)] = n

    def meth(call):
        for k in call.keywords:
            if k.arg == "methods":
                try:
                    return sorted(str(x) for x in ast.literal_eval(k.value))
                except Exception:
                    return ["?"]
        return ["GET"]

    def add(rule, m, fn, how):
        if isinstance(rule, str) and rule.startswith("/"):
            out.setdefault(rule, {"methods": set(), "fn": fn, "how": how})["methods"].update(m)

    for n in ast.walk(t):
        if isinstance(n, ast.FunctionDef):
            for d in n.decorator_list:
                if isinstance(d, ast.Call) and getattr(d.func, "attr", "") == "route" and d.args and isinstance(d.args[0], ast.Constant):
                    add(d.args[0].value, meth(d), n.name, "route")
        if isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "add_url_rule" and n.args:
            a0 = n.args[0]
            fn = ""
            for k in n.keywords:
                if k.arg == "view_func":
                    fn = ast.unparse(k.value)[:60]
            if isinstance(a0, ast.Constant):
                add(a0.value, meth(n), fn, "add_url_rule")
            elif isinstance(a0, ast.Name):
                if a0.id in consts:
                    add(consts[a0.id], meth(n), fn, "add_url_rule")
                    continue
                p = parents.get(id(n))
                while p is not None and not isinstance(p, ast.For):
                    p = parents.get(id(p))
                if p is not None and isinstance(p.target, ast.Tuple) and isinstance(p.iter, (ast.Tuple, ast.List)):
                    names = [e.id if isinstance(e, ast.Name) else None for e in p.target.elts]
                    if a0.id in names:
                        k = names.index(a0.id)
                        for el in p.iter.elts:
                            if isinstance(el, (ast.Tuple, ast.List)) and len(el.elts) > k:
                                v = el.elts[k]
                                m = ["GET"]
                                if "_m" in names or any(x and x.endswith("m") and x != a0.id for x in names):
                                    for j, nm in enumerate(names):
                                        if nm and j != k and j < len(el.elts) and isinstance(el.elts[j], (ast.List, ast.Tuple)):
                                            try:
                                                m = sorted(ast.literal_eval(el.elts[j]))
                                            except Exception:
                                                pass
                                if isinstance(v, ast.Constant):
                                    add(v.value, m, ast.unparse(el.elts[2])[:60] if len(el.elts) > 2 else "", "add_url_rule(Schleife)")
                                elif isinstance(v, ast.Name) and v.id in consts:
                                    add(consts[v.id], m, "", "add_url_rule(Schleife)")
    return out


def collect_routes(dash_src, live=True):
    """Liste (pfad, methoden, endpunkt, quelle). Live: /api/docs/routes des laufenden Dashboards (authoritativ), sonst AST."""
    ast_r = collect_ast_routes(dash_src) if dash_src else {}
    rows, src = [], "ast"
    if live:
        st, body = http_get("/api/docs/routes")
        if st == 200:
            try:
                d = json.loads(body)
                rows = [(r["rule"], ",".join(r.get("methods") or []), r.get("endpoint", ""), "live") for r in d.get("routes", [])]
                src = "live"
            except Exception as e:
                note("Routen live: %s" % e)
        else:
            note("Routen live nicht erreichbar (%s) - nur statisch aus dashboard.py" % str(body)[:80])
    if not rows:
        rows = [(k, ",".join(sorted(v["methods"])), v["fn"], v["how"]) for k, v in sorted(ast_r.items())]
    live_set = {r[0] for r in rows}
    miss = sorted(set(ast_r) - live_set) if src == "live" else []
    return rows, ast_r, src, miss


def page_templates(src):
    """Seiten-Vorlagen PAGE*: Name, Zeilen, statische Kachel-Ueberschriften; Zuordnung Route -> Vorlage per AST (Name im Funktionskoerper)."""
    res, rmap = {}, {}
    try:
        t = ast.parse(src)
        L = src.split("\n")
        for n in t.body:
            if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and re.match(r"PAGE[A-Z0-9_]*$", x.id) for x in n.targets):
                seg = "\n".join(L[n.lineno - 1:n.end_lineno])
                nm = [x.id for x in n.targets if isinstance(x, ast.Name)][0]
                tt = [clean_title(x) for x in re.findall(r'<div class="title"[^>]*>(.*?)</div>', seg, re.S)] + [clean_title(x) for x in re.findall(r"<h[12][^>]*>(.*?)</h[12]>", seg, re.S)]
                res[nm] = {"line": n.lineno, "end": n.end_lineno, "titles": [x for x in tt if x]}
        for n in ast.walk(t):
            if isinstance(n, ast.FunctionDef):
                paths = [d.args[0].value for d in n.decorator_list if isinstance(d, ast.Call) and getattr(d.func, "attr", "") == "route" and d.args and isinstance(d.args[0], ast.Constant)]
                names = {x.id for x in ast.walk(n) if isinstance(x, ast.Name) and x.id in res}
                for pth in paths:
                    rmap.setdefault(pth, set()).update(names)
    except Exception as e:
        note("PAGE-Vorlagen: %s" % e)
    return res, rmap


def clean_title(x):
    x = _html.unescape(re.sub(r"<[^>]+>", " ", x))
    x = re.sub(r"\{\{.*?\}\}|\{%.*?%\}", " ", x)
    x = re.sub(r"\s+", " ", x).strip()
    return x if len(x) >= 3 else ""


_TR = {"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"}
_STATUSW = {"ok", "fehler", "pruefen", "warnung", "gelb", "rot", "gruen", "aus", "an"}


def tr(x):
    x = x.lower()
    for k, v in _TR.items():
        x = x.replace(k, v)
    return x


def alnum(x):
    return " ".join(re.sub(r"[^0-9a-z ]+", " ", tr(x)).split())


def norm_key(x):
    w = []
    for t in alnum(x).split():
        if t in _STATUSW and w:
            break
        w.append(t)
    return " ".join(w[:3])


def live_pages():
    """Server-seitig gerenderte Kachel-Ueberschriften der Seiten (nur GET der festen Seitenliste, wie der Rauchtest)."""
    out = {}
    for p in LIVE_PAGES:
        st, body = http_get(p, timeout=25)
        if st != 200:
            out[p] = None
            continue
        tit = [clean_title(x) for x in re.findall(r'<div class="title"[^>]*>(.*?)</div>', body, re.S)]
        ids = sorted(set(re.findall(r'\bid="([A-Za-z0-9_]+(?:Card|Box|Tile))"', body)))
        out[p] = {"titles": [x for x in tit if x], "ids": ids}
    return out


def static_ids(src):
    ids = set(re.findall(r"""id=\\?["']([A-Za-z][A-Za-z0-9]{3,}(?:Card|Box|Tile|Tile2))\\?["']""", src))
    ids |= set(re.findall(r"""\.id\s*=\s*['"]([A-Za-z][A-Za-z0-9]{3,}(?:Card|Box|Tile))['"]""", src))
    return sorted(ids)


MARK_RE = re.compile(r"^# ===== ([A-Za-z0-9_ ()]+?)(?:: (.*?))?(?: =====)?\s*$")


def collect_markers(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, ln in enumerate(f, 1):
                if ln.startswith("# ===== ") and not ln.startswith("# ===== /"):
                    m = MARK_RE.match(ln.rstrip("\n"))
                    if m:
                        out.append((i, m.group(1).strip(), (m.group(2) or "").strip()))
    except Exception as e:
        note("Marker %s: %s" % (os.path.basename(path), e))
    return out


def project_files():
    rows = []
    try:
        for nm in sorted(os.listdir(BASE)):
            p = os.path.join(BASE, nm)
            if not os.path.isfile(p) or os.path.islink(p):
                continue
            if ".bak" in nm or nm.startswith(".") or nm.endswith((".pyc", ".swp", ".tmp")):
                continue
            rows.append(nm)
    except Exception as e:
        note("Dateiliste: %s" % e)
    return rows


def py_head(p):
    try:
        t = ast.parse(rd(p, limit=4 * 1024 * 1024))
        d = ast.get_docstring(t)
        if d:
            return re.sub(r"\s+", " ", d.strip().splitlines()[0])[:140]
        with open(p, encoding="utf-8", errors="replace") as f:
            for _ in range(6):
                ln = f.readline().strip()
                if ln.startswith("#") and not ln.startswith("#!"):
                    return ln.lstrip("# ").strip()[:140]
    except Exception:
        pass
    return ""


def collect_units():
    """systemd-Units (nur lesend): relevante Namen, Beschreibung, Zustand; Auszug aus show (kein Environment, keine Argumente)."""
    units = {}
    rc, out = run([SYSTEMCTL, "list-unit-files", "--no-legend", "--no-pager", "--type=service,timer,path,socket"])
    if rc == 0:
        for ln in out.splitlines():
            f = ln.split()
            if len(f) >= 2 and UNIT_RE.search(f[0]) and "@" not in f[0]:
                units[f[0]] = {"file": f[1]}
    else:
        note("systemctl list-unit-files nicht lesbar (rc %s)" % rc)
    rc, out = run([SYSTEMCTL, "list-units", "--all", "--no-legend", "--no-pager", "--plain", "--type=service,timer,path,socket"])
    if rc == 0:
        for ln in out.splitlines():
            f = ln.split(None, 4)
            if len(f) >= 4 and UNIT_RE.search(f[0]) and "@" not in f[0]:
                u = units.setdefault(f[0], {"file": "-"})
                u.update({"load": f[1], "active": f[2], "sub": f[3], "desc": f[4].strip() if len(f) > 4 else ""})
    try:                                              # Units mit Verweis auf den Projektordner (auch ohne passenden Namen)
        for nm in os.listdir(UNIT_DIR):
            if nm.endswith((".service", ".timer", ".path", ".socket")) and nm not in units:
                try:
                    if BASE in rd(os.path.join(UNIT_DIR, nm), limit=65536):
                        units[nm] = {"file": "fragment"}
                except Exception:
                    pass
    except Exception as e:
        note("Unit-Ordner: %s" % e)
    for nm, u in sorted(units.items()):
        rc, out = run([SYSTEMCTL, "show", nm, "-p", "Description", "-p", "ExecStart", "-p", "User", "-p", "Restart", "-p", "WatchdogUSec", "-p", "WorkingDirectory", "-p", "FragmentPath", "-p", "DropInPaths", "-p", "Triggers", "-p", "OnCalendar"], timeout=10)
        if rc != 0:
            continue
        for ln in out.splitlines():
            k, _, v = ln.partition("=")
            if k == "ExecStart":
                m = re.search(r"path=(\S+)", v)
                a = re.search(r"argv\[\]=(.*?)(?: ;|$)", v)
                prog = m.group(1) if m else ""
                scr = ""
                if a:
                    for tok in a.group(1).split():
                        if re.search(r"\.(py|sh)$", tok):
                            scr = os.path.basename(tok)
                            break
                u["exec"] = (os.path.basename(prog) + (" " + scr if scr else "")).strip()
            elif k in ("Description", "User", "Restart", "WorkingDirectory", "FragmentPath", "DropInPaths", "Triggers"):
                u[k.lower()] = v.strip()
            elif k == "WatchdogUSec":
                u["wd"] = v.strip()
    return units


def collect_timers():
    rc, out = run([SYSTEMCTL, "list-timers", "--all", "--no-legend", "--no-pager"])
    rows = []
    if rc == 0:
        for ln in out.splitlines():
            m = re.search(r"(\S+\.timer)\s+(\S+\.service)", ln)
            if m and UNIT_RE.search(m.group(1)):
                rows.append((m.group(1), m.group(2)))
    return rows


def collect_external():
    rows = []
    for d in SBIN_DIRS:
        try:
            for nm in sorted(os.listdir(d)):
                if nm.startswith(("prepper", "mesh", "sdr")):
                    p = os.path.join(d, nm)
                    if os.path.isfile(p) and not os.path.islink(p):
                        rows.append((p, sha16(p), nlines(p)))
        except Exception:
            pass
    sud = []
    try:
        for nm in sorted(os.listdir(SUDOERS_DIR)):
            if re.search(r"prepper|mesh|sdr", nm):
                sud.append(nm)
    except Exception as e:
        note("sudoers.d nicht lesbar (nur Namen gebraucht, ok ohne Rechte): %s" % str(e)[:60])
    return rows, sud


def collect_db():
    """Tabellen und Spalten (stabil) + Zeilenzahlen (fluechtig) der SQLite-Datenbank; nur lesend (mode=ro), keine Inhalte."""
    p = os.path.join(BASE, "lagezentrum.db")
    out = {}
    if not os.path.exists(p):
        note("lagezentrum.db nicht vorhanden")
        return out
    try:
        c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=3)
        try:
            for (nm,) in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"):
                cols = [r[1] for r in c.execute('PRAGMA table_info("%s")' % nm.replace('"', ""))]
                try:
                    n = c.execute('SELECT count(*) FROM "%s"' % nm.replace('"', "")).fetchone()[0]
                except Exception:
                    n = None
                out[nm] = (cols, n)
        finally:
            c.close()
    except Exception as e:
        note("lagezentrum.db: %s" % str(e)[:100])
    return out


def collect_patch_history():
    """Patch-Staende aus den Sicherungsdateien *.bak-NAME-JJJJMMTT-HHMMSS (keepLast 3 je Datei -> nur die neueren Patches sichtbar)."""
    seen = {}
    try:
        for nm in os.listdir(BASE):
            m = re.match(r"^(.+?)\.bak-([A-Za-z0-9_]+)-([0-9]{8})-([0-9]{6})$", nm)
            if m:
                k = m.group(2)
                v = (m.group(3), m.group(4))
                e = seen.setdefault(k, {"files": set(), "last": v})
                e["files"].add(m.group(1))
                e["last"] = max(e["last"], v)
    except Exception as e:
        note("Sicherungsdateien: %s" % e)
    return seen


# ------------------------------------------------------------------ Markup ------------------------------------------------------------------
def parse(text):
    """Mini-Markup -> Bloecke. '# '/'## '/'### ' Ueberschriften, '- ' Aufzaehlung ('  - ' zweite Ebene), '|'-Tabellen, ``` Code, Leerzeile trennt Absaetze."""
    B, L, i = [], text.split("\n"), 0
    while i < len(L):
        ln = L[i]
        if ln.startswith("```"):
            j, code = i + 1, []
            while j < len(L) and not L[j].startswith("```"):
                code.append(L[j]); j += 1
            B.append(("code", code)); i = j + 1; continue
        m = re.match(r"^(#{1,3}) (.*)$", ln)
        if m:
            B.append(("h%d" % len(m.group(1)), m.group(2).strip())); i += 1; continue
        if ln.startswith("|"):
            rows = []
            while i < len(L) and L[i].startswith("|"):
                cells = [c.strip() for c in L[i].strip().strip("|").split("|")]
                if not all(re.match(r"^:?-{2,}:?$", c) for c in cells):
                    rows.append(cells)
                i += 1
            B.append(("table", rows)); continue
        if re.match(r"^ {0,2}- ", ln):
            items = []
            while i < len(L) and (re.match(r"^ {0,4}- ", L[i]) or (L[i].startswith("  ") and L[i].strip() and items)):
                if re.match(r"^ {0,4}- ", L[i]):
                    lvl = 1 if L[i].startswith("  ") else 0
                    items.append([lvl, L[i].strip()[2:].strip()])
                else:
                    items[-1][1] += " " + L[i].strip()
                i += 1
            B.append(("ul", items)); continue
        if not ln.strip():
            i += 1; continue
        para = [ln.strip()]
        i += 1
        while i < len(L) and L[i].strip() and not re.match(r"^(#{1,3} |\||```|\s{0,2}- )", L[i]):
            para.append(L[i].strip()); i += 1
        B.append(("p", " ".join(para)))
    return B


def render_txt(B):
    out, h1, h2 = [], 0, 0
    for kind, v in B:
        if kind == "h1":
            h1 += 1; h2 = 0
            out += ["", "=" * WIDTH, "%d. %s" % (h1, v.upper()), "=" * WIDTH]
        elif kind == "h2":
            h2 += 1
            t = "%d.%d %s" % (h1, h2, v)
            out += ["", t, "-" * min(len(t), WIDTH)]
        elif kind == "h3":
            out += ["", "-- %s --" % v]
        elif kind == "p":
            out += [""] + textwrap.wrap(v.replace("`", ""), WIDTH, break_long_words=False, break_on_hyphens=False)
        elif kind == "ul":
            out.append("")
            for lvl, s in v:
                ind = "  " * lvl
                out += textwrap.wrap(s.replace("`", ""), WIDTH, initial_indent=ind + "- ", subsequent_indent=ind + "  ", break_long_words=False, break_on_hyphens=False)
        elif kind == "code":
            out += [""] + ["    " + c for c in v]
        elif kind == "table":
            rows = [[x.replace("`", "") for x in r] for r in v]
            nc = max(len(r) for r in rows)
            rows = [r + [""] * (nc - len(r)) for r in rows]
            w = [min(max(len(r[c]) for r in rows), 34) for c in range(nc)]
            w = [max(x, 4) for x in w]
            w[-1] = min(max(len(r[-1]) for r in rows), max(30, 112 - sum(w[:-1]) - 3 * (nc - 1)))
            if nc == 1:
                w[0] = min(max(len(r[0]) for r in rows), WIDTH)
            out.append("")
            for k, r in enumerate(rows):
                cells = [textwrap.wrap(r[c], w[c], break_long_words=True, break_on_hyphens=False) or [""] for c in range(nc)]
                for ln in range(max(len(x) for x in cells)):
                    out.append(" | ".join((cells[c][ln] if ln < len(cells[c]) else "").ljust(w[c]) for c in range(nc)).rstrip())
                if k == 0:
                    out.append("-+-".join("-" * w[c] for c in range(nc)))
    return "\n".join(out).strip("\n") + "\n"


def render_md(B):
    out, h1, h2 = [], 0, 0
    for kind, v in B:
        if kind == "h1":
            h1 += 1; h2 = 0
            out += ["", "# %d. %s" % (h1, v)]
        elif kind == "h2":
            h2 += 1
            out += ["", "## %d.%d %s" % (h1, h2, v)]
        elif kind == "h3":
            out += ["", "### %s" % v]
        elif kind == "p":
            out += ["", v]
        elif kind == "ul":
            out.append("")
            out += ["%s- %s" % ("  " * lvl, s) for lvl, s in v]
        elif kind == "code":
            out += ["", "```"] + v + ["```"]
        elif kind == "table":
            rows = v
            nc = max(len(r) for r in rows)
            rows = [[cell(c) for c in r] + [""] * (nc - len(r)) for r in rows]
            out.append("")
            out.append("| " + " | ".join(rows[0]) + " |")
            out.append("|" + "|".join("---" for _ in range(nc)) + "|")
            for r in rows[1:]:
                out.append("| " + " | ".join(r) + " |")
    return "\n".join(out).strip("\n") + "\n"


def toc(B):
    out, h1, h2 = [], 0, 0
    for kind, v in B:
        if kind == "h1":
            h1 += 1; h2 = 0
            out.append("%d. %s" % (h1, v))
        elif kind == "h2":
            h2 += 1
            out.append("   %d.%d %s" % (h1, h2, v))
    return out


# --------------------------------------------------------------- Auto-Abschnitte ---------------------------------------------------------------
class Ctx:
    pass


def build_ctx(live=True):
    c = Ctx()
    c.dash_path = os.path.join(BASE, "dashboard.py")
    c.dash_src = rd(c.dash_path) if os.path.exists(c.dash_path) else ""
    if not c.dash_src:
        note("dashboard.py nicht lesbar")
    c.routes, c.ast_routes, c.route_src, c.route_miss = collect_routes(c.dash_src, live)
    c.pages, c.rmap = page_templates(c.dash_src)
    c.live = live_pages() if (live and c.route_src == "live") else {}
    c.ids = static_ids(c.dash_src)
    c.files = project_files()
    c.units = collect_units()
    c.timers = collect_timers()
    c.ext, c.sudo = collect_external()
    c.db = collect_db()
    c.hist = collect_patch_history()
    c.markers = {}
    for nm in ("dashboard.py", "prepper_sdr.py", "sdr_manager.py", "database.py", "mesh_router.py", "lagegeo.py"):
        p = os.path.join(BASE, nm)
        if os.path.exists(p):
            c.markers[nm] = collect_markers(p)
    return c


def a_meta(c, ver, ts):
    host = socket.gethostname()
    return "\n".join(["- Version: v%s (Format JJJJMMTT-HHMM, Berlin-Zeit; identisch in Dateiname, Kachel und diesem Kopf)" % ver,
                      "- Erzeugt: %s (Berlin) von prepper_docs.py (Generator %s) auf dem Host %s, Python %s, %s" % (ts.strftime("%d.%m.%Y %H:%M"), GEN_VERSION, host, platform.python_version(), platform.platform()),
                      "- Routenquelle: %s%s" % ("laufendes Dashboard (/api/docs/routes, authoritativ) + AST-Abgleich" if c.route_src == "live" else "NUR statisch (AST aus dashboard.py) - Dashboard nicht erreichbar oder ohne projDoc",
                                              ("; im Code, aber nicht live registriert: %s" % ", ".join(c.route_miss[:12])) if c.route_miss else ""),
                      "- Diese Datei wird vollautomatisch aus Textkern + Live-Daten erzeugt; Nummern/Hashes/Listen in den Abschnitten 'automatisch' gelten fuer den Zeitpunkt der Erzeugung."])


def route_kind(path, methods):
    if path.startswith("/api/"):
        return "API" + (" (schreibend: POST)" if "POST" in methods else "")
    if "<" in path:
        return "Datei/Bild"
    return "Seite"


def a_routes(c):
    rows = []
    for path, meth, ep, how in sorted(c.routes):
        smoke = "ja" if (path in SMOKE_PAGES or path in SMOKE_APIS) else ""
        rows.append((path, meth, ep, route_kind(path, meth), smoke))
    t = table(["Pfad", "Methoden", "Endpunkt/Funktion", "Art", "Rauchtest"], rows)
    n_api = sum(1 for r in rows if r[3].startswith("API"))
    return "%d Routen (%d Seiten/Dateien, %d APIs); 'Rauchtest = ja' = Teil der 26 Pruefungen jedes apply-Skripts (12 Seiten + 14 APIs, muessen HTTP 200 liefern).\n\n%s" % (len(rows), len(rows) - n_api, n_api, t)


def a_page_map(c):
    rows = []
    for path in sorted(set(r[0] for r in c.routes if "<" not in r[0] and not r[0].startswith("/api/"))):
        tpl = sorted(c.rmap.get(path, []))
        tit = []
        for tp in tpl:
            tit += c.pages.get(tp, {}).get("titles", [])
        lv = c.live.get(path) or {}
        rows.append((path, ", ".join(tpl) or "(Seite wird in einem Patch-Block erzeugt)", "; ".join(dict.fromkeys(tit))[:300] or "-", "; ".join(dict.fromkeys(lv.get("titles", [])))[:300] or "-"))
    return table(["Seite", "Vorlage im Code", "Kachel-Ueberschriften statisch (Vorlage)", "serverseitig beim Lauf gerendert"], rows) + \
        "\n\nHinweis: Viele Kacheln entstehen erst im Browser (JavaScript, z. B. /funk) oder werden von Patch-Bloecken eingefuegt; die redaktionelle Beschreibung der Seiten steht in Kapitel 5."


def a_files(c):
    rows, data = [], []
    for nm in c.files:
        p = os.path.join(BASE, nm)
        if nm == "config.py":
            rows.append((nm, "-", "-", FILE_ROLES.get(nm, "Konfiguration"), "enthaelt Schluessel: Inhalt nie in Beschreibungen/Chats; Hash bewusst nicht aufgefuehrt"))
        elif nm.endswith((".py", ".sh")):
            try:
                rows.append((nm, nlines(p), sha16(p), FILE_ROLES.get(nm) or py_head(p) or "(nicht dokumentiert)", ""))
            except Exception as e:
                note("Datei %s: %s" % (nm, e))
        elif nm.endswith(".db"):
            rows.append((nm, "-", "-", FILE_ROLES.get(nm, "Datenbank"), "Laufzeitdaten, nie ins Repo"))
        else:
            r = FILE_ROLES.get(nm)
            data.append("%s (%s)" % (nm, r) if r else nm)
    out = table(["Datei", "Zeilen", "sha16", "Aufgabe", "Anmerkung"], rows)
    if data:
        out += "\n\nLaufzeit-/Datendateien im Projektordner (Inhalt nicht Teil der Beschreibung; Rotationskopien wie *.json.1 inklusive): " + "; ".join(data) + "."
    return out


def a_dirs(c):
    rows = []
    try:
        for nm in sorted(os.listdir(BASE)):
            p = os.path.join(BASE, nm)
            if os.path.isdir(p) and not os.path.islink(p) and nm not in ("__pycache__", "venv", ".git"):
                try:
                    n = len(os.listdir(p))
                except Exception:
                    n = "?"
                rows.append((nm + "/", n, FILE_ROLES.get(nm + "/", "(nicht dokumentiert)")))
    except Exception as e:
        note("Unterordner: %s" % e)
    return table(["Ordner", "Eintraege", "Aufgabe"], rows)


def a_markers(c):
    parts = []
    for nm, mk in c.markers.items():
        if not mk:
            continue
        parts.append("### %s (%d Schichten)" % (nm, len(mk)))
        parts.append(table(["Zeile", "Schicht/Patch", "Beschreibung (Kopfkommentar, gekuerzt)"], [(i, n, (d[:260] + "...") if len(d) > 260 else d) for i, n, d in mk]))
    return "\n\n".join(parts)


def a_units(c):
    rows = []
    for nm, u in sorted(c.units.items()):
        rows.append((nm, u.get("file", "-"), u.get("description") or u.get("desc") or "", u.get("exec", ""), u.get("user", ""), u.get("restart", ""), u.get("wd", "")))
    t = table(["Unit", "Zustand der Datei", "Beschreibung", "Programm", "User", "Restart", "WatchdogUSec"], rows)
    tm = table(["Timer", "startet"], c.timers) if c.timers else "Keine passenden Timer gefunden (oder systemctl list-timers nicht lesbar)."
    drop = []
    for nm, u in sorted(c.units.items()):
        if u.get("dropinpaths"):
            drop.append((nm, os.path.basename(os.path.dirname(u["dropinpaths"].split()[0])) + "/" + ", ".join(os.path.basename(x) for x in u["dropinpaths"].split())))
    dt = ("\n\nDrop-ins:\n\n" + table(["Unit", "Drop-in"], drop)) if drop else ""
    return "%d relevante Units (Namensfilter prepper|mesh|sdr|gpsd|chrony|kiwix|... oder Verweis auf den Projektordner):\n\n%s\n\nTimer:\n\n%s%s" % (len(c.units), t, tm, dt)


def a_unit_state(c):
    rows = [(nm, u.get("load", "-"), u.get("active", "-"), u.get("sub", "-")) for nm, u in sorted(c.units.items())]
    return table(["Unit", "load", "active", "sub"], rows) if rows else "keine Daten"


def a_db(c):
    if not c.db:
        return "lagezentrum.db nicht lesbar oder nicht vorhanden (siehe Pruefbericht)."
    return table(["Tabelle", "Spalten"], [(k, ", ".join(v[0])) for k, v in sorted(c.db.items())])


def a_db_counts(c):
    return table(["Tabelle", "Zeilen (Zeitpunkt der Erzeugung)"], [(k, v[1]) for k, v in sorted(c.db.items())]) if c.db else "keine Daten"


def a_external(c):
    rows = [(p, n, h) for p, h, n in c.ext]
    t = table(["Pfad", "Zeilen", "sha16"], rows) if rows else "Keine Hilfsprogramme gefunden (Pfade pruefen)."
    s = ("\n\nsudoers.d-Dateien mit Bezug (nur Namen): " + ", ".join(c.sudo)) if c.sudo else "\n\nsudoers.d: keine passenden Dateinamen sichtbar (Verzeichnis nur mit Rechten lesbar) - Regeln stehen laut Patch-Skripten in /etc/sudoers.d/zz-prepper-sdr-wd."
    return t + s


def a_hist(c):
    if not c.hist:
        return "Keine Sicherungsdateien *.bak-NAME-JJJJMMTT-HHMMSS gefunden."
    rows = []
    for k, v in sorted(c.hist.items(), key=lambda kv: kv[1]["last"], reverse=True):
        d, t = v["last"]
        rows.append((k, "%s.%s.%s %s:%s" % (d[6:8], d[4:6], d[0:4], t[0:2], t[2:4]), ", ".join(sorted(v["files"]))))
    return table(["Patch (Name im Sicherungsnamen)", "zuletzt angewendet", "Dateien mit Sicherung"], rows[:40])


def a_ids(c):
    return ", ".join(c.ids) if c.ids else "-"


AUTO = {"routes": a_routes, "pagemap": a_page_map, "files": a_files, "dirs": a_dirs, "markers": a_markers, "units": a_units, "unitstate": a_unit_state,
        "db": a_db, "dbcounts": a_db_counts, "external": a_external, "history": a_hist, "ids": a_ids}
VOLATILE = {"unitstate", "dbcounts", "history", "dirs"}      # aendern sich im Betrieb: zaehlen nicht fuer "neue Version noetig"


# ------------------------------------------------------------------ Validierung ------------------------------------------------------------------
def redact(text):
    """Schwaerzt Auffaelliges: unbekannte IPv4, Schluessel-/Token-Zuweisungen, lange Hex-/Base64-Ketten, E-Mail-Adressen. Gibt (text, funde)."""
    funde = []

    def ip(m):
        if m.group(0) in IP_OK or m.group(0).startswith(("127.", "224.", "0.")):
            return m.group(0)
        funde.append("IP " + m.group(0))
        return "<IP>"
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", ip, text)

    def kv(m):
        funde.append("Zuweisung " + m.group(1))
        return m.group(1) + m.group(2) + "<entfernt>"
    text = re.sub(r"(?i)\b(api[_-]?key|apikey|token|passwort|password|passwd|secret|bearer)(\s*[:=]\s*)(?!<)[^\s,;|]{6,}", kv, text)

    def longs(m):
        funde.append("lange Kette " + m.group(0)[:8] + "...")
        return "<entfernt>"
    text = re.sub(r"\b[A-Fa-f0-9]{33,}\b|\b(?=[A-Za-z0-9+/]*\d)(?=[A-Za-z0-9+/]*[A-Z])(?=[A-Za-z0-9+/]*[a-z])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9+/])", longs, text)

    def mail(m):
        funde.append("E-Mail")
        return "<E-Mail>"
    text = re.sub(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b", mail, text)
    text = re.sub(r"(https?://[^\s\"'<>)]+)\?[^\s\"'<>)]*", lambda m: (funde.append("URL-Parameter " + m.group(1)[:30]) or m.group(1) + "?<entfernt>") if re.search(r"(?i)(key|token|secret|pass)", m.group(0)) else m.group(0), text)
    return text, funde


def covered(core_low, key):
    return key and key in core_low


def validate(c, core_text):
    """Abgleich Code/Live gegen den redaktionellen Text. -> (nachtrag_markup, bericht_zeilen)."""
    low = re.sub(r"\s+", " ", core_text.lower())
    low_n = alnum(core_text)
    rep, nach = [], []
    miss_r = []
    for path, meth, ep, how in c.routes:
        base = path.split("<")[0].rstrip("/") or "/"
        if path in ("/", ) or base == "/":
            continue
        if path.lower() not in low and base.lower() not in low:
            miss_r.append((path, meth, ep))
    rep.append("Routen (%s): %d geprueft, %d im Text, %d als Nachtrag" % (c.route_src, len(c.routes), len(c.routes) - len(miss_r), len(miss_r)))
    if miss_r:
        nach.append("### Routen ohne redaktionelle Beschreibung\n\n" + table(["Pfad", "Methoden", "Endpunkt"], miss_r))
    miss_s = [p for p in SMOKE_PAGES + SMOKE_APIS if p != "/" and p.lower() not in low]
    rep.append("Rauchtest-Liste (12 Seiten + 14 APIs): %d fehlen im Text" % len(miss_s))
    if miss_s:
        nach.append("### Rauchtest-Pfade ohne Beschreibung\n\n" + "\n".join("- " + p for p in miss_s))
    titles = {}
    for tp, v in c.pages.items():
        for t in v["titles"]:
            titles.setdefault(norm_key(t), (t, "Vorlage " + tp))
    for pth, v in c.live.items():
        for t in (v or {}).get("titles", []):
            titles.setdefault(norm_key(t), (t, "Seite " + pth))
    miss_t = [(t, w) for k, (t, w) in titles.items() if k and k not in low_n]
    rep.append("Kachel-Ueberschriften (Vorlagen %d + live %d Seiten): %d geprueft, %d als Nachtrag" % (len(c.pages), len([1 for v in c.live.values() if v]), len(titles), len(miss_t)))
    if miss_t:
        nach.append("### Kacheln ohne redaktionelle Beschreibung\n\n" + table(["Ueberschrift", "gefunden in"], miss_t))
    allids = set(c.ids)
    for v in c.live.values():
        allids |= set((v or {}).get("ids", []))
    miss_i = sorted(i for i in allids if i.lower() not in low)
    rep.append("Kachel-/Box-IDs (HTML/JS): %d geprueft, %d als Nachtrag" % (len(allids), len(miss_i)))
    if miss_i:
        nach.append("### Kachel-IDs ohne redaktionelle Beschreibung\n\n" + ", ".join(miss_i))
    miss_u = sorted(n for n in c.units if n.lower() not in low and n.rsplit(".", 1)[0].lower() not in low)
    rep.append("systemd-Units: %d gefunden, %d als Nachtrag" % (len(c.units), len(miss_u)))
    if miss_u:
        nach.append("### Units ohne redaktionelle Beschreibung\n\n" + table(["Unit", "Beschreibung", "Programm"], [(n, c.units[n].get("description") or c.units[n].get("desc") or "", c.units[n].get("exec", "")) for n in miss_u]))
    pyf = [f for f in c.files if f.endswith((".py", ".sh")) and f != "config.py"]
    miss_f = [f for f in pyf if f.lower() not in low]
    rep.append("Programmdateien (.py/.sh) im Projektordner: %d gefunden, %d als Nachtrag" % (len(pyf), len(miss_f)))
    if miss_f:
        nach.append("### Dateien ohne redaktionelle Beschreibung\n\n" + table(["Datei", "Kopfzeile"], [(f, py_head(os.path.join(BASE, f)) or "(nicht dokumentiert)") for f in miss_f]))
    mk_all = {}
    for nm, mk in c.markers.items():
        for i, n, d in mk:
            mk_all.setdefault(n.split(" ")[0].lower(), (nm, n, d))
    miss_m = [(a, b, d[:160]) for k, (a, b, d) in mk_all.items() if k not in low]
    rep.append("Patch-Schichten (Marker): %d geprueft, %d als Nachtrag" % (len(mk_all), len(miss_m)))
    if miss_m:
        nach.append("### Patch-Schichten ohne redaktionelle Beschreibung\n\n" + table(["Datei", "Schicht", "Kopfkommentar"], miss_m))
    miss_x = [p for p, h, n in c.ext if os.path.basename(p).lower() not in low]
    rep.append("Hilfsprogramme ausserhalb des Projektordners: %d gefunden, %d als Nachtrag" % (len(c.ext), len(miss_x)))
    if miss_x:
        nach.append("### Hilfsprogramme ohne redaktionelle Beschreibung\n\n" + "\n".join("- " + p for p in miss_x))
    return "\n\n".join(nach), rep


def assemble(c, ver, ts, with_nachtrag=True):
    """-> (Bloecke, Hash der stabilen Teile, Bericht, Nachtrag-Anzahl, Schwaerzungen)."""
    parts_stable, parts_all = [], []

    def sub(m):
        nm = m.group(1)
        try:
            body = AUTO[nm](c) if nm != "meta" else a_meta(c, ver, ts)
        except Exception as e:
            note("Auto-Abschnitt %s: %s" % (nm, e))
            body = "(Abschnitt %s konnte nicht erzeugt werden: %s)" % (nm, str(e)[:100])
        parts_all.append(body)
        if nm not in VOLATILE and nm != "meta":
            parts_stable.append(body)
        return body
    core_only = re.sub(r"@@AUTO (\w+)@@", "", CORE)
    text = re.sub(r"@@AUTO (\w+)@@", sub, CORE)

    def fi(m):
        out = []
        for nm in m.group(1).split(";"):
            nm = nm.strip()
            try:
                p = os.path.join(BASE, nm)
                out.append("%s %s/%d" % (nm, sha16(p), nlines(p)) if os.path.isfile(p) and nm != "config.py" else "%s (nicht gefunden)" % nm)
            except Exception as e:
                out.append("%s (Fehler)" % nm)
        r = " ; ".join(out)
        parts_stable.append(r)
        return r
    text = re.sub(r"@@FI ([^@]+)@@", fi, text)
    nach, rep = validate(c, core_only)
    nn = 0
    if nach and with_nachtrag:
        nn = nach.count("### ")
        text += "\n\n# Nachtrag (automatisch erkannt, noch nicht redaktionell beschrieben)\n\nDie folgenden Funde stehen im Code bzw. auf dem laufenden System, sind aber im redaktionellen Text noch nicht beschrieben. Sie sind vollstaendig (aus den Quellen ermittelt), nur ohne Erlaeuterung.\n\n" + nach
    bericht = "\n".join("- " + x for x in rep)
    text = text.replace("@@VALIDATION@@", bericht)
    text, funde = redact(text)
    B = parse(text)
    stable = hashlib.sha256((re.sub(r"@@AUTO \w+@@", "", CORE) + "\n".join(parts_stable) + nach).encode("utf-8")).hexdigest()
    return B, stable, rep, nn, funde


def version_files(d):
    out = {}
    try:
        for nm in os.listdir(d):
            m = re.match(r"^" + re.escape(STEM) + r"([0-9]{8}-[0-9]{4})\.(txt|md)$", nm)
            if m:
                out.setdefault(m.group(1), []).append(nm)
    except Exception:
        pass
    return out


def atomic_write(path, data):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".pd-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


def main(argv):
    keep = KEEP_DEFAULT
    force = "--force" in argv
    check = "--check" in argv
    live = "--no-live" not in argv
    if "--keep" in argv:
        try:
            keep = max(3, int(argv[argv.index("--keep") + 1]))
        except Exception:
            print("--keep braucht eine Zahl"); return 2
    ts = now_berlin()
    ver = ts.strftime("%Y%m%d-%H%M")
    c = build_ctx(live)
    B, stable, rep, nn, funde = assemble(c, ver, ts)
    # Hash der stabilen Teile (ohne Version/Zeit) -> keine neue Version bei unveraendertem Stand
    marker = "Stand-Hash: " + stable[:16]
    last = None
    vf = version_files(DOCS)
    if vf:
        lv = sorted(vf)[-1]
        try:
            lt = rd(os.path.join(DOCS, STEM + lv + ".txt"))
            m = re.search(r"Stand-Hash: ([0-9a-f]{16})", lt)
            last = (lv, m.group(1) if m else None)
        except Exception:
            last = None
    B = [b for b in B]
    toc_lines = toc(B)
    head_txt = ["=" * WIDTH, "PROJEKTBESCHREIBUNG LAGE PI", "=" * WIDTH,
                "Version: v%s (erzeugt %s Uhr, Berlin-Zeit)" % (ver, ts.strftime("%d.%m.%Y %H:%M")),
                "Dateiname: %s%s.txt (Hauptformat; gleicher Inhalt als .md)" % (STEM, ver),
                "Gegenstand: Prepper-Dashboard \"Kaeswasser Lage Monitor\" auf dem Raspberry Pi 4 \"BND-Prepper\" - Projektdokumentation fuer Frank, KIs und neue Entwickler",
                "Erzeugt von: prepper_docs.py (statischer Textkern + automatische Abschnitte aus dem Ist-Stand des Pi, danach Pruefabgleich); Version = JJJJMMTT-HHMM",
                "", "INHALTSVERZEICHNIS", "-" * 18] + toc_lines + [""]
    head_md = ["# Projektbeschreibung Lage Pi", "",
               "- Version: **v%s** (erzeugt %s Uhr, Berlin-Zeit)" % (ver, ts.strftime("%d.%m.%Y %H:%M")),
               "- Dateiname: `%s%s.md` (gleicher Inhalt wie die .txt, die TXT ist das Hauptformat)" % (STEM, ver),
               "- Gegenstand: Prepper-Dashboard \"Kaeswasser Lage Monitor\" auf dem Raspberry Pi 4 \"BND-Prepper\" - Projektdokumentation fuer Frank, KIs und neue Entwickler",
               "- Erzeugt von: `prepper_docs.py` (statischer Textkern + automatische Abschnitte aus dem Ist-Stand, danach Pruefabgleich)", "",
               "## Inhaltsverzeichnis", ""] + ["%s- %s" % ("  " if x.startswith("   ") else "", x.strip()) for x in toc_lines] + [""]
    txt = "\n".join(head_txt) + render_txt(B).replace("@@STANDHASH@@", marker)
    md = "\n".join(head_md) + render_md(B).replace("@@STANDHASH@@", marker)
    rep_txt = ["Pruefbericht prepper_docs.py v%s" % ver] + rep + ["Schwaerzungen: %d%s" % (len(funde), (" (" + "; ".join(funde[:6]) + ")") if funde else "")] + \
              ["Nachtrag-Abschnitte: %d" % nn] + ["Hinweise der Sammler: %d" % len(NOTES)] + ["  - " + x for x in NOTES[:20]]
    print("\n".join(rep_txt))
    print("Groesse TXT %d B, MD %d B, %d Zeilen TXT; Kapitel: %s" % (len(txt.encode()), len(md.encode()), txt.count("\n"), "; ".join(x for x in toc_lines if not x.startswith(" "))))
    if check:
        print("Trockenlauf (--check): nichts geschrieben")
        return 0
    if last and last[1] == stable[:16] and not force:
        print("UNVERAENDERT: Stand-Hash %s wie in v%s - keine neue Version (--force erzwingt eine)" % (last[1], last[0]))
        return 0
    try:
        os.makedirs(DOCS, exist_ok=True)
        for fmt, data in (("txt", txt), ("md", md)):
            atomic_write(os.path.join(DOCS, "%s%s.%s" % (STEM, ver, fmt)), data.encode("utf-8"))
    except Exception as e:
        print("FEHLER beim Schreiben: %s" % e)
        return 1
    vf = version_files(DOCS)
    for old in sorted(vf)[:-keep]:                      # Rotation: nur Dateien mit genau diesem Namensmuster, aeltere als die letzten N Versionen
        for nm in vf[old]:
            try:
                os.unlink(os.path.join(DOCS, nm))
                print("Rotation: %s entfernt (keepLast %d)" % (nm, keep))
            except Exception as e:
                print("Rotation: %s nicht entfernt (%s)" % (nm, e))
    print("OK Version v%s: %s%s.txt (%d B), %s%s.md (%d B) in %s" % (ver, STEM, ver, len(txt.encode()), STEM, ver, len(md.encode()), DOCS))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
APD_EOF
PF="$W/patch-fu.py"; RED="$W/mp_edits.py"; RBLK="$W/mp_block.py"; RGD="$W/guard_meshpost.py"; MPC="$W/mpcheck.py"; PCK="$W/pdcheck.py"; RPD="$W/prepper_docs.py"
for x in "$EXPECT_PF $PF" "$EXPECT_AE $RED" "$EXPECT_ABK $RBLK" "$EXPECT_AGD $RGD" "$EXPECT_AMC $MPC" "$EXPECT_APC $PCK" "$EXPECT_APD $RPD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
for x in "$F" "$PD" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert (projDoc zuerst einspielen: bash /tmp/apply-projdoc.sh commit13)"; exit 1; }; done
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); PD0=$(s16 "$PD")
LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt ); CF16=$( [[ -f "$CF" ]] && s16 "$CF" || echo fehlt )
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $([[ "$D16" == "$KNOWN_D16" ]] && echo "bekannt (projDoc, Basis)" || { [[ "$D16" == "$KNOWN_D16N" ]] && echo "bekannt (meshPost schon drin)" || echo UNBEKANNT; }))"
echo "Basis prepper_docs.py sha16 $PD0 ($(wc -l < "$PD") Zeilen, $([[ "$PD0" == "$KNOWN_PD16O" ]] && echo "bekannt (projDoc, Basis)" || { [[ "$PD0" == "$KNOWN_PD16" ]] && echo "bekannt (meshPost schon drin)" || echo UNBEKANNT; }))"
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, $([[ "$SDR16" == "$KNOWN_SDR16" ]] && echo "bekannt (bleibt)" || echo UNBEKANNT))"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $([[ "$SM16" == "$KNOWN_SM16" ]] && echo "bekannt (bleibt)" || echo UNBEKANNT))"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
[[ "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16 = projDoc oder $KNOWN_D16N = meshPost);"
[[ "$PD0" == "$KNOWN_PD16O" || "$PD0" == "$KNOWN_PD16" ]] || bad="$bad prepper_docs.py (sha16 $PD0, erwartet $KNOWN_PD16O = projDoc oder $KNOWN_PD16 = meshPost);"
[[ "$SDR16" == "$KNOWN_SDR16" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16);"
[[ "$SM16" == "$KNOWN_SM16" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten Stand ab:$bad"
  echo "      meshPost passt nur auf den projDoc-Stand (dashboard $KNOWN_D16, prepper_docs $KNOWN_PD16O, prepper_sdr $KNOWN_SDR16, sdr_manager $KNOWN_SM16) - nichts geaendert. Zuerst projDoc einspielen (bash /tmp/apply-projdoc.sh commit13) oder diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = projDoc (bzw. meshPost schon drin), alle sha16 bekannt"
if [[ "$CF16" == "$KNOWN_CF16" ]]; then echo "OK sdr_config.json sha16 $CF16 (bleibt)"
else echo "HINWEIS sdr_config.json sha16 $CF16 statt $KNOWN_CF16 (andere Arbeitsschritte koennen die Konfiguration angepasst haben) - meshPost fasst die Datei nicht an"; fi
grep -q '# ===== sdrFall:' "$M" || { echo "STOP: sdrFall fehlt in prepper_sdr.py (Basis) - nichts geaendert"; exit 1; }
grep -q '# ===== projDoc:' "$F" && grep -q '# ===== /projDoc =====' "$F" || { echo "STOP: projDoc fehlt im Dashboard (Basis) - nichts geaendert"; exit 1; }
grep -q '# ===== piPolish2:' "$F" && grep -q 'def _pp2_block' "$F" || { echo "STOP: piPolish2 fehlt im Dashboard - nichts geaendert"; exit 1; }
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
SDR_AET0=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
# ---------- 2) Trockenlauf (alles auf Kopien in $W; nichts installiert, nichts gesendet) ----------
cp "$F" "$W/work/dashboard.py"
if [[ "$D16" == "$KNOWN_D16N" ]]; then echo "dashboard.py: meshPost schon drin" > "$W/q.log"
else python3 "$PF" meshPost dsh "$F" "$W/work/dashboard.py" "$RBLK" "$RED" > "$W/q.log" || { cat "$W/q.log"; echo "STOP: dashboard.py meshPost-Stufe passt nicht - nichts geaendert"; exit 1; }
fi
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || { echo "STOP: Ergebnis dashboard.py $ND16 statt $KNOWN_D16N - nichts geaendert"; exit 1; }
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log")); prepper_docs.py $(s16 "$RPD") ($(wc -l < "$RPD") Zeilen)"
[[ "$(s16 "$RPD")" == "$KNOWN_PD16" ]] || { echo "STOP: prepper_docs.py sha16 $(s16 "$RPD") statt $KNOWN_PD16 - nichts geaendert"; exit 1; }
python3 "$PF" meshPost dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBLK" "$RED" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || { echo "STOP: dashboard.py nicht idempotent - nichts geaendert"; exit 1; }
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$RPD" "$RGD" "$MPC" "$PCK"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, prepper_docs.py, Pruefprogramme; $SPY und $VPY)"
if [[ "$D16" == "$KNOWN_D16N" ]]; then
  python3 - "$F" "$RBLK" "$RED" "$W/work/base.py" << 'PYE' || { echo "STOP: Block meshPost nicht sauber entfernbar - nichts geaendert"; exit 1; }
import sys
s = open(sys.argv[1], encoding="utf-8").read(); b = open(sys.argv[2], encoding="utf-8").read().rstrip("\n") + "\n"
g = {}; exec(compile(open(sys.argv[3], encoding="utf-8").read(), sys.argv[3], "exec"), g)
r = s.replace("\n\n" + b.rstrip("\n"), "", 1)
assert r != s
for o, n in g["DSH_EDITS"]:
    assert r.count(n) == 1
    r = r.replace(n, o, 1)
open(sys.argv[4], "w", encoding="utf-8").write(r)
PYE
  [[ "$(s16 "$W/work/base.py")" == "$KNOWN_D16" ]] || { echo "STOP: dashboard.py ohne Block meshPost/Aufruferstellen ist nicht der projDoc-Stand ($(s16 "$W/work/base.py")) - nichts geaendert"; exit 1; }
  GBASE="$W/work/base.py"
else GBASE="$F"; fi
GPY=""
for py in "$VPY" "$SPY"; do "$py" -c "import flask" 2>/dev/null && { GPY="$py"; break; }; done
[[ -n "$GPY" ]] || { echo "STOP: kein Python mit Flask fuer den AST-Guard-Selbsttest - nichts geaendert"; exit 1; }
"$GPY" "$RGD" check "$GBASE" "$W/work/dashboard.py" "$RBLK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; echo "STOP: AST-Guard meshPost - nichts geaendert"; exit 1; }
cat "$W/g.log"
"$GPY" "$RGD" mutate "$RBLK" "$RED" > "$W/gm.log" 2>&1 || { tail -5 "$W/gm.log"; echo "STOP: AST-Guard Mutationstest - nichts geaendert"; exit 1; }
tail -1 "$W/gm.log"
python3 "$MPC" tamper > "$W/pt.log" 2>&1 || { tail -5 "$W/pt.log"; echo "STOP: Pruefprogramm mpcheck Selbsttest - nichts geaendert"; exit 1; }
tail -1 "$W/pt.log"
python3 "$PCK" tamper > "$W/pt2.log" 2>&1 || { tail -5 "$W/pt2.log"; echo "STOP: Pruefprogramm pdcheck Selbsttest - nichts geaendert"; exit 1; }
tail -1 "$W/pt2.log"
python3 "$MPC" callers "$W/work/dashboard.py" > "$W/cl.log" 2>&1 || { cat "$W/cl.log"; echo "STOP: Aufrufer-Pruefung (6 Knoepfe auf POST) - nichts geaendert"; exit 1; }
cat "$W/cl.log"
nbt=0
for py in "$VPY" "$SPY"; do
  "$py" -c "import flask" 2>/dev/null || { echo "HINWEIS Flask fehlt in $py - Block-Test dort entfaellt"; continue; }
  "$py" "$RGD" check "$GBASE" "$W/work/dashboard.py" "$RBLK" "$RED" > "$W/g2.log" 2>&1 || { tail -4 "$W/g2.log"; echo "STOP: AST-Guard ($py) - nichts geaendert"; exit 1; }
  "$py" "$MPC" blocktest "$W/work/dashboard.py" "$RBLK" > "$W/bt.log" 2>&1 || { tail -8 "$W/bt.log"; echo "STOP: Block-Test meshPost ($py) - nichts geaendert"; exit 1; }
  echo "$(tail -1 "$W/bt.log") ($py)"; nbt=$((nbt + 1))
done
[[ "$nbt" -ge 1 ]] || { echo "STOP: kein Python mit Flask fuer den Block-Test - nichts geaendert"; exit 1; }
# Aufrufer-Suche im Projektordner und in den Zeitplaenen (nur Hinweis, nur lesen; Ausgabe: Datei und Pfad, sonst nichts)
echo "Aufrufer-Suche (Hinweis): Dateien im Projektordner ausser dashboard.py/prepper_docs.py/Sicherungen, die die sechs Pfade nennen:"
timeout 60 python3 "$MPC" extscan "$DASH_DIR" 2>/dev/null | tail -25 | sed 's/^/   /' || true
for u in /etc/systemd/system /etc/cron.d /etc/cron.daily /etc/cron.hourly /var/spool/cron/crontabs; do
  grep -rIoE '/api/mesh_(weather|odl|pegel|spaceweather|luft|test|freq)' "$u" 2>/dev/null | sed "s|^|   Zeitplan: |" | head -10 || true
done
crontab -l 2>/dev/null | grep -oE '/api/mesh_(weather|odl|pegel|spaceweather|luft|test|freq)' | sed 's|^|   crontab fmg: |' | head -10 || true
echo "   (TFT-Anzeige, Homescreen-Kachel, Lesezeichen auf Handy/Browser und fremde Geraete lassen sich vom Pi aus nicht pruefen: nicht dokumentiert/zu pruefen. Ein altes GET darauf sendet nicht mehr, es zeigt nur die Vorschau.)"
# Generator in der Sandbox: Kopie der Programmdateien (ohne config.py), Ausgabe nach $W/sbxdocs, kein Zugriff auf das laufende Dashboard (Port 1), nichts gesendet
for x in "$DASH_DIR"/*.py; do [[ "$(basename "$x")" == config.py ]] && continue; cp "$x" "$W/sbx/"; done
cp "$W/work/dashboard.py" "$W/sbx/dashboard.py"; cp "$RPD" "$W/sbx/prepper_docs.py"
PRDOCS_BASE="$W/sbx" PRDOCS_OUT="$W/sbxdocs" PRDOCS_PORT=1 python3 "$W/sbx/prepper_docs.py" > "$W/gen0.log" 2>&1 || { tail -12 "$W/gen0.log"; echo "STOP: Generator in der Sandbox - nichts geaendert"; exit 1; }
python3 "$PCK" docs "$W/sbxdocs" > "$W/gen1.log" 2>&1 || { cat "$W/gen1.log"; echo "STOP: Sandbox-Version der Projektbeschreibung fehlerhaft - nichts geaendert"; exit 1; }
echo "OK Generator-Probelauf in der Sandbox: $(cat "$W/gen1.log")"
SBT=$(ls -1 "$W/sbxdocs"/*.txt | tail -1)
grep -q "X-Mesh-Post" "$SBT" && grep -q "/api/meshpost/status" "$SBT" && ! grep -q "alle sechs sind GET" "$SBT" && ! grep -q "loesen beim Aufruf eine Mesh-Sendung aus (force=True)\. Nie in Tests" "$SBT" || { echo "STOP: Sandbox-Version enthaelt noch den alten Stand (GET sendet) oder nicht den neuen (POST/X-Mesh-Post) - nichts geaendert"; exit 1; }
echo "OK Sandbox-Version beschreibt den neuen Stand (Senden nur per POST, GET = Vorschau, /api/meshpost/status) und nicht mehr 'GET sendet'"
PRDOCS_BASE="$W/sbx" PRDOCS_OUT="$W/sbxdocs" PRDOCS_PORT=1 python3 "$W/sbx/prepper_docs.py" 2>&1 | grep -q "UNVERAENDERT" && echo "OK Generator idempotent (zweiter Lauf: UNVERAENDERT, keine neue Version)" || { echo "STOP: Generator nicht idempotent - nichts geaendert"; exit 1; }
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
SEND6=(/api/mesh_weather /api/mesh_odl /api/mesh_pegel /api/mesh_spaceweather /api/mesh_luft /api/mesh_test)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
echo "(die sechs Sende-Wege werden nie aufgerufen, weder GET noch POST - Pruefung nur ueber /api/meshpost/status und /api/docs/routes)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
[[ "$R0" -ge 1 ]] || { echo "STOP: /pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - nichts geaendert"; exit 1; }
# SQLite-Sicherung (nur lesend gelesen, Kopie ueber die Backup-Schnittstelle) - vor jeder Aenderung
NEED_D=0; NEED_P=0
cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
cmp -s "$RPD" "$PD" 2>/dev/null || NEED_P=1
LZB=""
if [[ -f "$LZ" && ( "$NEED_D" == 1 || "$NEED_P" == 1 ) ]]; then
  LZB="$LZ.bak-meshpost-$TS"
  python3 - "$LZ" "$LZB" << 'PYE' || { rm -f "$LZB"; echo "STOP: SQLite-Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=20)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
n = dst.execute("PRAGMA integrity_check").fetchone()[0]
assert n == "ok", n
dst.close(); src.close()
PYE
  { ls -1t "$LZ.bak-meshpost-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  echo "OK SQLite-Sicherung $(basename "$LZB") ($(wc -c < "$LZB") Bytes, integrity_check ok), behalten: letzte $KEEP_LAST"
fi
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert); nur dashboard.py + prepper_docs.py + docs/, nur Neustart prepper-dashboard ----------
trap '' INT
RESTARTED=0
ls -1 "$DOCS" 2>/dev/null | sort > "$W/docs0.txt" || true
DOCS_EXISTED=0; [[ -d "$DOCS" ]] && DOCS_EXISTED=1
rb() {
  set +e +o pipefail
  echo "ROLLBACK: $1"
  sudo journalctl -u prepper-dashboard --since "@${T0:-0}" --no-pager -o cat 2>/dev/null | grep -E "meshPost|Traceback" | tail -4 | cut -c1-200 || true
  if [[ -f "$F.bak-meshpost-$TS" ]]; then cp -a "$F.bak-meshpost-$TS" "$F.rb" && mv -f "$F.rb" "$F"; fi
  if [[ -f "$PD.bak-meshpost-$TS" ]]; then cp -a "$PD.bak-meshpost-$TS" "$PD.rb" && mv -f "$PD.rb" "$PD"; fi
  if [[ -d "$DOCS" ]]; then
    ls -1 "$DOCS" | sort > "$W/docs1.txt"
    comm -13 "$W/docs0.txt" "$W/docs1.txt" | grep -E '^Projektbeschreibung Lage Pi v[0-9]{8}-[0-9]{4}\.(txt|md)$' | while read -r o; do rm -f -- "$DOCS/$o"; done
    [[ "$DOCS_EXISTED" == 0 ]] && rmdir "$DOCS" 2>/dev/null || true
  fi
  if [[ "$RESTARTED" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-meshpost-$TS" ]] && { cmp -s "$F" "$F.bak-meshpost-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  [[ -f "$PD.bak-meshpost-$TS" ]] && { cmp -s "$PD" "$PD.bak-meshpost-$TS" && echo "  prepper_docs.py = Sicherung ($(s16 "$PD"))" || echo "  WARNUNG prepper_docs.py ungleich Sicherung"; }
  echo "  SQLite-Sicherung (nicht zurueckgespielt, Datenbank wurde nicht veraendert): ${LZB:-keine}"
  echo "alter Stand (projDoc) wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), HTTP / = $(code "$B/")"
}
T0=$(date +%s)
if [[ "$NEED_D" == 0 && "$NEED_P" == 0 ]]; then
  echo "OK meshPost schon installiert (dashboard.py, prepper_docs.py) - kein Neustart, keine Aenderung der Programme"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  [[ "$NEED_D" == 1 ]] && RESTARTED=1
  [[ "$RESTARTED" == 1 ]] && sudo -v
  for x in "$F" "$PD"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-meshpost-$TS"
    { ls -1t "$x.bak-meshpost-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  mkdir -p "$DOCS" || { rb "docs/ nicht anlegbar"; exit 1; }
  if [[ "$NEED_P" == 1 ]]; then
    cp "$RPD" "$PD.new" && chmod --reference="$PD.bak-meshpost-$TS" "$PD.new" && mv -f "$PD.new" "$PD" || { rb "installieren prepper_docs.py"; exit 1; }
  fi
  if [[ "$NEED_D" == 1 ]]; then
    cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-meshpost-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard.py"; exit 1; }
    echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'meshPost aktiv' im Journal ..."
    sudo systemctl restart prepper-dashboard.service
    ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
    [[ "$ok" == 1 ]] || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
  fi
fi
rbx() { if [[ "$RESTARTED" == 1 || "$NEED_P" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# Nach dem Neustart zeigt das Dashboard erst eine Startseite ("Dashboard startet"), bis das erste Voll-Update da ist (bis ca. 2 min). Die neue Version der Beschreibung soll ein fertig gestartetes Dashboard sehen (Kachel-Ueberschriften live), sonst waere sie duenner und ein erneuter Lauf gaebe eine weitere Version.
rdy=0
for i in $(seq 1 40); do
  ok2=1; for p in /umwelt /energie /; do "${CURL[@]}" "$B$p" -o "$W/pg.html" || true; grep -q "<title>Dashboard startet" "$W/pg.html" && ok2=0; done
  [[ "$ok2" == 1 ]] && { rdy=1; break; }
  [[ "$RESTARTED" == 1 ]] || { rdy=1; break; }
  sleep 5
done
[[ "$rdy" == 1 ]] && echo "OK Dashboard fertig gestartet (erstes Voll-Update da)" || echo "HINWEIS Dashboard zeigt nach 200 s noch die Startseite - die Version wird trotzdem erzeugt (Kachel-Ueberschriften live teilweise leer)"
# ---------- 4) Version erzeugen (prepper_docs.py, liest nur: AST, systemctl-Lesebefehle, ls, GET auf die eigenen Seiten) ----------
(cd "$DASH_DIR" && PRDOCS_BASE="$DASH_DIR" PRDOCS_OUT="$DOCS" PRDOCS_PORT="$PORT" "$SPY" "$PD" > "$W/gen.log" 2>&1) || { tail -15 "$W/gen.log"; rbx "prepper_docs.py meldet einen Fehler"; }
grep -E "^(OK Version|UNVERAENDERT)" "$W/gen.log" | cut -c1-260
VER_LINE=$(grep -E "^OK Version|^UNVERAENDERT" "$W/gen.log" | tail -1 || true)
[[ -n "$VER_LINE" ]] || { tail -10 "$W/gen.log"; rbx "prepper_docs.py: weder neue Version noch UNVERAENDERT gemeldet"; }
python3 "$PCK" docs "$DOCS" > "$W/pd.log" 2>&1 && echo "OK $(cat "$W/pd.log")" || { cat "$W/pd.log"; rbx "docs/: Projektbeschreibung unvollstaendig oder mit Schluessel-Muster"; }
sed -n '/^Pruefbericht/,/^Nachtrag-Abschnitte/p' "$W/gen.log" | cut -c1-200 | sed 's/^/   /'
# ---------- 5) Rauchtest (nur GET auf lesende Seiten/APIs; die sechs Sende-Wege nie) ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist /karte /api/sdr/wd /api/sdr/ui /api/t2/status /api/t4/status /api/t4/tii /api/br24 /api/meshpost/status /api/docs/list; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x doPrepperRestore wie vorher)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$PCK" pi "$W/pi.html" "$DOCS" > "$W/pi.log" 2>&1 && echo "OK $(cat "$W/pi.log")" || { cat "$W/pi.log"; rbx "/pi: Kachel Projektbeschreibung Lage Pi"; }
# Knoepfe: die Seiten liefern die sechs Aufrufer nur noch als POST mit X-Mesh-Post (nur Seitentext lesen, nichts ausloesen). Nach dem Neustart zeigt das Dashboard erst eine Startseite ("Dashboard startet"), bis das erste Voll-Update da ist (bis ca. 2 min)
sx=0; gold=0
for p in / /umwelt /luft /pegel /mesh /funk /pi; do
  "${CURL[@]}" "$B$p" -o "$W/pg.html" || true
  g=$(grep -cE "fetch\((\"|')/api/mesh_(weather|odl|pegel|spaceweather|luft)(\"|')[^,]" "$W/pg.html" || true); gold=$((gold + ${g:-0}))
  [[ "$p" == / || "$p" == /umwelt || "$p" == /luft || "$p" == /pegel ]] && sx=$((sx + $(grep -o "X-Mesh-Post" "$W/pg.html" | wc -l || true)))
done
[[ "$gold" == 0 ]] || rbx "eine Seite ruft noch eine Sende-Route per GET auf ($gold Stellen)"
if [[ "$rdy" == 1 && "$sx" -ge 6 ]]; then echo "OK Seiten / (NINA-Test), /umwelt (Sonne, ODL, Wetter), /luft, /pegel: ${sx}x X-Mesh-Post in den Knopf-Aufrufen, kein GET-Aufruf einer Sende-Route"
else echo "HINWEIS Seitenpruefung: Dashboard fertig=${rdy}, X-Mesh-Post auf den Seiten ${sx}x (erwartet 6: / 1, /umwelt 3, /luft 1, /pegel 1); die Quellpruefung 'callers' oben ist massgebend, ein GET-Aufruf einer Sende-Route wurde nicht gefunden"; fi
"${CURL[@]}" "$B/api/meshpost/status" -o "$W/mps.json" || true
python3 "$MPC" status "$W/mps.json" > "$W/mps.log" 2>&1 && echo "OK $(cat "$W/mps.log")" || { cat "$W/mps.log"; rbx "/api/meshpost/status: Sende-Wege nicht geschuetzt"; }
"${CURL[@]}" "$B/api/docs/list" -o "$W/dl_list.json" || true
python3 "$PCK" list "$W/dl_list.json" "$DOCS" > "$W/pl.log" 2>&1 && echo "OK $(cat "$W/pl.log")" || { cat "$W/pl.log"; rbx "/api/docs/list"; }
for fmt in txt md; do
  for v in "" "$(python3 -c "import json;print(json.load(open('$W/dl_list.json'))['current'])")"; do
    curl -s --connect-timeout 3 --max-time 40 -D "$W/dl.hdr" -o "$W/dl.body" "$B/api/docs/download?fmt=$fmt&v=$v" || true
    python3 "$PCK" dl "$W/dl.hdr" "$W/dl.body" "$DOCS" "$v" "$fmt" > "$W/pdl.log" 2>&1 && echo "OK $(cat "$W/pdl.log")$([[ -z "$v" ]] && echo " (ohne Versionsangabe = neueste)")" || { cat "$W/pdl.log"; rbx "/api/docs/download fmt=$fmt v=$v"; }
  done
done
for q in "v=../../etc/passwd" "v=..%2f..%2fetc%2fpasswd" "v=20261024-1830/../../x" "fmt=exe" "fmt=txt/../x" "fmt=txt&v=config"; do
  c=$(code "$B/api/docs/download?$q"); [[ "$c" == 400 || "$c" == 404 ]] || rbx "Pfad-Traversal/Format-Test $q wurde nicht abgewiesen (HTTP $c)"
done
echo "OK Download: 6 Pfad-Traversal-/Format-Versuche abgewiesen (HTTP 400/404), nur Dateien mit Versionsnamen aus docs/"
"${CURL[@]}" "$B/api/docs/routes" -o "$W/dr.json" || true
python3 "$PCK" routes "$W/dr.json" "${PAGES[@]}" "${APIS[@]}" /api/docs/list /api/docs/download /api/docs/routes /api/meshpost/status "${SEND6[@]}" > "$W/pr.log" 2>&1 && echo "OK $(cat "$W/pr.log")" || { cat "$W/pr.log"; rbx "/api/docs/routes"; }
python3 "$MPC" routes "$W/dr.json" > "$W/pr2.log" 2>&1 && echo "OK $(cat "$W/pr2.log")" || { cat "$W/pr2.log"; rbx "/api/docs/routes: Sende-Wege ohne POST"; }
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
SDR_AET1=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
[[ "$SDR_AET1" == "$SDR_AET0" ]] && echo "OK prepper-sdr nicht neu gestartet (Start $SDR_AET1)" || rbx "prepper-sdr wurde neu gestartet ($SDR_AET0 -> $SDR_AET1)"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JA=$(echo "$JD" | grep -F "meshPost aktiv: meshPost selftest ok" | tail -1 || true)
  [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-230)" || rbx "Journal prepper-dashboard ohne 'meshPost aktiv: meshPost selftest ok'"
fi
E2=$(echo "$JD" | grep -c -E "Traceback|meshPost FEHLER|projDoc (FEHLER|Liste:|Download:|/pi:)" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/meshPost-Fehler" || { echo "$JD" | grep -E "Traceback|meshPost FEHLER|projDoc (FEHLER|Liste:|Download:|/pi:)" | head -5 | cut -c1-240; rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"; }
NS=$(echo "$JD" | grep -c "meshPost: POST " || true)
[[ "${NS:-0}" == 0 ]] && echo "OK Journal: seit Neustart kein POST auf die sechs Sende-Wege (der Patch und sein Test haben nichts gesendet)" || echo "HINWEIS Journal: ${NS}x 'meshPost: POST' seit Neustart (ein Knopf wurde auf einer Seite gedrueckt - nicht vom Patch)"
for x in "$SMF:$SM16" "$DBF:$DB16" "$MR:$MR16" "$M:$SDR16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ ! -f "$CF" || "$(s16 "$CF")" == "$CF16" ]] && echo "OK sdr_config.json unveraendert ($CF16)" || rbx "sdr_config.json hat sich veraendert"
echo "OK guards meshPost(dash)=$(grep -c '# ===== meshPost:' "$F" || true) meshPost-Ende=$(grep -c '# ===== /meshPost =====' "$F" || true) projDoc=$(grep -c '# ===== projDoc:' "$F" || true) piPolish2=$(grep -c '# ===== piPolish2:' "$F" || true) sdrFall(sdr)=$(grep -c '# ===== sdrFall:' "$M" || true) X-Mesh-Post(dash)=$(grep -o 'X-Mesh-Post' "$F" | wc -l || true)"
[[ -f "$F.bak-meshpost-$TS" ]] && echo "Backups: *.bak-meshpost-$TS (dashboard.py$([[ -f "$PD.bak-meshpost-$TS" ]] && echo ", prepper_docs.py")), SQLite: ${LZB:+$(basename "$LZB")}, behalten: letzte $KEEP_LAST"
for x in "$F" "$PD" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
VNEW=$(python3 -c "import json;print(json.load(open('$W/dl_list.json'))['current'])")
echo "docs/ (neueste Version v$VNEW; aeltere Versionen bleiben):"
for x in "$DOCS/Projektbeschreibung Lage Pi v$VNEW.txt" "$DOCS/Projektbeschreibung Lage Pi v$VNEW.md"; do echo "  $(basename "$x") sha256 $(sha256sum "$x" | cut -d' ' -f1), $(wc -c < "$x") Bytes, $(wc -l < "$x") Zeilen"; done
if [[ -f "$F.bak-meshpost-$TS" ]]; then echo "Rueckweg: dashboard.py.bak-meshpost-$TS (und prepper_docs.py.bak-meshpost-$TS) zurueckkopieren, dann sudo systemctl restart prepper-dashboard (docs/ stoert nicht)"
else LB=$({ ls -1t "$F.bak-meshpost-"* 2>/dev/null || true; } | head -1); [[ -n "$LB" ]] && echo "Rueckweg (neueste meshPost-Sicherung: $(basename "$LB")): zurueckkopieren, dann sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine meshPost-Sicherung vorhanden (nichts geaendert)"; fi
echo "Neue Version spaeter: cd $DASH_DIR && python3 prepper_docs.py (erzeugt nur bei geaendertem Stand eine neue Version, --force erzwingt, behaelt die letzten 10)"
echo "meshPost: GET auf /api/mesh_weather, /api/mesh_odl, /api/mesh_pegel, /api/mesh_spaceweather, /api/mesh_luft = Vorschau ohne Senden, /api/mesh_test GET = 405; Senden nur per POST von der Seite (Knopf); gesendet wurde nichts (kein Mesh, kein Telegram, keine Alarme); Sticks/Planer/Watchdog/Gain/Dienste ausser prepper-dashboard unveraendert"
echo "COMMIT $COMMIT_ARG meshpost=1 fertig"
