#!/usr/bin/env bash
set -euo pipefail

BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/main"
APP="/home/fmg/prepper-dashboard"
TOOLS="$APP/tools"
TMP="/tmp/prepper-bakrestore-$$"
mkdir -p "$TMP" "$TOOLS"

curl -fsSL "$BASE/patch-backup-restore.py" -o "$TMP/patch-backup-restore.py"
curl -fsSL "$BASE/backup.sh" -o "$TMP/backup.sh"
curl -fsSL "$BASE/restore.sh" -o "$TMP/restore.sh"

install -m 0755 "$TMP/backup.sh" "$TOOLS/backup.sh"
install -m 0755 "$TMP/restore.sh" "$TOOLS/restore.sh"

cp -a "$APP/dashboard.py" "$APP/dashboard.py.bak-pre-bakrestore-$(date +%Y%m%d-%H%M%S)"
python3 "$TMP/patch-backup-restore.py" "$APP/dashboard.py"
python3 -m py_compile "$APP/dashboard.py"

if systemctl restart prepper-dashboard 2>/dev/null; then
  :
elif command -v sudo >/dev/null 2>&1; then
  sudo systemctl restart prepper-dashboard
else
  echo "WARN: could not restart prepper-dashboard" >&2
fi

sleep 1
systemctl is-active prepper-dashboard 2>/dev/null || sudo systemctl is-active prepper-dashboard
grep -n "bakRestore" "$APP/dashboard.py" | head -20
echo "OK bakRestore applied"
rm -rf "$TMP"
