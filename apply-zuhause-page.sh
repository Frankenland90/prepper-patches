#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

echo "=== zuhause-page apply COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "PLACEHOLDER"* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi

curl -fsSL "$BASE/zuhause.py" -o /tmp/zuhause.py
curl -fsSL "$BASE/patch-zuhause-page.py" -o /tmp/patch-zuhause-page.py
curl -fsSL "$BASE/health_check.py" -o /tmp/health_check.py

grep -q 'zuhausePage' /tmp/zuhause.py || { echo "FAIL: kein zuhausePage in zuhause.py"; exit 1; }
grep -q 'Käswasser' /tmp/zuhause.py || { echo "FAIL: kein Käswasser"; exit 1; }
grep -q 'page_zuhause' /tmp/patch-zuhause-page.py || { echo "FAIL: kein page_zuhause"; exit 1; }
grep -q '/zuhause' /tmp/health_check.py || { echo "FAIL: health ohne /zuhause"; exit 1; }
grep -q 'PLACEHOLDER' /tmp/zuhause.py && { echo "FAIL PLACEHOLDER zuhause"; exit 1; } || true

cp -a "$DASH_DIR/zuhause.py" "$DASH_DIR/zuhause.py.bak-$TS" 2>/dev/null || true
install -m 0644 /tmp/zuhause.py "$DASH_DIR/zuhause.py"
python3 -m py_compile "$DASH_DIR/zuhause.py"

python3 /tmp/patch-zuhause-page.py "$DASH_DIR/dashboard.py"
python3 -m py_compile "$DASH_DIR/dashboard.py"

cp -a "$DASH_DIR/health_check.py" "$DASH_DIR/health_check.py.bak-zuhause-$TS" 2>/dev/null || true
install -m 0644 /tmp/health_check.py "$DASH_DIR/health_check.py"
python3 -m py_compile "$DASH_DIR/health_check.py"

cd "$DASH_DIR"
python3 -c 'import zuhause; d=zuhause.load_or_refresh(force=True); w=d["waste"]; print("waste_ok", w.get("ok"), "items", len(w.get("items") or []), "events", w.get("count_events"));
[print(i.get("label"), i.get("weekday"), i.get("date_fmt"), i.get("until"), i.get("color")) for i in (w.get("items") or [])]'

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true
sleep 3
systemctl is-active prepper-dashboard.service 2>/dev/null \
  || systemctl is-active prepper-dashboard \
  || true

code=$(curl -s -o /tmp/zuhause.html -w "%{http_code}" http://127.0.0.1:5000/zuhause || echo 0)
echo "HTTP /zuhause=$code"
grep -n 'Zuhause\|Restmüll\|Tierklinik\|Käswasser' /tmp/zuhause.html | head -15 || true
grep -n 'href="/zuhause"' "$DASH_DIR/dashboard.py" | head -5
echo "OK zuhause-page applied COMMIT=$COMMIT"
