#!/bin/bash
set -u
MODE="${1:-A}"
[[ "$MODE" == "M" || "$MODE" == "A" ]] || MODE="A"
RAW_LABEL="${2:-}"
# sanitize: alnum, dash, underscore, max 40
LABEL="$(printf '%s' "$RAW_LABEL" | tr -cd 'A-Za-z0-9_-' | cut -c1-40)"
if [[ -z "$LABEL" ]]; then
  if [[ "$MODE" == "A" ]]; then LABEL="auto"; else LABEL="manual"; fi
fi

APP="/home/fmg/prepper-dashboard"
DEST="/home/fmg/prepper-backups"
mkdir -p "$DEST"
STAMP="$(date +%Y%m%d-%H%M%S)"
BASE="prepper-${STAMP}-${MODE}"
FILE="${DEST}/${BASE}.tgz"
META="${DEST}/${BASE}.json"
OK=0
ERR=""
HASH=""

if tar \
  --exclude="${APP}/venv" \
  --exclude="${APP}/__pycache__" \
  --exclude="${APP}/backups" \
  --exclude="*.zim" \
  -C /home/fmg \
  -czf "$FILE" \
  prepper-dashboard \
  2>/tmp/prepper-backup.err
then
  if tar -tzf "$FILE" >/dev/null 2>&1 && [[ -s "$FILE" ]]; then
    OK=1
    HASH="$(sha256sum "$APP/dashboard.py" 2>/dev/null | awk '{print substr($1,1,12)}')"
  else
    ERR="verify"
  fi
else
  ERR="tar"
fi

python3 - "$META" "$FILE" "$MODE" "$OK" "$ERR" "$LABEL" "$HASH" "$BASE" << 'PY'
import json, os, sys, datetime
meta, file, mode, ok, err, label, hash_, base = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1",
    sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8],
)
now = datetime.datetime.now()
wd = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][now.weekday()]
d = {
    "ok": ok,
    "mode": mode,
    "err": err or None,
    "file": os.path.basename(file) if os.path.exists(file) else None,
    "bytes": os.path.getsize(file) if os.path.exists(file) else 0,
    "at": now.strftime("%d.%m.%Y %H:%M:%S"),
    "wd": wd,
    "iso": now.isoformat(timespec="seconds"),
    "label": label or None,
    "hash": hash_ or None,
    "id": base,
}
with open(meta, "w") as f:
    json.dump(d, f)
if ok:
    print("OK " + d["at"] + " " + mode + " label=" + (label or "-") + " hash=" + (hash_ or "????"))
else:
    print("FAIL " + d["at"] + " " + mode + " err=" + (err or "?"))
PY

# Rotation: neueste 10 Paare behalten
python3 - "$DEST" << 'PY'
import os, sys, glob
dest = sys.argv[1]
tgz = sorted(glob.glob(os.path.join(dest, "prepper-*.tgz")), key=os.path.getmtime, reverse=True)
for old in tgz[10:]:
    base = old[:-4]
    for p in (old, base + ".json"):
        try:
            os.remove(p)
        except FileNotFoundError:
            pass
PY

if [[ "$OK" -eq 1 ]]; then
  exit 0
fi
exit 1
