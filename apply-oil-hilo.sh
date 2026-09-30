#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

curl -fsSL "$BASE/patch-oil-hilo.py" -o /tmp/patch-oil-hilo.py
if ! grep -q 'oilHiLo' /tmp/patch-oil-hilo.py; then
  echo "FAIL: patch-oil-hilo.py ohne Marker oilHiLo (COMMIT=$COMMIT)"
  head -8 /tmp/patch-oil-hilo.py
  exit 1
fi
wc -c /tmp/patch-oil-hilo.py

cp -a "$DASH" "$DASH.bak-oilhilo-$TS" 2>/dev/null || true
python3 /tmp/patch-oil-hilo.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 1
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'oilHiLo\|oilHiText\|oilLoText' "$DASH" | head -15
echo "OK oil-hilo applied COMMIT=$COMMIT"
echo "Check: Energie → Rohöl → unter Chart ↑ rot Höchst + ↓ grün Tiefst (Datum Zeit Preis)."
