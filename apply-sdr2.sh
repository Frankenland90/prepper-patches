#!/bin/bash
set -euo pipefail
# sdrFunk2: SDR-Kachel von der Lage-Seite nach ganz unten auf die Funk-Seite (/funk), kompakt einzeilig;
# /funk433 und /aprs verlinken zurueck auf Funk. Nur Anzeige - sendet nichts. Nur bei dashboard.py sha16 39a804e354c250e4.
# Neustart nur prepper-dashboard (prepper-sdr bleibt unberuehrt).
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdr2-apply
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== sdrFunk2 apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="2de8588fcfcf6c13d6e5cc3e4aadec3fdbc55ddac336a8295ecc882d63649208"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-sdr2.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""sdrFunk2: SDR-Kachel von Lage nach unten auf /funk, kompakt; Links /funk433 /aprs zurueck auf Funk. Sendet nichts."""
import ast
import hashlib
import sys
from pathlib import Path

MARK = "# ===== sdrFunk2:"
EXPECT = "39a804e354c250e4"
NEWTILE = r'''_SDR_TILE_JS = """<script id="sdr-js">
(function(){""" + _SDR_JS_COMMON + """
function ln(c,txt,col,href){var d=sdrEl(href?'a':'div','sdr-l',txt);if(href){d.href=href;}if(col)d.style.color=col;c.appendChild(d);return d;}
function render(d){var c=document.getElementById('sdrCard');if(!c||!d)return;c.textContent='';var now=d.now,s=d.status||{};
c.appendChild(sdrEl('div','title','📻 SDR-Empfänger'));var l=sdrLine(d);
ln(c,'● '+l.txt,l.col);
ln(c,'📡 433 MHz: '+d.n433_1h+' Sensoren/1h · letztes '+sdrAgo(d.last_433_t,now)+' ›',null,'/funk433');
(d.temps||[]).slice(0,2).forEach(function(t){ln(c,'· '+t.model+(t.ch!==undefined&&t.ch!==null?' K'+t.ch:'')+': '+sdrN(t.c)+' °C'+(t.h!==undefined&&t.h!==null?' · '+t.h+' %':''),'#94a3b8');});
ln(c,'📻 APRS: '+d.naprs_1h+' Stationen/1h · letztes '+sdrAgo(d.last_aprs_t,now)+(d.aprs_far?' · weiteste '+d.aprs_far+' '+sdrN(d.aprs_far_km)+' km':'')+' ›',null,'/aprs');
if(d.last_msg)ln(c,'✉ '+d.last_msg.from+' → '+(d.last_msg.to||'')+': '+String(d.last_msg.text||'').slice(0,60),'#94a3b8');
if(s.err&&d.state!=='ok')ln(c,'⚠ '+String(s.err).slice(0,90),'#eab308');
sdrBtns(c,d,poll);}
function poll(){fetch('/api/sdr/status').then(function(r){return r.json();}).then(render).catch(function(){});}
function place(){var c=document.getElementById('sdrCard');if(!c||c.getAttribute('data-p')==='1')return;
document.body.appendChild(c);c.style.display='';c.setAttribute('data-p','1');
try{render(JSON.parse(document.getElementById('sdrTileData').textContent));}catch(e){}setInterval(poll,60000);}
document.addEventListener('DOMContentLoaded',place);setTimeout(place,700);
})();
</script>"""

_SDR_TILE_CSS = """<style id="sdr-style">
#sdrCard{margin-top:12px}
#sdrCard .title{font-size:.75rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.06em;margin-bottom:6px}
#sdrCard .sdr-l{display:block;font-size:.78rem;line-height:1.5;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#e2e8f0;text-decoration:none}
#sdrCard a.sdr-l:hover{color:#93c5fd}
#sdrCard .btns{display:flex;flex-wrap:wrap;gap:5px;margin-top:8px}
#sdrCard .sdr-btn{background:#1e293b;color:#cbd5e1;border:1px solid #334155;border-radius:8px;padding:3px 7px;font-size:.7rem;cursor:pointer}
#sdrCard .sdr-btn.on{background:#1d4ed8;color:#fff;border-color:#3b82f6}
</style>"""
'''
REPL = [
    ("""<a href="/">↩ Lage</a>""", """<a href="/funk">↩ Funk</a>"""),
    ("""        if _sdr_req.path not in ("/", "/pi") or resp.status_code""", """        if _sdr_req.path not in ("/funk", "/pi") or resp.status_code"""),
    ("""        if _sdr_req.path == "/":\n            blk = ('<div class="card" id="sdrCard\"""", """        if _sdr_req.path == "/funk":\n            blk = ('<div class="card" id="sdrCard\""""),
]


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    if MARK in src:
        print("RESULT dashboard.py=schon sha16 %s" % h)
        return
    if h != EXPECT and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    if src.count("# ===== sdrFunk:") != 1 or src.count("# ===== /sdrFunk =====") != 1:
        raise SystemExit("STOP: sdrFunk-Block nicht eindeutig - nichts geaendert")
    a = src.find("\n_SDR_TILE_JS = ")
    b = src.find("\n_SDR_PI_JS = ")
    if a < 0 or b < a or src.count("\n_SDR_TILE_JS = ") != 1:
        raise SystemExit("STOP: Kachel-Code nicht gefunden - nichts geaendert")
    new = src[:a] + "\n" + MARK + " SDR-Kachel unten auf der Funk-Seite (nicht mehr Lage), kompakt einzeilig =====\n" + NEWTILE.strip("\n") + "\n# ===== /sdrFunk2 =====\n\n" + src[b:]
    for old, rep in REPL:
        if new.count(old) != 1:
            raise SystemExit("STOP: Stelle %r %d mal - nichts geaendert" % (old[:50], new.count(old)))
        new = new.replace(old, rep)
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s, nachher %s)" % (h, hashlib.sha256(new.encode()).hexdigest()[:16]))


if __name__ == "__main__":
    main()
PATCHPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-sdr2.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
vals = {}
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("NEWTILE", "REPL"):
        vals[n.targets[0].id] = n.value
if "NEWTILE" not in vals or "REPL" not in vals:
    raise SystemExit(4)
code = vals["NEWTILE"].value
hit = False
tree = ast.parse(code)
for node in tree.body:
    if not (isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id in ("_SDR_TILE_JS", "_SDR_TILE_CSS")):
        print("Kachel-Code: nur Text-Konstanten erlaubt"); hit = True
for node in ast.walk(tree):
    if isinstance(node, (ast.Call, ast.Import, ast.ImportFrom, ast.Subscript)):
        print("Kachel-Code: Aufruf/Import"); hit = True
for t in vals["REPL"].elts:
    o, r = t.elts[0].value, t.elts[1].value
    for x in (o, r):
        for bad in ("send", "mesh", "subprocess", "open(", "data_store"):
            if bad in x:
                print("Ersetzung enthaelt", bad); hit = True
for bad in ("send", "mesh", "POST"):
    if bad in code.replace("method:'POST'", ""):
        print("Kachel-Code enthaelt", bad); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (nur Anzeige-Text, kein Mesh, keine Aufrufe)"

# ---------- 1) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error::SyntaxWarning -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /funk /pi /funk433 /aprs /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /funk=${PRE[/funk]} /pi=${PRE[/pi]} /funk433=${PRE[/funk433]} /aprs=${PRE[/aprs]}"
[[ "${PRE[/funk]}" == "200" ]] || { echo "STOP: /funk antwortet nicht (${PRE[/funk]}) - nichts geaendert"; exit 1; }
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l)

if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK sdrFunk2 schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-sdr2-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-sdr2-$TS"
  }
  cp -a "$F" "$F.bak-sdr2-$TS"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  "${CURL[@]}" -L --max-redirs 5 "$B/" -o "$W/lage.html" || true
  if grep -q -e 'id="sdr-js"' -e 'id="sdrCard"' "$W/lage.html"; then rb "Lage-Seite hat noch die SDR-Kachel"; exit 1; fi
  echo "OK Lage-Seite ohne SDR-Kachel"
  fc=$("${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" -w "%{http_code}" || true)
  [[ "$fc" == "200" ]] || { rb "/funk antwortet nicht ($fc)"; exit 1; }
  python3 - "$W/funk.html" << 'PY' || { rb "/funk: SDR-Kachel fehlt oder nicht zuletzt"; exit 1; }
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
i = h.find('id="sdrCard"')
assert i > 0 and h.count('id="sdrCard"') == 1 and 'id="sdr-js"' in h and 'sdr-l' in h, "Kachel fehlt"
assert h.rfind('class="card') == h.rfind('class="card', 0, i), "Kachel nicht als letzte Karte"
assert "document.body.appendChild(c)" in h and "/funk433" in h and "/aprs" in h
PY
  echo "OK /funk mit SDR-Kachel als letzte Karte (Links /funk433 /aprs)"
  for pg in /funk433 /aprs; do
    pc=$("${CURL[@]}" "$B$pg" -o "$W/pg.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] && grep -q 'href="/funk">↩ Funk' "$W/pg.html" && ! grep -q 'href="/">↩ Lage' "$W/pg.html" || { rb "$pg fehlerhaft ($pc)"; exit 1; }
  done
  echo "OK /funk433 + /aprs verlinken zurueck auf Funk"
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] && grep -q 'id="sdr-pi-js"' "$W/pi.html" || { rb "/pi ohne SDR-Zeile"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l)
    [[ "$R1" == "$R0" ]] || { rb "/pi Sicherung veraendert"; exit 1; }
    echo "OK /pi SDR-Zeile + Sicherung unveraendert (doPrepperRestore $R1)"
  fi
  sc=$("${CURL[@]}" "$B/api/sdr/status" -o /dev/null -w "%{http_code}" || true)
  [[ "$sc" == "200" ]] || { rb "/api/sdr/status ($sc)"; exit 1; }
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'sdrFunk' | tail -2 || true
fi
fail=0
for p in / /funk /pi /funk433 /aprs /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-sdr2-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "prepper-sdr: $(systemctl is-active prepper-sdr 2>/dev/null || true) (unberuehrt)"
echo "OK guards sdrFunk2=$(grep -q '# ===== sdrFunk2:' "$F" && echo 1 || echo 0) sdrFunk=$(grep -q '# ===== sdrFunk:' "$F" && echo 1 || echo 0) speedTile=$(grep -q '# ===== speedTile:' "$F" && echo 1 || echo 0) piPolish2=$(grep -q '# ===== piPolish2:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-sdr2-$TS" ]] && echo "Backup: $F.bak-sdr2-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG sdrFunk2=1"
