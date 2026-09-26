#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
BRIDGE="$DASH_DIR/mesh_bridge.py"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== mesh1-send-fix apply COMMIT=$COMMIT ==="

curl -fsSL "$BASE/patch-mesh1-send-fix.py" -o /tmp/patch-mesh1-send-fix.py
curl -fsSL "$BASE/apply-mesh1-send-fix.sh" -o /tmp/apply-mesh1-send-fix.sh.self 2>/dev/null || true

if ! grep -qE 'meshSendFix|startswith\("/send"\)' /tmp/patch-mesh1-send-fix.py; then
  echo "FAIL: patch-mesh1-send-fix.py ohne meshSendFix//send. COMMIT=$COMMIT"
  head -8 /tmp/patch-mesh1-send-fix.py
  exit 1
fi
grep -q 'PLACEHOLDER' /tmp/patch-mesh1-send-fix.py \
  && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/patch-mesh1-send-fix.py

# Backup live
[ -f "$BRIDGE" ] && cp -a "$BRIDGE" "$DASH_DIR/mesh_bridge.py.bak-presendfix-$TS"

# Repair (twice = idempotent)
python3 /tmp/patch-mesh1-send-fix.py "$DASH_DIR"
python3 /tmp/patch-mesh1-send-fix.py "$DASH_DIR"

python3 -m py_compile "$BRIDGE"

# Asserts
grep -q 'def do_POST' "$BRIDGE" || { echo "FAIL: kein def do_POST"; exit 1; }
grep -qE 'startswith\(["'"'"']/send' "$BRIDGE" || { echo "FAIL: kein /send"; exit 1; }
if grep -nE 'traceroute_run_once|meshTraceManual|target=traceroute_worker' "$BRIDGE"; then
  echo "FAIL: traceroute-Reste in Bridge"
  exit 1
fi

# Nur Mesh1-Bridge (kein mesh2, kein prepper-dashboard)
sudo systemctl restart mesh-bridge.service 2>/dev/null \
  || sudo systemctl restart mesh-bridge \
  || true
sleep 2
systemctl is-active mesh-bridge.service 2>/dev/null \
  || systemctl is-active mesh-bridge \
  || true

echo "--- Verify POST /send ---"
POST_OUT=$(curl -sS -m 8 -w "\nHTTP_CODE:%{http_code}" \
  -X POST "http://127.0.0.1:5001/send" \
  -H "Content-Type: application/json" \
  -d '{"text":"send-fix-probe","channel":0}' || true)
echo "$POST_OUT"
HTTP_CODE=$(echo "$POST_OUT" | sed -n 's/^HTTP_CODE://p')
BODY=$(echo "$POST_OUT" | sed '/^HTTP_CODE:/d')
case "$HTTP_CODE" in
  200)
    echo "$BODY" | grep -q '"ok"' || { echo "FAIL: POST 200 aber kein ok in JSON"; exit 1; }
    ;;
  *)
    echo "FAIL: POST /send HTTP=$HTTP_CODE (erwartet 200, JSON ok — nicht HTML 501)"
    exit 1
    ;;
esac

echo "--- /health ---"
curl -sS -m 5 "http://127.0.0.1:5001/health" | head -c 400; echo

echo ""
echo "OK mesh1-send-fix applied COMMIT=$COMMIT"
echo "Restored: Handler.do_POST /hold /resume /send via _send_q (Sep-2 original)."
echo "NOT touched: mesh2, prepper-dashboard, traceroute (stays gone)."
echo ""
echo "NOTE Mesh2: tele_state stuck seit ~16:27 (ch_util frozen). Autorestart is dry_run."
echo "Optional manuell (NICHT auto): sudo systemctl restart mesh-bridge-bayern"
