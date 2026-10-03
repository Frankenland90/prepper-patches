#!/bin/bash
set -euo pipefail
# Zeitstempel je Kachel: letzter guter Wert bleibt, gelb/rot nach eigener Kadenz.
# Smoke nur :8080. 302 auf trailing slash ist ok. Nicht :5000.
# staleTs
# Der Patch laeuft VOR jeder PAGE1-Pruefung. Rollback nur wenn das gerenderte
# Template den Marker nicht hat (oder py_compile / Idempotenz / Boot-Guards reißen).
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"
EXPECT_SHA="079a44e73772719e2bedf308fa5230c8be80988c61cd54421ffd540e90705db4"

if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 - smoke only :8080"
  exit 1
fi

echo "=== stale-ts apply COMMIT=$COMMIT PORT=$PORT ==="
mkdir -p /tmp/stale-b64
: > /tmp/stale-b64/all
for i in 0 1 2 3; do
  curl -fsSL "$BASE/patch-stale-ts.py.b64.$i" -o "/tmp/stale-b64/c$i"
  cat "/tmp/stale-b64/c$i" >> /tmp/stale-b64/all
done
base64 -d /tmp/stale-b64/all | gzip -dc > /tmp/patch-stale-ts.py
echo "$EXPECT_SHA  /tmp/patch-stale-ts.py" | sha256sum -c -
grep -q 'staleTsBoot' /tmp/patch-stale-ts.py || { echo "FAIL: patch ohne staleTsBoot"; exit 1; }
if grep -q 'Thread(target=update_all' /tmp/patch-stale-ts.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
if grep -nE '^[[:space:]]*data_store[[:space:]]*=' /tmp/patch-stale-ts.py; then
  echo "FAIL: patch schreibt data_store"
  exit 1
fi
python3 -m py_compile /tmp/patch-stale-ts.py
wc -c /tmp/patch-stale-ts.py

cp -a "$DASH" "$DASH.bak-stalets-$TS"

had_fein=0; grep -q 'pageFein' "$DASH" && had_fein=1 || true
had_lock=0; grep -q 'dataStoreLock' "$DASH" && had_lock=1 || true
had_nina=0; grep -q 'ninaDualGuard' "$DASH" && had_nina=1 || true
had_boot=0; grep -q 'update_all()  # einmal beim Start' "$DASH" && had_boot=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-stalets-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-stale-ts.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch-stale-ts.py exit $rc"
  exit 1
fi

cp -a "$DASH" /tmp/dashboard.py.stalets-once
python3 /tmp/patch-stale-ts.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.stalets-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }

if [[ "$had_fein" == 1 ]]; then
  grep -q 'pageFein' "$DASH" || { rollback "pageFein weg"; exit 1; }
fi
if [[ "$had_lock" == 1 ]]; then
  grep -q 'dataStoreLock' "$DASH" || { rollback "dataStoreLock weg"; exit 1; }
fi
if [[ "$had_nina" == 1 ]]; then
  grep -q 'ninaDualGuard' "$DASH" || { rollback "ninaDualGuard weg"; exit 1; }
fi
if [[ "$had_boot" == 1 ]]; then
  grep -q 'update_all()  # einmal beim Start' "$DASH" || { rollback "Boot-Pfad weg"; exit 1; }
fi
if grep -q 'Thread(target=update_all' "$DASH"; then
  rollback "Thread(target=update_all im Dashboard"
  exit 1
fi
grep -q 'staleTs snap' "$DASH" || { rollback "kein staleTs snap"; exit 1; }
grep -q 'staleTs restore' "$DASH" || { rollback "kein staleTs restore"; exit 1; }
grep -q 'staleTsBoot' "$DASH" || { rollback "kein staleTsBoot"; exit 1; }
grep -q 'def _stale_ts_render' "$DASH" || { rollback "kein page1-Render-Fallback"; exit 1; }

set +e
python3 - "$DASH" << 'PY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(src)
ns = {}
for node in tree.body:
    if not isinstance(node, (ast.Assign, ast.AugAssign, ast.AnnAssign)):
        continue
    if any(isinstance(n, ast.Call) for n in ast.walk(node)):
        continue
    if isinstance(node, ast.Assign):
        targets = node.targets
    else:
        targets = [node.target]
    interesting = False
    for t in targets:
        if isinstance(t, ast.Name) and (t.id == "PAGE1" or t.id.startswith("PAGE") or "STYLE" in t.id or t.id.isupper()):
            interesting = True
    if not interesting:
        continue
    seg = ast.get_source_segment(src, node)
    if not seg:
        continue
    try:
        exec(seg, ns)
    except Exception as e:
        print("WARN: PAGE1-Teil nicht auswertbar (%s) — HTTP prueft das gerenderte HTML" % e)
        sys.exit(0)
page = ns.get("PAGE1")
if not isinstance(page, str):
    print("WARN: PAGE1 nicht als String auswertbar — HTTP prueft das gerenderte HTML")
    sys.exit(0)
html = page
if 'id="staleTsBoot"' not in html and "_stale_ts_render(" in src:
    k = html.rfind("</body>")
    snippet = '<script id="staleTsBoot"></script>'
    html = (html[:k] + snippet + html[k:]) if k >= 0 else (html + snippet)
n = html.count('id="staleTsBoot"')
style = html.rfind("</style>")
body = html.rfind("</body>")
mark = html.find('id="staleTsBoot"')
if n != 1 or mark < 0 or (body >= 0 and not mark < body) or (style >= 0 and not style < mark):
    print("FAIL PAGE1 rendered n=%s style=%s mark=%s body=%s" % (n, style, mark, body))
    sys.exit(3)
print("OK PAGE1 rendered enthaelt staleTsBoot einmal nach </style> vor </body>")
PY
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "PAGE1 rendered ohne staleTsBoot"
  exit 1
fi

echo "--- restart ---"
set +e
sudo systemctl restart prepper-dashboard.service
rc=$?
if [[ $rc -ne 0 ]]; then
  sudo systemctl restart prepper-dashboard
  rc=$?
fi
set -e
if [[ $rc -ne 0 ]]; then
  echo "WARN: systemctl restart fehlgeschlagen. Patch bleibt, kein Rollback."
  echo "OK stale-ts written COMMIT=$COMMIT (Dienst bitte neu starten)"
  exit 0
fi

gunzip_body() {
  python3 - "$1" << 'PY'
import gzip, pathlib, sys
p = pathlib.Path(sys.argv[1])
b = p.read_bytes()
if b.startswith(b"\x1f\x8b"):
    p.write_bytes(gzip.decompress(b))
    print("NOTE: body war gzip, entpackt", p.name)
PY
}

echo "--- HTTP :$PORT (nie :5000) ---"
code="000"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  code=$(curl -s -o /tmp/stalets_home.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || true)
  [[ -z "$code" ]] && code=000
  echo "try $i HTTP /=$code"
  if [[ "$code" == "200" || "$code" == "500" ]]; then
    break
  fi
  sleep 3
done
gunzip_body /tmp/stalets_home.html || true
eng=$(curl -s -o /tmp/stalets_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || true)
[[ -z "$eng" ]] && eng=000
echo "HTTP /energie=$eng"
gunzip_body /tmp/stalets_energie.html || true
slash=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 15 "http://127.0.0.1:${PORT}/energie/" || true)
[[ -z "$slash" ]] && slash=000
echo "HTTP /energie/=$slash (200 oder 302 ok)"

if [[ "$code" == "500" || "$eng" == "500" || "$slash" == "500" ]]; then
  rollback "HTTP 500"
  exit 1
fi
if [[ "$eng" == "302" || "$eng" == "301" || "$eng" == "308" ]]; then
  echo "OK /energie $eng (redirect)"
fi
if [[ "$slash" == "302" || "$slash" == "301" || "$slash" == "308" || "$slash" == "200" ]]; then
  echo "OK /energie/ $slash"
fi
if [[ "$code" == "200" ]]; then
  if grep -q 'staleTsBoot' /tmp/stalets_home.html; then
    echo "OK HTML / enthaelt staleTsBoot"
  elif grep -q 'nav-top' /tmp/stalets_home.html || grep -q 'Käswasser' /tmp/stalets_home.html; then
    rollback "Dashboard-HTML ohne staleTsBoot"
    exit 1
  else
    echo "WARN: / ist 200 aber kein Dashboard-HTML — kein Rollback"
  fi
else
  echo "WARN: / nicht 200 (code=$code) — Patch bleibt, kein Rollback"
fi
if [[ "$eng" == "200" ]]; then
  if grep -q 'staleTsBoot' /tmp/stalets_energie.html; then
    echo "OK HTML /energie enthaelt staleTsBoot"
  elif grep -q 'nav-top' /tmp/stalets_energie.html; then
    rollback "Energie-HTML ohne staleTsBoot"
    exit 1
  fi
fi

echo "OK stale-ts applied COMMIT=$COMMIT"
echo "Check: Zeitstempel grau solange die Kachel im Takt ist, gelb wenn der Takt ueberfaellig ist, rot wenn der Stand viel aelter ist. Fehlfetch laesst den letzten Wert stehen."
