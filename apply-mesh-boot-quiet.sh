#!/bin/bash
set -euo pipefail
# meshBootQuiet=1: nach einem Dashboard-Neustart 5 Minuten keine automatischen Mesh-Sendungen.
# - NINA: zuletzt gesendeter Stand wird aus nina_mesh_status.json geladen; nichts neu senden was schon raus ist
# - ODL/Luft/Kp/Pegel: in der Ruhezeit nur Stand merken; Wetter: kein Nachholen
# - manuelle Buttons (force) bleiben erlaubt. Bridge + Dienste werden NICHT angefasst.
# Smoke auf dem Dashboard-Port aus config.py (5000), 8080 = Kiwix wird verweigert.
# Aendert nie update_all()  # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
STATUS="$DASH_DIR/mesh_boot_quiet.json"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/mbq
EXPECT_PATCH="2c52ab7259472b49c7b80af28d2a660e2b3b0f90ec2c089ba1af735a16967945"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-mesh-boot-quiet.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""meshBootQuiet: 5 Min Ruhe nach Dashboard-Start, keine Auto-Mesh-Doppel-Sendungen.

Patcht dashboard.py (idempotent, Marker meshBootQuiet):
  PFLICHT  Block vor if __name__ == "__main__"
  PFLICHT  maybe_mesh_nina + maybe_mesh_weather muessen existieren
  weich    odl/luft/space/pegel
  weich    load_nina_mesh_status() neben load_mesh_weather_status
  weich    MESH_BOOT_GUARD_SEC = 300
Aendert nie die Zeile update_all()  # einmal beim Start.
Keine data_store-Zuweisung, kein data_store.clear().
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

MARK = "meshBootQuiet"
PROTECT_LINE = "update_all()  # einmal beim Start"

BLOCK = r'''
# ===== meshBootQuiet: 5 Min nach Dashboard-Start keine Auto-Mesh-Sendungen =====
# NINA: gesendeter Stand kommt aus nina_mesh_status.json; in der Ruhezeit wird nichts
#       gesendet, danach normal verglichen (neu -> senden, gleich -> nicht, weg -> Entwarnung).
# ODL/Luft/Space/Pegel: in der Ruhezeit nur aktuellen Stand als "zuletzt" merken.
# Wetter: kein Nachholen - laufender Slot gilt als erledigt, erst naechster Slot sendet.
# Manuell (force=True) bleibt immer erlaubt.
import time as _mbq_time
import inspect as _mbq_inspect
import os as _mbq_os
import json as _mbq_json
MESH_BOOT_QUIET_SEC = 300  # meshBootQuiet
_mbq_t0 = _mbq_time.time()
_mbq_state = {"nina_loaded": False, "nina_file": None, "nina_primed": False, "res": {}, "wx_done": set()}


def _mbq_quiet():
    try:
        return (_mbq_time.time() - _mbq_t0) < MESH_BOOT_QUIET_SEC
    except Exception:
        return False


def _mbq_dir():
    try:
        return _mbq_os.path.dirname(_mbq_os.path.abspath(__file__))
    except Exception:
        return "/home/fmg/prepper-dashboard"


def _mbq_load_nina():
    if _mbq_state["nina_loaded"]:
        return
    _mbq_state["nina_loaded"] = True
    _mbq_state["nina_file"] = _mbq_os.path.exists(_mbq_os.path.join(_mbq_dir(), "nina_mesh_status.json"))
    f = globals().get("load_nina_mesh_status")
    if callable(f):
        try:
            f()
        except Exception as e:
            print("meshBootQuiet load_nina:", e)
    print("meshBootQuiet: NINA zuletzt gesendet=%r (Datei %s)" % (
        (globals().get("last_nina_mesh") or "-")[:60], "da" if _mbq_state["nina_file"] else "fehlt"))


def _mbq_nina_key(nina_data):
    if nina_data is None:
        return None
    items = []
    if isinstance(nina_data, list):
        items = nina_data
    elif isinstance(nina_data, dict):
        items = nina_data.get("alerts") or nina_data.get("warnings") or (
            [nina_data] if nina_data.get("title") else [])
    parts = []
    for w in items or []:
        if isinstance(w, dict):
            city = (w.get("city") or w.get("area") or "").strip()
            title = (w.get("title") or w.get("headline") or w.get("text") or "").strip()
            line = (city + ": " + title).strip(": ").strip()
        else:
            line = str(w).strip()
        if line:
            parts.append(line)
    return " | ".join(parts)[:180] if parts else ""


def _mbq_is_force(orig, a, kw):
    try:
        ba = _mbq_inspect.signature(orig).bind(*a, **kw)
        ba.apply_defaults()
        return bool(ba.arguments.get("force"))
    except Exception:
        return bool(kw.get("force"))


def _mbq_wrap(name, quiet_fn):
    orig = globals().get(name)
    if not callable(orig):
        return "fehlt"
    if getattr(orig, "_mbq", False):
        return "schon"

    def wrapped(*a, **kw):  # meshBootQuiet
        if _mbq_is_force(orig, a, kw):
            return orig(*a, **kw)
        if _mbq_quiet():
            try:
                quiet_fn(*a, **kw)
            except Exception as e:
                print("meshBootQuiet %s:" % name, e)
            return False
        if name == "maybe_mesh_weather":
            try:
                if _mbq_slot_now() in _mbq_state["wx_done"]:
                    return False  # Slot lief in der Ruhezeit: kein Nachholen
            except Exception:
                pass
        return orig(*a, **kw)

    wrapped._mbq = True
    wrapped.__wrapped__ = orig
    wrapped.__name__ = name
    for attr in ("_last_slot",):
        if hasattr(orig, attr):
            setattr(wrapped, attr, getattr(orig, attr))
    globals()[name] = wrapped
    return "neu"


def _mbq_q_nina(nina_data=None, *a, **kw):
    _mbq_load_nina()
    if _mbq_state["nina_primed"]:
        return
    key = _mbq_nina_key(nina_data)
    if key is None:
        return  # Fetch-Fehler: nichts lernen
    _mbq_state["nina_primed"] = True
    if not _mbq_state["nina_file"] and globals().get("last_nina_mesh") is None and key:
        # ohne gespeicherten Stand: aktuelle Warnung gilt als schon gesendet
        globals()["last_nina_mesh"] = key
        print("meshBootQuiet: NINA ohne Datei -> Stand gemerkt, kein Send:", key[:60])
    else:
        print("meshBootQuiet: NINA Ruhezeit, aktuell=%r zuletzt=%r" % (key[:40], (globals().get("last_nina_mesh") or "-")[:40]))


def _mbq_q_hold(*a, **kw):
    pass


def _mbq_q_odl(odl_data=None, *a, **kw):
    d = odl_data
    if d is None and callable(globals().get("fetch_odl")):
        d = fetch_odl()
    st = globals().get("odl_stage")
    stage = st((d or {}).get("avg"))[0] if callable(st) else "unknown"
    if stage != "unknown":
        globals()["last_odl_stage"] = stage
        print("meshBootQuiet: ODL gemerkt", stage)


def _mbq_q_luft(*a, **kw):
    data = None
    try:
        if callable(globals().get("fetch_luft")):
            data = fetch_luft()
    except Exception:
        data = None
    if not data:
        try:
            blob = globals().get("data_store", {}).get("luft")
            data = blob.get("value") if isinstance(blob, dict) else None
        except Exception:
            data = None
    if not isinstance(data, dict):
        return
    n = int(data.get("n_hotspots") or 0)
    pm = (data.get("sensors") or {}).get("pm25")
    if pm is None:
        pm_lvl = "none"
    elif pm >= 50:
        pm_lvl = "red"
    elif pm >= 25:
        pm_lvl = "yellow"
    else:
        pm_lvl = "green"
    globals()["last_luft_fires"] = n
    globals()["last_luft_pm"] = pm_lvl
    globals()["last_luft_stage"] = data.get("stage")
    print("meshBootQuiet: Luft gemerkt Brand=%s PM=%s" % (n, pm_lvl))


def _mbq_q_space(data=None, *a, **kw):
    if not data:
        return
    stage = data.get("stage")
    if not stage and callable(globals().get("space_stage")):
        stage = space_stage(data.get("kp"))[0]
    if stage:
        globals()["last_space_stage"] = stage
        print("meshBootQuiet: Space gemerkt", stage)


def _mbq_slot_now():
    n = now()
    h = n.hour - (n.hour % 3)
    return n.replace(hour=h, minute=0, second=0, microsecond=0).strftime("%Y-%m-%d-%H")


def _mbq_q_weather(*a, **kw):
    try:
        slot = _mbq_slot_now()
        _mbq_state["wx_done"].add(slot)
        w = globals().get("maybe_mesh_weather")
        if w is not None and getattr(w, "_last_slot", None) != slot:
            w._last_slot = slot
            print("meshBootQuiet: Wetter-Slot erledigt", slot)
    except Exception as e:
        print("meshBootQuiet Wetter:", e)


def _mbq_q_pegel(*a, **kw):
    try:
        if globals().get("last_pegel_mesh") is not None:
            return
        items = ((globals().get("data_store", {}).get("pegel") or {}).get("value") or [])
        key = "|".join("%s:%s" % (x.get("id"), x.get("cm")) for x in (items or [])
                       if isinstance(x, dict) and str(x.get("id")) in ("24228009", "24224008"))
        if key:
            globals()["last_pegel_mesh"] = key
    except Exception as e:
        print("meshBootQuiet Pegel:", e)


def _mbq_install():
    res = {}
    _mbq_load_nina()
    res["nina"] = _mbq_wrap("maybe_mesh_nina", _mbq_q_nina)
    res["nina_bayern"] = _mbq_wrap("maybe_mesh_nina_bayern", _mbq_q_hold)
    res["odl"] = _mbq_wrap("maybe_mesh_odl", _mbq_q_odl)
    res["luft"] = _mbq_wrap("maybe_mesh_luft", _mbq_q_luft)
    res["space"] = _mbq_wrap("maybe_mesh_spaceweather", _mbq_q_space)
    res["weather"] = _mbq_wrap("maybe_mesh_weather", _mbq_q_weather)
    res["pegel"] = _mbq_wrap("maybe_mesh_pegel", _mbq_q_pegel)
    _mbq_q_weather()  # laufender Slot sofort erledigt (kein Nachholen)
    _mbq_state["res"] = res
    print("meshBootQuiet aktiv %ds: %s" % (MESH_BOOT_QUIET_SEC, res))
    if __name__ == "__main__":
        try:
            p = _mbq_os.path.join(_mbq_dir(), "mesh_boot_quiet.json")
            with open(p + ".tmp", "w") as f:
                _mbq_json.dump({"marker": "meshBootQuiet", "pid": _mbq_os.getpid(), "t0": _mbq_t0,
                                "quiet_sec": MESH_BOOT_QUIET_SEC, "res": res,
                                "nina_last": (globals().get("last_nina_mesh") or "")[:120],
                                "nina_file": _mbq_state["nina_file"]}, f, ensure_ascii=False)
            _mbq_os.replace(p + ".tmp", p)
        except Exception as e:
            print("meshBootQuiet status:", e)
    return res


try:
    _mbq_install()
except Exception as _mbq_e:
    print("meshBootQuiet install:", _mbq_e)
# ===== /meshBootQuiet =====
'''

MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
LOAD_WX_RE = re.compile(r"^load_mesh_weather_status\(\)\s*$", re.M)
GUARD_RE = re.compile(r"^MESH_BOOT_GUARD_SEC\s*=\s*\d+\s*(#.*)?$", re.M)


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


def top_funcs(src: str):
    tree = ast.parse(src)
    return {n.name for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}


def patch_dashboard(src: str):
    info = {}
    before = guard_counts(src)
    if MARK in src and "_mbq_install" in src:
        info["block"] = "schon"
        return src, info

    if not BLOCK or "meshBootQuiet" not in BLOCK:
        raise SystemExit("STOP: BLOCK leer/kaputt")

    funcs = top_funcs(src)
    if "maybe_mesh_nina" not in funcs:
        raise SystemExit("STOP: maybe_mesh_nina fehlt")
    if "maybe_mesh_weather" not in funcs:
        raise SystemExit("STOP: maybe_mesh_weather fehlt")
    tree = ast.parse(src)
    fn = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    nina_names = {x.id for x in ast.walk(fn["maybe_mesh_nina"]) if isinstance(x, ast.Name)}
    if "last_nina_mesh" not in nina_names:
        raise SystemExit("STOP: maybe_mesh_nina nutzt last_nina_mesh nicht - Annahme passt nicht")
    info["nina"] = "ok (last_nina_mesh)"
    wx_src = ast.get_source_segment(src, fn["maybe_mesh_weather"]) or ""
    info["weather"] = "ok (_last_slot)" if "_last_slot" in wx_src else "ok (eigene Slot-Sperre)"
    for soft in ("maybe_mesh_odl", "maybe_mesh_luft", "maybe_mesh_spaceweather", "maybe_mesh_pegel",
                 "load_nina_mesh_status"):
        info[soft] = "ok" if soft in funcs else "fehlt (weich)"

    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__-Block %d mal" % len(ms))
    pos = ms[0].start()
    src = src[:pos].rstrip("\n") + "\n\n" + BLOCK.strip("\n") + "\n\n" + src[pos:]
    info["block"] = "neu"

    if re.search(r"^load_nina_mesh_status\(\)\s*(#.*)?$", src, re.M):
        info["load_nina_call"] = "schon"
    else:
        m = LOAD_WX_RE.search(src)
        dpos = src.find("def load_nina_mesh_status")
        if m and "load_nina_mesh_status" in funcs and 0 <= dpos < m.start():
            src = src[: m.end()] + "\nload_nina_mesh_status()  # meshBootQuiet\n" + src[m.end() :]
            info["load_nina_call"] = "neu"
        elif "load_nina_mesh_status" in funcs:
            info["load_nina_call"] = "lazy-im-Block"
        else:
            info["load_nina_call"] = "Funktion fehlt (weich)"

    if GUARD_RE.search(src):
        src, n = GUARD_RE.subn("MESH_BOOT_GUARD_SEC = 300  # meshBootQuiet", src, count=1)
        info["guard_sec"] = "300" if n else "?"
    else:
        info["guard_sec"] = "kein MESH_BOOT_GUARD_SEC (weich)"

    after = guard_counts(src)
    if before != after:
        raise SystemExit("STOP dashboard guards %s -> %s" % (before, after))
    if sum(1 for ln in src.splitlines() if ln.strip() == PROTECT_LINE) != before["boot_line"]:
        raise SystemExit("STOP: Boot-Zeile Anzahl geaendert")
    ast.parse(src)
    compile(src, "dashboard.py", "exec")
    return src, info


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
    dash = root / "dashboard.py" if root.is_dir() else root
    if not dash.is_file():
        raise SystemExit("STOP: fehlt %s" % dash)
    src = dash.read_text(encoding="utf-8")
    new, info = patch_dashboard(src)
    if new != src:
        dash.write_text(new, encoding="utf-8")
        info["changed"] = dash.name
    else:
        info["changed"] = "-"
    for k, v in info.items():
        print("RESULT %s=%s" % (k, v))


if __name__ == "__main__":
    main()
PATCHPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1
fi
if [[ "$PORT" == "8080" ]]; then
  echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1
fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
echo "=== meshBootQuiet apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="

# ---------- 0) Bytes + AST-Guard der Patchdatei ----------
echo "$EXPECT_PATCH  $W/patch-mesh-boot-quiet.py" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
grep -q 'meshBootQuiet' "$W/patch-mesh-boot-quiet.py" || { echo "STOP: Patch ohne Marker"; exit 1; }
if grep -q 'PLACEHOLDER' "$W/patch-mesh-boot-quiet.py"; then echo "STOP: PLACEHOLDER im Patch"; exit 1; fi
python3 -m py_compile "$W/patch-mesh-boot-quiet.py"
set +e
python3 - "$W/patch-mesh-boot-quiet.py" << 'GUARDPY'
import ast, pathlib, sys
hit = False
path = sys.argv[1]
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
# eingebetteter Block (String) ebenfalls pruefen
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "BLOCK" for t in node.targets):
        blk = ast.parse(node.value.value)
        for n in ast.walk(blk):
            tg = []
            if isinstance(n, ast.Assign):
                tg = n.targets
            for t in tg:
                if isinstance(t, ast.Name) and t.id == "data_store":
                    print("BLOCK data_store-Zuweisung"); hit = True
            if isinstance(n, ast.Call):
                f = n.func
                if isinstance(f, ast.Attribute) and f.attr == "clear" and isinstance(f.value, ast.Name) and f.value.id == "data_store":
                    print("BLOCK data_store.clear()"); hit = True
                if isinstance(f, ast.Name) and f.id == "update_all":
                    print("BLOCK update_all()"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard Patchdatei rc=$g"; exit 1; }
echo "OK Bytes + AST-Guard (Patch + Block ohne data_store/update_all)"

[[ -f "$DASH" ]] || { echo "STOP: fehlt $DASH"; exit 1; }
grep -q 'update_all()  # einmal beim Start' "$DASH" || { echo "STOP: Boot-Zeile in dashboard.py nicht gefunden - nichts geaendert"; exit 1; }

# ---------- 1) Trockenlauf auf Kopie ----------
rm -rf "$W/work" && mkdir -p "$W/work"
cp -a "$DASH" "$W/work/"
set +e
python3 "$W/patch-mesh-boot-quiet.py" "$W/work" > "$W/dry.txt" 2>&1
rc=$?
set -e
cat "$W/dry.txt"
if [[ "$rc" -ne 0 ]]; then
  echo "STOP: Pflicht-Anker (NINA/Wetter) nicht gefunden - NICHTS geaendert. Bitte Ausgabe schicken."
  grep -n 'def maybe_mesh_nina\|def maybe_mesh_weather\|last_nina_mesh =\|^if __name__' "$DASH" | head -10 || true
  exit 1
fi
cp -a "$W/work" "$W/work1"
python3 "$W/patch-mesh-boot-quiet.py" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
python3 -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert"
echo "--- uebersprungene/unsichere Sender ---"
grep -E 'fehlt|lazy|kein ' "$W/dry.txt" | sed 's/^RESULT /  /' || echo "  keine"

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

# ---------- 2) Installieren ----------
if cmp -s "$W/work/dashboard.py" "$DASH"; then
  need=0
  echo "OK meshBootQuiet schon drin - nichts geaendert, kein Neustart"
  rollback() { echo "STOP (nichts geaendert): $1"; }
else
  need=1
  sudo -v
  cp -a "$DASH" "$DASH.bak-mbq-$TS"
  rollback() {
    echo "ROLLBACK dashboard.py: $1"
    cp -a "$DASH.bak-mbq-$TS" "$DASH"
    rm -f "$STATUS"
    sudo systemctl restart prepper-dashboard.service || true
    echo "Bridge + andere Dienste unberuehrt."
  }
  cp "$W/work/dashboard.py" "$DASH"
  python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
  g_now=$(guard_snap "$DASH")
  [[ "$g_now" == "$g_before" ]] || { rollback "Guards dashboard.py geaendert"; exit 1; }
  grep -q 'update_all()  # einmal beim Start' "$DASH" || { rollback "Boot-Zeile weg"; exit 1; }
  rm -f "$STATUS"
  sudo systemctl restart prepper-dashboard.service
  echo "OK dashboard.py installiert, Dashboard neu gestartet (Bridge NICHT)"
fi

# ---------- 3) Smoke Dashboard-Port ----------
echo "--- HTTP Dashboard :$PORT (nicht :8080 = Kiwix) ---"
root=""
for i in $(seq 1 80); do
  root=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "$B/" || true)
  [[ -z "$root" ]] && root=000
  [[ "$root" == "200" || "$root" == "500" ]] && break
  (( i % 10 == 1 )) && echo "warte auf Dashboard ... HTTP /=$root"
  sleep 3
done
[[ "$root" == "200" ]] || { rollback "HTTP / = $root"; exit 1; }
echo "OK HTTP / = 200"
funk=$("${CURL[@]}" -L --max-redirs 5 -o "$W/funk.html" -w "%{http_code}" "$B/funk" || true)
[[ "$funk" == "200" ]] || { rollback "HTTP /funk = $funk"; exit 1; }
echo "OK HTTP /funk = 200"
if [[ "$need" -eq 1 ]]; then
  ok_s=0
  for i in $(seq 1 20); do
    if python3 - "$STATUS" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if d.get("marker") == "meshBootQuiet" and d.get("res", {}).get("nina") in ("neu", "schon") else 1)
PY
    then ok_s=1; break; fi
    sleep 3
  done
  [[ "$ok_s" -eq 1 ]] || { rollback "Status mesh_boot_quiet.json fehlt (Block laeuft nicht)"; exit 1; }
  echo "OK meshBootQuiet laeuft:"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("  Sender:", d.get("res")); print("  NINA zuletzt gesendet:", repr(d.get("nina_last"))[:100], "Datei:", d.get("nina_file"))' "$STATUS" || true
  sudo journalctl -u prepper-dashboard --since "-3min" --no-pager -o cat 2>/dev/null | grep -E 'meshBootQuiet|NINA-Mesh|Mesh-Wetter|Luft-Mesh|ODL-Mesh|Space-Mesh|Mesh-Pegel' | tail -12 || true
fi

had() { grep -q "$1" "$DASH" && echo 1 || echo 0; }
echo "OK guards boot=$(grep -q 'update_all()  # einmal beim Start' "$DASH" && echo 1 || echo 0) staleTsBoot=$(had staleTsBoot) strom14dChart=$(had strom14dChart) navUnify=$(had navUnify) gasLngSign=$(had gasLngSign) lngColorFlip=$(had lngColorFlip) adsbMilThird=$(had adsbMilThird) keepLast=$(had keepLast) meshBootQuiet=$(had meshBootQuiet)"
[[ "$need" -eq 1 ]] && echo "Backup: $DASH.bak-mbq-$TS"
echo "OK meshBootQuiet=1 fertig: 5 Min Ruhe nach Neustart, NINA-Stand wird geladen"
echo "COMMIT $COMMIT_ARG meshBootQuiet=1"
