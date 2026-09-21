#!/usr/bin/env python3
"""mesh_ping_reply*.py: von Name (id). /* pingName */"""
from pathlib import Path
import sys

MARK = "/* pingName */"

HELPER = """
def _from_label(interface, from_id):  # /* pingName */
    try:
        import mesh_node_label
        return mesh_node_label.label_from_iface(interface, from_id)
    except Exception:
        return str(from_id or "?")

"""


def patch_build_a(src: str) -> str:
    if "def build_a(packet, from_id, rx, tx):" in src:
        src = src.replace(
            "def build_a(packet, from_id, rx, tx):",
            "def build_a(packet, from_id, rx, tx, from_label=None):  # " + MARK,
            1,
        )
    old = '    extra.append("von %s" % from_id)\n'
    new = '    extra.append("von %s" % (from_label or from_id))  # ' + MARK + "\n"
    if old in src:
        src = src.replace(old, new, 1)
    old_call = "        msg = build_a(packet, from_id, rx, now_hms())\n"
    new_call = (
        "        msg = build_a(packet, from_id, rx, now_hms(), "
        "_from_label(interface, from_id))  # " + MARK + "\n"
    )
    if old_call in src:
        src = src.replace(old_call, new_call, 1)
    if "def _from_label" not in src:
        if "def build_a(" in src:
            src = src.replace("def build_a(", HELPER + "def build_a(", 1)
        else:
            raise SystemExit("STOP: build_a fehlt")
    return src


def patch_reply2(src: str) -> str:
    old = '            "Hops %s · von %s" % (hops if hops is not None else "–", from_id),\n'
    new = (
        '            "Hops %s · von %s" % (hops if hops is not None else "–", '
        "_from_label(iface, from_id)),  # " + MARK + "\n"
    )
    if old not in src:
        if MARK in src and "_from_label" in src:
            return src
        raise SystemExit("STOP reply2 von-Anker")
    src = src.replace(old, new, 1)
    if "def _from_label" not in src:
        anchor = 'def now_hms():\n    return datetime.now().strftime("%H:%M:%S")\n'
        if anchor not in src:
            raise SystemExit("STOP reply2 now_hms")
        src = src.replace(anchor, anchor + "\n" + HELPER, 1)
    return src


def patch_file(path: Path):
    src = path.read_text(encoding="utf-8")
    if path.name == "mesh_ping_reply2.py":
        src = patch_reply2(src)
    else:
        src = patch_build_a(src)
    path.write_text(src, encoding="utf-8")
    print("OK", path.name)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    for n in ("mesh_ping_reply.py", "mesh_ping_reply2.py", "mesh_ping_reply_bayern.py"):
        p = root / n
        if p.exists():
            patch_file(p)
        else:
            print("skip missing", n)


if __name__ == "__main__":
    main()
