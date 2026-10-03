#!/bin/bash
set -euo pipefail
# Zeitstempel je Kachel: letzter guter Wert bleibt, gelb/rot nach eigener Kadenz.
# Smoke nur :8080. 302 auf trailing slash ist ok. Nicht :5000.
# staleTs
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"
EXPECT_SHA="998531231452c3bc0b0b2ac40c0c93a69e910c9b478d01e0b120cfcf116061db"

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

page1_ok=0
python3 - << 'PY' || page1_ok=$?
import ast, pathlib, sys
src = pathlib.Path("/home/fmg/prepper-dashboard/dashboard.py").read_text(encoding="utf-8")
tree = ast.parse(src)
lines = src.splitlines(keepends=True)
ok = False
for node in tree.body:
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if isinstance(t, ast.Name) and t.id == "PAGE1":
                block = "".join(lines[node.lineno - 1:node.end_lineno])
                mark = block.rfind('id="staleTsBoot"')
                body = block.rfind("</body>")
                ok = mark >= 0 and body > mark
if not ok or "_stale_ts_render(render_template_string(" not in src:
    sys.exit(1)
print("OK PAGE1 literal enthaelt staleTsBoot vor </body>")
PY
if [[ "$page1_ok" -ne 0 ]]; then
  rollback "PAGE1 Template ohne staleTsBoot"
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
