#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)

curl -fsSL "$BASE/patch-rohoel-eia.py" -o /tmp/patch-rohoel-eia.py
grep -q 'rohoelEia' /tmp/patch-rohoel-eia.py || {
  echo "FAIL: patch-rohoel-eia.py ohne Marker rohoelEia (COMMIT=$COMMIT)"
  head -8 /tmp/patch-rohoel-eia.py
  exit 1
}
wc -c /tmp/patch-rohoel-eia.py

mkdir -p "$DASH_DIR/secrets"
chmod 700 "$DASH_DIR/secrets"
if [[ ! -f "$DASH_DIR/secrets/eia_api_key" ]]; then
  if [[ -n "${EIA_API_KEY:-}" ]]; then
    printf '%s\n' "$EIA_API_KEY" > "$DASH_DIR/secrets/eia_api_key"
    chmod 600 "$DASH_DIR/secrets/eia_api_key"
    echo "EIA key aus Env nach secrets/eia_api_key geschrieben"
  else
    echo "WARN: $DASH_DIR/secrets/eia_api_key fehlt — bitte EIA-Key dort ablegen (chmod 600). Yahoo-Fallback aktiv."
  fi
fi

cp -a "$DASH" "$DASH.bak-rohoeleia-$TS"
python3 /tmp/patch-rohoel-eia.py "$DASH"
python3 -m py_compile "$DASH"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 2
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

echo "--- Marker ---"
grep -n 'rohoelEia\|EIA+EZB\|EIA RBRTE' "$DASH" | head -15
echo "OK rohoel-eia applied COMMIT=$COMMIT"
echo "Test: Dashboard Rohöl-Kachel — Quelle EIA+EZB oder Yahoo+EZB, Farbe nach Sitzungsalter."
