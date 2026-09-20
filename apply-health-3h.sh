#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"

curl -fsSL "$BASE/health_check.py" -o /tmp/health_check.py
curl -fsSL "$BASE/prepper-health.timer" -o /tmp/prepper-health.timer
curl -fsSL "$BASE/patch-health-ui.py" -o /tmp/patch-health-ui.py

# backup
cp -a "$DASH_DIR/health_check.py" "$DASH_DIR/health_check.py.bak-health3h-$(date +%Y%m%d-%H%M%S)"
install -m 0755 /tmp/health_check.py "$DASH_DIR/health_check.py"

python3 /tmp/patch-health-ui.py "$DASH"
python3 -m py_compile "$DASH"

# timer (needs sudo)
sudo cp /tmp/prepper-health.timer /etc/systemd/system/prepper-health.timer
sudo systemctl daemon-reload
sudo systemctl enable --now prepper-health.timer
sudo systemctl restart prepper-health.timer

# einmal jetzt laufen lassen
sudo systemctl start prepper-health.service || true
sleep 2

# dashboard neu laden Label
sudo systemctl restart prepper-dashboard || true
sleep 1
systemctl is-active prepper-dashboard prepper-health.timer prepper-watchdog.timer || true
systemctl list-timers --all | grep -Ei 'prepper-health|prepper-watch' || true
echo "--- PAGES ---"
grep -A20 '^PAGES' "$DASH_DIR/health_check.py" | head -25
echo "--- score ---"
python3 -c "import json; d=json.load(open('$DASH_DIR/health_status.json')); print(d.get('at'), d.get('score'), '/', d.get('max'), 'ok=', d.get('ok')); print([i['id'] for i in d.get('items',[]) if i['id'].startswith('page_')])"
echo "OK health3h applied"
