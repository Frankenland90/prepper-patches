#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-special-squawk.py" -o /tmp/patch-adsb-special-squawk.py
grep -q 'adsbSpecialSq' /tmp/patch-adsb-special-squawk.py
wc -c /tmp/patch-adsb-special-squawk.py
python3 /tmp/patch-adsb-special-squawk.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 8
systemctl is-active prepper-dashboard || true
grep -n "adsbSpecialSq\|Sonder-Squawks\|ADSB_SPECIAL_SQUAWKS" "$DASH" | head -20
echo "OK adsbSpecialSq applied"
