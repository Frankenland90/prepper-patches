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
# Anker sind Mesh und Kachel NACH sunGtext (Pin 2ed945e8), nicht die Fassung davor.
# 763fa785 nicht erneut ausfuehren: der stoppte an den alten Ankern (mesh=0 tile=0).
# Smoke nur :8080, curl --compressed. /energie 302 ist ok.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung und data_store.clear() unveraendert.
# Der Patch erwaehnt data_store = { und data_store.clear() nur im Docstring.
# Gezaehlt wird nur ein echter AST-Call bzw. eine echte Zuweisung.
# Patch-Bytes stecken gzip+base64 in diesem Skript. EXPECT_SHA ist sha256 der .py-Datei.
EXPECT_SHA="580c1d9c07f71300da468252e1382c9e67eda6e73b3fc7426ab5fb076d6922a5"
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
