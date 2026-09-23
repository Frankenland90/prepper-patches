#!/usr/bin/env python3
"""Reply-watch via exact anchors (pingName / Pong-Trigger). # meshHangBridge / # meshHangPing"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK_B = "meshHangBridge"
MARK_P = "meshHangPing"


def _ensure_import(src: str, mod: str, mark: str) -> str:
    if re.search(r"(?m)^import " + re.escape(mod) + r"\b", src):
        return src
    # Only module-level imports (start of line) — never inside try/helpers
    for pat in (
        r"(?m)^(import mesh_node_label[^\n]*\n)",
        r"(?m)^(import mesh_chutil[^\n]*\n)",
        r"(?m)^(from pathlib import Path\n)",
    ):
        m = re.search(pat, src)
        if m:
            return src[: m.end()] + f"import {mod}  # {mark}\n" + src[m.end() :]
    block = re.search(r"(?m)^(?:(?:import |from ).+\n)+", src)
    if block:
        return src[: block.end()] + f"import {mod}  # {mark}\n" + src[block.end() :]
    return f"import {mod}  # {mark}\n" + src


def _line_indent(line: str) -> str:
    return line[: len(line) - len(line.lstrip(" \t"))]


def _stmt_end_index(src: str, line_start: int) -> int:
    i, n = line_start, len(src)
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


def _strip_note_watch(src: str) -> str:
    """Remove only mesh_reply_watch inserts (not unrelated try/except)."""
    src = re.sub(
        r'(?m)^[ \t]*try:\s*mesh_reply_watch\.note_(?:rx|tx)\("[^"]+"\)[^\n]*\n'
        r"[ \t]*except Exception:\s*pass\n",
        "",
        src,
    )
    src = re.sub(
        r"(?m)^[ \t]*try:\s*\n"
        r'[ \t]+mesh_reply_watch\.note_(?:rx|tx)\("[^"]+"\)[^\n]*\n'
        r"[ \t]*except Exception:\s*\n"
        r"[ \t]+pass\n",
        "",
        src,
    )
    if "mesh_reply_watch.note_" not in src:
        src = re.sub(r"(?m)^import mesh_reply_watch[^\n]*\n", "", src)
    return src


def _insert_after_exact_line(
    src: str, exact_line: str, block_lines: list[str], key_snip: str
) -> tuple[str, bool]:
    if key_snip in src:
        return src, True
    lines = src.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.rstrip("\n") == exact_line.rstrip("\n"):
            ind = _line_indent(line)
            block = "".join(ind + ln + "\n" for ln in block_lines)
            lines.insert(i + 1, block)
            return "".join(lines), True
    return src, False


def _insert_after_substring_line(
    src: str, substr: str, block_lines: list[str], key_snip: str
) -> tuple[str, bool]:
    if key_snip in src:
        return src, True
    lines = src.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if substr in line and "mesh_reply_watch" not in line:
            # Skip mid-list / trailing-comma lines (reply2 Hops row)
            stripped = line.rstrip("\n").rstrip()
            if stripped.endswith(",") or stripped.endswith("(") or stripped.endswith("\\"):
                continue
            ind = _line_indent(line)
            block = "".join(ind + ln + "\n" for ln in block_lines)
            lines.insert(i + 1, block)
            return "".join(lines), True
    return src, False


_SEND_PATS = [
    r"(?m)^[^\n]*\b_iface\.sendText\s*\(",
    r"(?m)^[^\n]*\biface\.sendText\s*\(",
    r"(?m)^[^\n]*\binterface\.sendText\s*\(",
    r"(?m)^[^\n]*\.sendText\s*\(",
    r"(?m)^[^\n]*\bsend_reply\s*\(",
]


def _find_send_matches(region: str) -> list[re.Match[str]]:
    found: list[re.Match[str]] = []
    for pat in _SEND_PATS:
        found.extend(re.finditer(pat, region))
    found.sort(key=lambda m: m.start())
    out: list[re.Match[str]] = []
    seen: set[int] = set()
    for m in found:
        if m.start() in seen:
            continue
        seen.add(m.start())
        out.append(m)
    return out


def _insert_note_tx_after_send(
    src: str, mesh_key: str, mark: str, *, after_pos: int = 0, before_pos: int | None = None
) -> tuple[str, bool]:
    """Insert note_tx after a sendText call. Prefer last send before before_pos (bridges)."""
    key = f'mesh_reply_watch.note_tx("{mesh_key}")'
    if key in src:
        return src, True
    end = before_pos if before_pos is not None else len(src)
    if end <= after_pos:
        return src, False
    region = src[after_pos:end]
    matches = _find_send_matches(region)
    if not matches:
        return src, False
    m = matches[-1]
    abs_match = after_pos + m.start()
    line_start = src.rfind("\n", 0, abs_match) + 1
    stmt_end = _stmt_end_index(src, line_start)
    if before_pos is not None and stmt_end > before_pos:
        stmt_end = before_pos
    nl = src.find("\n", line_start)
    ind = _line_indent(src[line_start : nl if nl >= 0 else len(src)])
    block_lines = [
        "try:",
        f'    mesh_reply_watch.note_tx("{mesh_key}")  # {mark}',
        "except Exception:",
        "    pass",
    ]
    block = "".join(ind + ln + "\n" for ln in block_lines)
    return src[:stmt_end] + block + src[stmt_end:], True


def _insert_note_rx_before_send(src: str, mesh_key: str, mark: str) -> tuple[str, bool]:
    key = f'mesh_reply_watch.note_rx("{mesh_key}")'
    if key in src:
        return src, True
    matches = _find_send_matches(src)
    if not matches:
        return src, False
    m = matches[0]
    line_start = src.rfind("\n", 0, m.start()) + 1
    nl = src.find("\n", line_start)
    ind = _line_indent(src[line_start : nl if nl >= 0 else len(src)])
    block_lines = [
        "try:",
        f'    mesh_reply_watch.note_rx("{mesh_key}")  # {mark}',
        "except Exception:",
        "    pass",
    ]
    block = "".join(ind + ln + "\n" for ln in block_lines)
    return src[:line_start] + block + src[line_start:], True


def patch_bridge(path: Path, mesh_key: str, label: str) -> None:
    if not path.exists():
        print("skip missing", path)
        return
    src = _strip_note_watch(path.read_text(encoding="utf-8"))
    src = _ensure_import(src, "mesh_reply_watch", MARK_B)

    rx_lines = [
        "try:",
        f'    mesh_reply_watch.note_rx("{mesh_key}")  # {MARK_B}',
        "except Exception:",
        "    pass",
    ]
    ok_rx = False
    for exact in (
        '        log("Pong-Trigger:", text, "von", mesh_node_label.label_from_iface(_iface, _from_id(packet)))  # /* pingName */',
        '        log("Pong-Trigger:", text, "von", _from_id(packet))',
        '        log("Pong-Trigger:", text, "von", mesh_node_label.label_from_iface(_iface, _from_id(packet)))',
    ):
        src, ok = _insert_after_exact_line(
            src, exact, rx_lines, f'mesh_reply_watch.note_rx("{mesh_key}")'
        )
        if ok and f'mesh_reply_watch.note_rx("{mesh_key}")' in src:
            ok_rx = True
            break
    if not ok_rx:
        src, ok_rx = _insert_after_substring_line(
            src,
            "Pong-Trigger:",
            rx_lines,
            f'mesh_reply_watch.note_rx("{mesh_key}")',
        )

    # Bridges: iface.sendText is BEFORE the Pong-Trigger log line
    pong = src.find("Pong-Trigger")
    if pong < 0:
        pong = len(src)
    window_start = max(0, pong - 4000)
    src, ok_tx = _insert_note_tx_after_send(
        src, mesh_key, MARK_B, after_pos=window_start, before_pos=pong
    )
    if not ok_tx:
        src, ok_tx = _insert_note_tx_after_send(src, mesh_key, MARK_B, after_pos=0)

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
    src = _strip_note_watch(path.read_text(encoding="utf-8"))
    src = _ensure_import(src, "mesh_reply_watch", MARK_P)

    rx_lines = [
        "try:",
        f'    mesh_reply_watch.note_rx("{mesh_key}")  # {MARK_P}',
        "except Exception:",
        "    pass",
    ]

    ok_rx = False
    # reply2 Hops-row is a mid-list string — never insert after it
    is_reply2 = path.name.startswith("mesh_ping_reply2") or "bayern" in path.name

    if not is_reply2:
        for exact in (
            "        msg = build_a(packet, from_id, rx, now_hms(), _from_label(interface, from_id))  # /* pingName */",
            "        msg = build_a(packet, from_id, rx, now_hms())",
        ):
            src, ok = _insert_after_exact_line(
                src, exact, rx_lines, f'mesh_reply_watch.note_rx("{mesh_key}")'
            )
            if ok and f'mesh_reply_watch.note_rx("{mesh_key}")' in src:
                ok_rx = True
                break
        if not ok_rx:
            src, ok_rx = _insert_after_substring_line(
                src,
                "msg = build_a(",
                rx_lines,
                f'mesh_reply_watch.note_rx("{mesh_key}")',
            )

    if f'mesh_reply_watch.note_rx("{mesh_key}")' not in src:
        src, ok_rx = _insert_note_rx_before_send(src, mesh_key, MARK_P)

    src, ok_tx = _insert_note_tx_after_send(src, mesh_key, MARK_P, after_pos=0)

    compile(src, str(path), "exec")
    path.write_text(src, encoding="utf-8")
    print(f"OK {path.name} rx={ok_rx} tx={ok_tx}")
    if not ok_rx:
        print(f"WARN {path.name}: note_rx fehlt")
    if not ok_tx:
        print(f"WARN {path.name}: note_tx fehlt")


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
