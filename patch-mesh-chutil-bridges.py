#!/usr/bin/env python3
"""Beide Mesh-Bridges: chutil_worker + Datei. /* chutilBridge */."""
from pathlib import Path
import sys

MARK = "/* chutilBridge */"

WORKER = '''
def chutil_worker():  # /* chutilBridge */
    """DeviceMetrics periodisch in CHUTIL_FILE schreiben (keine 2. TCP-Session)."""
    while True:
        time.sleep(60)
        try:
            with _lock:
                iface = _iface
                ids = set(_my_ids)
            if not iface:
                continue
            r = mesh_chutil.sample_and_store(iface, CHUTIL_FILE, my_ids=ids, min_gap=300)
            if r.get("ok") and r.get("wrote"):
                cur = r.get("current") or {}
                log("chutil", cur.get("ch_util"), "% air", cur.get("air_tx"), cur.get("node"))
        except Exception as e:
            log("chutil:", e)


'''

def patch_one(path: Path, hist_name: str, label: str):
    src = path.read_text(encoding="utf-8")
    if MARK in src:
        print(label, "schon gepatcht")
        return
    if "def main():" not in src or "_iface" not in src:
        raise SystemExit("STOP %s: unerwartete Bridge" % label)

    needle = "from pathlib import Path\n"
    if needle not in src:
        raise SystemExit("STOP %s: pathlib import" % label)
    if "import mesh_chutil" not in src:
        src = src.replace(needle, needle + "import mesh_chutil  # %s\n" % MARK, 1)

    if "CHUTIL_FILE" not in src:
        anchor = "HOLD_MAX = 3 * 3600  # 3 Stunden manuell getrennt\n"
        if anchor not in src:
            raise SystemExit("STOP %s: HOLD_MAX" % label)
        src = src.replace(
            anchor,
            anchor
            + 'CHUTIL_FILE = Path("/home/fmg/prepper-dashboard/%s")  # %s\n'
            % (hist_name, MARK),
            1,
        )

    if "def chutil_worker():" not in src:
        if "\ndef main():\n" not in src:
            raise SystemExit("STOP %s: main()" % label)
        src = src.replace("\ndef main():\n", "\n" + WORKER + "def main():\n", 1)

    old_main = (
        "def main():\n"
        "    load_inbox()\n"
        "    threading.Thread(target=worker, daemon=True).start()\n"
        "    threading.Thread(target=watchdog, daemon=True).start()\n"
    )
    new_main = (
        "def main():\n"
        "    load_inbox()\n"
        "    threading.Thread(target=worker, daemon=True).start()\n"
        "    threading.Thread(target=watchdog, daemon=True).start()\n"
        "    threading.Thread(target=chutil_worker, daemon=True).start()  # %s\n" % MARK
    )
    if old_main not in src:
        raise SystemExit("STOP %s: main()-Start Anker" % label)
    src = src.replace(old_main, new_main, 1)

    old_get_end = (
        '            self._json(200, {"messages": list(_inbox)[-200:]})\n'
        "            return\n"
        '        self._json(404, {"error": "not found"})\n'
    )
    new_get_end = (
        '            self._json(200, {"messages": list(_inbox)[-200:]})\n'
        "            return\n"
        '        if self.path.startswith("/chutil"):  # %s\n' % MARK
        + "            try:\n"
        "                with _lock:\n"
        "                    iface = _iface\n"
        "                    ids = set(_my_ids)\n"
        "                live = mesh_chutil.pick_local_metrics(iface, ids) if iface else None\n"
        "                hist = mesh_chutil.hist_payload(CHUTIL_FILE, hours=24)\n"
        '                self._json(200, {"ok": True, "live": live, "hist": hist})\n'
        "            except Exception as e:\n"
        '                self._json(500, {"ok": False, "error": str(e)})\n'
        "            return\n"
        '        self._json(404, {"error": "not found"})\n'
    )
    if old_get_end not in src:
        print(label, "WARN: /chutil HTTP Anker fehlt — nur Worker")
    else:
        src = src.replace(old_get_end, new_get_end, 1)

    path.write_text(src, encoding="utf-8")
    print("OK", label, "->", path)


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    patch_one(root / "mesh_bridge.py", "mesh1_chutil.json", "mesh1")
    patch_one(root / "mesh_bridge_bayern.py", "mesh2_chutil.json", "mesh2")


if __name__ == "__main__":
    main()
