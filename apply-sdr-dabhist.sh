#!/bin/bash
set -euo pipefail
# dabHist: SDR-Kachel /funk - BR24 (DAB 11D) und ASA DE (DAB 5C) als zwei normale Zeilen (Punkt, Symbol, fett, verlinkt, 'vor x min', naechste Pruefung),
# Verlauf aller DAB-Textmeldungen von 11D/5C (prepper-sdr: sdr_dabhist.json Ring + archive/dabhist/YYYY-MM/*.jsonl), Seite /dabhist. Nur Empfang/Anzeige.
# Neustart nur prepper-sdr und prepper-dashboard. Sendet nichts.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/dabhist-apply
KEEP_LAST=3
BASE_DASH16="08ce880bd1259a08"  # live mit stickTestFix (17382 Zeilen)
BASE_MOD16="e37420ade316793e"  # live mit stickTestFix (4901 Zeilen)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== dabHist apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"
EXPECT_BLK="d13c519bb152d3a246426072f4b4fec75e7a7c1f5571dd7a9b73e98394428ac5"
cat > "$W/dh_block.py" << 'DHBLK_EOF'
# ===== dabHist: SDR-Kachel auf /funk - BR24 (DAB 11D) und ASA DE (DAB 5C) als zwei normale Zeilen wie APRS/433 (Punkt, Symbol, fett, verlinkt, "vor x min", naechste Pruefung); Seite /dabhist mit allen DAB-Textmeldungen (nur Anzeige) =====
import html as _dh_html
import time as _dh_time

_DH_CH = {"11D": "DAB 11D (BR24)", "5C": "DAB 5C (ASA DE)"}


def _dh_events():
    try:
        d = _sdr_load("sdr_dabhist.json", {}) or {}
        ev = d.get("ev") if isinstance(d, dict) else None
        return [x for x in (ev or []) if isinstance(x, dict) and isinstance(x.get("t"), (int, float))]
    except Exception as e:
        print("dabHist lesen:", e, flush=True)
        return []


def _dh_last(ev, ch):
    for x in reversed(ev):
        if x.get("ch") == ch:
            return x
    return None


def _dh_lvl(st):
    return {"gruen": "ok", "rot": "rot", "gelb": "gelb"}.get(st, "aus")


def _dh_core(l1, prefixes):
    """Kanal/Dienstnamen aus dem Text nehmen (stehen schon im fetten Zeilennamen)."""
    s = str(l1 or "").strip()
    for pf in prefixes:
        if s.startswith(pf + " ") or s == pf:
            s = s[len(pf):].strip(" ·")
    return " · ".join(x for x in s.split(" · ") if x.strip() not in ("DAB 11D", "DAB 5C", "BR24", "ASA DE")).strip(" ·")


def _dh_rows(r, now=None):
    """Zwei Zeilen fuer die SDR-Kachel aus dem /api/br24-Zustand."""
    now = now or _dh_time.time()
    r = r if isinstance(r, dict) else {}
    ev = _dh_events()
    plan = r.get("bc_plan") if isinstance(r.get("bc_plan"), dict) else {}
    b = r.get("br24_row") if isinstance(r.get("br24_row"), dict) else {}
    a = r.get("asa_row") if isinstance(r.get("asa_row"), dict) else {}
    out = []
    lb = _dh_last(ev, "11D")
    bst = b.get("state") or r.get("state")
    btx = _dh_core(b.get("l1") or r.get("text"), ("BR24",))
    if bst != "rot" and not btx:
        btx = "empfangen" if r.get("last_rx") else "noch nicht empfangen"
    out.append({"k": "br24", "lvl": _dh_lvl(bst), "icon": "📻", "label": "BR24 (DAB 11D):", "text": btx or "–",
                "t": r.get("last_rx") if isinstance(r.get("last_rx"), (int, float)) else None, "next": plan.get("br24") if isinstance(plan.get("br24"), (int, float)) else None,
                "run": plan.get("run") == "br24", "href": "/dabhist?ch=11D", "warn": bst == "rot",
                "tip": ("letzte DAB-Meldung %s: %s" % (_dh_time.strftime("%d.%m. %H:%M", _dh_time.localtime(lb["last"] or lb["t"])), lb.get("text"))) if lb else "noch keine DAB-Textmeldung von 11D gespeichert"})
    la = _dh_last(ev, "5C")
    ast = a.get("state")
    atx = _dh_core(a.get("l1"), ("ASA DE",))
    out.append({"k": "asa", "lvl": _dh_lvl(ast), "icon": "📢", "label": "ASA DE (DAB 5C):", "text": atx or "–",
                "t": a.get("t") if isinstance(a.get("t"), (int, float)) else None, "next": plan.get("asa") if isinstance(plan.get("asa"), (int, float)) else None,
                "run": plan.get("run") == "asa", "href": "/dabhist?ch=5C", "warn": ast == "rot",
                "tip": ("letzte DAB-Meldung %s: %s" % (_dh_time.strftime("%d.%m. %H:%M", _dh_time.localtime(la["last"] or la["t"])), la.get("text"))) if la else "noch keine DAB-Textmeldung von 5C gespeichert"})
    return out


_dh_orig_br24 = _br24_state


def _br24_state():
    r = _dh_orig_br24()
    try:
        r["dh_rows"] = _dh_rows(r)
    except Exception as e:
        print("dabHist Zeilen:", e, flush=True)
    return r


def _dh_page():
    from flask import request as rq
    e = _dh_html.escape
    try:
        ch = (rq.args.get("ch") or "").upper()
        ch = ch if ch in _DH_CH else ""
        ev = _dh_events()
        rows = [x for x in ev if not ch or x.get("ch") == ch][::-1][:500]
        fm = lambda t: _dh_time.strftime("%d.%m.%Y %H:%M:%S", _dh_time.localtime(t)) if isinstance(t, (int, float)) else "–"
        trs = []
        for x in rows:
            n = int(x.get("n") or 1)
            trs.append('<tr class="%s"><td class="dh-t">%s%s</td><td>%s</td><td>%s</td><td class="dh-x">%s</td><td class="dh-n">%d</td><td>%s</td></tr>' % (
                "dh-warn" if x.get("warn") else "", e(fm(x.get("t"))),
                ('<br><span class="dh-s">bis %s</span>' % e(fm(x.get("last")))) if n > 1 and x.get("last") != x.get("t") else "",
                e(str(x.get("ch") or "")), e(str(x.get("src") or "")), e(str(x.get("text") or "")), n, "⚠" if x.get("warn") else ""))
        flt = " ".join('<a href="/dabhist%s"%s>%s</a>' % (("?ch=" + k) if k else "", ' class="on"' if k == ch else "", e(v))
                       for k, v in (("", "alle"), ("11D", "11D BR24"), ("5C", "5C ASA DE")))
        tab = ('<table class="dh-tab"><thead><tr><th>Zeit</th><th>Kanal</th><th>Quelle</th><th>Text</th><th>Anz.</th><th>Warn</th></tr></thead><tbody>%s</tbody></table>' % "".join(trs)) if trs \
            else '<div class="dh-empty">noch keine Nachrichten</div>'
        body = ('<div class="card"><div class="title">📻 DAB-Meldungen %s</div><div class="dh-f">%s</div>'
                '<div class="dh-sub">%d Einträge%s · gleiche Folgemeldung wird gezählt (Anz.) · Archiv: archive/dabhist/</div>%s</div>') % (
            e(_DH_CH.get(ch, "11D + 5C")), flt, len(rows), " (neueste 500)" if len(rows) >= 500 else "", tab)
    except Exception as ex:
        print("dabHist Seite:", ex, flush=True)
        body = '<div class="card"><div class="title">📻 DAB-Meldungen</div><div class="dh-empty">noch keine Nachrichten (Verlauf nicht lesbar)</div></div>'
    nav = globals().get("NAV_UNIFY") or ""
    nav = nav if isinstance(nav, str) and "{{" not in nav and "{%" not in nav else ""
    css = globals().get("BASE_STYLE") or ""
    css = css if isinstance(css, str) and "{{" not in css and "{%" not in css else ""
    sc = globals().get("_SDR_CSS") or ""
    return ('<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">'
            '<title>DAB-Meldungen</title><style>%s%s%s</style></head><body>%s<div class="sdr-wrap"><div class="header"><div class="brand">Käswasser Lage Monitor</div>DAB-Meldungen</div>'
            '<div class="sdrsub" style="margin:4px 0 10px"><a href="/funk433">📡 433 MHz</a> <a href="/aprs">📻 APRS</a> <a href="/rundfunk">📻 Rundfunk</a> <a href="/funk">↩ Funk</a></div>%s</div></body></html>') % (
        css, sc, _DH_CSS, nav, body)


_DH_CSS = """.dh-tab{width:100%;border-collapse:collapse;font-size:.88rem}.dh-tab th,.dh-tab td{border-bottom:1px solid #334155;padding:4px 6px;text-align:left;vertical-align:top}
.dh-tab td.dh-x{overflow-wrap:anywhere;min-width:0}.dh-tab td.dh-t{white-space:nowrap;font-variant-numeric:tabular-nums}.dh-tab td.dh-n{text-align:right}
.dh-tab tr.dh-warn td{color:#fca5a5}.dh-s{opacity:.7;font-size:.85em}.dh-f a{margin-right:10px}.dh-f a.on{font-weight:700;text-decoration:underline}
.dh-sub{font-size:.8rem;opacity:.7;margin:6px 0}.dh-empty{opacity:.75;padding:10px 0}
@media (max-width:600px){.dh-tab th:nth-child(3),.dh-tab td:nth-child(3){display:none}}"""

_DH_JS = r"""<style id="dh-css">#sdrUiCard #br24Row{display:none !important}
#sdrUiCard .su-row.dh-row{white-space:normal !important;align-items:flex-start !important;overflow:visible !important}
#sdrUiCard .su-row.dh-row .su-dot{margin-top:.35em}
#sdrUiCard .su-row.dh-row .su-v{white-space:normal !important;overflow:visible !important;text-overflow:clip !important;overflow-wrap:anywhere;min-width:0}
#sdrUiCard .su-row.dh-row.rot .su-v{color:#fca5a5}#sdrUiCard .su-row.dh-row.rot .su-k{color:#fca5a5}</style>
<script id="dh-js">(function(){var D=null,N0=0,T0=Date.now();
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function now(){return N0+Math.round((Date.now()-T0)/1000);}
function p2(n){return (n<10?'0':'')+n;}
function hm(t){var d=new Date(t*1000);return p2(d.getHours())+':'+p2(d.getMinutes());}
function ago(t){if(!t)return 'noch nie';var s=now()-t;if(s<60)return 'gerade eben';if(s<3600)return 'vor '+Math.floor(s/60)+' min';if(s<86400)return 'vor '+Math.floor(s/3600)+' h '+Math.floor(s%3600/60)+' min';var d=new Date(t*1000);return p2(d.getDate())+'.'+p2(d.getMonth()+1)+'. '+hm(t);}
function txt(r){return r.text+' · '+ago(r.t)+(r.run?' · prüft gerade':(r.next?' · nächste '+hm(r.next):''));}
function fix(){var c=document.getElementById('sdrUiCard');if(!c||!D)return;var rf=c.querySelector('.su-row[data-su=rf]');if(!rf)return;var R=D.dh_rows||[];
var ex=c.querySelectorAll('.dh-row');var ok=ex.length===R.length&&ex.length&&ex[0].previousElementSibling===rf;
if(ok){for(var i=0;i<R.length;i++){var v=ex[i].querySelector('.su-v'),s=txt(R[i]);if(v&&v.textContent!==s)v.textContent=s;}return;}
for(var j=0;j<ex.length;j++)ex[j].remove();var ref=rf.nextSibling;
R.forEach(function(r){var x=el('div','su-row dh-row '+(r.lvl||'aus'));var d=el('span','su-dot '+(r.lvl||'aus'));d.setAttribute('aria-label',r.lvl||'aus');x.appendChild(d);
x.appendChild(el('span','su-i',r.icon||''));x.appendChild(el('span','su-k',r.label||''));var a=el('a','su-v',txt(r));a.href=r.href;x.appendChild(a);if(r.tip)x.title=r.tip;rf.parentNode.insertBefore(x,ref);});}
function load(){fetch('/api/br24',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.dh_rows){D=j;N0=j.now||Math.round(Date.now()/1000);T0=Date.now();var c=document.getElementById('sdrUiCard');if(c){var ex=c.querySelectorAll('.dh-row');for(var i=0;i<ex.length;i++)ex[i].remove();}fix();}}).catch(function(){});}
load();setInterval(fix,1000);setInterval(load,30000);})();</script>"""


def _dh_after(resp):
    try:
        from flask import request as rq
        if rq.path != "/funk" or resp.status_code != 200 or resp.direct_passthrough:
            return resp
        if resp.headers.get("Content-Encoding") or (resp.mimetype or "") != "text/html":
            return resp
        body = resp.get_data(as_text=True)
        if 'id="dh-js"' in body:
            return resp
        j = body.rfind("</body>")
        if j >= 0:
            resp.set_data(body[:j] + _DH_JS + body[j:])
    except Exception as e:
        print("dabHist /funk:", e, flush=True)
    return resp


def _dh_selftest():
    now = 1760000000
    r = {"state": "gruen", "last_rx": now - 120, "bc_plan": {"br24": now + 600, "asa": None, "run": "asa"},
         "br24_row": {"l1": "BR24 empfangen · DAB 11D", "l2": "", "state": "gruen"}, "asa_row": {"l1": "ASA DE · DAB 5C · Dienst empfangen", "state": "gruen", "t": now - 60}}
    rows = _dh_rows(r, now)
    assert [x["label"] for x in rows] == ["BR24 (DAB 11D):", "ASA DE (DAB 5C):"] and rows[0]["text"] == "empfangen" and rows[1]["text"] == "Dienst empfangen", rows
    assert rows[0]["lvl"] == "ok" and rows[1]["run"] and rows[0]["href"] == "/dabhist?ch=11D"
    r2 = dict(r, state="rot", br24_row={"l1": "BR24 UKW ⚠ RadioText: „Gefahr“", "state": "rot"}, asa_row={})
    rows = _dh_rows(r2, now)
    assert rows[0]["lvl"] == "rot" and "Gefahr" in rows[0]["text"] and rows[1]["lvl"] == "aus" and rows[1]["text"] == "–"
    assert _dh_rows(None, now)[0]["text"]
    assert "fetch(" in _DH_JS and _DH_JS.count("fetch(") == 1 and "method:" not in _DH_JS
    return "dabHist selftest ok"


try:
    _dh_st = _dh_selftest()
    if "app" in globals():
        if "dh_page" not in app.view_functions:
            app.add_url_rule("/dabhist", endpoint="dh_page", view_func=_dh_page, methods=["GET"])
        if not any(getattr(f, "__name__", "") == "_dh_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_dh_after)
    print("dabHist aktiv: /funk BR24/ASA-Zeilen, Seite /dabhist; %s" % _dh_st, flush=True)
except Exception as _dh_e:
    print("dabHist:", _dh_e, flush=True)
# ===== /dabHist =====
DHBLK_EOF
EXPECT_PATCH="7e84335ff6b8856a5f9ee5918d128258c55f17aa9d5a1cbd6ff700a43bb40425"
cat > "$W/patch-dh.py" << 'DHPATCH_EOF'
"""dabHist Dashboard-Teil. Aufruf: patch-dh.py QUELLE ZIEL BLOCKDATEI -> 0 ok, 3 Basis passt nicht."""
import sys
src, dst, blkf = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blkf, encoding="utf-8").read()
if "# ===== dabHist:" in s:
    open(dst, "w", encoding="utf-8").write(s); print("schon da"); raise SystemExit(0)
a = "# ===== /stickTestFix =====\n"
for need in (a, "def _br24_state():", "def _sdr_load(name, default):", "rr.dataset.su='rf'"):
    if s.count(need) < 1 or (need == a and s.count(need) != 1):
        print("Basis passt nicht:", need[:50], s.count(need)); raise SystemExit(3)
s = s.replace(a, a + blk)
open(dst, "w", encoding="utf-8").write(s)
print("geaendert")
DHPATCH_EOF
EXPECT_MOD="896d511f3ef527544743eb9cbc86fb5f8c116dbf12083a6e70658f9dc0f610b0"
cat > "$W/dh_mod.py" << 'DHMOD_EOF'
# ===== dabHist: Verlauf aller DAB-Textmeldungen (DLS) und Ansagen von 11D (BR24) und 5C (ASA DE): gleiche Folgemeldung -> nur zuletzt/Anzahl; Ring sdr_dabhist.json (atomar) + archive/dabhist/YYYY-MM/*.jsonl; nur Empfang =====
DABHIST_CH = ("11D", "5C")
DABHIST_FILE = "sdr_dabhist.json"


class DabHist:
    MAX_N = 2000
    SAVE_S = 60

    def __init__(self, base):
        self.base = base
        self.f = p(DABHIST_FILE, base)
        d = load_json(self.f, {}) or {}
        ev = d.get("ev") if isinstance(d, dict) else None
        self.ev = [x for x in (ev or []) if isinstance(x, dict) and isinstance(x.get("t"), (int, float))][-self.MAX_N:]
        self.seq = max([x.get("id", 0) for x in self.ev if isinstance(x.get("id"), int)] + [0])
        self.dirty = False
        self.last_save = 0

    def note(self, ch, src, text, now, warn=False, kind="dls"):
        text = " ".join(str(text or "").split())[:200]
        ch = str(ch or "").upper()
        if not text or ch not in DABHIST_CH:
            return None
        src = str(src or "?").strip()[:40] or "?"
        now = int(now)
        last = None
        for x in reversed(self.ev[-80:]):
            if x.get("ch") == ch and x.get("src") == src:
                last = x
                break
        if last is not None and last.get("text") == text:
            last["last"] = max(now, int(last.get("last") or now))
            last["n"] = int(last.get("n") or 1) + 1
            last["warn"] = bool(last.get("warn")) or bool(warn)
            self.dirty = True
            self.save()
            return last
        self.seq += 1
        e = {"id": self.seq, "t": now, "last": now, "n": 1, "ch": ch, "src": src, "text": text, "warn": bool(warn), "k": kind}
        self.ev = (self.ev + [e])[-self.MAX_N:]
        self.dirty = True
        self.archive(e)
        self.save(force=True)
        return e

    def archive(self, e):
        try:
            lt = time.localtime(e["t"])
            d = p(os.path.join("archive", "dabhist", time.strftime("%Y-%m", lt)), self.base)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "dabhist-%s.jsonl" % time.strftime("%Y-%m-%d", lt)), "a", encoding="utf-8") as f:
                f.write(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n")
        except Exception as ex:
            print("dabHist Archiv:", ex, flush=True)

    def save(self, force=False):
        now = time.time()
        if self.dirty and (force or now - self.last_save > self.SAVE_S or now < self.last_save):
            try:
                write_json(self.f, {"v": 1, "t": int(now), "ev": self.ev})
                self.dirty, self.last_save = False, now
            except Exception as ex:
                print("dabHist speichern:", ex, flush=True)


def dabhist_note(bc, ch, src, text, warn, now, kind="dls"):
    """Aus BcState.on_dab aufgerufen; Fehler hier duerfen den Rundfunk-Empfang nie stoeren."""
    try:
        dh = getattr(bc, "_dabhist", None)
        if dh is None:
            dh = bc._dabhist = DabHist(os.path.dirname(bc.f))
        return dh.note(ch, src, text, now, warn, kind)
    except Exception as ex:
        print("dabHist:", ex, flush=True)
        return None


def selftest_dabhist():
    import tempfile
    tmp = tempfile.mkdtemp()
    h = DabHist(tmp)
    a = h.note("11D", "BR24", "Nachrichten  um 15 Uhr", 1000)
    assert a and a["n"] == 1 and a["text"] == "Nachrichten um 15 Uhr"
    b = h.note("11D", "BR24", "Nachrichten um 15 Uhr", 1060)
    assert b is a and a["n"] == 2 and a["last"] == 1060 and len(h.ev) == 1
    h.note("11D", "Bayern 3", "Musik", 1061)
    h.note("11D", "BR24", "Wetter", 1100)
    h.note("11D", "BR24", "Nachrichten um 15 Uhr", 1200)  # nicht direkt hintereinander -> neuer Eintrag
    assert [x["text"] for x in h.ev if x["src"] == "BR24"] == ["Nachrichten um 15 Uhr", "Wetter", "Nachrichten um 15 Uhr"]
    assert h.note("5C", "ASA DE", "Gefahr", 1300, warn=True)["warn"] and h.note("8B", "X", "y", 1) is None and h.note("5C", "x", "  ", 1) is None
    h.save(force=True)
    h2 = DabHist(tmp)
    assert len(h2.ev) == 5 and h2.seq == 5 and h2.ev[0]["n"] == 2
    arch = os.path.join(tmp, "archive", "dabhist")
    n = sum(1 for r, _, fs in os.walk(arch) for fn in fs for _ in open(os.path.join(r, fn)))
    assert n == 5, n
    for i in range(DabHist.MAX_N + 5):
        h2.note("5C", "ASA DE", "t%d" % i, 2000 + i)
    assert len(h2.ev) == DabHist.MAX_N

    class B:
        f = os.path.join(tmp, "broadcast_state.json")
    assert dabhist_note(B(), "11d", "BR24", "x", False, 5)["ch"] == "11D"
    print("selftest dabHist ok (Ring, Zaehlen, Archiv, Grenzen)", flush=True)
# ===== /dabHist =====


DHMOD_EOF
EXPECT_EDIT="99bf4411a1f6a6a851990b13dc3c2b93f744006f2bb59d395686fe23f8d4950b"
cat > "$W/edit-dh.py" << 'DHEDIT_EOF'
import sys
src = open(sys.argv[1]).read(); mod = open(sys.argv[3]).read()
if "# ===== dabHist:" in src:
    open(sys.argv[2], "w").write(src); print("schon da"); raise SystemExit(0)
def rep(a, b, n=1):
    global src
    assert src.count(a) == n, (a[:60], src.count(a)); src = src.replace(a, b)
rep("            sc = _ws_score(dl)\n", "            sc = _ws_score(dl)\n            if dl and ch in DABHIST_CH:\n                dabhist_note(self, ch, (l or \"?\").strip()[:30], dl, sc[\"cls\"] == \"rot\", now)  # dabHist\n")
rep('                self.evl.add("dab_ann", "DAB %s" % ch, now, text="; ".join(alarm[:3]), ens=(lab or "").strip()[:40])\n',
    '                self.evl.add("dab_ann", "DAB %s" % ch, now, text="; ".join(alarm[:3]), ens=(lab or "").strip()[:40])\n                if ch in DABHIST_CH:\n                    dabhist_note(self, ch, "Ansage", "; ".join(alarm[:3]), True, now, "ann")  # dabHist\n')
rep("# ---------------------------------------------------------------- Selbsttest (ohne Stick)\n", mod + "# ---------------------------------------------------------------- Selbsttest (ohne Stick)\n")
rep("        selftest_sticktestfix()\n", "        selftest_sticktestfix()\n        selftest_dabhist()\n")
open(sys.argv[2], "w").write(src); print("geaendert")
DHEDIT_EOF
EXPECT_GUARD="c90ffab98e5438992bcaf7344a927c3645afcd46aa3dfc0e802954584d579285"
cat > "$W/guard_dh.py" << 'DHGUARD_EOF'
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
inst = "# ===== dabHist:" in open(sys.argv[1], encoding="utf-8").read()
allow = {"Popen": 0, "Thread": 0, "execv": 0}
err = []
if ni - bi - {"hashlib", "tempfile"}: err.append("Importe neu %s" % (ni - bi))
if nb != bb: err.append("shell=True neu")
for nm in ("send_meshtastic", "sendText", "sendData", "urlopen", "socket", "create_connection", "bind", "listen", "connect", "system", "Popen", "Thread", "Timer", "execv", "run", "call", "check_output", "HTTPServer", "serve_forever"):
    d = nc.count(nm) - bc.count(nm)
    if d != (0 if inst else allow.get(nm, 0)): err.append("Aufrufe %s %+d" % (nm, d))
src = open(sys.argv[2], encoding="utf-8").read()
blk = src[src.index("# ===== dabHist:"):src.index("# ===== /dabHist =====")]
blk = "\n".join(l for l in blk.splitlines() if not l.startswith("STK_TOOLS = "))  # nur Namensliste zum Erkennen belegter Sticks
if "mesh" in blk.lower() and "meshtastic" in blk.lower(): err.append("Block erwaehnt Meshtastic")
for w in ("rtl_tcp", "rtl_sdr", "-T", "transmit"):
    if '"%s"' % w in blk: err.append("Block nutzt " + w)
if err: print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard prepper_sdr: keine Sendestelle/Netz/Server neu, kein shell=True; keine neuen Prozesse (Popen +%d, Thread +%d, execv +%d)" % tuple(0 if inst else allow[k] for k in ("Popen", "Thread", "execv")))
DHGUARD_EOF
EXPECT_LC="ce93e3ddcf0b05d63c62c93a67f29e114bfe5bc488c22c1c2ae372329e852e36"
cat > "$W/layout_check.py" << 'DHLC_EOF'
"""Raster-Pruefung /funk: layout_check.py SEITE.html [VORHER.html] -> 0 ok, 1 Fehler.
Haupt-Raster = div.grid mit den meisten Kacheln. Kachel = div.card, nicht in einer anderen Kachel.
Pflicht: #stickTestCard genau einmal, direktes Kind des Rasters und letztes div darin; keine Kachel ausserhalb, die es vorher nicht schon gab."""
import sys
from html.parser import HTMLParser


class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.nodes = [], []

    def handle_starttag(self, tag, attrs):
        if tag != "div":
            return
        a = dict(attrs)
        n = {"i": len(self.nodes), "cls": (a.get("class") or "").split(), "id": a.get("id") or "", "par": self.stack[-1] if self.stack else None, "kids": [], "txt": ""}
        if n["par"] is not None:
            self.nodes[n["par"]]["kids"].append(n["i"])
        self.nodes.append(n)
        self.stack.append(n["i"])

    def handle_endtag(self, tag):
        if tag == "div" and self.stack:
            self.stack.pop()

    def handle_data(self, d):
        if self.stack and len(self.nodes[self.stack[-1]]["txt"]) < 40:
            self.nodes[self.stack[-1]]["txt"] += d.strip()


def analyse(fn):
    p = P()
    p.feed(open(fn, encoding="utf-8", errors="replace").read())
    N = p.nodes

    def anc(i):
        j = N[i]["par"]
        while j is not None:
            yield j
            j = N[j]["par"]
    tiles = [n["i"] for n in N if "card" in n["cls"] and not any("card" in N[j]["cls"] for j in anc(n["i"]))]
    grids = [n["i"] for n in N if "grid" in n["cls"]]
    if not grids:
        return None, tiles, N, []
    g = max(grids, key=lambda x: sum(1 for t in tiles if x in anc(t)))
    out = [t for t in tiles if g not in anc(t)]
    return g, tiles, N, out


def sig(N, i):
    return N[i]["id"] or ("%s:%s" % (".".join(N[i]["cls"]), N[i]["txt"][:30]))


g, tiles, N, out = analyse(sys.argv[1])
err = []
if g is None:
    err.append("kein Kachel-Raster gefunden")
else:
    st = [n["i"] for n in N if n["id"] == "stickTestCard"]
    if len(st) != 1:
        err.append("#stickTestCard %d-mal" % len(st))
    else:
        s = st[0]
        if N[s]["par"] != g:
            err.append("#stickTestCard nicht direkt im Raster")
        elif N[g]["kids"][-1] != s:
            err.append("#stickTestCard nicht letzte Kachel (danach: %s)" % sig(N, N[g]["kids"][-1]))
    before = set()
    if len(sys.argv) > 2:
        g0, t0, N0, out0 = analyse(sys.argv[2])
        before = set(sig(N0, i) for i in out0)
    new_out = [sig(N, i) for i in out if N[i]["id"] != "stickTestCard" and sig(N, i) not in before]
    if new_out:
        err.append("Kacheln ausserhalb des Rasters (neu): " + ", ".join(new_out))
    print("Raster: %d Kacheln im Raster, ausserhalb (schon vorher/Absicht): %s" % (sum(1 for t in tiles if t not in out), ", ".join(sig(N, i) for i in out if N[i]["id"] != "stickTestCard") or "keine"))
if err:
    print("FEHLER Raster /funk: " + "; ".join(err)); raise SystemExit(1)
print("OK /funk: Antennentest letzte Kachel im Raster, keine Kachel neu ausserhalb")
DHLC_EOF
P="$W/patch-dh.py"; LB="$W/dh_block.py"; SM="$W/dh_mod.py"; SE="$W/edit-dh.py"; SG="$W/guard_dh.py"; LC="$W/layout_check.py"
for x in "$EXPECT_BLK $LB" "$EXPECT_PATCH $P" "$EXPECT_MOD $SM" "$EXPECT_EDIT $SE" "$EXPECT_GUARD $SG" "$EXPECT_LC $LC"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
# ---------- 1) Basis ----------
[[ -f "$F" && -f "$M" ]] || { echo "STOP: dashboard.py/prepper_sdr.py fehlt"; exit 1; }
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16)
if [[ "$D16" != "$BASE_DASH16" ]] && ! grep -q "# ===== dabHist:" "$F"; then echo "STOP: dashboard.py sha16 $D16 erwartet $BASE_DASH16 - nichts geaendert"; exit 1; fi
if [[ "$S16" != "$BASE_MOD16" ]] && ! grep -q "# ===== dabHist:" "$M"; then echo "STOP: prepper_sdr.py sha16 $S16 erwartet $BASE_MOD16 - nichts geaendert"; exit 1; fi
grep -q "# ===== stickTestFix:" "$F" && grep -q "# ===== stickTestFix:" "$M" && grep -q "# ===== lageTest:" "$F" || { echo "STOP: stickTestFix/lageTest-Guard fehlt - nichts geaendert"; exit 1; }
echo "OK Basis dashboard.py $D16 ($(wc -l < "$F") Zeilen), prepper_sdr.py $S16 ($(wc -l < "$M") Zeilen)"
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
  grep -q "selftest dabHist ok" "$W/selftest.log" || { echo "STOP: Selbsttest dabHist fehlt ($py)"; exit 1; }
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY: $(grep 'selftest stickTest ok' "$W/selftest.log" | cut -c1-40) / $(grep 'selftest dabHist ok' "$W/selftest.log")"
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
inst = "# ===== dabHist:" in open(sys.argv[1], encoding="utf-8").read()
if nc.count("add_url_rule") != bc.count("add_url_rule") + (0 if inst else 1): err.append("genau eine neue Route (/dabhist) erwartet")
if nc.count("after_request") != bc.count("after_request") + (0 if inst else 1): err.append("genau ein neuer after_request erwartet")
if [c for c in lc if c.startswith(("send", "maybe_mesh"))]: err.append("Block: Sendeaufruf")
if li - {"html", "time", "flask"} or pi - {"sys"}: err.append("Importe Block/Patch %s %s" % (li, pi))
blk = open(sys.argv[3], encoding="utf-8").read()
if "mesh" in blk.lower(): err.append("Block erwaehnt mesh")
if "mesh" in blk.lower() or blk.count("fetch('") != 1 or "fetch('/api/br24'" not in blk or "POST" in blk or "XMLHttpRequest" in blk or blk.count("add_url_rule") != 1 or 'add_url_rule("/dabhist"' not in blk: err.append("Block: nur Lese-Abruf /api/br24 und Route /dabhist erlaubt")
if err: print("\n".join(err)); raise SystemExit(1)
print("OK AST-Guard Dashboard: keine Sendestelle (send_meshtastic %d=%d), keine Prozesse/Netz/Threads, genau 1 neue Route (/dabhist, nur Anzeige) + 1 after_request (/funk-Zeilen), nur GET /api/br24" % (bc.count("send_meshtastic"), nc.count("send_meshtastic")))
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
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 4) Installieren ----------
RESTARTED=0
if cmp -s "$W/work/dashboard.py" "$F" && cmp -s "$W/work/prepper_sdr.py" "$M"; then
  echo "OK dabHist schon installiert - kein Neustart"
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-sdr -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | tail -15 | cut -c1-200 || true
    sudo systemctl stop prepper-sdr.service || true
    for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json"; do
      [[ -f "$x.bak-dabhist-$TS" ]] && cp -a "$x.bak-dabhist-$TS" "$x.rb" && mv -f "$x.rb" "$x"
    done
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    for x in "$F" "$M"; do cmp -s "$x" "$x.bak-dabhist-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), Stick 2 im Config: $(grep -c '"stick2"' "$DASH_DIR/sdr_config.json" || true)"
  }
  for x in "$F" "$M" "$DASH_DIR/sdr_lage.json" "$DASH_DIR/sdr_config.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-dabhist-$TS"
    { ls -1t "$x.bak-dabhist-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  T0=$(date +%s)
  sudo systemctl stop prepper-sdr.service
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-dabhist-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-dabhist-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
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
for p in /dabhist "/dabhist?ch=11D" "/dabhist?ch=5C" /api/sdr/ui /api/br24 /api/sdr/sticktest; do c=$(code_r "$B$p"); printf '  HTTP %s = %s\n' "$p" "$c"; [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" -L --max-redirs 5 "$B/pi" -o "$W/pi.html" || true
"${CURL[@]}" -L --max-redirs 5 "$B/funk" -o "$W/funk.html" || true
grep -q 'id="stickTestCard"' "$W/pi.html" && rbx "/pi zeigt Antennentest-Kachel"
python3 "$LC" "$W/funk.html" "$W/funk0.html" || rbx "Raster /funk fehlerhaft"
grep -q 'id="dh-js"' "$W/funk.html" || rbx "/funk ohne BR24/ASA-Zeilen"
"${CURL[@]}" "$B/dabhist" -o "$W/dh.html" || true
grep -q 'class="dh-tab"\|noch keine Nachrichten' "$W/dh.html" || rbx "/dabhist ohne Tabelle/Leer-Hinweis"
"${CURL[@]}" "$B/api/br24" | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('dh_rows') or []
assert [x.get('label') for x in r]==['BR24 (DAB 11D):','ASA DE (DAB 5C):'], r
for x in r: print('  Zeile: %s %s %s' % (x['lvl'], x['label'], x['text'][:80]))
" || rbx "/api/br24 ohne dh_rows"
echo "OK /funk: BR24- und ASA-Zeile, /dabhist $(grep -c '<tr class' "$W/dh.html" || true) Eintraege"
c=$(code -X POST -H 'Content-Type: application/json' -H 'X-Stick-Test: 1' -d '{"action":"start"}' "$B/api/sdr/sticktest")
[[ "$c" == 403 ]] && echo "OK fremder Aufruf ohne gleichen Ursprung abgelehnt (403)" || rbx "Anforderung ohne Ursprung nicht abgelehnt ($c)"
[[ -f "$DASH_DIR/sdr_req_sticktest" ]] && rbx "Anforderungsdatei trotz 403 angelegt"
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] || rbx "/pi Sicherung veraendert ($R0/$R1)"
echo "OK /pi doPrepperRestore unveraendert ($R1)"
# ---------- 6) Abschluss ----------
c=$(code_r "$B/api/sdr/ui"); [[ "$c" == 200 ]] || rbx "/api/sdr/ui nach Test $c"
echo "OK /api/sdr/ui = 200 nach Test"
echo "OK guards dabHist(dash)=$(grep -c '# ===== dabHist:' "$F" || true) dabHist(sdr)=$(grep -c '# ===== dabHist:' "$M" || true) stickTestFix(dash)=$(grep -c '# ===== stickTestFix:' "$F" || true) stickTestFix(sdr)=$(grep -c '# ===== stickTestFix:' "$M" || true) stickTest(dash)=$(grep -c '# ===== stickTest:' "$F" || true) stickTest(sdr)=$(grep -c '# ===== stickTest:' "$M" || true) lageTest=$(grep -c '# ===== lageTest:' "$F" || true) sdrDual=$(grep -c '# ===== sdrDual:' "$F" || true) lageMesh1=$(grep -c '# ===== lageMesh1:' "$F" || true) piPolish2=$(grep -c '# ===== piPolish2:' "$F" || true) sdrLage=$(grep -c '# ===== sdrLage:' "$F" || true) sdrUi=$(grep -c '# ===== sdrUi:' "$F" || true)"
[[ -f "$F.bak-dabhist-$TS" ]] && echo "Backups: *.bak-dabhist-$TS (dashboard.py, prepper_sdr.py, sdr_lage.json, sdr_config.json), behalten: letzte $KEEP_LAST"
echo "dashboard.py sha16 jetzt $(sha256sum "$F" | cut -c1-16), $(wc -l < "$F") Zeilen; prepper_sdr.py sha16 $(sha256sum "$M" | cut -c1-16), $(wc -l < "$M") Zeilen"
echo "Hinweis: der Verlauf fuellt sich ab jetzt bei jeder BR24/ASA-Pruefung (DAB 11D/5C)."
echo "COMMIT $COMMIT_ARG dabHist=1"
