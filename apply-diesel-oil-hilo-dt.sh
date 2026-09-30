#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/patch-diesel-oil-hilo-dt.py" -o /tmp/patch-diesel-oil-hilo-dt.py
if ! grep -q 'dieselOilHiLoDt' /tmp/patch-diesel-oil-hilo-dt.py; then
  echo "FAIL: patch-diesel-oil-hilo-dt.py ohne Marker dieselOilHiLoDt (COMMIT=$COMMIT)"
  head -8 /tmp/patch-diesel-oil-hilo-dt.py
  exit 1
fi
wc -c /tmp/patch-diesel-oil-hilo-dt.py

cp -a "$DASH" "$DASH.bak-hilo-dt-$TS" 2>/dev/null || true
python3 /tmp/patch-diesel-oil-hilo-dt.py "$DASH"
# idempotent re-run
python3 /tmp/patch-diesel-oil-hilo-dt.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 1
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'dieselOilHiLoDt\|_fmtHiLoDt\|oilHiText\|dieselHiText' "$DASH" | head -20
echo "OK diesel-oil-hilo-dt applied COMMIT=$COMMIT"
echo "Check: Energie → Rohöl + Diesel → ↑/↓ jeweils DD.MM HH:MM · Preis."
