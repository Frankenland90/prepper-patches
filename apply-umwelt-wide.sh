#!/bin/bash
set -euo pipefail
# umweltWide: /umwelt - Waldbrand-Kachel (und jede andere Kachel ohne 'full') ueber die volle Breite wie die anderen.
# Nur after_request auf /umwelt (Klasse + CSS im ausgelieferten HTML), Vorlagen unveraendert. Neustart nur prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/umw-apply
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== umweltWide apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="889bda1c7e5d367e19ab7c333083eaa5562ad65dae7e7bb4d10bc0356f88cd5e"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-umwelt-wide.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""umweltWide: Block vor __main__ in dashboard.py - /umwelt: Waldbrand-Kachel und alle Kacheln ohne 'full' volle Breite
(after_request, nur Ausgabe-HTML von /umwelt, Vorlagen bleiben unveraendert). Sendet nichts. Verlangt Guards sdrNoise2..sdrFunk."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== umweltWide:"
GUARDS = ["sdrNoise2", "sdrGps", "sdrNoise", "sdrRf", "sdrRds", "sdrStick", "sdrAct", "sdrPreset", "sdrPlus", "sdAck", "sdrFunk2", "sdrFunk"]
NEED = ["# ===== %s:" % g for g in GUARDS] + ["app = Flask(", "Waldbrand"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''# ===== umweltWide: /umwelt alle Kacheln volle Breite (Waldbrand + weitere ohne 'full'), nur Ausgabe-Klasse + CSS, keine Vorlage geaendert =====
import re as _umw_re

_UMW_CARD_RE = _umw_re.compile(r'<div class="card"(\s[^>]*)?>')
_UMW_WB_RE = _umw_re.compile(r'<div class="card(?: [^"]*)?"[^>]*>\s*<div class="title">[^<]*Waldbrand', _umw_re.S)
_UMW_CSS = '<style id="umw-wide-css">.umw-wide{grid-column:1/-1 !important;width:auto;max-width:none;box-sizing:border-box}</style>'


def _umw_widen(body):
    """Nur Kacheln mit genau class=card (ohne full) bekommen 'card full umw-wide'; Waldbrand immer. -> (body, n)"""
    n = [0]

    def rep(m):
        n[0] += 1
        return '<div class="card full umw-wide"%s>' % (m.group(1) or "")
    body = _UMW_CARD_RE.sub(rep, body)

    def rep_wb(m):
        s = m.group(0)
        if "umw-wide" in s.split(">", 1)[0]:
            return s
        n[0] += 1
        return s.replace('<div class="card', '<div class="card umw-wide full', 1)
    body = _UMW_WB_RE.sub(rep_wb, body)
    j = body.find("</head>")
    body = (body[:j] + _UMW_CSS + body[j:]) if j >= 0 else (_UMW_CSS + body)
    return body, n[0]


def _umw_after(resp):
    try:
        from flask import request as _umw_rq
        if _umw_rq.path.rstrip("/") == "/umwelt" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="umw-wide-css"' not in body:
                body, n = _umw_widen(body)
                resp.set_data(body)
                resp.headers["X-Umwelt-Wide"] = str(n)
    except Exception as e:
        print("umweltWide:", e, flush=True)
    return resp


try:
    if not any(getattr(f, "__name__", "") == "_umw_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_umw_after)
    print("umweltWide aktiv", flush=True)
except Exception as _umw_e:
    print("umweltWide:", _umw_e, flush=True)
# ===== /umweltWide =====
'''


def h16(s):
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    src = f.read_text(encoding="utf-8")
    h = h16(src)
    if MARK in src:
        if BLOCK not in src:
            raise SystemExit("STOP: umweltWide-Guard da, aber Block weicht ab (sha16 %s) - nichts geaendert" % h)
        print("RESULT dashboard.py=schon sha16 %s" % h)
        return
    miss = [a for a in NEED if a not in src]
    if miss:
        raise SystemExit("STOP: dashboard.py sha16 %s ohne %s - nichts geaendert" % (h, miss))
    if "_umw_" in src or "umw-wide" in src:
        raise SystemExit("STOP: umweltWide-Teile schon da - nichts geaendert")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1 or ms[0].start() < src.index("# ===== /sdrNoise2 ====="):
        raise SystemExit("STOP: __main__ nicht eindeutig hinter sdrNoise2")
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (Guards ok; sha16 vorher %s, nachher %s)" % (h, h16(new)))


if __name__ == "__main__":
    main()
PATCHPY_EOF
P="$W/patch-umwelt-wide.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -W error -m py_compile "$P" || { echo "STOP: py_compile Patch"; exit 1; }
set +e
python3 - "$P" << 'GUARDPY'
import ast, sys
blk = None
for n in ast.parse(open(sys.argv[1], encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
low = blk.lower()
for bad in ("mesh", "socket", "subprocess", "urllib", "requests.", "http://", "https://", "os.system", "popen", "shell=", "open(", "write_text", "render_template", "templates"):
    if bad in low:
        print("Block enthaelt", bad); hit = True
def fname(f):
    return f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            m = getattr(node, "module", None) or a.name
            if m not in ("re", "flask"):
                print("Import", m); hit = True
    if isinstance(node, ast.Call) and fname(node.func) in ("bind", "listen", "accept", "connect", "send", "sendall", "run", "call", "system", "remove", "unlink", "setattr", "exec", "eval"):
        print("Aufruf", fname(node.func)); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (nur re/flask, kein Netz, kein Mesh, keine Dateien, keine Vorlage)"

[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
for gm in sdrNoise2 sdrGps sdrNoise sdrRf sdrRds sdrStick sdrAct sdrPreset sdrPlus sdAck sdrFunk2 sdrFunk; do
  grep -q "# ===== $gm:" "$F" || { echo "STOP: dashboard.py ohne Guard $gm - nichts geaendert"; exit 1; }
done
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"

rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
[[ "${PRE[/umwelt]}" == "200" ]] || { echo "STOP: /umwelt antwortet nicht (${PRE[/umwelt]}) - nichts geaendert"; exit 1; }
"${CURL[@]}" "$B/umwelt" -o "$W/umwelt0.html" || true
python3 - "$W/umwelt0.html" << 'PY' || { echo "STOP: Waldbrand-Kachel auf /umwelt nicht gefunden - nichts geaendert"; exit 1; }
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
cards = re.findall(r'<div class="(card[^"]*)"[^>]*>\s*<div class="title">([^<]*)', h)
narrow = [t.strip() for c, t in cards if c.split()[0] == "card" and "full" not in c.split()]
print("Kacheln auf /umwelt: %d, davon ohne volle Breite: %s" % (len(cards), ", ".join(narrow) or "keine"))
assert any("Waldbrand" in t for _c, t in cards), "keine Waldbrand-Kachel"
PY
if grep -q 'id="umw-wide-css"' "$W/umwelt0.html" && cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK umweltWide schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | tail -12 | cut -c1-200 || true
    cp -a "$F.bak-umw-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-umw-$TS"
  }
  cp -a "$F" "$F.bak-umw-$TS"
  cp "$W/work/dashboard.py" "$F.new" && mv -f "$F.new" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet (nur prepper-dashboard; sendet nichts) - warte auf HTTP (max 240 s) ..."
  ok=0
  for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }; done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  uc=$(code_r "$B/umwelt"); [[ "$uc" == "200" ]] || { rb "/umwelt fehlerhaft ($uc)"; exit 1; }
  "${CURL[@]}" "$B/umwelt" -o "$W/umwelt.html" || true
  python3 - "$W/umwelt.html" "$W/umwelt0.html" << 'PY' || { rb "/umwelt: Waldbrand-Kachel ohne volle Breite oder Inhalt veraendert"; exit 1; }
import re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
h0 = open(sys.argv[2], encoding="utf-8", errors="replace").read()
assert h.count('id="umw-wide-css"') == 1 and "grid-column:1/-1" in h, "CSS fehlt"
cards = re.findall(r'<div class="(card[^"]*)"[^>]*>\s*<div class="title">([^<]*)', h)
wb = [c for c, t in cards if "Waldbrand" in t]
assert wb and all("umw-wide" in c.split() and "full" in c.split() for c in wb), ("Waldbrand", wb)
narrow = [t for c, t in cards if c.split()[0] == "card" and "full" not in c.split()]
assert not narrow, ("noch schmal", narrow)
cards0 = re.findall(r'<div class="(card[^"]*)"[^>]*>\s*<div class="title">([^<]*)', h0)
assert [t for _c, t in cards0] == [t for _c, t in cards], "Kachel-Reihenfolge/Anzahl veraendert"
strip = lambda s: re.sub(r'<style id="umw-wide-css">.*?</style>', "", re.sub(r' umw-wide| full umw-wide', "", s), flags=re.S)
assert len(strip(h)) > 0.9 * len(h0), "Seite deutlich kuerzer"
print("OK /umwelt: Waldbrand-Kachel %s, %d Kacheln, alle volle Breite" % (wb[0], len(cards)))
PY
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a 'umweltWide' | tail -2 || true
  for pg in /funk /pi; do
    "${CURL[@]}" -L --max-redirs 5 "$B$pg" -o "$W/pg.html" || true
    if grep -q 'umw-wide' "$W/pg.html"; then rb "$pg veraendert (nur /umwelt erlaubt)"; exit 1; fi
  done
  echo "OK /funk und /pi unveraendert (nur /umwelt betroffen)"
fi
fail=0
for p in "${PAGES[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-umw-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
GL=""; for gm in umweltWide sdrNoise2 sdrGps sdrNoise sdrRf sdrRds sdrStick sdrAct sdrPreset sdrPlus sdAck sdrFunk2 sdrFunk; do GL="$GL $gm=$(grep -c "# ===== $gm:" "$F" || true)"; done
echo "OK guards$GL"
[[ -f "$F.bak-umw-$TS" ]] && echo "Backup: $F.bak-umw-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG umweltWide=1"
