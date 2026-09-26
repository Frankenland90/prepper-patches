#!/usr/bin/env python3
"""Mesh1 only: hourly traceroute_worker via existing _iface. /* meshTraceBridge */
Idempotent: upgrades ALREADY-patched bridges — strips manual do_POST /
traceroute/run / _trace_busy / traceroute_run_once, restores fat worker
(sendData inside with _lock:, wait outside) from proven 071f133 pattern.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "/* meshTraceBridge */"

# Fat worker: sendData under _lock; wait outside (produced successful 08:30 SNR).
WORKER = '''
def traceroute_worker():  # /* meshTraceBridge */
    """Stündlich Traceroute zu TRACE_DEST über bestehende _iface-Session (kein 2. TCP)."""
    import threading as _threading

    def _run_once():
        with _lock:
            iface = _iface
        if not iface:
            mesh_traceroute.store_result(
                TRACE_FILE, ok=False, dest=TRACE_DEST, error="no iface"
            )
            return
        done = _threading.Event()
        box = {"pkt": None, "err": None}

        def _on_resp(pkt):
            box["pkt"] = pkt
            done.set()

        try:
            # sendData + Event (kein waitForTraceRoute-Block der Library)
            try:
                from meshtastic import mesh_pb2, portnums_pb2
                r = mesh_pb2.RouteDiscovery()
                port = portnums_pb2.PortNum.TRACEROUTE_APP
            except Exception:
                r = None
                port = 70  # TRACEROUTE_APP
            with _lock:
                iface2 = _iface
                if not iface2:
                    raise RuntimeError("no iface")
                if r is not None and hasattr(iface2, "sendData"):
                    iface2.sendData(
                        r,
                        destinationId=TRACE_DEST,
                        portNum=port,
                        wantResponse=True,
                        onResponse=_on_resp,
                        channelIndex=TRACE_CH,
                        hopLimit=TRACE_HOP,
                    )
                elif hasattr(iface2, "sendTraceRoute"):
                    # Fallback: sendTraceRoute blockiert intern — Timeout-Thread
                    def _send():
                        try:
                            iface2.sendTraceRoute(
                                TRACE_DEST, TRACE_HOP, channelIndex=TRACE_CH
                            )
                        except Exception as e:
                            box["err"] = str(e)
                        finally:
                            done.set()
                    _threading.Thread(target=_send, daemon=True).start()
                else:
                    raise RuntimeError("kein sendData/sendTraceRoute")
            if not done.wait(TRACE_TIMEOUT):
                mesh_traceroute.store_result(
                    TRACE_FILE, ok=False, dest=TRACE_DEST, error="timeout"
                )
                log("traceroute: timeout", TRACE_DEST)
                return
            if box.get("err"):
                mesh_traceroute.store_result(
                    TRACE_FILE, ok=False, dest=TRACE_DEST, error=str(box["err"])
                )
                log("traceroute:", box["err"])
                return
            pkt = box.get("pkt")
            if pkt is None and box.get("err") is None and not hasattr(iface, "sendData"):
                # sendTraceRoute ohne onResponse-Paket: als ok ohne SNR werten nur wenn kein Fehler
                mesh_traceroute.store_result(
                    TRACE_FILE, ok=True, dest=TRACE_DEST, error="no-snr-payload"
                )
                log("traceroute: ok (kein Payload)", TRACE_DEST)
                return
            if pkt is None:
                mesh_traceroute.store_result(
                    TRACE_FILE, ok=False, dest=TRACE_DEST, error="no response"
                )
                log("traceroute: no response", TRACE_DEST)
                return
            parsed = mesh_traceroute.parse_route_discovery(pkt)
            # Funktionstest: Antwort innerhalb Timeout = ok
            point = mesh_traceroute.store_result(
                TRACE_FILE,
                ok=True,
                dest=TRACE_DEST,
                snr_towards=parsed.get("snr_towards"),
                snr_back=parsed.get("snr_back"),
                hops_towards=parsed.get("hops_towards"),
                hops_back=parsed.get("hops_back"),
                payload=pkt,
            )
            log(
                "traceroute ok",
                TRACE_DEST,
                "snr_t",
                point.get("snr_towards"),
                "snr_b",
                point.get("snr_back"),
            )
        except Exception as e:
            try:
                mesh_traceroute.store_result(
                    TRACE_FILE, ok=False, dest=TRACE_DEST, error=str(e)
                )
            except Exception:
                pass
            log("traceroute:", e)

    # erster Lauf nach kurzer Warmup-Pause, dann stündlich
    time.sleep(90)
    while True:
        try:
            _run_once()
        except Exception as e:
            log("traceroute_worker:", e)
        time.sleep(TRACE_INTERVAL)


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


def _strip_manual(src: str) -> str:
    """Remove manual Trace button bridge bits: do_POST traceroute, _trace_busy, run_once."""
    # Strip traceroute_run_once function (and preceding _trace_busy)
    src = re.sub(
        r"(?ms)^_trace_busy\s*=\s*False[^\n]*\n+",
        "",
        src,
    )
    src = re.sub(
        r"(?ms)^def traceroute_run_once\([^)]*\):.*?^(?=def |\Z)",
        "",
        src,
    )
    # Strip any leftover _trace_busy assignments inside remaining code (worker etc.)
    # (fat worker replacement will drop thin worker that references it)

    # Strip entire do_POST that only handles traceroute (our injected method)
    def _strip_do_post(m: re.Match) -> str:
        body = m.group(0)
        # Only strip if this do_POST is traceroute-related (meshTraceManual)
        if "traceroute" not in body and "meshTraceManual" not in body:
            return body
        # If do_POST ONLY does traceroute (returns 404 otherwise) — remove whole method
        if "meshTraceManual" in body or "/traceroute/run" in body or "traceroute_run_once" in body:
            # Check if there's non-traceroute handling beyond the traceroute block + 404
            # Our injected DO_POST only has traceroute + 404 — remove entirely.
            # Also handle inject-at-start style: remove only the traceroute preamble.
            if re.search(
                r"(?ms)def do_POST\(self\):.*?meshTraceManual.*?self\._json\(404",
                body,
            ) and body.count("def ") == 1:
                # Pure traceroute do_POST — drop it
                return ""
            # Injected-at-start: remove traceroute preamble, keep rest of do_POST
            body2 = re.sub(
                r"(?ms)^([ \t]*)global _trace_busy[^\n]*\n"
                r"(?:[ \t]*_tp\s*=.*?return\n)+",
                "",
                body,
                count=1,
            )
            # Also remove inline traceroute if-block at start
            body2 = re.sub(
                r"(?ms)^([ \t]*def do_POST\(self\):\s*\n)"
                r"(?:[ \t]*global _trace_busy[^\n]*\n)?"
                r"(?:[ \t]*_tp\s*=[^\n]*\n)?"
                r"(?:[ \t]*path\s*=[^\n]*\n)?"
                r"(?:[ \t]*if[^\n]*traceroute[^\n]*:\n"
                r"(?:[ \t]+[^\n]*\n)+?)",
                r"\1",
                body2,
                count=1,
            )
            # If after strip the method is empty / only pass — drop it
            if re.match(
                r"(?ms)^[ \t]*def do_POST\(self\):\s*\n(?:[ \t]*pass\s*\n)?\s*\Z",
                body2,
            ):
                return ""
            # If method still only has traceroute leftovers + 404 — drop
            if (
                "traceroute" in body2
                and "traceroute_run_once" in body2
                and body2.count("self._json") <= 3
            ):
                # Try harder: remove whole method if it's clearly our traceroute POST
                if "meshTraceManual" in body or (
                    "_trace_busy" in body and "traceroute_run_once" in body
                ):
                    return ""
            return body2
        return body

    src = re.sub(
        r"(?ms)^[ \t]*def do_POST\(self\):.*?(?=^[ \t]*def |\Z)",
        _strip_do_post,
        src,
    )

    # Remove meshTraceManual comment markers left behind
    src = src.replace("  # /* meshTraceManual */", "")
    src = src.replace(" # /* meshTraceManual */", "")
    src = src.replace("/* meshTraceManual */", "")

    # Collapse excessive blank lines (keep max 2)
    src = re.sub(r"\n{4,}", "\n\n\n", src)
    return src


def _is_fat_worker(body: str) -> bool:
    """Fat worker has sendData under _lock inline (not thin run_once/execute_probe)."""
    return (
        "sendData" in body
        and "with _lock:" in body
        and "traceroute_run_once" not in body
        and "execute_probe" not in body
        and "_trace_busy" not in body
    )


def _replace_or_insert_worker(src: str) -> str:
    """Ensure fat traceroute_worker is present (replace thin/manual variants)."""
    if "def traceroute_worker():" in src:
        m = re.search(
            r"(?ms)^def traceroute_worker\(\):.*?^(?=def |\Z)",
            src,
        )
        if m:
            body = m.group(0)
            if _is_fat_worker(body):
                # Ensure MARK on def line
                if MARK not in body.split("\n", 1)[0]:
                    body2 = body.replace(
                        "def traceroute_worker():",
                        "def traceroute_worker():  # %s" % MARK,
                        1,
                    )
                    src = src[: m.start()] + body2 + src[m.end() :]
                return src
            # Replace thin / busy-lock / execute_probe worker with fat WORKER
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
    print("mesh1 WARN: /traceroute GET Anker fehlt — nur Worker")
    return src


def _assert_no_manual(src: str) -> None:
    """Hard check: no manual POST path left after upgrade."""
    bad = []
    if "def traceroute_run_once" in src:
        bad.append("traceroute_run_once")
    if re.search(r"(?m)^_trace_busy\s*=", src):
        bad.append("_trace_busy")
    if "/traceroute/run" in src:
        bad.append("/traceroute/run")
    if "meshTraceManual" in src:
        bad.append("meshTraceManual")
    # do_POST that mentions traceroute
    for m in re.finditer(
        r"(?ms)^[ \t]*def do_POST\(self\):.*?(?=^[ \t]*def |\Z)", src
    ):
        if "traceroute" in m.group(0):
            bad.append("do_POST+traceroute")
    if bad:
        raise SystemExit("STOP mesh1: manual leftover after strip: " + ", ".join(bad))


def patch_mesh1(path: Path):
    src = path.read_text(encoding="utf-8")
    if "def main():" not in src or "_iface" not in src:
        raise SystemExit("STOP mesh1: unerwartete Bridge")

    had_manual = (
        "meshTraceManual" in src
        or "def traceroute_run_once" in src
        or "_trace_busy" in src
        or "/traceroute/run" in src
    )
    if had_manual:
        print("mesh1: strippe Manual-Trace (do_POST/_trace_busy/run_once) …")
        src = _strip_manual(src)

    src = _ensure_import(src)
    src = _ensure_constants(src)
    src = _replace_or_insert_worker(src)
    src = _ensure_thread(src)
    src = _ensure_get(src)

    # Markers
    if MARK not in src:
        src = src.replace(
            "def traceroute_worker():",
            "def traceroute_worker():  # %s" % MARK,
            1,
        )

    _assert_no_manual(src)

    if "def traceroute_worker():" not in src:
        raise SystemExit("STOP mesh1: traceroute_worker fehlt")
    if "!fbc48dcb" not in src:
        raise SystemExit("STOP mesh1: TRACE_DEST !fbc48dcb fehlt")

    path.write_text(src, encoding="utf-8")
    print("OK mesh1 ->", path)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    patch_mesh1(root / "mesh_bridge.py")
    # Mesh2 bewusst nicht


if __name__ == "__main__":
    main()
