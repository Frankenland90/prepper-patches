#!/usr/bin/env python3
"""Bridge Pong: Node-Name + ID. /* pingName */"""
from pathlib import Path
import sys

MARK = "/* pingName */"
OLD = '            f"Hops {_hops(packet)} · von {_from_id(packet)}"\n'
NEW = (
    '            f"Hops {_hops(packet)} · von '
    '{mesh_node_label.label_from_iface(_iface, _from_id(packet))}"'
    f"  # {MARK}\n"
)


def patch(path: Path):
    src = path.read_text(encoding="utf-8")
    if MARK in src and "mesh_node_label.label_from_iface" in src:
        print(path.name, "schon gepatcht")
        return
    if "import mesh_node_label" not in src:
        if "import mesh_chutil" in src:
            src = src.replace(
                "import mesh_chutil  # /* chutilBridge */\n",
                "import mesh_chutil  # /* chutilBridge */\n"
                "import mesh_node_label  # %s\n" % MARK,
                1,
            )
        if "import mesh_node_label" not in src:
            needle = "from pathlib import Path\n"
            if needle not in src:
                raise SystemExit("STOP pathlib: %s" % path)
            src = src.replace(needle, needle + "import mesh_node_label  # %s\n" % MARK, 1)
    if OLD not in src:
        raise SystemExit("STOP von-Anker fehlt: %s" % path)
    src = src.replace(OLD, NEW, 1)
    old_log = '        log("Pong-Trigger:", text, "von", _from_id(packet))\n'
    new_log = (
        '        log("Pong-Trigger:", text, "von", '
        "mesh_node_label.label_from_iface(_iface, _from_id(packet))"
        f")  # {MARK}\n"
    )
    if old_log in src:
        src = src.replace(old_log, new_log, 1)
    path.write_text(src, encoding="utf-8")
    print("OK", path)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    patch(root / "mesh_bridge.py")
    patch(root / "mesh_bridge_bayern.py")


if __name__ == "__main__":
    main()
