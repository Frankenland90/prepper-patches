#!/usr/bin/env python3
"""Mesh1 only: traceroute_worker + /traceroute via existing _iface. /* meshTraceBridge */"""
from pathlib import Path
import sys

MARK = "/* meshTraceBridge */"

WORKER = '''
def traceroute_worker():  # /* meshTraceBridge */
    """Stuendlich Traceroute zu TRACE_DEST ueber bestehende _iface-Session (kein 2. TCP)."""
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

    time.sleep(90)
    while True:
        try:
            _run_once()
        except Exception as e:
            log("traceroute_worker:", e)
        time.sleep(TRACE_INTERVAL)


'''


def patch_mesh1(path: Path):
    src = path.read_text(encoding="utf-8")
    if MARK in src:
        print("mesh1 schon gepatcht")
        return
    if "def main():" not in src or "_iface" not in src:
        raise SystemExit("STOP mesh1: unerwartete Bridge")

    needle = "from pathlib import Path\n"
    if needle not in src:
        if "import mesh_chutil" in src and "import mesh_traceroute" not in src:
            src = src.replace(
                "import mesh_chutil",
                "import mesh_chutil\nimport mesh_traceroute  # %s" % MARK,
                1,
            )
        elif "import mesh_traceroute" not in src:
            raise SystemExit("STOP mesh1: pathlib/mesh_chutil import")
    elif "import mesh_traceroute" not in src:
        src = src.replace(needle, needle + "import mesh_traceroute  # %s\n" % MARK, 1)

    if "TRACE_DEST" not in src:
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

    if "def traceroute_worker():" not in src:
        if "\ndef main():\n" not in src:
            raise SystemExit("STOP mesh1: main()")
        src = src.replace("\ndef main():\n", "\n" + WORKER + "def main():\n", 1)

    if "target=traceroute_worker" not in src:
        import re as _re
        m = _re.search(
            r"(?m)^(    threading\.Thread\(target=chutil_worker, daemon=True\)\.start\(\).*)\n",
            src,
        )
        if not m:
            m = _re.search(
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
        src = src[: m.start()] + insert + src[m.end() :]

    if "/traceroute" not in src:
        old_get_end = (
            '        self._json(404, {"error": "not found"})\n'
        )
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
            src = src.replace(chutil_end, insert, 1)
        elif old_get_end in src:
            src = src.replace(
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
        else:
            print("mesh1 WARN: /traceroute HTTP Anker fehlt — nur Worker")

    path.write_text(src, encoding="utf-8")
    print("OK mesh1 ->", path)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    patch_mesh1(root / "mesh_bridge.py")


if __name__ == "__main__":
    main()
