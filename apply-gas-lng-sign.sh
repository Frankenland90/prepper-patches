#!/bin/bash
set -euo pipefail
# Gas- und LNG-Speicher: Vorzeichen Frank, Bestand gasInStorage (gasLngSign).
# fetch_gas, fetch_lng und die zwei Kacheln. Smoke nur :8080. curl --compressed.
# / 200, /energie 302 ok. Rollback nur bei HTTP 500. Idempotent.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung, data_store.clear(),
# staleTsBoot, strom14dChart, navUnify, adsbMilThird und lngColorFlip unangetastet.
# Der Patch erwaehnt data_store.clear() und data_store = { nur im Kommentar/Self-Check.
# Gezaehlt wird nur ein echter AST-Call bzw. eine echte Zuweisung.
COMMIT="${COMMIT:-f2a0d4b158d939059f47d1766587b0b994cb1b9b}"
EXPECT_SHA="b5eb75500825eeccace9ec531e2c1d6366542fd752355891dfd00428e6a0f93a"
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

echo "=== gasLngSign apply COMMIT=$COMMIT PORT=$PORT ==="
rm -f /tmp/patch-gas-lng-sign.py
for i in 0 1 2; do
  curl -fsSL "$BASE/patch-gas-lng-sign.py.b64.p${i}" -o "/tmp/gaslng.p${i}.b64"
  base64 -d "/tmp/gaslng.p${i}.b64" >> /tmp/patch-gas-lng-sign.py
done
echo "$EXPECT_SHA  /tmp/patch-gas-lng-sign.py" | sha256sum -c -
grep -q 'gasLngSign' /tmp/patch-gas-lng-sign.py || { echo "FAIL: patch ohne gasLngSign"; head -8 /tmp/patch-gas-lng-sign.py; exit 1; }
head -1 /tmp/patch-gas-lng-sign.py | grep -q python3 || { echo "FAIL: patch ist kein python"; exit 1; }
if grep -q 'PLACEHOLDER_WILL_REPLACE' /tmp/patch-gas-lng-sign.py; then
  echo "FAIL: patch ist PLACEHOLDER"
  exit 1
fi
if grep -q 'Thread(target=update_all' /tmp/patch-gas-lng-sign.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
# Nur echter Call und echte Zuweisung (AST). Docstring, Kommentar oder
# Self-Check-String wie data_store.clear() bzw. data_store = { ist kein Treffer.
guard_rc=0
set +e
python3 - /tmp/patch-gas-lng-sign.py << 'GUARDPY'
import ast, pathlib, sys
path = sys.argv[1]
tree = ast.parse(pathlib.Path(path).read_text(encoding="utf-8"), filename=path)
hit = False
def name_is(node):
    return isinstance(node, ast.Name) and node.id == "data_store"
for node in ast.walk(tree):
    if isinstance(node, ast.Assign):
        for t in node.targets:
            if name_is(t):
                print("%s:%s: data_store assignment" % (path, node.lineno))
                hit = True
    elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
        if name_is(node.target):
            print("%s:%s: data_store assignment" % (path, node.lineno))
            hit = True
    elif isinstance(node, ast.Call):
        func = node.func
        if (
            isinstance(func, ast.Attribute)
            and func.attr == "clear"
            and isinstance(func.value, ast.Name)
            and func.value.id == "data_store"
        ):
            print("%s:%s: data_store.clear()" % (path, node.lineno))
            hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
guard_rc=$?
set -e
if [[ "$guard_rc" -eq 3 ]]; then
  echo "FAIL: patch schreibt data_store oder ruft data_store.clear auf"
  exit 1
fi
if [[ "$guard_rc" -ne 0 ]]; then
  echo "FAIL: clear-guard konnte Patch nicht parsen"
  exit 1
fi
echo "OK clear-guard AST (kein data_store.clear, keine data_store-Zuweisung)"
python3 -m py_compile /tmp/patch-gas-lng-sign.py
echo "OK gasLngSign patch sha256 $EXPECT_SHA"
wc -c /tmp/patch-gas-lng-sign.py

[[ -f "$DASH" ]] || { echo "FAIL: missing $DASH"; exit 1; }
cp -a "$DASH" "$DASH.bak-gaslngsign-$TS"

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
    "lngColorFlip",
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
had_lngflip=0; grep -q 'lngColorFlip' "$DASH" && had_lngflip=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-gaslngsign-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-gas-lng-sign.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch exit $rc"
  exit 1
fi
cp -a "$DASH" /tmp/dashboard.py.gaslngsign-once
python3 /tmp/patch-gas-lng-sign.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.gaslngsign-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
echo "OK gasLngSign idempotent"

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
if [[ "$had_lngflip" == 1 ]]; then
  grep -q 'lngColorFlip' "$DASH" || { rollback "lngColorFlip weg"; exit 1; }
  grep -q 'grün ≥80' "$DASH" || { rollback "LNG-Terminal-Legende weg"; exit 1; }
fi
grep -q 'gasLngSign' "$DASH" || { rollback "Marker gasLngSign fehlt"; exit 1; }
grep -q 'gasInStorage' "$DASH" || { rollback "gasInStorage fehlt"; exit 1; }
grep -q '5-Tage-Mittel' "$DASH" || { rollback "5-Tage-Mittel fehlt"; exit 1; }
grep -q '1,5 TWh/Tag' "$DASH" || { rollback "Annahme 1,5 fehlt"; exit 1; }
echo "OK guards boot=${had_boot} staleTsBoot=${had_stale} strom14dChart=${had_strom} navUnify=${had_nav} adsbMilThird=${had_adsb} lngColorFlip=${had_lngflip}"

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
  root=$(curl --compressed -s -o /tmp/gaslng_root.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || true)
  [[ -z "$root" ]] && root=000
  echo "try $i HTTP /=$root"
  if [[ "$root" == "200" || "$root" == "500" ]]; then
    break
  fi
  sleep 2
done
decode_http_body /tmp/gaslng_root.html || true
if [[ "$root" == "500" ]]; then
  rollback "HTTP / = 500"
  exit 1
fi
if [[ "$root" != "200" ]]; then
  echo "WARN: HTTP / = $root — Patch bleibt, kein Rollback"
else
  echo "OK HTTP / = 200"
fi

eng=$(curl --compressed -s -o /tmp/gaslng_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || true)
[[ -z "$eng" ]] && eng=000
decode_http_body /tmp/gaslng_energie.html || true
echo "HTTP /energie=$eng"
if [[ "$eng" == "500" ]]; then
  rollback "HTTP /energie = 500"
  exit 1
fi
if [[ "$eng" == "302" || "$eng" == "301" || "$eng" == "308" ]]; then
  echo "OK /energie $eng (redirect)"
fi

sp=$(curl --compressed -s -o /tmp/gaslng_speicher.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/speicher" || true)
[[ -z "$sp" ]] && sp=000
decode_http_body /tmp/gaslng_speicher.html || true
echo "HTTP /speicher=$sp"
if [[ "$sp" == "500" ]]; then
  rollback "HTTP /speicher = 500"
  exit 1
fi
if [[ "$sp" == "200" ]] && grep -q 'gasLngSign' /tmp/gaslng_speicher.html; then
  echo "OK /speicher zeigt gasLngSign"
fi

echo "OK gasLngSign applied COMMIT=$COMMIT PORT=$PORT"
echo "OK Gas: Bestand gasInStorage, minus Entnahme, plus Befuellung, Annahme 1,5 TWh/Tag"
echo "OK LNG: 5-Tage-Mittel, Ausspeisung=Entnahme, Fallback 0,15 TWh/Tag nur bei Annahme"
