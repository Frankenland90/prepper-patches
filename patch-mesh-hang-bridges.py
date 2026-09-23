#!/usr/bin/env python3
"""Beide Bridges + Ping-Reply: reply_watch note_rx/note_tx. # meshHangBridge / # meshHangPing"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK_B = "meshHangBridge"
MARK_P = "meshHangPing"


def _ensure_import(src: str, mod: str, mark: str) -> str:
    if f"import {mod}" in src:
        return src
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
    m = re.search(r"(^(?:import |from ).+\n)+", src, re.M)
    if m:
        return src[: m.end()] + f"import {mod}  # {mark}\n" + src[m.end() :]
    return f"import {mod}  # {mark}\n" + src


def _line_indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip(" \t"))]


def _stmt_end_index(src: str, line_start: int) -> int:
    """Index just after the statement starting at line_start (balances (), [], {})."""
    i = line_start
    n = len(src)
    paren = bracket = brace = 0
    in_s = None
    escape = False
    while i < n:
        ch = src[i]
        if in_s is not None:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == in_s:
                in_s = None
            i += 1
            continue
        if ch in ("'", '"'):
            in_s = ch
            i += 1
            continue
        if ch == "(":
            paren += 1
        elif ch == ")":
            paren = max(0, paren - 1)
        elif ch == "[":
            bracket += 1
        elif ch == "]":
            bracket = max(0, bracket - 1)
        elif ch == "{":
            brace += 1
        elif ch == "}":
            brace = max(0, brace - 1)
        elif ch == "\n" and paren == 0 and bracket == 0 and brace == 0:
            return i + 1
        i += 1
    return n


def _strip_broken_inserts(src: str) -> str:
    """Remove previous bad one-liner / mid-call inserts."""
    src = re.sub(
        r'(?m)^[ \t]*try:\s*mesh_reply_watch\.note_(?:rx|tx)\("[^"]+"\)[^\n]*\n'
        r'[ \t]*except Exception:\s*pass\n',
        "",
        src,
    )
    src = re.sub(
        r'(?m)^[ \t]*try:\s*\n'
        r'[ \t]+mesh_reply_watch\.note_(?:rx|tx)\("[^"]+"\)[^\n]*\n'
        r'[ \t]*except Exception:\s*\n'
        r'[ \t]+pass\n',
        "",
        src,
    )
    return src


def _block(ind: str, lines: list[str]) -> str:
    return "".join(ind + ln + "\n" for ln in lines)


def _insert_rx_tx(src: str, mesh_key: str, mark: str) -> tuple[str, bool, bool]:
    rx_lines = [
        "try:",
        f'    mesh_reply_watch.note_rx("{mesh_key}")  # {mark}',
        "except Exception:",
        "    pass",
    ]
    tx_lines = [
        "try:",
        f'    mesh_reply_watch.note_tx("{mesh_key}")  # {mark}',
        "except Exception:",
        "    pass",
    ]
    ok_rx = f'mesh_reply_watch.note_rx("{mesh_key}")' in src
    ok_tx = f'mesh_reply_watch.note_tx("{mesh_key}")' in src

    if not ok_rx:
        for pat in (
            r"(?m)^[^\n]*Pong-Trigger[^\n]*$",
            r'(?m)^[^\n]*["\']ping["\'][^\n]*["\']test["\'][^\n]*$',
            r'(?m)^[^\n]*\bping\b[^\n]*\btest\b[^\n]*$',
        ):
            m = re.search(pat, src)
            if not m:
                continue
            line_start = src.rfind("\n", 0, m.start()) + 1
            end = _stmt_end_index(src, line_start)
            ind = _line_indent(src[line_start : src.find("\n", line_start)])
            src = src[:end] + _block(ind, rx_lines) + src[end:]
            ok_rx = True
            break

    if not ok_tx:
        pong = src.find("Pong-Trigger")
        region_from = pong if pong >= 0 else 0
        region = src[region_from:]
        m = re.search(r"(?m)^[^\n]*\.?sendText\s*\(", region)
        if m:
            abs_match = region_from + m.start()
            line_start = src.rfind("\n", 0, abs_match) + 1
            end = _stmt_end_index(src, line_start)
            ind = _line_indent(src[line_start : src.find("\n", line_start)])
            src = src[:end] + _block(ind, tx_lines) + src[end:]
            ok_tx = True

    return src, ok_rx, ok_tx


def patch_bridge(path: Path, mesh_key: str, label: str) -> None:
    if not path.exists():
        print("skip missing", path)
        return
    src = path.read_text(encoding="utf-8")
    src = _strip_broken_inserts(src)
    if (
        MARK_B in src
        and f'mesh_reply_watch.note_rx("{mesh_key}")' in src
        and f'mesh_reply_watch.note_tx("{mesh_key}")' in src
    ):
        compile(src, str(path), "exec")
        path.write_text(src, encoding="utf-8")
        print(label, "schon gepatcht (bereinigt)")
        return

    src = _ensure_import(src, "mesh_reply_watch", MARK_B)
    src, ok_rx, ok_tx = _insert_rx_tx(src, mesh_key, MARK_B)
    compile(src, str(path), "exec")
    path.write_text(src, encoding="utf-8")
    print(f"OK {label} -> {path} rx={ok_rx} tx={ok_tx}")
    if not ok_rx:
        print(f"WARN {label}: note_rx fehlt")
    if not ok_tx:
        print(f"WARN {label}: note_tx fehlt")


def patch_ping_reply(path: Path, mesh_key: str) -> None:
    if not path.exists():
        print("skip missing", path)
        return
    src = path.read_text(encoding="utf-8")
    src = _strip_broken_inserts(src)
    if (
        MARK_P in src
        and f'mesh_reply_watch.note_rx("{mesh_key}")' in src
        and f'mesh_reply_watch.note_tx("{mesh_key}")' in src
    ):
        compile(src, str(path), "exec")
        path.write_text(src, encoding="utf-8")
        print(path.name, "schon gepatcht (bereinigt)")
        return

    src = _ensure_import(src, "mesh_reply_watch", MARK_P)
    src, ok_rx, ok_tx = _insert_rx_tx(src, mesh_key, MARK_P)
    if not ok_rx:
        m = re.search(r"(?m)^[^\n]*\b(?:ping|test)\b[^\n]*$", src)
        if m:
            line_start = src.rfind("\n", 0, m.start()) + 1
            end = _stmt_end_index(src, line_start)
            ind = _line_indent(src[line_start : src.find("\n", line_start)])
            rx_lines = [
                "try:",
                f'    mesh_reply_watch.note_rx("{mesh_key}")  # {MARK_P}',
                "except Exception:",
                "    pass",
            ]
            src = src[:end] + _block(ind, rx_lines) + src[end:]
            ok_rx = True
    compile(src, str(path), "exec")
    path.write_text(src, encoding="utf-8")
    print(f"OK {path.name} rx={ok_rx} tx={ok_tx}")


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    patch_bridge(root / "mesh_bridge.py", "m1", "mesh1")
    patch_bridge(root / "mesh_bridge_bayern.py", "m2", "mesh2")
    patch_ping_reply(root / "mesh_ping_reply.py", "m1")
    patch_ping_reply(root / "mesh_ping_reply2.py", "m2")
    p = root / "mesh_ping_reply_bayern.py"
    if p.exists():
        patch_ping_reply(p, "m2")
    print("OK patch-mesh-hang-bridges done")


if __name__ == "__main__":
    main()
