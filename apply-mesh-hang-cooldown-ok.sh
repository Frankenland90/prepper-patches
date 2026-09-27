#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== mesh-hang-cooldown-ok apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/mesh_hang_watchdog.py" -o /tmp/mesh_hang_watchdog.py
grep -q 'meshHangCooldownOk' /tmp/mesh_hang_watchdog.py || { echo "FAIL: kein meshHangCooldownOk"; exit 1; }
grep -q 'restart_failed' /tmp/mesh_hang_watchdog.py || { echo "FAIL: kein restart_failed"; exit 1; }
grep -q 'PLACEHOLDER' /tmp/mesh_hang_watchdog.py && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/mesh_hang_watchdog.py

cp -a "$DASH_DIR/mesh_hang_watchdog.py" "$DASH_DIR/mesh_hang_watchdog.py.bak-cooldownok-$TS" 2>/dev/null || true
install -m 0644 /tmp/mesh_hang_watchdog.py "$DASH_DIR/mesh_hang_watchdog.py"
python3 -m py_compile "$DASH_DIR/mesh_hang_watchdog.py"

cd "$DASH_DIR"
python3 "$DASH_DIR/mesh_hang_watchdog.py" --apply
sleep 1
python3 -c '
import json
from pathlib import Path
base = Path("/home/fmg/prepper-dashboard")
d = json.loads((base/"mesh_hang_status.json").read_text())
print("at=", d.get("at"), "dry_run=", d.get("dry_run"), "autorestart=", d.get("autorestart_enabled"))
for k,v in (d.get("meshes") or {}).items():
    print(k, "tele=", v.get("tele_state"), "stuck=", v.get("stuck_sec"), "action=", v.get("action"), "attempts=", v.get("restart_attempts"))
'
grep -n 'meshHangCooldownOk\|restart_failed' "$DASH_DIR/mesh_hang_watchdog.py" | head -5
echo "OK mesh-hang-cooldown-ok applied COMMIT=$COMMIT"
echo "Regel: Cooldown/Zaehler nur wenn mind. ein systemctl restart gelungen ist."
