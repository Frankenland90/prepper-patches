#!/bin/bash
set -euo pipefail
# URGENT pageFein 500 hotfix: restore bak OR repair live clear()/StartBg-thread.
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
MODE="${1:-repair}"  # repair | restore

if [[ "$MODE" == "restore" ]]; then
  BAK=""
  if [[ -f "$DASH_DIR/dashboard.py.bak-pagefein-20261002-211022" ]]; then
    BAK="$DASH_DIR/dashboard.py.bak-pagefein-20261002-211022"
  else
    BAK=$(ls -1t "$DASH_DIR"/dashboard.py.bak-pagefein-* 2>/dev/null | head -1 || true)
  fi
  [[ -n "$BAK" && -f "$BAK" ]] || { echo "FAIL: no bak"; exit 1; }
  cp -a "$BAK" "$DASH"
  echo "Restored $BAK"
else
  python3 - <<'PY'
from pathlib import Path
import re, shutil
from datetime import datetime
DASH = Path("/home/fmg/prepper-dashboard/dashboard.py")
src = DASH.read_text(encoding="utf-8")
changed = []
stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
shutil.copy2(DASH, DASH.with_name("dashboard.py.bak-pagefein-hotfix-%s" % stamp))

bad_swap = (
    "    # pageFein atomicSwap \u2014 kurze Lock-Phase, HTTP bleibt threaded\n"
    "    with data_store_lock:\n"
    "        data_store.clear()\n"
    "        data_store.update(_new)\n"
    "    text, color, reason = calculate_lage(data_store)"
)
good_swap = (
    "    # pageFein atomicSwap \u2014 Referenz-Tausch (kein clear: sonst leerer Store \u2192 Jinja 500)\n"
    "    with data_store_lock:\n"
    "        data_store = _new\n"
    "    text, color, reason = calculate_lage(data_store)"
)
if bad_swap in src:
    src = src.replace(bad_swap, good_swap, 1)
    changed.append("atomicSwap")
elif "data_store.clear()" in src and "pageFein atomicSwap" in src:
    src = src.replace("        data_store.clear()\n        data_store.update(_new)\n", "        data_store = _new\n", 1)
    src = src.replace(
        "# pageFein atomicSwap \u2014 kurze Lock-Phase, HTTP bleibt threaded",
        "# pageFein atomicSwap \u2014 Referenz-Tausch (kein clear: sonst leerer Store \u2192 Jinja 500)",
        1,
    )
    changed.append("atomicSwap-loose")

bad_bg = (
    "    # pageFeinStartBg \u2014 erstes Update parallel, HTTP nicht blockieren\n"
    "    threading.Thread(target=update_all, daemon=True).start()\n"
    "    threading.Thread(target=background_loop, daemon=True).start()\n"
)
good_bg = (
    "    update_all()  # pageFeinStartBg \u2014 blockierend bis Store gef\u00fcllt (sonst Jinja 500)\n"
    "    threading.Thread(target=background_loop, daemon=True).start()\n"
)
if bad_bg in src:
    src = src.replace(bad_bg, good_bg, 1)
    changed.append("StartBg")
elif "Thread(target=update_all" in src:
    src = re.sub(
        r"[ \t]*#[^\n]*pageFeinStartBg[^\n]*\n[ \t]*threading\.Thread\(target=update_all, daemon=True\)\.start\(\)\n",
        "    update_all()  # pageFeinStartBg \u2014 blockierend bis Store gef\u00fcllt\n",
        src,
        count=1,
    )
    changed.append("StartBg-re")

# PAGE_LOKALE nav before DOCTYPE (best-effort)
m = re.search(
    r'PAGE_LOKALE_ENERGIE = """<nav class="nav-top">.*?</nav>\s*<!DOCTYPE html><html lang="de"><head>\n',
    src,
    re.S,
)
if m:
    nav_m = re.search(r'(<nav class="nav-top">.*?</nav>)', m.group(0), re.S)
    if nav_m:
        nav_html = nav_m.group(1)
        if "pageFein lokaleDoctypeNav" not in nav_html:
            nav_html = nav_html.replace('<nav class="nav-top">', '<nav class="nav-top">  <!-- pageFein lokaleDoctypeNav -->', 1)
        src = src[:m.start()] + 'PAGE_LOKALE_ENERGIE = """<!DOCTYPE html><html lang="de"><head>  <!-- pageFein lokaleDoctypeNav -->\n' + src[m.end():]
        lok_i = src.find("PAGE_LOKALE_ENERGIE")
        lok_end = src.find('@app.route("/energie")', lok_i)
        if lok_end < 0:
            lok_end = lok_i + 12000
        region = src[lok_i:lok_end]
        body_re = re.compile(r"</style></head><body>\n(?:<nav class=\"nav-top\">.*?</nav>\n)?<div class=\"header\">Lokale Energie", re.S)
        bm = body_re.search(region)
        if bm:
            region2 = region[:bm.start()] + "</style></head><body>\n" + nav_html + "\n" + '<div class="header">Lokale Energie' + region[bm.end():]
            src = src[:lok_i] + region2 + src[lok_end:]
            changed.append("lokaleDoctypeNav")

DASH.write_text(src, encoding="utf-8")
print("hotfix changes:", ", ".join(changed) if changed else "(none \u2014 already fixed?)")
if "Thread(target=update_all" in src:
    raise SystemExit("FAIL: StartBg thread still present")
if "data_store.clear()" in src and "pageFein atomicSwap" in src:
    raise SystemExit("FAIL: atomicSwap clear still present")
print("OK hotfix")
PY
fi

python3 -m py_compile "$DASH"
sudo systemctl restart prepper-dashboard.service 2>/dev/null || sudo systemctl restart prepper-dashboard || true
sleep 8
systemctl is-active prepper-dashboard.service 2>/dev/null || systemctl is-active prepper-dashboard || true
for path in / /energie /lokale-energie /speicher /umwelt /pegel /adsb /news; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:5000$path" || echo 0)
  echo "HTTP $path=$code"
done
echo "OK page-fein hotfix MODE=$MODE"
