#!/usr/bin/env python3
"""Mesh1 only: strip ALL traceroute bits from mesh_bridge.py. /* meshTraceRemove */
Idempotent: second run is a no-op / safe. Leaves hang/chutil intact.
Removes:
  - import mesh_traceroute
  - TRACE_DEST / TRACE_FILE / TRACE_* constants
  - def traceroute_worker(): ... until next top-level def
  - threading.Thread(target=traceroute_worker ...)
  - /traceroute GET handler in do_GET
  - leftover _trace_busy, traceroute_run_once, do_POST traceroute
NEVER deletes a do_POST that contains /send (keeps hold/resume/send).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "/* meshTraceRemove */"


def _strip_import(src: str) -> str:
    src = re.sub(
        r"(?m)^import mesh_traceroute[^\n]*\n",
        "",
        src,
    )
    src = re.sub(
        r"(?m)^from mesh_traceroute import[^\n]*\n",
        "",
        src,
    )
    return src


def _strip_constants(src: str) -> str:
    # Any TRACE_* assignment (incl. comments / marks)
    src = re.sub(
        r"(?m)^TRACE_(?:DEST|FILE|INTERVAL|TIMEOUT|HOP|CH)\s*=[^\n]*\n",
        "",
        src,
    )
    return src


def _strip_worker(src: str) -> str:
    """Remove entire traceroute_worker function up to next top-level def."""
    if "def traceroute_worker" not in src:
        return src
    src = re.sub(
        r"(?ms)^def traceroute_worker\([^)]*\):.*?^(?=def |class |\Z)",
        "",
        src,
    )
    # Also handle indented class-level? Unlikely; keep top-level only.
    return src


def _strip_thread(src: str) -> str:
    src = re.sub(
        r"(?m)^[ \t]*threading\.Thread\(\s*target=traceroute_worker\b[^)]*\)\.start\(\)[^\n]*\n",
        "",
        src,
    )
    # Thread(... target=traceroute_worker ...) multiline-ish single line variants
    src = re.sub(
        r"(?m)^[ \t]*threading\.Thread\([^\n]*traceroute_worker[^\n]*\)\.start\(\)[^\n]*\n",
        "",
        src,
    )
    return src


def _strip_get_handler(src: str) -> str:
    """Remove /traceroute GET block inside do_GET."""
    # Pattern matching the block inserted by patch-mesh-traceroute-bridge.py:
    #         if self.path.startswith("/traceroute"):  # ...
    #             try:
    #                 ...
    #             except ...
    #             return
    src = re.sub(
        r"(?ms)^([ \t]*)if self\.path\.startswith\([\"']/traceroute[\"']\):[^\n]*\n"
        r"(?:(?:\1[ \t]+|\1(?:try|except|else|finally|return|pass)\b)[^\n]*\n)+",
        "",
        src,
    )
    # Fallback: any startswith("/traceroute") if-block with indented body
    src = re.sub(
        r"(?ms)^([ \t]*)if[^\n]*startswith\([\"']/traceroute[\"']\)[^\n]*:\n"
        r"(?:\1[ \t]+[^\n]*\n)+",
        "",
        src,
    )
    return src


def _strip_manual_leftovers(src: str) -> str:
    """Remove manual Trace button leftovers if still present."""
    src = re.sub(r"(?ms)^_trace_busy\s*=\s*[^\n]*\n+", "", src)
    src = re.sub(
        r"(?ms)^def traceroute_run_once\([^)]*\):.*?^(?=def |class |\Z)",
        "",
        src,
    )

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

    src = re.sub(
        r"(?ms)^[ \t]*def do_POST\(self\):.*?(?=^[ \t]*def |\Z)",
        _strip_do_post,
        src,
    )

    # Comment/mark leftovers
    for junk in (
        "  # /* meshTraceBridge */",
        " # /* meshTraceBridge */",
        "/* meshTraceBridge */",
        "  # /* meshTraceManual */",
        " # /* meshTraceManual */",
        "/* meshTraceManual */",
        "  # meshTraceBridge",
        " # meshTraceBridge",
    ):
        src = src.replace(junk, "")

    src = re.sub(r"\n{4,}", "\n\n\n", src)
    return src


def _assert_clean(src: str) -> None:
    bad = []
    for needle in (
        "import mesh_traceroute",
        "def traceroute_worker",
        "target=traceroute_worker",
        "TRACE_DEST",
        "TRACE_FILE",
        "TRACE_INTERVAL",
        "TRACE_TIMEOUT",
        "TRACE_HOP",
        "TRACE_CH",
        "startswith(\"/traceroute\")",
        "startswith('/traceroute')",
        "def traceroute_run_once",
        "/traceroute/run",
        "meshTraceManual",
        "meshTraceBridge",
    ):
        if needle in src:
            bad.append(needle)
    if re.search(r"(?m)^_trace_busy\s*=", src):
        bad.append("_trace_busy")
    if bad:
        raise SystemExit("STOP mesh1 remove: leftover: " + ", ".join(bad))


def strip_mesh1(path: Path) -> bool:
    """Return True if file changed."""
    src0 = path.read_text(encoding="utf-8")
    if "def main():" not in src0:
        raise SystemExit("STOP mesh1 remove: unerwartete Bridge (kein main)")

    # Already clean?
    already = (
        "import mesh_traceroute" not in src0
        and "def traceroute_worker" not in src0
        and "TRACE_DEST" not in src0
        and "target=traceroute_worker" not in src0
        and "/traceroute" not in src0
        and "traceroute_run_once" not in src0
        and "_trace_busy" not in src0
        and "meshTraceBridge" not in src0
        and "meshTraceManual" not in src0
    )
    if already:
        print("OK mesh1 already clean (no traceroute) ->", path)
        return False

    src = src0
    src = _strip_manual_leftovers(src)
    src = _strip_worker(src)
    src = _strip_thread(src)
    src = _strip_get_handler(src)
    src = _strip_import(src)
    src = _strip_constants(src)
    src = _strip_manual_leftovers(src)  # second pass for orphans
    src = re.sub(r"\n{4,}", "\n\n\n", src)

    _assert_clean(src)

    # Must still look like a bridge
    if "def main():" not in src:
        raise SystemExit("STOP mesh1 remove: main() verloren")
    if "_iface" not in src and "chutil_worker" not in src:
        # Soft: some test bridges may lack _iface; real Pi has it
        print("WARN mesh1 remove: weder _iface noch chutil_worker — prüfe Bridge")

    path.write_text(src, encoding="utf-8")
    print("OK mesh1 traceroute entfernt ->", path, MARK)
    return True


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    bridge = root / "mesh_bridge.py"
    if not bridge.is_file():
        raise SystemExit("STOP mesh1 remove: fehlt " + str(bridge))
    strip_mesh1(bridge)
    # Mesh2 bewusst nicht


if __name__ == "__main__":
    main()
