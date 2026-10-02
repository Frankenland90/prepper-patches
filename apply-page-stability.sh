#!/bin/bash
set -euo pipefail
# Non-Mesh page stability harden (idempotent). # pageStability
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
ZUH="$DASH_DIR/zuhause.py"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== page-stability apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi

curl -fsSL "$BASE/patch-page-stability.py" -o /tmp/patch-page-stability.py

grep -q 'pageStability' /tmp/patch-page-stability.py || { echo "FAIL: kein pageStability im Patch"; exit 1; }
grep -q 'stratumTsGuard' /tmp/patch-page-stability.py || { echo "FAIL: kein stratumTsGuard"; exit 1; }
grep -q 'histTojsonGuard' /tmp/patch-page-stability.py || { echo "FAIL: kein histTojsonGuard"; exit 1; }
grep -q 'PLACEHOLDER' /tmp/patch-page-stability.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-page-stability.py

cp -a "$DASH" "$DASH.bak-pagestab-$TS" 2>/dev/null || true
[[ -f "$ZUH" ]] && cp -a "$ZUH" "$ZUH.bak-pagestab-$TS" 2>/dev/null || true

python3 /tmp/patch-page-stability.py "$DASH" "$ZUH"
# idempotent second pass
python3 /tmp/patch-page-stability.py "$DASH" "$ZUH"
python3 -m py_compile "$DASH"
[[ -f "$ZUH" ]] && python3 -m py_compile "$ZUH" || true

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 3
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'pageStability\|stratumTsGuard\|histTojsonGuard\|rtlTailCap\|adsbPageGuard\|pegelPageGuard\|pageRenderDefaults\|zuhPhoneGuard' "$DASH" | head -30
[[ -f "$ZUH" ]] && grep -n 'zuhPhoneGuard\|pageStability' "$ZUH" | head -10 || true

echo "--- HTTP sample ---"
for path in / /energie /lokale-energie /speicher /umwelt /luft /pegel /adsb /zuhause /news /pi /medizin; do
  code=$(curl -s -o "/tmp/pagestab${path////_}.html" -w "%{http_code}" "http://127.0.0.1:5000$path" || echo 0)
  echo "HTTP $path=$code"
done

# quick 500 sniff: stratum unguarded must be gone; default tojson present
grep -q 'stratumTsGuard' "$DASH" && echo "OK stratumTsGuard"
grep -q 'default(\[\]) | tojson' "$DASH" && echo "OK hist defaults"
grep -q 'stratum.value.timestamp \* 1000 }};' "$DASH" && echo "WARN: unguarded timestamp still present" || echo "OK no unguarded timestamp"

echo "OK page-stability applied COMMIT=$COMMIT"
echo "Check: Lage/Energie/ADSB/Pegel ohne 500; Charts leer statt crash vor erstem Update."
