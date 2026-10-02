#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-REPLACE_ME}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned"; exit 1
fi
echo "=== mesh-stability loader COMMIT=$COMMIT ==="
curl -fsSL "$BASE/apply-mesh-stability.zb64.p0" -o /tmp/apply-mesh-stability.zb64.p0
curl -fsSL "$BASE/apply-mesh-stability.zb64.p1" -o /tmp/apply-mesh-stability.zb64.p1
python3 - <<'PY'
import base64, zlib, pathlib
p0 = pathlib.Path("/tmp/apply-mesh-stability.zb64.p0").read_text().strip()
p1 = pathlib.Path("/tmp/apply-mesh-stability.zb64.p1").read_text().strip()
raw = zlib.decompress(base64.b64decode(p0 + p1))
path = pathlib.Path("/tmp/apply-mesh-stability.real.sh")
path.write_bytes(raw)
path.chmod(0o755)
print("decoded", path, "bytes", len(raw))
PY
grep -q "mesh-stability apply" /tmp/apply-mesh-stability.real.sh \
  || { echo "FAIL: decoded apply ohne mesh-stability"; head -5 /tmp/apply-mesh-stability.real.sh; exit 1; }
exec bash /tmp/apply-mesh-stability.real.sh
