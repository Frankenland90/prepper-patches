#!/usr/bin/env python3
"""Zuhause-Seite in dashboard.py einbinden. Idempotent (# zuhausePage)."""
from pathlib import Path
import shutil
import sys
from datetime import datetime

DASH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
MARKER = "# zuhausePage"

src = DASH.read_text(encoding="utf-8")
if MARKER in src and "page_zuhause" in src and 'href="/zuhause"' in src:
    print("already patched (zuhausePage) — nichts geändert.")
    sys.exit(0)

if '<a href="/adsb">ADSB</a>' not in src:
    raise SystemExit("STOP: ADSB-Nav-Anker fehlt")
if "BASE_STYLE" not in src:
    raise SystemExit("STOP: BASE_STYLE fehlt")
if '@app.route("/adsb")' not in src:
    raise SystemExit("STOP: /adsb Route fehlt")

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
bak = DASH.with_name(f"dashboard.py.bak-zuhause-{stamp}")
shutil.copy2(DASH, bak)
print(f"Backup: {bak}")

# Nav: Zuhause nach ADSB auf allen Seiten
nav_old = '<a href="/adsb">ADSB</a>'
nav_new = '<a href="/adsb">ADSB</a>\n    <a href="/zuhause">Zuhause</a>'
if 'href="/zuhause"' not in src:
    n = src.count(nav_old)
    if n < 1:
        raise SystemExit("STOP: keine ADSB-Nav-Links")
    src = src.replace(nav_old, nav_new)
    print(f"Nav: Zuhause nach ADSB ({n}x)")
else:
    print("Nav: Zuhause schon vorhanden")

ROUTE_OLD = (
    '@app.route("/adsb")\n'
    "def page_adsb():\n"
    "    return render_template_string(PAGE_ADSB, adsb=fetch_adsb())"
)

ROUTE_NEW = (
    '@app.route("/adsb")\n'
    "def page_adsb():\n"
    "    return render_template_string(PAGE_ADSB, adsb=fetch_adsb())\n"
    "\n"
    "\n"
    '@app.route("/zuhause")\n'
    "def page_zuhause():\n"
    "    # zuhausePage\n"
    "    import zuhause as _zuh\n"
    "    z = _zuh.load_or_refresh(force=False)\n"
    "    return render_template_string(_zuh.page_template(BASE_STYLE), z=z)\n"
)

if "def page_zuhause" not in src:
    n = src.count(ROUTE_OLD)
    if n != 1:
        raise SystemExit(f"STOP: adsb-Route-Anker {n}x (erwartet 1)")
    src = src.replace(ROUTE_OLD, ROUTE_NEW, 1)
    print("Route /zuhause eingefügt")
else:
    print("Route /zuhause schon vorhanden")

DASH.write_text(src, encoding="utf-8")
print("OK patched zuhausePage ->", DASH)
print("  zuhause href:", src.count('href="/zuhause"'))
print("  page_zuhause:", src.count("def page_zuhause"))
