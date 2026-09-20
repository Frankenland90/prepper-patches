#!/usr/bin/env python3
"""Health Report → health_status.json (nie systemctl restart). /* health3h */"""
import json
import subprocess
import urllib.request
from datetime import datetime
from pathlib import Path

BASE = Path("/home/fmg/prepper-dashboard")
OUT = BASE / "health_status.json"
LOG = BASE / "health_check.log"
# Nav-Seiten (ohne API / Scanner / Decoder)
PAGES = [
    "/",
    "/energie",
    "/lokale-energie",
    "/speicher",
    "/umwelt",
    "/luft",
    "/pegel",
    "/adsb",
    "/mesh",
    "/mesh2",
    "/news",
    "/funk",
    "/pi",
    "/medizin",
]

def now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")

def log(msg):
    line = f"[{now_str()}] {msg}"
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
        lines = LOG.read_text().splitlines()
        if len(lines) > 500:
            LOG.write_text("\n".join(lines[-350:]) + "\n")
    except Exception:
        pass

def run(cmd, timeout=40):
    try:
        p = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except Exception as e:
        return 1, "", str(e)

def item(id_, ok, msg):
    return {"id": id_, "ok": bool(ok), "msg": str(msg)[:120]}

def mesh_host():
    try:
        ns = {}
        exec(open(BASE / "config.py").read(), ns)
        return ns.get("MESHTASTIC_HOST", "192.168.178.141")
    except Exception:
        return "192.168.178.141"

def main():
    items = []
    try:
        rc, _, err = run(
            f"cd {BASE} && ./venv/bin/python -m py_compile dashboard.py"
        )
        items.append(
            item("compile", rc == 0, "Syntax OK" if rc == 0 else (err or "FAIL")[:80])
        )

        for svc in ("prepper-dashboard", "kiwix", "chrony"):
            rc, out, _ = run(f"systemctl is-active {svc}")
            items.append(item(f"svc_{svc}", rc == 0 and out == "active", out or "inactive"))

        for p in PAGES:
            try:
                r = urllib.request.urlopen(f"http://127.0.0.1:5000{p}", timeout=8)
                code = r.status
            except Exception:
                code = 0
            items.append(item(f"page_{p}", code == 200, str(code)))

        try:
            code = urllib.request.urlopen("http://127.0.0.1:8080/", timeout=4).status
            k_ok = code == 200
        except Exception:
            k_ok, code = False, 0
        items.append(item("kiwix", k_ok, str(code)))

        host = mesh_host()
        rc, _, _ = run(f"nc -z -w2 {host} 4403")
        items.append(item("mesh", rc == 0, f"{host}:4403"))

        rc, out, _ = run("df -P / | awk 'NR==2{print $5}'")
        try:
            pct = int(out.replace("%", ""))
            items.append(item("disk", pct < 90, f"{pct} % belegt"))
        except Exception:
            items.append(item("disk", False, out or "n/a"))

        rc, out, _ = run("awk '/MemAvailable/{printf \"%d\", $2}' /proc/meminfo")
        try:
            avail_mb = int(out) // 1024
            items.append(item("ram", avail_mb >= 100, f"{avail_mb} MB frei"))
        except Exception:
            items.append(item("ram", False, "n/a"))

        rc, out, _ = run("vcgencmd measure_temp 2>/dev/null | tr -d \"temp='C\"")
        try:
            temp = float(out)
            items.append(item("temp", temp < 80, f"{temp:.1f} °C"))
        except Exception:
            items.append(item("temp", True, "n/a"))

        rc, out, _ = run("vcgencmd get_throttled 2>/dev/null")
        th_ok = "0x0" in out.replace(" ", "")
        items.append(item("throttle", th_ok or rc != 0, out or "n/a"))

        rc, out, _ = run("chronyc tracking 2>/dev/null | head -6")
        items.append(item("chrony", rc == 0 and bool(out), "tracking OK" if out else "fail"))

        rc, out, _ = run(
            "apt list --upgradable 2>/dev/null | grep -vc '^Auflistung' || true"
        )
        try:
            n = int(out.strip().splitlines()[-1])
        except Exception:
            n = -1
        items.append(item("apt", n == 0, f"{n} Updates" if n >= 0 else "n/a"))

    except Exception as e:
        log(f"ERROR {e}")
        items.append(item("internal", False, str(e)[:80]))

    critical = [i for i in items if i["id"] != "apt"]
    ok = all(i["ok"] for i in critical)
    data = {
        "ok": ok,
        "score": sum(1 for i in items if i["ok"]),
        "max": len(items),
        "at": now_str(),
        "items": items,
    }
    try:
        tmp = OUT.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        tmp.replace(OUT)
    except Exception as e:
        log(f"write JSON fail: {e}")
    log(f"done ok={ok} score={data['score']}/{data['max']}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
