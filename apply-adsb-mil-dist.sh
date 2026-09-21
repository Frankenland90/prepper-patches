#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-56d3ce7821aba503fbaeca79cdad816f908dea5c}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-mil-dist.py" -o /tmp/patch-adsb-mil-dist.py
if ! grep -q 'milDist' /tmp/patch-adsb-mil-dist.py; then
  echo "FAIL: patch-adsb-mil-dist.py sieht falsch aus"
  head -5 /tmp/patch-adsb-mil-dist.py
  exit 1
fi
wc -c /tmp/patch-adsb-mil-dist.py
python3 /tmp/patch-adsb-mil-dist.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 1
systemctl is-active prepper-dashboard || true
grep -n "milDist\|_adsb_home_dist\|Dist</th>\|0\.62rem" "$DASH" | head -10
echo "OK milDist applied"
