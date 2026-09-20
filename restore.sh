#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERR: $*" >&2; exit 1; }

ID="${1:-}"
[[ -n "$ID" ]] || die "usage: restore.sh <id>  (e.g. prepper-20260920-140458-M)"
[[ "$ID" =~ ^prepper-[0-9]{8}-[0-9]{6}-[MA]$ ]] || die "invalid id: $ID"

APP="/home/fmg/prepper-dashboard"
DEST="/home/fmg/prepper-backups"
TGZ="${DEST}/${ID}.tgz"
TOOLS_DIR="${APP}/tools"
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="${APP}.bak-restore-${STAMP}"

[[ -f "$TGZ" ]] || die "missing archive: $TGZ"
[[ -s "$TGZ" ]] || die "empty archive: $TGZ"
tar -tzf "$TGZ" >/dev/null || die "tar -tzf failed for $TGZ"

svc() {
  local action="$1"
  if systemctl "$action" prepper-dashboard >/dev/null 2>&1; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo systemctl "$action" prepper-dashboard
    return $?
  fi
  return 1
}

svc_is_active() {
  if systemctl is-active --quiet prepper-dashboard 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo systemctl is-active --quiet prepper-dashboard 2>/dev/null; then
    return 0
  fi
  return 1
}

rollback() {
  echo "ERR: $1 — rolling back" >&2
  rm -rf "$APP" 2>/dev/null || true
  if [[ -d "$BAK" ]]; then
    mv "$BAK" "$APP" || echo "ERR: could not restore bak $BAK" >&2
  fi
  svc start || true
  exit 1
}

# 2) Safety backup with label pre-restore (before stopping service)
[[ -x "${TOOLS_DIR}/backup.sh" ]] || die "backup.sh missing/not executable at ${TOOLS_DIR}/backup.sh"
"${TOOLS_DIR}/backup.sh" M pre-restore || die "pre-restore backup failed"

# 3) Stop service
svc stop || die "systemctl stop prepper-dashboard failed"

# 4) Move current app aside
[[ -d "$APP" ]] || die "APP missing: $APP"
mv "$APP" "$BAK" || die "mv $APP -> $BAK failed"

# 5) Extract archive (creates /home/fmg/prepper-dashboard)
if ! tar -xzf "$TGZ" -C /home/fmg; then
  rollback "tar extract failed"
fi
[[ -d "$APP" ]] || rollback "extract did not create $APP"
[[ -f "$APP/dashboard.py" ]] || rollback "dashboard.py missing after extract"

# 6–7) Compile check; rollback on fail
if ! python3 -m py_compile "$APP/dashboard.py"; then
  rollback "py_compile dashboard.py failed"
fi

# Ensure tools are executable (restored tree may have older tools)
chmod +x "$APP/tools/"*.sh 2>/dev/null || true

# 8) Start + check active
svc start || die "systemctl start prepper-dashboard failed"
sleep 2
if ! svc_is_active; then
  die "prepper-dashboard not active after start"
fi

# 9) Optional HTTP probe — keep restored code even on WARN
CODE="000"
for url in "http://127.0.0.1:5000/pi" "http://127.0.0.1:5000/"; do
  CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null || echo "000")"
  if [[ "$CODE" == "200" ]]; then
    break
  fi
done
if [[ "$CODE" != "200" ]]; then
  echo "WARN: HTTP check not 200 (got ${CODE}) — restored code left in place"
fi

# 10) Keep only the latest .bak-restore-*
shopt -s nullglob
for old in /home/fmg/prepper-dashboard.bak-restore-*; do
  [[ "$old" == "$BAK" ]] && continue
  rm -rf "$old"
done
shopt -u nullglob

echo "OK restore ${ID} (bak kept: $(basename "$BAK"))"
exit 0
