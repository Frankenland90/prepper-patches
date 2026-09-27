#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-emerg-hist.py" -o /tmp/patch-adsb-emerg-hist.py
grep -q 'adsbEmergHist' /tmp/patch-adsb-emerg-hist.py
wc -c /tmp/patch-adsb-emerg-hist.py
python3 /tmp/patch-adsb-emerg-hist.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 3
systemctl is-active prepper-dashboard || true
grep -n "adsbEmergHist\|emerg_hist\|Letzte Notfälle" "$DASH" | head -15
echo "OK adsbEmergHist applied"
