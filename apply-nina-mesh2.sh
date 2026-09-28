#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== nina-mesh2 apply COMMIT=$COMMIT ==="
echo "Ansatz: Mesh2 NINA wie Mesh1 via :5002 (send_nina_to_bayern)."
echo "JSON-Mirror forward_nina in mesh-ping-reply-2 AUS (kein Doppel-TX)."
echo "Entwarnungen bleiben in Tile (nina_mesh_status.cleared)."

curl -fsSL "$BASE/patch-nina-mesh2.py" -o /tmp/patch-nina-mesh2.py
curl -fsSL "$BASE/apply-nina-mesh2.sh" -o /tmp/apply-nina-mesh2.sh.self 2>/dev/null || true

grep -q 'ninaMesh2Direct' /tmp/patch-nina-mesh2.py \
  || { echo "FAIL: patch ohne ninaMesh2Direct. COMMIT=$COMMIT"; head -8 /tmp/patch-nina-mesh2.py; exit 1; }
grep -q 'PLACEHOLDER' /tmp/patch-nina-mesh2.py \
  && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-nina-mesh2.py

# Backups
[ -f "$DASH_DIR/dashboard.py" ] && cp -a "$DASH_DIR/dashboard.py" "$DASH_DIR/dashboard.py.bak-ninamesh2-$TS"
[ -f "$DASH_DIR/mesh_ping_reply2.py" ] && cp -a "$DASH_DIR/mesh_ping_reply2.py" "$DASH_DIR/mesh_ping_reply2.py.bak-ninamesh2-$TS"

# Repair twice = idempotent
python3 /tmp/patch-nina-mesh2.py "$DASH_DIR"
python3 /tmp/patch-nina-mesh2.py "$DASH_DIR"

python3 -m py_compile "$DASH_DIR/dashboard.py"
[ -f "$DASH_DIR/mesh_ping_reply2.py" ] && python3 -m py_compile "$DASH_DIR/mesh_ping_reply2.py"

# Asserts Dashboard
grep -q 'ninaMesh2Direct' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: Marker fehlt in dashboard.py"; exit 1; }
grep -q 'send_nina_to_bayern(text' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: kein send_nina_to_bayern in maybe_mesh_nina-Pfad"; exit 1; }
grep -q 'nina_mesh_status.cleared' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: Entwarnung/cleared aus Tile verschwunden"; exit 1; }
# maybe_mesh_nina_bayern bleibt aus (andere Quelle)
grep -n 'maybe_mesh_nina_bayern' "$DASH_DIR/dashboard.py" | grep -v '^[^:]*:.*def maybe_mesh_nina_bayern' | head -5 || true

# Asserts reply2 Mirror off
if [ -f "$DASH_DIR/mesh_ping_reply2.py" ]; then
  grep -q 'ninaMesh2Direct' "$DASH_DIR/mesh_ping_reply2.py" \
    || { echo "FAIL: Marker fehlt in mesh_ping_reply2.py"; exit 1; }
  # early return must exist; old TX body should not run
  grep -A2 'def forward_nina' "$DASH_DIR/mesh_ping_reply2.py" | grep -q 'return  # ninaMesh2Direct' \
    || { echo "FAIL: forward_nina nicht disabled"; exit 1; }
fi

# Services: Dashboard + Mesh2-Bridge (Send-Pfad). ping-reply-2 bleibt fuer Ping, NINA-Mirror ist noop.
sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sudo systemctl restart mesh-bridge-bayern.service 2>/dev/null \
  || sudo systemctl restart mesh-bridge-bayern \
  || true
# ping-reply-2 neu laden damit disabled forward_nina aktiv ist
sudo systemctl restart mesh-ping-reply-2.service 2>/dev/null \
  || sudo systemctl restart mesh-ping-reply-2 \
  || true

sleep 2
echo "--- systemctl ---"
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true
systemctl is-active mesh-bridge-bayern.service 2>/dev/null \
  || systemctl is-active mesh-bridge-bayern \
  || true
systemctl is-active mesh-ping-reply-2.service 2>/dev/null \
  || systemctl is-active mesh-ping-reply-2 \
  || true

echo "--- Mesh2 health :5002 ---"
READY=0
for _ in $(seq 1 15); do
  sleep 1
  if curl -sf -m 2 "http://127.0.0.1:5002/health" >/dev/null; then
    READY=1
    break
  fi
done
if [ "$READY" -eq 1 ]; then
  curl -sS -m 5 "http://127.0.0.1:5002/health" | head -c 300; echo
  echo "OK Mesh2 bridge health"
else
  echo "WARN: :5002/health nicht ready — Mesh2-NINA-Send braucht mesh-bridge-bayern"
  journalctl -u mesh-bridge-bayern -n 20 --no-pager 2>/dev/null || true
fi

echo ""
echo "OK nina-mesh2 applied COMMIT=$COMMIT"
echo "Mesh1: maybe_mesh_nina -> :5001/send (unverändert)"
echo "Mesh2: nach Mesh1-OK -> send_nina_to_bayern (:5002/send)"
echo "Mirror: forward_nina = noop (kein Doppel-TX)"
echo "Tile: Entwarnungen/cleared bleiben sichtbar"
echo ""
echo "Pi-Check empfohlen:"
echo "  systemctl is-active mesh-bridge-bayern mesh-ping-reply-2 prepper-dashboard"
echo "  curl -sS http://127.0.0.1:5002/health | head -c 200; echo"
echo "  journalctl -u prepper-dashboard -n 30 --no-pager | grep -i NINA-Mesh"
