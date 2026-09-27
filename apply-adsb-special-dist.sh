#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-special-dist.py" -o /tmp/patch-adsb-special-dist.py
grep -q 'adsbSpecialDist' /tmp/patch-adsb-special-dist.py
wc -c /tmp/patch-adsb-special-dist.py
python3 /tmp/patch-adsb-special-dist.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 8
systemctl is-active prepper-dashboard || true
grep -n "adsbSpecialDist\|dist_col\|dist_km\|_adsb_home_dist" "$DASH" | head -25
echo "OK adsbSpecialDist applied"
