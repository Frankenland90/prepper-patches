#!/bin/bash
set -euo pipefail
# mesh2Calm: Mesh2-Bridge ruhig halten + Abbrueche ehrlich zaehlen.
# - Keepalive-Heartbeat alle 60 s (meshtastic-Lib sendet nur alle 300 s -> tote
#   Verbindung fiel erst nach ~5 min als "Connection reset by peer" auf)
# - alter 60-s-Watchdog der Bridge verbindet nicht mehr neu (Keeper = einziger Besitzer)
# - Abbrueche als Episoden (reset+verloren+neu verbunden = 1), Logzeile je Episode
# - halboffene Verbindung nach "Timed out waiting for connection completion" sofort schliessen
# - KEINE automatische Antwort 300 s nach Bridge-Start, nie auf Ping-Rueckstau nach Reconnect
# - Funk-Banner: gelb ab 3, rot ab 6 Episoden/h; getrennt erst nach 5 min rot
# Sendet nichts. Neustart nur mesh-bridge-bayern (+ Dashboard fuer das Banner, meshBootQuiet).
# Smoke gegen config.py PORT (5000), nie :8080 (kiwix). Bei Fehler: ROLLBACK.
# Aendert nie update_all() # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
BRIDGE="$DASH_DIR/mesh_bridge_bayern.py"
MSESS="$DASH_DIR/mesh_session.py"
DASH="$DASH_DIR/dashboard.py"
STATUS="$DASH_DIR/mesh2_session.json"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/m2calm
EXPECT_PATCH="b7e19b81f4da81ca193fe8916db892c9704e41f54ee3be1f7484987b2761127a"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-mesh2-calm.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""mesh2Calm: Mesh2-Bridge ruhig halten + Abbrueche ehrlich zaehlen.

Patcht (idempotent, Marker mesh2Calm):
  mesh_bridge_bayern.py  PFLICHT  Keepalive-Heartbeat alle 60 s (Lib nur alle 300 s),
                                  alter 60-s-Watchdog ohne Reconnect (Keeper = einziger Besitzer),
                                  Abbrueche als Episoden (+ Logzeile je Episode),
                                  halboffene Verbindung nach Fehler schliessen,
                                  keine automatische Antwort 300 s nach Bridge-Start
                                  und keine Antwort auf Ping-Rueckstau direkt nach Reconnect
  mesh_session.py        weich    Banner nach Episoden (gelb ab 3/h, rot ab 6/h),
                                  getrennt erst nach 5 min rot, Aufschluesselung im Text
Voraussetzung: mesh2OneSession (Stufe A) ist in der Bridge.
Aendert nie update_all() # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
Sendet nichts.
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

MARK = "mesh2Calm"

BRIDGE_BLOCK = r'''
# ===== mesh2Calm: Keepalive, ein Reconnect-Besitzer, Episoden, Ruhezeit =====
import queue as _m2c_queue
M2C_KA_EVERY = 60        # Keepalive-Heartbeat (Lib sendet nur alle 300 s)
M2C_EP_GAP = 90          # Ereignisse innerhalb 90 s = EINE Abbruch-Episode
M2C_BOOT_QUIET = 300     # nach Bridge-Start 5 min keine automatische Antwort
M2C_BACKLOG_WIN = 60     # so lange nach (Re)Connect liefert das Geraet Rueckstau
M2C_BACKLOG_AGE = 120    # Ping aelter als 2 min im Rueckstau -> nie beantworten
_M2C_DISRUPT = ("lost", "libreconnect", "connect_fail", "send_fail", "reconnect")
_m2c = {
    "t0": _m2os_time.time(), "eps": _m2os_deque(maxlen=300), "ep": None, "ep_open": False,
    "ka_on": True, "ka_sent": 0, "ka_fail": 0, "ka_last": 0.0, "short": 0,
    "down_since": None, "quiet_drop": 0, "halfopen": 0, "n": 0,
}
_m2c_tls = _m2os_threading.local()


def _m2c_fmt(ts):
    try:
        return datetime.fromtimestamp(float(ts)).strftime("%H:%M:%S")
    except Exception:
        return "?"


def _m2c_episode(kind, err=None):
    if kind not in _M2C_DISRUPT:
        return
    now = _m2os_time.time()
    ep = _m2c["ep"]
    same = ep is not None and (_m2c["ep_open"] or now - ep["last"] <= M2C_EP_GAP)
    if same:
        ep["kinds"][kind] = ep["kinds"].get(kind, 0) + 1
        ep["last"] = now
        if err and not ep.get("err"):
            ep["err"] = str(err)[:120]
        if kind == "reconnect":
            _m2c["ep_open"] = False
            ep["back"] = now
            log("mesh2Calm: wieder verbunden nach %d s (Episode %d)" % (int(now - ep["start"]), ep["no"]))
        else:
            _m2c["ep_open"] = True
        return
    ca = _m2os.get("connected_at") or 0
    lp = _m2os.get("last_pkt") or 0
    ka = _m2c.get("ka_last") or 0
    _m2c["n"] += 1
    ep = {
        "no": _m2c["n"], "start": now, "last": now, "kinds": {kind: 1}, "cause": kind,
        "err": str(err)[:120] if err else "",
        "sess": int(now - ca) if ca else None,
        "pkt": int(now - max(lp, ca)) if (lp or ca) else None,
        "ka": int(now - ka) if ka else None,
        "back": None,
    }
    _m2c["eps"].append(ep)
    _m2c["ep"] = ep
    _m2c["ep_open"] = kind != "reconnect"
    log("mesh2Calm: Abbruch-Episode %d: %s nach %s s Sitzung, letztes Paket vor %s s, Keepalive vor %s s%s" % (
        ep["no"], kind, ep["sess"], ep["pkt"], ep["ka"], (" - " + ep["err"]) if ep["err"] else ""))
    # Schutz: stirbt die Verbindung wiederholt direkt nach UNSEREM Keepalive, obwohl
    # bis eben Pakete kamen -> Keepalive abschalten (zurueck auf Lib-Standard 300 s).
    if (_m2c["ka_on"] and ep["sess"] is not None and ep["sess"] < M2C_KA_EVERY * 2 + 20
            and ep["pkt"] is not None and ep["pkt"] < 20 and ep["ka"] is not None and ep["ka"] < 8):
        _m2c["short"] += 1
        if _m2c["short"] >= 3:
            _m2c["ka_on"] = False
            log("mesh2Calm: Keepalive AUS - Verbindung fiel 3x direkt nach dem Keepalive (Lib-Standard 300 s bleibt)")
    else:
        _m2c["short"] = 0


_m2c_orig_event = _m2os_event


def _m2os_event(kind, err=None):  # mesh2Calm: zusaetzlich zu Episoden zusammenfassen
    _m2c_orig_event(kind, err)
    try:
        _m2c_episode(kind, err)
    except Exception as e:
        log("mesh2Calm episode:", e)


def _m2c_status(d):
    now = _m2os_time.time()
    cut = now - 3600
    eps = [e for e in list(_m2c["eps"]) if e["start"] >= cut]
    kinds = {}
    for e in eps:
        for k, v in e["kinds"].items():
            kinds[k] = kinds.get(k, 0) + v
    sess = [e["sess"] for e in eps if e.get("sess") is not None]
    conn = bool(d.get("connected"))
    if conn:
        _m2c["down_since"] = None
    elif _m2c["down_since"] is None:
        ep = _m2c["ep"]
        _m2c["down_since"] = ep["start"] if (ep is not None and _m2c["ep_open"]) else now
    quiet_left = int(max(0, M2C_BOOT_QUIET - (now - _m2c["t0"])))
    return {
        "calm": 1,
        "episodes_1h": len(eps),
        "ep_kinds_1h": kinds,
        "sess_avg_1h": int(sum(sess) / len(sess)) if sess else None,
        "episodes": [
            {"at": _m2c_fmt(e["start"]), "cause": e["cause"], "kinds": e["kinds"], "sess": e["sess"],
             "pkt": e["pkt"], "ka": e["ka"], "down": int((e["back"] or now) - e["start"]),
             "open": e["back"] is None, "err": e["err"][:80]}
            for e in eps[-6:]
        ],
        "down_since": _m2c["down_since"],
        "down_for": int(now - _m2c["down_since"]) if _m2c["down_since"] else 0,
        "keepalive": {"on": _m2c["ka_on"], "every": M2C_KA_EVERY, "sent": _m2c["ka_sent"],
                      "fail": _m2c["ka_fail"], "last": _m2c_fmt(_m2c["ka_last"]) if _m2c["ka_last"] else None},
        "quiet_left": quiet_left, "auto_reply_dropped": _m2c["quiet_drop"], "halfopen_closed": _m2c["halfopen"],
    }


_m2c_orig_write = _m2os_write


def _m2os_write(force=False):  # mesh2Calm: Status um Episoden ergaenzen
    before = _m2os.get("last_write")
    _m2c_orig_write(force)
    if _m2os.get("last_write") == before:
        return
    try:
        d = _m2os_json.loads(M2OS_STATUS_FILE.read_text() or "{}")
        d.update(_m2c_status(d))
        tmp = M2OS_STATUS_FILE.with_name(M2OS_STATUS_FILE.name + ".tmp")
        tmp.write_text(_m2os_json.dumps(d, ensure_ascii=False))
        _m2os_os.replace(str(tmp), str(M2OS_STATUS_FILE))
    except Exception as e:
        log("mesh2Calm status:", e)


def watchdog():  # mesh2Calm: alter 60-s-Watchdog verbindet NICHT mehr neu (das macht nur der Keeper)
    log("mesh2Calm: alter Watchdog ohne Reconnect - Keeper ist einziger Reconnect-Besitzer")
    while True:
        _m2os_time.sleep(3600)


def _m2c_keepalive():
    while True:
        _m2os_time.sleep(M2C_KA_EVERY)
        try:
            if not _m2c["ka_on"] or is_held():
                continue
            iface = _iface
            if iface is None or _m2os_dead():
                continue
            if not _m2os_conn_lock.acquire(blocking=False):
                continue  # Reconnect laeuft gerade
            _m2os_conn_lock.release()
            iface.sendHeartbeat()
            _m2c["ka_sent"] += 1
            _m2c["ka_last"] = _m2os_time.time()
        except Exception as e:
            _m2c["ka_fail"] += 1
            log("mesh2Calm Keepalive:", e)


def _m2c_install_tcp_guard():
    """Schlaegt der Verbindungsaufbau fehl (z.B. Timed out waiting for connection
    completion), die halboffene Verbindung sofort schliessen - sonst bleibt ein
    zweiter Client im eigenen Prozess haengen."""
    try:
        import meshtastic.tcp_interface as _m2c_ti
        base = _m2c_ti.TCPInterface
        if getattr(base, "_m2c", False):
            return

        class _M2cTCPInterface(base):
            _m2c = True

            def __init__(self, *a, **kw):
                try:
                    super().__init__(*a, **kw)
                except Exception as e:
                    try:
                        self._wantExit = True
                        self.close()
                    except Exception:
                        pass
                    _m2c["halfopen"] += 1
                    log("mesh2Calm: halboffene Verbindung geschlossen nach:", str(e)[:100])
                    raise

        _m2c_ti.TCPInterface = _M2cTCPInterface
    except Exception as e:
        log("mesh2Calm tcp-guard:", e)


def _m2c_quiet_reason(pkt):
    now = _m2os_time.time()
    left = M2C_BOOT_QUIET - (now - _m2c["t0"])
    if left > 0:
        return "Ruhezeit nach Bridge-Start, noch %d s" % int(left)
    try:
        ca = _m2os.get("connected_at") or 0
        rt = float((pkt or {}).get("rxTime") or 0)
        if ca and now - ca < M2C_BACKLOG_WIN and rt > 0 and M2C_BACKLOG_AGE < now - rt < 6 * 3600:
            return "Rueckstau nach Reconnect, Ping von vor %d s" % int(now - rt)
    except Exception:
        pass
    return None


class _M2cQueue(_m2c_queue.Queue):
    """Sende-Queue: automatische Antworten (aus on_receive) in der Ruhezeit verwerfen."""

    def put_nowait(self, item):
        pkt = getattr(_m2c_tls, "rx", None)
        if pkt is not None:
            why = _m2c_quiet_reason(pkt)
            if why:
                _m2c["quiet_drop"] += 1
                log("mesh2Calm: automatische Antwort NICHT gesendet (%s)" % why)
                return None
        return super().put_nowait(item)


if _send_q.qsize() == 0 and not isinstance(_send_q, _M2cQueue):
    _send_q = _M2cQueue(maxsize=_send_q.maxsize)

_m2c_orig_on_receive = on_receive


def on_receive(packet, interface=None):  # mesh2Calm: Antworten aus diesem Paket ggf. unterdruecken
    _m2c_tls.rx = packet if isinstance(packet, dict) else {}
    try:
        return _m2c_orig_on_receive(packet, interface)
    finally:
        _m2c_tls.rx = None


_m2c_orig_main = main


def main(*a, **kw):  # mesh2Calm
    _m2c_install_tcp_guard()
    _m2os_threading.Thread(target=_m2c_keepalive, daemon=True, name="m2calm-keepalive").start()
    log("mesh2Calm aktiv: Keepalive alle %d s, Reconnect nur Keeper, Episoden %d s, Ruhezeit %d s" % (
        M2C_KA_EVERY, M2C_EP_GAP, M2C_BOOT_QUIET))
    return _m2c_orig_main(*a, **kw)
# ===== /mesh2Calm =====

'''

MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)


def top_names(src):
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


def patch_bridge(src):
    if "# ===== mesh2Calm:" in src:
        return src, "schon"
    if "mesh2OneSession" not in src:
        raise SystemExit("STOP bridge: mesh2OneSession (Stufe A) fehlt")
    funcs, names = top_names(src)
    need_f = {"_m2os_event", "_m2os_write", "_m2os_dead", "_m2os_keeper", "watchdog", "connect",
              "on_receive", "main", "is_held", "log", "send_now", "close_iface"}
    need_n = {"_m2os", "_m2os_conn_lock", "M2OS_STATUS_FILE", "_send_q", "_iface", "_state"}
    miss = sorted((need_f - funcs) | (need_n - names))
    if miss:
        raise SystemExit("STOP bridge: fehlt %s" % ", ".join(miss))
    for frag in ("threading.Thread(target=watchdog", "_m2os_write()", "_m2os_event(\"lost\""):
        if frag not in src:
            raise SystemExit("STOP bridge: Anker fehlt: %s" % frag)
    if "datetime" not in src:
        raise SystemExit("STOP bridge: datetime fehlt")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP bridge: __main__-Block %d mal" % len(ms))
    pos = ms[0].start()
    new = src[:pos].rstrip("\n") + "\n\n" + BRIDGE_BLOCK + "\n" + src[pos:]
    ast.parse(new)
    return new, "neu"


# ---------------------------------------------------------------- mesh_session (weich)
MS_OLD_CONST = "ERR_RED = 12\n"
MS_NEW_CONST = ("ERR_RED = 12\n"
                "EP_WARN = 3   # mesh2Calm: Abbruch-Episoden pro Stunde -> gelb\n"
                "EP_RED = 6    # mesh2Calm: -> rot\n"
                "DOWN_RED_SEC = 5 * 60  # mesh2Calm: erst nach 5 min getrennt rot\n")

MS_OLD_DOWN = (
    "            elif b_active and not connected:\n"
    "                err = (st.get(\"last_error\") or \"\").strip()\n"
    "                w.append((\"red\", \"%s: Bridge nicht mit dem Funkgerät verbunden%s\" % (name, \" (%s)\" % err[:80] if err else \"\")))\n"
)
MS_NEW_DOWN = (
    "            elif b_active and not connected:\n"
    "                err = (st.get(\"last_error\") or \"\").strip()\n"
    "                dfor = int(st.get(\"down_for\") or 0) if st.get(\"calm\") else DOWN_RED_SEC  # mesh2Calm\n"
    "                if dfor >= DOWN_RED_SEC:\n"
    "                    w.append((\"red\", \"%s: Bridge nicht mit dem Funkgerät verbunden%s%s\" % (\n"
    "                        name, \" seit %d min\" % _mins(dfor) if st.get(\"calm\") else \"\", \" (%s)\" % err[:80] if err else \"\")))\n"
    "                else:\n"
    "                    w.append((\"yellow\", \"%s: Verbindung wird neu aufgebaut (seit %d s)\" % (name, dfor)))\n"
)

MS_OLD_CNT = (
    "            n = int(st.get(\"reconnects_1h\") or 0) + int(st.get(\"errors_1h\") or 0)\n"
    "            if n >= ERR_WARN:\n"
    "                err = (st.get(\"last_error\") or \"\").strip()\n"
    "                w.append((\"red\" if n >= ERR_RED else \"yellow\",\n"
    "                          \"%s: %d Abbrüche/Neuverbindungen in 1 h%s\" % (name, n, \" (zuletzt: %s)\" % err[:60] if err else \"\")))\n"
)
MS_NEW_CNT = (
    "            if st.get(\"calm\"):  # mesh2Calm: echte Abbrueche (Episoden) statt Rohereignisse\n"
    "                ne = int(st.get(\"episodes_1h\") or 0)\n"
    "                if ne >= EP_WARN:\n"
    "                    w.append((\"red\" if ne >= EP_RED else \"yellow\", _calm_text(name, ne, st)))\n"
    "            else:\n"
    "                n = int(st.get(\"reconnects_1h\") or 0) + int(st.get(\"errors_1h\") or 0)\n"
    "                if n >= ERR_WARN:\n"
    "                    err = (st.get(\"last_error\") or \"\").strip()\n"
    "                    w.append((\"red\" if n >= ERR_RED else \"yellow\",\n"
    "                              \"%s: %d Abbrüche/Neuverbindungen in 1 h%s\" % (name, n, \" (zuletzt: %s)\" % err[:60] if err else \"\")))\n"
)

MS_OLD_EVAL = "def evaluate(force=False):\n"
MS_HELPER = '''_CALM_KIND = {"libreconnect": "Lib-Neuverbindung", "lost": "verloren", "connect_fail": "Fehlversuch",
              "send_fail": "Sendefehler", "reconnect": "neu verbunden"}


def _calm_text(name, ne, st):  # mesh2Calm
    parts = []
    sa = st.get("sess_avg_1h")
    if sa:
        parts.append("Ø Sitzung %s" % ("%d min" % max(1, int(sa) // 60) if sa >= 60 else "%d s" % int(sa)))
    eps = st.get("episodes") or []
    if eps:
        e = eps[-1]
        why = (e.get("err") or e.get("cause") or "").strip()
        if "] " in why:
            why = why.rsplit("] ", 1)[-1]
        parts.append("zuletzt %s%s" % (str(e.get("at") or "?")[:5], (" " + why[:50]) if why else ""))
    k = st.get("ep_kinds_1h") or {}
    raw = ", ".join("%d %s" % (v, _CALM_KIND.get(x, x)) for x, v in sorted(k.items(), key=lambda kv: -kv[1]) if v)
    if raw:
        parts.append("Rohereignisse: " + raw)
    return "%s: %d Verbindungsabbrüche in 1 h%s" % (name, ne, (" · " + " · ".join(parts)) if parts else "")


'''


def patch_session(src):
    if "mesh2Calm" in src:
        return src, "schon"
    for a in (MS_OLD_CONST, MS_OLD_DOWN, MS_OLD_CNT, MS_OLD_EVAL):
        if src.count(a) != 1:
            return src, "Anker fehlt (weich, Banner bleibt wie bisher)"
    src = src.replace(MS_OLD_CONST, MS_NEW_CONST, 1)
    src = src.replace(MS_OLD_DOWN, MS_NEW_DOWN, 1)
    src = src.replace(MS_OLD_CNT, MS_NEW_CNT, 1)
    src = src.replace(MS_OLD_EVAL, MS_HELPER + MS_OLD_EVAL, 1)
    src = re.sub(r'^VERSION = "([^"]*)"', lambda m: 'VERSION = "%s+mesh2Calm"' % m.group(1), src, count=1, flags=re.M)
    ast.parse(src)
    return src, "neu"


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    fb = root / "mesh_bridge_bayern.py"
    fs = root / "mesh_session.py"
    if not fb.is_file():
        raise SystemExit("STOP: fehlt %s" % fb)
    sb = fb.read_text(encoding="utf-8")
    nb, ib = patch_bridge(sb)
    compile(nb, str(fb), "exec")
    ns, is_ = None, "Datei fehlt (weich)"
    if fs.is_file():
        ss = fs.read_text(encoding="utf-8")
        ns, is_ = patch_session(ss)
        compile(ns, str(fs), "exec")
    changed = []
    if nb != sb:
        fb.write_text(nb, encoding="utf-8")
        changed.append(fb.name)
    if ns is not None and ns != ss:
        fs.write_text(ns, encoding="utf-8")
        changed.append(fs.name)
    print("RESULT bridge=%s" % ib)
    print("RESULT session=%s" % is_)
    print("RESULT changed=%s" % (",".join(changed) or "-"))


if __name__ == "__main__":
    main()
PATCHPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
echo "=== mesh2Calm apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="

# ---------- 0) Bytes + AST-Guard ----------
echo "$EXPECT_PATCH  $W/patch-mesh2-calm.py" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
grep -q 'mesh2Calm' "$W/patch-mesh2-calm.py" || { echo "STOP: Patch ohne Marker"; exit 1; }
if grep -q 'PLACEHOLDER' "$W/patch-mesh2-calm.py"; then echo "STOP: PLACEHOLDER im Patch"; exit 1; fi
python3 -m py_compile "$W/patch-mesh2-calm.py"
set +e
python3 - "$W/patch-mesh2-calm.py" << 'GUARDPY'
import ast, pathlib, sys
hit = False
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
trees = [ast.parse(src)]
m = ast.parse(src)
for n in m.body:  # eingebetteten Bridge-Block mitpruefen
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "BRIDGE_BLOCK" for t in n.targets):
        trees.append(ast.parse(n.value.value))
for tree in trees:
    for node in ast.walk(tree):
        tg = node.targets if isinstance(node, ast.Assign) else ([node.target] if isinstance(node, (ast.AnnAssign, ast.AugAssign)) else [])
        for t in tg:
            if isinstance(t, ast.Name) and t.id == "data_store":
                print("data_store-Zuweisung Zeile", node.lineno); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Attribute) and f.attr == "clear" and isinstance(f.value, ast.Name) and f.value.id == "data_store":
                print("data_store.clear() Zeile", node.lineno); hit = True
            if isinstance(f, ast.Name) and f.id == "update_all":
                print("update_all() Zeile", node.lineno); hit = True
            if isinstance(f, ast.Attribute) and f.attr in ("sendText", "sendData"):
                print("Sende-Aufruf Zeile", node.lineno); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein data_store, kein update_all, kein Sende-Aufruf im Patch)"

# ---------- 1) Voraussetzungen (nur lesen) ----------
for f in "$BRIDGE" "$DASH"; do [[ -f "$f" ]] || { echo "STOP: fehlt $f - nichts geaendert"; exit 1; }; done
grep -q 'mesh2OneSession' "$BRIDGE" || { echo "STOP: Bridge ohne mesh2OneSession (Stufe A fehlt) - nichts geaendert"; exit 1; }
python3 - "$STATUS" << 'PY' || true
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    print("vorher: connected=%s Neuverbindungen/1h=%s Fehler/1h=%s %s" % (d.get("connected"), d.get("reconnects_1h"), d.get("errors_1h"), d.get("counts_1h")))
except Exception as e:
    print("vorher: Status nicht lesbar:", e)
PY

# ---------- 2) Trockenlauf auf Kopien ----------
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$BRIDGE" "$W/work/"
[[ -f "$MSESS" ]] && cp -a "$MSESS" "$W/work/"
set +e
python3 "$W/patch-mesh2-calm.py" "$W/work" > "$W/dry.txt" 2>&1
rc=$?
set -e
cat "$W/dry.txt"
if [[ "$rc" -ne 0 ]]; then
  echo "STOP: Anker nicht gefunden - NICHTS geaendert. Bitte Ausgabe schicken."
  grep -n '^def watchdog\|^def _m2os_write\|^def _m2os_event\|^_send_q\|__main__' "$BRIDGE" | head -8 || true
  exit 1
fi
cp -a "$W/work" "$W/work1"
python3 "$W/patch-mesh2-calm.py" "$W/work" > /dev/null
for f in "$W/work"/*.py; do
  cmp -s "$f" "$W/work1/$(basename "$f")" || { echo "STOP: nicht idempotent ($(basename "$f")) - nichts geaendert"; exit 1; }
  python3 -m py_compile "$f" || { echo "STOP: py_compile $(basename "$f") - nichts geaendert"; exit 1; }
done
grep -q '# ===== mesh2Calm:' "$W/work/mesh_bridge_bayern.py" || { echo "STOP: Marker fehlt nach Trockenlauf"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert"
dash_sum=$(sha256sum "$DASH" | cut -d' ' -f1)

# ---------- 3) Vorher-Stand HTTP ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
pre_root=$(code "$B/"); pre_pi=$(code -L --max-redirs 5 "$B/pi"); pre_funk=$(code -L --max-redirs 5 "$B/funk"); pre_en=$(code "$B/energie")
echo "vorher HTTP / =$pre_root /pi=$pre_pi /funk=$pre_funk /energie=$pre_en"

# ---------- 4) Installieren ----------
b_need=0; s_need=0
cmp -s "$W/work/mesh_bridge_bayern.py" "$BRIDGE" || b_need=1
[[ -f "$W/work/mesh_session.py" ]] && { cmp -s "$W/work/mesh_session.py" "$MSESS" || s_need=1; }
sudo -v
rollback_bridge() {
  echo "ROLLBACK Bridge: $1"
  cp -a "$BRIDGE.bak-m2calm-$TS" "$BRIDGE"
  sudo systemctl restart mesh-bridge-bayern.service || true
  echo "alter Bridge-Stand wieder aktiv"
}
rollback_session() {
  echo "ROLLBACK Funk-Banner: $1"
  cp -a "$MSESS.bak-m2calm-$TS" "$MSESS"
  sudo systemctl restart prepper-dashboard.service || true
}
mainpid() { systemctl show -p MainPID --value mesh-bridge-bayern 2>/dev/null || echo 0; }

if [[ "$b_need" -eq 1 ]]; then
  cp -a "$BRIDGE" "$BRIDGE.bak-m2calm-$TS"
  cp "$W/work/mesh_bridge_bayern.py" "$BRIDGE"
  python3 -m py_compile "$BRIDGE" || { rollback_bridge "py_compile"; exit 1; }
  old_pid=$(mainpid)
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl restart mesh-bridge-bayern.service
  echo "Bridge neu gestartet (vorher PID $old_pid) - warte auf Verbindung (max 120 s, sendet nichts) ..."
  ok=0
  for i in $(seq 1 60); do
    sleep 2
    st=$(systemctl is-active mesh-bridge-bayern 2>/dev/null || true)
    if [[ "$st" == "failed" || "$st" == "inactive" ]]; then break; fi
    pid=$(mainpid)
    if python3 - "$STATUS" "$pid" << 'PY'
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    ok = d.get("calm") == 1 and str(d.get("pid")) == sys.argv[2] and d.get("connected") is True and time.time() - float(d.get("ts") or 0) < 90
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)
PY
    then ok=1; break; fi
    (( i % 10 == 0 )) && echo "  ... $((i*2)) s, Dienst=$st"
  done
  sudo journalctl -u mesh-bridge-bayern --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E 'mesh2Calm|verbunden ids|Traceback|Error' | head -8 || true
  if [[ "$ok" -ne 1 ]]; then
    rollback_bridge "Bridge nach 120 s nicht verbunden bzw. neuer Code laeuft nicht (Dienst=$(systemctl is-active mesh-bridge-bayern 2>/dev/null || true))"
    exit 1
  fi
  echo "OK Bridge verbunden mit mesh2Calm (PID $(mainpid))"
else
  echo "OK Bridge hat mesh2Calm schon - kein Neustart"
fi

if [[ "$s_need" -eq 1 ]]; then
  cp -a "$MSESS" "$MSESS.bak-m2calm-$TS"
  install -m 0644 "$W/work/mesh_session.py" "$MSESS"
  python3 -m py_compile "$MSESS" || { rollback_session "py_compile"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "OK Banner-Logik installiert, Dashboard neu gestartet (meshBootQuiet: 5 min keine Auto-Sendung)"
else
  grep -q 'session=Anker fehlt' "$W/dry.txt" && echo "WARN: mesh_session.py anders als erwartet - Banner bleibt wie bisher (Bridge-Fix aktiv)"
  rollback_session() { echo "WARN (Banner unveraendert): $1"; }
fi
[[ "$(sha256sum "$DASH" | cut -d' ' -f1)" == "$dash_sum" ]] || { echo "WARN: dashboard.py hat sich geaendert?!"; }

# ---------- 5) Smoke Dashboard-Port ----------
echo "--- HTTP Dashboard :$PORT (nicht :8080 = Kiwix) ---"
root=000
for i in $(seq 1 80); do
  root=$(code "$B/")
  [[ "$root" == "200" || "$root" == "500" ]] && break
  (( i % 10 == 1 )) && echo "warte auf Dashboard ... HTTP /=$root"
  sleep 3
done
[[ "$root" == "200" ]] || { rollback_session "HTTP / = $root"; exit 1; }
echo "OK HTTP / = 200"
pi=$(code -L --max-redirs 5 "$B/pi")
if [[ "$pi" != "200" ]] && ! [[ "$pre_pi" != "200" && "$pi" == "$pre_pi" ]]; then rollback_session "HTTP /pi = $pi (vorher $pre_pi)"; exit 1; fi
echo "OK HTTP /pi = $pi (vorher $pre_pi)"
funk=$("${CURL[@]}" -L --max-redirs 5 -o "$W/funk.html" -w "%{http_code}" "$B/funk" || true)
[[ "$funk" == "200" ]] || { rollback_session "HTTP /funk = $funk"; exit 1; }
grep -q 'id="m2osBanner"' "$W/funk.html" || { rollback_session "Banner fehlt auf /funk"; exit 1; }
echo "OK HTTP /funk = 200 mit Mesh-Banner"
en=$(code "$B/energie"); [[ "$en" == "200" || "$en" == "302" ]] || { rollback_session "HTTP /energie = $en"; exit 1; }
echo "OK HTTP /energie = $en (302 = Weiterleitung, ok)"
api=$("${CURL[@]}" -L --max-redirs 5 -o "$W/ms.json" -w "%{http_code}" "$B/api/funk/mesh_session" || true)
[[ "$api" == "200" ]] || { rollback_session "/api/funk/mesh_session = $api"; exit 1; }
echo "OK /api/funk/mesh_session = 200"

# ---------- 6) Stand jetzt ----------
echo "--- Mesh 2 jetzt ---"
python3 - "$STATUS" "$W/ms.json" << 'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
ka = d.get("keepalive") or {}
print("Bridge: verbunden=%s, Keepalive %s alle %ss (gesendet %s), Ruhezeit noch %s s, Episoden/1h=%s" % (
    d.get("connected"), "an" if ka.get("on") else "aus", ka.get("every"), ka.get("sent"), d.get("quiet_left"), d.get("episodes_1h")))
m = json.load(open(sys.argv[2]))
print("Version Funk-Check:", m.get("version"))
items = m.get("items") or []
if not items:
    print("Banner: GRUEN - Mesh-Verbindungen OK")
for it in items:
    print(("Banner ROT:  " if it.get("level") == "red" else "Banner GELB: ") + it.get("text", ""))
PY
n140=$(ss -tn 2>/dev/null | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.140\]?:4403$/' | wc -l)
echo "TCP-Sessions Pi -> Mesh2: $n140"
[[ -f "$DASH_DIR/mesh2_outbox.txt" ]] && echo "Info: mesh2_outbox.txt nicht angefasst (Altpfad ohne Leser, NINA Mesh2 geht direkt ueber :5002)"
had() { grep -q "$1" "$DASH" && echo 1 || echo 0; }
calm=0; grep -q '# ===== mesh2Calm:' "$BRIDGE" && calm=1
echo "OK guards boot=$(grep -q 'update_all()  # einmal beim Start' "$DASH" && echo 1 || echo 0) keepLast=$(had keepLast) meshBootQuiet=$(had meshBootQuiet) uplinkDetect=$(had uplinkDetect) mesh2OneSession=$(grep -q mesh2OneSession "$BRIDGE" && echo 1 || echo 0) mesh2Calm=$calm"
[[ "$b_need" -eq 1 || "$s_need" -eq 1 ]] && echo "Backups: *.bak-m2calm-$TS"
echo "OK mesh2Calm fertig: Keepalive 60 s, Reconnect nur Keeper, Banner nach Episoden"
echo "COMMIT $COMMIT_ARG mesh2Calm=$calm"
