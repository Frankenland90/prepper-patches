#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-mil-median.py" -o /tmp/patch-adsb-mil-median.py
python3 /tmp/patch-adsb-mil-median.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 1
systemctl is-active prepper-dashboard || true
grep -n "milMedCmp\|ungewöhnlich wenig Militär\|mil_med == 0" "$DASH" | head -8
echo "OK milMedCmp applied"
