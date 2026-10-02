#!/bin/bash
set -euo pipefail
# pageStability Feinschliff (idempotent). # pageFein
COMMIT="${COMMIT:-1cb16539f8e2b654faffaab148166a565b50c8a6}"
export COMMIT
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
NCHUNKS=29

echo "=== page-fein apply COMMIT=$COMMIT NCHUNKS=$NCHUNKS ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi

rm -f /tmp/patch-page-fein.real.c*.b64 /tmp/patch-page-fein.real.py
for i in $(seq -w 0 $((NCHUNKS-1))); do
  curl -fsSL "$BASE/patch-page-fein.real.c${i}.b64" -o "/tmp/patch-page-fein.real.c${i}.b64"
done
python3 - <<'PY'
import base64, pathlib
n = 29
out = b""
for i in range(n):
    out += base64.b64decode(pathlib.Path("/tmp/patch-page-fein.real.c%02d.b64" % i).read_text().strip())
assert b"pageFein" in out and b"dataStoreLock" in out and b"ninaDualGuard" in out
pathlib.Path("/tmp/patch-page-fein.real.py").write_bytes(out)
print("decoded", len(out))
PY
grep -q 'PLACEHOLDER' /tmp/patch-page-fein.real.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-page-fein.real.py

cp -a "$DASH" "$DASH.bak-pagefein-$TS" 2>/dev/null || true

python3 /tmp/patch-page-fein.real.py "$DASH"
python3 /tmp/patch-page-fein.real.py "$DASH"
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

python3 - <<'PY'
from pathlib import Path
src = Path("/home/fmg/prepper-dashboard/dashboard.py").read_text()
n = src.count('"lng": {"value": fetch_lng()')
print("lng keys:", n)
assert n <= 1, "duplicate lng still present"
assert "dataStoreLock" in src and "ninaDualGuard" in src
if "PAGE_LOKALE_ENERGIE" in src:
    i = src.find("PAGE_LOKALE_ENERGIE")
    chunk = src[i:i+900]
    if "<nav" in chunk and "<!DOCTYPE" in chunk:
        assert chunk.find("<!DOCTYPE") < chunk.find("<nav"), "PAGE_LOKALE nav still before DOCTYPE"
print("OK pageFein sanity")
PY

echo "OK page-fein applied COMMIT=$COMMIT"
echo "Check: Race/Lock, threaded HTTP, lng dedup, Lokale DOCTYPE, NINA kein Doppel-TX."
