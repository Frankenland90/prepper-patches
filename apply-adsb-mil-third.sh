#!/bin/bash
set -euo pipefail
# ADSB only: Militaer-Kachel wird die dritte Kachel, direkt ueber Squawk/Notlage.
# Marker adsbMilThird. Smoke nur :8080. curl --compressed. /energie 302 ist ok.
# Rollback nur bei HTTP 500.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung, data_store.clear(),
# staleTsBoot, strom14dChart und navUnify unangetastet.
EXPECT_SHA="a1e2f5dc25ebb0b9c6b6785b86daabff750b2fb8d460117a3186e5982c0fe326"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"

if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 - smoke only :8080"
  exit 1
fi
if [[ "$EXPECT_SHA" == PLACEHOLDER* || -z "$EXPECT_SHA" ]]; then
  echo "FAIL: pin not set"
  exit 1
fi

echo "=== adsbMilThird apply PORT=$PORT ==="
base64 -d << 'B64' | gzip -dc > /tmp/patch-adsb-mil-third.py
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
B64
echo "$EXPECT_SHA  /tmp/patch-adsb-mil-third.py" | sha256sum -c -
grep -q 'adsbMilThird' /tmp/patch-adsb-mil-third.py || { echo "FAIL: patch ohne adsbMilThird"; exit 1; }
head -1 /tmp/patch-adsb-mil-third.py | grep -q python3 || { echo "FAIL: patch ist kein python"; exit 1; }
if grep -q 'Thread(target=update_all' /tmp/patch-adsb-mil-third.py; then
  echo "FAIL: patch enthaelt Thread(target=update_all"
  exit 1
fi
if grep -nE '^[[:space:]]*data_store[[:space:]]*=' /tmp/patch-adsb-mil-third.py; then
  echo "FAIL: patch schreibt data_store"
  exit 1
fi
if grep -q 'data_store.clear()' /tmp/patch-adsb-mil-third.py; then
  echo "FAIL: patch ruft data_store.clear auf"
  exit 1
fi
python3 -m py_compile /tmp/patch-adsb-mil-third.py
echo "OK adsbMilThird patch sha256 $EXPECT_SHA"
wc -c /tmp/patch-adsb-mil-third.py

[[ -f "$DASH" ]] || { echo "FAIL: missing $DASH"; exit 1; }
cp -a "$DASH" "$DASH.bak-adsbmilthird-$TS"

guard_snap() {
  python3 - "$1" << 'PY'
import pathlib, re, sys
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
keys = [
    "update_all()  # einmal beim Start",
    "staleTsBoot",
    "strom14dChart",
    "navUnify",
    "data_store.clear()",
]
for k in keys:
    print("%s\t%d" % (k, t.count(k)))
n = 0
for line in t.splitlines():
    if re.match(r"\s*data_store\s*=", line):
        n += 1
print("data_store_assign\t%d" % n)
PY
}

before=$(guard_snap "$DASH")
had_boot=0; grep -q 'update_all()  # einmal beim Start' "$DASH" && had_boot=1 || true
had_stale=0; grep -q 'staleTsBoot' "$DASH" && had_stale=1 || true
had_strom=0; grep -q 'strom14dChart' "$DASH" && had_strom=1 || true
had_nav=0; grep -q 'navUnify' "$DASH" && had_nav=1 || true
had_fein=0; grep -q 'pageFein' "$DASH" && had_fein=1 || true

rollback() {
  echo "ROLLBACK: $1"
  cp -a "$DASH.bak-adsbmilthird-$TS" "$DASH"
  sudo systemctl restart prepper-dashboard.service 2>/dev/null \
    || sudo systemctl restart prepper-dashboard \
    || true
}

set +e
python3 /tmp/patch-adsb-mil-third.py "$DASH"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  rollback "patch exit $rc"
  exit 1
fi
cp -a "$DASH" /tmp/dashboard.py.adsbmilthird-once
python3 /tmp/patch-adsb-mil-third.py "$DASH"
cmp -s "$DASH" /tmp/dashboard.py.adsbmilthird-once || { rollback "zweiter Lauf nicht idempotent"; exit 1; }
python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
echo "OK adsbMilThird idempotent"

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
if [[ "$had_fein" == 1 ]]; then
  grep -q 'pageFein' "$DASH" || { rollback "pageFein weg"; exit 1; }
fi
grep -q 'adsbMilThird' "$DASH" || { rollback "Marker adsbMilThird fehlt"; exit 1; }
echo "OK guards boot=${had_boot} staleTsBoot=${had_stale} strom14dChart=${had_strom} navUnify=${had_nav}"

sudo systemctl restart prepper-dashboard.service 2>/dev/null \
  || sudo systemctl restart prepper-dashboard \
  || true

echo "--- HTTP :$PORT (nie :5000) ---"
decode_http_body() {
  python3 - "$1" << 'PY'
import gzip, pathlib, sys
p = pathlib.Path(sys.argv[1])
if not p.is_file():
    raise SystemExit(0)
b = p.read_bytes()
if len(b) >= 2 and b[0] == 0x1F and b[1] == 0x8B:
    p.write_bytes(gzip.decompress(b))
    print("NOTE: body war gzip, entpackt", p.name)
PY
}

root=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  root=$(curl --compressed -s -o /tmp/adsbmil_root.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/" || true)
  [[ -z "$root" ]] && root=000
  echo "try $i HTTP /=$root"
  if [[ "$root" == "200" || "$root" == "500" ]]; then
    break
  fi
  sleep 2
done
decode_http_body /tmp/adsbmil_root.html || true
if [[ "$root" == "500" ]]; then
  rollback "HTTP / = 500"
  exit 1
fi
if [[ "$root" != "200" ]]; then
  echo "WARN: HTTP / = $root — Patch bleibt, kein Rollback"
else
  echo "OK HTTP / = 200"
fi

eng=$(curl --compressed -s -o /tmp/adsbmil_energie.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/energie" || true)
[[ -z "$eng" ]] && eng=000
decode_http_body /tmp/adsbmil_energie.html || true
echo "HTTP /energie=$eng"
if [[ "$eng" == "500" ]]; then
  rollback "HTTP /energie = 500"
  exit 1
fi
if [[ "$eng" == "302" || "$eng" == "301" || "$eng" == "308" ]]; then
  echo "OK /energie $eng (redirect)"
fi

adsb=$(curl --compressed -s -o /tmp/adsbmil_adsb.html -w "%{http_code}" --connect-timeout 3 --max-time 20 "http://127.0.0.1:${PORT}/adsb" || true)
[[ -z "$adsb" ]] && adsb=000
decode_http_body /tmp/adsbmil_adsb.html || true
echo "HTTP /adsb=$adsb"
if [[ "$adsb" == "500" ]]; then
  rollback "HTTP /adsb = 500"
  exit 1
fi
if [[ "$adsb" == "200" ]]; then
  python3 - << 'PY'
import pathlib, re, sys
html = pathlib.Path("/tmp/adsbmil_adsb.html").read_text(encoding="utf-8", errors="replace")
if "adsbMilThird" not in html:
    print("WARN: /adsb 200 ohne adsbMilThird im HTML — kein Rollback")
    sys.exit(0)
titles = re.findall(r'<div class="title">\s*(.*?)\s*</div>', html, re.S)
titles = [re.sub(r"\s+", " ", t).strip() for t in titles]
print("ADSB TITLES:", " | ".join(titles))
mil = next((i for i,t in enumerate(titles) if "milit" in t.casefold() and ("tar1090" in t.casefold() or "dbflag" in t.casefold())), None)
sq = next((i for i,t in enumerate(titles) if "squawk" in t.casefold() and "notlage" in t.casefold()), None)
if mil == 2 and sq == 3:
    print("OK /adsb Kachel 3 MILITÄR direkt über SQUAWK / NOTLAGE")
else:
    print("WARN: /adsb Reihenfolge mil=%s sq=%s — Datei wurde geprueft, kein Rollback" % (mil, sq))
PY
fi

echo "OK adsbMilThird applied PORT=$PORT"
echo "OK MILITÄR ist die dritte Kachel, direkt über SQUAWK / NOTLAGE"
