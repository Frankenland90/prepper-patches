#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH="${DASH:-/home/fmg/prepper-dashboard/dashboard.py}"
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi
curl -fsSL "$BASE/patch-adsb-notlage-sq3.py" -o /tmp/patch-adsb-notlage-sq3.py
curl -fsSL "$BASE/patch-adsb-notlage-sq3.zb64" -o /tmp/patch-adsb-notlage-sq3.zb64
# stub + zb64 already siblings in /tmp — do NOT cp same path to itself
test -f /tmp/patch-adsb-notlage-sq3.py
test -f /tmp/patch-adsb-notlage-sq3.zb64
grep -q 'adsbNotlageSq3' /tmp/patch-adsb-notlage-sq3.py
grep -q PLACEHOLDER /tmp/patch-adsb-notlage-sq3.py && { echo FAIL PLACEHOLDER; exit 1; } || true
# expand sanity
python3 -c 'import base64,zlib,pathlib; b=zlib.decompress(base64.b64decode(pathlib.Path("/tmp/patch-adsb-notlage-sq3.zb64").read_text().strip())); assert b"adsbNotlageSq3" in b; print("zb64 ok", len(b))'
wc -c /tmp/patch-adsb-notlage-sq3.py /tmp/patch-adsb-notlage-sq3.zb64
export COMMIT
python3 /tmp/patch-adsb-notlage-sq3.py "$DASH"
python3 /tmp/patch-adsb-notlage-sq3.py "$DASH"
python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard || true
sleep 8
systemctl is-active prepper-dashboard || true
grep -n "adsbNotlageSq3\|0001\|4000\|7000\|QRA\|TIEFFLUG\|Letzte Notfälle\|CODES ·\|e\.flag" "$DASH" | head -40
grep -q '"0001": "QRA"' "$DASH"
grep -q '"4000": "TIEFFLUG"' "$DASH"
grep -q '"7000": "VFR"' "$DASH"
grep -q '{{ e.alt }}&nbsp;m' "$DASH"
grep -q 'e.flag' "$DASH"
if grep -q 'CODES · OHNE KUNSTFLUG' "$DASH"; then
  echo "FAIL: CODES-Header noch vorhanden"; exit 1
fi
if python3 -c "
import re
from pathlib import Path
d=re.search(r'ADSB_SPECIAL_SQUAWKS\s*=\s*\{.*?\}', Path('$DASH').read_text(), re.S).group(0)
raise SystemExit(0 if '\"0027\"' not in d else 1)
"; then :; else echo "FAIL: 0027 Kunstflug in SPECIAL"; exit 1; fi
echo "OK adsbNotlageSq3 applied COMMIT=$COMMIT"
