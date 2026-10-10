#!/bin/bash
set -euo pipefail
# escfix: SyntaxWarning 'invalid escape sequence' in dashboard.py beseitigen (z.B. JS-Regex \d in HTML-String).
# Nur Backslash verdoppeln in nicht-rohen Literalen -> Laufzeit-Wert Byte fuer Byte gleich (AST identisch geprueft),
# danach 0 Warnungen. Kein Gesamt-sha noetig: Pruefung ueber AST + Anker-Zeile (hoechstens 1x).
# Sendet nichts. Neustart nur prepper-dashboard. Smoke gegen config.py PORT, nie :8080. Rollback bei Fehler.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/escfix
EXPECT_PATCH="fb5c7d134c96d4faa1d96c327fb17c6b3076833416e61191f555feeaa133186e"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-escfix.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""escfix: ungueltige Escape-Sequenzen (SyntaxWarning) in dashboard.py wertgleich reparieren.
Nur Backslash verdoppeln in nicht-rohen String-Literalen; danach muss der AST exakt gleich sein
und compile() darf keine SyntaxWarning mehr melden. Sonst STOP, nichts geschrieben."""
import ast
import io
import sys
import tokenize
import warnings
from pathlib import Path

ANCHOR = r'var m = String(text||"").match(/(\d{2})\.(\d{2})\.(\d{4}) (\d{2}):(\d{2}):(\d{2})/g);'
VALID_COMMON = set("\n\r\\'\"abfnrtv01234567x")
VALID_STR = VALID_COMMON | set("NuU")


def syntax_warnings(src, name):
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        compile(src, name, "exec")
    return [(x.lineno, str(x.message)) for x in w if issubclass(x.category, (SyntaxWarning, DeprecationWarning))
            and "escape" in str(x.message)]


def fix_body(body, is_bytes):
    valid = VALID_COMMON if is_bytes else VALID_STR
    out, i, n = [], 0, 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt in valid:
                out.append(body[i:i + 2])
            else:
                out.append("\\\\" + nxt)
                n += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out), n


def plan(src):
    lines = src.splitlines(keepends=True)
    offs = [0]
    for ln in lines:
        offs.append(offs[-1] + len(ln))

    def pos(rc):
        return offs[rc[0] - 1] + rc[1]

    edits, skipped = [], []
    fstack = []
    for t in tokenize.generate_tokens(io.StringIO(src).readline):
        name = tokenize.tok_name.get(t.type, "")
        if name == "FSTRING_START":
            fstack.append("r" in t.string.lower())
            continue
        if name == "FSTRING_END":
            fstack and fstack.pop()
            continue
        if name == "FSTRING_MIDDLE":
            if fstack and fstack[-1]:
                continue
            a, b = pos(t.start), pos(t.end)
            if "\\" not in t.string:
                continue
            if src[a:b] != t.string:
                skipped.append(t.start[0])
                continue
            new, k = fix_body(t.string, False)
            if k:
                edits.append((a, b, new, t.start[0], k))
            continue
        if t.type != tokenize.STRING or "\\" not in t.string:
            continue
        s = t.string
        q = min(i for i in (s.find("'"), s.find('"')) if i >= 0)
        prefix = s[:q].lower()
        if "r" in prefix:
            continue
        d = s[q:q + 3] if s[q:q + 3] in ('"""', "'''") else s[q]
        body = s[q + len(d):len(s) - len(d)]
        new, k = fix_body(body, "b" in prefix)
        if k:
            a, b = pos(t.start), pos(t.end)
            assert src[a:b] == s
            edits.append((a, b, s[:q + len(d)] + new + d, t.start[0], k))
    return edits, skipped


def main():
    path = Path(sys.argv[1])
    write = "--write" in sys.argv[2:]
    src = path.read_text(encoding="utf-8")
    before = syntax_warnings(src, str(path))
    n_anchor = src.count(ANCHOR)
    print("VORHER %d Escape-Warnung(en)%s; Anker-Zeile %d mal" % (
        len(before), (": Zeilen " + ",".join(str(l) for l, _ in before[:30])) if before else "", n_anchor))
    if not before:
        print("RESULT nichts zu tun (0 Warnungen)")
        return 0
    if n_anchor > 1:
        raise SystemExit("STOP: Anker-Zeile %d mal statt 1 - nichts geaendert" % n_anchor)
    edits, skipped = plan(src)
    new = src
    for a, b, rep, _, _ in sorted(edits, reverse=True):
        new = new[:a] + rep + new[b:]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        same = ast.dump(ast.parse(src)) == ast.dump(ast.parse(new))
    if not same:
        raise SystemExit("STOP: AST waere anders (Wert nicht gleich) - nichts geaendert")
    after = syntax_warnings(new, str(path))
    if after:
        raise SystemExit("STOP: danach noch %d Warnung(en) Zeilen %s (uebersprungen: %s) - nichts geaendert" % (
            len(after), ",".join(str(l) for l, _ in after), skipped))
    if n_anchor == 1 and ANCHOR in new:
        raise SystemExit("STOP: Anker-Zeile nicht repariert - nichts geaendert")
    total = sum(e[4] for e in edits)
    print("RESULT %d Literal(e), %d Backslash(es) verdoppelt, Zeilen %s; AST identisch; danach 0 Warnungen" % (
        len(edits), total, ",".join(str(e[3]) for e in sorted(edits)[:40])))
    if write:
        path.write_text(new, encoding="utf-8")
        print("GESCHRIEBEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PATCHPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
[[ -x "$VPY" ]] || VPY=python3
echo "=== escfix apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}), Python $("$VPY" -c 'import sys; print(sys.version.split()[0])') ==="
P="$W/patch-escfix.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
"$VPY" -m py_compile "$P"
echo "OK Bytes"
[[ -f "$DASH" ]] || { echo "STOP: dashboard.py fehlt"; exit 1; }
echo "dashboard.py vorher sha16 $(sha256sum "$DASH" | cut -c1-16)"

# ---------- Trockenlauf auf Kopie ----------
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$DASH" "$W/work/dashboard.py"
"$VPY" "$P" "$W/work/dashboard.py" --write > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - NICHTS geaendert"; exit 1; }
cat "$W/dry.txt"
if grep -q 'RESULT nichts zu tun' "$W/dry.txt"; then
  echo "OK keine Escape-Warnung (mehr) - nichts geaendert, kein Neustart"
  echo "COMMIT $COMMIT_ARG escfix=1"
  exit 0
fi
cp -a "$W/work" "$W/work1"
"$VPY" "$P" "$W/work/dashboard.py" --write | grep -q 'RESULT nichts zu tun' || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: 2. Lauf aendert noch - nichts geaendert"; exit 1; }
"$VPY" -W error::SyntaxWarning -m py_compile "$W/work/dashboard.py" || { echo "STOP: strenges Kompilieren - nichts geaendert"; exit 1; }
"$VPY" - "$DASH" "$W/work/dashboard.py" << 'PY' || { echo "STOP: Werte nicht gleich - nichts geaendert"; exit 1; }
import ast, sys, warnings
warnings.simplefilter("ignore")
a = ast.parse(open(sys.argv[1], encoding="utf-8").read())
b = ast.parse(open(sys.argv[2], encoding="utf-8").read())
ca = [n.value for n in ast.walk(a) if isinstance(n, ast.Constant) and isinstance(n.value, (str, bytes))]
cb = [n.value for n in ast.walk(b) if isinstance(n, ast.Constant) and isinstance(n.value, (str, bytes))]
ok = ca == cb and ast.dump(a) == ast.dump(b)
print("Wertepruefung: %d String-Konstanten, alle identisch=%s, AST identisch=%s" % (len(ca), ca == cb, ast.dump(a) == ast.dump(b)))
sys.exit(0 if ok else 1)
PY
echo "OK Trockenlauf: idempotent, Werte identisch, 0 SyntaxWarning"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /funk /mesh /mesh2 /luft /pi /api/funk/harden /api/funk/atomic; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done

# ---------- Einspielen ----------
rb() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-escfix-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service || true
  for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
  echo "alter Stand wieder aktiv (HTTP / = $(code "$B/"))"
}
sudo -v
cp -a "$DASH" "$DASH.bak-escfix-$TS"
cp "$W/work/dashboard.py" "$DASH"
"$VPY" -W error::SyntaxWarning -m py_compile "$DASH" || { rb "py_compile"; exit 1; }
touch "$DASH_DIR/last_dashboard_restart.txt"   # Watchdog-Cooldown waehrend des Neustarts
SINCE=$(date '+%Y-%m-%d %H:%M:%S')
sudo systemctl restart prepper-dashboard.service
echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; 5 min Ruhezeit, sendet nichts) ..."
ok=0
for i in $(seq 1 80); do
  sleep 3
  [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
  (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
done
[[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fail=0
for p in / /funk /mesh /mesh2 /luft /pi /api/funk/harden /api/funk/atomic; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
[[ "$fail" -eq 0 ]] || { rb "Seite antwortet schlechter als vorher"; exit 1; }
nw=$( (sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null || true) | grep -c 'SyntaxWarning' || true)
echo "SyntaxWarning im Journal seit Neustart: $nw"
echo "dashboard.py nachher sha16 $(sha256sum "$DASH" | cut -c1-16)"
echo "Backup: dashboard.py.bak-escfix-$TS"
echo "OK escfix fertig: 0 Escape-Warnungen, Seiten unveraendert"
echo "COMMIT $COMMIT_ARG escfix=1"
