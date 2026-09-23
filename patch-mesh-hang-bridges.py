#!/usr/bin/env python3
"""Beide Bridges + Ping-Reply: reply_watch note_rx/note_tx. # meshHangBridge / # meshHangPing"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK_B = "# meshHangBridge"
MARK_P = "# meshHangPing"


def _ensure_import(src: str, mod: str, mark: str) -> str:
    needle = f"import {mod}"
    if needle in src:
        return src
    # Prefer after mesh_node_label / mesh_chutil / pathlib
    for anchor in (
        "import mesh_node_label",
        "import mesh_chutil",
        "from pathlib import Path\n",
    ):
        if anchor in src:
            if anchor.endswith("\n"):
                return src.replace(anchor, anchor + f"import {mod}  # {mark}\n", 1)
            idx = src.find(anchor)
            end = src.find("\n", idx)
            if end < 0:
                end = len(src)
            line = src[idx:end]
            return src.replace(line, line + f"\nimport {mod}  # {mark}", 1)
    # Fallback: after first import block
    m = re.search(r"(^(?:import |from ).+\n)+", src, re.M)
    if m:
        pos = m.end()
        return src[:pos] + f"import {mod}  # {mark}\n" + src[pos:]
    # No imports at all — prepend
    return f"import {mod}  # {mark}\n" + src


def _line_indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip(" \t"))]


def _indent_block(block: str, ind: str) -> str:
    out = []
    for ln in block.splitlines():
        if not ln.strip():
            out.append("")
            continue
        # strip existing leading spaces from template, re-indent
        out.append(ind + ln.lstrip())
    return "\n".join(out) + "\n"


def _insert_after_line_containing(src: str, needles, insert: str, label: str) -> tuple[str, bool]:
    """Insert once after first line matching any needle substring; match indent."""
    # idempotent: any note_rx/note_tx already for this insert marker
    marker = None
    if "note_rx" in insert:
        marker = "mesh_reply_watch.note_rx"
    elif "note_tx" in insert:
        marker = "mesh_reply_watch.note_tx"
    if marker and marker in src and ("meshHangBridge" in src or "meshHangPing" in src):
        # still allow if this specific mesh key not yet present — check insert body
        keybit = None
        for part in insert.split('"'):
            if part in ("m1", "m2"):
                keybit = part
                break
        if keybit and f'note_r' in insert:
            pass
        if insert.strip().split("\n")[0].strip() in src.replace(" ", ""):
            # loose
            pass
    if "mesh_reply_watch.note_rx" in insert and "mesh_reply_watch.note_rx" in src:
        # check mesh key
        import re as _re
        m = _re.search(r'note_rx\("([^"]+)"', insert)
        if m and f'note_rx("{m.group(1)}"' in src:
            return src, True
    if "mesh_reply_watch.note_tx" in insert and "mesh_reply_watch.note_tx" in src:
        import re as _re
        m = _re.search(r'note_tx\("([^"]+)"', insert)
        if m and f'note_tx("{m.group(1)}"' in src:
            return src, True

    lines = src.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if any(n in line for n in needles):
            window = "".join(lines[i : min(i + 5, len(lines))])
            if "mesh_reply_watch.note_" in window and (
                ("note_rx" in insert and "note_rx" in window)
                or ("note_tx" in insert and "note_tx" in window)
            ):
                return src, True
            ind = _line_indent(line)
            # if anchor is an if/for/def that ends with :, indent one level deeper
            bare = line.rstrip("\n")
            if bare.rstrip().endswith(":"):
                # detect indent style
                step = "    " if "    " in ind or ind == "" else "\t"
                if ind.startswith("\t"):
                    step = "\t"
                child = ind + step
            else:
                child = ind
            block = _indent_block(insert, child)
            lines.insert(i + 1, block)
            return "".join(lines), True
    return src, False


def patch_bridge(path: Path, mesh_key: str, label: str) -> None:
    if not path.exists():
        print("skip missing", path)
        return
    src = path.read_text(encoding="utf-8")
    if MARK_B in src and "mesh_reply_watch.note_rx" in src and "mesh_reply_watch.note_tx" in src:
        print(label, "schon gepatcht")
        return

    src = _ensure_import(src, "mesh_reply_watch", MARK_B)

    # RX: after Pong-Trigger log (preferred) or ping/test detect
    rx_line = (
        f'        try:\n'
        f'            mesh_reply_watch.note_rx("{mesh_key}", _from_id(packet) if "_from_id" in dir() else None)  # {MARK_B}\n'
        f'        except Exception:\n'
        f'            pass\n'
    )
    # simpler single-line insert preferred for bridges
    rx_simple = (
        f'        try: mesh_reply_watch.note_rx("{mesh_key}")  # {MARK_B}\n'
        f'        except Exception: pass\n'
    )
    tx_simple = (
        f'        try: mesh_reply_watch.note_tx("{mesh_key}")  # {MARK_B}\n'
        f'        except Exception: pass\n'
    )

    src2, ok_rx = _insert_after_line_containing(
        src,
        ['log("Pong-Trigger:"', "log('Pong-Trigger:'", "Pong-Trigger:"],
        rx_simple,
        label + " rx",
    )
    if not ok_rx:
        # resilient: find ping/test branch
        m = re.search(
            r"(?m)^(?P<ind>\s*).*(?:text|tl|msg).*(?:\.strip\(\)|\.lower\(\)).*\n"
            r"(?P=ind).*(?:ping|test).*\n",
            src2,
        )
        if m:
            # insert after a nearby block — find first 'ping' check line
            src2, ok_rx = _insert_after_line_containing(
                src2,
                ['in ("ping"', "in ('ping'", '== "ping"', "== 'ping'", '== "test"', ".lower() in"],
                rx_simple,
                label + " rx-fallback",
            )
        if not ok_rx:
            print(f"WARN {label}: kein Pong-Trigger/ping Anker für note_rx — suche sendText Umgebung")

    src3, ok_tx = _insert_after_line_containing(
        src2,
        [
            "sendText(",
            ".sendText(",
            "iface.sendText",
            "_iface.sendText",
        ],
        tx_simple,
        label + " tx",
    )
    # Prefer: insert after the reply send that follows Pong — if multiple sendText, first after Pong-Trigger
    if ok_tx and "Pong-Trigger" in src3:
        # Re-do more carefully: find Pong-Trigger, then first sendText after it
        if src3.count(f'mesh_reply_watch.note_tx("{mesh_key}")') == 0:
            pass
        # If note_tx landed before Pong (wrong sendText), relocate
        pong_i = src3.find("Pong-Trigger")
        tx_i = src3.find(f'mesh_reply_watch.note_tx("{mesh_key}")')
        if pong_i >= 0 and 0 <= tx_i < pong_i:
            # remove misplaced and re-insert after first sendText after pong
            src3 = src3.replace(tx_simple, "", 1)
            after = src3[pong_i:]
            m = re.search(r"(?m)^.*sendText\(.*$", after)
            if m:
                abs_line_start = pong_i + m.start()
                # find end of that line
                abs_line_end = src3.find("\n", abs_line_start)
                if abs_line_end < 0:
                    abs_line_end = len(src3)
                else:
                    abs_line_end += 1
                src3 = src3[:abs_line_end] + tx_simple + src3[abs_line_end:]
                ok_tx = True
            else:
                ok_tx = False

    if not ok_rx:
        print(f"WARN {label}: note_rx nicht gesetzt — manuell prüfen")
    if not ok_tx:
        # last resort: after Hops von reply string build
        src3, ok_tx = _insert_after_line_containing(
            src3,
            ["Hops ", "· von "],
            tx_simple,
            label + " tx-hops",
        )
        if not ok_tx:
            print(f"WARN {label}: note_tx nicht gesetzt — manuell prüfen")

    if MARK_B not in src3:
        # ensure marker somewhere if imports added
        src3 = src3.replace(
            "import mesh_reply_watch",
            f"import mesh_reply_watch  # {MARK_B}",
            1,
        )

    path.write_text(src3, encoding="utf-8")
    has_rx = "mesh_reply_watch.note_rx" in src3
    has_tx = "mesh_reply_watch.note_tx" in src3
    print("OK", label, "->", path, "rx=", has_rx, "tx=", has_tx)


def patch_ping_reply(path: Path, mesh_key: str) -> None:
    if not path.exists():
        print("skip missing", path.name)
        return
    src = path.read_text(encoding="utf-8")
    if MARK_P in src and "mesh_reply_watch.note_rx" in src and "mesh_reply_watch.note_tx" in src:
        print(path.name, "schon gepatcht")
        return

    src = _ensure_import(src, "mesh_reply_watch", MARK_P)

    rx_simple = (
        f'        try: mesh_reply_watch.note_rx("{mesh_key}")  # {MARK_P}\n'
        f'        except Exception: pass\n'
    )
    tx_simple = (
        f'        try: mesh_reply_watch.note_tx("{mesh_key}")  # {MARK_P}\n'
        f'        except Exception: pass\n'
    )

    # Typical patterns in reply scripts
    # Prefer inside ping/test branch (after if … ping)
    src, ok_rx = _insert_after_line_containing(
        src,
        [
            'in ("ping"',
            "in ('ping'",
            '== "ping"',
            "== 'ping'",
            '== "test"',
            "Pong-Trigger",
            "trigger",
        ],
        rx_simple,
        path.name + " rx",
    )
    if not ok_rx:
        # insert near onReceive / on_receive handler start after text extract
        src, ok_rx = _insert_after_line_containing(
            src,
            ["def onReceive", "def on_receive", "decoded.get", "get('text'"],
            rx_simple,
            path.name + " rx2",
        )

    src, ok_tx = _insert_after_line_containing(
        src,
        ["sendText(", ".sendText(", "send_text("],
        tx_simple,
        path.name + " tx",
    )
    if not ok_tx:
        src, ok_tx = _insert_after_line_containing(
            src,
            ["Hops ", "· von ", "build_a("],
            tx_simple,
            path.name + " tx2",
        )

    if MARK_P not in src:
        src = src.replace(
            "import mesh_reply_watch",
            f"import mesh_reply_watch  # {MARK_P}",
            1,
        )

    path.write_text(src, encoding="utf-8")
    print(
        "OK",
        path.name,
        "rx=",
        "mesh_reply_watch.note_rx" in src,
        "tx=",
        "mesh_reply_watch.note_tx" in src,
    )


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    patch_bridge(root / "mesh_bridge.py", "m1", "mesh1")
    patch_bridge(root / "mesh_bridge_bayern.py", "m2", "mesh2")
    patch_ping_reply(root / "mesh_ping_reply.py", "m1")
    patch_ping_reply(root / "mesh_ping_reply2.py", "m2")
    # optional bayern alias
    p = root / "mesh_ping_reply_bayern.py"
    if p.exists():
        patch_ping_reply(p, "m2")


if __name__ == "__main__":
    main()
