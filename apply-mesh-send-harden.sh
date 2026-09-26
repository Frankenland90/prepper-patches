#!/bin/bash
set -euo pipefail
# Pinned after push; override with COMMIT=... if needed.
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
BRIDGE1="$DASH_DIR/mesh_bridge.py"
BRIDGE2="$DASH_DIR/mesh_bridge_bayern.py"
TS=$(date +%Y%m%d-%H%M%S)
PROBE1="Mesh1 harden-probe"
PROBE2="Mesh2 harden-probe"

echo "=== mesh-send-harden apply COMMIT=$COMMIT ==="

if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi

curl -fsSL "$BASE/patch-mesh-send-harden.py" -o /tmp/patch-mesh-send-harden.py
curl -fsSL "$BASE/patch-mesh-traceroute-remove.py" -o /tmp/patch-mesh-traceroute-remove.py
curl -fsSL "$BASE/patch-mesh-traceroute-remove-guard.py" -o /tmp/patch-mesh-traceroute-remove-guard.py
curl -fsSL "$BASE/apply-mesh-send-harden.sh" -o /tmp/apply-mesh-send-harden.sh.self 2>/dev/null || true

if ! grep -qE 'meshSendHarden|startswith\("/send"\)' /tmp/patch-mesh-send-harden.py; then
  echo "FAIL: patch-mesh-send-harden.py ohne meshSendHarden//send. COMMIT=$COMMIT"
  head -8 /tmp/patch-mesh-send-harden.py
  exit 1
fi
if ! grep -qE 'has_send|NEVER delete' /tmp/patch-mesh-traceroute-remove.py; then
  echo "FAIL: patch-mesh-traceroute-remove.py ohne /send-Guard. COMMIT=$COMMIT"
  head -8 /tmp/patch-mesh-traceroute-remove.py
  exit 1
fi
if ! grep -q 'meshTraceRemoveGuard\|has_send' /tmp/patch-mesh-traceroute-remove-guard.py; then
  echo "FAIL: patch-mesh-traceroute-remove-guard.py unvollständig"
  head -8 /tmp/patch-mesh-traceroute-remove-guard.py
  exit 1
fi
grep -q 'PLACEHOLDER' /tmp/patch-mesh-send-harden.py /tmp/patch-mesh-traceroute-remove.py \
  /tmp/patch-mesh-traceroute-remove-guard.py \
  && { echo "FAIL PLACEHOLDER in patch files"; exit 1; } || true
wc -c /tmp/patch-mesh-send-harden.py /tmp/patch-mesh-traceroute-remove.py \
  /tmp/patch-mesh-traceroute-remove-guard.py

# Backup both bridges
[ -f "$BRIDGE1" ] && cp -a "$BRIDGE1" "$DASH_DIR/mesh_bridge.py.bak-sendharden-$TS"
[ -f "$BRIDGE2" ] && cp -a "$BRIDGE2" "$DASH_DIR/mesh_bridge_bayern.py.bak-sendharden-$TS"
[ -f "$DASH_DIR/patch-mesh-traceroute-remove.py" ] \
  && cp -a "$DASH_DIR/patch-mesh-traceroute-remove.py" \
     "$DASH_DIR/patch-mesh-traceroute-remove.py.bak-sendharden-$TS" || true

# Install safe traceroute-remove + guard into dashboard (for future apply-mesh-traceroute-remove)
install -m 0755 /tmp/patch-mesh-traceroute-remove.py "$DASH_DIR/patch-mesh-traceroute-remove.py"
install -m 0755 /tmp/patch-mesh-traceroute-remove-guard.py "$DASH_DIR/patch-mesh-traceroute-remove-guard.py"
# Belt+suspenders: rewrite in place if an older copy somehow remains
python3 /tmp/patch-mesh-traceroute-remove-guard.py "$DASH_DIR"
python3 /tmp/patch-mesh-traceroute-remove-guard.py "$DASH_DIR"  # idempotent

# Harden both bridges (twice = idempotent)
python3 /tmp/patch-mesh-send-harden.py "$DASH_DIR"
python3 /tmp/patch-mesh-send-harden.py "$DASH_DIR"

python3 -m py_compile "$BRIDGE1"
[ -f "$BRIDGE2" ] && python3 -m py_compile "$BRIDGE2"

# Asserts per bridge
mesh_assert() {
  local f="$1" label="$2"
  grep -q 'def do_POST' "$f" || { echo "FAIL $label: kein def do_POST"; return 1; }
  grep -qE 'startswith\(["'\''"]/send' "$f" || { echo "FAIL $label: kein /send"; return 1; }
  grep -q '_send_q' "$f" || { echo "FAIL $label: kein _send_q"; return 1; }
  grep -qE 'def worker|target=worker' "$f" || { echo "FAIL $label: kein worker"; return 1; }
  echo "OK $label asserts (do_POST+/send+_send_q+worker)"
  return 0
}
mesh_assert "$BRIDGE1" "Mesh1" || exit 1
if [ -f "$BRIDGE2" ]; then
  mesh_assert "$BRIDGE2" "Mesh2" || exit 1
else
  echo "WARN Mesh2: $BRIDGE2 fehlt"
fi

# Restart BOTH bridges
sudo systemctl restart mesh-bridge.service 2>/dev/null \
  || sudo systemctl restart mesh-bridge || true
sudo systemctl restart mesh-bridge-bayern.service 2>/dev/null \
  || sudo systemctl restart mesh-bridge-bayern || true
systemctl is-active mesh-bridge.service 2>/dev/null \
  || systemctl is-active mesh-bridge || true
systemctl is-active mesh-bridge-bayern.service 2>/dev/null \
  || systemctl is-active mesh-bridge-bayern || true

wait_health() {
  local port="$1" label="$2"
  local ready=0
  for _ in $(seq 1 20); do
    sleep 1
    if curl -sf -m 2 "http://127.0.0.1:${port}/health" >/dev/null; then
      ready=1
      break
    fi
  done
  if [ "$ready" -ne 1 ]; then
    echo "FAIL $label: :${port}/health nicht bereit in 20s"
    journalctl -u "mesh-bridge*" -n 30 --no-pager || true
    return 1
  fi
  echo "OK $label health :${port}"
  return 0
}

MESH1_OK=0
MESH2_OK=0
wait_health 5001 Mesh1 && MESH1_OK=1 || MESH1_OK=0
if [ -f "$BRIDGE2" ]; then
  wait_health 5002 Mesh2 && MESH2_OK=1 || MESH2_OK=0
else
  MESH2_OK=0
  echo "FAIL Mesh2: bridge file missing"
fi

health_json() {
  curl -sS -m 5 "http://127.0.0.1:$1/health" || echo "{}"
}

sent_ok_of() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("sent_ok") or 0))' 2>/dev/null \
    || echo 0
}
last_text_of() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("last_text") or "")' 2>/dev/null \
    || echo ""
}

probe_send() {
  local port="$1" label="$2" text="$3"
  local before after before_txt after_txt post_out http_code body

  health_json "$port" > /tmp/harden-health-before-$port.json
  before=$(sent_ok_of < /tmp/harden-health-before-$port.json)
  before_txt=$(last_text_of < /tmp/harden-health-before-$port.json)

  echo "--- $label POST /send probe ---"
  post_out=$(curl -sS -m 8 -w "\nHTTP_CODE:%{http_code}" \
    -X POST "http://127.0.0.1:${port}/send" \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"${text}\",\"channel\":0}" || true)
  echo "$post_out"
  http_code=$(echo "$post_out" | sed -n 's/^HTTP_CODE://p')
  body=$(echo "$post_out" | sed '/^HTTP_CODE:/d')
  case "$http_code" in
    200)
      echo "$body" | grep -q '"ok"' || {
        echo "FAIL $label: POST 200 aber kein ok"
        return 1
      }
      ;;
    *)
      echo "FAIL $label: POST /send HTTP=$http_code (erwartet 200)"
      return 1
      ;;
  esac

  sleep 5
  health_json "$port" | tee /tmp/harden-health-after-$port.json >/dev/null
  after=$(sent_ok_of < /tmp/harden-health-after-$port.json)
  after_txt=$(last_text_of < /tmp/harden-health-after-$port.json)
  echo "$label sent_ok before=$before after=$after last_text='$after_txt'"

  if [ "$after" -gt "$before" ] 2>/dev/null; then
    echo "OK $label sent_ok increased ($before -> $after)"
    return 0
  fi
  case "$after_txt" in
    *"$text"*)
      echo "OK $label last_text matches probe"
      return 0
      ;;
  esac
  echo "FAIL $label: sent_ok not increased and last_text != probe"
  echo "  before_txt='$before_txt' after_txt='$after_txt'"
  return 1
}

if [ "$MESH1_OK" -eq 1 ]; then
  probe_send 5001 Mesh1 "$PROBE1" && MESH1_OK=1 || MESH1_OK=0
fi
if [ "$MESH2_OK" -eq 1 ]; then
  probe_send 5002 Mesh2 "$PROBE2" && MESH2_OK=1 || MESH2_OK=0
fi

echo ""
echo "======== RESULT ========"
if [ "$MESH1_OK" -eq 1 ]; then echo "OK Mesh1 (:5001)"; else echo "FAIL Mesh1 (:5001)"; fi
if [ "$MESH2_OK" -eq 1 ]; then echo "OK Mesh2 (:5002)"; else echo "FAIL Mesh2 (:5002)"; fi
echo "Safe traceroute-remove installed at $DASH_DIR/patch-mesh-traceroute-remove.py"
echo "COMMIT=$COMMIT"

if [ "$MESH1_OK" -ne 1 ] || [ "$MESH2_OK" -ne 1 ]; then
  exit 1
fi
echo "OK mesh-send-harden applied COMMIT=$COMMIT"
