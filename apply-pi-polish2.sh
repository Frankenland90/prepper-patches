#!/bin/bash
set -euo pipefail
# piPolish2: Sicherung (#backupBox) als letzte Karte, kompakte einzeilige Eintraege, nur die 5 neuesten. Wiederherstellen unveraendert.
# Nur bei dashboard.py sha16 527140d85d3ed165. Nur Anzeige, sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/pipolish2
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== piPolish2 apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="1826ac643f39c74e092a4b42898996fd45b671f4a0419b4d3e958f822bc25835"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-pi-polish2.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""piPolish2: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== piPolish2:"
EXPECT = "527140d85d3ed165"
NEED = ["# ===== piPolish:", "# ===== sdHealth:", "# ===== sourceWatch:", "backupBox", "doPrepperRestore", "after_request"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== piPolish2: Sicherung (#backupBox) als letzte Karte, kompakte Zeilen, nur die 5 neuesten (nur Anzeige) =====
# Server: #backupBox-Block hinter alle eingefuegten Karten verschieben (laeuft als letzter after_request-Haken).
# Browser: nach piPolish erneut ans Ende, Zeilen einzeilig, Original-Knoepfe nur verschoben (nie kopiert), onclick unveraendert.
import re as _pp2_re

_PP2_TOK = _pp2_re.compile(r"<script\b.*?</script>|<div\b|</div>", _pp2_re.S | _pp2_re.I)
_PP2_START = _pp2_re.compile(r"<div\b[^>]*\bid=[\"']backupBox[\"'][^>]*>", _pp2_re.I)


def _pp2_block(body):
    """(start, end) des #backupBox-Blocks mit ausbalancierten div-Tags, sonst None."""
    ms = list(_PP2_START.finditer(body))
    if len(ms) != 1:
        return None
    s = ms[0].start()
    depth = 0
    for m in _PP2_TOK.finditer(body, s):
        t = m.group(0)
        if t.lower().startswith("<script"):
            continue
        if t.lower() == "<div":
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return s, m.end()
    return None


_PP2_CSS = """<style id="pp2-style">
#backupBox .pp2-row{display:flex;align-items:center;gap:6px;flex-wrap:nowrap!important;white-space:nowrap;overflow:hidden;font-size:13px;line-height:1.7;min-width:0}
#backupBox .pp2-txt{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis}
#backupBox .pp2-m{opacity:.6;margin:0 3px}
#backupBox .pp2-h{opacity:.55;font-variant-numeric:tabular-nums}
#backupBox .pp2-row button{margin-left:auto!important;flex:none;padding:2px 8px!important;font-size:11px!important;line-height:1.4!important;border-radius:6px!important;margin-top:0!important}
#backupBox .pp2-more{background:none;border:0;color:#60a5fa;font-size:12px;padding:2px 0;cursor:pointer}
</style>"""

_PP2_JS = """<script id="pp2-js">
(function(){
var DRX=/(Mo|Di|Mi|Do|Fr|Sa|So)?\\s*(\\d{2})\\.(\\d{2})\\.(\\d{4})\\s+(\\d{2}):(\\d{2})(?::(\\d{2}))?/;
function last(){var box=document.getElementById('backupBox');if(!box)return;
var all=Array.prototype.slice.call(document.querySelectorAll('.card')).filter(function(x){return x!==box&&!box.contains(x)&&!(x.parentNode&&x.parentNode.closest&&x.parentNode.closest('.card'));});
var l=all[all.length-1];
if(l&&l.nextElementSibling!==box){l.parentNode.insertBefore(box,l.nextSibling);}
document.body.setAttribute('data-pp2-backup','zuletzt');}
function compact(){var box=document.getElementById('backupBox');if(!box||box.getAttribute('data-pp2')==='1')return;
var rows=[];Array.prototype.slice.call(box.querySelectorAll('span')).forEach(function(sp){
if(sp.closest('#bakRestorePanel'))return;
var r=sp.parentElement;if(!r||r===box||r.tagName!=='DIV'||rows.indexOf(r)>=0)return;
if(DRX.test(sp.textContent||'')&&r.querySelectorAll('span').length<=6){rows.push(r);}});
rows=rows.filter(function(r){return !rows.some(function(o){return o!==r&&r.contains(o);});});
if(!rows.length){box.setAttribute('data-pp2','0');return;}
var list=rows[0].parentNode;
rows.forEach(function(r){r._t=0;var tx=null;Array.prototype.slice.call(r.children).forEach(function(c){if(c.tagName==='SPAN'&&DRX.test(c.textContent||''))tx=c;});
if(!tx)return;var s=(tx.textContent||'').replace(/\\s+/g,' ').trim();var m=s.match(DRX);if(!m)return;
r._t=Date.UTC(+m[4],+m[3]-1,+m[2],+m[5],+m[6],+(m[7]||0));
var rest=s.slice(m.index+m[0].length);var md=(rest.match(/\\(([A-Za-z])\\)/)||[])[1]||'';
var parts=rest.replace(/\\([A-Za-z]\\)/,'').split('·').map(function(p){return p.trim();}).filter(function(p){return p&&p!=='–'&&p!=='-';});
var hash='';var lab=[];parts.forEach(function(p){var h=p.match(/^#?([0-9a-f]{6,})$/i);if(h)hash='#'+h[1].slice(0,7);else lab.push(p);});
tx.textContent='';tx.className=(tx.className?tx.className+' ':'')+'pp2-txt';tx.title=s;
tx.appendChild(document.createTextNode((m[1]?m[1]+' ':'')+m[2]+'.'+m[3]+'. '+m[5]+':'+m[6]));
if(md){var a=document.createElement('span');a.className='pp2-m';a.textContent=md;tx.appendChild(a);}
if(lab.length){tx.appendChild(document.createTextNode(lab.join(' · ')+' '));}
if(hash){var h2=document.createElement('span');h2.className='pp2-h';h2.textContent=hash;tx.appendChild(h2);}
r.classList.add('pp2-row');});
var sorted=rows.slice().sort(function(a,b){return b._t-a._t;});
sorted.forEach(function(r){if(r.parentNode===list)list.appendChild(r);});
var n=sorted.length;sorted.forEach(function(r,i){if(i>=5){r.style.display='none';r.setAttribute('data-pp2-hidden','1');}});
if(n>5){var t=document.createElement('button');t.type='button';t.className='pp2-more';var open=false;
t.textContent='alle anzeigen ('+n+')';t.addEventListener('click',function(){open=!open;
sorted.forEach(function(r,i){if(i>=5)r.style.display=open?'':'none';});t.textContent=open?'weniger anzeigen':'alle anzeigen ('+n+')';});
list.parentNode.insertBefore(t,list.nextSibling);}
box.setAttribute('data-pp2','1');}
function run(){try{compact();}catch(e){}try{last();}catch(e){}}
document.addEventListener('DOMContentLoaded',run);window.addEventListener('load',run);setTimeout(run,800);
})();
</script>"""


def _pp2_after(resp):
    try:
        from flask import request as _pp2_req
        if _pp2_req.path != "/pi" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="pp2-js"' in body:
            return resp
        blk = _pp2_block(body)
        if blk:
            s, e = blk
            box = body[s:e]
            rest = body[:s] + body[e:]
            j = rest.rfind("</body>")
            if j >= 0:
                body = rest[:j] + box + rest[j:]
        i = body.find("</head>")
        body = (body[:i] + _PP2_CSS + body[i:]) if i >= 0 else (_PP2_CSS + body)
        j = body.rfind("</body>")
        if j >= 0:
            body = body[:j] + _PP2_JS + body[j:]
        resp.set_data(body)
    except Exception as e:
        print("piPolish2 /pi:", e, flush=True)
    return resp


try:
    _pp2_l = app.after_request_funcs.setdefault(None, [])
    _pp2_ix = 0
    for _pp2_n, _pp2_f in enumerate(list(_pp2_l)):
        if "compress" in (getattr(_pp2_f, "__module__", "") or "").lower() or "compress" in (getattr(_pp2_f, "__qualname__", "") or "").lower():
            _pp2_ix = _pp2_n + 1
    _pp2_l.insert(_pp2_ix, _pp2_after)
    print("piPolish2 aktiv (after_request Position %d von %d)" % (_pp2_ix, len(_pp2_l)), flush=True)
except Exception as _pp2_e:
    app.after_request(_pp2_after)
    print("piPolish2 aktiv (Fallback):", _pp2_e, flush=True)
# ===== /piPolish2 =====

'''


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
    miss = [a for a in NEED if a not in src]
    if miss:
        raise SystemExit("STOP: fehlt %s - nichts geaendert" % miss)
    if "pp2-js" in src:
        raise SystemExit("STOP: pp2-js gibt es schon - nichts geaendert")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s, nachher %s)" % (h, hashlib.sha256(new.encode()).hexdigest()[:16]))


if __name__ == "__main__":
    main()
PATCHPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-pi-polish2.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if a.name.split(".")[0] in ("requests", "urllib", "socket", "http", "subprocess", "meshtastic"):
                print("verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        f = node.func
        fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("update_all", "urlopen", "Popen", "system", "remove", "unlink"):
            print("verbotener Aufruf", fn); hit = True
        if fn == "open" and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and any(c in str(node.args[1].value) for c in "wax+"):
            print("Schreib-open im Block"); hit = True
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
        print("data_store-Schreiben"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (Block liest nur, kein Senden, kein Abruf, kein Schreiben)"

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
for p in / /pi /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /energie=${PRE[/energie]}"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l); P0=$(grep -o 'id=.bakRestorePanel' "$W/pi0.html" | wc -l)
echo "vorher /pi: doPrepperRestore $R0 mal, bakRestorePanel $P0, backupBox $(grep -c 'id=.backupBox' "$W/pi0.html" || true)"

if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK piPolish2 schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-pipolish2-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-pipolish2-$TS"
  }
  cp -a "$F" "$F.bak-pipolish2-$TS"
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
  if [[ "${PRE[/pi]}" == "200" ]]; then
    pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" -w "%{http_code}" || true)
    [[ "$pc" == "200" ]] || { rb "/pi antwortet nicht mehr"; exit 1; }
    grep -q 'id=.pp2-js' "$W/pi.html" || { rb "/pi ohne piPolish2"; exit 1; }
    R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l); P1=$(grep -o 'id=.bakRestorePanel' "$W/pi.html" | wc -l)
    echo "nachher /pi: doPrepperRestore $R1 mal (vorher $R0), bakRestorePanel $P1 (vorher $P0)"
    [[ "$R1" == "$R0" && "$P1" == "$P0" ]] || { rb "Wiederherstellen-Teile veraendert"; exit 1; }
    python3 - "$W/pi.html" << 'PY'
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
b = h.find('id="backupBox"')
pos = {m: h.find(m) for m in ("src-card", "sd-card", "arch-card")}
print("Server-Reihenfolge:", ", ".join("%s@%d" % kv for kv in sorted(pos.items(), key=lambda kv: kv[1])), "backupBox@%d" % b)
if b < 0:
    print("Hinweis: backupBox nicht im Server-HTML")
elif all(p < 0 or p < b for p in pos.values()):
    print("OK backupBox steht im Server-HTML hinter allen Karten")
else:
    print("WARN backupBox nicht hinter allen Karten - Browser setzt sie ans Ende")
PY
  fi
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a 'piPolish2' | tail -2 || true
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-pipolish2-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "OK guards piPolish2=$(grep -q '# ===== piPolish2:' "$F" && echo 1 || echo 0) piPolish=$(grep -q '# ===== piPolish:' "$F" && echo 1 || echo 0) sdHealth=$(grep -q '# ===== sdHealth:' "$F" && echo 1 || echo 0) sourceWatch=$(grep -q '# ===== sourceWatch:' "$F" && echo 1 || echo 0) firmsKeep=$(grep -q '# ===== firmsKeep:' "$F" && echo 1 || echo 0) longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) priceAllTime=$(grep -q '# ===== priceAllTime:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-pipolish2-$TS" ]] && echo "Backup: $F.bak-pipolish2-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG piPolish2=1"
