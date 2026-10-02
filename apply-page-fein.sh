#!/bin/bash
set -euo pipefail
# pageFein SAFE (idempotent). Restores bak-pagefein, applies boot-safe fein only.
# NO StartBg rewrite, NO BusyGuard, NO data_store.clear(). Curls discover PORT (Pi: 8080).
COMMIT="${COMMIT:-7ca303284d4764aa79705cbbda2eb03078f93886}"
export COMMIT
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
RESTORE_BAK="${RESTORE_BAK:-1}"

echo "=== page-fein SAFE apply COMMIT=$COMMIT RESTORE_BAK=$RESTORE_BAK ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi

# Discover PORT from config.py / dashboard.py (Frank Pi: 8080)
PORT=$(python3 - <<'PY'
from pathlib import Path
import re
for p in (Path("/home/fmg/prepper-dashboard/config.py"), Path("/home/fmg/prepper-dashboard/dashboard.py")):
    if not p.is_file():
        continue
    m = re.search(r"^PORT\s*=\s*(\d+)", p.read_text(encoding="utf-8", errors="replace"), re.M)
    if m:
        print(m.group(1))
        raise SystemExit
print("8080")
PY
)
echo "PORT=$PORT"

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
    echo "FAIL: no bak-pagefein found — refuse apply without known-good bak"
    exit 1
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
assert b"Referenz-Tausch" in raw
assert b"ABANDONED" in raw or b"Boot-safe" in raw or b"SAFE Feinschliff" in raw
assert b"updateBusyGuard" in raw  # reject-string only; must not be applied to dash
print("zb64 SAFE parts ok", len(raw))
PY
grep -q 'PLACEHOLDER' /tmp/patch-page-fein.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-page-fein.py /tmp/patch-page-fein.zb64.p0 /tmp/patch-page-fein.zb64.p1

cp -a "$DASH" "$DASH.bak-pagefein-$TS" 2>/dev/null || true

python3 /tmp/patch-page-fein.py "$DASH"
python3 /tmp/patch-page-fein.py "$DASH"
python3 -m py_compile "$DASH"

# Boot-safety markers
if grep -q 'Thread(target=update_all' "$DASH"; then
  echo "FAIL: StartBg thread present"; exit 1
fi
if grep -A3 'pageFein atomicSwap' "$DASH" | grep -q 'data_store.clear'; then
  echo "FAIL: atomicSwap clears"; exit 1
fi
if grep -q 'updateBusyGuard\|_update_all_body' "$DASH"; then
  echo "FAIL: BusyGuard present"; exit 1
fi
if ! grep -q 'update_all()  # einmal beim Start' "$DASH"; then
  echo "FAIL: bak-style StartBg missing"; exit 1
fi
echo "OK boot-safety markers"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
# bak-style start runs update_all once then binds — allow headroom
sleep 12
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'pageFein\|dataStoreLock\|atomicSwap\|lngDedup\|lokaleDoctypeNav\|ninaDualGuard\|pageFeinThreaded\|Referenz-Tausch' "$DASH" | head -40

echo "--- HTTP sample PORT=$PORT ---"
fail=0
for path in / /energie /lokale-energie /speicher /umwelt /pegel /adsb /news; do
  code=$(curl -s -o "/tmp/pagefein${path////_}.html" -w "%{http_code}" --connect-timeout 3 --max-time 15 "http://127.0.0.1:${PORT}${path}" || echo 000)
  echo "HTTP $path=$code"
  if [[ "$code" != "200" ]]; then fail=1; fi
done

python3 - <<PY
from pathlib import Path
src = Path("$DASH").read_text()
assert "dataStoreLock" in src and "ninaDualGuard" in src
assert "Thread(target=update_all" not in src
assert "updateBusyGuard" not in src and "_update_all_body" not in src
assert "update_all()  # einmal beim Start" in src
if "pageFein atomicSwap" in src:
    assert "data_store = _new" in src
print("OK pageFein SAFE sanity")
PY

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: HTTP smoke not all 200 on :$PORT — consider restore bak"
  exit 1
fi
echo "OK page-fein SAFE applied COMMIT=$COMMIT PORT=$PORT"
echo "Check: Lock+Referenz-Tausch, bak StartBg, lng dedup, Lokale DOCTYPE, NINA kein Doppel-TX."
