#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== mesh-hang-retry apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/mesh_hang_watchdog.py" -o /tmp/mesh_hang_watchdog.py
grep -q 'meshHangRetry' /tmp/mesh_hang_watchdog.py || { echo "FAIL: kein meshHangRetry"; exit 1; }
grep -q 'COOLDOWN_RETRY_SEC' /tmp/mesh_hang_watchdog.py || { echo "FAIL: kein RETRY"; exit 1; }
grep -q -- '--force' /tmp/mesh_hang_watchdog.py || { echo "FAIL: kein --force"; exit 1; }
grep -q 'PLACEHOLDER' /tmp/mesh_hang_watchdog.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/mesh_hang_watchdog.py

cp -a "$DASH_DIR/mesh_hang_watchdog.py" "$DASH_DIR/mesh_hang_watchdog.py.bak-retry-$TS" 2>/dev/null || true
install -m 0644 /tmp/mesh_hang_watchdog.py "$DASH_DIR/mesh_hang_watchdog.py"
python3 -m py_compile "$DASH_DIR/mesh_hang_watchdog.py"

mkdir -p "$DASH_DIR/secrets"
touch "$DASH_DIR/secrets/mesh_hang_autorestart"
chmod 644 "$DASH_DIR/secrets/mesh_hang_autorestart" || true

# Sofort: Cooldown leeren + einmal scharf laufen (--force --apply)
cd "$DASH_DIR"
python3 "$DASH_DIR/mesh_hang_watchdog.py" --force --apply
sleep 2

python3 -c '
import json, time
from pathlib import Path
base = Path("/home/fmg/prepper-dashboard")
d = json.loads((base/"mesh_hang_status.json").read_text())
c = json.loads((base/"mesh_hang_watchdog_cooldown.json").read_text()) if (base/"mesh_hang_watchdog_cooldown.json").exists() else {}
print("at=", d.get("at"))
print("dry_run=", d.get("dry_run"))
print("autorestart_enabled=", d.get("autorestart_enabled"))
print("actions=", d.get("actions"))
print("cooldown=", c)
for k,v in (d.get("meshes") or {}).items():
    print(k, "tele=", v.get("tele_state"), "stuck_sec=", v.get("stuck_sec"),
          "recommend=", v.get("recommend_restart"), "action=", v.get("action"),
          "attempts=", v.get("restart_attempts"))
'
echo "OK mesh-hang-retry applied COMMIT=$COMMIT"
echo "Regel: solange stuck → alle 25 Min erneut (max 4), danach 2h Pause; bei Erholung Zaehler reset."
