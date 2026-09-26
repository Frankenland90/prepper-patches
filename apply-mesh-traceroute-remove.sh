#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== mesh-traceroute REMOVE apply COMMIT=$COMMIT ==="

curl -fsSL "$BASE/funk_health.py" -o /tmp/funk_health.py
curl -fsSL "$BASE/patch-mesh-traceroute-remove.py" -o /tmp/patch-mesh-traceroute-remove.py
curl -fsSL "$BASE/apply-mesh-traceroute-remove.sh" -o /tmp/apply-mesh-traceroute-remove.sh.self 2>/dev/null || true

# funk_health must be hang/chutil only — NO traceroute markers
if grep -qE 'mesh_traceroute|Trace · MMSC|trace-fail|!fbc48dcb|meshTraceFunk|_trace_card' /tmp/funk_health.py; then
  echo "FAIL: funk_health.py enthält noch traceroute-Marker. COMMIT=$COMMIT"
  grep -nE 'mesh_traceroute|Trace ·|trace-fail|!fbc48dcb|meshTraceFunk|_trace_card' /tmp/funk_health.py | head -20
  exit 1
fi
# hang/chutil markers must remain
if ! grep -qE 'meshHangFunk|chutilFunk' /tmp/funk_health.py; then
  echo "FAIL: funk_health.py ohne meshHangFunk/chutilFunk"
  head -8 /tmp/funk_health.py
  exit 1
fi
# patcher must be a real remover
if ! grep -qE 'meshTraceRemove|traceroute_worker|TRACE_DEST' /tmp/patch-mesh-traceroute-remove.py; then
  echo "FAIL: patch-mesh-traceroute-remove.py ohne Strip-Logik"
  head -8 /tmp/patch-mesh-traceroute-remove.py
  exit 1
fi
grep -q 'PLACEHOLDER' /tmp/funk_health.py /tmp/patch-mesh-traceroute-remove.py \
  && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/funk_health.py /tmp/patch-mesh-traceroute-remove.py

# Backups
[ -f "$DASH_DIR/mesh_bridge.py" ] && cp -a "$DASH_DIR/mesh_bridge.py" "$DASH_DIR/mesh_bridge.py.bak-traceroute-remove-$TS"
[ -f "$DASH_DIR/funk_health.py" ] && cp -a "$DASH_DIR/funk_health.py" "$DASH_DIR/funk_health.py.bak-traceroute-remove-$TS"

install -m 0644 /tmp/funk_health.py "$DASH_DIR/funk_health.py"
install -m 0755 /tmp/patch-mesh-traceroute-remove.py "$DASH_DIR/patch-mesh-traceroute-remove.py"

# Strip traceroute from Mesh1 bridge (twice = idempotent)
python3 /tmp/patch-mesh-traceroute-remove.py "$DASH_DIR"
python3 /tmp/patch-mesh-traceroute-remove.py "$DASH_DIR"

# Optional: retire mesh_traceroute.py on Pi (keep as .bak)
if [ -f "$DASH_DIR/mesh_traceroute.py" ]; then
  mv -f "$DASH_DIR/mesh_traceroute.py" "$DASH_DIR/mesh_traceroute.py.bak-traceroute-remove-$TS"
  echo "mv mesh_traceroute.py -> mesh_traceroute.py.bak-traceroute-remove-$TS"
fi

# Reset history so old fails don't linger if someone re-adds
echo '[]' > "$DASH_DIR/mesh1_traceroute.json"
echo "reset mesh1_traceroute.json -> []"

python3 -m py_compile \
  "$DASH_DIR/funk_health.py" \
  "$DASH_DIR/mesh_bridge.py"

# Nur Mesh1-Bridge + Dashboard (kein mesh2)
sudo systemctl restart mesh-bridge.service prepper-dashboard || true
sleep 2
systemctl is-active mesh-bridge.service prepper-dashboard || true

echo "--- Verify bridge (must be empty) ---"
if grep -nE 'traceroute_worker|TRACE_DEST|import mesh_traceroute|meshTraceBridge|/traceroute' \
  "$DASH_DIR/mesh_bridge.py" 2>/dev/null; then
  echo "FAIL: Bridge enthält noch traceroute-Reste"
  exit 1
fi
echo "(keine traceroute-Marker in mesh_bridge.py)"

echo "--- Verify funk_health (must be empty) ---"
if grep -nE 'mesh_traceroute|Trace ·|trace-fail|meshTraceFunk|_trace_card|!fbc48dcb' \
  "$DASH_DIR/funk_health.py" 2>/dev/null; then
  echo "FAIL: funk_health enthält noch traceroute-Marker"
  exit 1
fi
echo "(keine traceroute-Marker in funk_health.py)"
grep -nE 'meshHangFunk|chutilFunk' "$DASH_DIR/funk_health.py" | head -5

echo ""
echo "OK mesh-traceroute REMOVED COMMIT=$COMMIT"
echo "Entfernt: hourly traceroute_worker, TRACE_*, /traceroute GET, Trace-Karte, trace-fail Ampel."
echo "Erhalten: meshHangFunk / chutilFunk / reply_watch."
