#!/bin/bash
set -euo pipefail
COMMIT="${COMMIT:-main}"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
echo "=== mesh-traceroute-remove loader COMMIT=$COMMIT ==="
if [[ "$COMMIT" == PLACEHOLDER* ]]; then echo "FAIL: COMMIT not pinned"; exit 1; fi
curl -fsSL "$BASE/apply-mesh-traceroute-remove.zb64" -o /tmp/apply-mesh-traceroute-remove.zb64
python3 - <<'PY'
import base64, zlib, pathlib
raw = zlib.decompress(base64.b64decode(pathlib.Path("/tmp/apply-mesh-traceroute-remove.zb64").read_text().strip()))
path = pathlib.Path("/tmp/apply-mesh-traceroute-remove.real.sh")
path.write_bytes(raw)
path.chmod(0o755)
print("decoded", path, "bytes", len(raw))
PY
grep -q "assert_send\|/send intact" /tmp/apply-mesh-traceroute-remove.real.sh \
  || { echo "FAIL: decoded traceroute-remove ohne /send-assert"; exit 1; }
exec bash /tmp/apply-mesh-traceroute-remove.real.sh
