#!/bin/bash
set -euo pipefail
# br24Warn2 (auf br24Warn 67133d86 oder direkt auf evLog): Warn-Score fuer BR24-Texte und ASA DE (5C):
# rot nur bei starkem Begriff / 2 mittleren / mittel + Verhaltensanweisung; Entwarnung beendet; Probewarnung/Warntag = grau Test;
# Verkehr/Medien/Titel ausgeschlossen, Falschfahrer = Verkehrsgefahr (Info). RadioText erst wenn stabil; PTY 31 rot nur dauerhaft; TA nur Beleg.
# prepper-sdr: 5C im Rundfunk-Block (ASA DE), festes Preset 10D (BDR-Testkanal), welle-cli-Faehigkeitspruefung (nur lesen). Neustart nur prepper-sdr + prepper-dashboard. Sendet nichts, kein neues Netz, kein Mesh.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/br2-apply
UNIT="prepper-sdr.service"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== br24Warn2 apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
BASE_MOD="8c68e3bef6ef1645f651a6809c48fee91e385bb4401bb8883435fb12c75c7b0f"
BR1_MOD="fad5db34c6c33aed482df3ee543a798c2d3308011c1e531f213b1f39d0d1a8e0"
BASE_GPS="2029ad85a90675a47d23a3c6603ef97d2ab740c3aaa0d57bed2183e41b58209d"
EXPECT_PATCH="b1bbc51a16ae9d5a3ae485091916a297bfe63a0f94febf77fee46f2c92159232"
EXPECT_MOD="68b43190df5fa1146eb8816f76932374b20492d8d9077c1dbd58cdc9fa02db8a"
EXPECT_NET="1ffc61d0268fd874e5ff0b5f9a85274875c73a31051b5eb7b067092a90ac2336"
EXPECT_GPS="2029ad85a90675a47d23a3c6603ef97d2ab740c3aaa0d57bed2183e41b58209d"
EXPECT_EV="5e16f710aba58f34b99f718b7adbfbbb38ea1432e70c58631f5805e218a1794b"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-br24-warn2.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""br24Warn2: ersetzt den br24Warn-Block (falls da, nur exakt Stand 67133d86) oder setzt den Block neu vor __main__ in dashboard.py.
Warn-Score fuer BR24 + ASA DE, PTY 31 nur dauerhaft, TA nur Beleg, Entwarnung/Test. Sendet nichts. Verlangt die evLog-Guards."""
import ast
import hashlib
import re
import sys
from pathlib import Path

MARK = "# ===== br24Warn2:"
END = "# ===== /br24Warn2 ====="
OLD_MARK = "# ===== br24Warn:"
OLD_END = "# ===== /br24Warn ====="
OLD_SHA = "2c156d063b10cdcead8376a3cbb56f2a404c653c81497795ef6db951b0d143ef"
NEED = ["# ===== evLog:", "# ===== /evLog =====", "def _sdrf_data():", "def _sdrf_events():", "def _sdrp_bc():", "_SDRF_JS = _SDR_HEAD_JS + r", "def _sdrf_page():", "import json as _sdr_json", "# ===== gpsLearn:", "# ===== /gpsLearn =====", "_SDR_BASE = ", "def _sdr_load(", "def _sdr_status():", "c.id='sdrnQrm'", "g.id='sdrnThunder'", "<div id=\"sdrMain\"></div>", "import sys as _sdrn_sys", "# ===== sdrNoise2:", "# ===== /sdrNoise2 =====", "var G=D.gps||{};if(G.src){var GS=G.G||null,GR=G.R||null;", "# ===== sdrGps:", "# ===== /sdrGps =====", "D.ghist", "var G=D.gps||{};if(G.src){", "rows.insertBefore(gr,rows.firstChild);}", "(function(){var G=(d.status||{}).gps||{};if(!G.src)return;", "# ===== sdrNoise:", "# ===== /sdrNoise =====", "def _sdrn_data():", "def _sdrn_block():", "_SDRN_JS = r", "Störer/QRM: ", "sdrCalRow",
        "var t=N.thunder||{},tl=t.lvl||'grau';", "l.appendChild(c);r.appendChild(l);g.appendChild(r);",
        "var q=(N.qrm||{}).lvl||'grau';", "function drawQ(){var hh=", "if(!B.length)rows.appendChild(",
        "if(b.id==='gps')t+=' · Hinweis auf GPS-Störer nur mit passender L1-Antenne';",
        "[].forEach.call(rows.children,function(x){x.className='sdrn-row';});r.className='sdrn-row sel';drawQ();};rows.appendChild(r);});",
        "# ===== sdrRf:", "# ===== sdrRds:", "# ===== sdrStick:", "# ===== sdrAct:", "# ===== sdrPreset:", "# ===== sdrPlus:", "# ===== sdAck:", "# ===== sdrFunk2:", "# ===== sdrFunk:", "app = Flask("]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)

BLOCK = r'''# ===== br24Warn2: /rundfunk + Funk-Kachel nur BR24-Texte (+ ASA DE), Warn-Score (stark/mittel/Anweisung, Entwarnung, Test, Ausschluesse), PTY 31 nur dauerhaft, TA nur Beleg; BR24-Zeile auf Lage (unter NINA), /funk, /rundfunk; nur lesen/anzeigen, sendet nichts =====
# --br24-pure-begin
import re as _br24_re
import time as _br24_time

# --ws-score-begin (gleicher Text in prepper_sdr.py und dashboard.py br24Warn2)
import re as _ws_re

_WS_F = _ws_re.I
_WS_TEST = _ws_re.compile(r"probealarm|probe-?warnung|warntag|test-?warnung|test-?meldung|warn-?test|dies ist (?:nur )?eine? (?:test|probe)|\btest\b[^.]{0,25}\b(?:asa|warn)", _WS_F)
_WS_END = _ws_re.compile(r"entwarnung|aufgehoben|keine gefahr|gefahr (?:ist )?(?:vorbei|beendet)|warnung (?:ist )?beendet", _WS_F)
_WS_META = _ws_re.compile(r"warnstreik|experten warnen|warnen experten|betrug|betr(?:ü|ue)ger|phishing|podcast|gewinnspiel|gewinnen sie|jetzt (?:läuft|laeuft|on air)|now playing", _WS_F)
_WS_SOFT = _ws_re.compile(r"\bstau\b|verkehr|unfall|\b[AB]\s?\d{1,3}\b|blitzer|baustelle|sperrung|gesperrt|warnt vor|\bapp\b|\bbr\.de\b|br24\.de", _WS_F)
_WS_VERK = _ws_re.compile(r"falschfahrer|geisterfahrer", _WS_F)
_WS_NOWPLAY = _ws_re.compile(r"^[^:!?.]{2,40}\s[-–/]\s[^:!?.]{2,60}$")
_WS_STRONG = [
    ("Amtliche Gefahrendurchsage", r"amtliche\s+gefahrendurchsage"), ("Gefahrendurchsage", r"gefahrendurchsage"),
    ("Amtliche Warnung", r"amtliche\s+warnung"), ("extreme Gefahr", r"extreme\s+gefahr"),
    ("Warnung der Bevölkerung", r"warnung\s+der\s+bev(?:ö|oe)lkerung"),
    ("Fenster und Türen schließen", r"fenster\s+und\s+t(?:ü|ue)ren\s+(?:geschlossen|schlie(?:ß|ss)en|zu)"),
    ("Lüftung/Klimaanlage abschalten", r"(?:l(?:ü|ue)ftung|klimaanlage)[^.]{0,60}(?:ab|aus)(?:zu)?schalten|(?:ab|aus)schalten[^.]{0,40}(?:l(?:ü|ue)ftung|klimaanlage)"),
    ("Gebiet meiden", r"gebiet[^.]{0,25}meiden|meiden\s+sie[^.]{0,30}gebiet"), ("Evakuierung", r"evakuier"), ("Katastrophenfall", r"katastrophenfall")]
_WS_MED = [
    ("Unwetterwarnung DWD/Stufe 3-4", r"unwetterwarnung", r"dwd|wetterdienst|amtlich|(?:warn)?stufe\s*[34]\b"),
    ("extremes Unwetter", r"extreme[sn]?\s+unwetter", None), ("Hochwasser-Warnung", r"hochwasser", r"warn"),
    ("Trinkwasser abkochen", r"trinkwasser[^.]{0,40}abkoch|abkochgebot", None),
    ("Stromausfall + Behörde", r"stromausfall", r"beh(?:ö|oe)rde|landratsamt")]
_WS_STRONG = [(n, _ws_re.compile(r, _WS_F)) for n, r in _WS_STRONG]
_WS_MED = [(n, _ws_re.compile(a, _WS_F), _ws_re.compile(b, _WS_F) if b else None) for n, a, b in _WS_MED]
_WS_BEHAV = _ws_re.compile(r"bleiben sie|halten sie sich|suchen sie|meiden sie|verlassen sie|schlie(?:ß|ss)en sie|informieren sie sich|nicht ins freie|im haus bleiben|drinnen bleiben|begeben sie sich|vermeiden sie", _WS_F)


def _ws_score(t, rtp=None):
    """Text -> {cls: rot|ende|test|verkehr|None, why}. rot nur bei starkem Begriff, 2+ mittleren oder mittel + Verhaltensanweisung."""
    t = " ".join(str(t or "").split())
    if not t:
        return {"cls": None, "why": "leer"}
    m = _WS_TEST.search(t)
    if m:
        return {"cls": "test", "why": "Test: " + m.group(0)}
    m = _WS_META.search(t)
    if m:
        return {"cls": None, "why": "ausgeschlossen: " + m.group(0)}
    m = _WS_END.search(t)
    if m:
        return {"cls": "ende", "why": "Entwarnung: " + m.group(0)}
    st = [n for n, r in _WS_STRONG if r.search(t)]
    if st:
        return {"cls": "rot", "why": "stark: " + ", ".join(st[:3])}
    m = _WS_VERK.search(t)
    if m:
        return {"cls": "verkehr", "why": "Verkehrsgefahr: " + m.group(0)}
    m = _WS_SOFT.search(t)
    if m:
        return {"cls": None, "why": "ausgeschlossen: " + m.group(0)}
    md = [n for n, a, b in _WS_MED if a.search(t) and (b is None or b.search(t))]
    if any(str(x).startswith("item.") for x in (rtp or [])) or (not md and _WS_NOWPLAY.match(t)):
        return {"cls": None, "why": "ausgeschlossen: Titel/Interpret"}
    bh = _WS_BEHAV.search(t)
    if len(md) >= 2 or (md and bh):
        return {"cls": "rot", "why": "mittel: " + ", ".join(md[:3]) + ((" + Anweisung „%s“" % bh.group(0)) if bh else "")}
    return {"cls": None, "why": ("nur 1 mittlerer Begriff: " + md[0]) if md else "kein Warnbegriff"}


_WS_VEC = [
    ("Amtliche Gefahrendurchsage für Erlangen: Fenster und Türen schließen", "rot"), ("Gefahrendurchsage der Polizei Nürnberg", "rot"),
    ("Großbrand: Lüftung und Klimaanlage bitte abschalten", "rot"), ("Bitte das Gebiet um den Hafen weiträumig meiden", "rot"),
    ("Evakuierung in Forchheim nach Bombenfund", "rot"), ("Landratsamt ERH: Katastrophenfall ausgerufen", "rot"),
    ("DWD Unwetterwarnung Stufe 3 für Mittelfranken", None), ("Extremes Unwetter: DWD Unwetterwarnung Stufe 4", "rot"),
    ("Hochwasserwarnung für die Regnitz - bleiben Sie den Ufern fern", "rot"), ("Hochwasserwarnung Regnitz: verlassen Sie die Keller", "rot"),
    ("Trinkwasser in Herzogenaurach abkochen", None), ("Trinkwasser abkochen, Stromausfall laut Landratsamt", "rot"),
    ("Amtliche Unwetterwarnung Landkreis ERH", None), ("Probewarnung zum Warntag", "test"), ("Amtliche Warnung der Bevölkerung - Probealarm", "test"),
    ("Entwarnung für Erlangen: Gefahr ist vorbei", "ende"), ("Die Warnung wurde aufgehoben", "ende"), ("Falschfahrer auf der A73", "verkehr"),
    ("Stau auf der A9 nach Unfall, Warnung vor Glätte", None), ("Blitzer in Fürth", None), ("Warnstreik bei der Bahn", None),
    ("Polizei warnt vor Betrug am Telefon", None), ("Experten warnen vor Hitze", None), ("Phishing-Mails im Umlauf", None),
    ("Podcast: Was tun bei einer Gefahrendurchsage?", None), ("Gewinnspiel: jetzt anrufen", None), ("Hochwasser-Warnung - mehr in der BR24 App", None),
    ("Adele - Hello", None), ("BR24 Nachrichten", None), ("", None)]


def _ws_selftest():
    for t, exp in _WS_VEC:
        r = _ws_score(t)
        assert r["cls"] == exp, (t, r, exp)
    assert _ws_score("Unwetter Sturmwarnung Stufe 3 Extremes Unwetter", ["item.title"])["cls"] is None
    return "warnscore selftest ok (%d Faelle)" % len(_WS_VEC)
# --ws-score-end

BR24_HOLD_S = 2 * 3600      # rot bleibt 2 h nach der letzten Warnung (Entwarnung beendet frueher)
BR24_RX_S = 3 * 3600        # gruen, wenn BR24 in den letzten 3 h empfangen wurde (Rundfunk-Block alle 30 min)
BR24_TEST_S = 3600          # grau "Test" 1 h nach Probewarnung/Warntag
BR24_VERK_S = 1800          # Verkehrsgefahr (Falschfahrer) 30 min als Zusatz in der Zeile
BR24_TA_S = 600             # TA nur als Beleg: TA von BR24 +-10 min um die Warnung
_BR24_NAME = _br24_re.compile(r"^\s*BR\s*-?\s*24(?![0-9])", _br24_re.I)
_BR24_ASA = _br24_re.compile(r"^\s*ASA(?:\s|-|$)", _br24_re.I)
_BR24_DABANN = _br24_re.compile(r"alarm|warn|katastroph|emergency|notfall", _br24_re.I)
_BR24_DABANN_NO = _br24_re.compile(r"traffic|verkehr|transport|news|nachricht|weather|wetter|sport|event|financ|programme|program", _br24_re.I)


def _br24_is_warn_text(t, rtp=None):
    """rot nur nach Warn-Score (stark, 2x mittel oder mittel + Anweisung)."""
    return _ws_score(t, rtp)["cls"] == "rot"


def _br24_fmt(t):
    try:
        return _br24_time.strftime("%d.%m.%Y %H:%M:%S", _br24_time.localtime(int(t)))
    except Exception:
        return "–"


def _br24_match(b):
    """BR24: UKW ueber PS (BR24/BR 24/BR24live) und die so gelernte PI; DAB ueber Dienst-Label und gelernte SId. ASA DE getrennt (Label ASA ...)."""
    fm = {k: v for k, v in ((b or {}).get("fm") or {}).items() if isinstance(v, dict)}
    dab = {k: v for k, v in ((b or {}).get("dab") or {}).items() if isinstance(v, dict)}
    pis = {str(v.get("pi")).upper() for v in fm.values() if v.get("pi") and _BR24_NAME.match(str(v.get("ps") or ""))}
    sids = set()
    for ch, x in dab.items():
        for sv in x.get("services") or []:
            if isinstance(sv, dict) and sv.get("sid") and _BR24_NAME.match(str(sv.get("label") or "")):
                sids.add(str(sv["sid"]).upper())
    mfm = {}
    for k, v in fm.items():
        why = []
        if _BR24_NAME.match(str(v.get("ps") or "")):
            why.append("PS %s" % str(v.get("ps")).strip())
        if v.get("pi") and str(v.get("pi")).upper() in pis:
            why.append("PI %s" % v.get("pi"))
        if not v.get("ps") and not v.get("pi") and _BR24_NAME.match(str(v.get("name") or k)):
            why.append("Name %s (noch ohne PS/PI)" % (v.get("name") or k))
        if why:
            mfm[k] = why
    mdab, masa = {}, {}
    for ch, x in dab.items():
        for sv in x.get("services") or []:
            if not isinstance(sv, dict):
                continue
            lab = str(sv.get("label") or "?")
            why = []
            if _BR24_NAME.match(lab):
                why.append("Label %s" % lab.strip())
            if sv.get("sid") and str(sv["sid"]).upper() in sids:
                why.append("SId %s" % sv["sid"])
            if why:
                mdab.setdefault(ch, {})[lab] = why
            if sv.get("asa") or _BR24_ASA.match(lab):
                masa.setdefault(ch, {})[lab] = ["Label %s" % lab.strip()] + (["SId %s" % sv["sid"]] if sv.get("sid") else [])
    return {"fm": mfm, "dab": mdab, "asa": masa, "pi": sorted(pis), "sid": sorted(sids)}


def _br24_ev_src(e, m):
    """-> 'BR24' / 'ASA' / None: Ereignis gehoert zu BR24 oder ASA DE."""
    k = e.get("k")
    if k in ("rt_warn", "ews", "ta", "pty31"):
        if e.get("src") in m["fm"] or _BR24_NAME.match(str(e.get("ps") or "")) or (e.get("pi") and str(e.get("pi")).upper() in m["pi"]):
            return "BR24"
        return None
    ch = str(e.get("src") or "").replace("DAB", "").strip()
    if k in ("dls", "asa"):
        sv = str(e.get("svc") or "")
        if _BR24_NAME.match(sv) or sv in (m["dab"].get(ch) or {}):
            return "BR24"
        if e.get("asa") or _BR24_ASA.match(sv) or sv in (m["asa"].get(ch) or {}):
            return "ASA"
        return None
    if k in ("dab_ann", "dab_ann_end"):
        return "BR24" if ch in m["dab"] else ("ASA" if ch in m["asa"] else None)
    return None


def _br24_ev_is_br(e, m, b=None):
    return _br24_ev_src(e, m) is not None


def _br24_items(b, events, m):
    """Alle bewerteten Texte/Signale von BR24 + ASA DE: (t, quelle, art, text, cls, why)."""
    fm, dab = b.get("fm") or {}, b.get("dab") or {}
    it = []
    for k in m["fm"]:
        s = fm.get(k) or {}
        t = s.get("t") if isinstance(s.get("t"), (int, float)) else None
        if t and s.get("rt_ok") and s.get("rt_ok") == s.get("rt"):
            sc = _ws_score(s["rt_ok"], s.get("rtp"))
            it.append({"t": t, "src": "BR24 UKW", "kind": "RadioText", "text": s["rt_ok"], "cls": sc["cls"], "score": sc["why"]})
        if t and s.get("pty31_persist"):
            it.append({"t": t, "src": "BR24 UKW", "kind": "RDS PTY 31 Alarm (dauerhaft)", "text": "Programmart Alarm", "cls": "rot", "score": "PTY 31 >= 30 s"})
    for grp, src in ((m["dab"], "BR24 DAB"), (m["asa"], "ASA DE")):
        for ch, svs in grp.items():
            x = dab.get(ch) or {}
            t = x.get("t") if isinstance(x.get("t"), (int, float)) else None
            for sv in x.get("services") or []:
                if t and isinstance(sv, dict) and str(sv.get("label") or "?") in svs and sv.get("dls"):
                    sc = _ws_score(sv.get("dls"))
                    it.append({"t": t, "src": "%s %s" % (src, ch), "kind": "DLS", "text": sv.get("dls"), "cls": sc["cls"], "score": sc["why"]})
            for a in x.get("alarm") or []:
                if t and _BR24_DABANN.search(str(a)) and not _BR24_DABANN_NO.search(str(a)):
                    it.append({"t": t, "src": "%s %s" % (src, ch), "kind": "Ansage/Alarm", "text": str(a), "cls": "rot", "score": "DAB-Alarm-Ansage"})
    for e in events or []:
        if not isinstance(e, dict) or not isinstance(e.get("t"), (int, float)):
            continue
        g = _br24_ev_src(e, m)
        if not g:
            continue
        k = e.get("k")
        ch = str(e.get("src") or "").replace("DAB", "").strip()
        sx = ("BR24 UKW" if k in ("rt_warn", "ews", "pty31", "ta") else ("%s %s" % ("BR24 DAB" if g == "BR24" else "ASA DE", ch)))
        if k == "ews":
            it.append({"t": e["t"], "src": sx, "kind": "RDS Notfall", "text": e.get("text") or "RDS-Notfallgruppe", "cls": "rot", "score": "RDS EWS"})
        elif k == "pty31" and e.get("persist"):
            it.append({"t": e["t"], "src": sx, "kind": "RDS PTY 31 Alarm (dauerhaft)", "text": e.get("text") or "PTY 31", "cls": "rot", "score": "PTY 31 >= 30 s"})
        elif k in ("rt_warn", "dls"):
            sc = _ws_score(e.get("text"))
            it.append({"t": e["t"], "src": sx, "kind": "RadioText" if k == "rt_warn" else "DLS", "text": e.get("text"), "cls": sc["cls"], "score": sc["why"]})
        elif k == "dab_ann" and _BR24_DABANN.search(str(e.get("text"))) and not _BR24_DABANN_NO.search(str(e.get("text"))):
            it.append({"t": e["t"], "src": sx, "kind": "Ansage/Alarm", "text": e.get("text"), "cls": "rot", "score": "DAB-Alarm-Ansage"})
        elif k == "ta" and g == "BR24":
            it.append({"t": e["t"], "src": sx, "kind": "TA", "text": "TA", "cls": "ta", "score": "nur Beleg"})
    return it


def _br24_eval(b, events, now=None):
    """-> Zeile: state gruen/rot/grau (+ test), Text, Grund (Quelle, Art, Auszug, Zeit), Treffer."""
    now = now or _br24_time.time()
    b = b if isinstance(b, dict) else {}
    m = _br24_match(b)
    fm, dab = b.get("fm") or {}, b.get("dab") or {}
    rx, asa_rx = [], []
    for k in m["fm"]:
        t = (fm.get(k) or {}).get("t")
        if isinstance(t, (int, float)):
            rx.append((t, "UKW %s" % str((fm.get(k) or {}).get("f") or "").replace("M", "").replace(".", ",")))
    for ch in m["dab"]:
        t = (dab.get(ch) or {}).get("t")
        if isinstance(t, (int, float)):
            rx.append((t, "DAB %s" % ch))
    for ch in m["asa"]:
        t = (dab.get(ch) or {}).get("t")
        if isinstance(t, (int, float)) and now - t < BR24_RX_S:
            asa_rx.append("ASA DE %s" % ch)
    it = [w for w in _br24_items(b, events, m) if (0 <= now - w["t"] < BR24_HOLD_S) or (w["t"] > now and w["t"] - now < 600)]
    it.sort(key=lambda w: -w["t"])

    def last(c, win=BR24_HOLD_S):
        for w in it:
            if w["cls"] == c and now - w["t"] < win:
                return w
        return None
    red, end, test, verk = last("rot"), last("ende"), last("test", BR24_TEST_S), last("verkehr", BR24_VERK_S)
    if red and end and end["t"] >= red["t"]:
        red = None
    lr = max(rx) if rx else None
    out = {"ok": True, "now": int(now), "match": m, "last_rx": int(lr[0]) if lr else None, "last_src": lr[1] if lr else None,
           "srcs": sorted({s for t, s in rx if now - t < BR24_RX_S}), "asa": sorted(set(asa_rx)), "n_warn": len([w for w in it if w["cls"] == "rot"]),
           "caps": b.get("welle_caps") or None, "test": False,
           "recent": [dict(w, text=" ".join(str(w.get("text") or "").split())[:90], t_txt=_br24_fmt(w["t"])) for w in it[:8]]}

    def ex(w):
        return " ".join(str(w.get("text") or "").split())[:90]
    if red:
        ta = any(w["cls"] == "ta" and abs(w["t"] - red["t"]) <= BR24_TA_S for w in it)
        out.update({"state": "rot", "why": dict(red, text=ex(red), t_txt=_br24_fmt(red["t"]), until=int(red["t"] + BR24_HOLD_S), ta=ta),
                    "text": "%s ⚠ %s: „%s“ · %s%s" % (red["src"], red["kind"], ex(red), _br24_fmt(red["t"]), " · TA aktiv" if ta else "")})
    elif test:
        out.update({"state": "grau", "test": True, "why": dict(test, text=ex(test), t_txt=_br24_fmt(test["t"])),
                    "text": "%s · Test: „%s“ · %s" % (test["src"], ex(test), _br24_fmt(test["t"]))})
    elif lr and now - lr[0] < BR24_RX_S:
        out.update({"state": "gruen", "text": "BR24 empfangen · %s · zuletzt %s" % (" + ".join(out["srcs"]) or lr[1], _br24_fmt(lr[0]))})
    else:
        out.update({"state": "grau", "text": "BR24 · kein Empfang" + (" seit %s (%s)" % (_br24_fmt(lr[0]), lr[1]) if lr else " (noch nie empfangen)")})
    if out["state"] != "rot":
        if end and (not test or end["t"] >= test["t"]):
            out["text"] += " · Entwarnung %s" % _br24_fmt(end["t"])[11:16]
        if verk:
            out["text"] += " · Verkehrsgefahr: „%s“ %s" % (ex(verk)[:50], _br24_fmt(verk["t"])[11:16])
    if out["asa"]:
        out["text"] += " · ASA DE ok"
    return out


def _br24_filter_fm(fm, m):
    """Nur BR24 behaelt RadioText; TA/TP-Kennzeichen entfernt."""
    out = []
    for x in fm:
        x = dict(x)
        for k in ("ta", "tp", "ta_t"):
            x.pop(k, None)
        if x.get("name") not in m["fm"]:
            x["rt"] = None
        out.append(x)
    return out


def _br24_selftest():
    _ws_selftest()
    now = 179 * 10 ** 7
    W = "Amtliche Gefahrendurchsage für Erlangen: Fenster und Türen schließen"
    b = {"fm": {"BR24": {"name": "BR24", "f": "102.0M", "pi": "0xD314", "ps": "BR24", "t": now - 600, "rt": "Nachrichten", "rt_ok": "Nachrichten", "ta": True, "tp": True},
                "Bayern 3": {"name": "Bayern 3", "pi": "0xD313", "ps": "BAYERN 3", "t": now - 300, "rt": W, "rt_ok": W},
                "X": {"name": "X", "pi": "0xd314", "t": now - 100}},
         "dab": {"11D": {"t": now - 900, "services": [{"label": "BR24", "sid": "0xD314", "dls": "Nachrichten"}, {"label": "Bayern 3", "dls": W}], "alarm": []},
                 "5C": {"t": now - 50, "services": [{"label": "ASA DE", "sid": "0x1D11", "asa": True, "dls": "Informationen zu ASA"}, {"label": "Antenne", "dls": W}], "alarm": []}}}
    m = _br24_match(b)
    assert set(m["fm"]) == {"BR24", "X"} and m["pi"] == ["0XD314"] and "PI 0xd314" in m["fm"]["X"] and list(m["dab"]) == ["11D"] and list(m["dab"]["11D"]) == ["BR24"], m
    assert list(m["asa"]["5C"]) == ["ASA DE"], m
    r = _br24_eval(b, [], now)
    assert r["state"] == "gruen" and "UKW 102,0" in r["text"] and "DAB 11D" in r["text"] and r["text"].endswith("ASA DE ok"), r   # fremde Warnungen zaehlen nicht, ASA-Dienst allein nicht rot
    assert _br24_eval(b, [], now + BR24_RX_S + 1)["state"] == "grau"
    assert _br24_eval({}, [], now)["text"].endswith("(noch nie empfangen)")
    ev = [{"t": now - 60, "k": "rt_warn", "src": "BR24", "ps": "BR24", "text": "Stau auf der A9 Warnung vor Glätte"},
          {"t": now - 30, "k": "ta", "src": "BR24", "ps": "BR24"}, {"t": now - 20, "k": "dls", "src": "DAB 11D", "svc": "Bayern 3", "text": W},
          {"t": now - 25, "k": "rt_warn", "src": "BR24", "ps": "BR24", "text": "Amtliche Unwetterwarnung Landkreis ERH"},
          {"t": now - 26, "k": "pty31", "src": "BR24", "ps": "BR24", "persist": False}]
    assert _br24_eval(b, ev, now)["state"] == "gruen"                                                 # Verkehr, TA, fremder Dienst, 1x mittel, PTY kurz: nicht rot
    ev.append({"t": now - 3600, "k": "dls", "src": "DAB 11D", "svc": "BR24", "text": "Amtliche Warnung: Evakuierung in Erlangen-Höchstadt"})
    r = _br24_eval(b, ev, now)
    assert r["state"] == "rot" and r["why"]["src"] == "BR24 DAB 11D" and r["why"]["kind"] == "DLS" and "Erlangen" in r["text"] and r["why"]["t_txt"].count(":") == 2 and not r["why"]["ta"], r
    assert _br24_eval(b, ev, now + 3601)["state"] == "gruen"                                             # nach 2 h wieder gruen
    ev2 = ev + [{"t": now - 3590, "k": "ta", "src": "BR24", "ps": "BR24"}]
    assert _br24_eval(b, ev2, now)["why"]["ta"] and "TA aktiv" in _br24_eval(b, ev2, now)["text"]
    r = _br24_eval(b, ev + [{"t": now - 100, "k": "dls", "src": "DAB 11D", "svc": "BR24", "text": "Entwarnung: die Gefahr ist vorbei"}], now)
    assert r["state"] == "gruen" and "Entwarnung" in r["text"], r
    r = _br24_eval(b, [{"t": now - 100, "k": "dls", "src": "DAB 5C", "svc": "ASA DE", "asa": True, "text": "Probewarnung zum Warntag"}], now)
    assert r["state"] == "grau" and r["test"] and r["text"].startswith("ASA DE 5C · Test"), r
    r = _br24_eval(b, [{"t": now - 100, "k": "dls", "src": "DAB 5C", "svc": "ASA DE", "asa": True, "text": W}], now)
    assert r["state"] == "rot" and r["why"]["src"] == "ASA DE 5C", r
    assert _br24_eval(b, [{"t": now - 5, "k": "pty31", "src": "BR24", "ps": "BR24", "persist": True}], now)["why"]["kind"].startswith("RDS PTY 31")
    b2 = dict(b, fm=dict(b["fm"], BR24=dict(b["fm"]["BR24"], pty31_persist=1)))
    assert _br24_eval(b2, [], now)["state"] == "rot"
    b3 = dict(b, fm=dict(b["fm"], BR24=dict(b["fm"]["BR24"], rt="Achtung: Gefahrendurchsage", rt_ok="Nachrichten")))
    assert _br24_eval(b3, [], now)["state"] == "gruen"                                                # RadioText noch nicht stabil
    b4 = dict(b, fm=dict(b["fm"], BR24=dict(b["fm"]["BR24"], rt="Achtung: Gefahrendurchsage", rt_ok="Achtung: Gefahrendurchsage")))
    assert _br24_eval(b4, [], now)["why"]["kind"] == "RadioText"
    r = _br24_eval(b, [{"t": now - 50, "k": "rt_warn", "src": "BR24", "ps": "BR24", "text": "Falschfahrer auf der A73 bei Erlangen"}], now)
    assert r["state"] == "gruen" and "Verkehrsgefahr" in r["text"], r
    assert _br24_eval(b, [{"t": now - 5, "k": "ews", "src": "BR24", "ps": "BR24"}], now)["why"]["kind"] == "RDS Notfall"
    assert _br24_eval(b, [{"t": now - 5, "k": "dab_ann", "src": "DAB 11D", "text": "announcements=[{\"type\":\"Alarm\"}]"}], now)["state"] == "rot"
    assert _br24_eval(b, [{"t": now - 5, "k": "dab_ann", "src": "DAB 11D", "text": "announcements=[{\"type\":\"Road Traffic\"}]"}], now)["state"] == "gruen"
    assert _br24_eval(b, [{"t": now - 5, "k": "dab_ann", "src": "DAB 8C", "text": "Alarm"}], now)["state"] == "gruen"
    f = _br24_filter_fm(list(b["fm"].values()), m)
    assert [x["rt"] for x in f if x["name"] == "Bayern 3"] == [None] and all("ta" not in x and "tp" not in x for x in f) and f[0]["rt"] == "Nachrichten"
    return "br24 selftest ok (br24Warn2, %d Warn-Score-Faelle)" % len(_WS_VEC)
# --br24-pure-end


def _br24_events():
    try:
        return _sdrf_events()
    except Exception:
        return []


def _br24_state():
    b = _sdr_load("broadcast_state.json", {}) or {}
    return _br24_eval(b, _br24_events())


_br24_orig_sdrf_data = _sdrf_data
_br24_orig_sdrp_bc = _sdrp_bc


def _sdrf_data():
    """/rundfunk: nur BR24-Texte, keine TA-Markierung/-Ereignisse."""
    d = _br24_orig_sdrf_data()
    b = _sdr_load("broadcast_state.json", {}) or {}
    m = _br24_match(b)
    d["events"] = [e for e in (d.get("events") or []) if e.get("k") != "ta" and (e.get("k") not in ("rt_warn", "ews", "dls", "dab_ann", "dab_ann_end") or _br24_ev_is_br(e, m, b))]
    evs = []
    for e in d["events"]:
        if e.get("k") in ("rt_warn", "dls"):
            sc = _ws_score(e.get("text"))
            e = dict(e, w2=sc["cls"] or "", w2why=sc["why"])
            if e.get("k") == "dls":
                e["warn"] = sc["cls"] == "rot"
        evs.append(e)
    d["events"] = evs
    d["fm"] = _br24_filter_fm(d.get("fm") or [], m)
    for x in d.get("dab") or []:
        if str(x.get("label") or "?") not in (m["dab"].get(x.get("ch")) or {}) and str(x.get("label") or "?") not in (m["asa"].get(x.get("ch")) or {}):
            x["dls"] = None
    d["br24"] = _br24_eval(b, d["events"])
    return d


def _sdrp_bc():
    """Funk-Kachel/Status: Warnliste nur BR24 und ohne TA; RadioText nur BR24."""
    d = _br24_orig_sdrp_bc()
    b = _sdr_load("broadcast_state.json", {}) or {}
    m = _br24_match(b)
    names = set(m["fm"])
    w = []
    for x in d.get("warn") or []:
        src = str(x.get("src") or "")
        if x.get("kind") == "TA":
            continue
        ok = src in names
        if src.startswith("DAB "):
            parts = src.split(" ", 2)
            ch = parts[1] if len(parts) > 1 else ""
            lab = parts[2] if len(parts) > 2 else ""
            ok = (ch in m["dab"] and (not lab or lab in m["dab"][ch])) or (ch in m["asa"] and bool(lab) and lab in m["asa"][ch])
        if x.get("kind") == "Ansage" and (not _BR24_DABANN.search(str(x.get("text"))) or _BR24_DABANN_NO.search(str(x.get("text")))):
            ok = False
        if ok and (x.get("kind") != "RT" or _br24_is_warn_text(x.get("text"))) and (x.get("kind") != "DLS" or _br24_is_warn_text(x.get("text"))):
            w.append(x)
    d["warn"] = w
    d["fm"] = _br24_filter_fm(d.get("fm") or [], m)
    return d


def _br24_api():
    from flask import jsonify
    try:
        return jsonify(_br24_state())
    except Exception as e:
        return jsonify({"ok": False, "state": "grau", "text": "BR24: Daten nicht lesbar (%s)" % str(e)[:80]})


_BR24_JS = r"""
(function(){var P=location.pathname.replace(/\/$/,'')||'/';var D=null;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
var CL=(P==='/'?'br24-row card full':'br24-row');function mk(){var r=el('div',CL);r.id='br24Row';r.setAttribute('role','status');return r;}
function fill(r){if(!D)return;var s=D.state||'grau';r.className=CL+' br24-'+s;r.textContent='';var d=el('span','br24-dot');r.appendChild(d);
r.appendChild(el('span','br24-tx',D.text||'BR24'));var w=D.why;var m=D.match||{};
r.title=(w?('Grund: '+w.src+' '+w.kind+' · '+w.t_txt+' · '+w.text+' · rot bis '+new Date(w.until*1000).toLocaleString('de-DE',{timeZone:'Europe/Berlin'})+'\n'):'')+'Erkannt: UKW '+(Object.keys(m.fm||{}).map(function(k){return k+' ('+m.fm[k].join(', ')+')';}).join('; ')||'–')+' · DAB '+(Object.keys(m.dab||{}).map(function(c){return c+': '+Object.keys(m.dab[c]).join(', ');}).join('; ')||'–')+' · ASA '+(Object.keys(m.asa||{}).map(function(c){return c+': '+Object.keys(m.asa[c]).join(', ');}).join('; ')||'–')+(D.caps?'\nwelle-cli: '+D.caps.note:'');if(D.test)r.className+=' br24-test';r.dataset.v=String(D.now)+s;}
function ninaCard(){var ts=document.querySelectorAll('.title,h2,h3');for(var i=0;i<ts.length;i++){if(/\bNINA\b/i.test(ts[i].textContent||'')){var c=ts[i].closest('.card')||ts[i].parentElement;if(c&&c.id!=='br24Row')return c;}}return null;}
function funkLine(){var all=document.querySelectorAll('div,span,a,li');var best=null;for(var i=0;i<all.length;i++){var t=all[i].textContent||'';if(/^\s*(📻|⚠|●)\s*Rundfunk/.test(t)&&t.length<400){if(!best||best.contains(all[i]))best=all[i];}}return best;}
function place(){if(!D)return;var r=document.getElementById('br24Row');var anchor=null,mode='after';
if(P==='/'){anchor=ninaCard();}else if(P==='/funk'){anchor=funkLine();}else if(P==='/rundfunk'){anchor=document.getElementById('sdrMain');mode='first';}
if(!anchor){return;}
if(!r){r=mk();}
var okpos=(mode==='first')?(anchor.firstChild===r):(anchor.nextSibling===r);
if(!okpos){if(mode==='first')anchor.insertBefore(r,anchor.firstChild);else anchor.parentNode.insertBefore(r,anchor.nextSibling);}
if(r.dataset.v!==String(D.now)+(D.state||''))fill(r);}
function load(){fetch('/api/br24',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.state){D=j;var r=document.getElementById('br24Row');if(r)r.dataset.v='';place();}}).catch(function(){});}
try{D=JSON.parse(document.getElementById('br24-data').textContent);}catch(e){}
place();setInterval(place,2000);setInterval(load,30000);})();
"""

_BR24_CSS = """<style id="br24-css">
.br24-row{grid-column:1/-1;display:flex !important;align-items:center;gap:8px;white-space:nowrap;overflow:hidden;padding:6px 10px !important;margin:6px 0;border-radius:10px;font-size:.92rem;box-sizing:border-box;min-width:0}
.br24-row .br24-tx{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.br24-row .br24-dot{flex:0 0 auto;width:10px;height:10px;border-radius:50%;background:currentColor}
.br24-gruen{background:#14532d !important;color:#dcfce7 !important;border:1px solid #22c55e !important}
.br24-rot{background:#7f1d1d !important;color:#fee2e2 !important;border:1px solid #ef4444 !important}
.br24-grau{background:#1f2937 !important;color:#cbd5e1 !important;border:1px solid #475569 !important}
</style>"""


def _br24_inject(body):
    try:
        data = _sdr_json.dumps(_br24_state(), ensure_ascii=False).replace("<", "\\u003c")
    except Exception:
        data = "null"
    add = _BR24_CSS + '<script type="application/json" id="br24-data">' + data + '</script><script id="br24-js">' + _BR24_JS + '</script>'
    j = body.rfind("</body>")
    return (body[:j] + add + body[j:]) if j >= 0 else (body + add)


def _br24_after(resp):
    try:
        from flask import request as _br24_rq
        pth = _br24_rq.path.rstrip("/") or "/"
        if pth in ("/funk", "/rundfunk") and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="br24-js"' not in body:
                resp.set_data(_br24_inject(body))
                resp.headers["X-Br24"] = "1"
    except Exception as e:
        print("br24Warn2:", e, flush=True)
    return resp


_BR24_RF_REPL = [
    ("Rot = Warnung/Alarm, gelb = TA.", "Nur BR24-Texte und ASA DE (5C), andere Sender ausgeblendet; TA wird nicht markiert. Rot nur bei amtlicher Warnung (starker Begriff, 2 mittlere oder mittel + Verhaltensanweisung; RadioText erst wenn vollstaendig/stabil), Entwarnung beendet, Probewarnung = grau Test."),
    ("['MHz','Name','PS','PI','RadioText','zuletzt','TA']", "['MHz','Name','PS','PI','RadioText (nur BR24)','zuletzt']"),
    (",dm(x.t),{t:ta?'TA':(x.ta_t?'zuletzt '+dm(x.ta_t):''),col:ta?YEL:null}]);", ",dm(x.t)]);"),
    ("else if(e.k==='rt_warn'){kind='RDS Warn-Text';col=RED;", "else if(e.k==='rt_warn'){kind=(e.w2==='rot'?'RDS Warn-Text':'RDS Text ('+(e.w2||'kein Alarm')+')');col=(e.w2==='rot'?RED:null);if(e.w2why)e.text=(e.text||'')+' ['+e.w2why+']';"),
    ("else{kind=e.k||'?';txt=e.text||'';}", "else if(e.k==='asa'){kind='ASA DE Dienst';st=(e.src||'')+' · '+(e.svc||'');txt=e.text||'';}else if(e.k==='pty31'){kind='RDS PTY 31';col=e.persist?RED:null;st=(e.ps||e.src||'');txt=e.text||'';}else{kind=e.k||'?';txt=e.text||'';}"),
    ("['Kanal','Ensemble','Dienst','DLS','Stand']", "['Kanal','Ensemble','Dienst','DLS (nur BR24 + ASA DE)','Stand']"),
]


def _br24_patch_js():
    global _SDRF_JS
    js, n = _SDRF_JS, 0
    if "nur BR24" not in js:
        for a, c in _BR24_RF_REPL:
            if js.count(a) == 1:
                js = js.replace(a, c)
                n += 1
    _SDRF_JS = js
    return n


try:
    _br24_n = _br24_patch_js()
    if "br24_api" not in app.view_functions and not any(r.rule == "/api/br24" for r in app.url_map.iter_rules()):
        app.add_url_rule("/api/br24", endpoint="br24_api", view_func=_br24_api, methods=["GET"])
    if not any(getattr(f, "__name__", "") == "_br24_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_br24_after)
    print("br24Warn2 aktiv: Rundfunk-Seite=%s/6, %s" % (_br24_n, _br24_selftest()), flush=True)
except Exception as _br24_e:
    print("br24Warn2:", _br24_e, flush=True)
# ===== /br24Warn2 =====
'''

BLOCK_LM1 = r'''# ===== lageMesh1: Lage-Seite: BR24-Kachel wie NINA direkt unter NINA; Knopf "An Mesh 1 senden" an NINA + BR24 (NUR bei Klick, Bestaetigung, gleicher Ursprung, Sperrzeit, max 200 Zeichen); Knopf "Netzfrequenz an Mesh senden" entfernt =====
import threading as _lm1_threading
import time as _lm1_time

LM1_MAX = 200                 # Zeichen (Bridge schneidet ebenfalls bei 200)
LM1_GAP_S = 120               # je Quelle (NINA/BR24) hoechstens 1x in 2 min
LM1_HOUR_MAX = 6              # zusammen hoechstens 6x pro Stunde
LM1_SAME_S = 1800             # gleicher Text derselben Quelle erst nach 30 min wieder
_lm1_lock = _lm1_threading.Lock()
_lm1_log = []                 # nur im Speicher: (t, src, text) - nach Neustart leer, es wird nie automatisch gesendet
_LM1_SRC = ("nina", "br24")
_LM1_END = _br24_re.compile(r"entwarn|aufheb|aufgehoben|keine warnung|all-clear", _br24_re.I)


def _lm1_nina_lines():
    """Aktive NINA-Warnungen (wie die Kachel), Entwarnungen weg."""
    ds = globals().get("data_store") or {}
    v = (ds.get("nina") or {}).get("value")
    if not isinstance(v, list):
        return []
    nl, alert = globals().get("nina_lines"), globals().get("nina_is_alert")
    items = []
    for w in v:
        if isinstance(w, dict):
            title = str(w.get("title") or w.get("headline") or "").strip()
            if _LM1_END.search(title):
                continue
            if callable(alert):
                try:
                    if not alert(title):
                        continue
                except Exception:
                    pass
        items.append(w)
    if callable(nl):
        try:
            return [str(x) for x in nl(items) if str(x).strip()]
        except Exception:
            pass
    out = []
    for w in items:
        x = ("%s: %s" % (w.get("city") or "", w.get("title") or "")).strip(": ").strip() if isinstance(w, dict) else str(w).strip()
        if x and x not in out:
            out.append(x)
    return out


def _lm1_cut(t):
    t = " ".join(str(t or "").split())
    return t if len(t) <= LM1_MAX else t[:LM1_MAX - 1].rstrip() + "…"


def _lm1_texts():
    """Aktueller Sendetext je Quelle oder None (dann Knopf grau)."""
    n = _lm1_nina_lines()
    nina = _lm1_cut("NINA: " + "; ".join(n)) if n else None
    try:
        r = _br24_state()
    except Exception:
        r = {"state": "grau", "text": "BR24: Daten nicht lesbar"}
    br = None
    if r.get("state") == "rot" and isinstance(r.get("why"), dict):
        w = r["why"]
        br = _lm1_cut("BR24 Warnung %s %s %s: %s" % (str(w.get("t_txt") or "")[:16], w.get("src") or "", w.get("kind") or "", w.get("text") or ""))
    return {"nina": nina, "br24": br, "row": r, "nina_n": len(n)}


def _lm1_wait(src, text, now):
    """Sekunden bis wieder erlaubt (0 = jetzt erlaubt)."""
    w = 0
    hour = [x for x in _lm1_log if now - x[0] < 3600]
    if len(hour) >= LM1_HOUR_MAX:
        w = max(w, int(3600 - (now - hour[0][0])) + 1)
    for t, s, tx in _lm1_log:
        if s == src and now - t < LM1_GAP_S:
            w = max(w, int(LM1_GAP_S - (now - t)) + 1)
        if s == src and tx == text and now - t < LM1_SAME_S:
            w = max(w, int(LM1_SAME_S - (now - t)) + 1)
    return w


def _lm1_status():
    now = _lm1_time.time()
    tx = _lm1_texts()
    out = {"ok": True, "now": int(now), "sent_n": len(_lm1_log), "row": tx["row"], "max": LM1_MAX}
    for s in _LM1_SRC:
        last = [x for x in _lm1_log if x[1] == s]
        out[s] = {"active": bool(tx[s]), "text": tx[s] or "", "wait": _lm1_wait(s, tx[s], now) if tx[s] else 0,
                  "last": _br24_fmt(last[-1][0]) if last else None}
    out["nina"]["n"] = tx["nina_n"]
    return out


def _lm1_api():
    from flask import jsonify
    try:
        return jsonify(_lm1_status())
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:80], "nina": {"active": False}, "br24": {"active": False}})


def _lm1_same_origin(rq):
    base = rq.host_url.rstrip("/")
    o = rq.headers.get("Origin")
    if o is not None and o.rstrip("/") != base:
        return False
    ref = rq.headers.get("Referer") or ""
    if o is None and not (ref == base or ref.startswith(base + "/")):
        return False
    sfs = rq.headers.get("Sec-Fetch-Site")
    if sfs is not None and sfs != "same-origin":
        return False
    return rq.headers.get("X-Lage-Mesh1") == "1" and (rq.mimetype or "") == "application/json"


def _lm1_send_post():
    """Einzige Sendestelle: nur per Klick auf 'An Mesh 1 senden' (POST, gleicher Ursprung, confirm, bestaetigter Text = aktueller Text)."""
    from flask import jsonify, request as rq
    if not _lm1_same_origin(rq):
        return jsonify({"ok": False, "error": "nur von der Lage-Seite (gleicher Ursprung)"}), 403
    j = rq.get_json(silent=True) or {}
    src = j.get("src")
    if src not in _LM1_SRC or j.get("confirm") is not True or not isinstance(j.get("text"), str):
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _lm1_lock:
        now = _lm1_time.time()
        text = _lm1_texts()[src]
        if not text:
            return jsonify({"ok": False, "error": "keine aktive Warnung"}), 409
        if j["text"] != text:
            return jsonify({"ok": False, "error": "Warnung hat sich geaendert - bitte neu bestaetigen", "text": text}), 409
        w = _lm1_wait(src, text, now)
        if w:
            return jsonify({"ok": False, "error": "Sperrzeit, noch %d s" % w, "wait": w}), 429
        _lm1_log.append((now, src, text))
        del _lm1_log[:-50]
        ok = bool(send_meshtastic(text, channel=0))
    print("lageMesh1: %s per Klick an Mesh 1 (Kanal 0): %s -> %s" % (src, text[:80], "ok" if ok else "FEHLER"), flush=True)
    return jsonify({"ok": ok, "src": src, "text": text, "at": _br24_fmt(now)})


def _lm1_freq_gone(*a, **kw):
    from flask import jsonify
    return jsonify({"ok": False, "error": "entfernt (lageMesh1): Netzfrequenz wird nicht mehr per Knopf gesendet"}), 410


def _lm1_strip_freq(body):
    """Karte mit dem Knopf 'Netzfrequenz an Mesh senden' (id freqMeshBtn) aus der Lage-Seite entfernen."""
    i = body.find('id="freqMeshBtn"')
    if i < 0:
        return body, 0
    a = body.rfind('<div class="card"', 0, i)
    s = body.find("</script>", i)
    e = body.find("</div>", s) if s >= 0 else -1
    seg = body[a:e + 6] if a >= 0 and e > 0 else ""
    if seg and len(seg) < 4000 and "sendFreqMesh" in seg and "NINA" not in seg and seg.count("<button") == 1 and body[a:i].count("<div") == 1:
        return body[:a] + "<!-- lageMesh1: Netzfrequenz-Knopf entfernt -->" + body[e + 6:], 1
    return body.replace('id="freqMeshBtn"', 'id="freqMeshBtnAus" hidden disabled', 1).replace('onclick="sendFreqMesh()"', "", 1), 2


_LM1_JS = r"""
(function(){var D=null,BUSY={};
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function ninaCard(){var ts=document.querySelectorAll('.title');for(var i=0;i<ts.length;i++){if(/\bNINA\b/i.test(ts[i].textContent||'')){var c=ts[i].closest('.card');if(c&&c.id!=='br24Tile')return c;}}return null;}
var BS='margin-top:10px;width:100%;background:#1e3a5f;color:#93c5fd;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:0.95rem';
var BO='margin-top:10px;width:100%;background:#1f2937;color:#64748b;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:0.95rem;cursor:not-allowed';
function btn(card,src){var b=card.querySelector('.lm1-btn[data-src="'+src+'"]');if(!b){b=el('button','lm1-btn','📡 An Mesh 1 senden');b.type='button';b.dataset.src=src;
var st=el('div','small lm1-st');st.style.marginTop='6px';st.style.color='#94a3b8';b.addEventListener('click',function(){go(src,b,st);});card.appendChild(b);card.appendChild(st);}
var x=(D&&D[src])||{};var on=!!x.active&&!BUSY[src];b.disabled=!on;b.setAttribute('style',on?BS:BO);
b.title=x.active?('Sendet nur nach Bestätigung an Mesh 1: '+x.text):'keine aktive Warnung – nichts zu senden';
var st2=b.nextSibling;if(st2&&!BUSY[src]&&!st2.dataset.keep)st2.textContent=(x.active?'bereit':'keine aktive Warnung')+(x.last?' · zuletzt gesendet '+x.last:'')+(x.wait?' · Sperrzeit '+x.wait+' s':'');}
function go(src,b,st){var x=(D&&D[src])||{};if(!x.active||BUSY[src])return;
if(!window.confirm('Wirklich an Mesh 1 senden?\n\n'+x.text+'\n\n('+x.text.length+' Zeichen)'))return;
BUSY[src]=1;b.disabled=true;st.dataset.keep='1';st.textContent='Sende…';
fetch('/api/lage_mesh1/send',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-Lage-Mesh1':'1'},body:JSON.stringify({src:src,confirm:true,text:x.text})})
.then(function(r){return r.json();}).then(function(j){st.textContent=j.ok?('gesendet '+(j.at||'')):('nicht gesendet: '+(j.error||'Fehler'));})
.catch(function(){st.textContent='nicht gesendet: Netzfehler';}).then(function(){BUSY[src]=0;setTimeout(function(){delete st.dataset.keep;},20000);load();});}
function tile(){var n=ninaCard();if(!n||!D)return;var t=document.getElementById('br24Tile');
if(!t){t=el('div',n.className);t.id='br24Tile';t.appendChild(el('div','title','BR24 Warnungen'));var l=el('div','lm1-line');t.appendChild(l);var s=el('div','small lm1-upd');t.appendChild(s);}
if(n.nextSibling!==t)n.parentNode.insertBefore(t,n.nextSibling);
var R=D.row||{},l2=t.querySelector('.lm1-line'),s2=t.querySelector('.lm1-upd');var st=R.state||'grau';
l2.className='lm1-line'+(st==='gruen'?' online':'');l2.textContent=R.text||'BR24';l2.style.cssText='white-space:nowrap;overflow:hidden;text-overflow:ellipsis;'+(st==='rot'?'color:#ef4444;font-weight:600':(st==='gruen'?'':'color:#94a3b8'));
var w=R.why;s2.textContent=(w?('Grund: '+w.score+' · rot bis '+new Date(w.until*1000).toLocaleString('de-DE',{timeZone:'Europe/Berlin'})):(R.test?'Probewarnung/Test':'BR24 + ASA DE · nur Empfang'));
btn(n,'nina');btn(t,'br24');}
function load(){fetch('/api/lage_mesh1',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.ok){D=j;tile();}}).catch(function(){});}
try{D=JSON.parse(document.getElementById('lm1-data').textContent);}catch(e){}
tile();setInterval(tile,2000);setInterval(load,30000);})();
"""


def _lm1_after(resp):
    try:
        from flask import request as _lm1_rq
        if (_lm1_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="lm1-js"' not in body:
                body, nf = _lm1_strip_freq(body)
                try:
                    data = _sdr_json.dumps(_lm1_status(), ensure_ascii=False).replace("<", "\\u003c")
                except Exception:
                    data = "null"
                add = '<script type="application/json" id="lm1-data">' + data + '</script><script id="lm1-js">' + _LM1_JS + '</script>'
                j = body.rfind("</body>")
                body = (body[:j] + add + body[j:]) if j >= 0 else (body + add)
                resp.set_data(body)
                resp.headers["X-Lm1"] = "freq%d" % nf
    except Exception as e:
        print("lageMesh1:", e, flush=True)
    return resp


try:
    _lm1_fq = 0
    for _lm1_r in list(app.url_map.iter_rules()):
        if _lm1_r.rule == "/api/mesh_freq" and _lm1_r.endpoint in app.view_functions:
            app.view_functions[_lm1_r.endpoint] = _lm1_freq_gone
            _lm1_fq += 1
    if "lm1_api" not in app.view_functions:
        app.add_url_rule("/api/lage_mesh1", endpoint="lm1_api", view_func=_lm1_api, methods=["GET"])
    if "lm1_send" not in app.view_functions:
        app.add_url_rule("/api/lage_mesh1/send", endpoint="lm1_send", view_func=_lm1_send_post, methods=["POST"])
    if not any(getattr(f, "__name__", "") == "_lm1_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_lm1_after)
    print("lageMesh1 aktiv: BR24-Kachel unter NINA, Knopf An Mesh 1 nur per Klick, /api/mesh_freq gesperrt=%d, gesendet seit Start=%d" % (_lm1_fq, len(_lm1_log)), flush=True)
except Exception as _lm1_e:
    print("lageMesh1:", _lm1_e, flush=True)
# ===== /lageMesh1 =====
'''
LM1_MARK = "# ===== lageMesh1:"


def h16(s):
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    src = f.read_text(encoding="utf-8")
    h = h16(src)
    a, b = BLOCK.index("# --br24-pure-begin"), BLOCK.index("# --br24-pure-end")
    ns = {}
    exec(compile(BLOCK[a:b], "br24-pure", "exec"), ns)
    print("OK " + ns["_br24_selftest"]())
    if MARK in src:
        if BLOCK not in src or OLD_MARK in src:
            raise SystemExit("STOP: br24Warn2-Guard da, aber Block weicht ab (sha16 %s) - nichts geaendert" % h)
        if LM1_MARK in src:
            if BLOCK_LM1 not in src or src.count(LM1_MARK) != 1:
                raise SystemExit("STOP: lageMesh1-Guard da, aber Block weicht ab (sha16 %s) - nichts geaendert" % h)
            print("RESULT dashboard.py=schon sha16 %s" % h)
            return
        if "_lm1_" in src or "/api/lage_mesh1" in src:
            raise SystemExit("STOP: lageMesh1-Teile ohne Guard - nichts geaendert")
        k = src.index(BLOCK) + len(BLOCK)
        new = src[:k] + "\n" + BLOCK_LM1 + src[k:]
        ast.parse(new)
        compile(new, str(f), "exec")
        tmp = f.with_name(f.name + ".br2tmp")
        tmp.write_text(new, encoding="utf-8")
        tmp.replace(f)
        print("RESULT dashboard.py=neu (lageMesh1 nachgetragen; sha16 vorher %s, nachher %s)" % (h, h16(new)))
        return
    if LM1_MARK in src or "_lm1_" in src or "/api/lage_mesh1" in src:
        raise SystemExit("STOP: lageMesh1 ohne br24Warn2 - nichts geaendert")
    miss = [x for x in NEED if x not in src]
    if miss:
        raise SystemExit("STOP: dashboard.py sha16 %s ohne %s (evLog nicht installiert?) - nichts geaendert" % (h, miss))
    if src.count("# ===== evLog:") != 1:
        raise SystemExit("STOP: evLog doppelt - nichts geaendert")
    base = "evLog"
    if OLD_MARK in src:
        if src.count(OLD_MARK) != 1 or src.count(OLD_END) != 1:
            raise SystemExit("STOP: br24Warn-Block doppelt/unvollstaendig - nichts geaendert")
        i = src.index(OLD_MARK)
        j = src.index(OLD_END) + len(OLD_END) + 1
        if j <= i or hashlib.sha256(src[i:j].encode()).hexdigest() != OLD_SHA:
            raise SystemExit("STOP: br24Warn-Block ist nicht der Stand 67133d86 (sha16 %s) - nichts geaendert" % hashlib.sha256(src[i:j].encode()).hexdigest()[:16])
        rest = src[:i] + src[j:]
        if "def _br24_" in rest or "br24-js" in rest or "/api/br24" in rest:
            raise SystemExit("STOP: br24-Teile ausserhalb des Blocks - nichts geaendert")
        new = src[:i] + BLOCK + "\n" + BLOCK_LM1 + src[j:]
        base = "br24Warn (ersetzt)"
    else:
        if "def _br24_" in src or "br24-js" in src or "/api/br24" in src:
            raise SystemExit("STOP: br24-Teile/Route schon da - nichts geaendert")
        ms = list(MAIN_RE.finditer(src))
        if len(ms) != 1:
            raise SystemExit("STOP: __main__ %d mal" % len(ms))
        p = ms[0].start()
        if p < src.index("# ===== /evLog =====") or ("# ===== /umweltWide =====" in src and p < src.index("# ===== /umweltWide =====")):
            raise SystemExit("STOP: __main__ vor evLog/umweltWide-Block")
        new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n" + BLOCK_LM1 + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    tmp = f.with_name(f.name + ".br2tmp")
    tmp.write_text(new, encoding="utf-8")
    tmp.replace(f)
    print("RESULT dashboard.py=neu (Basis %s; sha16 vorher %s, nachher %s)" % (base, h, h16(new)))


if __name__ == "__main__":
    main()
PATCHPY_EOF
cat > "$W/prepper_sdr.py" << 'MODPY_EOF'
#!/usr/bin/env python3
"""prepper_sdr: SDR-Planer fuer den RTL-SDR-Stick (nur Empfang, sendet nichts - weder Funk noch Mesh).

Ein Programm besitzt den Stick und teilt ihn zeitlich auf:
  433  = rtl_433 auf 433,92 MHz (ISM-Sensoren) -> rtl433.jsonl + funk433_state.json
  aprs = rtl_fm 144,800 MHz | direwolf (APRS, Amateurfunk) -> aprs.jsonl + aprs_state.json
  tcp  = rtl_tcp Port 1234 fuer SDR-Apps im LAN (Decoder pausiert, endet automatisch)
  bc   = alle 30 min kurzer Rundfunk-Block: UKW-RDS (rtl_fm | redsea: PS/Radiotext/TA) + DAB+ (welle-cli: DLS/Ansagen)
  meteor = Wettersatellit Meteor-M LRPT 137,9 MHz (satdump) bei Ueberfluegen >= 20 Grad, hat dann Vorrang
Nur Empfang: Rundfunk + Wettersatellit + ISM + Amateurfunk.
Betriebsart steht in sdr_mode.json (schreibt das Dashboard). Status: sdr_status.json.
Fehlt der Stick, wartet der Planer ruhig (kein Neustart-Karussell). Nur ISM/Amateurfunk, keine Pager-/BOS-Dekodierung.
Aufruf: prepper_sdr.py run | selftest | status
"""
import json
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time

V = 10
BASE = os.path.dirname(os.path.abspath(__file__))
MODES = ("auto", "433", "aprs", "tcp", "off")
DEFAULT_CFG = {
    "slice_433_s": 300, "slice_aprs_s": 300, "auto": ["433", "aprs"],
    "f433": "433.92M", "faprs": "144.800M", "ppm": 0, "gain_433": None, "gain_aprs": None,
    "device": None, "serial": "19348831", "dab_tcp_port": 1235, "tcp_port": 1234, "tcp_bind": "0.0.0.0", "tcp_default_min": 60, "tcp_max_min": 480,
    "usb_ids": ["0bda:2838", "0bda:2832"], "max_jsonl_mb": 8, "aprs_max_jsonl_mb": 4,
    "home": None, "keep_days": 14,
    "bc_enable": True, "bc_interval_s": 1800, "fm": None, "fm_s": 60, "dab": None, "dab_s": 60, "dab_port": 7979, "gain_fm": 40, "gain_dab": None, "gain_act": None,
    "meteor_enable": True, "sats": None, "meteor_min_el": 20, "meteor_gain": 38, "meteor_samplerate": "1024000",
    "meteor_keep": 30, "meteor_cap_mb": 300, "meteor_tmp": "/tmp/prepper-meteor", "tle_refresh_h": 12,
    "redsea": None, "welle": None, "satdump": None,
    "noise_enable": True, "noise_interval_s": 900, "noise_s": 7, "noise_hf": True, "gain_noise": 30, "noise_car_db": 10, "noise_car_n": 4,
    "noise_raise_yel": 5, "noise_raise_red": 10, "noise_k_yel": 4, "noise_k_red": 6, "noise_trend_lambda": 0.03, "noise_trend_db": 2.0, "noise_trend_off_db": 1.0, "noise_warmup_s": 300, "thunder_yel_pm": 5, "thunder_red_pm": 20,
    "gps_enable": True, "gps_interval_s": 120, "gps_read_s": 6, "gps_persist": 3, "gps_drop_yel": 6, "gps_drop_red": 10,
    "cal_enable": True, "cal_hour": 3, "cal_s": 45, "cal_step_ppm": 5, "ppm_auto": True, "ppm_cal": None,
    "linelog_enable": True, "linelog_keyword": None, "linelog_flush_s": 300, "linelog_part_kb": 512, "linelog_keep_days": 14,
}

# ---------------------------------------------------------------- Frequenz-Whitelist (einzige Quelle; Dashboard + Planer nutzen sie)
# Nur Empfang. Erlaubte Bereiche in MHz - alles andere wird verweigert (auch aus sdr_config.json).
F_RANGES = {"ism433": (433.05, 434.79), "srd868": (863.0, 870.0), "aprs": (144.8, 144.8), "fm": (87.5, 108.0),
            "dab": (174.0, 240.0), "wxsat": (137.0, 138.0),
            "act2m": (145.5, 145.5), "pmr446": (446.0, 446.2),
            "noise_mw": (0.5, 1.6), "noise_hf": (9.9, 10.2), "noise2m": (144.0, 146.0), "noisefm": (87.5, 108.0), "noisedab": (174.0, 240.0),
            "noisepmr": (446.0, 446.2), "noise433": (433.05, 434.79), "noise868": (863.0, 870.0), "noisegps": (1573.42, 1577.42)}
# Messbereiche Funkumgebung: nur Leistung je Bin (rtl_power / Direktabtastung), keine Demodulation, nur Zahlen
NOISE_KINDS = ("noise_mw", "noise_hf", "noise2m", "noisefm", "noisedab", "noisepmr", "noise433", "noise868", "noisegps")
# nur Aktivitaetsmessung (Kanalleistung gegen Rauschen) - kein Demodulieren, keine Aufnahme, kein Inhalt
ACT_KINDS = ("act2m", "pmr446")
# DAB Band III Kanaltabelle (Mittenfrequenz MHz) - DAB nur ueber Kanalnamen
DAB_CHANNELS = {"5A": 174.928, "5B": 176.640, "5C": 178.352, "5D": 180.064, "6A": 181.936, "6B": 183.648, "6C": 185.360, "6D": 187.072,
                "7A": 188.928, "7B": 190.640, "7C": 192.352, "7D": 194.064, "8A": 195.936, "8B": 197.648, "8C": 199.360, "8D": 201.072,
                "9A": 202.928, "9B": 204.640, "9C": 206.352, "9D": 208.064, "10A": 209.936, "10B": 211.648, "10C": 213.360, "10D": 215.072,
                "11A": 216.928, "11B": 218.640, "11C": 220.352, "11D": 222.064, "12A": 223.936, "12B": 225.648, "12C": 227.360, "12D": 229.072,
                "13A": 230.784, "13B": 232.496, "13C": 234.208, "13D": 235.776, "13E": 237.488, "13F": 239.200}
# Feste Auswahl fuer die Funk-Kachel (Preset-ID -> Empfang). Keine freie Frequenz.
PRESETS = [
    {"id": "433", "group": "Sensoren", "label": "433,92 MHz Sensoren (rtl_433)", "kind": "ism433", "f": "433.92M"},
    {"id": "868", "group": "Sensoren", "label": "868,3 MHz Sensoren (rtl_433)", "kind": "srd868", "f": "868.3M"},
    {"id": "aprs", "group": "Amateurfunk", "label": "APRS 144,800 MHz (direwolf)", "kind": "aprs", "f": "144.800M"},
    {"id": "fm_br24", "group": "UKW-RDS", "label": "BR24 102,0", "kind": "fm", "f": "102.0M", "name": "BR24"},
    {"id": "fm_b3", "group": "UKW-RDS", "label": "Bayern 3 97,9", "kind": "fm", "f": "97.9M", "name": "Bayern 3"},
    {"id": "fm_b1", "group": "UKW-RDS", "label": "Bayern 1 88,9", "kind": "fm", "f": "88.9M", "name": "Bayern 1"},
    {"id": "fm_b2", "group": "UKW-RDS", "label": "Bayern 2 92,3", "kind": "fm", "f": "92.3M", "name": "Bayern 2"},
    {"id": "fm_brk", "group": "UKW-RDS", "label": "BR-Klassik 87,6", "kind": "fm", "f": "87.6M", "name": "BR-Klassik"},
    {"id": "fm_gong", "group": "UKW-RDS", "label": "Gong 97,1 (Nürnberg)", "kind": "fm", "f": "97.1M", "name": "Gong 97,1"},
    {"id": "fm_chari", "group": "UKW-RDS", "label": "Charivari 98,6 (Nürnberg)", "kind": "fm", "f": "98.6M", "name": "Charivari"},
    {"id": "fm_n1", "group": "UKW-RDS", "label": "Hit Radio N1 92,9 (Nürnberg)", "kind": "fm", "f": "92.9M", "name": "Hit Radio N1"},
    {"id": "fm_980", "group": "UKW-RDS", "label": "UKW 98,0 MHz", "kind": "fm", "f": "98.000M", "name": "UKW 98,0"},
    {"id": "dab_11D", "group": "DAB+", "label": "11D BR Bayern", "kind": "dab", "ch": "11D"},
    {"id": "dab_8C", "group": "DAB+", "label": "8C BR Mittelfranken", "kind": "dab", "ch": "8C"},
    {"id": "dab_10C", "group": "DAB+", "label": "10C Nürnberg lokal", "kind": "dab", "ch": "10C"},
    {"id": "dab_5C", "group": "DAB+", "label": "5C DR Deutschland", "kind": "dab", "ch": "5C"},
    {"id": "dab_5D", "group": "DAB+", "label": "5D Antenne DE", "kind": "dab", "ch": "5D"},
    {"id": "dab_10D", "group": "DAB+", "label": "10D BDR Testkanal (ASA-Test, Büttelberg/Wendelstein)", "kind": "dab", "ch": "10D"},
    {"id": "met_1379", "group": "Wettersatellit", "label": "Meteor-M2 3/4 · 137,9 MHz (satdump)", "kind": "wxsat", "f": "137.9e6"},
    {"id": "met_1371", "group": "Wettersatellit", "label": "Meteor-M2 3/4 · 137,1 MHz Ersatzfrequenz (satdump)", "kind": "wxsat", "f": "137.1e6"},
    {"id": "act_1455", "group": "Aktivität (nur Pegel)", "label": "2 m Anruf 145,500 – nur Aktivität", "kind": "act2m", "f": "145.500M", "short": "145,500"},
    {"id": "act_pmr3", "group": "Aktivität (nur Pegel)", "label": "PMR446 Kanal 3 446,03125 – nur Aktivität", "kind": "pmr446", "f": "446.03125M", "short": "PMR3"},
]
PRESET_IDS = tuple(x["id"] for x in PRESETS)
PRESET_MINUTES = (30, 60, 120)


def preset(pid):
    for x in PRESETS:
        if x["id"] == pid:
            return x
    return None


def to_mhz(v):
    """'433.92M' / '137.9e6' / Zahl (Hz oder MHz) -> MHz (float) oder None."""
    try:
        if isinstance(v, (int, float)):
            x = float(v)
        else:
            t = str(v).strip()
            if t.endswith("M"):
                return float(t[:-1])
            if t.endswith("k"):
                return float(t[:-1]) / 1000.0
            x = float(t)
        return x / 1e6 if x > 10000 else x
    except Exception:
        return None


def tune_ok(kind, f=None, ch=None):
    """True nur wenn die Frequenz im erlaubten Bereich der Art liegt (DAB nur per Kanaltabelle)."""
    if kind == "dab":
        mhz = DAB_CHANNELS.get(str(ch))
        lo, hi = F_RANGES["dab"]
        return mhz is not None and lo <= mhz <= hi
    if kind not in F_RANGES:
        return False
    mhz = to_mhz(f)
    if mhz is None:
        return False
    lo, hi = F_RANGES[kind]
    if kind == "aprs":
        return abs(mhz - 144.8) < 1e-6
    if kind == "act2m":
        return abs(mhz - 145.5) < 1e-6
    return lo <= mhz <= hi


def check_tune(kind, f=None, ch=None):
    if not tune_ok(kind, f, ch):
        raise RuntimeError("Frequenz verweigert: %s %s" % (kind, f if ch is None else ch))

HOME_FALLBACK = (49.56, 11.13)


# ---------------------------------------------------------------- Dateien
def p(name, base=None):
    return os.path.join(base or BASE, name)


def load_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def config(base=None):
    c = dict(DEFAULT_CFG)
    u = load_json(p("sdr_config.json", base), {}) or {}
    if isinstance(u, dict):
        for k, v in u.items():
            if k in c:
                c[k] = v
    if not c.get("home"):
        c["home"] = list(home_from_config(base))
    return c


def save_cfg_keys(base, upd):
    """Nur die genannten Schluessel in sdr_config.json setzen (Rest bleibt), atomar."""
    fn = p("sdr_config.json", base)
    d = load_json(fn, {}) or {}
    if not isinstance(d, dict):
        d = {}
    d.update(upd)
    write_json(fn, d)


def home_from_config(base=None):
    try:
        txt = open(p("config.py", base), encoding="utf-8").read()
        la = re.search(r"^WEATHER_LAT\s*=\s*([0-9.+-]+)", txt, re.M)
        lo = re.search(r"^WEATHER_LON\s*=\s*([0-9.+-]+)", txt, re.M)
        if la and lo:
            a, b = float(la.group(1)), float(lo.group(1))
            if 47 < a < 56 and 5 < b < 16:
                return (a, b)
    except Exception:
        pass
    return HOME_FALLBACK


def get_mode(base=None):
    d = load_json(p("sdr_mode.json", base), {}) or {}
    if d.get("mode") == "preset":
        u = d.get("until")
        if d.get("preset") in PRESET_IDS and isinstance(u, (int, float)) and u > time.time():
            return {"mode": "preset", "preset": d["preset"], "until": u, "at": d.get("at")}
        return {"mode": "auto", "until": None, "at": d.get("at")}
    m = d.get("mode") if d.get("mode") in MODES else "auto"
    until = d.get("until")
    if m == "tcp" and (not isinstance(until, (int, float)) or until <= time.time()):
        m = "auto"
    if m in ("433", "aprs") and isinstance(until, (int, float)) and until <= time.time():
        m = "auto"
    return {"mode": m, "until": until if m != "auto" else None, "at": d.get("at")}


def set_mode(base, mode, minutes=None):
    """Vom Dashboard: Betriebsart setzen (nur Datei schreiben; der Planer reagiert in ~2 s)."""
    if mode not in MODES:
        raise ValueError("mode")
    c = config(base)
    until = None
    if mode == "tcp":
        mins = minutes if isinstance(minutes, (int, float)) and minutes > 0 else c["tcp_default_min"]
        until = int(time.time() + 60 * min(float(mins), float(c["tcp_max_min"])))
    elif mode in ("433", "aprs") and isinstance(minutes, (int, float)) and minutes > 0:
        until = int(time.time() + 60 * min(float(minutes), 1440.0))
    write_json(p("sdr_mode.json", base), {"mode": mode, "until": until, "at": int(time.time())})
    return get_mode(base)


def set_preset(base, pid, minutes):
    """Vom Dashboard: festes Preset fuer 30/60/120 min, danach Automatik. Nur IDs aus PRESETS."""
    if not isinstance(pid, str) or pid not in PRESET_IDS:
        raise ValueError("preset")
    if isinstance(minutes, bool) or not isinstance(minutes, int) or minutes not in PRESET_MINUTES:
        raise ValueError("minutes")
    write_json(p("sdr_mode.json", base), {"mode": "preset", "preset": pid, "until": int(time.time() + 60 * minutes), "at": int(time.time())})
    return get_mode(base)


def stick_info(ids):
    """USB-Stick per sysfs suchen (ohne Programmstart)."""
    root = os.environ.get("SDR_SYSFS_USB", "/sys/bus/usb/devices")
    out = []
    try:
        names = sorted(os.listdir(root))
    except Exception:
        return out
    for n in names:
        d = os.path.join(root, n)
        try:
            vid = open(os.path.join(d, "idVendor")).read().strip()
            pid = open(os.path.join(d, "idProduct")).read().strip()
        except Exception:
            continue
        if "%s:%s" % (vid, pid) in ids:
            info = {"usb": "%s:%s" % (vid, pid), "bus": n}
            for k in ("manufacturer", "product", "serial"):
                try:
                    info[k] = open(os.path.join(d, k)).read().strip()
                except Exception:
                    pass
            out.append(info)
    return out


# ---------------------------------------------------------------- Stick-Bindung per Seriennummer (sdrStick)
DEFAULT_SERIAL = "19348831"  # Nooelec NESDR SMArt v5 von Frank
SERIAL_RE = re.compile(r"^[0-9]{1,16}$")
LIST_RE = re.compile(r"^\s*(\d+):\s+(.*?),?\s+SN:\s*(\S*)\s*$")


def serial_ok(sn):
    return isinstance(sn, str) and bool(SERIAL_RE.match(sn))


def cfg_serial(cfg):
    """Seriennummer aus sdr_config.json - nur Ziffern, sonst None (dann startet nichts)."""
    sn = cfg.get("serial", DEFAULT_SERIAL)
    if isinstance(sn, int) and not isinstance(sn, bool):
        sn = str(sn)
    return sn if serial_ok(sn) else None


def parse_sticks(txt):
    out = []
    for ln in txt.splitlines():
        m = LIST_RE.match(ln)
        if m:
            out.append({"idx": int(m.group(1)), "name": m.group(2).strip().rstrip(","), "sn": m.group(3)})
    return out


def list_sticks(timeout=12):
    """Nur lesen: rtl_test mit einer Geraeteangabe, die auf keinen Stick passt, listet Index/Name/SN
    und beendet sich sofort (oeffnet keinen Stick, kein Test). -> (liste, fehler)"""
    try:
        pr = subprocess.Popen(["rtl_test", "-d", "prepper-nur-liste"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, start_new_session=True)
    except FileNotFoundError:
        return None, "rtl_test fehlt (Paket rtl-sdr)"
    try:
        out, err = pr.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        pr.kill()
        pr.communicate()
        return None, "rtl_test antwortet nicht"
    txt = (out + err).decode("utf-8", "replace")
    res = parse_sticks(txt)
    if not res and "Found" not in txt and "No supported devices" not in txt:
        return None, "rtl_test-Ausgabe unklar: " + txt.strip()[-80:]
    return res, None


def port_listening(port, files=("/proc/net/tcp", "/proc/net/tcp6")):
    """Nur lesen: lauscht etwas auf 127.0.0.1:port? (aus /proc/net/tcp, ohne Verbindung aufzubauen)"""
    want = ":%04X" % int(port)
    for fn in files:
        try:
            rows = open(fn).read().splitlines()[1:]
        except Exception:
            continue
        for r in rows:
            c = r.split()
            if len(c) > 3 and c[1].endswith(want) and c[3] == "0A":
                return True
    return False


def pick_stick(lst, sn):
    """-> (index, fehler). Nie ein anderer Stick als der mit der Seriennummer."""
    m = [x for x in lst if x.get("sn") == sn]
    if len(m) > 1:
        return None, "doppelte Seriennummer %s (%d Sticks) - nicht gestartet" % (sn, len(m))
    if not m:
        return None, "Stick %s fehlt" % sn
    return m[0]["idx"], None


def sticks_cli(base):
    cfg = dict(DEFAULT_CFG)
    cfg.update(load_json(p("sdr_config.json", base), {}) or {})
    sn = cfg_serial(cfg)
    lst, e = list_sticks()
    print("prepper-sdr Stick-Liste (nur lesen)")
    print("prepper-sdr ist gebunden an SN %s" % (sn or "UNGUELTIG in sdr_config.json"))
    if lst is None:
        print("Fehler:", e)
        return 2
    if not lst:
        print("keine RTL-SDR-Sticks gefunden")
    seen = {}
    for x in lst:
        seen[x["sn"]] = seen.get(x["sn"], 0) + 1
    for x in lst:
        mark = ""
        if seen[x["sn"]] > 1:
            mark = "  DOPPELTE SN!"
        elif x["sn"] == sn:
            mark = "  <- prepper-sdr"
        else:
            mark = "  frei"
        print("  Index %d  SN %-10s  %s%s" % (x["idx"], x["sn"] or "-", x["name"], mark))
    if sn:
        i, e = pick_stick(lst, sn)
        print("Ergebnis:", "Index %d" % i if e is None else e)
    return 0


def rotate(path, max_mb):
    try:
        if os.path.getsize(path) > max_mb * 1024 * 1024:
            os.replace(path, path + ".1")
    except Exception:
        pass


# ---------------------------------------------------------------- Geo
def dist_km(a, b, c, d):
    r = 6371.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def bearing(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    dl = math.radians(d - b)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


# ---------------------------------------------------------------- rtl_433
KEEP433 = ("model", "id", "channel", "subtype", "battery_ok", "temperature_C", "temperature_F", "humidity", "pressure_hPa",
           "wind_avg_km_h", "wind_max_km_h", "wind_avg_m_s", "wind_max_m_s", "wind_dir_deg", "rain_mm", "rain_rate_mm_h",
           "uv", "light_lux", "moisture", "button", "state", "event", "code", "rssi", "snr", "noise", "freq", "protocol")


def parse_433(line):
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        d = json.loads(line)
    except Exception:
        return None
    if not isinstance(d, dict) or not d.get("model"):
        return None
    t = d.get("time")
    try:
        t = float(t)
    except Exception:
        t = time.time()
    if "temperature_C" not in d and isinstance(d.get("temperature_F"), (int, float)):
        d["temperature_C"] = round((d["temperature_F"] - 32) / 1.8, 1)
    if "wind_avg_km_h" not in d and isinstance(d.get("wind_avg_m_s"), (int, float)):
        d["wind_avg_km_h"] = round(d["wind_avg_m_s"] * 3.6, 1)
    if "wind_max_km_h" not in d and isinstance(d.get("wind_max_m_s"), (int, float)):
        d["wind_max_km_h"] = round(d["wind_max_m_s"] * 3.6, 1)
    rec = {k: d[k] for k in KEEP433 if k in d and isinstance(d[k], (int, float, str))}
    rec["t"] = int(t)
    key = "%s|%s|%s" % (d.get("model"), d.get("id", ""), d.get("channel", ""))
    return key, rec, d


class State433:
    def __init__(self, base):
        self.base = base
        self.f = p("funk433_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "sensors": {}, "n": 0}
        self.d.setdefault("sensors", {})
        self.dirty = False
        self.last_saved = 0
        self.recent = {}

    def add(self, line, now=None):
        r = parse_433(line)
        if not r:
            return None
        key, rec, raw = r
        now = now or time.time()
        sig = json.dumps({k: v for k, v in raw.items() if k not in ("time", "rssi", "snr", "noise", "freq", "mic", "mod")}, sort_keys=True)
        if self.recent.get(key) == sig and now - self.recent.get(key + "#t", 0) < 3:
            return None  # Wiederholung desselben Telegramms (Sensoren senden 2-6x)
        self.recent[key], self.recent[key + "#t"] = sig, now
        s = self.d["sensors"].get(key) or {"first": rec["t"], "n": 0}
        s.update(rec)
        s["n"] = s.get("n", 0) + 1
        s["key"] = key
        self.d["sensors"][key] = s
        self.d["n"] = self.d.get("n", 0) + 1
        self.d["last_t"] = rec["t"]
        self.dirty = True
        return raw

    def prune(self, keep_days):
        cut = time.time() - keep_days * 86400
        for k in [k for k, v in self.d["sensors"].items() if (v.get("t") or 0) < cut]:
            del self.d["sensors"][k]
        if len(self.d["sensors"]) > 300:
            for k, _ in sorted(self.d["sensors"].items(), key=lambda kv: kv[1].get("t") or 0)[:len(self.d["sensors"]) - 300]:
                del self.d["sensors"][k]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


# ---------------------------------------------------------------- APRS
RE_DW = re.compile(r"^\[[0-9A-Za-z.]{1,8}\]\s*([A-Za-z0-9-]{1,9})>([^:\s]+):(.*)$")
RE_TNC2 = re.compile(r"^([A-Za-z0-9-]{1,9})>([^:\s]+):(.*)$")
RE_UNC = re.compile(r"^(\d{2})([0-9 ]{2}\.[0-9 ]{2})([NS])(.)(\d{3})([0-9 ]{2}\.[0-9 ]{2})([EW])(.)")
RE_WX = re.compile(r"([cstgrpPhbL])(-?\d{1,5}|\.{2,5}|\s{2,5})")


def _num(s):
    try:
        return float(s)
    except Exception:
        return None


def _unc(m):
    la = int(m.group(1)) + float(m.group(2).replace(" ", "0")) / 60.0
    lo = int(m.group(5)) + float(m.group(6).replace(" ", "0")) / 60.0
    if m.group(3) == "S":
        la = -la
    if m.group(7) == "W":
        lo = -lo
    return la, lo, m.group(4) + m.group(8)


def _b91(s):
    v = 0
    for ch in s:
        v = v * 91 + (ord(ch) - 33)
    return v


def _compressed(s):
    if len(s) < 13:
        return None
    t = s[0]
    if not (t in "/\\" or "A" <= t <= "Z" or "a" <= t <= "j"):
        return None
    body = s[1:9]
    if any(not (33 <= ord(c) <= 124) for c in body):
        return None
    la = 90.0 - _b91(body[:4]) / 380926.0
    lo = -180.0 + _b91(body[4:8]) / 190463.0
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return la, lo, t + s[9], s[13:]


def _mice(dest, info):
    d = dest.split("-")[0]
    if len(d) != 6 or len(info) < 9:
        return None
    dig = ""
    for c in d:
        if "0" <= c <= "9":
            dig += c
        elif "A" <= c <= "J":
            dig += chr(ord(c) - 17)
        elif "P" <= c <= "Y":
            dig += chr(ord(c) - 32)
        elif c in "KLZ":
            dig += "0"
        else:
            return None
    la = int(dig[0:2]) + (int(dig[2:4]) + int(dig[4:6]) / 100.0) / 60.0
    if not ("P" <= d[3] <= "Z"):
        la = -la
    off = 100 if "P" <= d[4] <= "Z" else 0
    west = "P" <= d[5] <= "Z"
    deg = ord(info[1]) - 28 + off
    if 180 <= deg <= 189:
        deg -= 80
    elif 190 <= deg <= 199:
        deg -= 190
    mi = ord(info[2]) - 28
    if mi >= 60:
        mi -= 60
    hu = ord(info[3]) - 28
    lo = deg + (mi + hu / 100.0) / 60.0
    if west:
        lo = -lo
    sp = (ord(info[4]) - 28) * 10 + (ord(info[5]) - 28) // 10
    dc = (ord(info[5]) - 28) % 10 * 100 + (ord(info[6]) - 28)
    if sp >= 800:
        sp -= 800
    if dc >= 400:
        dc -= 400
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return la, lo, info[8] + info[7], round(sp * 1.852), dc, info[9:]


def _wx(s):
    w = {}
    m = re.match(r"^(\d{3}|\.{3}|\s{3})/(\d{3}|\.{3}|\s{3})", s)
    if m:
        if _num(m.group(1)) is not None:
            w["wind_dir"] = int(m.group(1))
        if _num(m.group(2)) is not None:
            w["wind_kmh"] = round(int(m.group(2)) * 1.609, 1)
        s = s[7:]
    for k, v in RE_WX.findall(s[:60]):
        x = _num(v)
        if x is None:
            continue
        if k == "c" and "wind_dir" not in w:
            w["wind_dir"] = int(x)
        elif k == "s" and "wind_kmh" not in w:
            w["wind_kmh"] = round(x * 1.609, 1)
        elif k == "g":
            w["gust_kmh"] = round(x * 1.609, 1)
        elif k == "t":
            w["temp_c"] = round((x - 32) / 1.8, 1)
        elif k == "r":
            w["rain_1h_mm"] = round(x * 0.254, 1)
        elif k == "p":
            w["rain_24h_mm"] = round(x * 0.254, 1)
        elif k == "P":
            w["rain_mid_mm"] = round(x * 0.254, 1)
        elif k == "h":
            w["hum"] = 100 if int(x) == 0 else int(x)
        elif k == "b":
            w["hpa"] = round(x / 10.0, 1)
    return w if ("temp_c" in w or "hpa" in w or "hum" in w) else None


def parse_aprs(line, depth=0):
    """TNC2-Zeile (direwolf) -> dict oder None. Nur Lesen/Dekodieren."""
    line = line.rstrip("\r\n")
    m = RE_DW.match(line) if line.startswith("[") else RE_TNC2.match(line)
    if not m:
        return None
    src, path, info = m.group(1).upper(), m.group(2), m.group(3)
    parts = path.split(",")
    dest = parts[0]
    via = [x for x in parts[1:] if not x.startswith(("q", "TCPIP"))]
    r = {"src": src, "dest": dest, "path": ",".join(via), "direct": not any("*" in x for x in via), "raw": line[:300]}
    if not info:
        return None
    dti = info[0]
    try:
        if dti == "}" and depth < 2:
            inner = parse_aprs(info[1:], depth + 1)
            if inner:
                inner["third"] = src
                return inner
            return None
        if dti in "!=/@":
            s = info[1:]
            if dti in "/@":
                s = s[7:]
            mm = RE_UNC.match(s)
            if mm:
                la, lo, sym = _unc(mm)
                rest = s[19:]
            else:
                c = _compressed(s)
                if not c:
                    r["type"] = "other"
                    return r
                la, lo, sym, rest = c
            r.update({"type": "pos", "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "comment": rest.strip()[:120]})
            if sym[1:] == "_":
                w = _wx(rest)
                if w:
                    r["type"], r["wx"] = "wx", w
                    r["comment"] = ""
            else:
                cs = re.match(r"^(\d{3})/(\d{3})", rest)
                if cs:
                    r["course"], r["speed_kmh"] = int(cs.group(1)), round(int(cs.group(2)) * 1.852)
            alt = re.search(r"/A=(-?\d{6})", rest)
            if alt:
                r["alt_m"] = round(int(alt.group(1)) * 0.3048)
            return r
        if dti in "`'\x1c\x1d":
            mc = _mice(dest, info)
            if mc:
                la, lo, sym, sp, dc, rest = mc
                r.update({"type": "pos", "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "speed_kmh": sp, "course": dc,
                          "comment": re.sub(r"[\x00-\x1f]", "", rest).strip()[:120], "mice": True})
                return r
        if dti == "_":
            w = _wx(info[9:])
            if w:
                r.update({"type": "wx", "wx": w})
                return r
        if dti == ":" and len(info) >= 11 and info[10] == ":":
            to = info[1:10].strip().upper()
            txt = info[11:]
            mid = None
            if "{" in txt:
                txt, mid = txt.rsplit("{", 1)
            if re.match(r"^(ack|rej)[A-Za-z0-9]{1,5}$", txt):
                r.update({"type": "ack", "to": to})
                return r
            kind = "bulletin" if to.startswith(("BLN", "NWS")) else ("telemetry" if txt.startswith(("PARM.", "UNIT.", "EQNS.", "BITS.")) else "msg")
            r.update({"type": kind, "to": to, "text": txt[:200], "msgid": (mid or "")[:5] or None})
            return r
        if dti == ";" and len(info) > 18:
            name, live = info[1:10].strip(), info[10] == "*"
            s = info[18:]
            mm = RE_UNC.match(s)
            if mm:
                la, lo, sym = _unc(mm)
                rest = s[19:]
            else:
                c = _compressed(s)
                if not c:
                    return None
                la, lo, sym, rest = c
            r.update({"type": "obj", "name": name, "live": live, "lat": round(la, 5), "lon": round(lo, 5), "sym": sym, "comment": rest.strip()[:120]})
            return r
        if dti == ">":
            r.update({"type": "status", "text": info[1:120]})
            return r
        if dti == "T":
            r["type"] = "telemetry"
            return r
    except Exception:
        return None
    r["type"] = "other"
    return r


class StateAPRS:
    def __init__(self, base, home):
        self.base = base
        self.home = home
        self.f = p("aprs_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "stations": {}, "msgs": [], "n": 0}
        self.d.setdefault("stations", {})
        self.d.setdefault("msgs", [])
        self.dirty = False
        self.last_saved = 0

    def add(self, line, now=None):
        r = parse_aprs(line)
        if not r or r.get("type") in ("ack",):
            return None
        now = int(now or time.time())
        r["t"] = now
        key = r.get("name") if r.get("type") == "obj" else r["src"]
        s = self.d["stations"].get(key) or {"call": key, "first": now, "n": 0}
        s["n"] = s.get("n", 0) + 1
        s["t"] = now
        s["path"] = r.get("path")
        s["direct"] = r.get("direct")
        if r.get("type") == "obj":
            s["obj"] = True
            s["by"] = r["src"]
        if "lat" in r:
            s.update({"lat": r["lat"], "lon": r["lon"], "sym": r.get("sym"), "pos_t": now})
            s["dist_km"] = round(dist_km(self.home[0], self.home[1], r["lat"], r["lon"]), 1)
            s["brg"] = round(bearing(self.home[0], self.home[1], r["lat"], r["lon"]))
            for k in ("speed_kmh", "course", "alt_m"):
                if k in r:
                    s[k] = r[k]
                else:
                    s.pop(k, None)
        if r.get("comment"):
            s["comment"] = r["comment"]
        if r.get("type") == "status":
            s["status"] = r.get("text")
        if r.get("wx"):
            s["wx"] = r["wx"]
            s["wx_t"] = now
        if r.get("type") in ("msg", "bulletin") and not any(
                x.get("from") == r["src"] and x.get("to") == r.get("to") and x.get("text") == r.get("text") and now - (x.get("t") or 0) < 1800
                for x in self.d["msgs"][-30:]):
            self.d["msgs"].append({"t": now, "from": r["src"], "to": r.get("to"), "text": r.get("text"), "kind": r["type"]})
            self.d["msgs"] = self.d["msgs"][-150:]
        s["last_type"] = r.get("type")
        self.d["stations"][key] = s
        self.d["n"] = self.d.get("n", 0) + 1
        self.d["last_t"] = now
        self.dirty = True
        return r

    def prune(self, keep_days):
        cut = time.time() - keep_days * 86400
        for k in [k for k, v in self.d["stations"].items() if (v.get("t") or 0) < cut]:
            del self.d["stations"][k]
        if len(self.d["stations"]) > 600:
            for k, _ in sorted(self.d["stations"].items(), key=lambda kv: kv[1].get("t") or 0)[:len(self.d["stations"]) - 600]:
                del self.d["stations"][k]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"], self.d["home"] = V, int(time.time()), list(self.home)
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


DIREWOLF_CONF = """# prepper-sdr: nur Empfang (kein PTT, keine Audioausgabe, kein IGate, keine Baken)
ADEVICE null null
ACHANNELS 1
CHANNEL 0
MYCALL N0CALL
MODEM 1200
AGWPORT 0
KISSPORT 0
"""


# ---------------------------------------------------------------- Rundfunk (UKW-RDS / DAB+) - nur Warn-/Verkehrskennungen + Texte
FM_DEFAULT = [{"name": "BR24", "f": "102.0M"}, {"name": "Bayern 3", "f": "97.9M"}, {"name": "Bayern 1", "f": "88.9M"}]
DAB_DEFAULT = ["11D"]
WARN_WORDS = re.compile(r"warn|unwetter|gefahr|katastroph|evaku|sirene|alarm|hochwasser|stromausfall|bevoelkerung|bevölkerung|amtliche", re.I)
ASA_RE = re.compile(r"^\s*ASA(?:\s|-|$)", re.I)      # ASA DE (Automatic Safety Alert, DR Deutschland 5C): Dienst-Label
PTY31_PERSIST_S = 30                                # PTY 31 (Alarm) erst rot, wenn >= 30 s und >= 3 Gruppen

# --ws-score-begin (gleicher Text in prepper_sdr.py und dashboard.py br24Warn2)
import re as _ws_re

_WS_F = _ws_re.I
_WS_TEST = _ws_re.compile(r"probealarm|probe-?warnung|warntag|test-?warnung|test-?meldung|warn-?test|dies ist (?:nur )?eine? (?:test|probe)|\btest\b[^.]{0,25}\b(?:asa|warn)", _WS_F)
_WS_END = _ws_re.compile(r"entwarnung|aufgehoben|keine gefahr|gefahr (?:ist )?(?:vorbei|beendet)|warnung (?:ist )?beendet", _WS_F)
_WS_META = _ws_re.compile(r"warnstreik|experten warnen|warnen experten|betrug|betr(?:ü|ue)ger|phishing|podcast|gewinnspiel|gewinnen sie|jetzt (?:läuft|laeuft|on air)|now playing", _WS_F)
_WS_SOFT = _ws_re.compile(r"\bstau\b|verkehr|unfall|\b[AB]\s?\d{1,3}\b|blitzer|baustelle|sperrung|gesperrt|warnt vor|\bapp\b|\bbr\.de\b|br24\.de", _WS_F)
_WS_VERK = _ws_re.compile(r"falschfahrer|geisterfahrer", _WS_F)
_WS_NOWPLAY = _ws_re.compile(r"^[^:!?.]{2,40}\s[-–/]\s[^:!?.]{2,60}$")
_WS_STRONG = [
    ("Amtliche Gefahrendurchsage", r"amtliche\s+gefahrendurchsage"), ("Gefahrendurchsage", r"gefahrendurchsage"),
    ("Amtliche Warnung", r"amtliche\s+warnung"), ("extreme Gefahr", r"extreme\s+gefahr"),
    ("Warnung der Bevölkerung", r"warnung\s+der\s+bev(?:ö|oe)lkerung"),
    ("Fenster und Türen schließen", r"fenster\s+und\s+t(?:ü|ue)ren\s+(?:geschlossen|schlie(?:ß|ss)en|zu)"),
    ("Lüftung/Klimaanlage abschalten", r"(?:l(?:ü|ue)ftung|klimaanlage)[^.]{0,60}(?:ab|aus)(?:zu)?schalten|(?:ab|aus)schalten[^.]{0,40}(?:l(?:ü|ue)ftung|klimaanlage)"),
    ("Gebiet meiden", r"gebiet[^.]{0,25}meiden|meiden\s+sie[^.]{0,30}gebiet"), ("Evakuierung", r"evakuier"), ("Katastrophenfall", r"katastrophenfall")]
_WS_MED = [
    ("Unwetterwarnung DWD/Stufe 3-4", r"unwetterwarnung", r"dwd|wetterdienst|amtlich|(?:warn)?stufe\s*[34]\b"),
    ("extremes Unwetter", r"extreme[sn]?\s+unwetter", None), ("Hochwasser-Warnung", r"hochwasser", r"warn"),
    ("Trinkwasser abkochen", r"trinkwasser[^.]{0,40}abkoch|abkochgebot", None),
    ("Stromausfall + Behörde", r"stromausfall", r"beh(?:ö|oe)rde|landratsamt")]
_WS_STRONG = [(n, _ws_re.compile(r, _WS_F)) for n, r in _WS_STRONG]
_WS_MED = [(n, _ws_re.compile(a, _WS_F), _ws_re.compile(b, _WS_F) if b else None) for n, a, b in _WS_MED]
_WS_BEHAV = _ws_re.compile(r"bleiben sie|halten sie sich|suchen sie|meiden sie|verlassen sie|schlie(?:ß|ss)en sie|informieren sie sich|nicht ins freie|im haus bleiben|drinnen bleiben|begeben sie sich|vermeiden sie", _WS_F)


def _ws_score(t, rtp=None):
    """Text -> {cls: rot|ende|test|verkehr|None, why}. rot nur bei starkem Begriff, 2+ mittleren oder mittel + Verhaltensanweisung."""
    t = " ".join(str(t or "").split())
    if not t:
        return {"cls": None, "why": "leer"}
    m = _WS_TEST.search(t)
    if m:
        return {"cls": "test", "why": "Test: " + m.group(0)}
    m = _WS_META.search(t)
    if m:
        return {"cls": None, "why": "ausgeschlossen: " + m.group(0)}
    m = _WS_END.search(t)
    if m:
        return {"cls": "ende", "why": "Entwarnung: " + m.group(0)}
    st = [n for n, r in _WS_STRONG if r.search(t)]
    if st:
        return {"cls": "rot", "why": "stark: " + ", ".join(st[:3])}
    m = _WS_VERK.search(t)
    if m:
        return {"cls": "verkehr", "why": "Verkehrsgefahr: " + m.group(0)}
    m = _WS_SOFT.search(t)
    if m:
        return {"cls": None, "why": "ausgeschlossen: " + m.group(0)}
    md = [n for n, a, b in _WS_MED if a.search(t) and (b is None or b.search(t))]
    if any(str(x).startswith("item.") for x in (rtp or [])) or (not md and _WS_NOWPLAY.match(t)):
        return {"cls": None, "why": "ausgeschlossen: Titel/Interpret"}
    bh = _WS_BEHAV.search(t)
    if len(md) >= 2 or (md and bh):
        return {"cls": "rot", "why": "mittel: " + ", ".join(md[:3]) + ((" + Anweisung „%s“" % bh.group(0)) if bh else "")}
    return {"cls": None, "why": ("nur 1 mittlerer Begriff: " + md[0]) if md else "kein Warnbegriff"}


_WS_VEC = [
    ("Amtliche Gefahrendurchsage für Erlangen: Fenster und Türen schließen", "rot"), ("Gefahrendurchsage der Polizei Nürnberg", "rot"),
    ("Großbrand: Lüftung und Klimaanlage bitte abschalten", "rot"), ("Bitte das Gebiet um den Hafen weiträumig meiden", "rot"),
    ("Evakuierung in Forchheim nach Bombenfund", "rot"), ("Landratsamt ERH: Katastrophenfall ausgerufen", "rot"),
    ("DWD Unwetterwarnung Stufe 3 für Mittelfranken", None), ("Extremes Unwetter: DWD Unwetterwarnung Stufe 4", "rot"),
    ("Hochwasserwarnung für die Regnitz - bleiben Sie den Ufern fern", "rot"), ("Hochwasserwarnung Regnitz: verlassen Sie die Keller", "rot"),
    ("Trinkwasser in Herzogenaurach abkochen", None), ("Trinkwasser abkochen, Stromausfall laut Landratsamt", "rot"),
    ("Amtliche Unwetterwarnung Landkreis ERH", None), ("Probewarnung zum Warntag", "test"), ("Amtliche Warnung der Bevölkerung - Probealarm", "test"),
    ("Entwarnung für Erlangen: Gefahr ist vorbei", "ende"), ("Die Warnung wurde aufgehoben", "ende"), ("Falschfahrer auf der A73", "verkehr"),
    ("Stau auf der A9 nach Unfall, Warnung vor Glätte", None), ("Blitzer in Fürth", None), ("Warnstreik bei der Bahn", None),
    ("Polizei warnt vor Betrug am Telefon", None), ("Experten warnen vor Hitze", None), ("Phishing-Mails im Umlauf", None),
    ("Podcast: Was tun bei einer Gefahrendurchsage?", None), ("Gewinnspiel: jetzt anrufen", None), ("Hochwasser-Warnung - mehr in der BR24 App", None),
    ("Adele - Hello", None), ("BR24 Nachrichten", None), ("", None)]


def _ws_selftest():
    for t, exp in _WS_VEC:
        r = _ws_score(t)
        assert r["cls"] == exp, (t, r, exp)
    assert _ws_score("Unwetter Sturmwarnung Stufe 3 Extremes Unwetter", ["item.title"])["cls"] is None
    return "warnscore selftest ok (%d Faelle)" % len(_WS_VEC)
# --ws-score-end


_WELLE_CAPS = {}


def welle_caps(exe):
    """Nur lesen: welle-cli-Programmdatei nach Alarm-/Ansage-/ASA-Unterstuetzung durchsuchen (FIG 0/0 Alarmflag, FIG 0/18-19 Ansagen, ASA/EWS)."""
    if not exe:
        return {"exe": None, "fig0_0": False, "fig0_19": False, "asa": False, "note": "welle-cli fehlt"}
    if exe in _WELLE_CAPS:
        return _WELLE_CAPS[exe]
    try:
        with open(exe, "rb") as fh:
            b = fh.read(64 * 1024 * 1024)
    except Exception as e:
        return {"exe": exe, "fig0_0": False, "fig0_19": False, "asa": False, "note": "nicht lesbar: %s" % str(e)[:60]}
    r = {"exe": exe,
         "fig0_0": bool(re.search(rb"alarm[_ ]?flag|AlarmFlag|\balarm\b|\bAlarm\b", b)),
         "fig0_19": bool(re.search(rb"[Aa]nnouncement|\bASw\b|\bASu\b|FIG0_19|fig0_19|FIG 0/19", b)),
         "asa": bool(re.search(rb"\bASA\b|[Ss]afety[_ ]?[Aa]lert|\bEWS\b|[Ee]mergency[_ ]?[Ww]arning", b))}
    r["note"] = "nutzbar: " + ", ".join(k for k in ("fig0_0", "fig0_19", "asa") if r[k]) if any(r[k] for k in ("fig0_0", "fig0_19", "asa")) else \
        "welle-cli liefert weder Alarmflag (FIG 0/0) noch Ansagen (FIG 0/19) noch ASA - nur DLS-Text auswertbar"
    _WELLE_CAPS[exe] = r
    return r


# ---------------------------------------------------------------- Funkumgebung: Stoerer/QRM + Gewitter-Hinweis (nur Pegel, nur Zahlen)
# Feste Messbereiche (nur Leistung je Frequenzbin, kein Demodulieren, nichts gespeichert ausser Zahlen).
NOISE_BANDS = [
    {"id": "n2m", "label": "2 m 144–146 MHz", "short": "2 m", "kind": "noise2m", "lo": "144.000M", "hi": "146.000M", "bin": "5k", "i": 1, "s": 6},
    {"id": "fm", "label": "UKW 87,5–108 MHz", "short": "UKW", "kind": "noisefm", "lo": "87.500M", "hi": "108.000M", "bin": "25k", "i": 2, "s": 10},
    {"id": "dab", "label": "DAB Band III 174–240 MHz", "short": "DAB", "kind": "noisedab", "lo": "174.000M", "hi": "240.000M", "bin": "100k", "i": 3, "s": 12},
    {"id": "pmr", "label": "PMR446 446,0–446,2 MHz", "short": "PMR", "kind": "noisepmr", "lo": "446.000M", "hi": "446.200M", "bin": "1k", "i": 1, "s": 6},
    {"id": "n433", "label": "ISM 433,05–434,79 MHz", "short": "433", "kind": "noise433", "lo": "433.050M", "hi": "434.790M", "bin": "5k", "i": 1, "s": 6},
    {"id": "n868", "label": "SRD 863–870 MHz", "short": "868", "kind": "noise868", "lo": "863.000M", "hi": "870.000M", "bin": "10k", "i": 2, "s": 8},
    {"id": "gps", "label": "GPS L1 1575,42 ±2 MHz", "short": "GPS", "kind": "noisegps", "lo": "1573.420M", "hi": "1577.420M", "bin": "10k", "i": 1, "s": 6},
    {"id": "mw", "label": "MW 0,54–1,56 MHz (Direktabtastung)", "short": "MW", "kind": "noise_mw", "fc": "1.050M", "sr": 1024000, "hf": True, "s": 8},
    {"id": "hf10", "label": "KW 9,92–10,18 MHz (Direktabtastung)", "short": "KW", "kind": "noise_hf", "fc": "10.050M", "sr": 256000, "hf": True, "s": 8},
]
NOISE_IDS = [b["id"] for b in NOISE_BANDS]


def noise_gain(c):
    """Feste Verstaerkung fuer Pegelmessungen (nie AGC/Automatik: -g fehlt oder 0 = Automatik bei rtl_power/rtl_fm)."""
    g = c.get("gain_noise")
    try:
        g = float(g)
    except (TypeError, ValueError):
        g = 30.0
    if not math.isfinite(g) or not (1.0 <= g <= 50.0):
        g = 30.0
    return "%g" % g


def _np():
    import numpy as np
    return np


class NoiseMeter:
    """Sammelt 'Sweeps' (Leistung je Bin in dB) eines Messbereichs; bei KW/MW (Direktabtastung) zusaetzlich kurze Impulse.
    Ergebnis: Rauschboden (Median), schmalbandige Traeger (Bins > X dB ueber Boden in >= N aufeinanderfolgenden Sweeps),
    breitbandige Impulse je Minute (viele Bins gleichzeitig angehoben = typisch Blitz-Sferics oder Zuendfunken)."""
    NFFT = 1024

    def __init__(self, band, car_db=10.0, car_n=4, imp_db=10.0):
        self.np = _np()
        self.band = band
        self.car_db, self.car_n, self.imp_db = float(car_db), int(car_n), float(imp_db)
        self.sweeps = []
        self.f0 = None
        self.df = None
        self.blocks = 0
        self.imp = 0
        self.bb = 0
        self.secs = 0.0
        self.buf = b""
        self.acc = None
        self.nacc = 0
        self.t0 = time.time()
        self.lastpk = False

    # rtl_power CSV: Datum, Zeit, Hz unten, Hz oben, Hz Schritt, Samples, dB...
    def feed_power(self, line):
        """Eine rtl_power-Zeile = ein Hop; alle Hops mit gleicher Zeit = ein Sweep (nach Frequenz sortiert zusammengesetzt)."""
        c = [x.strip() for x in line.split(",")]
        if len(c) < 8:
            return False
        try:
            lo, step = float(c[2]), float(c[4])
            db = [float(x) for x in c[6:]]
        except Exception:
            return False
        key = c[0] + " " + c[1]
        if getattr(self, "_key", None) not in (None, key):
            self._flush_hops()
        self._key = key
        self._hops = getattr(self, "_hops", [])
        self._hops.append((lo, step, db))
        return True

    def _flush_hops(self):
        hops = sorted(getattr(self, "_hops", []) or [], key=lambda h: h[0])
        self._hops = []
        if not hops:
            return
        self.nhop = max(getattr(self, "nhop", 0), len(hops))
        if len(hops) < self.nhop:
            return  # unvollstaendiger Sweep
        row = [v for h in hops for v in h[2]]
        if self.sweeps and len(row) != len(self.sweeps[0]):
            return
        a = self.np.array(row, dtype=float)
        if not self.np.all(self.np.isfinite(a)):
            return
        if self.f0 is None:
            self.f0, self.df = hops[0][0], hops[0][1]
            self.hop_bins = len(hops[0][2])
        self.sweeps.append(a)
        self.secs += float(self.band.get("i") or 1)

    # rtl_fm -M raw: int16 I/Q verschraenkt
    def feed_iq(self, raw, sr):
        np = self.np
        self.buf += raw
        n = self.NFFT * 4
        k = len(self.buf) // n
        if not k:
            return
        a = np.frombuffer(self.buf[:k * n], dtype="<i2").astype(np.float32) / 32768.0
        self.buf = self.buf[k * n:]
        iq = (a[0::2] + 1j * a[1::2]).reshape(k, self.NFFT)
        iq = iq - iq.mean(axis=1, keepdims=True)
        sp = np.abs(np.fft.fftshift(np.fft.fft(iq * np.hanning(self.NFFT), axis=1), axes=1)) ** 2 / self.NFFT
        sp_db = 10 * np.log10(sp + 1e-12)
        pw = 10 * np.log10(np.mean(np.abs(iq) ** 2, axis=1) + 1e-12)
        med = float(np.median(pw))
        avg = 10 * np.log10(np.mean(sp, axis=0) + 1e-12)
        for i in range(k):
            pk = pw[i] > med + self.imp_db
            if pk and not self.lastpk:
                self.imp += 1
                if float(np.mean(sp_db[i] > avg + 6.0)) >= 0.5:
                    self.bb += 1
            self.lastpk = bool(pk)
        self.blocks += k
        self.secs += k * self.NFFT / float(sr)
        self.acc = sp if self.acc is None else np.vstack([self.acc, sp])
        if self.acc.shape[0] * self.NFFT >= sr / 2:  # ~0,5 s je Sweep
            self.sweeps.append(10 * np.log10(np.mean(self.acc, axis=0) + 1e-12))
            self.acc = None
            if self.f0 is None:
                fc = to_mhz(self.band["fc"]) * 1e6
                self.df = sr / float(self.NFFT)
                self.f0 = fc - sr / 2.0

    def result(self, now=None):
        np = self.np
        now = int(now or time.time())
        if not self.band.get("hf"):
            self._flush_hops()
        sw = self.sweeps[1:]  # erster Sweep nach dem Start (Tuner/PLL/Temperatur) verworfen
        if len(sw) < 2:
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(sw), "s": round(self.secs, 1), "why": "zu wenig Sweeps"}
        m = np.vstack(sw)
        nb = m.shape[1]
        keep = np.ones(nb, dtype=bool)
        e = max(1, nb // 20)
        keep[:e] = False
        keep[-e:] = False
        hb = int(getattr(self, "hop_bins", 0) or nb)
        dcw = max(2, hb // 100)
        for h0 in range(0, nb, hb):  # DC-Spitze je Hop-Mitte
            mid = h0 + hb // 2
            keep[max(0, mid - dcw):mid + dcw + 1] = False
        if not keep.any():
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(sw), "s": round(self.secs, 1), "why": "keine Bins"}
        floor = float(np.median(m[:, keep]))  # Rauschboden = Median ueber Zeit und Bins (Traeger/Impulse ziehen kaum)
        if not math.isfinite(floor):
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(sw), "s": round(self.secs, 1), "why": "Messwert ungueltig"}
        if self.band.get("hf") and (floor < -100 or float(np.percentile(m[:, keep], 90)) - floor < 0.05):
            return {"band": self.band["id"], "t": now, "ok": False, "n": len(self.sweeps), "s": round(self.secs, 1), "why": "kein Signal (Direktabtastung/KW-Antenne?)"}
        above = (m > floor + self.car_db) & keep[None, :]
        run = np.zeros(nb, dtype=int)
        best = np.zeros(nb, dtype=int)
        for r in above:
            run = np.where(r, run + 1, 0)
            best = np.maximum(best, run)
        need = min(self.car_n, max(2, len(sw) - 1))
        hit = best >= need
        cars = []
        i = 0
        while i < nb:
            if hit[i]:
                j = i
                while j + 1 < nb and hit[j + 1]:
                    j += 1
                seg = np.median(m[:, i:j + 1], axis=0)
                pk = i + int(np.argmax(seg))
                cars.append({"f": round((self.f0 + (pk + 0.5) * self.df) / 1e6, 4), "db": round(float(np.max(seg) - floor), 1),
                             "w_khz": round((j - i + 1) * self.df / 1e3, 1)})
                i = j + 1
            else:
                i += 1
        cars.sort(key=lambda x: -x["db"])
        bbs = float(np.mean(np.mean(m[:, keep] > floor + 6.0, axis=1) >= 0.5))
        r = {"band": self.band["id"], "t": now, "ok": True, "n": len(sw), "s": round(self.secs, 1),
             "floor": round(floor, 1), "p90": round(float(np.percentile(m[:, keep], 90)), 1), "cars": cars[:8], "n_car": len(cars),
             "bb_sweep_pct": round(100 * bbs, 1)}
        if self.band.get("hf") and self.secs > 0:
            mins = self.secs / 60.0
            r.update({"imp_pm": round(self.imp / mins, 1), "bb_pm": round(self.bb / mins, 1)})
        return r


def _med(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def _lvl(*xs):
    o = {"gruen": 0, "gelb": 1, "rot": 2}
    return max(xs, key=lambda x: o.get(x, -1)) if xs else "grau"


def _fin(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(float(x))


def robust(xs):
    """-> (median, MAD*1.4826, n) nur endlicher Werte; (None, None, 0) ohne Werte."""
    v = sorted(float(x) for x in xs if _fin(x))
    if not v:
        return None, None, 0
    m = _med(v)
    return m, 1.4826 * _med([abs(x - m) for x in v]), len(v)


def thresholds(mad, cfg, ky="noise_k_yel", kr="noise_k_red", fy="noise_raise_yel", fr="noise_raise_red", dy=5.0, dr=10.0):
    """Robuste Schwellen: gelb = max(fest, k*MAD), rot = max(fest, k2*MAD), rot immer > gelb."""
    mad = float(mad) if _fin(mad) else 0.0
    y = max(float(cfg.get(fy) or dy), float(cfg.get(ky) or 4) * mad)
    r = max(float(cfg.get(fr) or dr), float(cfg.get(kr) or 6) * mad, y + 1.0)
    return round(y, 1), round(r, 1)


def _hour(ts):
    try:
        return time.localtime(ts).tm_hour
    except Exception:
        return -1


def load_keep(path, default=None):
    """JSON laden; kaputt/fehlt -> vorherige Fassung (.1); sonst default (Anzeige behaelt letzten Stand)."""
    d = load_json(path, None)
    if d is None:
        d = load_json(path + ".1", None)
    return default if d is None else d


def write_json_keep(path, obj):
    """Atomar schreiben und vorherige Fassung als .1 behalten (Verlaeufe, selten geschrieben)."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    if os.path.exists(path):
        os.replace(path, path + ".1")
    os.replace(tmp, path)


CLOCK_OK = 17 * 10 ** 8  # vor Nov. 2023 = Uhr nicht gestellt (Pi ohne RTC) -> nichts bewerten/speichern
HOURLY = ("mw", "hf10")  # Tagesgang (Ausbreitung MW/KW): Grundlinie je Tagesstunde


class NoiseState:
    """noise_state.json (aktuell, klein) + sdr_noise_hist.json (Verlauf 14 Tage, je Messbereich; fuer Kacheln und Archiv).
    Grundlinie: Median der Messungen 1 h-7 d (MW/KW und Gewitter-Impulse: gleiche Tagesstunde 1-14 d, bis genug da sind 24 h).
    Schwellen robust: Abweichung >= max(5 dB, 4*MAD) gelb, >= max(10 dB, 6*MAD) rot (MAD*1,4826).
    Trend: EWMA (lambda 0,03 je Messung) der Abweichung gegen die Grundlinie 3-14 d alt; 'Trend steigend' ab >= 2 dB
    nach >= 24 Messungen seit Reset, aus unter 1 dB (Hysterese). Reset: Luecke > 6 h, Uhr rueckwaerts, Band nicht messbar.
    Verlauf hoechstens alle 30 min geschrieben (SD-Karte, vorherige Fassung .1), aktueller Stand nach jedem Messblock."""
    KEEP_S = 14 * 86400
    CAP = 1500

    def __init__(self, base):
        self.f = p("noise_state.json", base)
        self.fh = p("sdr_noise_hist.json", base)
        d = load_keep(self.f)
        self.d = d if isinstance(d, dict) else {}
        for k in ("bands", "cars", "trend", "since"):
            if not isinstance(self.d.get(k), dict):
                self.d[k] = {}
        h = load_keep(self.fh)
        h = h if isinstance(h, dict) else {}
        self.h = {}
        for b in NOISE_IDS + ["impulse"]:
            v = h.get(b) if isinstance(h.get(b), list) else []
            self.h[b] = [x for x in v if isinstance(x, dict) and _fin(x.get("ts"))][-self.CAP:]
        self.last_hsave = 0
        self.hdirty = False

    def ref(self, band, key, now, lo_s, hi_s, hour=None):
        out = []
        for x in self.h.get(band, []):
            a = now - x.get("ts", 0)
            if lo_s <= a < hi_s and _fin(x.get(key)):
                if hour is not None and x.get("_h", _hour(x["ts"])) != hour:
                    continue
                out.append(x)
        return out

    def baseline(self, band, key, now, long_lo=3600, long_hi=7 * 86400):
        """-> (median, mad, n, Quelle) ; median None = lernt noch."""
        if band in HOURLY:
            hr = _hour(now)
            pts = self.ref(band, key, now, 3600, 14 * 86400, hr)
            days = len(set(int(x["ts"] // 86400) for x in pts))
            if len(pts) >= 8 and days >= 3:
                m, s, n = robust(x[key] for x in pts)
                return m, s, n, "Stunde %02d (%d Tage)" % (hr, days)
            pts = self.ref(band, key, now, 3600, 86400)
            if len(pts) >= 8:
                m, s, n = robust(x[key] for x in pts)
                return m, s, n, "24 h (Stunden-Grundlinie lernt)"
            return None, None, len(pts), "lernt"
        pts = self.ref(band, key, now, long_lo, long_hi)
        if len(pts) >= 8:
            m, s, n = robust(x[key] for x in pts)
            return m, s, n, "7 Tage" if (now - min(x["ts"] for x in pts)) > 2 * 86400 else "24 h"
        return None, None, len(pts), "lernt"

    def trend_step(self, bid, dev, now, cfg):
        tr = self.d["trend"].get(bid)
        if not isinstance(tr, dict) or not _fin(tr.get("e")) or not _fin(tr.get("t")):
            tr = {"e": 0.0, "t": now, "n": 0, "on": False}
        if now - tr["t"] > 6 * 3600 or now < tr["t"] - 600:
            tr = {"e": 0.0, "t": now, "n": 0, "on": False, "reset": int(now)}
        if dev is None:
            self.d["trend"][bid] = tr
            return tr
        lam = min(0.5, max(0.005, float(cfg.get("noise_trend_lambda") or 0.03)))
        e = lam * dev + (1 - lam) * float(tr["e"])
        n = int(tr.get("n") or 0) + 1
        on = bool(tr.get("on"))
        if not on and n >= 24 and e >= float(cfg.get("noise_trend_db") or 2.0):
            on, tr["since"] = True, int(now)
        elif on and e < float(cfg.get("noise_trend_off_db") or 1.0):
            on = False
        tr.update({"e": round(e, 2), "t": int(now), "n": min(n, 100000), "on": on})
        self.d["trend"][bid] = tr
        return tr

    def add(self, r, cfg, now=None):
        now = int(now or r.get("t") or time.time())
        bid = r.get("band")
        if bid not in NOISE_IDS:
            return
        if now < CLOCK_OK:
            self.d["bands"][bid] = dict(self.d["bands"].get(bid) or {}, ok=False, t=now, why="Uhr nicht gestellt")
            return
        if not r.get("ok") or not _fin(r.get("floor")):
            self.d["bands"][bid] = dict(self.d["bands"].get(bid) or {}, ok=False, t=now, n=r.get("n"), why=r.get("why"))
            self.trend_step(bid, None, now, cfg)
            return
        floor = float(r["floor"])
        med, mad, nb, src = self.baseline(bid, "floor", now)
        yel, red = thresholds(mad, cfg)
        raise_db = round(floor - med, 1) if med is not None else None
        # Traeger-Register: gleiche Frequenz (+-2 Bins) ueber mehrere Bloecke = "seit"
        reg = self.d["cars"].get(bid) if isinstance(self.d["cars"].get(bid), list) else []
        reg = [x for x in reg if isinstance(x, dict) and _fin(x.get("f")) and _fin(x.get("db"))]
        tol = 0.002 if not str(bid).startswith(("mw", "hf")) else 0.0006
        seen = []
        for c in r.get("cars") or []:
            if not (_fin(c.get("f")) and _fin(c.get("db"))):
                continue
            hitc = None
            for x in reg:
                if abs(x["f"] - c["f"]) <= tol:
                    hitc = x
                    break
            if hitc is None:
                hitc = {"f": c["f"], "first": now, "n": 0}
                reg.append(hitc)
            hitc.update({"f": c["f"], "db": c["db"], "w_khz": c.get("w_khz"), "last": now})
            hitc["n"] = hitc.get("n", 0) + 1
            seen.append(hitc)
        iv = float(cfg.get("noise_interval_s") or 900)
        for x in reg:
            age = now - x.get("first", now)
            slots = max(1.0, age / iv)
            if age >= 86400 and x.get("n", 0) / slots >= 0.5:
                x["known"] = True
                if x in seen:
                    x["kdb"] = round(0.9 * x.get("kdb", x["db"]) + 0.1 * x["db"], 1) if _fin(x.get("kdb")) else x["db"]
        keep_s = 2 * 86400 if any(x.get("known") for x in reg) else iv * 2.5
        self.d["cars"][bid] = sorted([x for x in reg if 0 <= now - x.get("last", 0) <= (keep_s if x.get("known") else iv * 2.5)],
                                     key=lambda y: -y.get("db", 0))[:80]
        sn = self.d["since"].get(bid)
        if not _fin(sn) or sn > now:
            sn = self.d["since"][bid] = now
        learning = (now - sn) < 86400
        pers = [x for x in self.d["cars"][bid] if x.get("last") == now and x.get("n", 0) >= 3 and
                (not x.get("known") or (_fin(x.get("kdb")) and x["db"] - x["kdb"] >= 10)) and not learning]
        lvl = "gruen"
        if raise_db is not None and raise_db >= red:
            lvl = "rot"
        elif any(x["db"] >= 20 for x in pers):
            lvl = "rot"
        elif (raise_db is not None and raise_db >= yel) or pers:
            lvl = "gelb"
        # Trend gegen aeltere Grundlinie (3-14 d), Abweichung begrenzt (Einzelspitzen ziehen nicht)
        tm, _tmad, tn, _ts = self.baseline(bid, "floor", now, 3 * 86400, 14 * 86400) if bid not in HOURLY else (None, None, 0, "")
        if tn < 48:
            tm = None
        if bid in HOURLY:
            pts = self.ref(bid, "floor", now, 3 * 86400, 14 * 86400, _hour(now))
            tm = robust(x["floor"] for x in pts)[0] if len(pts) >= 6 else None
        dev = None if tm is None else max(-red, min(red, floor - tm))
        tr = self.trend_step(bid, dev, now, cfg)
        cur = {"t": now, "ok": True, "floor": round(floor, 1), "p90": r.get("p90"), "base": None if med is None else round(med, 1),
               "mad": None if mad is None else round(mad, 2), "src": src, "yel": yel, "red": red, "raise": raise_db, "n_base": nb, "lvl": lvl,
               "s": r.get("s"), "trend": {"on": bool(tr.get("on")), "e": tr.get("e"), "since": tr.get("since")},
               "cars": [{"f": x["f"], "db": x["db"], "w_khz": x.get("w_khz"), "since": x["first"], "n": x["n"]} for x in sorted(pers, key=lambda y: -y["db"])[:6]],
               "n_car": len(seen), "n_known": sum(1 for x in seen if x.get("known")), "n_pers": len(pers), "learning": learning or med is None}
        if _fin(r.get("bb_pm")):
            cur.update({"imp_pm": r.get("imp_pm"), "bb_pm": r["bb_pm"]})
        self.d["bands"][bid] = cur
        pt = {"ts": now, "_h": _hour(now), "floor": round(floor, 1), "car": len(pers)}
        if raise_db is not None:
            pt["raise"] = raise_db
        if _fin(r.get("bb_pm")):
            pt["bb_pm"] = r["bb_pm"]
            pt["imp_pm"] = r.get("imp_pm") if _fin(r.get("imp_pm")) else None
        self.h[bid] = (self.h[bid] + [pt])[-self.CAP:]
        self.hdirty = True

    def finish_block(self, cfg, now=None):
        """Nach allen Messbereichen: Gesamtampel Stoerer + Gewitter-Hinweis (Impulse gegen Stunden-Grundlinie), Impuls-Verlauf."""
        now = int(now or time.time())
        bands = self.d["bands"]
        fresh = [b for b in NOISE_IDS if (bands.get(b) or {}).get("ok") and 0 <= now - bands[b].get("t", 0) < 3600]
        q = [bands[b]["lvl"] for b in fresh]
        self.d["qrm"] = {"t": now, "lvl": _lvl(*q) if q else "grau", "trend": [b for b in fresh if (bands[b].get("trend") or {}).get("on")]}
        hf = [b for b in ("mw", "hf10") if b in fresh and _fin(bands[b].get("bb_pm"))]
        th = {"t": now, "lvl": "grau", "bb_pm": None, "base": None, "why": "MW/KW nicht messbar (Direktabtastung / KW-Antenne?)"}
        if hf:
            bid = max(hf, key=lambda y: bands[y]["bb_pm"])
            bb = float(bands[bid]["bb_pm"])
            med, mad, nb, src = self.baseline(bid, "bb_pm", now)
            ref = max(1.0, med or 0.0)
            mad = mad or 0.0
            yel = max(float(cfg.get("thunder_yel_pm") or 5), 3 * ref, (med or 0) + 4 * mad)
            red = max(float(cfg.get("thunder_red_pm") or 20), 6 * ref, (med or 0) + 6 * mad)
            prev = [y.get("bb_pm") for y in self.h.get("impulse", [])[-1:] if 0 <= now - y.get("ts", 0) < 3600]
            lvl = "gruen"
            if bb >= red and prev and _fin(prev[0]) and prev[0] >= max(5.0, 3 * ref):
                lvl = "rot"
            elif bb >= yel:
                lvl = "gelb"
            why = {"gruen": "ruhig", "gelb": "mehr breitbandige Impulse als üblich", "rot": "stark impulsiv, steigend"}[lvl]
            if med is None:
                lvl, why = "grau", "lernt Grundlinie (erste 24 h, noch keine Bewertung)"
            th = {"t": now, "lvl": lvl, "bb_pm": bb, "base": None if med is None else round(med, 1), "src": src, "yel": round(yel, 1), "red": round(red, 1),
                  "band": bid, "why": why}
            self.h["impulse"] = (self.h["impulse"] + [{"ts": now, "_h": _hour(now), "bb_pm": bb, "base": th["base"]}])[-self.CAP:]
            self.hdirty = True
        self.d["thunder"] = th
        self.d["v"], self.d["t"] = V, now
        write_json(self.f, self.d)
        self.save_hist(now=now)

    def save_hist(self, force=False, now=None):
        now = float(now or time.time())
        if self.hdirty and (force or now - self.last_hsave > 1800 or now < self.last_hsave):
            cut = now - self.KEEP_S
            for k in list(self.h):
                if isinstance(self.h[k], list):
                    self.h[k] = [x for x in self.h[k] if cut <= x.get("ts", 0) <= now + 3600][-self.CAP:]
            write_json_keep(self.fh, self.h)
            self.hdirty, self.last_hsave = False, now


# ---------------------------------------------------------------- Frequenzkalibrierung (DAB-Traeger, welle-cli Frequenzkorrektur)
def cal_compute(c0, c1, step_ppm, f_hz):
    """c0/c1: welle-cli Frequenzkorrektur (Hz) bei rtl_tcp -P 0 und -P step. Steigung prueft Einheit und Vorzeichen.
    -> (ppm, note) ; ppm None = unzuverlaessig"""
    if c0 is None or c1 is None or not step_ppm:
        return None, "zu wenig Messwerte"
    k = f_hz / 1e6
    s = (c1 - c0) / (step_ppm * k)
    if not (0.6 <= abs(s) <= 1.4):
        return None, "Steigung %.2f unplausibel" % s
    ppm = -c0 / (s * k)
    if not (-10.0 <= ppm <= 10.0):
        return None, "%.1f ppm ausserhalb -10..+10" % ppm
    return round(ppm, 2), "ok (Steigung %.2f)" % s


def ppm_val(cfg):
    v = cfg.get("ppm")
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    v = int(round(v))
    return v if -10 <= v <= 10 else 0


class BcEvents:
    """broadcast_events.jsonl: Rundfunk-Ereignisse der letzten 48 h (TA Beginn/Ende mit RT, RDS-Warn-RT, DAB-Ansagen, DLS).
    Klein gehalten (max 1500 Eintraege / 400 kB), atomar neu geschrieben (tmp + rename), hoechstens alle 60 s."""
    KEEP_S = 48 * 3600
    MAX_N = 1500
    MAX_B = 400 * 1024

    def __init__(self, base):
        self.f = p("broadcast_events.jsonl", base)
        self.ev = []
        try:
            for ln in open(self.f, encoding="utf-8"):
                try:
                    x = json.loads(ln)
                except Exception:
                    continue
                if isinstance(x, dict) and isinstance(x.get("t"), (int, float)):
                    self.ev.append(x)
        except Exception:
            pass
        self.dirty = False
        self.last_saved = 0
        self.seq = max([x.get("id", 0) for x in self.ev] + [0])

    def add(self, k, src, now, **kw):
        self.seq += 1
        e = {"id": self.seq, "t": int(now), "k": k, "src": str(src)[:40]}
        for a, b in kw.items():
            if b not in (None, ""):
                e[a] = b[:200] if isinstance(b, str) else b
        self.ev.append(e)
        self.dirty = True
        return e

    def find(self, eid):
        for x in reversed(self.ev[-200:]):
            if x.get("id") == eid:
                return x
        return None

    def trim(self, now):
        cut = now - self.KEEP_S
        ev = [x for x in self.ev if (x.get("end") or x.get("t", 0)) >= cut or x.get("open")][-self.MAX_N:]
        while ev and sum(len(json.dumps(x, ensure_ascii=False)) + 1 for x in ev) > self.MAX_B:
            ev = ev[len(ev) // 10 + 1:]
        if len(ev) != len(self.ev):
            self.dirty = True
        self.ev = ev

    def save(self, force=False):
        now = time.time()
        if self.dirty and (force or now - self.last_saved > 60):
            self.trim(now)
            tmp = self.f + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                for x in self.ev:
                    fh.write(json.dumps(x, ensure_ascii=False, separators=(",", ":")) + "\n")
            os.replace(tmp, self.f)
            self.dirty, self.last_saved = False, now


class StateBC:
    """broadcast_state.json: je UKW-Sender PS/RT/TA/TP, je DAB-Kanal Ensemble/DLS/Ansagen, Warnliste."""

    def __init__(self, base):
        self.f = p("broadcast_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "fm": {}, "dab": {}, "warn": []}
        for k, v in (("fm", {}), ("dab", {}), ("warn", [])):
            self.d.setdefault(k, v)
        self.dirty = False
        self.last_saved = 0
        self.cur = None
        self.evl = BcEvents(os.path.dirname(self.f))
        self.ta_open = {}   # Sender -> Ereignis-ID (TA laeuft)
        self.ta_post = {}   # Sender -> (ID, bis) RT nach TA-Ende noch 60 s mitschreiben
        self.last_rt = {}
        self.last_dls = {}
        self.rt_seen = {}
        self.asa_seen = {}
        self.last_ann = {}

    def _rt_into(self, eid, rt):
        e = self.evl.find(eid)
        if e is not None and rt and rt not in (e.get("rt") or []):
            e["rt"] = (e.get("rt") or []) + [rt[:80]]
            e["rt"] = e["rt"][-8:]
            self.evl.dirty = True

    def ta_close(self, name, now, why=None):
        eid = self.ta_open.pop(name, None)
        e = self.evl.find(eid) if eid else None
        if e is None:
            return
        last = self.d["fm"].get(name, {}).get("t", now)
        end = int(now if why is None else min(now, last))
        e.update({"open": False, "end": end, "dur_s": max(0, end - e["t"])})
        if why:
            e["note"] = why
        self.evl.dirty = True
        self.ta_post[name] = (eid, now + 60)

    def tick(self, now, listening=None):
        """TA ohne Ende schliessen, wenn der Sender nicht mehr gehoert wird (Rundfunk-Block vorbei)."""
        for name in list(self.ta_open):
            if name != listening and now - self.d["fm"].get(name, {}).get("t", 0) > 90:
                self.ta_close(name, now, "Empfang beendet, Ende unbekannt")

    def warn(self, src, kind, text, now):
        w = self.d["warn"]
        for x in w[-20:]:
            same = x.get("text") == text or (kind == "TA" and now - x.get("last", 0) < 1800)
            if x.get("src") == src and x.get("kind") == kind and same and now - x.get("t", 0) < 6 * 3600:
                x["last"] = int(now)
                return
        w.append({"t": int(now), "last": int(now), "src": src, "kind": kind, "text": (text or "")[:160]})
        cut = now - 48 * 3600
        self.d["warn"] = [x for x in w if x.get("last", x.get("t", 0)) >= cut][-60:]

    def on_rds(self, name, freq, line, now=None):
        line = line.strip()
        if not line.startswith("{"):
            return None
        try:
            g = json.loads(line)
        except Exception:
            return None
        now = now or time.time()
        s = self.d["fm"].get(name) or {"name": name, "f": freq}
        s.update({"f": freq, "t": int(now)})
        s["groups"] = s.get("groups", 0) + 1
        if g.get("pi"):
            s["pi_t"] = int(now)
        for k_in, k_out in (("pi", "pi"), ("ps", "ps"), ("radiotext", "rt"), ("prog_type", "pty"), ("tp", "tp"), ("ta", "ta")):
            if k_in in g:
                s[k_out] = g[k_in] if not isinstance(g[k_in], str) else g[k_in].strip()[:80]
        rp = g.get("radiotext_plus")
        if isinstance(rp, dict) and isinstance(rp.get("tags"), list):
            s["rtp"] = [str(x.get("content-type"))[:24] for x in rp["tags"][:6] if isinstance(x, dict) and x.get("content-type")]
        if "prog_type" in g:
            pty = g.get("prog_type")
            if pty == 31 or (isinstance(pty, str) and re.search(r"alarm", pty, re.I)):
                if not s.get("pty31_since") or now - s.get("pty31_last", 0) > 120:
                    s["pty31_since"], s["pty31_n"], s["pty31_persist"] = int(now), 0, 0
                    self.evl.add("pty31", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 31 (Alarm) gesehen", persist=False)
                s["pty31_n"] = s.get("pty31_n", 0) + 1
                s["pty31_last"] = int(now)
                if not s.get("pty31_persist") and s["pty31_n"] >= 3 and now - s["pty31_since"] >= PTY31_PERSIST_S:
                    s["pty31_persist"] = 1
                    self.evl.add("pty31", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS PTY 31 (Alarm) dauerhaft seit %d s" % int(now - s["pty31_since"]), persist=True)
                    self.warn(name, "PTY31", "RDS PTY 31 Alarm (dauerhaft)", now)
            else:
                s["pty31_since"], s["pty31_persist"] = 0, 0
        rt = g["radiotext"].strip()[:80] if isinstance(g.get("radiotext"), str) else None
        rt_new_stable = False
        if rt:
            sn = self.rt_seen.get(name)
            if sn and sn[0] == rt:
                sn[1] += 1
            else:
                sn = self.rt_seen[name] = [rt, 1]
            if sn[1] == 2:       # vollstaendig (redsea: ganze Nachricht) und 2x gleich empfangen = stabil
                rt_new_stable = True
                s["rt_ok"], s["rt_ok_t"] = rt, int(now)
        if g.get("ta") is True and s.get("tp"):
            s["ta_t"] = int(now)
            self.warn(name, "TA", "Durchsage aktiv (TA)", now)
            if name not in self.ta_open:
                e = self.evl.add("ta", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), open=True, rt=[x for x in (s.get("rt"),) if x])
                self.ta_open[name] = e["id"]
        elif g.get("ta") is False and name in self.ta_open:
            self.ta_close(name, now)
        if rt and rt != self.last_rt.get(name):
            self.last_rt[name] = rt
            if name in self.ta_open:
                self._rt_into(self.ta_open[name], rt)
            elif name in self.ta_post and now <= self.ta_post[name][1]:
                self._rt_into(self.ta_post[name][0], rt)
        if rt_new_stable:
            sc = _ws_score(rt, s.get("rtp"))
            if sc["cls"] or WARN_WORDS.search(rt):
                self.evl.add("rt_warn", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text=rt, cls=sc["cls"], why=sc["why"][:80])
            if sc["cls"] == "rot":
                self.warn(name, "RT", rt, now)
        if g.get("group") in ("9A",) or "ews" in g:
            if now - self.last_ann.get("ews:" + name, 0) > 1800:
                self.evl.add("ews", name, now, f=freq, ps=s.get("ps"), pi=s.get("pi"), text="RDS-Notfallgruppe empfangen")
            self.last_ann["ews:" + name] = now
            self.warn(name, "EWS", "RDS-Notfallgruppe empfangen", now)
        self.d["fm"][name] = s
        self.dirty = True
        return s

    def on_dab(self, ch, mux, now=None):
        now = now or time.time()
        if not isinstance(mux, dict):
            return None
        ens = mux.get("ensemble") or {}
        lab = ens.get("label") if isinstance(ens.get("label"), str) else (ens.get("label") or {}).get("label")
        svcs, alarm = [], []

        def walk(o, path):
            if isinstance(o, dict):
                for k, v in o.items():
                    kl = str(k).lower()
                    if ("announc" in kl or "alarm" in kl or kl in ("asu", "asw")) and v not in (None, False, 0, "", [], {}):
                        alarm.append("%s%s=%s" % (path, k, json.dumps(v, ensure_ascii=False)[:80]))
                    walk(v, path + str(k) + ".")
            elif isinstance(o, list):
                for x in o[:80]:
                    walk(x, path)
        walk(mux, "")
        for sv in (mux.get("services") or [])[:40]:
            if not isinstance(sv, dict):
                continue
            l = sv.get("label")
            l = l if isinstance(l, str) else (l or {}).get("label")
            dls = sv.get("dls")
            dls = dls if isinstance(dls, str) else (dls or {}).get("label")
            sid = sv.get("sid", sv.get("SId", sv.get("id")))
            sid = ("0x%04X" % sid) if isinstance(sid, int) and not isinstance(sid, bool) and 0 <= sid <= 0xFFFFFFFF else (str(sid).strip()[:12] if isinstance(sid, str) and re.match(r"^(0x)?[0-9A-Fa-f]{1,8}$", sid.strip()) else None)
            asa = bool(ASA_RE.match(l or ""))
            svcs.append(dict({"label": (l or "?").strip()[:30], "dls": (dls or "").strip()[:160], "sid": sid}, **({"asa": True} if asa else {})))
            key = "%s|%s" % (ch, (l or "?").strip()[:30])
            dl = (dls or "").strip()[:160]
            if asa and (key not in self.asa_seen or now - self.asa_seen[key] > 6 * 3600):
                self.asa_seen[key] = now
                self.evl.add("asa", "DAB %s" % ch, now, svc=(l or "?").strip()[:30], sid=sid, text="ASA-Dienst empfangen (Dienst allein ist kein Alarm)")
            sc = _ws_score(dl)
            if dl and self.last_dls.get(key) != dl:
                self.last_dls[key] = dl
                self.evl.add("dls", "DAB %s" % ch, now, svc=(l or "?").strip()[:30], text=dl, warn=sc["cls"] == "rot", cls=sc["cls"], asa=asa)
            if dl and sc["cls"] == "rot":
                self.warn("DAB %s %s" % (ch, (l or "").strip()), "DLS", dl, now)
        for a in alarm[:3]:
            self.warn("DAB %s" % ch, "Ansage", a, now)
        sig = "|".join(sorted(alarm[:5]))
        if sig != self.last_ann.get("dab:" + ch, ""):
            if alarm:
                self.evl.add("dab_ann", "DAB %s" % ch, now, text="; ".join(alarm[:3]), ens=(lab or "").strip()[:40])
            elif self.last_ann.get("dab:" + ch):
                self.evl.add("dab_ann_end", "DAB %s" % ch, now, text="Ansage beendet")
            self.last_ann["dab:" + ch] = sig
        self.d["dab"][ch] = {"ch": ch, "t": int(now), "ensemble": (lab or "").strip()[:40], "services": svcs, "alarm": alarm[:5], "n": len(svcs),
                             "asa": [x for x in svcs if x.get("asa")][:3]}
        self.dirty = True
        return self.d["dab"][ch]

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 60):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()
        self.tick(time.time(), self.cur)
        self.evl.save(force)


# ---------------------------------------------------------------- Wettersatelliten (Meteor-M LRPT) - Bahnvorhersage
SATS_DEFAULT = [{"name": "METEOR-M2 3", "norad": 57166, "f": "137.9e6"}, {"name": "METEOR-M2 4", "norad": 59051, "f": "137.9e6"}]


def _gmst(jd_ut1):
    t = (jd_ut1 - 2451545.0) / 36525.0
    g = 67310.54841 + (876600.0 * 3600 + 8640184.812866) * t + 0.093104 * t * t - 6.2e-6 * t ** 3
    return math.radians((g % 86400.0) / 240.0)


def _obs_ecef(lat, lon, h_km=0.35):
    a, f = 6378.137, 1 / 298.257223563
    e2 = f * (2 - f)
    la, lo = math.radians(lat), math.radians(lon)
    n = a / math.sqrt(1 - e2 * math.sin(la) ** 2)
    return ((n + h_km) * math.cos(la) * math.cos(lo), (n + h_km) * math.cos(la) * math.sin(lo), (n * (1 - e2) + h_km) * math.sin(la))


def look(sat, t, lat, lon):
    """-> (Elevation, Azimut) in Grad zum Zeitpunkt t (Unix) oder None. sgp4 TEME -> ECEF (GMST-Drehung)."""
    jd = t / 86400.0 + 2440587.5
    jd0 = math.floor(jd - 0.5) + 0.5
    e, r, _v = sat.sgp4(jd0, jd - jd0)
    if e != 0:
        return None
    g = _gmst(jd)
    x = r[0] * math.cos(g) + r[1] * math.sin(g)
    y = -r[0] * math.sin(g) + r[1] * math.cos(g)
    z = r[2]
    ox, oy, oz = _obs_ecef(lat, lon)
    dx, dy, dz = x - ox, y - oy, z - oz
    la, lo = math.radians(lat), math.radians(lon)
    east = -math.sin(lo) * dx + math.cos(lo) * dy
    north = -math.sin(la) * math.cos(lo) * dx - math.sin(la) * math.sin(lo) * dy + math.cos(la) * dz
    up = math.cos(la) * math.cos(lo) * dx + math.cos(la) * math.sin(lo) * dy + math.sin(la) * dz
    rng = math.sqrt(east ** 2 + north ** 2 + up ** 2)
    return math.degrees(math.asin(up / rng)), (math.degrees(math.atan2(east, north)) + 360) % 360


def predict(tles, lat, lon, start, hours=36, min_el=20.0, horizon=8.0):
    """Ueberfluege mit Max-Elevation >= min_el. tles: [{name,norad,f,l1,l2}]."""
    try:
        from sgp4.api import Satrec
    except Exception:
        lib = os.path.join(BASE, "sdr_lib")  # Ersatz ohne Debian-Paket: reines Python-sgp4 (vom Patch, sha256-geprueft)
        if os.path.isdir(os.path.join(lib, "sgp4")) and lib not in sys.path:
            sys.path.append(lib)
        try:
            from sgp4.api import Satrec
        except Exception:
            return None
    out = []
    for s in tles:
        try:
            sat = Satrec.twoline2rv(s["l1"], s["l2"])
        except Exception:
            continue
        t, end, step = start, start + hours * 3600, 30
        inpass, aos, best, best_t, aos_az = False, None, -90, None, None
        while t <= end:
            la = look(sat, t, lat, lon)
            el = la[0] if la else -90
            if el >= horizon and not inpass:
                inpass, aos, best, best_t, aos_az = True, t, el, t, la[1]
            elif inpass and el >= horizon:
                if el > best:
                    best, best_t = el, t
            elif inpass:
                if best >= min_el:
                    out.append({"sat": s["name"], "norad": s["norad"], "f": s["f"], "aos": int(aos), "los": int(t), "max_el": round(best, 1),
                                "max_t": int(best_t), "dur_s": int(t - aos), "dir": "N→S" if aos_az is not None and (aos_az < 90 or aos_az > 270) else "S→N"})
                inpass = False
            t += step
    out.sort(key=lambda x: x["aos"])
    # Ueberschneidungen: hoeheren Ueberflug behalten
    res = []
    for x in out:
        if res and x["aos"] < res[-1]["los"]:
            if x["max_el"] > res[-1]["max_el"]:
                res[-1] = x
            continue
        res.append(x)
    return res


# ---------------------------------------------------------------- Planer
class ActMeter:
    """Aktivitaet eines Kanals aus rohen IQ-Daten (rtl_sdr, Mitte = Kanalfrequenz): Leistung im Kanal (+-6 kHz,
    ohne DC-Spitze) gegen Rauschboden (20-%-Quantil ausserhalb). Nichts wird demoduliert oder gespeichert.
    Ergebnis je Minute: Belegung %, Spitze dBFS, Anzahl Aussendungen, Rauschboden dBFS."""
    FS = 240000
    N = 1024

    def __init__(self, on_db=6.0, off_db=3.0):
        import numpy as np
        self.np = np
        self.win = np.hanning(self.N).astype(np.float32)
        self.wpow = float((self.win ** 2).sum())
        f = np.fft.fftfreq(self.N, 1.0 / self.FS)
        af = np.abs(f)
        self.ch = (af <= 6000) & (af >= 600)
        self.ref = (af >= 20000) & (af <= 100000)
        self.on_db, self.off_db = on_db, off_db
        self.rest = b""
        self.on = False
        self.on_blocks = 0
        self.m0 = None
        self._reset(None)

    def _reset(self, t):
        self.m0 = t
        self.nb = 0
        self.nb_on = 0
        self.peak = None
        self.tx = 0
        self.noise = []

    def _record(self):
        if not self.nb:
            return None
        nz = sorted(self.noise)
        return {"t": int(self.m0), "s": round(self.nb * self.N * 16 / self.FS), "occ_pct": round(100.0 * self.nb_on / self.nb, 1),
                "peak_dbfs": round(self.peak, 1) if self.peak is not None else None, "tx": self.tx,
                "noise_dbfs": round(nz[len(nz) // 2], 1) if nz else None}

    def feed(self, raw, now=None):
        """raw: u8 IQ. -> Liste fertiger Minuten-Datensaetze."""
        np = self.np
        now = now or time.time()
        if self.m0 is None:
            self._reset(now - now % 60)
        out = []
        data = self.rest + raw
        blk = self.N * 2 * 16  # 16 FFTs je Messblock (~68 ms)
        nfull = len(data) // blk
        self.rest = data[nfull * blk:]
        for i in range(nfull):
            if now - self.m0 >= 60:
                r = self._record()
                if r:
                    out.append(r)
                self._reset(now - now % 60)
            a = np.frombuffer(data[i * blk:(i + 1) * blk], dtype=np.uint8).astype(np.float32)
            a = (a - 127.4) / 127.5
            z = (a[0::2] + 1j * a[1::2]).reshape(16, self.N)
            psd = (np.abs(np.fft.fft(z * self.win, axis=1)) ** 2).mean(axis=0) / (self.N * self.wpow)
            pch = float(psd[self.ch].sum())
            nref = float(np.quantile(psd[self.ref], 0.2)) * int(self.ch.sum())
            snr = 10 * math.log10(max(pch, 1e-20) / max(nref, 1e-20))
            dbfs = 10 * math.log10(max(pch, 1e-20))
            self.noise.append(10 * math.log10(max(nref, 1e-20)))
            if len(self.noise) > 2000:
                self.noise = self.noise[::2]
            self.nb += 1
            if self.on:
                if snr < self.off_db:
                    self.on = False
            elif snr > self.on_db:
                self.on = True
                self.on_blocks = 0
            if self.peak is None or dbfs > self.peak:
                self.peak = dbfs
            if self.on:
                self.nb_on += 1
                self.on_blocks += 1
                if self.on_blocks == 4:  # erst ab ~0,3 s als Aussendung zaehlen
                    self.tx += 1
        return out

    def finish(self):
        r = self._record()
        self._reset(None)
        return [r] if r and r["s"] >= 20 else []


class ActState:
    """Minutenwerte (nur Zahlen) je Aktivitaets-Preset, 3 Tage, sparsam gespeichert (activity_state.json)."""

    def __init__(self, base):
        self.f = p("activity_state.json", base)
        self.d = load_json(self.f, None) or {"v": V, "series": {}}
        self.d.setdefault("series", {})
        self.dirty = False
        self.last_saved = 0

    def add(self, pid, rec):
        s = self.d["series"].setdefault(pid, [])
        s.append(rec)
        cut = time.time() - 3 * 86400
        self.d["series"][pid] = [x for x in s if x.get("t", 0) >= cut][-4320:]
        self.dirty = True

    def save(self, force=False):
        if self.dirty and (force or time.time() - self.last_saved > 300):
            self.d["v"], self.d["saved"] = V, int(time.time())
            write_json(self.f, self.d)
            self.dirty, self.last_saved = False, time.time()


class LineLog:
    """Zeilen-Logger (prepper_linelog-Art) im Planer: Decoder-Ausgabe des gewaehlten Presets mit Zeitstempel,
    optional nur Zeilen mit festem Stichwort (sdr_config.json linelog_keyword), gepuffert und atomar
    (tmp + fsync + os.replace) nach archive/linelog/<preset>_<JJJJMMTT>[_n].jsonl. Kein Port, kein Netz."""

    def __init__(self, base, cfg):
        self.dir = os.path.join(base, "archive", "linelog")
        kw = cfg.get("linelog_keyword")
        self.kw = str(kw).lower() if isinstance(kw, str) and kw.strip() else None
        self.on = bool(cfg.get("linelog_enable", True))
        self.flush_s = max(30.0, float(cfg.get("linelog_flush_s") or 300))
        self.part = max(32, int(cfg.get("linelog_part_kb") or 512)) * 1024
        self.keep = max(1, int(cfg.get("linelog_keep_days") or 14))
        self.buf = []
        self.lock = threading.Lock()
        self.last = time.time()
        self.n = 0
        self.dropped = 0

    def add(self, pid, text, now=None, numeric=False):
        if not self.on or pid not in PRESET_IDS:
            return False
        t = (text or "").strip()
        if not t or (self.kw and not numeric and self.kw not in t.lower()):
            return False
        with self.lock:
            if len(self.buf) >= 5000:
                self.buf.pop(0)
                self.dropped += 1
            self.buf.append({"t": round(now or time.time(), 1), "preset": pid, "line": t[:600]})
            self.n += 1
        return True

    def _target(self, pid, day, size_add):
        i = 1
        while True:
            name = "%s_%s%s.jsonl" % (pid, day, "" if i == 1 else "_%d" % i)
            fn = os.path.join(self.dir, name)
            if not os.path.exists(fn) or os.path.getsize(fn) + size_add <= self.part or i >= 50:
                return fn
            i += 1

    def flush(self, force=False):
        if not force and time.time() - self.last < self.flush_s:
            return 0
        self.last = time.time()
        with self.lock:
            buf, self.buf = self.buf, []
        if not buf:
            return 0
        os.makedirs(self.dir, exist_ok=True)
        groups = {}
        for r in buf:
            groups.setdefault((r["preset"], time.strftime("%Y%m%d", time.localtime(r["t"]))), []).append(r)
        for (pid, day), rows in groups.items():
            data = "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in rows).encode("utf-8")
            fn = self._target(pid, day, len(data))
            old = b""
            if os.path.exists(fn):
                with open(fn, "rb") as f:
                    old = f.read()
            tmp = fn + ".tmp"
            with open(tmp, "wb") as f:
                f.write(old + data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, fn)
        self.prune()
        return len(buf)

    def prune(self):
        cut = time.time() - self.keep * 86400
        try:
            for name in os.listdir(self.dir):
                fn = os.path.join(self.dir, name)
                if name.endswith((".jsonl", ".tmp")) and os.path.getmtime(fn) < cut:
                    os.remove(fn)
        except Exception:
            pass


class Planner:
    def __init__(self, base):
        self.base = base
        self.cfg = config(base)
        self.s433 = State433(base)
        self.saprs = StateAPRS(base, tuple(self.cfg["home"]))
        self.procs = []
        self.active = "idle"
        self.since = time.time()
        self.slice_start = time.time()
        self.auto_idx = 0
        self.fails = 0
        self.retry_at = 0
        self.err = None
        self.err_t = None
        self.stderr = []
        self.stop = False
        self.lock = threading.Lock()
        self.last_status = 0
        self.last_prune = 0
        self.stick = []
        self.dev_idx = None
        self.dev_sn = None
        self.list_n = 0
        self.pin_err = None
        self.sticks_n = 0
        self.others = []
        self.counts = {"433": 0, "aprs": 0, "rds": 0, "dab": 0, "meteor": 0, "linelog": 0}
        self.llog = LineLog(base, self.cfg)
        self.sact = ActState(base)
        self.last_dabpoll = 0
        self.pmeteor = None
        self._lastdls = {}
        self.sbc = StateBC(base)
        self.snoise = NoiseState(base)
        self.nzm = None
        self.nzt = None
        self.last_noise = time.time() - float(self.cfg.get("noise_interval_s") or 900) + max(45.0, float(self.cfg.get("noise_warmup_s") or 300))
        self._has_rp = None
        self.cal_samples = [[], []]
        self.cal_res = [None, None]
        self.last_calpoll = 0
        self.special = None
        self.gps = None
        self.evlog = self.kfz = None
        self.last_bc = time.time() - float(self.cfg.get("bc_interval_s") or 1800) + 120
        self.passes = (load_json(p("sdr_passes.json", base), {}) or {}).get("passes") or []
        self.last_predict = 0
        self.last_tle_try = 0
        self.tools = {}
        self.started = time.time()
        self.lastsig = None

    def log(self, *a):
        print("prepper-sdr:", *a, flush=True)

    def _dev(self, args, flag="-d"):
        """Immer genau der gebundene Stick: rtl_433 per :SERIENNUMMER, sonst der beim Start aufgeloeste Index."""
        if self.dev_idx is None or not serial_ok(self.dev_sn):
            raise RuntimeError("Stick nicht aufgeloest")
        if args[0] == "rtl_433":
            return args + ["-d", ":" + self.dev_sn]
        return args + [flag, str(int(self.dev_idx))]

    def resolve(self):
        """Seriennummer -> Index, bei jedem Start neu (Reihenfolge kann sich nach Umstecken aendern)."""
        self.dev_idx = None
        sn = cfg_serial(self.cfg)
        if sn is None:
            raise RuntimeError("Seriennummer in sdr_config.json ungueltig (nur Ziffern)")
        lst, e = list_sticks()
        if lst is None:
            raise RuntimeError("Stick-Liste: %s" % e)
        idx, e = pick_stick(lst, sn)
        if e:
            raise RuntimeError(e)
        self.dev_idx, self.dev_sn, self.list_n = idx, sn, len(lst)
        return idx

    def tool(self, name):
        if name not in self.tools:
            import shutil
            exe = {"redsea": "redsea", "welle": "welle-cli", "satdump": "satdump"}[name]
            cand = self.cfg.get(name) or shutil.which(exe) or ("/usr/local/bin/" + exe if os.path.exists("/usr/local/bin/" + exe) else None)
            ok = cand and os.path.basename(str(cand)) == exe and os.path.isfile(cand) and os.access(cand, os.X_OK)
            self.tools[name] = cand if ok else None
        return self.tools[name]

    def fm_list(self):
        v = self.cfg.get("fm")
        return v if isinstance(v, list) and v else FM_DEFAULT

    def dab_list(self):
        v = self.cfg.get("dab")
        v = list(v) if isinstance(v, list) and v else list(DAB_DEFAULT)
        if self.cfg.get("asa_5c", True) and "5C" not in v:
            v.append("5C")      # br24Warn2: ASA DE (DR Deutschland 5C) bei jedem Rundfunk-Block mitlesen
        return v

    def sat_list(self):
        v = self.cfg.get("sats")
        return v if isinstance(v, list) and v else SATS_DEFAULT

    def cmd(self, what):
        c = self.cfg
        if what.startswith("p:"):
            ps = preset(what[2:])
            if ps is None:
                raise RuntimeError("Preset unbekannt: %s" % what)
            k = ps["kind"]
            check_tune(k, ps.get("f"), ps.get("ch"))
            if k in ("ism433", "srd868"):
                a = ["rtl_433", "-f", ps["f"], "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"]
                if k == "srd868":
                    a += ["-s", "1024k"]
                if ppm_val(c):
                    a += ["-p", str(ppm_val(c))]
                if c.get("gain_433") not in (None, ""):
                    a += ["-g", str(c["gain_433"])]
                return [self._dev(a)]
            if k == "aprs":
                return self.cmd("aprs")
            if k == "fm":
                return self._cmd_rds(ps["f"])
            if k == "dab":
                return self._cmd_dab(ps["ch"])
            if k in ACT_KINDS:
                return self._cmd_act(k, ps["f"])
            if k == "wxsat":
                m = get_mode(self.base)
                secs = max(60, int((m.get("until") or time.time() + 1800) - time.time()))
                return self._cmd_meteor(ps["f"], secs, c["meteor_tmp"])
            raise RuntimeError("Preset-Art unbekannt")
        if what.startswith("nz:"):
            return self._cmd_noise(int(what[3:]))
        if what.startswith("cal:"):
            return self._cmd_cal(int(what[4:]))
        if what.startswith("rds:"):
            st = self.fm_list()[int(what[4:])]
            return self._cmd_rds(st["f"])
        if what.startswith("dab:"):
            return self._cmd_dab(str(self.dab_list()[int(what[4:])]))
        if what == "meteor":
            sp = self.special or {}
            ps = sp.get("pass") or {}
            secs = max(60, int(ps.get("los", time.time() + 600) - time.time()))
            return self._cmd_meteor(ps.get("f") or "137.9e6", secs, sp.get("tmp") or c["meteor_tmp"])
        if what == "433":
            check_tune("ism433", c["f433"])
        if what == "aprs":
            check_tune("aprs", c["faprs"])
        return self._cmd_base(what)

    def _cmd_rds(self, f):
        c = self.cfg
        check_tune("fm", f)
        a = ["rtl_fm", "-M", "fm", "-l", "0", "-A", "std", "-s", "171k", "-F", "9", "-f", str(f)]
        if ppm_val(c):
            a += ["-p", str(ppm_val(c))]
        if c.get("gain_fm") not in (None, ""):
            a += ["-g", str(c["gain_fm"])]
        return [self._dev(a) + ["-"], [self.tool("redsea"), "-r", "171k"]]

    def _cmd_dab(self, ch):
        c = self.cfg
        check_tune("dab", ch=ch)
        if self.list_n == 1 and self.dev_idx == 0 and serial_ok(self.dev_sn):
            # genau ein Stick vorhanden und das ist unserer -> welle-cli direkt (sicher, es gibt keinen anderen)
            a = [self.tool("welle"), "-c", str(ch), "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_sdr"]
            if c.get("gain_dab") not in (None, ""):
                a += ["-g", str(c["gain_dab"])]
            return [a]
        # mehrere Sticks: welle-cli nimmt mit -F rtl_sdr "den ersten freien" - darum getrennt: rtl_tcp nur 127.0.0.1 am gebundenen Stick,
        # dann welle-cli als eigener Prozess (kein Pipe), erst wenn der Port lauscht
        port = int(c.get("dab_tcp_port") or 1235)
        if not (1024 < port < 65536) or port in (int(c["tcp_port"]), int(c["dab_port"])):
            raise RuntimeError("dab_tcp_port ungueltig")
        srv = self._dev(["rtl_tcp", "-a", "127.0.0.1", "-p", str(port), "-P", str(ppm_val(c))])
        a = [self.tool("welle"), "-c", str(ch), "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_tcp,127.0.0.1:%d" % port]
        if c.get("gain_dab") not in (None, ""):
            a += ["-g", str(c["gain_dab"])]
        return [srv, a]

    def _cmd_act(self, kind, f):
        """Nur rohe IQ-Daten nach stdout (Planer misst Pegel, verwirft die Daten). Mitte = Kanalfrequenz."""
        c = self.cfg
        check_tune(kind, f)
        try:
            import numpy  # noqa: F401
        except Exception:
            raise RuntimeError("Aktivitaet: python3-numpy fehlt")
        a = ["rtl_sdr", "-f", str(f), "-s", str(ActMeter.FS)]
        if ppm_val(c):
            a += ["-p", str(ppm_val(c))]
        if c.get("gain_act") not in (None, ""):
            a += ["-g", str(c["gain_act"])]
        return [self._dev(a) + ["-"]]

    def _act_reader(self, stream, pid):
        try:
            mt = ActMeter()
        except Exception as e:
            self.log("Aktivitaet:", e)
            return
        def put(recs):
            for r in recs:
                with self.lock:
                    self.sact.add(pid, r)
                self._ll(pid, json.dumps(dict(r, preset=pid), separators=(",", ":")), numeric=True)
        try:
            while True:
                raw = stream.read(122880)
                if not raw:
                    break
                put(mt.feed(raw))
        except Exception as e:
            self.log("Aktivitaet Messung:", e)
        put(mt.finish())

    def _cmd_noise(self, i):
        """Nur Leistung je Bin: rtl_power (VHF/UHF/GPS) bzw. rtl_fm -M raw mit Q-Direktabtastung (MW/KW) nach stdout; Planer rechnet Zahlen."""
        b = NOISE_BANDS[i]
        c = self.cfg
        k = b["kind"]
        if k not in NOISE_KINDS:
            raise RuntimeError("Messbereich unbekannt")
        if b.get("hf"):
            check_tune(k, b["fc"])
            fc = to_mhz(b["fc"])
            half = b["sr"] / 2e6
            check_tune(k, "%.4fM" % (fc - half))
            check_tune(k, "%.4fM" % (fc + half))
            a = ["rtl_fm", "-M", "raw", "-E", "direct2", "-f", b["fc"], "-s", str(int(b["sr"])), "-g", noise_gain(c)]
        else:
            check_tune(k, b["lo"])
            check_tune(k, b["hi"])
            a = ["rtl_power", "-f", "%s:%s:%s" % (b["lo"], b["hi"], b["bin"]), "-i", str(int(b.get("i") or 1)), "-c", "0.2",
                 "-e", "%ds" % max(3, int(self._nz_secs(b)) - 1), "-g", noise_gain(c)]
        if ppm_val(c):
            a += ["-p", str(ppm_val(c))]
        return [self._dev(a) + ["-"]]

    def _nz_secs(self, b):
        return float(b.get("s") or self.cfg.get("noise_s") or 7)

    def _noise_reader(self, stream, mt, b):
        try:
            if b.get("hf"):
                while True:
                    raw = stream.read(65536)
                    if not raw:
                        break
                    mt.feed_iq(raw, b["sr"])
            else:
                for raw in iter(stream.readline, b""):
                    mt.feed_power(raw.decode("ascii", "replace"))
        except Exception as e:
            self.log("Funkumgebung Messung:", e)

    def noise_queue(self):
        c = self.cfg
        if not c.get("noise_enable"):
            return []
        try:
            import numpy  # noqa: F401
        except Exception:
            return []
        if self._has_rp is None:
            import shutil
            self._has_rp = bool(shutil.which("rtl_power"))
        q = []
        for i, b in enumerate(NOISE_BANDS):
            if b.get("hf") and not c.get("noise_hf"):
                continue
            if not b.get("hf") and not self._has_rp:
                continue
            q.append(("nz:%d" % i, self._nz_secs(b) + 1.5))
        return q

    def _cmd_cal(self, i):
        """Kalibrierung: rtl_tcp (127.0.0.1) mit -P 0 bzw. -P Schritt am ersten DAB-Kanal, welle-cli liest Frequenzkorrektur."""
        c = self.cfg
        ch = str(self.dab_list()[0])
        check_tune("dab", ch=ch)
        port = int(c.get("dab_tcp_port") or 1235)
        if not (1024 < port < 65536) or port in (int(c["tcp_port"]), int(c["dab_port"])):
            raise RuntimeError("dab_tcp_port ungueltig")
        step = int(c.get("cal_step_ppm") or 5)
        pp = [0, step][i]
        srv = self._dev(["rtl_tcp", "-a", "127.0.0.1", "-p", str(port), "-P", str(pp)])
        a = [self.tool("welle"), "-c", ch, "-C", "1", "-w", str(int(c["dab_port"])), "-F", "rtl_tcp,127.0.0.1:%d" % port]
        return [srv, a]

    def _cal_trigger(self):
        f = p("sdr_cal_now", self.base)
        if os.path.exists(f):
            try:
                os.remove(f)
            except Exception:
                pass
            return True
        return False

    def cal_due(self, now):
        c = self.cfg
        if not c.get("cal_enable") or not self.tool("welle"):
            return False
        if self._cal_trigger():
            return True
        pc = c.get("ppm_cal") if isinstance(c.get("ppm_cal"), dict) else {}
        lt = time.localtime(now)
        last = pc.get("try_t") or 0
        return lt.tm_hour == int(c.get("cal_hour") or 3) and time.strftime("%Y%m%d", time.localtime(last)) != time.strftime("%Y%m%d", lt)

    def _cal_poll(self, now):
        i = int(self.active[4:])
        try:
            import prepper_sdr_net
            mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
        except Exception:
            return
        dm = (mux or {}).get("demodulator") or {}
        fc, snr = dm.get("frequencycorrection"), dm.get("snr")
        if isinstance(fc, (int, float)) and isinstance(snr, (int, float)) and snr >= 3 and now - self.since >= 12:
            self.cal_samples[i].append(float(fc))

    def cal_sub(self, i):
        xs = sorted(self.cal_samples[i])
        self.cal_samples[i] = []
        if len(xs) >= 4:
            q1, q3 = xs[len(xs) // 4], xs[(3 * len(xs)) // 4]
            if q3 - q1 <= 40:
                self.cal_res[i] = _med(xs)
                return
        self.cal_res[i] = None

    def cal_finish(self, now):
        c = self.cfg
        ch = str(self.dab_list()[0])
        f_hz = DAB_CHANNELS[ch] * 1e6
        ppm, note = cal_compute(self.cal_res[0], self.cal_res[1], int(c.get("cal_step_ppm") or 5), f_hz)
        old = c.get("ppm_cal") if isinstance(c.get("ppm_cal"), dict) else {}
        rec = dict(old)
        rec.update({"try_t": int(now), "note": note, "ch": ch, "c0": self.cal_res[0], "c1": self.cal_res[1]})
        upd = {"ppm_cal": rec}
        if ppm is not None:
            rec.update({"ppm": ppm, "t": int(now), "ok": True})
            if c.get("ppm_auto", True):
                upd["ppm"] = int(round(ppm))
        else:
            rec["ok_last"] = False
        save_cfg_keys(self.base, upd)
        c.update(upd)
        self.cal_res = [None, None]
        self.log("Kalibrierung: %s -> %s" % (note, "%+.2f ppm (angewendet %+d)" % (ppm, ppm_val(c)) if ppm is not None else "alter Wert bleibt"))

    def _cmd_meteor(self, f, secs, tmp):
        c = self.cfg
        check_tune("wxsat", f)
        if not serial_ok(self.dev_sn) or self.dev_idx is None:
            raise RuntimeError("Stick nicht aufgeloest")
        return [[self.tool("satdump"), "live", "meteor_m2-x_lrpt", tmp, "--source", "rtlsdr", "--source_id", self.dev_sn,
                 "--samplerate", str(c["meteor_samplerate"]), "--frequency", str(f),
                 "--gain", str(c["meteor_gain"]), "--timeout", str(int(secs))] + (["--ppm_correction", str(ppm_val(c))] if ppm_val(c) else [])]

    def _cmd_base(self, what):
        c = self.cfg
        if what == "433":
            a = ["rtl_433", "-f", str(c["f433"]), "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"]
            if ppm_val(c):
                a += ["-p", str(ppm_val(c))]
            if c.get("gain_433") not in (None, ""):
                a += ["-g", str(c["gain_433"])]
            return [self._dev(a)]
        if what == "aprs":
            conf = p("sdr_direwolf.conf", self.base)
            try:
                if open(conf).read() != DIREWOLF_CONF:
                    raise ValueError
            except Exception:
                with open(conf, "w") as f:
                    f.write(DIREWOLF_CONF)
            a = ["rtl_fm", "-f", str(c["faprs"]), "-s", "24000"]
            if ppm_val(c):
                a += ["-p", str(ppm_val(c))]
            if c.get("gain_aprs") not in (None, ""):
                a += ["-g", str(c["gain_aprs"])]
            a = self._dev(a) + ["-"]
            return [a, ["direwolf", "-c", conf, "-r", "24000", "-D", "1", "-t", "0", "-q", "hd", "-"]]
        if what == "tcp":
            return [self._dev(["rtl_tcp", "-a", str(c["tcp_bind"]), "-p", str(int(c["tcp_port"])), "-P", str(ppm_val(c))])]
        return []

    def _reader(self, stream, fn):
        try:
            for raw in iter(stream.readline, b""):
                try:
                    fn(raw.decode("utf-8", "replace"))
                except Exception as e:
                    self.log("Zeile:", e)
        except Exception:
            pass

    def _err_reader(self, stream):
        try:
            for raw in iter(stream.readline, b""):
                s = raw.decode("utf-8", "replace").strip()
                if s:
                    with self.lock:
                        self.stderr = (self.stderr + [s[:160]])[-8:]
        except Exception:
            pass

    def on433(self, line):
        with self.lock:
            raw = self.s433.add(line)
            if raw is None:
                return
            self.counts["433"] += 1
        fn = p("rtl433.jsonl", self.base)
        rotate(fn, self.cfg["max_jsonl_mb"])
        with open(fn, "a", encoding="utf-8") as f:
            f.write(json.dumps(raw, ensure_ascii=False, separators=(",", ":")) + "\n")
        if self.kfz:
            try:
                with self.lock:
                    self.kfz.add(raw)
            except Exception as e:
                self.log("KFZ-Log:", e)

    def onaprs(self, line):
        with self.lock:
            r = self.saprs.add(line)
            if r is None:
                return
            self.counts["aprs"] += 1
        fn = p("aprs.jsonl", self.base)
        rotate(fn, self.cfg["aprs_max_jsonl_mb"])
        r = {k: v for k, v in r.items() if k != "raw"} | {"raw": r.get("raw", "")[:200]}
        with open(fn, "a", encoding="utf-8") as f:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")

    def onrds(self, st, line):
        with self.lock:
            if self.sbc.on_rds(st["name"], st["f"], line):
                self.counts["rds"] += 1

    def start(self, what):
        self.resolve()
        cmds = self.cmd(what)
        if self._pkind(what) == "wxsat":
            os.makedirs(self.cfg["meteor_tmp"], exist_ok=True)
        if any(not a[0] for a in cmds):
            raise RuntimeError("Start %s: Programm fehlt" % what)
        self.stderr = []
        prev = None
        procs = []
        if len(cmds) == 2 and cmds[0][0] == "rtl_tcp" and "127.0.0.1" in cmds[0] and str(cmds[1][0]).endswith("welle-cli"):
            self._start_sep(what, cmds)
            return
        try:
            for i, a in enumerate(cmds):
                last = i == len(cmds) - 1
                pr = subprocess.Popen(a, stdin=(prev.stdout if prev else subprocess.DEVNULL), stdout=subprocess.PIPE if (not last or what in ("433", "aprs") or what.startswith(("rds:", "nz:")) or self._pkind(what) in ("ism433", "srd868", "aprs", "fm") + ACT_KINDS) else subprocess.DEVNULL,
                                      stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
                if prev is not None:
                    prev.stdout.close()
                procs.append(pr)
                threading.Thread(target=self._err_reader, args=(pr.stderr,), daemon=True).start()
                prev = pr
        except Exception as e:
            self.procs = procs
            self.kill()
            raise RuntimeError("Start %s: %s" % (cmds[len(procs)][0] if len(procs) < len(cmds) else what, e))
        self.procs = procs
        pk = self._pkind(what)
        if pk:
            pid = what[2:]
            ps = preset(pid)
            if pk in ("ism433", "srd868"):
                fn = lambda ln, pid=pid: (self.on433(ln), self._ll(pid, ln))
            elif pk == "aprs":
                fn = lambda ln, pid=pid: (self.onaprs(ln), self._ll(pid, ln))
            elif pk == "fm":
                st = {"name": ps["name"], "f": ps["f"]}
                fn = lambda ln, pid=pid, st=st: (self.onrds(st, ln), self._ll(pid, ln))
            else:
                fn = None
            if pk in ACT_KINDS:
                threading.Thread(target=self._act_reader, args=(procs[-1].stdout, pid), daemon=True).start()
            if fn:
                threading.Thread(target=self._reader, args=(procs[-1].stdout, fn), daemon=True).start()
            if pk == "wxsat":
                self.pmeteor = {"pass": {"sat": "manuell " + ps["f"].replace("e6", " MHz"), "aos": time.time(), "f": ps["f"], "tag": "man" + pid[-4:]}, "tmp": self.cfg["meteor_tmp"], "pid": pid}
            self.last_dabpoll = time.time()
            self._ll(pid, "== Start %s (%s)" % (ps["label"], " | ".join(" ".join(a) for a in cmds)))
        elif what == "433":
            threading.Thread(target=self._reader, args=(procs[-1].stdout, self.on433), daemon=True).start()
        elif what == "aprs":
            threading.Thread(target=self._reader, args=(procs[-1].stdout, self.onaprs), daemon=True).start()
        elif what.startswith("nz:"):
            b = NOISE_BANDS[int(what[3:])]
            self.nzm = NoiseMeter(b, self.cfg.get("noise_car_db") or 10, self.cfg.get("noise_car_n") or 4)
            self.nzt = threading.Thread(target=self._noise_reader, args=(procs[-1].stdout, self.nzm, b), daemon=True)
            self.nzt.start()
        elif what.startswith("rds:"):
            st = self.fm_list()[int(what[4:])]
            threading.Thread(target=self._reader, args=(procs[-1].stdout, lambda ln, st=st: self.onrds(st, ln)), daemon=True).start()
        self.active, self.since = what, time.time()
        self.log("Start", what, " | ".join(" ".join(a) for a in cmds))

    def _start_sep(self, what, cmds):
        """rtl_tcp (127.0.0.1) und welle-cli als zwei getrennte Prozesse; welle-cli erst wenn der Port lauscht (max 10 s)."""
        port = int(cmds[0][cmds[0].index("-p") + 1])
        procs = []
        try:
            srv = subprocess.Popen(cmds[0], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
            procs.append(srv)
            threading.Thread(target=self._err_reader, args=(srv.stderr,), daemon=True).start()
            end = time.time() + 10
            while not port_listening(port):
                if srv.poll() is not None:
                    raise RuntimeError("rtl_tcp beendet (rc %s)" % srv.returncode)
                if time.time() > end:
                    raise RuntimeError("rtl_tcp lauscht nach 10 s nicht auf 127.0.0.1:%d" % port)
                time.sleep(0.25)
            wl = subprocess.Popen(cmds[1], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True, cwd=self.base)
            procs.append(wl)
            threading.Thread(target=self._err_reader, args=(wl.stderr,), daemon=True).start()
        except Exception as e:
            self.procs = procs
            self.kill()
            raise RuntimeError("Start %s: %s" % (what, e))
        self.procs = procs
        self.last_dabpoll = time.time()
        if self._pkind(what):
            ps = preset(what[2:])
            self._ll(ps["id"], "== Start %s (%s ; %s)" % (ps["label"], " ".join(cmds[0]), " ".join(cmds[1])))
        self.active, self.since = what, time.time()
        self.log("Start", what, " ; ".join(" ".join(a) for a in cmds), "(getrennt)")

    def _pkind(self, what):
        ps = preset(what[2:]) if isinstance(what, str) and what.startswith("p:") else None
        return ps["kind"] if ps else None

    def _ll(self, pid, line, numeric=False):
        if self.llog.add(pid, line, numeric=numeric):
            with self.lock:
                self.counts["linelog"] += 1

    def kill(self):
        for pr in self.procs:
            try:
                os.killpg(pr.pid, signal.SIGTERM)
            except Exception:
                pass
        end = time.time() + 4
        for pr in self.procs:
            try:
                pr.wait(timeout=max(0.1, end - time.time()))
            except Exception:
                try:
                    os.killpg(pr.pid, signal.SIGKILL)
                    pr.wait(timeout=2)
                except Exception:
                    pass
        had = bool(self.procs)
        self.procs = []
        if had:
            time.sleep(1.0)  # USB freigeben lassen

    def alive(self):
        return bool(self.procs) and all(pr.poll() is None for pr in self.procs)

    def want(self, mode, now):
        m = mode["mode"]
        if m == "off":
            return "idle"
        if m in ("433", "aprs", "tcp"):
            return m
        if m == "preset":
            if self.special:
                try:
                    self.sub_done(self.special, now)
                finally:
                    self.special = None
            return "p:" + mode["preset"]
        sp = self.special
        if sp and sp["kind"] in ("bc", "noise") and self.cfg.get("cal_enable") and self.tool("welle") and os.path.exists(p("sdr_cal_now", self.base)):
            # Kalibrierung von Hand: laufenden Rundfunk-/Messblock abbrechen statt bis zu 15 min zu warten (Block laeuft spaeter erneut)
            try:
                self.sub_done(sp, now)
            except Exception as e:
                self.log("Block-Abbruch:", e)
            self.special = None
            sp = None
            self.log("Kalibrierung von Hand: laufenden Block unterbrochen")
        if sp:
            if now < sp["sub_end"]:
                return sp["queue"][sp["i"]]
            self.sub_done(sp, now)
            sp["i"] += 1
            if sp["i"] < len(sp["queue"]) and now < sp.get("hard_end", now + 1):
                sp["sub_end"] = now + sp["durs"][sp["i"]]
                return sp["queue"][sp["i"]]
            if sp["kind"] == "bc":
                self.last_bc = now
                self.sbc.last_saved = 0  # Block-Ergebnis gleich einmal speichern
            if sp["kind"] == "noise":
                self.last_noise = now
                try:
                    with self.lock:
                        self.snoise.finish_block(self.cfg, now)
                except Exception as e:
                    self.log("Funkumgebung:", e)
            if sp["kind"] == "cal":
                try:
                    self.cal_finish(now)
                except Exception as e:
                    self.log("Kalibrierung:", e)
            self.special = None
        ps = self.pass_now(now)
        if ps:
            tmp = self.cfg["meteor_tmp"]
            self._clean_tmp(tmp)
            os.makedirs(tmp, exist_ok=True)
            self.special = {"kind": "meteor", "queue": ["meteor"], "durs": [ps["los"] - now + 300], "i": 0, "sub_end": ps["los"] + 300,
                            "pass": ps, "tmp": tmp, "t0": now}
            self.log("Meteor-Ueberflug %s max %s Grad bis %s" % (ps["sat"], ps["max_el"], time.strftime("%H:%M", time.localtime(ps["los"]))))
            return "meteor"
        if self.cal_due(now):
            d = float(self.cfg.get("cal_s") or 45)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + 2 * d + 60:
                self.cal_samples, self.cal_res = [[], []], [None, None]
                self.special = {"kind": "cal", "queue": ["cal:0", "cal:1"], "durs": [d, d], "i": 0, "sub_end": now + d, "hard_end": now + 2 * d + 30, "t0": now}
                self.log("Kalibrierung startet (DAB %s)" % self.dab_list()[0])
                return "cal:0"
        nq = self.noise_queue()
        niv = float(self.cfg.get("noise_interval_s") or 900)
        if nq and now - self.last_noise >= niv:
            tot = sum(d for _, d in nq)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + tot + 60:
                self.special = {"kind": "noise", "queue": [j for j, _ in nq], "durs": [d for _, d in nq], "i": 0, "sub_end": now + nq[0][1],
                                "hard_end": now + tot + 30, "t0": now}
                return nq[0][0]
            self.last_noise = now - niv + 300
        q = self.bc_queue()
        if q and now - self.last_bc >= float(self.cfg.get("bc_interval_s") or 1800):
            tot = sum(d for _, d in q)
            nxt = self.next_pass(now)
            if not nxt or nxt["aos"] > now + tot + 60:
                self.special = {"kind": "bc", "queue": [j for j, _ in q], "durs": [d for _, d in q], "i": 0, "sub_end": now + q[0][1],
                                "hard_end": now + tot + 30, "t0": now}
                return q[0][0]
            self.last_bc = now - float(self.cfg.get("bc_interval_s") or 1800) + 300
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")] or ["433"]
        if self.active not in order:
            self.auto_idx = self.auto_idx % len(order)
            return order[self.auto_idx]
        sl = float(self.cfg.get("slice_%s_s" % self.active) or 300)
        if len(order) > 1 and now - self.slice_start >= sl:
            self.auto_idx = (order.index(self.active) + 1) % len(order)
            return order[self.auto_idx]
        return self.active

    def bc_queue(self):
        if not self.cfg.get("bc_enable"):
            return []
        q = []
        if self.tool("redsea"):
            q += [("rds:%d" % i, float(self.cfg.get("fm_s") or 60)) for i in range(len(self.fm_list()))]
        if self.tool("welle"):
            q += [("dab:%d" % i, float(self.cfg.get("dab_s") or 60)) for i in range(len(self.dab_list()))]
        return q

    def sub_done(self, sp, now):
        job = sp["queue"][sp["i"]]
        if job.startswith("dab:") and self.procs and self.alive():
            ch = str(self.dab_list()[int(job[4:])])
            try:
                import prepper_sdr_net
                mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
                with self.lock:
                    self.sbc.d["welle_caps"] = welle_caps(self.tool("welle"))
                    if self.sbc.on_dab(ch, mux, now):
                        self.counts["dab"] += 1
            except Exception as e:
                self.log("DAB %s: kein Status (%s)" % (ch, e))
                with self.lock:
                    self.sbc.d["dab"].setdefault(ch, {"ch": ch})["err"] = str(e)[:100]
                    self.sbc.d["dab"][ch]["err_t"] = int(now)
                    self.sbc.dirty = True
        if job == "meteor":
            if self.procs:
                self.kill()
            self.collect_meteor(sp)
        if job.startswith("nz:"):
            if self.procs:
                self.kill()
            if self.nzt is not None:
                self.nzt.join(timeout=3)
            mt, self.nzm, self.nzt = self.nzm, None, None
            if mt is not None:
                try:
                    r = mt.result(now)
                    with self.lock:
                        self.snoise.add(r, self.cfg, now)
                    self._ll("noise_" + r["band"], json.dumps({k: r.get(k) for k in ("band", "t", "floor", "p90", "n_car", "imp_pm", "bb_pm", "ok")}, separators=(",", ":")), numeric=True)
                except Exception as e:
                    self.log("Funkumgebung %s: %s" % (job, e))
        if job.startswith("cal:"):
            if self.procs:
                self.kill()
            self.cal_sub(int(job[4:]))

    def pass_now(self, now):
        if not self.cfg.get("meteor_enable") or not self.tool("satdump"):
            return None
        for ps in self.passes:
            if ps["aos"] - 20 <= now < ps["los"] - 60 and ps["max_el"] >= float(self.cfg.get("meteor_min_el") or 20) and not ps.get("done"):
                ps["done"] = True
                return ps
        return None

    def next_pass(self, now):
        for ps in self.passes:
            if ps["los"] > now and ps["max_el"] >= float(self.cfg.get("meteor_min_el") or 20):
                return ps
        return None

    def maintain(self, now):
        """TLE holen (wenn online, alle 12 h), Ueberfluege vorhersagen (stuendlich). Ohne Netz: Cache."""
        if not self.cfg.get("meteor_enable"):
            return
        fn = p("sdr_tle.json", self.base)
        cache = load_json(fn, {}) or {}
        age = now - (cache.get("t") or 0)
        if age > float(self.cfg.get("tle_refresh_h") or 12) * 3600 and now - self.last_tle_try > 1800:
            self.last_tle_try = now
            try:
                import prepper_sdr_net
                got = []
                for s in self.sat_list():
                    name, l1, l2 = prepper_sdr_net.fetch_tle(s["norad"])
                    got.append({"name": s["name"], "norad": int(s["norad"]), "f": s["f"], "l1": l1, "l2": l2})
                cache = {"t": int(now), "tles": got, "src": "celestrak"}
                write_json(fn, cache)
                self.last_predict = 0
                self.log("TLE aktualisiert:", ", ".join(x["name"] for x in got))
            except Exception as e:
                self.log("TLE nicht geholt (offline?), nutze Cache vom %s: %s" % (time.strftime("%d.%m. %H:%M", time.localtime(cache.get("t") or 0)) if cache.get("t") else "-", e))
        if cache.get("tles") and now - self.last_predict > 3600:
            done = {(x["sat"], x["aos"]) for x in self.passes if x.get("done")}
            ps = predict(cache["tles"], self.saprs.home[0], self.saprs.home[1], now - 900, 36, float(self.cfg.get("meteor_min_el") or 20))
            if ps is not None:
                for x in ps:
                    if (x["sat"], x["aos"]) in done:
                        x["done"] = True
                self.passes = ps
                write_json(p("sdr_passes.json", self.base), {"t": int(now), "tle_t": cache.get("t"), "passes": ps, "min_el": self.cfg.get("meteor_min_el")})
            self.last_predict = now

    def _clean_tmp(self, tmp):
        import shutil
        if tmp.startswith("/tmp/prepper-meteor") and os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)

    def collect_meteor(self, sp):
        """Bilder aus dem satdump-Ausgabeordner (tmpfs) als JPEG nach meteor/ uebernehmen, alte loeschen."""
        ps = sp.get("pass") or {}
        tmp = sp.get("tmp") or ""
        dst = p("meteor", self.base)
        os.makedirs(dst, exist_ok=True)
        pngs = []
        for root, _d, files in os.walk(tmp):
            for fn in files:
                if fn.lower().endswith((".png", ".jpg")):
                    pngs.append(os.path.join(root, fn))
        def score(x):
            n = os.path.basename(x).lower()
            return (0 if "221" in n else 1 if "rgb" in n or "natural" in n else 2 if "msu" in n else 3, -os.path.getsize(x))
        pick = sorted(pngs, key=score)[:3]
        stamp = time.strftime("%Y%m%d-%H%M", time.localtime(ps.get("aos") or time.time()))
        sat = re.sub(r"[^A-Za-z0-9]+", "", ps.get("tag") or (ps.get("sat") or "meteor").replace("METEOR-", ""))[-8:]
        saved = []
        for src in pick:
            base = re.sub(r"[^A-Za-z0-9_-]+", "_", os.path.splitext(os.path.basename(src))[0])[:40]
            out = os.path.join(dst, "%s_%s_%s.jpg" % (stamp, sat, base))
            try:
                from PIL import Image
                im = Image.open(src)
                im = im.convert("RGB")
                if im.width > 1600:
                    im = im.resize((1600, int(im.height * 1600 / im.width)))
                im.save(out + ".tmp", "JPEG", quality=85)
                os.replace(out + ".tmp", out)
            except Exception:
                out = out[:-4] + ".png"
                with open(src, "rb") as a, open(out + ".tmp", "wb") as b:
                    b.write(a.read())
                os.replace(out + ".tmp", out)
            saved.append(os.path.basename(out))
        self._clean_tmp(tmp)
        self._prune_meteor(dst)
        st = load_json(p("meteor_state.json", self.base), {}) or {}
        hist = st.get("passes") or []
        hist.append({"t": int(time.time()), "sat": ps.get("sat"), "aos": ps.get("aos"), "los": ps.get("los"), "max_el": ps.get("max_el"),
                     "images": saved, "note": None if saved else "keine Bilder (Signal zu schwach / Antenne?)",
                     "err": (self.stderr[-1] if self.stderr else None)})
        st["passes"] = hist[-60:]
        st["v"] = V
        write_json(p("meteor_state.json", self.base), st)
        with self.lock:
            self.counts["meteor"] += len(saved)
        self.log("Meteor: %d Bild(er) gespeichert" % len(saved))

    def _prune_meteor(self, dst):
        keep = int(self.cfg.get("meteor_keep") or 30)
        cap = float(self.cfg.get("meteor_cap_mb") or 300) * 1024 * 1024
        files = sorted((os.path.join(dst, f) for f in os.listdir(dst) if f.endswith((".jpg", ".png"))), key=os.path.getmtime, reverse=True)
        tot = 0
        for i, f in enumerate(files):
            tot += os.path.getsize(f)
            if i >= keep or tot > cap:
                os.remove(f)

    def status(self, mode, force=False):
        now = time.time()
        order = [x for x in (self.cfg.get("auto") or []) if x in ("433", "aprs")]
        nxt = None
        if mode["mode"] == "auto" and self.active in order and len(order) > 1:
            nxt = int(self.slice_start + float(self.cfg.get("slice_%s_s" % self.active) or 300))
        with self.lock:
            st = {"v": V, "t": int(now), "pid": os.getpid(), "started": int(self.started), "mode": mode["mode"], "until": mode.get("until"),
                  "active": self.active, "since": int(self.since), "next_switch": nxt, "stick": self.stick,
                  "serial": cfg_serial(self.cfg), "stick_idx": self.dev_idx, "sticks_n": self.sticks_n, "others": list(self.others), "pin_err": self.pin_err,
                  "err": self.err, "err_t": self.err_t, "fails": self.fails, "retry_at": int(self.retry_at) if self.retry_at > now else None,
                  "stderr": self.stderr[-3:], "counts": dict(self.counts), "last_433_t": self.s433.d.get("last_t"),
                  "last_aprs_t": self.saprs.d.get("last_t"), "sensors": len(self.s433.d["sensors"]), "stations": len(self.saprs.d["stations"]),
                  "tcp": {"port": int(self.cfg["tcp_port"]), "bind": self.cfg["tcp_bind"]}, "auto": order,
                  "slices": {"433": self.cfg["slice_433_s"], "aprs": self.cfg["slice_aprs_s"]},
                  "freq": {"433": self.cfg["f433"], "aprs": self.cfg["faprs"]}, "home": list(self.saprs.home),
                  "special": ({"kind": self.special["kind"], "job": self.special["queue"][self.special["i"]], "until": int(self.special["sub_end"])} if self.special else None),
                  "next_bc": int(self.last_bc + float(self.cfg.get("bc_interval_s") or 1800)) if self.bc_queue() else None,
                  "next_pass": self.next_pass(now), "sgp4": predict([], 0, 0, now) is not None,
                  "preset": mode.get("preset"), "preset_label": (preset(mode.get("preset")) or {}).get("label"),
                  "noise": self.noise_summary(), "cal": self.cal_summary(), "gps": self.gps.summary() if self.gps else {"lvl": "grau", "ok": None, "why": "aus", "src": "Dach-GPS"},
                  "evlog": ({"n": self.evlog.n, "open": len(self.evlog.open), "kfz": self.kfz.n if self.kfz else 0} if self.evlog else None), "linelog": {"n": self.llog.n, "kw": self.llog.kw, "on": self.llog.on, "dropped": self.llog.dropped}, "tools": {"redsea": bool(self.tool("redsea")), "welle": bool(self.tool("welle")), "satdump": bool(self.tool("satdump"))}}
        sig = (st["mode"], st["active"], st["err"], len(st["stick"]), st["until"], bool(self.special))
        if force or sig != self.lastsig or now - self.last_status >= 60:
            write_json(p("sdr_status.json", self.base), st)
            self.last_status, self.lastsig = now, sig
        return st

    def noise_summary(self):
        d = self.snoise.d
        bands = []
        for b in NOISE_BANDS:
            x = (d.get("bands") or {}).get(b["id"])
            if not x:
                continue
            bands.append({"id": b["id"], "short": b["short"], "label": b["label"], "ok": x.get("ok"), "t": x.get("t"), "floor": x.get("floor"),
                          "raise": x.get("raise"), "lvl": x.get("lvl") if x.get("ok") else "grau", "n_pers": x.get("n_pers"), "learning": x.get("learning"),
                          "cars": (x.get("cars") or [])[:3], "bb_pm": x.get("bb_pm"), "why": x.get("why"), "base": x.get("base"), "src": x.get("src"),
                          "yel": x.get("yel"), "red": x.get("red"), "trend": x.get("trend") if x.get("ok") else None})
        return {"t": d.get("t"), "qrm": d.get("qrm"), "thunder": d.get("thunder"), "bands": bands,
                "next": int(self.last_noise + float(self.cfg.get("noise_interval_s") or 900)) if self.cfg.get("noise_enable") else None}

    def cal_summary(self):
        pc = self.cfg.get("ppm_cal") if isinstance(self.cfg.get("ppm_cal"), dict) else {}
        return {"ppm": pc.get("ppm"), "t": pc.get("t"), "try_t": pc.get("try_t"), "note": pc.get("note"), "applied": ppm_val(self.cfg),
                "auto": bool(self.cfg.get("ppm_auto", True)), "on": bool(self.cfg.get("cal_enable"))}

    def flush(self, force=False):
        try:
            self.llog.flush(force)
        except Exception as e:
            self.log("Zeilen-Log:", e)
        with self.lock:
            self.s433.save(force)
            self.saprs.save(force)
            self.sbc.save(force)
            self.sact.save(force)
            self.snoise.save_hist(force)
            if self.kfz:
                self.kfz.save(force)

    def step(self):
        now = time.time()
        mode = get_mode(self.base)
        allst = stick_info(self.cfg["usb_ids"])
        sn = cfg_serial(self.cfg)
        mine = [x for x in allst if sn and x.get("serial") == sn]
        self.stick = mine[:1] + [x for x in allst if x not in mine[:1]]
        self.sticks_n = len(allst)
        self.others = [x.get("serial") or "?" for x in allst if not (sn and x.get("serial") == sn)]
        if sn is None:
            perr = "Seriennummer in sdr_config.json ungueltig (nur Ziffern) - nicht gestartet"
        elif len(mine) > 1:
            perr = "doppelte Seriennummer %s (%d Sticks) - nicht gestartet" % (sn, len(mine))
        elif not mine:
            perr = "Stick %s fehlt" % sn
        else:
            perr = None
        if perr:
            if self.procs:
                self.kill()
            if self.pin_err != perr:
                self.log(perr, "- warte still, nehme keinen anderen Stick (pruefe alle 15 s)")
            self.pin_err = perr
            self.active, self.err, self.dev_idx = ("nostick" if perr.startswith("Stick ") else "fehler"), perr, None
            self.fails = 0
            return 15, mode
        if self.pin_err or self.active == "nostick":
            self.pin_err = None
            self.active, self.err, self.since = "idle", None, now
            self.log("Stick da: SN %s (%s), Sticks gesamt %d" % (sn, mine[0].get("product"), len(allst)))
        if self._pkind(self.active) == "dab" and self.procs and self.alive() and now - self.last_dabpoll >= 30:
            self.last_dabpoll = now
            ps = preset(self.active[2:])
            try:
                import prepper_sdr_net
                mux = prepper_sdr_net.fetch_welle(self.cfg["dab_port"])
                with self.lock:
                    r = self.sbc.on_dab(ps["ch"], mux, now)
                for sv in (r or {}).get("services") or []:
                    if sv.get("dls") and sv["dls"] != self._lastdls.get(sv["label"]):
                        self._lastdls[sv["label"]] = sv["dls"]
                        self._ll(ps["id"], "%s: %s" % (sv["label"], sv["dls"]))
                for a in (r or {}).get("alarm") or []:
                    self._ll(ps["id"], "Ansage: " + a)
            except Exception as e:
                self._ll(ps["id"], "== DAB-Status nicht lesbar: %s" % e)
        if self.active.startswith("cal:") and self.procs and self.alive() and now - self.last_calpoll >= 4:
            self.last_calpoll = now
            self._cal_poll(now)
        w = self.want(mode, now)
        if self.pmeteor and (w != self.active or not self.alive()):
            pid = (self.pmeteor.get("pid") or "")
            if self.procs and w != self.active:
                self.kill()
            if not self.alive():
                rc = [pr.poll() for pr in self.procs]
                self.kill()
                pm, self.pmeteor = self.pmeteor, None
                self.collect_meteor(pm)
                self._ll(pid, "== Ende Meteor-Aufnahme (rc %s)" % rc)
                if rc and all(x == 0 for x in rc):
                    self.active, self.since = "idle", now
                    return 2, mode
        if self.procs and not self.alive() and self.special and self.active in self.special["queue"]:
            sp = self.special
            rc = [pr.poll() for pr in self.procs]
            with self.lock:
                tail = self.stderr[-1] if self.stderr else ""
            if sp["kind"] == "bc":
                self.err, self.err_t = "%s beendet (rc %s): %s" % (self.active, rc, tail), int(now)
                self.log(self.err)
            self.kill()
            sp["sub_end"] = now  # naechster Teil / Ende
            self.active = "idle"
            return 1, mode
        if self.procs and not self.alive():
            rc = [pr.poll() for pr in self.procs]
            ran = now - self.since
            self.kill()
            self.fails = 1 if ran > 120 else self.fails + 1
            back = min(300, 10 * 2 ** (self.fails - 1))
            self.retry_at = now + back
            with self.lock:
                tail = self.stderr[-1] if self.stderr else ""
            self.err, self.err_t = "%s beendet (rc %s) nach %d s: %s" % (self.active, rc, ran, tail), int(now)
            self.log(self.err, "- neuer Versuch in %d s" % back)
            self.active = "fehler"
            return 2, mode
        if w == "idle":
            if self.procs:
                self.kill()
            self.active, self.since = "idle", now if self.active != "idle" else self.since
            return 2, mode
        if self.active == "fehler" and self.special and w in self.special["queue"]:
            self.retry_at = 0
        if w != self.active or not self.procs:
            if now < self.retry_at and w == getattr(self, "_last_try", None):
                return 2, mode
            if self.procs:
                self.kill()
            self._last_try = w
            try:
                self.start(w)
                self.slice_start = time.time()
                if self.err and self.err.startswith("Start"):
                    self.err = None
            except Exception as e:
                self.fails += 1
                back = min(300, 10 * 2 ** (self.fails - 1))
                self.retry_at = now + back
                self.err, self.err_t = str(e)[:200], int(now)
                self.active = "fehler"
                self.log(self.err, "- neuer Versuch in %d s" % back)
        elif self.fails and now - self.since > 120:
            self.fails, self.err = 0, None
        return 2, mode

    def loop(self):
        def _sig(*_):
            self.stop = True
        signal.signal(signal.SIGTERM, _sig)
        signal.signal(signal.SIGINT, _sig)
        self.log("Start v%d, Basis %s, Heimat %s, auto %s" % (V, self.base, self.cfg["home"], self.cfg["auto"]))
        if self.cfg.get("gps_enable", True):
            try:
                import prepper_gps
                self.gps = prepper_gps.GpsWatch(p("sdr_gps_hist.json", self.base), self.cfg, load_keep, write_json_keep, self.log)
                threading.Thread(target=self.gps.run, daemon=True).start()
            except Exception as e:
                self.gps = None
                self.log("Dach-GPS nicht gestartet:", e)
        try:
            import prepper_evlog
            tq = prepper_evlog.TimeQ()
            self.evlog = prepper_evlog.EvLog(self.base, load_keep, write_json_keep, self.log, tq=tq)
            self.kfz = prepper_evlog.KfzLog(self.base, load_keep, write_json_keep, self.log, tq=tq)
        except Exception as e:
            self.evlog = self.kfz = None
            self.log("Ereignis-Log nicht gestartet:", e)
        mode = get_mode(self.base)
        while not self.stop:
            try:
                wait, mode = self.step()
            except Exception as e:
                self.log("Planer-Fehler:", e)
                wait = 10
            try:
                if not self.special:
                    self.maintain(time.time())
            except Exception as e:
                self.log("Wartung:", e)
            try:
                st = self.status(mode, force=(time.time() - self.started < 20))
                if self.evlog:
                    try:
                        self.evlog.update(st)
                    except Exception as e:
                        self.log("Ereignis-Log:", e)
                self.flush()
                if time.time() - self.last_prune > 3600:
                    with self.lock:
                        self.s433.prune(self.cfg["keep_days"])
                        self.saprs.prune(self.cfg["keep_days"])
                        if self.kfz:
                            try:
                                self.kfz.prune()
                            except Exception as e:
                                self.log("KFZ-Bereinigung:", e)
                    self.last_prune = time.time()
            except Exception as e:
                self.log("Speichern:", e)
            end = time.time() + wait
            while not self.stop and time.time() < end:
                time.sleep(0.5)
                gm = get_mode(self.base)
                if gm["mode"] != mode["mode"] or gm.get("preset") != mode.get("preset"):
                    break
        self.kill()
        self.active = "idle"
        if self.gps:
            self.gps.stop = True
            try:
                with self.gps.lock:
                    if self.gps.dirty:
                        self.gps.save()
            except Exception as e:
                self.log("Dach-GPS speichern:", e)
        if self.evlog:
            try:
                self.evlog.save()
            except Exception as e:
                self.log("Ereignis-Log speichern:", e)
        self.flush(True)
        self.status(mode, True)
        self.log("Ende")


# ---------------------------------------------------------------- Selbsttest (ohne Stick)
SAMPLES_433 = [
    '{"time":"1760270000","model":"Nexus-TH","id":177,"channel":1,"battery_ok":1,"temperature_C":12.3,"humidity":71,"rssi":-7.1,"snr":21.4,"noise":-28.5}',
    '{"time":"1760270000","model":"Nexus-TH","id":177,"channel":1,"battery_ok":1,"temperature_C":12.3,"humidity":71,"rssi":-7.0,"snr":21.0,"noise":-28.5}',
    '{"time":"1760270031","model":"Fineoffset-WH24","id":44,"temperature_C":10.9,"humidity":88,"wind_dir_deg":225,"wind_avg_m_s":2.1,"wind_max_m_s":4.4,"rain_mm":12.6,"uv":3,"light_lux":5540.0}',
    '{"time":"1760270040","model":"Acurite-Tower","id":9876,"channel":"A","temperature_F":50.0,"humidity":60}',
    'kein json', '{"kaputt":',
]
SAMPLES_APRS = [
    "[0.4] DB0NU>APNU19,WIDE2-1:!4927.37N/01105.36E#PHG5130 Digi Nuernberg",
    "[0.3] DL1ABC-9>493S33,DB0NU*,WIDE2:`'#t\x1e\x1cv>/Fahrt",
    "[0L] DO2XYZ-13>APRS,WIDE1-1:@121215z4933.33N/01107.88E_225/004g009t050r000p012P012h88b10132WX Kalchreuth",
    "[0.1] DL2BBB>APRS,WIDE2-2::DL1ABC-9 :Hallo, QRV?{42",
    "[0.1] DL1ABC-9>APRS::DL2BBB   :ack42",
    "[0.2] DK0XX>APOT30,WIDE2-1:=/5L!!<*e7>7P[Kompr",
    "[0.2] DB0XYZ>APRS:;LEOSAT   *121200z4930.00N/01100.00E`Objekt",
    "[0.2] DL3QQ>APRS:>Status Text",
    "audio level = 34(10/9)   [NONE]   ||||||___",
    "[0.2] DB0ABC>APRS:}DL9XX>APRS,TCPIP,DB0ABC*:!4950.00N/01110.00E-drittes",
]


def selftest_noise2(tmp):
    """Synthetische Pruefungen sdrNoise2: robuste Schwellen, Stunden-Grundlinie, Trend (inkl. Fehlalarm), Gewitter, Uhr, kaputte Dateien."""
    import random
    rnd = random.Random(11)
    cfg = dict(DEFAULT_CFG)
    m, s, n = robust([1, 2, 3, 4, 100, float("nan"), None, float("inf")])
    assert m == 3 and abs(s - 1.4826) < 1e-6 and n == 5, (m, s, n)
    assert thresholds(0.5, cfg) == (5.0, 10.0) and thresholds(2.0, cfg) == (8.0, 12.0) and thresholds(None, cfg) == (5.0, 10.0)
    T0 = int(time.mktime((2026, 9, 1, 0, 0, 0, 0, 0, -1)))
    # 1) Stationaeres Rauschen 14 Tage (sigma 1 dB) -> nie gelb/rot/Trend (Fehlalarm-Pruefung)
    d1 = os.path.join(tmp, "n1")
    os.makedirs(d1, exist_ok=True)
    ns = NoiseState(d1)
    bad = 0
    for k in range(14 * 96):
        t = T0 + k * 900
        ns.add({"band": "fm", "t": t, "ok": True, "floor": -40 + rnd.gauss(0, 1.0), "p90": -38, "cars": [], "s": 10}, cfg, t)
        x = ns.d["bands"]["fm"]
        bad += x["lvl"] != "gruen" or x["trend"]["on"]
    assert bad <= 2, bad
    assert len(ns.h["fm"]) <= NoiseState.CAP
    # 2) langsamer Anstieg +3 dB ueber 2 Tage -> 'Trend steigend' ohne gelb; danach zurueck -> Trend aus (Hysterese)
    tr_on = None
    for k in range(4 * 96):
        t = T0 + (14 * 96 + k) * 900
        ns.add({"band": "fm", "t": t, "ok": True, "floor": -40 + min(3.0, 3.0 * k / 192.0) + rnd.gauss(0, 1.0), "cars": [], "s": 10}, cfg, t)
        x = ns.d["bands"]["fm"]
        if x["trend"]["on"] and tr_on is None:
            tr_on = k
        assert x["lvl"] != "rot", x
    assert tr_on is not None and tr_on < 4 * 96, tr_on
    for k in range(3 * 96):
        t = T0 + (18 * 96 + k) * 900
        ns.add({"band": "fm", "t": t, "ok": True, "floor": -40 + rnd.gauss(0, 1.0), "cars": [], "s": 10}, cfg, t)
    assert not ns.d["bands"]["fm"]["trend"]["on"], ns.d["bands"]["fm"]["trend"]
    # Luecke > 6 h und Uhr rueckwaerts setzen den Trend zurueck
    tr = ns.trend_step("fm", 5.0, T0 + 30 * 86400, cfg)
    assert tr["n"] == 1 and tr.get("reset")
    tr = ns.trend_step("fm", 5.0, T0 + 29 * 86400, cfg)
    assert tr["n"] == 1 and tr.get("reset")
    # 3) Sprung +12 dB -> rot, +6 dB -> gelb; verrauschtes Band (MAD 3 dB) hebt die Schwellen an
    t = T0 + 22 * 86400
    ns.add({"band": "fm", "t": t, "ok": True, "floor": -24.0, "cars": [], "s": 10}, cfg, t)
    assert ns.d["bands"]["fm"]["lvl"] == "rot", ns.d["bands"]["fm"]
    ns.add({"band": "fm", "t": t + 900, "ok": True, "floor": -30.0, "cars": [], "s": 10}, cfg, t + 900)
    assert ns.d["bands"]["fm"]["lvl"] == "gelb", ns.d["bands"]["fm"]
    d2 = os.path.join(tmp, "n2")
    os.makedirs(d2, exist_ok=True)
    nz = NoiseState(d2)
    for k in range(3 * 96):
        tt = T0 + k * 900
        nz.add({"band": "n433", "t": tt, "ok": True, "floor": -40 + rnd.gauss(0, 3.0), "cars": [], "s": 6}, cfg, tt)
    x = nz.d["bands"]["n433"]
    assert x["yel"] > 9 and x["red"] > 14, x
    # 4) MW mit Tagesgang (nachts +8 dB Ausbreitung) -> Stunden-Grundlinie: kein Alarm nachts; ohne Stunden-GL waere es gelb
    d3 = os.path.join(tmp, "n3")
    os.makedirs(d3, exist_ok=True)
    nm = NoiseState(d3)
    alarms = 0
    for k in range(10 * 96):
        tt = T0 + k * 900
        hr = time.localtime(tt).tm_hour
        fl = -50 + (8.0 if (hr >= 19 or hr < 6) else 0.0) + rnd.gauss(0, 0.8)
        nm.add({"band": "mw", "t": tt, "ok": True, "floor": fl, "cars": [], "s": 8, "bb_pm": max(0.0, rnd.gauss(2, 1)), "imp_pm": 3}, cfg, tt)
        x = nm.d["bands"]["mw"]
        if k > 5 * 96:
            alarms += x["lvl"] != "gruen" or x["trend"]["on"]
            assert x["src"].startswith("Stunde"), x["src"]
    assert alarms <= 2, alarms
    # 5) Gewitter: Stunden-Grundlinie der Impulse; 1 Messung viel -> gelb, zwei hintereinander -> rot
    nm.finish_block(cfg, T0 + 10 * 96 * 900)
    assert nm.d["thunder"]["lvl"] == "gruen" and nm.d["thunder"]["src"].startswith("Stunde"), nm.d["thunder"]
    tt = T0 + 10 * 96 * 900 + 900
    nm.add({"band": "mw", "t": tt, "ok": True, "floor": -50.0, "cars": [], "s": 8, "bb_pm": 30.0, "imp_pm": 40}, cfg, tt)
    nm.finish_block(cfg, tt)
    assert nm.d["thunder"]["lvl"] == "gelb", nm.d["thunder"]
    nm.add({"band": "mw", "t": tt + 900, "ok": True, "floor": -50.0, "cars": [], "s": 8, "bb_pm": 40.0, "imp_pm": 50}, cfg, tt + 900)
    nm.finish_block(cfg, tt + 900)
    assert nm.d["thunder"]["lvl"] == "rot", nm.d["thunder"]
    # 6) Uhr nicht gestellt / NaN -> nichts gespeichert
    n0 = len(nm.h["mw"])
    nm.add({"band": "mw", "t": 1000, "ok": True, "floor": -50.0, "cars": []}, cfg, 1000)
    nm.add({"band": "mw", "t": tt + 1800, "ok": True, "floor": float("nan"), "cars": []}, cfg, tt + 1800)
    nm.add({"band": "unbekannt", "t": tt, "ok": True, "floor": 1.0}, cfg, tt)
    assert len(nm.h["mw"]) == n0
    # 7) Verlauf: atomar mit .1; kaputte Datei -> vorige Fassung; beides kaputt -> leer, kein Absturz
    nm.save_hist(True, now=tt)
    nm.hdirty = True
    nm.save_hist(True, now=tt)
    with open(nm.fh, "w") as f:
        f.write("{kaputt")
    with open(nm.f, "w") as f:
        f.write("")
    nr = NoiseState(d3)
    assert len(nr.h["mw"]) == len(nm.h["mw"]) and isinstance(nr.d["bands"], dict)
    with open(nm.fh + ".1", "w") as f:
        f.write("[1,2")
    nr = NoiseState(d3)
    assert nr.h["mw"] == [] and nr.d["trend"] == {}
    print("selftest sdrNoise2 ok")


def selftest():
    import tempfile
    tmp = tempfile.mkdtemp(prefix="sdrtest")
    s = State433(tmp)
    got = [s.add(x) for x in SAMPLES_433]
    assert got[0] and got[1] is None and got[2] and got[3] and got[4] is None and got[5] is None, got
    w = s.d["sensors"]["Fineoffset-WH24|44|"]
    assert w["wind_avg_km_h"] == 7.6 and w["rain_mm"] == 12.6, w
    assert s.d["sensors"]["Acurite-Tower|9876|A"]["temperature_C"] == 10.0
    s.save(True)
    a = StateAPRS(tmp, HOME_FALLBACK)
    res = [parse_aprs(x) for x in SAMPLES_APRS]
    assert res[0]["type"] == "pos" and abs(res[0]["lat"] - 49.45617) < 1e-3 and abs(res[0]["lon"] - 11.08933) < 1e-3, res[0]
    assert res[1]["type"] == "pos" and res[1].get("mice") and not res[1]["direct"] and abs(res[1]["lat"] - 49.5555) < 1e-3 and abs(res[1]["lon"] - 11.1313) < 1e-3 and res[1]["speed_kmh"] == 37, res[1]
    assert res[2]["type"] == "wx" and res[2]["wx"]["temp_c"] == 10.0 and res[2]["wx"]["hpa"] == 1013.2 and res[2]["wx"]["hum"] == 88, res[2]
    assert res[3]["type"] == "msg" and res[3]["to"] == "DL1ABC-9" and res[3]["text"] == "Hallo, QRV?" and res[3]["msgid"] == "42", res[3]
    assert res[4]["type"] == "ack"
    assert res[5]["type"] == "pos" and -90 < res[5]["lat"] < 90, res[5]
    assert res[6]["type"] == "obj" and res[6]["name"] == "LEOSAT", res[6]
    assert res[7]["type"] == "status"
    assert res[8] is None
    assert res[9]["src"] == "DL9XX" and res[9]["third"] == "DB0ABC", res[9]
    for x in SAMPLES_APRS:
        a.add(x)
    a.save(True)
    st = load_json(p("aprs_state.json", tmp))
    assert st["stations"]["DB0NU"]["dist_km"] < 20 and len(st["msgs"]) == 1, st["stations"]["DB0NU"]
    # Whitelist (Testfrequenzen ausserhalb werden berechnet, damit keine verbotenen Literale im Code stehen)
    def _mz(x):
        return "%.3fM" % x
    assert tune_ok("ism433", "433.92M") and tune_ok("srd868", "868.3M") and tune_ok("aprs", "144.800M") and not tune_ok("aprs", _mz(144.8 + 0.025))
    assert tune_ok("fm", "87.5M") and tune_ok("fm", "108.0M") and not tune_ok("fm", _mz(108 + 0.1)) and not tune_ok("fm", _mz(170 + 3.2))
    assert tune_ok("dab", ch="11D") and not tune_ok("dab", ch="L1") and tune_ok("wxsat", "137.1e6") and not tune_ok("wxsat", _mz(138 + 0.5))
    assert not tune_ok("ism433", _mz(430 + 3)) and not tune_ok("bos", _mz(170 + 2)) and not tune_ok("fm", "abc")
    for x in PRESETS:
        assert tune_ok(x["kind"], x.get("f"), x.get("ch")), x
    assert len(set(PRESET_IDS)) == len(PRESET_IDS)
    for bad in (("433", 45), ("x", 30), (None, 30), ("433", "30"), ("433", True), (_mz(170 + 3.2), 30)):
        try:
            set_preset(tmp, *bad)
            raise AssertionError(bad)
        except ValueError:
            pass
    assert set_preset(tmp, "fm_b3", 30)["preset"] == "fm_b3" and get_mode(tmp)["mode"] == "preset"
    write_json(p("sdr_mode.json", tmp), {"mode": "preset", "preset": "fm_b3", "until": int(time.time()) - 1})
    assert get_mode(tmp)["mode"] == "auto"
    write_json(p("sdr_mode.json", tmp), {"mode": "preset", "preset": "evil", "until": int(time.time()) + 600})
    assert get_mode(tmp)["mode"] == "auto"
    pl0 = Planner(tmp)
    pl0.dev_idx, pl0.dev_sn = 0, DEFAULT_SERIAL
    pl0.cfg["f433"] = _mz(170 + 3.25)
    try:
        pl0.cmd("433")
        raise AssertionError("433 ausserhalb")
    except RuntimeError:
        pass
    assert pl0.cmd("p:868")[0][2] == "868.3M" and pl0.cmd("p:868")[0][-2:] == ["-d", ":" + DEFAULT_SERIAL]
    pl0.tools["welle"] = "/x/welle-cli"
    pl0.list_n = 1
    assert pl0.cmd("p:dab_11D") == [["/x/welle-cli", "-c", "11D", "-C", "1", "-w", "7979", "-F", "rtl_sdr"]], pl0.cmd("p:dab_11D")
    pl0.list_n = 2
    dc = pl0.cmd("p:dab_11D")
    assert dc[0] == ["rtl_tcp", "-a", "127.0.0.1", "-p", "1235", "-P", "0", "-d", "0"] and "rtl_tcp,127.0.0.1:1235" in dc[1], dc
    pl0.tools["satdump"] = "/x/satdump"
    pl0.special = {"pass": {"f": "137.9e6", "los": time.time() + 300}, "tmp": tmp}
    mc = pl0.cmd("meteor")[0]
    assert mc[mc.index("--source_id") + 1] == DEFAULT_SERIAL, mc
    pl0.special = None
    # Zeilen-Log
    ll = LineLog(tmp, {"linelog_keyword": "warn", "linelog_flush_s": 30})
    assert ll.add("fm_b3", "Amtliche Warnung") and not ll.add("fm_b3", "Musik") and not ll.add("evil", "warn")
    ll.flush(True)
    ll.add("fm_b3", "Unwetterwarnung 2")
    ll.flush(True)
    fl = os.listdir(os.path.join(tmp, "archive", "linelog"))
    assert len(fl) == 1 and fl[0].startswith("fm_b3_"), fl
    rows = [json.loads(x) for x in open(os.path.join(tmp, "archive", "linelog", fl[0]))]
    assert [r["line"] for r in rows] == ["Amtliche Warnung", "Unwetterwarnung 2"], rows
    # Aktivitaet: synthetisch 2 Aussendungen je ~15 s in einer Minute, sonst Rauschen
    try:
        import numpy as np
        mt = ActMeter()
        rng = np.random.default_rng(1)
        t0 = 60 * 3000 * 10000
        recs = []
        sec = 240000
        tt = np.arange(sec) / 240000.0
        tone = 0.25 * np.exp(2j * np.pi * 2500 * tt)
        for i in range(62):
            iq = (rng.normal(0, 0.02, sec) + 1j * rng.normal(0, 0.02, sec))
            if 5 <= i < 20 or 35 <= i < 50:
                iq = iq + tone
            u = np.empty(2 * sec, dtype=np.uint8)
            u[0::2] = np.clip(np.round(iq.real * 127.5 + 127.4), 0, 255)
            u[1::2] = np.clip(np.round(iq.imag * 127.5 + 127.4), 0, 255)
            recs += mt.feed(u.tobytes(), now=t0 + i)
        assert len(recs) == 1 and recs[0]["tx"] == 2 and 45 <= recs[0]["occ_pct"] <= 55 and -16 < recs[0]["peak_dbfs"] < -8, recs
        assert set(recs[0]) == {"t", "s", "occ_pct", "peak_dbfs", "tx", "noise_dbfs"}
    except ImportError:
        print("selftest: numpy fehlt - Aktivitaet nicht geprueft")
    assert tune_ok("act2m", "145.500M") and not tune_ok("act2m", _mz(145.5 + 0.0125)) and not tune_ok("fm", "145.500M")
    assert tune_ok("pmr446", "446.03125M") and not tune_ok("pmr446", _mz(446 + 0.3)) and not tune_ok("act2m", "446.03125M")
    b = StateBC(tmp)
    assert b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","tp":true,"ta":false,"ps":"BR24    "}')["ps"] == "BR24"
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"0A","tp":true,"ta":true,"ps":"BAYERN 3"}')
    b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Amtliche Warnung vor Unwetter im Landkreis ERH"}')
    assert [w["kind"] for w in b.d["warn"]] == ["TA"] and "rt_ok" not in b.d["fm"]["BR24"], b.d["warn"]      # erst stabil (2x) auswerten
    b.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Amtliche Warnung vor Unwetter im Landkreis ERH"}')
    assert [w["kind"] for w in b.d["warn"]] == ["TA", "RT"] and b.d["fm"]["BR24"]["rt_ok"].startswith("Amtliche"), b.d["warn"]
    dab = b.on_dab("11D", {"ensemble": {"label": {"label": "BR Bayern"}}, "services": [{"label": {"label": "BR24"}, "dls": {"label": "Nachrichten"}, "sid": "0xD314"},
                                                                                      {"label": {"label": "Bayern 3"}, "dls": {"label": "Unwetterwarnung Nürnberg"}}],
                                     "announcements": [{"type": "Alarm", "active": True}]})
    assert dab["ensemble"] == "BR Bayern" and dab["n"] == 2 and dab["alarm"] and len(b.d["warn"]) == 3, (dab, b.d["warn"])   # "Unwetterwarnung Nuernberg" allein ist nicht rot
    assert dab["services"][0]["sid"] == "0xD314" and dab["services"][1]["sid"] is None, dab["services"]
    _bx = os.path.join(tmp, "bx")
    os.makedirs(_bx, exist_ok=True)
    _sx = StateBC(_bx).on_dab("11D", {"services": [{"label": "X", "sid": 54036}, {"label": "Y", "sid": "kaputt; rm"}]})["services"]
    assert _sx[0]["sid"] == "0xD314" and _sx[1]["sid"] is None, _sx
    print(_ws_selftest())
    _b2 = StateBC(_bx)
    _a = _b2.on_dab("5C", {"services": [{"label": "ASA DE", "sid": "0x1D11", "dls": "Amtliche Gefahrendurchsage: Fenster und Türen schließen"}, {"label": "DLF", "dls": "Nachrichten"}]}, now=1000)
    assert _a["asa"] and _a["asa"][0]["label"] == "ASA DE" and [w["kind"] for w in _b2.d["warn"]] == ["DLS"], (_a, _b2.d["warn"])
    _ks = [(x["k"], x.get("cls")) for x in _b2.evl.ev]
    assert ("asa", None) in _ks and ("dls", "rot") in _ks and ("dls", None) in _ks, _ks
    _b2.on_dab("5C", {"services": [{"label": "ASA DE", "dls": "Info zu ASA"}]}, now=1100)
    assert [x["k"] for x in _b2.evl.ev].count("asa") == 1
    for i, tt in enumerate((0, 10, 20, 31)):
        _b2.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","prog_type":"Alarm"}', now=2000 + tt)
    _p = [x for x in _b2.evl.ev if x["k"] == "pty31"]
    assert [x["persist"] for x in _p] == [False, True] and _b2.d["fm"]["BR24"]["pty31_persist"] == 1, _p
    _b2.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"0A","prog_type":"News"}', now=2050)
    assert _b2.d["fm"]["BR24"]["pty31_persist"] == 0
    for _ in range(2):
        _b2.on_rds("BR24", "102.0M", '{"pi":"0xD314","group":"2A","radiotext":"Adele - Hello","radiotext_plus":{"tags":[{"content-type":"item.artist"}]}}', now=2100)
    assert [x for x in _b2.evl.ev if x["k"] == "rt_warn"] == [] and _b2.d["fm"]["BR24"]["rtp"] == ["item.artist"]
    _wc = welle_caps(sys.executable)
    assert set(_wc) >= {"fig0_0", "fig0_19", "asa", "note"} and welle_caps(None)["exe"] is None
    _pl = Planner.__new__(Planner)
    _pl.cfg = {"dab": ["11D"]}
    assert _pl.dab_list() == ["11D", "5C"] and (_pl.cfg.update(asa_5c=False) or _pl.dab_list() == ["11D"])
    print("selftest br24Warn2 ok (Warn-Score, ASA DE 5C, PTY 31 dauerhaft, RT stabil, RT+ Titel)")
    b.save(True)
    t9 = time.time()
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"2A","radiotext":"Stau A9 Richtung Muenchen"}', now=t9 + 10)
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"0A","tp":true,"ta":false}', now=t9 + 70)
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"2A","radiotext":"Bayern 3 - Die beste Musik"}', now=t9 + 90)
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"2A","radiotext":"Spaeter Text"}', now=t9 + 200)
    ta = [x for x in b.evl.ev if x["k"] == "ta"]
    assert len(ta) == 1 and not ta[0]["open"] and ta[0]["ps"] == "BAYERN 3" and ta[0]["pi"] == "0xD313" and ta[0]["dur_s"] >= 60, ta
    assert ta[0]["rt"] == ["Stau A9 Richtung Muenchen", "Bayern 3 - Die beste Musik"], ta
    b.on_rds("Bayern 3", "97.9M", '{"pi":"0xD313","group":"0A","tp":true,"ta":true}', now=t9 + 300)
    b.tick(t9 + 500)
    ta = [x for x in b.evl.ev if x["k"] == "ta"]
    assert len(ta) == 2 and ta[1]["note"].startswith("Empfang beendet") and ta[1]["end"] == int(t9 + 300), ta
    ks = [x["k"] for x in b.evl.ev]
    assert ks.count("dls") == 2 and ks.count("dab_ann") == 1 and ks.count("rt_warn") == 1, ks
    b.on_dab("11D", {"services": [{"label": "BR24", "dls": "Nachrichten"}]}, now=t9 + 600)
    assert [x["k"] for x in b.evl.ev].count("dls") == 2 and b.evl.ev[-1]["k"] == "dab_ann_end", b.evl.ev[-1]
    b.save(True)
    rows = [json.loads(x) for x in open(os.path.join(tmp, "broadcast_events.jsonl"))]
    assert len(rows) == len(b.evl.ev) and not os.path.exists(os.path.join(tmp, "broadcast_events.jsonl.tmp"))
    assert len(BcEvents(tmp).ev) == len(rows)
    mice = res[1]
    # Stick-Bindung
    lt = "Found 2 device(s):\n  0:  Nooelec, NESDR SMArt v5, SN: 19348831\n  1:  Nooelec, NESDR SMArt v5, SN: 00000002\n"
    sl = parse_sticks(lt)
    assert [(x["idx"], x["sn"], x["name"]) for x in sl] == [(0, "19348831", "Nooelec, NESDR SMArt v5"), (1, "00000002", "Nooelec, NESDR SMArt v5")], sl
    assert pick_stick(sl, "00000002") == (1, None) and pick_stick(sl, "5")[1] == "Stick 5 fehlt"
    assert pick_stick(parse_sticks(lt.replace("00000002", "19348831")), "19348831")[1].startswith("doppelte Seriennummer")
    assert parse_sticks("No supported devices found.\n") == []
    for bad in ("", "12a", "-1", " 1", "1" * 17, None, True, 1.5, ["1"]):
        assert cfg_serial({"serial": bad}) is None, bad
    assert cfg_serial({}) == DEFAULT_SERIAL and cfg_serial({"serial": 42}) == "42"
    pl2 = Planner.__new__(Planner)
    pl2.dev_idx, pl2.dev_sn = 1, "00000002"
    assert pl2._dev(["rtl_433", "-f", "x"]) == ["rtl_433", "-f", "x", "-d", ":00000002"]
    assert pl2._dev(["rtl_fm"]) == ["rtl_fm", "-d", "1"]
    pl2.dev_idx = None
    try:
        pl2._dev(["rtl_fm"])
        raise AssertionError("ohne Index gestartet")
    except RuntimeError:
        pass
    fake = os.path.join(tmp, "tcp")
    with open(fake, "w") as f:
        f.write("  sl  local_address rem_address   st\n   0: 0100007F:04D3 00000000:0000 0A 0\n   1: 0100007F:04D4 00000000:0000 01 0\n")
    assert port_listening(1235, (fake,)) and not port_listening(1236, (fake,)) and not port_listening(1234, (fake,))
    assert "-g" in pl0.cmd("rds:0")[0] and DEFAULT_CFG["fm_s"] == 60
    # Funkumgebung + Kalibrierung
    try:
        import numpy as np
        rng = np.random.default_rng(3)
        bd = NOISE_BANDS[NOISE_IDS.index("fm")]
        mt = NoiseMeter(bd, 10, 4)
        for k in range(6):
            for h in range(3):
                v = rng.normal(-40, 1.0, 100)
                if h == 1:
                    v[30] = -15.0  # Traeger
                    v[31] = -22.0
                mt.feed_power("2026-10-12, 18:00:%02d, %d, %d, 25000, 4000, " % (k, 87500000 + h * 2500000, 87500000 + (h + 1) * 2500000) + ", ".join("%.2f" % x for x in v) + "\n")
        r = mt.result()
        assert r["ok"] and r["n"] == 5 and abs(r["floor"] + 40) < 1 and r["n_car"] == 1 and abs(r["cars"][0]["f"] - 90.7625) < 0.03 and r["cars"][0]["db"] > 20, r
        ns = NoiseState(tmp)
        t0 = time.time() - 30 * 3600
        cfg0 = dict(DEFAULT_CFG)
        for k in range(110):  # 27 h ruhig mit bekanntem Traeger
            ns.add(dict(r, t=int(t0 + k * 900), floor=-40.0 + 0.1 * (k % 3)), cfg0)
        x = ns.d["bands"]["fm"]
        assert x["lvl"] == "gruen" and x["n_pers"] == 0 and not x["learning"], x
        rr = dict(r, t=int(t0 + 110 * 900), floor=-29.0, cars=r["cars"] + [{"f": 99.0, "db": 25.0, "w_khz": 25}])
        for k in range(3):
            ns.add(dict(rr, t=int(t0 + (110 + k) * 900)), cfg0)
        x = ns.d["bands"]["fm"]
        assert x["lvl"] == "rot" and x["raise"] >= 10 and x["n_pers"] == 1 and x["cars"][0]["f"] == 99.0, x
        # Impulse (Direktabtastung): Rauschen + 12 breitbandige Knackser in 2 s
        bm = NOISE_BANDS[NOISE_IDS.index("mw")]
        mi = NoiseMeter(bm)
        sr = bm["sr"]
        iq = (rng.normal(0, 300, 2 * sr) + 1j * rng.normal(0, 300, 2 * sr))
        for k in range(12):
            j = 50000 + k * 150000
            iq[j:j + 300] += rng.normal(0, 9000, 300) + 1j * rng.normal(0, 9000, 300)
        u = np.empty(4 * sr, dtype="<i2")
        u[0::2] = np.clip(iq.real, -32767, 32767)
        u[1::2] = np.clip(iq.imag, -32767, 32767)
        bb = u.tobytes()
        for k in range(0, len(bb), 65536):
            mi.feed_iq(bb[k:k + 65536], sr)
        ri = mi.result()
        assert ri["ok"] and 300 <= ri["bb_pm"] <= 400 and ri["imp_pm"] >= ri["bb_pm"], ri
        ns.add(ri, cfg0)
        ns.finish_block(cfg0)
        assert ns.d["thunder"]["lvl"] == "grau" and ns.d["thunder"]["bb_pm"] > 300 and ns.d["qrm"]["lvl"] == "gruen", (ns.d["thunder"], ns.d["qrm"])
        z = NoiseMeter(bm)
        z.feed_iq(b"\x00" * (4 * sr), sr)
        assert z.result()["ok"] is False
        selftest_noise2(tmp)
    except ImportError:
        print("selftest: numpy fehlt - Funkumgebung nicht geprueft")
    f11 = DAB_CHANNELS["11D"] * 1e6
    assert cal_compute(0.3 * 222.064, (0.3 - 5) * 222.064, 5, f11) == (0.3, "ok (Steigung -1.00)"), cal_compute(0.3 * 222.064, (0.3 - 5) * 222.064, 5, f11)
    assert cal_compute(66.6, 66.6, 5, f11)[0] is None and cal_compute(None, 1, 5, f11)[0] is None
    assert cal_compute(15 * 222.064, 10 * 222.064, 5, f11)[0] is None  # ausserhalb +-10
    assert ppm_val({"ppm": 3}) == 3 and ppm_val({"ppm": 40}) == 0 and ppm_val({"ppm": True}) == 0 and ppm_val({"ppm": -0.6}) == -1
    pl0.cfg["ppm"] = 2
    nzc = " ".join(pl0.cmd("nz:0")[0])
    assert nzc.startswith("rtl_power -f 144.000M:146.000M:5k ") and nzc.endswith(" -p 2 -d 0 -"), nzc
    assert " ".join(pl0.cmd("nz:%d" % NOISE_IDS.index("mw"))[0]).startswith("rtl_fm -M raw -E direct2 -f 1.050M -s 1024000 -g 30 ")
    for gv, want in ((None, "30"), (0, "30"), ("auto", "30"), (float("nan"), "30"), (99, "30"), (20.7, "20.7"), (True, "30")):
        pl0.cfg["gain_noise"] = gv
        got = noise_gain(pl0.cfg) if gv is not True else ("30" if noise_gain(pl0.cfg) in ("30", "1") else "?")
        assert got == want, (gv, got)
        for j in range(len(NOISE_BANDS)):
            cc = pl0.cmd("nz:%d" % j)[0]
            assert cc[cc.index("-g") + 1] not in ("0", "", None), cc
    pl0.cfg["gain_noise"] = 30
    pl0.cfg["ppm"] = 0
    # sdr_cal_now unterbricht laufenden Rundfunkblock sofort
    pl0.cfg["cal_enable"] = True
    tn = time.time()
    pl0.special = {"kind": "bc", "queue": ["rds:0", "rds:1"], "durs": [60, 60], "i": 0, "sub_end": tn + 60, "hard_end": tn + 200, "t0": tn}
    pl0.passes = []
    open(p("sdr_cal_now", tmp), "w").close()
    wj = pl0.want({"mode": "auto"}, tn)
    assert wj == "cal:0" and pl0.special["kind"] == "cal" and not os.path.exists(p("sdr_cal_now", tmp)), (wj, pl0.special)
    pl0.special = None
    assert "gps" in pl0.status({"mode": "auto"}, True)
    try:
        sys.path.insert(0, BASE)
        import prepper_gps
        prepper_gps.selftest()
    except ImportError:
        pass
    print("selftest OK: 433 Sensoren=%d, APRS Stationen=%d, Mic-E %.4f/%.4f, WX %s" % (
        len(s.d["sensors"]), len(st["stations"]), mice["lat"], mice["lon"], res[2]["wx"]))
    return True


if __name__ == "__main__":
    a = sys.argv[1] if len(sys.argv) > 1 else "status"
    if a == "run":
        Planner(BASE).loop()
    elif a == "selftest":
        selftest()
    elif a == "sticks":
        sys.exit(sticks_cli(BASE))
    else:
        print(json.dumps(load_json(p("sdr_status.json"), {}), indent=1, ensure_ascii=False))
MODPY_EOF
cat > "$W/prepper_sdr_net.py" << 'NETPY_EOF'
#!/usr/bin/env python3
"""prepper_sdr_net: einzige Netzzugriffe des SDR-Planers (nur lesen):
- Bahndaten (TLE) der Wettersatelliten von celestrak.org (fester Host, nur wenn online; Cache fuer offline)
- Status-JSON von welle-cli auf 127.0.0.1 (lokal, DAB+-Texte)
Sendet nichts - kein Mesh, kein Funk."""
import json
import re
import urllib.request

CELESTRAK = "https://celestrak.org/NORAD/elements/gp.php?CATNR=%d&FORMAT=tle"
RE_L1 = re.compile(r"^1 (\d{5})[A-Z ]")
RE_L2 = re.compile(r"^2 (\d{5}) ")


def fetch_tle(catnr, timeout=15):
    """-> (name, line1, line2) oder Exception. Nur celestrak.org, Ergebnis wird geprueft."""
    catnr = int(catnr)
    req = urllib.request.Request(CELESTRAK % catnr, headers={"User-Agent": "prepper-sdr/1 (Wetterbilder)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        txt = r.read(4096).decode("ascii", "replace")
    lines = [x.rstrip() for x in txt.splitlines() if x.strip()]
    if len(lines) < 3:
        raise ValueError("TLE leer: %s" % txt[:60])
    name, l1, l2 = lines[0].strip(), lines[1], lines[2]
    m1, m2 = RE_L1.match(l1), RE_L2.match(l2)
    if not (m1 and m2 and int(m1.group(1)) == catnr and int(m2.group(1)) == catnr and len(l1) >= 68 and len(l2) >= 68):
        raise ValueError("TLE ungueltig")
    return name, l1, l2


def fetch_welle(port, timeout=4):
    """mux.json von welle-cli (nur 127.0.0.1)."""
    port = int(port)
    with urllib.request.urlopen("http://127.0.0.1:%d/mux.json" % port, timeout=timeout) as r:
        return json.loads(r.read(2000000).decode("utf-8", "replace"))
NETPY_EOF
cat > "$W/prepper_gps.py" << 'GPSPY_EOF'
#!/usr/bin/env python3
"""prepper_gps: Dach-GPS (gpsd auf dem Stratum-1-Server) nur lesen, als Hinweis auf GPS-Stoerer.
Einzige Netzverbindung: TCP-Client zu 192.168.178.15:2947 (fest), sendet nur das feste ?WATCH-Kommando
(JSON-Ausgabe einschalten), liest ein paar Sekunden TPV/SKY und trennt wieder. Kein Server, kein Mesh, kein Funk.
Bewertung getrennt fuer GPS (gnssid 0) und GLONASS (gnssid 6): Signalstaerke (ss > 0, nur verfolgte Satelliten) je Hoehenband
10-30 / 30-60 / >60 Grad (unter 10 Grad ignoriert) gegen die 7-Tage-Grundlinie desselben Bandes (Median, MAD).
Gelb ab max(6 dB, 4*MAD), rot ab max(10 dB, 6*MAD) oder Fix-Verlust; zusaetzlich muessen >= 70 % der Satelliten des Systems
>= 3 dB unter ihrer Grundlinie liegen (Stoerer trifft alle, Abschattung nur einzelne). Beide Systeme schwaecher = breitbandig,
nur GPS = L1-schmalbandig (GPS L1 1575,42 MHz, GLONASS ~1602 MHz). Ampel erst nach 3 Messungen hintereinander."""
import json
import socket
import threading
import time

GPSD_HOST = "192.168.178.15"
GPSD_PORT = 2947
WATCH = b'?WATCH={"enable":true,"json":true}\n'
UNWATCH = b'?WATCH={"enable":false}\n'


RANK = {"grau": 0, "gruen": 1, "gelb": 2, "rot": 3}
LVL = {v: k for k, v in RANK.items()}
SYS = {0: "G", 6: "R"}
SYSNAME = {"G": "GPS", "R": "GLONASS"}
EBINS = ((10.0, 30.0, "1"), (30.0, 60.0, "2"), (60.0, 90.01, "3"))
CLOCK_OK = 17 * 10 ** 8  # vor Nov. 2023 = Uhr nicht gestellt (Pi ohne RTC) -> nichts bewerten/speichern


def _fin(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x == x and x not in (float("inf"), float("-inf"))


def _med(xs):
    xs = sorted(float(x) for x in xs if _fin(x))
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def robust(xs):
    v = [float(x) for x in xs if _fin(x)]
    m = _med(v)
    if m is None:
        return None, None, 0
    return m, 1.4826 * _med([abs(x - m) for x in v]), len(v)


def ebin(el):
    if not _fin(el):
        return None
    for lo, hi, k in EBINS:
        if lo <= el < hi:
            return k
    return None


def read_gpsd(read_s=6.0, timeout=4.0):
    """-> Liste JSON-Objekte (TPV/SKY/DEVICES/VERSION) einer kurzen Lesung. Exception wenn nicht erreichbar."""
    out = []
    s = socket.create_connection((GPSD_HOST, GPSD_PORT), timeout=timeout)
    try:
        s.settimeout(1.0)
        s.sendall(WATCH)
        buf = b""
        end = time.time() + float(read_s)
        got_sky = got_tpv = False
        while time.time() < end and len(buf) < 400000:
            try:
                chunk = s.recv(16384)
            except socket.timeout:
                continue
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    o = json.loads(line.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if isinstance(o, dict):
                    out.append(o)
                    if o.get("class") == "SKY" and isinstance(o.get("satellites"), list):
                        got_sky = True
                    if o.get("class") == "TPV":
                        got_tpv = True
            if got_sky and got_tpv and len(out) >= 6:
                break
        try:
            s.sendall(UNWATCH)
        except OSError:
            pass
    finally:
        s.close()
    return out


def parse(objs, now=None):
    """Kurze Lesung -> Messpunkt (nur Zahlen). Nur verfolgte Satelliten (ss > 0); je System und Hoehenband Mittelwert."""
    now = int(now or time.time())
    objs = [o for o in (objs or []) if isinstance(o, dict)]
    sky = [o for o in objs if o.get("class") == "SKY" and isinstance(o.get("satellites"), list)]
    tpv = [o for o in objs if o.get("class") == "TPV"]
    devs = [o for o in objs if o.get("class") == "DEVICES"]
    r = {"ts": now, "ok": True}
    if devs and not (devs[-1].get("devices") or []):
        r.update(ok=False, why="gpsd ohne Empfänger")
        return r
    mode = None
    for o in reversed(tpv):
        if isinstance(o.get("mode"), int) and not isinstance(o.get("mode"), bool):
            mode = o["mode"]
            break
    r["mode"] = mode if mode is not None else 0
    if not sky:
        r.update(seen=0, used=0, snr=None, top4=None, hdop=None, nosky=True, g={}, gn={}, sats=[])
        return r
    sats = []
    for x in sky[-1]["satellites"]:
        if not isinstance(x, dict) or not _fin(x.get("ss")) or not (0 < float(x["ss"]) < 99):
            continue
        gid = x.get("gnssid")
        if not isinstance(gid, int) or isinstance(gid, bool):
            prn = x.get("PRN")
            gid = 0 if isinstance(prn, int) and 1 <= prn <= 32 else (6 if isinstance(prn, int) and 65 <= prn <= 96 else -1)
        sats.append({"sys": SYS.get(gid), "ss": float(x["ss"]), "el": x.get("el") if _fin(x.get("el")) else None, "used": bool(x.get("used"))})
    ss_all = [x["ss"] for x in sats]
    ss_used = [x["ss"] for x in sats if x["used"]]
    pool = ss_used if len(ss_used) >= 4 else ss_all
    top = sorted(ss_all, reverse=True)[:4]
    g, gn = {}, {}
    for x in sats:
        k = ebin(x["el"])
        if x["sys"] and k:
            g.setdefault(x["sys"] + k, []).append(x["ss"])
    for k in list(g):
        gn[k] = len(g[k])
        g[k] = round(sum(g[k]) / len(g[k]), 1)
    hd = sky[-1].get("hdop")
    r.update(seen=len(ss_all), used=len(ss_used), snr=round(sum(pool) / len(pool), 1) if pool else None,
             top4=round(sum(top) / len(top), 1) if top else None, hdop=round(float(hd), 2) if _fin(hd) else None, g=g, gn=gn,
             sats=[x for x in sats if x["sys"] and ebin(x["el"])])
    return r


def sys_eval(pt, ref, s, cfg):
    """Ein System (G/R): gewichtete Abweichung gegen Hoehenband-Grundlinien. -> dict oder None (keine Daten/Grundlinie)."""
    cur = pt.get("g") or {}
    tot = w = madw = 0.0
    base = {}
    for _lo, _hi, k in EBINS:
        key = s + k
        vals = [(x.get("g") or {}).get(key) for x in ref]
        m, mad, n = robust(vals)
        if m is not None and n >= 24:
            base[key] = (m, mad)
        if key in base and _fin(cur.get(key)):
            nn = float((pt.get("gn") or {}).get(key) or 1)
            tot += (base[key][0] - cur[key]) * nn
            madw += base[key][1] * nn
            w += nn
    if not base:
        return None
    if not w:
        return {"sys": s, "drop": None, "n": 0, "frac": None, "has_base": True}
    sats = [x for x in (pt.get("sats") or []) if x["sys"] == s and (s + ebin(x["el"])) in base]
    low = [x for x in sats if base[s + ebin(x["el"])][0] - x["ss"] >= 3.0]
    mad = madw / w
    yel = max(float(cfg.get("gps_drop_yel") or 6), float(cfg.get("gps_k_yel") or 4) * mad)
    red = max(float(cfg.get("gps_drop_red") or 10), float(cfg.get("gps_k_red") or 6) * mad, yel + 1.0)
    return {"sys": s, "drop": round(tot / w, 1), "n": int(w), "frac": round(len(low) / len(sats), 2) if sats else None,
            "yel": round(yel, 1), "red": round(red, 1), "mad": round(mad, 2), "has_base": True}


def judge(pt, hist, cfg, now):
    """Roh-Ampel eines Messpunkts gegen 7-Tage-Grundlinie je System/Hoehenband. -> (lvl, info)"""
    now = int(now)
    ref = [x for x in hist if 3600 <= now - x.get("ts", 0) < 7 * 86400 and (x.get("mode") or 0) >= 2]
    span = (max(x["ts"] for x in ref) - min(x["ts"] for x in ref)) if ref else 0
    b_snr, _m, _n = robust(x.get("snr") for x in ref)
    b_used = _med([x.get("used") for x in ref])
    info = {"b_snr": None if b_snr is None else round(b_snr, 1), "b_used": b_used, "n_base": len(ref), "drop": None, "cls": None, "G": None, "R": None}
    if not pt.get("ok"):
        return "grau", dict(info, why=pt.get("why") or "nicht erreichbar")
    if now < CLOCK_OK:
        return "grau", dict(info, why="Uhr nicht gestellt")
    if _fin(pt.get("snr")) and b_snr is not None:
        info["drop"] = round(b_snr - pt["snr"], 1)
    ev = {s: (sys_eval(pt, ref, s, cfg) if len(ref) >= 36 and span >= 12 * 3600 else None) for s in ("G", "R")}
    info["G"], info["R"] = ev["G"], ev["R"]
    lost = (pt.get("mode") or 0) < 2 and (b_used or 0) >= 4
    if not any(ev.values()):
        if lost:
            return "gelb", dict(info, why="kein Fix (Grundlinie lernt noch)")
        return "grau", dict(info, why="lernt Grundlinie je System/Höhe (12-24 h, noch keine Bewertung)", learning=True)

    def down(e, which="yel"):
        return bool(e and _fin(e.get("drop")) and e["drop"] >= e[which] and (e.get("frac") is None or e["frac"] >= 0.7))
    g, r = ev["G"], ev["R"]
    gd, rd = down(g), down(r)
    gr, rr = down(g, "red"), down(r, "red")
    r_ok = bool(r and _fin(r.get("drop")))
    g_none = bool(g and g.get("n") == 0)
    def f(x):
        return str(round(x, 1)).replace(".", ",")
    if lost and (gd or rd or g_none or not (g and _fin(g.get("drop")))):
        return "rot", dict(info, cls="breitbandig" if (rd or not r_ok) and (gd or g_none) else None, why="Fix verloren, Signale eingebrochen")
    if gd and rd:
        return ("rot" if (gr or rr) else "gelb"), dict(info, cls="breitbandig", why="GPS %s / GLONASS %s dB schwächer (breitbandig)" % (f(g["drop"]), f(r["drop"])))
    if gd and r_ok and r["drop"] < r["yel"] / 2.0:
        return ("rot" if gr else "gelb"), dict(info, cls="L1-schmalbandig", why="nur GPS %s dB schwächer, GLONASS normal (L1-schmalbandig)" % f(g["drop"]))
    if gd:
        return ("rot" if gr else "gelb"), dict(info, cls="GPS", why="GPS %s dB schwächer (kein GLONASS-Vergleich)" % f(g["drop"]))
    if rd:
        return ("rot" if rr else "gelb"), dict(info, cls="GLONASS", why="nur GLONASS %s dB schwächer" % f(r["drop"]))
    if lost:
        return "gelb", dict(info, why="kein Fix (Signale normal: eher Empfänger/Antenne)")
    return "gruen", dict(info, why="normal")


def sys_progress(hist, lk, cur, now):
    """Je System (G/R): jetzt verfolgte Satelliten (>= 10 Grad, ss > 0) + mittlere ss, gesammelte Proben, Lernfortschritt.
    Bewertung beginnt, wenn >= 36 Proben ueber >= 12 h vorliegen und ein Hoehenband >= 24 Werte hat (wie judge/sys_eval)."""
    out = {}
    g, gn = (lk or {}).get("g") or {}, (lk or {}).get("gn") or {}
    ok_now = bool(lk) and (cur or {}).get("ok") is not False
    for s in ("G", "R"):
        n_now = sum(int(gn.get(s + k) or 0) for _lo, _hi, k in EBINS) if ok_now else 0
        ssw = sum(float(g[s + k]) * int(gn.get(s + k) or 0) for _lo, _hi, k in EBINS if _fin(g.get(s + k))) if ok_now else 0.0
        pts = [x for x in hist if isinstance(x.get("g"), dict) and any(_fin(x["g"].get(s + k)) for _lo, _hi, k in EBINS)
               and 3600 <= now - x.get("ts", 0) < 7 * 86400 and (x.get("mode") or 0) >= 2]
        allp = [x for x in hist if isinstance(x.get("g"), dict) and any(_fin(x["g"].get(s + k)) for _lo, _hi, k in EBINS) and 0 <= now - x.get("ts", 0) < 7 * 86400]
        span = (max(x["ts"] for x in pts) - min(x["ts"] for x in pts)) / 3600.0 if pts else 0.0
        best = max([sum(1 for x in pts if _fin(x["g"].get(s + k))) for _lo, _hi, k in EBINS] or [0])
        ev = (cur or {}).get(s)
        learning = not (ev and ev.get("has_base"))
        eta = max(12.0 - span, (36 - len(pts)) * 5 / 60.0, (24 - best) * 5 / 60.0, 0.0) if learning else 0.0
        out[s] = {"name": SYSNAME[s], "now_n": n_now, "now_ss": round(ssw / n_now, 1) if n_now else None, "samples": len(allp),
                  "ref": len(pts), "span_h": round(span, 1), "best_bin": best, "learning": learning, "eta_h": round(eta, 1),
                  "state": ("bewertet" if not learning else ("lernt" if (n_now or allp) else "keine Daten"))}
    return out


def sys_mean(pt, s):
    """Mittlere ss eines Systems (G/R) ueber alle Hoehenbaender, gewichtet mit Satellitenzahl."""
    g, gn = (pt or {}).get("g") or {}, (pt or {}).get("gn") or {}
    if not isinstance(g, dict) or not isinstance(gn, dict):
        return None, 0
    sw = n = 0.0
    for _lo, _hi, k in EBINS:
        v, c = g.get(s + k), gn.get(s + k)
        c = float(c) if _fin(c) and c > 0 else 1.0
        if _fin(v):
            sw += v * c
            n += c
    return (round(sw / n, 1), int(n)) if n else (None, 0)


SYS_FILES = {"G": "sdr_gps_snr_gps.json", "R": "sdr_gps_snr_glo.json"}


def sys_base(hs, now):
    """Grundlinie je System = Median der Punkte 1 h - 7 d alt (mind. 36), sonst None."""
    v = sorted(x["snr"] for x in hs if _fin(x.get("snr")) and 3600 <= now - x.get("ts", 0) < 7 * 86400)
    return round(v[len(v) // 2], 1) if len(v) >= 36 else None


class GpsWatch:
    """Thread: alle gps_interval_s eine kurze Lesung. Verlauf sdr_gps_hist.json {"snr": [...]} (Archiv sdr_gps_snr),
    Punkt hoechstens alle 5 min, geschrieben hoechstens alle 30 min. Ampel = schwaechste der letzten gps_persist Roh-Ampeln."""
    KEEP_S = 14 * 86400

    def __init__(self, fh, cfg, load_json, write_json, log):
        self.fh, self.cfg, self.write_json, self.log = fh, cfg, write_json, log
        h = load_json(fh, None) or {}
        h = h if isinstance(h, dict) else {}
        self.h = [x for x in (h.get("snr") or []) if isinstance(x, dict) and _fin(x.get("ts"))][-5000:]
        self.raw = []
        self.cur = None
        self.last_ok = None
        for x in reversed(self.h):
            self.last_ok = dict(x, ok=True)
            break
        self.fail_since = None
        self.err = None
        self.lock = threading.Lock()
        self.stop = False
        self.dirty = False
        self.last_save = time.time()
        self.n = 0
        self._prog, self._prog_n = {}, None
        d = fh.rsplit("/", 1)[0] if "/" in fh else "."
        self.fs, self.hs = {}, {}
        for k, fn in SYS_FILES.items():
            self.fs[k] = d + "/" + fn
            try:
                hx = load_json(self.fs[k], None) or {}
            except Exception:
                hx = {}
            hx = hx if isinstance(hx, dict) else {}
            self.hs[k] = [x for x in (hx.get("snr") or []) if isinstance(x, dict) and _fin(x.get("ts")) and _fin(x.get("snr"))][-5000:]

    def step(self, now=None, objs=None):
        now = int(now or time.time())
        try:
            pt = parse(objs if objs is not None else read_gpsd(float(self.cfg.get("gps_read_s") or 6)), now)
            self.err = None if pt.get("ok") else pt.get("why")
        except Exception as e:
            pt = {"ts": now, "ok": False, "why": "nicht erreichbar"}
            if self.err != str(e)[:120]:
                self.log("Dach-GPS %s:%d nicht erreichbar: %s" % (GPSD_HOST, GPSD_PORT, e))
            self.err = str(e)[:120]
        with self.lock:
            lvl, info = judge(pt, self.h, self.cfg, now)
            self.n += 1
            if pt.get("ok"):
                self.fail_since = None
                self.raw = (self.raw + [RANK[lvl]])[-12:]
                k = max(1, int(self.cfg.get("gps_persist") or 3))
                last = self.raw[-k:]
                show = LVL[min(last)] if len(last) >= k else ("gruen" if lvl != "grau" else "grau")
                if lvl == "grau":
                    show = "grau"
                self.last_ok = {k2: pt.get(k2) for k2 in ("ts", "snr", "top4", "seen", "used", "mode", "hdop", "g", "gn")}
                prev = self.h[-1] if self.h else None
                if now >= CLOCK_OK and (not prev or now - prev.get("ts", 0) >= 290 or now < prev.get("ts", 0) or (show in ("gelb", "rot"))):
                    self.h.append({k2: pt.get(k2) for k2 in ("ts", "snr", "top4", "seen", "used", "mode", "hdop", "g", "gn")})
                    self.h = self.h[-5000:]
                    for k in SYS_FILES:
                        m, nn = sys_mean(pt, k)
                        if m is not None:
                            self.hs[k] = (self.hs[k] + [{"ts": now, "snr": m, "n": nn}])[-5000:]
                    self.dirty = True
                self.cur = dict(info, lvl=show, raw=lvl, t=now, ok=True)
            else:
                self.fail_since = self.fail_since or now
                self.cur = dict(info, lvl="grau", raw="grau", t=now, ok=False, why=pt.get("why") or "nicht erreichbar", since=self.fail_since)
            if self.dirty and (now - self.last_save >= 1800 or now < self.last_save):
                self.save(now)
        return self.cur

    def save(self, now=None):
        now = now or time.time()
        cut = now - self.KEEP_S
        self.h = [x for x in self.h if cut <= x.get("ts", 0) <= now + 3600][-5000:]
        self.write_json(self.fh, {"snr": self.h, "src": "gpsd %s:%d" % (GPSD_HOST, GPSD_PORT)})
        for k in SYS_FILES:
            self.hs[k] = [x for x in self.hs[k] if cut <= x.get("ts", 0) <= now + 3600][-5000:]
            self.write_json(self.fs[k], {"snr": self.hs[k], "sys": k, "src": "gpsd %s:%d" % (GPSD_HOST, GPSD_PORT)})
        self.dirty, self.last_save = False, now

    def summary(self):
        with self.lock:
            c = dict(self.cur or {"lvl": "grau", "ok": None, "why": "noch keine Abfrage"})
            lk = self.last_ok or {}
            c.update({"src": "Dach-GPS", "host": GPSD_HOST, "snr": lk.get("snr"), "top4": lk.get("top4"), "seen": lk.get("seen"),
                      "used": lk.get("used"), "mode": lk.get("mode"), "hdop": lk.get("hdop"), "last_t": lk.get("ts"),
                      "iv": int(self.cfg.get("gps_interval_s") or 120)})
            if self._prog_n != (self.n, len(self.h)):
                t0 = c.get("t") or time.time()
                self._prog, self._prog_n = sys_progress(self.h, lk, c, t0), (self.n, len(self.h))
                for k in SYS_FILES:
                    if isinstance(self._prog.get(k), dict):
                        self._prog[k]["b_snr"] = sys_base(self.hs.get(k) or [], t0)
                        self._prog[k]["hist_n"] = len(self.hs.get(k) or [])
            c["sys"] = self._prog
        return c

    def run(self):
        iv = max(60.0, float(self.cfg.get("gps_interval_s") or 120))
        time.sleep(5)
        while not self.stop:
            t0 = time.time()
            try:
                self.step()
            except Exception as e:
                self.log("Dach-GPS:", e)
            while not self.stop and time.time() < t0 + iv:
                time.sleep(1)
        try:
            with self.lock:
                if self.dirty:
                    self.save()
        except Exception as e:
            self.log("Dach-GPS speichern:", e)


def _synth(now, dg=0.0, dr=0.0, rnd=None, mode=3, obstruct=False, glo=True):
    """Synthetische gpsd-Lesung: 8 GPS + 6 GLONASS in drei Hoehenbaendern, dazu ein Satellit unter 10 Grad und einer mit ss 0."""
    import random
    rnd = rnd or random.Random(1)
    sats = []
    for i in range(8):
        el = (15, 25, 40, 50, 55, 65, 75, 35)[i]
        base = 30 + el * 0.2
        d = dg if not (obstruct and i < 4) else (15.0 if obstruct else 0.0)
        sats.append({"PRN": i + 1, "gnssid": 0, "el": el, "az": 10 * i, "ss": round(base - d + rnd.gauss(0, 1.2), 1), "used": True})
    if glo:
        for i in range(6):
            el = (20, 35, 45, 62, 70, 28)[i]
            sats.append({"PRN": 65 + i, "gnssid": 6, "el": el, "az": 30 * i, "ss": round(28 + el * 0.2 - dr + rnd.gauss(0, 1.2), 1), "used": True})
    sats.append({"PRN": 30, "gnssid": 0, "el": 5, "ss": 15, "used": False})
    sats.append({"PRN": 31, "gnssid": 0, "el": 40, "ss": 0, "used": False})
    sats.append({"PRN": 32, "gnssid": 0, "el": 40, "ss": float("nan"), "used": False})
    return [{"class": "DEVICES", "devices": [{"path": "/dev/serial0"}]}, {"class": "TPV", "mode": mode}, {"class": "SKY", "hdop": 0.9, "satellites": sats}]


def selftest():
    import random
    rnd = random.Random(7)
    now = 179 * 10 ** 7
    a = parse(_synth(now, rnd=rnd), now)
    assert a["ok"] and a["seen"] == 15 and a["used"] == 14 and a["mode"] == 3 and set(a["g"]) == {"G1", "G2", "G3", "R1", "R2", "R3"}, a
    assert all(x["el"] >= 10 for x in a["sats"]) and len(a["sats"]) == 14, a["sats"]
    assert not parse([{"class": "DEVICES", "devices": []}])["ok"]
    assert parse([{"class": "TPV", "mode": 3}], now)["nosky"]
    assert parse(["kaputt", None, {"class": "SKY", "satellites": "x"}], now)["nosky"]
    # 3 Tage Normalbetrieb als Verlauf (alle 5 min)
    hist = []
    for k in range(3 * 288):
        t = now - 3 * 86400 + k * 300
        q = parse(_synth(t, rnd=rnd), t)
        hist.append({k2: q.get(k2) for k2 in ("ts", "snr", "top4", "seen", "used", "mode", "hdop", "g", "gn")})
    hist += ["kaputt", {"ts": float("nan")}, {"ts": now - 7200, "snr": float("inf"), "mode": 3, "g": {"G1": None}}]
    hist = [x for x in hist if isinstance(x, dict) and _fin(x.get("ts"))]
    cfg = {}
    assert judge(a, hist[:10], cfg, now)[0] == "grau"
    # Fehlalarm-Pruefung: 600 normale Messungen -> nach 3er-Regel nie gelb/rot
    g = GpsWatch("/x", {"gps_persist": 3}, lambda f, d: {"snr": hist}, lambda f, d: None, lambda *x: None)
    worst = 0
    for k in range(200):
        worst = max(worst, RANK[g.step(now + k, _synth(now + k, rnd=rnd))["lvl"]])
    assert worst <= RANK["gruen"], worst
    lv, inf = judge(parse(_synth(now, dg=12, dr=12, rnd=rnd), now), hist, cfg, now)
    assert lv == "rot" and inf["cls"] == "breitbandig", (lv, inf)
    lv, inf = judge(parse(_synth(now, dg=7.5, dr=7.5, rnd=rnd), now), hist, cfg, now)
    assert lv == "gelb" and inf["cls"] == "breitbandig", (lv, inf)
    lv, inf = judge(parse(_synth(now, dg=8, rnd=rnd), now), hist, cfg, now)
    assert lv == "gelb" and inf["cls"] == "L1-schmalbandig", (lv, inf)
    lv, inf = judge(parse(_synth(now, dg=12, rnd=rnd), now), hist, cfg, now)
    assert lv == "rot" and inf["cls"] == "L1-schmalbandig", (lv, inf)
    lv, inf = judge(parse(_synth(now, obstruct=True, rnd=rnd), now), hist, cfg, now)
    assert lv == "gruen", (lv, inf)  # Abschattung einzelner Satelliten
    lv, inf = judge(parse(_synth(now, dg=9, glo=False, rnd=rnd), now), hist, cfg, now)
    assert lv == "gelb" and inf["cls"] == "GPS", (lv, inf)
    lv, inf = judge(parse(_synth(now, dg=12, dr=12, mode=1, rnd=rnd), now), hist, cfg, now)
    assert lv == "rot", (lv, inf)
    lv, inf = judge(parse(_synth(now, mode=1, rnd=rnd), now), hist, cfg, now)
    assert lv == "gelb", (lv, inf)  # Fix weg, Signale normal
    assert judge({"ok": False, "ts": now}, hist, cfg, now)[0] == "grau"
    assert judge(a, hist, cfg, 1000)[0] == "grau"  # Uhr nicht gestellt
    # 3er-Regel + keepLast
    g = GpsWatch("/x", {"gps_persist": 3}, lambda f, d: {"snr": hist}, lambda f, d: None, lambda *x: None)
    assert g.step(now, _synth(now, rnd=rnd))["lvl"] == "gruen"
    assert g.step(now + 120, _synth(now, dg=12, dr=12, rnd=rnd))["lvl"] == "gruen"
    assert g.step(now + 240, _synth(now, dg=12, dr=12, rnd=rnd))["lvl"] == "gruen"
    c = g.step(now + 360, _synth(now, dg=12, dr=12, rnd=rnd))
    assert c["lvl"] == "rot" and c["cls"] == "breitbandig", c
    g.read = None
    s = g.summary()
    assert s["src"] == "Dach-GPS" and _fin(s["snr"])
    sp = s["sys"]
    assert sp["G"]["state"] == "bewertet" and sp["R"]["state"] == "bewertet" and sp["R"]["now_n"] == 6 and _fin(sp["R"]["now_ss"]), sp
    # lernend: nur 2 h Verlauf, GLONASS per PRN 65-96 ohne gnssid erkannt
    q = _synth(now, rnd=rnd)
    for x in q[2]["satellites"]:
        if x.get("gnssid") == 6:
            del x["gnssid"]
    pq = parse(q, now)
    assert pq["gn"].get("R1", 0) + pq["gn"].get("R2", 0) + pq["gn"].get("R3", 0) == 6, pq["gn"]
    g2 = GpsWatch("/x", {}, lambda f, d: {"snr": hist[-24:]}, lambda f, d: None, lambda *x: None)
    g2.step(now, q)
    sp = g2.summary()["sys"]
    assert sp["R"]["state"] == "lernt" and sp["R"]["now_n"] == 6 and sp["R"]["eta_h"] > 0 and sp["R"]["samples"] >= 20, sp["R"]
    g3 = GpsWatch("/x", {}, lambda f, d: {"snr": []}, lambda f, d: None, lambda *x: None)
    g3.step(now, _synth(now, glo=False, rnd=rnd))
    sp = g3.summary()["sys"]
    assert sp["R"]["state"] == "keine Daten" and sp["R"]["now_n"] == 0 and sp["G"]["state"] == "lernt", sp
    bad = GpsWatch("/x", {}, lambda f, d: "kaputt", lambda f, d: None, lambda *x: None)
    assert bad.h == [] and bad.summary()["lvl"] == "grau"
    # Verlauf je System: getrennte Dateien, begrenzt, atomar ueber write_json (keepLast), kaputte Eintraege raus
    wr = {}
    g = GpsWatch("/tmp/x/sdr_gps_hist.json", {}, lambda f, d: {"snr": [{"ts": now - 99, "snr": 40.0}, "kaputt", {"ts": now, "snr": float("nan")}] * 3000}, lambda f, d: wr.__setitem__(f.rsplit("/", 1)[-1], d), lambda *x: None)
    assert all(len(g.hs[k]) <= 5000 and all(_fin(x["snr"]) for x in g.hs[k]) for k in "GR"), {k: len(g.hs[k]) for k in "GR"}
    g.hs = {"G": [], "R": []}
    g.h = []
    for k in range(3):
        g.step(now + k * 300, _synth(now, rnd=rnd))
    g.step(now + 1200, _synth(now, glo=False, rnd=rnd))
    g.save(now + 1200)
    assert set(wr) == {"sdr_gps_hist.json", "sdr_gps_snr_gps.json", "sdr_gps_snr_glo.json"}, wr.keys()
    assert len(wr["sdr_gps_snr_gps.json"]["snr"]) == 4 and len(wr["sdr_gps_snr_glo.json"]["snr"]) == 3, wr
    mg, mr = wr["sdr_gps_snr_gps.json"]["snr"][0]["snr"], wr["sdr_gps_snr_glo.json"]["snr"][0]["snr"]
    assert 35 < mg < 45 and 30 < mr < 42 and mg > mr, (mg, mr)
    hb = [{"ts": now - 7200 - i * 300, "snr": 40.0 + (i % 3)} for i in range(40)]
    assert sys_base(hb, now) == 41.0 and sys_base(hb[:30], now) is None
    assert sys_mean({"g": {"R1": 30.0, "R2": 40.0}, "gn": {"R1": 1, "R2": 3}}, "R") == (37.5, 4)
    assert sys_mean({"g": "x"}, "G") == (None, 0)
    print("prepper_gps selftest ok")
    return True


if __name__ == "__main__":
    selftest()
GPSPY_EOF
cat > "$W/prepper_evlog.py" << 'EVPY_EOF'
#!/usr/bin/env python3
"""prepper_evlog: Ereignis-Log fuer prepper-sdr (nur lesen/auswerten, sendet nichts, kein Netz).

1) Stoersender/QRM, Gewitter, Dach-GPS (GPS/GLO), Trend: Ereignis oeffnet, wenn ein Band/System nicht mehr gruen ist,
   und schliesst, wenn es wieder gruen ist. Luecken < 5 min werden zusammengefasst (kein Flattern).
   Ring sdr_events.json (letzte 50 + offene), Langzeit archive/evlog/JJJJ-MM/sdr_events.jsonl (nur anhaengen, fsync).
2) KFZ-Sensoren (TPMS usw. aus dem vorhandenen rtl_433-Strom von prepper-sdr): Ring sdr_kfz.json (letzte 50, Wiedersehen,
   Tageszahlen), Langzeit archive/evlog/JJJJ-MM/kfz.jsonl + kfz_days.jsonl. IDs in voller Laenge; fremde IDs nach 30 Tagen
   aus Archiv/Ring entfernt (nur Modell + Zeit bleiben), eigene IDs (kfz_own.json, Modus 600) bleiben dauerhaft.
Eigene Sensoren eintragen:  python3 prepper_evlog.py own-add MODELL ID   (anzeigen: own-list)
"""
import json
import os
import re
import subprocess
import sys
import time

V = 1
GAP_S = 300          # Luecke < 5 min -> gleiches Ereignis
STALE_S = 1800       # offenes Ereignis nach Neustart: aelter -> geschlossen mit Hinweis
KFZ_DEB_S = 120      # gleiche Sensor-ID innerhalb 2 min = dieselbe Sichtung (Reifen senden in Salven)
KEEP_ID_S = 30 * 86400
RING = 50
RANK = {"grau": 0, "gruen": 1, "gelb": 2, "rot": 3, "trend": 2}
KFZ_RE = re.compile(r"tpms|schrader|toyota|citroen|renault|ford|hyundai|kia|jansite|abarth|elantra|pmv-?107|truck|porsche|bmw|audi|nissan|mazda|tyre|tire|steelmate|carchet|peugeot|mercedes|vw|volkswagen|honda|subaru|bosch", re.I)


def _fin(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x == x and abs(x) != float("inf")


def mon_dir(base, t):
    return os.path.join(base, "archive", "evlog", time.strftime("%Y-%m", time.localtime(t)))


def append_line(path, obj):
    """Eine JSON-Zeile anhaengen: O_APPEND, ein write, fsync (Zeile bleibt ganz oder fehlt)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    b = (json.dumps(obj, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
    try:
        os.write(fd, b)
        os.fsync(fd)
    finally:
        os.close(fd)


def write_private(path, obj):
    """Atomar mit Modus 600 schreiben (tmp + fsync + replace)."""
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, json.dumps(obj, ensure_ascii=False, indent=1).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def rewrite_lines(path, rows):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
    try:
        os.write(fd, "".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in rows).encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def read_lines(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for ln in f:
                try:
                    x = json.loads(ln)
                except Exception:
                    continue
                if isinstance(x, dict):
                    out.append(x)
    except OSError:
        pass
    return out


def iso(t):
    """Epoch -> lokale Zeit ISO 8601 mit Offset, z. B. 2026-10-12T20:51:03+02:00."""
    z = time.strftime("%z", time.localtime(t))
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(t)) + z[:3] + ":" + z[3:]


CHRONY = ["chronyc", "-c", "tracking"]


def _chrony_read():
    """chronyc -c tracking lokal lesen (Liste, ohne Shell, 3 s Zeitlimit). -> CSV-Zeile oder None; FileNotFoundError = fehlt."""
    pr = subprocess.Popen(CHRONY, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    try:
        out, _ = pr.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        pr.kill()
        pr.communicate()
        return None
    return out.decode("utf-8", "replace").strip().splitlines()[0] if pr.returncode == 0 and out.strip() else None


def parse_tracking(line):
    f = (line or "").split(",")
    if len(f) < 14:
        return None
    try:
        st, off, rd, rdisp = int(f[2]), float(f[4]), float(f[10]), float(f[11])
    except ValueError:
        return None
    err = abs(off) + rd / 2.0 + rdisp
    sync = 1 <= st <= 15 and f[13].strip().lower().startswith("normal")
    return {"s": st, "ref": f[1][:40] or f[0][:16], "off": round(off, 6), "err": round(err, 6), "sync": bool(sync and err < 0.5)}


class TimeQ:
    """Zeitqualitaet je Datensatz: Stratum, Referenz, Offset, geschaetzter Fehler, sync. Cache 60 s, letzter guter Wert bleibt."""

    def __init__(self, reader=None):
        self.reader, self.t, self.v, self.good = reader or _chrony_read, None, None, None

    def get(self, now=None):
        now = now or time.time()
        if self.v is not None and self.t is not None and 0 <= now - self.t < 60:
            return self.v
        self.t = now
        try:
            q = parse_tracking(self.reader())
            if q:
                self.good, self.v = dict(q, t=int(now)), q
            elif self.good:
                self.v = dict(self.good, sync=False, alt=int(now - self.good["t"]))
            else:
                self.v = {"sync": False, "na": "chronyc ohne Antwort"}
        except FileNotFoundError:
            self.v = {"sync": False, "na": "nicht installiert"}
        except Exception as ex:
            self.v = dict(self.good, sync=False, alt=int(now - self.good["t"])) if self.good else {"sync": False, "na": str(ex)[:60]}
        return self.v


def badge(q):
    q = q or {}
    return ("S%d" % q["s"]) if q.get("sync") and _fin(q.get("s")) else "ungenau"


def _mhz(f):
    return round(f / 1e6, 3) if _fin(f) and f > 1e5 else f


# ------------------------------------------------------------------ Ereignisse Funkumgebung
def derive(st):
    """Status -> {key: {band, kind, grp, lvl, delta, info}} fuer alles, was gerade nicht gruen ist."""
    cur = {}
    nz = (st or {}).get("noise") or {}
    for b in nz.get("bands") or []:
        if not isinstance(b, dict) or not b.get("ok") or b.get("learning"):
            continue
        bid, nm = str(b.get("id")), b.get("short") or b.get("id")
        if b.get("lvl") in ("gelb", "rot"):
            cur[bid + "|floor"] = {"band": nm, "kind": "Rauschboden", "grp": "qrm", "lvl": b["lvl"], "delta": b.get("raise") if _fin(b.get("raise")) else None}
        cars = [c for c in (b.get("cars") or []) if isinstance(c, dict)]
        if (b.get("n_pers") or 0) > 0 and cars:
            top = max(cars, key=lambda c: c.get("db") if _fin(c.get("db")) else -99)
            cur[bid + "|car"] = {"band": nm, "kind": "Träger", "grp": "qrm", "lvl": "gelb", "delta": top.get("db") if _fin(top.get("db")) else None,
                                 "info": "%s MHz" % _mhz(top.get("f"))}
        tr = b.get("trend") or {}
        if isinstance(tr, dict) and tr.get("on"):
            cur[bid + "|trend"] = {"band": nm, "kind": "Trend", "grp": "qrm", "lvl": "trend", "delta": tr.get("e") if _fin(tr.get("e")) else None}
    th = nz.get("thunder") or {}
    if isinstance(th, dict) and th.get("lvl") in ("gelb", "rot"):
        cur["thunder"] = {"band": "MW", "kind": "Gewitter", "grp": "thunder", "lvl": th["lvl"], "delta": None,
                          "info": ("%s Impulse/min" % th.get("bb_pm")) if _fin(th.get("bb_pm")) else None}
    g = (st or {}).get("gps") or {}
    if isinstance(g, dict) and g.get("ok") and g.get("lvl") in ("gelb", "rot"):
        cls = g.get("cls")
        band, kind = {"breitbandig": ("GPS+GLO", "GPS breitbandig"), "L1-schmalbandig": ("GPS", "L1"), "GLONASS": ("GLO", "GLONASS"),
                      "GPS": ("GPS", "GPS")}.get(cls, ("GPS", "Signal/Fix"))
        drops = [x.get("drop") for x in (g.get("G"), g.get("R"), g) if isinstance(x, dict) and _fin(x.get("drop"))]
        cur["gps|" + kind] = {"band": band, "kind": kind, "grp": "qrm", "lvl": g["lvl"], "delta": -max(drops) if drops else None, "info": g.get("why")}
    return cur


class EvLog:
    def __init__(self, base, load_json, write_json, log=lambda *a: None, now=None, tq=None):
        self.base, self.write_json, self.log = base, write_json, log
        self.tq = tq or TimeQ()
        self.f = os.path.join(base, "sdr_events.json")
        d = load_json(self.f, None) or {}
        d = d if isinstance(d, dict) else {}
        now = now or time.time()
        self.open = {k: v for k, v in (d.get("open") or {}).items() if isinstance(v, dict) and _fin(v.get("start"))}
        self.pend = {k: v for k, v in (d.get("pend") or {}).items() if isinstance(v, dict) and _fin(v.get("start")) and _fin(v.get("end"))}
        self.last = [x for x in (d.get("last") or []) if isinstance(x, dict) and _fin(x.get("start"))][-RING:]
        self.n = int(d.get("n") or 0) if _fin(d.get("n")) else 0
        self.dirty, self.saved = False, 0
        for k in list(self.open):
            e = self.open[k]
            if now - (e.get("last") or e["start"]) > STALE_S or now < e["start"]:
                e["end"], e["note"], e["end_tq"] = e.get("last") or e["start"], "Ende geschätzt (Neustart/Ausfall)", {"sync": False, "na": "Ende geschätzt"}
                self.pend[k] = self.open.pop(k)
                self.dirty = True

    def _final(self, e):
        e["dur"] = max(0, int(e["end"] - e["start"]))
        e["start_iso"], e["end_iso"] = iso(e["start"]), iso(e["end"])
        if "end_tq" not in e:
            e["end_tq"] = self.tq.get()
        e["ungenau"] = not ((e.get("start_tq") or {}).get("sync") and (e.get("end_tq") or {}).get("sync"))
        self.last = (self.last + [e])[-RING:]
        self.n += 1
        try:
            append_line(os.path.join(mon_dir(self.base, e["start"]), "sdr_events.jsonl"), e)
        except Exception as ex:
            self.log("Ereignis-Archiv:", ex)

    def update(self, st, now=None):
        now = int(now or time.time())
        cur = derive(st)
        for k, x in cur.items():
            e = self.open.get(k)
            if e is None and k in self.pend and 0 <= now - self.pend[k]["end"] < GAP_S:
                e = self.pend.pop(k)
                e.pop("end", None)
                e.pop("end_tq", None)
                e.pop("note", None)
                e["merged"] = int(e.get("merged") or 0) + 1
                self.open[k] = e
            if e is None:
                e = self.open[k] = {"key": k, "band": x["band"], "kind": x["kind"], "grp": x["grp"], "lvl": x["lvl"], "delta": x.get("delta"),
                                    "start": now, "start_iso": iso(now), "last": now, "start_tq": self.tq.get(now)}
                if x.get("info"):
                    e["info"] = x["info"]
            else:
                if RANK.get(x["lvl"], 0) > RANK.get(e.get("lvl"), 0):
                    e["lvl"] = x["lvl"]
                dv = x.get("delta")
                if _fin(dv) and (not _fin(e.get("delta")) or abs(dv) > abs(e["delta"])):
                    e["delta"] = dv
                    if x.get("info"):
                        e["info"] = x["info"]
                e["last"] = now
            self.dirty = True
        for k in [k for k in self.open if k not in cur]:
            e = self.open.pop(k)
            e["end"], e["end_tq"] = now, self.tq.get(now)
            self.pend[k] = e
            self.dirty = True
        for k in [k for k, e in self.pend.items() if now - e["end"] >= GAP_S or now < e["start"]]:
            self._final(self.pend.pop(k))
            self.dirty = True
        if self.dirty and (now - self.saved >= 60 or now < self.saved) or (self.open and now - self.saved >= 300):
            self.save(now)
        return cur

    def save(self, now=None):
        self.write_json(self.f, {"v": V, "t": int(now or time.time()), "open": self.open, "pend": self.pend, "last": self.last, "n": self.n})
        self.dirty, self.saved = False, int(now or time.time())


# ------------------------------------------------------------------ KFZ-Sensoren
def is_kfz(raw):
    if not isinstance(raw, dict):
        return False
    return str(raw.get("type") or "").upper() == "TPMS" or bool(KFZ_RE.search(str(raw.get("model") or "")))


def own_path(base):
    return os.path.join(base, "kfz_own.json")


def own_load(base):
    try:
        with open(own_path(base), encoding="utf-8") as f:
            d = json.load(f)
    except Exception:
        return set()
    return {(str(x.get("model")), str(x.get("id"))) for x in (d.get("own") or []) if isinstance(x, dict) and x.get("model") and x.get("id") is not None}


OWN_MAX = 200
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,39}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,23}$")


def own_set(base, model, sid, on=True):
    """Eintrag setzen/entfernen; prueft Format + Laenge + Listenobergrenze. -> (ok, text, anzahl)"""
    model, sid = str(model or "").strip(), str(sid if sid is not None else "").strip()
    if not MODEL_RE.match(model) or not ID_RE.match(sid):
        return False, "Modell/ID ungueltig", None
    s = own_load(base)
    if on:
        if (model, sid) not in s and len(s) >= OWN_MAX:
            return False, "Liste voll (%d)" % OWN_MAX, len(s)
        s.add((model, sid))
    else:
        s.discard((model, sid))
    write_private(own_path(base), {"own": [{"model": m, "id": i} for m, i in sorted(s)], "hinweis": "eigene KFZ-Sensoren: ID bleibt dauerhaft, Anzeige 'eigen'"})
    return True, "eigen" if on else "entfernt", len(s)


def own_add(base, model, sid):
    ok, txt, n = own_set(base, model, sid, True)
    if not ok:
        raise ValueError(txt)
    return n


def _press(raw):
    for k, fac in (("pressure_kPa", 0.01), ("pressure_bar", 1.0), ("pressure_PSI", 0.0689476), ("pressure_psi", 0.0689476)):
        if _fin(raw.get(k)):
            return round(raw[k] * fac, 2)
    return None


class KfzLog:
    def __init__(self, base, load_json, write_json, log=lambda *a: None, tq=None):
        self.base, self.write_json, self.log = base, write_json, log
        self.tq = tq or TimeQ()
        self.f = os.path.join(base, "sdr_kfz.json")
        d = load_json(self.f, None) or {}
        d = d if isinstance(d, dict) else {}
        self.last = [x for x in (d.get("last") or []) if isinstance(x, dict) and _fin(x.get("t"))][-RING:]
        self.seen = {k: v for k, v in (d.get("seen") or {}).items() if isinstance(v, dict) and _fin(v.get("t"))}
        self.days = {k: v for k, v in (d.get("days") or {}).items() if isinstance(v, dict)}
        td = d.get("today") if isinstance(d.get("today"), dict) else {}
        self.today = {"d": td.get("d"), "n": int(td.get("n") or 0), "u": list(td.get("u") or [])[:5000]}
        self.pruned = str(d.get("pruned") or "")
        self.n = int(d.get("n") or 0) if _fin(d.get("n")) else 0
        self.own, self.own_m = set(), None
        self.dirty, self.saved = False, 0

    def _own(self):
        try:
            m = os.stat(own_path(self.base)).st_mtime
        except OSError:
            m = None
        if m != self.own_m:
            self.own, self.own_m = own_load(self.base), m
        return self.own

    def _day(self, now):
        ds = time.strftime("%Y-%m-%d", time.localtime(now))
        if self.today.get("d") != ds:
            if self.today.get("d"):
                rec = {"d": self.today["d"], "n": self.today["n"], "sensoren": len(set(self.today["u"]))}
                self.days[self.today["d"]] = {"n": rec["n"], "sensoren": rec["sensoren"]}
                self.days = dict(sorted(self.days.items())[-62:])
                try:
                    append_line(os.path.join(self.base, "archive", "evlog", self.today["d"][:7], "kfz_days.jsonl"), rec)
                except Exception as ex:
                    self.log("KFZ-Tageszahl:", ex)
            self.today = {"d": ds, "n": 0, "u": []}

    def add(self, raw, now=None):
        if not is_kfz(raw):
            return None
        now = int(now or time.time())
        model, sid = str(raw.get("model") or "?")[:40], raw.get("id")
        sid = None if sid is None else str(sid)[:24]
        key = "%s|%s" % (model, sid if sid is not None else "-")
        own = sid is not None and (model, sid) in self._own()
        s = self.seen.get(key)
        self._day(now)
        if s and 0 <= now - s["t"] < KFZ_DEB_S:
            s["t"] = now
            if self.last and self.last[-1].get("key") == key:
                for k, v in (("p_bar", _press(raw)), ("temp_C", raw.get("temperature_C")), ("rssi", raw.get("rssi"))):
                    if _fin(v):
                        self.last[-1][k] = v
            return None
        s = self.seen[key] = {"n": (s or {}).get("n", 0) + 1, "first": (s or {}).get("first", now), "t": now, "model": model, "own": own}
        rec = {"t": now, "t_iso": iso(now), "key": key, "model": model, "type": str(raw.get("type") or "")[:16] or None, "id": sid, "own": own, "n": s["n"]}
        for k, v in (("p_bar", _press(raw)), ("temp_C", raw.get("temperature_C")), ("rssi", raw.get("rssi"))):
            if _fin(v):
                rec[k] = v
        rec["tq"] = self.tq.get(now)
        rec["ungenau"] = not rec["tq"].get("sync")
        self.last = (self.last + [rec])[-RING:]
        self.n += 1
        self.today["n"] += 1
        if key not in self.today["u"] and len(self.today["u"]) < 5000:
            self.today["u"].append(key)
        try:
            append_line(os.path.join(mon_dir(self.base, now), "kfz.jsonl"), rec)
        except Exception as ex:
            self.log("KFZ-Archiv:", ex)
        self.dirty = True
        return rec

    def prune(self, now=None):
        """Fremde IDs aelter 30 Tage: im Ring + Archiv nur Modell + Zeit behalten. Eigene bleiben. Einmal je Tag."""
        now = int(now or time.time())
        ds = time.strftime("%Y-%m-%d", time.localtime(now))
        self._day(now)
        cut, own, n = now - KEEP_ID_S, self._own(), 0

        def strip(r):
            if r.get("own") or (r.get("model"), r.get("id")) in own or r.get("id") is None:
                return r, 0
            return {"t": r.get("t"), "t_iso": r.get("t_iso"), "tq": r.get("tq"), "ungenau": r.get("ungenau"), "model": r.get("model"), "type": r.get("type"), "own": False, "id_entfernt": True}, 1
        nl = []
        for r in self.last:
            if (r.get("t") or 0) < cut:
                r, k = strip(r)
                n += k
            nl.append(r)
        self.last = nl
        for k in [k for k, v in self.seen.items() if v.get("t", 0) < cut and not v.get("own") and tuple(k.split("|", 1)) not in own]:
            del self.seen[k]
            n += 1
        if self.pruned != ds:
            root = os.path.join(self.base, "archive", "evlog")
            try:
                mons = sorted(m for m in os.listdir(root) if re.match(r"^\d{4}-\d{2}$", m))
            except OSError:
                mons = []
            for m in mons:
                fp = os.path.join(root, m, "kfz.jsonl")
                rows = read_lines(fp)
                if not rows or not any((r.get("t") or 0) < cut and r.get("id") is not None for r in rows):
                    continue
                out, ch = [], 0
                for r in rows:
                    if (r.get("t") or 0) < cut:
                        r, k = strip(r)
                        ch += k
                    out.append(r)
                if ch:
                    rewrite_lines(fp, out)
                    n += ch
            self.pruned = ds
            self.dirty = True
        if n:
            self.dirty = True
        return n

    def save(self, force=False, now=None):
        now = int(now or time.time())
        if self.dirty and (force or now - self.saved >= 60 or now < self.saved):
            self.write_json(self.f, {"v": V, "t": now, "last": self.last, "seen": dict(sorted(self.seen.items(), key=lambda kv: kv[1]["t"])[-3000:]),
                                     "days": self.days, "today": self.today, "pruned": self.pruned, "n": self.n})
            self.dirty, self.saved = False, now


# ------------------------------------------------------------------ Selbsttest
def selftest():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="evlog-") as tmp:
        _selftest(tmp)
    print("prepper_evlog selftest ok")


def _selftest(tmp):
    W = {}

    def wj(p, d):
        json.dumps(d, allow_nan=False)
        W[p] = json.loads(json.dumps(d))

    def lj(p, dflt):
        return W.get(p, dflt)
    t0 = 179 * 10 ** 7
    st_g = {"noise": {"bands": [{"id": "n433", "short": "433", "ok": True, "lvl": "gruen", "learning": False, "cars": [], "trend": {"on": False}}],
                      "thunder": {"lvl": "gruen"}}, "gps": {"ok": True, "lvl": "gruen"}}

    def st_bad(raise_db, car=False, gps=None):
        b = {"id": "n433", "short": "433", "ok": True, "lvl": "rot" if raise_db > 10 else "gelb", "raise": raise_db, "learning": False,
             "n_pers": 1 if car else 0, "cars": [{"f": 433920000, "db": 14.0}] if car else [], "trend": {"on": False}}
        s = {"noise": {"bands": [b], "thunder": {"lvl": "gruen"}}, "gps": {"ok": True, "lvl": "gruen"}}
        if gps:
            s["gps"] = {"ok": True, "lvl": "rot", "cls": gps, "G": {"drop": 11.0}, "R": {"drop": 12.5}}
        return s
    GOOD = "C0A8B20F,192.168.178.15,2,1791830000.1,0.000012,0.000020,0.000030,-1.2,0.001,0.02,0.000400,0.000300,64.0,Normal"
    BAD = "00000000,,0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,1.0,1.0,0.0,Not synchronised"
    assert parse_tracking(GOOD) == {"s": 2, "ref": "192.168.178.15", "off": 1.2e-05, "err": 0.000512, "sync": True}, parse_tracking(GOOD)
    assert parse_tracking(BAD)["sync"] is False and parse_tracking("kaputt") is None
    src = [GOOD]
    tq = TimeQ(lambda: src[0])
    assert badge(tq.get(t0)) == "S2"
    src[0] = None
    assert tq.get(t0 + 30)["sync"] and tq.get(t0 + 61)["sync"] is False and tq.v["alt"] == 61   # Cache 60 s, dann letzter guter Wert (alt) = ungenau

    def nochrony():
        raise FileNotFoundError("chronyc")
    q = TimeQ(nochrony).get(t0)
    assert q == {"sync": False, "na": "nicht installiert"} and badge(q) == "ungenau"
    src[0] = GOOD
    tq = TimeQ(lambda: src[0])
    e = EvLog(tmp, lj, wj, now=t0, tq=tq)
    e.update(st_g, t0)
    e.update(st_bad(6), t0 + 60)
    e.update(st_bad(12, car=True), t0 + 960)
    e.update(st_g, t0 + 1860)            # gruen -> pend
    e.update(st_bad(7), t0 + 1980)       # nach 2 min wieder -> zusammengefasst
    e.update(st_g, t0 + 2880)
    e.update(st_g, t0 + 3300)            # >5 min gruen -> abgeschlossen
    fl = [x for x in e.last if x["key"] == "n433|floor"]
    assert len(fl) == 1 and fl[0]["merged"] == 1 and fl[0]["lvl"] == "rot" and fl[0]["delta"] == 12 and fl[0]["start"] == t0 + 60 and fl[0]["end"] == t0 + 2880, e.last
    assert fl[0]["dur"] == 2820 and any(x["kind"] == "Träger" and x["info"] == "433.92 MHz" and x["delta"] == 14.0 for x in e.last), e.last
    arch = read_lines(os.path.join(mon_dir(tmp, t0 + 60), "sdr_events.jsonl"))
    assert len(arch) == 2 and not e.open and not e.pend, (arch, e.open, e.pend)
    # GPS breitbandig, Gewitter, Trend
    s = st_bad(3, gps="breitbandig")
    s["noise"]["bands"][0]["lvl"], s["noise"]["bands"][0]["trend"] = "gruen", {"on": True, "e": 2.5}
    s["noise"]["thunder"] = {"lvl": "gelb", "bb_pm": 900}
    c = e.update(s, t0 + 4000)
    assert set(c) == {"gps|GPS breitbandig", "thunder", "n433|trend"} and c["gps|GPS breitbandig"]["delta"] == -12.5 and c["thunder"]["grp"] == "thunder", c
    e.save(t0 + 4000)
    # Neustart: frisch -> bleibt offen; alt -> geschlossen mit Hinweis
    assert fl[0]["start_tq"]["s"] == 2 and fl[0]["ungenau"] is False, fl[0]
    e2 = EvLog(tmp, lj, wj, now=t0 + 4100)
    assert len(e2.open) == 3
    e3 = EvLog(tmp, lj, wj, now=t0 + 4000 + STALE_S + 10)
    assert not e3.open and all(x["note"].startswith("Ende geschätzt") for x in e3.pend.values())
    e3.update(st_g, t0 + 4000 + STALE_S + 400)
    assert len(e3.last) == 5 and e3.n == 5, e3.last
    # kaputte Ringdatei
    W[os.path.join(tmp, "sdr_events.json")] = {"open": {"x": "kaputt", "y": {"start": float("nan")}}, "last": ["x", None]}
    assert not EvLog(tmp, lj, wj, now=t0).open
    for _ in range(80):
        e3._final({"key": "x", "band": "433", "kind": "Rauschboden", "grp": "qrm", "lvl": "gelb", "start": t0, "end": t0 + 1})
    assert len(e3.last) == RING
    # KFZ: volle IDs, Wiedersehen, Entprellen, Tageszahl, eigen, 30-Tage-Bereinigung
    k = KfzLog(tmp, lj, wj, tq=TimeQ(lambda: BAD))
    tp = {"model": "Schrader-EG53MA4", "type": "TPMS", "id": "1A2B3C4D", "pressure_kPa": 230.0, "temperature_C": 18.0, "rssi": -11.2}
    assert k.add({"model": "Nexus-TH", "id": 177, "temperature_C": 12.0}, t0) is None   # Haussensor: nicht im KFZ-Log
    r = k.add(tp, t0)
    assert r["id"] == "1A2B3C4D" and r["p_bar"] == 2.3 and r["n"] == 1 and not r["own"] and r["ungenau"] and r["tq"]["s"] == 0, r
    assert k.add(tp, t0 + 30) is None                     # gleiche Salve
    r = k.add(dict(tp), t0 + 3600)
    assert r["n"] == 2
    own_add(tmp, "Toyota", "0xABC")
    assert oct(os.stat(own_path(tmp)).st_mode & 0o777) == "0o600"
    r = k.add({"model": "Toyota", "type": "TPMS", "id": "0xABC", "pressure_PSI": 33.0}, t0 + 3700)
    assert r["own"] and r["p_bar"] == 2.28, r
    k.add({"model": "Toyota", "type": "TPMS", "id": "0xABC"}, t0 + 86400)
    assert k.days and list(k.days.values())[0] == {"n": 3, "sensoren": 2}, k.days
    n = k.prune(t0 + KEEP_ID_S + 7200)
    rows = read_lines(os.path.join(mon_dir(tmp, t0), "kfz.jsonl"))
    assert n >= 2 and all(x.get("id") is None for x in rows if x.get("model") == "Schrader-EG53MA4") and all(x.get("t") for x in rows), rows
    assert all(x.get("id") == "0xABC" for x in rows if x.get("model") == "Toyota"), rows
    assert all(x.get("id") is None for x in k.last if x.get("model") == "Schrader-EG53MA4") and "Schrader-EG53MA4|1A2B3C4D" not in k.seen
    assert "1A2B3C4D" not in json.dumps(rows) and "1A2B3C4D" not in json.dumps({"l": k.last, "s": k.seen})
    k.save(True, t0 + KEEP_ID_S + 7200)
    assert all(read_lines(os.path.join(tmp, "archive", "evlog", m, "kfz.jsonl")) is not None for m in os.listdir(os.path.join(tmp, "archive", "evlog")))
    assert not own_set(tmp, "Toy ota", "1")[0] and not own_set(tmp, "Toyota", "x" * 30)[0] and not own_set(tmp, "", "1")[0]
    assert own_set(tmp, "Toyota", "0xABC", False)[2] == 0 and own_load(tmp) == set()
    for i in range(OWN_MAX):
        own_set(tmp, "Ford", "id%d" % i)
    assert not own_set(tmp, "Ford", "zuviel")[0] and own_set(tmp, "Ford", "id5")[0]
    ev0 = read_lines(os.path.join(mon_dir(tmp, t0 + 60), "sdr_events.jsonl"))[0]
    assert re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$", ev0["start_iso"]) and rows[0]["t_iso"], (ev0, rows[0])
    assert is_kfz({"model": "Citroen", "id": 5}) and not is_kfz({"model": "Fineoffset-WH24"}) and not is_kfz("x")


def main(argv):
    base = os.path.dirname(os.path.abspath(__file__))
    if len(argv) >= 4 and argv[1] == "own-add":
        print("kfz_own.json: %d eigene Sensoren (%s)" % (own_add(base, argv[2], argv[3]), own_path(base)))
    elif len(argv) >= 2 and argv[1] == "own-list":
        for m, i in sorted(own_load(base)):
            print("eigen", m, i)
    elif len(argv) >= 2 and argv[1] == "selftest":
        selftest()
    else:
        print("Aufruf: prepper_evlog.py own-add MODELL ID | own-list | selftest")


if __name__ == "__main__":
    main(sys.argv)
EVPY_EOF

# ---------- 0) Bytes + AST-Guards + Selbsttest ----------
P="$W/patch-br24-warn2.py"; M="$W/prepper_sdr.py"; N="$W/prepper_sdr_net.py"; G="$W/prepper_gps.py"; E="$W/prepper_evlog.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $M" | sha256sum -c - >/dev/null || { echo "STOP: Modul sha256 falsch"; exit 1; }
echo "$EXPECT_NET  $N" | sha256sum -c - >/dev/null || { echo "STOP: Netzmodul sha256 falsch"; exit 1; }
echo "$EXPECT_GPS  $G" | sha256sum -c - >/dev/null || { echo "STOP: GPS-Modul sha256 falsch"; exit 1; }
echo "$EXPECT_EV  $E" | sha256sum -c - >/dev/null || { echo "STOP: evLog-Modul sha256 falsch"; exit 1; }
for x in "$P" "$M" "$N" "$G" "$E"; do python3 -W error -m py_compile "$x" || { echo "STOP: py_compile $x - nichts geaendert"; exit 1; }; done
set +e
python3 - "$P" "$M" "$N" "$G" "$E" << 'GUARDPY'
import ast, pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK":
        blk = n.value.value
if not blk:
    raise SystemExit(4)
hit = False
NET = ("requests", "urllib", "socket", "socketserver", "http", "meshtastic", "subprocess", "asyncio", "ssl")
RANGES = {"ism433": (433.05, 434.79), "srd868": (863.0, 870.0), "aprs": (144.8, 144.8), "fm": (87.5, 108.0), "dab": (174.0, 240.0), "wxsat": (137.0, 138.0),
          "act2m": (145.5, 145.5), "pmr446": (446.0, 446.2),
          "noise_mw": (0.5, 1.6), "noise_hf": (9.9, 10.2), "noise2m": (144.0, 146.0), "noisefm": (87.5, 108.0), "noisedab": (174.0, 240.0),
          "noisepmr": (446.0, 446.2), "noise433": (433.05, 434.79), "noise868": (863.0, 870.0), "noisegps": (1573.42, 1577.42)}
def fname(f):
    return f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
def in_ranges(mhz):
    return any(lo - 1e-9 <= mhz <= hi + 1e-9 for lo, hi in RANGES.values())
FRE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*(M|MHz|e6)\s*$")
def bad_common(code, who):
    h = False
    low = code.lower()
    for bad in ("multimon", "pocsag", "rpitx", "hackrf_transfer", "sendiq", "ptt gpio", "ptt /dev", "igserver", "pbeacon", "serve_forever", "socketserver"):
        if bad in low:
            print(who, "verboten:", bad); h = True
    if "FLEX" in code:
        print(who, "verboten: FLEX"); h = True
    tree = ast.parse(code)
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if "173." in node.value:
                print(who, "verboten: 173.x"); h = True
            m = FRE.match(node.value)
            if m and not in_ranges(float(m.group(1))):
                print(who, "Frequenz ausserhalb Whitelist:", node.value); h = True
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
            v = float(node.value)
            if 1e7 <= v <= 3e9 and not in_ranges(v / 1e6):
                print(who, "Zahl wie Frequenz ausserhalb Whitelist:", v); h = True
            if 173.0 <= v < 174.0:
                print(who, "verboten: 173.x"); h = True
        if isinstance(node, ast.keyword) and node.arg == "shell":
            print(who, "shell="); h = True
        if isinstance(node, ast.Call) and fname(node.func) in ("bind", "listen", "accept", "serve_forever", "create_server", "start_server"):
            print(who, "Server-Aufruf", fname(node.func)); h = True
    return h, tree
h, btree = bad_common(blk, "Block")
hit |= h
for node in ast.walk(btree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in NET:
                print("Block: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        fn = fname(node.func)
        if fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("open", "update_all", "urlopen", "Popen", "system", "call", "run", "remove", "unlink", "rmtree", "write_json", "write_text", "set_mode"):
            print("Block: verbotener Aufruf", fn); hit = True
# br24Warn: nur lesen/anzeigen - keine POST-Route, keine Schreibstelle, kein Netz; flask request nur fuer den Pfad im after_request
blk_chk = blk.replace("from flask import request as _br24_rq", "").replace("_br24_rq.path", "").replace("app.after_request_funcs", "").replace("app.after_request(_br24_after)", "")
for bad in ("mesh", "Mesh", "<input", "'input'", '"input"', "freq", "frequency", "range(", "POST", "request", "method:", "methods=['POST']", "urlopen", "socket", "write_", "os.replace"):
    if bad in blk_chk:
        print("Block enthaelt", bad); hit = True
for node in ast.walk(btree):
    if isinstance(node, ast.Call) and fname(node.func) == "add_url_rule":
        kws = {k.arg: k.value for k in node.keywords}
        if "methods" not in kws or ast.literal_eval(kws["methods"]) != ["GET"]:
            print("Block: Route nicht nur GET"); hit = True
# lageMesh1: einzige Mesh-Sendestelle = Klick-Handler _lm1_send_post (POST, gleicher Ursprung, confirm, Sperrzeit) -> send_meshtastic(text, channel=0)
lm1 = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "BLOCK_LM1":
        lm1 = n.value.value
if not lm1:
    print("lageMesh1-Block fehlt"); hit = True
else:
    h, ltree = bad_common(lm1, "lageMesh1")
    hit |= h
    lown = {}
    for fn_node in ast.walk(ltree):
        if isinstance(fn_node, ast.FunctionDef):
            for sub in ast.walk(fn_node):
                lown[id(sub)] = fn_node.name
    sends, routes, refs = [], [], 0
    for node in ast.walk(ltree):
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for a in node.names:
                if (getattr(node, "module", None) or a.name).split(".")[0] not in ("threading", "time", "flask"):
                    print("lageMesh1: Import", a.name); hit = True
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "_lm1_threading" and node.attr != "Lock":
            print("lageMesh1: threading.%s" % node.attr); hit = True
        if isinstance(node, ast.Call):
            fn = fname(node.func)
            if fn == "send_meshtastic":
                sends.append(node)
                kw = {k.arg: k.value for k in node.keywords}
                if lown.get(id(node)) != "_lm1_send_post" or len(node.args) != 1 or getattr(node.args[0], "id", None) != "text" or set(kw) != {"channel"} or getattr(kw["channel"], "value", None) != 0:
                    print("lageMesh1: send_meshtastic ausserhalb Klick-Handler oder nicht text/Kanal 0"); hit = True
            elif fn.startswith(("send", "maybe_mesh", "fetch", "save", "record")) or fn in ("open", "urlopen", "Popen", "system", "call", "run", "remove", "unlink", "rmtree", "write_json", "write_text", "Thread", "Timer", "start", "set_mode", "post", "get_json_send"):
                print("lageMesh1: verbotener Aufruf", fn); hit = True
            if fn == "add_url_rule":
                kws = {k.arg: k.value for k in node.keywords}
                routes.append((node.args[0].value, getattr(kws.get("view_func"), "id", None), ast.literal_eval(kws["methods"])))
        if isinstance(node, ast.Name) and node.id == "_lm1_send_post":
            refs += 1
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and ("://" in node.value or "requests" in node.value or "5001" in node.value or "5002" in node.value):
            print("lageMesh1: Adresse/requests im Text"); hit = True
    if len(sends) != 1:
        print("lageMesh1: %d Sendestellen statt 1" % len(sends)); hit = True
    if sorted(routes) != [("/api/lage_mesh1", "_lm1_api", ["GET"]), ("/api/lage_mesh1/send", "_lm1_send_post", ["POST"])]:
        print("lageMesh1: Routen", routes); hit = True
    if refs != 1:
        print("lageMesh1: Klick-Handler %d mal benutzt (nur Route erlaubt)" % refs); hit = True
    js = lm1[lm1.index("_LM1_JS = r"):lm1.index("def _lm1_after")]
    if js.count("method:'POST'") != 1 or js.count("fetch('/api/lage_mesh1/send'") != 1 or js.index("window.confirm(") > js.index("fetch('/api/lage_mesh1/send'") or "addEventListener('click'" not in js:
        print("lageMesh1: JS sendet nicht nur nach Klick + confirm"); hit = True
    if re.sub(r"[A-Za-z_]go\(", "", js).count("go(") != 2 or js.count("function go(") != 1 or js.count("addEventListener('click',function(){go(src,b,st);})") != 1:
        print("lageMesh1: go() nicht nur im Klick-Handler"); hit = True
    for bad in ("maybe_mesh", "mesh2", "channel=1", "before_first_request", "atexit"):
        if bad in lm1:
            print("lageMesh1 enthaelt", bad); hit = True
mod = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
h, tree = bad_common(mod, "Modul")
hit |= h
ALLOWED = {"rtl_433", "rtl_fm", "rtl_tcp", "direwolf", "rtl_sdr", "rtl_test", "rtl_power"}
TOOLS = {"redsea", "welle", "satdump"}
owner = {}
consts = {}
for fn_node in ast.walk(tree):
    if isinstance(fn_node, ast.FunctionDef):
        for sub in ast.walk(fn_node):
            owner[id(sub)] = fn_node.name
for n in tree.body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("F_RANGES", "DAB_CHANNELS", "PRESETS"):
        consts[n.targets[0].id] = ast.literal_eval(n.value)
if consts.get("F_RANGES") != RANGES:
    print("Modul: F_RANGES veraendert"); hit = True
for k, v in (consts.get("DAB_CHANNELS") or {}).items():
    if not (174.0 <= v <= 240.0):
        print("Modul: DAB-Kanal ausserhalb Band III", k); hit = True
for x in consts.get("PRESETS") or [print("Modul: PRESETS fehlt")]:
    k = x.get("kind")
    if k == "dab":
        ok = x.get("ch") in (consts.get("DAB_CHANNELS") or {})
    else:
        m = FRE.match(str(x.get("f")))
        lo, hi = RANGES.get(k, (1, 0))
        ok = bool(m) and lo - 1e-9 <= float(m.group(1)) <= hi + 1e-9
    if not ok:
        print("Modul: Preset ausserhalb", x); hit = True
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name).split(".")[0] in ("requests", "urllib", "socket", "socketserver", "http", "meshtastic", "asyncio", "ssl"):
                print("Modul: verbotener Import", a.name); hit = True
    if isinstance(node, ast.Call):
        fn = fname(node.func)
        where = owner.get(id(node))
        if fn == "rmtree" and where == "_clean_tmp":
            pass
        elif fn == "remove" and where in ("_prune_meteor", "prune", "_cal_trigger"):
            pass
        elif fn.startswith(("send", "maybe_mesh")) or fn in ("system", "popen", "call", "check_output", "check_call", "run", "rmtree", "unlink", "remove", "execv", "execvp"):
            print("Modul: verbotener Aufruf", fn, "in", where); hit = True
        if fn == "tool" and not (node.args and isinstance(node.args[0], ast.Constant) and node.args[0].value in TOOLS):
            print("Modul: tool() mit", ast.dump(node.args[0]) if node.args else "-"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "rtl_sdr":
        if owner.get(id(node)) != "_cmd_act":
            print("Modul: rtl_sdr ausserhalb _cmd_act"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "rtl_power":
        if owner.get(id(node)) != "_cmd_noise":
            print("Modul: rtl_power ausserhalb _cmd_noise"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "rtl_fm":
        vals = [getattr(e, "value", None) for e in node.elts]
        if "raw" in vals and (owner.get(id(node)) != "_cmd_noise" or vals[1:5] != ["-M", "raw", "-E", "direct2"]):
            print("Modul: rtl_fm raw ausserhalb _cmd_noise"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "rtl_test":
        if owner.get(id(node)) != "list_sticks" or [getattr(e, "value", None) for e in node.elts] != ["rtl_test", "-d", "prepper-nur-liste"]:
            print("Modul: rtl_test nicht nur als Liste"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "rtl_tcp" and owner.get(id(node)) == "_cmd_dab":
        if [getattr(e, "value", None) for e in node.elts[1:3]] != ["-a", "127.0.0.1"]:
            print("Modul: rtl_tcp fuer DAB nicht nur 127.0.0.1"); hit = True
    if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) and isinstance(node.elts[0].value, str):
        v = node.elts[0].value
        if v.startswith(("rtl", "direwolf", "rpitx", "hackrf", "sendiq", "tx", "multimon", "redsea", "welle", "satdump")) and v not in ALLOWED:
            print("Modul: Programm", v); hit = True
dv = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_dev"]
if not dv or any(isinstance(c, ast.Subscript) and isinstance(c.value, ast.Attribute) and c.value.attr == "cfg" for c in ast.walk(dv[0])) or "device" in ast.dump(dv[0]):
    print("Modul: _dev nutzt nicht nur den aufgeloesten Stick"); hit = True
ca = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_cmd_act"]
if ca and not any(isinstance(c, ast.List) and c.elts and isinstance(c.elts[-1], ast.Constant) and c.elts[-1].value == "-" for c in ast.walk(ca[0])):
    print("Modul: rtl_sdr nicht nur nach stdout"); hit = True
ar = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in ("_act_reader", "feed", "_record", "_noise_reader", "feed_power", "feed_iq", "_flush_hops", "result")]
cn = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_cmd_noise"]
if not cn or not any(isinstance(c, ast.Call) and fname(c.func) == "check_tune" for c in ast.walk(cn[0])) or not any(isinstance(c, ast.Constant) and c.value == "-" for c in ast.walk(cn[0])):
    print("Modul: _cmd_noise ohne check_tune / nicht nur stdout"); hit = True
for fdef in ar:
    for c in ast.walk(fdef):
        if isinstance(c, ast.Call) and fname(c.func) in ("open", "write", "write_json", "wavfile", "save"):
            print("Modul: Aktivitaet schreibt Rohdaten?", fname(c.func)); hit = True
for fnn in ("_cmd_rds", "_cmd_dab", "_cmd_meteor", "_cmd_act"):
    body = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == fnn]
    if not body or not any(isinstance(c, ast.Call) and fname(c.func) == "check_tune" for c in ast.walk(body[0])):
        print("Modul: %s ohne check_tune" % fnn); hit = True
net = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8")
h, ntree = bad_common(net, "Netz")
hit |= h
URLS = {"https://celestrak.org/NORAD/elements/gp.php?CATNR=%d&FORMAT=tle", "http://127.0.0.1:%d/mux.json"}
for node in ast.walk(ntree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            m = (getattr(node, "module", None) or a.name)
            if m not in ("json", "re", "urllib.request"):
                print("Netz: Import", m); hit = True
    if isinstance(node, ast.Constant) and isinstance(node.value, str) and "://" in node.value and node.value not in URLS:
        print("Netz: URL", node.value); hit = True
    if isinstance(node, ast.Call) and fname(node.func) not in ("Request", "urlopen", "read", "decode", "splitlines", "strip", "rstrip", "match", "int", "len", "ValueError", "group", "loads", "compile"):
        print("Netz: Aufruf", fname(node.func)); hit = True
    if isinstance(node, ast.keyword) and node.arg == "data":
        print("Netz: data= (POST)"); hit = True
gps = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
h, gtree = bad_common(gps, "GPS")
hit |= h
GOK = {"GPSD_HOST": "192.168.178.15", "GPSD_PORT": 2947}
for n in gtree.body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in GOK:
        if ast.literal_eval(n.value) != GOK.pop(n.targets[0].id):
            print("GPS: Adresse veraendert"); hit = True
if GOK:
    print("GPS: feste Adresse fehlt", GOK); hit = True
for node in ast.walk(gtree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name) not in ("json", "socket", "threading", "time", "random"):
                print("GPS: Import", a.name); hit = True
    if isinstance(node, ast.Constant) and isinstance(node.value, str) and any(ip != "192.168.178.15" for ip in re.findall(r"\d+\.\d+\.\d+\.\d+", node.value)):
        print("GPS: andere Adresse", node.value); hit = True
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "socket" and node.attr not in ("create_connection", "timeout"):
        print("GPS: socket.%s" % node.attr); hit = True
    if isinstance(node, ast.Call) and fname(node.func) == "create_connection":
        if not (node.args and isinstance(node.args[0], ast.Tuple) and [getattr(e, "id", None) for e in node.args[0].elts] == ["GPSD_HOST", "GPSD_PORT"]):
            print("GPS: Verbindung nicht zur festen Adresse"); hit = True
    if isinstance(node, ast.Call) and fname(node.func) in ("sendall", "send", "sendto"):
        if fname(node.func) != "sendall" or not (node.args and getattr(node.args[0], "id", None) in ("WATCH", "UNWATCH")):
            print("GPS: sendet anderes als ?WATCH"); hit = True
    if isinstance(node, ast.Call) and fname(node.func) in ("open", "Popen", "system", "run", "remove", "unlink", "bind", "listen", "accept", "connect", "urlopen"):
        print("GPS: Aufruf", fname(node.func)); hit = True
for n in gtree.body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("WATCH", "UNWATCH"):
        if ast.literal_eval(n.value) not in (b'?WATCH={"enable":true,"json":true}\n', b'?WATCH={"enable":false}\n'):
            print("GPS: WATCH veraendert"); hit = True
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if a.name == "prepper_gps" and owner.get(id(node)) not in ("loop", "selftest"):
                print("Modul: prepper_gps ausserhalb loop/selftest"); hit = True
for fdef in [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "_cmd_noise"]:
    for c in ast.walk(fdef):
        if isinstance(c, ast.List) and c.elts and isinstance(c.elts[0], ast.Constant) and c.elts[0].value in ("rtl_power", "rtl_fm"):
            vals = [getattr(e, "value", None) for e in c.elts]
            if "-g" not in vals:
                print("Modul: Pegelmessung ohne feste Verstaerkung (-g)", vals[0]); hit = True
evs = pathlib.Path(sys.argv[5]).read_text(encoding="utf-8")
h, etree = bad_common(evs, "evLog")
hit |= h
for n in etree.body:
    if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "CHRONY":
        if ast.literal_eval(n.value) != ["chronyc", "-c", "tracking"]:
            print("evLog: CHRONY veraendert"); hit = True
if "CHRONY = [" not in evs:
    print("evLog: CHRONY fehlt"); hit = True
eown = {}
for fn_node in ast.walk(etree):
    if isinstance(fn_node, ast.FunctionDef):
        for sub in ast.walk(fn_node):
            eown[id(sub)] = fn_node.name
for node in ast.walk(etree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if (getattr(node, "module", None) or a.name) not in ("json", "os", "re", "subprocess", "sys", "time", "tempfile"):
                print("evLog: Import", a.name); hit = True
    if isinstance(node, ast.Call):
        fn = fname(node.func)
        if fn == "Popen" and not (eown.get(id(node)) == "_chrony_read" and node.args and getattr(node.args[0], "id", None) == "CHRONY"):
            print("evLog: Popen nicht nur chronyc -c tracking"); hit = True
        if fn.startswith(("send", "maybe_mesh")) or fn in ("system", "popen", "call", "check_output", "check_call", "run", "rmtree", "unlink", "remove", "execv", "execvp",
                                                           "bind", "listen", "accept", "connect", "urlopen", "create_connection", "rename"):
            print("evLog: verbotener Aufruf", fn); hit = True
    if isinstance(node, ast.Constant) and isinstance(node.value, str) and ("://" in node.value or re.search(r"\d+\.\d+\.\d+\.\d+", node.value)) and eown.get(id(node)) not in ("selftest", "_selftest"):
        print("evLog: Adresse/URL", node.value); hit = True
for node in ast.walk(tree):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            if a.name == "prepper_evlog" and owner.get(id(node)) != "loop":
                print("Modul: prepper_evlog ausserhalb loop"); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
python3 "$M" selftest > "$W/selftest.txt" 2>&1 || { tail -20 "$W/selftest.txt"; echo "STOP: Selbsttest - nichts geaendert"; exit 1; }
STL=$(grep -c -e 'prepper_gps selftest ok' -e 'selftest sdrNoise2 ok' -e 'Kalibrierung von Hand: laufenden Block unterbrochen' "$W/selftest.txt" || true)
[[ "$STL" == 3 ]] || { echo "STOP: Selbsttest ohne sdrNoise2-/GPS-/Kalibrier-Test - nichts geaendert"; exit 1; }
(cd "$W" && python3 -W error "$E" selftest) > "$W/selftest_ev.txt" 2>&1 || { tail -20 "$W/selftest_ev.txt"; echo "STOP: evLog-Selbsttest - nichts geaendert"; exit 1; }
grep -c 'prepper_evlog selftest ok' "$W/selftest_ev.txt" >/dev/null || { echo "STOP: evLog-Selbsttest ohne ok - nichts geaendert"; exit 1; }
grep -c 'selftest br24Warn2 ok' "$W/selftest.txt" >/dev/null && grep -c 'warnscore selftest ok' "$W/selftest.txt" >/dev/null || { echo "STOP: Selbsttest ohne br24Warn2/Warn-Score - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (br24Warn2: nur GET, keine Schreibstelle, kein Netz, kein Mesh; lageMesh1: einzige Sendestelle = Klick-Handler -> send_meshtastic Kanal 0; prepper_sdr nur Rundfunk-Auswertung + feste Presets) + Selbsttests (SDR inkl. Warn-Score/ASA/PTY31, GPS, evLog)"
echo "  $(grep 'warnscore selftest ok' "$W/selftest.txt")"

# ---------- 1) Voraussetzungen (nur lesen) ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
LIVE_MOD=$(sha256sum "$DASH_DIR/prepper_sdr.py" 2>/dev/null | cut -c1-64 || true)
LIVE_GPS=$(sha256sum "$DASH_DIR/prepper_gps.py" 2>/dev/null | cut -c1-64 || true)
LIVE_EV=$(sha256sum "$DASH_DIR/prepper_evlog.py" 2>/dev/null | cut -c1-64 || true)
if [[ "$LIVE_EV" != "$EXPECT_EV" ]]; then echo "STOP: prepper_evlog.py ist nicht der evLog-Stand (sha ${LIVE_EV:0:16}) - nichts geaendert"; exit 1; fi
if [[ "$LIVE_GPS" != "$BASE_GPS" && "$LIVE_GPS" != "$EXPECT_GPS" ]]; then echo "STOP: prepper_gps.py ist nicht der gpsLearn-Stand (sha ${LIVE_GPS:0:16}) - nichts geaendert"; exit 1; fi
if [[ "$LIVE_MOD" == "$BASE_MOD" ]]; then MODBASE="evLog"; elif [[ "$LIVE_MOD" == "$BR1_MOD" ]]; then MODBASE="br24Warn"; elif [[ "$LIVE_MOD" == "$EXPECT_MOD" ]]; then MODBASE="br24Warn2"; else echo "STOP: prepper_sdr.py ist weder evLog- noch br24Warn-Stand (sha ${LIVE_MOD:0:16}) - nichts geaendert"; exit 1; fi
if grep -q "# ===== br24Warn2:" "$F"; then DBASE="br24Warn2"; elif grep -q "# ===== br24Warn:" "$F"; then DBASE="br24Warn (67133d86)"; else DBASE="evLog (ohne br24Warn)"; fi
echo "Basis: dashboard.py $DBASE, prepper_sdr.py $MODBASE"
for gm in evLog gpsLearn sdrNoise2 sdrGps sdrNoise sdrRf sdrRds sdrStick sdrAct sdrPreset sdrPlus sdAck sdrFunk2 sdrFunk; do
  grep -q "# ===== $gm:" "$F" || { echo "STOP: dashboard.py ohne Guard $gm - nichts geaendert"; exit 1; }
done
systemctl cat "$UNIT" >/dev/null 2>&1 || { echo "STOP: $UNIT fehlt - nichts geaendert"; exit 1; }
SDR_WAS=$(systemctl is-active "$UNIT" 2>/dev/null || true)
SCFG="$DASH_DIR/sdr_config.json"
echo "dashboard.py sha16 vorher $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; prepper_sdr.py ${LIVE_MOD:0:16}; prepper-sdr $SDR_WAS"
CAL0=$(python3 -c "import json,sys; print((json.load(open(sys.argv[1])) or {}).get('ppm_cal'))" "$SCFG" 2>/dev/null || echo "?")
echo "Kalibrierung vorher (sdr_config.json): $CAL0"
sudo journalctl -u "$UNIT" --since "-12h" --no-pager -o cat 2>/dev/null | grep -a -e 'Kalibrierung' | tail -4 | sed 's/^/  Log: /' || true
GP=$(cd "$W" && python3 -c "
import prepper_gps as g
try:
    p = g.parse(g.read_gpsd(6))
    print('erreichbar, Fix-Modus %s, Satelliten %s/%s, SNR %s dB-Hz, HDOP %s' % (p.get('mode'), p.get('used'), p.get('seen'), p.get('snr'), p.get('hdop')) if p.get('ok') else 'erreichbar, aber ' + str(p.get('why')))
except Exception as e:
    print('NICHT erreichbar: %s' % e)
" 2>&1 || true)
echo "Dach-GPS 192.168.178.15:2947 (nur lesen): $GP"
python3 - "$DASH_DIR/broadcast_state.json" << 'PY' || true
import json, sys, re, time
try:
    b = json.load(open(sys.argv[1]))
except Exception as e:
    print("Rundfunk-Zustand vorher: nicht lesbar (%s)" % e); sys.exit(0)
R = re.compile(r"^\s*BR\s*-?\s*24(?![0-9])", re.I)
fm = [(k, v) for k, v in (b.get("fm") or {}).items() if isinstance(v, dict)]
print("Rundfunk vorher: UKW %d Sender, DAB %d Kanaele" % (len(fm), len(b.get("dab") or {})))
for k, v in fm:
    if R.match(str(v.get("ps") or "")) or R.match(str(k)):
        print("  UKW-Kandidat BR24: Name %s · PS %s · PI %s · %s MHz · zuletzt %s" % (k, v.get("ps"), v.get("pi"), v.get("f"), time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(v.get("t") or 0))))
for ch, x in (b.get("dab") or {}).items():
    for sv in (x.get("services") or []) if isinstance(x, dict) else []:
        if isinstance(sv, dict) and R.match(str(sv.get("label") or "")):
            print("  DAB-Kandidat BR24: Kanal %s · %s · Dienst %s · SId %s" % (ch, x.get("ensemble"), sv.get("label"), sv.get("sid") or "(noch nicht gespeichert, kommt nach dem naechsten DAB-Block)"))
PY

WEX=$(command -v welle-cli || true)
WV=$(dpkg-query -W -f='${Version}' welle.io 2>/dev/null || echo "?")
(cd "$W" && python3 -c "
import sys, prepper_sdr as p
c = p.welle_caps(sys.argv[1] or None)
print('welle-cli %s (%s): Alarmflag FIG 0/0 %s, Ansagen FIG 0/18-19 %s, ASA/EWS %s' % (sys.argv[2], c['exe'] or 'fehlt', 'JA' if c['fig0_0'] else 'nein', 'JA' if c['fig0_19'] else 'nein', 'JA' if c['asa'] else 'nein'))
print('  -> ' + c['note'])
" "$WEX" "$WV") 2>&1 || echo "welle-cli Faehigkeit: nicht pruefbar"
python3 - "$DASH_DIR/broadcast_state.json" "$SCFG" << 'PY' || true
import json, sys, re, time
try:
    b = json.load(open(sys.argv[1]))
except Exception:
    b = {}
try:
    c = json.load(open(sys.argv[2])) or {}
except Exception:
    c = {}
dl = c.get("dab") if isinstance(c.get("dab"), list) and c.get("dab") else ["11D"]
print("DAB-Kanaele im Rundfunk-Block bisher %s, ab jetzt %s (5C fuer ASA DE%s)" % (",".join(dl), ",".join(dl + ([] if "5C" in dl or c.get("asa_5c") is False else ["5C"])), ", aus per asa_5c=false" if c.get("asa_5c") is False else ""))
x = (b.get("dab") or {}).get("5C")
if not isinstance(x, dict):
    print("ASA/5C: 5C noch nie empfangen - ASA DE wird ab dem naechsten Rundfunk-Block gesucht")
else:
    a = [sv for sv in x.get("services") or [] if isinstance(sv, dict) and re.match(r"^\s*ASA(?:\s|-|$)", str(sv.get("label") or ""), re.I)]
    print("ASA/5C: Ensemble %s, %s Dienste, zuletzt %s; ASA-Dienst: %s" % (x.get("ensemble") or "?", len(x.get("services") or []), time.strftime("%d.%m.%Y %H:%M:%S", time.localtime(x.get("t") or 0)),
          "; ".join("%s SId %s DLS %s" % (sv.get("label"), sv.get("sid") or "?", (sv.get("dls") or "-")[:60]) for sv in a) or "nicht gefunden"))
PY

# ---------- 2) Trockenlauf ----------
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
grep -c "OK br24 selftest ok" "$W/dry.txt" >/dev/null || { echo "STOP: BR24-Selbsttest fehlt - nichts geaendert"; exit 1; }
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
[[ "${PRE[/umwelt]}" == "200" && "${PRE[/funk]}" == "200" ]] || { echo "STOP: /umwelt oder /funk antwortet nicht - nichts geaendert"; exit 1; }
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
"${CURL[@]}" "$B/umwelt" -o "$W/umwelt0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)

# ---------- 3) Installieren + Neustart (nur prepper-sdr + prepper-dashboard) ----------
same_dash=0; cmp -s "$W/work/dashboard.py" "$F" && same_dash=1
same_mod=0; cmp -s "$M" "$DASH_DIR/prepper_sdr.py" && same_mod=1
same_gps=0; cmp -s "$G" "$DASH_DIR/prepper_gps.py" 2>/dev/null && same_gps=1
same_ev=0; cmp -s "$E" "$DASH_DIR/prepper_evlog.py" 2>/dev/null && same_ev=1
cmp -s "$N" "$DASH_DIR/prepper_sdr_net.py" 2>/dev/null || echo "WARN prepper_sdr_net.py weicht ab (bleibt unveraendert)"
if [[ "$same_dash$same_mod$same_gps$same_ev" == "1111" && "$SDR_WAS" == active ]]; then
  echo "OK br24Warn2 schon installiert - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    echo "--- Dashboard-Log ---"
    sudo journalctl -u prepper-dashboard --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | tail -12 | cut -c1-200 || true
    echo "--- prepper-sdr-Log ---"
    sudo journalctl -u "$UNIT" --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | tail -6 | cut -c1-200 || true
    cp -a "$F.bak-br2-$TS" "$F"
    [[ -f "$DASH_DIR/prepper_sdr.py.bak-br2-$TS" ]] && cp -a "$DASH_DIR/prepper_sdr.py.bak-br2-$TS" "$DASH_DIR/prepper_sdr.py"
    if [[ -f "$DASH_DIR/prepper_gps.py.bak-br2-$TS" ]]; then cp -a "$DASH_DIR/prepper_gps.py.bak-br2-$TS" "$DASH_DIR/prepper_gps.py"; elif [[ "${GPS_NEW:-0}" == 1 ]]; then rm -f "$DASH_DIR/prepper_gps.py"; fi
    if [[ -f "$DASH_DIR/prepper_evlog.py.bak-br2-$TS" ]]; then cp -a "$DASH_DIR/prepper_evlog.py.bak-br2-$TS" "$DASH_DIR/prepper_evlog.py"; elif [[ "${EV_NEW:-0}" == 1 ]]; then rm -f "$DASH_DIR/prepper_evlog.py"; fi
    rm -f "$DASH_DIR/sdr_cal_now"
    sudo systemctl restart "$UNIT" 2>/dev/null || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/"), prepper-sdr $(systemctl is-active "$UNIT" 2>/dev/null || true)), Backup $F.bak-br2-$TS"
  }
  cp -a "$F" "$F.bak-br2-$TS"
  cp -a "$DASH_DIR/prepper_sdr.py" "$DASH_DIR/prepper_sdr.py.bak-br2-$TS"
  if [[ -f "$DASH_DIR/prepper_gps.py" ]]; then cp -a "$DASH_DIR/prepper_gps.py" "$DASH_DIR/prepper_gps.py.bak-br2-$TS"; else GPS_NEW=1; fi
  if [[ -f "$DASH_DIR/prepper_evlog.py" ]]; then cp -a "$DASH_DIR/prepper_evlog.py" "$DASH_DIR/prepper_evlog.py.bak-br2-$TS"; else EV_NEW=1; fi
  install -m 644 "$E" "$DASH_DIR/prepper_evlog.py.new" && mv -f "$DASH_DIR/prepper_evlog.py.new" "$DASH_DIR/prepper_evlog.py" || { rb "evLog-Modul installieren"; exit 1; }
  install -m 644 "$G" "$DASH_DIR/prepper_gps.py.new" && mv -f "$DASH_DIR/prepper_gps.py.new" "$DASH_DIR/prepper_gps.py" || { rb "GPS-Modul installieren"; exit 1; }
  install -m 644 "$M" "$DASH_DIR/prepper_sdr.py.new" && mv -f "$DASH_DIR/prepper_sdr.py.new" "$DASH_DIR/prepper_sdr.py" || { rb "Modul installieren"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && mv -f "$F.new" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  sudo systemctl restart "$UNIT" || { rb "Start $UNIT"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard + prepper-sdr neu gestartet - warte auf HTTP (max 240 s; sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  for i in $(seq 1 40); do python3 -c "import json,sys; assert json.load(open(sys.argv[1])).get('v')==10" "$DASH_DIR/sdr_status.json" 2>/dev/null && break; sleep 2; done
  systemctl is-active --quiet "$UNIT" || { rb "$UNIT laeuft nicht"; exit 1; }
  echo "Dach-GPS: warte auf erste Abfrage (max 60 s) ..."
  GS=""
  for i in $(seq 1 20); do
    sleep 3
    GS=$("${CURL[@]}" "$B/api/sdr/status" | python3 -c "
import json,sys
s=(json.load(sys.stdin).get('status') or {})
g=s.get('gps') or {}
assert s.get('v')==10
if g.get('t'):
    print('%s · %s · SNR %s dB-Hz · Sat %s/%s · Fix %s · GPS %s · GLONASS %s · %s' % (g.get('lvl'), 'ok' if g.get('ok') else 'nicht erreichbar', g.get('snr'), g.get('used'), g.get('seen'), g.get('mode'), (g.get('G') or {}).get('drop', 'lernt'), (g.get('R') or {}).get('drop', 'lernt'), g.get('why')))
" 2>/dev/null || true)
    [[ -n "$GS" ]] && break
  done
  [[ -n "$GS" ]] || { rb "/api/sdr/status ohne v10 / Dach-GPS-Abfrage"; exit 1; }
  echo "OK prepper-sdr v10, Dach-GPS: $GS"
  uc=$(code_r "$B/umwelt"); [[ "$uc" == "200" ]] || { rb "/umwelt fehlerhaft ($uc)"; exit 1; }
  "${CURL[@]}" "$B/umwelt" -o "$W/umwelt.html" || true
  python3 - "$W/umwelt.html" "$W/umwelt0.html" << 'PY' || { rb "/umwelt: sdrNoise2/Dach-GPS/Breite/Zeilen fehlen oder alter Inhalt verloren"; exit 1; }
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
assert h.count('id="sdrn-js"') == 1 and h.count('id="sdrg-js"') == 1 and h.count('id="sdrg-css"') == 1, "Bloecke"
assert "Störsender / QRM" in h and "Gewitter-Hinweis" in h and "Dach-GPS " in h and "D.ghist" in h and "sdrn-car" in h and "Stick-L1 (Nebenwert)" in h, "Inhalt"
assert "grid-column:1/-1" in h and "text-overflow:ellipsis" in h and "white-space:nowrap" in h, "Layout"
assert " neue Träger: '" not in h, "Traeger noch in einer Zeile"
assert h.count('id="gpsl-css"') == 1 and "srow('G')" in h and "gpsl-blink" in h and "prefers-reduced-motion" in h and "keine Satelliten/Daten" in h and "D.ghist_s" in h and "sel==='dachglo'" in h and "Grundlinie lernt oder keine" not in h, "gpsLearn fehlt"
assert h.count('id="sdrn2-css"') == 1 and "COL.trend" in h and "dachglo" in h and "Schwelle +" in h and "Trend steigend" in h, "sdrNoise2 fehlt"
h0 = open(sys.argv[2], encoding="utf-8", errors="replace").read()
import re
def cut(x):
    x = re.sub(r'<style id="gpsl-css">.*?</style>', '', x, count=1, flags=re.S)
    return re.sub(r'<style id="evl-css">.*?</style><script type="application/json" id="evl-data">.*?</script><script id="evl-js">.*?</script>', '', x, count=1, flags=re.S)
assert cut(h0)[:2000] == cut(h)[:2000], "alte Umwelt-Seite veraendert"
assert h.count('id="evl-js"') == 1 and h.count('id="evl-data"') == 1 and h.count('id="evl-css"') == 1 and "sdrnThunder" in h and "evl-qrm" in h and "läuft seit" in h and "ungenau" in h, "evLog fehlt"
PY
  python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('ok') and d['gps'].get('src')=='Dach-GPS' and 'd' in d['ghist'] and 'w' in d['ghist'] and len(d.get('bands') or [])==9" < <("${CURL[@]}" "$B/api/sdr/noise") || { rb "/api/sdr/noise ohne Dach-GPS"; exit 1; }
  echo "OK /umwelt: Dach-GPS-Zeile in Stoersender/QRM, beide Kacheln volle Breite, einzeilige Zeilen, /api/sdr/noise mit Verlauf"
  "${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" || true
  grep -q "Dach-GPS: " "$W/funk.html" || { rb "/funk ohne Dach-GPS-Zeile"; exit 1; }
  grep -q "Trend steigend: " "$W/funk.html" || { rb "/funk ohne Trend-Zeile"; exit 1; }
  "${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" || true
  grep -q "sdrGpsRow" "$W/pi.html" || { rb "/pi ohne Datenquelle Dach-GPS"; exit 1; }
  R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
  [[ "$R1" == "$R0" ]] || { rb "/pi Sicherung veraendert ($R0/$R1)"; exit 1; }
  echo "OK /funk Zeile Dach-GPS, /pi Datenquelle Dach-GPS (Sicherung unveraendert)"
  "${CURL[@]}" -L --max-redirs 5 "$B/funk433" -o "$W/f433.html" || true
  python3 -c "
import sys; h=open(sys.argv[1],encoding='utf-8',errors='replace').read()
assert h.count('id=\"evl-js\"')==1 and 'als eigen markieren' in h and 'id=\"sdrMain\"' in h and '433-MHz-Sensoren' in h
" "$W/f433.html" || { rb "/funk433 ohne KFZ-Log"; exit 1; }
  EVS=$("${CURL[@]}" "$B/api/sdr/evlog" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') and isinstance(d.get('qrm'), list) and isinstance(d.get('th'), list) and isinstance(d.get('kfz'), list), d
lv=d.get('live') or {}
print('  Ereignisse Funkumgebung: %s abgeschlossen gespeichert, %s offen (Kacheln zeigen %s QRM/GPS, %s Gewitter)' % (d.get('n_ev'), lv.get('open', '?'), len(d['qrm']), len(d['th'])))
print('  KFZ-Sensoren: %s Sichtungen gesamt, heute %s / %s Sensoren, eigene %s' % (d.get('n_kfz'), d['kfz_today'].get('n'), d['kfz_today'].get('sensoren'), d.get('own_n')))
" 2>&1 || echo FEHLER)
  [[ "$EVS" != *FEHLER* ]] || { echo "$EVS"; rb "/api/sdr/evlog fehlerhaft"; exit 1; }
  for i in $(seq 1 20); do python3 -c "import json,sys; assert (json.load(open(sys.argv[1])).get('evlog') or {}).get('n') is not None" "$DASH_DIR/sdr_status.json" 2>/dev/null && break; sleep 3; done
  python3 -c "import json,sys; assert (json.load(open(sys.argv[1])).get('evlog') or {}).get('n') is not None" "$DASH_DIR/sdr_status.json" || { rb "prepper-sdr ohne Ereignis-Log"; exit 1; }
  echo "OK evLog weiter aktiv:"
  echo "$EVS"
  "${CURL[@]}" -L --max-redirs 5 "$B/rundfunk" -o "$W/rf.html" || true
  python3 - "$W/rf.html" << 'PY' || { rb "/rundfunk: BR24-Filter/Zeile fehlt oder TA noch markiert"; exit 1; }
import json, re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
assert h.count('id="br24-js"') == 1 and h.count('id="br24-data"') == 1 and "nur BR24" in h and "gelb = TA" not in h, "Seite"
d = json.loads(re.search(r'<script type="application/json" id="sdrData">(.*?)</script>', h, re.S).group(1).replace("\\u003c", "<"))["d"]
assert not any(e.get("k") == "ta" for e in d.get("events") or []), "TA-Ereignis"
assert all("ta" not in x and "tp" not in x for x in d.get("fm") or []), "TA-Spalte"
m = d["br24"]["match"]
assert all(x.get("rt") in (None, "") or x.get("name") in m["fm"] for x in d.get("fm") or []), "fremder RadioText"
assert all(not x.get("dls") or x.get("label") in (m["dab"].get(x.get("ch")) or {}) or x.get("label") in (m.get("asa", {}).get(x.get("ch")) or {}) for x in d.get("dab") or []), "fremder DLS"
assert "nur BR24 + ASA DE" in h and "ASA DE" in h, "Hinweis br24Warn2"
PY
  "${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/pg.html" || true
  grep -c 'id="br24-js"' "$W/pg.html" >/dev/null || { rb "/funk ohne BR24-Zeile"; exit 1; }
  "${CURL[@]}" -L --max-redirs 5 -D "$W/lage.hdr" "$B/" -o "$W/lage.html" || true
  LM=$(python3 - "$W/lage.html" "$W/lage.hdr" << 'PY' 2>&1 || echo FEHLER
import json, re, sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
hd = open(sys.argv[2], encoding="utf-8", errors="replace").read()
assert h.count('id="lm1-js"') == 1 and h.count('id="lm1-data"') == 1, "lageMesh1 fehlt"
assert 'id="freqMeshBtn"' not in h and 'onclick="sendFreqMesh()"' not in h, "Netzfrequenz-Knopf noch da"
d = json.loads(re.search(r'<script type="application/json" id="lm1-data">(.*?)</script>', h, re.S).group(1).replace("\\u003c", "<"))
assert d.get("ok") and d.get("sent_n") == 0, d
fq = re.search(r"X-Lm1: freq(\d)", hd)
print("  Netzfrequenz-Knopf: %s" % {"0": "nicht im HTML gefunden", "1": "Karte entfernt", "2": "Knopf versteckt+deaktiviert"}.get(fq.group(1) if fq else "?", "?"))
for k in ("nina", "br24"):
    x = d[k]
    print("  Knopf An Mesh 1 (%s): %s%s" % (k.upper(), "AKTIV (nur per Klick+Bestaetigung) Text: " + x["text"][:90] if x["active"] else "grau - keine aktive Warnung", "" if not x.get("wait") else " · Sperrzeit %s s" % x["wait"]))
print("  per Knopf gesendet seit Neustart: %s (Apply klickt nicht)" % d["sent_n"])
PY
)
  [[ "$LM" != *FEHLER* && "$LM" != *Error* ]] || { echo "$LM"; rb "/ (Lage): BR24-Kachel/Knoepfe fehlen oder Netzfrequenz-Knopf noch da"; exit 1; }
  NINA=$(grep -c -i 'class="title">[^<]*NINA' "$W/lage.html" || true)
  FQ=$(sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -o 'mesh_freq gesperrt=[0-9]*' | tail -1 || true)
  echo "OK lageMesh1: BR24-Kachel (wie NINA) direkt unter NINA (NINA-Kachel im HTML: $NINA), Knopf An Mesh 1 an NINA + BR24 nur per Klick, /api/${FQ:-mesh_freq gesperrt=? (Log)}"
  echo "$LM"
  BRS=$("${CURL[@]}" "$B/api/br24" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d.get('ok') and d.get('state') in ('gruen', 'rot', 'grau') and d.get('text'), d
m=d.get('match') or {}
print('  BR24 erkannt UKW: ' + ('; '.join('%s (%s)' % (k, ', '.join(v)) for k, v in (m.get('fm') or {}).items()) or 'nichts'))
print('  BR24 erkannt DAB: ' + ('; '.join('%s: %s' % (c, ', '.join('%s (%s)' % (l, ', '.join(w)) for l, w in v.items())) for c, v in (m.get('dab') or {}).items()) or 'nichts'))
print('  gelernte PI: %s · gelernte SId: %s' % (', '.join(m.get('pi') or []) or '-', ', '.join(m.get('sid') or []) or '- (nach dem naechsten DAB-Block)'))
print('  ASA DE: ' + ('; '.join('%s: %s' % (c, ', '.join('%s (%s)' % (l, ', '.join(w)) for l, w in v.items())) for c, v in (m.get('asa') or {}).items()) or 'nicht gefunden (5C kommt im naechsten Rundfunk-Block)'))
cp=d.get('caps') or {}
print('  welle-cli laut prepper-sdr: ' + (cp.get('note') or 'noch kein DAB-Block mit br24Warn2'))
for w in (d.get('recent') or [])[:4]: print('  zuletzt bewertet: %s %s %s · %s · %s (%s)' % (w['t_txt'], w['src'], w['kind'], w['cls'] or '-', w['text'][:60], w['score']))
print('  Zeile jetzt: %s%s · %s' % (d['state'].upper(), ' (TEST)' if d.get('test') else '', d['text']))
w=d.get('why')
if w: print('  Grund: %s %s · %s · bleibt rot bis %s' % (w['src'], w['kind'], w['t_txt'], __import__('time').strftime('%d.%m.%Y %H:%M:%S', __import__('time').localtime(w['until']))))
" 2>&1 || echo FEHLER)
  [[ "$BRS" != *FEHLER* ]] || { echo "$BRS"; rb "/api/br24 fehlerhaft"; exit 1; }
  echo "OK br24Warn2: /rundfunk nur BR24 + ASA DE, Warn-Score aktiv, TA nur Beleg; Zeile auf /funk + /rundfunk, Kachel auf Lage"
  echo "$BRS"
  sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -a -e 'br24Warn2' -e 'lageMesh1' -e 'evLog' | tail -3 || true
  GSYS=$("${CURL[@]}" "$B/api/sdr/status" | python3 -c "
import json,sys
g=((json.load(sys.stdin).get('status') or {}).get('gps') or {})
sy=g.get('sys') or {}
assert set(sy) == {'G', 'R'}, sy
for k in ('G', 'R'):
    x = sy[k]
    print('  %-7s jetzt %s Sat (>=10 Grad, ss>0), mittlere ss %s dB-Hz · Proben gesamt %s, fuer Grundlinie %s ueber %s h, bestes Hoehenband %s/24 · %s%s' % (
        x['name'], x['now_n'], x['now_ss'], x['samples'], x['ref'], x['span_h'], x['best_bin'], x['state'], (' (noch ~%s h)' % x['eta_h']) if x['state'] == 'lernt' else ''))
    assert 'b_snr' in x and 'hist_n' in x, x
    print('          eigene Kurve: %s Punkte gespeichert (Datei %s), Grundlinie %s' % (x['hist_n'], 'sdr_gps_snr_gps.json' if k == 'G' else 'sdr_gps_snr_glo.json', ('%s dB-Hz' % x['b_snr']) if x['b_snr'] is not None else 'lernt'))
" 2>&1 || echo FEHLER)
  GH=$("${CURL[@]}" "$B/api/sdr/noise" | python3 -c "
import json,sys
h=json.load(sys.stdin).get('ghist_s') or {}
assert set(h) == {'G', 'R'} and all(isinstance(h[k].get('d'), list) and isinstance(h[k].get('w'), list) for k in h), h
print('  Kurven /api/sdr/noise: GPS %d/%d, GLONASS %d/%d Punkte (24h/14d)' % (len(h['G']['d']), len(h['G']['w']), len(h['R']['d']), len(h['R']['w'])))
" 2>&1 || echo FEHLER)
  [[ "$GH" != *FEHLER* ]] || { echo "$GH"; rb "/api/sdr/noise ohne Kurven je System"; exit 1; }
  [[ "$GSYS" != *FEHLER* && "$GSYS" == *GLONASS* ]] || { echo "$GSYS"; rb "Dach-GPS ohne Angaben je System"; exit 1; }
  echo "OK Dach-GPS je System:"
  echo "$GSYS"
  echo "$GH"
fi
fail=0
for p in "${PAGES[@]}"; do
  c=$(code_r -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  [[ -f "$F.bak-br2-$TS" ]] && rb "Seite antwortet schlechter als vorher"
  exit 1
fi
"${CURL[@]}" "$B/api/sdr/status" | python3 -c "
import json,sys
d=json.load(sys.stdin); s=d.get('status') or {}; g=s.get('gps') or {}
print('SDR Dienst %s · v%s · aktiv %s · Modus %s' % (d.get('service'), s.get('v'), s.get('active'), (d.get('mode') or {}).get('mode')))
print('Dach-GPS: %s, SNR %s dB-Hz (Grundlinie %s), Sat %s/%s, Fix %s, %s' % (g.get('lvl'), g.get('snr'), g.get('b_snr'), g.get('used'), g.get('seen'), g.get('mode'), g.get('why')))
print('Funkumgebung: QRM %s, Gewitter %s; Kalibrierung %s' % (((s.get('noise') or {}).get('qrm') or {}).get('lvl'), ((s.get('noise') or {}).get('thunder') or {}).get('lvl'), s.get('cal')))
" 2>/dev/null || echo "WARN Status nicht lesbar"
SN=$("${CURL[@]}" "$B/api/lage_mesh1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sent_n'))" 2>/dev/null || echo "?")
KL=$(sudo journalctl -u prepper-dashboard --since "${SINCE:-10 min ago}" --no-pager -o cat 2>/dev/null | grep -a -c 'lageMesh1: .* per Klick' || true)
if [[ "$SN" != "0" && "$SN" != "?" ]] || [[ "${KL:-0}" != "0" ]]; then echo "FEHLER: Knopf-Sendung waehrend Apply (sent_n=$SN, Log=$KL)"; [[ -f "$F.bak-br2-$TS" ]] && rb "Mesh-Sendung waehrend Apply"; exit 1; fi
echo "OK keine Mesh-Sendung ueber den neuen Knopf waehrend Apply (sent_n=$SN, Log-Zeilen=${KL:-0})"
GL=""; for gm in lageMesh1 br24Warn2 br24Warn evLog gpsLearn umweltWide sdrNoise2 sdrGps sdrNoise sdrRf sdrRds sdrStick sdrAct sdrPreset sdrPlus sdAck sdrFunk2 sdrFunk; do GL="$GL $gm=$(grep -c "# ===== $gm:" "$F" || true)"; done
echo "OK guards$GL"
[[ -f "$F.bak-br2-$TS" ]] && echo "Backup: $F.bak-br2-$TS"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen"
echo "COMMIT $COMMIT_ARG br24Warn2=1 lageMesh1=1"
