#!/bin/bash
set -eEuo pipefail
# perfKeep (commit27): Dashboard bei Aufrufen schneller (nur dashboard.py). Sendet nichts (kein Mesh, kein Telegram, keine Alarme), aendert keine Alarm-, Sende- oder Abruflogik, keine Anzeige.
#  Befund: Die keepLast-Heilung (before_request und render_template_string) schrieb bei JEDER Anfrage bis zu 22-mal die ganze Datei keep-last.json neu (Kopie + json.dump + os.replace je Schluessel) unter einer globalen Sperre;
#   dadurch ~1 s fuer eine Mini-Anfrage wie /api/time und ~2,3 s Sockel je Seite. /pi rief ausserdem bei jedem Aufruf ping -c 3 (mind. 2 s) auf.
#  A) _keep_heal_store merkt (Kopie + Schreiben von keep-last.json) nur noch, wenn sich Inhalt oder Zeitstempel gegenueber dem Gemerkten (_KEEP_MEM) geaendert haben; Wiederherstellung schlechter Abrufe, Faerbung und alle echten Abruf-Wrapper bleiben gleich.
#     Schlug das Schreiben fehl, wird wie bisher bei jeder Heilung neu versucht, bis es klappt.
#  B) /pi nimmt den Ping aus data_store, wenn freq_loop ihn vor hoechstens 90 s gemessen hat (Zeitstempel in einer eigenen Variable, monoton); sonst wie bisher fetch_ping().
#  Basis streng (sha16): dashboard.py cdd62e7136267498 (Stand nach relHygiene commit19b) oder perfKeep schon drin. Andere Dateien werden nicht angefasst (nur vorher/nachher-Vergleich).
#  Neustart: nur prepper-dashboard. Sicherung: dashboard.py.bak-perfkeep-ZEIT (letzte 3). Keine Datenbank-Aenderung (daher keine SQLite-Sicherung). Keine neue Docs-Version (nur dashboard.py; Text fuer die naechste Docs-Version liegt beim Bericht).
# Aufruf: bash /tmp/apply-perfkeep.sh commit27 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
KL="$DASH_DIR/keep-last.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/perfkeep-apply
KEEP_LAST=3
KNOWN_D16="cdd62e7136267498"      # dashboard.py vor perfKeep (Basis = Stand nach relHygiene commit19b)
KNOWN_D16N="08fbc3e35940faab"             # dashboard.py nach perfKeep (Ziel)
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
echo "=== perfKeep apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): keep-last.json nur bei Aenderung schreiben, /pi-Ping aus dem Zwischenspeicher, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PPK="98b60e83994b5e81e8713bf3958d99f14e01f7f0cc23feb350a65f4313c14a08"
cat > "$W/patch-pk.py" << 'PK_PPK_EOF'
"""Patcher perfKeep. Aufruf: patch-pk.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
PK_PPK_EOF
EXPECT_RED="0b4bbff5dcbdb1bc1e10eacd8498b43abb1f308bc8667cb48f00431ab75e5591"
cat > "$W/edits_pk.py" << 'PK_RED_EOF'
# perfKeep: Stellen (alt, neu) fuer dashboard.py. Jede alte Stelle genau einmal. Nur Geschwindigkeit: Heilung schreibt keep-last.json nur bei Aenderung (A), /pi nimmt den Ping aus dem Zwischenspeicher (B).
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    # A0: Merker, ob das letzte Schreiben von keep-last.json fehlgeschlagen ist (dann wird beim naechsten Mal wieder geschrieben wie bisher)
    ("_KEEP_MEM = {}\n_KEEP_LOCK = _keep_threading.RLock()\n",
     "_KEEP_MEM = {}\n_KEEP_DISK_BAD = [False]  # perfKeep: True = letztes Schreiben von keep-last.json fehlgeschlagen -> Heilung schreibt wieder wie bisher\n_KEEP_LOCK = _keep_threading.RLock()\n"),
    # A1: Vergleich mit dem Gemerkten (reine Funktion, keine Kopie, keine Datei)
    ("def _keep_remember(key, payload, updated):\n    if payload is None:\n        return\n",
     '''def _keep_same(key, payload, updated, mem=None, bad=None):
    """perfKeep: True nur, wenn payload/updated genau dem Gemerkten (_KEEP_MEM) entsprechen - dann sind Kopie und Neuschreiben von keep-last.json ueberfluessig.
    Im Zweifel False (= wie bisher merken und schreiben): fehlender Eintrag, anderer Zeitstempel, anderer Inhalt, Fehler beim Vergleich, letztes Schreiben fehlgeschlagen."""
    try:
        if payload is None or (_KEEP_DISK_BAD[0] if bad is None else bad):
            return False
        rec = (_KEEP_MEM if mem is None else mem).get(key)
        if not isinstance(rec, dict) or (rec.get("updated") or "") != (updated or ""):
            return False
        if isinstance(payload, dict) and ("_keepLastTs" in payload or "kept" in payload):
            payload = {k: v for k, v in payload.items() if k not in ("_keepLastTs", "kept")}
        return bool(rec.get("payload") == payload)
    except Exception:
        return False

def _keep_remember(key, payload, updated):
    if payload is None:
        return
'''),
    # A2: Schreibfehler merken / Erfolg loeschen
    ('''        _keep_os.replace(tmp, path)
    except Exception as e:
        print("keepLast disk:", e)
''',
     '''        _keep_os.replace(tmp, path)
        _KEEP_DISK_BAD[0] = False
    except Exception as e:
        _KEEP_DISK_BAD[0] = True
        print("keepLast disk:", e)
'''),
    # A3: Heilung merkt nur noch bei Aenderung
    ('''            if _keep_good(key, payload):
                _keep_remember(key, payload if kind != "slot" else slot, slot.get("updated"))
                _keep_recolor(key, slot)
                continue
''',
     '''            if _keep_good(key, payload):
                if not _keep_same(key, payload if kind != "slot" else slot, slot.get("updated")):  # perfKeep: unveraendert -> nichts kopieren, nichts schreiben
                    _keep_remember(key, payload if kind != "slot" else slot, slot.get("updated"))
                _keep_recolor(key, slot)
                continue
'''),
    # B0: Zwischenspeicher-Ping (Zeitstempel in einer eigenen Variable, data_store bleibt unveraendert)
    ("def freq_loop():\n    while True:\n        try:\n            f = fetch_frequenz_live()\n",
     '''_PERF_PING_T = [None]  # perfKeep: time.monotonic() der letzten erfolgreichen Messung von freq_loop (monoton, uhrunabhaengig)
_PERF_PING_MAX_AGE = 90.0  # Sekunden; freq_loop misst etwa alle 25 s


def _perf_ping_cached(store=None, stamp=None, now=None, max_age=None):
    """perfKeep: Ping fuer /pi aus data_store, wenn freq_loop ihn vor hoechstens 90 s gemessen hat; sonst None (dann wie bisher der Ping-Aufruf)."""
    try:
        t = (_PERF_PING_T if stamp is None else stamp)[0]
        if t is None:
            return None
        age = (time.monotonic() if now is None else now) - t
        if age < 0 or age > (_PERF_PING_MAX_AGE if max_age is None else max_age):
            return None
        v = (data_store if store is None else store).get("ping")
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            return None
        return v
    except Exception:
        return None


def freq_loop():
    while True:
        try:
            f = fetch_frequenz_live()
'''),
    ('''                data_store["ping"] = p
                data_store["ping_history"] = list(ping_history)
                # Ping ok => nicht als offline stehen lassen
''',
     '''                data_store["ping"] = p
                data_store["ping_history"] = list(ping_history)
                _PERF_PING_T[0] = time.monotonic()  # perfKeep: Zeitstempel der Messung
                # Ping ok => nicht als offline stehen lassen
'''),
    # B1: /pi
    ('''    try:
        ping = fetch_ping()
    except Exception:
        ping = data_store.get("ping")
    try:
        public_ip = data_store.get("public_ip") or (fetch_public_ip()[0] if False else None)
''',
     '''    try:
        ping = _perf_ping_cached()  # perfKeep: frischer Wert aus dem Zwischenspeicher (kein ping-Aufruf je Seitenaufruf)
        if ping is None:
            ping = fetch_ping()
    except Exception:
        ping = data_store.get("ping")
    try:
        public_ip = data_store.get("public_ip") or (fetch_public_ip()[0] if False else None)
'''),
]
PK_RED_EOF
EXPECT_RBK="33c40cfddecb8406edb17a6448643cc7c8325a81c47ee83dc6f074fe787b301f"
cat > "$W/blk_pk.py" << 'PK_RBK_EOF'
# ===== perfKeep: keepLast schreibt keep-last.json nur noch bei Aenderung, /pi nimmt den Ping aus dem Zwischenspeicher (nur Geschwindigkeit; keine Anzeige-, Alarm-, Sende- oder Abruflogik) =====
def _selftest_perfkeep():
    """Rein rechnend, ohne Datei, ohne _KEEP_MEM/data_store/Netz anzufassen (Fake-Werte)."""
    mem = {"wetter": {"payload": {"temp": 5, "x": [1, 2]}, "updated": "10:00"}}
    same = _keep_same("wetter", {"temp": 5, "x": [1, 2]}, "10:00", mem=mem, bad=False)
    tagged = _keep_same("wetter", {"temp": 5, "x": [1, 2], "_keepLastTs": "09:00", "kept": True}, "10:00", mem=mem, bad=False)
    diff_p = _keep_same("wetter", {"temp": 6, "x": [1, 2]}, "10:00", mem=mem, bad=False)
    diff_t = _keep_same("wetter", {"temp": 5, "x": [1, 2]}, "10:01", mem=mem, bad=False)
    nokey = _keep_same("gas", {"full": 1}, "10:00", mem=mem, bad=False)
    badf = _keep_same("wetter", {"temp": 5, "x": [1, 2]}, "10:00", mem=mem, bad=True)
    assert same is True and tagged is True and diff_p is False and diff_t is False and nokey is False and badf is False, "keep_same %s" % [same, tagged, diff_p, diff_t, nokey, badf]
    st = [100.0]
    ds = {"ping": 12.5}
    fresh = _perf_ping_cached(store=ds, stamp=st, now=150.0)
    old = _perf_ping_cached(store=ds, stamp=st, now=191.0)
    back = _perf_ping_cached(store=ds, stamp=st, now=90.0)
    none_t = _perf_ping_cached(store=ds, stamp=[None], now=150.0)
    no_val = _perf_ping_cached(store={"ping": None}, stamp=st, now=150.0)
    bad_val = _perf_ping_cached(store={"ping": True}, stamp=st, now=150.0)
    assert fresh == 12.5 and old is None and back is None and none_t is None and no_val is None and bad_val is None, "ping_cached %s" % [fresh, old, back, none_t, no_val, bad_val]
    return "perfKeep ok (Heilung schreibt nur bei Aenderung, /pi-Ping aus dem Zwischenspeicher bis %d s)" % int(_PERF_PING_MAX_AGE)


try:
    _PK = {"selftest": _selftest_perfkeep()}
    print("perfKeep aktiv: %s" % _PK["selftest"], flush=True)
except Exception as _pk_e:
    _PK = {"selftest": "FEHLER %s" % _pk_e}
    print("perfKeep Selbsttest FEHLER:", _pk_e, flush=True)
PK_RBK_EOF
EXPECT_RGD="d473ab292e78320cb3e553143ee056957943b3d47f849ff6a2bb3a558b5d27fd"
cat > "$W/guard_pk.py" << 'PK_RGD_EOF'
"""AST-Guard perfKeep (nur dashboard.py). Aufruf:
  guard_pk.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne perfKeep (Rueckbau, byte-genau)
  guard_pk.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhalten in der Sandbox (Differenztest alt/neu)
  RH_ALT=ALT_VERZ guard_pk.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest: jede absichtliche Verfehlung muss erkannt werden
Kein node, kein Netz, keine echten Dateien des Dashboards: alles in temporaeren Ordnern."""
import ast
import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import time

MARK = "# ===== perfKeep:"
MAIN = '\n\nif __name__ == "__main__":\n'


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block perfKeep nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle perfKeep nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


# ---------------- statische Regeln ----------------
ALLOWED_TOP = {"_KEEP_DISK_BAD", "_keep_same", "_keep_remember", "_keep_heal_store", "_PERF_PING_T", "_PERF_PING_MAX_AGE",
               "_perf_ping_cached", "freq_loop", "page_pi", "_selftest_perfkeep", "_PK"}


def top_name(n):
    if isinstance(n, (ast.FunctionDef, ast.ClassDef)):
        return n.name
    if isinstance(n, ast.Assign):
        return ",".join(t.id for t in n.targets if isinstance(t, ast.Name)) or "#assign"
    if isinstance(n, ast.Try):
        return "_PK" if "_selftest_perfkeep()" in ast.unparse(n) else "#try"
    return "#" + type(n).__name__


def find_func(tree, name):
    for n in ast.walk(tree):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n
    raise AssertionError("Funktion fehlt: " + name)


def calls_in(node, name):
    return [c for c in ast.walk(node) if isinstance(c, ast.Call) and isinstance(c.func, ast.Name) and c.func.id == name]


def static(alt, new, blk):
    n = 0
    ta, tn = ast.parse(alt), ast.parse(new)
    # 1) nur erlaubte Top-Level-Knoten geaendert/neu
    da = {ast.dump(x): top_name(x) for x in ta.body}
    dn = {ast.dump(x): top_name(x) for x in tn.body}
    changed = [dn[k] for k in dn if k not in da] + [da[k] for k in da if k not in dn]
    bad = sorted(set(c for c in changed if c not in ALLOWED_TOP))
    assert not bad, "perfKeep aendert ausserhalb der erlaubten Stellen: %s" % bad
    n += 1
    # 2) Heilung: _keep_remember nur hinter 'if not _keep_same(...)'
    hs = find_func(tn, "_keep_heal_store")
    rem = calls_in(hs, "_keep_remember")
    assert len(rem) == 1, "_keep_heal_store: genau ein _keep_remember-Aufruf erwartet (%d)" % len(rem)
    guarded = False
    for node in ast.walk(hs):
        if isinstance(node, ast.If) and isinstance(node.test, ast.UnaryOp) and isinstance(node.test.op, ast.Not) \
                and isinstance(node.test.operand, ast.Call) and isinstance(node.test.operand.func, ast.Name) and node.test.operand.func.id == "_keep_same" \
                and not node.orelse and any(c is rem[0] for b in node.body for c in ast.walk(b)):
            guarded = True
            # die uebergebenen Argumente muessen dieselben sein wie beim Merken
            assert [ast.dump(a) for a in node.test.operand.args] == [ast.dump(a) for a in rem[0].args], "_keep_same bekommt andere Argumente als _keep_remember"
    assert guarded, "_keep_remember in der Heilung nicht durch 'if not _keep_same(...)' geschuetzt"
    # _keep_recolor und continue bleiben ausserhalb der Bedingung (wie bisher)
    n += 1
    # 3) _keep_remember: Schreibfehler-Merker
    kr = ast.unparse(find_func(tn, "_keep_remember"))
    i_rep, i_f, i_ex, i_t = kr.find("_keep_os.replace(tmp, path)"), kr.find("_KEEP_DISK_BAD[0] = False"), kr.find("except Exception as e:"), kr.find("_KEEP_DISK_BAD[0] = True")
    assert 0 <= i_rep < i_f < i_ex < i_t, "_keep_remember: _KEEP_DISK_BAD muss nach os.replace geloescht und im except gesetzt werden"
    assert kr.count("_KEEP_DISK_BAD") == 2
    n += 1
    # 4) _keep_same: reine Funktion (keine Datei, keine Kopie, kein Schreiben)
    ks = find_func(tn, "_keep_same")
    ksu = ast.unparse(ks)
    for forbidden in ("open(", "deepcopy", "_keep_remember", "replace(", "dump(", "print(", "subprocess", "_KEEP_MEM[", "data_store"):
        assert forbidden not in ksu, "_keep_same enthaelt %s" % forbidden
    assert "_KEEP_DISK_BAD" in ksu and "updated" in ksu and "payload" in ksu
    n += 1
    # 5) freq_loop: Zeitstempel direkt nach der Ping-Historie, nur bei gemessenem Ping, monoton
    fl = find_func(tn, "freq_loop")
    stamps = [s for s in ast.walk(fl) if isinstance(s, ast.Assign) and ast.unparse(s) == "_PERF_PING_T[0] = time.monotonic()"]
    assert len(stamps) == 1, "freq_loop: genau ein Zeitstempel _PERF_PING_T[0] = time.monotonic() erwartet (%d)" % len(stamps)
    ok = False
    for node in ast.walk(fl):
        if isinstance(node, ast.If) and ast.unparse(node.test) == "p is not None":
            u = [ast.unparse(s) for s in node.body]
            k = u.index("_PERF_PING_T[0] = time.monotonic()") if "_PERF_PING_T[0] = time.monotonic()" in u else -1
            ok = k > 0 and u[k - 1] == "data_store['ping_history'] = list(ping_history)" and u[k - 2] == "data_store['ping'] = p"
    assert ok, "freq_loop: Zeitstempel muss in 'if p is not None' direkt nach data_store['ping'] / ['ping_history'] stehen"
    n += 1
    # 6) /pi: Zwischenspeicher zuerst, fetch_ping() nur als Rueckfall, Ausnahmezweig unveraendert
    pp = find_func(tn, "page_pi")
    tries = [t for t in ast.walk(pp) if isinstance(t, ast.Try) and "_perf_ping_cached" in ast.unparse(t)]
    assert len(tries) == 1, "page_pi: genau ein try mit _perf_ping_cached erwartet"
    t = tries[0]
    body = [ast.unparse(s) for s in t.body]
    assert body == ["ping = _perf_ping_cached()", "if ping is None:\n    ping = fetch_ping()"], "page_pi: Reihenfolge Zwischenspeicher -> fetch_ping() verletzt: %s" % body
    assert len(t.handlers) == 1 and [ast.unparse(s) for s in t.handlers[0].body] == ["ping = data_store.get('ping')"] and ast.unparse(t.handlers[0].type) == "Exception", "page_pi: Ausnahmezweig geaendert"
    assert len(calls_in(pp, "fetch_ping")) == 1, "page_pi: fetch_ping() nur einmal (Rueckfall)"
    n += 1
    # 7) _perf_ping_cached: reine Funktion
    pc = ast.unparse(find_func(tn, "_perf_ping_cached"))
    for forbidden in ("fetch_ping", "subprocess", "open(", "requests", "socket", "print("):
        assert forbidden not in pc, "_perf_ping_cached enthaelt %s" % forbidden
    assert "time.monotonic()" in pc and "time.time()" not in pc, "_perf_ping_cached/Zeitstempel: nur time.monotonic()"
    n += 1
    # 8) Neuer Code: keine Netz-/Prozess-/Sendewege, keine Dateizugriffe, keine fremden Importe
    B = rd(blk)
    added = B + "\n" + "\n".join(ast.unparse(find_func(tn, f)) for f in ("_keep_same", "_perf_ping_cached"))
    for forbidden in ("subprocess", "requests", "urllib", "socket", "os.system", "Popen", "open(", "mesh_send", "telegram", "send_", ".post(", "http://", "https://", "eval(", "exec(", "__import__", "import "):
        assert forbidden not in added, "perfKeep-Code enthaelt '%s'" % forbidden
    n += 1
    # 9) Marker genau einmal, Block steht vor dem Main-Abschnitt, nach relHygiene (falls vorhanden)
    assert new.count(MARK) == 1 and new.index(MARK) < new.index(MAIN), "perfKeep-Block: Marker/Position"
    n += 1
    return n


# ---------------- Verhalten ----------------
class OsCount:
    def __init__(self):
        self.replaces = 0

    def replace(self, a, b):
        self.replaces += 1
        return os.replace(a, b)

    def __getattr__(self, k):
        return getattr(os, k)


def keep_ns(src, workdir):
    i, j = src.index("# keepLast \u2014 letzter guter Payload"), src.index("def _keep_scrub_ctx")
    seg = src[i:j]
    ns = {"__file__": os.path.join(workdir, "dashboard.py"), "data_store": {}, "__name__": "pk_sandbox"}
    ns["now_str"] = lambda: "NOW"
    ns["stale_ts_color"] = lambda key, upd: "c:%s:%s" % (key, upd)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(seg, "keep_segment", "exec"), ns)
    cnt = OsCount()
    ns["_keep_os"] = cnt
    ns["_cnt"] = cnt
    return ns


PAYLOADS = {
    "mix": {"renew": 40}, "load": {"load_gw": 50}, "strom": {"current": 5}, "gas": {"full": 70}, "lng": {"full": 60},
    "lng_term": {"de_util": 3}, "kraftstoff": {"diesel": 1.7}, "rohoel": {"brent": 80}, "stromausfall": {"count": 0},
    "wetter": {"temp": 5, "kept": True}, "odl": {"avg": 0.1}, "luft": {"lqi": 2}, "pegel": [{"cm": 100}], "spaceweather": {"kp": 2},
    "nina": [], "metalle": {"btc": 1}, "news": {"feeds": [{"items": [1]}]}, "adsb": {"ok": True}, "system": {"cpu": 3},
    "stratum": {"time": "12:00:00"}, "dwd_warn": {"items": []}, "dwd_wbi": {"wbi": 1},
}


def scenario(src, workdir):
    ns = keep_ns(src, workdir)
    ds = ns["data_store"]
    trace = []
    cnt = ns["_cnt"]
    out = io.StringIO()

    def snap(tag):
        p = ns["_keep_path"]()
        disk = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else None
        mem = json.loads(json.dumps(ns["_KEEP_MEM"], sort_keys=True, default=str))
        trace.append((tag, json.dumps(ds, sort_keys=True, default=str), json.dumps(disk, sort_keys=True), json.dumps(mem, sort_keys=True), out.getvalue().replace(workdir, "<W>")))
        out.truncate(0)
        out.seek(0)

    def heal(times=1):
        with contextlib.redirect_stdout(out):
            for _ in range(times):
                ns["_keep_heal_store"]()

    counts = {}
    for k, v in PAYLOADS.items():
        ds[k] = {"value": json.loads(json.dumps(v)), "updated": "10:00"}
    with contextlib.redirect_stdout(out):
        for k in PAYLOADS:
            ns["_keep_remember"](k, ds[k]["value"], ds[k]["updated"])
    counts["seed"] = cnt.replaces
    cnt.replaces = 0
    heal(3)
    counts["unchanged"] = cnt.replaces
    snap("unveraendert x3")
    cnt.replaces = 0
    ds["wetter"]["value"]["temp"] = 6
    heal()
    counts["wert"] = cnt.replaces
    snap("Wert geaendert")
    cnt.replaces = 0
    ds["gas"]["updated"] = "10:05"
    heal()
    counts["zeit"] = cnt.replaces
    snap("Zeitstempel geaendert")
    cnt.replaces = 0
    heal()
    counts["danach"] = cnt.replaces
    snap("danach unveraendert")
    cnt.replaces = 0
    ds["strom"]["value"] = {"current": None}
    heal()
    counts["schlecht"] = cnt.replaces
    snap("schlechter Abruf -> Wiederherstellung")
    cnt.replaces = 0
    ds["kraftstoff"]["value"] = {"diesel": 1.7, "_keepLastTs": "09:00"}
    heal(2)
    counts["tag"] = cnt.replaces
    snap("Markierung _keepLastTs")
    cnt.replaces = 0
    ds["pegel"]["value"] = [{"cm": 101}]
    ds["nina"]["value"] = [{"id": 1}]
    heal()
    counts["liste"] = cnt.replaces
    snap("Listen geaendert")
    cnt.replaces = 0
    ds["slotlos"] = 5            # Schluessel ohne Slot-Dict im Speicher: wird uebersprungen
    ds["odl"] = "kaputt"
    heal()
    snap("Slot kein dict")
    ds["odl"] = {"value": {"avg": 0.2}, "updated": "10:10"}
    # Schreibfehler: Pfad nicht beschreibbar
    good_path = ns["_keep_path"]
    calls = [0]

    def bad_path():
        calls[0] += 1
        return os.path.join(workdir, "gibt-es-nicht", "x", "keep-last.json")
    ns["_keep_path"] = bad_path
    cnt.replaces = 0
    heal()
    counts["bad1_calls"] = calls[0]
    calls[0] = 0
    heal()
    counts["bad2_calls"] = calls[0]            # neu: wieder alle Schluessel (Merker gesetzt); alt: ebenso
    calls[0] = 0
    ns["_keep_path"] = good_path
    heal()
    counts["recover_replaces"] = cnt.replaces
    cnt.replaces = 0
    heal(2)
    counts["after_recover"] = cnt.replaces
    snap("nach Schreibfehler")
    return trace, counts


def behav(alt, new):
    n = 0
    w = tempfile.mkdtemp(prefix="pk-guard-")
    try:
        os.makedirs(os.path.join(w, "a"))
        os.makedirs(os.path.join(w, "n"))
        ta, ca = scenario(alt, os.path.join(w, "a"))
        tn, cn = scenario(new, os.path.join(w, "n"))
        assert len(ta) == len(tn)
        for x, y in zip(ta, tn):
            if x[0] == "nach Schreibfehler":      # Meldungszahl darf kleiner sein (weniger Wiederholungen), Inhalt und Zustand nicht
                x, y = x[:4] + (sorted(set(x[4].splitlines())),), y[:4] + (sorted(set(y[4].splitlines())),)
            assert x == y, "Verhalten weicht ab (Schritt %s): data_store/keep-last.json/Merker/Meldungen ungleich zum alten Stand" % x[0]
        n += 1
        # Wirkung: alt schreibt bei jeder Heilung alles neu (Sinn des Tests), neu nur bei Aenderung
        assert ca["unchanged"] >= 22 * 3 - 3, "Testaufbau: alter Stand schreibt nicht (%s)" % ca
        assert cn["unchanged"] == 0, "neu: unveraenderter Stand darf keine Datei schreiben (%d)" % cn["unchanged"]
        assert cn["wert"] == 1 and cn["zeit"] == 1, "neu: je echter Aenderung genau ein Schreibvorgang (Wert %d, Zeit %d)" % (cn["wert"], cn["zeit"])
        assert cn["danach"] == 0 and cn["schlecht"] == 0, "neu: danach/Wiederherstellung schreibt nichts (%d/%d)" % (cn["danach"], cn["schlecht"])
        assert cn["tag"] == 1 and cn["liste"] == 2, "neu: Markierung (1 Aenderung)/Listen (2 Aenderungen): %d/%d" % (cn["tag"], cn["liste"])
        n += 1
        # Schreibfehler: weiter versuchen wie bisher (alle Schluessel), nach Behebung genau ein Lauf, danach Ruhe
        assert cn["bad1_calls"] >= 1 and cn["bad2_calls"] >= 22, "neu: bei Schreibfehler muss weiter versucht werden (%d/%d)" % (cn["bad1_calls"], cn["bad2_calls"])
        assert cn["after_recover"] == 0, "neu: nach Behebung des Schreibfehlers kein dauerndes Neuschreiben (%d)" % cn["after_recover"]
        assert cn["recover_replaces"] >= 1, "neu: nach Behebung muss geschrieben werden"
        n += 1
        # _keep_same direkt (Grenzfaelle)
        ns = keep_ns(new, os.path.join(w, "n"))
        ks = ns["_keep_same"]
        mem = {"k": {"payload": {"a": 1}, "updated": "t"}}
        assert ks("k", {"a": 1}, "t", mem=mem, bad=False) is True
        assert ks("k", None, "t", mem={"k": {"payload": None, "updated": "t"}}, bad=False) is False, "payload None gilt nie als gleich"
        assert ks("k", None, "t", mem={"k": {"payload": None, "updated": "t"}}, bad=True) is False
        assert ks("k", {"a": 2}, "t", mem=mem, bad=False) is False
        assert ks("k", {"a": 1}, "u", mem=mem, bad=False) is False
        assert ks("k", {"a": 1}, "", mem={"k": {"payload": {"a": 1}}}, bad=False) is True
        assert ks("k", {"a": 1}, "t", mem=mem, bad=True) is False
        assert ks("x", {"a": 1}, "t", mem=mem, bad=False) is False
        assert ks("k", None, "t", mem=mem, bad=False) is False
        assert ks("k", {"a": 1}, "t", mem="kaputt", bad=False) is False
        assert ks("k", {"a": 1}, "t", mem={"k": 5}, bad=False) is False
        assert ks("k", [1], "t", mem={"k": {"payload": [1], "updated": "t"}}, bad=False) is True
        assert ks("k", {"a": 1, "kept": True, "_keepLastTs": "x"}, "t", mem=mem, bad=False) is True
        assert ks("k", {"a": float("nan")}, "t", mem={"k": {"payload": {"a": float("nan")}, "updated": "t"}}, bad=False) is False, "NaN -> im Zweifel schreiben"
        n += 1
    finally:
        shutil.rmtree(w, ignore_errors=True)
    # Zwischenspeicher-Ping und Block-Selbsttest
    i, j = new.index("_PERF_PING_T = [None]"), new.index("def freq_loop():")
    seg = new[i:j]
    bi = new.index(MARK)
    blockt = new[bi:new.index(MAIN, bi)]
    ns = {"time": time, "data_store": {"ping": 12.5}}
    exec(compile(seg, "perf_segment", "exec"), ns)
    ns.update(__name__="pk_sandbox")
    ns["_keep_same"] = None
    # Block braucht _keep_same: aus dem keep-Segment
    kns = keep_ns(new, tempfile.gettempdir())
    ns["_keep_same"] = kns["_keep_same"]
    ns["_KEEP_MEM"] = kns["_KEEP_MEM"]
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        exec(compile(blockt, "perf_block", "exec"), ns)
    assert "perfKeep aktiv: perfKeep ok" in out.getvalue(), "Block-Selbsttest meldet nicht ok: %s" % out.getvalue()[:200]
    assert ns["_PERF_PING_MAX_AGE"] == 90.0 and ns["_PERF_PING_T"] == [None]
    pc = ns["_perf_ping_cached"]
    st = [100.0]
    ds = {"ping": 12.5}
    assert pc(store=ds, stamp=st, now=190.0) == 12.5, "genau 90 s alt gilt noch als frisch"
    assert pc(store=ds, stamp=st, now=190.5) is None
    assert pc(store=ds, stamp=st, now=100.0) == 12.5
    assert pc(store=ds, stamp=st, now=99.9) is None, "Uhr zurueck -> nicht verwenden"
    assert pc(store=ds, stamp=[None], now=101.0) is None
    assert pc(store={}, stamp=st, now=101.0) is None
    assert pc(store={"ping": None}, stamp=st, now=101.0) is None
    assert pc(store={"ping": True}, stamp=st, now=101.0) is None
    assert pc(store={"ping": "12"}, stamp=st, now=101.0) is None
    assert pc(store={"ping": 0}, stamp=st, now=101.0) == 0
    assert pc(store=None, stamp=[None]) is None
    ns["data_store"]["ping"] = 7.0
    ns["_PERF_PING_T"][0] = time.monotonic()
    assert pc() == 7.0, "Standardaufruf nutzt data_store und den Zeitstempel"
    ns["_PERF_PING_T"][0] = time.monotonic() - 91
    assert pc() is None, "Standardaufruf: 91 s alt -> None"
    n += 1
    return n


def check(altdir, newdir, blk, ep):
    alt, new = rd(os.path.join(altdir, "dashboard.py")), rd(os.path.join(newdir, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = static(alt, new, blk)
    if os.environ.get("RH_PK_NOREV") != "1":
        assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau von Block und Stellen ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    assert rd(blk).rstrip("\n") in new
    compile(new, "dashboard.py", "exec")
    n += 1
    n += behav(alt, new)
    print("OK guard perfKeep: %d Pruefungen, 0 fehlerhaft" % n)
    return n


# ---------------- Mutationstest ----------------
# (Name, Zielzeichenfolge in dashboard.py, Ersatz, norev) - norev=1: der Mutant muss auch OHNE den Rueckbau-Vergleich erkannt werden (Regeln/Verhalten allein)
MUT = [
    ("M01 _keep_same liefert nie True", 'return bool(rec.get("payload") == payload)', "return False", 1),
    ("M02 _keep_same liefert immer True", 'return bool(rec.get("payload") == payload)', "return True", 1),
    ("M03 Zeitstempel nicht verglichen", ' or (rec.get("updated") or "") != (updated or ""):\n            return False', ":\n            return False", 1),
    ("M04 Schreibfehler-Merker ignoriert", "(_KEEP_DISK_BAD[0] if bad is None else bad)", "False", 1),
    ("M05 Merker bei Fehler nicht gesetzt", "        _KEEP_DISK_BAD[0] = True\n", "        pass\n", 1),
    ("M06 Merker nach Erfolg nicht geloescht", "        _KEEP_DISK_BAD[0] = False\n    except", "        pass\n    except", 1),
    ("M07 Heilung: Bedingung verneint", "if not _keep_same(key, payload if kind", "if _keep_same(key, payload if kind", 1),
    ("M08 Heilung: nie merken", "if not _keep_same(key, payload if kind", "if False and not _keep_same(key, payload if kind", 1),
    ("M09 Heilung: immer merken", "if not _keep_same(key, payload if kind", "if True or not _keep_same(key, payload if kind", 1),
    ("M10 Heilung: Recolor entfaellt", "                _keep_recolor(key, slot)\n                continue\n            mem = _KEEP_MEM.get(key)", "                continue\n            mem = _KEEP_MEM.get(key)", 1),
    ("M11 kept/_keepLastTs nicht abgezogen", 'if isinstance(payload, dict) and ("_keepLastTs" in payload or "kept" in payload):', "if False:", 1),
    ("M12 nur _keepLastTs abgezogen", '("_keepLastTs" in payload or "kept" in payload)', '("_keepLastTs" in payload)', 1),
    ("M13 Ausnahme liefert True", "    except Exception:\n        return False\n\ndef _keep_remember", "    except Exception:\n        return True\n\ndef _keep_remember", 1),
    ("M14 payload None gilt als gleich", "if payload is None or (_KEEP_DISK_BAD", "if payload is not None and (_KEEP_DISK_BAD", 1),
    ("M15 _keep_same schreibt selbst", "        return bool(rec.get(\"payload\") == payload)", "        print('x')\n        return bool(rec.get(\"payload\") == payload)", 1),
    ("M16 Grenze >= statt >", "if age < 0 or age > (_PERF_PING_MAX_AGE if max_age is None else max_age):", "if age < 0 or age >= (_PERF_PING_MAX_AGE if max_age is None else max_age):", 1),
    ("M17 Uhr zurueck nicht beachtet", "if age < 0 or age >", "if age >", 1),
    ("M18 bool als Ping erlaubt", "if isinstance(v, bool) or not isinstance(v, (int, float)):", "if not isinstance(v, (int, float)):", 1),
    ("M20 Hoechstalter 900 s", "_PERF_PING_MAX_AGE = 90.0", "_PERF_PING_MAX_AGE = 900.0", 1),
    ("M21 Zeitstempel in freq_loop fehlt", "                _PERF_PING_T[0] = time.monotonic()  # perfKeep: Zeitstempel der Messung\n", "", 1),
    ("M22 Zeitstempel mit time.time()", "_PERF_PING_T[0] = time.monotonic()  # perfKeep: Zeitstempel der Messung", "_PERF_PING_T[0] = time.time()  # perfKeep: Zeitstempel der Messung", 1),
    ("M23 /pi ohne Rueckfall fetch_ping", "        if ping is None:\n            ping = fetch_ping()\n    except Exception:\n        ping = data_store.get(\"ping\")\n    try:\n        public_ip", "    except Exception:\n        ping = data_store.get(\"ping\")\n    try:\n        public_ip", 1),
    ("M24 /pi immer fetch_ping zuerst", "ping = _perf_ping_cached()  # perfKeep", "ping = None  # perfKeep", 1),
    ("M25 /pi ohne Zwischenspeicher-Aufruf, direkt data_store", "ping = _perf_ping_cached()  # perfKeep", "ping = data_store.get('ping')  # perfKeep", 1),
    ("M26 /pi: fetch_ping zweimal", "            ping = fetch_ping()\n    except Exception:\n        ping = data_store.get(\"ping\")\n    try:\n        public_ip", "            ping = fetch_ping()\n        ping = fetch_ping()\n    except Exception:\n        ping = data_store.get(\"ping\")\n    try:\n        public_ip", 1),
    ("M27 Block-Selbsttest ohne Pruefung der Heilung", "assert same is True and tagged is True and diff_p is False and diff_t is False and nokey is False and badf is False", "assert True", 1),
    ("M28 Block meldet nicht ok", 'return "perfKeep ok (Heilung', 'return "perfKeep kaputt (Heilung', 1),
    ("M29 Netzzugriff im Block", "def _selftest_perfkeep():", "import subprocess\n\ndef _selftest_perfkeep():", 1),
    ("M30 _keep_same liest data_store", "        rec = (_KEEP_MEM if mem is None else mem).get(key)", "        rec = (_KEEP_MEM if mem is None else mem).get(key) or data_store.get(key)", 1),
    ("M31 stille Zusatzaenderung: Server-Start", "use_reloader=False, threaded=True)  # sysBoot", "use_reloader=True, threaded=True)  # sysBoot", 0),
    ("M32 stille Zusatzaenderung in _keep_heal_store", "            _keep_untag_slot(slot)\n            kind = \"value\"", "            kind = \"value\"", 0),
    ("M33 stille Zusatzaenderung in _keep_remember", "    _keep_strip_obj(blob)\n    if isinstance(blob, dict):", "    if isinstance(blob, dict):", 0),
    ("M34 stille Zusatzaenderung in freq_loop", "                data_store[\"internet\"] = {\n                    \"value\": True, \"status\": \"online\"", "                data_store[\"internet\"] = {\n                    \"value\": False, \"status\": \"online\"", 0),
    ("M35 stille Zusatzaenderung in fetch_ping", '["ping", "-c", "3", "-W", "2", "8.8.8.8"]', '["ping", "-c", "1", "-W", "2", "8.8.8.8"]', 0),
]


# aequivalente Mutanten: das Verhalten ist nachweislich gleich (Gitterbeweis ueber alle relevanten Eingaben), sie werden nicht als "uebersehen" gezaehlt
EQUIV = [
    ("A01 ohne ausdrueckliche Zeitstempel-Pruefung (None - Zahl wirft TypeError, vom except aufgefangen = None)", "        if t is None:\n            return None\n        age =", "        if False:\n            return None\n        age ="),
]


def equiv_proof(new, mut):
    def load(src):
        i, j = src.index("_PERF_PING_T = [None]"), src.index("def freq_loop():")
        ns = {"time": time, "data_store": {}}
        exec(compile(src[i:j], "perf_segment", "exec"), ns)
        return ns["_perf_ping_cached"]
    f0, f1 = load(new), load(mut)
    cases = 0
    for stamp in ([None], [100.0], [0.0]):
        for now in (-1.0, 99.0, 100.0, 150.0, 190.0, 190.5, 1e9):
            for ping in (None, True, False, 0, 12.5, "x", [], {}):
                for max_age in (None, 0.0, 50.0):
                    r0 = f0(store={"ping": ping}, stamp=stamp, now=now, max_age=max_age)
                    r1 = f1(store={"ping": ping}, stamp=stamp, now=now, max_age=max_age)
                    assert r0 == r1 and type(r0) is type(r1), "nicht aequivalent: %r %r %r %r" % (stamp, now, ping, max_age)
                    cases += 1
    return cases


def mutate(newdir, blk, ep):
    altdir = os.environ["RH_ALT"]
    base_new = rd(os.path.join(newdir, "dashboard.py"))
    bad = []
    done = 0
    for name, a, b, norev in MUT:
        w = tempfile.mkdtemp(prefix="pk-mut-")
        try:
            nd = os.path.join(w, "new")
            os.makedirs(nd)
            assert base_new.count(a) == 1, "%s: Stelle nicht eindeutig (%d)" % (name, base_new.count(a))
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(base_new.replace(a, b, 1))
            if norev:
                os.environ["RH_PK_NOREV"] = "1"
            else:
                os.environ.pop("RH_PK_NOREV", None)
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    check(altdir, nd, blk, ep)
                bad.append(name)
                print("UEBERSEHEN:", name)
            except BaseException as e:
                if isinstance(e, KeyboardInterrupt):
                    raise
                print("erkannt %s: %s" % (name, (type(e).__name__ + " " + str(e)).replace("\n", " ")[:90]))
            done += 1
        finally:
            os.environ.pop("RH_PK_NOREV", None)
            shutil.rmtree(w, ignore_errors=True)
    for name, a, b in EQUIV:
        assert base_new.count(a) == 1, name
        cases = equiv_proof(base_new, base_new.replace(a, b, 1))
        print("aequivalent bewiesen %s: Gitterbeweis, %d Faelle identisch" % (name[:3], cases))
    if bad:
        print("FEHLER: %d von %d Mutanten uebersehen: %s" % (len(bad), done, bad))
        return 1
    print("OK mutation perfKeep: %d Mutationen, %d erkannt, 0 uebersehen (+ %d aequivalent bewiesen)" % (done, done, len(EQUIV)))
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
        print("guard perfKeep FEHLER: %s" % e)
        sys.exit(1)
PK_RGD_EOF
PPK="$W/patch-pk.py"; RED="$W/edits_pk.py"; RBK="$W/blk_pk.py"; RGD="$W/guard_pk.py"
for x in "$EXPECT_PPK $PPK" "$EXPECT_RED $RED" "$EXPECT_RBK $RBK" "$EXPECT_RGD $RGD"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei $(basename "$2") falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (patch-pk.py, edits_pk.py, blk_pk.py, guard_pk.py)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
[[ -f "$F" ]] || stop "dashboard.py fehlt im Projektordner $DASH_DIR"
D16=$(s16 "$F")
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "bekannt ($2)"; return; }; shift 2; done; echo UNBEKANNT; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Basis nach relHygiene commit19b" "$KNOWN_D16N" "perfKeep schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      perfKeep passt nur auf den Stand nach relHygiene commit19b. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
grep -q '# ===== relHygiene:' "$F" || stop "relHygiene (commit19b) fehlt im Dashboard (Basis)"
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true)
  if [[ "$a" != active ]]; then [[ "$DRY" == 1 ]] && echo "HINWEIS Dienst $u ist nicht aktiv ($a) - im Trockenlauf unerheblich" || stop "Dienst $u ist nicht aktiv ($a)"; fi
done
SVCS="prepper-dashboard prepper-sdr mesh-bridge mesh-bridge-bayern"
declare -A AET0 ACT0
for u in $SVCS; do AET0[$u]=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true); ACT0[$u]=$(systemctl is-active "$u" 2>/dev/null || true); done
echo "Dienste vorher: $(for u in $SVCS; do printf '%s=%s ' "$u" "${ACT0[$u]}"; done)"
# andere Programmdateien: nur Vorher/Nachher-Vergleich
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$PPK" perfKeep dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer perfKeep nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" perfKeep dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
# AST-Guard: Rueckbau ergibt die bekannte Basis; dann Regeln, Verhalten (Differenztest alt/neu) und Mutationstest. Kein node noetig.
"$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: perfKeep im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne perfKeep ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
"$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard perfKeep meldet Verstoss"; }
cat "$W/g.log"
RH_ALT="$W/alt" "$VPY" "$RGD" mutate "$W/neu" "$RBK" "$RED" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "AST-Guard Mutationstest: eine Verfehlung wurde nicht erkannt (siehe Zeilen oben)"; }
grep -E "^aequivalent|^OK" "$W/gm.log" | cut -c1-240
# ---------- 3) Zustand vorher: Seiten, Zeiten (nur Lesen) ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
tm() { local t; t=$("${CURL[@]}" "$@" -o /dev/null -w "%{time_total}" || true); echo "${t:-?}"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
kl_stat() { stat -c '%Y.%y' "$KL" 2>/dev/null | cut -c1-60 || echo fehlt; }
kl_probe() { local m0 m1 i; [[ -f "$KL" ]] || { echo "keep-last.json fehlt"; return; }; m0=$(stat -c %y "$KL"); for i in 1 2 3 4 5; do "${CURL[@]}" "$B/api/time" -o /dev/null || true; done; m1=$(stat -c %y "$KL"); [[ "$m0" == "$m1" ]] && echo "nein (Aenderungszeit unveraendert)" || echo "ja (Aenderungszeit hat gewechselt)"; }
T0_TIME=$(tm "$B/api/time"); T0_ROOT=$(tm "$B/"); T0_PI=$(tm "$B/pi")
KL0=$( [[ -f "$KL" ]] && stat -c %s "$KL" || echo 0 )
echo "Zeiten vorher (Sekunden): /api/time $T0_TIME, / $T0_ROOT, /pi $T0_PI; keep-last.json ${KL0} Bytes; wird bei 5 Mini-Anfragen /api/time neu geschrieben: $(kl_probe)"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: perfKeep ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-perfkeep-ZEIT, letzte $KEEP_LAST), Neustart nur prepper-dashboard, eine sudo-Passwortabfrage."; fi
  echo "COMMIT $COMMIT_ARG perfkeep=dry fertig"
  exit 0
fi
[[ "$NEED_D" == 0 ]] || { sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; }
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
KEYS0=$("$SPY" -c "import json,sys;print(' '.join(sorted(json.load(open(sys.argv[1])).keys())))" "$KL" 2>/dev/null || echo "")
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "perfKeep|keepLast heal|Traceback" | tail -4 | cut -c1-200
  [[ -f "$F.bak-perfkeep-$TS" ]] && cp -a "$F.bak-perfkeep-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-perfkeep-$TS" ]] && { cmp -s "$F" "$F.bak-perfkeep-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK perfKeep schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-perfkeep-$TS"
  { ls -1t "$F.bak-perfkeep-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-perfkeep-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-perfkeep-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'perfKeep aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; perfKeep aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
# keep-last.json: gueltig, alle bisherigen Schluessel noch da
if [[ -f "$KL" ]]; then
  "$SPY" - "$KL" "$KEYS0" > "$W/kl.log" 2>&1 <<'PYE' || { cat "$W/kl.log"; rbx "keep-last.json ungueltig oder Schluessel fehlen"; }
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(d, dict)
old = set(sys.argv[2].split())
miss = sorted(old - set(d))
assert not miss, "Schluessel fehlen: %s" % miss
bad = [k for k, v in d.items() if not (isinstance(v, dict) and "payload" in v)]
assert not bad, "Eintraege ohne payload: %s" % bad
print("keep-last.json gueltig: %d Schluessel (vorher %d), alle bisherigen vorhanden" % (len(d), len(old)))
PYE
  echo "OK $(cat "$W/kl.log")"
else echo "HINWEIS keep-last.json fehlt (vor dem Patch auch nicht vorhanden?) - wird beim ersten Abruf angelegt"; fi
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E perfKeep"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "perfKeep aktiv: perfKeep ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-200)" || rbx "Journal prepper-dashboard ohne 'perfKeep aktiv: perfKeep ok' ($(echo "$JD" | grep -F perfKeep | tail -1 | cut -c1-200))"
    JR=$(echo "$JD" | grep -F "relHygiene aktiv: relHygiene ok" | tail -1 || true)
    [[ -n "$JR" ]] && echo "OK relHygiene weiter aktiv: $(echo "$JR" | cut -c1-120)" || rbx "Journal ohne 'relHygiene aktiv: relHygiene ok' (Regression)"
  fi
  E2=$(echo "$JD" | grep -c -E 'perfKeep Selbsttest FEHLER|keepLast heal:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne perfKeep-/keepLast-Heilungsfehler" || { echo "$JD" | grep -E 'perfKeep|keepLast heal:' | cut -c1-240; rbx "$E2 perfKeep-/Heilungsfehler im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein perfKeep-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | head -5 | cut -c1-200 | sed 's/^/   | /'; }
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
CNT=$(grep -c '# ===== perfKeep:' "$F" || true); CNR=$(grep -c '# ===== relHygiene:' "$F" || true)
[[ "$CNT" == 1 && "$CNR" == 1 ]] && echo "OK Marker perfKeep=$CNT relHygiene=$CNR in dashboard.py" || rbx "Marker perfKeep=$CNT relHygiene=$CNR"
# Zeiten nachher (nur Lesen; /pi-Ping-Zwischenspeicher fuellt sich erst, wenn freq_loop gelaufen ist)
sleep 5
T1_TIME=$(tm "$B/api/time"); T1_ROOT=$(tm "$B/"); T1_PI=$(tm "$B/pi")
echo "Zeiten nachher (Sekunden, direkt nach dem Neustart; Dashboard laedt noch im Hintergrund): /api/time $T1_TIME (vorher $T0_TIME), / $T1_ROOT (vorher $T0_ROOT), /pi $T1_PI (vorher $T0_PI)"
echo "keep-last.json wird bei 5 Mini-Anfragen /api/time neu geschrieben: $(kl_probe) (vorher: siehe oben)"
echo "Hinweis: nach etwa 1 bis 2 Minuten erneut messen (der Ping-Zwischenspeicher fuer /pi braucht einen Lauf von freq_loop): curl -s -o /dev/null -w %{time_total} $B/pi"
echo "OK Datenbank, Alarm-, Sende- und Abruflogik, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-perfkeep-$TS" ]] && echo "Backup: dashboard.py.bak-perfkeep-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-perfkeep-"* 2>/dev/null || true; } | head -1); [[ -n "$LB" ]] && echo "Rueckweg (neueste Sicherung: $(basename "$LB")): cp -a $LB $F ; sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine perfKeep-Sicherung vorhanden (nichts geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  curl -s -o /dev/null -w %{time_total} $B/api/time"
echo "  curl -s -o /dev/null -w %{time_total} $B/pi"
echo "  sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -c perfKeep"
echo "  ls -l --time-style=full-iso $KL"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG perfkeep=1 fertig"
