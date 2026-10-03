#!/bin/bash
set -euo pipefail
# Energie: Day-Ahead-Kachel weg, Strompreis aktuell = 14-Tage-Chart wie Diesel.
# Smoke nur :8080. 302 auf trailing slash ist ok. Nicht :5000.
COMMIT="${COMMIT:-c7493440aec7a8da5a2c7fe99d7b44f7a9b326d9}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"

if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 \u2014 smoke only :8080"
  exit 1
fi

echo "=== strom-14d apply COMMIT=$COMMIT PORT=$PORT ==="
curl -fsSL "$BASE/patch-strom-14d.py" -o /tmp/patch-strom-14d.py
grep -q 'strom14dChart' /tmp/patch-strom-14d.py || { echo "FAIL: patch ohne strom14dChart"; exit 1; }
if grep -q 'Thread(target=update_all' /tmp/patch-strom-14d.py; then
  echo "FAIL: patch enthaelt StartBg update_all"
  exit 1
fi
if grep -q 'data_store =' /tmp/patch-strom-14d.py; then
  echo "FAIL: patch schreibt data_store"
  exit 1
fi
wc -c /tmp/patch-strom-14d.py

cp -a "$DASH" "$DASH.bak-strom14d-$TS"

had_fein=0; grep -q 'pageFein' "$DASH" && had_fein=1 || true
had_lock=0; grep -q 'dataStoreLock' "$DASH" && had_lock=1 || true
had_nina=0; grep -q 'ninaDualGuard' "$DASH" && had_nina=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-strom14d-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

python3 /tmp/patch-strom-14d.py "$DASH"
cp -a "$DASH" /tmp/dashboard.py.strom14d-once
python3 /tmp/patch-strom-14d.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.strom14d-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
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
if grep -q 'Thread(target=update_all' "$DASH"; then
  echo "WARN: Thread(target=update_all ist noch in dashboard.py (nicht von diesem Patch neu, aber Boot riskant)"
fi

echo "--- Marker ---"
grep -n 'strom14dChart\|stromHiLo\|DE-LU' "$DASH" | head -20
if grep -q 'Strompreis Day-Ahead' "$DASH"; then
  rollback "Day-Ahead noch im File"
  exit 1
fi

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
code="000"
for i in 1 2 3 4 5 6 7 8 9 10; do
  code=$(curl -s -o /tmp/strom14d_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || echo 000)
  echo "try $i HTTP /energie=$code"
  if [[ "$code" == "200" || "$code" == "500" ]]; then
    break
  fi
  sleep 3
done
home=$(curl -s -o /tmp/strom14d_home.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || echo 000)
echo "HTTP /=$home"
slash=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 15 "http://127.0.0.1:${PORT}/energie/" || echo 000)
echo "HTTP /energie/=$slash (200 oder 302 ok)"

if [[ "$code" == "500" || "$home" == "500" || "$slash" == "500" ]]; then
  rollback "HTTP 500"
  exit 1
fi
if [[ "$code" == "200" ]]; then
  if grep -q 'Strompreis Day-Ahead' /tmp/strom14d_energie.html; then
    rollback "Day-Ahead noch im HTML"
    exit 1
  fi
  grep -q 'stromHiLo' /tmp/strom14d_energie.html || { rollback "kein stromHiLo im HTML"; exit 1; }
  grep -q 'stromLineChart' /tmp/strom14d_energie.html || { rollback "kein stromLineChart"; exit 1; }
  grep -q 'DE-LU' /tmp/strom14d_energie.html || { rollback "kein DE-LU Untertitel"; exit 1; }
  echo "OK HTML: keine Day-Ahead-Kachel, stromHiLo + 14-Tage-Chart"
else
  echo "WARN: /energie nicht 200 (code=$code) \u2014 Patch ist drauf, Dienst pruefen"
fi

echo "OK strom-14d applied COMMIT=$COMMIT"
echo "Check: Energie -> Strompreis aktuell volle Breite, 14-Tage-Flaeche, rot hoch / gruen runter, kein Day-Ahead."
