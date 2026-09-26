#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== mesh-hang-autorestart apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/mesh-hang-watchdog.service" -o /tmp/mesh-hang-watchdog.service
curl -fsSL "$BASE/mesh_hang_watchdog.py" -o /tmp/mesh_hang_watchdog.py

grep -q -- '--apply' /tmp/mesh-hang-watchdog.service || {
  echo "FAIL: service ohne --apply"; head -20 /tmp/mesh-hang-watchdog.service; exit 1
}
grep -qE 'stuck.*STUCK_ACTION_SEC|Telemetrie-Hang' /tmp/mesh_hang_watchdog.py || {
  echo "FAIL: watchdog ohne Stuck-alone Restart"; head -8 /tmp/mesh_hang_watchdog.py; exit 1
}
grep -q 'sudo' /tmp/mesh_hang_watchdog.py || {
  echo "FAIL: watchdog ohne sudo restart"; exit 1
}
grep -q 'PLACEHOLDER' /tmp/mesh-hang-watchdog.service /tmp/mesh_hang_watchdog.py \
  && { echo "FAIL PLACEHOLDER"; exit 1; } || true
wc -c /tmp/mesh-hang-watchdog.service /tmp/mesh_hang_watchdog.py

# Backup
cp -a "$DASH_DIR/mesh_hang_watchdog.py" \
  "$DASH_DIR/mesh_hang_watchdog.py.bak-autorestart-$TS" 2>/dev/null || true
sudo cp -a /etc/systemd/system/mesh-hang-watchdog.service \
  "/etc/systemd/system/mesh-hang-watchdog.service.bak-autorestart-$TS" 2>/dev/null || true

install -m 0644 /tmp/mesh_hang_watchdog.py "$DASH_DIR/mesh_hang_watchdog.py"
sudo install -m 0644 /tmp/mesh-hang-watchdog.service /etc/systemd/system/mesh-hang-watchdog.service

# Flag sicherstellen (ohne Flag bleibt Detect-only trotz --apply)
mkdir -p "$DASH_DIR/secrets"
touch "$DASH_DIR/secrets/mesh_hang_autorestart"
chmod 644 "$DASH_DIR/secrets/mesh_hang_autorestart" || true

sudo systemctl daemon-reload
sudo systemctl enable mesh-hang-watchdog.timer
sudo systemctl restart mesh-hang-watchdog.timer
# einmal sofort laufen lassen (scharf)
sudo systemctl start mesh-hang-watchdog.service || true
sleep 2

systemctl is-active mesh-hang-watchdog.timer || true
systemctl cat mesh-hang-watchdog.service | grep -E 'ExecStart|apply' || true

python3 -c '
import json
from pathlib import Path
p=Path("/home/fmg/prepper-dashboard/mesh_hang_status.json")
d=json.loads(p.read_text()) if p.exists() else {}
print("dry_run=", d.get("dry_run"))
print("autorestart_enabled=", d.get("autorestart_enabled"))
print("flag=", d.get("flag"))
for k,v in (d.get("meshes") or {}).items():
    print(k, "tele=", v.get("tele_state"), "stuck_sec=", v.get("stuck_sec"),
          "recommend=", v.get("recommend_restart"), "action=", v.get("action"))
print("actions=", d.get("actions"))
'

# Expect dry_run false when --apply + flag
python3 -c '
import json
from pathlib import Path
d=json.loads(Path("/home/fmg/prepper-dashboard/mesh_hang_status.json").read_text())
assert d.get("autorestart_enabled") is True, "FAIL: autorestart_enabled nicht true"
assert d.get("dry_run") is False, "FAIL: dry_run noch true — service ohne --apply?"
print("OK mesh-hang-autorestart scharf COMMIT=" + __import__("os").environ.get("COMMIT","?"))
'

echo "OK mesh-hang-autorestart applied COMMIT=$COMMIT"
echo "Hinweis: Restart erst nach ~45 Min Telemetrie-Stuck (Cooldown). Flag loeschen = wieder Detect-only."
