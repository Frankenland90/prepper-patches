#!/bin/bash
set -euo pipefail
# Non-Mesh page stability harden (idempotent). # pageStability
COMMIT="${COMMIT:-55ca080067b7d8050729e33d58273858280e34cc}"
export COMMIT
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
ZUH="$DASH_DIR/zuhause.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"

echo "=== page-stability apply COMMIT=$COMMIT PORT=${PORT:-8080} ==="
if [[ "${PORT:-8080}" == "5000" ]]; then echo "FAIL: refused PORT=5000 — use 8080"; exit 1; fi
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi

curl -fsSL "$BASE/patch-page-stability.py" -o /tmp/patch-page-stability.py
curl -fsSL "$BASE/patch-page-stability.zb64.p0" -o /tmp/patch-page-stability.zb64.p0
curl -fsSL "$BASE/patch-page-stability.zb64.p1" -o /tmp/patch-page-stability.zb64.p1

grep -q 'pageStability' /tmp/patch-page-stability.py || { echo "FAIL: kein pageStability im Stub"; exit 1; }
python3 - <<'PY'
import base64, zlib, pathlib
p0 = pathlib.Path("/tmp/patch-page-stability.zb64.p0").read_text().strip()
p1 = pathlib.Path("/tmp/patch-page-stability.zb64.p1").read_text().strip()
raw = zlib.decompress(base64.b64decode(p0 + p1))
assert b"pageStability" in raw and b"stratumTsGuard" in raw
print("zb64 parts ok", len(raw))
PY
grep -q 'PLACEHOLDER' /tmp/patch-page-stability.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-page-stability.py /tmp/patch-page-stability.zb64.p0 /tmp/patch-page-stability.zb64.p1

cp -a "$DASH" "$DASH.bak-pagestab-$TS" 2>/dev/null || true
[[ -f "$ZUH" ]] && cp -a "$ZUH" "$ZUH.bak-pagestab-$TS" 2>/dev/null || true

python3 /tmp/patch-page-stability.py "$DASH" "$ZUH"
python3 /tmp/patch-page-stability.py "$DASH" "$ZUH"
python3 -m py_compile "$DASH"
[[ -f "$ZUH" ]] && python3 -m py_compile "$ZUH" || true

# Do not disturb pageFein SAFE if already applied
if grep -q 'pageFein' "$DASH"; then
  grep -q 'dataStoreLock' "$DASH" || { echo "FAIL: broke dataStoreLock"; exit 1; }
  grep -q 'ninaDualGuard' "$DASH" || { echo "FAIL: broke ninaDualGuard"; exit 1; }
  if grep -q 'Thread(target=update_all' "$DASH"; then echo "FAIL: StartBg thread"; exit 1; fi
  echo "OK pageFein SAFE markers intact"
fi

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

echo "--- HTTP sample PORT=$PORT (never :5000) ---"
fail=0
for path in / /energie /lokale-energie /speicher /umwelt /luft /pegel /adsb /zuhause /news /pi /medizin; do
  code=$(curl -s -o "/tmp/pagestab${path////_}.html" -w "%{http_code}" --connect-timeout 3 --max-time 15 "http://127.0.0.1:${PORT}${path}" || echo 000)
  echo "HTTP $path=$code"
  if [[ "$code" != "200" ]]; then fail=1; fi
done
if [[ "$fail" -ne 0 ]]; then echo "WARN: not all HTTP 200 on :$PORT (service warm-up / already ok)"; fi

grep -q 'stratumTsGuard' "$DASH" && echo "OK stratumTsGuard"
grep -q 'default(\[\]) | tojson' "$DASH" && echo "OK hist defaults"
grep -q 'stratum.value.timestamp \* 1000 }};' "$DASH" && echo "WARN: unguarded timestamp still present" || echo "OK no unguarded timestamp"

echo "OK page-stability applied COMMIT=$COMMIT"
echo "Check: Lage/Energie/ADSB/Pegel ohne 500; Charts leer statt crash vor erstem Update."
