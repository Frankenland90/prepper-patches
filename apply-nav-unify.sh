#!/bin/bash
set -euo pipefail
# Nav ONLY (# navUnify): eine gemeinsame Leiste, 3 gleichmaessige Zeilen, volle Namen.
# Smoke nur :8080. 302 (trailing slash) ist ok. Rollback bei HTTP 500 oder wenn / nicht 200 ist.
# Aendert nicht update_all() # einmal beim Start, data_store-Zuweisung, staleTsBoot, strom14dChart.
COMMIT="886499e4fd8b2d842572a21a4ca8fbee7094c22e"
EXPECT_SHA="bdaf9f13b2485782e308c94081fb492f93b287a170457c7217a0e6950dcc2560"
BASE="https://raw.githubusercontent.com/Frankenland90/prepper-patches/${COMMIT}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
ZUH="$DASH_DIR/zuhause.py"
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

echo "=== navUnify apply COMMIT=$COMMIT PORT=$PORT ==="
mkdir -p /tmp/navunify-b64
: > /tmp/navunify-b64/all
for i in 0 1 2 3; do
  curl -fsSL "$BASE/patch-nav-unify.py.b64.$i" -o "/tmp/navunify-b64/c$i"
  tr -d '[:space:]' < "/tmp/navunify-b64/c$i" >> /tmp/navunify-b64/all
done
base64 -d /tmp/navunify-b64/all | gzip -dc > /tmp/patch-nav-unify.py
echo "$EXPECT_SHA  /tmp/patch-nav-unify.py" | sha256sum -c -
grep -q 'navUnify' /tmp/patch-nav-unify.py || { echo "FAIL: patch ohne navUnify"; exit 1; }
grep -q 'id="navUnify"' /tmp/patch-nav-unify.py || { echo "FAIL: patch ohne id=navUnify"; exit 1; }
if grep -q 'Thread(target=update_all' /tmp/patch-nav-unify.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
if grep -nE '^[[:space:]]*data_store[[:space:]]*=' /tmp/patch-nav-unify.py; then
  echo "FAIL: patch schreibt data_store"
  exit 1
fi
if grep -q 'data_store.clear' /tmp/patch-nav-unify.py && grep -q 'data_store.clear()' /tmp/patch-nav-unify.py; then
  echo "FAIL: patch ruft data_store.clear auf"
  exit 1
fi
python3 -m py_compile /tmp/patch-nav-unify.py
echo "OK navUnify patch sha256 COMMIT=$COMMIT"
wc -c /tmp/patch-nav-unify.py

[[ -f "$DASH" ]] || { echo "FAIL: missing $DASH"; exit 1; }
cp -a "$DASH" "$DASH.bak-navunify-$TS"
if [[ -f "$ZUH" ]]; then
  cp -a "$ZUH" "$ZUH.bak-navunify-$TS"
fi

had_boot=0; grep -q 'update_all()  # einmal beim Start' "$DASH" && had_boot=1 || true
had_fein=0; grep -q 'pageFein' "$DASH" && had_fein=1 || true
had_stale=0; grep -q 'staleTsBoot' "$DASH" && had_stale=1 || true
had_strom=0; grep -q 'strom14dChart' "$DASH" && had_strom=1 || true
had_lock=0; grep -q 'dataStoreLock' "$DASH" && had_lock=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-navunify-$TS" "$DASH"
  if [[ -f "$ZUH.bak-navunify-$TS" ]]; then
    cp -a "$ZUH.bak-navunify-$TS" "$ZUH"
  fi
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-nav-unify.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch dashboard exit $rc"
  exit 1
fi
cp -a "$DASH" /tmp/dashboard.py.navunify-once
python3 /tmp/patch-nav-unify.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.navunify-once || { rollback "dashboard zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "dashboard py_compile"; exit 1; }
echo "OK navUnify dashboard idempotent"

if [[ -f "$ZUH" ]]; then
  set +e
  python3 /tmp/patch-nav-unify.py "$ZUH"
  zrc=$?
  set -e
  if [[ "$zrc" -ne 0 ]]; then
    rollback "patch zuhause exit $zrc"
    exit 1
  fi
  cp -a "$ZUH" /tmp/zuhause.py.navunify-once
  python3 /tmp/patch-nav-unify.py "$ZUH"
  cmp -s "$ZUH" /tmp/zuhause.py.navunify-once || { rollback "zuhause zweiter Lauf nicht idempotent"; exit 1; }
  python3 -m py_compile "$ZUH" || { rollback "zuhause py_compile"; exit 1; }
  echo "OK navUnify zuhause idempotent"
else
  echo "WARN: keine zuhause.py"
fi

if [[ "$had_boot" == 1 ]]; then
  grep -q 'update_all()  # einmal beim Start' "$DASH" || { rollback "Boot-Pfad weg"; exit 1; }
fi
if [[ "$had_fein" == 1 ]]; then
  grep -q 'pageFein' "$DASH" || { rollback "pageFein weg"; exit 1; }
fi
if [[ "$had_stale" == 1 ]]; then
  grep -q 'staleTsBoot' "$DASH" || { rollback "staleTsBoot weg"; exit 1; }
fi
if [[ "$had_strom" == 1 ]]; then
  grep -q 'strom14dChart' "$DASH" || { rollback "strom14dChart weg"; exit 1; }
fi
if [[ "$had_lock" == 1 ]]; then
  grep -q 'dataStoreLock' "$DASH" || { rollback "dataStoreLock weg"; exit 1; }
fi
if grep -q 'Thread(target=update_all' "$DASH"; then
  rollback "Thread(target=update_all im Dashboard"
  exit 1
fi
grep -q 'NAV_UNIFY' "$DASH" || { rollback "NAV_UNIFY fehlt"; exit 1; }
grep -q 'id="navUnify"' "$DASH" || { rollback "id=navUnify fehlt"; exit 1; }
echo "OK guards boot=${had_boot} pageFein=${had_fein} staleTsBoot=${had_stale} strom14dChart=${had_strom}"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
root=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  root=$(curl -s -o /tmp/navunify_root.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || echo 000)
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
  rollback "HTTP / not 200 ($root)"
  exit 1
fi
echo "OK HTTP / = 200"

fail=0
for path in / /energie /lokale-energie /lokal /speicher /umwelt /luft /pegel /adsb /zuhause /mesh /mesh2 /news /funk /pi /medizin; do
  safe="navu${path//\//_}"
  code=$(curl -s -o "/tmp/${safe}.html" -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}${path}" || echo 000)
  echo "HTTP $path=$code"
  if [[ "$code" == "500" ]]; then
    echo "FAIL: HTTP 500 $path"
    fail=1
    break
  fi
  if [[ "$code" == "302" || "$code" == "301" || "$code" == "404" || "$code" == "000" ]]; then
    continue
  fi
  if [[ "$code" != "200" ]]; then
    echo "WARN: HTTP $path=$code"
    continue
  fi
  # Seiten ausserhalb des Dashboards (z.B. eigener Zuhause/Funk-Prozess) nur warnen
  ids=$(grep -c 'id="navUnify"' "/tmp/${safe}.html" || true)
  rows=$(grep -c 'class="nr"' "/tmp/${safe}.html" || true)
  if [[ "$path" == "/zuhause" || "$path" == "/funk" ]]; then
    echo "  note $path ids=${ids:-0} rows=${rows:-0}"
    continue
  fi
  if [[ "${ids:-0}" != "1" || "${rows:-0}" -lt 3 ]]; then
    echo "FAIL: navUnify fehlt/doppelt auf $path ids=${ids:-0} rows=${rows:-0}"
    fail=1
    break
  fi
  for name in "Lage" "Energie" "Lokale" "Speicher" "Umwelt" "Luft" "Pegel" "ADSB" "Zuhause" "Mesh 1" "Mesh 2" "News" "Funk" "System" "Medizin"; do
    if ! grep -q "$name" "/tmp/${safe}.html"; then
      echo "FAIL: Name fehlt auf $path: $name"
      fail=1
      break
    fi
  done
  [[ "$fail" == 1 ]] && break
done
if [[ "$fail" == 1 ]]; then
  rollback "smoke navUnify"
  exit 1
fi

echo "OK navUnify applied COMMIT=$COMMIT PORT=$PORT"
echo "OK nav 3 Zeilen x 5: Lage Energie Lokale Energie Speicher Umwelt | Luft Pegel ADSB Zuhause Mesh 1 | Mesh 2 News Funk System Medizin"
