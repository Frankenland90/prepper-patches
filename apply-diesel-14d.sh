#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-e4f5a1cb883475c86cd46a74ba26176f87014325}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

curl -fsSL "$BASE/patch-diesel-14d.py" -o /tmp/patch-diesel-14d.py
if ! grep -q 'maxlen=1344' /tmp/patch-diesel-14d.py; then
  echo "FAIL: patch-diesel-14d.py ohne maxlen=1344 (COMMIT=$COMMIT)"
  head -8 /tmp/patch-diesel-14d.py
  exit 1
fi
wc -c /tmp/patch-diesel-14d.py

cp -a "$DASH" "$DASH.bak-diesel14d-$TS" 2>/dev/null || true
python3 /tmp/patch-diesel-14d.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 1
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'maxlen=1344\|ELO Uttenreuth · 14 Tage\|%d\.%m %H:%M' "$DASH" | head -15
echo "OK diesel-14d applied COMMIT=$COMMIT"
