#!/bin/bash
set -euo pipefail
# ninaCalm: NINA-Kachel + NINA-Mesh beruhigen.
# - Kachel: abgelaufene Meldungen weg; Entwarnung nur 2 h nach Ausgabe, grau mit Label "Entwarnung";
#   leer -> "Keine aktiven Warnungen". Lage-Bewertung unveraendert.
# - Mesh: jede NINA-Meldungs-ID hoechstens einmal (Warnung und Entwarnung je einmal).
#   Wegfall/Ablauf sendet NICHTS mehr (keine "Entwarnung - keine Warnung mehr" nachts).
#   Wieder auftauchende Meldung wird nicht erneut gesendet. Gemerkt in nina_mesh_sent.json (7 Tage).
# - Installation sendet nichts: aktueller Feed wird als "schon gesendet" gemerkt,
#   meshBootQuiet (300 s) bleibt aussen herum.
# Neustart nur prepper-dashboard (Bridges NICHT). Smoke gegen config.py PORT (5000), nie :8080 (kiwix).
# Bei Fehler: ROLLBACK. Aendert nie update_all() # einmal beim Start, keine data_store-Zuweisung, kein data_store.clear().
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
DASH="$DASH_DIR/dashboard.py"
MOD="$DASH_DIR/nina_calm.py"
SENT="$DASH_DIR/nina_mesh_sent.json"
NSTAT="$DASH_DIR/nina_mesh_status.json"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/ninacalm
EXPECT_PATCH="d5db403f13ca798a39f28fbfc0a5f5ea32716c9a9f9d0055e42ff55e720566fa"
EXPECT_MOD="bde0d4e113030ecb998337d954072df7a6b49abb365569274fc43bf90952476f"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-nina-calm.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""ninaCalm: dashboard.py anpassen (idempotent, Marker ninaCalm).
1) fetch_nina: je Meldung zusaetzlich id, msgType, sent, expires
2) NINA-Kachel: nina_visible() filtert (abgelaufen weg, Entwarnung 2 h grau), leer -> 'Keine aktiven Warnungen'
3) Block vor meshBootQuiet: nina_calm.install() ersetzt maybe_mesh_nina (Dedupe je ID, Wegfall sendet nichts);
   meshBootQuiet wickelt danach die neue Funktion ein (Ruhezeit 300 s bleibt).
Aendert nie update_all()  # einmal beim Start. Keine data_store-Zuweisung, kein data_store.clear(), sendet nichts.
"""
import re
import sys
from pathlib import Path

MARK = "ninaCalm"
BEGIN = "# ===== ninaCalm: NINA Anzeige + Mesh je Meldungs-ID (nina_calm.py) ====="
END = "# ===== /ninaCalm ====="
BLOCK = BEGIN + "\n" + """try:
    import nina_calm as _nc_mod  # ninaCalm
    _nc_mod.install(app, globals())
except Exception as _nc_e:
    print("ninaCalm:", _nc_e)
""" + END + "\n\n"
MBQ = "# ===== meshBootQuiet:"
FETCH_NEW = ('warnings.append({"city": city, "title": title, "id": w.get("id"), '
             '"msgType": ((w.get("payload") or {}).get("data") or {}).get("msgType"), '
             '"sent": w.get("sent"), "expires": w.get("expires")})  # ninaCalm')
SET_NEW = ('{% set nv = (nina_visible(nina.value if nina is defined else None) if nina_visible is defined '
           'else (nina.value if nina is defined else None)) %}'
           '<span data-ninacalm="{{ 1 if nina_visible is defined else 0 }}" hidden></span>')
BADGE = ('{% if w.cancel %}<span style="display:inline-block;font-size:11px;padding:1px 6px;border-radius:6px;'
         'background:#334155;color:#cbd5e1;margin-right:6px">Entwarnung</span>{% endif %}')

def fail(msg):
    raise SystemExit("STOP: " + msg)

d = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard")
p = d / "dashboard.py" if d.is_dir() else d
src = p.read_text(encoding="utf-8")
new = src

# ---- 1) fetch_nina ----
m = re.search(r"^def fetch_nina\(.*?(?=^\S)", new, re.M | re.S)
if not m:
    fail("def fetch_nina fehlt")
body = m.group(0)
if "# ninaCalm" in body:
    print("RESULT fetch_nina=schon")
else:
    pat = re.compile(r'warnings\.append\(\{\s*"city"\s*:\s*city\s*,\s*"title"\s*:\s*title\s*\}\)')
    hits = pat.findall(body)
    if len(hits) != 1:
        fail("fetch_nina-Anker warnings.append({city,title}) %d-mal gefunden" % len(hits))
    if "for w in data" not in body:
        fail("fetch_nina ohne 'for w in data'")
    body2 = pat.sub(lambda _m: FETCH_NEW, body, count=1)
    new = new[:m.start()] + body2 + new[m.end():]
    print("RESULT fetch_nina=neu")

# ---- 2) Kachel-Template ----
SET_OLD = re.compile(r"\{%-?\s*set nv = nina\.value if nina is defined else None\s*-?%\}")
n_set = len(SET_OLD.findall(new))
n_done = new.count('data-ninacalm=')
if n_set == 0 and n_done == 0:
    fail("NINA-Kachel-Anker '{% set nv = nina.value ... %}' fehlt")
out, pos, n_loop, n_txt = [], 0, 0, 0
for sm in SET_OLD.finditer(new):
    out.append(new[pos:sm.start()])
    out.append(SET_NEW)
    tail_start = sm.end()
    seg_end = new.find("</div>\n  </div>", tail_start)
    window_end = min(len(new), tail_start + 900)
    seg = new[tail_start:window_end]
    lm = re.search(r"\{%-?\s*for w in nv\s*-?%\}(.*?)\{%-?\s*endfor\s*-?%\}", seg, re.S)
    if not lm:
        fail("Schleife '{% for w in nv %}' nach NINA-Anker fehlt")
    loop_new = ('{% for w in nv %}<div class="ninaCalm"{% if w.cancel %} style="color:#94a3b8"{% endif %}>'
                + BADGE + lm.group(1) + '</div>{% endfor %}')
    seg2 = seg[:lm.start()] + loop_new + seg[lm.end():]
    if "Keine Warnungen vorliegend" in seg2:
        seg2 = seg2.replace("Keine Warnungen vorliegend", "Keine aktiven Warnungen", 1)
        n_txt += 1
    out.append(seg2)
    pos = window_end
    n_loop += 1
out.append(new[pos:])
new = "".join(out)
print("RESULT kachel=%s (neu %d, Text %d, schon %d)" % ("neu" if n_loop else "schon", n_loop, n_txt, n_done))

# ---- 3) Block vor meshBootQuiet ----
if BEGIN in new:
    a = new.index(BEGIN)
    if END not in new[a:]:
        fail("ninaCalm-Block ohne Ende-Marker")
    b = new.index(END, a) + len(END)
    while b < len(new) and new[b] == "\n":
        b += 1
    new = new[:a] + BLOCK + new[b:]
    print("RESULT block=schon")
else:
    mains = list(re.finditer(r"^if __name__ == ['\"]__main__['\"]:", new, re.M))
    if not mains:
        fail("if __name__ == '__main__' fehlt")
    mainpos = mains[-1].start()
    if "update_all()  # einmal beim Start" not in new[mainpos:]:
        fail("Boot-Zeile nicht nach __main__")
    q = new.find("\n" + MBQ)
    at = q + 1 if 0 <= q < mainpos else mainpos
    defs = [x.start() for x in re.finditer(r"^def maybe_mesh_nina\(", new, re.M)]
    if not defs:
        fail("def maybe_mesh_nina fehlt")
    if max(defs) > at:
        fail("def maybe_mesh_nina steht hinter dem Einfuegepunkt")
    if re.search(r"^\s*maybe_mesh_nina\s*=", new[at:], re.M):
        fail("maybe_mesh_nina wird hinter dem Einfuegepunkt neu zugewiesen")
    if not re.search(r"^app\s*=\s*Flask\(", new[:at], re.M):
        fail("app = Flask(...) nicht vor Einfuegepunkt")
    new = new[:at] + BLOCK + new[at:]
    print("RESULT block=neu (%s)" % ("vor meshBootQuiet" if at != mainpos else "vor __main__, meshBootQuiet fehlt"))

print("RESULT mesh2-direkt im alten maybe_mesh_nina: %s" % (
    "ja" if re.search(r"^def maybe_mesh_nina\(.*?send_nina_to_bayern\(", src, re.M | re.S) and
    "send_nina_to_bayern(" in (re.search(r"^def maybe_mesh_nina\(.*?(?=^\S)", src, re.M | re.S).group(0)) else "nein"))
bm = re.search(r"^def maybe_mesh_nina_bayern\(.*?(?=^\S)", src, re.M | re.S)
print("RESULT nina_bayern: %s" % ("fehlt" if not bm else ("aus (pageFein)" if "return False  # pageFein" in bm.group(0) else "unveraendert (eigene Checkbox-Logik)")))
if new != src:
    p.write_text(new, encoding="utf-8")
    print("RESULT changed=dashboard.py")
else:
    print("RESULT changed=nichts")
PATCHPY_EOF
cat > "$W/nina_calm.py" << 'MODPY_EOF'
#!/usr/bin/env python3
"""ninaCalm: NINA-Kachel und NINA-Mesh ruhig halten.

- Anzeige: abgelaufene Meldungen (expires vorbei) weg; Entwarnungen (msgType Cancel
  oder Titel beginnt mit "Entwarnung") nur 2 h nach sent, grau mit Label "Entwarnung".
- Mesh: jede Meldungs-ID hoechstens einmal (Warnung, Update, Entwarnung).
  Verschwinden/Ablaufen sendet NICHTS (keine generische "keine Warnung mehr"-Nachricht).
  Wieder auftauchende ID wird nicht erneut gesendet. Gesendete IDs in
  nina_mesh_sent.json (7 Tage). force=True sendet die aktuell sichtbaren Meldungen.
- Erststart ohne Datei: alles, was im Feed steht, gilt als schon gesendet (kein Send).
Keine data_store-Zuweisung, kein update_all, sendet nur ueber send_meshtastic /
send_nina_to_bayern des Dashboards (wie bisher maybe_mesh_nina).
"""
import json
import os
import re
import threading
import time
from datetime import datetime

MARK = "ninaCalm"
CANCEL_SHOW_SEC = 2 * 3600
PRUNE_SEC = 7 * 86400
_DIR = os.path.dirname(os.path.abspath(__file__))
STATE_FILE = os.path.join(_DIR, "nina_mesh_sent.json")
_LOCK = threading.Lock()
_G = {}
_STATE = {"loaded": False, "ids": {}, "cancels": {}, "seed_pending": False}


def parse_ts(s):
    if not s:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    try:
        return datetime.fromisoformat(str(s).strip().replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def is_cancel(w):
    if not isinstance(w, dict):
        return False
    if str(w.get("msgType") or "").lower() == "cancel":
        return True
    t = str(w.get("title") or w.get("headline") or "").strip().lower()
    return t.startswith("entwarnung")


def item_id(w):
    if isinstance(w, dict):
        i = w.get("id")
        if i:
            return str(i)
        city = str(w.get("city") or w.get("area") or "").strip()
        title = str(w.get("title") or w.get("headline") or w.get("text") or "").strip()
        return "t:" + (city + ": " + title).strip(": ").lower()[:200]
    return "t:" + str(w).strip().lower()[:200]


def base_title(w):
    t = str((w.get("title") or w.get("headline") or "") if isinstance(w, dict) else w).strip()
    t = re.sub(r"^\s*entwarnung\s*[:\-–]\s*", "", t, flags=re.I)
    return re.sub(r"\s+", " ", t).strip().lower()[:200]


def note_cancels(items, now=None):
    """Entwarnungen merken: aeltere Warnung mit gleichem Titel gilt als aufgehoben
    (NINA-CDN liefert zeitweise noch die alte Warnung statt der Entwarnung)."""
    now = time.time() if now is None else now
    changed = False
    for w in _items(items):
        if not is_cancel(w):
            continue
        b = base_title(w)
        if not b:
            continue
        st = parse_ts(w.get("sent")) or now
        cur = _STATE["cancels"].get(b)
        if not isinstance(cur, dict) or float(cur.get("sent") or 0) < st:
            _STATE["cancels"][b] = {"sent": st, "at": now, "id": w.get("id")}
            changed = True
    return changed


def superseded(w):
    if not isinstance(w, dict) or is_cancel(w):
        return False
    c = _STATE["cancels"].get(base_title(w))
    if not isinstance(c, dict):
        return False
    st = parse_ts(w.get("sent"))
    return st is None or st <= float(c.get("sent") or 0)


def _items(nina_data):
    if isinstance(nina_data, list):
        return nina_data
    if isinstance(nina_data, dict):
        return nina_data.get("alerts") or nina_data.get("warnings") or (
            [nina_data] if nina_data.get("title") else [])
    return []


def active(nina_data, now=None):
    """Sichtbare Meldungen (Kopien) + Feld cancel. Strings bleiben wie sie sind."""
    now = time.time() if now is None else now
    out = []
    for w in _items(nina_data):
        if not isinstance(w, dict):
            if str(w).strip():
                out.append(w)
            continue
        exp = parse_ts(w.get("expires"))
        if exp is not None and exp <= now:
            continue
        if superseded(w):
            continue
        c = is_cancel(w)
        if c:
            sent = parse_ts(w.get("sent"))
            if sent is None or now - sent > CANCEL_SHOW_SEC:
                continue
        d = dict(w)
        d["cancel"] = c
        out.append(d)
    return out


def nina_visible(nina_data):
    """Jinja: Kachel-Liste. Entwarnung ohne doppeltes 'Entwarnung:' im Titel."""
    try:
        with _LOCK:
            _load()
            note_cancels(nina_data)
        res = []
        for w in active(nina_data):
            if isinstance(w, dict) and w.get("cancel"):
                t = str(w.get("title") or "")
                t2 = re.sub(r"^\s*entwarnung\s*[:\-–]\s*", "", t, flags=re.I)
                w["title"] = t2 or t
            res.append(w)
        return res
    except Exception as e:
        print("ninaCalm visible:", e)
        return nina_data if isinstance(nina_data, list) else []


def _line(w):
    if isinstance(w, dict):
        city = str(w.get("city") or w.get("area") or "").strip()
        title = str(w.get("title") or w.get("headline") or w.get("text") or "").strip()
        if w.get("cancel") and not title.lower().startswith("entwarnung"):
            title = "Entwarnung: " + title
        return (city + ": " + title).strip(": ").strip()
    return str(w).strip()


# ---------------- Zustand ----------------
def _load():
    if _STATE["loaded"]:
        return
    _STATE["loaded"] = True
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            d = json.load(f)
        ids = d.get("ids") if isinstance(d, dict) else None
        _STATE["ids"] = ids if isinstance(ids, dict) else {}
        cs = d.get("cancels") if isinstance(d, dict) else None
        _STATE["cancels"] = cs if isinstance(cs, dict) else {}
        _STATE["seed_pending"] = bool(d.get("seed_pending")) if isinstance(d, dict) else True
    except FileNotFoundError:
        _STATE["ids"] = {}
        _STATE["seed_pending"] = True
    except Exception as e:
        print("ninaCalm state:", e)
        _STATE["ids"] = {}
        _STATE["seed_pending"] = True


def _save():
    now = time.time()
    ids = {k: v for k, v in _STATE["ids"].items()
           if isinstance(v, dict) and now - float(v.get("at") or 0) < PRUNE_SEC}
    _STATE["ids"] = ids
    _STATE["cancels"] = {k: v for k, v in _STATE["cancels"].items()
                         if isinstance(v, dict) and now - float(v.get("at") or 0) < PRUNE_SEC}
    d = {"marker": MARK, "v": 1, "seed_pending": _STATE["seed_pending"], "ids": ids, "cancels": _STATE["cancels"],
         "saved": datetime.now().strftime("%d.%m.%Y %H:%M:%S")}
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE_FILE)


def _mark(items, how):
    now = time.time()
    for w in items:
        _STATE["ids"][item_id(w)] = {
            "at": now, "how": how,
            "when": datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
            "type": "Cancel" if (isinstance(w, dict) and w.get("cancel")) else (
                (w.get("msgType") if isinstance(w, dict) else None) or "Alert"),
            "title": _line(w)[:160],
        }


def seed(nina_data, how="seed"):
    """Alles Aktuelle als gesendet merken, ohne zu senden."""
    with _LOCK:
        _load()
        note_cancels(nina_data)
        items = [w for w in _items(nina_data)]
        for w in items:
            if isinstance(w, dict):
                w = dict(w, cancel=is_cancel(w))
            _mark([w], how)
        _STATE["seed_pending"] = False
        _save()
        return len(items)


# ---------------- Mesh ----------------
def _now_str():
    f = _G.get("now_str")
    try:
        return f() if callable(f) else datetime.now().strftime("%d.%m.%Y %H:%M:%S")
    except Exception:
        return datetime.now().strftime("%d.%m.%Y %H:%M:%S")


def maybe_mesh_nina(nina_data, force=False):  # ninaCalm
    """Ersetzt maybe_mesh_nina: Dedupe je Meldungs-ID, Wegfall sendet nichts."""
    try:
        if nina_data is None:
            print("NINA: Fetch fehlgeschlagen – Mesh unverändert")
            return False
        with _LOCK:
            _load()
            if note_cancels(nina_data):
                _save()
            if _STATE["seed_pending"] and not force:
                n = 0
                for w in _items(nina_data):
                    w2 = dict(w, cancel=is_cancel(w)) if isinstance(w, dict) else w
                    _mark([w2], "seed-runtime")
                    n += 1
                _STATE["seed_pending"] = False
                _save()
                print("ninaCalm: Erststart - %d Meldung(en) als gesendet gemerkt, kein Send" % n)
                return False
            vis = active(nina_data)
            new = vis if force else [w for w in vis if item_id(w) not in _STATE["ids"]]
            if not new:
                return False
            parts, seen = [], set()
            for w in new:
                ln = _line(w)
                if ln and ln.lower() not in seen:
                    seen.add(ln.lower())
                    parts.append(ln)
            if not parts:
                return False
            key = " | ".join(parts)[:180]
            text = ("NINA: " + key)[:200]
            send = _G.get("send_meshtastic")
            if not callable(send):
                print("ninaCalm: send_meshtastic fehlt")
                return False
            ok = bool(send(text))
            ts = _now_str()
            if not ok:
                print("NINA-Mesh FAIL – nächster Zyklus:", key[:80])
                return False
            _mark(new, "force" if force else "auto")
            _save()
        _G["last_nina_mesh"] = key
        _G["last_nina_received"] = ts
        _G["last_nina_mesh_status"] = {"ok": True, "text": key, "at": ts, "received": ts,
                                       "sent": ts, "cleared": None}
        sv = _G.get("save_nina_mesh_status")
        if callable(sv):
            try:
                sv(key, cleared=None)
            except Exception as e:
                print("ninaCalm status-json:", e)
        ok2 = None
        b = _G.get("send_nina_to_bayern")
        if _G.get("_nc_mesh2") and callable(b):
            try:
                ok2 = b(text)
            except Exception as e:
                print("ninaCalm Mesh2:", e)
                ok2 = False
        print("NINA-Mesh OK (ninaCalm %s):" % ("force" if force else "neu"), key[:80],
              "Mesh2", "-" if ok2 is None else ("OK" if ok2 else "FAIL"), flush=True)
        return True
    except Exception as e:
        print("maybe_mesh_nina (ninaCalm):", e)
        return False


maybe_mesh_nina._ninaCalm = True


def _orig_has_mesh2(g):
    try:
        src = open(g.get("__file__") or os.path.join(_DIR, "dashboard.py"), encoding="utf-8").read()
        m = re.search(r"^def maybe_mesh_nina\(.*?(?=^\S|\Z)", src, re.M | re.S)
        return bool(m and "send_nina_to_bayern(" in m.group(0))
    except Exception:
        return False


def install(app, g):
    globals()["_G"] = g
    g["_nc_mesh2"] = _orig_has_mesh2(g)
    prev = g.get("maybe_mesh_nina")
    if not getattr(prev, "_ninaCalm", False):
        g["_nc_prev_maybe_mesh_nina"] = prev
    g["maybe_mesh_nina"] = maybe_mesh_nina
    try:
        app.jinja_env.globals["nina_visible"] = nina_visible
    except Exception as e:
        print("ninaCalm jinja:", e)
    with _LOCK:
        _load()
    print("ninaCalm: installiert (IDs gemerkt=%d, Erststart=%s, Mesh2 direkt=%s)" % (
        len(_STATE["ids"]), _STATE["seed_pending"], g["_nc_mesh2"]), flush=True)


# ---------------- CLI: Seed vor dem Neustart ----------------
def _areas_from_dashboard(path):
    src = open(path, encoding="utf-8").read()
    m = re.search(r"^def fetch_nina\(.*?(?=^\S|\Z)", src, re.M | re.S)
    body = m.group(0) if m else ""
    return re.findall(r"[\"'](.+?)[\"']\s*:\s*[\"'](\d{12})[\"']", body)


def fetch_feed(path, rounds=3):
    import urllib.request
    out, ok, seen = [], 0, set()
    for city, ars in _areas_from_dashboard(path) * rounds:
        try:
            req = urllib.request.Request("https://warnung.bund.de/api31/dashboard/%s.json" % ars,
                                         headers={"User-Agent": "KaeswasserLage/1.0"})
            with urllib.request.urlopen(req, timeout=10) as r:
                data = json.loads(r.read().decode("utf-8") or "[]")
            ok += 1
            for w in data if isinstance(data, list) else []:
                title = ((w.get("i18nTitle") or {}).get("de") or (w.get("payload") or {}).get("data", {}).get("headline") or "").strip()
                if title and (city, w.get("id")) not in seen:
                    seen.add((city, w.get("id")))
                    out.append({"city": city, "title": title, "id": w.get("id"),
                                "msgType": ((w.get("payload") or {}).get("data") or {}).get("msgType"),
                                "sent": w.get("sent"), "expires": w.get("expires")})
        except Exception as e:
            print("  Feed", city, e)
    return (out if ok else None), ok


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 2 and sys.argv[1] == "--seed":
        dash = sys.argv[2] if len(sys.argv) > 2 else os.path.join(_DIR, "dashboard.py")
        _load()
        had = os.path.exists(STATE_FILE) and not _STATE["seed_pending"]
        feed, ok = fetch_feed(dash)
        if had:
            if feed and note_cancels(feed):
                _save()
            print("SEED nicht noetig - nina_mesh_sent.json schon da (%d IDs, %d Entwarnungen)" % (len(_STATE["ids"]), len(_STATE["cancels"])))
            for w in feed or []:
                print("  %s | %s | gemerkt=%s | %s" % (w.get("id"), w.get("msgType"), "ja" if item_id(w) in _STATE["ids"] else "NEIN",
                                                   "sichtbar" if active([w]) else "ausgeblendet"))
            sys.exit(0)
        if feed is None:
            if not had:
                _STATE["seed_pending"] = True
                _save()
            print("SEED Feed nicht erreichbar - Erststart-Merker gesetzt (erster Zyklus sendet nichts)")
            sys.exit(0)
        new = [w for w in feed if item_id(w) not in _STATE["ids"]]
        seed(feed, "seed-install")
        print("SEED %d Abfragen ok (Regionen x3), %d Meldung(en) im Feed als gesendet gemerkt (neu %d)" % (ok, len(feed), len(new)))
        for w in feed:
            vis = "sichtbar" if active([w]) else "ausgeblendet"
            print("  %s | %s | sent %s | expires %s | %s | %s" % (
                w.get("id"), w.get("msgType"), w.get("sent"), w.get("expires"), vis, _line(dict(w, cancel=is_cancel(w)))[:90]))
    elif len(sys.argv) >= 2 and sys.argv[1] == "--show":
        _load()
        print("Erststart offen:", _STATE["seed_pending"], "IDs:", len(_STATE["ids"]), "Entwarnungen gemerkt:", len(_STATE["cancels"]))
        for k, v in sorted(_STATE["ids"].items(), key=lambda kv: kv[1].get("at", 0)):
            print(" ", v.get("when"), v.get("how"), v.get("type"), k, "|", (v.get("title") or "")[:70])
MODPY_EOF

CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 25)
echo "=== ninaCalm apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="

# ---------- 0) Bytes + AST-Guard ----------
echo "$EXPECT_PATCH  $W/patch-nina-calm.py" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
echo "$EXPECT_MOD  $W/nina_calm.py" | sha256sum -c - >/dev/null || { echo "STOP: nina_calm.py sha256 falsch"; exit 1; }
for f in patch-nina-calm.py nina_calm.py; do
  grep -q 'ninaCalm' "$W/$f" || { echo "STOP: $f ohne Marker"; exit 1; }
  if grep -q 'PLACEHOLDER' "$W/$f"; then echo "STOP: PLACEHOLDER in $f"; exit 1; fi
  python3 -m py_compile "$W/$f"
done
set +e
python3 - "$W/patch-nina-calm.py" "$W/nina_calm.py" << 'GUARDPY'
import ast, pathlib, sys
hit = False
for fn in sys.argv[1:]:
    tree = ast.parse(pathlib.Path(fn).read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        tg = node.targets if isinstance(node, ast.Assign) else ([node.target] if isinstance(node, (ast.AnnAssign, ast.AugAssign)) else [])
        for t in tg:
            if isinstance(t, ast.Name) and t.id == "data_store":
                print(fn, "data_store-Zuweisung Zeile", node.lineno); hit = True
            if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name) and t.value.id == "data_store":
                print(fn, "data_store[...]-Zuweisung Zeile", node.lineno); hit = True
        if isinstance(node, ast.Call):
            f = node.func
            if isinstance(f, ast.Attribute) and f.attr == "clear" and isinstance(f.value, ast.Name) and f.value.id == "data_store":
                print(fn, "data_store.clear() Zeile", node.lineno); hit = True
            if isinstance(f, ast.Name) and f.id == "update_all":
                print(fn, "update_all() Zeile", node.lineno); hit = True
            if isinstance(f, ast.Attribute) and f.attr in ("sendText", "sendData"):
                print(fn, "Sende-Aufruf Zeile", node.lineno); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (keine data_store-Zuweisung, kein update_all, kein Sende-Aufruf)"

# ---------- 1) Voraussetzungen ----------
[[ -f "$DASH" ]] || { echo "STOP: fehlt $DASH - nichts geaendert"; exit 1; }
grep -q 'meshBootQuiet' "$DASH" || echo "WARN: meshBootQuiet nicht gefunden - Block kommt vor __main__"
VPY="$DASH_DIR/venv/bin/python"; [[ -x "$VPY" ]] || VPY=python3

# ---------- 2) Trockenlauf auf Kopie ----------
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$DASH" "$W/work/dashboard.py"
set +e
python3 "$W/patch-nina-calm.py" "$W/work" > "$W/dry.txt" 2>&1
rc=$?
set -e
cat "$W/dry.txt"
if [[ "$rc" -ne 0 ]]; then
  echo "STOP: Anker nicht gefunden - NICHTS geaendert. Bitte Ausgabe schicken."
  grep -n 'def fetch_nina\|warnings.append\|set nv = nina\|for w in nv\|Keine Warnungen vorliegend\|def maybe_mesh_nina\|===== meshBootQuiet\|__main__' "$DASH" | head -20 || true
  exit 1
fi
cp -a "$W/work" "$W/work1"
python3 "$W/patch-nina-calm.py" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
cp "$W/nina_calm.py" "$W/work/nina_calm.py"
python3 -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile dashboard.py - nichts geaendert"; exit 1; }
python3 -m py_compile "$W/work/nina_calm.py" || { echo "STOP: py_compile nina_calm.py - nichts geaendert"; exit 1; }
grep -q '# ===== ninaCalm:' "$W/work/dashboard.py" || { echo "STOP: Marker fehlt nach Trockenlauf"; exit 1; }
set +e
"$VPY" - "$W/work/dashboard.py" "$W/work" << 'PY'
import ast, sys
sys.path.insert(0, sys.argv[2])
import nina_calm as nc
src = open(sys.argv[1], encoding="utf-8").read()
try:
    import jinja2
except Exception:
    print("Jinja-Test uebersprungen (kein jinja2)"); jinja2 = None
n = 0
if jinja2:
    env = jinja2.Environment(); env.globals["nina_visible"] = nc.nina_visible
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str) and "data-ninacalm" in node.value.value:
            env.parse(node.value.value); n += 1
    if n == 0:
        print("WARN: Kachel-Template nicht als String-Konstante gefunden (Smoke prueft live)")
live = {"city": "LK Fürth", "title": "Entwarnung: Test", "id": "x", "msgType": "Cancel", "sent": "2020-01-01T00:00:00+02:00", "expires": "2099-01-01T00:00:00+02:00"}
assert nc.nina_visible([live]) == []
print("OK Templates geparst: %d, Filter ok" % n)
PY
jr=$?
set -e
[[ "$jr" -eq 0 ]] || { echo "STOP: Template/Filter-Test rc=$jr - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert"

# ---------- 3) Vorher-Stand HTTP ----------
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
pre_root=$(code "$B/"); pre_pi=$(code -L --max-redirs 5 "$B/pi"); pre_funk=$(code -L --max-redirs 5 "$B/funk"); pre_en=$(code "$B/energie")
echo "vorher HTTP / =$pre_root /pi=$pre_pi /funk=$pre_funk /energie=$pre_en"

# ---------- 4) Installieren ----------
d_need=0; m_need=0
cmp -s "$W/work/dashboard.py" "$DASH" || d_need=1
cmp -s "$W/nina_calm.py" "$MOD" 2>/dev/null || m_need=1
if [[ "$d_need" -eq 0 && "$m_need" -eq 0 ]]; then
  echo "OK ninaCalm schon drin - kein Neustart"
  "$VPY" "$MOD" --seed "$DASH" || true
else
  sudo -v
  cp -a "$DASH" "$DASH.bak-ninacalm-$TS"
  [[ -f "$MOD" ]] && cp -a "$MOD" "$MOD.bak-ninacalm-$TS"
  [[ -f "$NSTAT" ]] && cp -a "$NSTAT" "$NSTAT.bak-ninacalm-$TS"
  [[ -f "$SENT" ]] && cp -a "$SENT" "$SENT.bak-ninacalm-$TS"
  rollback() {
    echo "ROLLBACK: $1"
    cp -a "$DASH.bak-ninacalm-$TS" "$DASH"
    if [[ -f "$MOD.bak-ninacalm-$TS" ]]; then cp -a "$MOD.bak-ninacalm-$TS" "$MOD"; else rm -f "$MOD"; fi
    [[ -f "$NSTAT.bak-ninacalm-$TS" ]] && cp -a "$NSTAT.bak-ninacalm-$TS" "$NSTAT"
    sudo systemctl restart prepper-dashboard.service || true
    echo "alter Stand wieder aktiv (Dashboard neu gestartet, meshBootQuiet 5 min)"
  }
  install -m 0644 "$W/nina_calm.py" "$MOD"
  echo "--- Seed: aktueller NINA-Feed gilt als gesendet (sendet nichts) ---"
  "$VPY" "$MOD" --seed "$DASH" || { rollback "Seed fehlgeschlagen"; exit 1; }
  cp "$W/work/dashboard.py" "$DASH"
  python3 -m py_compile "$DASH" || { rollback "py_compile"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "OK installiert, Dashboard neu gestartet (Bridges NICHT, meshBootQuiet: 5 min keine Auto-Sendung)"
fi

# ---------- 5) Smoke Dashboard-Port ----------
[[ "$(type -t rollback)" == "function" ]] || rollback() { echo "FEHLER (nichts geaendert in diesem Lauf): $1"; }
echo "--- HTTP Dashboard :$PORT (nicht :8080 = Kiwix) ---"
root=000
for i in $(seq 1 80); do
  root=$("${CURL[@]}" -o "$W/root.html" -w "%{http_code}" "$B/" || true); [[ -z "$root" ]] && root=000
  [[ "$root" == "200" || "$root" == "500" ]] && break
  (( i % 10 == 1 )) && echo "warte auf Dashboard ... HTTP /=$root"
  sleep 3
done
[[ "$root" == "200" ]] || { rollback "HTTP / = $root"; exit 1; }
echo "OK HTTP / = 200"
grep -q 'data-ninacalm="1"' "$W/root.html" || { rollback "NINA-Kachel ohne ninaCalm auf / (Modul nicht geladen?)"; exit 1; }
echo "OK Lage-Seite: NINA-Kachel mit ninaCalm"
pi=$(code -L --max-redirs 5 "$B/pi")
if [[ "$pi" != "200" ]] && ! [[ "$pre_pi" != "200" && "$pi" == "$pre_pi" ]]; then rollback "HTTP /pi = $pi (vorher $pre_pi)"; exit 1; fi
echo "OK HTTP /pi = $pi (vorher $pre_pi)"
funk=$(code -L --max-redirs 5 "$B/funk")
if [[ "$funk" != "200" ]] && ! [[ "$pre_funk" != "200" && "$funk" == "$pre_funk" ]]; then rollback "HTTP /funk = $funk (vorher $pre_funk)"; exit 1; fi
echo "OK HTTP /funk = $funk (vorher $pre_funk)"
en=$(code "$B/energie"); [[ "$en" == "200" || "$en" == "302" ]] || { rollback "HTTP /energie = $en"; exit 1; }
echo "OK HTTP /energie = $en (302 = Weiterleitung, ok)"

# ---------- 6) Stand jetzt ----------
echo "--- NINA jetzt ---"
python3 - "$W/root.html" << 'PY' || true
import re, sys, html
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
i = s.find("NINA Warnungen")
seg = s[i:i + 4000] if i >= 0 else ""
j = seg.find("Empfangen")
seg = seg[:j] if j > 0 else seg[:1500]
txt = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", seg))).strip()
print("Kachel:", txt[:300])
PY
sudo journalctl -u prepper-dashboard --since "-3min" --no-pager -o cat 2>/dev/null | grep -E 'ninaCalm|NINA-Mesh|meshBootQuiet: NINA' | tail -6 || true
"$VPY" "$MOD" --show 2>/dev/null | head -6 || true
had() { grep -q "$1" "$DASH" && echo 1 || echo 0; }
nc=0; grep -q '# ===== ninaCalm:' "$DASH" && [[ -f "$MOD" ]] && nc=1
echo "OK guards boot=$(grep -q 'update_all()  # einmal beim Start' "$DASH" && echo 1 || echo 0) keepLast=$(had keepLast) meshBootQuiet=$(had meshBootQuiet) uplinkDetect=$(had uplinkDetect) ninaMesh2Direct=$(had ninaMesh2Direct) ninaCalm=$nc"
[[ -f "$DASH.bak-ninacalm-$TS" ]] && echo "Backup: $DASH.bak-ninacalm-$TS (+ nina_mesh_status.json, nina_calm.py/nina_mesh_sent.json falls vorhanden)"
echo "OK ninaCalm fertig: Kachel ohne alte Entwarnung, Mesh je Meldung einmal, Wegfall sendet nichts"
echo "COMMIT $COMMIT_ARG ninaCalm=$nc"
