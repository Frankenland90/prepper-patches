#!/bin/bash
set -euo pipefail
# LNG Ausspeise-Auslastung: Farbe umdrehen — hohe Ausspeisung = gruen (lngColorFlip).
# Nur lng_util_color + Legende. Smoke nur :8080. curl --compressed. /energie 302 ok.
# Rollback nur bei HTTP 500. Idempotent.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung, data_store.clear(),
# staleTsBoot, strom14dChart, navUnify und adsbMilThird unangetastet.
COMMIT="${COMMIT:-93ebe974f0d471bff61b91e99061b27ae31525d1}"
EXPECT_SHA="0b3d44d5eafd48230f0a15b3092ecabe575ff09bcb91b10980bc057ebfde6b8f"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"

if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 - smoke only :8080"
  exit 1
fi
if [[ "$COMMIT" == "REPLACE_ME" || "$COMMIT" == PLACEHOLDER* || "$EXPECT_SHA" == PLACEHOLDER* ]]; then
  echo "FAIL: pin not set"
  exit 1
fi
if [[ -z "$EXPECT_SHA" || ${#EXPECT_SHA} -ne 64 ]]; then
  echo "FAIL: EXPECT_SHA pin not set"
  exit 1
fi

echo "=== lngColorFlip apply COMMIT=$COMMIT PORT=$PORT ==="
curl -fsSL "$BASE/patch-lng-color-flip.py" -o /tmp/patch-lng-color-flip.py
echo "$EXPECT_SHA  /tmp/patch-lng-color-flip.py" | sha256sum -c -
grep -q 'lngColorFlip' /tmp/patch-lng-color-flip.py || { echo "FAIL: patch ohne lngColorFlip"; head -8 /tmp/patch-lng-color-flip.py; exit 1; }
head -1 /tmp/patch-lng-color-flip.py | grep -q python3 || { echo "FAIL: patch ist kein python"; exit 1; }
if grep -q 'PLACEHOLDER_WILL_REPLACE' /tmp/patch-lng-color-flip.py; then
  echo "FAIL: patch ist PLACEHOLDER"
  exit 1
fi
if grep -q 'Thread(target=update_all' /tmp/patch-lng-color-flip.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
if grep -nE '^[[:space:]]*data_store[[:space:]]*=' /tmp/patch-lng-color-flip.py; then
  echo "FAIL: patch schreibt data_store"
  exit 1
fi
if grep -q 'data_store.clear()' /tmp/patch-lng-color-flip.py; then
  echo "FAIL: patch ruft data_store.clear auf"
  exit 1
fi
python3 -m py_compile /tmp/patch-lng-color-flip.py
echo "OK lngColorFlip patch sha256 $EXPECT_SHA"
wc -c /tmp/patch-lng-color-flip.py

[[ -f "$DASH" ]] || { echo "FAIL: missing $DASH"; exit 1; }
cp -a "$DASH" "$DASH.bak-lngcolorflip-$TS"

guard_snap() {
  python3 - "$1" << 'GPY'
import pathlib, re, sys
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
keys = [
    "update_all()  # einmal beim Start",
    "staleTsBoot",
    "strom14dChart",
    "navUnify",
    "adsbMilThird",
    "data_store.clear()",
]
for k in keys:
    print("%s\t%d" % (k, t.count(k)))
n = 0
for line in t.splitlines():
    if re.match(r"\s*data_store\s*=", line):
        n += 1
print("data_store_assign\t%d" % n)
GPY
}

before=$(guard_snap "$DASH")
had_boot=0; grep -q 'update_all()  # einmal beim Start' "$DASH" && had_boot=1 || true
had_stale=0; grep -q 'staleTsBoot' "$DASH" && had_stale=1 || true
had_strom=0; grep -q 'strom14dChart' "$DASH" && had_strom=1 || true
had_nav=0; grep -q 'navUnify' "$DASH" && had_nav=1 || true
had_adsb=0; grep -q 'adsbMilThird' "$DASH" && had_adsb=1 || true
had_fein=0; grep -q 'pageFein' "$DASH" && had_fein=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-lngcolorflip-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-lng-color-flip.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch exit $rc"
  exit 1
fi
cp -a "$DASH" /tmp/dashboard.py.lngcolorflip-once
python3 /tmp/patch-lng-color-flip.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.lngcolorflip-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
echo "OK lngColorFlip idempotent"

after=$(guard_snap "$DASH")
if [[ "$before" != "$after" ]]; then
  echo "FAIL guards before:"
  printf '%s\n' "$before"
  echo "FAIL guards after:"
  printf '%s\n' "$after"
  rollback "guards geaendert"
  exit 1
fi
if [[ "$had_boot" == 1 ]]; then
  grep -q 'update_all()  # einmal beim Start' "$DASH" || { rollback "Boot-Pfad weg"; exit 1; }
fi
if [[ "$had_stale" == 1 ]]; then
  grep -q 'staleTsBoot' "$DASH" || { rollback "staleTsBoot weg"; exit 1; }
fi
if [[ "$had_strom" == 1 ]]; then
  grep -q 'strom14dChart' "$DASH" || { rollback "strom14dChart weg"; exit 1; }
fi
if [[ "$had_nav" == 1 ]]; then
  grep -q 'navUnify' "$DASH" || { rollback "navUnify weg"; exit 1; }
fi
if [[ "$had_adsb" == 1 ]]; then
  grep -q 'adsbMilThird' "$DASH" || { rollback "adsbMilThird weg"; exit 1; }
fi
if [[ "$had_fein" == 1 ]]; then
  grep -q 'pageFein' "$DASH" || { rollback "pageFein weg"; exit 1; }
fi
grep -q 'lngColorFlip' "$DASH" || { rollback "Marker lngColorFlip fehlt"; exit 1; }
grep -q 'grün ≥80' "$DASH" || { rollback "neue Legende fehlt"; exit 1; }
echo "OK guards boot=${had_boot} staleTsBoot=${had_stale} strom14dChart=${had_strom} navUnify=${had_nav} adsbMilThird=${had_adsb}"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
decode_http_body() {
  python3 - "$1" << 'DPY'
import gzip, pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.is_file():
    raise SystemExit(0)
b = p.read_bytes()
if len(b) >= 2 and b[0] == 0x1F and b[1] == 0x8B:
    p.write_bytes(gzip.decompress(b))
    print("NOTE: body war gzip, entpackt", p.name)
DPY
}

root=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  root=$(curl --compressed -s -o /tmp/lngflip_root.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || true)
  [[ -z "$root" ]] && root=000
  echo "try $i HTTP /=$root"
  if [[ "$root" == "200" || "$root" == "500" ]]; then
    break
  fi
  sleep 2
done
decode_http_body /tmp/lngflip_root.html || true
if [[ "$root" == "500" ]]; then
  rollback "HTTP / = 500"
  exit 1
fi
if [[ "$root" != "200" ]]; then
  echo "WARN: HTTP / = $root — Patch bleibt, kein Rollback"
else
  echo "OK HTTP / = 200"
fi

eng=$(curl --compressed -s -o /tmp/lngflip_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || true)
[[ -z "$eng" ]] && eng=000
decode_http_body /tmp/lngflip_energie.html || true
echo "HTTP /energie=$eng"
if [[ "$eng" == "500" ]]; then
  rollback "HTTP /energie = 500"
  exit 1
fi
if [[ "$eng" == "302" || "$eng" == "301" || "$eng" == "308" ]]; then
  echo "OK /energie $eng (redirect)"
fi

if [[ "$eng" == "200" ]] && grep -qE 'lngColorFlip|grün ≥80' /tmp/lngflip_energie.html; then
  echo "OK /energie zeigt neue LNG-Farblegende"
elif [[ "$root" == "200" ]] && grep -q 'grün ≥80' /tmp/lngflip_root.html; then
  echo "OK / zeigt neue LNG-Farblegende"
fi

echo "OK lngColorFlip applied COMMIT=$COMMIT PORT=$PORT"
echo "OK LNG: gruen >=80%, gelb >=50%, rot <50% (hohe Ausspeisung = gut)"
