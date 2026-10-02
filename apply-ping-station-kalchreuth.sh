#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-f248e5292e3c696a23d04da2fa30029a917bb9d9}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== ping-station-kalchreuth apply COMMIT=$COMMIT ==="

if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/patch-ping-station-kalchreuth.py" -o /tmp/patch-ping-station-kalchreuth.py
grep -q 'pingStationKalch' /tmp/patch-ping-station-kalchreuth.py \
  || { echo "FAIL: patch ohne pingStationKalch. COMMIT=$COMMIT"; head -8 /tmp/patch-ping-station-kalchreuth.py; exit 1; }
grep -q 'PLACEHOLDER' /tmp/patch-ping-station-kalchreuth.py \
  && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-ping-station-kalchreuth.py

for f in mesh_ping_reply2.py mesh_ping_reply_bayern.py mesh_bridge_bayern.py; do
  [ -f "$DASH_DIR/$f" ] && cp -a "$DASH_DIR/$f" "$DASH_DIR/$f.bak-pingstation-$TS" || true
done

# twice = idempotent
python3 /tmp/patch-ping-station-kalchreuth.py "$DASH_DIR"
python3 /tmp/patch-ping-station-kalchreuth.py "$DASH_DIR"

for f in mesh_ping_reply2.py mesh_ping_reply_bayern.py mesh_bridge_bayern.py; do
  [ -f "$DASH_DIR/$f" ] && python3 -m py_compile "$DASH_DIR/$f"
done

# Assert: Mesh2 reply label
if [ -f "$DASH_DIR/mesh_ping_reply2.py" ]; then
  grep -q 'STATION = "Station Kalchreuth"' "$DASH_DIR/mesh_ping_reply2.py" \
    || { echo "FAIL: STATION nicht Kalchreuth in mesh_ping_reply2.py"; grep -n '^STATION' "$DASH_DIR/mesh_ping_reply2.py" || true; exit 1; }
  grep -q 'pingStationKalch' "$DASH_DIR/mesh_ping_reply2.py" \
    || { echo "FAIL: Marker fehlt"; exit 1; }
  # must not still say Bayern/Mesh2 as station label
  if grep -E '^STATION\s*=\s*["'\'']Station (Bayern|Mesh2)["'\'']' "$DASH_DIR/mesh_ping_reply2.py"; then
    echo "FAIL: altes Station Bayern/Mesh2 noch da"; exit 1
  fi
fi

sudo systemctl restart mesh-ping-reply-2.service 2>/dev/null \
  || sudo systemctl restart mesh-ping-reply-2 \
  || true
# Bridge only if we may have touched its STATION
if [ -f "$DASH_DIR/mesh_bridge_bayern.py" ] && grep -q 'pingStationKalch' "$DASH_DIR/mesh_bridge_bayern.py"; then
  sudo systemctl restart mesh-bridge-bayern.service 2>/dev/null \
    || sudo systemctl restart mesh-bridge-bayern \
    || true
fi

sleep 2
echo "--- systemctl ---"
systemctl is-active mesh-ping-reply-2.service 2>/dev/null \
  || systemctl is-active mesh-ping-reply-2 \
  || true
systemctl is-active mesh-bridge-bayern.service 2>/dev/null \
  || systemctl is-active mesh-bridge-bayern \
  || true

echo "--- Marker ---"
grep -n 'STATION\|pingStationKalch' \
  "$DASH_DIR/mesh_ping_reply2.py" \
  "$DASH_DIR/mesh_bridge_bayern.py" 2>/dev/null | head -20 || true

echo "OK ping-station-kalchreuth applied COMMIT=$COMMIT"
echo "Test: ping/test an Mesh2 — Antwortzeile 1 muss 'Station Kalchreuth' sein."
