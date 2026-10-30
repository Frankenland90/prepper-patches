#!/bin/bash
set -eEuo pipefail
# pagesSplit1 (commit41): Modul-Aufteilung, Pilot: Vorlage der ADS-B-Seite (PAGE_ADSB, 354 Zeilen) unveraendert nach lage_pages.py (page_adsb(NAV_UNIFY)); dashboard.py importiert sie unter dem alten Namen; Seite, Route und Endpunkt unveraendert
# Aufruf: bash /tmp/apply-pagessplit1.sh commit41 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16, zwei Dateien): ALT = dashboard.py f8977a31bf4c177f (Stand nach asyncMini commit40) und lage_pages.py fehlt; NEU = dashboard.py 7ffa9d33c5fd4974 und lage_pages.py e7b3bb1ea1a145d3 (schon drin).
#   Jeder Mischstand -> STOP mit allen Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-pagessplit1-ZEIT (letzte 3); lage_pages.py ist neu (vorher nicht vorhanden, Rueckweg = entfernen). Keine Datenbank-Aenderung.
# Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
L="$DASH_DIR/lage_pages.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/pagessplit1-apply
KEEP_LAST=3
KNOWN_D16="f8977a31bf4c177f"      # dashboard.py vor pagesSplit1 (Basis: Stand nach asyncMini commit40)
KNOWN_D16N="7ffa9d33c5fd4974"             # dashboard.py nach pagesSplit1 (Ziel)
KNOWN_L16N="e7b3bb1ea1a145d3"             # lage_pages.py nach pagesSplit1 (neu; vorher nicht vorhanden)
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
echo "=== pagesSplit1 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Vorlage der ADS-B-Seite nach lage_pages.py verschieben (Text byte-gleich), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="2ef84309f39fabc2a4fb1c50f73d4227b612a21871c4c89fa57cd9a59c66fe91"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher pagesSplit1. Aufruf: patch-ps.py DASH_QUELLE MOD_QUELLE|- DASH_ZIEL MOD_ZIEL BLOCK EDITS
Basis (dashboard alt, lage_pages.py fehlt) -> beide Ziele erzeugen; schon drin (beide neu) -> Ziele = Quellen; Mischstand -> Exit 2.
Schreibt nur die Ziele (nie die Quellen)."""
import ast, hashlib, os, sys
ds, ms, dd, md, bp, ep = sys.argv[1:7]
g = {}
exec(compile(open(ep, encoding="utf-8").read(), ep, "exec"), g)
B = open(bp, encoding="utf-8").read().rstrip("\n")
s = open(ds, encoding="utf-8").read()
m = open(ms, encoding="utf-8").read() if ms != "-" and os.path.exists(ms) else None
NL, ANCH = g["NEW_LINES"], g["DSH_ANCHOR"]
has_new = s.count(NL) == 1 and s.count("\n\n" + B + ANCH) == 1
has_old = ("\n" + g["OLD_HEAD"] + "\n") in s
has_mark = "# ===== pagesSplit1:" in s or "lage_pages" in s
if has_new and not has_old:
    ok = m is not None and m.startswith(g["MOD_HEAD"]) and m.endswith(g["MOD_TAIL"]) and s.count("lage_pages") == 2 + B.count("lage_pages")
    if not ok:
        print("Mischstand: dashboard.py hat pagesSplit1, lage_pages.py fehlt oder weicht ab"); raise SystemExit(2)
    open(dd, "w", encoding="utf-8").write(s); open(md, "w", encoding="utf-8").write(m)
    print("dashboard.py + lage_pages.py: pagesSplit1 schon drin"); raise SystemExit(0)
if has_mark or m is not None:
    print("Mischstand: %s" % ("lage_pages.py existiert schon, dashboard.py ist aber die Basis" if not has_mark else "dashboard.py teilweise gepatcht")); raise SystemExit(2)
t = ast.parse(s)
nodes = [n for n in t.body if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id == g["NAME"] for x in n.targets)]
if len(nodes) != 1 or len(nodes[0].targets) != 1:
    print("dashboard.py: %s nicht genau einmal zugewiesen (%d)" % (g["NAME"], len(nodes))); raise SystemExit(2)
n = nodes[0]
names = sorted({x.id for x in ast.walk(n.value) if isinstance(x, ast.Name)})
seg = ast.get_source_segment(s, n.value)
if names != g["ARGS"] or hashlib.sha256(seg.encode()).hexdigest() != g["VALUE_SHA256"] or n.col_offset != 0:
    print("dashboard.py: Vorlage %s weicht vom erwarteten Text ab" % g["NAME"]); raise SystemExit(2)
L = s.split("\n")
old = "\n".join(L[n.lineno - 1:n.end_lineno])
if old != "PAGE_ADSB = " + seg or s.count("\n" + old + "\n") != 1:
    print("dashboard.py: Zuweisung nicht eindeutig"); raise SystemExit(2)
s2 = s.replace("\n" + old + "\n", "\n" + NL + "\n", 1)
if s2.count(ANCH) != 1:
    print("dashboard.py: Ankerstelle fehlt"); raise SystemExit(2)
i = s2.index(ANCH)
s2 = s2[:i] + "\n\n" + B + s2[i:]
open(dd, "w", encoding="utf-8").write(s2)
open(md, "w", encoding="utf-8").write(g["MOD_HEAD"] + seg + g["MOD_TAIL"])
print("dashboard.py: 1 Stelle + Block, lage_pages.py neu (%d Zeilen verschoben) pagesSplit1" % (n.end_lineno - n.lineno + 1))
MK_PAL_EOF
EXPECT_RAE="9929a43572d75718d3278fa03cc63f76ec83f3425ce3c4b489de09476930a1e9"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer pagesSplit1 (commit41): Basis dashboard.py f8977a31bf4c177f (Stand nach asyncMini commit40), lage_pages.py fehlt
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
NAME = "PAGE_ADSB"                       # Vorlage der ADS-B-Seite (Route /adsb)
FUNC = "page_adsb"                       # Funktion in lage_pages.py
ALIAS = "_lp_page_adsb"                  # Name in dashboard.py
ARGS = ["NAV_UNIFY"]                     # einzige freie Namen der Vorlage
VALUE_SHA256 = "81516afa7c046e9115c06db45d87393bf50d23dc8585bb284aed94f152e90814"  # Quelltext des Ausdrucks (byte-genau verschoben)
VALUE_LEN = 18084
OLD_HEAD = 'PAGE_ADSB = """'
NEW_LINES = ('from lage_pages import page_adsb as _lp_page_adsb  # pagesSplit1: Vorlage der ADS-B-Seite liegt in lage_pages.py\n'
             'PAGE_ADSB = _lp_page_adsb(NAV_UNIFY)')
MOD_HEAD = ('# ===== pagesSplit1: Seitenvorlagen aus dashboard.py (Modul-Aufteilung, Pilot: ADS-B-Seite); Text byte-genau verschoben; kein Netz, keine Dateien, sendet nichts =====\n'
            '"""lage_pages: Seitenvorlagen des Lage-Dashboards (nur Text). dashboard.py importiert sie unter den alten Namen (PAGE_ADSB = page_adsb(NAV_UNIFY))."""\n'
            '\n'
            'PAGES_SPLIT = "pagesSplit1"\n'
            '\n'
            '\n'
            'def page_adsb(NAV_UNIFY):\n'
            '    return ')
MOD_TAIL = '\n'
MK_RAE_EOF
EXPECT_RAB="381377596a360c32cbcb57ee2e887258c74c18e2c082290754bccec88c8bff0e"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== pagesSplit1: Vorlage der ADS-B-Seite (PAGE_ADSB) kommt aus lage_pages.py (Modul-Aufteilung, Pilot); Text unveraendert, Route und Endpunkt unveraendert; kein Netz, sendet nichts =====
def _selftest_pagessplit1():
    import os.path as _ps_path
    import lage_pages as _ps_mod
    assert _ps_path.dirname(_ps_path.abspath(_ps_mod.__file__)) == _ps_path.dirname(_ps_path.abspath(__file__)), "lage_pages.py nicht aus dem Projektordner"
    assert getattr(_ps_mod, "PAGES_SPLIT", None) == "pagesSplit1", "lage_pages.py ohne Kennung pagesSplit1"
    assert _lp_page_adsb is _ps_mod.page_adsb, "PAGE_ADSB nicht aus lage_pages.page_adsb"
    p = _ps_mod.page_adsb(NAV_UNIFY)
    assert isinstance(p, str) and p.count(NAV_UNIFY) == 1, "Vorlage ohne Navigation"
    assert "<title>K\u00e4swasser \u00b7 ADSB</title>" in p and p.rstrip().endswith("</body></html>"), "Vorlage ADS-B unvollstaendig"
    cur = globals().get("PAGE_ADSB")
    assert isinstance(cur, str) and (cur == p or cur.replace(_STALE_TS_JS.decode("utf-8"), "", 1) == p), "PAGE_ADSB weicht von lage_pages.page_adsb ab"
    return "pagesSplit1 ok (ADS-B-Seite aus lage_pages.py, %d Zeichen, gleich der Vorlage)" % len(p)


try:
    _PS_ST = _selftest_pagessplit1()
except Exception as _ps_e:
    _PS_ST = None
    print("pagesSplit1 Selbsttest FEHLER (%s: %s)" % (type(_ps_e).__name__, _ps_e), flush=True)
if _PS_ST:
    print("pagesSplit1 aktiv: %s" % _PS_ST, flush=True)
# ===== /pagesSplit1 =====
MK_RAB_EOF
EXPECT_RAG="c5c12cfdf697c1c5d5ff167491e0a9c1a1b1de21f4304576269313a2a8907e9b"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""Guard pagesSplit1 (dashboard.py: PAGE_ADSB -> Import + Zuweisung, Block pagesSplit1; neue Datei lage_pages.py). Aufruf:
  guard_ps.py revert NEU_VERZ ALT_VERZ BLOCK EDITS   -> ALT_VERZ/dashboard.py = NEU ohne pagesSplit1 (byte-genau, lage_pages.py entfaellt)
  guard_ps.py check  ALT_VERZ NEU_VERZ BLOCK EDITS   -> Rueckbau = ALT, AST (nur Zuweisung + Block), Modul nur Text, Vorlage gleich, Selbsttest neu ok / alt und Fehlvarianten FEHLER
  RH_ALT=ALT_VERZ guard_ps.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest (jede Mutation muss check scheitern lassen). Ohne node."""
import ast, contextlib, hashlib, importlib, io, os, shutil, sys, tempfile

rd = lambda p: open(p, encoding="utf-8").read()
FORBID = ("requests", "urlopen", "socket", "subprocess", "open(", "send_", "mesh", "telegram", "eval(", "exec(", "signal", "systemctl", "remove(", "unlink", "write")


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g


def revert_text(s, m, B, E):
    B = B.rstrip("\n")
    assert s.count("\n\n" + B + E["DSH_ANCHOR"]) == 1, "Block pagesSplit1 nicht genau einmal vor __main__"
    s = s.replace("\n\n" + B, "", 1)
    assert m.startswith(E["MOD_HEAD"]) and m.endswith(E["MOD_TAIL"]), "lage_pages.py Kopf/Ende unerwartet"
    seg = m[len(E["MOD_HEAD"]):len(m) - len(E["MOD_TAIL"])]
    assert s.count("\n" + E["NEW_LINES"] + "\n") == 1, "Import/Zuweisung nicht genau einmal"
    return s.replace("\n" + E["NEW_LINES"] + "\n", "\n%s = %s\n" % (E["NAME"], seg), 1)


def isname(n, k):
    return isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and n.targets[0].id == k


def cval(t, k):
    n = [x for x in t.body if isname(x, k)]
    assert len(n) == 1, k
    return eval(compile(ast.Expression(n[0].value), k, "eval"), {"__builtins__": {}}, {})


def run_selftest(B, gl, moddir):
    """gl: dict oder Funktion(lage_pages-Modul) -> dict; das Modul bleibt waehrend des Laufs in sys.modules (wie im Dashboard)."""
    sys.modules.pop("lage_pages", None)
    sys.path.insert(0, moddir)
    importlib.invalidate_caches()
    o = io.StringIO()
    try:
        if callable(gl):
            try:
                import lage_pages as lp
            except Exception as e:
                return "VARIANTE_KAPUTT Import lage_pages: %s" % e
            gl = gl(lp)
        with contextlib.redirect_stdout(o):
            exec(compile(B, "pagesSplit1-Block", "exec"), gl)
    except Exception as e:
        o.write("AUSNAHME %s" % e)
    finally:
        sys.path.remove(moddir)
        sys.modules.pop("lage_pages", None)
    return o.getvalue()


def load_mod(path):
    g = {"__name__": "lage_pages_probe"}
    exec(compile(rd(path), path, "exec"), g)
    return g


def check(altd, neud, bp, ep):
    E = load_edits(ep)
    da, dn, mn = os.path.join(altd, "dashboard.py"), os.path.join(neud, "dashboard.py"), os.path.join(neud, "lage_pages.py")
    A, N, B = rd(da), rd(dn), rd(bp)
    n, fails = 0, []

    def ok(c, msg):
        nonlocal n
        n += 1
        if not c:
            fails.append(msg)
    ok(not os.path.exists(os.path.join(altd, "lage_pages.py")), "Basis hat schon lage_pages.py")
    ok(os.path.isfile(mn), "lage_pages.py fehlt im Zielstand")
    if not os.path.isfile(mn):
        return n, fails
    M = rd(mn)
    try:
        ok(revert_text(N, M, B, E) == A, "Rueckbau ungleich Basis")
    except AssertionError as e:
        ok(False, "Rueckbau: %s" % e)
    ok("pagesSplit1" not in A and "lage_pages" not in A, "Basis unerwartet")
    try:
        tA, tN, tM, tB = ast.parse(A), ast.parse(N), ast.parse(M), ast.parse(B)
        ok(True, "")
    except SyntaxError as e:
        ok(False, "Syntax %s" % e)
        return n, fails
    # dashboard.py: nur PAGE_ADSB-Zuweisung -> Import + Zuweisung, plus Block
    iA = [k for k, x in enumerate(tA.body) if isname(x, E["NAME"])]
    ok(len(iA) == 1, "Basis: PAGE_ADSB nicht genau einmal")
    vA = tA.body[iA[0]].value
    dA = [ast.dump(x) for x in tA.body]
    rep = [ast.dump(x) for x in ast.parse(E["NEW_LINES"]).body]
    exp = dA[:iA[0]] + rep + dA[iA[0] + 1:]
    dB = [ast.dump(x) for x in tB.body]
    dN = [ast.dump(x) for x in tN.body]
    i = next((k for k in range(len(dN) - len(dB) + 1) if dN[k:k + len(dB)] == dB), None)
    ok(i is not None and dN[:i] + dN[i + len(dB):] == exp, "AST dashboard.py ausserhalb Zuweisung/Block veraendert")
    ok(rep == [ast.dump(x) for x in ast.parse("from lage_pages import page_adsb as _lp_page_adsb\nPAGE_ADSB = _lp_page_adsb(NAV_UNIFY)").body], "Import/Zuweisung nicht wie vorgesehen")
    rest = N.replace(B.rstrip("\n"), "", 1).replace(E["NEW_LINES"], "", 1)
    ok("lage_pages" not in rest and "_lp_page_adsb" not in rest and "pagesSplit1" not in rest, "lage_pages/_lp_page_adsb ausserhalb der vorgesehenen Stellen")
    # lage_pages.py: nur Text, eine Funktion mit genau dem alten Ausdruck
    ok(M.startswith(E["MOD_HEAD"]) and M.endswith(E["MOD_TAIL"]) and M.startswith("# ===== pagesSplit1:"), "Kopf/Ende lage_pages.py")
    seg = M[len(E["MOD_HEAD"]):len(M) - len(E["MOD_TAIL"])]
    ok(hashlib.sha256(seg.encode()).hexdigest() == E["VALUE_SHA256"] and len(seg) == E["VALUE_LEN"], "Vorlagentext nicht byte-genau (sha256)")
    b = tM.body
    shape = (len(b) == 3 and isinstance(b[0], ast.Expr) and isinstance(b[0].value, ast.Constant) and isinstance(b[0].value.value, str)
             and isname(b[1], "PAGES_SPLIT") and isinstance(b[1].value, ast.Constant) and b[1].value.value == "pagesSplit1"
             and isinstance(b[2], ast.FunctionDef) and b[2].name == E["FUNC"] and not b[2].decorator_list and b[2].returns is None
             and [a.arg for a in b[2].args.args] == E["ARGS"] and not b[2].args.defaults and not b[2].args.kwonlyargs
             and b[2].args.vararg is None and b[2].args.kwarg is None and not b[2].args.posonlyargs
             and len(b[2].body) == 1 and isinstance(b[2].body[0], ast.Return))
    ok(shape, "lage_pages.py: Aufbau nicht nur Kennung + page_adsb(NAV_UNIFY) mit return")
    ok(shape and ast.dump(b[2].body[0].value) == ast.dump(vA), "page_adsb liefert nicht den alten Ausdruck (AST)")
    ok(not any(isinstance(x, (ast.Import, ast.ImportFrom, ast.Call, ast.Attribute, ast.Global, ast.Lambda)) for x in ast.walk(tM)), "lage_pages.py enthaelt Code ausser Text")
    # Wert gleich: echtes NAV_UNIFY und Platzhalter
    try:
        nav = cval(tA, "NAV_UNIFY")
        old = lambda v: eval(compile(ast.Expression(vA), "alt", "eval"), {"__builtins__": {}}, {"NAV_UNIFY": v})
        mg = load_mod(mn)
        ok(mg["page_adsb"](nav) == old(nav) and mg["page_adsb"]("<NAV/>") == old("<NAV/>"), "Vorlage alt/neu ungleich")
    except Exception as e:
        ok(False, "Wertvergleich: %s" % e)
        return n, fails
    # Block
    C = " ".join(l.split("#")[0] for l in B.splitlines())
    for f in FORBID:
        ok(f not in C, "verboten im Block: " + f)
    stjs = [x for x in tA.body if isname(x, "_STALE_TS_JS")]
    sts = eval(compile(ast.Expression(stjs[0].value), "st", "eval"), {"__builtins__": {}}, {}) if stjs else b""
    snip = sts.decode("utf-8")
    page = mg["page_adsb"](nav)
    emb = page.replace("</body>", snip + "</body>", 1)
    with tempfile.TemporaryDirectory() as d:
        pd, od = os.path.join(d, "proj"), os.path.join(d, "fremd")
        os.makedirs(pd); os.makedirs(od)
        shutil.copy(mn, pd)
        fake = os.path.join(pd, "dashboard.py")

        def gl(**kw):
            def mk(lp):
                g = {"__name__": "x", "__file__": fake, "NAV_UNIFY": nav, "_STALE_TS_JS": sts, "PAGE_ADSB": emb, "_lp_page_adsb": lp.page_adsb}
                g.update(kw)
                return g
            return mk
        good = "pagesSplit1 aktiv: pagesSplit1 ok"
        for nm, g, md in (("eingebettet", gl(), pd), ("ohne staleTs", gl(PAGE_ADSB=page), pd)):
            so = run_selftest(B, g, md)
            ok(good in so and "FEHLER" not in so, "Selbsttest neu (%s): %r" % (nm, so[:140]))
        so = run_selftest(B, {"__name__": "x", "__file__": os.path.join(od, "dashboard.py"), "NAV_UNIFY": nav, "_STALE_TS_JS": sts, "PAGE_ADSB": old(nav)}, od)
        ok("pagesSplit1 Selbsttest FEHLER" in so and "aktiv" not in so, "Selbsttest schlaegt am alten Stand nicht an")
        # Fehlvarianten
        shutil.copy(mn, od)
        mnk = os.path.join(d, "nokenn"); os.makedirs(mnk)
        open(os.path.join(mnk, "lage_pages.py"), "w", encoding="utf-8").write(M.replace('PAGES_SPLIT = "pagesSplit1"', 'PAGES_SPLIT = "x"', 1))
        mtt = os.path.join(d, "notitle"); os.makedirs(mtt)
        open(os.path.join(mtt, "lage_pages.py"), "w", encoding="utf-8").write(M.replace("<title>K\u00e4swasser \u00b7 ADSB</title>", "<title>x</title>", 1))
        mnv = os.path.join(d, "nonav"); os.makedirs(mnv)
        open(os.path.join(mnv, "lage_pages.py"), "w", encoding="utf-8").write(M.replace('""" + NAV_UNIFY + """', '""" + """', 1))

        def modg(md, **kw):
            def mk(lp):
                g = {"__name__": "x", "__file__": os.path.join(md, "dashboard.py"), "NAV_UNIFY": nav, "_STALE_TS_JS": sts, "_lp_page_adsb": lp.page_adsb, "PAGE_ADSB": lp.page_adsb(nav)}
                g.update(kw)
                return g
            return mk
        for nm, g, md in (("Modul aus fremdem Ordner", gl(), od),  # __file__ im Projektordner, Modul aus fremdem Ordner
                          ("andere Funktion", gl(_lp_page_adsb=lambda v: page), pd),
                          ("PAGE_ADSB geaendert", gl(PAGE_ADSB=emb.replace("ADSB", "ADS-B", 1)), pd),
                          ("ohne Kennung", modg(mnk), mnk),
                          ("ohne Titel", modg(mtt), mtt),
                          ("ohne Navigation", modg(mnv), mnv)):
            so = run_selftest(B, g, md)
            ok("pagesSplit1 Selbsttest FEHLER" in so and "aktiv" not in so, "Selbsttest erkennt nicht: %s (%r)" % (nm, so[:100]))
    return n, fails


MUT = [  # (Ziel, alt, neu): dash = dashboard.py, mod = lage_pages.py, blk = Block
    ("dash", "PAGE_ADSB = _lp_page_adsb(NAV_UNIFY)", "PAGE_ADSB = _lp_page_adsb(NAV_UNIFY + '')"),
    ("dash", "from lage_pages import page_adsb as _lp_page_adsb", "from lage_pages import page_adsb as _lp_page_adsb, PAGES_SPLIT"),
    ("dash", "RS_TOTAL_S = 4.0", "RS_TOTAL_S = 5.0"),
    ("dash", 'PAGE_NEWS = """<!DOCTYPE html>', 'PAGE_NEWS = """<!DOCTYPE  html>'),
    ("dash", "    return render_template_string(PAGE_ADSB, adsb=adsb)", "    return render_template_string(PAGE_ADSB + '', adsb=adsb)"),
    ("mod", "<title>K\u00e4swasser \u00b7 ADSB</title>", "<title>K\u00e4swasser \u00b7 ADS-B</title>"),
    ("mod", 'PAGES_SPLIT = "pagesSplit1"\n', 'PAGES_SPLIT = "pagesSplit1"\nimport os\n'),
    ("mod", 'PAGES_SPLIT = "pagesSplit1"', 'PAGES_SPLIT = "pagesSplit2"'),
    ("mod", "def page_adsb(NAV_UNIFY):", "def page_adsb(NAV_UNIFY=''):"),
    ("mod", '""" + NAV_UNIFY + """', '""" + NAV_UNIFY.strip() + """'),
    ("mod", "# ===== pagesSplit1: Seitenvorlagen", "# pagesSplit1: Seitenvorlagen"),
    ("mod", "</body></html>\n", "</body></html> \n"),
    ("blk", '    assert _lp_page_adsb is _ps_mod.page_adsb, "PAGE_ADSB nicht aus lage_pages.page_adsb"\n', ""),
    ("blk", '    assert _ps_path.dirname(_ps_path.abspath(_ps_mod.__file__)) == _ps_path.dirname(_ps_path.abspath(__file__)), "lage_pages.py nicht aus dem Projektordner"\n', ""),
    ("blk", '    assert getattr(_ps_mod, "PAGES_SPLIT", None) == "pagesSplit1", "lage_pages.py ohne Kennung pagesSplit1"\n', ""),
    ("blk", "    _PS_ST = _selftest_pagessplit1()", "    _PS_ST = 'pagesSplit1 ok'"),
    ("blk", '    print("pagesSplit1 aktiv: %s" % _PS_ST, flush=True)', '    print("pagesSplit1: %s" % _PS_ST, flush=True)'),
    ("blk", "    return \"pagesSplit1 ok", "    open('/tmp/x', 'w')\n    return \"pagesSplit1 ok"),
    ("blk", "(cur == p or cur.replace(", "(True or cur.replace("),
    ("blk", 'p.count(NAV_UNIFY) == 1, "Vorlage ohne Navigation"', 'p.count(NAV_UNIFY) >= 0, "Vorlage ohne Navigation"'),
    ("blk", '"<title>K\\u00e4swasser \\u00b7 ADSB</title>" in p and ', ""),
]


def mutate(altd, neud, bp, ep):
    B, N, M, miss = rd(bp), rd(os.path.join(neud, "dashboard.py")), rd(os.path.join(neud, "lage_pages.py")), 0
    for i, (tg, o, nw) in enumerate(MUT, 1):
        src = {"blk": B, "dash": N, "mod": M}[tg]
        if src.count(o) != 1:
            print("UEBERSEHEN Mutation %d Stelle nicht eindeutig (%d)" % (i, src.count(o)))
            miss += 1
            continue
        with tempfile.TemporaryDirectory() as d:
            bp2 = os.path.join(d, "blk.py")
            B2, N2, M2 = B, N, M
            if tg == "blk":
                B2 = B.replace(o, nw, 1)
                N2 = N.replace(B.rstrip("\n"), B2.rstrip("\n"), 1)
            elif tg == "dash":
                N2 = N.replace(o, nw, 1)
            else:
                M2 = M.replace(o, nw, 1)
            open(bp2, "w", encoding="utf-8").write(B2)
            open(os.path.join(d, "dashboard.py"), "w", encoding="utf-8").write(N2)
            open(os.path.join(d, "lage_pages.py"), "w", encoding="utf-8").write(M2)
            try:
                _, f = check(altd, d, bp2, ep)
            except Exception as e:
                f = ["Ausnahme %s: %s" % (type(e).__name__, e)]
        print("%s Mutation %2d (%s): %s" % ("OK" if f else "UEBERSEHEN", i, tg, (f[0] if f else o.strip()[:60])[:110]))
        miss += 0 if f else 1
    print("%s Mutationstest pagesSplit1: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", len(MUT), miss))
    return miss


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "revert":
        nd, ad = sys.argv[2], sys.argv[3]
        open(os.path.join(ad, "dashboard.py"), "w", encoding="utf-8").write(
            revert_text(rd(os.path.join(nd, "dashboard.py")), rd(os.path.join(nd, "lage_pages.py")), rd(sys.argv[4]), load_edits(sys.argv[5])))
        print("OK Rueckbau pagesSplit1 byte-genau erzeugt (dashboard.py ohne Import, Vorlage wieder eingesetzt; lage_pages.py entfaellt)")
    elif cmd == "check":
        n, f = check(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        for x in f:
            print("FEHLER", x)
        print("%s Guard pagesSplit1: %d Pruefungen, %d Fehler (Rueckbau byte-genau, AST nur Zuweisung+Block, Modul nur Text, Vorlage alt=neu, Selbsttest + 6 Fehlvarianten, ohne node)" % ("OK" if not f else "FEHLER", n, len(f)))
        sys.exit(1 if f else 0)
    elif cmd == "mutate":
        sys.exit(1 if mutate(os.environ["RH_ALT"], sys.argv[2], sys.argv[3], sys.argv[4]) else 0)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach asyncMini commit40" "$KNOWN_D16N" "pagesSplit1 schon drin"))"
if [[ -e "$L" || -L "$L" ]]; then L16=$(s16 "$L"); echo "Basis lage_pages.py sha16 $L16 ($(wc -l < "$L") Zeilen, $(lbl "$L16" "$KNOWN_L16N" "pagesSplit1 schon drin"))"; else L16=fehlt; echo "Basis lage_pages.py: fehlt (erwartet vor pagesSplit1)"; fi
ST=MISCH
[[ "$D16" == "$KNOWN_D16" && "$L16" == fehlt ]] && ST=ALT
[[ "$D16" == "$KNOWN_D16N" && "$L16" == "$KNOWN_L16N" && ! -L "$L" ]] && ST=NEU
if [[ "$ST" == MISCH && ( "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ) ]]; then
  echo "STOP: Mischstand - dashboard.py $D16 ($(lbl "$D16" "$KNOWN_D16" "alt" "$KNOWN_D16N" "neu")), lage_pages.py $L16 - nichts geaendert."
  echo "      Erlaubt sind nur: ALT (dashboard.py $KNOWN_D16 und lage_pages.py fehlt) oder NEU (dashboard.py $KNOWN_D16N und lage_pages.py $KNOWN_L16N). Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      pagesSplit1 passt nur auf den Stand Stand nach asyncMini commit40 (dashboard.py f8977a31bf4c177f). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
FOWN=$(stat -c %U:%G "$F"); FMOD=$(stat -c %a "$F")
[[ "$(id -un)" == "$(stat -c %U "$F")" ]] || stop "Skript laeuft als $(id -un), dashboard.py gehoert $(stat -c %U "$F") - bitte als $(stat -c %U "$F") starten (lage_pages.py soll denselben Eigentuemer bekommen)"
id -nG | tr ' ' '\n' | grep -qx "$(stat -c %G "$F")" || stop "Benutzer $(id -un) ist nicht in der Gruppe $(stat -c %G "$F") von dashboard.py"
echo "OK Eigentuemer/Rechte dashboard.py: $FOWN $FMOD (lage_pages.py bekommt dieselben)"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- pagesSplit1: Neustart-Sperre HH:55-HH:04 (jede Stunde, Berlin-Zeit); geprueft jetzt und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${PAGESSPLIT1_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$PAGESSPLIT1_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$ST" == NEU ]]; then echo "OK Neustart-Sperre: pagesSplit1 ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - zwischen HH:55 und HH:04 wird prepper-dashboard nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04 ($1)"; fi; }
rscheck "Vorpruefung"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" || "$f" == "$L" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
LSRC=-; [[ "$ST" == NEU ]] && LSRC="$L"
python3 "$PPK" "$F" "$LSRC" "$W/work/dashboard.py" "$W/work/lage_pages.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py/lage_pages.py: Stelle fuer pagesSplit1 nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py"); NL16=$(s16 "$W/work/lage_pages.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
[[ "$NL16" == "$KNOWN_L16N" ]] || stop "Ergebnis lage_pages.py $NL16 statt $KNOWN_L16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen), lage_pages.py $NL16 ($(wc -l < "$W/work/lage_pages.py") Zeilen) - $(cat "$W/q.log")"
python3 "$PPK" "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/work/x.py" "$W/work/y.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" && cmp -s "$W/work/lage_pages.py" "$W/work/y.py" || stop "nicht idempotent (zweite Anwendung aendert dashboard.py oder lage_pages.py)"
rm -f "$W/work/x.py" "$W/work/y.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/lage_pages.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, lage_pages.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/neu/"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: pagesSplit1 im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne pagesSplit1 ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
[[ ! -e "$W/alt/lage_pages.py" ]] || stop "AST-Guard: Rueckbau enthaelt lage_pages.py"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard pagesSplit1 meldet Verstoss"; }
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
# ---- pagesSplit1: Zustand vorher (nur Lesen): ADS-B-Seite ----
"${CURL[@]}" "$B/adsb" -o "$W/adsb0.html" -w "%{http_code}" > "$W/adsb0.code" || true
AC0=$(cat "$W/adsb0.code" 2>/dev/null || echo 000)
echo "Zustand vorher: /adsb HTTP $AC0, $(wc -c < "$W/adsb0.html" 2>/dev/null || echo 0) Bytes, Titel $(grep -c 'ADSB</title>' "$W/adsb0.html" || true)x, Navigation $(grep -c 'navUnify' "$W/adsb0.html" || true)x, staleTs $(grep -c 'staleTsBoot' "$W/adsb0.html" || true)x"
rscheck "vor dem Neustart"
NEED_D=0; [[ "$ST" == ALT ]] && NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: pagesSplit1 ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: lage_pages.py neu anlegen ($FOWN, $FMOD) und dashboard.py ersetzen (Sicherung dashboard.py.bak-pagessplit1-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG pagessplit1=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "pagesSplit1|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-pagessplit1-$TS" ]] && cp -a "$F.bak-pagessplit1-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$ST" == ALT ]]; then rm -f -- "$L" "$L.new" "$DASH_DIR"/__pycache__/lage_pages.*.pyc; [[ -e "$L" ]] && echo "  WARNUNG lage_pages.py noch da" || echo "  lage_pages.py entfernt (war vorher nicht da)"; fi
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-pagessplit1-$TS" ]] && { cmp -s "$F" "$F.bak-pagessplit1-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK pagesSplit1 schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-pagessplit1-$TS"
  { ls -1t "$F.bak-pagessplit1-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/lage_pages.py" "$L.new" && chmod "$FMOD" "$L.new" && chown "$FOWN" "$L.new" && mv -f "$L.new" "$L" || { rb "lage_pages.py konnte nicht angelegt werden"; exit 1; }
  [[ "$(s16 "$L")" == "$KNOWN_L16N" && "$(stat -c '%U:%G %a' "$L")" == "$FOWN $FMOD" ]] || { rb "lage_pages.py nach dem Anlegen falsch ($(s16 "$L"), $(stat -c '%U:%G %a' "$L" 2>/dev/null))"; exit 1; }
  echo "OK lage_pages.py atomar angelegt ($KNOWN_L16N, $(stat -c '%U:%G %a' "$L"), gleiche Rechte wie dashboard.py)"
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-pagessplit1-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(stat -c '%U:%G %a' "$F")" == "$FOWN $FMOD" ]] || { rb "dashboard.py Eigentuemer/Rechte veraendert ($(stat -c '%U:%G %a' "$F"))"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-pagessplit1-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'pagesSplit1 aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; pagesSplit1 aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- pagesSplit1: Marker, Import, ADS-B-Seite wie vorher ----
PSM=$(grep -c "^# ===== pagesSplit1:" "$F" || true); PSI=$(grep -c "^from lage_pages import page_adsb as _lp_page_adsb" "$F" || true); PSO=$(grep -c '^PAGE_ADSB = """' "$F" || true)
[[ "$PSM" == 1 && "$PSI" == 1 && "$PSO" == 0 ]] && echo "OK Marker pagesSplit1 1x, Import 1x, alte Vorlage in dashboard.py 0x" || rbx "dashboard.py pagesSplit1 falsch (Marker ${PSM}x, Import ${PSI}x, alte Vorlage ${PSO}x)"
"${CURL[@]}" "$B/adsb" -o "$W/adsb1.html" -w "%{http_code}" > "$W/adsb1.code" || true
AC1=$(cat "$W/adsb1.code" 2>/dev/null || echo 000)
[[ "$AC1" == "$AC0" ]] || rbx "/adsb antwortet $AC1 (vorher $AC0)"
if [[ "$AC1" == 200 ]]; then
  for k in 'ADSB</title>' 'navUnify' 'staleTsBoot' '</body></html>'; do
    a=$(grep -c "$k" "$W/adsb0.html" || true); b=$(grep -c "$k" "$W/adsb1.html" || true)
    [[ "$a" == "$b" && "$b" -ge 1 ]] || rbx "/adsb: '$k' ${b}x (vorher ${a}x)"
  done
  if cmp -s "$W/adsb0.html" "$W/adsb1.html"; then echo "OK /adsb: HTML byte-gleich wie vorher ($(wc -c < "$W/adsb1.html") Bytes)"
  else
    sed 's/[0-9]/0/g' "$W/adsb0.html" > "$W/adsb0.n"; sed 's/[0-9]/0/g' "$W/adsb1.html" > "$W/adsb1.n"
    DL=$(diff "$W/adsb0.n" "$W/adsb1.n" | grep -c '^[<>]' || true)
    echo "OK /adsb: HTTP 200, Titel/Navigation/staleTs/Seitenende wie vorher; HTML nicht byte-gleich, weil Live-Werte sich geaendert haben ($DL Zeilen ohne Ziffern verschieden, Vorlage selbst ist im Trockenlauf als byte-gleich nachgewiesen)"
  fi
fi
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E pagesSplit1"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "pagesSplit1 aktiv: pagesSplit1 ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'pagesSplit1 aktiv: pagesSplit1 ok' ($(echo "$JD" | grep -F pagesSplit1 | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'pagesSplit1 Selbsttest FEHLER|No module named .lage_pages|cannot import name .page_adsb|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'pagesSplit1 Selbsttest FEHLER|No module named .lage_pages|cannot import name .page_adsb|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein pagesSplit1-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
[[ "$(s16 "$L")" == "$KNOWN_L16N" && "$(stat -c '%U:%G %a' "$L")" == "$FOWN $FMOD" && "$(s16 "$F")" == "$KNOWN_D16N" ]] && echo "OK lage_pages.py $(s16 "$L") ($(stat -c '%U:%G %a' "$L")) und dashboard.py $(s16 "$F") ($(stat -c '%U:%G %a' "$F")) wie erwartet" || rbx "Endstand Dateien falsch: dashboard.py $(s16 "$F"), lage_pages.py $(s16 "$L" 2>/dev/null) $(stat -c '%U:%G %a' "$L" 2>/dev/null)"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-pagessplit1-$TS" ]] && echo "Backup: dashboard.py.bak-pagessplit1-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen; lage_pages.py sha16 $(s16 "$L"), $(wc -c < "$L") Bytes, $(wc -l < "$L") Zeilen"
LB=$({ ls -1t "$F.bak-pagessplit1-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && rm -f $L && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine pagessplit1-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c pagesSplit1 /home/fmg/prepper-dashboard/dashboard.py"
echo "  ls -l /home/fmg/prepper-dashboard/lage_pages.py /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s -o /dev/null -w %{http_code} http://127.0.0.1:5000/adsb   (200 erwartet)"
echo "  sudo journalctl -u prepper-dashboard --since -1h --no-pager | grep -E 'pagesSplit1|asyncMini'"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep pagesSplit1"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (Auftrag: kein Docs-Update)."
echo "COMMIT $COMMIT_ARG pagessplit1=1 fertig"
