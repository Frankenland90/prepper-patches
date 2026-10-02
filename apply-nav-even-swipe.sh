#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
ZUH="$DASH_DIR/zuhause.py"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== nav-even-swipe apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/patch-nav-even-swipe.py" -o /tmp/patch-nav-even-swipe.py
curl -fsSL "$BASE/patch-nav-even-swipe-zuhause.py" -o /tmp/patch-nav-even-swipe-zuhause.py

grep -q 'navEvenSwipe' /tmp/patch-nav-even-swipe.py || { echo "FAIL: kein navEvenSwipe im Patch"; exit 1; }
grep -q 'touchstart' /tmp/patch-nav-even-swipe.py || { echo "FAIL: kein touchstart"; exit 1; }
grep -q 'nav-even-row' /tmp/patch-nav-even-swipe.py || { echo "FAIL: kein nav-even-row"; exit 1; }
grep -q 'PLACEHOLDER' /tmp/patch-nav-even-swipe.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-nav-even-swipe.py /tmp/patch-nav-even-swipe-zuhause.py

cp -a "$DASH" "$DASH.bak-navswipe-$TS" 2>/dev/null || true
python3 /tmp/patch-nav-even-swipe.py "$DASH"
# idempotent second run
python3 /tmp/patch-nav-even-swipe.py "$DASH"
python3 -m py_compile "$DASH"

if [[ -f "$ZUH" ]]; then
  cp -a "$ZUH" "$ZUH.bak-navswipe-$TS" 2>/dev/null || true
  python3 /tmp/patch-nav-even-swipe-zuhause.py "$ZUH"
  python3 /tmp/patch-nav-even-swipe-zuhause.py "$ZUH"
  python3 -m py_compile "$ZUH"
else
  echo "WARN: keine zuhause.py — nur dashboard.py"
fi

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 2
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'navEvenSwipe\|nav-even-row\|__navEvenSwipe\|flex:1 1 0' "$DASH" | head -25
echo "--- HTTP sample ---"
for path in / /energie /adsb /medizin /news /pegel; do
  code=$(curl -s -o "/tmp/navswipe${path////_}.html" -w "%{http_code}" "http://127.0.0.1:5000$path" || echo 0)
  hits=$(grep -c 'navEvenSwipe\|nav-even-row\|flex:1 1 0' "/tmp/navswipe${path////_}.html" 2>/dev/null || echo 0)
  echo "HTTP $path=$code markers~$hits"
done
# zuhause optional
code=$(curl -s -o /tmp/navswipe_zuhause.html -w "%{http_code}" http://127.0.0.1:5000/zuhause || echo 0)
if [[ "$code" == "200" ]]; then
  grep -c 'navEvenSwipe' /tmp/navswipe_zuhause.html || true
  echo "HTTP /zuhause=$code"
fi
echo "OK nav-even-swipe applied COMMIT=$COMMIT"
echo "Check: Nav-Tabs gleich breit; auf Handy Wischen links/rechts wechselt Seite."
