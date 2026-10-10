#!/bin/bash
set -euo pipefail
# mesh1Fresh: Mesh-1-Bridge zeigt lastHeard/Node-DB aus der laufenden Sitzung (wie Mesh 2 seit funkHarden)
# - lastHeard = letztes Paket eines ANDEREN Knotens (alle Portnums), heard_src=bridge-rx
# - Node-DB = live len(iface.nodes) bei jeder Messung
# - Zaehler rx_other_n + Liste zuletzt gehoerter Knoten in /chutil (nur lesen), rx_other_* in /health
# Nur mesh_bridge.py, nur bei exakt geprueftem Stand (sha16 nach funkHarden2), sonst STOP.
# Sendet nichts. Neustart nur mesh-bridge. Smoke 5001 + Dashboard /funk (Port aus config.py, nie 8080).
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/mesh_bridge.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/mesh1fresh
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
[[ -x "$VPY" ]] || VPY=python3
echo "=== mesh1Fresh apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="88a8b2b1f861bd2dbbdb5655dafb287c6ecd0ddfae9064e83594e16020a969ae"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-mesh1-fresh.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""mesh1Fresh: Mesh-1-Bridge lastHeard/Node-DB aus laufender Sitzung (wie funkHarden m2). Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== mesh1Fresh"
EXPECT = "d25aa4d153a42a66"   # mesh_bridge.py nach funkHarden2
ANCHORS = ["# ===== /funkHarden m1 =====", "# ===== /funkHarden2 bridge =====", "pub.subscribe(on_receive, \"meshtastic.receive\")",
           "def _is_self(packet):", "def _from_id(packet):", "def _hops(packet):", "if self.path.startswith(\"/chutil\"):",
           "CHUTIL_FILE = ", "import mesh_node_label", "import mesh_chutil"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== mesh1Fresh: lastHeard/Node-DB aus der laufenden Sitzung (wie Mesh 2) =====
# lastHeard = letztes Paket eines ANDEREN Knotens (alle Portnums, ueber den Empfangs-Callback),
# Node-DB = live len(iface.nodes) bei jeder Messung, Zaehler fuer Pakete anderer Knoten,
# /chutil zeigt zusaetzlich die zuletzt gehoerten Knoten (nur lesen). Sendet nichts.
import collections as _m1f_col
_m1f = {"rx": 0.0, "n": 0, "t0": time.time(), "last": _m1f_col.OrderedDict()}
M1F_KEEP = 60
_m1f_orig_on_receive = on_receive


def on_receive(packet, interface=None):  # mesh1Fresh: Empfang von anderen Knoten merken
    try:
        if isinstance(packet, dict) and (interface is None or interface is _iface) and not _is_self(packet):
            now = time.time()
            _m1f["rx"] = now
            _m1f["n"] += 1
            dec = packet.get("decoded") or {}
            port = str(dec.get("portnum") or ("verschluesselt" if packet.get("encrypted") else "?"))
            fid = _from_id(packet)
            last = _m1f["last"]
            prev = last.pop(fid, None) or {}
            last[fid] = {"ts": now, "port": port, "snr": packet.get("rxSnr"), "rssi": packet.get("rxRssi"),
                         "hops": _hops(packet), "n": int(prev.get("n") or 0) + 1}
            while len(last) > M1F_KEEP:
                last.popitem(last=False)
            _state["rx_other_n"] = _m1f["n"]
            _state["rx_other_at"] = datetime.fromtimestamp(now).strftime("%d.%m.%Y %H:%M:%S")
            _state["rx_other_from"] = fid
            _state["rx_other_port"] = port
    except Exception:
        pass
    return _m1f_orig_on_receive(packet, interface)


_m1f_orig_pick = mesh_chutil.pick_local_metrics


def _m1f_pick(iface, my_ids=None):  # mesh1Fresh
    r = _m1f_orig_pick(iface, my_ids)
    if not r or iface is None:
        return r
    try:
        n = len(getattr(iface, "nodes", None) or {})
        if n:
            r["nodedb_myinfo"] = r.get("nodedb")
            r["nodedb"] = n
    except Exception:
        pass
    try:
        if iface is _iface and _m1f["rx"] > 0:
            r["heard_sec"] = max(0, int(time.time() - _m1f["rx"]))
            r["heard_src"] = "bridge-rx"
    except Exception:
        pass
    r["m1fresh"] = 1
    r["rx_other_n"] = _m1f["n"]
    return r


mesh_chutil.pick_local_metrics = _m1f_pick


def _m1f_label(fid):
    try:
        return mesh_node_label.label_from_iface(_iface, fid)
    except Exception:
        return fid


def _m1f_heard(limit=10):
    now = time.time()
    items = sorted(_m1f["last"].items(), key=lambda kv: kv[1]["ts"], reverse=True)[:limit]
    return [{"node": k, "name": _m1f_label(k), "age_s": int(now - v["ts"]), "port": v["port"],
             "snr": v["snr"], "rssi": v["rssi"], "hops": v["hops"], "n": v["n"]} for k, v in items]


def _m1f_nodes_lastheard(iface, limit=8):
    out = []
    try:
        now = time.time()
        for nid, info in (getattr(iface, "nodes", None) or {}).items():
            if not isinstance(info, dict):
                continue
            lh = info.get("lastHeard")
            try:
                lh = float(lh)
            except Exception:
                continue
            if lh > 1e12:
                lh = lh / 1000.0
            if lh > 1e8:
                out.append((lh, nid))
        out.sort(reverse=True)
        return [{"node": n, "name": _m1f_label(n), "age_s": max(0, int(now - t))} for t, n in out[:limit]]
    except Exception:
        return []


_m1f_orig_do_GET = Handler.do_GET


def _m1f_do_GET(self):  # mesh1Fresh: /chutil um zuletzt gehoerte Knoten ergaenzen (nur lesen)
    if not self.path.startswith("/chutil"):
        return _m1f_orig_do_GET(self)
    try:
        with _lock:
            iface = _iface
            ids = set(_my_ids)
        live = mesh_chutil.pick_local_metrics(iface, ids) if iface else None
        hist = mesh_chutil.hist_payload(CHUTIL_FILE, hours=24)
        rx = _m1f["rx"]
        self._json(200, {"ok": True, "live": live, "hist": hist,
                         "rx_other_n": _m1f["n"], "rx_other_age_s": (int(time.time() - rx) if rx else None),
                         "since_start_s": int(time.time() - _m1f["t0"]),
                         "heard": _m1f_heard(), "nodes_lastheard": _m1f_nodes_lastheard(iface) if iface else []})
    except Exception as e:
        self._json(500, {"ok": False, "error": str(e)})


Handler.do_GET = _m1f_do_GET
log("mesh1Fresh aktiv: lastHeard = letztes Paket eines anderen Knotens, Node-DB live aus Sitzung")
# ===== /mesh1Fresh =====

'''


def main():
    f = Path(sys.argv[1]) / "mesh_bridge.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    if MARK in src:
        print("RESULT mesh_bridge.py=schon")
        return
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    if h != EXPECT and not nosha:
        raise SystemExit("STOP: mesh_bridge.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    miss = [a for a in ANCHORS if a not in src]
    if miss:
        raise SystemExit("STOP: Anker fehlt %s - nichts geaendert" % miss)
    if "M2OS_" in src:
        raise SystemExit("STOP: das ist die Mesh-2-Bridge - nichts geaendert")
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT mesh_bridge.py=neu (sha16 vorher %s)" % h)


if __name__ == "__main__":
    main()
PATCHPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-mesh1-fresh.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
trees = [("patch", ast.parse(src))]
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "BLOCK" for t in n.targets):
        trees.append(("BLOCK", ast.parse(n.value.value)))
hit = False
for nm, tree in trees:
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            f = node.func
            fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if fn in ("TCPInterface", "sendText", "sendData", "sendHeartbeat", "sendPosition", "urlopen", "create_connection", "send_text", "_enqueue", "connect", "sample_and_store"):
                print(nm, "verbotener Aufruf", fn, "Zeile", node.lineno); hit = True
            if isinstance(f, ast.Attribute) and f.attr in ("post", "get", "request") and isinstance(f.value, ast.Name) and f.value.id in ("requests", "urllib"):
                print(nm, "Netz-Aufruf", f.attr, "Zeile", node.lineno); hit = True
raise SystemExit(3 if hit else (0 if len(trees) == 2 else 4))
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Sendeweg, keine neue Verbindung im Patch)"

# ---------- 1) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
echo "  mesh_bridge.py live sha16 $(sha256sum "$F" | cut -c1-16)"
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/mesh_bridge.py" "$W/work1/mesh_bridge.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -m py_compile "$W/work/mesh_bridge.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
grep -q '# ===== mesh1Fresh' "$W/work/mesh_bridge.py" || { echo "STOP: Marker fehlt im Trockenlauf"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
FPRE=$(code -L --max-redirs 5 "$B/funk")
echo "vorher HTTP /funk=$FPRE"
mainpid() { systemctl show -p MainPID --value "$1" 2>/dev/null || echo 0; }

if cmp -s "$W/work/mesh_bridge.py" "$F"; then
  echo "OK mesh_bridge.py hat mesh1Fresh schon - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-m1f-$TS" "$F"
    sudo systemctl restart mesh-bridge.service || true
    echo "alter Stand wieder aktiv (Backup $F.bak-m1f-$TS bleibt)"
  }
  cp -a "$F" "$F.bak-m1f-$TS"
  cp "$W/work/mesh_bridge.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl restart mesh-bridge.service
  echo "Mesh-1-Bridge neu gestartet - warte auf Verbindung (max 120 s, sendet nichts) ..."
  ok=0
  for i in $(seq 1 60); do
    sleep 2
    st=$(systemctl is-active mesh-bridge 2>/dev/null || true)
    [[ "$st" == "failed" || "$st" == "inactive" ]] && break
    h=$("${CURL[@]}" "http://127.0.0.1:5001/health" || true)
    if echo "$h" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("connected") is True else 1)' 2>/dev/null; then ok=1; break; fi
    (( i % 10 == 0 )) && echo "  ... $((i*2)) s, Dienst=$st"
  done
  sudo journalctl -u mesh-bridge --since "$SINCE" --no-pager -o cat 2>/dev/null > "$W/j1.txt" || true
  grep -E 'mesh1Fresh|Traceback' "$W/j1.txt" | head -3 || true
  [[ "$ok" -eq 1 ]] || { rb "Mesh 1 nach 120 s nicht verbunden"; exit 1; }
  grep -q 'mesh1Fresh aktiv' "$W/j1.txt" || { rb "neuer Code laeuft nicht"; exit 1; }
  echo "OK Mesh 1 verbunden mit mesh1Fresh (PID $(mainpid mesh-bridge))"
  "${CURL[@]}" "http://127.0.0.1:5001/chutil" -o "$W/c.json" || true
  python3 - "$W/c.json" << 'PY' || { rb "/chutil ohne mesh1Fresh-Felder"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
need = ("ok", "live", "hist", "rx_other_n", "heard", "nodes_lastheard")
miss = [k for k in need if k not in d]
lv = d.get("live") or {}
print("/chutil: ok=%s Node-DB live=%s (myInfo %s) lastHeard=%s s Quelle=%s rx_other_n=%s" % (
    d.get("ok"), lv.get("nodedb"), lv.get("nodedb_myinfo"), lv.get("heard_sec"), lv.get("heard_src") or "Verbindungsaufbau", d.get("rx_other_n")))
print("zuletzt laut Node-DB:", ", ".join("%s %ss" % (x.get("name"), x.get("age_s")) for x in (d.get("nodes_lastheard") or [])[:4]) or "-")
sys.exit(0 if d.get("ok") is True and not miss and (not lv or lv.get("m1fresh") == 1) else 1)
PY
fi
fc=$(code -L --max-redirs 5 "$B/funk")
echo "HTTP /funk = $fc (vorher $FPRE)"
if [[ "$fc" != "200" && "$fc" != "$FPRE" ]]; then
  if [[ -f "$F.bak-m1f-$TS" ]]; then rb "/funk antwortet schlechter"; fi
  exit 1
fi
n1=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.141\]?:4403$/' | wc -l)
c1=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^CLOSE-WAIT/ && $5 ~ /4403$/' | wc -l)
echo "TCP Pi -> Mesh1 ESTAB=$n1 | CLOSE-WAIT=$c1"
echo "OK guards mesh1Fresh=$(grep -q '# ===== mesh1Fresh' "$F" && echo 1 || echo 0) funkHarden2=$(grep -q '# ===== funkHarden2' "$F" && echo 1 || echo 0) funkHarden=$(grep -q '# ===== /funkHarden m1 =====' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-m1f-$TS" ]] && echo "Backup: $F.bak-m1f-$TS"
echo "Hinweis: /funk Funk wird gruen mit dem naechsten Messpunkt (alle 5 min) nach dem ersten Paket eines anderen Knotens"
echo "COMMIT $COMMIT_ARG mesh1Fresh=1"
