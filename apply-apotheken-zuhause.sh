#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== apotheken-zuhause apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/patch-apotheken-zuhause.zb64" -o /tmp/patch-apotheken-zuhause.zb64
python3 -c 'import base64,pathlib,zlib; zb=pathlib.Path("/tmp/patch-apotheken-zuhause.zb64").read_text().strip(); pathlib.Path("/tmp/patch-apotheken-zuhause.py").write_bytes(zlib.decompress(base64.b64decode(zb))); print("expanded", pathlib.Path("/tmp/patch-apotheken-zuhause.py").stat().st_size)'

grep -q 'apoZuhause' /tmp/patch-apotheken-zuhause.py \
  || { echo "FAIL: patch ohne apoZuhause"; exit 1; }
grep -q 'patch_zuhause' /tmp/patch-apotheken-zuhause.py \
  || { echo "FAIL: patch ohne patch_zuhause"; exit 1; }
grep -q 'PLACEHOLDER_WILL_REPLACE' /tmp/patch-apotheken-zuhause.py \
  && { echo "FAIL PLACEHOLDER stub"; exit 1; } || true
wc -c /tmp/patch-apotheken-zuhause.py /tmp/patch-apotheken-zuhause.zb64

grep -q 'def fetch_apotheken_notdienst(' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: fetch_apotheken_notdienst fehlt in dashboard.py — zuerst Apotheken-Patch"; exit 1; }
grep -q 'def page_zuhause(' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: page_zuhause fehlt — zuerst zuhause-page apply"; exit 1; }
[ -f "$DASH_DIR/zuhause.py" ] \
  || { echo "FAIL: zuhause.py fehlt"; exit 1; }
grep -q 'Müllabfuhr' "$DASH_DIR/zuhause.py" \
  || { echo "FAIL: kein Müllabfuhr in zuhause.py"; exit 1; }

cp -a "$DASH_DIR/dashboard.py" "$DASH_DIR/dashboard.py.bak-apozuhause-$TS"
cp -a "$DASH_DIR/zuhause.py" "$DASH_DIR/zuhause.py.bak-apozuhause-$TS"

python3 /tmp/patch-apotheken-zuhause.py "$DASH_DIR"
python3 /tmp/patch-apotheken-zuhause.py "$DASH_DIR"

python3 -m py_compile "$DASH_DIR/dashboard.py"
python3 -m py_compile "$DASH_DIR/zuhause.py"

grep -q 'apoZuhause' "$DASH_DIR/zuhause.py" \
  || { echo "FAIL: Marker fehlt in zuhause.py"; exit 1; }
grep -q 'apoZuhause' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: Marker fehlt in dashboard.py"; exit 1; }
grep -q 'apotheken_notdienst=apo' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: Route übergibt kein apotheken_notdienst"; exit 1; }
grep -q 'def fetch_apotheken_notdienst(' "$DASH_DIR/dashboard.py" \
  || { echo "FAIL: fetch entfernt (soll bleiben)"; exit 1; }
if grep -q 'class="apo-wrap"' "$DASH_DIR/dashboard.py"; then
  echo "FAIL: apo-wrap Card noch in dashboard.py (Medizin)"
  exit 1
fi
grep -q '<!-- apoZuhause -->' "$DASH_DIR/zuhause.py" \
  || { echo "FAIL: kein Apotheken-Tile in zuhause.py"; exit 1; }

python3 -c "
from pathlib import Path
t = Path('$DASH_DIR/zuhause.py').read_text(encoding='utf-8')
i_m = t.find('<div class=\"title\">Müllabfuhr</div>')
i_a = t.find('<!-- apoZuhause -->')
i_t = t.find('<div class=\"title\">Tierkliniken</div>')
assert i_m > 0 and i_a > i_m and i_t > i_a, (i_m, i_a, i_t)
print('order OK: Müllabfuhr < Apotheken < Tierkliniken')
"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 3
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

code=$(curl -s -o /tmp/zuhause.html -w "%{http_code}" http://127.0.0.1:5000/zuhause || echo 0)
echo "HTTP /zuhause=$code"
grep -n 'Apotheken-Notdienst\|Müllabfuhr\|Tierklinik\|BLAK' /tmp/zuhause.html | head -20 || true

code_m=$(curl -s -o /tmp/medizin.html -w "%{http_code}" http://127.0.0.1:5000/medizin || echo 0)
echo "HTTP /medizin=$code_m"
if grep -q 'Apotheken-Notdienst' /tmp/medizin.html; then
  echo "WARN: Apotheken-Notdienst noch auf /medizin sichtbar"
else
  echo "OK: Apotheken-Notdienst nicht mehr auf /medizin"
fi

echo "OK apotheken-zuhause applied COMMIT=$COMMIT"
