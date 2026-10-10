#!/bin/bash
set -euo pipefail
# funkHarden: Haertung Funk/Mesh-Stack (aus der 100/100-Pruefung)
# m2  mesh_bridge_bayern.py: /funk Mesh 2 zeigt echte Node-DB + lastHeard (vorher
#     eingefroren seit letztem Verbindungs-Dump -> Node-DB 2, lastHeard 17 h, Funk alt)
# m1  mesh_bridge.py: Verbindungsverlust erkennen, Watchdog verbindet in max 60 s neu,
#     Reconnect unter Sperre (nie zwei Sitzungen im Prozess)
# p1  mesh-ping-reply (Mesh 1) aus + maskiert, NUR wenn sie nachweislich nie antworten kann
#     (setzt iface.onReceive, das die Lib nie aufruft) und die Bridge ping selbst beantwortet.
#     Sie belegt sonst den einzigen TCP-Platz des Funkgeraets (Abbrueche, CLOSE-WAIT).
# Sendet nichts. Neustart nur mesh-bridge-bayern und mesh-bridge. Dashboard unveraendert.
# Smoke gegen config.py PORT (5000), nie :8080. Jede Stufe mit eigenem ROLLBACK.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
B2="$DASH_DIR/mesh_bridge_bayern.py"
B1="$DASH_DIR/mesh_bridge.py"
PR1="$DASH_DIR/mesh_ping_reply.py"
DASH="$DASH_DIR/dashboard.py"
STATUS2="$DASH_DIR/mesh2_session.json"
U1=mesh-ping-reply.service
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/funkharden
EXPECT_PATCH="1ab7d142470e02b2459cd850b43afd6bc136fae21d373089e754b22cc574b321"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-funk-harden.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""funkHarden: Haertung Funk/Mesh-Stack (Mesh2-Statusquelle, Mesh1 eine Sitzung).

m2 (Pflicht) mesh_bridge_bayern.py: lastHeard = letztes Paket eines anderen Knotens,
   Node-DB = max(nodedb_count, Knoten der Sitzung). Vorher eingefroren seit dem letzten
   Verbindungs-Dump (Node-DB 2, lastHeard 17 h, Funk alt).
m1 (weich) mesh_bridge.py: Verbindungsverlust per connection.lost erkennen, Watchdog-
   Reconnect unter _lock (keine zwei Sitzungen im Prozess).
ping (nur Befund) mesh_ping_reply.py: setzt iface.onReceive (von der Lib nie aufgerufen)
   -> antwortet nie, belegt aber den einzigen TCP-Platz des Funkgeraets.
Sendet nichts.
"""
import ast
import re
import sys
from pathlib import Path

M2_BLOCK = r'''
# ===== funkHarden m2: Node-DB/lastHeard aus der laufenden Sitzung =====
_m2f = {"rx": 0.0, "n": 0}
_m2f_orig_on_receive = on_receive


def on_receive(packet, interface=None):  # funkHarden: Empfang von anderen Knoten merken
    try:
        if isinstance(packet, dict) and (interface is None or interface is _iface) and not _is_self(packet):
            _m2f["rx"] = _m2os_time.time()
            _m2f["n"] += 1
    except Exception:
        pass
    return _m2f_orig_on_receive(packet, interface)


_m2f_orig_pick = mesh_chutil.pick_local_metrics


def _m2f_pick(iface, my_ids=None):  # funkHarden
    r = _m2f_orig_pick(iface, my_ids)
    if not r or iface is None:
        return r
    try:
        n = len(getattr(iface, "nodes", None) or {})
        cur = r.get("nodedb")
        if n and (cur is None or n > int(cur)):
            r["nodedb"] = n
    except Exception:
        pass
    try:
        if iface is _iface and _m2f["rx"] > 0:
            r["heard_sec"] = max(0, int(_m2os_time.time() - _m2f["rx"]))
            r["heard_src"] = "bridge-rx"
    except Exception:
        pass
    r["m2fresh"] = 1
    r["rx_other_n"] = _m2f["n"]
    return r


mesh_chutil.pick_local_metrics = _m2f_pick
log("funkHarden m2 aktiv: lastHeard = letztes Paket eines anderen Knotens, Node-DB aus Sitzung")
# ===== /funkHarden m2 =====
'''

M1_BLOCK = r'''
# ===== funkHarden m1: Verbindungsverlust erkennen =====
def _fh_on_lost(interface=None):  # funkHarden: tote Sitzung -> Watchdog verbindet neu (max 60 s)
    try:
        if interface is not None and interface is _iface and not is_held():
            _state["connected"] = False
            _state["last_error"] = "Verbindung verloren"
            log("funkHarden m1: Verbindung verloren - Watchdog verbindet neu (max 60 s)")
    except Exception:
        pass


def _fh_hook():
    try:
        from pubsub import pub as _fh_pub
        _fh_pub.subscribe(_fh_on_lost, "meshtastic.connection.lost")
        log("funkHarden m1 aktiv: Verlust-Erkennung, Watchdog-Reconnect unter Sperre")
    except Exception as e:
        log("funkHarden m1 lost-hook:", e)


_fh_hook()
# ===== /funkHarden m1 =====
'''

M1_WD_OLD = (
    "            if _iface is None or not _state.get(\"connected\"):\n"
    "                log(\"Watchdog: reconnect\")\n"
    "                try:\n"
    "                    connect()\n"
)
M1_WD_NEW = (
    "            if _iface is None or not _state.get(\"connected\"):\n"
    "                log(\"Watchdog: reconnect\")\n"
    "                try:\n"
    "                    with _lock:  # funkHarden: nie parallel zu ensure_iface()\n"
    "                        connect()\n"
)

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
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names:
                names.add((a.asname or a.name).split(".")[0])
    return funcs, names


def insert_before_main(src, block):
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise ValueError("__main__-Block %d mal" % len(ms))
    pos = ms[0].start()
    return src[:pos].rstrip("\n") + "\n\n" + block + "\n" + src[pos:]


def patch_m2(src):
    if "# ===== funkHarden m2:" in src:
        return src, "schon"
    if "# ===== mesh2Calm:" not in src:
        raise SystemExit("STOP m2: mesh2Calm fehlt in mesh_bridge_bayern.py")
    if "# ===== mesh2Fresh:" in src:
        raise SystemExit("STOP m2: mesh2Fresh schon drin - unerwarteter Stand")
    funcs, names = top_names(src)
    miss = sorted(({"on_receive", "_is_self", "log", "connect"} - funcs) | ({"_m2os_time", "_iface", "mesh_chutil", "CHUTIL_FILE"} - names))
    if miss:
        raise SystemExit("STOP m2: fehlt %s" % ", ".join(miss))
    for frag in ("mesh_chutil.sample_and_store(", 'pub.subscribe(on_receive, "meshtastic.receive")'):
        if frag not in src:
            raise SystemExit("STOP m2: Anker fehlt: %s" % frag)
    try:
        new = insert_before_main(src, M2_BLOCK)
    except ValueError as e:
        raise SystemExit("STOP m2: %s" % e)
    ast.parse(new)
    return new, "neu"


def patch_m1(src):
    if "# ===== funkHarden m1:" in src:
        return src, "schon"
    if "mesh2OneSession" in src or "mesh_bridge_bayern" in src:
        return src, "Anker fehlt (falsche Datei)"
    funcs, names = top_names(src)
    miss = sorted(({"connect", "close_iface", "is_held", "log", "watchdog", "on_receive"} - funcs) | ({"_iface", "_state", "_lock"} - names))
    if miss:
        return src, "Anker fehlt (%s)" % ",".join(miss)
    if src.count(M1_WD_OLD) != 1 or 'pub.subscribe(on_receive, "meshtastic.receive")' not in src:
        return src, "Anker fehlt (watchdog/subscribe)"
    if not re.search(r"TRIGGERS\s*=.*[\"']ping[\"']", src) or "Pong-Trigger" not in src:
        return src, "Anker fehlt (Bridge beantwortet ping nicht selbst)"
    new = src.replace(M1_WD_OLD, M1_WD_NEW, 1)
    try:
        new = insert_before_main(new, M1_BLOCK)
    except ValueError:
        return src, "Anker fehlt (__main__)"
    ast.parse(new)
    return new, "neu"


def ping_state(src):
    """dead = kann nie antworten (nur iface.onReceive, kein pubsub)."""
    if src is None:
        return "fehlt"
    if "iface.onReceive = on_receive" in src and "subscribe" not in src and "meshtastic.receive" not in src:
        return "dead"
    return "aktiv"


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    f2 = root / "mesh_bridge_bayern.py"
    f1 = root / "mesh_bridge.py"
    fp = root / "mesh_ping_reply.py"
    if not f2.is_file():
        raise SystemExit("STOP: fehlt %s" % f2)
    s2 = f2.read_text(encoding="utf-8")
    n2, r2 = patch_m2(s2)
    compile(n2, str(f2), "exec")
    s1 = f1.read_text(encoding="utf-8") if f1.is_file() else None
    n1, r1 = (patch_m1(s1) if s1 is not None else (None, "Datei fehlt"))
    if n1 is not None:
        compile(n1, str(f1), "exec")
    ps = ping_state(fp.read_text(encoding="utf-8") if fp.is_file() else None)
    if n2 != s2:
        f2.write_text(n2, encoding="utf-8")
    if n1 is not None and n1 != s1:
        f1.write_text(n1, encoding="utf-8")
    print("RESULT m2=%s" % r2)
    print("RESULT m1=%s" % r1)
    print("RESULT m1ping=%s" % ps)


if __name__ == "__main__":
    main()
PATCHPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
echo "=== funkHarden apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="

# ---------- 0) Bytes + AST-Guard ----------
echo "$EXPECT_PATCH  $W/patch-funk-harden.py" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
grep -q 'funkHarden' "$W/patch-funk-harden.py" || { echo "STOP: Patch ohne Marker"; exit 1; }
python3 -m py_compile "$W/patch-funk-harden.py"
set +e
python3 - "$W/patch-funk-harden.py" << 'GUARDPY'
import ast, pathlib, sys
hit = False
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
trees = [ast.parse(src)]
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ("M2_BLOCK", "M1_BLOCK") for t in n.targets):
        trees.append(ast.parse(n.value.value))
for tree in trees:
    for node in ast.walk(tree):
        tg = node.targets if isinstance(node, ast.Assign) else ([node.target] if isinstance(node, (ast.AnnAssign, ast.AugAssign)) else [])
        for t in tg:
            if isinstance(t, ast.Name) and t.id == "data_store":
                print("data_store-Zuweisung Zeile", node.lineno); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Name) and f.id == "update_all":
                print("update_all() Zeile", node.lineno); hit = True
            if isinstance(f, ast.Attribute) and f.attr in ("sendText", "sendData", "sendHeartbeat", "put_nowait", "clear"):
                print("Sende-/Queue-Aufruf Zeile", node.lineno, f.attr); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein data_store, kein update_all, kein Senden im Patch)"

# ---------- 1) Voraussetzungen ----------
for f in "$B2" "$DASH"; do [[ -f "$f" ]] || { echo "STOP: fehlt $f - nichts geaendert"; exit 1; }; done
python3 - "$DASH_DIR/mesh2_chutil.json" << 'PY' || true
import json, sys
try:
    h = json.load(open(sys.argv[1])); c = h[-1] if h else {}
    print("vorher Mesh2-Karte: %s Node-DB=%s lastHeard=%s s" % (c.get("t"), c.get("nodedb"), c.get("heard_sec")))
except Exception as e:
    print("vorher: mesh2_chutil.json nicht lesbar:", e)
PY

# ---------- 2) Trockenlauf ----------
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$B2" "$W/work/"
[[ -f "$B1" ]] && cp -a "$B1" "$W/work/"
[[ -f "$PR1" ]] && cp -a "$PR1" "$W/work/"
set +e
python3 "$W/patch-funk-harden.py" "$W/work" > "$W/dry.txt" 2>&1
rc=$?
set -e
cat "$W/dry.txt"
[[ "$rc" -eq 0 ]] || { echo "STOP: Pflicht-Anker (Mesh 2) nicht gefunden - NICHTS geaendert. Bitte Ausgabe schicken."; exit 1; }
cp -a "$W/work" "$W/work1"
python3 "$W/patch-funk-harden.py" "$W/work" > /dev/null
for f in "$W/work"/*.py; do
  cmp -s "$f" "$W/work1/$(basename "$f")" || { echo "STOP: nicht idempotent ($(basename "$f")) - nichts geaendert"; exit 1; }
  python3 -m py_compile "$f" || { echo "STOP: py_compile $(basename "$f") - nichts geaendert"; exit 1; }
done
grep -q '# ===== funkHarden m2:' "$W/work/mesh_bridge_bayern.py" || { echo "STOP: Marker m2 fehlt nach Trockenlauf"; exit 1; }
R_M1=$(sed -n 's/^RESULT m1=//p' "$W/dry.txt"); R_P1=$(sed -n 's/^RESULT m1ping=//p' "$W/dry.txt")
echo "OK Trockenlauf idempotent + kompiliert (m1=$R_M1, mesh_ping_reply=$R_P1)"
dash_sum=$(sha256sum "$DASH" | cut -d' ' -f1)
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
pre_root=$(code "$B/"); pre_funk=$(code -L --max-redirs 5 "$B/funk"); pre_pi=$(code -L --max-redirs 5 "$B/pi")
echo "vorher HTTP / =$pre_root /funk=$pre_funk /pi=$pre_pi"
sudo -v
mainpid() { systemctl show -p MainPID --value "$1" 2>/dev/null || echo 0; }

# ---------- 3) m2: Mesh-2-Bridge ----------
rb_m2() { echo "ROLLBACK Mesh 2: $1"; cp -a "$B2.bak-funkharden-$TS" "$B2"; sudo systemctl restart mesh-bridge-bayern.service || true; echo "alter Mesh-2-Stand wieder aktiv"; }
if cmp -s "$W/work/mesh_bridge_bayern.py" "$B2"; then
  echo "OK Mesh 2 hat funkHarden schon - kein Neustart"
else
  cp -a "$B2" "$B2.bak-funkharden-$TS"
  cp "$W/work/mesh_bridge_bayern.py" "$B2"
  python3 -m py_compile "$B2" || { rb_m2 "py_compile"; exit 1; }
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  sudo systemctl restart mesh-bridge-bayern.service
  echo "Mesh-2-Bridge neu gestartet - warte auf Verbindung (max 120 s, sendet nichts) ..."
  ok=0
  for i in $(seq 1 60); do
    sleep 2
    st=$(systemctl is-active mesh-bridge-bayern 2>/dev/null || true)
    [[ "$st" == "failed" || "$st" == "inactive" ]] && break
    pid=$(mainpid mesh-bridge-bayern)
    if python3 - "$STATUS2" "$pid" << 'PY'
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if (d.get("calm") == 1 and str(d.get("pid")) == sys.argv[2] and d.get("connected") is True and time.time() - float(d.get("ts") or 0) < 90) else 1)
except Exception:
    sys.exit(1)
PY
    then ok=1; break; fi
    (( i % 10 == 0 )) && echo "  ... $((i*2)) s, Dienst=$st"
  done
  sudo journalctl -u mesh-bridge-bayern --since "$SINCE" --no-pager -o cat 2>/dev/null > "$W/j2.txt" || true
  grep -E 'funkHarden|verbunden ids|Traceback' "$W/j2.txt" | head -5 || true
  [[ "$ok" -eq 1 ]] || { rb_m2 "Mesh 2 nach 120 s nicht verbunden (Dienst=$(systemctl is-active mesh-bridge-bayern 2>/dev/null || true))"; exit 1; }
  grep -q 'funkHarden m2 aktiv' "$W/j2.txt" || { rb_m2 "neuer Code laeuft nicht (keine funkHarden-Zeile)"; exit 1; }
  echo "OK Mesh 2 verbunden mit funkHarden (PID $(mainpid mesh-bridge-bayern))"
fi
ch=$("${CURL[@]}" -o "$W/chutil2.json" -w "%{http_code}" "http://127.0.0.1:5002/chutil" || true)
[[ "$ch" == "200" ]] || { rb_m2 "Mesh-2-Bridge /chutil = $ch"; exit 1; }
python3 - "$W/chutil2.json" << 'PY' || true
import json, sys
l = (json.load(open(sys.argv[1])).get("live") or {})
print("Mesh 2 live: Node-DB=%s lastHeard=%s s (%s) ch_util=%s" % (l.get("nodedb"), l.get("heard_sec"), l.get("heard_src") or "Dump", l.get("ch_util")) if l else "Info: Mesh 2 noch ohne eigene DeviceMetrics - Karte folgt mit naechstem Telemetriepaket")
PY

# ---------- 4) m1 + p1: Mesh 1 eine Sitzung ----------
m1_done=0; p1_done=0
if [[ "$R_M1" != "neu" && "$R_M1" != "schon" ]]; then
  echo "WARN Mesh 1 uebersprungen: $R_M1 (nichts an Mesh 1 geaendert)"
elif [[ "$R_P1" == "aktiv" ]]; then
  echo "WARN Mesh 1 uebersprungen: mesh_ping_reply.py kann antworten - zwei Clients bleiben, bitte Ausgabe schicken (nichts an Mesh 1 geaendert)"
else
  l1=$(systemctl show -p LoadState --value "$U1" 2>/dev/null || true)
  a1=$(systemctl is-active "$U1" 2>/dev/null || true)
  e1=$(systemctl is-enabled "$U1" 2>/dev/null || true)
  f1=$(systemctl show -p FragmentPath --value "$U1" 2>/dev/null || true)
  echo "vorher $U1: load=${l1:-?} active=${a1:-?} enabled=${e1:-?}"
  moved=""
  rb_m1() {
    echo "ROLLBACK Mesh 1: $1"
    [[ -f "$B1.bak-funkharden-$TS" ]] && cp -a "$B1.bak-funkharden-$TS" "$B1"
    if [[ "$p1_done" -eq 1 ]]; then
      sudo systemctl unmask "$U1" >/dev/null 2>&1 || true
      [[ -n "$moved" && -f "$moved" ]] && sudo mv "$moved" "$f1"
      sudo systemctl daemon-reload
      [[ "$e1" == "enabled" ]] && sudo systemctl enable "$U1" >/dev/null 2>&1 || true
      [[ "$a1" == "active" ]] && sudo systemctl start "$U1" || true
    fi
    sudo systemctl restart mesh-bridge.service || true
    echo "alter Mesh-1-Stand wieder aktiv"
  }
  if [[ "$l1" == "loaded" && "$R_P1" == "dead" ]]; then
    sudo systemctl disable --now "$U1" 2>&1 | grep -v '^Removed' || true
    if [[ -n "$f1" && "$f1" == /etc/systemd/system/* && -f "$f1" ]]; then
      cp -a "$f1" "$DASH_DIR/mesh-ping-reply.service.bak-funkharden-$TS"
      sudo mv "$f1" "$f1.off-funkharden-$TS"; moved="$f1.off-funkharden-$TS"
    fi
    sudo systemctl daemon-reload
    sudo systemctl mask "$U1" >/dev/null 2>&1 || echo "WARN $U1 nur deaktiviert (mask ging nicht)"
    sudo systemctl daemon-reload
    p1_done=1
    [[ "$(systemctl is-active "$U1" 2>/dev/null || true)" == "active" ]] && { rb_m1 "$U1 laeuft noch"; exit 1; }
    echo "OK $U1 gestoppt + maskiert (konnte nie antworten, belegte den TCP-Platz)"
  else
    echo "OK $U1: ${l1:-nicht vorhanden} - nichts zu tun"
  fi
  if ! cmp -s "$W/work/mesh_bridge.py" "$B1" || [[ "$p1_done" -eq 1 ]]; then
    cp -a "$B1" "$B1.bak-funkharden-$TS"
    cp "$W/work/mesh_bridge.py" "$B1"
    python3 -m py_compile "$B1" || { rb_m1 "py_compile"; exit 1; }
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
    grep -E 'funkHarden|verbunden ids|Traceback' "$W/j1.txt" | head -5 || true
    [[ "$ok" -eq 1 ]] || { rb_m1 "Mesh 1 nach 120 s nicht verbunden (Dienst=$(systemctl is-active mesh-bridge 2>/dev/null || true))"; exit 1; }
    grep -q 'funkHarden m1 aktiv' "$W/j1.txt" || { rb_m1 "neuer Code laeuft nicht (keine funkHarden-Zeile)"; exit 1; }
    m1_done=1
    echo "OK Mesh 1 verbunden mit funkHarden (PID $(mainpid mesh-bridge))"
  else
    m1_done=1; echo "OK Mesh 1 hat funkHarden schon - kein Neustart"
  fi
fi
[[ "$(sha256sum "$DASH" | cut -d' ' -f1)" == "$dash_sum" ]] || echo "WARN: dashboard.py hat sich geaendert?!"

# ---------- 5) Smoke Dashboard (nicht neu gestartet) ----------
root=$(code "$B/"); funk=$(code -L --max-redirs 5 "$B/funk"); pi=$(code -L --max-redirs 5 "$B/pi"); en=$(code "$B/energie")
echo "HTTP :$PORT / =$root /funk=$funk /pi=$pi /energie=$en (vorher / =$pre_root /funk=$pre_funk /pi=$pre_pi)"
[[ "$root" == "200" && "$funk" == "200" ]] || echo "WARN: Dashboard antwortet anders als erwartet - Dashboard wurde NICHT angefasst"
n1=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.141\]?:4403$/' | wc -l)
c1=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^CLOSE-WAIT/ && $5 ~ /192\.168\.178\.141\]?:4403$/' | wc -l)
n2=$( (ss -tn 2>/dev/null || true) | awk '$1 ~ /^ESTAB/ && $5 ~ /192\.168\.178\.140\]?:4403$/' | wc -l)
echo "TCP Pi -> Mesh1: ESTAB=$n1 CLOSE-WAIT=$c1 | Pi -> Mesh2: ESTAB=$n2"
fh=0; grep -q '# ===== funkHarden m2:' "$B2" && fh=1
echo "OK guards mesh2OneSession=$(grep -q mesh2OneSession "$B2" && echo 1 || echo 0) mesh2Calm=$(grep -q '# ===== mesh2Calm:' "$B2" && echo 1 || echo 0) funkHarden=$fh m1=$m1_done pingreply1_aus=$p1_done dashboard=unveraendert"
echo "Backups: *.bak-funkharden-$TS"
if [[ "$m1_done" -eq 1 ]]; then echo "OK funkHarden fertig: Mesh 2 Node-DB/lastHeard live (Karte max. 5 min), Mesh 1 eine Sitzung + Verlust-Erkennung"; else echo "OK funkHarden fertig: Mesh 2 Node-DB/lastHeard live (Karte max. 5 min), Mesh 1 unveraendert"; fi
echo "COMMIT $COMMIT_ARG funkHarden=$fh"
