#!/bin/bash
set -eEuo pipefail
# clockOff (commit35): Kachel 'Zeit-Offset' (Lage-Seite) zeigt den chrony-Wert (chronyc -c tracking: System time, Stratum, Referenz; positiv = Systemuhr geht nach) statt einer einzelnen ntplib-Abfrage (Messartefakt, z. B. -1,39 ms bei real ~2 us); unter 0,1 ms in Mikrosekunden, Cache 60 s beim Rendern und per Abruf /api/clock-off (Kachel aktualisiert sich alle 60 s); Rueckfall bei chronyc fehlt/Fehler/Timeout auf den ntplib-Wert mit Hinweis '(ntplib)', nie leer/NaN. Nur dashboard.py (2 Stellen + Block). Neustart-Sperre: nie HH:55-HH:04 um die Wetter-Slots und HH:55-HH:59 der Slot-Stunden.
# Aufruf: bash /tmp/apply-clockoff.sh commit35 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 03ee294d6e4ed56f (Stand nach wxSlot commit34) oder clockOff schon drin (1831e7cd923396d1); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-clockoff-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/clockoff-apply
KEEP_LAST=3
KNOWN_D16="03ee294d6e4ed56f"      # dashboard.py vor clockOff (Basis: Stand nach wxSlot commit34)
KNOWN_D16N="1831e7cd923396d1"             # dashboard.py nach clockOff (Ziel)
PHASE=vorher
ERRLN=""; ERRCMD=""
trap 'ERRLN=$LINENO; ERRCMD=$BASH_COMMAND' ERR
trap 'ec=$?; if [[ $ec -ne 0 && -n "$ERRLN" ]]; then echo "ABBRUCH: unerwarteter Fehler (Exit $ec) in Zeile $ERRLN, Befehl: $(echo "$ERRCMD" | cut -c1-160) - Phase: $PHASE$([[ "$PHASE" == vorher ]] && echo " - es wurde nichts geaendert")"; fi' EXIT
stop() { echo "STOP: $1 - nichts geaendert"; exit 1; }
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then stop "Dashboard-Port unklar ($PORT)"; fi
if [[ "$PORT" == "8080" ]]; then stop "Port 8080 ist kiwix-serve, nicht das Dashboard"; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== clockOff apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): Zeit-Offset-Kachel aus chrony, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="61e87184cd9a018bb4a9fbe2b84aec1c99beda20443bd2592fa24ea3423e5aab"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher clockOff. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
Exit 0 ok, 2 unbekannte Basis/teilweise gepatcht. Schreibt nur ZIEL (nie QUELLE)."""
import sys
label, kind, src, dst, blk, edp = sys.argv[1:7]
g = {}
exec(compile(open(edp, encoding="utf-8").read(), edp, "exec"), g)
E = g["%s_EDITS" % kind.upper()]
ANCH = g.get("%s_ANCHOR" % kind.upper())
s = open(src, encoding="utf-8").read()
B = None
if blk != "-":
    B = open(blk, encoding="utf-8").read().rstrip("\n") + "\n"
name = {"dsh": "dashboard.py", "fh": "funk_health.py", "hw": "mesh_hang_watchdog.py", "pd": "prepper_docs.py"}[kind]
new_in = [s.count(n) >= 1 for o, n in E]
blk_in = (B is None) or (s.count(B) == 1)
if all(new_in) and blk_in:
    rest = s.replace(B, "", 1) if B else s
    ok = all(rest.count(n) == 1 for o, n in E) and (B is None or s.count(B.splitlines()[0]) == 1)
    if not ok:
        print("%s: %s teilweise/anders vorhanden" % (name, label)); raise SystemExit(2)
    open(dst, "w", encoding="utf-8").write(s)
    print("%s: %s schon drin" % (name, label)); raise SystemExit(0)
if any(new_in) or (B is not None and B.splitlines()[0] in s):
    print("%s: %s teilweise vorhanden (%d von %d Stellen%s)" % (name, label, sum(new_in), len(E), ", Block da" if B and B.splitlines()[0] in s else "")); raise SystemExit(2)
for o, n in E:
    if s.count(o) != 1:
        print("%s: Stelle nicht eindeutig (%d): %s" % (name, s.count(o), o.strip().splitlines()[0][:70])); raise SystemExit(2)
    s = s.replace(o, n, 1)
if B is not None:
    if s.count(ANCH) != 1:
        print("%s: Ankerstelle fehlt" % name); raise SystemExit(2)
    i = s.index(ANCH)
    s = s[:i] + "\n\n" + B.rstrip("\n") + s[i:]
open(dst, "w", encoding="utf-8").write(s)
print("%s: %d Stellen%s %s" % (name, len(E), (" + Block" if B else ""), label))
MK_PAL_EOF
EXPECT_RAE="95a02b6e5bcdf59044ea5af353d502cc4a06a615478c180ba9a5afb6997424d6"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer clockOff (commit35): Basis 03ee294d6e4ed56f (Stand nach wxSlot commit34)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    ('  <div class="small">Stratum Offset: {% if stratum.value.offset_ms is not none %}{{ stratum.value.offset_ms }} ms{% else %}–{% endif %}</div>\n',
     '''  {% set co = clock_off if clock_off else {'text': '–', 'sub': '', 'src': 'none', 'us': none, 'title': ''} %}
  <div class="small" id="clock-off" data-src="{{ co.src }}" data-us="{{ co.us if co.us is not none else '' }}" title="{{ co.title }}">Zeit-Offset: {{ co.text }}</div>
  <div class="small" id="clock-off2">{{ co.sub }}</div>
  <script>(function(){var e=document.getElementById('clock-off'),s=document.getElementById('clock-off2');if(!e)return;
  function up(){fetch('/api/clock-off',{cache:'no-store'}).then(function(r){return r.json();}).then(function(d){if(!d||!d.text)return;e.textContent='Zeit-Offset: '+d.text;e.title=d.title||'';e.setAttribute('data-src',d.src||'');e.setAttribute('data-us',(d.us===null||d.us===undefined)?'':d.us);if(s)s.textContent=d.sub||'';}).catch(function(){});}
  setInterval(up,60000);})();</script>
'''),
    ('''        PAGE1,
        minutes_left=_ml,
        **_ds
''',
     '''        PAGE1,
        minutes_left=_ml,
        clock_off=globals().get("_clk_view", lambda s: None)(_ds.get("stratum")),  # clockOff: chrony-Wert, Cache 60 s
        **_ds
'''),
]
MK_RAE_EOF
EXPECT_RAB="8f8de6af6500a5d72a6cfae435d80d788192e460b11fe7554896ac7462a5479b"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== clockOff: Kachel "Zeit-Offset" (Lage-Seite) zeigt den chrony-Wert statt einer einzelnen ntplib-Abfrage =====
# Warum: Die alte Zeile "Stratum Offset: -1.39 ms" kam aus EINER ntplib-Abfrage (Python-Messartefakt: Netzlaufzeit/Scheduling), waehrend chrony
#        (chronyc -c tracking) Mikrosekunden meldet. Jetzt: System time aus chronyc, Stratum und Referenz dazu, Cache 60 s (beim Rendern/Abruf).
# Vorzeichen (wie chronyc "System time"): POSITIV = Systemuhr geht NACH (slow of NTP time), NEGATIV = Systemuhr geht VOR (fast). chronyc -c tracking
#        liefert den Rohwert in Sekunden mit genau dieser Konvention; ntplib (offset = Server - lokal) hat dieselbe: positiv = lokal geht nach.
# Felder von chronyc -c tracking: 0 Ref-ID (hex), 1 Ref-Name/IP, 2 Stratum, 3 Ref-Zeit, 4 System time (s), 5 Last offset, ..., 13 Leap status.
# Fehler/Timeout/fehlt: Rueckfall auf den bisherigen ntplib-Wert mit Hinweis "(ntplib)"; nie leer, nie NaN. chronyc: nur Argumentliste, ohne Shell, 3 s Zeitlimit.
import math as _cl_math
import os as _cl_os
import signal as _cl_sig
import subprocess as _cl_sp
import threading as _cl_th
import time as _cl_time

CL_CMD = ["chronyc", "-c", "tracking"]
CL_TIMEOUT = 3.0        # Sekunden fuer chronyc
CL_TTL_OK = 60.0        # Cache bei Erfolg (hoechstens 60 s alt)
CL_TTL_ERR = 15.0       # Cache bei Fehler (rasch erneut versuchen, aber nie bei jedem Aufruf)
_CL = {"lock": _cl_th.Lock(), "t": None, "v": None, "n": 0, "err": None}


def _cl_read():
    """chronyc -c tracking -> erste Zeile; wirft FileNotFoundError (fehlt), TimeoutError, RuntimeError (Fehlercode/leer)."""
    pr = _cl_sp.Popen(CL_CMD, stdout=_cl_sp.PIPE, stderr=_cl_sp.DEVNULL, stdin=_cl_sp.DEVNULL, start_new_session=True)
    try:
        out, _ = pr.communicate(timeout=CL_TIMEOUT)
    except _cl_sp.TimeoutExpired:
        try:
            _cl_os.killpg(pr.pid, _cl_sig.SIGKILL)  # ganze Prozessgruppe: auch Kindprozesse, die das Rohr offen halten
        except Exception:
            pr.kill()
        try:
            pr.communicate(timeout=2)
        except Exception:
            pass
        raise TimeoutError("chronyc ohne Antwort in %.1f s" % CL_TIMEOUT)
    txt = (out or b"").decode("utf-8", "replace").strip()
    if pr.returncode != 0 or not txt:
        raise RuntimeError("chronyc Rueckgabe %s" % pr.returncode)
    return txt.splitlines()[0]


def _cl_parse(line):
    """CSV-Zeile -> {'s': Sekunden (positiv = Uhr geht nach), 'stratum': int, 'ref': Text, 'sync': bool, 'leap': Text} oder None."""
    f = (line or "").split(",")
    if len(f) < 14:
        return None
    try:
        st = int(f[2])
        off = float(f[4])
    except ValueError:
        return None
    if not _cl_math.isfinite(off) or abs(off) > 86400 or not (0 <= st <= 16):
        return None
    leap = f[13].strip()
    ref = (f[1].strip() or f[0].strip())[:40]
    sync = 1 <= st <= 15 and leap.lower() in ("normal", "insert second", "delete second") and f[0].strip().strip("0") != ""
    return {"s": off, "stratum": st, "ref": ref, "sync": bool(sync), "leap": leap[:30]}


def _cl_fmt(s):
    """Sekunden (positiv = Uhr geht nach) -> (Text, Richtung). < 0,1 ms in Mikrosekunden, sonst Millisekunden (3 Stellen), ab 1 s in Sekunden."""
    a = abs(s)
    if a < 1e-4:
        v, u, d = s * 1e6, "\u00b5s", 1
    elif a < 1.0:
        v, u, d = s * 1e3, "ms", 3
    else:
        v, u, d = s, "s", 3
    r = round(v, d)
    t = ("%.*f" % (d, abs(r))).replace(".", ",")
    if r == 0:
        return "%s %s" % (t, u), ""
    return "%s%s %s" % ("+" if r > 0 else "-", t, u), ("Systemuhr geht nach" if r > 0 else "Systemuhr geht vor")


def _cl_get(now_ts=None, reader=None):
    """Cache 60 s (Fehler 15 s). -> {'ok': True, ...parse} oder {'ok': False, 'why': Text}. Wirft nie."""
    ts = _cl_time.time() if now_ts is None else now_ts
    if not _CL["lock"].acquire(timeout=6):
        return _CL["v"] or {"ok": False, "why": "chronyc-Abfrage laeuft noch"}
    try:
        v, t = _CL["v"], _CL["t"]
        if v is not None and t is not None and 0 <= ts - t < (CL_TTL_OK if v.get("ok") else CL_TTL_ERR):
            return v
        try:
            q = _cl_parse((reader or _cl_read)())
            v = dict(q, ok=True, t=ts) if q else {"ok": False, "why": "chronyc-Ausgabe unlesbar", "t": ts}
        except FileNotFoundError:
            v = {"ok": False, "why": "chronyc nicht installiert", "t": ts}
        except Exception as e:
            v = {"ok": False, "why": ("%s: %s" % (type(e).__name__, e))[:80], "t": ts}
        _CL["v"], _CL["t"] = v, ts
        _CL["n"] += 1
        if not v["ok"]:
            if _CL["err"] != v["why"] and not _CL.get("mute"):
                print("clockOff: chronyc nicht nutzbar (%s) - Kachel zeigt den ntplib-Wert" % v["why"], flush=True)
        elif _CL["err"] and not _CL.get("mute"):
            print("clockOff: chronyc wieder nutzbar", flush=True)
        _CL["err"] = None if v["ok"] else v["why"]
        return v
    finally:
        _CL["lock"].release()


def _clk_view(stratum=None, now_ts=None, reader=None):
    """Anzeige fuer die Kachel: {'text','sub','title','src','us'}; stratum = data_store['stratum'] (Rueckfall ntplib). Wirft nie, nie leer."""
    try:
        q = _cl_get(now_ts, reader)
        if q.get("ok"):
            t, d = _cl_fmt(q["s"])
            sub = "Stratum %d \u00b7 Referenz %s" % (q["stratum"], q["ref"] or "?")
            if not q["sync"]:
                sub += " \u00b7 nicht synchronisiert (%s)" % (q["leap"] or "?")
            ts = _cl_time.time() if now_ts is None else now_ts
            return {"text": t + (" \u00b7 " + d if d else ""), "sub": sub, "src": "chrony", "us": round(q["s"] * 1e6, 3),
                    "title": "chronyc tracking: System time %+.9f s (positiv = Systemuhr geht nach, negativ = geht vor), gelesen vor %d s" % (q["s"], max(0, int(ts - q["t"])))}
        why = q.get("why") or "?"
    except Exception as e:
        why = "Fehler %s" % type(e).__name__
    off = None
    try:
        v = ((stratum or {}).get("value") or {}).get("offset_ms")
        if isinstance(v, (int, float)) and not isinstance(v, bool) and _cl_math.isfinite(v):
            off = float(v)
    except Exception:
        off = None
    if off is None:
        return {"text": "nicht verf\u00fcgbar", "sub": "chronyc: %s \u00b7 keine NTP-Abfrage" % why, "src": "none", "us": None, "title": "Zeit-Offset nicht verf\u00fcgbar (chronyc: %s)" % why}
    t, d = _cl_fmt(off / 1000.0)
    return {"text": t + " (ntplib)", "sub": "chronyc: %s \u00b7 Wert aus einer einzelnen NTP-Abfrage (ungenau)" % why, "src": "ntplib", "us": round(off * 1000.0, 3),
            "title": "Rueckfall: einzelne ntplib-Abfrage (positiv = Systemuhr geht nach); chronyc: %s" % why}


def _clk_api():
    from flask import jsonify as _cl_j
    try:
        r = _clk_view(globals().get("data_store", {}).get("stratum"))
    except Exception:
        r = {"text": "nicht verf\u00fcgbar", "sub": "", "src": "none", "us": None, "title": ""}
    resp = _cl_j(r)
    resp.headers["Cache-Control"] = "no-store"
    return resp


def _selftest_clockoff():
    L = lambda **k: ",".join(str(k.get(x, d)) for x, d in (("a", "C0A8B20F"), ("b", "192.168.178.15"), ("st", 2), ("rt", "1792931706.5"), ("off", "0.000002100"), ("lo", "-0.0000016"), ("rms", "0.000003"),
                                                           ("fr", "1.2"), ("rf", "0.0"), ("sk", "0.05"), ("rd", "0.0004"), ("rdi", "0.0008"), ("ui", "64.0"), ("lp", "Normal")))
    # Parser und Vorzeichen: positiv = Uhr geht nach
    p = _cl_parse(L())
    assert p and p["stratum"] == 2 and p["ref"] == "192.168.178.15" and p["sync"] and abs(p["s"] - 2.1e-6) < 1e-12, p
    assert _cl_fmt(2.1e-6) == ("+2,1 \u00b5s", "Systemuhr geht nach"), _cl_fmt(2.1e-6)
    assert _cl_fmt(-3.04e-6) == ("-3,0 \u00b5s", "Systemuhr geht vor"), _cl_fmt(-3.04e-6)
    assert _cl_fmt(0.0)[0] == "0,0 \u00b5s" and _cl_fmt(-1e-9) == ("0,0 \u00b5s", ""), (_cl_fmt(0.0), _cl_fmt(-1e-9))
    assert _cl_fmt(0.00123456) == ("+1,235 ms", "Systemuhr geht nach") and _cl_fmt(-0.0001)[0] == "-0,100 ms" and _cl_fmt(1.5)[0] == "+1,500 s", (_cl_fmt(0.00123456), _cl_fmt(-0.0001), _cl_fmt(1.5))
    for bad in ("", "x", "a,b,c", L(off="nan"), L(off="inf"), L(off="abc"), L(st="x"), L(off="1e9"), L(st=99)):
        assert _cl_parse(bad) is None, bad
    assert _cl_parse(L(lp="Not synchronised"))["sync"] is False and _cl_parse(L(a="00000000"))["sync"] is False and _cl_parse(L(st=0))["sync"] is False
    # Ansicht und Cache (Attrappen-Leser, eigener Cache)
    saved = dict(_CL)
    try:
        _CL.update(t=None, v=None, n=0, err=None, mute=True)
        calls = []

        def rd_ok():
            calls.append(1)
            return L()
        v = _clk_view(None, 1000.0, rd_ok)
        assert v["src"] == "chrony" and v["text"] == "+2,1 \u00b5s \u00b7 Systemuhr geht nach" and v["sub"] == "Stratum 2 \u00b7 Referenz 192.168.178.15" and v["us"] == 2.1, v
        _clk_view(None, 1059.0, rd_ok)
        assert len(calls) == 1, "Cache 60 s"
        _clk_view(None, 1060.5, rd_ok)
        assert len(calls) == 2, "nach 60 s neu lesen"
        for exc, what in ((FileNotFoundError("x"), "nicht installiert"), (TimeoutError("t"), "TimeoutError"), (RuntimeError("r"), "RuntimeError")):
            _CL.update(t=None, v=None)

            def rd_bad(e=exc):
                raise e
            fb = _clk_view({"value": {"offset_ms": -1.39}}, 2000.0, rd_bad)
            assert fb["src"] == "ntplib" and fb["text"] == "-1,390 ms (ntplib)" and what in fb["sub"], fb
            assert _clk_view({"value": {"offset_ms": None}}, 2001.0, rd_bad)["text"] == "nicht verf\u00fcgbar"
            assert _clk_view({"value": {"offset_ms": float("nan")}}, 2001.0, rd_bad)["src"] == "none"
            assert _clk_view(None, 2001.0, rd_bad)["src"] == "none"
        _CL.update(t=None, v=None)
        assert _clk_view(None, 3000.0, lambda: "kaputt")["src"] == "none"
    finally:
        _CL.clear()
        _CL.update(saved)
    return "clockOff ok (chrony-Wert mit Vorzeichen slow=+, Stratum/Referenz, Cache 60 s, Rueckfall ntplib bei fehlt/Fehler/Timeout/unlesbar, nie leer/NaN)"


try:
    _CL_ST = _selftest_clockoff()
except Exception as _cl_e:
    _CL_ST = None
    print("clockOff Selbsttest FEHLER (%s)" % _cl_e, flush=True)
if _CL_ST:
    try:
        app.add_url_rule("/api/clock-off", endpoint="clock_off_api", view_func=_clk_api, methods=["GET"])
        print("clockOff aktiv: %s" % _CL_ST, flush=True)
    except Exception as _cl_e2:
        print("clockOff Selbsttest FEHLER (Einbau: %s)" % _cl_e2, flush=True)
# ===== /clockOff =====
MK_RAB_EOF
EXPECT_RAG="32224d3484c37e6309aebd8899516bf585ef504bbe2db95d7657a2743bf8f027"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-/Verhaltens-Guard clockOff (nur dashboard.py: 2 Stellen + Block clockOff). Aufruf:
  guard_cl.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne clockOff (Rueckbau, byte-genau)
  guard_cl.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhaltenstests (Parser/Vorzeichen/Format, Cache, Rueckfall, Kachel-Template, ECHTER
                                                           chronyc-Aufruf gegen Attrappen: positiv, negativ, Fehler, fehlt, Timeout, Muell)
  RH_ALT=ALT_VERZ guard_cl.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest   (ohne node, ohne Netz, ohne Dienste)"""
import ast
import contextlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import time

FORBID = ("requests", "urlopen", "socket", "os.system", "send_meshtastic", "eval(", "exec(", "__import__", "curl", "sudo", "systemctl", "shell=True")
BLOCK_NODES = ["Import:"] * 6 + ["Assign:"] * 5 + ["FunctionDef:" + x for x in ("_cl_read", "_cl_parse", "_cl_fmt", "_cl_get", "_clk_view", "_clk_api", "_selftest_clockoff")] + ["Try:", "If:"]
CHANGED = ["PAGE1", "page1"]


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block clockOff nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle clockOff nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def fn_node(tree, name):
    for n in tree.body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def check_block_text(B):
    t = ast.parse(B)
    kinds = [type(n).__name__ + ":" + getattr(n, "name", "") for n in t.body]
    assert kinds == BLOCK_NODES, "Blockaufbau weicht ab: %s" % [k for k in kinds if k not in BLOCK_NODES]
    for w in FORBID:
        assert w not in B, "Block enthaelt verbotenes Wort: " + w
    pops = []
    for n in t.body:
        for x in ast.walk(n):
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Name) and x.func.id in ("eval", "exec", "__import__", "compile", "open"):
                raise AssertionError("Block ruft " + x.func.id)
            if isinstance(x, ast.Call) and isinstance(x.func, ast.Attribute) and x.func.attr in ("system", "popen", "run", "call", "check_output", "check_call", "kill_all", "remove", "unlink"):
                raise AssertionError("Block ruft " + x.func.attr)
            if isinstance(x, ast.Call) and ast.unparse(x.func) == "_cl_sp.Popen":
                pops.append((getattr(n, "name", ""), ast.unparse(x)))
            if isinstance(x, ast.keyword) and x.arg == "shell":
                raise AssertionError("Block nutzt shell=")
    assert pops == [("_cl_read", "_cl_sp.Popen(CL_CMD, stdout=_cl_sp.PIPE, stderr=_cl_sp.DEVNULL, stdin=_cl_sp.DEVNULL, start_new_session=True)")], "Popen nur in _cl_read mit Argumentliste: %s" % pops
    assert B.splitlines()[0].startswith("# ===== clockOff:") and B.rstrip().splitlines()[-1] == "# ===== /clockOff =====", "Block ohne Marker"
    consts = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name):
            try:
                consts[n.targets[0].id] = ast.literal_eval(n.value)
            except Exception:
                pass
    assert consts.get("CL_CMD") == ["chronyc", "-c", "tracking"], "chronyc-Aufruf weicht ab: %s" % consts.get("CL_CMD")
    assert consts.get("CL_TIMEOUT") == 3.0 and consts.get("CL_TTL_OK") == 60.0 and 5 <= consts.get("CL_TTL_ERR", 0) <= 60, "Zeitlimit/Cache weichen von der Vorgabe ab: %s" % consts


def static(alt, new, blk, edits):
    n = 0
    B = rd(blk).rstrip("\n")
    check_block_text(B)
    assert new.count("\n\n" + B + "\n\nif __name__ == \"__main__\":\n") == 1, "Block nicht direkt vor dem __main__-Block"
    n += 2
    assert len(edits) == 2, "erwartet genau 2 Stellen"
    for o, nw in edits:
        assert alt.count(o) == 1, "Stelle nicht genau einmal im alten Stand"
    n += 1
    bs = new.count("\n", 0, new.index(B)) + 1
    be = bs + B.count("\n")
    ta, tn = ast.parse(alt), ast.parse(new)
    N = [x for x in tn.body if not (bs <= x.lineno <= be)]
    assert len(tn.body) - len(N) == len(BLOCK_NODES), "Block hat nicht %d Knoten" % len(BLOCK_NODES)
    da = {ast.dump(x) for x in ta.body}
    ch = sorted((getattr(x, "name", None) or (x.targets[0].id if isinstance(x, ast.Assign) else "?")) for x in N if ast.dump(x) not in da)
    assert ch == sorted(CHANGED), "geaenderte/neue Knoten ausserhalb des Blocks: %s" % ch
    n += 2
    p1 = ast.unparse(fn_node(tn, "page1"))
    assert p1.count("clock_off=") == 1 and "_clk_view" in p1 and "_ds.get('stratum')" in p1, "page1: Kachel-Wert fehlt"
    n += 1
    tm = [x for x in N if isinstance(x, ast.Assign) and getattr(x.targets[0], "id", "") == "PAGE1"][0]
    pg = ast.unparse(tm)
    for need in ('id="clock-off"', "Zeit-Offset", "/api/clock-off", "clock_off", "data-src"):
        assert need in new[new.index("PAGE1 ="):new.index("PAGE1 =") + 60000] and need in edits[0][1], "Kachel ohne " + need
    assert "Stratum Offset" not in edits[0][1], "alte Beschriftung noch im neuen Text"
    assert edits[0][1].count("setInterval(up,60000)") == 1 and "/api/clock-off" in edits[0][1], "Kachel aktualisiert sich nicht alle 60 s"
    n += 2
    return n


# ---------- Verhaltenstests ----------
def csv(**k):
    d = (("a", "C0A8B20F"), ("b", "192.168.178.15"), ("st", 2), ("rt", "1792931706.5"), ("off", "0.000002100"), ("lo", "-0.0000016"), ("rms", "0.000003"), ("fr", "1.2"), ("rf", "0.0"),
         ("sk", "0.05"), ("rd", "0.0004"), ("rdi", "0.0008"), ("ui", "64.0"), ("lp", "Normal"))
    return ",".join(str(k.get(x, v)) for x, v in d)


class FakeApp:
    def __init__(self):
        self.rules = []

    def add_url_rule(self, rule, endpoint=None, view_func=None, methods=None, **kw):
        self.rules.append((rule, endpoint, view_func, tuple(methods or ())))


def mk_ns():
    return {"__name__": "dash_test", "app": FakeApp(), "data_store": {"stratum": {"value": {"offset_ms": -1.39}}}}


def run_block(B, g):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(B, "blk", "exec"), g)
    return buf.getvalue()


def fake_chronyc(d, body, exit_code=0, sleep=0):
    p = os.path.join(d, "chronyc")
    with open(p, "w") as f:
        f.write("#!/bin/sh\n[ \"$1 $2\" = '-c tracking' ] || exit 9\n" + ("echo $$ > '%s.pid'\nsleep %s\n" % (p, sleep) if sleep else "") + ("printf '%s\\n' '" + body + "'\n" if body is not None else "") + "exit %d\n" % exit_code)
    os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)


def behav(alt, new, blk, edits):
    B = rd(blk)
    n = 0
    g = mk_ns()
    o = run_block(B, g)
    assert "clockOff aktiv: clockOff ok" in o and "FEHLER" not in o, "Block-Selbsttest: " + o[:200]
    assert [(r[0], r[1], r[3]) for r in g["app"].rules] == [("/api/clock-off", "clock_off_api", ("GET",))], "Route /api/clock-off (nur GET) nicht genau einmal eingebaut"
    n += 2
    tmp = tempfile.mkdtemp(prefix="cl-guard-")
    oldpath = os.environ.get("PATH", "")
    try:
        os.environ["PATH"] = tmp + os.pathsep + "/usr/bin:/bin"
        def view(body, exit_code=0, sleep=0, st=None, timeout=None, fresh=True):
            fake_chronyc(tmp, body, exit_code, sleep)
            if fresh:
                g["_CL"].update(t=None, v=None, err=None, mute=True)
            if timeout:
                g["CL_TIMEOUT"] = timeout
            t0 = time.time()
            r = g["_clk_view"](st if st is not None else g["data_store"]["stratum"])
            g["CL_TIMEOUT"] = 3.0
            return r, time.time() - t0
        r, _ = view(csv())
        assert r["src"] == "chrony" and r["text"] == "+2,1 \u00b5s \u00b7 Systemuhr geht nach" and r["sub"] == "Stratum 2 \u00b7 Referenz 192.168.178.15" and r["us"] == 2.1, "positiv: %s" % r
        r, _ = view(csv(off="-0.000003000"))
        assert r["src"] == "chrony" and r["text"].startswith("-3,0 \u00b5s") and "geht vor" in r["text"] and r["us"] == -3.0, "negativ: %s" % r
        r, _ = view(csv(off="0.000123456"))
        assert r["text"].startswith("+0,123 ms") and "geht nach" in r["text"], "ms-Bereich: %s" % r
        r, _ = view(csv(lp="Not synchronised", a="00000000", st=0, b=""))
        assert r["src"] == "chrony" and "nicht synchronisiert" in r["sub"], "unsynchron: %s" % r
        n += 4
        for body, ec, what in ((csv(), 1, "Rueckgabe 1"), (None, 0, "Rueckgabe 0"), ("muell", 0, "unlesbar"), (csv(off="nan"), 0, "unlesbar"), ("", 0, "Rueckgabe 0")):
            r, _ = view(body, ec)
            assert r["src"] == "ntplib" and r["text"] == "-1,390 ms (ntplib)" and what in r["sub"] and r["us"] == -1390.0, "Fehlerfall %r/%s: %s" % (body, ec, r)
        r, dt = view(csv(), sleep=6, timeout=0.5)
        assert r["src"] == "ntplib" and "TimeoutError" in r["sub"] and dt < 3.0, "Timeout: %s nach %.1f s" % (r, dt)
        pid = int(rd(os.path.join(tmp, "chronyc.pid")).strip())
        for _ in range(20):
            try:
                os.kill(pid, 0)
                time.sleep(0.1)
            except ProcessLookupError:
                pid = 0
                break
        assert pid == 0, "chronyc-Prozess lebt nach dem Zeitlimit noch (pid %s)" % pid
        saved = g["CL_CMD"]
        g["CL_CMD"] = ["chronyc-gibt-es-nicht", "-c", "tracking"]
        g["_CL"].update(t=None, v=None, err=None, mute=True)
        r = g["_clk_view"](g["data_store"]["stratum"])
        g["CL_CMD"] = saved
        assert r["src"] == "ntplib" and "nicht installiert" in r["sub"] and r["text"].endswith("(ntplib)"), "chronyc fehlt: %s" % r
        r, _ = view(None, 1, st={"value": {"offset_ms": None}})
        assert r["src"] == "none" and r["text"] and "NaN" not in json.dumps(r) and r["us"] is None, "nichts verfuegbar: %s" % r
        r, _ = view(None, 1, st={"value": {"offset_ms": float("nan")}})
        assert r["src"] == "none" and "nan" not in r["text"].lower(), "NaN-Rueckfall: %s" % r
        n += 5 + 1 + 1 + 2 + 1
        # Cache: 60 s
        fake_chronyc(tmp, csv())
        g["_CL"].update(t=None, v=None, err=None, mute=True)
        t1 = g["_clk_view"](None, 5000.0)
        fake_chronyc(tmp, csv(off="0.000009000"))
        t2 = g["_clk_view"](None, 5059.0)
        t3 = g["_clk_view"](None, 5061.0)
        assert t1["us"] == 2.1 and t2["us"] == 2.1 and t3["us"] == 9.0, "Cache: %s %s %s" % (t1["us"], t2["us"], t3["us"])
        n += 1
        # JSON-Abruf
        try:
            import flask
        except Exception:
            flask = None
        assert flask is not None, "flask fehlt (Guard laeuft mit der venv)"
        fa = flask.Flask("x")
        with fa.test_request_context("/api/clock-off"):
            g["_CL"].update(t=None, v=None, err=None, mute=True)
            resp = g["_clk_api"]()
            j = json.loads(resp.get_data(as_text=True))
            assert j["src"] == "chrony" and j["text"] and resp.headers.get("Cache-Control") == "no-store", "API: %s" % j
        n += 1
        # Kachel (Jinja) fuer alle Faelle
        import jinja2
        snip = edits[0][1]
        env = jinja2.Environment(autoescape=True)
        tpl = env.from_string(snip)
        okv = {"text": "+2,1 \u00b5s \u00b7 Systemuhr geht nach", "sub": "Stratum 2 \u00b7 Referenz 192.168.178.15", "src": "chrony", "us": 2.1, "title": "t"}
        h = tpl.render(clock_off=okv)
        assert 'id="clock-off"' in h and "Zeit-Offset: +2,1 \u00b5s" in h and 'data-src="chrony"' in h and 'data-us="2.1"' in h and "Stratum 2" in h, "Kachel ok: " + h[:300]
        for cv in (None, {}, ):
            h = tpl.render(clock_off=cv)
            assert "Zeit-Offset: \u2013" in h, "Kachel ohne Wert: " + h[:200]
        h = tpl.render()
        assert "Zeit-Offset: \u2013" in h, "Kachel ohne clock_off (undefined)"
        h = tpl.render(clock_off=dict(okv, text="<b>x</b>", us=None))
        assert "<b>x</b>" not in h and 'data-us=""' in h, "Kachel maskiert nicht"
        n += 4
    finally:
        os.environ["PATH"] = oldpath
        shutil.rmtree(tmp, ignore_errors=True)
    # kaputter Selbsttest wird gemeldet, kein Einbau
    g2 = mk_ns()
    g2["app"] = None
    o = run_block(B, g2)
    assert "clockOff Selbsttest FEHLER" in o and "aktiv" not in o, "Einbaufehler wird nicht gemeldet: " + o[:200]
    n += 1
    g3 = mk_ns()
    import math
    realm = sys.modules["math"]
    broken = type(sys)("math")
    broken.isfinite = lambda x: True
    sys.modules["math"] = broken
    try:
        o = run_block(B, g3)
    finally:
        sys.modules["math"] = realm
    assert "clockOff Selbsttest FEHLER" in o and "aktiv" not in o, "Selbsttest erkennt fehlende NaN-Pruefung nicht: " + o[:200]
    n += 1
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = 0 if os.environ.get("RH_CL_NOSTATIC") == "1" else static(alt, new, blk, edits)
    if os.environ.get("RH_CL_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new, blk, edits)
    print("OK guard clockOff: %d Pruefungen, 0 fehlerhaft" % n)
    return n


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    B = rd(blk).rstrip("\n")
    edits, anch = load_edits(ep)
    pre, post = base_new[:base_new.index(B)], base_new[base_new.index(B):]

    def rep(s, a, b):
        assert s.count(a) == 1, "%s: %d" % (a[:60], s.count(a))
        return s.replace(a, b, 1)
    M = []
    M.append(("M1 Kachel-Edit zurueckgenommen", rep(pre, edits[0][1], edits[0][0]) + post, B, 1, None))
    M.append(("M2 page1-Edit zurueckgenommen", rep(pre, edits[1][1], edits[1][0]) + post, B, 1, None))
    M.append(("M3 stille Zusatzaenderung", rep(pre, "def _fnum(x):\n", "def _fnum(x): \n") + post, B, 0, None))
    # Aenderungen an den Stellen selbst (Template und page1), jeweils mit passenden Edits
    for nm, a, b in (("T1 Kachel ohne data-src", ' data-src="{{ co.src }}"', ""),
                     ("T2 Kachel ohne Zeit-Offset-Beschriftung", ">Zeit-Offset: {{ co.text }}<", ">Offset: {{ co.text }}<"),
                     ("T3 Kachel ohne Rueckfall fuer fehlendes clock_off", "{% set co = clock_off if clock_off else", "{% set co = clock_off if True else"),
                     ("T4 Kachel ohne Stratum-Zeile", '{{ co.sub }}</div>', '</div>'),
                     ("T5 Kachel ohne Abruf alle 60 s", "setInterval(up,60000)", "setInterval(up,6000)")):
        e2 = [tuple(x) for x in edits]
        e2[0] = (e2[0][0], rep(e2[0][1], a, b))
        M.append((nm, rep(pre, edits[0][1], e2[0][1]) + post, B, 1, e2))
    for nm, a, b in (("B1 Zeitlimit 30 s", "CL_TIMEOUT = 3.0 ", "CL_TIMEOUT = 30.0 "),
                     ("B2 Cache 600 s", "CL_TTL_OK = 60.0 ", "CL_TTL_OK = 600.0 "),
                     ("B3 Vorzeichen vertauscht", '"+" if r > 0 else "-"', '"-" if r > 0 else "+"'),
                     ("B4 Richtung vertauscht", '("Systemuhr geht nach" if r > 0 else "Systemuhr geht vor")', '("Systemuhr geht vor" if r > 0 else "Systemuhr geht nach")'),
                     ("B5 NaN-Pruefung fehlt", "if not _cl_math.isfinite(off) or abs(off) > 86400 or not (0 <= st <= 16):", "if abs(off) > 86400 or not (0 <= st <= 16):"),
                     ("B6 Schwelle 0,1 ms falsch", "    if a < 1e-4:\n", "    if a < 1e-2:\n"),
                     ("B7 Rueckfall ohne Hinweis ntplib", '"text": t + " (ntplib)"', '"text": t'),
                     ("B8 Fehler wird nicht gecacht", '        _CL["v"], _CL["t"] = v, ts\n', ""),
                     ("B9 shell=True", "start_new_session=True)\n    try:", "start_new_session=True, shell=True)\n    try:"),
                     ("B10 Prozess bei Timeout nicht beendet", "            _cl_os.killpg(pr.pid, _cl_sig.SIGKILL)", "            pass"),
                     ("B11 Rueckgabewert nicht geprueft", "    if pr.returncode != 0 or not txt:", "    if not txt:"),
                     ("B12 Einheit Mikrosekunden fehlt", 'v, u, d = s * 1e6, "\\u00b5s", 1', 'v, u, d = s * 1e3, "ms", 1'),
                     ("B13 Sync ignoriert Leap-Status", 'and leap.lower() in ("normal", "insert second", "delete second")', ""),
                     ("B14 Route erlaubt POST", 'methods=["GET"])\n        print("clockOff aktiv', 'methods=["GET", "POST"])\n        print("clockOff aktiv'),
                     ("B15 Block mit requests", "def _cl_read():\n", "import requests\n\n\ndef _cl_read():\n"),
                     ("B16 Block ohne Ende-Marker", "# ===== /clockOff =====", ""),
                     ("B17 Selbsttest schluckt Fehler", '    print("clockOff Selbsttest FEHLER (%s)" % _cl_e, flush=True)\n', "    pass\n"),
                     ("B18 anderer Befehl", 'CL_CMD = ["chronyc", "-c", "tracking"]', 'CL_CMD = ["chronyc", "tracking"]')):
        assert B.count(a) == 1, nm + " (%d)" % B.count(a)
        nb = B.replace(a, b)
        M.append((nm, pre + nb + post[len(B):], nb, 1, None))
    bad = []
    done = 0
    for name, mnew, mblk, norev, e2 in M:
        w = tempfile.mkdtemp(prefix="cl-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(mnew)
            bf = os.path.join(w, "blk.py")
            with open(bf, "w", encoding="utf-8") as f:
                f.write(mblk if mblk.endswith("\n") else mblk + "\n")
            ef = ep
            if e2 is not None:
                ef = os.path.join(w, "edits.py")
                with open(ef, "w", encoding="utf-8") as f:
                    f.write("DSH_ANCHOR = %r\nDSH_EDITS = %r\n" % (anch, e2))
            if norev:
                os.environ["RH_CL_NOREV"] = "1"
            else:
                os.environ.pop("RH_CL_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, bf, ef)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            os.environ.pop("RH_CL_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)

    def edmut(name, fn):
        nonlocal done
        e2 = fn([tuple(x) for x in edits])
        w = tempfile.mkdtemp(prefix="cl-mut-")
        try:
            ef = os.path.join(w, "edits.py")
            with open(ef, "w", encoding="utf-8") as f:
                f.write("DSH_ANCHOR = %r\nDSH_EDITS = %r\n" % (anch, e2))
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new)
            os.environ.pop("RH_CL_NOREV", None)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altdir, nd, blk, ef)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            shutil.rmtree(w, ignore_errors=True)
    edmut("E1 eine Stelle fehlt", lambda e: e[1:])
    edmut("E2 Stelle mit falschem Alttext (Rueckbau ungenau)", lambda e: [(e[0][0] + "# x\n", e[0][1])] + e[1:])
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation clockOff: %d Mutationen, %d erkannt, 0 uebersehen" % (done, done))
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a[0] == "revert":
            revert(*a[1:5])
        elif a[0] == "check":
            check(*a[1:5])
        elif a[0] == "mutate":
            sys.exit(mutate(*a[1:4]))
        else:
            print(__doc__)
            sys.exit(2)
    except AssertionError as e:
        print("guard clockOff FEHLER: %s" % e)
        sys.exit(1)
MK_RAG_EOF
PPK="$W/patch.py"; RED="$W/edits.py"; RBK="$W/blk.py"; RGD="$W/guard.py"
for x in "$EXPECT_PAL $PPK" "$EXPECT_RAE $RED" "$EXPECT_RAB $RBK" "$EXPECT_RAG $RGD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (Patcher, Stellen, Block, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach wxSlot commit34" "$KNOWN_D16N" "clockOff schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      clockOff passt nur auf den Stand Stand nach wxSlot commit34 (dashboard.py 03ee294d6e4ed56f). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- clockOff: Neustart-Fenster rund um die Wetter-Slots (3-h-Takt 0,3,...,21 Uhr, Berlin) ----
# Gesperrt: HH:55-HH:59 jeder Stunde vor einem Slot (z. B. 14:55-14:59), die ersten 5 Minuten der Slot-Stunde (15:00-15:04) und HH:55-HH:59 der Slot-Stunde selbst.
# (Neustart um HH:59 kann die Slot-Meldung verzoegern; wxSlot holt sie dann nach, aber der Apply soll nie selbst in dieses Fenster fallen.)
wxwin() { local s=$1 h m r; h=$(( s / 3600 % 24 )); m=$(( s / 60 % 60 )); r=$(( h % 3 ))
  if [[ $r == 2 && $m -ge 55 ]]; then return 0; fi
  if [[ $r == 0 && ( $m -lt 5 || $m -ge 55 ) ]]; then return 0; fi
  return 1; }
wxsec() { local hm
  if [[ -n "${WXSLOT_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$WXSLOT_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) + $1 )); }
wxfree() { local k s; for k in $(seq 0 240); do s=$(wxsec $(( k * 60 ))); wxwin "$s" || { printf '%02d:%02d' $(( s / 3600 % 24 )) $(( s / 60 % 60 )); return; }; done; echo "?"; }
wxcheck() { local when=$1 s0 s1
  s0=$(wxsec 0); s1=$(wxsec 150)
  if wxwin "$s0" || wxwin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Fenster: jetzt ($when, Berlin-Zeit $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 )))) waere ein echter Lauf gesperrt (Slot-Zeit des Wetters) - frei ab ca. $(wxfree) Uhr; der Trockenlauf aendert nichts"
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Fenster: clockOff ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Fenster: es ist $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 ))) Uhr (Berlin) - kurz vor/in/nach einer 3-h-Wetter-Slot-Zeit (0,3,...,21 Uhr; gesperrt HH:55-HH:04 um die Slots und HH:55-HH:59 der Slot-Stunde). Ein Neustart jetzt koennte die Wetter-Slot-Meldung verzoegern (wxSlot holt sie zwar nach, aber das Fenster wird gemieden). Bitte ab ca. $(wxfree) Uhr neu starten (Bridge und andere Dienste wurden nicht beruehrt)"; fi
  else echo "OK Neustart-Fenster: $(printf '%02d:%02d' $(( s0 / 3600 % 24 )) $(( s0 / 60 % 60 ))) Uhr (Berlin) liegt ausserhalb der Wetter-Slot-Zeit (gesperrt HH:55-HH:04 um 0,3,...,21 Uhr und HH:55-HH:59 der Slot-Stunden)"; fi; }
wxcheck "Vorpruefung"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" clockOff dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer clockOff nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" clockOff dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: clockOff im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne clockOff ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard clockOff meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" nice -n 10 "$VPY" "$RGD" mutate "$W/neu" "$RBK" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^aequivalent|^OK" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-0}"; }
tmed() { local i; for i in 1 2 3 4 5; do tm "$1"; done | sort -n | sed -n 3p; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
pcode() { code -X POST "$@"; }
PILAT0=$(tmed "$B/pi")
echo "Zustand vorher: /pi antwortet im Median in ${PILAT0} s"
# ---- clockOff: Fenster direkt vor dem Neustart noch einmal pruefen; chronyc-Stand vorher ----
wxcheck "vor dem Neustart"
CHR_OK=0
if command -v chronyc >/dev/null 2>&1; then
  CHR_L=$(timeout 5 chronyc -c tracking 2>/dev/null | head -1 || true)
  if [[ "$(echo "$CHR_L" | awk -F, '{print NF}')" -ge 14 ]]; then CHR_OK=1
    echo "Zustand vorher: chronyc -c tracking liefert Stratum $(echo "$CHR_L" | cut -d, -f3), Referenz $(echo "$CHR_L" | cut -d, -f2), System time $(echo "$CHR_L" | cut -d, -f5) s (positiv = Uhr geht nach)"
  else echo "HINWEIS chronyc ist da, liefert aber keine verwertbare Zeile - die Kachel zeigt dann den ntplib-Rueckfall mit Hinweis"; fi
else echo "HINWEIS chronyc ist auf diesem Rechner nicht installiert - die Kachel zeigt den ntplib-Rueckfall '(ntplib)'"; fi
OLDT=$("${CURL[@]}" "$B/" 2>/dev/null | grep -o 'Stratum Offset: [^<]*' | head -1 || true)
echo "Zustand vorher: Kachel '${OLDT:-?}'"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: clockOff ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-clockoff-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG clockoff=dry fertig"
  exit 0
fi
if [[ "$NEED_D" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "clockOff|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-clockoff-$TS" ]] && cp -a "$F.bak-clockoff-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-clockoff-$TS" ]] && { cmp -s "$F" "$F.bak-clockoff-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK clockOff schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-clockoff-$TS"
  { ls -1t "$F.bak-clockoff-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-clockoff-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-clockoff-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'clockOff aktiv' im Journal ..."
  sudo systemctl restart prepper-dashboard.service
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-dashboard && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-dashboard antwortet nach dem Neustart nicht (240 s)"; exit 1; }
fi
PHASE=Pruefung
# ---------- 5) Pruefung ----------
for p in "${PAGES[@]}" "${APIS[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  [[ "$c" == "${PRE[$p]}" ]] || rbx "$p antwortet $c (vorher ${PRE[$p]})"
done
echo "OK Smoke-Test: ${#PAGES[@]} Seiten und ${#APIS[@]} APIs antworten wie vorher (alle $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s ' "${PRE[$p]}"; done | tr ' ' '\n' | sort -u | tr '\n' ' '))"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); P1=$(grep -o 'Projektbeschreibung' "$W/pi.html" | wc -l || true)
[[ "$R1" -ge 1 && "$P1" -ge 1 ]] || rbx "/pi liefert Sicherung/Projektbeschreibung nicht mehr (doPrepperRestore ${R1}x, Projektbeschreibung ${P1}x)"
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; clockOff aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- clockOff: Marker einmal, Kachel auf der Lage-Seite, Vorzeichen gegen chronyc, API ----
CLM=$(grep -c "^# ===== clockOff:" "$F" || true); CLO=$(grep -c 'Stratum Offset: {%' "$F" || true)
[[ "$CLM" == 1 && "$CLO" == 0 ]] && echo "OK Marker clockOff 1x im Programm, alte Kachelzeile 'Stratum Offset' kommt im Programm nicht mehr vor" || rbx "Marker/Kachelzeile clockOff falsch (Marker $CLM, alte Zeile $CLO)"
"${CURL[@]}" "$B/" -o "$W/lage.html" || true
CLT=$(grep -o '<div class="small" id="clock-off"[^>]*>[^<]*' "$W/lage.html" | head -1 || true)
if [[ -n "$CLT" ]]; then
  CLX=$(echo "$CLT" | sed 's/^[^>]*>//'); echo "OK Kachel auf der Lage-Seite: '$CLX'"
  case "$CLX" in *nan*|*NaN*|"Zeit-Offset: ") rbx "Kachel zeigt leeren/ungueltigen Wert: '$CLX'" ;; esac
else echo "HINWEIS Die Lage-Seite zeigt die Kachel noch nicht (sie zeigt bis zum ersten Voll-Update den Ladehinweis) - geprueft wird /api/clock-off; die Kachel erscheint, sobald die Seite wieder normal laeuft"; fi
CLA=$("${CURL[@]}" "$B/api/clock-off" 2>/dev/null || true)
echo "$CLA" > "$W/clk.json"
CLR=$(python3 - "$W/clk.json" <<'PY' 2>/dev/null || echo "NOK unlesbar"
import sys, json
j = json.load(open(sys.argv[1]))
t = j.get("text") or ""
ok = bool(t) and "nan" not in t.lower() and j.get("src") in ("chrony", "ntplib", "none")
print(("OK" if ok else "NOK"), j.get("src"), "" if j.get("us") is None else j.get("us"), "|", t, "|", j.get("sub"))
PY
)
case "$CLR" in OK*) echo "OK /api/clock-off: ${CLR#OK }" ;; *) rbx "/api/clock-off liefert keine gueltige Antwort ($CLR)" ;; esac
CLS=$(echo "$CLR" | awk '{print $2}'); CLU=$(echo "$CLR" | awk '{ if ($3 != "|") print $3 }')
if [[ "$CHR_OK" == 1 ]]; then
  if [[ "$CLS" == chrony ]]; then
    CLP=$(LC_ALL=C timeout 5 chronyc tracking 2>/dev/null | sed -n 's/^System time *: *\([0-9.eE+-]*\) seconds \(slow\|fast\) of NTP time.*/\1 \2/p' | head -1 || true)
    python3 - "$CLU" "$CLP" <<'PY' || true
import sys
us = sys.argv[1]; p = sys.argv[2].split()
if not us or len(p) != 2:
    print("HINWEIS Vorzeichen-Gegenprobe nicht moeglich (Kachel '%s', chronyc tracking '%s')" % (us, " ".join(p))); raise SystemExit(0)
k = float(us); c = float(p[0]) * 1e6 * (1 if p[1] == "slow" else -1)
if abs(k) < 3 or abs(c) < 3:
    print("OK Vorzeichen-Gegenprobe: Kachel %+.2f us, chronyc tracking %+.2f us (slow = +, fast = -) - beide unter 3 us, Vorzeichen bei so kleinen Werten nicht aussagekraeftig" % (k, c))
elif (k > 0) == (c > 0):
    print("OK Vorzeichen-Gegenprobe: Kachel %+.2f us, chronyc tracking %+.2f us (slow = +, fast = -): gleiches Vorzeichen" % (k, c))
else:
    print("WARNUNG Vorzeichen-Gegenprobe: Kachel %+.2f us, chronyc tracking %+.2f us (slow = +, fast = -) - Vorzeichen verschieden (zwischen den Messungen vergehen Sekunden; bitte von Hand pruefen: chronyc tracking)" % (k, c))
PY
  else echo "HINWEIS chronyc liefert auf der Pi eine Zeile, die Kachel zeigt aber '$CLS' - das Dashboard erreicht chronyc nicht (Rechte/Sandbox?) und zeigt den Rueckfall; Journal: 'clockOff: chronyc nicht nutzbar'"; fi
else echo "HINWEIS Ohne nutzbares chronyc zeigt die Kachel den Rueckfall '$CLS' - Funktion bewusst (nie leer)"; fi
echo "HINWEIS Docs: prepper_docs.py nennt noch 'Stratum Offset (ntplib)' (3 Stellen) - nicht in diesem Patch; Text fuer die naechste Docs-Version liegt bei"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E clockOff"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "clockOff aktiv: clockOff ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'clockOff aktiv: clockOff ok' ($(echo "$JD" | grep -F clockOff | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein clockOff-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)")"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"))" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-clockoff-$TS" ]] && echo "Backup: dashboard.py.bak-clockoff-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-clockoff-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine clockoff-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c 'clockOff' /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/api/clock-off"
echo "  chronyc tracking | head -5"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep clockOff"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG clockoff=1 fertig"
