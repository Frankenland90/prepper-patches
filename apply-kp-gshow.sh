#!/bin/bash
set -euo pipefail
# kpGshow: G/R/S auf der Kachel Sonnenaktivitaet zeigt nicht mehr ein
# widerspruechliches G0, wenn Kp oder 24h-max schon eine Sturmstufe tragen.
# Ursache (live 2026-10-04 19:48 UTC, Screenshot 21:43 Berlin): kein Parse-Bug
# und kein haengen gebliebener Fallback. noaa-scales.json Schluessel "0"
# (aktuell beobachtet) hat G.Scale "0". Schluessel "1" ist der Tages-Forecast
# mit G1, Schluessel "-1" ist gestern mit G1. planetary_k_index_1m.json:
# letztes kp_index 5, Maximum im Fenster kp_index 6 (estimated_kp bleibt darunter).
# Der Code liest nur Block "0" und formatiert Scale korrekt als G0.
# Fix: angezeigtes G = max(NOAA-G aus Block 0, G aus aktuellem Kp, G aus 24h-max).
# Karte wie space_stage: Kp 5 = G1, Kp 6 = G2, 7 = G3, 8 = G4, ab 9 = G5.
# R und S bleiben NOAA. Forecast-Block wird nicht gelesen. Kein G ueber 5.
# Der deutsche Satz folgt diesem angezeigten G. G0: kein Zusatz.
# Ersetzt einen vorhandenen sunGtext-Haken, damit der alte NOAA-only-Check
# den neuen nicht blockiert.
# Smoke nur :8080, curl --compressed. /energie 302 ist ok.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung und data_store.clear() unveraendert.
# Der Patch erwaehnt data_store = { und data_store.clear() nur im Docstring.
# Gezaehlt wird nur ein echter AST-Call bzw. eine echte Zuweisung.
# Patch-Bytes stecken gzip+base64 in diesem Skript. EXPECT_SHA ist sha256 der .py-Datei.
EXPECT_SHA="d06783ab7fbc4771901617617b21a98f4e39a2cb56c4bf0d7a6e85a47fb59f36"
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

echo "=== kpGshow apply PORT=$PORT ==="
rm -f /tmp/patch-kp-gshow.py /tmp/patch-kp-gshow.py.gz.b64
cat > /tmp/patch-kp-gshow.py.gz.b64 << 'B64'
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
lTviFkZ4AAA=
B64
base64 -d /tmp/patch-kp-gshow.py.gz.b64 | gzip -dc > /tmp/patch-kp-gshow.py
echo "$EXPECT_SHA  /tmp/patch-kp-gshow.py" | sha256sum -c -
head -1 /tmp/patch-kp-gshow.py | grep -q python3 || { echo "FAIL: patch ist kein python"; exit 1; }
grep -q 'kpGshow' /tmp/patch-kp-gshow.py || { echo "FAIL: patch ohne kpGshow"; exit 1; }
if grep -q 'PLACEHOLDER_WILL_REPLACE' /tmp/patch-kp-gshow.py; then
  echo "FAIL: patch ist PLACEHOLDER"
  exit 1
fi
if grep -q 'Thread(target=update_all' /tmp/patch-kp-gshow.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
guard_rc=0
set +e
python3 - /tmp/patch-kp-gshow.py << 'GUARDPY'
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
python3 -m py_compile /tmp/patch-kp-gshow.py
python3 /tmp/patch-kp-gshow.py --selftest
echo "OK kpGshow selftest"

[[ -f "$DASH" ]] || { echo "FAIL: missing $DASH"; exit 1; }
cp -a "$DASH" "$DASH.bak-kpgshow-$TS"

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
  cp -a "$DASH.bak-kpgshow-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-kp-gshow.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch exit $rc"
  exit 1
fi
cp -a "$DASH" /tmp/dashboard.py.kpgshow-once
python3 /tmp/patch-kp-gshow.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.kpgshow-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
echo "OK kpGshow idempotent"

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
grep -q 'def shown_g_num' "$DASH" || { rollback "shown_g_num fehlt"; exit 1; }
grep -q 'Kleiner Sturm, erste Polarlichter' "$DASH" || { rollback "G1-Satz fehlt"; exit 1; }
grep -q 'kpGshow' "$DASH" || { rollback "kpGshow Marker fehlt"; exit 1; }
if grep -q 'sun_g_sentence(' "$DASH"; then
  rollback "alter sunGtext-Check bleibt"
  exit 1
fi
echo "OK guards boot=$had_boot staleTsBoot=$had_stale strom14dChart=$had_strom navUnify=$had_nav gasLngSign=$had_gas lngColorFlip=$had_lng adsbMilThird=$had_adsb keepLast=$had_keep"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
root=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  root=$(curl --compressed -s -o /tmp/kpgshow_root.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || true)
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

eng=$(curl --compressed -s -o /tmp/kpgshow_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || true)
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

echo "OK kpGshow applied PORT=$PORT"
echo "OK kpGshow: G = max(NOAA-Block0, Kp, 24h-max); Satz folgt diesem G, G0 ohne Satz"
