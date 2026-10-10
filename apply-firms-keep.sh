#!/bin/bash
set -euo pipefail
# firmsKeep: Waldbrand-Historie firms_history.json ueberlebt Neustarts (Laden beim Import).
# Ohne feste sha16: prueft Anker (longArchive, firms-Funktionen), zeigt sha16 vorher/nachher. Sendet nichts. Neustart nur prepper-dashboard.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/firmskeep
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== firmsKeep apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="53956d13df59eeabe03e95e56f549420230c14456bcad37ab6d40362c27d5a2f"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-firms-keep.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""firmsKeep: Block vor __main__ in dashboard.py. Sendet nichts."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== firmsKeep:"
NEED = ["# ===== longArchive:", "FIRMS_HISTORY_FILE", "firms_history", "def record_firms_history", "def save_firms_history"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== firmsKeep: Waldbrand-Historie (firms_history) beim Start laden, Neustarts behalten sie =====
# Ursache: load_firms_history wurde in __main__ nicht aufgerufen -> leere Deque, naechstes save ueberschrieb die Datei.
# Laedt einmal beim Import (vor __main__/update_all), nur wenn die Deque leer ist. Spaetere Ladeaufrufe werden dedupliziert.
import json as _fk_json
_fk_state = {"loaded": False, "n": None, "err": None}


def _fk_dedupe():
    try:
        dq = globals().get("firms_history")
        if dq is None:
            return 0
        seen, out = set(), []
        for it in list(dq):
            k = _fk_json.dumps(it, sort_keys=True, default=str)
            if k in seen:
                continue
            seen.add(k)
            out.append(it)
        if len(out) != len(dq):
            dq.clear()
            dq.extend(out)
            return 1
    except Exception as e:
        print("firmsKeep dedupe:", e, flush=True)
    return 0


def _fk_boot_load():
    if _fk_state["loaded"]:
        return
    _fk_state["loaded"] = True
    dq = globals().get("firms_history")
    try:
        if dq is None or len(dq) > 0:
            _fk_state["n"] = len(dq) if dq is not None else None
            print("firmsKeep: Deque schon gefuellt (%s) - nichts geladen" % _fk_state["n"], flush=True)
            return
        with open(FIRMS_HISTORY_FILE, "r", encoding="utf-8") as f:
            d = _fk_json.load(f)
        items = d.get("firms") if isinstance(d, dict) else d
        if isinstance(items, list):
            dq.extend(x for x in items if isinstance(x, dict))
        _fk_state["n"] = len(dq)
        print("firmsKeep: %d Punkte geladen" % len(dq), flush=True)
    except FileNotFoundError:
        _fk_state["n"] = 0
        print("firmsKeep: 0 Punkte geladen (keine Datei)", flush=True)
    except Exception as e:
        _fk_state["err"] = str(e)
        print("firmsKeep Fehler:", e, flush=True)


if callable(globals().get("load_firms_history")):
    _fk_orig_load = load_firms_history

    def load_firms_history(*a, **k):
        r = _fk_orig_load(*a, **k)
        _fk_dedupe()
        return r

_fk_boot_load()
# ===== /firmsKeep =====

'''
LOADS = ["load_firms_history", "load_fuel_history", "load_oil_history", "load_outage_history", "load_wbi_history",
         "load_dwd_mesh_status", "load_nina_mesh_status", "load_mesh_weather_status", "load_health_status",
         "load_ping_stats", "load_history"]


def calls(src):
    tree = ast.parse(src)
    res = {n: [0, 0, 0] for n in LOADS}   # [Modulebene, __main__, in Funktionen]
    def walk(node, where):
        for ch in ast.iter_child_nodes(node):
            w = where
            if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                w = 2
            elif isinstance(ch, ast.If) and where == 0 and "__main__" in ast.dump(ch.test):
                w = 1
            if isinstance(ch, ast.Call) and isinstance(ch.func, ast.Name) and ch.func.id in res:
                res[ch.func.id][w] += 1
            walk(ch, w)
    walk(tree, 0)
    return res


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    src = f.read_text(encoding="utf-8")
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    c = calls(src)
    print("LADEN (Modul/__main__/Funktion):", " ".join("%s=%d/%d/%d" % (n.replace("load_", ""), *c[n]) for n in LOADS))
    if MARK in src:
        print("RESULT dashboard.py=schon sha16 %s" % h)
        return
    miss = [a for a in NEED if a not in src]
    if miss:
        raise SystemExit("STOP: fehlt %s - nichts geaendert" % miss)
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s, nachher %s)" % (h, hashlib.sha256(new.encode()).hexdigest()[:16]))


if __name__ == "__main__":
    main()
PATCHPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-firms-keep.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
for node in ast.walk(ast.parse(blk)):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if a.name.split(".")[0] in ("requests", "urllib", "socket", "http", "subprocess", "meshtastic"):
                print("verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        f = node.func
        fn = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("update_all", "urlopen", "Popen", "system", "remove", "unlink"):
            print("verbotener Aufruf", fn); hit = True
        if fn == "open" and len(node.args) >= 2 and isinstance(node.args[1], ast.Constant) and any(c in str(node.args[1].value) for c in "wax+"):
            print("Schreib-open im Block"); hit = True
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name) and node.value.id == "data_store" and isinstance(node.ctx, ast.Store):
        print("data_store-Schreiben"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (Block liest nur, kein Senden, kein Abruf, kein Schreiben)"

# ---------- 1) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error::SyntaxWarning -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
npts() { python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    l = d.get("firms") if isinstance(d, dict) else d
    print(len(l) if isinstance(l, list) else -1)
except FileNotFoundError:
    print(0)
except Exception:
    print(-1)' "$DASH_DIR/firms_history.json"; }
span() { python3 -c 'import json,sys
try:
    l = json.load(open(sys.argv[1])).get("firms") or []
    print("erster", l[0].get("t"), "letzter", l[-1].get("t")) if l else print("leer")
except Exception as e:
    print("?", e)' "$DASH_DIR/firms_history.json"; }
declare -A PRE
for p in / /pi /energie; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pi=${PRE[/pi]} /energie=${PRE[/energie]}"
N0=$(npts); echo "firms_history.json vorher: $N0 Punkte ($(span))"

if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK firmsKeep schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-firmskeep-$TS" "$F"
    [[ -f "$W/firms_before.json" ]] && cp -a "$W/firms_before.json" "$DASH_DIR/firms_history.json"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-firmskeep-$TS"
  }
  cp -a "$F" "$F.bak-firmskeep-$TS"
  [[ -f "$DASH_DIR/firms_history.json" ]] && cp -a "$DASH_DIR/firms_history.json" "$W/firms_before.json"
  [[ -f "$DASH_DIR/firms_history.json" ]] && cp -a "$DASH_DIR/firms_history.json" "$DASH_DIR/firms_history.json.bak-firmskeep-$TS"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  L=$(sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a 'firmsKeep' | tail -2 || true)
  echo "Journal: ${L:-keine firmsKeep-Zeile}"
  echo "$L" | grep -q 'firmsKeep Fehler' && { rb "firmsKeep Fehler beim Laden"; exit 1; }
  sleep 20
  N1=$(npts)
  echo "firms_history.json nachher: $N1 Punkte ($(span))"
  if [[ "$N0" -gt 0 && "$N1" -lt "$N0" ]]; then rb "Historie geschrumpft ($N0 -> $N1)"; exit 1; fi
fi
fail=0
for p in / /pi /energie; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-firmskeep-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
echo "OK guards firmsKeep=$(grep -q '# ===== firmsKeep:' "$F" && echo 1 || echo 0) longArchive=$(grep -q '# ===== longArchive:' "$F" && echo 1 || echo 0) priceAllTime=$(grep -q '# ===== priceAllTime:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-firmskeep-$TS" ]] && echo "Backup: $F.bak-firmskeep-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG firmsKeep=1"
