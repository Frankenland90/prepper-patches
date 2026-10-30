#!/bin/bash
set -eEuo pipefail
# pagesSplit3 (commit43): Modul-Aufteilung, Schritt 3: 4 Seitenvorlagen (PAGE1, PAGE2, PAGE3, PAGE_LOKALE_ENERGIE; 1755 Zeilen) unveraendert nach lage_pages.py; dashboard.py importiert sie unter den alten Namen; Seiten, Routen und Endpunkte unveraendert
# Aufruf: bash /tmp/apply-pagessplit3.sh commit43 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16, zwei Dateien): ALT = dashboard.py 6661a7f77b1e1487 (Stand nach pagesSplit2 commit42) und lage_pages.py 6a596584014df095; NEU = dashboard.py 64a83af070677323 und lage_pages.py 231d4c309c1ae009 (schon drin).
#   Jeder Mischstand -> STOP mit allen Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-pagessplit3-ZEIT und lage_pages.py.bak-pagessplit3-ZEIT (je letzte 3; lage_pages.py nur, wenn sie vorher da war, sonst Rueckweg = entfernen). Keine Datenbank-Aenderung.
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
W=/tmp/pagessplit3-apply
KEEP_LAST=3
KNOWN_D16="6661a7f77b1e1487"      # dashboard.py vor pagesSplit3 (Basis: Stand nach pagesSplit2 commit42)
KNOWN_D16N="64a83af070677323"             # dashboard.py nach pagesSplit3 (Ziel)
KNOWN_L16="6a596584014df095"             # lage_pages.py vor pagesSplit3 (leer = fehlt)
KNOWN_L16N="231d4c309c1ae009"             # lage_pages.py nach pagesSplit3
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
echo "=== pagesSplit3 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): 4 Seitenvorlagen nach lage_pages.py verschieben (Text byte-gleich), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="7b4308e1d4b511bb127d00e367a81b56bb89640ed519043027dadfb8b01938dc"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher pagesSplit (generisch, Daten aus EDITS). Aufruf: patch_pages.py DASH_QUELLE MOD_QUELLE|- DASH_ZIEL MOD_ZIEL BLOCK EDITS
Basis -> beide Ziele erzeugen; schon drin -> Ziele = Quellen; Mischstand/unerwarteter Text -> Exit 2. Schreibt nur die Ziele."""
import ast, hashlib, os, sys
ds, ms, dd, md, bp, ep = sys.argv[1:7]
E = {}
exec(compile(open(ep, encoding="utf-8").read(), ep, "exec"), E)
LB, P = E["LABEL"], E["PAGES"]
B = open(bp, encoding="utf-8").read().rstrip("\n")
s = open(ds, encoding="utf-8").read()
m = open(ms, encoding="utf-8").read() if ms != "-" and os.path.exists(ms) else None
ANCH = E["DSH_ANCHOR"]
NLS = [E["new_lines"](p[0], p[1], p[2]) for p in P]
has_new = all(s.count("\n" + x + "\n") == 1 for x in NLS) and s.count("\n\n" + B + ANCH) == 1
any_new = any(x in s for x in NLS) or ("# ===== %s:" % LB) in s
if has_new:
    ok = m is not None and m.count(E["SPLIT_HEAD"]) == 1 and all(("\ndef %s(" % p[1]) in m for p in P)
    if not ok:
        print("Mischstand: dashboard.py hat %s, lage_pages.py nicht" % LB); raise SystemExit(2)
    open(dd, "w", encoding="utf-8").write(s); open(md, "w", encoding="utf-8").write(m)
    print("dashboard.py + lage_pages.py: %s schon drin" % LB); raise SystemExit(0)
if any_new:
    print("dashboard.py: %s teilweise vorhanden" % LB); raise SystemExit(2)
if (m is None) == E["MOD_BASE"] or (m is not None and E["SPLIT_HEAD"] in m):
    print("Mischstand: lage_pages.py %s" % ("fehlt" if m is None else "passt nicht zur Basis")); raise SystemExit(2)
t = ast.parse(s)
L = s.split("\n")
rep = {}
mod_add = E["SPLIT_HEAD"]
for name, fn, args, h, ln, *_ in P:
    nodes = [n for n in t.body if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and n.targets[0].id == name]
    if len(nodes) != 1 or nodes[0].col_offset != 0:
        print("dashboard.py: %s nicht genau einmal zugewiesen" % name); raise SystemExit(2)
    n = nodes[0]
    seg = ast.get_source_segment(s, n.value)
    if tuple(sorted({x.id for x in ast.walk(n.value) if isinstance(x, ast.Name)})) != tuple(args) or hashlib.sha256(seg.encode()).hexdigest() != h or len(seg) != ln:
        print("dashboard.py: Vorlage %s weicht vom erwarteten Text ab" % name); raise SystemExit(2)
    old = "\n".join(L[n.lineno - 1:n.end_lineno])
    if old != "%s = %s" % (name, seg) or s.count("\n" + old + "\n") != 1:
        print("dashboard.py: Zuweisung %s nicht eindeutig" % name); raise SystemExit(2)
    rep[name] = (old, E["new_lines"](name, fn, args))
    mod_add += E["fn_text"](fn, args, seg)
for name, (old, new) in rep.items():
    s = s.replace("\n" + old + "\n", "\n" + new + "\n", 1)
if s.count(ANCH) != 1:
    print("dashboard.py: Ankerstelle fehlt"); raise SystemExit(2)
i = s.index(ANCH)
s = s[:i] + "\n\n" + B + s[i:]
m2 = (m if m is not None else E["MOD_HEAD1"]) + mod_add
open(dd, "w", encoding="utf-8").write(s)
open(md, "w", encoding="utf-8").write(m2)
print("dashboard.py: %d Vorlagen + Block, lage_pages.py +%d Funktionen (%d Zeilen verschoben) %s" % (len(P), len(P), sum(p[6] for p in P), LB))
MK_PAL_EOF
EXPECT_RAE="9bced974e75027257647feb39fc2652b31a8ed14d1888e280c498013bfb951d4"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer pagesSplit3 (commit43), erzeugt von mk_pages_cfg.py aus der Namensliste. Basis dashboard.py 6661a7f77b1e1487, lage_pages.py 6a596584014df095
LABEL = "pagesSplit3"
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
MOD_BASE = True  # lage_pages.py in der Basis vorhanden
# (Name, Funktion in lage_pages.py, Argumente, sha256 Quelltext des Ausdrucks, Laenge, Zeile in der Basis, Zeilen, Routen)
PAGES = [
    ('PAGE1', 'page1', ('BASE_STYLE', 'NAV_UNIFY'), '3dd0de233a55bf32473176f2361b47fff2b4b3456609c7dd548f7d9bf89e7b07', 22524, 3941, 507, ('/',)),
    ('PAGE2', 'page2', ('BASE_STYLE', 'NAV_UNIFY'), 'd2736df8aa773bc0e1e9d0ff205703dd47cb205e41892e256e519698038fb035', 27752, 4449, 592, ('/energie',)),
    ('PAGE3', 'page3', ('BASE_STYLE', 'NAV_UNIFY'), '9fa15f7ef31d4d4e71773dfd3fa14f77086fd92771b8d2857ced02cffd2f63f0', 22494, 5042, 443, ('/system', '/umwelt')),
    ('PAGE_LOKALE_ENERGIE', 'page_lokale_energie', ('BASE_STYLE', 'NAV_UNIFY'), 'a9dc1fc86d318c722a38b7f4b1948086bd43910a48cfc3582e3613a56b886ea0', 9285, 6187, 213, ('/lokal', '/lokale-energie')),
]
SPLIT_HEAD = "\n\n# ===== pagesSplit3: Seitenvorlagen PAGE1, PAGE2, PAGE3, PAGE_LOKALE_ENERGIE (byte-genau aus dashboard.py verschoben, nur Text) =====\n"
MOD_HEAD1 = '"""lage_pages: Seitenvorlagen des Lage-Dashboards (nur Text)."""\n'  # nur falls lage_pages.py neu entsteht


def new_lines(name, fn, args):
    return "from lage_pages import %s as _lp_%s  # %s: Vorlage liegt in lage_pages.py\n%s = _lp_%s(%s)" % (fn, fn, LABEL, name, fn, ", ".join(args))


def fn_prefix(fn, args):
    return "\n\ndef %s(%s):\n    return " % (fn, ", ".join(args))


def fn_text(fn, args, seg):
    return fn_prefix(fn, args) + seg + "\n"
MK_RAE_EOF
EXPECT_RAB="c4c575291b178c4c32e473be7c2e49fe17f51a6236cee98051b846df9c573aba"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== pagesSplit3: Seitenvorlagen PAGE1, PAGE2, PAGE3, PAGE_LOKALE_ENERGIE kommen aus lage_pages.py (Modul-Aufteilung); Text unveraendert, Routen und Endpunkte unveraendert; kein Netz, sendet nichts =====
_PAGESSPLIT3_PAGES = (
    ('PAGE1', 'page1', ('BASE_STYLE', 'NAV_UNIFY')),
    ('PAGE2', 'page2', ('BASE_STYLE', 'NAV_UNIFY')),
    ('PAGE3', 'page3', ('BASE_STYLE', 'NAV_UNIFY')),
    ('PAGE_LOKALE_ENERGIE', 'page_lokale_energie', ('BASE_STYLE', 'NAV_UNIFY')),
)


def _selftest_pagessplit3():
    import os.path as _ps_path
    import lage_pages as _ps_mod
    assert _ps_path.dirname(_ps_path.abspath(_ps_mod.__file__)) == _ps_path.dirname(_ps_path.abspath(__file__)), "lage_pages.py nicht aus dem Projektordner"
    snip = _STALE_TS_JS.decode("utf-8")
    g = globals()
    extra = [g["_pat_html"](k) for k in (g.get("_PAT_ANCH") or {})] if callable(g.get("_pat_html")) else []

    def _norm(x):  # bekannte Laufzeit-Schicht priceAllTime-Zeilen (staleTs separat)
        for e in extra:
            x = x.replace(e, "", 1)
        return x
    for name, fn, args in _PAGESSPLIT3_PAGES:
        f = getattr(_ps_mod, fn, None)
        assert f is not None and g.get("_lp_" + fn) is f, "%s nicht aus lage_pages.%s" % (name, fn)
        p = f(*[g[a] for a in args])
        assert isinstance(p, str) and all(p.count(g[a]) >= 1 for a in args), "%s: Vorlage ohne %s" % (name, "/".join(args))
        cur = g.get(name)
        assert isinstance(cur, str) and (_norm(cur) == p or _norm(cur).replace(snip, "", 1) == p), "%s weicht von lage_pages.%s ab" % (name, fn)
    return "pagesSplit3 ok (%d Seitenvorlagen aus lage_pages.py: %s; gleich den Vorlagen)" % (len(_PAGESSPLIT3_PAGES), ", ".join(x[0] for x in _PAGESSPLIT3_PAGES))


try:
    _PAGESSPLIT3_ST = _selftest_pagessplit3()
except Exception as _pagessplit3_e:
    _PAGESSPLIT3_ST = None
    print("pagesSplit3 Selbsttest FEHLER (%s: %s)" % (type(_pagessplit3_e).__name__, _pagessplit3_e), flush=True)
if _PAGESSPLIT3_ST:
    print("pagesSplit3 aktiv: %s" % _PAGESSPLIT3_ST, flush=True)
# ===== /pagesSplit3 =====
MK_RAB_EOF
EXPECT_RAG="644961310ba507dd72910cb9e0b1b1819d536888190f542df7e709fd013d1e3b"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""Guard pagesSplit (generisch, Daten aus EDITS). Aufruf:
  guard_pages.py revert NEU_VERZ ALT_VERZ BLOCK EDITS   -> ALT_VERZ/dashboard.py und lage_pages.py (falls Basis eine hatte) = NEU ohne den Schritt (byte-genau)
  guard_pages.py check  ALT_VERZ NEU_VERZ BLOCK EDITS   -> Rueckbau = ALT, AST (nur Zuweisungen + Block / nur angehaengte Funktionen), Modul nur Text, Vorlagen alt=neu,
                                                           Selbsttest neu ok / alt und Fehlvarianten FEHLER
  RH_ALT=ALT_VERZ guard_pages.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest (Mutationen aus EDITS abgeleitet; jede muss check scheitern lassen). Ohne node."""
import ast, contextlib, hashlib, importlib, io, os, shutil, sys, tempfile

rd = lambda p: open(p, encoding="utf-8").read()
FORBID = ("requests", "urlopen", "socket", "subprocess", "open(", "send_", "mesh_", "telegram", "eval(", "exec(", "signal", "systemctl", "remove(", "unlink", "write")


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g


def split_mod(m, E):
    """lage_pages.py (neu) -> (Basis-Text, {fn: seg})"""
    H = E["SPLIT_HEAD"]
    assert m.count(H) == 1, "Abschnittskopf %s nicht genau einmal in lage_pages.py" % E["LABEL"]
    base, rest = m.split(H)
    segs, P = {}, E["PAGES"]
    for k, p in enumerate(P):
        pre = E["fn_prefix"](p[1], p[2])
        assert rest.startswith(pre), "Funktion %s nicht an erwarteter Stelle" % p[1]
        rest = rest[len(pre):]
        if k + 1 < len(P):
            nxt = "\n" + E["fn_prefix"](P[k + 1][1], P[k + 1][2])
            assert rest.count(nxt) == 1, "Grenze nach %s unklar" % p[1]
            j = rest.index(nxt)
            segs[p[1]], rest = rest[:j], rest[j + 1:]
        else:
            assert rest.endswith("\n"), "Ende lage_pages.py"
            segs[p[1]], rest = rest[:-1], ""
    if not E["MOD_BASE"]:
        assert base == E["MOD_HEAD1"], "Kopf lage_pages.py"
        base = None
    return base, segs


def revert_text(s, m, B, E):
    B = B.rstrip("\n")
    assert s.count("\n\n" + B + E["DSH_ANCHOR"]) == 1, "Block %s nicht genau einmal vor __main__" % E["LABEL"]
    s = s.replace("\n\n" + B, "", 1)
    base, segs = split_mod(m, E)
    for name, fn, args, *_ in E["PAGES"]:
        nl = E["new_lines"](name, fn, args)
        assert s.count("\n" + nl + "\n") == 1, "Import/Zuweisung %s nicht genau einmal" % name
        s = s.replace("\n" + nl + "\n", "\n%s = %s\n" % (name, segs[fn]), 1)
    return s, base


def isname(n, k):
    return isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) and n.targets[0].id == k


def cval(t, k):
    n = [x for x in t.body if isname(x, k)]
    assert len(n) == 1, k
    return eval(compile(ast.Expression(n[0].value), k, "eval"), {"__builtins__": {}}, {})


def run_selftest(B, gl, moddir):
    """gl: Funktion(lage_pages-Modul) -> dict; das Modul bleibt waehrend des Laufs in sys.modules (wie im Dashboard)."""
    sys.modules.pop("lage_pages", None)
    sys.path.insert(0, moddir)
    importlib.invalidate_caches()
    o = io.StringIO()
    try:
        try:
            import lage_pages as lp
        except Exception as e:
            lp = None
        g = gl(lp)
        with contextlib.redirect_stdout(o):
            exec(compile(B, "Block", "exec"), g)
    except Exception as e:
        o.write("AUSNAHME %s" % e)
    finally:
        sys.path.remove(moddir)
        sys.modules.pop("lage_pages", None)
    return o.getvalue()


def check(altd, neud, bp, ep):
    E = load_edits(ep)
    LB, P = E["LABEL"], E["PAGES"]
    da, ma, dn, mn = (os.path.join(altd, "dashboard.py"), os.path.join(altd, "lage_pages.py"), os.path.join(neud, "dashboard.py"), os.path.join(neud, "lage_pages.py"))
    A, N, B = rd(da), rd(dn), rd(bp)
    n, fails = 0, []

    def ok(c, msg):
        nonlocal n
        n += 1
        if not c:
            fails.append(msg)
    ok(os.path.isfile(ma) == E["MOD_BASE"], "Basis lage_pages.py %s" % ("fehlt" if E["MOD_BASE"] else "unerwartet da"))
    ok(os.path.isfile(mn), "lage_pages.py fehlt im Zielstand")
    if not os.path.isfile(mn):
        return n, fails
    M = rd(mn)
    MA = rd(ma) if os.path.isfile(ma) else None
    try:
        ra, rb = revert_text(N, M, B, E)
        ok(ra == A, "Rueckbau dashboard.py ungleich Basis")
        ok(rb == MA, "Rueckbau lage_pages.py ungleich Basis")
    except AssertionError as e:
        ok(False, "Rueckbau: %s" % e)
    ok(LB not in A and (MA is None or LB not in MA), "Basis enthaelt schon %s" % LB)
    try:
        tA, tN, tM, tB = ast.parse(A), ast.parse(N), ast.parse(M), ast.parse(B)
        tMA = ast.parse(MA) if MA is not None else ast.parse("")
        ok(True, "")
    except SyntaxError as e:
        ok(False, "Syntax %s" % e)
        return n, fails
    # dashboard.py: je Vorlage Zuweisung -> Import + Zuweisung, plus Block vor __main__
    dA = [ast.dump(x) for x in tA.body]
    vals = {}
    exp = []
    for k, x in enumerate(tA.body):
        hit = [p for p in P if isname(x, p[0])]
        if hit:
            p = hit[0]
            vals[p[0]] = x.value
            exp += [ast.dump(y) for y in ast.parse(E["new_lines"](p[0], p[1], p[2])).body]
        else:
            exp.append(dA[k])
    ok(sorted(vals) == sorted(p[0] for p in P), "Basis: nicht alle Vorlagen genau einmal (%s)" % sorted(vals))
    dB = [ast.dump(x) for x in tB.body]
    dN = [ast.dump(x) for x in tN.body]
    i = next((k for k in range(len(dN) - len(dB) + 1) if dN[k:k + len(dB)] == dB), None)
    ok(i is not None and dN[:i] + dN[i + len(dB):] == exp, "AST dashboard.py ausserhalb Zuweisungen/Block veraendert")
    rest = N.replace(B.rstrip("\n"), "", 1)
    for p in P:
        nl = E["new_lines"](p[0], p[1], p[2])
        ok(nl.startswith("from lage_pages import %s as _lp_%s  # " % (p[1], p[1])) and nl.endswith("\n%s = _lp_%s(%s)" % (p[0], p[1], ", ".join(p[2]))), "Zeilen %s nicht wie vorgesehen" % p[0])
        rest = rest.replace(nl, "", 1)
    ok(LB not in rest and not any(("_lp_" + p[1]) in rest for p in P), "%s/_lp_-Namen ausserhalb der vorgesehenen Stellen" % LB)
    # lage_pages.py: Basis-Body + je Vorlage eine Funktion mit genau dem alten Ausdruck
    bM, bMA = tM.body, tMA.body
    ok([ast.dump(x) for x in bM[:len(bMA)]] == [ast.dump(x) for x in bMA] and len(bM) == len(bMA) + len(P) + (0 if E["MOD_BASE"] else 1), "lage_pages.py: Basisteil veraendert oder Zusatzteile")
    fns = bM[len(bM) - len(P):]
    for p, f in zip(P, fns):
        shape = (isinstance(f, ast.FunctionDef) and f.name == p[1] and not f.decorator_list and f.returns is None and [a.arg for a in f.args.args] == list(p[2])
                 and not f.args.defaults and not f.args.kwonlyargs and f.args.vararg is None and f.args.kwarg is None and not f.args.posonlyargs
                 and len(f.body) == 1 and isinstance(f.body[0], ast.Return))
        ok(shape, "lage_pages.py: %s nicht nur return mit Argumenten %s" % (p[1], p[2]))
        ok(shape and p[0] in vals and ast.dump(f.body[0].value) == ast.dump(vals[p[0]]), "%s liefert nicht den alten Ausdruck (AST)" % p[1])
    ok(not any(isinstance(x, (ast.Import, ast.ImportFrom, ast.Call, ast.Attribute, ast.Global, ast.Nonlocal, ast.Lambda, ast.Subscript, ast.JoinedStr)) for x in ast.walk(tM)), "lage_pages.py enthaelt Code ausser Text")
    try:
        _, segs = split_mod(M, E)
        for p in P:
            ok(hashlib.sha256(segs[p[1]].encode()).hexdigest() == p[3] and len(segs[p[1]]) == p[4], "%s: Vorlagentext nicht byte-genau (sha256)" % p[0])
    except AssertionError as e:
        ok(False, "Abschnitt lage_pages.py: %s" % e)
    # Werte gleich (echte Konstanten und Platzhalter)
    try:
        cst = {a: cval(tA, a) for p in P for a in p[2]}
        mg = {"__name__": "lage_pages_probe"}
        exec(compile(M, "lage_pages.py", "exec"), mg)
        for p in P:
            old = lambda env: eval(compile(ast.Expression(vals[p[0]]), p[0], "eval"), {"__builtins__": {}}, env)
            ok(mg[p[1]](*[cst[a] for a in p[2]]) == old(cst) and mg[p[1]](*["<%s/>" % a for a in p[2]]) == old({a: "<%s/>" % a for a in p[2]}), "%s: Vorlage alt/neu ungleich" % p[0])
    except Exception as e:
        ok(False, "Wertvergleich: %s" % e)
        return n, fails
    # Block: verbotene Aufrufe, Seitenliste = EDITS
    C = " ".join(l.split("#")[0] for l in B.splitlines())
    for f in FORBID:
        ok(f not in C, "verboten im Block: " + f)
    tl = [x for x in tB.body if isinstance(x, ast.Assign) and len(x.targets) == 1 and isinstance(x.targets[0], ast.Name) and x.targets[0].id.endswith("_PAGES")]
    try:
        ok(len(tl) == 1 and ast.literal_eval(tl[0].value) == tuple((p[0], p[1], tuple(p[2])) for p in P), "Seitenliste im Block ungleich EDITS")
    except Exception as e:
        ok(False, "Seitenliste im Block: %s" % e)
    ok(B.startswith("# ===== %s:" % LB) and B.rstrip("\n").endswith("# ===== /%s =====" % LB), "Marker %s" % LB)
    stj = [x for x in tA.body if isname(x, "_STALE_TS_JS")]
    sts = eval(compile(ast.Expression(stj[0].value), "st", "eval"), {"__builtins__": {}}, {}) if stj else b""
    snip = sts.decode("utf-8")
    good = "%s aktiv: %s ok" % (LB, LB)
    bad = "%s Selbsttest FEHLER" % LB
    with tempfile.TemporaryDirectory() as d:
        pd, od = os.path.join(d, "proj"), os.path.join(d, "fremd")
        os.makedirs(pd); os.makedirs(od)
        shutil.copy(mn, pd)
        fake = os.path.join(pd, "dashboard.py")

        def gl(fl=fake, emb=True, **kw):
            def mk(lp):
                g = {"__name__": "x", "__file__": fl, "_STALE_TS_JS": sts}
                g.update(cst)
                for p in P:
                    v = getattr(lp, p[1])(*[cst[a] for a in p[2]])
                    g[p[0]] = v.replace("</body>", snip + "</body>", 1) if emb else v
                    g["_lp_" + p[1]] = getattr(lp, p[1])
                g.update(kw)
                return g
            return mk
        def patg(lp, _b=gl(), bad=False):
            x = _b(lp)
            x["_pat_html"] = lambda k: "<!--PAT %s %s-->" % (k, "x" * 40)
            x["_PAT_ANCH"] = {"k": "</head>"}
            for p in P:
                if "</head>" in x[p[0]]:
                    x[p[0]] = x[p[0]].replace("</head>", "</head>" + ("<!--PAT k %s-->" % ("x" * 40) if not bad else "<!--PAT anders-->"), 1)
            return x
        pv = [("mit Laufzeit-Einfuegung (priceAllTime)", patg)] if "_norm(" in B else []
        if pv:
            so = run_selftest(B, lambda lp: patg(lp, bad=True), pd)
            ok(bad in so and "aktiv" not in so, "Selbsttest erkennt nicht: unbekannte Laufzeit-Einfuegung (%r)" % so[:100])
        for nm, g in [("eingebettet", gl()), ("ohne staleTs", gl(emb=False))] + pv:
            so = run_selftest(B, g, pd)
            ok(good in so and "FEHLER" not in so, "Selbsttest neu (%s): %r" % (nm, so[:160]))

        def altg(lp):
            g = {"__name__": "x", "__file__": os.path.join(od, "dashboard.py"), "_STALE_TS_JS": sts}
            g.update(cst)
            for p in P:
                g[p[0]] = eval(compile(ast.Expression(vals[p[0]]), p[0], "eval"), {"__builtins__": {}}, dict(cst))
            return g
        if E["MOD_BASE"]:
            shutil.copy(ma, od)
        so = run_selftest(B, altg, od)
        ok(bad in so and "aktiv" not in so, "Selbsttest schlaegt am alten Stand nicht an (%r)" % so[:100])
        os.remove(os.path.join(od, "lage_pages.py")) if os.path.exists(os.path.join(od, "lage_pages.py")) else None
        shutil.copy(mn, od)
        p0, pl = P[0], P[-1]
        a0 = p0[2][0] if p0[2] else None
        vd = os.path.join(d, "noarg"); os.makedirs(vd)
        if a0:
            # Variante: erste Vorlage ohne ihr erstes Argument (Navigation)
            pre = E["fn_prefix"](p0[1], p0[2])
            j = M.index(pre) + len(pre)
            seg0 = M[j:j + p0[4]]
            assert ("+ %s +" % a0) in seg0, "Variante: '+ %s +' fehlt in %s" % (a0, p0[0])
            open(os.path.join(vd, "lage_pages.py"), "w", encoding="utf-8").write(M[:j] + seg0.replace("+ %s +" % a0, "+", 1) + M[j + p0[4]:])
        vars_ = [("Modul aus fremdem Ordner", gl(), od),
                 ("andere Funktion %s" % p0[0], gl(**{"_lp_" + p0[1]: (lambda *a: "x")}), pd),
                 ("%s geaendert" % pl[0], None, pd)]
        if a0:
            vars_.append(("%s ohne %s" % (p0[0], a0), None, vd))
        for nm, g, md in vars_:
            if nm.endswith(" geaendert"):
                def g(lp, _b=gl()):
                    x = _b(lp); x[pl[0]] = x[pl[0]] + " "
                    return x
            elif g is None:
                def g(lp):
                    x = {"__name__": "x", "__file__": os.path.join(vd, "dashboard.py"), "_STALE_TS_JS": sts}
                    x.update(cst)
                    for p in P:
                        x[p[0]] = getattr(lp, p[1])(*[cst[a] for a in p[2]]); x["_lp_" + p[1]] = getattr(lp, p[1])
                    return x
            so = run_selftest(B, g, md)
            ok(bad in so and "aktiv" not in so, "Selbsttest erkennt nicht: %s (%r)" % (nm, so[:100]))
    return n, fails


def mutations(E, B, N, M):
    P = E["PAGES"]
    p0, pl = P[0], P[-1]
    out = []
    for p in (p0, pl):
        nl = E["new_lines"](p[0], p[1], p[2])
        out.append(("dash", nl, nl.replace("(%s)" % ", ".join(p[2]), "(%s + '')" % ", ".join(p[2]))))
    out.append(("dash", E["new_lines"](P[1][0], P[1][1], P[1][2]) + "\n", ""))
    out.append(("dash", "RS_TOTAL_S = 4.0", "RS_TOTAL_S = 5.0"))
    for p in P:  # je Vorlage ein Byte im verschobenen Text
        pre = E["fn_prefix"](p[1], p[2])
        j = M.index(pre) + len(pre)
        o = M[j - len(pre):j + 60]
        out.append(("mod", o, o[:len(pre) + 3] + " " + o[len(pre) + 3:]))
    out.append(("mod", E["SPLIT_HEAD"], E["SPLIT_HEAD"] + "import os\n"))
    out.append(("mod", E["fn_prefix"](pl[1], pl[2]), E["fn_prefix"](pl[1], pl[2]).replace("):", "=''):", 1) if pl[2] else E["fn_prefix"](pl[1], pl[2]).replace("():", "(x=''):", 1)))
    out.append(("mod", E["SPLIT_HEAD"], E["SPLIT_HEAD"].replace("# ===== ", "# ", 1)))
    if E["MOD_BASE"]:
        out.append(("mod", "\n\ndef page_adsb(", "\n\n\ndef page_adsb("))
    for line in B.splitlines():
        st = line.strip()
        if st.startswith("assert "):
            out.append(("blk", line + "\n", ""))
    lines = B.splitlines()
    sti = next(l for l in lines if l.strip().startswith("_") and l.strip().endswith("_ST = _selftest_" + E["LABEL"].lower().replace("-", "") + "()"))
    out.append(("blk", sti, sti.split("=")[0] + "= '%s ok'" % E["LABEL"]))
    pr = next(l for l in lines if 'print("%s aktiv: ' % E["LABEL"] in l)
    out.append(("blk", pr, pr.replace(" aktiv: ", ": ", 1)))
    out.append(("blk", "    snip = ", "    open('/tmp/x', 'w')\n    snip = "))
    if "_norm(cur).replace(snip" in B:
        out.append(("blk", "(_norm(cur) == p or _norm(cur).replace(", "(True or _norm(cur).replace("))
        out.append(("blk", "        return x\n", "        return ''\n"))
        out.append(("blk", '            x = x.replace(e, "", 1)\n', '            x = x.replace(e[:20], "", 1)\n'))
    else:
        out.append(("blk", "(cur == p or cur.replace(", "(True or cur.replace("))
    out.append(("blk", "    (%r, %r, %r),\n" % (pl[0], pl[1], tuple(pl[2])), ""))
    out.append(("blk", ' >= 1 for a in args)', ' >= 0 for a in args)'))
    return out


def mutate(altd, neud, bp, ep):
    E = load_edits(ep)
    B, N, M, miss = rd(bp), rd(os.path.join(neud, "dashboard.py")), rd(os.path.join(neud, "lage_pages.py")), 0
    MUT = mutations(E, B, N, M)
    for i, (tg, o, nw) in enumerate(MUT, 1):
        src = {"blk": B, "dash": N, "mod": M}[tg]
        if src.count(o) != 1 or o == nw:
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
    print("%s Mutationstest %s: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", E["LABEL"], len(MUT), miss))
    return miss


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "revert":
        nd, ad = sys.argv[2], sys.argv[3]
        E = load_edits(sys.argv[5])
        s, m = revert_text(rd(os.path.join(nd, "dashboard.py")), rd(os.path.join(nd, "lage_pages.py")), rd(sys.argv[4]), E)
        open(os.path.join(ad, "dashboard.py"), "w", encoding="utf-8").write(s)
        if m is not None:
            open(os.path.join(ad, "lage_pages.py"), "w", encoding="utf-8").write(m)
        print("OK Rueckbau %s byte-genau erzeugt (dashboard.py und lage_pages.py ohne %d Vorlagen)" % (E["LABEL"], len(E["PAGES"])))
    elif cmd == "check":
        n, f = check(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        for x in f:
            print("FEHLER", x)
        E = load_edits(sys.argv[5])
        print("%s Guard %s: %d Pruefungen, %d Fehler (Rueckbau beider Dateien byte-genau, AST nur Zuweisungen+Block, Modul nur Text, %d Vorlagen alt=neu, Selbsttest + Fehlvarianten, ohne node)" % ("OK" if not f else "FEHLER", E["LABEL"], n, len(f), len(E["PAGES"])))
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach pagesSplit2 commit42" "$KNOWN_D16N" "pagesSplit3 schon drin"))"
if [[ -e "$L" || -L "$L" ]]; then L16=$(s16 "$L"); echo "Basis lage_pages.py sha16 $L16 ($(wc -l < "$L") Zeilen, $(lbl "$L16" "${KNOWN_L16:-x}" "Stand nach pagesSplit2 commit42" "$KNOWN_L16N" "pagesSplit3 schon drin"))"; else L16=fehlt; echo "Basis lage_pages.py: fehlt (erwartet vor pagesSplit3)"; fi
ST=MISCH
[[ "$D16" == "$KNOWN_D16" && "$L16" == "${KNOWN_L16:-fehlt}" && ! -L "$L" ]] && ST=ALT
[[ "$D16" == "$KNOWN_D16N" && "$L16" == "$KNOWN_L16N" && ! -L "$L" ]] && ST=NEU
if [[ "$ST" == MISCH && ( "$D16" == "$KNOWN_D16" || "$D16" == "$KNOWN_D16N" ) ]]; then
  echo "STOP: Mischstand - dashboard.py $D16 ($(lbl "$D16" "$KNOWN_D16" "alt" "$KNOWN_D16N" "neu")), lage_pages.py $L16 ($(lbl "$L16" "${KNOWN_L16:-fehlt}" "alt" "$KNOWN_L16N" "neu")) - nichts geaendert."
  echo "      Erlaubt sind nur: ALT (dashboard.py $KNOWN_D16 und lage_pages.py ${KNOWN_L16:-fehlt}) oder NEU (dashboard.py $KNOWN_D16N und lage_pages.py $KNOWN_L16N). Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      pagesSplit3 passt nur auf den Stand Stand nach pagesSplit2 commit42 (dashboard.py 6661a7f77b1e1487). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
FOWN=$(stat -c %U:%G "$F"); FMOD=$(stat -c %a "$F")
[[ "$(id -un)" == "$(stat -c %U "$F")" ]] || stop "Skript laeuft als $(id -un), dashboard.py gehoert $(stat -c %U "$F") - bitte als $(stat -c %U "$F") starten (lage_pages.py soll denselben Eigentuemer bekommen)"
id -nG | tr ' ' '\n' | grep -qx "$(stat -c %G "$F")" || stop "Benutzer $(id -un) ist nicht in der Gruppe $(stat -c %G "$F") von dashboard.py"
if [[ -f "$L" ]]; then LOWN=$(stat -c %U:%G "$L"); LMOD=$(stat -c %a "$L"); [[ "$(id -un)" == "$(stat -c %U "$L")" ]] || stop "lage_pages.py gehoert $(stat -c %U "$L"), Skript laeuft als $(id -un)"; [[ -w "$L" ]] || stop "lage_pages.py ist nicht beschreibbar"
else LOWN=$FOWN; LMOD=$FMOD; fi
echo "OK Eigentuemer/Rechte: dashboard.py $FOWN $FMOD, lage_pages.py $LOWN $LMOD$([[ -f "$L" ]] || echo " (neu, wie dashboard.py)") - bleiben so"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- pagesSplit3: Neustart-Sperre HH:55-HH:04 (jede Stunde, Berlin-Zeit); geprueft jetzt und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${PAGES_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$PAGES_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$ST" == NEU ]]; then echo "OK Neustart-Sperre: pagesSplit3 ist schon installiert, es wird kein Neustart gebraucht"
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
LSRC=-; [[ -f "$L" ]] && LSRC="$L"
python3 "$PPK" "$F" "$LSRC" "$W/work/dashboard.py" "$W/work/lage_pages.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py/lage_pages.py: Stelle fuer pagesSplit3 nicht eindeutig (Datei vom Standard abweichend)"; }
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
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: pagesSplit3 im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne pagesSplit3 ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
if [[ -n "$KNOWN_L16" ]]; then [[ "$(s16 "$W/alt/lage_pages.py")" == "$KNOWN_L16" ]] || stop "AST-Guard: Rueckbau lage_pages.py ist nicht die bekannte Basis"
else [[ ! -e "$W/alt/lage_pages.py" ]] || stop "AST-Guard: Rueckbau enthaelt lage_pages.py"; fi
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard pagesSplit3 meldet Verstoss"; }
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
# ---- pagesSplit3: Zustand vorher (nur Lesen): Seiten der verschobenen Vorlagen ----
PSURLS=(/ /energie /lokal /lokale-energie /system /umwelt)
declare -A PSC0 PSS0 PSN0 PSP0
psph() { grep -q 'Dashboard startet</h2>' "$1" 2>/dev/null && echo 1 || echo 0; }   # Start-Platzhalter (erste Daten laden noch)
for u in "${PSURLS[@]}"; do
  f="$W/ps0$(echo "$u" | tr '/' '_').html"
  PSC0[$u]=$("${CURL[@]}" "$B$u" -o "$f" -w "%{http_code}" || true); [[ -z "${PSC0[$u]}" ]] && PSC0[$u]=000
  PSS0[$u]=$(grep -c 'staleTsBoot' "$f" 2>/dev/null || true); PSN0[$u]=$(grep -c 'navUnify' "$f" 2>/dev/null || true); PSP0[$u]=$(psph "$f")
done
echo "Zustand vorher: $(for u in "${PSURLS[@]}"; do printf '%s=%s ' "$u" "${PSC0[$u]}"; done)(Seiten der verschobenen Vorlagen)"
rscheck "vor dem Neustart"
NEED_D=0; [[ "$ST" == ALT ]] && NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: pagesSplit3 ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: lage_pages.py $([[ -f "$L" ]] && echo ersetzen || echo "neu anlegen") ($LOWN, $LMOD, Sicherung lage_pages.py.bak-pagessplit3-ZEIT falls vorhanden) und dashboard.py ersetzen (Sicherung dashboard.py.bak-pagessplit3-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG pagessplit3=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "pagesSplit3|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-pagessplit3-$TS" ]] && cp -a "$F.bak-pagessplit3-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  rm -f -- "$L.new"
  if [[ -n "$KNOWN_L16" ]]; then
    [[ -f "$L.bak-pagessplit3-$TS" ]] && cp -a "$L.bak-pagessplit3-$TS" "$L.rb" && mv -f "$L.rb" "$L"
    [[ -f "$L.bak-pagessplit3-$TS" ]] && { cmp -s "$L" "$L.bak-pagessplit3-$TS" && echo "  lage_pages.py = Sicherung ($(s16 "$L"))" || echo "  WARNUNG lage_pages.py ungleich Sicherung"; }
  elif [[ "$ST" == ALT ]]; then rm -f -- "$L" "$DASH_DIR"/__pycache__/lage_pages.*.pyc; [[ -e "$L" ]] && echo "  WARNUNG lage_pages.py noch da" || echo "  lage_pages.py entfernt (war vorher nicht da)"; fi
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-pagessplit3-$TS" ]] && { cmp -s "$F" "$F.bak-pagessplit3-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK pagesSplit3 schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-pagessplit3-$TS"
  { ls -1t "$F.bak-pagessplit3-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  if [[ -f "$L" ]]; then
    cp -a "$L" "$L.bak-pagessplit3-$TS"
    { ls -1t "$L.bak-pagessplit3-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  cp "$W/work/lage_pages.py" "$L.new" && chmod "$LMOD" "$L.new" && chown "$LOWN" "$L.new" && mv -f "$L.new" "$L" || { rb "lage_pages.py konnte nicht geschrieben werden"; exit 1; }
  [[ "$(s16 "$L")" == "$KNOWN_L16N" && "$(stat -c '%U:%G %a' "$L")" == "$LOWN $LMOD" ]] || { rb "lage_pages.py nach dem Schreiben falsch ($(s16 "$L"), $(stat -c '%U:%G %a' "$L" 2>/dev/null))"; exit 1; }
  echo "OK lage_pages.py atomar geschrieben ($KNOWN_L16N, $(stat -c '%U:%G %a' "$L") wie vorher$([[ -f "$L.bak-pagessplit3-$TS" ]] && echo ", Sicherung lage_pages.py.bak-pagessplit3-$TS, behalten: letzte $KEEP_LAST"))"
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-pagessplit3-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(stat -c '%U:%G %a' "$F")" == "$FOWN $FMOD" ]] || { rb "dashboard.py Eigentuemer/Rechte veraendert ($(stat -c '%U:%G %a' "$F"))"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-pagessplit3-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'pagesSplit3 aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; pagesSplit3 aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- pagesSplit3: Marker, Importe, Seiten der verschobenen Vorlagen wie vorher ----
PSM=$(grep -c "^# ===== pagesSplit3:" "$F" || true); PSI=$(grep -c "^from lage_pages import .* # pagesSplit3: " "$F" || true); PSO=0
for n in PAGE1 PAGE2 PAGE3 PAGE_LOKALE_ENERGIE; do PSO=$(( PSO + $(grep -c "^$n = \"\"\"" "$F" || true) )); done
[[ "$PSM" == 1 && "$PSI" == 4 && "$PSO" == 0 ]] && echo "OK Marker pagesSplit3 1x, Importe 4x, alte Vorlagen in dashboard.py 0x" || rbx "dashboard.py pagesSplit3 falsch (Marker ${PSM}x, Importe ${PSI}x statt 4, alte Vorlagen ${PSO}x)"
PSOK=""; PSH=""; PSWT=0  # Wartezeit auf echte Seiten gemeinsam fuer alle URLs: hoechstens 40x3 s
for u in "${PSURLS[@]}"; do
  f="$W/ps1$(echo "$u" | tr '/' '_').html"
  while true; do
    c=$("${CURL[@]}" "$B$u" -o "$f" -w "%{http_code}" || true); [[ -z "$c" ]] && c=000
    [[ "$c" == 200 && "$(psph "$f")" == 1 ]] || break
    [[ "$PSWT" -lt 40 ]] || break
    PSWT=$(( PSWT + 1 )); sleep 3
  done
  [[ "$c" == "${PSC0[$u]}" ]] || rbx "$u antwortet $c (vorher ${PSC0[$u]})"
  if [[ "$c" == 200 && "$(psph "$f")" == 0 && "${PSP0[$u]}" == 0 ]]; then
    a=$(grep -c 'staleTsBoot' "$f" || true); b=$(grep -c 'navUnify' "$f" || true)
    [[ "$a" == "${PSS0[$u]}" && "$b" == "${PSN0[$u]}" ]] || rbx "$u: staleTs ${a}x/Navigation ${b}x (vorher ${PSS0[$u]}x/${PSN0[$u]}x)"
  elif [[ "$c" == 200 ]]; then PSH="$PSH $u"; fi
  PSOK="$PSOK $u=$c"
done
echo "OK Seiten der verschobenen Vorlagen wie vorher (HTTP, Navigation, staleTs):$PSOK (Vorlagentext im Trockenlauf byte-gleich nachgewiesen; Live-Werte duerfen sich aendern)"
[[ -z "$PSH" ]] || echo "HINWEIS noch Start-Platzhalter (erste Daten laden) bei:$PSH - HTTP 200 geprueft; spaeter ansehen: curl -s $B$(echo $PSH | cut -d' ' -f1) | grep -c navUnify (vorher ${PSN0[$(echo $PSH | cut -d' ' -f1)]})"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E pagesSplit3"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "pagesSplit3 aktiv: pagesSplit3 ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'pagesSplit3 aktiv: pagesSplit3 ok' ($(echo "$JD" | grep -F pagesSplit3 | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|No module named .lage_pages|cannot import name .page|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|No module named .lage_pages|cannot import name .page|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein pagesSplit3-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
[[ "$(s16 "$L")" == "$KNOWN_L16N" && "$(stat -c '%U:%G %a' "$L")" == "$LOWN $LMOD" && "$(s16 "$F")" == "$KNOWN_D16N" ]] && echo "OK lage_pages.py $(s16 "$L") ($(stat -c '%U:%G %a' "$L")) und dashboard.py $(s16 "$F") ($(stat -c '%U:%G %a' "$F")) wie erwartet" || rbx "Endstand Dateien falsch: dashboard.py $(s16 "$F"), lage_pages.py $(s16 "$L" 2>/dev/null) $(stat -c '%U:%G %a' "$L" 2>/dev/null)"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-pagessplit3-$TS" ]] && echo "Backup: dashboard.py.bak-pagessplit3-$TS$([[ -f "$L.bak-pagessplit3-$TS" ]] && echo " und lage_pages.py.bak-pagessplit3-$TS") (behalten: je letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen; lage_pages.py sha16 $(s16 "$L"), $(wc -c < "$L") Bytes, $(wc -l < "$L") Zeilen"
LB=$({ ls -1t "$F.bak-pagessplit3-"* 2>/dev/null || true; } | head -1)
LLB=$({ ls -1t "$L.bak-pagessplit3-"* 2>/dev/null || true; } | head -1)
if [[ -n "$LB" && -n "$KNOWN_L16" ]]; then echo "Rueckweg: cp -a $LB $F && cp -a $LLB $L && sudo systemctl restart prepper-dashboard"
elif [[ -n "$LB" ]]; then echo "Rueckweg: cp -a $LB $F && rm -f $L && sudo systemctl restart prepper-dashboard"; fi
[[ -n "$LB" ]] || echo "Rueckweg: keine pagessplit3-Sicherung vorhanden (nichts geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c pagesSplit3 /home/fmg/prepper-dashboard/dashboard.py"
echo "  ls -l /home/fmg/prepper-dashboard/lage_pages.py /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s -o /dev/null -w %{http_code} http://127.0.0.1:5000/   (200 erwartet)"
echo "  sudo journalctl -u prepper-dashboard --since -1h --no-pager | grep -E 'pagesSplit3|pagesSplit1'"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep pagesSplit3"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (Auftrag: kein Docs-Update)."
echo "COMMIT $COMMIT_ARG pagessplit3=1 fertig"
