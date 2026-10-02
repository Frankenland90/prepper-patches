#!/bin/bash
set -euo pipefail
# pageFein SAFE apply loader — fetches zlib+b64 body (PORT systemd/8080, never :5000).
COMMIT="${COMMIT:-680b69d4ba08fe2cc101f57c883afd537f6103a2}"
export COMMIT
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
echo "=== page-fein SAFE loader COMMIT=$COMMIT ==="
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* ]]; then
  echo "FAIL: COMMIT not pinned (got $COMMIT). Set COMMIT=<tip-sha>."
  exit 1
fi
curl -fsSL "$BASE/apply-page-fein.zb64.p0" -o /tmp/apply-page-fein.zb64.p0
curl -fsSL "$BASE/apply-page-fein.zb64.p1" -o /tmp/apply-page-fein.zb64.p1
python3 - <<'PY'
import base64, zlib, pathlib
p0 = pathlib.Path("/tmp/apply-page-fein.zb64.p0").read_text().strip()
p1 = pathlib.Path("/tmp/apply-page-fein.zb64.p1").read_text().strip()
raw = zlib.decompress(base64.b64decode(p0 + p1))
assert b"page-fein SAFE" in raw and b"NEVER smoke" in raw
assert b"PLACEHOLDER_LOAD" not in raw
path = pathlib.Path("/tmp/apply-page-fein.real.sh")
path.write_bytes(raw)
path.chmod(0o755)
print("decoded", path, "bytes", len(raw))
PY
grep -q "NEVER smoke" /tmp/apply-page-fein.real.sh \
  || { echo "FAIL: decoded apply missing NEVER smoke"; head -8 /tmp/apply-page-fein.real.sh; exit 1; }
exec bash /tmp/apply-page-fein.real.sh
