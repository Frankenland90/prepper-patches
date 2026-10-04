#!/bin/bash
set -euo pipefail
# sunGtext: ein deutscher Satz auf der Kachel Sonnenaktivitaet und im Mesh,
# nur wenn die schon angezeigte NOAA-G-Skala (Block 0, Feld Scale) G1..G5 ist.
# G0 oder fehlend: kein Zusatz. Kein Forecast-Block 1, kein estimated_kp,
# kein Sonnenwind, kein 24h-max-Fix, keine Farbanderung, keine andere Kachel.
# Smoke nur :8080, curl --compressed. /energie 302 ist ok.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung und data_store.clear() unveraendert.
# Der Patch erwaehnt data_store = { und data_store.clear() nur im Docstring.
# Gezaehlt wird nur ein echter AST-Call bzw. eine echte Zuweisung.
# Patch-Bytes stecken gzip+base64 in diesem Skript. EXPECT_SHA ist sha256 der .py-Datei.
EXPECT_SHA="71a42ec669b8693acaced09c58ff47d531606deca78c23520eb94a99106d0783"
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

echo "=== sunGtext apply PORT=$PORT ==="
rm -f /tmp/patch-sun-gtext.py /tmp/patch-sun-gtext.py.gz.b64
cat > /tmp/patch-sun-gtext.py.gz.b64 << 'B64'
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
nQ4uFi/myO2JVl77H2g2e0AfTAAA
B64
base64 -d /tmp/patch-sun-gtext.py.gz.b64 | gzip -dc > /tmp/patch-sun-gtext.py
echo "$EXPECT_SHA  /tmp/patch-sun-gtext.py" | sha256sum -c -
head -1 /tmp/patch-sun-gtext.py | grep -q python3 || { echo "FAIL: patch ist kein python"; exit 1; }
grep -q 'sunGtext' /tmp/patch-sun-gtext.py || { echo "FAIL: patch ohne sunGtext"; exit 1; }
if grep -q 'PLACEHOLDER_WILL_REPLACE' /tmp/patch-sun-gtext.py; then
  echo "FAIL: patch ist PLACEHOLDER"
  exit 1
fi
if grep -q 'Thread(target=update_all' /tmp/patch-sun-gtext.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
guard_rc=0
set +e
python3 - /tmp/patch-sun-gtext.py << 'GUARDPY'
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
python3 -m py_compile /tmp/patch-sun-gtext.py
python3 /tmp/patch-sun-gtext.py --selftest
echo "OK sunGtext selftest"

[[ -f "$DASH" ]] || { echo "FAIL: missing $DASH"; exit 1; }
cp -a "$DASH" "$DASH.bak-sungtext-$TS"

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
    "pageFein",
    "keepLast",
    "estimated_kp",
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
had_keep=0; grep -q 'keepLast' "$DASH" && had_keep=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-sungtext-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-sun-gtext.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch exit $rc"
  exit 1
fi
cp -a "$DASH" /tmp/dashboard.py.sungtext-once
python3 /tmp/patch-sun-gtext.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.sungtext-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
echo "OK sunGtext idempotent"

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
if [[ "$had_keep" == 1 ]]; then
  grep -q 'keepLast' "$DASH" || { rollback "keepLast weg"; exit 1; }
fi
grep -q 'def sun_g_sentence' "$DASH" || { rollback "sun_g_sentence fehlt"; exit 1; }
grep -q 'Kleiner Sturm, erste Polarlichter' "$DASH" || { rollback "G1-Satz fehlt"; exit 1; }
grep -q 'sunGtext' "$DASH" || { rollback "sunGtext Marker fehlt"; exit 1; }
echo "OK guards boot=$had_boot staleTsBoot=$had_stale strom14dChart=$had_strom navUnify=$had_nav gasLngSign=$had_gas lngColorFlip=$had_lng adsbMilThird=$had_adsb keepLast=$had_keep"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
root=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  root=$(curl --compressed -s -o /tmp/sungtext_root.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || true)
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

eng=$(curl --compressed -s -o /tmp/sungtext_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || true)
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

echo "OK sunGtext applied PORT=$PORT"
echo "OK sunGtext: G1..G5 Satz auf Kachel und im Mesh, G0 ohne Zusatz"
