#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

curl -fsSL "$BASE/mesh_chutil.py" -o /tmp/mesh_chutil.py
curl -fsSL "$BASE/patch-mesh-chutil-bridges.py" -o /tmp/patch-mesh-chutil-bridges.py
curl -fsSL "$BASE/funk_health.py" -o /tmp/funk_health.py

# Sanity: neue Dateien, keine alten Stub-Caches
for f in /tmp/mesh_chutil.py /tmp/patch-mesh-chutil-bridges.py /tmp/funk_health.py; do
  if ! grep -q 'chutil' "$f"; then
    echo "FAIL: $f ohne chutil-Marker (CDN/Cache?). COMMIT=$COMMIT"
    head -5 "$f"
    exit 1
  fi
done
wc -c /tmp/mesh_chutil.py /tmp/patch-mesh-chutil-bridges.py /tmp/funk_health.py

# Backups
cp -a "$DASH_DIR/funk_health.py" "$DASH_DIR/funk_health.py.bak-chutil-$TS" 2>/dev/null || true
cp -a "$DASH_DIR/mesh_bridge.py" "$DASH_DIR/mesh_bridge.py.bak-chutil-$TS"
cp -a "$DASH_DIR/mesh_bridge_bayern.py" "$DASH_DIR/mesh_bridge_bayern.py.bak-chutil-$TS"

install -m 0644 /tmp/mesh_chutil.py "$DASH_DIR/mesh_chutil.py"
install -m 0644 /tmp/funk_health.py "$DASH_DIR/funk_health.py"
python3 /tmp/patch-mesh-chutil-bridges.py "$DASH_DIR"

python3 -m py_compile \
  "$DASH_DIR/mesh_chutil.py" \
  "$DASH_DIR/funk_health.py" \
  "$DASH_DIR/mesh_bridge.py" \
  "$DASH_DIR/mesh_bridge_bayern.py"

# Leere History-Dateien anlegen (falls fehlen)
[ -f "$DASH_DIR/mesh1_chutil.json" ] || echo '[]' > "$DASH_DIR/mesh1_chutil.json"
[ -f "$DASH_DIR/mesh2_chutil.json" ] || echo '[]' > "$DASH_DIR/mesh2_chutil.json"

sudo systemctl restart mesh-bridge.service mesh-bridge-bayern.service prepper-dashboard
sleep 2
systemctl is-active mesh-bridge.service mesh-bridge-bayern.service prepper-dashboard || true

echo "--- Marker ---"
grep -n 'chutilBridge\|chutil_worker\|CHUTIL_FILE' "$DASH_DIR/mesh_bridge.py" | head -8
grep -n 'chutilBridge\|chutil_worker\|CHUTIL_FILE' "$DASH_DIR/mesh_bridge_bayern.py" | head -8
grep -n 'Kanalauslastung\|chutilFunk\|/api/funk/chutil' "$DASH_DIR/funk_health.py" | head -8

echo "--- warte auf erstes Sample (Mesh1, max ~70s) ---"
ok=0
for i in $(seq 1 14); do
  sleep 5
  n=$(python3 -c "import json; print(len(json.load(open('$DASH_DIR/mesh1_chutil.json'))))" 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt 0 ]; then
    echo "mesh1 samples: $n"
    python3 -c "import json; d=json.load(open('$DASH_DIR/mesh1_chutil.json')); print(d[-1])"
    ok=1
    break
  fi
  echo "… noch leer ($i/14)"
done
[ "$ok" = 1 ] || echo "WARN: noch kein Mesh1-Sample (Node-DB braucht ggf. länger)"

echo "OK mesh-chutil applied COMMIT=$COMMIT"
