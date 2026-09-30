#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

curl -fsSL "$BASE/patch-diesel-hilo.py" -o /tmp/patch-diesel-hilo.py
if ! grep -q 'dieselHiLo' /tmp/patch-diesel-hilo.py; then
  echo "FAIL: patch-diesel-hilo.py ohne Marker dieselHiLo (COMMIT=$COMMIT)"
  head -8 /tmp/patch-diesel-hilo.py
  exit 1
fi
wc -c /tmp/patch-diesel-hilo.py

cp -a "$DASH" "$DASH.bak-dieselhilo-$TS" 2>/dev/null || true
python3 /tmp/patch-diesel-hilo.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 1
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'dieselHiLo\|dieselHiText\|dieselLoText' "$DASH" | head -15
echo "OK diesel-hilo applied COMMIT=$COMMIT"
echo "Check: Energie → Diesel regional → unter Chart ↑ rot Höchst + ↓ grün Tiefst (Datum Zeit Preis)."
