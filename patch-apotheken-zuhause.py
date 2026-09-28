#!/usr/bin/env python3
"""Move Apotheken-Notdienst tile from /medizin (PAGE4) to /zuhause under Müllabfuhr.
Keeps fetch_apotheken_notdienst + data_store entry. Idempotent. # apoZuhause
"""
from __future__ import annotations

import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

MARK = "apoZuhause"
DASH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")


def must_have(src: str, needle: str, label: str) -> None:
    if needle not in src:
        raise SystemExit(f"STOP {MARK}: fehlt {label}")


def main() -> None:
    src0 = DASH.read_text(encoding="utf-8")
    src = src0

    must_have(src, "def fetch_apotheken_notdienst(", "fetch_apotheken_notdienst")
    must_have(src, "def page_zuhause(", "page_zuhause")
    must_have(src, "data_store", "data_store")

    # Already fully applied?
    has_route = f"# {MARK}" in src and "apotheken_notdienst=apo" in src
    has_medizin_card = 'class="apo-wrap"' in src
    if has_route and not has_medizin_card:
        print(f"already patched ({MARK}) — nichts geändert.")
        return

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = DASH.with_name(f"dashboard.py.bak-apozuhause-{stamp}")
    shutil.copy2(DASH, bak)
    print(f"Backup: {bak}")

    changed = False

    # --- 1) page_zuhause: pass apotheken_notdienst from data_store ---
    route_old = (
        '@app.route("/zuhause")\n'
        "def page_zuhause():\n"
        "    # zuhausePage\n"
        "    import zuhause as _zuh\n"
        "    z = _zuh.load_or_refresh(force=False)\n"
        "    return render_template_string(_zuh.page_template(BASE_STYLE), z=z)\n"
    )
    route_new = (
        '@app.route("/zuhause")\n'
        "def page_zuhause():\n"
        "    # zuhausePage\n"
        f"    # {MARK}\n"
        "    import zuhause as _zuh\n"
        "    z = _zuh.load_or_refresh(force=False)\n"
        '    apo = data_store.get("apotheken_notdienst")\n'
        "    return render_template_string(\n"
        "        _zuh.page_template(BASE_STYLE), z=z, apotheken_notdienst=apo\n"
        "    )\n"
    )
    if "apotheken_notdienst=apo" in src and f"# {MARK}" in src:
        print("Route page_zuhause: apo schon verdrahtet")
    elif route_old in src:
        src = src.replace(route_old, route_new, 1)
        changed = True
        print("Route page_zuhause: apotheken_notdienst verdrahtet")
    else:
        # Looser: inject after load_or_refresh if marker missing
        m = re.search(
            r'(def page_zuhause\(\):\n'
            r'(?:[ \t]*#.*\n)*'
            r'[ \t]*import zuhause as _zuh\n'
            r'[ \t]*z = _zuh\.load_or_refresh\(force=False\)\n)'
            r'([ \t]*return render_template_string\(_zuh\.page_template\(BASE_STYLE\), z=z\)\n)',
            src,
        )
        if m and "apotheken_notdienst=apo" not in src:
            indent = "    "
            inject = (
                m.group(1)
                + ("" if f"# {MARK}" in m.group(1) else f"{indent}# {MARK}\n")
                + f'{indent}apo = data_store.get("apotheken_notdienst")\n'
                + f"{indent}return render_template_string(\n"
                + f"{indent}    _zuh.page_template(BASE_STYLE), z=z, apotheken_notdienst=apo\n"
                + f"{indent})\n"
            )
            src = src[: m.start()] + inject + src[m.end() :]
            changed = True
            print("Route page_zuhause: apo verdrahtet (loose)")
        elif "apotheken_notdienst=apo" in src:
            print("Route page_zuhause: schon ok")
        else:
            raise SystemExit(f"STOP {MARK}: page_zuhause-Anker nicht gefunden")

    # Ensure marker comment exists near route
    if f"# {MARK}" not in src:
        src = src.replace(
            "def page_zuhause():\n    # zuhausePage\n",
            f"def page_zuhause():\n    # zuhausePage\n    # {MARK}\n",
            1,
        )
        changed = True

    # --- 2) Remove apo-wrap card from Medizin PAGE4 ---
    if 'class="apo-wrap"' in src:
        new_src, n = re.subn(
            r'\n?  <div class="apo-wrap">.*?</div>\n(  <iframe src="http://192\.168\.178\.99:8080")',
            r"\n\1",
            src,
            count=1,
            flags=re.DOTALL,
        )
        if n != 1:
            raise SystemExit(
                f"STOP {MARK}: apo-wrap Entfernen fehlgeschlagen (n={n})"
            )
        src = new_src
        changed = True
        print("Medizin PAGE4: apo-wrap entfernt")
    else:
        print("Medizin PAGE4: kein apo-wrap (schon weg)")

    if not changed and src == src0:
        print(f"already patched ({MARK}) — nichts geändert.")
        return

    DASH.write_text(src, encoding="utf-8")
    print(f"OK patched {MARK} -> {DASH}")
    print(f"  marker: {src.count(MARK)}")
    print(f"  apo-wrap left: {src.count('apo-wrap')}")
    print(f"  fetch kept: {'def fetch_apotheken_notdienst(' in src}")
    print(f"  route apo: {'apotheken_notdienst=apo' in src}")


if __name__ == "__main__":
    main()
