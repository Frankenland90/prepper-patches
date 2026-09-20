#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-mil-flag.py" -o /tmp/patch-adsb-mil-flag.py
python3 /tmp/patch-adsb-mil-flag.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 1
systemctl is-active prepper-dashboard || true
grep -n "milFlag\|Land</th>" "$DASH" | head -8
echo "OK milFlag applied"
