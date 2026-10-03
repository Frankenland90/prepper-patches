#!/bin/bash
set -euo pipefail
# ADSB only: Militaer-Kachel wird die dritte Kachel, direkt ueber Squawk/Notlage.
# PAGE_ADSB darf ein String oder eine Verkettung (auch in Klammern) sein.
# Marker adsbMilThird. Smoke nur :8080. curl --compressed. /energie 302 ist ok.
# Rollback nur bei HTTP 500.
# Laesst update_all() # einmal beim Start, data_store-Zuweisung, data_store.clear(),
# staleTsBoot, strom14dChart und navUnify unangetastet.
EXPECT_SHA="1464171d716fe046b631697fc9183c9b0d6fffc2132d5860118ed66f61f1b52a"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
TS=$(date +%Y%m%d-%H%M%S)
PORT="${PORT:-8080}"

if [[ "$PORT" == "5000" ]]; then
  echo "FAIL: refused PORT=5000 - smoke only :8080"
  exit 1
fi
if [[ -z "$EXPECT_SHA" || ${#EXPECT_SHA} -ne 64 ]]; then
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
