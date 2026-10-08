#!/bin/bash
set -euo pipefail
# mesh2OneSession Stufe B (Funk-Warnung) - Smoke gegen den DASHBOARD-Port (config.py PORT, Standard 5000).
# :8080 ist kiwix-serve (WikiMed), NICHT das Dashboard - wird verweigert.
# - Bridge (Stufe A) muss den Marker schon haben: wird NICHT angefasst, NICHT neu gestartet,
#   Dienste werden NICHT veraendert (nur gelesen).
# - funk_health / dashboard / mesh_hang_watchdog + mesh_session.py (neue Version m2osFunkwarn):
#   Banner auch auf dem Umleitungsziel von /funk, Probe-Schutz zur Laufzeit
#   (kein Probe-Connect zum Funkgeraet solange die Bridge verbunden ist), Dienst-Anzeige = Bridge.
# Smoke auf dem Dashboard-Port mit curl --compressed (-L folgt Umleitungen).
# Aendert nie update_all() # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
# Bei Fehler: ROLLBACK von funk_health/dashboard/watchdog/mesh_session.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
BRIDGE="$DASH_DIR/mesh_bridge_bayern.py"
FUNK="$DASH_DIR/funk_health.py"
DASH="$DASH_DIR/dashboard.py"
HANG="$DASH_DIR/mesh_hang_watchdog.py"
MSESS="$DASH_DIR/mesh_session.py"
STATUS="$DASH_DIR/mesh2_session.json"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/m2fw5
EXPECT_PATCH="493fa0b8f1201da5d87377992104337b3be3cbc075a4289ec3fcfb0b19a2ab90"
EXPECT_MSESS="2cffeda3811fc54bff7066667bac07c62ef03cbbff4b8c2cb81a247f92e59d92"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-mesh2-funkwarn.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""mesh2OneSession Stufe B (Funk-Warnung), Nachzuegler zu apply-mesh2-onesession.

Prueft/patcht (idempotent, Marker mesh2OneSession):
  mesh_bridge_bayern.py  PFLICHT  muss den Marker schon haben (Stufe A) - wird NICHT veraendert
  funk_health.py         PFLICHT  mesh_session.install(app) -> Banner + /api/funk/mesh_session
                         weich    Mesh-Status ohne Probe-Connect (Dienst = Bridge)
  dashboard.py           weich    Probe-Connects nur wenn keine Session besteht,
                                  Dienst-Anzeige = Bridge statt mesh-ping-reply*
  mesh_hang_watchdog.py  weich    startet mesh-ping-reply-2 nicht mehr neu
Fehlt ein PFLICHT-Anker: Exit 2, es wird NICHTS geschrieben.
Aendert nie update_all() # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

MARK = "mesh2OneSession"


FUNK_INSTALL = (
    "    try:  # mesh2OneSession: Mesh-Problem-Banner + /api/funk/mesh_session\n"
    "        import mesh_session as _m2os_ms\n"
    "        _m2os_ms.install(app)\n"
    "    except Exception as _m2os_e:\n"
    "        print(\"mesh_session:\", _m2os_e)\n"
)

PROTECT_LINE = "update_all()  # einmal beim Start"


# ---------------------------------------------------------------- guards
def guard_counts(src: str) -> dict:
    tree = ast.parse(src)
    assign = clear = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "data_store":
                    assign += 1
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
            if isinstance(node.target, ast.Name) and node.target.id == "data_store":
                assign += 1
        elif isinstance(node, ast.Call):
            f = node.func
            if (isinstance(f, ast.Attribute) and f.attr == "clear"
                    and isinstance(f.value, ast.Name) and f.value.id == "data_store"):
                clear += 1
    boot = sum(1 for ln in src.splitlines() if ln.strip() == PROTECT_LINE)
    return {"data_store_assign": assign, "data_store_clear": clear, "boot_line": boot,
            "boot_text": src.count(PROTECT_LINE)}


def top_names(src: str):
    tree = ast.parse(src)
    funcs, names = set(), set()
    for n in tree.body:
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            funcs.add(n.name)
        elif isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    names.add(t.id)
        elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name):
            names.add(n.target.id)
    return funcs, names


# ---------------------------------------------------------------- bridge
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)


def check_bridge(src: str):
    if MARK not in src:
        raise SystemExit("STOP bridge: Marker mesh2OneSession fehlt - erst Stufe A (apply-mesh2-onesession.sh)")
    return src, {"bridge": "schon (Stufe A, unveraendert)",
                 "pong": "ja" if "Pong-Trigger" in src else "erg\u00e4nzt" if "M2OS_ADD_PONG = True" in src else "?"}


# ---------------------------------------------------------------- funk_health
REG_RE = re.compile(r"^def register_funk\(\s*app\s*\)\s*:[^\n]*\n", re.M)
FETCH_RE = re.compile(
    r"^(?P<i>[ \t]+)from dashboard import fetch_mesh_status\n"
    r"(?P=i)st = fetch_mesh_status\(\) or \{\}\n", re.M)


def patch_funk(src: str):
    info = {}
    if "_m2os_ms.install(app)" in src:
        info["funk_banner"] = "schon"
    else:
        ms = list(REG_RE.finditer(src))
        if len(ms) != 1:
            raise SystemExit("STOP funk_health: def register_funk(app) %d mal gefunden" % len(ms))
        m = ms[0]
        src = src[:m.end()] + FUNK_INSTALL + src[m.end():]
        info["funk_banner"] = "neu"
    if "_m2os_ms2.mesh_status()" in src:
        info["funk_status"] = "schon"
    else:
        m = FETCH_RE.search(src)
        if m:
            i = m.group("i")
            repl = (
                f"{i}try:  # mesh2OneSession: ohne Probe-Connect, Dienst = Bridge\n"
                f"{i}    import mesh_session as _m2os_ms2\n"
                f"{i}    st = _m2os_ms2.mesh_status() or {{}}\n"
                f"{i}except Exception:\n"
                f"{i}    from dashboard import fetch_mesh_status\n"
                f"{i}    st = fetch_mesh_status() or {{}}\n"
            )
            src = src[:m.start()] + repl + src[m.end():]
            info["funk_status"] = "neu"
        else:
            info["funk_status"] = "Anker fehlt (weich)"
    ast.parse(src)
    return src, info


# ---------------------------------------------------------------- dashboard (weich)
PROBE_LINK_RE = re.compile(
    r"^(?P<i>[ \t]+)s = socket\.create_connection\(\(host, 4403\), timeout=2\)\n"
    r"(?P=i)s\.close\(\)\n"
    r"(?P=i)tcp = True\n", re.M)
PROBE_PI_RE = re.compile(
    r"^(?P<i>[ \t]+)s = socket\.create_connection\(\(str\(mesh_host\), 4403\), timeout=3\)\n"
    r"(?P=i)s\.close\(\)\n"
    r"(?P=i)mesh_ok = True\n", re.M)


def patch_dashboard(src: str):
    info = {}
    before = guard_counts(src)
    if "_m2os_ms3" in src:
        info["dash_link"] = "schon"
    else:
        m = PROBE_LINK_RE.search(src)
        if m and len(PROBE_LINK_RE.findall(src)) == 1:
            i = m.group("i")
            repl = (
                f"{i}try:  # mesh2OneSession: kein Probe-Connect wenn Bridge verbunden\n"
                f"{i}    import mesh_session as _m2os_ms3\n"
                f"{i}    tcp = _m2os_ms3.port_ok(host)\n"
                f"{i}except Exception:\n"
                f"{i}    s = socket.create_connection((host, 4403), timeout=2)\n"
                f"{i}    s.close()\n"
                f"{i}    tcp = True\n"
            )
            src = src[:m.start()] + repl + src[m.end():]
            info["dash_link"] = "neu"
        else:
            info["dash_link"] = "Anker fehlt (weich)"
    if "_m2os_ms4" in src:
        info["dash_pi"] = "schon"
    else:
        m = PROBE_PI_RE.search(src)
        if m and len(PROBE_PI_RE.findall(src)) == 1:
            i = m.group("i")
            repl = (
                f"{i}try:  # mesh2OneSession: kein Probe-Connect wenn Bridge verbunden\n"
                f"{i}    import mesh_session as _m2os_ms4\n"
                f"{i}    mesh_ok = _m2os_ms4.port_ok(str(mesh_host), 3)\n"
                f"{i}except Exception:\n"
                f"{i}    s = socket.create_connection((str(mesh_host), 4403), timeout=3)\n"
                f"{i}    s.close()\n"
                f"{i}    mesh_ok = True\n"
            )
            src = src[:m.start()] + repl + src[m.end():]
            info["dash_pi"] = "neu"
        else:
            info["dash_pi"] = "Anker fehlt (weich)"
    n = 0
    for svc_old, svc_new in (("mesh-ping-reply-2", "mesh-bridge-bayern"), ("mesh-ping-reply", "mesh-bridge")):
        # fetch_mesh_link(h2, "Mesh 2", "mesh-ping-reply-2") oder svc="..." oder '...' oder .service
        rx = re.compile(r"(fetch_mesh_link\([^()\n]*?(?:svc\s*=\s*)?)([\"'])" + re.escape(svc_old)
                        + r"((?:\.service)?)\2(\s*\))")
        hits = rx.findall(src)
        if len(hits) == 1:
            src = rx.sub(lambda m: m.group(1) + m.group(2) + svc_new + m.group(3) + m.group(2) + m.group(4), src, count=1)
            n += 1
    info["dash_svc"] = str(n)
    after = guard_counts(src)
    if before != after:
        raise SystemExit("STOP dashboard guards %s -> %s" % (before, after))
    return src, info


# ---------------------------------------------------------------- hang watchdog (weich)
def patch_hang(src: str):
    if MARK in src:
        return src, {"hang": "schon"}
    old1 = '"ping_svc": "mesh-ping-reply-2.service",'
    old2_re = re.compile(r'^(?P<i>[ \t]+)units\.append\(cfg\["ping_svc"\]\)\n', re.M)
    if src.count(old1) != 1 or len(old2_re.findall(src)) != 1:
        return src, {"hang": "Anker fehlt (weich, Unit ist maskiert)"}
    src = src.replace(old1, '"ping_svc": None,  # mesh2OneSession: Ping laeuft in der Bridge', 1)
    m = old2_re.search(src)
    i = m.group("i")
    src = src[:m.start()] + (
        f'{i}if cfg.get("ping_svc"):  # mesh2OneSession\n'
        f'{i}    units.append(cfg["ping_svc"])\n') + src[m.end():]
    ast.parse(src)
    return src, {"hang": "neu"}


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    files = {
        "bridge": root / "mesh_bridge_bayern.py",
        "funk": root / "funk_health.py",
        "dash": root / "dashboard.py",
        "hang": root / "mesh_hang_watchdog.py",
    }
    for k in ("bridge", "funk", "dash"):
        if not files[k].is_file():
            raise SystemExit("STOP: fehlt %s" % files[k])
    srcs = {k: p.read_text(encoding="utf-8") for k, p in files.items() if p.is_file()}
    out, info = {}, {}
    # alles erst im Speicher, geschrieben wird nur wenn ALLES ok ist
    out["bridge"], i1 = check_bridge(srcs["bridge"])
    out["funk"], i2 = patch_funk(srcs["funk"])
    out["dash"], i3 = patch_dashboard(srcs["dash"])
    info.update(i1); info.update(i2); info.update(i3)
    if "hang" in srcs:
        out["hang"], i4 = patch_hang(srcs["hang"])
        info.update(i4)
    else:
        info["hang"] = "Datei fehlt"
    for k, s in out.items():
        compile(s, str(files[k]), "exec")
    changed = []
    for k, s in out.items():
        if s != srcs[k]:
            files[k].write_text(s, encoding="utf-8")
            changed.append(files[k].name)
    for k, v in info.items():
        print("RESULT %s=%s" % (k, v))
    print("RESULT changed=%s" % (",".join(changed) or "-"))


if __name__ == "__main__":
    main()
PATCHPY_EOF
cat > "$W/mesh_session.py" << 'MSESSPY_EOF'
#!/usr/bin/env python3
"""Mesh-Sessions pruefen: genau EINE TCP-Session je Funkgeraet. # mesh2OneSession

Wird von funk_health.py geladen (Funk-Seite). Leichtgewichtig:
ein `ss -tnp` + ein `systemctl show`, Ergebnis 20 s gecacht.
Oeffnet KEINE eigene TCP-Verbindung zu einem Node, solange dort
schon eine Session besteht (ein zweiter Client wirft die Bridge raus).
"""
from __future__ import annotations

import html
import json
import re
import socket
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

MARK = "mesh2OneSession"
VERSION = "m2osFunkwarn"  # zweite Version: Redirect-fest, Probe-Schutz zur Laufzeit
BASE = Path("/home/fmg/prepper-dashboard")
STATUS2 = BASE / "mesh2_session.json"
PORT = 4403
CACHE_SEC = 20
PKT_WARN_SEC = 30 * 60
PKT_RED_SEC = 90 * 60
ERR_WARN = 5
ERR_RED = 12
STATUS_OLD_SEC = 5 * 60

_cache = {"ts": 0.0, "data": None}
_cache_lock = threading.Lock()


def _now_str():
    return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def _hosts():
    h1, h2 = "192.168.178.141", "192.168.178.140"
    try:
        import config  # noqa: WPS433
        h1 = getattr(config, "MESH1_HOST", None) or getattr(config, "MESHTASTIC_HOST", None) or h1
        h2 = getattr(config, "MESH2_HOST", None) or getattr(config, "MESHTASTIC_HOST_BAYERN", None) or h2
    except Exception:
        pass
    return str(h1), str(h2)


def meshes():
    h1, h2 = _hosts()
    return [
        {"key": "m1", "name": "Mesh 1", "host": h1, "bridge": "mesh-bridge",
         "extra": ["mesh-ping-reply"], "extra_warn": False, "status": None},
        {"key": "m2", "name": "Mesh 2", "host": h2, "bridge": "mesh-bridge-bayern",
         "extra": ["mesh-ping-reply-2"], "extra_warn": True, "status": STATUS2},
    ]


def _run(cmd, timeout=3):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout or ""
    except Exception:
        return ""


def _unit_of_pid(pid):
    try:
        txt = Path("/proc/%s/cgroup" % int(pid)).read_text()
    except Exception:
        return None
    m = re.findall(r"([A-Za-z0-9@._-]+)\.service", txt)
    return m[-1] if m else None


def _peer_host(peer):
    p = peer.strip()
    if p.startswith("["):
        p = p[1:].split("]")[0]
    else:
        p = p.rsplit(":", 1)[0]
    if p.startswith("::ffff:"):
        p = p[7:]
    return p


def tcp_sessions(hosts):
    """{host: {estab, closewait, owners}} aus `ss -tnp` (nur lesen)."""
    res = {h: {"estab": 0, "closewait": 0, "owners": [], "ok": False} for h in hosts}
    out = _run(["ss", "-tnp"])
    if not out:
        out = _run(["ss", "-tn"])
    if not out:
        return res
    for h in hosts:
        res[h]["ok"] = True
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 5:
            continue
        state, peer = parts[0], parts[4]
        if not peer.endswith(":%d" % PORT):
            continue
        host = _peer_host(peer)
        if host not in res:
            continue
        if state.upper().startswith("ESTAB"):
            res[host]["estab"] += 1
            owner = None
            m = re.search(r"pid=(\d+)", line)
            if m:
                owner = _unit_of_pid(m.group(1)) or "pid %s" % m.group(1)
            if owner and owner not in res[host]["owners"]:
                res[host]["owners"].append(owner)
        elif "CLOSE-WAIT" in state.upper():
            res[host]["closewait"] += 1
    return res


def unit_states(units):
    """{unit: {active, file, load}} mit einem einzigen systemctl-Aufruf."""
    res = {u: {"active": "unknown", "file": "", "load": ""} for u in units}
    if not units:
        return res
    cmd = ["systemctl", "show", "-p", "Id", "-p", "ActiveState", "-p", "UnitFileState", "-p", "LoadState"]
    cmd += ["%s.service" % u for u in units]
    out = _run(cmd)
    for block in out.strip().split("\n\n"):
        d = {}
        for line in block.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
        uid = (d.get("Id") or "").replace(".service", "")
        if uid in res:
            res[uid] = {
                "active": d.get("ActiveState") or "unknown",
                "file": d.get("UnitFileState") or "",
                "load": d.get("LoadState") or "",
            }
    return res


def read_status(path):
    if not path:
        return None
    try:
        d = json.loads(Path(path).read_text() or "{}")
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def _mins(sec):
    return max(1, int(sec // 60))


_ORIG_CC = socket.create_connection


def _probe(host, timeout=2):
    s = None
    try:
        s = _ORIG_CC((host, PORT), timeout=timeout)
        return True
    except Exception:
        return False
    finally:
        try:
            if s is not None:
                s.close()
        except Exception:
            pass


def port_ok(host, timeout=2):
    """True wenn der Node erreichbar ist. Besteht schon eine Session
    (Bridge verbunden), wird NICHT geprobt: ein Probe-Connect wuerde die
    Bridge beim Funkgeraet rauswerfen."""
    try:
        if tcp_sessions([str(host)])[str(host)]["estab"] > 0:
            return True
    except Exception:
        pass
    return _probe(str(host), timeout)


def evaluate(force=False):
    now = time.time()
    with _cache_lock:
        if not force and _cache["data"] is not None and now - _cache["ts"] < CACHE_SEC:
            return _cache["data"]
    ms = meshes()
    hosts = [m["host"] for m in ms]
    units = []
    for m in ms:
        units.append(m["bridge"])
        units.extend(m["extra"])
    ss = tcp_sessions(hosts)
    us = unit_states(units)
    items = []
    per = {}
    for m in ms:
        name, host = m["name"], m["host"]
        s = ss.get(host) or {"estab": 0, "closewait": 0, "owners": [], "ok": False}
        b = us.get(m["bridge"]) or {}
        b_active = b.get("active") == "active"
        st = read_status(m["status"])
        w = []
        if not b_active and b.get("active") not in (None, "", "unknown"):
            w.append(("red", "%s: Bridge-Dienst %s läuft nicht (%s)" % (name, m["bridge"], b.get("active") or "?")))
        if s["estab"] > 1:
            owners = ", ".join(s["owners"]) if s["owners"] else "?"
            w.append(("red", "%s: %d TCP-Sessions gleichzeitig (%s) – Dienste werfen sich gegenseitig raus"
                      % (name, s["estab"], owners)))
        # Mesh1: mesh-ping-reply laeuft seit Wochen problemlos mit -> nur echte Befunde
        # (>1 Session, CLOSE-WAIT, Abbrueche, Stille). Mesh2: mesh-ping-reply-2 = Problem.
        for x in (m["extra"] if m.get("extra_warn") else []):
            u = us.get(x) or {}
            if u.get("active") in ("active", "activating", "reloading"):
                lvl = "red"
                w.append((lvl, "%s: %s läuft zusätzlich – zweiter TCP-Client, stört die Bridge" % (name, x)))
            elif u.get("file") in ("enabled", "enabled-runtime"):
                w.append(("yellow", "%s: %s ist beim Booten aktiviert (kommt nach Neustart wieder)" % (name, x)))
        if s["closewait"]:
            w.append(("yellow", "%s: %d hängende TCP-Verbindung(en) (CLOSE-WAIT)" % (name, s["closewait"])))
        held = False
        connected = None
        pkt_age = None
        if st:
            age = now - float(st.get("ts") or 0)
            held = bool(st.get("held"))
            connected = bool(st.get("connected"))
            if b_active and age > STATUS_OLD_SEC:
                w.append(("yellow", "%s: Bridge-Status seit %d min nicht aktualisiert" % (name, _mins(age))))
            elif held:
                left = 0
                try:
                    left = int((float(st.get("hold_until") or 0) - now) // 60)
                except Exception:
                    pass
                w.append(("yellow", "%s: manuell getrennt (Hold%s)" % (name, ", noch %d min" % left if left > 0 else "")))
            elif b_active and not connected:
                err = (st.get("last_error") or "").strip()
                w.append(("red", "%s: Bridge nicht mit dem Funkgerät verbunden%s" % (name, " (%s)" % err[:80] if err else "")))
            else:
                ref = st.get("last_pkt") or st.get("started_at") or st.get("connected_at")
                if ref:
                    pkt_age = now - float(ref)
                    if pkt_age > PKT_RED_SEC:
                        w.append(("red", "%s: seit %d min kein Paket vom Funkgerät" % (name, _mins(pkt_age))))
                    elif pkt_age > PKT_WARN_SEC:
                        w.append(("yellow", "%s: seit %d min kein Paket vom Funkgerät" % (name, _mins(pkt_age))))
            n = int(st.get("reconnects_1h") or 0) + int(st.get("errors_1h") or 0)
            if n >= ERR_WARN:
                err = (st.get("last_error") or "").strip()
                w.append(("red" if n >= ERR_RED else "yellow",
                          "%s: %d Abbrüche/Neuverbindungen in 1 h%s" % (name, n, " (zuletzt: %s)" % err[:60] if err else "")))
        elif b_active and s["ok"] and s["estab"] == 0:
            w.append(("yellow", "%s: Bridge hat gerade keine TCP-Session zum Funkgerät" % name))
        per[m["key"]] = {
            "name": name, "host": host, "estab": s["estab"], "closewait": s["closewait"],
            "owners": s["owners"], "bridge": m["bridge"], "bridge_active": b_active,
            "extra": {x: us.get(x) for x in m["extra"]}, "held": held, "connected": connected,
            "pkt_age": int(pkt_age) if pkt_age is not None else None,
            "status": st, "warnings": [{"level": l, "text": t} for l, t in w],
        }
        items.extend(w)
    level = "ok"
    if any(l == "red" for l, _ in items):
        level = "red"
    elif items:
        level = "yellow"
    data = {
        "marker": MARK, "at": _now_str(), "ts": now, "level": level,
        "items": [{"level": l, "text": t} for l, t in items], "meshes": per,
    }
    with _cache_lock:
        _cache["ts"] = now
        _cache["data"] = data
    return data


def mesh_status():
    """Ersatz fuer dashboard.fetch_mesh_status() ohne Probe-Connect.
    Dienst = Bridge (nicht mehr mesh-ping-reply*)."""
    ev = evaluate()
    out = {}
    for key, m in (ev.get("meshes") or {}).items():
        estab = m.get("estab") or 0
        b_ok = bool(m.get("bridge_active"))
        tcp = estab > 0
        if not tcp and not b_ok:
            tcp = _probe(m["host"])  # niemand verbunden -> Probe wirft keinen raus
        if m.get("held"):
            color, label = "#eab308", "manuell getrennt"
        elif tcp and b_ok and estab == 1:
            color, label = "#22c55e", "läuft"
        elif tcp and b_ok:
            color, label = "#dc2626", "%d Sessions – Konflikt" % estab
        elif b_ok:
            color, label = "#eab308", "Bridge ohne TCP-Session"
        elif tcp:
            color, label = "#eab308", "Port offen · Bridge aus"
        else:
            color, label = "#ef4444", "offline"
        out[key] = {
            "host": m["host"], "name": m["name"], "tcp": tcp, "svc_ok": b_ok,
            "heard_sec": None, "cw": m.get("closewait") or 0, "color": color,
            "label": label, "at": ev.get("at"),
        }
    return out


def banner_html(ev=None):
    try:
        ev = ev or evaluate()
    except Exception as e:
        return '<div id="m2osBanner" class="card" style="color:#94a3b8">Mesh-Check: %s</div>' % html.escape(str(e)[:80])
    items = ev.get("items") or []
    if not items:
        return ('<div id="m2osBanner" class="card" style="border-color:#166534;padding:8px 14px">'
                '<span style="color:#22c55e;font-weight:600">&#10003; Mesh-Verbindungen OK</span>'
                '<span style="color:#94a3b8;font-size:.8rem"> &middot; je eine TCP-Session &middot; %s</span></div>'
                % html.escape(str(ev.get("at") or "")))
    red = ev.get("level") == "red"
    border = "#b91c1c" if red else "#a16207"
    bg = "#450a0a" if red else "#422006"
    rows = []
    for it in items:
        c = "#fca5a5" if it.get("level") == "red" else "#fde68a"
        dot = "&#9679;"
        rows.append('<div style="margin:3px 0;color:%s">%s %s</div>' % (c, dot, html.escape(it.get("text") or "")))
    hint = ""
    txt = " ".join(i.get("text") or "" for i in items)
    if "mesh-ping-reply" in txt:
        hint = ('<div style="color:#cbd5e1;font-size:.78rem;margin-top:6px">Abhilfe: zweiten Dienst stoppen, '
                'z.B. <code>sudo systemctl disable --now mesh-ping-reply-2</code></div>')
    return ('<div id="m2osBanner" class="card" style="background:%s;border:1px solid %s">'
            '<div class="title" style="color:#fecaca">Mesh-Problem</div>%s%s'
            '<div style="color:#94a3b8;font-size:.75rem;margin-top:6px">Stand %s</div></div>'
            % (bg, border, "".join(rows), hint, html.escape(str(ev.get("at") or ""))))


_CARD_RE = re.compile(r'<div class="card[" ]')
_BODY_RE = re.compile(r"<body[^>]*>", re.I)


def inject(page):
    """Banner vor die erste Karte setzen (sonst direkt nach <body>)."""
    if not isinstance(page, str) or 'id="m2osBanner"' in page:
        return page
    b = banner_html()
    m = _CARD_RE.search(page)
    if m:
        return page[:m.start()] + b + "\n" + page[m.start():]
    m = _BODY_RE.search(page)
    if m:
        return page[:m.end()] + "\n" + b + page[m.end():]
    return page


# ---------------------------------------------------------------- Probe-Schutz zur Laufzeit
# Ein Probe-Connect (socket.create_connection(host, 4403)) wirft die Bridge beim
# Funkgeraet raus. Waehrend Funk-/System-Seiten und in fetch_mesh_link wird ein
# solcher Probe durch eine Attrappe ersetzt, SOLANGE schon eine Session besteht.
# Ausserhalb dieser Stellen (z.B. echtes Senden per TCPInterface) bleibt alles wie es war.
_tls = threading.local()
_sess_cache = {"ts": 0.0, "data": {}}


class _NoProbeSock(object):
    """Attrappe: 'Port offen' ohne echte Verbindung."""

    def close(self):
        pass

    def shutdown(self, *a):
        pass

    def settimeout(self, *a):
        pass

    def setsockopt(self, *a):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def __getattr__(self, name):
        raise OSError("mesh2OneSession: kein Probe-Connect, Bridge ist verbunden")


def _estab(host):
    now = time.time()
    if now - _sess_cache["ts"] > 5:
        try:
            _sess_cache["data"] = tcp_sessions(list({m["host"] for m in meshes()}))
        except Exception:
            _sess_cache["data"] = {}
        _sess_cache["ts"] = now
    return int(((_sess_cache["data"] or {}).get(str(host)) or {}).get("estab") or 0)


def _guarded_cc(address, *a, **kw):
    try:
        if getattr(_tls, "noprobe", 0) and isinstance(address, (tuple, list)) and len(address) >= 2 \
                and int(address[1]) == PORT and _estab(str(address[0])) > 0:
            return _NoProbeSock()
    except Exception:
        pass
    return _ORIG_CC(address, *a, **kw)


_guarded_cc._m2os = True

SVC_MAP = {
    "mesh-ping-reply-2": "mesh-bridge-bayern", "mesh-ping-reply-2.service": "mesh-bridge-bayern.service",
    "mesh-ping-reply": "mesh-bridge", "mesh-ping-reply.service": "mesh-bridge.service",
}


def _wrap_link(orig):
    def fetch_mesh_link(*a, **kw):  # mesh2OneSession: Dienst = Bridge, kein Probe bei Session
        a = list(a)
        if len(a) >= 3 and a[2] in SVC_MAP:
            a[2] = SVC_MAP[a[2]]
        if kw.get("svc") in SVC_MAP:
            kw["svc"] = SVC_MAP[kw["svc"]]
        _tls.noprobe = getattr(_tls, "noprobe", 0) + 1
        try:
            return orig(*a, **kw)
        finally:
            _tls.noprobe -= 1
    fetch_mesh_link._m2os = True
    fetch_mesh_link.__wrapped__ = orig
    return fetch_mesh_link


def _wrap_portok(orig):
    def _mesh_port_ok(host, *a, **kw):  # mesh2OneSession
        try:
            if _estab(str(host)) > 0:
                return True
        except Exception:
            pass
        return orig(host, *a, **kw)
    _mesh_port_ok._m2os = True
    return _mesh_port_ok


def patch_modules():
    """dashboard (auch als __main__) zur Laufzeit absichern. Idempotent."""
    import sys
    n = 0
    for name in ("__main__", "dashboard"):
        mod = sys.modules.get(name)
        if mod is None:
            continue
        f = getattr(mod, "fetch_mesh_link", None)
        if callable(f) and not getattr(f, "_m2os", False):
            setattr(mod, "fetch_mesh_link", _wrap_link(f))
            n += 1
        f = getattr(mod, "_mesh_port_ok", None)
        if callable(f) and not getattr(f, "_m2os", False):
            setattr(mod, "_mesh_port_ok", _wrap_portok(f))
            n += 1
    return n


_funk_paths = {"/funk"}
_NOPROBE_PATHS = {"/funk", "/pi"}  # nur GET-Seitenaufrufe, nie Sende-Aktionen


def _norm(path):
    return (path or "").rstrip("/") or "/"


def _learn_redirect(resp):
    """/funk leitet um -> Ziel merken, Banner dort zeigen."""
    try:
        loc = resp.headers.get("Location") or ""
        if not loc:
            return
        from urllib.parse import urlparse
        p = _norm(urlparse(loc).path)
        low = p.lower()
        if p and not any(x in low for x in ("login", "auth", "static", "/api/")):
            if p not in _funk_paths:
                print("mesh_session: /funk leitet um nach", p, "- Banner dort")
            _funk_paths.add(p)
    except Exception:
        pass


def install(app):
    """Route /api/funk/mesh_session + Banner auf /funk (auch nach Umleitung)."""
    import socket as _sock
    if not getattr(_sock.create_connection, "_m2os", False):
        _sock.create_connection = _guarded_cc
    try:
        patch_modules()
    except Exception as e:
        print("mesh_session patch_modules:", e)
    if getattr(app, "_m2os_installed", False):
        return
    app._m2os_installed = True
    from flask import jsonify, request

    def _api():
        try:
            d = dict(evaluate(force=True))
            d["version"] = VERSION
            d["funk_paths"] = sorted(_funk_paths)
            return jsonify(d)
        except Exception as e:
            return jsonify({"marker": MARK, "level": "unknown", "error": str(e)[:200], "items": []})

    try:
        app.add_url_rule("/api/funk/mesh_session", "m2os_mesh_session", _api)
    except Exception as e:
        print("mesh_session route:", e)

    def _before():
        try:
            path = _norm(request.path)
            if request.method == "GET" and (path in _funk_paths or path in _NOPROBE_PATHS
                                            or path.startswith("/api/funk")):
                patch_modules()
                _tls.noprobe = 1
            else:
                _tls.noprobe = 0
        except Exception:
            _tls.noprobe = 0

    def _after(resp):
        try:
            _tls.noprobe = 0
            path = _norm(request.path)
            if path == "/funk" and 300 <= resp.status_code < 400:
                _learn_redirect(resp)
                return resp
            if path not in _funk_paths:
                return resp
            if resp.status_code != 200 or resp.mimetype != "text/html" or resp.direct_passthrough:
                return resp
            enc = (resp.headers.get("Content-Encoding") or "").lower()
            if enc and enc != "gzip":
                return resp
            raw = resp.get_data()
            if enc == "gzip":
                import gzip
                raw = gzip.decompress(raw)
            cs = (resp.mimetype_params or {}).get("charset") or "utf-8"
            page = raw.decode(cs)
            new = inject(page)
            if new != page:
                out = new.encode(cs)
                if enc == "gzip":
                    import gzip
                    out = gzip.compress(out)
                resp.set_data(out)
        except Exception as e:
            print("mesh_session banner:", e)
        return resp

    app.before_request(_before)
    app.after_request(_after)


if __name__ == "__main__":
    print(json.dumps(evaluate(force=True), ensure_ascii=False, indent=1))
MSESSPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1
fi
if [[ "$PORT" == "8080" ]]; then
  echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1
fi
echo "Dashboard-Port: $PORT (config.py: ${CFG_PORT:-fehlt, Standard 5000})"
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
echo "=== mesh2OneSession Funk-Warnung (Stufe B) PORT=$PORT ==="

# ---------- 0) Bytes pruefen ----------
echo "$EXPECT_PATCH  $W/patch-mesh2-funkwarn.py" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MSESS  $W/mesh_session.py" | sha256sum -c - >/dev/null || { echo "STOP: mesh_session sha256 falsch"; exit 1; }
for f in "$W/patch-mesh2-funkwarn.py" "$W/mesh_session.py"; do
  grep -q 'mesh2OneSession' "$f" || { echo "STOP: $f ohne Marker"; exit 1; }
  if grep -q 'PLACEHOLDER' "$f"; then echo "STOP: PLACEHOLDER in $f"; exit 1; fi
  python3 -m py_compile "$f"
done
set +e
python3 - "$W/patch-mesh2-funkwarn.py" "$W/mesh_session.py" << 'GUARDPY'
import ast, pathlib, sys
hit = False
for path in sys.argv[1:]:
    tree = ast.parse(pathlib.Path(path).read_text(encoding="utf-8"), filename=path)
    for node in ast.walk(tree):
        tg = []
        if isinstance(node, ast.Assign):
            tg = node.targets
        elif isinstance(node, (ast.AnnAssign, ast.AugAssign)):
            tg = [node.target]
        for t in tg:
            if isinstance(t, ast.Name) and t.id == "data_store":
                print("%s:%s data_store-Zuweisung" % (path, node.lineno)); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Attribute) and f.attr == "clear" and isinstance(f.value, ast.Name) and f.value.id == "data_store":
                print("%s:%s data_store.clear()" % (path, node.lineno)); hit = True
            if isinstance(f, ast.Name) and f.id == "update_all":
                print("%s:%s update_all()" % (path, node.lineno)); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard Patchdateien rc=$g"; exit 1; }
echo "OK Bytes + AST-Guard (kein data_store/update_all im Patch)"

# ---------- 1) Stufe A vorhanden? (nur lesen) ----------
for f in "$BRIDGE" "$FUNK" "$DASH"; do
  [[ -f "$f" ]] || { echo "STOP: fehlt $f - nichts geaendert"; exit 1; }
done
if ! grep -q 'mesh2OneSession' "$BRIDGE"; then
  echo "STOP: Bridge ohne mesh2OneSession - erst apply-mesh2-onesession.sh (Stufe A). Nichts geaendert."
  exit 1
fi
echo "OK Stufe A schon drin - Bridge + Dienste bleiben unangetastet"
echo "Info: mesh-bridge-bayern=$(systemctl is-active mesh-bridge-bayern 2>/dev/null || true) mesh-ping-reply-2=$(systemctl is-active mesh-ping-reply-2 2>/dev/null || true)/$(systemctl is-enabled mesh-ping-reply-2 2>/dev/null || true)"
python3 - "$STATUS" << 'PY' || true
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    age = d.get("last_pkt_age")
    print("Info: Bridge-Status connected=%s Paket vor %s s Neuverbindungen/1h=%s Fehler/1h=%s (Stand vor %d s)" % (
        d.get("connected"), age if age is not None else "-", d.get("reconnects_1h"), d.get("errors_1h"),
        int(time.time() - float(d.get("ts") or 0))))
except Exception as e:
    print("Info: Bridge-Status nicht lesbar:", e)
PY
n140=$(ss -tn 2>/dev/null | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.140\]?:4403$/' | wc -l)
echo "Info: TCP-Sessions Pi -> Mesh2 (.140:4403): $n140"

# ---------- 2) /funk vorher ansehen (Umleitung) ----------
funk_probe() {
  local tag="$1" out1 out2
  out1=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "$B/funk" || true)
  F1_CODE="${out1%% *}"; F1_LOC="${out1#* }"; [[ "$F1_LOC" == "$out1" ]] && F1_LOC=""
  out2=$("${CURL[@]}" -L --max-redirs 5 -o "$W/funk-$tag.html" -w '%{http_code} %{url_effective} %{num_redirects}' "$B/funk" || true)
  read -r FL_CODE FL_URL FL_N <<< "$out2" || true
  [[ -z "${F1_CODE:-}" ]] && F1_CODE=000
  [[ -z "${FL_CODE:-}" ]] && FL_CODE=000
  echo "$tag /funk: HTTP $F1_CODE${F1_LOC:+ -> $F1_LOC} | mit -L: HTTP $FL_CODE ${FL_URL:-} (${FL_N:-0} Umleitung(en))"
}
funk_probe vorher
PRE_FINAL="$FL_CODE"
PRE_LOC="$F1_LOC"
echo "--- wer bedient /funk? ---"
grep -n '"/funk\|'"'"'/funk' "$DASH_DIR"/*.py 2>/dev/null | grep -v 'href=' | grep -v '\.bak' | head -8 || true
grep -n 'before_request\|redirect(' "$DASH" 2>/dev/null | head -8 || true

# ---------- 3) Trockenlauf auf Kopien (aendert nichts) ----------
rm -rf "$W/work" && mkdir -p "$W/work"
cp -a "$BRIDGE" "$FUNK" "$DASH" "$W/work/"
[[ -f "$HANG" ]] && cp -a "$HANG" "$W/work/"
set +e
python3 "$W/patch-mesh2-funkwarn.py" "$W/work" > "$W/dry.txt" 2>&1
rc=$?
set -e
cat "$W/dry.txt"
if [[ "$rc" -ne 0 ]]; then
  echo "STOP: Anker nicht gefunden - NICHTS geaendert. Bitte Ausgabe schicken."
  grep -n 'def register_funk\|fetch_mesh_status' "$FUNK" | head -5 || true
  grep -n 'def fetch_mesh_link\|fetch_mesh_link(\|4403' "$DASH" | head -10 || true
  exit 1
fi
cmp -s "$W/work/mesh_bridge_bayern.py" "$BRIDGE" || { echo "STOP: Bridge wuerde geaendert - nichts geaendert"; exit 1; }
cp -a "$W/work" "$W/work1"
python3 "$W/patch-mesh2-funkwarn.py" "$W/work" > /dev/null
for f in "$W/work"/*.py; do
  cmp -s "$f" "$W/work1/$(basename "$f")" || { echo "STOP: nicht idempotent ($(basename "$f")) - nichts geaendert"; exit 1; }
  python3 -m py_compile "$f" || { echo "STOP: py_compile $(basename "$f") - nichts geaendert"; exit 1; }
done
echo "OK Trockenlauf idempotent + kompiliert"
if grep -q 'RESULT dash_svc=0' "$W/dry.txt"; then
  echo "Info: dash_svc=0 -> Dienstnamen in dashboard.py anders geschrieben; mesh_session biegt das zur Laufzeit um (fetch_mesh_link: mesh-ping-reply* -> Bridge)"
  grep -n 'fetch_mesh_link(' "$DASH" | grep -v 'def ' | head -4 || true
fi

guard_snap() {
  python3 - "$1" << 'GPY'
import ast, pathlib, sys
t = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for k in ["update_all()  # einmal beim Start", "staleTsBoot", "strom14dChart", "navUnify",
          "gasLngSign", "lngColorFlip", "adsbMilThird", "keepLast", "pageFein"]:
    print("%s\t%d" % (k, t.count(k)))
a = c = 0
for n in ast.walk(ast.parse(t)):
    if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id == "data_store" for x in n.targets):
        a += 1
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "clear" \
            and isinstance(n.func.value, ast.Name) and n.func.value.id == "data_store":
        c += 1
print("data_store_assign\t%d\ndata_store_clear\t%d" % (a, c))
GPY
}
g_before=$(guard_snap "$DASH")
g_after=$(guard_snap "$W/work/dashboard.py")
if [[ "$g_before" != "$g_after" ]]; then
  echo "STOP: Guards im Trockenlauf geaendert - nichts geaendert"; printf '%s\n' "$g_before" "---" "$g_after"; exit 1
fi
echo "OK AST-Guard dashboard.py unveraendert (update_all-Boot, data_store)"

# ---------- 4) Installieren (mit Backups) ----------
need=0
cmp -s "$W/mesh_session.py" "$MSESS" 2>/dev/null || need=1
cmp -s "$W/work/funk_health.py" "$FUNK" || need=1
cmp -s "$W/work/dashboard.py" "$DASH" || need=1
[[ -f "$HANG" ]] && { cmp -s "$W/work/mesh_hang_watchdog.py" "$HANG" || need=1; }
sudo -v
had_ms=0; [[ -f "$MSESS" ]] && had_ms=1
rollback_b() {
  echo "ROLLBACK Funk/Dashboard: $1"
  cp -a "$FUNK.bak-m2fw-$TS" "$FUNK"
  cp -a "$DASH.bak-m2fw-$TS" "$DASH"
  [[ -f "$HANG.bak-m2fw-$TS" ]] && cp -a "$HANG.bak-m2fw-$TS" "$HANG"
  if [[ "$had_ms" == 1 ]]; then cp -a "$MSESS.bak-m2fw-$TS" "$MSESS"; else rm -f "$MSESS"; fi
  sudo systemctl restart prepper-dashboard.service || true
  echo "Bridge-Fix (Stufe A) bleibt aktiv, mesh-ping-reply-2 bleibt aus."
}
if [[ "$need" -eq 1 ]]; then
  [[ "$had_ms" == 1 ]] && cp -a "$MSESS" "$MSESS.bak-m2fw-$TS"
  cp -a "$FUNK" "$FUNK.bak-m2fw-$TS"
  cp -a "$DASH" "$DASH.bak-m2fw-$TS"
  [[ -f "$HANG" ]] && cp -a "$HANG" "$HANG.bak-m2fw-$TS"
  install -m 0644 "$W/mesh_session.py" "$MSESS"
  cp "$W/work/funk_health.py" "$FUNK"
  cp "$W/work/dashboard.py" "$DASH"
  [[ -f "$W/work/mesh_hang_watchdog.py" ]] && cp "$W/work/mesh_hang_watchdog.py" "$HANG"
  for f in "$MSESS" "$FUNK" "$DASH"; do
    python3 -m py_compile "$f" || { rollback_b "py_compile $(basename "$f")"; exit 1; }
  done
  [[ -f "$HANG" ]] && { python3 -m py_compile "$HANG" || { rollback_b "py_compile mesh_hang_watchdog.py"; exit 1; }; }
  g_now=$(guard_snap "$DASH")
  [[ "$g_now" == "$g_before" ]] || { rollback_b "Guards dashboard.py geaendert"; exit 1; }
  grep -q 'update_all()  # einmal beim Start' "$DASH.bak-m2fw-$TS" && { grep -q 'update_all()  # einmal beim Start' "$DASH" || { rollback_b "Boot-Zeile weg"; exit 1; }; }
  sudo systemctl restart prepper-dashboard.service
  echo "OK Dateien installiert, Dashboard neu gestartet (Bridge NICHT)"
else
  echo "OK schon installiert - nichts geaendert, kein Neustart"
  rollback_b() { echo "STOP (nichts geaendert): $1"; }
fi

# ---------- 5) Smoke Dashboard-Port ----------
echo "--- HTTP Dashboard :$PORT (nicht :8080 = Kiwix) ---"
root=""
for i in $(seq 1 80); do
  root=$("${CURL[@]}" -o "$W/root.html" -w "%{http_code}" "$B/" || true)
  [[ -z "$root" ]] && root=000
  [[ "$root" == "200" || "$root" == "500" ]] && break
  (( i % 10 == 1 )) && echo "warte auf Dashboard ... HTTP /=$root"
  sleep 3
done
[[ "$root" == "500" ]] && { rollback_b "HTTP / = 500"; exit 1; }
[[ "$root" == "200" ]] || { rollback_b "HTTP / = $root"; exit 1; }
echo "OK HTTP / = 200"
eng=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "$B/energie" || true)
echo "HTTP /energie=${eng:-000}"
[[ "$eng" == "500" ]] && { rollback_b "HTTP /energie = 500"; exit 1; }
funk_probe nachher
if [[ "$FL_CODE" != "200" ]]; then
  if [[ "$PRE_FINAL" != "200" && "$FL_CODE" == "$PRE_FINAL" ]]; then
    echo "WARN: /funk war schon vorher final HTTP $PRE_FINAL - Banner nur per /api/funk/mesh_session pruefbar"
  else
    rollback_b "HTTP /funk final = $FL_CODE (vorher $PRE_FINAL)"; exit 1
  fi
elif ! grep -q 'id="m2osBanner"' "$W/funk-nachher.html"; then
  rollback_b "Banner fehlt auf der Funk-Seite (${FL_URL:-?})"
  sudo journalctl -u prepper-dashboard -n 40 --no-pager -o cat 2>/dev/null | grep -i 'mesh_session' | tail -5 || true
  exit 1
else
  echo "OK Funk-Seite HTTP 200 mit Banner (${FL_URL:-/funk})"
fi
api=$("${CURL[@]}" -L --max-redirs 5 -o "$W/ms.json" -w "%{http_code}" "$B/api/funk/mesh_session" || true)
[[ "$api" == "200" ]] || { rollback_b "/api/funk/mesh_session = $api"; exit 1; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("marker")=="mesh2OneSession" else 1)' "$W/ms.json" \
  || { rollback_b "/api/funk/mesh_session ohne Marker"; exit 1; }
echo "OK /api/funk/mesh_session 200"
grep 'RESULT ' "$W/dry.txt" | sed 's/^RESULT /  /' || true

# ---------- 6) Was die Funk-Seite jetzt zeigt ----------
echo "--- Funk-Seite Mesh-Check ---"
python3 - "$W/ms.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
items = d.get("items") or []
print("Version %s, Banner-Seiten: %s" % (d.get("version", "?"), ", ".join(d.get("funk_paths") or [])))
if not items:
    print("GRUEN: Mesh-Verbindungen OK, je eine TCP-Session")
for it in items:
    print(("ROT:  " if it.get("level") == "red" else "GELB: ") + it.get("text", ""))
for k, m in sorted((d.get("meshes") or {}).items()):
    ex = ", ".join("%s=%s/%s" % (u, (s or {}).get("active"), (s or {}).get("file")) for u, s in (m.get("extra") or {}).items())
    print("%s: Sessions=%s CLOSE-WAIT=%s Bridge=%s %s" % (m.get("name"), m.get("estab"), m.get("closewait"),
          "aktiv" if m.get("bridge_active") else "AUS", ex))
PY
echo "--- TCP 4403 (nur Info) ---"
sudo ss -tnp 2>/dev/null | awk '$5 ~ /:4403$/ {print "  " $1, $5, $6}' || true
n140b=$(ss -tn 2>/dev/null | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.140\]?:4403$/' | wc -l)
echo "TCP-Sessions Pi -> Mesh2 nachher: $n140b"

had() { grep -q "$1" "$DASH" && echo 1 || echo 0; }
m2=0; grep -q 'mesh2OneSession' "$BRIDGE" && grep -q '_m2os_ms.install' "$FUNK" && grep -q 'm2osFunkwarn' "$MSESS" && m2=1
echo "OK guards boot=$(grep -q 'update_all()  # einmal beim Start' "$DASH" && echo 1 || echo 0) staleTsBoot=$(had staleTsBoot) strom14dChart=$(had strom14dChart) navUnify=$(had navUnify) gasLngSign=$(had gasLngSign) lngColorFlip=$(had lngColorFlip) adsbMilThird=$(had adsbMilThird) keepLast=$(had keepLast) mesh2OneSession=$m2"
[[ "$need" -eq 1 ]] && echo "Backups: *.bak-m2fw-$TS"
echo "OK mesh2OneSession Funk-Warnung fertig (/funk vorher: ${PRE_LOC:-keine Umleitung})"
echo "COMMIT $COMMIT_ARG mesh2OneSession"
