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

if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 - smoke only :8080"
  exit 1
fi

echo "=== stale-ts apply COMMIT=$COMMIT PORT=$PORT ==="
curl -fsSL "$BASE/patch-stale-ts.py" -o /tmp/patch-stale-ts.py
grep -q 'staleTsBoot' /tmp/patch-stale-ts.py || { echo "FAIL: patch ohne staleTsBoot"; exit 1; }
if grep -q 'Thread(target=update_all' /tmp/patch-stale-ts.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
# Echte Store-Ersetzung. data_store[\"key\"] = und Kommentare zaehlen nicht.
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

python3 /tmp/patch-stale-ts.py "$DASH"
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

echo "--- Marker ---"
grep -n 'staleTs snap\|staleTs restore\|staleTsBoot\|staleTs pegelPage\|staleTs freqApi' "$DASH" | head -20

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
code="000"
for i in 1 2 3 4 5 6 7 8 9 10; do
  code=$(curl -s -o /tmp/stalets_home.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || echo 000)
  echo "try $i HTTP /=$code"
  if [[ "$code" == "200" || "$code" == "500" ]]; then
    break
  fi
  sleep 3
done
eng=$(curl -s -o /tmp/stalets_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || echo 000)
echo "HTTP /energie=$eng"
slash=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 15 "http://127.0.0.1:${PORT}/energie/" || echo 000)
echo "HTTP /energie/=$slash (200 oder 302 ok)"

if [[ "$code" == "500" || "$eng" == "500" || "$slash" == "500" ]]; then
  rollback "HTTP 500"
  exit 1
fi
if [[ "$code" == "200" ]]; then
  grep -q 'staleTsBoot' /tmp/stalets_home.html || { rollback "kein staleTsBoot im HTML"; exit 1; }
  echo "OK HTML / enthaelt staleTsBoot"
else
  echo "WARN: / nicht 200 (code=$code) - Patch ist drauf, Dienst pruefen"
fi
if [[ "$eng" == "200" ]]; then
  grep -q 'staleTsBoot' /tmp/stalets_energie.html || { rollback "Energie ohne staleTsBoot"; exit 1; }
fi

echo "OK stale-ts applied COMMIT=$COMMIT"
echo "Check: Zeitstempel grau solange die Kachel im Takt ist, gelb wenn der Takt ueberfaellig ist, rot wenn der Stand viel aelter ist. Fehlfetch laesst den letzten Wert stehen."
