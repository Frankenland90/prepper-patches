#!/usr/bin/env python3
"""Mesh1 only: restore Handler.do_POST (/hold,/resume,/send) after traceroute-remove. # meshSendFix
Idempotent. Does NOT restore traceroute. Does NOT touch mesh2.
Uses the exact Sep-2 original do_POST body (queue via _send_q).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "# meshSendFix"

# Exact do_POST from mesh_bridge.ORIGINAL-from-att-20260902.py (lines 459-487)
DO_POST = '''    def do_POST(self):  # meshSendFix
        if self.path.startswith("/hold"):
            hold_bridge()
            self._json(200, dict(_state, held=True))
            return
        if self.path.startswith("/resume"):
            ok = resume_bridge()
            self._json(200, dict(_state, held=is_held(), resume_ok=ok))
            return
        if self.path.startswith("/send"):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n).decode("utf-8") if n else "{}"
            try:
                data = json.loads(body) if body else {}
            except Exception:
                data = {}
            text = (data.get("text") or "").strip()
            ch = int(data.get("channel") or 0)
            if not text:
                self._json(400, {"ok": False, "error": "text fehlt"})
                return
            try:
                _send_q.put_nowait({"text": text, "channel": ch})
                _state["queued"] = _send_q.qsize()
                self._json(200, {"ok": True, "queued": _state["queued"]})
            except queue.Full:
                self._json(429, {"ok": False, "error": "queue full"})
            return
        self._json(404, {"error": "not found"})


'''


def _extract_do_post(src: str) -> str | None:
    m = re.search(r"(?ms)^[ \t]*def do_POST\(self\):.*?(?=^[ \t]*def |\Z)", src)
    return m.group(0) if m else None


def _has_send_in_do_post(src: str) -> bool:
    body = _extract_do_post(src)
    if not body:
        return False
    return 'startswith("/send")' in body or "startswith('/send')" in body


def _strip_do_post(src: str) -> str:
    """Remove any existing do_POST method (broken/traceroute-only/empty)."""
    return re.sub(
        r"(?ms)^[ \t]*def do_POST\(self\):.*?(?=^[ \t]*def |\Z)",
        "",
        src,
    )


def _insert_do_post(src: str) -> str:
    """Insert DO_POST after do_GET method if present, else after _json, else before main."""
    # Prefer after end of do_GET (matches original Handler order: _json, do_GET, do_POST)
    m = re.search(r"(?ms)^([ \t]*def do_GET\(self\):.*?)(?=^[ \t]*def |\Z)", src)
    if m:
        return src[: m.end()] + DO_POST + src[m.end() :]

    m = re.search(r"(?ms)^([ \t]*def _json\(self[^)]*\):.*?)(?=^[ \t]*def |\Z)", src)
    if m:
        return src[: m.end()] + DO_POST + src[m.end() :]

    m = re.search(r"(?m)^def main\(", src)
    if m:
        return src[: m.start()] + DO_POST + src[m.start() :]

    raise SystemExit("STOP meshSendFix: kein Insert-Anker (do_GET/_json/main)")


def _assert_clean(src: str) -> None:
    if "def do_POST" not in src:
        raise SystemExit("STOP meshSendFix: def do_POST fehlt nach Patch")
    if 'startswith("/send")' not in src and "startswith('/send')" not in src:
        raise SystemExit("STOP meshSendFix: /send fehlt nach Patch")
    for bad in (
        "traceroute_run_once",
        "meshTraceManual",
        "target=traceroute_worker",
    ):
        if bad in src:
            raise SystemExit(f"STOP meshSendFix: traceroute-Rest '{bad}' — nicht erlaubt")


def repair(path: Path) -> bool:
    src0 = path.read_text(encoding="utf-8")

    if "_send_q" not in src0:
        raise SystemExit(
            "STOP meshSendFix: _send_q fehlt in live mesh_bridge.py — "
            "voller Restore nötig, nicht nur do_POST"
        )
    if "def worker" not in src0 and "target=worker" not in src0:
        raise SystemExit(
            "STOP meshSendFix: worker fehlt in live mesh_bridge.py — "
            "voller Restore nötig"
        )

    if _has_send_in_do_post(src0):
        print("OK meshSendFix already has do_POST+/send ->", path)
        return False

    src = _strip_do_post(src0)
    src = re.sub(r"\n{4,}", "\n\n\n", src)
    src = _insert_do_post(src)
    src = re.sub(r"\n{4,}", "\n\n\n", src)

    _assert_clean(src)

    path.write_text(src, encoding="utf-8")
    print("OK meshSendFix do_POST+/send restored ->", path, MARK)
    return True


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    # Allow passing file directly or dashboard dir
    if root.is_file() and root.name.endswith(".py"):
        bridge = root
    else:
        bridge = root / "mesh_bridge.py"
    if not bridge.is_file():
        raise SystemExit("STOP meshSendFix: fehlt " + str(bridge))
    repair(bridge)


if __name__ == "__main__":
    main()
