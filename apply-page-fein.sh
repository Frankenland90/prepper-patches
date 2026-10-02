#!/bin/bash
set -euo pipefail
# pageFein Feinschliff (idempotent). Restores bak-pagefein if present, then apply/repair.
COMMIT="${COMMIT:-REPLACE_ME}"
export COMMIT
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
RESTORE_BAK="${RESTORE_BAK:-1}"

echo "=== page-fein apply COMMIT=$COMMIT RESTORE_BAK=$RESTORE_BAK ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi

# Fast recover: put pre-pageFein dashboard back, then re-apply fixed patch
if [[ "$RESTORE_BAK" == "1" ]]; then
  BAK=""
  if [[ -f "$DASH_DIR/dashboard.py.bak-pagefein-20261002-211022" ]]; then
    BAK="$DASH_DIR/dashboard.py.bak-pagefein-20261002-211022"
  else
    BAK=$(ls -1t "$DASH_DIR"/dashboard.py.bak-pagefein-* 2>/dev/null | head -1 || true)
  fi
  if [[ -n "${BAK:-}" && -f "$BAK" ]]; then
    cp -a "$BAK" "$DASH"
    echo "Restored from $BAK"
  else
    echo "WARN: no bak-pagefein found — will REPAIR live if broken markers present"
  fi
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
assert b"Referenz-Tausch" in raw and b"blockierend bis Store" in raw
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
# First update_all is blocking again — give it time to fill store before HTTP sample
sleep 8
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'pageFein\|dataStoreLock\|atomicSwap\|lngDedup\|lokaleDoctypeNav\|ninaDualGuard\|pageFeinThreaded\|pageFeinStartBg\|Referenz-Tausch\|blockierend' "$DASH" | head -40

echo "--- no clear / no StartBg-thread ---"
if grep -n 'data_store.clear()' "$DASH" | grep -q .; then
  if grep -A2 'pageFein atomicSwap' "$DASH" | grep -q 'data_store.clear'; then
    echo "FAIL: atomicSwap still clears"; exit 1
  fi
fi
if grep -q 'Thread(target=update_all' "$DASH"; then
  echo "FAIL: StartBg still threads update_all"; exit 1
fi
echo "OK swap/startbg"

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
assert "Thread(target=update_all" not in src
if "pageFein atomicSwap" in src:
    assert "data_store = _new" in src
    assert "data_store.clear()" not in src or "pageFein atomicSwap" not in src.split("data_store.clear()")[0][-80:]
if "PAGE_LOKALE_ENERGIE" in src:
    i = src.find("PAGE_LOKALE_ENERGIE")
    chunk = src[i:i+900]
    if "<nav" in chunk and "<!DOCTYPE" in chunk:
        assert chunk.find("<!DOCTYPE") < chunk.find("<nav"), "PAGE_LOKALE nav still before DOCTYPE"
print("OK pageFein sanity")
PY

echo "OK page-fein applied COMMIT=$COMMIT"
echo "Check: Lock+Referenz-Tausch, blocking Start-Update, lng dedup, Lokale DOCTYPE, NINA kein Doppel-TX."
