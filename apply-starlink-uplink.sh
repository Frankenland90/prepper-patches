#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== starlink-uplink apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/patch-starlink-uplink.py" -o /tmp/patch-starlink-uplink.py
grep -q 'starlinkUplink' /tmp/patch-starlink-uplink.py || {
  echo "FAIL: patch ohne Marker starlinkUplink"; head -8 /tmp/patch-starlink-uplink.py; exit 1
}
grep -q 'classify_uplink' /tmp/patch-starlink-uplink.py || {
  echo "FAIL: patch ohne classify_uplink"; exit 1
}
wc -c /tmp/patch-starlink-uplink.py

cp -a "$DASH" "$DASH.bak-starlink-$TS"
python3 /tmp/patch-starlink-uplink.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 3
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'starlinkUplink\|classify_uplink\|Ausfallschutz' "$DASH" | head -20
echo "OK starlink-uplink applied COMMIT=$COMMIT"
echo "Erwartung System-Kachel: Festnetz · … (ASN/ISP); Download-Zeile nach Messung mit Wert+Zeit."
