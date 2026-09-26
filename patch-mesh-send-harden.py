#!/usr/bin/env python3
"""Mesh1+Mesh2: restore Handler.do_POST (/hold,/resume,/send) if missing. # meshSendHarden
Idempotent. Does NOT restore/add traceroute. Leaves traceroute leftovers alone
unless they live inside a broken do_POST that lacks /send (then whole method
is replaced with Sep-2 original).
Applies to mesh_bridge.py AND mesh_bridge_bayern.py.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "# meshSendHarden"

# Exact do_POST from mesh_bridge.ORIGINAL-from-att-20260902.py (lines 459-487)
# Same body as meshSendFix; mark differs so harden is distinguishable.
DO_POST = '''    def do_POST(self):  # meshSendHarden
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

BRIDGES = ("mesh_bridge.py", "mesh_bridge_bayern.py")


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
    """Insert DO_POST after do_GET if present, else after _json, else before main."""
    m = re.search(r"(?ms)^([ \t]*def do_GET\(self\):.*?)(?=^[ \t]*def |\Z)", src)
    if m:
        return src[: m.end()] + DO_POST + src[m.end() :]

    m = re.search(r"(?ms)^([ \t]*def _json\(self[^)]*\):.*?)(?=^[ \t]*def |\Z)", src)
    if m:
        return src[: m.end()] + DO_POST + src[m.end() :]

    m = re.search(r"(?m)^def main\(", src)
    if m:
        return src[: m.start()] + DO_POST + src[m.start() :]

    raise SystemExit("STOP meshSendHarden: kein Insert-Anker (do_GET/_json/main)")


def _assert_after(src: str, label: str) -> None:
    if "def do_POST" not in src:
        raise SystemExit(f"STOP meshSendHarden [{label}]: def do_POST fehlt nach Patch")
    if 'startswith("/send")' not in src and "startswith('/send')" not in src:
        raise SystemExit(f"STOP meshSendHarden [{label}]: /send fehlt nach Patch")
    if "_send_q" not in src:
        raise SystemExit(f"STOP meshSendHarden [{label}]: _send_q fehlt nach Patch")
    if "def worker" not in src and "target=worker" not in src:
        raise SystemExit(f"STOP meshSendHarden [{label}]: worker fehlt nach Patch")


def repair(path: Path) -> bool:
    """Return True if file changed. STOP (exit) on missing _send_q for this file."""
    label = path.name
    src0 = path.read_text(encoding="utf-8")

    if "_send_q" not in src0:
        raise SystemExit(
            f"STOP meshSendHarden [{label}]: _send_q fehlt — "
            "voller Restore nötig, nicht nur do_POST"
        )
    if "def worker" not in src0 and "target=worker" not in src0:
        raise SystemExit(
            f"STOP meshSendHarden [{label}]: worker fehlt — voller Restore nötig"
        )

    if _has_send_in_do_post(src0):
        print(f"OK meshSendHarden already has do_POST+/send -> {path}")
        return False

    # Broken/missing do_POST: replace (may discard traceroute-only do_POST body)
    src = _strip_do_post(src0)
    src = re.sub(r"\n{4,}", "\n\n\n", src)
    src = _insert_do_post(src)
    src = re.sub(r"\n{4,}", "\n\n\n", src)

    _assert_after(src, label)

    path.write_text(src, encoding="utf-8")
    print(f"OK meshSendHarden do_POST+/send restored -> {path} {MARK}")
    return True


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    # Allow passing a single bridge file directly
    if root.is_file() and root.name.endswith(".py"):
        repair(root)
        return

    if not root.is_dir():
        raise SystemExit(f"STOP meshSendHarden: kein Dashboard-Dir {root}")

    any_fail = False
    for name in BRIDGES:
        bridge = root / name
        if not bridge.is_file():
            print(f"WARN meshSendHarden: fehlt {bridge} — übersprungen")
            continue
        try:
            repair(bridge)
        except SystemExit as e:
            print(str(e))
            any_fail = True
    if any_fail:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
