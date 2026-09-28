#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="/home/fmg/prepper-dashboard/dashboard.py"
curl -fsSL "$BASE/patch-adsb-mil-flags.py" -o /tmp/patch-adsb-mil-flags.py
if ! grep -q 'milFlagsRow' /tmp/patch-adsb-mil-flags.py; then
  echo "FAIL: patch-adsb-mil-flags.py fehlt milFlagsRow"
  head -8 /tmp/patch-adsb-mil-flags.py
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
grep -n "milFlagsRow\|milFlags\|Land</th>\|&nbsp;m\|white-space:nowrap" "$DASH" | head -20
# sanity: Höhe cell must be single-line
if ! grep -q '{{ m.alt }}&nbsp;m' "$DASH"; then
  echo "FAIL: Höhe fehlt &nbsp;m (single-line)"
  exit 1
fi
echo "OK milFlags/milFlagsRow applied"
