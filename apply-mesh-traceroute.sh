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
# funk: kein Manual-Button mehr
if grep -qE 'Jetzt tracen|runTraceNow|/api/funk/traceroute/run|meshTraceManual' /tmp/funk_health.py; then
  echo "FAIL: funk_health.py enthält noch Manual-Trace-Button"
  exit 1
fi
# patcher: darf Manual-Pfad strippen, aber kein do_POST traceroute/run mehr einbauen
if grep -qE 'def do_POST|DO_POST\s*=' /tmp/patch-mesh-traceroute-bridge.py; then
  # erlauben nur in Strip-/Assert-Kontext, nicht als einzufügender DO_POST-Block
  if grep -qE "^DO_POST\s*=|^RUN_ONCE\s*=" /tmp/patch-mesh-traceroute-bridge.py; then
    echo "FAIL: patcher enthält noch DO_POST/RUN_ONCE Insert-Blöcke"
    exit 1
  fi
fi
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
grep -nE 'meshTrace|TRACE_DEST|!fbc48dcb' "$DASH_DIR/mesh_traceroute.py" | head -15
grep -nE 'meshTraceBridge|traceroute_worker|TRACE_DEST|!fbc48dcb|/traceroute|sendData' "$DASH_DIR/mesh_bridge.py" | head -30
# Manual darf NICHT mehr in Bridge/Funk sein
if grep -nE 'meshTraceManual|Jetzt tracen|runTraceNow|/traceroute/run|def do_POST|_trace_busy|traceroute_run_once' \
  "$DASH_DIR/mesh_bridge.py" "$DASH_DIR/funk_health.py" 2>/dev/null; then
  echo "FAIL: Manual-Trace-Reste in Bridge/Funk"
  exit 1
fi
grep -nE 'meshTraceFunk|Trace ·|tr1|trace-fail|!fbc48dcb' "$DASH_DIR/funk_health.py" | head -20

echo ""
echo "OK mesh-traceroute applied COMMIT=$COMMIT"
echo "Probe: stündlich traceroute_worker (fat, sendData unter _lock) → !fbc48dcb. Kein Manual-Button."
echo "Tipp: nach Apply stündlichen Probe abwarten (~90s Warmup + bis 60s Trace), dann /funk Reload."
