#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== mesh-hang apply COMMIT=$COMMIT ==="

curl -fsSL "$BASE/mesh_chutil.py" -o /tmp/mesh_chutil.py
curl -fsSL "$BASE/funk_health.py" -o /tmp/funk_health.py
curl -fsSL "$BASE/mesh_reply_watch.py" -o /tmp/mesh_reply_watch.py
curl -fsSL "$BASE/patch-mesh-hang-bridges.py" -o /tmp/patch-mesh-hang-bridges.py
curl -fsSL "$BASE/mesh_hang_watchdog.py" -o /tmp/mesh_hang_watchdog.py
curl -fsSL "$BASE/mesh-hang-watchdog.service" -o /tmp/mesh-hang-watchdog.service
curl -fsSL "$BASE/mesh-hang-watchdog.timer" -o /tmp/mesh-hang-watchdog.timer

for f in /tmp/mesh_chutil.py /tmp/funk_health.py /tmp/mesh_reply_watch.py \
         /tmp/patch-mesh-hang-bridges.py /tmp/mesh_hang_watchdog.py; do
  if ! grep -qE 'meshHang|meshHangBridge|meshHangPing|meshHangFunk' "$f"; then
    echo "FAIL: $f ohne meshHang-Marker. COMMIT=$COMMIT"
    head -8 "$f"
    exit 1
  fi
done
grep -q 'PLACEHOLDER' /tmp/mesh_chutil.py /tmp/funk_health.py /tmp/mesh_reply_watch.py \
  /tmp/mesh_hang_watchdog.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/mesh_chutil.py /tmp/funk_health.py /tmp/mesh_reply_watch.py \
  /tmp/patch-mesh-hang-bridges.py /tmp/mesh_hang_watchdog.py \
  /tmp/mesh-hang-watchdog.service /tmp/mesh-hang-watchdog.timer

# Backups
for n in mesh_chutil.py funk_health.py mesh_bridge.py mesh_bridge_bayern.py \
         mesh_ping_reply.py mesh_ping_reply2.py; do
  [ -f "$DASH_DIR/$n" ] && cp -a "$DASH_DIR/$n" "$DASH_DIR/$n.bak-meshhang-$TS" || true
done

install -m 0644 /tmp/mesh_chutil.py "$DASH_DIR/mesh_chutil.py"
install -m 0644 /tmp/funk_health.py "$DASH_DIR/funk_health.py"
install -m 0644 /tmp/mesh_reply_watch.py "$DASH_DIR/mesh_reply_watch.py"
install -m 0644 /tmp/mesh_hang_watchdog.py "$DASH_DIR/mesh_hang_watchdog.py"
install -m 0755 /tmp/patch-mesh-hang-bridges.py "$DASH_DIR/patch-mesh-hang-bridges.py"

python3 /tmp/patch-mesh-hang-bridges.py "$DASH_DIR"

python3 -m py_compile \
  "$DASH_DIR/mesh_chutil.py" \
  "$DASH_DIR/funk_health.py" \
  "$DASH_DIR/mesh_reply_watch.py" \
  "$DASH_DIR/mesh_hang_watchdog.py" \
  "$DASH_DIR/mesh_bridge.py" \
  "$DASH_DIR/mesh_bridge_bayern.py" \
  "$DASH_DIR/mesh_ping_reply.py" \
  "$DASH_DIR/mesh_ping_reply2.py"

# systemd system units
sudo install -m 0644 /tmp/mesh-hang-watchdog.service /etc/systemd/system/mesh-hang-watchdog.service
sudo install -m 0644 /tmp/mesh-hang-watchdog.timer /etc/systemd/system/mesh-hang-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now mesh-hang-watchdog.timer

# Services neu laden (Reply-Watch + Telemetrie)
sudo systemctl restart \
  mesh-bridge.service \
  mesh-bridge-bayern.service \
  mesh-ping-reply.service \
  mesh-ping-reply-2.service \
  prepper-dashboard \
  || true
sleep 2
systemctl is-active mesh-bridge.service mesh-bridge-bayern.service \
  mesh-ping-reply.service mesh-ping-reply-2.service prepper-dashboard \
  mesh-hang-watchdog.timer || true

# einmal Status schreiben (detect-only)
sudo -u fmg PYTHONPATH="$DASH_DIR" python3 "$DASH_DIR/mesh_hang_watchdog.py" || \
  PYTHONPATH="$DASH_DIR" python3 "$DASH_DIR/mesh_hang_watchdog.py" || true

echo "--- Marker ---"
grep -n 'meshHang' "$DASH_DIR/mesh_chutil.py" "$DASH_DIR/funk_health.py" \
  "$DASH_DIR/mesh_reply_watch.py" "$DASH_DIR/mesh_hang_watchdog.py" | head -30
grep -n 'meshHangBridge\|mesh_reply_watch' "$DASH_DIR/mesh_bridge.py" "$DASH_DIR/mesh_bridge_bayern.py" | head -20 || true
grep -n 'meshHangPing\|mesh_reply_watch' "$DASH_DIR/mesh_ping_reply.py" "$DASH_DIR/mesh_ping_reply2.py" | head -20 || true

echo "--- Status ---"
[ -f "$DASH_DIR/mesh_hang_status.json" ] && head -c 800 "$DASH_DIR/mesh_hang_status.json" && echo || echo "(noch kein Status)"

echo ""
echo "OK mesh-hang applied COMMIT=$COMMIT"
echo "Autorestart: AUS (detect-only). Zum Einschalten:"
echo "  mkdir -p $DASH_DIR/secrets && touch $DASH_DIR/secrets/mesh_hang_autorestart"
echo "  # Watchdog restartet dann Bridge (+ Ping-Reply) bei stuck>=45min + stumm/unbekannt, Cooldown 2h"
echo "Sofort Mesh2 manuell:"
echo "  sudo systemctl restart mesh-bridge-bayern.service mesh-ping-reply-2.service"
