#!/usr/bin/env bash
set -euo pipefail

# Pin / override: COMMIT=abc123 bash apply-...  or default main
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
APP="/home/fmg/prepper-dashboard"
TOOLS="$APP/tools"
DASH="$APP/dashboard.py"
TMP="/tmp/prepper-bakrestore-$$"
mkdir -p "$TMP" "$TOOLS"

echo "=== bakRestore apply COMMIT=$COMMIT ==="

die() { echo "ERR: $*" >&2; exit 1; }

# Prefer single file; fall back to part0..partN assembly
: > "$TMP/patch-backup-restore.py"
if curl -fsSL "$BASE/patch-backup-restore.py" -o "$TMP/patch-single.py" 2>/dev/null; then
  BYTES=$(wc -c < "$TMP/patch-single.py")
  if [[ "$BYTES" -ge 5000 ]] && ! grep -q '^PLACEHOLDER$' "$TMP/patch-single.py"; then
    cp "$TMP/patch-single.py" "$TMP/patch-backup-restore.py"
    echo "OK single patcher $BYTES bytes"
  fi
fi
if [[ ! -s "$TMP/patch-backup-restore.py" ]] || [[ $(wc -c < "$TMP/patch-backup-restore.py") -lt 5000 ]]; then
  if curl -fsSL "$BASE/patch-backup-restore.zb64" -o "$TMP/patch.zb64" 2>/dev/null; then
    echo "INFO: decoding patch-backup-restore.zb64…"
    python3 - "$TMP/patch.zb64" "$TMP/patch-backup-restore.py" <<'PYDEC'
import sys, base64, zlib
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "r", encoding="ascii").read().strip()
open(dst, "wb").write(zlib.decompress(base64.b64decode(data)))
PYDEC
  fi
fi
if [[ ! -s "$TMP/patch-backup-restore.py" ]] || [[ $(wc -c < "$TMP/patch-backup-restore.py") -lt 5000 ]]; then
  echo "INFO: assembling patcher from parts…"
  : > "$TMP/patch-backup-restore.py"
  if curl -fsSL "$BASE/patch-backup-restore.parts" -o "$TMP/parts" 2>/dev/null; then
    while IFS= read -r part; do
      [[ -z "$part" ]] && continue
      curl -fsSL "$BASE/$part" >> "$TMP/patch-backup-restore.py" || die "curl $part failed"
    done < "$TMP/parts"
  else
    for i in 0 1 2 3 4 5 6 7 8 9; do
      if curl -fsSL "$BASE/patch-backup-restore.part$i" >> "$TMP/patch-backup-restore.py" 2>/dev/null; then
        :
      else
        break
      fi
    done
  fi
fi

BYTES=$(wc -c < "$TMP/patch-backup-restore.py")
if [[ "$BYTES" -lt 5000 ]]; then
  die "patch-backup-restore.py too small ($BYTES bytes) — PLACEHOLDER or bad COMMIT?"
fi
if grep -q '^PLACEHOLDER$' "$TMP/patch-backup-restore.py" 2>/dev/null; then
  die "patch-backup-restore.py is PLACEHOLDER"
fi
grep -q 'bakRestore' "$TMP/patch-backup-restore.py" || die "patch without bakRestore marker"
grep -q 'doPrepperBackup' "$TMP/patch-backup-restore.py" || die "patch without doPrepperBackup"
python3 -m py_compile "$TMP/patch-backup-restore.py" || die "patch py_compile failed"
echo "OK patcher $BYTES bytes"

curl -fsSL "$BASE/backup.sh" -o "$TMP/backup.sh"
curl -fsSL "$BASE/restore.sh" -o "$TMP/restore.sh"
# Always (re)install tools executable
install -m 0755 "$TMP/backup.sh" "$TOOLS/backup.sh"
install -m 0755 "$TMP/restore.sh" "$TOOLS/restore.sh"
echo "OK tools installed: $TOOLS/backup.sh $TOOLS/restore.sh"

[[ -f "$DASH" ]] || die "missing $DASH"

verify_dash() {
  local f="$1"
  local ok=1
  for needle in "doPrepperBackup" "/api/backup" "/* bakRestore */" "bakLabel"; do
    if grep -qF "$needle" "$f"; then
      echo "OK verify: $needle"
    else
      echo "FAIL verify: missing $needle"
      ok=0
    fi
  done
  if grep -qF "api_backup_restore" "$f" || grep -qF "/api/backup/restore" "$f"; then
    echo "OK verify: api_backup_restore|/api/backup/restore"
  else
    echo "FAIL verify: missing api_backup_restore|/api/backup/restore"
    ok=0
  fi
  if [[ -x "$TOOLS/backup.sh" ]]; then
    echo "OK verify: tools/backup.sh executable"
  else
    echo "FAIL verify: tools/backup.sh missing or not executable"
    ok=0
  fi
  if [[ -x "$TOOLS/restore.sh" ]]; then
    echo "OK verify: tools/restore.sh executable"
  else
    echo "FAIL verify: tools/restore.sh missing or not executable"
    ok=0
  fi
  return $((1 - ok))
}

needs_force=0
if grep -qF "/* bakRestore */" "$DASH" 2>/dev/null; then
  if ! verify_dash "$DASH" >/tmp/bakrestore-preverify-$$.txt 2>&1; then
    needs_force=1
    echo "WARN: /* bakRestore */ present but verification FAIL — FORCE rebuild"
    cat /tmp/bakrestore-preverify-$$.txt || true
  else
    echo "INFO: marker present and verify OK — patcher will still run (additive/idempotent)"
  fi
fi
rm -f /tmp/bakrestore-preverify-$$.txt

if [[ "$needs_force" -eq 1 ]]; then
  restored=""
  shopt -s nullglob
  for bak in $(ls -1t "$APP"/dashboard.py.bak-pre-bakrestore-* 2>/dev/null); do
    if grep -qF 'def api_backup_run():' "$bak" \
      && ! grep -qF 'def api_backup_run(label' "$bak" \
      && grep -qF 'id="backupBox"' "$bak" \
      && ! grep -qF 'bakLabel' "$bak"; then
      restored=$bak
      break
    fi
  done
  shopt -u nullglob
  if [[ -n "$restored" ]]; then
    echo "FORCE restore $DASH <- $restored"
    cp -a "$restored" "$DASH"
  else
    echo "ERR: bakRestore broken and no suitable dashboard.py.bak-pre-bakrestore-* with OLD anchors" >&2
    echo "ERR: Need unpatched base containing: def api_backup_run(): (no label) and backupBox without bakLabel" >&2
    exit 1
  fi
fi

TS="$(date +%Y%m%d-%H%M%S)"
cp -a "$DASH" "$APP/dashboard.py.bak-pre-bakrestore-$TS"
python3 "$TMP/patch-backup-restore.py" "$DASH"
python3 -m py_compile "$DASH" || die "dashboard.py py_compile failed after patch"

echo "=== post-apply verification ==="
if ! verify_dash "$DASH"; then
  die "verification failed after patch"
fi

if systemctl restart prepper-dashboard 2>/dev/null; then
  :
elif command -v sudo >/dev/null 2>&1; then
  sudo systemctl restart prepper-dashboard
else
  echo "WARN: could not restart prepper-dashboard" >&2
fi

sleep 1
systemctl is-active prepper-dashboard 2>/dev/null || sudo systemctl is-active prepper-dashboard || true

echo "=== bakRestore markers (grep) ==="
grep -n "bakRestore\|doPrepperBackup\|api_backup_restore\|bakLabel" "$DASH" | head -30 || true
echo "OK bakRestore applied (COMMIT=$COMMIT)"
rm -rf "$TMP"
