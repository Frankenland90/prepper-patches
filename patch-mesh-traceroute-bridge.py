#!/usr/bin/env python3
"""Mesh1 only: traceroute_worker + manual /traceroute/run via existing _iface.
/* meshTraceBridge */ /* meshTraceManual */
Idempotent: upgrades ALREADY-patched bridges (adds run_once + do_POST).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "/* meshTraceBridge */"
MARK_M = "/* meshTraceManual */"

RUN_ONCE = '''
_trace_busy = False  # /* meshTraceManual */


def traceroute_run_once():  # /* meshTraceManual */
    """Ein Trace über bestehende _iface-Session (kein 2. TCP)."""
    global _trace_busy
    try:
        with _lock:
            iface = _iface
        mesh_traceroute.execute_probe(
            iface,
            dest=TRACE_DEST,
            path=TRACE_FILE,
            timeout=TRACE_TIMEOUT,
            hop_limit=TRACE_HOP,
            channel_index=TRACE_CH,
            log_fn=log,
        )
    except Exception as e:
        try:
            log("traceroute_run_once:", e)
        except Exception:
            pass
    finally:
        _trace_busy = False


'''

WORKER = '''
def traceroute_worker():  # /* meshTraceBridge */
    """Stündlich Traceroute zu TRACE_DEST über bestehende _iface-Session (kein 2. TCP)."""
    global _trace_busy
    time.sleep(90)
    while True:
        try:
            if _trace_busy:
                time.sleep(TRACE_INTERVAL)
                continue
            _trace_busy = True
            traceroute_run_once()
        except Exception as e:
            _trace_busy = False
            log("traceroute_worker:", e)
        time.sleep(TRACE_INTERVAL)


'''

DO_POST = '''
    def do_POST(self):  # /* meshTraceManual */
        global _trace_busy
        path = (self.path or "").split("?", 1)[0]
        if path in ("/traceroute", "/traceroute/run") or path.startswith("/traceroute"):
            if _trace_busy:
                self._json(409, {"ok": False, "started": False, "dest": TRACE_DEST})
                return
            _trace_busy = True
            threading.Thread(target=traceroute_run_once, daemon=True).start()
            self._json(202, {"ok": True, "started": True, "dest": TRACE_DEST})
            return
        self._json(404, {"error": "not found"})

'''


def _ensure_import(src: str) -> str:
    if re.search(r"(?m)^import mesh_traceroute\b", src):
        return src
    needle = "from pathlib import Path\n"
    if needle in src:
        return src.replace(needle, needle + "import mesh_traceroute  # %s\n" % MARK, 1)
    if "import mesh_chutil" in src:
        return src.replace(
            "import mesh_chutil",
            "import mesh_chutil\nimport mesh_traceroute  # %s" % MARK,
            1,
        )
    raise SystemExit("STOP mesh1: pathlib/mesh_chutil import")


def _ensure_constants(src: str) -> str:
    # Always pin dest to MMSC-RTB
    if "TRACE_DEST" in src:
        src = re.sub(
            r"TRACE_DEST\s*=\s*['\"][^'\"]+['\"]",
            "TRACE_DEST = '!fbc48dcb'",
            src,
            count=1,
        )
        return src
    inserted = False
    for anchor in (
        'CHUTIL_FILE = Path("/home/fmg/prepper-dashboard/mesh1_chutil.json")',
        "HOLD_MAX = 3 * 3600  # 3 Stunden manuell getrennt",
    ):
        if anchor in src:
            block = (
                anchor
                + "\n"
                + "TRACE_DEST = '!fbc48dcb'  # %s\n" % MARK
                + 'TRACE_FILE = Path("/home/fmg/prepper-dashboard/mesh1_traceroute.json")  # %s\n'
                % MARK
                + "TRACE_INTERVAL = 3600  # %s\n" % MARK
                + "TRACE_TIMEOUT = 60  # %s\n" % MARK
                + "TRACE_HOP = 5  # %s\n" % MARK
                + "TRACE_CH = 0  # %s\n" % MARK
            )
            src = src.replace(anchor, block, 1)
            inserted = True
            break
    if not inserted:
        raise SystemExit("STOP mesh1: TRACE Konstanten-Anker")
    return src


def _ensure_run_once(src: str) -> str:
    if "def traceroute_run_once():" in src and "_trace_busy" in src:
        return src
    # Prefer insert just before traceroute_worker or main
    if "def traceroute_worker():" in src:
        src = src.replace(
            "\ndef traceroute_worker():",
            "\n" + RUN_ONCE + "def traceroute_worker():",
            1,
        )
        return src
    if "\ndef main():\n" in src:
        src = src.replace("\ndef main():\n", "\n" + RUN_ONCE + "def main():\n", 1)
        return src
    raise SystemExit("STOP mesh1: traceroute_run_once Anker")


def _replace_or_insert_worker(src: str) -> str:
    """Replace fat old worker with thin one that calls traceroute_run_once; or insert."""
    if "def traceroute_worker():" in src:
        # Already thin (uses execute_probe / traceroute_run_once)?
        m = re.search(
            r"(?ms)^def traceroute_worker\(\):.*?^(?=def |\Z)",
            src,
        )
        if m:
            body = m.group(0)
            if (
                "traceroute_run_once()" in body
                and "execute_probe" not in body.replace("traceroute_run_once", "")
                and "sendData" not in body
            ):
                return src  # already upgraded
            src = src[: m.start()] + WORKER + src[m.end() :]
            return src
    if "\ndef main():\n" not in src:
        raise SystemExit("STOP mesh1: main()")
    src = src.replace("\ndef main():\n", "\n" + WORKER + "def main():\n", 1)
    return src


def _ensure_thread(src: str) -> str:
    if "target=traceroute_worker" in src:
        return src
    m = re.search(
        r"(?m)^(    threading\.Thread\(target=chutil_worker, daemon=True\)\.start\(\).*)\n",
        src,
    )
    if not m:
        m = re.search(
            r"(?m)^(    threading\.Thread\(target=watchdog, daemon=True\)\.start\(\).*)\n",
            src,
        )
    if not m:
        raise SystemExit("STOP mesh1: Thread-Start Anker")
    insert = (
        m.group(0)
        + "    threading.Thread(target=traceroute_worker, daemon=True).start()  # %s\n"
        % MARK
    )
    return src[: m.start()] + insert + src[m.end() :]


def _ensure_get(src: str) -> str:
    if 'startswith("/traceroute")' in src or "startswith('/traceroute')" in src:
        return src
    old_get_end = '        self._json(404, {"error": "not found"})\n'
    chutil_end = (
        '                self._json(500, {"ok": False, "error": str(e)})\n'
        "            return\n"
        '        self._json(404, {"error": "not found"})\n'
    )
    insert = (
        '                self._json(500, {"ok": False, "error": str(e)})\n'
        "            return\n"
        '        if self.path.startswith("/traceroute"):  # %s\n' % MARK
        + "            try:\n"
        "                last = mesh_traceroute.last_sample(TRACE_FILE)\n"
        "                hist = mesh_traceroute.hist_payload(TRACE_FILE, hours=48)\n"
        '                self._json(200, {"ok": True, "last": last, "hist": hist})\n'
        "            except Exception as e:\n"
        '                self._json(500, {"ok": False, "error": str(e)})\n'
        "            return\n"
        '        self._json(404, {"error": "not found"})\n'
    )
    if chutil_end in src:
        return src.replace(chutil_end, insert, 1)
    if old_get_end in src:
        return src.replace(
            old_get_end,
            '        if self.path.startswith("/traceroute"):  # %s\n' % MARK
            + "            try:\n"
            "                last = mesh_traceroute.last_sample(TRACE_FILE)\n"
            "                hist = mesh_traceroute.hist_payload(TRACE_FILE, hours=48)\n"
            '                self._json(200, {"ok": True, "last": last, "hist": hist})\n'
            "            except Exception as e:\n"
            '                self._json(500, {"ok": False, "error": str(e)})\n'
            "            return\n"
            + old_get_end,
            1,
        )
    print("mesh1 WARN: /traceroute GET Anker fehlt — nur Worker/POST")
    return src


def _ensure_do_post(src: str) -> str:
    if "def do_POST(self):" in src and "traceroute_run_once" in src:
        # Already has traceroute POST handling?
        if "/traceroute/run" in src or 'startswith("/traceroute")' in src:
            # Check do_POST body mentions traceroute
            m = re.search(r"(?ms)^[ \t]*def do_POST\(self\):.*?(?=^[ \t]*def |\Z)", src)
            if m and "traceroute" in m.group(0):
                return src
    if "def do_POST(self):" in src:
        # Existing do_POST without traceroute — inject at start of method
        m = re.search(r"(?m)^([ \t]*)def do_POST\(self\):\s*\n", src)
        if not m:
            raise SystemExit("STOP mesh1: do_POST Anker")
        ind = m.group(1)
        inject = (
            m.group(0)
            + ind
            + "    global _trace_busy  # %s\n" % MARK_M
            + ind
            + '    _tp = (self.path or "").split("?", 1)[0]\n'
            + ind
            + '    if _tp in ("/traceroute", "/traceroute/run") or _tp.startswith("/traceroute"):\n'
            + ind
            + "        if _trace_busy:\n"
            + ind
            + '            self._json(409, {"ok": False, "started": False, "dest": TRACE_DEST})\n'
            + ind
            + "            return\n"
            + ind
            + "        _trace_busy = True\n"
            + ind
            + "        threading.Thread(target=traceroute_run_once, daemon=True).start()\n"
            + ind
            + '        self._json(202, {"ok": True, "started": True, "dest": TRACE_DEST})\n'
            + ind
            + "        return\n"
        )
        return src[: m.start()] + inject + src[m.end() :]

    # Insert after do_GET's trailing 404
    anchor = '        self._json(404, {"error": "not found"})\n'
    # Prefer the do_GET final 404 (last occurrence before traceroute_worker / main)
    idx = src.rfind(anchor)
    if idx < 0:
        # fallback: after do_GET def block ending
        m = re.search(r"(?ms)^([ \t]*)def do_GET\(self\):.*?\n(?=[ \t]*def |\Z)", src)
        if not m:
            print("mesh1 WARN: do_POST Anker fehlt")
            return src
        return src[: m.end()] + DO_POST + src[m.end() :]
    return src[: idx + len(anchor)] + "\n" + DO_POST + src[idx + len(anchor) :]


def patch_mesh1(path: Path):
    src = path.read_text(encoding="utf-8")
    if "def main():" not in src or "_iface" not in src:
        raise SystemExit("STOP mesh1: unerwartete Bridge")

    already_full = (
        MARK in src
        and MARK_M in src
        and "def traceroute_run_once():" in src
        and "def do_POST(self):" in src
        and "traceroute_run_once()" in src
        and "!fbc48dcb" in src
    )
    if already_full:
        # Still re-run ensure steps for safety (idempotent)
        print("mesh1 schon vollständig (meshTraceBridge+Manual) — prüfe Idempotenz")

    src = _ensure_import(src)
    src = _ensure_constants(src)
    src = _ensure_run_once(src)
    src = _replace_or_insert_worker(src)
    src = _ensure_thread(src)
    src = _ensure_get(src)
    src = _ensure_do_post(src)

    # Markers must appear
    if MARK not in src:
        # constants/import already tagged; ensure at least one
        src = src.replace(
            "def traceroute_worker():",
            "def traceroute_worker():  # %s" % MARK,
            1,
        )
    if MARK_M not in src:
        src = src.replace(
            "def traceroute_run_once():",
            "def traceroute_run_once():  # %s" % MARK_M,
            1,
        )

    path.write_text(src, encoding="utf-8")
    print("OK mesh1 ->", path)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    patch_mesh1(root / "mesh_bridge.py")
    # Mesh2 bewusst nicht


if __name__ == "__main__":
    main()
