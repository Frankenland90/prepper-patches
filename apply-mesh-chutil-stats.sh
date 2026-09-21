#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
TS=$(date +%Y%m%d-%H%M%S)

curl -fsSL "$BASE/mesh_chutil.py" -o /tmp/mesh_chutil.py
curl -fsSL "$BASE/funk_health.py" -o /tmp/funk_health.py

for f in /tmp/mesh_chutil.py /tmp/funk_health.py; do
  if ! grep -q 'chutil' "$f"; then
    echo "FAIL: $f ohne chutil-Marker. COMMIT=$COMMIT"
    head -5 "$f"
    exit 1
  fi
done
# neue Features müssen da sein
grep -q 'peak_24h\|avg_24h\|threshold_streak\|Node-DB' /tmp/mesh_chutil.py /tmp/funk_health.py
wc -c /tmp/mesh_chutil.py /tmp/funk_health.py

cp -a "$DASH_DIR/mesh_chutil.py" "$DASH_DIR/mesh_chutil.py.bak-chutilstats-$TS"
cp -a "$DASH_DIR/funk_health.py" "$DASH_DIR/funk_health.py.bak-chutilstats-$TS"

install -m 0644 /tmp/mesh_chutil.py "$DASH_DIR/mesh_chutil.py"
install -m 0644 /tmp/funk_health.py "$DASH_DIR/funk_health.py"
python3 -m py_compile "$DASH_DIR/mesh_chutil.py" "$DASH_DIR/funk_health.py"

# Bridges neu: nächstes Sample inkl. nodedb/heard (min_gap 300 — Restart setzt Worker neu, Sample nach ~60s wenn Gap ok)
sudo systemctl restart mesh-bridge.service mesh-bridge-bayern.service prepper-dashboard
sleep 2
systemctl is-active mesh-bridge.service mesh-bridge-bayern.service prepper-dashboard || true

echo "--- Features ---"
grep -n 'avg_24h\|peak_7d\|threshold_streak\|Node-DB\|lastHeard' "$DASH_DIR/mesh_chutil.py" "$DASH_DIR/funk_health.py" | head -20

echo "--- warte Sample mit nodedb (max ~90s; min_gap kann blocken) ---"
ok=0
for i in $(seq 1 18); do
  sleep 5
  python3 - <<'PY' && ok=1 && break || true
import json
from pathlib import Path
for name in ("mesh1_chutil.json","mesh2_chutil.json"):
    p=Path("/home/fmg/prepper-dashboard")/name
    d=json.loads(p.read_text() or "[]")
    if not d: raise SystemExit(1)
    last=d[-1]
    print(name, "ch", last.get("ch_util"), "nodedb", last.get("nodedb"), "heard", last.get("heard_sec"), "t", last.get("t"))
    if last.get("nodedb") is None and "nodedb" not in last:
        raise SystemExit(1)
PY
  echo "… ($i/18)"
done
[ "$ok" = 1 ] || echo "WARN: nodedb noch nicht in Sample (min_gap 5 Min — Mittel/Peak/Hint wirken trotzdem auf History)"

echo "OK mesh-chutil-stats applied COMMIT=$COMMIT"
