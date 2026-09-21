#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-ee9d02ca171e580ab5aedfe72ceb649df6cf8890}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-mil-dist-font.py" -o /tmp/patch-adsb-mil-dist-font.py
python3 /tmp/patch-adsb-mil-dist-font.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 1
systemctl is-active prepper-dashboard || true
grep -n "milDistFont\|0\.7rem.*milDist\|0\.62rem" "$DASH" | head -8
echo "OK milDistFont applied"
