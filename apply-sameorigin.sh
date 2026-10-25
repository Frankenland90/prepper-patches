#!/bin/bash
set -eEuo pipefail
# sameOrigin (commit28): zentrale Herkunftspruefung fuer alle Aendern-Anfragen (SEC-05 + MOD-09), nur dashboard.py. Sendet nichts (kein Mesh, kein Telegram, keine Alarme), keine Anzeige, keine Sende-/Alarm-/Abruflogik.
#  Befund: Nur 11 der 32 POST-Routen pruefen die Herkunft (fuenf Kopien der Pruefung). /api/backup, /api/backup/restore, /api/clone/start, /api/mesh_send, /api/mesh2_send, /api/mesh_hold, /api/mesh_resume, /api/mesh2_hold, /api/mesh2_resume,
#   /api/sdr/mode, /api/sdr/preset, /api/sdr/release, /api/sources/update, /api/speedtest u. a. liessen sich von jeder fremden Webseite im Browser eines Nutzers im LAN ausloesen (CSRF).
#  A) require_same_origin (eine gemeinsame Pruefung, MOD-09): die fuenf bisherigen Kopien (_lm1_, _sl_, _stk_, _t2d_, _mp_same_origin) rufen sie auf - Ergebnis fuer jede Kopf-Kombination unveraendert (Differenztest alt/neu).
#  B) before_request-Hook als ERSTE Funktion: jede Anfrage ausser GET/HEAD/OPTIONS braucht Origin = eigene Seite (oder passenden Referer) und, falls gesendet, Sec-Fetch-Site = same-origin; sonst 403 (JSON), bevor eine Route laeuft.
#     Ausnahme: Anfragen vom Pi selbst (127.0.0.1/::1) ganz ohne Origin/Referer/Sec-Fetch-Site (curl, Skripte). Anfragen aus dem LAN ohne Herkunft werden abgelehnt. Kein PIN. Sende-Routen bleiben POST-only.
#     Bewusst NICHT verlangt (konservativ): Pflichtkopf/JSON fuer die bisher ungeschuetzten Routen (mehrere Seiten senden ihn nicht; sonst gaebe es 403 am Knopf). Die fuenf alten Pruefungen bleiben zusaetzlich bestehen.
#  Basis streng (sha16): dashboard.py 08fbc3e35940faab (Stand nach perfKeep commit27) oder sameOrigin schon drin. Andere Dateien werden nicht angefasst (nur vorher/nachher-Vergleich).
#  Neustart: nur prepper-dashboard. Sicherung: dashboard.py.bak-sameorigin-ZEIT (letzte 3). Keine Datenbank-Aenderung (daher keine SQLite-Sicherung). Keine neue Docs-Version (nur dashboard.py; Text fuer die naechste Docs-Version liegt beim Bericht).
# Aufruf: bash /tmp/apply-sameorigin.sh commit28 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sameorigin-apply
KEEP_LAST=3
KNOWN_D16="08fbc3e35940faab"      # dashboard.py vor sameOrigin (Basis = Stand nach perfKeep commit27)
KNOWN_D16N="4937aa9db3e4f3e4"             # dashboard.py nach sameOrigin (Ziel)
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
echo "=== sameOrigin apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Herkunftspruefung fuer alle Aendern-Anfragen, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PSO="346005b6fc0e004c6d3427e36845298dfd93be45460b09583fd67a1028950007"
cat > "$W/patch-so.py" << 'SO_PSO_EOF'
"""Patcher sameOrigin. Aufruf: patch-pk.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
SO_PSO_EOF
EXPECT_RED="5fc8284d6092de844d5f85bfe2b0197e89ab089f0ca6a393ae1668cf304438df"
cat > "$W/edits_so.py" << 'SO_RED_EOF'
# sameOrigin (commit28): Stellen (alt, neu) fuer dashboard.py. Jede alte Stelle genau einmal. MOD-09: eine gemeinsame Pruefung, die fuenf Kopien rufen sie mit unveraendertem Ergebnis auf.
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
_CORE = '''    base = rq.host_url.rstrip("/")
    o = rq.headers.get("Origin")
    if o is not None and o.rstrip("/") != base:
        return False
    ref = rq.headers.get("Referer") or ""
    if o is None and not (ref == base or ref.startswith(base + "/")):
        return False
    sfs = rq.headers.get("Sec-Fetch-Site")
    if sfs is not None and sfs != "same-origin":
        return False
'''


def _copy(prefix, hdr, doc=""):
    old = "def %s_same_origin(rq):\n%s%s    return rq.headers.get(\"%s\") == \"1\" and (rq.mimetype or \"\") == \"application/json\"\n" % (prefix, doc, _CORE, hdr)
    new = "def %s_same_origin(rq):\n%s    return require_same_origin(rq, \"%s\", True)  # sameOrigin (MOD-09): gemeinsame Pruefung, Ergebnis wie bisher\n" % (prefix, doc, hdr)
    return old, new


_MPDOC = '    """Gleiche Herkunftspruefung wie beim Knopf \'An Mesh 1 senden\' (_lm1_same_origin): Origin/Referer/Sec-Fetch-Site muessen die eigene Seite sein, dazu Kopf X-Mesh-Post: 1 und JSON."""\n'
_COMMON = '''def _so_origin_ok(rq):
    """sameOrigin (SEC-05/MOD-09): Herkunft der Anfrage ist die eigene Seite. Origin (falls gesendet) = eigener Ursprung, sonst Referer = eigene Seite; Sec-Fetch-Site (falls gesendet) = same-origin. Ohne Origin und ohne passenden Referer: nein."""
''' + _CORE + '''    return True


def require_same_origin(rq, header=None, need_json=False):
    """sameOrigin (MOD-09): gemeinsame Pruefung; optional Pflichtkopf (Wert 1) und JSON-Inhalt. Die fuenf Schichten (_lm1_, _sl_, _stk_, _t2d_, _mp_same_origin) rufen sie mit ihrem Kopf und need_json=True auf."""
    if not _so_origin_ok(rq):
        return False
    if header is not None and rq.headers.get(header) != "1":
        return False
    if need_json and (rq.mimetype or "") != "application/json":
        return False
    return True


'''
_o, _n = _copy("_lm1", "X-Lage-Mesh1")
DSH_EDITS = [
    (_o, _COMMON + _n),
    _copy("_sl", "X-SDR-Lage"),
    _copy("_stk", "X-Stick-Test"),
    _copy("_t2d", "X-T2"),
    _copy("_mp", "X-Mesh-Post", _MPDOC),
]
SO_RED_EOF
EXPECT_RBK="3a3f885b07407fc4d3c35f5b9d5273f94c6e5c794387d66f0dbe00975f621002"
cat > "$W/blk_so.py" << 'SO_RBK_EOF'
# ===== sameOrigin: zentrale Herkunftspruefung fuer alle Aendern-Anfragen (POST usw.), SEC-05/MOD-09; keine Sende-, Alarm- oder Abruflogik, keine Anzeige =====
_SO_STAT = {"denied": 0, "last_log": {}, "quiet": False}
_SO_LOG_GAP = 30.0


def _so_loopback(addr):
    """True nur fuer Anfragen vom Pi selbst (127.0.0.0/8, ::1, ::ffff:127.x)."""
    try:
        import ipaddress
        ip = ipaddress.ip_address((addr or "").strip())
        if getattr(ip, "ipv4_mapped", None) is not None:
            ip = ip.ipv4_mapped
        return bool(ip.is_loopback)
    except Exception:
        return False


def _so_allowed(rq):
    """Entscheidung ohne Nebenwirkung. Erlaubt: Anfrage von der eigenen Seite (Origin/Referer/Sec-Fetch-Site) ODER vom Pi selbst (loopback) ohne jeden Browser-Kopf (curl, Skripte). Alles andere (fremde Seite, Anfrage aus dem LAN ohne Herkunft) wird abgelehnt."""
    try:
        if _so_origin_ok(rq):
            return True
        if not (rq.headers.get("Origin") or rq.headers.get("Referer") or rq.headers.get("Sec-Fetch-Site")) and _so_loopback(rq.remote_addr):
            return True
    except Exception:
        return False
    return False


def _so_guard():
    """before_request (als erste): alles ausser GET/HEAD/OPTIONS braucht eine passende Herkunft; sonst 403, bevor irgendeine Route laeuft."""
    from flask import request as rq, jsonify
    if rq.method in ("GET", "HEAD", "OPTIONS"):
        return None
    if _so_allowed(rq):
        return None
    _SO_STAT["denied"] += 1
    try:
        now = time.monotonic()
        lg = _SO_STAT["last_log"]
        k = rq.path[:80]
        if not _SO_STAT["quiet"] and now - lg.get(k, -1e9) >= _SO_LOG_GAP:
            if len(lg) > 64:
                lg.clear()
            lg[k] = now
            print("sameOrigin: %s %s abgelehnt (Origin=%s, Sec-Fetch-Site=%s, von %s)" % (rq.method, k, (rq.headers.get("Origin") or "-")[:60].encode("ascii", "replace").decode(), (rq.headers.get("Sec-Fetch-Site") or "-")[:20].encode("ascii", "replace").decode(), (rq.remote_addr or "?")[:45]), flush=True)
    except Exception:
        pass
    r = jsonify({"ok": False, "error": "abgelehnt: nur von der eigenen Dashboard-Seite erlaubt (Herkunftspruefung)"})
    r.status_code = 403
    r.headers["Cache-Control"] = "no-store"
    return r


def _so_install(flask_app):
    """Haengt _so_guard als ERSTE before_request-Funktion ein (einmalig). Rueckgabe True = neu eingehaengt."""
    if getattr(flask_app, "_so_installed", False):
        return False
    flask_app.before_request_funcs.setdefault(None, []).insert(0, _so_guard)
    flask_app._so_installed = True
    return True


def _selftest_sameorigin():
    """Eigene kleine Flask-App (nicht die echte): prueft Hook, Reihenfolge und Entscheidungen; sendet nichts, schreibt nichts."""
    from flask import Flask
    t = Flask("so_selftest")
    hits = []

    @t.route("/p", methods=["POST"])
    def _p():
        hits.append(1)
        return "ok"

    @t.route("/g")
    def _g():
        return "g"
    first = []
    t.before_request(lambda: first.append(1))
    assert _so_install(t) is True and _so_install(t) is False, "Hook nicht genau einmal eingehaengt"
    assert t.before_request_funcs[None][0] is _so_guard, "Hook ist nicht die erste before_request-Funktion"
    c = t.test_client()
    base = "http://localhost"
    ok_o = {"Origin": base}
    assert c.get("/g").status_code == 200 and c.get("/g", headers={"Origin": "http://evil.example"}).status_code == 200, "GET darf nie blockiert werden"
    assert c.post("/p", headers=ok_o).status_code == 200 and hits, "gleiche Herkunft muss durchgehen"
    del hits[:]
    del first[:]
    n0 = _SO_STAT["denied"]
    for h in ({"Origin": "http://evil.example"}, {"Origin": "null"}, {"Origin": "http://localhost.evil.example"}, {"Referer": "http://evil.example/x"},
              {"Referer": "http://localhost.evil.example/x"}, {"Origin": base, "Sec-Fetch-Site": "cross-site"}, {"Sec-Fetch-Site": "cross-site"}, {"Origin": "https://localhost"}):
        r = c.post("/p", headers=h)
        assert r.status_code == 403 and r.get_json().get("ok") is False and not hits and not first, "fremde Herkunft nicht abgelehnt: %s" % h
    assert _SO_STAT["denied"] - n0 == 8
    assert c.post("/p", headers={"Referer": base + "/pi"}).status_code == 200, "eigener Referer ohne Origin muss durchgehen"
    assert c.post("/p", environ_overrides={"REMOTE_ADDR": "127.0.0.1"}).status_code == 200, "Pi selbst ohne Kopf muss durchgehen"
    assert c.post("/p", environ_overrides={"REMOTE_ADDR": "::1"}).status_code == 200
    assert c.post("/p", environ_overrides={"REMOTE_ADDR": "192.168.1.20"}).status_code == 403, "LAN ohne Herkunft muss abgelehnt werden"
    assert c.post("/p", headers={"Origin": "http://evil.example"}, environ_overrides={"REMOTE_ADDR": "127.0.0.1"}).status_code == 403, "fremde Herkunft auch vom Pi aus abgelehnt"
    assert c.put("/p", headers={"Origin": "http://evil.example"}).status_code == 403 and c.delete("/p", headers={"Origin": "http://evil.example"}).status_code == 403
    assert c.post("/unbekannt", headers={"Origin": "http://evil.example"}).status_code == 403
    assert not _so_loopback("192.168.1.1") and not _so_loopback("") and not _so_loopback(None) and _so_loopback("::ffff:127.0.0.1") and not _so_loopback("::ffff:10.0.0.1")
    return "sameOrigin ok (fremde Herkunft -> 403 vor jeder Route, eigene Seite und Pi selbst erlaubt, GET unberuehrt)"


try:
    _SO_STAT["quiet"] = True
    try:
        _SOG = {"selftest": _selftest_sameorigin()}
    finally:
        _SO_STAT["quiet"] = False
        _SO_STAT["denied"] = 0
        _SO_STAT["last_log"].clear()
    _SOG["installiert"] = _so_install(app)
    print("sameOrigin aktiv: %s" % _SOG["selftest"], flush=True)
except Exception as _so_e:
    _SOG = {"selftest": "FEHLER %s" % _so_e}
    print("sameOrigin Selbsttest FEHLER (Schutz NICHT aktiv):", _so_e, flush=True)
SO_RBK_EOF
EXPECT_RGD="b4d0061d136a13dcd845bf3d14ff101de5434e181b151ca14877a6ddd3ca69c5"
cat > "$W/guard_so.py" << 'SO_RGD_EOF'
"""AST-Guard sameOrigin (nur dashboard.py). Aufruf:
  guard_so.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne sameOrigin (Rueckbau, byte-genau)
  guard_so.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhalten in der Sandbox (Differenztest alt/neu der fuenf Pruefungen, Hook-Tests)
  RH_ALT=ALT_VERZ guard_so.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest: jede absichtliche Verfehlung muss erkannt werden
Kein node, kein Netz, keine echten Dateien des Dashboards: alles in temporaeren Ordnern (benoetigt flask/werkzeug, auf dem Pi in der venv)."""
import ast
import contextlib
import io
import os
import shutil
import sys
import tempfile
import time

MARK = "# ===== sameOrigin:"
MAIN = '\n\nif __name__ == "__main__":\n'
COPIES = {"_lm1_same_origin": "X-Lage-Mesh1", "_sl_same_origin": "X-SDR-Lage", "_stk_same_origin": "X-Stick-Test", "_t2d_same_origin": "X-T2", "_mp_same_origin": "X-Mesh-Post"}
ALLOWED_TOP = set(COPIES) | {"_so_origin_ok", "require_same_origin", "_SO_STAT", "_SO_LOG_GAP", "_so_loopback", "_so_allowed", "_so_guard", "_so_install", "_selftest_sameorigin", "_SOG"}


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block sameOrigin nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle sameOrigin nicht genau einmal: " + n.strip().splitlines()[0][:70]
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
        return "_SOG" if "_selftest_sameorigin()" in ast.unparse(n) else "#try"
    return "#" + type(n).__name__


def find_top(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def static(alt, new, blk):
    n = 0
    ta, tn = ast.parse(alt), ast.parse(new)
    da = {ast.dump(x): top_name(x) for x in ta.body}
    dn = {ast.dump(x): top_name(x) for x in tn.body}
    changed = [dn[k] for k in dn if k not in da] + [da[k] for k in da if k not in dn]
    bad = sorted(set(c for c in changed if c not in ALLOWED_TOP))
    assert not bad, "sameOrigin aendert ausserhalb der erlaubten Stellen: %s" % bad
    n += 1
    # fuenf Kopien: genau ein Return mit dem bisherigen Kopf, need_json=True
    for fn, hdr in COPIES.items():
        f = find_top(tn, fn)
        body = [s for s in f.body if not (isinstance(s, ast.Expr) and isinstance(getattr(s, "value", None), ast.Constant))]
        want = ast.dump(ast.parse('return require_same_origin(rq, "%s", True)' % hdr).body[0])
        assert len(body) == 1 and ast.dump(body[0]) == want, "%s ruft nicht genau require_same_origin(rq, '%s', True) auf" % (fn, hdr)
    n += 1
    # gemeinsame Pruefung steht vor der ersten Kopie (Import-Zeit-Selbsttests der alten Schichten)
    order = [top_name(x) for x in tn.body]
    for fn in ("_so_origin_ok", "require_same_origin"):
        assert order.index(fn) < min(order.index(c) for c in COPIES), "%s steht nicht vor den Kopien" % fn
    n += 1
    # Hook
    g = find_top(tn, "_so_guard")
    gu = ast.unparse(g)
    first_if = [s for s in g.body if isinstance(s, ast.If)][0]
    assert ast.unparse(first_if.test) == "rq.method in ('GET', 'HEAD', 'OPTIONS')" and ast.unparse(first_if.body[0]) == "return None", "_so_guard: GET/HEAD/OPTIONS muessen als Erstes durchgelassen werden"
    assert "_so_allowed(rq)" in gu and "r.status_code = 403" in gu and "return r" in gu and "no-store" in gu
    for forb in ("get_json", "subprocess", "open(", "os.", "requests", "socket"):
        assert forb not in gu, "_so_guard enthaelt %s" % forb
    n += 1
    ins = find_top(tn, "_so_install")
    assert ".insert(0, _so_guard)" in ast.unparse(ins) and "_so_installed" in ast.unparse(ins), "_so_install: Hook muss an Stelle 0 eingehaengt werden, einmalig"
    n += 1
    al = ast.unparse(find_top(tn, "_so_allowed"))
    for k in ("_so_origin_ok(rq)", "_so_loopback(rq.remote_addr)", "'Origin'", "'Referer'", "'Sec-Fetch-Site'"):
        assert k in al, "_so_allowed ohne %s" % k
    assert "except Exception:\n        return False" in al, "_so_allowed muss bei Fehler ablehnen"
    n += 1
    # Block: genau ein Aufruf _so_install(app), keine Routen, kein Netz/Prozess/Datei
    bt = rd(blk)
    bn = ast.parse(bt)
    inst = [c for c in ast.walk(bn) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == "_so_install" and ast.unparse(c) == "_so_install(app)"]
    assert len(inst) == 1, "Block: genau ein _so_install(app) erwartet"
    for forb in ("add_url_rule", "app.route(", "app.add_", "@app.", "subprocess", "requests", "socket", "os.system", "open(", "urlopen", "shutil"):
        assert forb not in bt, "Block enthaelt %s" % forb
    n += 1
    st = find_top(ast.parse(bt), "_selftest_sameorigin")
    na = len([x for x in ast.walk(st) if isinstance(x, ast.Assert) and not isinstance(x.test, ast.Constant)])
    assert na >= 14, "Block-Selbsttest hat nur %d Pruefungen (erwartet mindestens 14)" % na
    n += 1
    return n


def make_req(headers, ct=None):
    from werkzeug.test import EnvironBuilder
    from werkzeug.wrappers import Request
    return Request(EnvironBuilder(path="/x", method="POST", headers=headers, content_type=ct, base_url="http://pi:5000").get_environ())


_SEG = {}


def seg(src, name):
    k = (len(src), hash(src))
    if k not in _SEG:
        if len(_SEG) > 4:
            _SEG.clear()
        _SEG[k] = ({n.name: n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef)}, {})
    nodes, done = _SEG[k]
    if name not in nodes:
        raise AssertionError("Funktion fehlt: " + name)
    if name not in done:
        done[name] = ast.get_source_segment(src, nodes[name])
    return done[name]


def differential(alt, new):
    """Die fuenf Pruefungen liefern fuer alle Kopf-Kombinationen dasselbe wie vorher (MOD-09: Verhalten unveraendert)."""
    na, nn = {}, {}
    for ns, src in ((na, alt), (nn, new)):
        for fn in COPIES:
            exec(compile(seg(src, fn), fn, "exec"), ns)
        if "require_same_origin" in src:
            exec(compile(seg(src, "_so_origin_ok"), "o", "exec"), ns)
            exec(compile(seg(src, "require_same_origin"), "r", "exec"), ns)
    cnt = 0
    fast = os.environ.get("RH_SO_FAST") == "1"      # Mutationstest: kleineres Gitter (jede Spalte behaelt die Grenzfaelle), spart Last auf dem Pi
    O = (None, "http://pi:5000", "http://pi:5000/", "null", "http://pi:5000.evil.com") if fast else (None, "http://pi:5000", "http://pi:5000/", "http://evil.com", "null", "http://pi:5000.evil.com", "https://pi:5000", "")
    R = (None, "http://pi:5000", "http://pi:5000/x", "http://pi:5000.evil.com/x") if fast else (None, "http://pi:5000", "http://pi:5000/x", "http://pi:5000.evil.com/x", "http://evil/", "")
    S = (None, "same-origin", "cross-site") if fast else (None, "same-origin", "same-site", "cross-site", "none")
    H = (None, "1", "0") if fast else (None, "1", "0", "")
    C = ("application/json", "text/plain", None) if fast else ("application/json", "text/plain", "application/x-www-form-urlencoded", None)
    for o in O:
        for rf in R:
            for sf in S:
                for hv in H:
                    for ct in C:
                        rqs = {}
                        for fn, hdr in COPIES.items():
                            h = {}
                            if o is not None:
                                h["Origin"] = o
                            if rf is not None:
                                h["Referer"] = rf
                            if sf is not None:
                                h["Sec-Fetch-Site"] = sf
                            for other in COPIES.values():
                                if other != hdr and hv is not None and other == "X-T2":
                                    h[other] = hv          # fremder Kopf darf nichts bewirken
                            if hv is not None:
                                h[hdr] = hv
                            hk = tuple(sorted(h.items()))
                            rq = rqs.get(hk) or rqs.setdefault(hk, make_req(h, ct))
                            a, b = na[fn](rq), nn[fn](rq)
                            assert a == b and type(a) is type(b), "Verhalten von %s weicht ab: %s ct=%s alt=%s neu=%s" % (fn, h, ct, a, b)
                            cnt += 1
    return cnt


def sandbox(new, blk_text=None):
    """fuehrt gemeinsame Pruefung + Block in einer Sandbox mit eigener Flask-App aus; Rueckgabe (ns, Ausgabe)"""
    from flask import Flask
    ns = {"__name__": "so_sandbox", "time": time, "app": Flask("so_sandbox_app")}
    for fn in ("_so_origin_ok", "require_same_origin") + tuple(COPIES):
        exec(compile(seg(new, fn), fn, "exec"), ns)
    app = ns["app"]
    calls = []
    for p in ROUTES_POST:
        def mk(p):
            def v():
                from flask import request as rq
                calls.append(p)
                if p == "/api/mesh_weather" and not ns["_mp_same_origin"](rq):
                    return "own-deny", 403
                return "ok"
            v.__name__ = "v" + p.replace("/", "_")
            return v
        app.add_url_rule(p, view_func=mk(p), methods=["POST"])
    app.add_url_rule("/api/get", view_func=lambda: "g", endpoint="g", methods=["GET"])
    bt = blk_text if blk_text is not None else new[new.index(MARK):new.index(MAIN, new.index(MARK))]
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(bt, "so_block", "exec"), ns)
    return ns, out.getvalue(), calls


ROUTES_POST = ["/api/backup", "/api/backup/restore", "/api/clone/start", "/api/kfz/own", "/api/lage_mesh1/send", "/api/mesh2_hold", "/api/mesh2_resume", "/api/mesh2_send",
               "/api/mesh_hold", "/api/mesh_luft", "/api/mesh_odl", "/api/mesh_pegel", "/api/mesh_resume", "/api/mesh_send", "/api/mesh_spaceweather", "/api/mesh_test",
               "/api/mesh_weather", "/api/nina_bayern_auto", "/api/scanner_mode", "/api/sd_health/ack", "/api/sdr/airtest", "/api/sdr/autogain", "/api/sdr/lage", "/api/sdr/mode",
               "/api/sdr/preset", "/api/sdr/release", "/api/sdr/sticktest", "/api/sources/update", "/api/speedtest", "/api/t2/autosend", "/api/t2/stick2", "/api/t4/sdr2"]


def behav(alt, new, blk):
    n = differential(alt, new) // 1000 or 1
    with contextlib.redirect_stdout(io.StringIO()):       # der Hook meldet Ablehnungen auf stdout; hier nicht ausgeben
        n += hooktests(new)
    return n


def hooktests(new):
    n = 0
    # Block-Selbsttest meldet ok, Hook an Stelle 0 der echten (Sandbox-)App
    ns, out, calls = sandbox(new)
    assert "sameOrigin aktiv: sameOrigin ok" in out, "Block-Selbsttest meldet nicht ok: %s" % out[:200]
    app = ns["app"]
    assert ns["_SOG"].get("installiert") is True and app.before_request_funcs[None][0] is ns["_so_guard"], "Hook nicht als erste Funktion in der App"
    c = app.test_client()
    evil = {"Origin": "http://evil.example"}
    good = {"Origin": "http://localhost"}
    lan = {"REMOTE_ADDR": "192.168.178.50"}
    for p in ROUTES_POST:
        del calls[:]
        for h in (evil, {"Origin": "null"}, {"Referer": "http://evil.example/a"}, {"Sec-Fetch-Site": "cross-site", "Origin": "http://localhost"}):
            r = c.post(p, headers=h, json={})
            assert r.status_code == 403 and r.get_json()["ok"] is False and r.headers.get("Cache-Control") == "no-store", "%s: fremde Herkunft nicht abgelehnt (%s)" % (p, h)
        assert c.post(p, data="x=1", content_type="application/x-www-form-urlencoded", environ_overrides=lan).status_code == 403, p + ": LAN ohne Herkunft"
        assert not calls, "Route lief trotz Ablehnung: %s" % calls
        r = c.post(p, headers=good, json={})
        assert r.status_code in (200, 403) and (p == "/api/mesh_weather" or r.status_code == 200), "%s: eigene Seite abgelehnt" % p
        assert c.post(p, headers={"Referer": "http://localhost/pi"}).status_code in (200, 403)
        assert c.post(p).status_code in (200, 403), "Pi selbst (loopback) ohne Kopf: %s" % p
        n += 1
    # Schicht-Pruefung der alten Routen bleibt zusaetzlich bestehen (hier mesh_weather: eigener Test verlangt X-Mesh-Post)
    del calls[:]
    assert c.post("/api/mesh_weather", headers=good, json={}).status_code == 403, "eigene Pruefung muss weiter greifen"
    assert c.post("/api/mesh_weather", headers=dict(good, **{"X-Mesh-Post": "1"}), json={}).status_code == 200
    # GET und Methodenpruefung unveraendert
    assert c.get("/api/get", headers=evil).status_code == 200 and c.get("/api/backup").status_code == 405, "GET/405 veraendert"
    assert c.options("/api/backup", headers=evil).status_code == 200
    n += 1
    # Meldung: gekuerzt, hoechstens einmal je Pfad und Mindestabstand
    ns["_SO_STAT"]["last_log"].clear()
    lb = io.StringIO()
    with contextlib.redirect_stdout(lb):
        for i in range(3):
            assert c.post("/api/backup", headers={"Origin": "http://" + "a" * 500}).status_code == 403
    lines = [x for x in lb.getvalue().splitlines() if x.startswith("sameOrigin:")]
    assert len(lines) == 1 and len(lines[0]) < 220 and "/api/backup" in lines[0], "Meldung: %d Zeilen, Laenge %s" % (len(lines), [len(x) for x in lines])
    assert ns["_SO_STAT"]["denied"] >= 3
    n += 1
    # Installation einmalig, Ausnahme im Hook-Entscheid lehnt ab
    assert ns["_so_install"](app) is False
    ns["_so_origin_ok"] = lambda rq: 1 / 0
    assert c.post("/api/backup", headers=good).status_code == 403, "Fehler in der Pruefung muss ablehnen (fail closed)"
    n += 1
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_SO_NOSTATIC") == "1" else static(alt, new, blk)
    if os.environ.get("RH_SO_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau von Block und Stellen ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    assert rd(blk).rstrip("\n") in new
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk)
    print("OK guard sameOrigin: %d Pruefungen, 0 fehlerhaft" % n)
    return n


# (Name, Zielzeichenfolge, Ersatz, norev)
MUT = [
    ("M01 Hook blockt auch GET", 'rq.method in ("GET", "HEAD", "OPTIONS")', 'rq.method in ("HEAD", "OPTIONS")', 1),
    ("M02 Hook laesst POST durch", 'rq.method in ("GET", "HEAD", "OPTIONS")', 'rq.method in ("GET", "HEAD", "OPTIONS", "POST")', 1),
    ("M03 Entscheid immer erlaubt", "        if _so_origin_ok(rq):\n            return True\n", "        return True\n", 1),
    ("M04 Ausnahme Pi selbst ohne Kopfpruefung", 'if not (rq.headers.get("Origin") or rq.headers.get("Referer") or rq.headers.get("Sec-Fetch-Site")) and _so_loopback(rq.remote_addr):', "if _so_loopback(rq.remote_addr):", 1),
    ("M05 Ausnahme ohne Sec-Fetch-Site", ' or rq.headers.get("Sec-Fetch-Site")) and _so_loopback', ") and _so_loopback", 1),
    ("M06 Ausnahme ohne Referer", ' or rq.headers.get("Referer") or rq.headers.get("Sec-Fetch-Site")', ' or rq.headers.get("Sec-Fetch-Site")', 1),
    ("M07 Ausnahme ohne Origin", 'if not (rq.headers.get("Origin") or rq.headers.get("Referer")', 'if not (rq.headers.get("Referer")', 1),
    ("M08 loopback immer wahr", "        return bool(ip.is_loopback)", "        return True", 1),
    ("M09 loopback nie wahr", "        return bool(ip.is_loopback)", "        return False", 1),
    ("M10 loopback: LAN-Praefix erlaubt", "        return bool(ip.is_loopback)", "        return bool(ip.is_loopback or str(ip).startswith('192.168.'))", 1),
    ("M11 Hook hinten angehaengt", ".insert(0, _so_guard)", ".append(_so_guard)", 1),
    ("M12 Antwort 200 statt 403", '    r.status_code = 403\n    r.headers["Cache-Control"]', '    r.status_code = 200\n    r.headers["Cache-Control"]', 1),
    ("M13 Ablehnung ohne Antwort", "    return r\n\n\ndef _so_install", "    return None\n\n\ndef _so_install", 1),
    ("M14 Cache-Control entfaellt", '    r.status_code = 403\n    r.headers["Cache-Control"] = "no-store"\n', '    r.status_code = 403\n', 1),
    ("M15 Hook nicht einmalig", '    if getattr(flask_app, "_so_installed", False):\n        return False\n', "", 1),
    ("M16 Fehler im Entscheid erlaubt", "    except Exception:\n        return False\n    return False\n\n\ndef _so_guard", "    except Exception:\n        return True\n    return False\n\n\ndef _so_guard", 1),
    ("M17 Origin Gleichheit lax (Praefix)", 'if o is not None and o.rstrip("/") != base:', 'if o is not None and not o.startswith(base):', 1),
    ("M18 Referer Praefix ohne Schraegstrich", 'ref == base or ref.startswith(base + "/")', "ref.startswith(base)", 1),
    ("M19 Sec-Fetch-Site nicht geprueft", 'if sfs is not None and sfs != "same-origin":\n        return False\n    return True', 'if False:\n        return False\n    return True', 1),
    ("M20 Referer-Pflicht entfaellt", 'if o is None and not (ref == base or ref.startswith(base + "/")):\n        return False\n', 'if False:\n        return False\n', 1),
    ("M21 Origin null erlaubt", 'if o is not None and o.rstrip("/") != base:', 'if o is not None and o != "null" and o.rstrip("/") != base:', 1),
    ("M22 Pflichtkopf nicht geprueft", 'if header is not None and rq.headers.get(header) != "1":', 'if False:', 1),
    ("M23 Pflichtkopf: beliebiger Wert", 'rq.headers.get(header) != "1"', 'not rq.headers.get(header)', 1),
    ("M24 JSON nicht geprueft", 'if need_json and (rq.mimetype or "") != "application/json":', "if False:", 1),
    ("M25 Kopie mesh: falscher Kopf", 'return require_same_origin(rq, "X-Mesh-Post", True)', 'return require_same_origin(rq, "X-T2", True)', 1),
    ("M26 Kopie lage_mesh1: ohne JSON", 'return require_same_origin(rq, "X-Lage-Mesh1", True)', 'return require_same_origin(rq, "X-Lage-Mesh1", False)', 1),
    ("M27 Kopie stick: ohne Kopf", 'return require_same_origin(rq, "X-Stick-Test", True)', "return require_same_origin(rq, None, True)", 1),
    ("M28 Kopie sdr_lage: Herkunft nicht geprueft", 'return require_same_origin(rq, "X-SDR-Lage", True)', 'return rq.headers.get("X-SDR-Lage") == "1" and (rq.mimetype or "") == "application/json"', 1),
    ("M29 Block installiert nicht", "_SOG[\"installiert\"] = _so_install(app)", "_SOG[\"installiert\"] = True", 1),
    ("M30 Selbsttest ohne Pruefung", "assert c.post(\"/unbekannt\", headers={\"Origin\": \"http://evil.example\"}).status_code == 403", "assert True", 1),
    ("M31 Block meldet nicht ok", 'return "sameOrigin ok (', 'return "sameOrigin kaputt (', 1),
    ("M32 Prozess im Block", "def _selftest_sameorigin():", "import subprocess\n\ndef _selftest_sameorigin():", 1),
    ("M33 Zaehler zaehlt nicht", '    _SO_STAT["denied"] += 1\n', "", 1),
    ("M34 stille Zusatzaenderung: Server-Start", "use_reloader=False, threaded=True)  # sysBoot", "use_reloader=True, threaded=True)  # sysBoot", 0),
    ("M35 stille Zusatzaenderung: Route-Methoden", '@app.route("/api/mesh_send", methods=["POST"])', '@app.route("/api/mesh_send", methods=["GET", "POST"])', 0),
    ("M36 stille Zusatzaenderung: keepLast", "_keep_untag_slot(slot)\n            kind = \"value\"", "kind = \"value\"", 0),
    ("M38 Meldung bei jeder Ablehnung (kein Mindestabstand)", "_SO_LOG_GAP = 30.0", "_SO_LOG_GAP = 0.0", 1),
    ("M37 Hook ohne Pfadlaenge/Protokoll aber mit Ausgabe von Kopfwerten roh", '(rq.headers.get("Origin") or "-")[:60]', '(rq.headers.get("Origin") or "-")', 1),
]
EQUIV = []


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    bad = []
    done = 0
    for name, a, b, norev in MUT:
        w = tempfile.mkdtemp(prefix="so-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            assert base_new.count(a) == 1, "%s: Stelle nicht eindeutig (%d)" % (name, base_new.count(a))
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new.replace(a, b, 1))
            if norev:
                os.environ["RH_SO_NOREV"] = "1"
            else:
                os.environ.pop("RH_SO_NOREV", None)
            # Block-Mutanten: der Guard liest den Block aus einer Datei; Mutation im Block wird daher in eine Block-Kopie gespiegelt
            bf = os.path.join(w, "blk.py")
            bt = rd(blk)
            if a in bt:
                bt = bt.replace(a, b, 1)
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
            os.environ.pop("RH_SO_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation sameOrigin: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
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
        print("guard sameOrigin FEHLER: %s" % e)
        sys.exit(1)
SO_RGD_EOF
PPK="$W/patch-so.py"; RED="$W/edits_so.py"; RBK="$W/blk_so.py"; RGD="$W/guard_so.py"
for x in "$EXPECT_PSO $PPK" "$EXPECT_RED $RED" "$EXPECT_RBK $RBK" "$EXPECT_RGD $RGD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (patch-so.py, edits_so.py, blk_so.py, guard_so.py)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Basis nach perfKeep commit27" "$KNOWN_D16N" "sameOrigin schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      sameOrigin passt nur auf den Stand nach perfKeep commit27 (dashboard.py 08fbc3e35940faab). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
grep -q '# ===== relHygiene:' "$F" || stop "relHygiene (commit19b) fehlt im Dashboard (Basis)"
grep -q '# ===== perfKeep:' "$F" || stop "perfKeep (commit27) fehlt im Dashboard (Basis)"
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
# andere Programmdateien: nur Vorher/Nachher-Vergleich
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" sameOrigin dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer sameOrigin nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" sameOrigin dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
# AST-Guard: Rueckbau ergibt die bekannte Basis; dann Regeln, Verhalten (Differenztest alt/neu) und Mutationstest. Kein node noetig.
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: sameOrigin im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne sameOrigin ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard sameOrigin meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" nice -n 10 "$VPY" "$RGD" mutate "$W/neu" "$RBK" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^aequivalent|^OK" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-?}"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
LAN=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
pcode() { code -X POST "$@"; }
PRE_EVIL=$(pcode -H "Origin: http://evil.example" "$B/api/so-probe-vor")
echo "Zustand vorher (nur Lesen/Probe auf nicht vorhandenem Pfad): POST mit fremdem Origin -> HTTP $PRE_EVIL (403 = Schutz schon aktiv; 404 = noch ungeschuetzt)"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: sameOrigin ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-sameorigin-ZEIT, letzte $KEEP_LAST), Neustart nur prepper-dashboard, eine sudo-Passwortabfrage."; fi
  echo "COMMIT $COMMIT_ARG sameorigin=dry fertig"
  exit 0
fi
[[ "$NEED_D" == 0 ]] || { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; }
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "sameOrigin|Traceback" | tail -4 | cut -c1-200
  [[ -f "$F.bak-sameorigin-$TS" ]] && cp -a "$F.bak-sameorigin-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-sameorigin-$TS" ]] && { cmp -s "$F" "$F.bak-sameorigin-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK sameOrigin schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-sameorigin-$TS"
  { ls -1t "$F.bak-sameorigin-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-sameorigin-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-sameorigin-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'sameOrigin aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; sameOrigin aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
# Funktionspruefung der Herkunftspruefung: nur Probe-Pfade, die es nicht gibt - keine echte Route wird aufgerufen, nichts gesendet
c1=$(pcode -H "Origin: http://evil.example" "$B/api/so-probe-a"); c2=$(pcode -H "Origin: $B" "$B/api/so-probe-b"); c3=$(pcode "$B/api/so-probe-c")
c4=$(pcode -H "Sec-Fetch-Site: cross-site" -H "Origin: $B" "$B/api/so-probe-d"); c5=$(pcode -H "Referer: http://evil.example/x" "$B/api/so-probe-e"); c6=$(pcode -H "Origin: null" "$B/api/so-probe-g")
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c1 $c4 $c5 $c6" == "403 403 403 403" ]] || rbx "fremde Herkunft wird nicht abgelehnt (fremder Origin $c1, cross-site $c4, fremder Referer $c5, Origin null $c6; erwartet je 403)"
[[ "$c2" =~ ^(404|405)$ && "$c3" =~ ^(404|405)$ ]] || rbx "eigene Herkunft/Pi selbst wird abgelehnt (eigener Origin $c2, ohne Kopf von 127.0.0.1 $c3; erwartet 404 = durchgelassen)"
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
echo "OK Herkunftspruefung (Probe-Pfade): fremder Origin/Referer/Origin null/cross-site -> 403, eigener Origin und Pi selbst ohne Kopf -> durchgelassen (404), GET unberuehrt (200)"
if [[ -n "$LAN" ]]; then
  l1=$(pcode "http://$LAN:$PORT/api/so-probe-h"); l2=$(pcode -H "Origin: http://$LAN:$PORT" "http://$LAN:$PORT/api/so-probe-i")
  if [[ "$l1" == 403 && "$l2" =~ ^(404|405)$ ]]; then echo "OK LAN-Adresse $LAN: ohne Herkunft -> 403, mit eigenem Origin -> durchgelassen (404)"
  elif [[ "$l1" == 000 || "$l2" == 000 ]]; then echo "HINWEIS LAN-Adresse $LAN:$PORT nicht erreichbar (Test uebersprungen)"
  else rbx "LAN-Adresse $LAN: ohne Herkunft $l1 (erwartet 403), mit eigenem Origin $l2 (erwartet 404)"; fi
fi
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E sameOrigin"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "sameOrigin aktiv: sameOrigin ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-200)" || rbx "Journal prepper-dashboard ohne 'sameOrigin aktiv: sameOrigin ok' ($(echo "$JD" | grep -F sameOrigin | tail -1 | cut -c1-200))"
    JR=$(echo "$JD" | grep -F "relHygiene aktiv: relHygiene ok" | tail -1 || true)
    [[ -n "$JR" ]] && echo "OK relHygiene weiter aktiv: $(echo "$JR" | cut -c1-120)" || rbx "Journal ohne 'relHygiene aktiv: relHygiene ok' (Regression)"
  fi
  if [[ "$RESTARTED_D" == 1 ]]; then
    JP=$(echo "$JD" | grep -F "perfKeep aktiv: perfKeep ok" | tail -1 || true)
    [[ -n "$JP" ]] && echo "OK perfKeep weiter aktiv: $(echo "$JP" | cut -c1-120)" || rbx "Journal ohne 'perfKeep aktiv: perfKeep ok' (Regression)"
  fi
  E2=$(echo "$JD" | grep -c -E 'sameOrigin Selbsttest FEHLER|keepLast heal:|perfKeep Selbsttest FEHLER' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne sameOrigin-/perfKeep-/keepLast-Fehler" || { echo "$JD" | grep -E 'sameOrigin|perfKeep|keepLast heal:' | cut -c1-240; rbx "$E2 sameOrigin-/perfKeep-/Heilungsfehler im Journal Dashboard"; }
  echo "Journal: $(echo "$JD" | grep -c 'sameOrigin: .* abgelehnt' || true) Ablehnungsmeldung(en) seit Neustart (von den Probe-Aufrufen dieses Laufs; ein Knopf des Dashboards darf nie dabei sein)"
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein sameOrigin-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
CNT=$(grep -c '# ===== sameOrigin:' "$F" || true); CNR=$(grep -c '# ===== relHygiene:' "$F" || true); CNP=$(grep -c '# ===== perfKeep:' "$F" || true)
[[ "$CNT" == 1 && "$CNR" == 1 && "$CNP" == 1 ]] && echo "OK Marker sameOrigin=$CNT perfKeep=$CNP relHygiene=$CNR in dashboard.py" || rbx "Marker sameOrigin=$CNT perfKeep=$CNP relHygiene=$CNR"
echo "Hinweis: ein Knopf, der nach dem Patch Herkunft abgelehnt meldet, ist ein Fehler - bitte Seite und Knopf melden (Journal: sameOrigin: POST /api/... abgelehnt). Zugriff ueber eine andere Adresse/https-Proxy als die Seite selbst wird abgelehnt."
echo "OK Datenbank, Alarm-, Sende- und Abruflogik, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-sameorigin-$TS" ]] && echo "Backup: dashboard.py.bak-sameorigin-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-sameorigin-"* 2>/dev/null || true; } | head -1); [[ -n "$LB" ]] && echo "Rueckweg (neueste Sicherung: $(basename "$LB")): cp -a $LB $F ; sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine sameOrigin-Sicherung vorhanden (nichts geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s -o /dev/null -w %{http_code} -X POST -H Origin:http://evil.example $B/api/so-probe     (erwartet 403)"
echo "  curl -s -o /dev/null -w %{http_code} -X POST $B/api/so-probe     (erwartet 404 = vom Pi selbst durchgelassen, Route gibt es nicht)"
echo "  sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep sameOrigin"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG sameorigin=1 fertig"
