#!/bin/bash
set -euo pipefail
# Nav: 3 Zeilen, volle Namen (# navFull3). Smoke PORT=8080 (never :5000).
# Does NOT touch pageFein SAFE markers (Lock/NINA/lng).
COMMIT="${COMMIT:-REPLACE_ME}"
export COMMIT
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
ZUH="$DASH_DIR/zuhause.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"

echo "=== nav-full3rows apply COMMIT=$COMMIT PORT=$PORT ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi
if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 — use 8080"; exit 1
fi

curl -fsSL "$BASE/patch-nav-full3rows.py" -o /tmp/patch-nav-full3rows.py
curl -fsSL "$BASE/patch-nav-full3rows.zb64" -o /tmp/patch-nav-full3rows.zb64
curl -fsSL "$BASE/patch-nav-full3rows-zuhause.py" -o /tmp/patch-nav-full3rows-zuhause.py

grep -q 'navFull3' /tmp/patch-nav-full3rows.py || { echo "FAIL: kein navFull3 im Stub"; exit 1; }
python3 -c 'import base64,zlib,pathlib; b=zlib.decompress(base64.b64decode(pathlib.Path("/tmp/patch-nav-full3rows.zb64").read_text().strip())); assert b"navFull3" in b and b"nav-full3-row" in b; print("zb64 ok", len(b))'
wc -c /tmp/patch-nav-full3rows.py /tmp/patch-nav-full3rows.zb64 /tmp/patch-nav-full3rows-zuhause.py

cp -a "$DASH" "$DASH.bak-navfull3-$TS" 2>/dev/null || true
python3 /tmp/patch-nav-full3rows.py "$DASH"
python3 /tmp/patch-nav-full3rows.py "$DASH"
python3 -m py_compile "$DASH"

# pageFein SAFE markers must remain if present
if grep -q 'pageFein' "$DASH"; then
  grep -q 'dataStoreLock' "$DASH" || { echo "FAIL: pageFein present but dataStoreLock missing"; exit 1; }
  grep -q 'ninaDualGuard' "$DASH" || { echo "FAIL: pageFein present but ninaDualGuard missing"; exit 1; }
  if grep -q 'Thread(target=update_all' "$DASH"; then echo "FAIL: StartBg thread after nav"; exit 1; fi
  echo "OK pageFein SAFE markers intact"
fi

if [[ -f "$ZUH" ]]; then
  cp -a "$ZUH" "$ZUH.bak-navfull3-$TS" 2>/dev/null || true
  python3 /tmp/patch-nav-full3rows-zuhause.py "$ZUH"
  python3 /tmp/patch-nav-full3rows-zuhause.py "$ZUH"
  python3 -m py_compile "$ZUH"
else
  echo "WARN: keine zuhause.py"
fi

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 3
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'navFull3\|nav-full3-row' "$DASH" | head -25

echo "--- HTTP sample PORT=$PORT (never :5000) ---"
fail=0
for path in / /energie /lokale-energie /adsb /medizin /news /pegel /zuhause; do
  code=$(curl -s -o "/tmp/navfull3${path////_}.html" -w "%{http_code}" --connect-timeout 3 --max-time 15 "http://127.0.0.1:${PORT}${path}" || echo 000)
  rows=$(grep -c 'nav-full3-row' "/tmp/navfull3${path////_}.html" 2>/dev/null || echo 0)
  abbr=$(grep -cE '>(Lok|Med|Umw|Spei|Energ|Sys)\.<' "/tmp/navfull3${path////_}.html" 2>/dev/null || echo 0)
  echo "HTTP $path=$code full3rows~$rows abbr~$abbr"
  if [[ "$code" != "200" ]]; then fail=1; fi
  if [[ "$abbr" != "0" ]]; then echo "FAIL: abbreviated labels on $path"; fail=1; fi
done

export DASH
python3 - <<'SANITY'
from pathlib import Path
import os
src = Path(os.environ["DASH"]).read_text()
assert "navFull3" in src and "nav-full3-row" in src
assert src.count("nav-full3-row") >= 3
print("OK navFull3 sanity")
SANITY

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: smoke/abbr check on :$PORT"
  exit 1
fi
echo "OK nav-full3rows applied COMMIT=$COMMIT PORT=$PORT"
echo "Check: 3 Nav-Zeilen, volle Namen (Lokale Energie/Medizin/System), kein Ellipsis-Kuerzel."
