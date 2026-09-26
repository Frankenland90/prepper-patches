#!/usr/bin/env python3
"""Rewrite patch-mesh-traceroute-remove.py on Pi so _strip_do_post never deletes /send.
Additive: if the target already has the has_send guard, no-op.
Also usable offline against a local copy of the remove patcher.
Mark: # meshTraceRemoveGuard
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "# meshTraceRemoveGuard"

SAFE_STRIP_DO_POST = r'''
    def _strip_do_post(m: re.Match) -> str:
        """Strip traceroute from do_POST. NEVER delete a method that has /send."""
        body = m.group(0)
        has_send = (
            'startswith("/send")' in body
            or "startswith('/send')" in body
            or "/send" in body
        )
        if "traceroute" not in body and "meshTraceManual" not in body:
            return body

        def _strip_trace_blocks(b: str) -> str:
            # Injected preamble at start of do_POST
            b2 = re.sub(
                r"(?ms)^([ \t]*def do_POST\(self\):\s*\n)"
                r"(?:[ \t]*global _trace_busy[^\n]*\n)?"
                r"(?:[ \t]*_tp\s*=[^\n]*\n)?"
                r"(?:[ \t]*path\s*=[^\n]*\n)?"
                r"(?:([ \t]*)if[^\n]*traceroute[^\n]*:[^\n]*\n(?:\2[ \t]+[^\n]*\n)+)",
                r"\1",
                b,
                count=1,
            )
            # Any remaining traceroute if-blocks
            b2 = re.sub(
                r"(?ms)^([ \t]*)if[^\n]*traceroute[^\n]*:[^\n]*\n(?:\1[ \t]+[^\n]*\n)+",
                "",
                b2,
            )
            # global _trace_busy leftover lines
            b2 = re.sub(r"(?m)^[ \t]*global _trace_busy[^\n]*\n", "", b2)
            return b2

        # Critical guard: never return "" (delete whole method) if /send present
        if has_send:
            body2 = _strip_trace_blocks(body)
            if not (
                'startswith("/send")' in body2
                or "startswith('/send')" in body2
                or "/send" in body2
            ):
                # Stripping accidentally ate /send — keep original body
                return body
            return body2

        # No /send: pure traceroute do_POST may be dropped entirely
        if (
            "meshTraceManual" in body
            or "/traceroute/run" in body
            or "traceroute_run_once" in body
        ):
            if body.count("def ") == 1 and (
                "meshTraceManual" in body
                or ("_trace_busy" in body and "traceroute" in body)
            ):
                other = re.sub(
                    r"(?ms)[^\n]*traceroute[^\n]*\n|(?:[ \t]+[^\n]*_trace_busy[^\n]*\n)|"
                    r"(?:[ \t]+[^\n]*traceroute_run_once[^\n]*\n)",
                    "",
                    body,
                )
                if re.search(r"(?m)^[ \t]*if[ \t]+", other) and "traceroute" not in other:
                    return _strip_trace_blocks(body)
                return ""

        body2 = _strip_trace_blocks(body)
        if re.match(
            r"(?ms)^[ \t]*def do_POST\(self\):\s*\n(?:[ \t]*pass\s*\n)?\s*\Z",
            body2,
        ):
            return ""
        return body2
'''.lstrip("\n")


def _replace_strip_do_post(src: str) -> str:
    """Replace nested def _strip_do_post ... up to (not including) the re.sub that uses it."""
    # Locate nested function inside _strip_manual_leftovers
    m = re.search(
        r"(?ms)^(?P<indent>[ \t]*)def _strip_do_post\(m: re\.Match\) -> str:.*?"
        r"(?=^[ \t]*src = re\.sub\()",
        src,
    )
    if not m:
        raise SystemExit(
            "STOP meshTraceRemoveGuard: _strip_do_post nicht gefunden — "
            "unerwartete patch-mesh-traceroute-remove.py"
        )
    return src[: m.start()] + SAFE_STRIP_DO_POST + "\n" + src[m.end() :]


def guard(path: Path) -> bool:
    if not path.is_file():
        print(f"WARN meshTraceRemoveGuard: fehlt {path} — übersprungen")
        return False
    src0 = path.read_text(encoding="utf-8")
    if "has_send" in src0 and "NEVER delete a method that has /send" in src0:
        print(f"OK meshTraceRemoveGuard already safe -> {path}")
        return False
    if "def _strip_do_post" not in src0:
        raise SystemExit(f"STOP meshTraceRemoveGuard: kein _strip_do_post in {path}")

    src = _replace_strip_do_post(src0)
    if "NEVER deletes a do_POST that contains /send" not in src:
        # annotate docstring once
        src = src.replace(
            "  - leftover _trace_busy, traceroute_run_once, do_POST traceroute\n",
            "  - leftover _trace_busy, traceroute_run_once, do_POST traceroute\n"
            "NEVER deletes a do_POST that contains /send (keeps hold/resume/send).\n",
            1,
        )
    if "has_send" not in src:
        raise SystemExit("STOP meshTraceRemoveGuard: Guard-Insert fehlgeschlagen")

    path.write_text(src, encoding="utf-8")
    print(f"OK meshTraceRemoveGuard applied -> {path} {MARK}")
    return True


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    if root.is_file() and root.name.endswith(".py"):
        guard(root)
        return
    target = root / "patch-mesh-traceroute-remove.py"
    guard(target)


if __name__ == "__main__":
    main()
