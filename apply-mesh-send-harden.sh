#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
echo "=== mesh-send-harden loader COMMIT=$COMMIT ==="
if [[ "$COMMIT" == PLACEHOLDER* ]]; then echo "FAIL: COMMIT not pinned"; exit 1; fi
curl -fsSL "$BASE/apply-mesh-send-harden.zb64" -o /tmp/apply-mesh-send-harden.zb64
python3 - <<'PY'
import base64, zlib, pathlib
raw = zlib.decompress(base64.b64decode(pathlib.Path("/tmp/apply-mesh-send-harden.zb64").read_text().strip()))
path = pathlib.Path("/tmp/apply-mesh-send-harden.real.sh")
path.write_bytes(raw)
path.chmod(0o755)
print("decoded", path, "bytes", len(raw))
PY
grep -q "meshSendStable\|mesh-send-harden apply" /tmp/apply-mesh-send-harden.real.sh \
  || { echo "FAIL: decoded send-harden ohne meshSendStable"; exit 1; }
exec bash /tmp/apply-mesh-send-harden.real.sh
