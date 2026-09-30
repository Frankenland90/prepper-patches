#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-159592e720cb9f263810a0f7f00b6603879b67e1}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/patch-adsb-mil-dist-fix.py" -o /tmp/patch-adsb-mil-dist-fix.py
if ! grep -q 'milDistFix' /tmp/patch-adsb-mil-dist-fix.py; then
  echo "FAIL: patch-adsb-mil-dist-fix.py ohne Marker milDistFix (COMMIT=$COMMIT)"
  head -8 /tmp/patch-adsb-mil-dist-fix.py
  exit 1
fi
# zb64 sibling for stub loader (also try curl)
curl -fsSL "$BASE/patch-adsb-mil-dist-fix.zb64" -o /tmp/patch-adsb-mil-dist-fix.zb64
cp -a /tmp/patch-adsb-mil-dist-fix.zb64 /tmp/ 2>/dev/null || true
# stub resolves sibling next to __file__; keep both in /tmp
wc -c /tmp/patch-adsb-mil-dist-fix.py /tmp/patch-adsb-mil-dist-fix.zb64

cp -a "$DASH" "$DASH.bak-mil-dist-fix-$TS" 2>/dev/null || true
export COMMIT
python3 /tmp/patch-adsb-mil-dist-fix.py "$DASH"
python3 /tmp/patch-adsb-mil-dist-fix.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 1
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'milDistFix\|_adsb_home_dist\|Dist</th>\|dist_km\|m.dist_km is number\|sorted(mil_list' "$DASH" | head -25
if ! grep -q '"dist_km": _dkm' "$DASH"; then
  echo "FAIL: mil_list fehlt dist_km"
  exit 1
fi
if ! grep -q 'Dist</th>' "$DASH"; then
  echo "FAIL: Dist-Spalte fehlt"
  exit 1
fi
if ! grep -q 'm.dist_km is number' "$DASH"; then
  echo "FAIL: Dist-Zelle nicht auf is number"
  exit 1
fi
echo "OK milDistFix applied COMMIT=$COMMIT"
echo "Check: ADSB → Militär → Dist z.B. „123 km“ mit Zahl (Kalchreuth)."
