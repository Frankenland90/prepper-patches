#!/usr/bin/env python3
"""NINA Mesh2: Dashboard sendet wie Mesh1 direkt an :5002; JSON-Mirror aus (kein Doppel-TX).
# ninaMesh2Direct
Idempotent. Entwarnungen bleiben in Tile/JSON (cleared) sichtbar.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "ninaMesh2Direct"


def patch_dashboard(path: Path) -> bool:
    src0 = path.read_text(encoding="utf-8")
    src = src0
    changed = False

    if "def maybe_mesh_nina(" not in src:
        raise SystemExit("STOP ninaMesh2Direct: maybe_mesh_nina fehlt in " + str(path))
    if "def send_nina_to_bayern(" not in src:
        raise SystemExit("STOP ninaMesh2Direct: send_nina_to_bayern fehlt in " + str(path))

    # --- docstring maybe_mesh_nina ---
    old_doc = '    """Mesh 1 zuerst. JSON nur nach OK. Mesh 2 liest die Datei."""'
    new_doc = (
        '    """Mesh1 :5001, dann Mesh2 :5002 (wie Mesh1). JSON fuer Tile; '
        'Mirror in ping-reply-2 aus. # ' + MARK + '"""'
    )
    if old_doc in src:
        src = src.replace(old_doc, new_doc, 1)
        changed = True
    elif MARK in src and "Mesh2 :5002" in src:
        pass  # already
    elif '"""Mesh 1 zuerst.' in src:
        src = re.sub(
            r'(def maybe_mesh_nina\(nina_data\):\n\s+""")[^"]*(""")',
            r"\1Mesh1 :5001, dann Mesh2 :5002 (wie Mesh1). JSON fuer Tile; "
            r"Mirror in ping-reply-2 aus. # " + MARK + r"\2",
            src,
            count=1,
        )
        changed = True

    # --- Entwarnung: after Mesh1 OK, also Mesh2 ---
    ent_old = (
        "            if ok:\n"
        "                last_nina_mesh = None\n"
        "                save_nina_mesh_status(text, cleared=ts)\n"
        '                print("NINA-Mesh Entwarnung OK")\n'
    )
    ent_new = (
        "            if ok:\n"
        "                last_nina_mesh = None\n"
        "                save_nina_mesh_status(text, cleared=ts)\n"
        "                ok2 = send_nina_to_bayern(text)  # " + MARK + "\n"
        '                print("NINA-Mesh Entwarnung OK", "Mesh2", "OK" if ok2 else "FAIL")\n'
    )
    if "ok2 = send_nina_to_bayern(text)  # " + MARK in src:
        pass  # already (Entwarnung or both)
    elif ent_old in src:
        src = src.replace(ent_old, ent_new, 1)
        changed = True
    else:
        # already patched Entwarnung with slightly different print?
        if 'send_nina_to_bayern(text)  # ' + MARK not in src:
            # try looser: insert after save_nina_mesh_status(text, cleared=ts)
            m = re.search(
                r"(save_nina_mesh_status\(text, cleared=ts\)\n)"
                r"(\s+)print\(\"NINA-Mesh Entwarnung OK\"\)\n",
                src,
            )
            if m:
                indent = m.group(2)
                repl = (
                    m.group(1)
                    + indent
                    + "ok2 = send_nina_to_bayern(text)  # "
                    + MARK
                    + "\n"
                    + indent
                    + 'print("NINA-Mesh Entwarnung OK", "Mesh2", "OK" if ok2 else "FAIL")\n'
                )
                src = src[: m.start()] + repl + src[m.end() :]
                changed = True
            else:
                raise SystemExit(
                    "STOP ninaMesh2Direct: Entwarnung-Anker in maybe_mesh_nina nicht gefunden"
                )

    # --- neue Warnung: after Mesh1 OK, also Mesh2 ---
    warn_old = (
        "        if ok:\n"
        "            last_nina_mesh = key\n"
        "            save_nina_mesh_status(key, cleared=None)\n"
        '            print("NINA-Mesh OK:", key[:80])\n'
    )
    warn_new = (
        "        if ok:\n"
        "            last_nina_mesh = key\n"
        "            save_nina_mesh_status(key, cleared=None)\n"
        "            ok2 = send_nina_to_bayern(text[:200])  # " + MARK + "\n"
        '            print("NINA-Mesh OK:", key[:80], "Mesh2", "OK" if ok2 else "FAIL")\n'
    )
    if "ok2 = send_nina_to_bayern(text[:200])  # " + MARK in src:
        pass
    elif warn_old in src:
        src = src.replace(warn_old, warn_new, 1)
        changed = True
    else:
        m = re.search(
            r"(save_nina_mesh_status\(key, cleared=None\)\n)"
            r"(\s+)print\(\"NINA-Mesh OK:\", key\[:80\]\)\n",
            src,
        )
        if m:
            indent = m.group(2)
            repl = (
                m.group(1)
                + indent
                + "ok2 = send_nina_to_bayern(text[:200])  # "
                + MARK
                + "\n"
                + indent
                + 'print("NINA-Mesh OK:", key[:80], "Mesh2", "OK" if ok2 else "FAIL")\n'
            )
            src = src[: m.start()] + repl + src[m.end() :]
            changed = True
        elif MARK in src and "send_nina_to_bayern(text[:200])" in src:
            pass
        else:
            raise SystemExit(
                "STOP ninaMesh2Direct: Warnung-Anker in maybe_mesh_nina nicht gefunden"
            )

    # --- save_nina_mesh_status docstring: JSON bleibt Tile-Quelle, kein Mesh2-TX mehr ---
    old_save_doc = '    """Mesh-2-Quelle: nur nach erfolgreichem Mesh-1-Send."""'
    new_save_doc = (
        '    """Tile/Status-JSON nach Mesh1-OK; Mesh2-TX via :5002 (nicht Mirror). # '
        + MARK
        + '"""'
    )
    if old_save_doc in src:
        src = src.replace(old_save_doc, new_save_doc, 1)
        changed = True

    if MARK not in src or "send_nina_to_bayern(text" not in src:
        raise SystemExit("STOP ninaMesh2Direct: Marker/Mesh2-Call fehlt nach Patch")

    # Assert: Entwarnungen nicht aus Tile-Template entfernt
    if "nina_mesh_status.cleared" not in src:
        raise SystemExit(
            "STOP ninaMesh2Direct: Tile cleared/Entwarnung-Anzeige fehlt — nicht anfassen"
        )

    if src != src0:
        path.write_text(src, encoding="utf-8")
        print("OK dashboard maybe_mesh_nina + :5002 ->", path)
        return True
    print("OK dashboard already ninaMesh2Direct ->", path)
    return False


FORWARD_NINA_NEW = '''def forward_nina():
    """NINA Mesh2: Dashboard sendet direkt :5002 (wie Mesh1). Kein JSON-Mirror (Doppel-TX). # ninaMesh2Direct"""
    return  # ninaMesh2Direct — Mirror absichtlich aus


'''


def patch_reply2(path: Path) -> bool:
    src0 = path.read_text(encoding="utf-8")
    src = src0

    if "def forward_nina(" not in src:
        raise SystemExit("STOP ninaMesh2Direct: forward_nina fehlt in " + str(path))

    # Already disabled?
    if MARK in src and re.search(
        r"def forward_nina\(\):.*?return\s+#\s*" + re.escape(MARK),
        src,
        re.S,
    ):
        print("OK mesh_ping_reply2 forward_nina already disabled ->", path)
        return False

    m = re.search(r"(?ms)^def forward_nina\(\):.*?(?=^def |\Z)", src)
    if not m:
        raise SystemExit("STOP ninaMesh2Direct: forward_nina Block nicht extrahierbar")

    src = src[: m.start()] + FORWARD_NINA_NEW + src[m.end() :]
    # keep call site — harmless no-op
    if "forward_nina()" not in src:
        raise SystemExit("STOP ninaMesh2Direct: forward_nina() Aufruf fehlt unerwartet")

    path.write_text(src, encoding="utf-8")
    print("OK mesh_ping_reply2 forward_nina disabled (direct :5002) ->", path)
    return True


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    dash = root / "dashboard.py" if root.is_dir() else root
    if not dash.is_file():
        raise SystemExit("STOP ninaMesh2Direct: fehlt " + str(dash))
    reply = dash.parent / "mesh_ping_reply2.py"
    patch_dashboard(dash)
    if reply.is_file():
        patch_reply2(reply)
    else:
        print("WARN mesh_ping_reply2.py fehlt — nur Dashboard gepatcht:", reply)


if __name__ == "__main__":
    main()
