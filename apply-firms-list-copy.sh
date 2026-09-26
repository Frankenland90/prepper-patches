#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== firms-list-copy apply COMMIT=$COMMIT ==="
curl -fsSL "$BASE/patch-firms-list-copy.py" -o /tmp/patch-firms-list-copy.py
grep -q 'firmsListCopy' /tmp/patch-firms-list-copy.py || { echo FAIL; exit 1; }
wc -c /tmp/patch-firms-list-copy.py
cp -a "$DASH" "$DASH.bak-firmscopy-$TS"
cp -a "$DASH_DIR/luft.py" "$DASH_DIR/luft.py.bak-firmscopy-$TS" 2>/dev/null || true
python3 /tmp/patch-firms-list-copy.py "$DASH"
python3 -m py_compile "$DASH" "$DASH_DIR/luft.py"
sudo systemctl restart prepper-dashboard.service 2>/dev/null || sudo systemctl restart prepper-dashboard || true
sleep 2
systemctl is-active prepper-dashboard.service 2>/dev/null || systemctl is-active prepper-dashboard || true
grep -n 'firmsListCopy\|firms-line\|tippen = kopieren\|"gps"' "$DASH" "$DASH_DIR/luft.py" | head -20
echo "OK firms-list-copy applied COMMIT=$COMMIT"
