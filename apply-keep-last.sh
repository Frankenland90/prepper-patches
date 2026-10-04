#!/bin/bash
set -euo pipefail
# keepLast: fehlgeschlagener/leerer Fetch behaelt den letzten guten Wert.
# Zeitstempel bleibt der letzte erfolgreiche Fetch (staleTs faerbt grau/gelb/rot).
# Smoke nur :8080, curl --compressed. /energie 302 ist ok.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung und data_store.clear() unveraendert.
# Der Patch erwaehnt data_store = { und data_store.clear() nur im Docstring.
# Gezaehlt wird nur ein echter AST-Call bzw. eine echte Zuweisung.
# Patch-Bytes stecken gzip+base64 in diesem Skript. EXPECT_SHA ist sha256 der .py-Datei.
EXPECT_SHA="0b1bc40f14e87ef25acf48c73c4ae5db949cde3d8cde2c8c5d1ac88091a73fe3"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"

if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 - smoke only :8080"
  exit 1
fi
if [[ -z "$EXPECT_SHA" || ${#EXPECT_SHA} -ne 64 ]]; then
  echo "FAIL: EXPECT_SHA pin not set"
  exit 1
fi

echo "=== keepLast apply PORT=$PORT ==="
rm -f /tmp/patch-keep-last.py /tmp/patch-keep-last.py.gz.b64
cat > /tmp/patch-keep-last.py.gz.b64 << 'B64'
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
WQAA
B64
base64 -d /tmp/patch-keep-last.py.gz.b64 | gzip -dc > /tmp/patch-keep-last.py
echo "$EXPECT_SHA  /tmp/patch-keep-last.py" | sha256sum -c -
head -1 /tmp/patch-keep-last.py | grep -q python3 || { echo "FAIL: patch ist kein python"; exit 1; }
grep -q 'keepLast' /tmp/patch-keep-last.py || { echo "FAIL: patch ohne keepLast"; exit 1; }
if grep -q 'PLACEHOLDER_WILL_REPLACE' /tmp/patch-keep-last.py; then
  echo "FAIL: patch ist PLACEHOLDER"
  exit 1
fi
if grep -q 'Thread(target=update_all' /tmp/patch-keep-last.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
guard_rc=0
set +e
python3 - /tmp/patch-keep-last.py << 'GUARDPY'
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
python3 -m py_compile /tmp/patch-keep-last.py
python3 /tmp/patch-keep-last.py --selftest
echo "OK keepLast selftest"

[[ -f "$DASH" ]] || { echo "FAIL: missing $DASH"; exit 1; }
cp -a "$DASH" "$DASH.bak-keeplast-$TS"

guard_snap() {
  python3 - "$1" << 'GPY'
import pathlib, re, sys
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
keys = [
    "update_all()  # einmal beim Start",
    "staleTsBoot",
    "strom14dChart",
    "navUnify",
    "gasLngSign",
    "lngColorFlip",
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
had_gas=0; grep -q 'gasLngSign' "$DASH" && had_gas=1 || true
had_lng=0; grep -q 'lngColorFlip' "$DASH" && had_lng=1 || true
had_adsb=0; grep -q 'adsbMilThird' "$DASH" && had_adsb=1 || true
had_fein=0; grep -q 'pageFein' "$DASH" && had_fein=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-keeplast-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-keep-last.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch exit $rc"
  exit 1
fi
cp -a "$DASH" /tmp/dashboard.py.keeplast-once
python3 /tmp/patch-keep-last.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.keeplast-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
echo "OK keepLast idempotent"

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
if [[ "$had_gas" == 1 ]]; then
  grep -q 'gasLngSign' "$DASH" || { rollback "gasLngSign weg"; exit 1; }
fi
if [[ "$had_lng" == 1 ]]; then
  grep -q 'lngColorFlip' "$DASH" || { rollback "lngColorFlip weg"; exit 1; }
fi
if [[ "$had_adsb" == 1 ]]; then
  grep -q 'adsbMilThird' "$DASH" || { rollback "adsbMilThird weg"; exit 1; }
fi
if [[ "$had_fein" == 1 ]]; then
  grep -q 'pageFein' "$DASH" || { rollback "pageFein weg"; exit 1; }
fi
grep -q 'def _keep_install' "$DASH" || { rollback "keepLast runtime fehlt"; exit 1; }
grep -q 'keepLast installed' "$DASH" || { rollback "keepLast marker fehlt"; exit 1; }
echo "OK guards boot=$had_boot staleTsBoot=$had_stale strom14dChart=$had_strom navUnify=$had_nav gasLngSign=$had_gas lngColorFlip=$had_lng adsbMilThird=$had_adsb"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
root=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  root=$(curl --compressed -s -o /tmp/keeplast_root.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || true)
  [[ -z "$root" ]] && root=000
  echo "try $i HTTP /=$root"
  if [[ "$root" == "200" || "$root" == "500" ]]; then
    break
  fi
  sleep 2
done
if [[ "$root" == "500" ]]; then
  rollback "HTTP / = 500"
  exit 1
fi
if [[ "$root" != "200" ]]; then
  echo "WARN: HTTP / = $root — Patch bleibt, kein Rollback"
else
  echo "OK HTTP / = 200"
fi

eng=$(curl --compressed -s -o /tmp/keeplast_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || true)
[[ -z "$eng" ]] && eng=000
echo "HTTP /energie=$eng"
if [[ "$eng" == "500" ]]; then
  rollback "HTTP /energie = 500"
  exit 1
fi
if [[ "$eng" == "302" || "$eng" == "301" || "$eng" == "308" ]]; then
  echo "OK /energie $eng (redirect)"
fi
if [[ "$eng" == "200" ]]; then
  echo "OK HTTP /energie = 200"
fi

echo "OK keepLast applied PORT=$PORT"
echo "OK keepLast: leerer Fetch behaelt letzten guten Wert und dessen Zeitstempel"
