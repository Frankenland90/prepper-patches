#!/bin/bash
set -euo pipefail
# stickTest: Stick-Zuordnungstest fuer beide NESDR SMArt v5 (per Seriennummer, nacheinander, nur Empfang) als Einmal-Modus IM Dienst prepper-sdr
# (nie zweites Programm am Stick). Ergebnis: archive/sticktest/YYYY-MM/ + sdr_sticktest_last.json, eigene Kachel 'Antennentest' ganz unten auf /funk (/pi unveraendert).
# Rollen werden NIE automatisch getauscht ('Empfehlung uebernehmen' nur per Klick/Befehl). 'Grundlinien neu lernen' archiviert (loescht nicht).
# Neustart nur prepper-sdr und prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sticktest-apply
KEEP_LAST=3
BASE_DASH16="d0e5ad5d32143b14"  # sdrDual; Basis muss zusaetzlich lageTest (b13de665) enthalten
BASE_MOD16="78b9106899d1fbbd"
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== stickTest apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_BLK="c8f3839ed6960a7c4b07a4a584da4b535d4922e69a387f0e0bd9ee9553ca076d"
cat > "$W/st_block.py" << 'STBLK_EOF'
# ===== stickTest: eigene Kachel 'Antennentest' ganz unten auf /funk (letztes Ergebnis + Empfehlung, Knoepfe Antennentest starten / Neu lernen / Empfehlung uebernehmen) - legen nur Anforderungsdateien an, ausgefuehrt wird im Dienst prepper-sdr =====
import html as _stk_html
import json as _stk_json
import os as _stk_os
import time as _stk_time

_STK_REQ = {"start": "sdr_req_sticktest", "apply": "sdr_req_swap", "relearn": "sdr_req_relearn"}
_STK_LEARN_S = 86400


def _stk_load(name):
    try:
        with open(_stk_os.path.join(_SDR_BASE, name), encoding="utf-8") as f:
            v = _stk_json.load(f)
        return v if isinstance(v, dict) else {}
    except Exception:
        return {}


def _stk_info(now=None):
    now = now or _stk_time.time()
    last, run, rl = _stk_load("sdr_sticktest_last.json"), _stk_load("sdr_sticktest_run.json"), _stk_load("sdr_noise_relearn.json")
    pend = {k: _stk_os.path.exists(_stk_os.path.join(_SDR_BASE, v)) for k, v in _STK_REQ.items()}
    running = bool(run.get("running")) and now - (run.get("t") or 0) < 600
    rec = last.get("rec") if isinstance(last.get("rec"), dict) else {}
    learn = bool(rl.get("t")) and 0 <= now - rl["t"] < _STK_LEARN_S
    return {"running": running or pend["start"], "step": run.get("step") if running else ("angefordert" if pend["start"] else None),
            "eta": run.get("eta") if running else None, "pending": pend, "t": last.get("t"), "rows": rec.get("rows") or [],
            "note": rec.get("note"), "swap": bool(rec.get("swap")), "summary": last.get("summary") or [], "sticks": last.get("sticks") or [],
            "restored": last.get("restored"), "learn": learn, "learn_t": rl.get("t"), "learn_sns": rl.get("sns") or []}


def _stk_hm(t):
    return _stk_time.strftime("%d.%m. %H:%M", _stk_time.localtime(t)) if isinstance(t, (int, float)) and t else "–"


def _stk_rows(now=None):
    i = _stk_info(now)
    e = _stk_html.escape
    rows = []

    def row(dot, txt, tip=""):
        rows.append('<div class="stk-row" title="%s"><span class="su-dot %s"></span><span class="stk-tx">%s</span></div>' % (e(tip or txt), dot, e(txt)))
    if i["running"]:
        row("lernt", "läuft: %s%s" % (i["step"] or "…", (" · fertig ~%s" % _stk_time.strftime("%H:%M", _stk_time.localtime(i["eta"]))) if i.get("eta") else ""))
    if not i["t"]:
        row("aus", "noch kein Antennentest – „Antennentest starten“ oder prepper_sdr.py stick-test")
    else:
        row("ok" if i["restored"] else "gelb", "zuletzt %s · Modus/Lage danach %s" % (_stk_hm(i["t"]), "unverändert" if i["restored"] else "GEÄNDERT?"))
        for s in i["sticks"]:
            if not isinstance(s, dict):
                continue
            if not s.get("present"):
                row("rot", "Stick %s SN %s fehlt (%s)" % (s.get("no"), s.get("sn"), s.get("err") or "?"))
                continue
            a, b = s.get("433") or {}, s.get("aprs") or {}
            row("gelb" if s.get("errs") else "ok", "S%s %s · 433: %s Dek./SNR %s · APRS: %s Pakete" % (
                s.get("no"), s.get("sn"), a.get("n", "–"), a.get("snr") if a.get("snr") is not None else "–", b.get("n", "–")),
                "; ".join(s.get("errs") or []) or "Rauschboden 433 %s dB, APRS %s dB" % ((s.get("pwr433") or {}).get("floor"), (s.get("pwraprs") or {}).get("floor")))
        for r in i["rows"]:
            row({"ok": "ok", "aehnlich": "aus", "wenig": "gelb"}.get(r.get("lvl"), "aus"), r.get("txt") or "", r.get("why") or "")
        if i["note"]:
            row("gelb" if i["swap"] else "ok", i["note"] + (" – nur per „Empfehlung übernehmen“" if i["swap"] else ""))
    if i["learn"]:
        row("lernt", "Grundlinien lernen neu seit %s (je Stick %s)" % (_stk_hm(i["learn_t"]), "/".join(i["learn_sns"])))
    return "".join(rows)


def _stk_card(now=None):
    return ('<div class="card full" id="stickTestCard"><div class="title">🔌 Antennentest (Stick 1 / Stick 2)</div><div id="stkRows">%s</div></div>' % _stk_rows(now))


_STK_CSS = """<style id="stk-css">#stickTestCard .stk-row{display:flex;align-items:center;gap:6px;white-space:nowrap;overflow:hidden;font-size:13px;line-height:1.7;min-width:0}
#stickTestCard .stk-tx{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis}
#stickTestCard .su-dot{flex:0 0 auto;display:inline-block;width:10px;height:10px;border-radius:50%;background:#475569}
#stickTestCard .su-dot.ok{background:#22c55e}#stickTestCard .su-dot.gelb{background:#eab308}#stickTestCard .su-dot.rot{background:#ef4444}
#stickTestCard .su-dot.lernt,#sdrUiCard .su-dot.lernt{background:#94a3b8;animation:stk-blink 1.6s ease-in-out infinite}
@keyframes stk-blink{0%,100%{opacity:1}50%{opacity:.25}}
#stickTestCard .stk-bar{display:flex;flex-wrap:wrap;gap:6px;margin:8px 0 2px}.stk-bar button{background:#1f2937;color:#cbd5e1;border:1px solid #475569;border-radius:6px;padding:4px 10px;font-size:.85rem;cursor:pointer}
.stk-bar button:disabled{opacity:.5;cursor:default}.stk-bar .stk-msg{font-size:.8rem;opacity:.8;align-self:center;overflow-wrap:anywhere}</style>"""

_STK_JS = r"""<script id="stk-js">(function(){
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
var S=null,bar=null,msg=null,B={};
function post(a,q){if(!window.confirm(q))return;fetch('/api/sdr/sticktest',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-Stick-Test':'1'},body:JSON.stringify({action:a})})
.then(function(r){return r.json();}).then(function(j){msg.textContent=j.ok?(j.msg||'angefordert'):(j.error||'Fehler');load();}).catch(function(){msg.textContent='keine Verbindung';});}
function bottom(){var c=document.getElementById('stickTestCard');if(!c)return null;var cs=document.querySelectorAll('.card:not(#stickTestCard)');var lc=cs.length?cs[cs.length-1]:null;var par=lc?lc.parentNode:null;
if(par&&(c.parentNode!==par||par.lastElementChild!==c)){var n=par.lastElementChild;if(n!==c){par.appendChild(c);}}return c;}
function mk(){var c=bottom();if(!c||bar)return;bar=el('div','stk-bar');
B.start=el('button','','🔌 Antennentest starten');B.start.type='button';B.start.onclick=function(){post('start','Antennentest starten? Der normale Plan pausiert ca. 5 Minuten, beide Sticks werden nacheinander nur im Empfang getestet.');};
B.relearn=el('button','','↺ Neu lernen');B.relearn.type='button';B.relearn.onclick=function(){post('relearn','QRM-/Rausch-Grundlinien archivieren und je Stick neu lernen? Bewertung ist danach ca. 24 h grau (lernt).');};
B.apply=el('button','','↔ Empfehlung übernehmen');B.apply.type='button';B.apply.onclick=function(){post('apply','Rollen der Sticks tauschen (sdr_config.json)? prepper-sdr startet sich dafür kurz neu.');};
msg=el('span','stk-msg');bar.appendChild(B.start);bar.appendChild(B.relearn);bar.appendChild(B.apply);bar.appendChild(msg);c.appendChild(bar);show();}
function show(){if(!bar||!S)return;B.start.disabled=!!S.running;B.apply.style.display=S.swap&&!S.running?'':'none';B.relearn.disabled=!!S.running||!!(S.pending||{}).relearn;
if(S.running){msg.textContent='Antennentest läuft: '+(S.step||'…');}var r=document.getElementById('stkRows');if(r&&typeof S.rows_html==='string'&&r.dataset.h!==S.rows_html){r.dataset.h=S.rows_html;r.innerHTML=S.rows_html;}}
function load(){fetch('/api/sdr/sticktest',{credentials:'same-origin'}).then(function(r){return r.json();}).then(function(j){S=j;mk();show();}).catch(function(){});}
mk();load();setInterval(function(){bottom();mk();show();},1500);setInterval(load,10000);})();</script>"""


def _stk_same_origin(rq):
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
    return rq.headers.get("X-Stick-Test") == "1" and (rq.mimetype or "") == "application/json"


def _stk_api():
    from flask import jsonify, request as rq
    if rq.method == "GET":
        return jsonify(dict(_stk_info(), rows_html=_stk_rows()))
    if not _stk_same_origin(rq):
        return jsonify({"ok": False, "error": "nur von der Funk-Seite (gleicher Ursprung)"}), 403
    a = (rq.get_json(silent=True) or {}).get("action")
    if a not in _STK_REQ:
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    i = _stk_info()
    if i["running"] and a != "relearn":
        return jsonify({"ok": False, "error": "Stick-Test laeuft schon"}), 409
    if a == "apply" and not i["swap"]:
        return jsonify({"ok": False, "error": "keine Tausch-Empfehlung im letzten Stick-Test"}), 409
    st = _stk_load("sdr_status.json")
    if _stk_time.time() - (st.get("t") or 0) > 180:
        return jsonify({"ok": False, "error": "prepper-sdr laeuft nicht - Anforderung nicht angelegt"}), 409
    f = _stk_os.path.join(_SDR_BASE, _STK_REQ[a])
    with open(f + ".tmp", "w", encoding="utf-8") as h:
        _stk_json.dump({"t": int(_stk_time.time()), "by": "funk"}, h)
    _stk_os.replace(f + ".tmp", f)
    print("stickTest: Anforderung %s von /funk" % a, flush=True)
    return jsonify({"ok": True, "msg": {"start": "Antennentest angefordert (ca. 5 min)", "apply": "Tausch angefordert - prepper-sdr startet neu",
                                        "relearn": "Grundlinien werden archiviert und neu gelernt"}[a]})


_stk_orig_sdrui = _sdrui_data


def _sdrui_data():
    d = _stk_orig_sdrui()
    try:
        i = _stk_info()
        d["sticktest"] = {k: i[k] for k in ("running", "step", "t", "swap", "note", "learn", "learn_t")}
        if i["learn"]:
            fs = d.get("funcs")
            for f in (fs.values() if isinstance(fs, dict) else (fs or [])):
                if isinstance(f, dict) and f.get("k") == "noise" and f.get("lvl") not in ("aus", "rot"):
                    f["lvl"] = "lernt"
                    f["info"] = "Grundlinie lernt neu seit %s · %s" % (_stk_hm(i["learn_t"]), f.get("info") or "")
    except Exception as e:
        print("stickTest Anzeige:", e, flush=True)
    return d


def _stk_after(resp):
    try:
        from flask import request as rq
        if rq.path != "/funk" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="stk-css"' in body:
            return resp
        j = body.rfind("</body>")
        if j < 0:
            return resp
        add = _STK_CSS + _stk_card() + _STK_JS
        resp.set_data(body[:j] + add + body[j:])
    except Exception as e:
        print("stickTest Seite:", e, flush=True)
    return resp


def _stk_selftest():
    c = _stk_card(1.0)
    assert c.count('id="stickTestCard"') == 1 and 'id="stkRows"' in c
    assert _STK_JS.count("method:'POST'") == 1 and "/send" not in _STK_JS
    assert "confirm(" in _STK_JS
    return "stickTest selftest ok"


try:
    _stk_st = _stk_selftest()
    if "app" in globals():
        if "stk_api" not in app.view_functions:
            app.add_url_rule("/api/sdr/sticktest", endpoint="stk_api", view_func=_stk_api, methods=["GET", "POST"])
        if not any(getattr(f, "__name__", "") == "_stk_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_stk_after)
    print("stickTest aktiv: Kachel Antennentest unten auf /funk (nur Anforderungen an prepper-sdr); %s" % _stk_st, flush=True)
except Exception as _stk_e:
    print("stickTest:", _stk_e, flush=True)
# ===== /stickTest =====
STBLK_EOF
EXPECT_PATCH="e501c22230a68f3ba92643c55d0554d5a7191a275ef65b953ce63099af0bfdc1"
cat > "$W/patch-stk.py" << 'STPATCH_EOF'
"""stickTest Dashboard-Teil. Aufruf: patch-stk.py QUELLE ZIEL BLOCKDATEI -> 0 ok, 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
if "# ===== stickTest:" in s:
    open(dst, "w", encoding="utf-8").write(s); print("schon da"); raise SystemExit(0)
a = "# ===== /lageTest =====\n" if "# ===== /lageTest =====\n" in s else "# ===== /sdrDual =====\n"
for need in (a, "def _sdrui_data():", "_SDR_BASE = ", "# ===== piPolish2:", 'id="backupBox"'):
    if s.count(need) < 1 or (need == a and s.count(need) != 1):
        print("Basis passt nicht:", need[:50], s.count(need)); raise SystemExit(3)
s = s.replace(a, a + blk)
open(dst, "w", encoding="utf-8").write(s)
print("geaendert")
STPATCH_EOF
EXPECT_MOD="fcef7459f9e6073b95b7ee3cee0ac7e96c58c9550a823bcc473110b462bbd15f"
cat > "$W/stk_mod.py" << 'STMOD_EOF'
# ===== stickTest: Stick-Zuordnungstest (beide NESDR per Seriennummer, nacheinander, nur Empfang) im Dienst, Grundlinien je Stick neu lernen, Rollen-Tausch nur auf Befehl =====
STK_REQ = "sdr_req_sticktest"            # Anforderung (CLI 'stick-test' oder /funk-Knopf), der Dienst fuehrt aus
STK_REQ_RELEARN = "sdr_req_relearn"      # Grundlinien neu lernen
STK_REQ_SWAP = "sdr_req_swap"            # Empfehlung uebernehmen (Rollen tauschen) - nur auf ausdruecklichen Befehl
STK_LAST = "sdr_sticktest_last.json"
STK_RUN = "sdr_sticktest_run.json"
STK_RELEARN = "sdr_noise_relearn.json"
STK_433_S, STK_APRS_S, STK_PWR_S = 60, 60, 10
STK_MIN_N = 5          # weniger Treffer beim besseren Stick -> zu wenig Aktivitaet fuer eine Aussage
STK_Z = 2.0            # Unterschied der Zaehlungen >= 2 Standardabweichungen (Poisson: sqrt(n1+n2)) ...
STK_RATIO = 1.3        # ... und mindestens 30 % mehr
STK_SNR_DB = 3.0       # sonst: mittlerer SNR (433) mindestens 3 dB besser bei je >= STK_MIN_N Dekodierungen
STK_REQ_MAX_AGE = 900  # alte Anforderungen (> 15 min) verfallen
_STK_AUDIO = re.compile(r"audio level\s*=\s*(\d+)")


def stk_med(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)) and math.isfinite(x))
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def stk_avg(xs):
    xs = [x for x in xs if isinstance(x, (int, float)) and math.isfinite(x)]
    return round(sum(xs) / len(xs), 1) if xs else None


def stk_parse_433(line, acc):
    try:
        j = json.loads(line)
    except Exception:
        return
    if not isinstance(j, dict) or not j.get("model"):
        return
    acc["n"] += 1
    acc["ids"].add("%s|%s|%s" % (j.get("model"), j.get("id", ""), j.get("channel", "")))
    for k in ("rssi", "snr"):
        v = j.get(k)
        if isinstance(v, (int, float)) and math.isfinite(v):
            acc[k].append(float(v))


def stk_parse_aprs(line, acc):
    m = _STK_AUDIO.search(line)
    if m:
        acc["audio"].append(int(m.group(1)))
        return
    try:
        r = parse_aprs(line)
    except Exception:
        r = None
    if r:
        acc["n"] += 1
        acc["ids"].add(str(r.get("src") or r.get("call") or "?"))


def stk_parse_power(line, f0, acc):
    """rtl_power CSV: Datum, Zeit, Hz unten, Hz oben, Schritt, Proben, dB..."""
    pr = [x.strip() for x in line.split(",")]
    if len(pr) < 7:
        return
    try:
        lo, step = float(pr[2]), float(pr[4])
        vals = [float(x) for x in pr[6:]]
    except ValueError:
        return
    for i, v in enumerate(vals):
        if not math.isfinite(v):
            continue
        acc["all"].append(v)
        if abs(lo + (i + 0.5) * step - f0) <= 15000:
            acc["near"].append(v)


def stk_cmp(a, b, use_snr):
    """-> (sieger 1|2|None, Text, Stufe ok|aehnlich|wenig|fehlt). a/b: {'n':..,'snr':..} oder None (Stick fehlt)."""
    if not a and not b:
        return None, "kein Stick getestet", "fehlt"
    if not a or not b:
        w = 1 if a else 2
        return None, "nur Stick %d getestet - kein Vergleich" % w, "fehlt"
    n1, n2 = int(a.get("n") or 0), int(b.get("n") or 0)
    if max(n1, n2) < STK_MIN_N:
        return None, "zu wenig Aktivität (%d/%d in je %d s) - keine Aussage möglich" % (n1, n2, a.get("secs") or 60), "wenig"
    z = abs(n1 - n2) / math.sqrt(max(1, n1 + n2))
    hi, lo = max(n1, n2), min(n1, n2)
    if z >= STK_Z and hi >= STK_RATIO * max(lo, 1):
        w = 1 if n1 > n2 else 2
        return w, "%d gegen %d Treffer (deutlich)" % (hi, lo), "ok"
    s1, s2 = a.get("snr"), b.get("snr")
    if use_snr and min(n1, n2) >= STK_MIN_N and isinstance(s1, (int, float)) and isinstance(s2, (int, float)) and abs(s1 - s2) >= STK_SNR_DB:
        w = 1 if s1 > s2 else 2
        return w, "gleich viele Treffer (%d/%d), aber SNR %.1f gegen %.1f dB" % (n1, n2, max(s1, s2), min(s1, s2)), "ok"
    return None, "beide ähnlich (%d/%d Treffer) – Antenne entscheidet" % (n1, n2), "aehnlich"


def stk_recommend(res):
    """Empfehlung je Dienst + ob die Rollen getauscht werden sollten (Stick 2 = Wechselbetrieb 433/APRS)."""
    st = {x["no"]: x for x in res.get("sticks") or []}
    s1, s2 = st.get(1) or {}, st.get(2) or {}
    out, wins = [], []
    for k, lab, snr in (("433", "433 MHz", True), ("aprs", "APRS 144,800 MHz", False)):
        w, why, lvl = stk_cmp((s1.get(k) if s1.get("present") else None), (s2.get(k) if s2.get("present") else None), snr)
        sn = (s1 if w == 1 else s2).get("sn") if w else None
        out.append({"k": k, "label": lab, "win": w, "sn": sn, "lvl": lvl, "why": why,
                    "txt": ("Stick SN %s → %s (besser): %s" % (sn, lab, why)) if w else ("%s: %s" % (lab, why))})
        wins.append(w)
    swap = 1 in wins and 2 not in wins and s1.get("present") and s2.get("present")
    if swap:
        note = "Tausch empfohlen: Stick 1 (SN %s) empfängt 433/APRS besser - er sollte den Wechselbetrieb übernehmen, Stick 2 (SN %s) den Rundfunk" % (s1.get("sn"), s2.get("sn"))
    elif 1 in wins and 2 in wins:
        note = "gemischt (je ein Dienst besser) - Zuordnung bleibt"
    elif 2 in wins:
        note = "Zuordnung passt: Stick 2 (SN %s) ist für 433/APRS besser" % s2.get("sn")
    else:
        note = "kein klarer Unterschied - Zuordnung bleibt"
    return {"rows": out, "swap": bool(swap), "note": note}


def stk_summary(res):
    if not isinstance(res, dict) or not res.get("t"):
        return ["noch kein Stick-Test"]
    L = ["Stick-Test %s (%s, %d s)" % (time.strftime("%d.%m.%Y %H:%M", time.localtime(res["t"])), res.get("by") or "?", int(res.get("dur") or 0))]
    for s in res.get("sticks") or []:
        if not s.get("present"):
            L.append("Stick %d SN %s: FEHLT (%s)" % (s["no"], s.get("sn"), s.get("err") or "nicht gefunden"))
            continue
        a, b = s.get("433") or {}, s.get("aprs") or {}
        p4, pa = s.get("pwr433") or {}, s.get("pwraprs") or {}
        L.append("Stick %d SN %s (%s): 433: %s Dekod./%s Sender, RSSI %s, SNR %s dB, Boden %s/Spitze %s dB · APRS: %s Pakete/%s Rufz., Audio %s, Boden %s/Spitze %s dB%s" % (
            s["no"], s.get("sn"), s.get("role") or "?", a.get("n", "–"), a.get("ids", "–"), _fmt1(a.get("rssi")), _fmt1(a.get("snr")),
            _fmt1(p4.get("floor")), _fmt1(p4.get("peak")), b.get("n", "–"), b.get("ids", "–"), _fmt1(b.get("audio")),
            _fmt1(pa.get("floor")), _fmt1(pa.get("peak")), (" · Fehler: " + "; ".join(s.get("errs"))) if s.get("errs") else ""))
    rc = res.get("rec") or {}
    for r in rc.get("rows") or []:
        L.append(("⚠ " if r.get("lvl") == "wenig" else "") + r["txt"])
    if rc.get("note"):
        L.append("Gesamt: " + rc["note"] + (" - übernehmen nur mit 'Empfehlung übernehmen' (prepper_sdr.py stick-apply)" if rc.get("swap") else ""))
    L.append("Modus/Lage danach unverändert: %s" % ("ja" if res.get("restored") else "NEIN"))
    return L


def _fmt1(v):
    return ("%.1f" % v) if isinstance(v, (int, float)) else "–"


def stk_run_cmds(cmds, secs, on_line, cwd, log):
    """Kette starten, secs lesen, sauber beenden (SIGTERM, dann SIGKILL). -> (beendet_vorher, stderr-Ende)."""
    procs, err, prev = [], [], None
    try:
        for i, a in enumerate(cmds):
            last = i == len(cmds) - 1
            pr = subprocess.Popen(a, stdin=(prev.stdout if prev else subprocess.DEVNULL), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  start_new_session=True, cwd=cwd)
            if prev is not None:
                prev.stdout.close()
            procs.append(pr)

            def drain(s):
                try:
                    for raw in iter(s.readline, b""):
                        t = raw.decode("utf-8", "replace").strip()
                        if t:
                            err.append(t[:160])
                            del err[:-6]
                except Exception:
                    pass
            threading.Thread(target=drain, args=(pr.stderr,), daemon=True).start()
            prev = pr

        def rd(s):
            try:
                for raw in iter(s.readline, b""):
                    try:
                        on_line(raw.decode("utf-8", "replace"))
                    except Exception:
                        pass
            except Exception:
                pass
        th = threading.Thread(target=rd, args=(procs[-1].stdout,), daemon=True)
        th.start()
        end = time.time() + secs
        early = False
        while time.time() < end:
            if any(pr.poll() is not None for pr in procs):
                early = True
                break
            time.sleep(0.5)
    except Exception as e:
        err.append("Start: %s" % e)
        early = True
    finally:
        for pr in procs:
            try:
                os.killpg(pr.pid, signal.SIGTERM)
            except Exception:
                pass
        t2 = time.time() + 4
        for pr in procs:
            try:
                pr.wait(timeout=max(0.1, t2 - time.time()))
            except Exception:
                try:
                    os.killpg(pr.pid, signal.SIGKILL)
                    pr.wait(timeout=2)
                except Exception:
                    pass
        time.sleep(1.0)  # USB freigeben
    return early, err[-3:]


def stk_test_stick(pl, no, sn, ppm, role, prog):
    """Ein Stick nacheinander: 433 (rtl_433 per :SN), APRS (rtl_fm|direwolf per Index aus SN), rtl_power auf beiden Frequenzen."""
    c = pl.cfg
    r = {"no": no, "sn": sn, "role": role, "present": False, "errs": []}
    lst, e = list_sticks()
    if lst is None:
        r["err"] = "Stick-Liste: %s" % e
        return r
    idx, e = pick_stick(lst, sn)
    if e or idx is None:
        r["err"] = e or "nicht gefunden"
        return r
    r["present"], r["idx"] = True, idx
    pp = ["-p", str(ppm)] if ppm else []
    # 433
    prog("Stick %d SN %s: 433,92 MHz (%d s)" % (no, sn, STK_433_S))
    acc = {"n": 0, "ids": set(), "rssi": [], "snr": []}
    early, er = stk_run_cmds([["rtl_433", "-f", str(c["f433"]), "-F", "json", "-M", "time:unix", "-M", "level", "-M", "protocol"] + pp + ["-d", ":" + sn]],
                             STK_433_S, lambda ln: stk_parse_433(ln, acc), pl.base, pl.log)
    if early and acc["n"] == 0:
        r["errs"].append("433: beendet (%s)" % (er[-1] if er else "?"))
    r["433"] = {"n": acc["n"], "ids": len(acc["ids"]), "rssi": stk_avg(acc["rssi"]), "snr": stk_avg(acc["snr"]), "secs": STK_433_S}
    # APRS (gleiche Kette wie im Betrieb)
    prog("Stick %d SN %s: APRS 144,800 MHz (%d s)" % (no, sn, STK_APRS_S))
    conf = p("sdr_direwolf.conf", pl.base)
    try:
        if open(conf).read() != DIREWOLF_CONF:
            raise ValueError
    except Exception:
        with open(conf, "w") as f:
            f.write(DIREWOLF_CONF)
    acc = {"n": 0, "ids": set(), "audio": []}
    a = ["rtl_fm", "-f", str(c["faprs"]), "-s", "24000"] + pp
    if c.get("gain_aprs") not in (None, ""):
        a += ["-g", str(c["gain_aprs"])]
    early, er = stk_run_cmds([a + ["-d", str(int(idx)), "-"], ["direwolf", "-c", conf, "-r", "24000", "-D", "1", "-t", "0", "-q", "hd", "-"]],
                             STK_APRS_S, lambda ln: stk_parse_aprs(ln, acc), pl.base, pl.log)
    if early and acc["n"] == 0:
        r["errs"].append("APRS: beendet (%s)" % (er[-1] if er else "?"))
    r["aprs"] = {"n": acc["n"], "ids": len(acc["ids"]), "audio": stk_avg(acc["audio"]), "secs": STK_APRS_S}
    # Rauschboden/Spitze
    for key, f0 in (("pwr433", to_mhz(c["f433"]) * 1e6), ("pwraprs", to_mhz(c["faprs"]) * 1e6)):
        prog("Stick %d SN %s: Rauschboden %.3f MHz (%d s)" % (no, sn, f0 / 1e6, STK_PWR_S))
        acc = {"all": [], "near": []}
        rng = "%.3fM:%.3fM:10k" % ((f0 - 500e3) / 1e6, (f0 + 500e3) / 1e6)
        early, er = stk_run_cmds([["rtl_power", "-f", rng, "-i", "1", "-e", "%ds" % STK_PWR_S, "-g", noise_gain(c)] + pp + ["-d", str(int(idx)), "-"]],
                                 STK_PWR_S + 8, lambda ln, f0=f0: stk_parse_power(ln, f0, acc), pl.base, pl.log)
        fl = stk_med(acc["all"])
        r[key] = {"floor": None if fl is None else round(fl, 1), "peak": round(max(acc["near"]), 1) if acc["near"] else None, "n": len(acc["all"])}
        if fl is None:
            r["errs"].append("%s: keine Messwerte (%s)" % (key, er[-1] if er else "?"))
    return r


def _stk_md5(path):
    try:
        import hashlib
        with open(path, "rb") as f:
            return hashlib.md5(f.read()).hexdigest()
    except Exception:
        return None


def stk_write_atomic(path, obj):
    t = path + ".tmp"
    with open(t, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(t, path)


def stk_request(base, name, by):
    stk_write_atomic(p(name, base), {"t": int(time.time()), "by": str(by)[:20]})


def stk_take(base, name):
    """Anforderung abholen (Datei weg); zu alte verfallen."""
    f = p(name, base)
    if not os.path.exists(f):
        return None
    j = load_json(f, {}) or {}
    try:
        os.remove(f)
    except Exception:
        pass
    if not isinstance(j, dict) or not isinstance(j.get("t"), (int, float)) or abs(time.time() - j["t"]) > STK_REQ_MAX_AGE:
        return None
    return j


def stk_pause(pl, on, why=""):
    """Normalen Plan anhalten (beide Sticks frei) bzw. fortsetzen."""
    pl.st_pause = bool(on)
    if on:
        pl.kill()
        pl.special = None
        pl.active = "pause"
        w = pl.worker
        end = time.time() + 20
        while w is not None and (w.procs or w.active != "pause") and time.time() < end:
            time.sleep(0.5)
        pl.log("Plan angehalten:", why)
    else:
        pl.active = "idle"
        pl.log("Plan laeuft weiter")


def stk_run(pl, req):
    """Kompletter Stick-Test im Dienst (nacheinander, nie zwei Programme auf einem Stick). Modus/Lage werden nicht veraendert."""
    base = pl.base
    t0 = time.time()
    md0 = (_stk_md5(p("sdr_mode.json", base)), _stk_md5(p("sdr_lage.json", base)))
    sticks = [(1, cfg_serial(pl.cfg), ppm_val(pl.cfg), "Rundfunk fest" if pl.worker is not None else "alles")]
    sn2 = cfg_serial2(pl.cfg)
    if sn2:
        sticks.append((2, sn2, ppm_val(pl.worker.cfg) if pl.worker is not None else ppm_val({"ppm": pl.cfg.get("ppm2")}), "Wechselbetrieb"))
    eta = int(t0 + len(sticks) * (STK_433_S + STK_APRS_S + 2 * (STK_PWR_S + 6) + 8) + 25)
    state = {"running": True, "t0": int(t0), "eta": eta, "step": "Plan anhalten", "by": req.get("by")}

    def prog(s):
        state["step"] = s
        state["t"] = int(time.time())
        try:
            stk_write_atomic(p(STK_RUN, base), state)
            pl.status(get_mode(base), force=True)
        except Exception:
            pass
        pl.log("Stick-Test:", s)
    prog("Plan anhalten")
    res = {"v": 1, "t": int(t0), "by": req.get("by"), "sticks": []}
    stk_pause(pl, True, "Stick-Test")
    try:
        for no, sn, ppm, role in sticks:
            if sn is None:
                res["sticks"].append({"no": no, "sn": None, "present": False, "err": "Seriennummer ungueltig"})
                continue
            try:
                res["sticks"].append(stk_test_stick(pl, no, sn, ppm, role, prog))
            except Exception as e:
                res["sticks"].append({"no": no, "sn": sn, "present": False, "err": "Fehler: %s" % str(e)[:120]})
    finally:
        stk_pause(pl, False)
    res["dur"] = int(time.time() - t0)
    res["restored"] = md0 == (_stk_md5(p("sdr_mode.json", base)), _stk_md5(p("sdr_lage.json", base)))
    res["rec"] = stk_recommend(res)
    res["summary"] = stk_summary(res)
    d = p(os.path.join("archive", "sticktest", time.strftime("%Y-%m", time.localtime(t0))), base)
    try:
        os.makedirs(d, exist_ok=True)
        stk_write_atomic(os.path.join(d, "sticktest-%s.json" % time.strftime("%Y%m%d-%H%M%S", time.localtime(t0))), res)
    except Exception as e:
        pl.log("Stick-Test Archiv:", e)
    stk_write_atomic(p(STK_LAST, base), res)
    stk_write_atomic(p(STK_RUN, base), {"running": False, "t": int(time.time()), "last": int(t0)})
    for ln in res["summary"]:
        pl.log("Stick-Test:", ln)
    return res


def stk_relearn(pl, req):
    """QRM-/Rausch-Grundlinien archivieren (nicht loeschen) und neu lernen - ab jetzt je Stick (Messpunkte mit Seriennummer)."""
    base = pl.base
    now = time.time()
    d = p(os.path.join("archive", "noise-baseline", time.strftime("%Y%m%d-%H%M%S", time.localtime(now))), base)
    os.makedirs(d, exist_ok=True)
    moved = []
    with pl.lock:
        try:
            pl.snoise.save_hist(force=True, now=now)
        except Exception:
            pass
        for fn in ("noise_state.json", "sdr_noise_hist.json", "sdr_noise_hist.json.1", "noise_state.json.1"):
            src = p(fn, base)
            if os.path.exists(src):
                os.replace(src, os.path.join(d, fn))
                moved.append(fn)
        ns = NoiseState(base)
        pl.snoise = ns
        if pl.worker is not None:
            pl.worker.snoise = ns
    sns = [x for x in (cfg_serial(pl.cfg), cfg_serial2(pl.cfg)) if x]
    stk_write_atomic(p(STK_RELEARN, base), {"t": int(now), "archive": os.path.relpath(d, base), "files": moved, "sns": sns, "by": req.get("by")})
    pl.log("Grundlinien archiviert nach %s (%s), lernen neu je Stick %s" % (d, ", ".join(moved) or "keine Dateien", "/".join(sns)))


def stk_swap_cfg(base):
    """Rollen tauschen: Seriennummern und ppm-Werte von Stick 1 und 2 in sdr_config.json (atomar, Sicherung). -> (alt1, alt2)"""
    f = p("sdr_config.json", base)
    c = load_json(f, {}) or {}
    s2 = c.get("stick2") if isinstance(c.get("stick2"), dict) else None
    a, b = cfg_serial(c), cfg_serial2(c)
    if not s2 or not a or not b:
        raise RuntimeError("zwei Sticks muessen eingetragen sein")
    bak = f + ".bak-swap-%s" % time.strftime("%Y%m%d-%H%M%S")
    with open(f, "rb") as h, open(bak, "wb") as o:
        o.write(h.read())
    olds = sorted(x for x in os.listdir(base) if x.startswith("sdr_config.json.bak-swap-"))
    for x in olds[:-3]:
        try:
            os.remove(os.path.join(base, x))
        except Exception:
            pass
    c["serial"], s2["serial"] = b, a
    for k1, k2 in (("ppm", "ppm2"), ("ppm_cal", "ppm_cal2")):
        v1, v2 = c.get(k1), c.get(k2)
        if v2 is None:
            c.pop(k1, None)
        else:
            c[k1] = v2
        if v1 is None:
            c.pop(k2, None)
        else:
            c[k2] = v1
    c["stick2"] = s2
    stk_write_atomic(f, c)
    return a, b


def stk_poll(pl):
    """Im Hauptfaden des Dienstes: Anforderungen abholen und ausfuehren."""
    base = pl.base
    q = stk_take(base, STK_REQ_SWAP)
    if q:
        last = load_json(p(STK_LAST, base), {}) or {}
        if not ((last.get("rec") or {}).get("swap") and time.time() - (last.get("t") or 0) < 7 * 86400):
            pl.log("Empfehlung uebernehmen abgelehnt: kein aktueller Stick-Test mit Tausch-Empfehlung")
            stk_write_atomic(p("sdr_swap_result.json", base), {"t": int(time.time()), "ok": False, "why": "kein aktueller Stick-Test mit Tausch-Empfehlung"})
        else:
            try:
                a, b = stk_swap_cfg(base)
                stk_write_atomic(p("sdr_swap_result.json", base), {"t": int(time.time()), "ok": True, "stick1": b, "stick2": a})
                pl.log("Rollen getauscht: Stick 1 jetzt SN %s (Rundfunk), Stick 2 jetzt SN %s (Wechselbetrieb) - Dienst startet sich neu" % (b, a))
                pl.kill()
                if pl.worker is not None:
                    pl.st_pause = True
                    pl.worker.kill()
                pl.flush(True)
                os.execv(sys.executable, [sys.executable, os.path.abspath(__file__), "run"])
            except Exception as e:
                pl.log("Rollen tauschen:", e)
                stk_write_atomic(p("sdr_swap_result.json", base), {"t": int(time.time()), "ok": False, "why": str(e)[:120]})
    q = stk_take(base, STK_REQ_RELEARN)
    if q:
        try:
            stk_pause(pl, True, "Grundlinien neu lernen")
            stk_relearn(pl, q)
        except Exception as e:
            pl.log("Grundlinien neu lernen:", e)
        finally:
            stk_pause(pl, False)
    q = stk_take(base, STK_REQ)
    if q:
        try:
            stk_run(pl, q)
        except Exception as e:
            pl.log("Stick-Test:", e)
            stk_write_atomic(p(STK_RUN, base), {"running": False, "t": int(time.time()), "err": str(e)[:160]})


def stk_cli(base, what):
    """CLI: stick-test | stick-apply | noise-relearn - legt nur eine Anforderung an; ausgefuehrt wird im Dienst prepper-sdr."""
    st = load_json(p("sdr_status.json", base), {}) or {}
    if not isinstance(st.get("t"), (int, float)) or time.time() - st["t"] > 180:
        print("prepper-sdr laeuft nicht (Status aelter als 3 min) - Test laeuft nur ueber den Dienst (nie zweites Programm am Stick)", flush=True)
        return 1
    t0 = time.time()
    if what == "stick-test":
        stk_request(base, STK_REQ, "cli")
        print("Stick-Test angefordert - der Dienst haelt den Plan an und testet beide Sticks nacheinander (ca. 5 min, nur Empfang) ...", flush=True)
        last_step, end = None, t0 + 720
        while time.time() < end:
            time.sleep(3)
            r = load_json(p(STK_LAST, base), {}) or {}
            if isinstance(r.get("t"), (int, float)) and r["t"] >= t0 - 5:
                print("\n".join(r.get("summary") or stk_summary(r)), flush=True)
                return 0
            s = load_json(p(STK_RUN, base), {}) or {}
            if s.get("running") and s.get("step") != last_step:
                last_step = s.get("step")
                print("  ...", last_step, flush=True)
        print("Zeitueberschreitung - Ergebnis spaeter mit: prepper_sdr.py stick-last", flush=True)
        return 2
    if what == "noise-relearn":
        stk_request(base, STK_REQ_RELEARN, "cli")
        end = t0 + 120
        while time.time() < end:
            time.sleep(2)
            r = load_json(p(STK_RELEARN, base), {}) or {}
            if isinstance(r.get("t"), (int, float)) and r["t"] >= t0 - 5:
                print("Grundlinien archiviert nach %s (%s) - lernen neu je Stick %s" % (r.get("archive"), ", ".join(r.get("files") or []) or "keine Dateien", "/".join(r.get("sns") or [])), flush=True)
                return 0
        print("Zeitueberschreitung", flush=True)
        return 2
    if what == "stick-apply":
        last = load_json(p(STK_LAST, base), {}) or {}
        if not (last.get("rec") or {}).get("swap"):
            print("Keine Tausch-Empfehlung im letzten Stick-Test - nichts geaendert", flush=True)
            return 1
        stk_request(base, STK_REQ_SWAP, "cli")
        end = t0 + 90
        while time.time() < end:
            time.sleep(2)
            r = load_json(p("sdr_swap_result.json", base), {}) or {}
            if isinstance(r.get("t"), (int, float)) and r["t"] >= t0 - 5:
                print(("Rollen getauscht: Stick 1 SN %s (Rundfunk), Stick 2 SN %s (Wechselbetrieb)" % (r.get("stick1"), r.get("stick2"))) if r.get("ok") else "nicht getauscht: %s" % r.get("why"), flush=True)
                return 0 if r.get("ok") else 1
        print("Zeitueberschreitung", flush=True)
        return 2
    if what == "stick-last":
        print("\n".join(stk_summary(load_json(p(STK_LAST, base), {}) or {})), flush=True)
        return 0
    return 1


def selftest_sticktest():
    import tempfile
    tmp = tempfile.mkdtemp()
    acc = {"n": 0, "ids": set(), "rssi": [], "snr": []}
    for ln in SAMPLES_433:
        stk_parse_433(ln, acc)
    assert acc["n"] == 4 and len(acc["ids"]) == 3 and stk_avg(acc["snr"]) == 21.2, acc
    acc = {"n": 0, "ids": set(), "audio": []}
    for ln in SAMPLES_APRS:
        stk_parse_aprs(ln, acc)
    assert acc["n"] >= 8 and acc["audio"] == [34], acc
    acc = {"all": [], "near": []}
    stk_parse_power("2026-10-13, 12:00:00, 433420000, 434420000, 10000.00, 100, " + ", ".join(["-40"] * 49 + ["-20"] + ["-40"] * 50), 433.92e6, acc)
    assert stk_med(acc["all"]) == -40 and max(acc["near"]) == -20, acc
    assert stk_cmp({"n": 40}, {"n": 12}, False)[0] == 1
    assert stk_cmp({"n": 12}, {"n": 15}, False)[2] == "aehnlich"
    assert stk_cmp({"n": 2}, {"n": 3}, False)[2] == "wenig"
    assert stk_cmp({"n": 8, "snr": 20}, {"n": 9, "snr": 14}, True)[0] == 1 and stk_cmp({"n": 8, "snr": 20}, {"n": 9, "snr": 14}, False)[0] is None
    assert stk_cmp({"n": 9}, None, False)[2] == "fehlt"
    res = {"t": 1760000000, "by": "x", "dur": 300, "restored": True, "sticks": [
        {"no": 1, "sn": "19348831", "present": True, "433": {"n": 40, "snr": 20}, "aprs": {"n": 20}},
        {"no": 2, "sn": "72055505", "present": True, "433": {"n": 10, "snr": 18}, "aprs": {"n": 6}}]}
    rc = stk_recommend(res)
    assert rc["swap"] and rc["rows"][0]["sn"] == "19348831" and "433 MHz (besser)" in rc["rows"][0]["txt"], rc
    res["sticks"][1]["aprs"]["n"] = 40
    assert not stk_recommend(res)["swap"]
    res["rec"] = stk_recommend(res)
    assert any("Gesamt" in x for x in stk_summary(res))
    save_cfg_keys(tmp, {"serial": "19348831", "stick2": {"serial": "72055505", "enabled": True}, "ppm": 1, "ppm2": -3})
    stk_swap_cfg(tmp)
    c = load_json(p("sdr_config.json", tmp), {})
    assert c["serial"] == "72055505" and c["stick2"]["serial"] == "19348831" and c["ppm"] == -3 and c["ppm2"] == 1, c
    stk_request(tmp, STK_REQ, "t")
    assert stk_take(tmp, STK_REQ)["by"] == "t" and stk_take(tmp, STK_REQ) is None
    write_json(p(STK_REQ, tmp), {"t": 1})
    assert stk_take(tmp, STK_REQ) is None  # verfallen
    ns = NoiseState(tmp)
    ns.sn = "1"
    ns.h["n2m"] = [{"ts": 1000, "floor": -30, "sn": "1"}, {"ts": 1000, "floor": -10, "sn": "2"}, {"ts": 1000, "floor": -20}]
    assert [x["floor"] for x in ns.ref("n2m", "floor", 5000, 0, 9999)] == [-30, -20]
    print("selftest stickTest ok (Auswertung, Schwellen, Empfehlung, Tausch, Anforderungen, Grundlinie je Stick)")
# ===== /stickTest =====


STMOD_EOF
EXPECT_EDIT="e8362bf354bd0fd54b6e91f5edfaaa23e82955221dc3d046f37f724e823ce531"
cat > "$W/edit-st.py" << 'STEDIT_EOF'
import sys,re
src=open(sys.argv[1]).read(); mod=open(sys.argv[3]).read()
if "# ===== stickTest:" in src:
    open(sys.argv[2],'w').write(src); print("schon da"); raise SystemExit(0)
def rep(a,b,n=1):
    global src
    assert src.count(a)==n,(a,src.count(a)); src=src.replace(a,b)
# NoiseState je Stick
rep('        self.last_hsave = 0\n        self.hdirty = False\n','        self.last_hsave = 0\n        self.hdirty = False\n        self.sn = None  # stickTest: Messpunkte je Stick (Seriennummer)\n')
rep('            if lo_s <= a < hi_s and _fin(x.get(key)):\n','            if self.sn and x.get("sn") and x.get("sn") != self.sn:\n                continue  # stickTest: Grundlinie nur vom selben Stick\n            if lo_s <= a < hi_s and _fin(x.get(key)):\n')
rep('        pt = {"ts": now, "_h": _hour(now), "floor": round(floor, 1), "car": len(pers)}\n','        pt = {"ts": now, "_h": _hour(now), "floor": round(floor, 1), "car": len(pers)}\n        if self.sn:\n            pt["sn"] = self.sn\n')
rep('[{"ts": now, "_h": _hour(now), "bb_pm": bb, "base": th["base"]}]','[dict({"ts": now, "_h": _hour(now), "bb_pm": bb, "base": th["base"]}, **({"sn": self.sn} if self.sn else {}))]')
rep('                        self.snoise.finish_block(self.cfg, now)\n','                        self.snoise.sn = self.dev_sn\n                        self.snoise.finish_block(self.cfg, now)\n')
rep('                        self.snoise.add(r, self.cfg, now)\n','                        self.snoise.sn = self.dev_sn\n                        self.snoise.add(r, self.cfg, now)\n')
rep('        self.stop = False\n        self.lock = threading.Lock()\n','        self.stop = False\n        self.st_pause = False  # stickTest\n        self.lock = threading.Lock()\n')
# Worker pausiert
rep('''        while not self.main.stop:
            try:
                wait, mode = self.step()''','''        while not self.main.stop:
            if getattr(self.main, "st_pause", False):  # stickTest: Plan angehalten, Stick frei
                if self.procs:
                    self.kill()
                self.special = None
                self.active = "pause"
                time.sleep(0.5)
                continue
            try:
                wait, mode = self.step()''')
rep('''            try:
                self.dual_tick()
            except Exception as e:
                self.log("Stick-Rollen:", e)
''','''            try:
                stk_poll(self)  # stickTest: Anforderungen (Stick-Test, Grundlinien, Tausch) nur hier im Dienst
            except Exception as e:
                self.log("stickTest:", e)
            try:
                self.dual_tick()
            except Exception as e:
                self.log("Stick-Rollen:", e)
''')
# Hauptschleife soll Anforderungen bald sehen: kurze Wartezeit-Schleife pruefen
rep('# ---------------------------------------------------------------- Selbsttest (ohne Stick)\n', mod+'# ---------------------------------------------------------------- Selbsttest (ohne Stick)\n')
rep('''    elif a == "selftest":
        selftest()''','''    elif a == "selftest":
        selftest()
        selftest_sticktest()
    elif a in ("stick-test", "stick-apply", "noise-relearn", "stick-last"):
        sys.exit(stk_cli(BASE, a))''')
rep('''            while not self.stop and time.time() < end:
                time.sleep(0.5)
                gm = get_mode(self.base)
''','''            while not self.stop and time.time() < end:
                time.sleep(0.5)
                if any(os.path.exists(p(x, self.base)) for x in (STK_REQ, STK_REQ_RELEARN, STK_REQ_SWAP)):
                    break  # stickTest: Anforderung gleich abholen
                gm = get_mode(self.base)
''')
open(sys.argv[2],'w').write(src)
print('geaendert')
STEDIT_EOF
EXPECT_GUARD="130727edc5cf4c0816676532a8147646908b4a7577c659a00c9e3d4be32dacac"
cat > "$W/guard_sdr.py" << 'STGUARD_EOF'
import ast, sys
def info(fn):
    t = ast.parse(open(fn, encoding="utf-8").read()); imp, calls, bad = set(), [], 0
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names: imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False): bad += 1
        if isinstance(n, ast.Call):
            f = n.func; calls.append(f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
    return imp, calls, bad
bi, bc, bb = info(sys.argv[1]); ni, nc, nb = info(sys.argv[2])
inst = "# ===== stickTest:" in open(sys.argv[1], encoding="utf-8").read()
allow = {"Popen": 1, "Thread": 2, "execv": 1}
err = []
if ni - bi - {"hashlib", "tempfile"}: err.append("Importe neu %s" % (ni - bi))
if nb != bb: err.append("shell=True neu")
for nm in ("send_meshtastic", "sendText", "sendData", "urlopen", "socket", "create_connection", "bind", "listen", "connect", "system", "Popen", "Thread", "Timer", "execv", "run", "call", "check_output", "HTTPServer", "serve_forever"):
    d = nc.count(nm) - bc.count(nm)
    if d != (0 if inst else allow.get(nm, 0)): err.append("Aufrufe %s %+d" % (nm, d))
src = open(sys.argv[2], encoding="utf-8").read()
blk = src[src.index("# ===== stickTest:"):src.index("# ===== /stickTest =====")]
if "mesh" in blk.lower() and "meshtastic" in blk.lower(): err.append("Block erwaehnt Meshtastic")
for w in ("rtl_tcp", "rtl_sdr", "-T", "transmit"):
    if '"%s"' % w in blk: err.append("Block nutzt " + w)
if err: print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard prepper_sdr: keine Sendestelle/Netz/Server neu, kein shell=True; neu nur Popen +%d (Testkette), Thread +%d (Leser), execv +%d (Neustart nach Tausch)" % tuple(0 if inst else allow[k] for k in ("Popen", "Thread", "execv")))
STGUARD_EOF
P="$W/patch-stk.py"; LB="$W/st_block.py"; SM="$W/stk_mod.py"; SE="$W/edit-st.py"; SG="$W/guard_sdr.py"
for x in "$EXPECT_BLK $LB" "$EXPECT_PATCH $P" "$EXPECT_MOD $SM" "$EXPECT_EDIT $SE" "$EXPECT_GUARD $SG"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
LT=$(grep -c "# ===== lageTest:" "$F" || true)
if [[ "$LT" != 1 ]]; then echo "STOP: lageTest-Guard fehlt in dashboard.py (sha16 $D16) - erwartet sdrDual $BASE_DASH16 + lageTest - nichts geaendert"; exit 1; fi
if [[ "$S16" != "$BASE_MOD16" ]] && ! grep -q "# ===== stickTest:" "$M"; then echo "STOP: prepper_sdr.py sha16 $S16 erwartet $BASE_MOD16 - nichts geaendert"; exit 1; fi
grep -q "# ===== sdrDual:" "$F" && grep -q "# ===== piPolish2:" "$F" || { echo "STOP: sdrDual/piPolish2 fehlt - nichts geaendert"; exit 1; }
echo "OK Basis dashboard.py $D16 ($(wc -l < "$F") Zeilen, lageTest=$LT), prepper_sdr.py $S16 ($(wc -l < "$M") Zeilen)"
SDR_ACT=$(systemctl is-active prepper-sdr 2>/dev/null || true)
[[ "$SDR_ACT" == active ]] || { echo "STOP: prepper-sdr ist nicht aktiv ($SDR_ACT) - erst Dienst pruefen, nichts geaendert"; exit 1; }
# ---------- 2) Trockenlauf ----------
python3 "$SE" "$M" "$W/work/prepper_sdr.py" "$SM" >/dev/null || { echo "STOP: prepper_sdr-Basis passt nicht - nichts geaendert"; exit 1; }
python3 "$SE" "$W/work/prepper_sdr.py" "$W/work/s2.py" "$SM" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/s2.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
python3 "$P" "$F" "$W/work/dashboard.py" "$LB" >/dev/null || { echo "STOP: Dashboard-Basis passt nicht - nichts geaendert"; exit 1; }
python3 "$P" "$W/work/dashboard.py" "$W/work/d2.py" "$LB" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/d2.py" || { echo "STOP: Dashboard nicht idempotent"; exit 1; }
for py in "$SPY" "$VPY"; do
  "$py" -W error -m py_compile "$W/work/prepper_sdr.py" || { echo "STOP: py_compile prepper_sdr ($py) - nichts geaendert"; exit 1; }
done
"$VPY" -W error -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile dashboard - nichts geaendert"; exit 1; }
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest ($py) - nichts geaendert"; exit 1; }
  grep -q "selftest stickTest ok" "$W/selftest.log" || { echo "STOP: Selbsttest stickTest fehlt ($py)"; exit 1; }
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY: $(grep 'selftest stickTest ok' "$W/selftest.log")"
# ---------- 3) AST-Guard ----------
python3 "$SG" "$M" "$W/work/prepper_sdr.py" || { echo "STOP: Guard prepper_sdr - nichts geaendert"; exit 1; }
python3 - "$F" "$W/work/dashboard.py" "$LB" "$P" << 'GUARDPY' || { echo "STOP: Guard Dashboard - nichts geaendert"; exit 1; }
import ast, sys
def info(fn):
    t = ast.parse(open(fn, encoding="utf-8").read()); imp, calls, bad = set(), [], []
    for n in ast.walk(t):
        if isinstance(n, (ast.Import, ast.ImportFrom)):
            for a in n.names: imp.add((getattr(n, "module", None) or a.name).split(".")[0])
        if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False): bad.append("shell=")
        if isinstance(n, ast.Call):
            f = n.func; calls.append(f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""))
    return imp, calls, bad
bi, bc, bb = info(sys.argv[1]); ni, nc, nb = info(sys.argv[2]); li, lc, lb = info(sys.argv[3]); pi, pc, pb = info(sys.argv[4])
err = []
if ni != bi: err.append("Importe geaendert %s" % (ni ^ bi))
if len(nb) != len(bb): err.append("shell=True neu")
for nm in ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "Popen", "system", "run", "call", "check_output", "urlopen", "socket", "create_connection", "bind", "listen", "Thread", "Timer"):
    if nc.count(nm) != bc.count(nm): err.append("Aufrufe %s geaendert (%d->%d)" % (nm, bc.count(nm), nc.count(nm)))
    if nm in lc: err.append("Block ruft %s" % nm)
inst = "# ===== stickTest:" in open(sys.argv[1], encoding="utf-8").read()
if nc.count("add_url_rule") != bc.count("add_url_rule") + (0 if inst else 1): err.append("genau eine neue Route erwartet")
if nc.count("after_request") != bc.count("after_request") + (0 if inst else 1): err.append("genau ein neuer after_request erwartet")
if [c for c in lc if c.startswith(("send", "maybe_mesh"))]: err.append("Block: Sendeaufruf")
if li - {"html", "json", "os", "time", "flask"} or pi - {"sys"}: err.append("Importe Block/Patch %s %s" % (li, pi))
blk = open(sys.argv[3], encoding="utf-8").read()
if "mesh" in blk.lower(): err.append("Block erwaehnt mesh")
js = blk[blk.index('_STK_JS = r"""'):]; js = js[:js.index('"""', 16)]
if js.count("fetch(") != 2 or js.count("method:'POST'") != 1 or js.count("fetch('/api/sdr/sticktest'") != 2 or "confirm(" not in js: err.append("JS: nur Anforderung-POST (mit Bestaetigung) + Status-GET erlaubt")
for w in ("XMLHttpRequest", "WebSocket", "sendBeacon", "eval("):
    if w in js: err.append("JS enthaelt " + w)
if 'add_url_rule("/api/sdr/sticktest"' not in blk or blk.count("add_url_rule") != 1: err.append("Route")
if err: print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard Dashboard: keine Sendestelle (send_meshtastic %d=%d), keine Prozesse/Netz/Threads neu, genau 1 Route (/api/sdr/sticktest, legt nur Anforderungsdatei an) + 1 after_request, JS nur mit Bestaetigung" % (bc.count("send_meshtastic"), nc.count("send_meshtastic")))
GUARDPY
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons)"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys,time
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
md5s() { local x; for x in "$DASH_DIR/sdr_mode.json" "$DASH_DIR/sdr_lage.json"; do if [[ -f "$x" ]]; then md5sum "$x" | cut -c1-32 | tr '\n' ' '; else printf 'fehlt '; fi; done; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie)
declare -A PRE
for p in "${PAGES[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 4) Installieren ----------
RESTARTED=0
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK stickTest schon installiert - kein Neustart"
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -15 | cut -c1-200 || true
    sudo systemctl stop prepper-sdr.service || true
    for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json"; do
      [[ -f "$x.bak-sticktest-$TS" ]] && cp -a "$x.bak-sticktest-$TS" "$x.rb" && mv -f "$x.rb" "$x"
    done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    for x in "$F" "$M"; do cmp -s "$x" "$x.bak-sticktest-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), Stick 2 im Config: $(grep -c '"stick2"' "$DASH_DIR/sdr_config.json" || true)"
  }
  for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-sticktest-$TS"
    { ls -1t "$x.bak-sticktest-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  sudo systemctl stop prepper-sdr.service
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-sticktest-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-sticktest-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-sdr und prepper-dashboard - warte auf HTTP und SDR-Status (max 240 s; sendet nichts) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  ok=0; for i in $(seq 1 60); do systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && { ok=1; break; }; sleep 2; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr schreibt keinen frischen Status"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 5) Rauchtest ----------
fail=0
for p in "${PAGES[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite antwortet schlechter als vorher"
for p in /api/sdr/ui /api/br24 /api/sdr/sticktest; do c=$(code_r "$B$p"); printf '  HTTP %s = %s\n' "$p" "$c"; [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" || true
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" || true
python3 - "$W/pi.html" "$W/funk.html" << 'PY' || rbx "Kachel Antennentest fehlt"
import sys
pi = open(sys.argv[1], encoding="utf-8", errors="replace").read(); fk = open(sys.argv[2], encoding="utf-8", errors="replace").read()
assert fk.count('id="stickTestCard"') == 1 and fk.count('id="stk-js"') == 1, "Kachel/JS auf /funk fehlt"
assert fk.find('id="stickTestCard"') > fk.rfind('class="card', 0, fk.find('id="stickTestCard"') - 30), "Kachel nicht als letzte"
assert "stickTestCard" not in pi, "/pi darf nichts zeigen"
print("OK /funk: Kachel Antennentest ganz unten (Knoepfe Antennentest starten / Neu lernen / Empfehlung uebernehmen); /pi unveraendert")
PY
c=$(code -X POST -H 'Content-Type: application/json' -H 'X-Stick-Test: 1' -d '{"action":"start"}' "$B/api/sdr/sticktest")
[[ "$c" == 403 ]] && echo "OK fremder Aufruf ohne gleichen Ursprung abgelehnt (403)" || rbx "Anforderung ohne Ursprung nicht abgelehnt ($c)"
[[ -f "$DASH_DIR/sdr_req_sticktest" ]] && rbx "Anforderungsdatei trotz 403 angelegt"
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] || rbx "/pi Sicherung veraendert ($R0/$R1)"
echo "OK /pi doPrepperRestore unveraendert ($R1)"
# ---------- 6) Stick-Test einmal (ca. 5 min, nur Empfang, im Dienst) ----------
MD0=$(md5s)
echo "=== Stick-Test laeuft jetzt im Dienst prepper-sdr (ca. 5 min, nur Empfang, Plan pausiert) ==="
STR=0; "$SPY" "$M" stick-test || STR=$?
MD1=$(md5s)
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr nach Stick-Test nicht aktiv"
ok=0; T1=$(date +%s); for i in $(seq 1 40); do sdr_fresh "$T1" && { ok=1; break; }; sleep 3; done
[[ "$ok" == 1 ]] && echo "OK prepper-sdr laeuft nach dem Test normal weiter (Status frisch)" || echo "WARNUNG: SDR-Status nach Test nicht frisch"
[[ "$MD0" == "$MD1" ]] && echo "OK Modus/Lage-Dateien vorher = nachher" || echo "WARNUNG: sdr_mode/sdr_lage geaendert ($MD0 / $MD1)"
[[ "$STR" == 0 ]] || echo "WARNUNG: Stick-Test-CLI Rueckgabe $STR (Ergebnis spaeter: python3 $M stick-last)"
echo "Rollen NICHT geaendert. Tausch nur mit /funk-Kachel Antennentest 'Empfehlung uebernehmen' oder: python3 $M stick-apply"
# ---------- 7) Grundlinien neu lernen (archivieren, nicht loeschen) ----------
"$SPY" "$M" noise-relearn || echo "WARNUNG: Grundlinien neu lernen nicht bestaetigt"
c=$(code_r "$B/api/sdr/ui"); [[ "$c" == 200 ]] || rbx "/api/sdr/ui nach Test $c"
echo "OK /api/sdr/ui = 200 nach Test"
echo "OK guards stickTest(dash)=$(grep -c '# ===== stickTest:' "$F" || true) stickTest(sdr)=$(grep -c '# ===== stickTest:' "$M" || true) lageTest=$(grep -c '# ===== lageTest:' "$F" || true) sdrDual=$(grep -c '# ===== sdrDual:' "$F" || true) lageMesh1=$(grep -c '# ===== lageMesh1:' "$F" || true) piPolish2=$(grep -c '# ===== piPolish2:' "$F" || true) sdrLage=$(grep -c '# ===== sdrLage:' "$F" || true) sdrUi=$(grep -c '# ===== sdrUi:' "$F" || true)"
[[ -f "$F.bak-sticktest-$TS" ]] && echo "Backups: *.bak-sticktest-$TS (dashboard.py, prepper_sdr.py, sdr_lage.json, sdr_config.json), behalten: letzte $KEEP_LAST"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; prepper_sdr.py sha16 $(sha256sum "$M" | cut -c1-16), $(wc -l < "$M") Zeilen"
echo "COMMIT $COMMIT_ARG stickTest=1"
