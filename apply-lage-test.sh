#!/bin/bash
set -euo pipefail
# lageTest: Lage-Seite, BR24-Kachel: Knoepfe 'Testnachricht vorbereiten' (BR24, ASA DE). Bereitet NUR einen klar markierten TEST-Text vor
# (5 min gueltig) und schaltet den vorhandenen Knopf 'An Mesh 1 senden' dafuer frei. Senden nur per Klick + Bestaetigung ueber die vorhandene Sendestelle.
# Nie automatisch. Neustart nur prepper-dashboard. Aendert prepper_sdr.py nicht.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/lagetest-apply
KEEP_LAST=3
BASE_DASH16="d0e5ad5d32143b14"
BASE_MOD16="78b9106899d1fbbd"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== lageTest apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work"
EXPECT_BLK="e8e9940cc7d0d4c25befe5c78b93c39a8dad8bc0178523f0ce26344adf42a015"
cat > "$W/lt_block.py" << 'LTBLK_EOF'
# ===== lageTest: Lage-Seite - Knopf 'Testnachricht vorbereiten' fuer BR24 und ASA DE; bereitet nur einen klar markierten TEST-Text vor (5 min gueltig) und schaltet damit den vorhandenen Knopf frei; gesendet wird nur per Klick + Bestaetigung ueber die vorhandene Sendestelle; nie automatisch, Kachel bleibt nicht-rot =====
import threading as _lt_threading
import time as _lt_time

LT_TTL_S = 300                 # Vorbereitung verfaellt nach 5 min
_lt_lock = _lt_threading.Lock()
_lt_armed = {}                 # nur im Speicher: {"kind": "br24"|"asa", "text": ..., "t": ..., "until": ...}
_LT_TXT = {"br24": "TEST BR24-Warnkette · keine echte Warnung · %s", "asa": "TEST ASA DE (DAB 5C) · keine echte Warnung · %s"}


def _lt_text(kind, now):
    return _lm1_cut(_LT_TXT[kind] % _lt_time.strftime("%d.%m.%Y %H:%M", _lt_time.localtime(now)))


def _lt_current(now=None):
    """Gueltige Vorbereitung oder None (abgelaufen / schon gesendet -> weg)."""
    now = now or _lt_time.time()
    with _lt_lock:
        a = dict(_lt_armed)
        if not a:
            return None
        if now > a["until"] or any(s == "br24" and tx == a["text"] and t >= a["t"] for t, s, tx in list(_lm1_log)):
            _lt_armed.clear()
            return None
    return a


_lt_orig_texts = _lm1_texts


def _lm1_texts():
    tx = _lt_orig_texts()
    try:
        if not tx.get("br24"):
            a = _lt_current()
            if a:
                tx = dict(tx, br24=a["text"], br24_test=True)
    except Exception as e:
        print("lageTest:", e, flush=True)
    return tx


_lt_orig_status = _lm1_status


def _lm1_status():
    out = _lt_orig_status()
    try:
        a = _lt_current()
        real = bool((_lt_orig_texts() or {}).get("br24"))
        out["test"] = {"armed": bool(a) and not real, "kind": a["kind"] if a else None, "text": a["text"] if a else None,
                       "until": int(a["until"]) if a else None, "until_txt": _br24_fmt(a["until"])[11:] if a else None, "real": real, "ttl": LT_TTL_S}
        if a and not real and isinstance(out.get("br24"), dict):
            out["br24"]["test"] = True
    except Exception as e:
        out["test"] = {"armed": False, "error": str(e)[:80]}
    return out


def _lt_prepare_post():
    """Nur vorbereiten (kein Senden): POST gleicher Ursprung, Kopf X-Lage-Test, kind br24|asa|aus."""
    from flask import jsonify, request as rq
    if not _lm1_same_origin(rq) or rq.headers.get("X-Lage-Test") != "1":
        return jsonify({"ok": False, "error": "nur von der Lage-Seite (gleicher Ursprung)"}), 403
    j = rq.get_json(silent=True) or {}
    kind = j.get("kind")
    if kind not in ("br24", "asa", "aus"):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    now = _lt_time.time()
    if kind == "aus":
        with _lt_lock:
            _lt_armed.clear()
        return jsonify({"ok": True, "armed": False})
    if (_lt_orig_texts() or {}).get("br24"):
        return jsonify({"ok": False, "error": "echte BR24-Warnung aktiv - Test jetzt nicht moeglich"}), 409
    text = _lt_text(kind, now)
    with _lt_lock:
        _lt_armed.clear()
        _lt_armed.update(kind=kind, text=text, t=now, until=now + LT_TTL_S)
    print("lageTest: Testtext vorbereitet (%s), nicht gesendet: %s" % (kind, text), flush=True)
    return jsonify({"ok": True, "armed": True, "kind": kind, "text": text, "until_txt": _br24_fmt(now + LT_TTL_S)[11:]})


_LT_JS = r"""
(function(){var T=null;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
if(!document.getElementById('lt-css')){var s=el('style');s.id='lt-css';s.textContent='.lt-btn{margin:4px 0 0 18px;background:#1f2937;color:#cbd5e1;border:1px dashed #64748b;border-radius:6px;padding:4px 10px;font-size:.85rem;cursor:pointer}.lt-box{margin-top:8px;padding:8px 10px;border:1px dashed #eab308;border-radius:8px;color:#fde68a;background:#1c1917;white-space:normal;overflow-wrap:anywhere;font-size:.9rem}.lt-box button{margin-left:8px;background:none;border:1px solid #64748b;color:#cbd5e1;border-radius:6px;padding:1px 8px;cursor:pointer}';document.head.appendChild(s);}
function prep(kind){fetch('/api/lage_test/prepare',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-Lage-Mesh1':'1','X-Lage-Test':'1'},body:JSON.stringify({kind:kind})})
.then(function(r){return r.json();}).then(function(j){if(!j.ok){window.alert(j.error||'Fehler');}if(window.lm1Reload)window.lm1Reload();setTimeout(load,300);}).catch(function(){window.alert('keine Verbindung');});}
function addBtn(row,kind,label){if(!row||row.querySelector('.lt-btn'))return;var b=el('button','lt-btn','🧪 Testnachricht vorbereiten');b.type='button';b.title='Bereitet nur einen markierten TEST-Text ('+label+') vor - gesendet wird erst mit „An Mesh 1 senden“ und Bestätigung';b.onclick=function(){prep(kind);};row.appendChild(b);}
function fix(){var t=document.getElementById('br24Tile');if(!t)return;
addBtn(t.querySelector('.sdl-br .sdl-tx'),'br24','BR24');addBtn(t.querySelector('.sdl-asa .sdl-tx'),'asa','ASA DE');
var bx=t.querySelector('.lt-box');var a=T&&T.armed&&T.text;
if(!a){if(bx)bx.remove();return;}
if(!bx){bx=el('div','lt-box');var sb=t.querySelector('.lm1-btn');t.insertBefore(bx,sb||null);}
var k=T.text+'|'+T.until_txt;if(bx.dataset.k!==k){bx.dataset.k=k;bx.textContent='🧪 vorbereitet (noch nicht gesendet, gültig bis '+T.until_txt+'): „'+T.text+'“ – senden nur mit „An Mesh 1 senden“ unten';var c=el('button','','verwerfen');c.type='button';c.onclick=function(){prep('aus');};bx.appendChild(c);}}
function load(){fetch('/api/lage_mesh1',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){T=(j&&j.test)||null;fix();}).catch(function(){});}
try{var d=JSON.parse(document.getElementById('lm1-data').textContent);T=d&&d.test;}catch(e){}
fix();load();setInterval(fix,1000);setInterval(load,10000);})();
"""
_LT_JS_HOOK = ("tile();setInterval(tile,2000);setInterval(load,30000);})();", "tile();setInterval(tile,2000);setInterval(load,30000);window.lm1Reload=load;})();")
if _LT_JS_HOOK[0] in _LM1_JS and "lt-css" not in _LM1_JS:
    _LM1_JS = _LM1_JS.replace(_LT_JS_HOOK[0], _LT_JS_HOOK[1], 1) + _LT_JS


def _lt_selftest():
    now = 1760000000.0
    t = _lt_text("br24", now)
    assert t.startswith("TEST BR24-Warnkette · keine echte Warnung · ") and len(t) <= LM1_MAX
    assert _lt_text("asa", now).startswith("TEST ASA DE (DAB 5C) · keine echte Warnung")
    with _lt_lock:
        _lt_armed.update(kind="asa", text="TEST x", t=now, until=now + LT_TTL_S)
    assert _lt_current(now + 10)["text"] == "TEST x"
    assert _lt_current(now + LT_TTL_S + 1) is None and not _lt_armed  # verfaellt
    with _lt_lock:
        _lt_armed.update(kind="br24", text="TEST y", t=now, until=now + LT_TTL_S)
    _lm1_log.append((now + 5, "br24", "TEST y"))
    try:
        assert _lt_current(now + 6) is None  # nach Senden weg
    finally:
        _lm1_log.remove((now + 5, "br24", "TEST y"))
    assert "lm1Reload" in _LM1_JS and _LM1_JS.count("window.lm1Reload=load") == 1 and _LT_JS.count("method:'POST'") == 1 and "/api/lage_test/prepare" in _LT_JS
    assert "/api/lage_mesh1/send" not in _LT_JS and "/send" not in _LT_JS
    return "lageTest selftest ok"


try:
    _lt_st = _lt_selftest()
    if "app" in globals():
        if "lt_prepare" not in app.view_functions:
            app.add_url_rule("/api/lage_test/prepare", endpoint="lt_prepare", view_func=_lt_prepare_post, methods=["POST"])
    print("lageTest aktiv: Testnachricht vorbereiten (BR24, ASA DE), %d s gueltig, nur Senden per Klick; %s" % (LT_TTL_S, _lt_st), flush=True)
except Exception as _lt_e:
    print("lageTest:", _lt_e, flush=True)
# ===== /lageTest =====
LTBLK_EOF
EXPECT_PATCH="e976969f21dd7290d5d5072d091d4d427df2104b5b1bd291ab8e4d322673a75c"
cat > "$W/patch-lt.py" << 'LTPATCH_EOF'
"""lageTest Dashboard-Teil. Aufruf: patch-lt.py QUELLE ZIEL BLOCKDATEI -> 0 ok, 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
if "# ===== lageTest:" in s:
    open(dst, "w", encoding="utf-8").write(s); print("schon da"); raise SystemExit(0)
a = "# ===== /sdrDual =====\n"
for need in (a, "def _lm1_send_post():", "def _lm1_texts():", "def _lm1_status():", "tile();setInterval(tile,2000);setInterval(load,30000);})();"):
    if s.count(need) != 1:
        print("Basis passt nicht:", need[:50], s.count(need)); raise SystemExit(3)
s = s.replace(a, a + blk)
open(dst, "w", encoding="utf-8").write(s)
print("geaendert")
LTPATCH_EOF
P="$W/patch-lt.py"; LB="$W/lt_block.py"
echo "$EXPECT_BLK  $LB" | sha256sum -c - >/dev/null || { echo "STOP: Block sha256 falsch"; exit 1; }
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || { echo "STOP: dashboard.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$DASH_DIR/prepper_sdr.py" | cut -c1-16)
if [[ "$D16" != "$BASE_DASH16" ]] && ! grep -q "# ===== lageTest:" "$F"; then echo "STOP: dashboard.py sha16 $D16 erwartet $BASE_DASH16 - nichts geaendert"; exit 1; fi
[[ "$S16" == "$BASE_MOD16" ]] || echo "Hinweis: prepper_sdr.py sha16 $S16 (erwartet $BASE_MOD16) - wird nicht angefasst"
grep -q "# ===== sdrDual:" "$F" && grep -q "# ===== lageMesh1:" "$F" || { echo "STOP: sdrDual/lageMesh1 fehlt - nichts geaendert"; exit 1; }
echo "OK Basis dashboard.py $D16 ($(wc -l < "$F") Zeilen), prepper_sdr.py $S16"
# ---------- 2) Trockenlauf ----------
python3 "$P" "$F" "$W/work/dashboard.py" "$LB" || { echo "STOP: Dashboard-Basis passt nicht - nichts geaendert"; exit 1; }
python3 "$P" "$W/work/dashboard.py" "$W/work/d2.py" "$LB" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: nicht idempotent"; exit 1; }
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
# ---------- 3) AST-Guard ----------
python3 - "$F" "$W/work/dashboard.py" "$LB" "$P" << 'GUARDPY' || { echo "STOP: Guard - nichts geaendert"; exit 1; }
import ast, sys, re
def info(fn):
    t = ast.parse(open(fn, encoding="utf-8").read()); imp, calls, bad = set(), [], []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names: imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False): bad.append("shell=")
        if isinstance(n, ast.Call):
            f = n.func; nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            calls.append(nm)
    return imp, calls, bad
bi, bc, bb = info(sys.argv[1]); ni, nc, nb = info(sys.argv[2]); li, lc, lb = info(sys.argv[3]); pi, pc, pb = info(sys.argv[4])
err = []
if ni != bi: err.append("Importe geaendert %s" % (ni ^ bi))
if len(nb) != len(bb): err.append("shell=True neu")
for nm in ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "Popen", "system", "run", "call", "check_output", "urlopen", "socket", "create_connection", "bind", "listen", "Thread", "Timer"):
    if nc.count(nm) != bc.count(nm): err.append("Aufrufe %s geaendert (%d->%d)" % (nm, bc.count(nm), nc.count(nm)))
    if nm in lc: err.append("Block ruft %s" % nm)
inst = "# ===== lageTest:" in open(sys.argv[1], encoding="utf-8").read()
if nc.count("add_url_rule") != bc.count("add_url_rule") + (0 if inst else 1): err.append("genau eine neue Route erwartet")
if [c for c in lc if c.startswith(("send", "maybe_mesh"))]: err.append("Block: Sendeaufruf")
if li - {"threading", "time", "flask"} or pi - {"sys"}: err.append("Importe Block/Patch %s %s" % (li, pi))
blk = open(sys.argv[3], encoding="utf-8").read()
js = blk[blk.index('_LT_JS = r"""'):]; js = js[:js.index('"""', 14)]
if js.count("fetch(") != 2 or js.count("method:'POST'") != 1 or "fetch('/api/lage_test/prepare'" not in js or "/send" in js: err.append("JS: nur Vorbereiten-POST + Status-GET erlaubt")
for w in ("XMLHttpRequest", "WebSocket", "sendBeacon", "eval(", "setTimeout(function(){prep"):
    if w in js: err.append("JS enthaelt " + w)
if 'add_url_rule("/api/lage_test/prepare"' not in blk or blk.count("add_url_rule") != 1: err.append("Route")
if err: print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard: keine neue Sendestelle (send_meshtastic %d=%d), keine Prozesse/Netz/Threads neu, genau 1 neue Route (nur Vorbereiten), JS ohne Sende-Aufruf" % (bc.count("send_meshtastic"), nc.count("send_meshtastic")))
GUARDPY
echo "OK Trockenlauf idempotent, py_compile ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 4) Installieren ----------
RESTARTED=0
if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK lageTest schon installiert - kein Neustart"
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -12 | cut -c1-200 || true
    cp -a "$F.bak-lagetest-$TS" "$F.rb" && mv -f "$F.rb" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), dashboard.py $(sha256sum "$F" | cut -c1-16), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null)"
  }
  cp -a "$F" "$F.bak-lagetest-$TS"
  { ls -1t "$F.bak-lagetest-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-lagetest-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-dashboard - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 5) Rauchtest ----------
fail=0
for p in "${PAGES[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite antwortet schlechter als vorher"
for p in /api/sdr/ui /api/br24 /api/lage_mesh1; do c=$(code_r "$B$p"); printf '  HTTP %s = %s\n' "$p" "$c"; [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/" -o "$W/lage.html" || true
python3 - "$W/lage.html" << 'PY' || rbx "Lage-Seite ohne lageTest"
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
assert h.count('id="lm1-js"') == 1 and "lt-css" in h and "window.lm1Reload=load" in h and "Testnachricht vorbereiten" in h, "lageTest-JS fehlt"
print("OK Lage-Seite: Knoepfe 'Testnachricht vorbereiten' (BR24, ASA DE) eingebaut")
PY
c=$(code -X POST -H 'Content-Type: application/json' -H 'X-Lage-Test: 1' -d '{"kind":"br24"}' "$B/api/lage_test/prepare")
[[ "$c" == 403 ]] && echo "OK fremder Aufruf ohne gleichen Ursprung abgelehnt (403)" || rbx "Vorbereiten ohne Ursprung nicht abgelehnt ($c)"
"${CURL[@]}" "$B/api/lage_mesh1" | python3 -c "
import json,sys
d=json.load(sys.stdin); t=d.get('test') or {}
assert 'armed' in t and not t.get('armed'), t
print('OK Status: kein Test vorbereitet, echte BR24-Warnung aktiv: %s, BR24-Knopf aktiv: %s' % (t.get('real'), (d.get('br24') or {}).get('active')))
" || rbx "/api/lage_mesh1 ohne Testfeld"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] || rbx "/pi Sicherung veraendert ($R0/$R1)"
echo "OK /pi doPrepperRestore unveraendert ($R1)"
echo "OK guards lageTest=$(grep -c '# ===== lageTest:' "$F" || true) sdrDual=$(grep -c '# ===== sdrDual:' "$F" || true) lageMesh1=$(grep -c '# ===== lageMesh1:' "$F" || true) br24Warn2=$(grep -c '# ===== br24Warn2:' "$F" || true) sdrLage=$(grep -c '# ===== sdrLage:' "$F" || true) sdrUi=$(grep -c '# ===== sdrUi:' "$F" || true)"
[[ -f "$F.bak-lagetest-$TS" ]] && echo "Backup: $F.bak-lagetest-$TS, behalten: letzte $KEEP_LAST"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; prepper_sdr.py $(sha256sum "$DASH_DIR/prepper_sdr.py" | cut -c1-16), $(wc -l < "$DASH_DIR/prepper_sdr.py") Zeilen (unveraendert)"
echo "Hinweis: gesendet wird nur, wenn du 'An Mesh 1 senden' klickst und bestaetigst."
echo "COMMIT $COMMIT_ARG lageTest=1"
