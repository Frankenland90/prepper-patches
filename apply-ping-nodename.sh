#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

curl -fsSL "$BASE/mesh_node_label.py" -o /tmp/mesh_node_label.py
curl -fsSL "$BASE/patch-ping-nodename-bridges.py" -o /tmp/patch-ping-nodename-bridges.py
curl -fsSL "$BASE/patch-ping-nodename-replies.py" -o /tmp/patch-ping-nodename-replies.py

for f in /tmp/mesh_node_label.py /tmp/patch-ping-nodename-bridges.py /tmp/patch-ping-nodename-replies.py; do
  grep -q 'pingName' "$f" || { echo "FAIL marker $f COMMIT=$COMMIT"; head -5 "$f"; exit 1; }
done
wc -c /tmp/mesh_node_label.py /tmp/patch-ping-nodename-bridges.py /tmp/patch-ping-nodename-replies.py

cp -a "$DASH_DIR/mesh_bridge.py" "$DASH_DIR/mesh_bridge.py.bak-pingname-$TS"
cp -a "$DASH_DIR/mesh_bridge_bayern.py" "$DASH_DIR/mesh_bridge_bayern.py.bak-pingname-$TS"
cp -a "$DASH_DIR/mesh_ping_reply.py" "$DASH_DIR/mesh_ping_reply.py.bak-pingname-$TS"
cp -a "$DASH_DIR/mesh_ping_reply2.py" "$DASH_DIR/mesh_ping_reply2.py.bak-pingname-$TS"
cp -a "$DASH_DIR/mesh_ping_reply_bayern.py" "$DASH_DIR/mesh_ping_reply_bayern.py.bak-pingname-$TS" 2>/dev/null || true

install -m 0644 /tmp/mesh_node_label.py "$DASH_DIR/mesh_node_label.py"
python3 /tmp/patch-ping-nodename-bridges.py "$DASH_DIR"
python3 /tmp/patch-ping-nodename-replies.py "$DASH_DIR"

python3 -m py_compile \
  "$DASH_DIR/mesh_node_label.py" \
  "$DASH_DIR/mesh_bridge.py" \
  "$DASH_DIR/mesh_bridge_bayern.py" \
  "$DASH_DIR/mesh_ping_reply.py" \
  "$DASH_DIR/mesh_ping_reply2.py"

sudo systemctl restart mesh-bridge.service mesh-bridge-bayern.service mesh-ping-reply.service mesh-ping-reply-2.service
sleep 2
systemctl is-active mesh-bridge.service mesh-bridge-bayern.service mesh-ping-reply.service mesh-ping-reply-2.service || true

echo "--- Marker ---"
grep -n 'pingName\|label_from_iface\|from_label' \
  "$DASH_DIR/mesh_bridge.py" "$DASH_DIR/mesh_ping_reply.py" "$DASH_DIR/mesh_ping_reply2.py" | head -20

echo "OK ping-nodename applied COMMIT=$COMMIT"
echo "Test: von einem anderen Node 'ping' oder 'test' senden — Antwort sollte Name ( !id ) enthalten."
