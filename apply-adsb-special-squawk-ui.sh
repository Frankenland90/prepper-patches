#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-special-squawk-ui.py" -o /tmp/patch-adsb-special-squawk-ui.py
grep -q 'adsbSpecialSqUi' /tmp/patch-adsb-special-squawk-ui.py
wc -c /tmp/patch-adsb-special-squawk-ui.py
python3 /tmp/patch-adsb-special-squawk-ui.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 8
systemctl is-active prepper-dashboard || true
grep -n "adsbSpecialSqUi\|AKTIV\|SOFORT PRÜFEN\|RETTUNG\|BPOL" "$DASH" | head -20
echo "OK adsbSpecialSqUi applied"
