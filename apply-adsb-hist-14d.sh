#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-0b2776977fcd08e5ce556eaf4a62c377a4b2c5dd}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-hist-14d.py" -o /tmp/patch-adsb-hist-14d.py
if ! grep -q 'def one(' /tmp/patch-adsb-hist-14d.py; then
  echo "FAIL: alte patch-adsb-hist-14d.py geladen (kein def one). COMMIT=$COMMIT"
  head -8 /tmp/patch-adsb-hist-14d.py
  exit 1
fi
wc -c /tmp/patch-adsb-hist-14d.py
python3 /tmp/patch-adsb-hist-14d.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 1
systemctl is-active prepper-dashboard || true
grep -n "adsbHist14\|14 \* 24\|hist\[-2200\|Verlauf 14 Tage" "$DASH" | head -10
echo "OK adsbHist14 applied"
