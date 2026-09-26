#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== firms-list-chart apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/patch-firms-list-chart.py" -o /tmp/patch-firms-list-chart.py
grep -q 'firmsList14' /tmp/patch-firms-list-chart.py || {
  echo "FAIL: patch ohne Marker firmsList14"; head -8 /tmp/patch-firms-list-chart.py; exit 1
}
wc -c /tmp/patch-firms-list-chart.py

cp -a "$DASH" "$DASH.bak-firms14-$TS"
cp -a "$DASH_DIR/luft.py" "$DASH_DIR/luft.py.bak-firms14-$TS" 2>/dev/null || true
python3 /tmp/patch-firms-list-chart.py "$DASH"
python3 -m py_compile "$DASH" "$DASH_DIR/luft.py"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 3
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'firmsList14\|firmsChart\|acq_fmt\|firms_history' "$DASH" "$DASH_DIR/luft.py" | head -25
echo "OK firms-list-chart applied COMMIT=$COMMIT"
echo "Erwartung /luft: Hotspot-Liste mit GPS+Zeit, Chart Hotspots · 14 Tage (füllt sich über Updates)."
