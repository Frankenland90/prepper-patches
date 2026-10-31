#!/bin/bash
set -eEuo pipefail
# commit48 geoRelevanz - BR24/ASA-Warntexte nach Ortsbezug (Vorfall Oleschky 31.10.: Auslandsmeldung "wird evakuiert" loeste ECHTALARM, Uebernahme, Mesh 1 und Ton aus):
#  - Ausland ohne Bezug zu Bayern/DE -> INFO (grau, nur Anzeige); Ausland mit DE-Folgen (Strahlung, Pandemie, Cyberangriff Stromnetz ...) -> WARNUNG (nur Anzeige)
#  - kein Ort + kein amtlicher Begriff -> WARNUNG (nur Anzeige); kein Ort + amtlicher Begriff -> rot wie bisher; Ort in Bayern/Franken/DE + amtlich -> rot wie bisher
#  - Ort ohne amtlichen Begriff -> rot nur Anzeige (kein Mesh, kein Ton, keine Uebernahme), bis NINA/ASA/DWD (Stufe >= 3) binnen 30 min bestaetigen
#  - Kopfzeile "LAGE: ..." folgt teil4 (ECHTALARM/VORALARM); Ortsliste geo_relevanz.json im Projektordner (wird nur angelegt, wenn sie fehlt; eigene Aenderungen bleiben; Fehler -> eingebaute Liste)
#  dashboard.py: ein Block vor __main__ (keine geaenderte Zeile). lage_pages.py und prepper_sdr.py bleiben unveraendert. Mesh-Regeln (6 h, max 3/h) unveraendert.
# Aufruf: bash /tmp/apply-commit48.sh commit48 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 74ac7bfd0eebd4e0 (alt) oder 334b60f2ed228831 (neu), lage_pages.py 1d33ae9fd78f53dc, prepper_sdr.py 0900bfe6ba67e657.
# Sicherung dashboard.py.bak-commit48-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts, kein Ton, Gain-Stufe 16 bleibt.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
FL="$DASH_DIR/lage_pages.py"
FS="$DASH_DIR/prepper_sdr.py"
FJ="$DASH_DIR/geo_relevanz.json"
VENV="$DASH_DIR/venv"
VPY="$VENV/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/commit48-apply
KEEP_LAST=3
NM=commit48
KNOWN_D16="74ac7bfd0eebd4e0"; KNOWN_D16N="334b60f2ed228831"
KNOWN_L16="1d33ae9fd78f53dc"; KNOWN_S16="0900bfe6ba67e657"; KNOWN_J16="02acdd61e474039c"
PHASE=vorher
STATE=unbekannt
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
echo "=== commit48 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): geoRelevanz, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt"
EXPECT_PAL="45feaed48b77a616035112a3f48bd1eb80d364200d0f8a50946bb1c06f3c5f2a"
cat > "$W/patch.py" << 'MK_C48_PAL_EOF'
"""Patcher speedAsync (generisch wie relStop). Aufruf: patch-pw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
MK_C48_PAL_EOF
EXPECT_RAE="a7a7d24c60aabc78e84c9b90f770d0e9db9cc29878facaf04c6766e97e2e1fff"
cat > "$W/edits.py" << 'MK_C48_RAE_EOF'
# Stellen fuer geoRelevanz (commit48): Basis 74ac7bfd0eebd4e0 (Stand nach commit47); nur ein Block vor __main__, keine Aenderung an bestehenden Zeilen
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_C48_RAE_EOF
EXPECT_RAB="8499a9e1dbbc3a7aaa617f8b45895d11cb773aadedd26c4a057fa2e7dbcdab09"
cat > "$W/blk.py" << 'MK_C48_RAB_EOF'
# ===== geoRelevanz: BR24/ASA-Warntexte nach Ortsbezug - Ausland ohne DE-Bezug nur INFO (grau), Ausland mit DE-Folgen (Strahlung, Pandemie ...) WARNUNG, kein Ort und kein amtlicher Begriff WARNUNG (nur Anzeige); Ort in Bayern/Franken/DE + amtlich = rot wie bisher; Ort ohne amtlichen Begriff = rot nur Anzeige (kein Mesh, kein Ton, keine Uebernahme), bis NINA/ASA/DWD binnen 30 min bestaetigen; Kopfzeile LAGE: ECHTALARM/VORALARM nach teil4; Ortsliste geo_relevanz.json (editierbar, Fallback eingebaut); prepper_sdr.py und Mesh-Regeln unveraendert; sendet nichts =====
import json as _geo_json
import os as _geo_os
import re as _geo_re
import threading as _geo_th
import time as _geo_time

GEO_CONFIRM_S = 1800          # s: Zweitquelle (NINA/ASA/DWD) muss binnen 30 min nach dem BR24-Text da sein
GEO_DWD_MIN = 3               # DWD-Warnstufe ab der eine DWD-Warnung als Bestaetigung zaehlt
GEO_FILE = _geo_os.path.join(_SDR_BASE, "geo_relevanz.json")
GEO_HOLD_TAG = "geoRelevanz: Bestaetigung noetig"
GEO_CHANGED = ("Großbrand: Lüftung und Klimaanlage bitte abschalten", "Bitte das Gebiet um den Hafen weiträumig meiden", "Extremes Unwetter: DWD Unwetterwarnung Stufe 4")   # bewusst rot -> WARNUNG (kein Ort, kein amtlicher Begriff)

GEO_DEFAULT = {
    "version": 1,
    "hinweis": "geoRelevanz (commit48): Ortsliste fuer BR24/ASA-Warntexte. Eintraege ohne Gross/Klein und Umlaut-egal (ae=ä); * am Ende = Wortanfang; A+B = beide Begriffe noetig. kfz: Kennzeichen, nur in Grossbuchstaben als eigenes Wort. Bei Fehler gilt die eingebaute Liste.",
    "lokal": ["bayern", "bayerisch*", "freistaat", "franken", "fraenkisch*", "mittelfranken", "oberfranken", "unterfranken", "oberbayern", "niederbayern", "oberpfalz", "schwaben",
              "deutschland", "bundesweit", "bundesgebiet", "baden-wuerttemberg", "hessen", "thueringen", "sachsen", "sachsen-anhalt", "brandenburg", "berlin", "mecklenburg-vorpommern",
              "niedersachsen", "nordrhein-westfalen", "rheinland-pfalz", "saarland", "schleswig-holstein", "hamburg", "bremen",
              "erlangen", "erlangen-hoechstadt", "hoechstadt", "herzogenaurach", "baiersdorf", "eckental", "heroldsberg", "uttenreuth", "buckenhof", "spardorf", "moehrendorf", "heroldsbach", "hemhofen", "adelsdorf", "weisendorf",
              "nuernberg", "nuernberger land", "fuerth", "zirndorf", "oberasbach", "cadolzburg", "langenzenn", "schwabach", "roth", "hilpoltstein", "lauf an der pegnitz", "hersbruck", "roethenbach", "altdorf", "schwarzenbruck", "wendelstein",
              "ansbach", "dinkelsbuehl", "rothenburg", "feuchtwangen", "herrieden", "weissenburg", "weissenburg-gunzenhausen", "gunzenhausen", "treuchtlingen",
              "neustadt an der aisch", "neustadt/aisch", "bad windsheim", "scheinfeld", "uffenheim", "hoechstadt an der aisch",
              "bamberg", "bayreuth", "coburg", "forchheim", "ebermannstadt", "graefenberg", "kronach", "kulmbach", "lichtenfels", "wunsiedel", "marktredwitz", "selb", "arzberg", "muenchberg", "naila", "helmbrechts", "pegnitz", "hof/saale", "hof (saale)", "landkreis hof", "stadt hof",
              "wuerzburg", "schweinfurt", "aschaffenburg", "kitzingen", "bad kissingen", "hassfurt", "hassberge", "main-spessart", "karlstadt", "lohr", "gemuenden", "marktheidenfeld", "miltenberg", "obernburg", "rhoen-grabfeld", "bad neustadt", "mellrichstadt",
              "muenchen", "augsburg", "regensburg", "ingolstadt", "landshut", "passau", "rosenheim", "kempten", "memmingen", "kaufbeuren", "neu-ulm", "straubing", "freising", "dachau", "erding", "amberg", "weiden", "neumarkt", "eichstaett", "kelheim", "deggendorf", "dingolfing",
              "landsberg", "fuerstenfeldbruck", "starnberg", "garmisch-partenkirchen", "bad toelz", "traunstein", "berchtesgaden", "muehldorf", "altoetting", "pfaffenhofen", "neuburg", "donauwoerth", "noerdlingen", "dillingen", "guenzburg", "lindau", "sonthofen", "fuessen", "weilheim", "mindelheim",
              "schwandorf", "cham", "tirschenreuth", "sulzbach-rosenberg", "neustadt an der waldnaab", "auerbach",
              "steigerwald", "fichtelgebirge", "frankenwald", "fraenkische schweiz", "fraenkische alb", "fraenkisches seenland", "spessart", "rhoen", "altmuehltal", "frankenhoehe", "hesselberg", "bayerischer wald", "allgaeu", "chiemgau", "chiemsee", "ammersee", "starnberger see", "brombachsee",
              "regnitz", "pegnitz", "rednitz", "aisch", "zenn", "altmuehl", "wiesent", "main", "donau", "isar", "inn", "lech", "naab", "iller", "wertach", "fraenkische saale", "tauber", "main-donau-kanal"],
    "kfz": ["ERH", "NEA", "WUG", "LAU", "HEB", "LIF", "WUN", "HAS", "MSP", "MIL", "NES"],
    "ausland": ["ukrain*", "kiew", "kyjiw", "charkiw", "cherson", "odessa", "saporischschja", "oleschky", "mariupol", "donezk", "luhansk", "krim", "dnipro", "russland", "russisch*", "moskau", "kreml", "belarus", "weissrussland",
                "gaza", "israel*", "westjordanland", "palaestin*", "libanon*", "syri*", "iran*", "irak*", "jemen*", "nahost", "hamas", "hisbollah", "huthi",
                "tuerkei", "tuerkisch*", "griechenland", "griechisch*", "italien*", "frankreich", "franzoesisch*", "spanien", "spanisch*", "portugal", "polen", "polnisch*", "tschechien", "tschechisch*", "oesterreich*", "schweiz*",
                "niederlande", "niederlaendisch*", "belgien", "daenemark", "schweden", "norwegen", "finnland", "ungarn", "rumaenien", "bulgarien", "serbien", "kosovo", "bosnien", "kroatien", "slowakei", "slowenien",
                "grossbritannien", "britisch*", "england", "london", "irland", "island", "usa", "us-bundesstaat", "amerikan*", "kalifornien", "florida", "texas", "kanada", "mexiko", "brasilien", "argentinien", "chile",
                "china", "chinesisch*", "japan*", "taiwan", "korea*", "indien", "indisch*", "pakistan", "afghanistan", "bangladesch", "indonesien", "philippinen", "australien", "neuseeland",
                "afrika*", "sudan", "kongo", "nigeria", "aegypten", "libyen", "marokko", "tunesien", "algerien", "aethiopien", "somalia", "paris", "rom", "madrid", "washington", "peking", "tokio", "ausland*"],
    "de_folgen": ["kernkraftwerk*", "atomkraftwerk*", "akw", "reaktor*", "radioaktiv*", "strahlung*", "fallout", "nuklear*", "atomar*", "atomwaffe*", "atomangriff*", "jodtablette*",
                  "pandemie*", "epidemie*", "seuche*", "giftwolke*", "aschewolke*", "cyberangriff*+strom*", "hackerangriff*+strom*", "cyberangriff*+netz*"],
    "amtlich": ["amtliche gefahrendurchsage", "gefahrendurchsage", "amtliche warnung", "warnung der bevoelkerung", "katastrophenfall", "katastrophenalarm", "landratsamt", "katastrophenschutz*", "bevoelkerungsschutz", "integrierte leitstelle", "polizeipraesidium"],
}

_GEO = {"aktiv": False, "err": None, "n": {"KATASTROPHE": 0, "BESTAETIGUNG": 0, "WARNUNG": 0, "INFO": 0}, "last": [], "seen": {}, "conf": {}, "hold": None,
        "liste": {"src": "eingebaut", "file": GEO_FILE, "mtime": None, "err": None}, "cfg": None, "cfg_key": None}
_GEO_LOCK = _geo_th.Lock()
_GEO_NORM = (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"))
_GEO_CATS = ("lokal", "ausland", "de_folgen", "amtlich")


def _geo_norm(s):
    s = str(s or "").lower()
    for a, b in _GEO_NORM:
        s = s.replace(a, b)
    return " ".join(s.split())


def _geo_term_re(term):
    t = _geo_norm(term)
    pre = t.endswith("*")
    core = _geo_re.escape(t.rstrip("*").strip())
    return _geo_re.compile(r"(?<![a-z0-9])" + core + ("" if pre else r"(?![a-z0-9])"))


def _geo_valid(d):
    """Liste pruefen -> Fehlertext oder None. Pflicht: lokal, ausland, de_folgen, amtlich (Listen kurzer Texte), kfz (Kennzeichen)."""
    if not isinstance(d, dict):
        return "kein JSON-Objekt"
    n = 0
    for k in _GEO_CATS + ("kfz",):
        v = d.get(k)
        if not isinstance(v, list) or not v:
            return "%s fehlt oder leer" % k
        for x in v:
            if not isinstance(x, str) or not x.strip() or len(x) > 80:
                return "%s: ungueltiger Eintrag %r" % (k, str(x)[:40])
            if k == "kfz" and not _geo_re.fullmatch(r"[A-ZÄÖÜ]{2,4}", x):
                return "kfz: %r ist kein Kennzeichen (2-4 Grossbuchstaben)" % x[:10]
            if k != "kfz" and len(_geo_norm(x).replace("*", "").replace("+", "")) < 3:
                return "%s: Eintrag %r zu kurz" % (k, x)
        n += len(v)
    if n > 3000:
        return "zu viele Eintraege (%d)" % n
    return None


def _geo_compile(d):
    c = {"kfz": [(x, _geo_re.compile(r"(?<![A-Za-zÄÖÜäöüß0-9])" + _geo_re.escape(x) + r"(?![A-Za-zÄÖÜäöüß0-9])")) for x in d["kfz"]]}
    for k in _GEO_CATS:
        c[k] = [(x, [_geo_term_re(p) for p in x.split("+") if p.strip()]) for x in d[k]]
    c["n"] = dict((k, len(d[k])) for k in _GEO_CATS + ("kfz",))
    return c


_GEO_BUILTIN = _geo_compile(GEO_DEFAULT)


def _geo_cfg(path=None):
    """Aktive Liste: geo_relevanz.json (mtime-Cache), bei Fehlen/Fehler die eingebaute (Hinweis einmal ins Journal)."""
    path = path or GEO_FILE
    try:
        st = _geo_os.stat(path)
        key = (path, st.st_mtime_ns, st.st_size)
    except OSError:
        key = (path, None, None)
    with _GEO_LOCK:
        if _GEO["cfg_key"] == key and _GEO["cfg"] is not None:
            return _GEO["cfg"]
    err, cfg, src = None, None, "eingebaut (Datei fehlt)"
    if key[1] is not None:
        try:
            if key[2] > 512 * 1024:
                raise ValueError("Datei zu gross (%d B)" % key[2])
            with open(path, encoding="utf-8") as f:
                d = _geo_json.load(f)
            err = _geo_valid(d)
            if err is None:
                cfg, src = _geo_compile(d), "Datei"
        except Exception as e:
            err = "%s: %s" % (type(e).__name__, str(e)[:120])
        if err:
            src = "eingebaut (Datei ungueltig: %s)" % err
            print("geoRelevanz Hinweis: %s ungueltig (%s) - es gilt die eingebaute Liste" % (path, err), flush=True)
    cfg = cfg or _GEO_BUILTIN
    with _GEO_LOCK:
        _GEO["cfg"], _GEO["cfg_key"] = cfg, key
        _GEO["liste"] = {"src": src, "file": path, "mtime": key[1] and int(key[1] / 1e9), "err": err, "n": cfg["n"]}
    return cfg


def _geo_hits(t, cfg):
    n = _geo_norm(t)
    out = {}
    for k in _GEO_CATS:
        out[k] = [x for x, rs in cfg[k] if all(r.search(n) for r in rs)]
    out["lokal"] += [x for x, r in cfg["kfz"] if r.search(str(t or ""))]
    return out


def _geo_classify(t, cfg=None):
    """Nur fuer Texte, die der Warn-Score rot nennt -> {lvl: KATASTROPHE|BESTAETIGUNG|WARNUNG|INFO, hits, why}."""
    h = _geo_hits(t, cfg or _geo_cfg())
    lok, aus, fol, amt = h["lokal"], h["ausland"], h["de_folgen"], h["amtlich"]
    if lok and amt:
        lvl, why = "KATASTROPHE", "Ort %s + amtlich (%s)" % (", ".join(lok[:2]), ", ".join(amt[:2]))
    elif lok:
        lvl, why = "BESTAETIGUNG", "Ort %s, kein amtlicher Begriff" % ", ".join(lok[:2])
    elif aus:
        lvl, why = ("WARNUNG", "Ausland (%s) mit DE-Folgen (%s)" % (", ".join(aus[:2]), ", ".join(fol[:2]))) if fol else ("INFO", "Ausland (%s), kein Bezug zu Bayern/DE" % ", ".join(aus[:2]))
    elif amt:
        lvl, why = "KATASTROPHE", "kein Ort, amtlich (%s)" % ", ".join(amt[:2])
    else:
        lvl, why = "WARNUNG", "kein Ort in Bayern/Franken/DE und kein amtlicher Begriff"
    return {"lvl": lvl, "hits": h, "why": why}


def _geo_note(t, g):
    k = _geo_norm(t)[:200]
    with _GEO_LOCK:
        if k in _GEO["seen"]:
            return
        if len(_GEO["seen"]) > 500:
            _GEO["seen"].clear()
        _GEO["seen"][k] = g["lvl"]
        _GEO["n"][g["lvl"]] += 1
        _GEO["last"] = ([{"t": int(_geo_time.time()), "lvl": g["lvl"], "why": g["why"], "text": " ".join(str(t).split())[:90]}] + _GEO["last"])[:20]
    print("geoRelevanz: %s - %s: „%s“" % (g["lvl"], g["why"], " ".join(str(t).split())[:90]), flush=True)


def _geo_wrap_score(r, t, cfg=None, note=True):
    """Ergebnis des Warn-Scores nachbewerten (nur rot). Fehler -> Original (lieber Alarm als keiner)."""
    if not isinstance(r, dict) or r.get("cls") != "rot":
        return r
    g = _geo_classify(t, cfg)
    if note:
        _geo_note(t, g)
    if g["lvl"] == "KATASTROPHE":
        return dict(r, why="%s · geo: %s" % (r.get("why"), g["why"]), geo=g["lvl"])
    if g["lvl"] == "BESTAETIGUNG":
        return dict(r, why="%s · %s (%s)" % (r.get("why"), GEO_HOLD_TAG, g["why"]), geo=g["lvl"])
    return {"cls": None, "why": "geoRelevanz %s (nur Anzeige): %s; Warn-Score: %s" % (g["lvl"], g["why"], r.get("why")), "geo": g["lvl"]}


def _geo_score(t, rtp=None):
    r = _geo_prev["ws"](t, rtp)
    try:
        return _geo_wrap_score(r, t)
    except Exception as e:
        print("geoRelevanz Bewertung:", e, flush=True)
        return r


_geo_score._geo = True
_geo_prev = {}


def _geo_confirm_src(br, ds):
    """Zweitquelle jetzt da? -> Name oder None. NINA: Liste mit echter Meldung; DWD: Stufe >= 3; ASA DE: roter ASA-Text."""
    try:
        nv = ((ds or {}).get("nina") or {}).get("value")
        for w in nv if isinstance(nv, list) else []:
            tt = str((w or {}).get("title") or "") if isinstance(w, dict) else str(w)
            if tt and not _geo_re.search(r"(?i)probe|test|warntag", tt) and str((w or {}).get("msgType") if isinstance(w, dict) else "") != "Cancel":
                return "NINA"
    except Exception:
        pass
    try:
        dv = ((ds or {}).get("dwd_warn") or {}).get("value")
        if isinstance(dv, dict) and int(dv.get("max_level") or 0) >= GEO_DWD_MIN:
            return "DWD Stufe %s" % dv.get("max_level")
    except Exception:
        pass
    for w in (br or {}).get("recent") or []:
        if str(w.get("src") or "").startswith("ASA") and w.get("cls") == "rot":
            return "ASA DE"
    return None


def _geo_br_post(r, now=None, ds=None, conf=None):
    """Zustand /api/br24 nachbearbeiten: rot ohne amtlichen Begriff -> geo_hold (rot bleibt sichtbar), Hinweise INFO/WARNUNG anzeigen."""
    if not isinstance(r, dict):
        return r
    now = now or _geo_time.time()
    conf = _GEO["conf"] if conf is None else conf
    ds = globals().get("data_store") if ds is None else ds
    w = r.get("why") if isinstance(r.get("why"), dict) else {}
    if r.get("state") == "rot" and GEO_HOLD_TAG in str(w.get("score") or "") and not str(w.get("src") or "").startswith("ASA"):
        t0 = float(w.get("t") or now)
        key = "%d|%s" % (int(t0), str(w.get("text") or "")[:90])
        c = conf.get(key)
        if c is None and now - t0 <= GEO_CONFIRM_S:
            src = _geo_confirm_src(r, ds)
            if src:
                c = conf[key] = {"src": src, "t": int(now)}
                if conf is _GEO["conf"]:
                    print("geoRelevanz: bestaetigt durch %s - „%s“" % (src, str(w.get("text") or "")[:80]), flush=True)
        for k in [k for k, v in conf.items() if now - v.get("t", 0) > 4 * 3600]:
            conf.pop(k, None)
        if c:
            r = dict(r, geo_confirmed=c["src"], text="%s · bestätigt durch %s" % (r.get("text"), c["src"]))
        else:
            dl = _geo_time.strftime("%H:%M", _geo_time.localtime(t0 + GEO_CONFIRM_S))
            r = dict(r, geo_hold=True, text="%s · nur Anzeige: Ort ohne amtlichen Begriff – Alarm (Mesh/Ton/Übernahme) nur nach Bestätigung durch NINA/ASA/DWD %s" % (
                r.get("text"), ("bis %s" % dl) if now - t0 <= GEO_CONFIRM_S else "(30 min ohne Bestätigung abgelaufen)"))
    elif r.get("state") != "rot":
        for x in r.get("recent") or []:
            sc = str(x.get("score") or "")
            if sc.startswith("geoRelevanz "):
                lv = sc.split(" ", 2)[1]
                r = dict(r, geo_hint={"lvl": lv, "text": x.get("text"), "t_txt": x.get("t_txt"), "src": x.get("src")},
                         text="%s · Hinweis %s (nur Anzeige%s): „%s“" % (r.get("text"), lv, ", grau" if lv == "INFO" else "", str(x.get("text") or "")[:70]))
                break
    return r


def _geo_br24_state():
    r = _geo_prev["br"]()
    try:
        r = _geo_br_post(r)
        with _GEO_LOCK:
            _GEO["hold"] = {"text": (r.get("why") or {}).get("text"), "t": (r.get("why") or {}).get("t")} if r.get("geo_hold") else None
    except Exception as e:
        print("geoRelevanz BR24:", e, flush=True)
    return r


def _geo_ctx_post(ctx):
    """Alarmweg (teil2/teil4 ueber _lz_ctx): rot ohne Bestaetigung zaehlt nicht als Alarm (Zustand gelb, Text bleibt)."""
    br = (ctx or {}).get("br24") if isinstance(ctx, dict) else None
    if isinstance(br, dict) and br.get("state") == "rot" and br.get("geo_hold"):
        ctx = dict(ctx, br24=dict(br, state="gelb", geo_state="rot (nur Anzeige)"))
    return ctx


def _geo_lz_ctx():
    ctx = _geo_prev["ctx"]()
    try:
        return _geo_ctx_post(ctx)
    except Exception as e:
        print("geoRelevanz Alarmweg:", e, flush=True)
        return ctx


_GEO_JS = ("(function(){var w=document.getElementById('t4Why'),h=document.getElementById('geoHead'),c=document.getElementById('geoIcon');if(!w||!h)return;"
           "function up(){var t=w.textContent||'',n=h.getAttribute('data-orig')||'',k=c?c.getAttribute('data-orig'):'';"
           "if(t.indexOf('Status: ECHTALARM')===0){n='LAGE: ECHTALARM';k='\\ud83d\\udea8';}else if(t.indexOf('Status: VORALARM')===0){n='LAGE: VORALARM';k='\\u26a0';}"
           "if(h.textContent!==n)h.textContent=n;if(c&&c.textContent!==k)c.textContent=k;}"
           "up();if(window.MutationObserver)new MutationObserver(up).observe(w,{childList:true,characterData:true,subtree:true});})();")


def _geo_head_label(lv):
    lab = str((lv or {}).get("label") or "")
    if lab.startswith("ECHTALARM"):
        return "LAGE: ECHTALARM", "🚨"
    if lab.startswith("VORALARM"):
        return "LAGE: VORALARM", "⚠"
    return None, None


def _geo_head_html(body, lv):
    """Lage-Kasten (nach teil4): Kopfzeile LAGE: ... und Symbol bei ECHTALARM/VORALARM ueberschreiben; Original in data-orig (JS stellt zurueck)."""
    i = body.find('id="t4Lage"')
    if i < 0 or 'id="geoHead"' in body:
        return body
    j = body.find("</div>", i)
    m = _geo_re.compile(r"LAGE: ([^<\n]*)").search(body, i, j)
    if not m:
        return body
    head, icon = _geo_head_label(lv)
    orig = m.group(0).rstrip()
    e = globals().get("_t4_html_esc") or (lambda s: str(s))
    rep = '<span id="geoHead" data-orig="%s">%s</span>' % (e(orig), e(head or orig))
    seg = body[i:m.start()]
    n = _geo_re.compile(r'<span class="lage-icon">([^<]*)</span>').search(seg)
    if n:
        seg = seg[:n.start()] + '<span class="lage-icon" id="geoIcon" data-orig="%s">%s</span>' % (e(n.group(1)), icon or n.group(1)) + seg[n.end():]
    body = body[:i] + seg + rep + body[m.start() + len(orig):]
    add = '<script id="geo-js">' + _GEO_JS + '</script>'
    k = body.rfind("</body>")
    return (body[:k] + add + body[k:]) if k >= 0 else (body + add)


def _geo_after(resp):
    try:
        from flask import request as _geo_rq
        if (_geo_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="t4Lage"' in body and 'id="geoHead"' not in body:
                lv = ((globals().get("_T4") or {}).get("status") or {}).get("level") or {}
                resp.set_data(_geo_head_html(body, lv))
    except Exception as e:
        print("geoRelevanz Kopfzeile:", e, flush=True)
    return resp


def _geo_api():
    from flask import jsonify
    cfg = _geo_cfg()
    with _GEO_LOCK:
        d = {"aktiv": _GEO["aktiv"], "err": _GEO["err"], "liste": dict(_GEO["liste"]), "n": dict(_GEO["n"]), "last": list(_GEO["last"]), "hold": _GEO["hold"],
             "confirm_s": GEO_CONFIRM_S, "dwd_min": GEO_DWD_MIN, "bestaetigt": len(_GEO["conf"]), "kategorien": cfg["n"]}
    return jsonify(d)


def _selftest_georel(ws):
    """Goldene Faelle, die 36 Warn-Score-Faelle (3 bewusste Aenderungen), BR24-Kette bis Alarmliste/Ampel, Kopfzeile, Listenpruefung."""
    S = lambda t: _geo_wrap_score(ws(t), t, _GEO_BUILTIN, note=False)
    gold = [("+++ Ukrainische Stadt Oleschky wird evakuiert +++", None, "INFO"), ("Amtliche Warnung: Evakuierung in Erlangen-Höchstadt", "rot", "KATASTROPHE"),
            ("Evakuierung in Forchheim nach Bombenfund", "rot", "BESTAETIGUNG"), ("Landratsamt ERH: Katastrophenfall ausgerufen", "rot", "KATASTROPHE"),
            ("Kernkraftwerk Saporischschja: erhöhte Strahlung, Bevölkerung wird evakuiert", None, "WARNUNG"), ("Gaza: Klinik wird evakuiert", None, "INFO"),
            ("Amtliche Gefahrendurchsage: Fenster und Türen schließen", "rot", "KATASTROPHE"), ("Großbrand: Lüftung und Klimaanlage bitte abschalten", None, "WARNUNG"),
            ("Evakuierung in Kiew: Russland greift an", None, "INFO"), ("Bombenfund in ERH: Gebiet weiträumig meiden", "rot", "BESTAETIGUNG"),
            ("Evakuierung im Landkreis Fürth, Lüftung abschalten", "rot", "BESTAETIGUNG")]
    for t, c, lv in gold:
        assert ws(t)["cls"] == "rot", ("Warn-Score sollte rot sagen", t)
        r = S(t)
        assert r["cls"] == c and r.get("geo") == lv, (t, r)
        assert (GEO_HOLD_TAG in r["why"]) == (lv == "BESTAETIGUNG"), (t, r)
    chg = []
    for t, exp in _WS_VEC:
        r = S(t)
        if r["cls"] != exp:
            chg.append(t)
            assert t in GEO_CHANGED and exp == "rot" and r["cls"] is None and r.get("geo") == "WARNUNG", ("Warn-Score-Fall geaendert", t, r, exp)
        assert r == ws(t) or exp == "rot", ("nicht-rot unveraendert", t)
    assert sorted(chg) == sorted(GEO_CHANGED) and len(_WS_VEC) == 36, chg
    for t in ("Falschfahrer auf der A73", "Probewarnung zum Warntag", "Entwarnung für Erlangen: Gefahr ist vorbei", "Adele - Hello", ""):
        assert S(t) == ws(t), t
    assert _geo_valid(GEO_DEFAULT) is None and _geo_valid({"lokal": []}) and _geo_valid(dict(GEO_DEFAULT, kfz=["er"])) and _geo_valid(dict(GEO_DEFAULT, lokal=["ab"]))
    assert _geo_classify("Evakuierung in Forchheimer Straße", _GEO_BUILTIN)["lvl"] == "WARNUNG"            # Wortgrenze: Forchheimer ist kein Ort
    assert _geo_classify("Evakuierung in Nürnberg", _GEO_BUILTIN)["lvl"] == _geo_classify("EVAKUIERUNG IN NUERNBERG", _GEO_BUILTIN)["lvl"] == "BESTAETIGUNG"
    assert _geo_classify("Evakuierung in Erh", _GEO_BUILTIN)["lvl"] == "WARNUNG"                          # Kennzeichen nur gross
    # BR24-Kette: Ereignisse -> _br24_eval (mit diesem Score) -> Nachbearbeitung -> Alarmweg -> Alarmliste -> Ampel
    now = 179 * 10 ** 7
    b = {"fm": {}, "dab": {"11D": {"t": now - 60, "services": [{"label": "BR24", "sid": "0xD314", "dls": "Nachrichten"}], "alarm": []}}}
    prev = globals()["_ws_score"]
    globals()["_ws_score"] = lambda t, rtp=None: S(t)
    try:
        def chain(text, ds, conf, at=None):
            ev = [{"t": now - 120, "k": "dls", "src": "DAB 11D", "svc": "BR24", "text": text}]
            r = _geo_br_post(_br24_eval(b, ev, at or now), at or now, ds, conf)
            ctx = _geo_ctx_post({"nina": None, "br24": r})
            al = _lz_mgr.alarms_from(br=ctx["br24"], now=at or now)
            lv = _lz_mgr.t4_level(None, al, {}, ctx["br24"])
            return r, ctx, [a for a in al if a.get("real")], lv
        r, ctx, real, lv = chain("+++ Ukrainische Stadt Oleschky wird evakuiert +++", {}, {})
        assert r["state"] != "rot" and not real and lv.get("label") != "ECHTALARM" and r.get("geo_hint", {}).get("lvl") == "INFO" and "nur Anzeige, grau" in r["text"], (r, lv)
        r, ctx, real, lv = chain("Amtliche Warnung: Evakuierung in Erlangen-Höchstadt", {}, {})
        assert r["state"] == "rot" and not r.get("geo_hold") and ctx["br24"]["state"] == "rot" and real and lv.get("label") == "ECHTALARM", (r, lv)
        F = "Evakuierung in Forchheim nach Bombenfund"
        r, ctx, real, lv = chain(F, {}, {})
        assert r["state"] == "rot" and r.get("geo_hold") and ctx["br24"]["state"] == "gelb" and not real and lv.get("label") != "ECHTALARM" and "nur Anzeige" in r["text"], (r, lv)
        conf = {}
        r, ctx, real, lv = chain(F, {"nina": {"value": [{"title": "Probewarnung", "msgType": "Alert"}]}, "dwd_warn": {"value": {"max_level": 2}}}, conf)
        assert r.get("geo_hold") and not real and not conf, "Probe/DWD 2 bestaetigen nicht"
        r, ctx, real, lv = chain(F, {"nina": {"value": [{"title": "Gefahreninformation Bombenfund Forchheim", "msgType": "Alert"}]}}, conf)
        assert not r.get("geo_hold") and r.get("geo_confirmed") == "NINA" and real and lv.get("label") == "ECHTALARM", (r, lv)
        r, ctx, real, lv = chain(F, {}, conf)
        assert r.get("geo_confirmed") == "NINA" and real, "Bestaetigung bleibt gemerkt"
        r, ctx, real, lv = chain(F, {"dwd_warn": {"value": {"max_level": 3}}}, {}, now + GEO_CONFIRM_S + 200)
        assert r.get("geo_hold") and not real and "abgelaufen" in r["text"], "Bestaetigung nach 30 min zaehlt nicht"
        r, ctx, real, lv = chain(F, {"dwd_warn": {"value": {"max_level": 4}}}, {})
        assert r.get("geo_confirmed") == "DWD Stufe 4" and real
    finally:
        globals()["_ws_score"] = prev
    page = '<html><body><div class="lage normal t4s t4-alarm" id="t4Lage" data-t4-orig="normal">\n  <span class="lage-icon">🛡</span>\n  LAGE: NORMAL\n  <small>Keine</small><small class="t4-why" id="t4Why">Status: ECHTALARM – BR24</small></div></body></html>'
    h = _geo_head_html(page, {"label": "ECHTALARM"})
    assert 'id="geoHead" data-orig="LAGE: NORMAL">LAGE: ECHTALARM</span>' in h and 'id="geoIcon" data-orig="🛡">🚨</span>' in h and h.count('id="geo-js"') == 1, h
    assert _geo_head_html(h, {"label": "ECHTALARM"}) == h
    h2 = _geo_head_html(page, {"label": "OK"})
    assert '>LAGE: NORMAL</span>' in h2 and 'data-orig="🛡">🛡</span>' in h2
    assert '>LAGE: VORALARM</span>' in _geo_head_html(page, {"label": "VORALARM NETZFREQUENZ"})
    assert _geo_head_html("<div>LAGE: NORMAL</div>", {"label": "ECHTALARM"}) == "<div>LAGE: NORMAL</div>"
    return "geoRelevanz ok (%d goldene Faelle, %d Warn-Score-Faelle, davon %d bewusst rot->WARNUNG; Kette BR24->Alarm: Oleschky INFO kein Alarm, ERH amtlich ECHTALARM, Forchheim nur Anzeige bis NINA/ASA/DWD binnen %d min)" % (
        len(gold), len(_WS_VEC), len(chg), GEO_CONFIRM_S // 60)


def _geo_install():
    g = globals()
    for k, key, fn in (("_ws_score", "ws", _geo_score), ("_br24_state", "br", _geo_br24_state), ("_lz_ctx", "ctx", _geo_lz_ctx)):
        if not callable(g.get(k)):
            raise RuntimeError("%s fehlt" % k)
        if not getattr(g[k], "_geo", False):
            fn._geo = True
            _geo_prev[key] = g[k]
            g[k] = fn
    if "geo_status" not in app.view_functions and not any(r.rule == "/api/geo/status" for r in app.url_map.iter_rules()):
        app.add_url_rule("/api/geo/status", endpoint="geo_status", view_func=_geo_api, methods=["GET"])
    lst = app.after_request_funcs.setdefault(None, [])
    if not any(getattr(f, "__name__", "") == "_geo_after" for f in lst):
        lst.insert(0, _geo_after)          # Index 0 = laeuft zuletzt (nach teil4 _t4_after)
    _geo_cfg()


try:
    _GEO_ST = _selftest_georel(_ws_score)
    _geo_install()
    _GEO["aktiv"] = True
except Exception as _geo_e:
    _GEO_ST = None
    _GEO["err"] = "%s: %s" % (type(_geo_e).__name__, _geo_e)
    print("geoRelevanz Selbsttest FEHLER (%s: %s) - Warntexte wie bisher bewertet" % (type(_geo_e).__name__, str(_geo_e)[:300]), flush=True)
if _GEO_ST:
    print("geoRelevanz aktiv: %s; Liste: %s" % (_GEO_ST, _GEO["liste"]["src"]), flush=True)
# ===== /geoRelevanz =====
MK_C48_RAB_EOF
EXPECT_RAG="f400ec3f2219d62448b0f3ac78c54a8d34451641335209b269675c123962d6cc"
cat > "$W/guard.py" << 'MK_C48_RAG_EOF'
"""Guard geoRelevanz (commit48). dashboard.py: genau ein Block vor __main__, keine geaenderten Zeilen.
  guard_geo.py revert NEU ALT BLOCK          -> ALT/dashboard.py = NEU ohne Block (byte-genau)
  guard_geo.py check  ALT NEU BLOCK JSON     -> Rueckbau = ALT, statische Regeln, Verhaltenstests mit eigener Erwartungstabelle (echter Warn-Score-Abschnitt aus NEU)
  guard_geo.py mutate ALT NEU BLOCK JSON     -> Mutationstest (jede Mutation muss check scheitern lassen)
  guard_geo.py liste  BLOCK DATEI            -> Ortsliste pruefen (ok / ungueltig: Grund)
node (falls vorhanden) testet das Seitenskript; ohne node statische Pruefung (Mutationen werden in beiden Faellen erkannt)."""
import ast, json, os, shutil, subprocess, sys, tempfile

ANCH = '\n\nif __name__ == "__main__":\n'
M0, M1 = "# ===== geoRelevanz:", "# ===== /geoRelevanz ====="
TRAIL = "\n\ntry:\n    _GEO_ST = _selftest_georel(_ws_score)"
CHANGED = ["Großbrand: Lüftung und Klimaanlage bitte abschalten", "Bitte das Gebiet um den Hafen weiträumig meiden", "Extremes Unwetter: DWD Unwetterwarnung Stufe 4"]
# eigene Erwartung (unabhaengig vom Selbsttest im Block): Text -> (cls, geo)
GOLD = [("+++ Ukrainische Stadt Oleschky wird evakuiert +++", None, "INFO"), ("Amtliche Warnung: Evakuierung in Erlangen-Höchstadt", "rot", "KATASTROPHE"),
        ("Evakuierung in Forchheim nach Bombenfund", "rot", "BESTAETIGUNG"), ("Evakuierung im Landkreis ERH", "rot", "BESTAETIGUNG"),
        ("Landratsamt ERH: Katastrophenfall ausgerufen", "rot", "KATASTROPHE"), ("Gaza: Klinik wird evakuiert", None, "INFO"),
        ("Israelische Armee: Evakuierung im Libanon", None, "INFO"), ("Kernkraftwerk Saporischschja: erhöhte Strahlung, Bevölkerung wird evakuiert", None, "WARNUNG"),
        ("Ukraine: Cyberangriff legt Stromnetz lahm, Evakuierung", None, "WARNUNG"), ("Amtliche Gefahrendurchsage: Fenster und Türen schließen", "rot", "KATASTROPHE"),
        ("Gefahrendurchsage der Polizei Nürnberg", "rot", "KATASTROPHE"), ("Evakuierung in der Forchheimer Straße", None, "WARNUNG"),
        ("EVAKUIERUNG IN NUERNBERG", "rot", "BESTAETIGUNG"), ("Evakuierung in Erh", None, "WARNUNG"), ("Evakuierung wegen Hochwasser an der Regnitz", "rot", "BESTAETIGUNG"),
        ("Bayern: Evakuierung nach Explosion in Kiew-Hilfslager", "rot", "BESTAETIGUNG"), ("Großbrand: Lüftung und Klimaanlage bitte abschalten", None, "WARNUNG"),
        ("Evakuierung in Neuforchheim", None, "WARNUNG")]
FORBID_NAMES = {"send_meshtastic", "send_dab_to_private_mesh", "send_nina_to_bayern", "requests", "urllib", "socket", "subprocess", "Popen", "system", "Thread", "sleep",
                "_t4_cascade", "_t4_spawn", "_t4_run", "_t4_vol", "takeover_auto", "set_auto", "auto_send", "remove", "unlink", "rename", "rmtree", "makedirs", "mkdir", "chmod", "eval", "exec", "__import__"}


def rd(p):
    return open(p, encoding="utf-8").read()


def blk_text(bp):
    return rd(bp).rstrip("\n") + "\n"


def revert(neu, bp):
    B = blk_text(bp)
    assert neu.count(M0) == 1 and neu.count(M1) == 1, "Marker nicht genau einmal"
    assert neu.count("\n\n" + B.rstrip("\n") + ANCH) == 1, "Block nicht genau einmal unmittelbar vor __main__"
    return neu.replace("\n\n" + B.rstrip("\n") + ANCH, ANCH, 1)


def fail(m):
    print("VERSTOSS:", m)
    sys.exit(1)


def static(B):
    t = ast.parse(B)
    n = 0
    for node in ast.walk(t):
        if isinstance(node, ast.Name) and node.id in FORBID_NAMES:
            fail("verbotener Name %s" % node.id)
        if isinstance(node, ast.Attribute) and node.attr in FORBID_NAMES:
            fail("verbotenes Attribut .%s" % node.attr)
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            mods = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module]
            for m in mods:
                if m not in ("json", "os", "re", "threading", "time", "flask"):
                    fail("Import %s" % m)
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "_geo_os" and f.attr != "stat":
                fail("os-Aufruf _geo_os.%s" % f.attr)
            if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Attribute) and isinstance(f.value.value, ast.Name) and f.value.value.id == "_geo_os" and f.attr != "join":
                fail("os.path-Aufruf %s" % f.attr)
            if isinstance(f, ast.Name) and f.id == "open":
                n += 1
                if len(node.args) > 1 or any(k.arg == "mode" for k in node.keywords):
                    fail("open() mit Modus (nur Lesen erlaubt)")
            if isinstance(f, ast.Name) and f.id == "print":
                a0 = node.args[0] if node.args else None
                s = a0.left.value if isinstance(a0, ast.BinOp) and isinstance(a0.left, ast.Constant) else (a0.value if isinstance(a0, ast.Constant) else "")
                if not str(s).startswith("geoRelevanz"):
                    fail("print ohne Praefix geoRelevanz: %r" % str(s)[:40])
            if isinstance(f, ast.Name) and f.id == "_geo_stat":
                pass
        if isinstance(node, ast.Global):
            fail("global-Anweisung")
    for node in t.body:
        tg = []
        if isinstance(node, ast.Assign):
            tg = [x for x in node.targets]
        elif isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            if not (node.name.startswith("_geo") or node.name == "_selftest_georel"):
                fail("Funktion ausserhalb Namensraum: %s" % node.name)
        for x in tg:
            if isinstance(x, ast.Name) and not (x.id.startswith("GEO_") or x.id.startswith("_GEO") or x.id.startswith("_geo")):
                fail("Zuweisung ausserhalb Namensraum: %s" % x.id)
    if B.count("os.stat(path)") != 1 or "stat(" in B.replace("_geo_os.stat(path)", ""):
        fail("Dateizugriff ausser stat(path)")
    if B.count("lst.insert(0, _geo_after)") != 1 or "app.after_request(" in B:
        fail("after_request nicht an Index 0 (muss nach teil4 laufen)")
    if B.count('methods=["GET"]') != 1 or "POST" in B:
        fail("Route nicht nur GET")
    if B.count('for k, key, fn in (("_ws_score", "ws", _geo_score), ("_br24_state", "br", _geo_br24_state), ("_lz_ctx", "ctx", _geo_lz_ctx)):') != 1:
        fail("umverdrahtete Funktionen nicht genau _ws_score/_br24_state/_lz_ctx")
    ng = 0
    for node in ast.walk(t):
        if isinstance(node, (ast.Assign, ast.AugAssign)):
            for x in (node.targets if isinstance(node, ast.Assign) else [node.target]):
                if isinstance(x, ast.Subscript):
                    v = x.value
                    if isinstance(v, ast.Name) and v.id == "g":
                        ng += 1
                    if isinstance(v, ast.Call) and getattr(v.func, "id", "") == "globals":
                        if not (isinstance(x.slice, ast.Constant) and x.slice.value == "_ws_score"):
                            fail("globals()-Zuweisung an %s" % ast.dump(x.slice)[:40])
    if B.count("g[k] = fn") != 1 or ng != 1:
        fail("weitere globale Umverdrahtung")
    js_need = ["h.textContent=n", "c.textContent=k", "observe(w,{childList:true,characterData:true,subtree:true})", "indexOf('Status: ECHTALARM')===0", "indexOf('Status: VORALARM')===0",
               "getAttribute('data-orig')"]
    for s in js_need:
        if B.count(s) != (2 if "getAttribute" in s else 1):
            fail("Seitenskript: %s fehlt/geaendert" % s)
    jsx = B[B.index("_GEO_JS = ("):B.index("def _geo_head_label")]
    if "innerHTML" in jsx or "eval(" in jsx or "fetch(" in jsx or "XMLHttpRequest" in jsx:
        fail("Seitenskript: innerHTML/eval/fetch")
    return n


def load_ns(neu, B, tmp):
    i0 = neu.rindex("# --ws-score-begin")
    i1 = neu.index("# --ws-score-end", i0)
    g = {"__name__": "geoguard", "_SDR_BASE": tmp}
    exec(compile(neu[i0:i1], "ws-score", "exec"), g)
    j = B.index(TRAIL)
    exec(compile(B[:j], "geo-block", "exec"), g)
    return g


class FakeApp:
    def __init__(self):
        self.view_functions, self.rules, self.after_request_funcs = {}, [], {None: []}

    def add_url_rule(self, rule, endpoint=None, view_func=None, methods=None):
        assert endpoint not in self.view_functions
        self.view_functions[endpoint] = view_func
        self.rules.append(type("R", (), {"rule": rule, "methods": methods, "endpoint": endpoint})())

    class _M:
        pass

    @property
    def url_map(self):
        m = self._M()
        m.iter_rules = lambda: list(self.rules)
        return m


def behav(neu, B, jsonp):
    tmp = tempfile.mkdtemp()
    try:
        g = load_ns(neu, B, tmp)
        ws, W = g["_ws_score"], g["_geo_wrap_score"]
        cfg = g["_GEO_BUILTIN"]
        assert g["GEO_CONFIRM_S"] == 1800 and g["GEO_DWD_MIN"] == 3, "Konstanten 1800 s / Stufe 3"
        assert list(g["GEO_CHANGED"]) == CHANGED, "bewusste Aenderungen"
        dj = json.load(open(jsonp, encoding="utf-8"))
        assert dj == g["GEO_DEFAULT"], "geo_relevanz.json != eingebaute Liste"
        assert g["_geo_valid"](dj) is None
        S = lambda t: W(ws(t), t, cfg, note=False)
        for t, c, lv in GOLD:
            assert ws(t)["cls"] == "rot", ("Basis-Score", t)
            r = S(t)
            assert r["cls"] == c and r.get("geo") == lv, (t, r, c, lv)
            assert (g["GEO_HOLD_TAG"] in r["why"]) == (lv == "BESTAETIGUNG"), t
        ch = []
        for t, exp in g["_WS_VEC"]:
            r = S(t)
            if r["cls"] != exp:
                ch.append(t)
            if exp != "rot":
                assert r == ws(t), ("nicht-rot muss unveraendert bleiben", t)
        assert sorted(ch) == sorted(CHANGED) and len(g["_WS_VEC"]) == 36, ch
        for t in ("Falschfahrer auf der A73", "Probewarnung zum Warntag", "Entwarnung für Erlangen", "", "Stau auf der A9"):
            assert S(t) == ws(t)
        assert sum(g["_GEO"]["n"].values()) == 0 and g["_GEO"]["last"] == [], "Selbsttest/Guard ohne Zaehlung"
        g["_geo_prev"]["ws"] = ws
        g["_geo_score"]("Gaza: Klinik wird evakuiert")
        g["_geo_score"]("Gaza: Klinik wird evakuiert")
        assert g["_GEO"]["n"]["INFO"] == 1 and g["_GEO"]["last"][0]["lvl"] == "INFO", "Zaehlung/Journal einmal je Text"
        # Fehler im Klassifizierer -> Originalergebnis (lieber Alarm als keiner)
        g["_geo_prev"]["ws"] = ws
        c0 = g["_geo_classify"]
        g["_geo_classify"] = lambda *a, **k: 1 / 0
        r = g["_geo_score"]("Gaza: Klinik wird evakuiert")
        assert r == ws("Gaza: Klinik wird evakuiert"), "Fehler muss Original liefern"
        g["_geo_classify"] = c0
        # Nachbearbeitung /api/br24
        P, tag, now = g["_geo_br_post"], g["GEO_HOLD_TAG"], 2000000000
        red = lambda src="BR24 DAB 11D", sc="stark: Evakuierung · %s (Ort x)" % tag, t=now - 60: {"state": "rot", "text": "T", "why": {"t": t, "src": src, "text": "Evakuierung in Forchheim", "score": sc}, "recent": []}
        r = P(red(), now, {}, {})
        assert r.get("geo_hold") and "nur Anzeige" in r["text"] and r["state"] == "rot", r
        assert not P(red(src="ASA DE 5C"), now, {}, {}).get("geo_hold"), "ASA ist amtlich"
        assert not P(red(sc="stark: x · geo: Ort"), now, {}, {}).get("geo_hold"), "amtlich ohne Halt"
        for ds, ok in (({"nina": {"value": [{"title": "Bombenfund Forchheim", "msgType": "Alert"}]}}, "NINA"), ({"nina": {"value": [{"title": "Probewarnung", "msgType": "Alert"}]}}, None),
                       ({"nina": {"value": [{"title": "Bombenfund", "msgType": "Cancel"}]}}, None), ({"nina": {"value": []}}, None),
                       ({"dwd_warn": {"value": {"max_level": 3}}}, "DWD Stufe 3"), ({"dwd_warn": {"value": {"max_level": 2}}}, None)):
            r = P(red(), now, ds, {})
            assert (r.get("geo_confirmed") == ok) and (bool(r.get("geo_hold")) == (ok is None)), (ds, r)
        ra = red()
        ra["recent"] = [{"src": "ASA DE 5C", "cls": "rot"}]
        assert P(ra, now, {}, {}).get("geo_confirmed") == "ASA DE"
        ra["recent"] = [{"src": "ASA DE 5C", "cls": None}]
        assert P(ra, now, {}, {}).get("geo_hold")
        conf = {}
        assert P(red(), now, {"dwd_warn": {"value": {"max_level": 4}}}, conf).get("geo_confirmed") and P(red(), now + 60, {}, conf).get("geo_confirmed"), "gemerkt"
        assert P(red(t=now - 1801), now, {"dwd_warn": {"value": {"max_level": 4}}}, {}).get("geo_hold"), "nach 30 min keine Bestaetigung mehr"
        assert P(red(t=now - 1799), now, {"dwd_warn": {"value": {"max_level": 4}}}, {}).get("geo_confirmed"), "innerhalb 30 min"
        gi = P({"state": "gruen", "text": "BR24 empfangen", "recent": [{"text": "Gaza", "score": "geoRelevanz INFO (nur Anzeige): Ausland"}]}, now, {}, {})
        assert gi["geo_hint"]["lvl"] == "INFO" and "nur Anzeige, grau" in gi["text"] and gi["state"] == "gruen"
        gw = P({"state": "gruen", "text": "x", "recent": [{"text": "AKW", "score": "geoRelevanz WARNUNG (nur Anzeige): y"}]}, now, {}, {})
        assert gw["geo_hint"]["lvl"] == "WARNUNG" and "grau" not in gw["text"]
        # Alarmweg
        C = g["_geo_ctx_post"]
        h = P(red(), now, {}, {})
        c = C({"nina": None, "br24": h})
        assert c["br24"]["state"] == "gelb" and h["state"] == "rot", "Halt -> kein rot im Alarmweg (Original unveraendert)"
        c2 = {"br24": {"state": "rot", "why": {}}}
        assert C(c2) is c2 and C({"br24": None}) == {"br24": None}
        # Kopfzeile
        H = g["_geo_head_html"]
        pg = '<div class="lage normal t4s" id="t4Lage" data-t4-orig="normal">\n  <span class="lage-icon">🛡</span>\n  LAGE: NORMAL\n  <small>r</small><small class="t4-why" id="t4Why">Status: X</small></div><div>LAGE: ANDERS</div></body>'
        for lab, head, ic in (("ECHTALARM", "LAGE: ECHTALARM", "🚨"), ("VORALARM DSL-AUSFALL", "LAGE: VORALARM", "⚠"), ("PROBEALARM", "LAGE: NORMAL", "🛡"), ("SDR_OFFLINE", "LAGE: NORMAL", "🛡"), ("OK", "LAGE: NORMAL", "🛡")):
            x = H(pg, {"label": lab})
            assert '<span id="geoHead" data-orig="LAGE: NORMAL">%s</span>' % head in x and 'data-orig="🛡">%s</span>' % ic in x and "<div>LAGE: ANDERS</div>" in x and x.count('id="geo-js"') == 1, (lab, x)
            assert H(x, {"label": lab}) == x
        assert H("<div>LAGE: NORMAL</div>", {"label": "ECHTALARM"}) == "<div>LAGE: NORMAL</div>"
        # Ortsliste: Datei gilt, ungueltig -> eingebaut
        fp = os.path.join(tmp, "geo_relevanz.json")
        d2 = dict(dj, lokal=[x for x in dj["lokal"] if x != "forchheim"])
        json.dump(d2, open(fp, "w"))
        assert g["_geo_classify"]("Evakuierung in Forchheim")["lvl"] == "WARNUNG" and g["_GEO"]["liste"]["src"] == "Datei", "Datei muss gelten"
        open(fp, "w").write("{kaputt")
        os.utime(fp, (1, 1))
        assert g["_geo_classify"]("Evakuierung in Forchheim")["lvl"] == "BESTAETIGUNG" and g["_GEO"]["liste"]["src"].startswith("eingebaut (Datei ungueltig"), g["_GEO"]["liste"]
        json.dump(dict(dj, kfz=["erh"]), open(fp, "w"))
        assert g["_geo_classify"]("Evakuierung in Forchheim")["lvl"] == "BESTAETIGUNG" and "ungueltig" in g["_GEO"]["liste"]["src"]
        os.remove(fp)
        assert g["_GEO"]["liste"]["src"] != "Datei" or True
        assert g["_geo_cfg"]() is g["_GEO_BUILTIN"]
        # Einbau zweimal: genau eine Umverdrahtung, Route einmal, after_request an Index 0
        app = FakeApp()
        app.after_request_funcs[None] = [lambda r: r, lambda r: r]
        g["app"] = app
        o_ws, o_br, o_ctx = g["_ws_score"], (lambda: {"state": "gruen"}), (lambda: {"br24": None})
        g["_br24_state"], g["_lz_ctx"] = o_br, o_ctx
        g["_geo_prev"].clear()
        g["_geo_install"]()
        g["_geo_install"]()
        assert g["_geo_prev"]["ws"] is o_ws and g["_geo_prev"]["br"] is o_br and g["_geo_prev"]["ctx"] is o_ctx, "doppelt umverdrahtet"
        assert g["_ws_score"] is g["_geo_score"] and g["_br24_state"] is g["_geo_br24_state"] and g["_lz_ctx"] is g["_geo_lz_ctx"]
        assert app.after_request_funcs[None][0] is g["_geo_after"] and len(app.after_request_funcs[None]) == 3
        assert [r.rule for r in app.rules] == ["/api/geo/status"] and app.rules[0].methods == ["GET"]
        return g
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


JS_TEST = r'''
var els={};function E(id,o,t){var e={id:id,a:{"data-orig":o},textContent:t,getAttribute:function(k){return this.a[k]||null}};els[id]=e;return e}
var w=E("t4Why",null,"Status: OK – "),h=E("geoHead","LAGE: NORMAL","LAGE: NORMAL"),c=E("geoIcon","\ud83d\udee1","\ud83d\udee1");var cb=null;
globalThis.document={getElementById:function(i){return els[i]||null}};
function MO(f){this.observe=function(t,o){if(t===w&&o.characterData&&o.childList&&o.subtree)cb=f}}globalThis.window={MutationObserver:MO};globalThis.MutationObserver=MO;
eval(require("fs").readFileSync(process.argv[2],"utf8"));
var r=[];function st(t){w.textContent=t;cb&&cb();r.push(h.textContent+"|"+c.textContent)}
st("Status: ECHTALARM – BR24");st("Status: OK – x");st("Status: VORALARM NETZFREQUENZ – y");st("Status: PROBEALARM – z");st("Status: SDR_OFFLINE");
console.log(JSON.stringify({cb:!!cb,r:r}));
'''


def jstest(g):
    node = shutil.which("node") or shutil.which("nodejs")
    if not node or os.environ.get("GUARD_NO_NODE"):
        return "statisch (node fehlt)"
    d = tempfile.mkdtemp()
    try:
        open(os.path.join(d, "g.js"), "w").write(g["_GEO_JS"])
        open(os.path.join(d, "t.js"), "w").write(JS_TEST)
        o = subprocess.run([node, os.path.join(d, "t.js"), os.path.join(d, "g.js")], capture_output=True, text=True, timeout=30)
        j = json.loads(o.stdout.strip().splitlines()[-1])
        exp = ["LAGE: ECHTALARM|\U0001f6a8", "LAGE: NORMAL|\U0001f6e1", "LAGE: VORALARM|\u26a0", "LAGE: NORMAL|\U0001f6e1", "LAGE: NORMAL|\U0001f6e1"]
        assert j["cb"] and j["r"] == exp, j
        return "node ok (5 Zustaende)"
    finally:
        shutil.rmtree(d, ignore_errors=True)


def check(alt, neu, bp, jsonp):
    B = blk_text(bp)
    try:
        r = revert(neu, bp)
    except AssertionError as e:
        fail(str(e))
    if r != alt:
        fail("Rueckbau != Basis (Aenderung ausserhalb des Blocks)")
    if not B.startswith(M0) or not B.rstrip("\n").endswith(M1):
        fail("Block beginnt/endet nicht mit Marker")
    try:
        compile(B, "blk", "exec")
    except SyntaxError as e:
        fail("Syntax %s" % e)
    static(B)
    try:
        g = behav(neu, B, jsonp)
        js = jstest(g)
    except AssertionError as e:
        fail("Verhalten: %s" % str(e)[:300])
    except Exception as e:
        fail("Verhalten (%s): %s" % (type(e).__name__, str(e)[:300]))
    print("Guard geoRelevanz ok: Rueckbau byte-genau = Basis, statisch ok (nur Lesen, nichts senden, kein Ton, nur GET-Route, after_request Index 0, 3 Umverdrahtungen), %d eigene goldene Faelle, 36 Warn-Score-Faelle (3 bewusst rot->WARNUNG), Halt/Bestaetigung 15 Faelle, Kopfzeile 5 Zustaende, Liste Datei/kaputt/Fallback, Einbau 2x idempotent, Seitenskript %s" % (len(GOLD), js))


MUTS = [
    ("GEO_CONFIRM_S = 1800 ", "GEO_CONFIRM_S = 18000 "), ("GEO_DWD_MIN = 3 ", "GEO_DWD_MIN = 2 "), ("    if lok and amt:\n", "    if lok or amt:\n"),
    ('        lvl, why = "BESTAETIGUNG", ', '        lvl, why = "KATASTROPHE", '), (") if fol else (\"INFO\"", ") if not fol else (\"INFO\""),
    ('and not str(w.get("src") or "").startswith("ASA"):', ':'), ("if c is None and now - t0 <= GEO_CONFIRM_S:", "if c is None:"),
    ('br24=dict(br, state="gelb"', 'br24=dict(br, state="rot"'), ("lst.insert(0, _geo_after)", "lst.append(_geo_after)"),
    ('methods=["GET"]', 'methods=["GET", "POST"]'), ('r"(?i)probe|test|warntag"', 'r"(?i)xyzzy"'), (">= GEO_DWD_MIN:", ">= 1:"),
    ('r"(?<![a-z0-9])" + core', 'core'), ('("" if pre else r"(?![a-z0-9])")', '""'), ('_geo_re.compile(r"(?<![A-Za-zÄÖÜäöüß0-9])" + _geo_re.escape(x)', '_geo_re.compile(r"(?i)(?<![A-Za-zÄÖÜäöüß0-9])" + _geo_re.escape(x)'),
    ("h.textContent=n", "h.innerHTML=n"), ("characterData:true,", ""), ('    if lab.startswith("ECHTALARM"):', '    if "ALARM" in lab:'),
    ('        print("geoRelevanz Bewertung:", e, flush=True)\n        return r\n', '        print("geoRelevanz Bewertung:", e, flush=True)\n        return {"cls": None, "why": "x"}\n'),
    ('"Extremes Unwetter: DWD Unwetterwarnung Stufe 4")', '"Extremes Unwetter: DWD Unwetterwarnung Stufe 4", "Smog")'),
    ('("_lz_ctx", "ctx", _geo_lz_ctx)):', '("_lz_ctx", "ctx", _geo_lz_ctx), ("send_meshtastic", "sm", _geo_lz_ctx)):'),
    ('    if r.get("state") == "rot" and GEO_HOLD_TAG in str', '    if r.get("state") == "rot" and GEO_HOLD_TAG not in str'),
    ('", grau" if lv == "INFO" else ""', '""'), ('            fn._geo = True\n', ''), ("    if lok and amt:\n", "    if lok and amt and False:\n"),
    ('    return resp\n\n\ndef _geo_api', '    send_meshtastic("geo")\n    return resp\n\n\ndef _geo_api'),
    ('            with open(path, encoding="utf-8") as f:', '            with open(path, "a+", encoding="utf-8") as f:'),
    ("import time as _geo_time\n", "import time as _geo_time\nimport subprocess as _geo_sp\n"),
    ('"lokal": ["bayern", ', '"lokal": ['), ('"ausland": ["ukrain*", ', '"ausland": ['), ('"oleschky", ', ''),
    ('                return "NINA"\n', '                return None\n'), ('        return "LAGE: VORALARM", "⚠"\n', '        return None, None\n'),
    ("if note:\n        _geo_note(t, g)\n", "_geo_note(t, g)\n"), ("lst.insert(0, _geo_after)", "lst.insert(0, _geo_after); app.after_request(_geo_after)"),
    ('    elif r.get("state") != "rot":\n', '    elif r.get("state") == "rot":\n'), ('state="gelb", geo_state', 'state="gruen", geo_state'),
    ("now - v.get(\"t\", 0) > 4 * 3600", "now - v.get(\"t\", 0) > -1"),
]


def mutate(altp, neup, bp, jsonp):
    alt, B = rd(altp), blk_text(bp)
    me = os.path.abspath(__file__)
    d = tempfile.mkdtemp()
    caught = missed = 0
    try:
        def run(neu_txt, blk_txt, js=None):
            open(os.path.join(d, "n.py"), "w", encoding="utf-8").write(neu_txt)
            open(os.path.join(d, "b.py"), "w", encoding="utf-8").write(blk_txt)
            jp = js or jsonp
            o = subprocess.run([sys.executable, me, "check", altp, os.path.join(d, "n.py"), os.path.join(d, "b.py"), jp], capture_output=True, text=True, timeout=300, env=dict(os.environ))
            return o.returncode != 0, (o.stdout + o.stderr).strip().splitlines()[-1:] if (o.stdout + o.stderr).strip() else [""]
        ok, msg = run(rd(neup), B)
        if ok:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        cases = []
        for a, b in MUTS:
            if B.count(a) < 1:
                print("UEBERSEHEN (Mutation passt nicht): %r" % a[:60]); missed += 1; continue
            Bm = B.replace(a, b, 1)
            cases.append(("blk " + a[:40], alt.replace(ANCH, "\n\n" + Bm.rstrip("\n") + ANCH, 1), Bm, None))
        neu = rd(neup)
        cases.append(("Zeile ausserhalb", neu.replace("BR24_HOLD_S = ", "BR24_HOLD_S =  ", 1), B, None))
        cases.append(("Block doppelt", neu.replace(ANCH, "\n\n" + B.rstrip("\n") + ANCH, 1), B, None))
        jx = os.path.join(d, "x.json")
        dj = json.load(open(jsonp, encoding="utf-8")); dj["lokal"] = dj["lokal"][1:]
        json.dump(dj, open(jx, "w"), ensure_ascii=False)
        cases.append(("Liste anders", neu, B, jx))
        for name, n_txt, b_txt, js in cases:
            bad, msg = run(n_txt, b_txt, js)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest geoRelevanz: %d erkannt, %d uebersehen%s" % ("OK" if missed == 0 else "FEHLER", caught, missed, " (ohne node)" if os.environ.get("GUARD_NO_NODE") or not shutil.which("node") else ""))
    sys.exit(1 if missed else 0)


def liste(bp, fp):
    B = blk_text(bp)
    g = {"__name__": "geoliste", "_SDR_BASE": os.path.dirname(os.path.abspath(fp))}
    i0 = B.index("_GEO = {")
    exec(compile(B[:B.index("_GEO_BUILTIN = _geo_compile(GEO_DEFAULT)")], "blk", "exec"), g)
    try:
        d = json.load(open(fp, encoding="utf-8"))
        e = g["_geo_valid"](d)
    except Exception as x:
        e, d = "%s: %s" % (type(x).__name__, str(x)[:100]), None
    if e:
        print("LISTE ungueltig: %s" % e); sys.exit(1)
    print("LISTE ok (%s)%s" % (", ".join("%s %d" % (k, len(d[k])) for k in ("lokal", "kfz", "ausland", "de_folgen", "amtlich")), " = eingebaute Liste" if d == g["GEO_DEFAULT"] else " - eigene Fassung (von Hand geaendert)"))


if __name__ == "__main__":
    m = sys.argv[1]
    if m == "revert":
        neu = rd(os.path.join(sys.argv[2], "dashboard.py"))
        os.makedirs(sys.argv[3], exist_ok=True)
        open(os.path.join(sys.argv[3], "dashboard.py"), "w", encoding="utf-8").write(revert(neu, sys.argv[4]))
        print("Rueckbau geoRelevanz ok")
    elif m == "check":
        check(rd(sys.argv[2]), rd(sys.argv[3]), sys.argv[4], sys.argv[5])
    elif m == "mutate":
        mutate(*sys.argv[2:6])
    elif m == "liste":
        liste(sys.argv[2], sys.argv[3])
MK_C48_RAG_EOF
EXPECT_RGJ="02acdd61e474039c90274283f8de530c45958c5ed93c8072a4cdf5d72f7284c7"
cat > "$W/geo_relevanz.json" << 'MK_C48_RGJ_EOF'
{
 "version": 1,
 "hinweis": "geoRelevanz (commit48): Ortsliste fuer BR24/ASA-Warntexte. Eintraege ohne Gross/Klein und Umlaut-egal (ae=ä); * am Ende = Wortanfang; A+B = beide Begriffe noetig. kfz: Kennzeichen, nur in Grossbuchstaben als eigenes Wort. Bei Fehler gilt die eingebaute Liste.",
 "lokal": [
  "bayern",
  "bayerisch*",
  "freistaat",
  "franken",
  "fraenkisch*",
  "mittelfranken",
  "oberfranken",
  "unterfranken",
  "oberbayern",
  "niederbayern",
  "oberpfalz",
  "schwaben",
  "deutschland",
  "bundesweit",
  "bundesgebiet",
  "baden-wuerttemberg",
  "hessen",
  "thueringen",
  "sachsen",
  "sachsen-anhalt",
  "brandenburg",
  "berlin",
  "mecklenburg-vorpommern",
  "niedersachsen",
  "nordrhein-westfalen",
  "rheinland-pfalz",
  "saarland",
  "schleswig-holstein",
  "hamburg",
  "bremen",
  "erlangen",
  "erlangen-hoechstadt",
  "hoechstadt",
  "herzogenaurach",
  "baiersdorf",
  "eckental",
  "heroldsberg",
  "uttenreuth",
  "buckenhof",
  "spardorf",
  "moehrendorf",
  "heroldsbach",
  "hemhofen",
  "adelsdorf",
  "weisendorf",
  "nuernberg",
  "nuernberger land",
  "fuerth",
  "zirndorf",
  "oberasbach",
  "cadolzburg",
  "langenzenn",
  "schwabach",
  "roth",
  "hilpoltstein",
  "lauf an der pegnitz",
  "hersbruck",
  "roethenbach",
  "altdorf",
  "schwarzenbruck",
  "wendelstein",
  "ansbach",
  "dinkelsbuehl",
  "rothenburg",
  "feuchtwangen",
  "herrieden",
  "weissenburg",
  "weissenburg-gunzenhausen",
  "gunzenhausen",
  "treuchtlingen",
  "neustadt an der aisch",
  "neustadt/aisch",
  "bad windsheim",
  "scheinfeld",
  "uffenheim",
  "hoechstadt an der aisch",
  "bamberg",
  "bayreuth",
  "coburg",
  "forchheim",
  "ebermannstadt",
  "graefenberg",
  "kronach",
  "kulmbach",
  "lichtenfels",
  "wunsiedel",
  "marktredwitz",
  "selb",
  "arzberg",
  "muenchberg",
  "naila",
  "helmbrechts",
  "pegnitz",
  "hof/saale",
  "hof (saale)",
  "landkreis hof",
  "stadt hof",
  "wuerzburg",
  "schweinfurt",
  "aschaffenburg",
  "kitzingen",
  "bad kissingen",
  "hassfurt",
  "hassberge",
  "main-spessart",
  "karlstadt",
  "lohr",
  "gemuenden",
  "marktheidenfeld",
  "miltenberg",
  "obernburg",
  "rhoen-grabfeld",
  "bad neustadt",
  "mellrichstadt",
  "muenchen",
  "augsburg",
  "regensburg",
  "ingolstadt",
  "landshut",
  "passau",
  "rosenheim",
  "kempten",
  "memmingen",
  "kaufbeuren",
  "neu-ulm",
  "straubing",
  "freising",
  "dachau",
  "erding",
  "amberg",
  "weiden",
  "neumarkt",
  "eichstaett",
  "kelheim",
  "deggendorf",
  "dingolfing",
  "landsberg",
  "fuerstenfeldbruck",
  "starnberg",
  "garmisch-partenkirchen",
  "bad toelz",
  "traunstein",
  "berchtesgaden",
  "muehldorf",
  "altoetting",
  "pfaffenhofen",
  "neuburg",
  "donauwoerth",
  "noerdlingen",
  "dillingen",
  "guenzburg",
  "lindau",
  "sonthofen",
  "fuessen",
  "weilheim",
  "mindelheim",
  "schwandorf",
  "cham",
  "tirschenreuth",
  "sulzbach-rosenberg",
  "neustadt an der waldnaab",
  "auerbach",
  "steigerwald",
  "fichtelgebirge",
  "frankenwald",
  "fraenkische schweiz",
  "fraenkische alb",
  "fraenkisches seenland",
  "spessart",
  "rhoen",
  "altmuehltal",
  "frankenhoehe",
  "hesselberg",
  "bayerischer wald",
  "allgaeu",
  "chiemgau",
  "chiemsee",
  "ammersee",
  "starnberger see",
  "brombachsee",
  "regnitz",
  "pegnitz",
  "rednitz",
  "aisch",
  "zenn",
  "altmuehl",
  "wiesent",
  "main",
  "donau",
  "isar",
  "inn",
  "lech",
  "naab",
  "iller",
  "wertach",
  "fraenkische saale",
  "tauber",
  "main-donau-kanal"
 ],
 "kfz": [
  "ERH",
  "NEA",
  "WUG",
  "LAU",
  "HEB",
  "LIF",
  "WUN",
  "HAS",
  "MSP",
  "MIL",
  "NES"
 ],
 "ausland": [
  "ukrain*",
  "kiew",
  "kyjiw",
  "charkiw",
  "cherson",
  "odessa",
  "saporischschja",
  "oleschky",
  "mariupol",
  "donezk",
  "luhansk",
  "krim",
  "dnipro",
  "russland",
  "russisch*",
  "moskau",
  "kreml",
  "belarus",
  "weissrussland",
  "gaza",
  "israel*",
  "westjordanland",
  "palaestin*",
  "libanon*",
  "syri*",
  "iran*",
  "irak*",
  "jemen*",
  "nahost",
  "hamas",
  "hisbollah",
  "huthi",
  "tuerkei",
  "tuerkisch*",
  "griechenland",
  "griechisch*",
  "italien*",
  "frankreich",
  "franzoesisch*",
  "spanien",
  "spanisch*",
  "portugal",
  "polen",
  "polnisch*",
  "tschechien",
  "tschechisch*",
  "oesterreich*",
  "schweiz*",
  "niederlande",
  "niederlaendisch*",
  "belgien",
  "daenemark",
  "schweden",
  "norwegen",
  "finnland",
  "ungarn",
  "rumaenien",
  "bulgarien",
  "serbien",
  "kosovo",
  "bosnien",
  "kroatien",
  "slowakei",
  "slowenien",
  "grossbritannien",
  "britisch*",
  "england",
  "london",
  "irland",
  "island",
  "usa",
  "us-bundesstaat",
  "amerikan*",
  "kalifornien",
  "florida",
  "texas",
  "kanada",
  "mexiko",
  "brasilien",
  "argentinien",
  "chile",
  "china",
  "chinesisch*",
  "japan*",
  "taiwan",
  "korea*",
  "indien",
  "indisch*",
  "pakistan",
  "afghanistan",
  "bangladesch",
  "indonesien",
  "philippinen",
  "australien",
  "neuseeland",
  "afrika*",
  "sudan",
  "kongo",
  "nigeria",
  "aegypten",
  "libyen",
  "marokko",
  "tunesien",
  "algerien",
  "aethiopien",
  "somalia",
  "paris",
  "rom",
  "madrid",
  "washington",
  "peking",
  "tokio",
  "ausland*"
 ],
 "de_folgen": [
  "kernkraftwerk*",
  "atomkraftwerk*",
  "akw",
  "reaktor*",
  "radioaktiv*",
  "strahlung*",
  "fallout",
  "nuklear*",
  "atomar*",
  "atomwaffe*",
  "atomangriff*",
  "jodtablette*",
  "pandemie*",
  "epidemie*",
  "seuche*",
  "giftwolke*",
  "aschewolke*",
  "cyberangriff*+strom*",
  "hackerangriff*+strom*",
  "cyberangriff*+netz*"
 ],
 "amtlich": [
  "amtliche gefahrendurchsage",
  "gefahrendurchsage",
  "amtliche warnung",
  "warnung der bevoelkerung",
  "katastrophenfall",
  "katastrophenalarm",
  "landratsamt",
  "katastrophenschutz*",
  "bevoelkerungsschutz",
  "integrierte leitstelle",
  "polizeipraesidium"
 ]
}
MK_C48_RGJ_EOF
EMB="patch.py:$EXPECT_PAL edits.py:$EXPECT_RAE blk.py:$EXPECT_RAB guard.py:$EXPECT_RAG geo_relevanz.json:$EXPECT_RGJ"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (5: Patcher, Stellen, Block, Pruefprogramm, Ortsliste)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
for x in "$F" "$FL" "$FS"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS")
SD=UNBEKANNT; [[ "$D16" == "$KNOWN_D16" ]] && SD=alt; [[ "$D16" == "$KNOWN_D16N" ]] && SD=neu
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit47, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 - $([[ "$L16" == "$KNOWN_L16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
echo "Basis prepper_sdr.py sha16 $S16 - $([[ "$S16" == "$KNOWN_S16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
if [[ "$SD" == UNBEKANNT ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16) - nichts geaendert."
  echo "      commit48 passt nur auf den Stand nach commit47. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
[[ "$L16" == "$KNOWN_L16" ]] || stop "lage_pages.py ist nicht der Stand nach commit47 ($L16 statt $KNOWN_L16)"
[[ "$S16" == "$KNOWN_S16" ]] || stop "prepper_sdr.py ist nicht der Stand nach commit47 ($S16 statt $KNOWN_S16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug/jinja2 nicht"
JS=fehlt
if [[ -e "$FJ" || -L "$FJ" ]]; then
  if [[ -L "$FJ" || ! -f "$FJ" ]]; then stop "geo_relevanz.json ist ein Link oder keine Datei - bitte ansehen"; fi
  J16=$(s16 "$FJ"); JS=eigen; [[ "$J16" == "$KNOWN_J16" ]] && JS=gleich
fi
case "$JS" in
  fehlt) echo "Ortsliste: $FJ fehlt - wird angelegt (eingebaute Liste, danach von Hand aenderbar)";;
  gleich) echo "Ortsliste: $FJ vorhanden = eingebaute Liste";;
  eigen) LC=$(python3 "$W/guard.py" liste "$W/blk.py" "$FJ" 2>&1 || true)
         echo "Ortsliste: $FJ vorhanden, eigene Fassung - wird NICHT angefasst ($LC)";;
esac
# ---- perfWsgi muss laufen (waitress, 8 Arbeitsfaeden) ----
wsst() { "${CURL[@]}" "$B/api/perfwsgi/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("server"), d.get("workers"))' 2>/dev/null || echo "? ?"; }
PCSV=$(wsst)
if [[ "$PCSV" == "waitress 8" ]]; then echo "OK perfWsgi laeuft (waitress, 8 Arbeitsfaeden)"
elif [[ "$DRY" == 1 ]]; then echo "HINWEIS perfWsgi-Status nicht lesbar ($PCSV) - im Trockenlauf unerheblich"
else stop "perfWsgi-Status $PCSV statt 'waitress 8' - Dashboard laeuft nicht wie erwartet"; fi
# ---- Neustart-Sperre HH:55-HH:04 (Berlin); geprueft jetzt, vor dem Ersetzen und fuer die naechsten 150 s ----
rswin() { local m=$(( $1 / 60 % 60 )); [[ $m -ge 55 || $m -lt 5 ]]; }
rssec() { local hm
  if [[ -n "${C48_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$C48_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$STATE" == neu ]]; then echo "OK Neustart-Sperre: commit48 ist schon installiert, es wird kein Neustart gebraucht"
    else stop "Neustart-Sperre: es ist $(rshm "$s0") Uhr (Berlin) - zwischen HH:55 und HH:04 wird prepper-dashboard nicht neu gestartet; bitte ab HH:05 erneut starten"; fi
  else echo "OK Neustart-Sperre: $(rshm "$s0") Uhr (Berlin) liegt ausserhalb HH:55-HH:04 ($1)"; fi; }
rscheck "Vorpruefung"
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
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher; auch lage_pages.py und prepper_sdr.py)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$W/patch.py" geoRelevanz dsh "$F" "$W/work/dashboard.py" "$W/blk.py" "$W/edits.py" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer geoRelevanz nicht eindeutig"; }
[[ "$(s16 "$W/work/dashboard.py")" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $(s16 "$W/work/dashboard.py") statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(wc -l < "$W/work/dashboard.py") Zeilen; $(cat "$W/q.log"))"
python3 "$W/patch.py" geoRelevanz dsh "$W/work/dashboard.py" "$W/work/x1" "$W/blk.py" "$W/edits.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
rm -f "$W/work/x1"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/patch.py" "$W/edits.py" "$W/blk.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
python3 -c "import json, sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$W/geo_relevanz.json" || stop "geo_relevanz.json (eingebettet) ist kein JSON"
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY), Ortsliste lesbar"
cp "$W/work/dashboard.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/blk.py" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: geoRelevanz im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "Guard: Stand ohne geoRelevanz ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" "$W/geo_relevanz.json" > "$W/g.log" 2>&1 || { grep -v "^geoRelevanz" "$W/g.log" | cut -c1-300; stop "Guard geoRelevanz meldet Verstoss"; }
grep "^Guard geoRelevanz" "$W/g.log" | cut -c1-400
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Seitenskript-Test hier statisch; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C48_SIM_NOMUT:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" "$W/geo_relevanz.json" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "Mutationstest geoRelevanz: eine Verfehlung wurde nicht erkannt"; }
[[ "$MUTS" == 0 ]] || grep -E "^OK Mutationstest" "$W/gm.log" | cut -c1-200
# ---------- 3) Zustand vorher (nur Lesen) ----------
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
brst() { "${CURL[@]}" "$B/api/br24" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
print(d.get("state"), bool(d.get("geo_hold")), (d.get("geo_hint") or {}).get("lvl") or "-")' 2>/dev/null || echo "FEHLER"; }
t4lv() { "${CURL[@]}" "$B/api/t4/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
print(((d.get("level") or {}).get("label") or "?").replace(" ", "_"))' 2>/dev/null || echo "FEHLER"; }
read -r BR_S0 BR_H0 BR_G0 <<< "$(brst)"
T4L0=$(t4lv)
PILAT0=$(tmed "$B/pi")
echo "Zustand vorher: BR24 $BR_S0, Lage-Ampel (teil4) $T4L0, /pi Median ${PILAT0} s"
NEED=0; [[ "$STATE" == alt ]] && NEED=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED" == 0 ]]; then echo "  Zustand: geoRelevanz ist schon installiert - ein echter Lauf aendert an dashboard.py nichts (Ortsliste: $JS)."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-$NM-ZEIT, letzte $KEEP_LAST), Ortsliste $([[ "$JS" == fehlt ]] && echo anlegen || echo "unveraendert lassen ($JS)"), nur prepper-dashboard neu starten, pruefen (eine sudo-Passwortabfrage)."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
if [[ "$NEED" == 1 || "$JS" == fehlt ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
INST=()
JNEW=0
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "geoRelevanz|Traceback" | tail -6 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  [[ "$JNEW" == 1 ]] && rm -f -- "$FJ" && echo "  geo_relevanz.json (in diesem Lauf angelegt) wieder entfernt"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  echo "  Datenbank, lage_pages.py, prepper_sdr.py und Mesh-Regeln wurden nicht veraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "${#INST[@]}" -gt 0 || "$JNEW" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$JS" == fehlt ]]; then
  cp "$W/geo_relevanz.json" "$FJ.new" && chmod 644 "$FJ.new" && mv -f "$FJ.new" "$FJ" || { rm -f "$FJ.new"; stop "geo_relevanz.json nicht anlegbar"; }
  JNEW=1
  [[ "$(s16 "$FJ")" == "$KNOWN_J16" ]] || rbx "geo_relevanz.json nach dem Kopieren falsch"
  echo "OK Ortsliste angelegt: $FJ (eingebaute Liste; von Hand aenderbar, wird von spaeteren Laeufen nicht ueberschrieben)"
fi
if [[ "$NEED" == 0 ]]; then
  echo "OK geoRelevanz schon installiert - kein Neustart, keine Aenderung an dashboard.py$([[ "$JNEW" == 1 ]] && echo " (Ortsliste wird beim naechsten Zugriff gelesen)")"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen"
  cp -a "$F" "$F.bak-$NM-$TS"
  { ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  INST+=("$F")
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-$NM-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-$NM-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1
  T0D=$(date +%s)
  echo "Neustart prepper-dashboard (nur dieser Dienst; prepper-sdr bleibt laufen) - warte auf HTTP 200 (max 240 s) ..."
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
echo "OK /pi: Sicherung und Projektbeschreibung da (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung; vorher ${R0}x/${P0}x)"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" "$B/api/geo/status")
[[ "$c1" == 403 || "$c1" == 405 ]] || rbx "POST fremder Origin auf /api/geo/status -> HTTP $c1 (erwartet 403/405)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200); /api/geo/status nur GET (POST -> $c1)"
GEM=$(grep -c "^# ===== geoRelevanz:" "$F" || true)
[[ "$GEM" == 1 ]] && echo "OK Marker geoRelevanz 1x" || rbx "dashboard.py geoRelevanz-Marker ${GEM}x"
gest() { "${CURL[@]}" "$B/api/geo/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
l = d.get("liste") or {}
print(d.get("aktiv"), d.get("confirm_s"), (l.get("src") or "?").split(" ")[0], (d.get("kategorien") or {}).get("lokal"), d.get("err"))' 2>/dev/null || echo "FEHLER"; }
read -r G_AK G_CS G_SRC G_NL G_ERR <<< "$(gest)"
[[ "$G_AK" == True && "$G_CS" == 1800 ]] && echo "OK geoRelevanz aktiv (/api/geo/status: Bestaetigungsfenster ${G_CS} s, Liste: $G_SRC, $G_NL Orte/Gebiete)" || rbx "geoRelevanz nicht aktiv (Status: $G_AK $G_CS $G_ERR)"
[[ "$G_SRC" == Datei ]] || echo "HINWEIS Ortsliste: Dashboard nutzt die eingebaute Liste ($G_SRC) - geo_relevanz.json fehlt oder ist ungueltig (Journal: geoRelevanz Hinweis)"
LOK=0
for i in $(seq 1 30); do
  "${CURL[@]}" "$B/" -o "$W/p1.html" || true
  grep -q 'id="t4Lage" data-t4-orig' "$W/p1.html" && { LOK=1; break; }
  sleep 4
done
if [[ "$LOK" == 1 ]]; then
  grep -q 'id="geoHead"' "$W/p1.html" && grep -q 'id="geo-js"' "$W/p1.html" && echo "OK Lage-Seite: Kopfzeile folgt teil4 ($(grep -o 'id="geoHead"[^<]*' "$W/p1.html" | head -1 | cut -c1-90))" || rbx "Lage-Seite ohne geoHead/geo-js (Kopfzeile nicht eingebunden)"
else echo "HINWEIS Lage-Seite nach 120 s noch im Ladezustand (erstes Voll-Update) - Kopfzeile hier nicht pruefbar; spaeter: curl -s http://127.0.0.1:$PORT/ | grep -c geoHead"; fi
read -r BR_S1 BR_H1 BR_G1 <<< "$(brst)"
T4L1=$(t4lv)
[[ "$BR_S1" != FEHLER && "$T4L1" != FEHLER ]] || rbx "/api/br24 oder /api/t4/status nicht lesbar ($BR_S1 / $T4L1)"
echo "OK Zustand nachher: BR24 $BR_S1 (vorher $BR_S0; Halt bis Bestaetigung: $BR_H1, Hinweis: $BR_G1), Lage-Ampel $T4L1 (vorher $T4L0)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep geoRelevanz"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "geoRelevanz aktiv: geoRelevanz ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'geoRelevanz aktiv: geoRelevanz ok' ($(echo "$JD" | grep -F geoRelevanz | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'geoRelevanz Selbsttest FEHLER|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'geoRelevanz Selbsttest FEHLER|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein geoRelevanz-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
  echo "$JD" | grep -E '^geoRelevanz: |geoRelevanz Hinweis' | tail -3 | cut -c1-200 | sed 's/^/  Journal: /' || true
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)"); prepper-sdr laeuft unveraendert weiter"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"), darunter lage_pages.py und prepper_sdr.py)" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Mesh-Regeln (echte Alarme 6 h Dublettenschutz, max 3/h), Gain-Waechter (Stufe 16), lage_pages.py, prepper_sdr.py und alle Dienste ausser prepper-dashboard unberuehrt"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
echo "  geo_relevanz.json sha16 $(s16 "$FJ" 2>/dev/null || echo fehlt) ($([[ "$JS" == eigen ]] && echo "eigene Fassung, nicht angefasst" || echo "eingebaute Liste"))"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard   (geo_relevanz.json darf liegen bleiben)" || echo "Rueckweg: keine $NM-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c geoRelevanz /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/api/geo/status"
echo "  curl -s http://127.0.0.1:5000/api/br24"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep geoRelevanz"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme, kein Ton). Neue Docs-Version: bewusst nicht."
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
