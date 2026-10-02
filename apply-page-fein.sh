#!/bin/bash
set -euo pipefail
# pageStability Feinschliff (idempotent). # pageFein
COMMIT="${COMMIT:-REPLACE_ME}"
export COMMIT
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== page-fein apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi

curl -fsSL "$BASE/patch-page-fein.py" -o /tmp/patch-page-fein.py
curl -fsSL "$BASE/patch-page-fein.zb64.p0" -o /tmp/patch-page-fein.zb64.p0
curl -fsSL "$BASE/patch-page-fein.zb64.p1" -o /tmp/patch-page-fein.zb64.p1

grep -q 'pageFein' /tmp/patch-page-fein.py || { echo "FAIL: kein pageFein im Stub"; exit 1; }
python3 - <<'PY'
import base64, zlib, pathlib
p0 = pathlib.Path("/tmp/patch-page-fein.zb64.p0").read_text().strip()
p1 = pathlib.Path("/tmp/patch-page-fein.zb64.p1").read_text().strip()
raw = zlib.decompress(base64.b64decode(p0 + p1))
assert b"pageFein" in raw and b"dataStoreLock" in raw and b"ninaDualGuard" in raw
print("zb64 parts ok", len(raw))
PY
grep -q 'PLACEHOLDER' /tmp/patch-page-fein.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-page-fein.py /tmp/patch-page-fein.zb64.p0 /tmp/patch-page-fein.zb64.p1

cp -a "$DASH" "$DASH.bak-pagefein-$TS" 2>/dev/null || true

python3 /tmp/patch-page-fein.py "$DASH"
python3 /tmp/patch-page-fein.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 3
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'pageFein\|dataStoreLock\|atomicSwap\|lngDedup\|lokaleDoctypeNav\|ninaDualGuard\|pageFeinThreaded\|pageFeinStartBg' "$DASH" | head -40

echo "--- HTTP sample ---"
for path in / /energie /lokale-energie /speicher /umwelt /pegel /adsb /news; do
  code=$(curl -s -o "/tmp/pagefein${path////_}.html" -w "%{http_code}" "http://127.0.0.1:5000$path" || echo 0)
  echo "HTTP $path=$code"
done

# sanity: no duplicate lng key left in update_all body
python3 - <<'PY'
from pathlib import Path
src = Path("/home/fmg/prepper-dashboard/dashboard.py").read_text()
n = src.count('"lng": {"value": fetch_lng()')
print("lng keys:", n)
assert n <= 1, "duplicate lng still present"
assert "dataStoreLock" in src and "ninaDualGuard" in src
# lokale if present must be DOCTYPE-first
if "PAGE_LOKALE_ENERGIE" in src:
    i = src.find("PAGE_LOKALE_ENERGIE")
    chunk = src[i:i+900]
    if "<nav" in chunk and "<!DOCTYPE" in chunk:
        assert chunk.find("<!DOCTYPE") < chunk.find("<nav"), "PAGE_LOKALE nav still before DOCTYPE"
print("OK pageFein sanity")
PY

echo "OK page-fein applied COMMIT=$COMMIT"
echo "Check: Race/Lock, threaded HTTP, lng dedup, Lokale DOCTYPE, NINA kein Doppel-TX."
