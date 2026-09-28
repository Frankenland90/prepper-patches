#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-mil-flags.py" -o /tmp/patch-adsb-mil-flags.py
if ! grep -q 'milFlags' /tmp/patch-adsb-mil-flags.py; then
  echo "FAIL: patch-adsb-mil-flags.py sieht falsch aus"
  head -5 /tmp/patch-adsb-mil-flags.py
  exit 1
fi
if grep -q PLACEHOLDER /tmp/patch-adsb-mil-flags.py; then
  echo "FAIL: PLACEHOLDER"
  exit 1
fi
export COMMIT
python3 /tmp/patch-adsb-mil-flags.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 1
systemctl is-active prepper-dashboard || true
grep -n "milFlags\|Land</th>\|_adsb_icao_cc\|m\.flag" "$DASH" | head -12
echo "OK milFlags applied"
