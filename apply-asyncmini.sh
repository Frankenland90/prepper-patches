#!/bin/bash
set -eEuo pipefail
# asyncMini (commit40): async-Minifix: auf der Lage-Seite (PAGE1) den verwaisten Skriptblock '<script>async</script>' entfernen (loeste im Browser bei jedem Laden ReferenceError 'async is not defined' aus); nur Seitentext, Daten/API/Logik unveraendert
# Aufruf: bash /tmp/apply-asyncmini.sh commit40 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 7be7e011ee2426a6 (Stand nach relStop commit39) oder asyncMini schon drin (f8977a31bf4c177f); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-asyncmini-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/asyncmini-apply
KEEP_LAST=3
KNOWN_D16="7be7e011ee2426a6"      # dashboard.py vor asyncMini (Basis: Stand nach relStop commit39)
KNOWN_D16N="f8977a31bf4c177f"             # dashboard.py nach asyncMini (Ziel)
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
echo "=== asyncMini apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): verwaisten async-Skriptblock auf der Lage-Seite entfernen, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="e9eacee87cb25ffaac81b9d0ef84fa0868d951f9c3741154cd47a6a1d197e36c"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher hideTexts. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
EXPECT_RAE="e335e51616626a9afd2ac3b7c5b2d19418bb5a5ec512724573f7d6319608bead"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer asyncMini (commit40): Basis 7be7e011ee2426a6 (Stand nach relStop commit39)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    # PAGE1 (Lage-Seite /): verwaister Skriptblock nur mit "async" (Browser: ReferenceError "async is not defined") entfernen
    ('setInterval(updateFreq, 20000);\n</script>\n\n<script>\nasync \n</script>\n',
     'setInterval(updateFreq, 20000); /* asyncMini */\n</script>\n'),
]
MK_RAE_EOF
EXPECT_RAB="e3d10f387bbb8e4357ea4b3c09f5ff620d92491b249d38783fbecc211bedd16c"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== asyncMini: Lage-Seite ohne den verwaisten Skriptblock "<script>async</script>" (loeste im Browser ReferenceError aus); nur Seitentext, keine Daten, kein Netz, sendet nichts =====
def _selftest_asyncmini():
    p = globals().get("PAGE1")
    assert isinstance(p, str) and "async function updateFreq()" in p, "PAGE1 fehlt oder ohne updateFreq"
    assert "<script>\nasync \n</script>" not in p, "verwaister async-Block noch da"
    assert p.count("setInterval(updateFreq, 20000); /* asyncMini */\n</script>") == 1, "Frequenz-Skript nicht wie erwartet"
    assert p.count("<script") == p.count("</script>"), "Skript-Tags unausgeglichen"
    return "asyncMini ok (Lage-Seite ohne verwaisten async-Skriptblock, Frequenz-Skript unveraendert)"


try:
    _AM_ST = _selftest_asyncmini()
except Exception as _am_e:
    _AM_ST = None
    print("asyncMini Selbsttest FEHLER (%s: %s)" % (type(_am_e).__name__, _am_e), flush=True)
if _AM_ST:
    print("asyncMini aktiv: %s" % _AM_ST, flush=True)
# ===== /asyncMini =====
MK_RAB_EOF
EXPECT_RAG="6ec1a8438091e598e32de4a49dcd98f21df3562028cdfa910d3ad94a24db4fab"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""Guard asyncMini (nur dashboard.py: 1 Stelle in PAGE1 + Block asyncMini). Aufruf:
  guard_am.py revert NEU_VERZ ALT_VERZ BLOCK EDITS   -> ALT_VERZ/dashboard.py = NEU ohne asyncMini (byte-genau)
  guard_am.py check  ALT_VERZ NEU_VERZ BLOCK EDITS   -> Rueckbau = ALT, AST-Vergleich (nur PAGE1 + Block), PAGE1-Unterschied genau der async-Block, Selbsttest neu ok / alt Fehler, JS (node, falls da)
  RH_ALT=ALT_VERZ guard_am.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest (jede Mutation muss check scheitern lassen)"""
import ast, difflib, os, re, shutil, subprocess, sys, tempfile

rd = lambda p: open(p, encoding="utf-8").read()
ORPHAN = "<script>\nasync \n</script>"
FORBID = ("requests", "urlopen", "socket", "subprocess", "os.", "open(", "send_", "mesh", "telegram", "eval(", "exec(", "__import__", "signal", "systemctl")


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"]


def revert_text(s, B, E):
    B = B.rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block asyncMini nicht genau einmal"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in E:
        assert s.count(n) == 1, "Stelle asyncMini nicht genau einmal"
        s = s.replace(n, o, 1)
    return s


def page1(src):
    t = ast.parse(src)
    for nd in t.body:
        if isinstance(nd, ast.Assign) and [ast.unparse(x) for x in nd.targets] == ["PAGE1"]:
            names = {x.id for x in ast.walk(nd.value) if isinstance(x, ast.Name)}
            return eval(compile(ast.Expression(nd.value), "PAGE1", "eval"), {"__builtins__": {}}, {k: "<%s/>" % k for k in names})
    raise AssertionError("PAGE1 fehlt")


def scripts(p):
    return re.findall(r"<script>(.*?)</script>", p, flags=re.S)


def node_errs(p):
    nd = None if os.environ.get("AM_NO_NODE") else shutil.which("node")
    if not nd:
        return None
    errs = []
    with tempfile.TemporaryDirectory() as d:
        for i, sc in enumerate(scripts(p)):
            if "{{" in sc or "{%" in sc:
                continue
            f = os.path.join(d, "s%d.js" % i)
            open(f, "w", encoding="utf-8").write(sc)
            r = subprocess.run([nd, "--check", f], capture_output=True, text=True)
            if r.returncode:
                errs.append("Syntax %d" % i)
            elif re.fullmatch(r"\s*[A-Za-z_$][\w$]*\s*;?\s*", sc):
                errs.append("nacktes Wort %r" % sc.strip())
    return errs


def run_selftest(B, p):
    g = {"PAGE1": p, "__name__": "x"}
    import contextlib, io
    o = io.StringIO()
    with contextlib.redirect_stdout(o):
        exec(compile(B, "asyncMini-Block", "exec"), g)
    return o.getvalue()


def check(alt, neu, bp, ep):
    A, N, B, E = rd(alt), rd(neu), rd(bp), load_edits(ep)
    n, fails = 0, []

    def ok(c, msg):
        nonlocal n
        n += 1
        if not c:
            fails.append(msg)
    try:
        ok(revert_text(N, B, E) == A, "Rueckbau ungleich Basis")
    except AssertionError as e:
        ok(False, str(e))
    ok("asyncMini" not in A and A.count(ORPHAN) == 1, "Basis unerwartet")
    ok(N.count("\n\n" + B.rstrip("\n") + '\n\n\nif __name__ == "__main__":\n') == 1 or N.count("\n\n" + B.rstrip("\n") + '\n\nif __name__ == "__main__":\n') == 1, "Block nicht direkt vor __main__")
    try:
        tA, tN = ast.parse(A), ast.parse(N)
        ok(True, "")
    except SyntaxError as e:
        ok(False, "Syntax %s" % e)
        return n, fails
    dA = [ast.dump(x) for x in tA.body if not (isinstance(x, ast.Assign) and [ast.unparse(y) for y in x.targets] == ["PAGE1"])]
    tB = ast.parse(B)
    dB = [ast.dump(x) for x in tB.body]
    dN = [ast.dump(x) for x in tN.body if not (isinstance(x, ast.Assign) and [ast.unparse(y) for y in x.targets] == ["PAGE1"])]
    i = next((k for k in range(len(dN) - len(dB) + 1) if dN[k:k + len(dB)] == dB), None)
    ok(i is not None and dN[:i] + dN[i + len(dB):] == dA, "AST ausserhalb PAGE1/Block veraendert")
    C = " ".join(l.split("#")[0] for l in B.splitlines())
    for f in FORBID:
        ok(f not in C, "verboten im Block: " + f)
    pA, pN = page1(A), page1(N)
    ok(pA.count(ORPHAN) == 1 and pN.count(ORPHAN) == 0, "verwaister Block nicht entfernt")
    d = [l for l in difflib.unified_diff(pA.splitlines(), pN.splitlines(), lineterm="", n=0) if not l.startswith(("---", "+++", "@@"))]
    ok(d == ["-setInterval(updateFreq, 20000);", "-</script>", "-", "-<script>", "-async ", "+setInterval(updateFreq, 20000); /* asyncMini */"], "PAGE1-Unterschied nicht genau der async-Block: %r" % d[:8])
    ok(len(scripts(pA)) - 1 == len(scripts(pN)) and pN.count("<script") == pN.count("</script>"), "Skript-Anzahl/Tags")
    ok("updateFreq();\nsetInterval(updateFreq, 20000); /* asyncMini */\n</script>" in pN and pN.count("async function updateFreq()") == 1, "Frequenz-Skript beschaedigt")
    try:
        so = run_selftest(B, pN)
    except Exception as e:
        so = "AUSNAHME %s" % e
    ok("asyncMini aktiv: asyncMini ok" in so and "FEHLER" not in so, "Selbsttest neu: %r" % so[:120])
    try:
        sa = run_selftest(B, pA)
    except Exception as e:
        sa = "AUSNAHME %s" % e
    ok("asyncMini Selbsttest FEHLER" in sa and "aktiv" not in sa, "Selbsttest schlaegt am alten Stand nicht an")
    for nm, bad in (("verwaister Block", pN.replace("/* asyncMini */\n</script>\n", "/* asyncMini */\n</script>\n" + ORPHAN + "\n", 1)),
                    ("ohne Kennung", pN.replace(" /* asyncMini */", "", 1)),
                    ("Tags unausgeglichen", pN + "<script>"),
                    ("ohne updateFreq", pN.replace("async function updateFreq()", "async function updateF()", 1))):
        try:
            sb = run_selftest(B, bad)
        except Exception as e:
            sb = "AUSNAHME %s" % e
        ok(bad != pN and "asyncMini Selbsttest FEHLER" in sb, "Selbsttest erkennt nicht: " + nm)
    eA, eN = node_errs(pA), node_errs(pN)
    if eA is not None:
        ok(any("async" in x for x in eA) and eN == [x for x in eA if "async" not in x], "JS (node): alt %r neu %r" % (eA, eN))
    return n, fails


MUT = [  # (Ziel, alt, neu): Ziel "blk" = Block, "dash" = nur dashboard.py (Block und Stellen unveraendert)
    ("dash", "setInterval(updateFreq, 20000); /* asyncMini */\n</script>\n", "setInterval(updateFreq, 20000); /* asyncMini */\n</script>\n<script>\nasync \n</script>\n"),
    ("dash", "updateFreq();\nsetInterval(updateFreq, 20000); /* asyncMini */", "setInterval(updateFreq, 20000); /* asyncMini */"),
    ("dash", "async function updateFreq() {", "function updateFreq() {"),
    ("dash", "let pingChart = makeChart(", "let pingChart= makeChart("),
    ("dash", "RS_TOTAL_S = 4.0", "RS_TOTAL_S = 5.0"),
    ("blk", '    assert "<script>\\nasync \\n</script>" not in p, "verwaister async-Block noch da"\n', ""),
    ("blk", '    assert p.count("setInterval(updateFreq, 20000); /* asyncMini */\\n</script>") == 1, "Frequenz-Skript nicht wie erwartet"\n', ""),
    ("blk", "    _AM_ST = _selftest_asyncmini()", "    _AM_ST = 'asyncMini ok'"),
    ("blk", '    print("asyncMini aktiv: %s" % _AM_ST, flush=True)', '    print("asyncMini: %s" % _AM_ST, flush=True)'),
    ("blk", "    return \"asyncMini ok", "    open('/tmp/x', 'w')\n    return \"asyncMini ok"),
    ("blk", 'assert p.count("<script") == p.count("</script>")', 'assert p.count("<script") >= 0'),
]


def mutate(alt, neu, bp, ep):
    B, N, miss = rd(bp), rd(neu), 0
    for i, (tg, o, nw) in enumerate(MUT, 1):
        src = B if tg == "blk" else N
        if src.count(o) != 1:
            print("UEBERSEHEN Mutation %d Stelle nicht eindeutig (%d)" % (i, src.count(o)))
            miss += 1
            continue
        with tempfile.TemporaryDirectory() as d:
            bp2, np2 = os.path.join(d, "blk.py"), os.path.join(d, "dash.py")
            if tg == "blk":
                B2 = B.replace(o, nw, 1)
                N2 = N.replace(B.rstrip("\n"), B2.rstrip("\n"), 1)
            else:
                B2, N2 = B, N.replace(o, nw, 1)
            open(bp2, "w", encoding="utf-8").write(B2)
            open(np2, "w", encoding="utf-8").write(N2)
            try:
                _, f = check(alt, np2, bp2, ep)
            except Exception as e:
                f = ["Ausnahme %s" % e]
        print("%s Mutation %2d: %s" % ("OK" if f else "UEBERSEHEN", i, (f[0] if f else o.strip()[:60])[:110]))
        miss += 0 if f else 1
    print("%s Mutationstest asyncMini: %d Mutationen, %d uebersehen" % ("OK" if not miss else "UEBERSEHEN", len(MUT), miss))
    return miss


if __name__ == "__main__":
    cmd = sys.argv[1]
    dp = lambda d: os.path.join(d, "dashboard.py") if os.path.isdir(d) else d
    if cmd == "revert":
        open(dp(sys.argv[3]), "w", encoding="utf-8").write(revert_text(rd(dp(sys.argv[2])), rd(sys.argv[4]), load_edits(sys.argv[5])))
        print("OK Rueckbau asyncMini byte-genau erzeugt")
    elif cmd == "check":
        n, f = check(dp(sys.argv[2]), dp(sys.argv[3]), sys.argv[4], sys.argv[5])
        for x in f:
            print("FEHLER", x)
        print("%s Guard asyncMini: %d Pruefungen, %d Fehler (Rueckbau byte-genau, AST nur PAGE1+Block, PAGE1-Diff genau der async-Block, Selbsttest, JS %s)" % ("OK" if not f else "FEHLER", n, len(f), "node" if (shutil.which("node") and not os.environ.get("AM_NO_NODE")) else "ohne node"))
        sys.exit(1 if f else 0)
    elif cmd == "mutate":
        sys.exit(1 if mutate(dp(os.environ["RH_ALT"]), dp(sys.argv[2]), sys.argv[3], sys.argv[4]) else 0)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach relStop commit39" "$KNOWN_D16N" "asyncMini schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      asyncMini passt nur auf den Stand Stand nach relStop commit39 (dashboard.py 7be7e011ee2426a6). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- asyncMini: Neustart-Sperre HH:55-HH:04 (jede Stunde, Berlin-Zeit); geprueft jetzt und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${ASYNCMINI_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$ASYNCMINI_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Sperre: asyncMini ist schon installiert, es wird kein Neustart gebraucht"
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
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" asyncMini dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer asyncMini nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" asyncMini dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: asyncMini im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne asyncMini ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard asyncMini meldet Verstoss"; }
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
# ---- asyncMini: Zustand vorher (nur Lesen): verwaister async-Block auf der Lage-Seite ----
"${CURL[@]}" "$B/" -o "$W/lage0.html" || true
AM0=$(grep -c '^async $' "$W/lage0.html" || true); AMF0=$(grep -c 'async function updateFreq' "$W/lage0.html" || true)
echo "Zustand vorher: Lage-Seite: verwaister async-Block ${AM0}x, Frequenz-Skript ${AMF0}x"
rscheck "vor dem Neustart"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: asyncMini ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-asyncmini-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG asyncmini=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "asyncMini|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-asyncmini-$TS" ]] && cp -a "$F.bak-asyncmini-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-asyncmini-$TS" ]] && { cmp -s "$F" "$F.bak-asyncmini-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK asyncMini schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-asyncmini-$TS"
  { ls -1t "$F.bak-asyncmini-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-asyncmini-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-asyncmini-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'asyncMini aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; asyncMini aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- asyncMini: Marker, Lage-Seite ohne verwaisten async-Block, Frequenz-Skript weiter da ----
AMM=$(grep -c "^# ===== asyncMini:" "$F" || true); AMN=$(grep -c '^async $' "$F" || true)
[[ "$AMM" == 1 && "$AMN" == 0 ]] && echo "OK Marker asyncMini 1x, Zeile 'async ' kommt im Programm nicht mehr vor" || rbx "Marker/Programm asyncMini falsch (Marker ${AMM}x, 'async '-Zeile ${AMN}x)"
"${CURL[@]}" "$B/" -o "$W/lage1.html" || true
AM1=$(grep -c '^async $' "$W/lage1.html" || true); AMF1=$(grep -c 'async function updateFreq' "$W/lage1.html" || true)
if [[ "$AMF1" -ge 1 ]]; then
  [[ "$AM1" == 0 ]] && echo "OK Lage-Seite: verwaister async-Block weg (vorher ${AM0}x), Frequenz-Skript da (${AMF1}x)" || rbx "Lage-Seite enthaelt den async-Block noch (${AM1}x)"
else echo "HINWEIS Lage-Seite liefert noch den Ladehinweis (erstes Voll-Update laeuft) - Programmtext ist geprueft; spaeter: curl -s $B/ | grep -c '^async \$' (0 erwartet)"; fi
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E asyncMini"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "asyncMini aktiv: asyncMini ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'asyncMini aktiv: asyncMini ok' ($(echo "$JD" | grep -F asyncMini | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein asyncMini-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-asyncmini-$TS" ]] && echo "Backup: dashboard.py.bak-asyncmini-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-asyncmini-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine asyncmini-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c asyncMini /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/ | grep -c '^async $'   (0 erwartet)"
echo "  sudo journalctl -u prepper-dashboard --since -1h --no-pager | grep -E 'asyncMini|relStop SIGTERM'"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep asyncMini"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG asyncmini=1 fertig"
