#!/bin/bash
set -eEuo pipefail
# secXmlDash (commit33): Apotheken-Notdienst und News-Feeds im Dashboard laufen ueber lage_xml.fetch_root (Grenze 2 MiB fest, Gesamtzeit, Entity-/DTD-Sperre, defusedxml sobald installiert); Fehler wie bisher leer, URL-Token des Notdienstes steht nie im Journal; Voraussetzung apply-secxml (lage_xml.py f77305fc17ed2f77). Nur dashboard.py (4 Stellen + kleiner Selbsttest-Block).
# Aufruf: bash /tmp/apply-secxmldash.sh commit33 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py ee4ea3123eb561c4 (Stand nach modDead commit32) oder secXmlDash schon drin (1574109c8609cf26); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-secxmldash-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/secxmldash-apply
KEEP_LAST=3
KNOWN_D16="ee4ea3123eb561c4"      # dashboard.py vor secXmlDash (Basis: Stand nach modDead commit32)
KNOWN_D16N="1574109c8609cf26"             # dashboard.py nach secXmlDash (Ziel)
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
echo "=== secXmlDash apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Notdienst/News ueber lage_xml, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="2048eb2a41de2266e23829af82dba5a1218f092c5d80e044cabe3654b4ea98bd"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher secXmlDash. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
EXPECT_RAE="14d1230ea8e1bc22df70b362cc58faea8790042fb7bade1b7d6abaaf53233523"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer secXmlDash (commit33): Basis ee4ea3123eb561c4 (Stand nach modDead commit32); Entwurf aus /workspace/secxml/dashpatch (4 exakte Edits)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    ('        r = requests.get(APOTHEKEN_NOTDIENST_URL, timeout=15, headers=headers)\n        r.raise_for_status()\n        import xml.etree.ElementTree as ET\n        root = ET.fromstring(r.content)\n',
     '        import lage_xml   # secXml: 2 MiB fest, Gesamtzeit, defusedxml; Fehler/Ablehnung -> except unten (leer, wie bisher)\n        root = lage_xml.fetch_root(APOTHEKEN_NOTDIENST_URL, "apotheken-notdienst", timeout=15, headers=headers)\n'),
    ('        print("Apotheken-Notdienst Kalchreuth:", e)\n',
     '        print("Apotheken-Notdienst Kalchreuth:", str(e).replace(APOTHEKEN_NOTDIENST_URL, "<Notdienst-URL>"))   # die URL enthaelt ein Token: nie ins Journal\n'),
    ('    import xml.etree.ElementTree as ET\n    import requests as _rq\n',
     '    import lage_xml   # secXml\n'),
    ('            r = _rq.get(url, timeout=10, headers={"User-Agent": "Mozilla/5.0 KaeswasserLage/1.0"})\n            r.raise_for_status()\n            raw = r.content\n            if raw.startswith(b"\\xef\\xbb\\xbf"):\n                raw = raw[3:]\n            root = ET.fromstring(raw)\n',
     '            root = lage_xml.fetch_root(url, "news:" + url.split("/")[2], timeout=10, headers={"User-Agent": "Mozilla/5.0 KaeswasserLage/1.0"})   # BOM-Entfernung und 2-MiB-Grenze in lage_xml\n'),
]
MK_RAE_EOF
EXPECT_RAB="15c97c46e45c33f2183a1e96600971d0bb28f33721d8452827630a4f2dea792c"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== secXmlDash: Apotheken-Notdienst und News-Feeds ueber lage_xml.fetch_root (2 MiB fest, Gesamtzeit, defusedxml; Fehler wie bisher leer) =====
# Voraussetzung: lage_xml.py mit fetch_root (apply-secxml). Das URL-Token des Notdienstes steht nie im Journal (Platzhalter <Notdienst-URL>).
def _selftest_secxmldash():
    import lage_xml as _lx
    assert callable(getattr(_lx, "fetch_root", None)), "lage_xml.fetch_root fehlt (apply-secxml nicht angewendet?)"
    for _name in ("fetch_apotheken_notdienst", "fetch_news"):
        # andere Schichten (staleTs, keepLast, priceAllTime) umhuellen die Funktion: die eigentliche Funktion ueber Closure/__wrapped__ suchen
        _seen, _todo, _orig = set(), [globals()[_name]], []
        while _todo and len(_seen) < 40:
            _f = _todo.pop()
            if id(_f) in _seen or not callable(_f):
                continue
            _seen.add(id(_f))
            if getattr(getattr(_f, "__code__", None), "co_name", "") == _name:
                _orig.append(_f)
            for _c in (getattr(_f, "__closure__", None) or ()):
                try:
                    _todo.append(_c.cell_contents)
                except ValueError:
                    pass
            if getattr(_f, "__wrapped__", None) is not None:
                _todo.append(_f.__wrapped__)
        assert _orig, "%s: urspruengliche Funktion nicht auffindbar" % _name
        for _f in _orig:
            _names = set(_f.__code__.co_names) | set(_f.__code__.co_varnames) | set(_f.__code__.co_cellvars)
            assert "lage_xml" in _names, "%s nutzt lage_xml nicht" % _name
            assert "ET" not in _names and "_rq" not in _names, "%s nutzt noch ElementTree oder den alten Abruf direkt" % _name
    _r = _lx.selftest()
    return "secXmlDash ok (Apotheken-Notdienst und 4 News-Feeds ueber lage_xml.fetch_root; %s)" % str(_r)[:80]


try:
    _SD_ST = _selftest_secxmldash()
    print("secXmlDash aktiv: %s" % _SD_ST, flush=True)
except Exception as _sd_e:
    print("secXmlDash Selbsttest FEHLER (%s)" % _sd_e, flush=True)
# ===== /secXmlDash =====
MK_RAB_EOF
EXPECT_RAG="a6776176c1f211a3df46a539b92e9937d6e566f8ff119bc8377516710e5dd767"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-/Verhaltens-Guard secXmlDash (nur dashboard.py: 4 Stellen in fetch_apotheken_notdienst/fetch_news + kleiner Block). Aufruf:
  guard_sd.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne secXmlDash (Rueckbau, byte-genau)
  guard_sd.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhaltenstest gegen lokalen Testserver (alt gegen neu, gute und boese Antworten)
  RH_ALT=ALT_VERZ guard_sd.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest
lage_xml.py wird aus SECXML_LIBDIR geladen (Projektordner; Standard: Ordner dieses Programms, dann /workspace/secxml/src). Ohne node, ohne Netz (nur 127.0.0.1)."""
import ast
import contextlib
import gzip
import io
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import types
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CALL_A = "lage_xml.fetch_root(APOTHEKEN_NOTDIENST_URL, 'apotheken-notdienst', timeout=15, headers=headers)"
CALL_B = "lage_xml.fetch_root(url, 'news:' + url.split('/')[2], timeout=10, headers={'User-Agent': 'Mozilla/5.0 KaeswasserLage/1.0'})"
FORBID = ("subprocess", "requests", "urlopen", "socket", "open(", "Popen", "os.system", "send_meshtastic", "eval(", "exec(", "__import__")


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block secXmlDash nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle secXmlDash nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def libdir():
    for d in (os.environ.get("SECXML_LIBDIR"), os.path.dirname(os.path.abspath(__file__)), "/workspace/secxml/src"):
        if d and os.path.exists(os.path.join(d, "lage_xml.py")):
            return d
    raise AssertionError("lage_xml.py nicht gefunden (SECXML_LIBDIR) - apply-secxml nicht angewendet?")


def import_lx():
    d = libdir()
    if d not in sys.path:
        sys.path.insert(0, d)
    sys.modules.pop("lage_xml", None)
    import lage_xml
    assert callable(getattr(lage_xml, "fetch_root", None)), "lage_xml.fetch_root fehlt"
    return lage_xml


def fn_node(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def names_in(node):
    s = set()
    for x in ast.walk(node):
        if isinstance(x, ast.Name):
            s.add(x.id)
        elif isinstance(x, ast.Attribute):
            s.add(x.attr)
    return s


def check_block_text(B):
    t = ast.parse(B)
    kinds = [type(n).__name__ + ":" + getattr(n, "name", "") for n in t.body]
    assert kinds == ["FunctionDef:_selftest_secxmldash", "Try:"], kinds
    for w in FORBID:
        assert w not in B, "Block enthaelt verbotenes Wort: " + w
    for x in ast.walk(t):
        if isinstance(x, ast.Call) and isinstance(x.func, ast.Name) and x.func.id in ("eval", "exec", "open", "__import__", "compile"):
            raise AssertionError("Block ruft " + x.func.id)
        if isinstance(x, (ast.Import, ast.ImportFrom)):
            assert [a.name for a in x.names] == ["lage_xml"], "Block importiert Fremdes"
    assert B.splitlines()[0].startswith("# ===== secXmlDash:") and B.rstrip().splitlines()[-1] == "# ===== /secXmlDash =====", "Block ohne Marker"


def static(alt, new, blk, edits):
    n = 0
    B = rd(blk).rstrip("\n")
    check_block_text(B)
    assert new.count("\n\n" + B + "\n\nif __name__ == \"__main__\":\n") == 1, "Block nicht direkt vor dem __main__-Block"
    n += 2
    assert len(edits) == 4, "erwartet genau 4 Stellen"
    for o, nw in edits:
        assert alt.count(o) == 1, "Stelle nicht genau einmal im alten Stand"
    n += 1
    bs = new.count("\n", 0, new.index(B)) + 1
    be = bs + B.count("\n")
    ta, tn = ast.parse(alt), ast.parse(new)
    N = [x for x in tn.body if not (bs <= x.lineno <= be)]
    assert len(tn.body) - len(N) == 2, "Block hat nicht 2 Knoten"
    assert len(N) == len(ta.body), "Anzahl Knoten ausserhalb des Blocks verschieden"
    changed = []
    for a, b in zip(ta.body, N):
        if ast.dump(a) != ast.dump(b):
            changed.append(getattr(a, "name", "?"))
    assert sorted(changed) == ["fetch_apotheken_notdienst", "fetch_news"], "geaenderte Knoten: %s" % changed
    n += 2
    fa, fnw = fn_node(tn, "fetch_apotheken_notdienst"), fn_node(tn, "fetch_news")
    pf = [x for x in fnw.body if isinstance(x, ast.FunctionDef) and x.name == "parse_feed"]
    assert len(pf) == 1, "parse_feed fehlt"
    ca = [ast.unparse(x) for x in ast.walk(fa) if isinstance(x, ast.Call) and ast.unparse(x.func) == "lage_xml.fetch_root"]
    cb = [ast.unparse(x) for x in ast.walk(pf[0]) if isinstance(x, ast.Call) and ast.unparse(x.func) == "lage_xml.fetch_root"]
    assert ca == [CALL_A], "Aufruf Notdienst: %s" % ca
    assert cb == [CALL_B], "Aufruf News: %s" % cb
    n += 2
    for nd, nm in ((fa, "fetch_apotheken_notdienst"), (fnw, "fetch_news")):
        nn = names_in(nd)
        for bad in ("ET", "_rq", "fromstring", "raise_for_status", "content"):
            assert bad not in nn, "%s nutzt noch %s" % (nm, bad)
        assert "requests" not in nn, "%s nutzt noch requests" % nm
        assert "lage_xml" in nn
    n += 2
    src_fa = ast.unparse(fa)
    assert "replace(APOTHEKEN_NOTDIENST_URL, '<Notdienst-URL>')" in src_fa, "URL-Token wird nicht ersetzt"
    n += 1
    imps = [x for x in ast.walk(fnw) if isinstance(x, (ast.Import, ast.ImportFrom))]
    assert sorted(a.name for x in imps for a in x.names) == ["lage_xml", "re"], "Importe in fetch_news: %s" % [a.name for x in imps for a in x.names]
    n += 1
    return n


# ---------- Verhaltenstest ----------
NOTD = b'<?xml version="1.0" encoding="UTF-8"?><result><entries>' + b"".join(
    b"<entry><name>Apo %d</name><street>S</street><zipCode>90562</zipCode><location>Kalchreuth</location><phone>0911 %d</phone><distance>%d</distance>"
    b"<from>2026-10-25T00:00:00+01:00</from><to>2026-10-26T23:00:00+01:00</to></entry>" % (i, i, 1000 * i) for i in range(1, 4)) + b"</entries></result>"
RSS = ('<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>x</title><item><title>Titel \u00e4 1</title><link>http://a/1</link></item>'
       '<item><title>Titel 2</title><link>http://a/2</link></item></channel></rss>').encode()
ATOM = b'<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><entry><title>A1</title><link href="http://b/1"/></entry></feed>'
BOMB = (b'<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>'
        b'<rss><channel><item><title>&c;</title></item></channel></rss>')
BIG = b'<rss><channel><item><title>' + b"x" * (2 * 1024 * 1024 + 10) + b"</title></item></channel></rss>"
GZBOMB = gzip.compress(b'<rss><channel><item><title>' + b"x" * (3 * 1024 * 1024) + b"</title></item></channel></rss>")
BODIES = {"/notdienst": (NOTD, {}), "/rss": (RSS, {}), "/bomrss": (b"\xef\xbb\xbf" + RSS, {}), "/atom": (ATOM, {}), "/bomb": (BOMB, {}), "/big": (BIG, {}),
          "/gz": (GZBOMB, {"Content-Encoding": "gzip"}), "/notdienstbomb": (BOMB, {}), "/500": (None, {})}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        pth = self.path.split("?")[0]
        body, hdr = BODIES.get(pth, (b"", {}))
        if pth == "/500":
            self.send_response(500)
            self.end_headers()
            return
        self.send_response(200)
        for k, v in hdr.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass


def load_funcs(src, lx):
    tree = ast.parse(src)
    want = {}
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and (n.name.startswith("_apotheken") or n.name == "fetch_apotheken_notdienst"):
            want[n.name] = n
        if isinstance(n, ast.FunctionDef) and n.name == "fetch_news":
            for m in n.body:
                if isinstance(m, ast.FunctionDef) and m.name == "parse_feed":
                    want["parse_feed"] = m
    import datetime
    import requests
    g = {"requests": requests, "update_fail_counter": lambda *a, **k: None, "__name__": "dash_test", "datetime": datetime.datetime, "timezone": datetime.timezone,
         "timedelta": datetime.timedelta, "now_str": lambda: "x", "_re": re, "_rq": requests, "ET": __import__("xml.etree.ElementTree", fromlist=["x"]), "lage_xml": lx, "re": re}
    ns = ast.Module(body=[want[k] for k in sorted(want, key=lambda k: want[k].lineno) if k != "parse_feed"], type_ignores=[])
    exec(compile(ns, "dash", "exec"), g)
    pf = ast.Module(body=[want["parse_feed"]], type_ignores=[])
    exec(compile(pf, "dash", "exec"), g)
    return g


def run_all(g, base):
    out = {}
    g["APOTHEKEN_NOTDIENST_URL"] = base + "/notdienst?token=GEHEIM"
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        r = g["fetch_apotheken_notdienst"]()
        out["notdienst_ok"] = [(i["name"], i["km"]) for i in r["items"]] if r["items"] else r
        g["APOTHEKEN_NOTDIENST_URL"] = base + "/notdienstbomb?token=GEHEIM"
        out["notdienst_bomb"] = g["fetch_apotheken_notdienst"]()
        g["APOTHEKEN_NOTDIENST_URL"] = base + "/500?token=GEHEIM"
        out["notdienst_500"] = g["fetch_apotheken_notdienst"]()
        for k in ("rss", "bomrss", "atom", "bomb", "big", "gz", "500"):
            out["feed_" + k] = g["parse_feed"](base + "/" + k)
    return out, buf.getvalue()


def sandbox_block(B, fa_src, drop_fetch_root=False):
    """Block in einem Namensraum mit den beiden Funktionen ausfuehren; liefert ausgegebene Zeile."""
    g = {"__name__": "x"}
    exec(compile(fa_src, "fs", "exec"), g)
    buf = io.StringIO()
    saved = sys.modules.get("lage_xml")
    try:
        if drop_fetch_root:
            m = types.ModuleType("lage_xml")
            m.selftest = lambda: "x"
            sys.modules["lage_xml"] = m
        with contextlib.redirect_stdout(buf):
            exec(compile(B, "blk", "exec"), g)
    finally:
        if saved is not None:
            sys.modules["lage_xml"] = saved
        else:
            sys.modules.pop("lage_xml", None)
    return buf.getvalue()


GOOD_FS = ("import lage_xml\n"
           "def fetch_apotheken_notdienst():\n    root = lage_xml.fetch_root('u', 'a', timeout=1)\n    return root\n"
           "def fetch_news():\n    import lage_xml\n    def parse_feed(u):\n        return lage_xml.fetch_root(u, 'n')\n    return parse_feed\n")
WRAP_FS = ("import lage_xml\n"
           "def _w(orig):\n    def wrapped(*a, **k):\n        return orig(*a, **k)\n    return wrapped\n"
           "def fetch_apotheken_notdienst():\n    return lage_xml.fetch_root('u', 'a', timeout=1)\n"
           "def fetch_news():\n    import lage_xml\n    def parse_feed(u):\n        return lage_xml.fetch_root(u, 'n')\n    return parse_feed\n"
           "fetch_apotheken_notdienst = _w(fetch_apotheken_notdienst)\nfetch_news = _w(_w(fetch_news))\n")
BAD_WRAP_FS = WRAP_FS.replace("def fetch_apotheken_notdienst():\n    return lage_xml.fetch_root('u', 'a', timeout=1)\n", "def fetch_apotheken_notdienst():\n    import xml.etree.ElementTree as ET\n    lage_xml\n    return ET.fromstring(b'<a/>')\n")
NOFIND_FS = GOOD_FS + "fetch_apotheken_notdienst = lambda: None\n"
BAD_FS_ET = GOOD_FS.replace("    root = lage_xml.fetch_root('u', 'a', timeout=1)\n", "    import xml.etree.ElementTree as ET\n    root = ET.fromstring(b'<a/>')\n    lage_xml\n")


def behav(alt, new, blk):
    lx = import_lx()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % srv.server_address[1]
    try:
        ga, gn = load_funcs(alt, lx), load_funcs(new, lx)
        ra, la = run_all(ga, base)
        rn, ln = run_all(gn, base)
    finally:
        srv.shutdown()
        srv.server_close()
    fails = []
    for k in ("notdienst_ok", "feed_rss", "feed_bomrss", "feed_atom", "notdienst_500", "feed_500"):
        if ra[k] != rn[k]:
            fails.append("%s: alt %r neu %r" % (k, ra[k], rn[k]))
    if not rn["notdienst_ok"] or rn["notdienst_ok"][0][0] != "Apo 1":
        fails.append("Notdienst neu liefert nichts")
    if len(rn["feed_rss"]) != 2 or len(rn["feed_atom"]) != 1 or rn["feed_rss"] != rn["feed_bomrss"]:
        fails.append("Feeds neu falsch")
    for k in ("notdienst_bomb", "feed_bomb", "feed_big", "feed_gz"):
        v = rn[k]
        if not ((v == []) or (isinstance(v, dict) and v.get("items") == [] and v.get("count") == 0)):
            fails.append("%s: neu nicht abgelehnt: %r" % (k, str(v)[:100]))
    if "GEHEIM" in ln:
        fails.append("neu: URL-Token im Journal-Text")
    assert not fails, "; ".join(fails)
    B = rd(blk)
    ok = sandbox_block(B, GOOD_FS)
    assert "secXmlDash aktiv: secXmlDash ok" in ok and "FEHLER" not in ok, "Block-Selbsttest laeuft im sauberen Namensraum nicht durch: " + ok[:150]
    ok = sandbox_block(B, WRAP_FS)
    assert "secXmlDash aktiv: secXmlDash ok" in ok and "FEHLER" not in ok, "Selbsttest kommt mit umhuellten Funktionen (staleTs/keepLast) nicht zurecht: " + ok[:150]
    bad = sandbox_block(B, BAD_WRAP_FS)
    assert "FEHLER" in bad and "aktiv" not in bad, "Selbsttest erkennt ET hinter einer Huelle nicht"
    bad = sandbox_block(B, NOFIND_FS)
    assert "FEHLER" in bad and "aktiv" not in bad, "Selbsttest erkennt eine nicht auffindbare Originalfunktion nicht"
    bad = sandbox_block(B, BAD_FS_ET)
    assert "FEHLER" in bad and "aktiv" not in bad, "Selbsttest erkennt direkte ElementTree-Nutzung nicht"
    bad = sandbox_block(B, GOOD_FS, drop_fetch_root=True)
    assert "FEHLER" in bad, "Selbsttest erkennt fehlendes fetch_root nicht"
    return 4 + 9


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_SD_NOSTATIC") == "1" else static(alt, new, blk, edits)
    if os.environ.get("RH_SD_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk)
    print("OK guard secXmlDash: %d Pruefungen, 0 fehlerhaft" % n)
    return n


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    B = rd(blk).rstrip("\n")
    edits, anch = load_edits(ep)
    pre, post = base_new[:base_new.index(B)], base_new[base_new.index(B):]
    EA, EAP, EB, EBP = edits[0], edits[1], edits[2], edits[3]

    def rep(s, a, b):
        assert s.count(a) == 1, "%s: %d" % (a[:60], s.count(a))
        return s.replace(a, b, 1)
    M = []  # (Name, neu, block, norev)
    M.append(("M1 Notdienst-Edit zurueckgenommen", rep(pre, EA[1], EA[0]) + post, B, 1))
    M.append(("M2 News-Parse-Edit zurueckgenommen", rep(pre, EBP[1], EBP[0]) + post, B, 1))
    M.append(("M3 URL-Token-Edit zurueckgenommen", rep(pre, EAP[1], EAP[0]) + post, B, 1))
    M.append(("M4 News-Importe zurueckgenommen", rep(pre, EB[1], EB[0]) + post, B, 1))
    M.append(("M5 Notdienst-Timeout 150", rep(pre, "timeout=15, headers=headers)", "timeout=150, headers=headers)") + post, B, 1))
    M.append(("M6 News-Timeout 100", rep(pre, "timeout=10, headers={\"User-Agent\": \"Mozilla/5.0 KaeswasserLage/1.0\"})   # BOM", "timeout=100, headers={\"User-Agent\": \"Mozilla/5.0 KaeswasserLage/1.0\"})   # BOM") + post, B, 1))
    M.append(("M7 Quelle Notdienst umbenannt", rep(pre, '"apotheken-notdienst", timeout=15', '"x", timeout=15') + post, B, 1))
    M.append(("M8 Quelle News ohne Host", rep(pre, '"news:" + url.split("/")[2]', '"news"') + post, B, 1))
    M.append(("M9 Header Notdienst fehlt", rep(pre, 'lage_xml.fetch_root(APOTHEKEN_NOTDIENST_URL, "apotheken-notdienst", timeout=15, headers=headers)', 'lage_xml.fetch_root(APOTHEKEN_NOTDIENST_URL, "apotheken-notdienst", timeout=15)') + post, B, 1))
    M.append(("M10 Grenze vergroessert", rep(pre, 'timeout=15, headers=headers)   #', 'timeout=15, headers=headers, max_bytes=10**9)   #') if False else rep(pre, 'lage_xml.fetch_root(APOTHEKEN_NOTDIENST_URL, "apotheken-notdienst", timeout=15, headers=headers)', 'lage_xml.fetch_root(APOTHEKEN_NOTDIENST_URL, "apotheken-notdienst", timeout=15, headers=headers, max_bytes=10**9)') + post, B, 1))
    M.append(("M11 parse statt fetch_root", rep(pre, 'root = lage_xml.fetch_root(APOTHEKEN_NOTDIENST_URL', 'root = lage_xml.parse(APOTHEKEN_NOTDIENST_URL') + post, B, 1))
    M.append(("M12 Platzhalter fehlt", rep(pre, '"<Notdienst-URL>"', '""') + post, B, 1))
    M.append(("M13 stille Zusatzaenderung (Konstante)", rep(pre, "last_nina_received = None  # wann aktuelle Warnung zuerst gesehen", "last_nina_received = 0  # wann aktuelle Warnung zuerst gesehen") + post, B, 1))
    M.append(("M14 stille Zusatzaenderung (nur Text)", rep(pre, "def _fnum(x):\n", "def _fnum(x): \n") + post, B, 0))
    for nm, a, b in (("B1 Block ohne fetch_root-Pruefung", '    assert callable(getattr(_lx, "fetch_root", None)), "lage_xml.fetch_root fehlt (apply-secxml nicht angewendet?)"\n', ""),
                     ("B2 Block ohne ET-Pruefung", '            assert "ET" not in _names and "_rq" not in _names, "%s nutzt noch ElementTree oder den alten Abruf direkt" % _name\n', ""),
                     ("B6 Block ohne Suche in Huellen", '(getattr(_f, "__closure__", None) or ())', '()'),
                     ("B7 Block ohne Pruefung der Fundstelle", '        assert _orig, "%s: urspruengliche Funktion nicht auffindbar" % _name\n', ""),
                     ("B3 Block mit subprocess", "def _selftest_secxmldash():\n", "import subprocess\n\n\ndef _selftest_secxmldash():\n"),
                     ("B4 Block ohne Ende-Marker", "# ===== /secXmlDash =====", ""),
                     ("B5 Block schluckt Fehler still", '    print("secXmlDash Selbsttest FEHLER (%s)" % _sd_e, flush=True)\n', "    pass\n")):
        assert B.count(a) == 1, nm
        nb = B.replace(a, b)
        M.append((nm, pre + nb + post[len(B):], nb, 1))
    bad = []
    done = 0
    for name, mnew, mblk, norev in M:
        w = tempfile.mkdtemp(prefix="sd-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(mnew)
            bf = os.path.join(w, "blk.py")
            with open(bf, "w", encoding="utf-8") as f:
                f.write(mblk if mblk.endswith("\n") else mblk + "\n")
            if norev:
                os.environ["RH_SD_NOREV"] = "1"
            else:
                os.environ.pop("RH_SD_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, bf, ep)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            os.environ.pop("RH_SD_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)

    def edmut(name, fn):
        nonlocal done
        e2 = fn([tuple(x) for x in edits])
        w = tempfile.mkdtemp(prefix="sd-mut-")
        try:
            ef = os.path.join(w, "edits.py")
            with open(ef, "w", encoding="utf-8") as f:
                f.write("DSH_ANCHOR = %r\nDSH_EDITS = %r\n" % (anch, e2))
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new)
            os.environ.pop("RH_SD_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, blk, ef)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            shutil.rmtree(w, ignore_errors=True)
    edmut("E1 eine Stelle fehlt", lambda e: e[1:])
    edmut("E2 Stelle mit falschem Alttext (Rueckbau ungenau)", lambda e: [(e[0][0] + "# x\n", e[0][1])] + e[1:])
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation secXmlDash: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
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
        print("guard secXmlDash FEHLER: %s" % e)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach modDead commit32" "$KNOWN_D16N" "secXmlDash schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      secXmlDash passt nur auf den Stand Stand nach modDead commit32 (dashboard.py ee4ea3123eb561c4). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead kartevec; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- secXmlDash: Voraussetzung apply-secxml (lage_xml.py mit fetch_root im Projektordner) ----
LXF="$DASH_DIR/lage_xml.py"
[[ -f "$LXF" ]] || stop "lage_xml.py fehlt im Projektordner - zuerst apply-secxml anwenden (database.py e7a7ef192c522480, lage_xml.py f77305fc17ed2f77)"
grep -q "^def fetch_root(" "$LXF" || stop "lage_xml.py hat kein fetch_root - zuerst apply-secxml anwenden (lage_xml.py f77305fc17ed2f77)"
LX16=$(s16 "$LXF")
[[ "$LX16" == f77305fc17ed2f77 ]] && echo "OK Voraussetzung: lage_xml.py $LX16 (apply-secxml) mit fetch_root" || echo "HINWEIS lage_xml.py hat sha16 $LX16 (erwartet f77305fc17ed2f77) - fetch_root ist vorhanden, es wird nur das geprueft"
(cd "$DASH_DIR" && "$VPY" -c "import lage_xml; assert callable(lage_xml.fetch_root); print(lage_xml.selftest())") > "$W/lx.log" 2>&1 || { cat "$W/lx.log"; stop "lage_xml.py laesst sich mit $VPY nicht laden oder besteht den Selbsttest nicht"; }
echo "OK lage_xml mit $VPY geladen: $(tail -1 "$W/lx.log" | cut -c1-110)"
D16DB=$(s16 "$DASH_DIR/database.py" 2>/dev/null || echo fehlt)
[[ "$D16DB" == e7a7ef192c522480 ]] || echo "HINWEIS database.py sha16 $D16DB (apply-secxml liefert e7a7ef192c522480) - fuer dieses Programm nicht noetig"
export SECXML_LIBDIR="$DASH_DIR"
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
python3 "$PPK" secXmlDash dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer secXmlDash nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" secXmlDash dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: secXmlDash im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne secXmlDash ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard secXmlDash meldet Verstoss"; }
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
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: secXmlDash ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-secxmldash-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG secxmldash=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "secXmlDash|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-secxmldash-$TS" ]] && cp -a "$F.bak-secxmldash-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-secxmldash-$TS" ]] && { cmp -s "$F" "$F.bak-secxmldash-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK secXmlDash schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-secxmldash-$TS"
  { ls -1t "$F.bak-secxmldash-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-secxmldash-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-secxmldash-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'secXmlDash aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; secXmlDash aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- secXmlDash: Marker genau einmal, beide Abrufe nutzen lage_xml, News-Abruf und /news (nur Lesen) ----
SXM=$(grep -c "^# ===== secXmlDash:" "$F" || true); SXC=$(grep -c "lage_xml\.fetch_root(" "$F" || true); SXE=$(grep -c "xml\.etree\.ElementTree" "$F" || true)
[[ "$SXM" == 1 && "$SXC" == 2 ]] && echo "OK Marker secXmlDash 1x, lage_xml.fetch_root-Aufrufe 2x (Apotheken-Notdienst, News); direkte ElementTree-Importe in dashboard.py jetzt: $SXE" || rbx "Marker/Aufrufe secXmlDash falsch (Marker $SXM, Aufrufe $SXC)"
NK=$(code "$B/news"); [[ "$NK" == 200 ]] && echo "OK /news antwortet 200" || rbx "/news antwortet $NK"
NR=$("${CURL[@]}" -m 60 "$B/api/news_refresh" 2>/dev/null | python3 -c "import sys,json; j=json.load(sys.stdin); f=j.get('feeds') or []; print('OK' if j.get('ok') else 'NOK', len(f), sum(len(x.get('items') or []) for x in f))" 2>/dev/null || echo "NOK 0 0")
case "$NR" in OK*) echo "OK /api/news_refresh: ok, Feeds/Meldungen $NR (0 waere nur Netz/Quelle, nicht der Patch)" ;; *) rbx "/api/news_refresh liefert keine gueltige Antwort ($NR)" ;; esac
RJ=$(journalctl -u prepper-dashboard --since "$(date -d "-3 minutes" '+%Y-%m-%d %H:%M:%S')" --no-pager 2>/dev/null | grep -c "lage_xml:.*abgelehnt" || true)
echo "HINWEIS Quellen-Ablehnungen von lage_xml seit dem Neustart: ${RJ:-0} (0 ist normal; > 0 heisst: eine Quelle lieferte eine zu grosse/verbotene Antwort - Zeile 'lage_xml: <quelle> abgelehnt' im Journal)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E secXmlDash"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "secXmlDash aktiv: secXmlDash ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'secXmlDash aktiv: secXmlDash ok' ($(echo "$JD" | grep -F secXmlDash | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein secXmlDash-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead kartevec secXmlDash; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-secxmldash-$TS" ]] && echo "Backup: dashboard.py.bak-secxmldash-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-secxmldash-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine secxmldash-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c 'secXmlDash' /home/fmg/prepper-dashboard/dashboard.py"
echo "  grep -c 'lage_xml.fetch_root(' /home/fmg/prepper-dashboard/dashboard.py"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep secXmlDash"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG secxmldash=1 fertig"
