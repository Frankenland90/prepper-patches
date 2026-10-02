#!/bin/bash
set -euo pipefail
# Thin loader: unpack apply-nav-full3rows.zb64 from main, then exec body (navFull3v2 SAFE).
TIP_BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/main"
curl -fsSL "$TIP_BASE/apply-nav-full3rows.zb64" -o /tmp/apply-nav-full3rows.zb64
python3 -c 'import base64,zlib,pathlib; b=zlib.decompress(base64.b64decode(pathlib.Path("/tmp/apply-nav-full3rows.zb64").read_text().strip())); assert b"navFull3v2" in b and b"b7c3545bacb38c69532f0fe7446403d4dcafaa82" in b; pathlib.Path("/tmp/apply-nav-full3rows.body.sh").write_bytes(b); print("apply body ok", len(b))'
bash /tmp/apply-nav-full3rows.body.sh
