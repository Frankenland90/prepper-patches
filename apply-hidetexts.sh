#!/bin/bash
set -eEuo pipefail
# hideTexts (commit37): Lage-Seite ohne zwei Texte: (1) der ninaFix-Kachelhinweis 'Zertifikatskette: ... gepinnte Zwischenstelle genutzt' (nur der harmlose Rueckfall; echter Fehler und Ablaufwarnung < 90 Tage bleiben sichtbar), (2) die SDR-Rollen-Beschreibung 'Airspy R2 · 11D hoert fest BR24 ...' in der BR24-Kachel (Lage-Skript); nur die Anzeige, Daten (/api/br24 bc_note, /api/nina-cert), Journal und Rollen-Logik unveraendert
# Aufruf: bash /tmp/apply-hidetexts.sh commit37 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 8510b08e868edc46 (Stand nach ninaFix commit36) oder hideTexts schon drin (bb94f52af6e03c3b); sonst STOP mit beiden Werten, nichts geaendert.
# Sicherung: dashboard.py.bak-hidetexts-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts (kein Mesh, kein Telegram, keine Alarme). Keine neue Docs-Version (nur dashboard.py).
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/hidetexts-apply
KEEP_LAST=3
KNOWN_D16="8510b08e868edc46"      # dashboard.py vor hideTexts (Basis: Stand nach ninaFix commit36)
KNOWN_D16N="bb94f52af6e03c3b"             # dashboard.py nach hideTexts (Ziel)
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
echo "=== hideTexts apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): zwei Texte auf der Lage-Seite ausblenden, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt" "$W/pg"
EXPECT_PAL="e9eacee87cb25ffaac81b9d0ef84fa0868d951f9c3741154cd47a6a1d197e36c"
cat > "$W/patch.py" << 'MK_PAL_EOF'
"""Patcher hideTexts. Aufruf: patch-rw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
EXPECT_RAE="a0901a5dc19e74645bab7ffa23c4b0f15649ae35197afd4e64cbb4fb50ec20d5"
cat > "$W/edits.py" << 'MK_RAE_EOF'
# Stellen fuer hideTexts (commit37): Basis 8510b08e868edc46 (Stand nach ninaFix commit36)
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = [
    # 1) ninaFix-Kommentar im Kopf: Beschreibung der Anzeige an den neuen Stand anpassen
    ('# Anzeige: Kachel "NINA Warnungen" (Lage-Seite) zeigt "Zertifikatskette: ..." solange der Rueckfall genutzt wird oder die Kette nicht pruefbar ist; /api/nina-cert (nur GET).\n',
     '# Anzeige: Kachel "NINA Warnungen" (Lage-Seite) zeigt "Zertifikatskette: ..." nur noch bei einem echten Fehler (Kette nicht pruefbar) oder wenn die gepinnte Zwischenstelle in < 90 Tagen ablaeuft;\n'
     '#          die Nutzung des Rueckfalls allein ist harmlos und wird nicht mehr angezeigt (hideTexts); /api/nina-cert (nur GET) und die Journalzeilen zeigen sie weiter.\n'),
    # 2) _nina_cert_view: harmlosen Rueckfall-Hinweis (gelb) nicht mehr liefern; Fehler (rot) und Ablaufwarnung bleiben
    ('''        if _NF["fb_t"] is not None and 0 <= t - _NF["fb_t"] < NF_SHOW_S:
            return {"text": "Server sendet das Zwischenzertifikat nicht – gepinnte Zwischenstelle (Sectigo E36) genutzt", "color": "#eab308",
                    "title": "warnung.bund.de liefert die Kette unvollständig; die Prüfung bleibt voll (kein verify=False)"}
''',
     '''        # hideTexts: "Rueckfall genutzt" (gepinnte Zwischenstelle, Pruefung voll) ist der harmlose Normalfall -> keine Anzeige (Daten: /api/nina-cert, Journal)
'''),
    # 3) Selbsttest ninaFix an das neue Verhalten anpassen (Rueckfall genutzt: keine Anzeige)
    ('''        v = _nina_cert_view(6100.0)
        assert v and v["color"] == "#eab308" and "gepinnte" in v["text"], v
        assert _nina_cert_view(6000.0 + NF_SHOW_S + 1) is None
''',
     '''        assert _nina_cert_view(6100.0) is None, "Rueckfall genutzt: keine Anzeige"
        assert _nina_cert_view(6000.0 + NF_SHOW_S + 1) is None
'''),
    # 4) Lage-Seite: Beschreibungstext der SDR-Rollen (bc_note) nicht mehr in die BR24-Kachel schreiben (Daten /api/br24 bc_note bleiben)
    ("if(A&&A.note){var nt=t.querySelector('.sdl-note');if(!nt){nt=el('div','small sdl-note');t.insertBefore(nt,b);}nt.textContent=A.note;}", "/*hideTexts: keine Rollen-Beschreibung in der Kachel*/"),
]
MK_RAE_EOF
EXPECT_RAB="b91c733c4266c0487435955691cd3a98ec9a396e4975341c9ca1c160b32386dd"
cat > "$W/blk.py" << 'MK_RAB_EOF'
# ===== hideTexts: Lage-Seite ohne den Rueckfall-Hinweis "Zertifikatskette ..." und ohne die SDR-Rollen-Beschreibung in der BR24-Kachel (nur die Anzeige; Daten, API, Journal, Rollen-Logik unveraendert) =====
# Was: (1) _nina_cert_view (ninaFix) liefert fuer "Rueckfall genutzt" nichts mehr; ein echter Fehler (rot) und die Ablaufwarnung < 90 Tage bleiben sichtbar. /api/nina-cert und das Journal zeigen den Rueckfall weiter.
#      (2) Das Lage-Skript (_SD_LAGE_JS im Lage-Seiten-Skript _LM1_JS) schreibt den Text aus /api/br24 "bc_note" ("Airspy R2 · 11D hoert fest BR24 ...") nicht mehr in die Kachel. Das Feld bc_note in /api/br24 und _wd_bc_note() bleiben.
# Der Selbsttest prueft die laufenden Objekte (kein Netz, keine Dateien, Zustand von ninaFix wird gesichert und zurueckgesetzt).
def _selftest_hidetexts():
    js = globals().get("_LM1_JS")
    assert isinstance(js, str) and "sdl-css" in js and "fetch('/api/br24'" in js and "sdl-asa" in js, "Lage-Skript fehlt oder verstuemmelt"
    assert "A.note" not in js and "querySelector('.sdl-note')" not in js and "sdl-note'," not in js, "Lage-Skript schreibt die Rollen-Beschreibung noch"
    assert callable(globals().get("_wd_bc_note")) and callable(globals().get("_br24_state")), "bc_note-Quelle (Daten) fehlt"
    f = globals().get("_nina_cert_view")
    nf = globals().get("_NF")
    if f is None or not isinstance(nf, dict):
        return "hideTexts ok (Lage-Skript ohne Rollen-Beschreibung; ninaFix nicht da)"
    saved = {k: (dict(v) if isinstance(v, dict) else v) for k, v in nf.items() if k != "lock"}
    try:
        show, days = globals()["NF_SHOW_S"], globals()["NF_NOT_AFTER"]
        nf.update(fb_t=None, fb_n=0, fail=None)
        assert f(1000.0) is None
        nf.update(fb_t=1000.0, fb_n=1, fail=None)
        assert f(1100.0) is None, "Rueckfall genutzt: keine Anzeige"
        nf.update(fb_t=1000.0, fb_n=1, fail=(1000.0, "Datei fehlt"))
        v = f(1100.0)
        assert v and v["color"] == "#ef4444" and "Datei fehlt" in v["text"], "echter Fehler muss sichtbar bleiben"
        assert f(1000.0 + show + 1) is None
        nf.update(fb_t=None, fb_n=1, fail=None)
        v = f(days - 86400 * 10)
        assert v and "Tagen ab" in v["text"].replace("laeuft", "l\u00e4uft"), "Ablaufwarnung muss sichtbar bleiben"
    finally:
        for k, v in saved.items():
            nf[k] = v
    return "hideTexts ok (kein Rueckfall-Hinweis, keine Rollen-Beschreibung in der BR24-Kachel; Fehler und Ablaufwarnung bleiben sichtbar; Daten und API unveraendert)"


try:
    _HT_ST = _selftest_hidetexts()
except Exception as _ht_e:
    _HT_ST = None
    print("hideTexts Selbsttest FEHLER (%s: %s)" % (type(_ht_e).__name__, _ht_e), flush=True)
if _HT_ST:
    print("hideTexts aktiv: %s" % _HT_ST, flush=True)
# ===== /hideTexts =====
MK_RAB_EOF
EXPECT_RAG="f3a8b83602ede7484e97d2b6b1725443efc47c3c05214c604c4718dc3519aec7"
cat > "$W/guard.py" << 'MK_RAG_EOF'
"""AST-/Verhaltens-Guard hideTexts (nur dashboard.py: 4 Stellen + Block hideTexts). Aufruf:
  guard_ht.py revert NEU_VERZ ALT_VERZ BLOCK EDITS      -> ALT_VERZ/dashboard.py = NEU ohne hideTexts (Rueckbau, byte-genau)
  guard_ht.py check  ALT_VERZ NEU_VERZ BLOCK EDITS      -> statische Regeln + Verhaltenstests (ninaFix-Block mit Selbsttest, Kachelhinweis nur bei Fehler/Ablauf, Lage-Skript ohne Rollen-Beschreibung,
                                                           Block-Selbsttest schlaegt am alten Stand an, Jinja-Kachel, optional JS im node mit Attrappen-DOM, wenn node da ist)
  RH_ALT=ALT_VERZ guard_ht.py mutate NEU_VERZ BLOCK EDITS -> Mutationstest   (ohne node moeglich, ohne Netz, ohne Dienste)"""
import ast
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

FORBID = ("requests", "urlopen", "socket", "subprocess", "os.system", "send_meshtastic", "eval(", "exec(", "__import__", "curl", "sudo", "systemctl", "shell=True", "open(")
BLOCK_NODES = ["FunctionDef:_selftest_hidetexts", "Try:", "If:"]
CHANGED = sorted(["_SD_LAGE_JS", "_nina_cert_view", "_selftest_ninafix"])
NF_START, NF_END = "# ===== ninaFix:", "# ===== /ninaFix ====="


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def load_edits(ep):
    g = {}
    exec(compile(rd(ep), ep, "exec"), g)
    return g["DSH_EDITS"], g["DSH_ANCHOR"]


def revert_text(s, blk, edits):
    B = rd(blk).rstrip("\n")
    assert s.count("\n\n" + B) == 1, "Block hideTexts nicht genau einmal im Programm"
    s = s.replace("\n\n" + B, "", 1)
    for o, n in edits:
        assert s.count(n) == 1, "Stelle hideTexts nicht genau einmal: " + n.strip().splitlines()[0][:70]
        s = s.replace(n, o, 1)
    return s


def revert(newdir, altdir, blk, ep):
    edits, _ = load_edits(ep)
    s = revert_text(rd(os.path.join(newdir, "dashboard.py")), blk, edits)
    os.makedirs(altdir, exist_ok=True)
    with open(os.path.join(altdir, "dashboard.py"), "w", encoding="utf-8") as f:
        f.write(s)
    print("Rueckbau ok: Block weg, %d Stellen zurueck" % len(edits))


def check_block_text(B):
    t = ast.parse(B)
    kinds = [type(n).__name__ + ":" + getattr(n, "name", "") for n in t.body]
    assert kinds == BLOCK_NODES, "Blockaufbau weicht ab: %s" % kinds
    for w in FORBID:
        assert w not in B, "Block enthaelt verbotenes Wort: " + w
    for n in ast.walk(t):
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in ("eval", "exec", "__import__", "compile", "open", "setattr", "delattr"):
            raise AssertionError("Block ruft " + n.func.id)
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            raise AssertionError("Block importiert")
    assert B.splitlines()[0].startswith("# ===== hideTexts:") and B.rstrip().splitlines()[-1] == "# ===== /hideTexts =====", "Block ohne Marker"
    assert "hideTexts aktiv: %s" in B and "hideTexts Selbsttest FEHLER" in B, "Journalzeilen fehlen"


def gl(s, name):
    """Wert einer Modul-Zuweisung name = <Zeichenkette> aus dem Quelltext (ast, ohne auszufuehren)."""
    for n in ast.parse(s).body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and getattr(n.targets[0], "id", "") == name:
            return ast.literal_eval(n.value)
    raise AssertionError("Zuweisung fehlt: " + name)


def lage_js(s):
    """_LM1_JS (so wie ausgeliefert) = Grundskript + _SD_LAGE_JS."""
    return gl(s, "_LM1_JS") + gl(s, "_SD_LAGE_JS")


def nf_block(s):
    i, j = s.index(NF_START), s.index(NF_END) + len(NF_END)
    return s[i:j]


def static(alt, new, blk, edits):
    n = 0
    B = rd(blk).rstrip("\n")
    check_block_text(B)
    assert new.count("\n\n" + B + "\n\nif __name__ == \"__main__\":\n") == 1, "Block nicht direkt vor dem __main__-Block"
    assert new.index("# ===== /ninaFix =====") < new.index(B), "hideTexts muss nach ninaFix stehen"
    n += 3
    assert len(edits) == 4, "erwartet genau 4 Stellen"
    for o, nw in edits:
        assert alt.count(o) == 1, "Stelle nicht genau einmal im alten Stand"
        assert o != nw and nw != "", "Stelle ohne Wirkung/leer"
    n += 1
    bs = new.count("\n", 0, new.index(B)) + 1
    be = bs + B.count("\n")
    ta, tn = ast.parse(alt), ast.parse(new)
    N = [x for x in tn.body if not (bs <= x.lineno <= be)]
    assert len(tn.body) - len(N) == len(BLOCK_NODES), "Block hat nicht %d Knoten" % len(BLOCK_NODES)
    da = {ast.dump(x) for x in ta.body}
    ch = sorted((getattr(x, "name", None) or (x.targets[0].id if isinstance(x, ast.Assign) else "?")) for x in N if ast.dump(x) not in da)
    assert ch == CHANGED, "geaenderte/neue Knoten ausserhalb des Blocks: %s" % ch
    n += 2
    # Der Rest des Programms bleibt: Rollen-Logik und Daten (bc_note) unveraendert
    for nm in ("_wd_bc_note", "_br24_state"):
        fa = [ast.dump(x) for x in ast.walk(ta) if isinstance(x, ast.FunctionDef) and x.name == nm]
        fn = [ast.dump(x) for x in ast.walk(tn) if isinstance(x, ast.FunctionDef) and x.name == nm]
        assert fa and fa == fn, "Funktion %s hat sich geaendert" % nm
    assert new.count('r["bc_note"] = ') == 1 and new.count("note:j.bc_note") >= 1, "bc_note-Feld in der API/Seite fehlt"
    assert new.count("hört fest BR24 über DAB 11D") == alt.count("hört fest BR24 über DAB 11D"), "Rollen-Texte (Daten) veraendert"
    n += 3
    # Lage-Skript: nur die Note-Anweisung fehlt, sonst gleich
    ja, jn = gl(alt, "_SD_LAGE_JS"), gl(new, "_SD_LAGE_JS")
    assert "A.note" in ja and "A.note" not in jn and "sdl-note'" not in jn.replace(".sdl-note{margin", ""), "Lage-Skript: Note-Anweisung nicht entfernt"
    assert ja.replace(edits[3][0], edits[3][1]) == jn, "Lage-Skript weicht ausser der Note-Anweisung ab"
    for need in ("fetch('/api/br24'", "note:j.bc_note", "sdl-asa", "sdl-br", "setInterval(load,30000)"):
        assert need in jn, "Lage-Skript ohne " + need
    assert "POST" not in jn and "method" not in jn and jn.count("fetch(") == 1 and "</script" not in jn, "Lage-Skript: unzulaessige Zeichen"
    n += 3
    assert gl(new, "_LM1_JS") == gl(alt, "_LM1_JS"), "Grundskript der Lage-Seite veraendert"
    n += 1
    return n


# ---------- Verhaltenstests ----------
class FakeApp:
    def __init__(self):
        self.rules = []

    def add_url_rule(self, rule, endpoint=None, view_func=None, methods=None, **kw):
        self.rules.append((rule, endpoint, view_func, tuple(methods or ())))


def run_src(src, g, name):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(src, name, "exec"), g)
    return buf.getvalue()


def mk_ns(s, with_js=True):
    g = {"__name__": "ht_test", "app": FakeApp()}
    run_src(nf_block(s), g, "ninafix-block")
    assert g.get("_NF_ST"), "ninaFix-Block: Selbsttest nicht ok"
    g["_wd_bc_note"] = lambda: "x"
    g["_br24_state"] = lambda: {}
    if with_js:
        g["_LM1_JS"] = lage_js(s)
    return g


def view_table(g):
    f, nf = g["_nina_cert_view"], g["_NF"]
    show, nad = g["NF_SHOW_S"], g["NF_NOT_AFTER"]
    saved = {k: (dict(v) if isinstance(v, dict) else v) for k, v in nf.items() if k != "lock"}
    out = {}
    try:
        nf.update(fb_t=None, fb_n=0, fail=None)
        out["normal"] = f(1000.0)
        nf.update(fb_t=1000.0, fb_n=1, fail=None)
        out["rueckfall"] = f(1100.0)
        out["rueckfall_alt"] = f(1000.0 + show + 1)
        nf.update(fb_t=1000.0, fb_n=1, fail=(1000.0, "Datei fehlt"))
        out["fehler"] = f(1100.0)
        out["fehler_alt"] = f(1000.0 + show + 1)
        nf.update(fb_t=None, fb_n=1, fail=None)
        out["ablauf"] = f(nad - 86400 * 10)
        out["kein_ablauf"] = f(nad - 86400 * 400)
    finally:
        for k, v in saved.items():
            nf[k] = v
    return out


def behav(alt, new, blk, edits):
    n = 0
    B = rd(blk)
    # 1) Neuer Stand: ninaFix-Block samt (angepasstem) Selbsttest ok; hideTexts-Block aktiv und sauber
    g = mk_ns(new)
    t = view_table(g)
    assert t["normal"] is None and t["rueckfall"] is None and t["rueckfall_alt"] is None and t["fehler_alt"] is None and t["kein_ablauf"] is None, t
    assert t["fehler"] and t["fehler"]["color"] == "#ef4444" and "Datei fehlt" in t["fehler"]["text"], t
    assert t["ablauf"] and t["ablauf"]["color"] == "#eab308" and "10 Tagen" in t["ablauf"]["text"].replace("laeuft", "läuft"), t
    n += 3
    snap = {k: (dict(v) if isinstance(v, dict) else v) for k, v in g["_NF"].items() if k != "lock"}
    out = run_src(B, g, "hidetexts-block")
    assert g.get("_HT_ST") and "hideTexts aktiv: hideTexts ok" in out and "FEHLER" not in out, out
    assert {k: (dict(v) if isinstance(v, dict) else v) for k, v in g["_NF"].items() if k != "lock"} == snap, "Block hat den ninaFix-Zustand veraendert"
    n += 2
    # 2) Alter Stand: dieselbe Tabelle zeigt den Rueckfall-Hinweis; der Selbsttest des Blocks schlaegt an (Wachhund)
    ga = mk_ns(alt)
    ta = view_table(ga)
    assert ta["rueckfall"] and ta["rueckfall"]["color"] == "#eab308" and "gepinnte Zwischenstelle (Sectigo E36) genutzt" in ta["rueckfall"]["text"], "Kontrolle alter Stand"
    out = run_src(B, ga, "hidetexts-block-alt")
    assert ga.get("_HT_ST") is None and "hideTexts Selbsttest FEHLER" in out, "Block-Selbsttest haette am alten Stand anschlagen muessen: " + out
    n += 2
    # 2b) nur Kachel-Teil alt (Lage-Skript neu): Selbsttest schlaegt an; nur Skript alt (Kachel neu): schlaegt an
    gm = mk_ns(new)
    gm["_LM1_JS"] = lage_js(alt)
    assert "FEHLER" in run_src(B, gm, "hidetexts-js-alt") and gm.get("_HT_ST") is None, "Selbsttest haette das alte Lage-Skript melden muessen"
    gk = mk_ns(alt)
    gk["_LM1_JS"] = lage_js(new)
    assert "FEHLER" in run_src(B, gk, "hidetexts-kachel-alt") and gk.get("_HT_ST") is None, "Selbsttest haette die alte Kachel melden muessen"
    n += 2
    # 2c) Wachhund: der Selbsttest muss jeden ueberblendeten Fall einzeln melden (alles, nur Fehler, nur Ablaufwarnung versteckt; Lage-Skript ohne ASA-Zeile)
    for nm, hide in (("alles versteckt", lambda nf: True), ("nur der Fehler versteckt", lambda nf: bool(nf["fail"])), ("nur die Ablaufwarnung versteckt", lambda nf: not nf["fail"])):
        gx = mk_ns(new)
        gx["_nina_cert_view"] = (lambda now=None, o=gx["_nina_cert_view"], gg=gx, h=hide: None if h(gg["_NF"]) else o(now))
        assert "FEHLER" in run_src(B, gx, "hidetexts-wachhund") and gx.get("_HT_ST") is None, "Selbsttest haette '%s' melden muessen" % nm
    gj = mk_ns(new)
    gj["_LM1_JS"] = lage_js(new).replace("sdl-asa", "sdl-xx")
    assert "FEHLER" in run_src(B, gj, "hidetexts-wachhund-js") and gj.get("_HT_ST") is None, "Selbsttest haette das Lage-Skript ohne ASA-Zeile melden muessen"
    n += 4
    # 3) ohne ninaFix: Block meldet ok ohne Kachel-Teil
    gn = {"__name__": "ht_test2", "app": FakeApp(), "_LM1_JS": lage_js(new), "_wd_bc_note": lambda: "x", "_br24_state": lambda: {}}
    out = run_src(B, gn, "hidetexts-ohne-ninafix")
    assert gn.get("_HT_ST") and "ninaFix nicht da" in gn["_HT_ST"], out
    n += 1
    # 4) Lage-Skript: String-Ebene
    js = lage_js(new)
    assert "A.note" not in js and "sdl-asa" in js
    n += 1
    # 5) Jinja-Kachel: Hinweiszeile erscheint nur bei einem Wert (Fehler/Ablauf), nie beim Rueckfall
    import jinja2
    m = re.search(r"\{% if nina_cert %\}.*?\{% endif %\}", new, re.S)
    assert m, "Kachelzeile nicht gefunden"
    tpl = jinja2.Environment(autoescape=True).from_string(m.group(0))
    assert tpl.render(nina_cert=t["rueckfall"]).strip() == "" and "Zertifikatskette" not in tpl.render(nina_cert=t["rueckfall"])
    assert "Zertifikatskette" in tpl.render(nina_cert=t["fehler"]) and "Datei fehlt" in tpl.render(nina_cert=t["fehler"])
    assert "Zertifikatskette" in tpl.render(nina_cert=t["ablauf"])
    n += 3
    return n


NODE_TEST = r"""
class N{constructor(t){this.tagName=String(t).toUpperCase();this.children=[];this.parentNode=null;this.style={};this.dataset={};this._a={};this.className='';this.id='';this._t='';
 const o=this;this.classList={add:function(c){if(o.className.split(' ').indexOf(c)<0)o.className+=(o.className?' ':'')+c;}};}
 get textContent(){return this._t+this.children.map(c=>c.textContent).join('');}
 set textContent(v){this._t=String(v);this.children=[];}
 appendChild(c){c.remove();c.parentNode=this;this.children.push(c);return c;}
 insertBefore(c,r){c.remove();c.parentNode=this;const i=r?this.children.indexOf(r):-1;if(i<0)this.children.push(c);else this.children.splice(i,0,c);return c;}
 remove(){if(this.parentNode){const i=this.parentNode.children.indexOf(this);if(i>=0)this.parentNode.children.splice(i,1);this.parentNode=null;}}
 get nextSibling(){if(!this.parentNode)return null;const i=this.parentNode.children.indexOf(this);return this.parentNode.children[i+1]||null;}
 getAttribute(k){return k==='style'?(this._a.style||''):(k in this._a?this._a[k]:null);}
 setAttribute(k,v){this._a[k]=String(v);}
 m(sel){return sel.split(',').some(s=>{s=s.trim();if(s==='*')return true;if(s[0]==='.')return this.className.split(' ').indexOf(s.slice(1))>=0;return this.tagName===s.toUpperCase();});}
 all(sel,out){for(const c of this.children){if(c.m(sel))out.push(c);c.all(sel,out);}return out;}
 querySelectorAll(sel){return this.all(sel,[]);}
 querySelector(sel){return this.all(sel,[])[0]||null;}
 closest(sel){let e=this;while(e){if(e.m(sel))return e;e=e.parentNode;}return null;}
}
const root=new N('body');const head=new N('head');root.appendChild(head);
const doc={head:head,createElement:t=>new N(t),querySelectorAll:s=>root.querySelectorAll(s)};
function byId(id){let r=null;(function w(n){if(n.id===id)r=n;n.children.forEach(w);})(root);return r;}
doc.getElementById=byId;
const wrap=new N('div');root.appendChild(wrap);
const nina=new N('div');nina.className='card';const nt=new N('div');nt.className='title';nt.textContent='NINA Warnungen';nina.appendChild(nt);wrap.appendChild(nina);
const tile=new N('div');tile.className='card';tile.id='br24Tile';const tt=new N('div');tt.className='title';tt.textContent='BR24 Warnungen';tile.appendChild(tt);
const ln=new N('div');ln.className='lm1-line online';ln.setAttribute('style','color:#22c55e');ln.textContent='BR24 empfangen · DAB 11D · zuletzt 13.10.2026 12:50:00';tile.appendChild(ln);
const up=new N('div');up.className='small lm1-upd';tile.appendChild(up);wrap.appendChild(tile);
const payload={asa_row:{state:'gruen',l1:'ASA DE · ok',l2:'zuletzt 12:00 · nächste Prüfung 12:30'},br24_row:{state:'gruen',l1:'BR24 empfangen · DAB 11D',l2:'zuletzt 12:50 · prüft gerade'},bc_note:process.argv[2]};
const fetchStub=()=>Promise.resolve({json:()=>Promise.resolve(payload)});
const code=require('fs').readFileSync(process.argv[3],'utf8');
new Function('document','fetch','setInterval',code)(doc,fetchStub,function(){return 0;});
setTimeout(function(){
  const all=root.all('*',[]);
  console.log(JSON.stringify({noteEls:all.filter(e=>e.className.indexOf('sdl-note')>=0).length,rows:all.filter(e=>e.className.indexOf('sdl-row')>=0).map(e=>e.className),
    hasNoteText:root.textContent.indexOf(process.argv[2])>=0,tileText:tile.textContent}));
},80);
"""


def node_test(js, note, node):
    d = tempfile.mkdtemp(prefix="ht-node-")
    try:
        with open(os.path.join(d, "t.js"), "w", encoding="utf-8") as f:
            f.write(NODE_TEST)
        with open(os.path.join(d, "lage.js"), "w", encoding="utf-8") as f:
            f.write(js)
        r = subprocess.run([node, os.path.join(d, "t.js"), note, os.path.join(d, "lage.js")], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, "node-Test: " + (r.stderr or r.stdout)[:300]
        return json.loads(r.stdout.strip().splitlines()[-1])
    finally:
        shutil.rmtree(d, ignore_errors=True)


NOTE = "Airspy R2 · 11D hört fest BR24 über DAB 11D (Gain-Leiter + Daten-Watchdog); Stick 1 · 5C hört fest ASA DE über DAB 5C (Rückfall 10C)"


def js_behav(alt, new):
    node = shutil.which("node")
    if not node:
        print("HINWEIS guard hideTexts: node nicht vorhanden - JS-Verhaltenstest uebersprungen (Zeichenketten-Pruefungen gelten)")
        return 0
    ja = node_test(lage_js(alt), NOTE, node)
    assert ja["hasNoteText"] and ja["noteEls"] == 1, "Kontrolle: das alte Lage-Skript muss die Beschreibung zeigen (Testaufbau): %s" % ja
    jn = node_test(lage_js(new), NOTE, node)
    assert not jn["hasNoteText"] and jn["noteEls"] == 0 and "hört fest" not in jn["tileText"], "neues Lage-Skript zeigt die Beschreibung noch: %s" % jn
    assert len(jn["rows"]) == 2 and any("sdl-br" in r for r in jn["rows"]) and any("sdl-asa" in r for r in jn["rows"]), "BR24-/ASA-Zeile fehlen: %s" % jn
    assert "BR24 empfangen" in jn["tileText"] and "ASA DE" in jn["tileText"], jn
    return 4


def check(altd, newd, blk, ep):
    alt, new = rd(os.path.join(altd, "dashboard.py")), rd(os.path.join(newd, "dashboard.py"))
    edits, _ = load_edits(ep)
    n = static(alt, new, blk, edits)
    assert revert_text(new, blk, edits) == alt, "Aenderungsumfang: Rueckbau ergibt nicht den alten Stand (stille Zusatzaenderung)"
    n += 1
    n += behav(alt, new, blk, edits)
    n += js_behav(alt, new)
    print("OK guard hideTexts: %d Pruefungen, 0 fehlerhaft" % n)


# ---------- Mutationstest ----------
def mutate(newd, blk, ep):
    altd = os.environ.get("RH_ALT")
    assert altd, "RH_ALT fehlt"
    alt, new = rd(os.path.join(altd, "dashboard.py")), rd(os.path.join(newd, "dashboard.py"))
    B0 = rd(blk)
    edits, _ = load_edits(ep)
    muts = []

    def M(name, fn_new=None, fn_blk=None):
        muts.append((name, fn_new, fn_blk))

    for i, (o, nw) in enumerate(edits):
        M("E%d Stelle zurueckgenommen" % (i + 1), lambda s, o=o, nw=nw: s.replace(nw, o, 1))
    M("M6 stille Zusatzaenderung", lambda s: s.replace("def _nf_days_left(now=None):", "def _nf_days_left(now=None):  # x", 1))
    # Ueberblenden: zu viel versteckt
    M("T1 Fehler (rot) auch versteckt", lambda s: s.replace('''        if f and 0 <= t - f[0] < NF_SHOW_S:
            return {"text": "Zwischenzertifikat''', '''        if False and f and 0 <= t - f[0] < NF_SHOW_S:
            return {"text": "Zwischenzertifikat''', 1))
    M("T2 Ablaufwarnung auch versteckt", lambda s: s.replace('if _NF["fb_n"] and d < NF_WARN_DAYS:\n            return {"text": "gepinnte', 'if False and _NF["fb_n"] and d < NF_WARN_DAYS:\n            return {"text": "gepinnte', 1))
    M("T3 Fehlertext veraendert", lambda s: s.replace("Zwischenzertifikat nicht prüfbar (%s)", "Hinweis (%s)", 1))
    M("T4 Rueckfall wieder gelb (Text anders)", lambda s: s.replace("        # hideTexts: \"Rueckfall genutzt\"", "        if _NF[\"fb_t\"] is not None and 0 <= t - _NF[\"fb_t\"] < NF_SHOW_S:\n            return {\"text\": \"Rueckfall\", \"color\": \"#eab308\", \"title\": \"x\"}\n        # hideTexts: \"Rueckfall genutzt\"", 1))
    M("T5 Kachelzeile (Jinja) entfernt", lambda s: s.replace('{% if nina_cert %}', '{% if False %}', 1))
    M("T6 ninaFix-Selbsttest erwartet noch gelb", lambda s: s.replace('assert _nina_cert_view(6100.0) is None, "Rueckfall genutzt: keine Anzeige"', 'v = _nina_cert_view(6100.0)\n        assert v and v["color"] == "#eab308"', 1))
    # Lage-Skript: zu viel entfernt / kaputt
    M("J1 ASA-Zeile mit entfernt", lambda s: s.replace("var Q=A&&A.asa;if(Q&&Q.l1){b.parentNode.insertBefore(row('sdl-asa',Q.state||'grau',Q.l1,Q.l2||''),b.nextSibling);}", "", 1))
    M("J2 Daten-Abruf entfernt", lambda s: s.replace("function load(){fetch('/api/br24'", "function load(){var fetch2=('/api/br24'", 1))
    M("J3 Note per anderer Schreibweise", lambda s: s.replace("/*hideTexts: keine Rollen-Beschreibung in der Kachel*/", "if(A&&A['note']){t.insertBefore(el('div','small sdl-note',A['note']),b);}", 1))
    M("J4 BR24-Zeile entfernt", lambda s: s.replace("var b=row('sdl-br',st,p[0]||'BR24',p[1]);", "var b=row('sdl-xx',st,p[0]||'BR24',p[1]);", 1))
    # Daten/Logik beruehrt
    M("D1 bc_note-Feld aus der API entfernt", lambda s: s.replace('    r["bc_note"] = globals().get("_wd_bc_note"', '    r["bc_x"] = globals().get("_wd_bc_note"', 1))
    M("D2 Rollen-Text veraendert", lambda s: s.replace("%s hört fest BR24 über DAB 11D (Gain-Leiter + Daten-Watchdog)", "%s BR24 (11D)", 1))
    # Block
    M("B1 Selbsttest prueft das Skript nicht", None, lambda b: b.replace('assert "A.note" not in js and "querySelector(\'.sdl-note\')" not in js and "sdl-note\',"  not in js,', "assert True,").replace('assert "A.note" not in js and "querySelector(\'.sdl-note\')" not in js and "sdl-note\'," not in js,', "assert True,", 1))
    M("B2 Selbsttest prueft Rueckfall nicht", None, lambda b: b.replace('assert f(1100.0) is None, "Rueckfall genutzt: keine Anzeige"', "pass", 1))
    M("B3 Selbsttest prueft Fehlersichtbarkeit nicht", None, lambda b: b.replace('assert v and v["color"] == "#ef4444" and "Datei fehlt" in v["text"], "echter Fehler muss sichtbar bleiben"', "pass", 1))
    M("B4 Selbsttest prueft Ablaufwarnung nicht", None, lambda b: b.replace('assert v and "Tagen ab" in v["text"].replace("laeuft", "l\\u00e4uft"), "Ablaufwarnung muss sichtbar bleiben"', "pass", 1))
    M("B5 ninaFix-Zustand nicht zurueckgesetzt", None, lambda b: b.replace("            nf[k] = v\n", "            pass\n", 1))
    M("B6 Selbsttest schluckt Fehler", None, lambda b: b.replace("except Exception as _ht_e:\n    _HT_ST = None", "except Exception as _ht_e:\n    _HT_ST = 'ok'", 1))
    M("B7 Block mit eval", None, lambda b: b.replace('    js = globals().get("_LM1_JS")', '    eval("1")\n    js = globals().get("_LM1_JS")', 1))
    M("B8 Block ohne Ende-Marker", None, lambda b: b.replace("# ===== /hideTexts =====", "", 1))
    M("B9 Block sendet Netz", None, lambda b: b.replace('    js = globals().get("_LM1_JS")', '    import requests\n    js = globals().get("_LM1_JS")', 1))
    M("B10 Block prueft bc_note-Quelle nicht (gleichwertig?) / ohne Journalzeile", None, lambda b: b.replace('print("hideTexts aktiv: %s" % _HT_ST, flush=True)', "pass", 1))
    M("B11 Lage-Skript-Pruefung nur ASA nicht", None, lambda b: b.replace(' and "sdl-asa" in js', "", 1).replace(' "sdl-asa" in js', "", 1) if False else b.replace("and \"sdl-asa\" in js, \"Lage-Skript fehlt", ", \"Lage-Skript fehlt", 1))
    muts_ok = 0
    miss = []
    d = tempfile.mkdtemp(prefix="ht-mut-")
    try:
        for name, fn_new, fn_blk in muts:
            s2 = fn_new(new) if fn_new else new
            b2 = fn_blk(B0) if fn_blk else B0
            if s2 == new and b2 == B0:
                print("UEBERSEHEN (Mutant aendert nichts, Test kaputt):", name)
                miss.append(name)
                continue
            if fn_blk:
                s2 = s2.replace(B0.rstrip("\n"), b2.rstrip("\n"), 1)
            nd, bp = os.path.join(d, "n"), os.path.join(d, "blk.py")
            os.makedirs(nd, exist_ok=True)
            with open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8") as f:
                f.write(s2)
            with open(bp, "w", encoding="utf-8") as f:
                f.write(b2)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    check(altd, nd, bp, ep)
                print("UEBERSEHEN", name)
                miss.append(name)
            except BaseException as e:
                muts_ok += 1
                print("erkannt %s: %s %s" % (name, type(e).__name__, str(e)[:110].replace("\n", " ")))
    finally:
        shutil.rmtree(d, ignore_errors=True)
    if miss:
        print("FEHLER mutation hideTexts: %d von %d uebersehen: %s" % (len(miss), len(muts), miss))
        raise SystemExit(1)
    print("OK mutation hideTexts: %d Mutationen, %d erkannt, 0 uebersehen" % (len(muts), muts_ok))


if __name__ == "__main__":
    a = sys.argv[1:]
    try:
        if a and a[0] == "revert":
            revert(*a[1:5])
        elif a and a[0] == "check":
            check(*a[1:5])
        elif a and a[0] == "mutate":
            mutate(*a[1:4])
        else:
            print(__doc__)
            raise SystemExit(2)
    except AssertionError as e:
        print("guard hideTexts FEHLER:", e)
        raise SystemExit(1)
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
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(lbl "$D16" "$KNOWN_D16" "Stand nach ninaFix commit36" "$KNOWN_D16N" "hideTexts schon drin"))"
if [[ "$D16" != "$KNOWN_D16" && "$D16" != "$KNOWN_D16N" ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16, erwartet $KNOWN_D16 oder $KNOWN_D16N) - nichts geaendert."
  echo "      hideTexts passt nur auf den Stand Stand nach ninaFix commit36 (dashboard.py 8510b08e868edc46). Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug nicht"
# ---- hideTexts: Neustart-Fenster rund um die Wetter-Slots (3-h-Takt 0,3,...,21 Uhr, Berlin) ----
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
    elif [[ "$D16" == "$KNOWN_D16N" ]]; then echo "OK Neustart-Fenster: hideTexts ist schon installiert, es wird kein Neustart gebraucht"
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
python3 "$PPK" hideTexts dsh "$F" "$W/work/dashboard.py" "$RBK" "$RED" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer hideTexts nicht eindeutig (Datei vom Standard abweichend)"; }
ND16=$(s16 "$W/work/dashboard.py")
[[ "$ND16" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $ND16 statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $ND16 ($(wc -l < "$W/work/dashboard.py") Zeilen, $(cat "$W/q.log"))"
python3 "$PPK" hideTexts dsh "$W/work/dashboard.py" "$W/work/x.py" "$RBK" "$RED" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || stop "dashboard.py nicht idempotent (zweite Anwendung aendert die Datei)"
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$PPK" "$RED" "$RBK" "$RGD"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (dashboard.py, Block, Pruefprogramm; $SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/dashboard.py"
nice -n 10 "$VPY" "$RGD" revert "$W/neu" "$W/alt" "$RBK" "$RED" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "AST-Guard: hideTexts im Zielstand nicht sauber entfernbar"; }
cat "$W/g0.log"
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "AST-Guard: Stand ohne hideTexts ist nicht die bekannte Basis ($(s16 "$W/alt/dashboard.py") statt $KNOWN_D16)"
nice -n 10 "$VPY" "$RGD" check "$W/alt" "$W/neu" "$RBK" "$RED" > "$W/g.log" 2>&1 || { cat "$W/g.log"; stop "AST-Guard hideTexts meldet Verstoss"; }
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
# ---- hideTexts: Zustand vorher (nur Lesen): Zeichen der beiden Texte je Seite, Datenfeld bc_note in /api/br24 ----
htcount() { "${CURL[@]}" "$B$1" 2>/dev/null | grep -o 'A\.note\|sdl-note\|Zertifikatskette' | sort | uniq -c | tr -s ' ' | tr '\n' ',' || true; }
declare -A HT0
for p in / /funk /pi /rundfunk /umwelt; do HT0[$p]=$(htcount "$p"); done
echo "Zustand vorher (Zaehlung A.note/sdl-note/Zertifikatskette je Seite): $(for p in / /funk /pi /rundfunk /umwelt; do printf '%s=[%s] ' "$p" "${HT0[$p]}"; done)"
"${CURL[@]}" "$B/api/br24" -o "$W/br24_0.json" || true
HTBC0=$(python3 - "$W/br24_0.json" <<'PY' 2>/dev/null || echo "?"
import sys, json
j = json.load(open(sys.argv[1]))
print("ja" if "bc_note" in j and isinstance(j.get("bc_note"), str) else "nein")
PY
)
echo "Zustand vorher: /api/br24 hat das Feld bc_note: $HTBC0"
wxcheck "vor dem Neustart"
NEED_D=0; cmp -s "$W/work/dashboard.py" "$F" || NEED_D=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED_D" == 0 ]]; then echo "  Zustand: hideTexts ist schon installiert - ein echter Lauf aendert nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-hidetexts-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, dann pruefen (eine sudo-Passwortabfrage fuer Neustart und Journal)."; fi
  echo "COMMIT $COMMIT_ARG hidetexts=dry fertig"
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
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "hideTexts|Traceback" | tail -6 | cut -c1-240
  [[ -f "$F.bak-hidetexts-$TS" ]] && cp -a "$F.bak-hidetexts-$TS" "$F.rb" && mv -f "$F.rb" "$F"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  [[ -f "$F.bak-hidetexts-$TS" ]] && { cmp -s "$F" "$F.bak-hidetexts-$TS" && echo "  dashboard.py = Sicherung ($(s16 "$F"))" || echo "  WARNUNG dashboard.py ungleich Sicherung"; }
  echo "  Datenbank wurde nicht veraendert (keine SQLite-Sicherung noetig)"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "$NEED_D" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED_D" == 0 ]]; then
  echo "OK hideTexts schon installiert - kein Neustart, keine Aenderung"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  cp -a "$F" "$F.bak-hidetexts-$TS"
  { ls -1t "$F.bak-hidetexts-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-hidetexts-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-hidetexts-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst) - warte auf HTTP 200 (max 240 s) und die Zeile 'hideTexts aktiv' im Journal ..."
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
[[ "$R1" == "$R0" && "$P1" == "$P0" ]] && echo "OK /pi: Sicherung und Projektbeschreibung wie vorher (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung)" || echo "HINWEIS /pi: Zaehlung doPrepperRestore $R0/$R1, Projektbeschreibung $P0/$P1 (vorher/nachher) weicht ab - ein Dateistand (Sicherungen/Beschreibungen) kann sich zwischendurch geaendert haben; hideTexts aendert diese Kacheln nicht"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c1" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c1 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin auf Probe-Pfad -> 403, GET -> 200)"
# ---- hideTexts: Marker, Lage-Seite ohne die Texte, andere Seiten unveraendert, Daten (bc_note, /api/nina-cert) unveraendert ----
HTM=$(grep -c "^# ===== hideTexts:" "$F" || true); HTN=$(grep -c 'if(A&&A\.note)' "$F" || true)
[[ "$HTM" == 1 && "$HTN" == 0 ]] && echo "OK Marker hideTexts 1x im Programm, die Anweisung 'if(A&&A.note)' (Rollen-Beschreibung im Lage-Skript) kommt nicht mehr vor" || rbx "Marker/Lage-Skript hideTexts falsch (Marker $HTM, A.note $HTN)"
htcount() { "${CURL[@]}" "$B$1" 2>/dev/null | grep -o 'A\.note\|sdl-note\|Zertifikatskette' | sort | uniq -c | tr -s ' ' | tr '\n' ',' || true; }
"${CURL[@]}" "$B/" -o "$W/lage_ht.html" || true
HTA=$(grep -c 'A\.note' "$W/lage_ht.html" || true); HTS=$(grep -c "sdl-css" "$W/lage_ht.html" || true)
if [[ "$HTS" -ge 1 ]]; then
  [[ "$HTA" == 0 ]] && echo "OK Lage-Seite: Lage-Skript da, schreibt keine Rollen-Beschreibung mehr (A.note 0x)" || rbx "Lage-Seite enthaelt noch 'A.note' (${HTA}x)"
else echo "HINWEIS Die Lage-Seite liefert das Lage-Skript noch nicht (Ladehinweis nach dem Neustart?) - Programmtext ist geprueft (A.note 0x); die Seite spaeter laden und pruefen: curl -s $B/ | grep -c A.note"; fi
if grep -q 'id="nina-cert"' "$W/lage_ht.html" 2>/dev/null; then
  HTT=$(grep -o 'id="nina-cert"[^>]*>[^<]*' "$W/lage_ht.html" | head -1 | sed 's/^[^>]*>//' | cut -c1-160)
  case "$HTT" in *"gepinnte Zwischenstelle (Sectigo E36) genutzt"*) rbx "Lage-Seite zeigt den Rueckfall-Hinweis noch: $HTT" ;; *) echo "HINWEIS Lage-Seite zeigt einen echten Zertifikatskette-Hinweis (bleibt bewusst sichtbar): '$HTT'" ;; esac
else echo "OK Lage-Seite: kein Zertifikatskette-Hinweis"; fi
for p in /funk /pi /rundfunk /umwelt; do
  H1=$(htcount "$p")
  [[ "$H1" == "${HT0[$p]}" ]] && echo "OK $p unveraendert (Zaehlung [$H1])" || echo "HINWEIS $p Zaehlung vorher [${HT0[$p]}] nachher [$H1] - Seite aendert sich im Betrieb; hideTexts aendert sie nicht"
done
"${CURL[@]}" "$B/api/br24" -o "$W/br24_1.json" || true
HTBC1=$(python3 - "$W/br24_1.json" <<'PY' 2>/dev/null || echo "?"
import sys, json
j = json.load(open(sys.argv[1]))
print("ja" if "bc_note" in j and isinstance(j.get("bc_note"), str) else "nein")
PY
)
[[ "$HTBC1" == "$HTBC0" && "$HTBC1" != "?" ]] && echo "OK /api/br24: Feld bc_note wie vorher ($HTBC1) - Daten und Rollen-Logik unveraendert" || rbx "/api/br24: bc_note vorher $HTBC0, nachher $HTBC1"
"${CURL[@]}" "$B/api/nina-cert" -o "$W/nc_ht.json" || true
HTNC=$(python3 - "$W/nc_ht.json" <<'PY' 2>/dev/null || echo "NOK unlesbar"
import sys, json
j = json.load(open(sys.argv[1]))
print(("OK" if j.get("hosts") == ["warnung.bund.de"] and "mode" in j else "NOK"), "mode=%s pin_ok=%s plain_n=%s fallback_n=%s" % (j.get("mode"), j.get("pin_ok"), j.get("plain_n"), j.get("fallback_n")))
PY
)
case "$HTNC" in OK*) echo "OK /api/nina-cert weiter da und gueltig (Daten unveraendert): ${HTNC#OK }" ;; *) rbx "/api/nina-cert nicht in Ordnung nach hideTexts ($HTNC)" ;; esac
case "$HTNC" in *"pin_ok=False"*) echo "HINWEIS /api/nina-cert meldet pin_ok=False (Zertifikatsdatei certs/sectigo-e36.pem fehlt oder falsch) - unabhaengig von hideTexts; ninaFix-Rueckfall waere aus" ;; esac
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard --since -10min --no-pager | grep -E hideTexts"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "hideTexts aktiv: hideTexts ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'hideTexts aktiv: hideTexts ok' ($(echo "$JD" | grep -F hideTexts | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|wxSlot Takt:|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|kartevec FEHLER|dbVis Selbsttest FEHLER|dbVis /pi:|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|keepLast heal:|NameError|meshBootQuiet Wetter:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein hideTexts-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
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
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Sende- und Alarmregeln, Gain-Wachter (Stufe 16, nur Automatik) und alle Dienste ausser prepper-dashboard unberuehrt"
[[ -f "$F.bak-hidetexts-$TS" ]] && echo "Backup: dashboard.py.bak-hidetexts-$TS (behalten: letzte $KEEP_LAST); keine SQLite-Sicherung (Datenbank unberuehrt)"
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
LB=$({ ls -1t "$F.bak-hidetexts-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine hidetexts-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c hideTexts /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/api/nina-cert"
echo "  curl -s http://127.0.0.1:5000/ | grep -c A.note"
echo "  sudo journalctl -u prepper-dashboard --since -30min --no-pager | grep hideTexts"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme). Neue Docs-Version: bewusst nicht (nur dashboard.py geaendert)."
echo "COMMIT $COMMIT_ARG hidetexts=1 fertig"
