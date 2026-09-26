#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== mesh-traceroute apply COMMIT=$COMMIT ==="

curl -fsSL "$BASE/mesh_traceroute.py" -o /tmp/mesh_traceroute.py
curl -fsSL "$BASE/patch-mesh-traceroute-bridge.py" -o /tmp/patch-mesh-traceroute-bridge.py
curl -fsSL "$BASE/funk_health.py" -o /tmp/funk_health.py
curl -fsSL "$BASE/apply-mesh-traceroute.sh" -o /tmp/apply-mesh-traceroute.sh.self 2>/dev/null || true

for f in /tmp/mesh_traceroute.py /tmp/patch-mesh-traceroute-bridge.py /tmp/funk_health.py; do
  if ! grep -qE 'meshTrace|meshTraceBridge|meshTraceFunk|!fbc48dcb' "$f"; then
    echo "FAIL: $f ohne meshTrace/!fbc48dcb Marker. COMMIT=$COMMIT"
    head -8 "$f"
    exit 1
  fi
done
grep -q 'PLACEHOLDER' /tmp/mesh_traceroute.py /tmp/patch-mesh-traceroute-bridge.py /tmp/funk_health.py \
  && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/mesh_traceroute.py /tmp/patch-mesh-traceroute-bridge.py /tmp/funk_health.py

# Backups
[ -f "$DASH_DIR/mesh_bridge.py" ] && cp -a "$DASH_DIR/mesh_bridge.py" "$DASH_DIR/mesh_bridge.py.bak-traceroute-$TS"
[ -f "$DASH_DIR/funk_health.py" ] && cp -a "$DASH_DIR/funk_health.py" "$DASH_DIR/funk_health.py.bak-traceroute-$TS"

install -m 0644 /tmp/mesh_traceroute.py "$DASH_DIR/mesh_traceroute.py"
install -m 0644 /tmp/funk_health.py "$DASH_DIR/funk_health.py"
install -m 0755 /tmp/patch-mesh-traceroute-bridge.py "$DASH_DIR/patch-mesh-traceroute-bridge.py"

python3 /tmp/patch-mesh-traceroute-bridge.py "$DASH_DIR"
# Idempotenz: zweiter Lauf darf nicht doppelte Worker einfügen
python3 /tmp/patch-mesh-traceroute-bridge.py "$DASH_DIR"

python3 -m py_compile \
  "$DASH_DIR/mesh_traceroute.py" \
  "$DASH_DIR/funk_health.py" \
  "$DASH_DIR/mesh_bridge.py"

[ -f "$DASH_DIR/mesh1_traceroute.json" ] || echo '[]' > "$DASH_DIR/mesh1_traceroute.json"

# Nur Mesh1-Bridge + Dashboard (kein mesh2)
sudo systemctl restart mesh-bridge.service prepper-dashboard || true
sleep 2
systemctl is-active mesh-bridge.service prepper-dashboard || true

echo "--- Marker ---"
grep -nE 'meshTrace|execute_probe|TRACE_DEST|!fbc48dcb' "$DASH_DIR/mesh_traceroute.py" | head -15
grep -nE 'meshTraceBridge|meshTraceManual|traceroute_run_once|traceroute_worker|TRACE_DEST|!fbc48dcb|/traceroute|do_POST|_trace_busy' "$DASH_DIR/mesh_bridge.py" | head -30
grep -nE 'meshTraceFunk|meshTraceManual|Jetzt tracen|tr1|trace-fail|!fbc48dcb' "$DASH_DIR/funk_health.py" | head -25

echo ""
echo "OK mesh-traceroute applied COMMIT=$COMMIT"
echo "Probe: stündlich traceroute_worker + Button /funk → POST /traceroute/run (bestehendes _iface)."
echo "Tipp: nach Apply ersten Probe abwarten oder 'Jetzt tracen'; Ergebnis ~60s, dann Reload zeigt SNR."
