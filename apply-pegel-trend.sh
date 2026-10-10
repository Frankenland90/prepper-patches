#!/bin/bash
set -euo pipefail
# pegelTrend: Trend je Pegel (3 h, aus den GKD-Rohwerten) auf /pegel und im Mesh-Pegeltext.
# Delta = aktuell - Median der Werte von vor 2h45 bis 3h15. |Delta| < 2 cm gleichbleibend (blauer Punkt),
# >= 10 cm Doppelpfeil. Steigend rot, fallend gruen. Kein zusaetzlicher GKD-Abruf, keine Zusatzsendung
# (Dedupe id:cm und funkHarden2-Haltezeit unveraendert). Nur dashboard.py, nur bei sha16 d5b30d1c9ee7647b.
# Sendet nichts. Neustart nur prepper-dashboard (5 min Ruhezeit). Smoke nur GET, nie /api/mesh_pegel.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
VPY="$DASH_DIR/venv/bin/python"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/pegeltrend
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve, nicht das Dashboard - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
echo "=== pegelTrend apply, Dashboard-Port $PORT (config.py: ${CFG_PORT:-fehlt}) ==="
EXPECT_PATCH="3219aa605f42b553691b43f1b3a961d8310b9810a9b47e2af6aafad3c847cb15"
rm -rf "$W" && mkdir -p "$W"
cat > "$W/patch-pegel-trend.py" << 'PATCHPY_EOF'
#!/usr/bin/env python3
"""pegelTrend: Trend je Pegel (3 h) auf /pegel und im Mesh-Text. Sendet nichts."""
import ast
import hashlib
import io
import re
import sys
import tokenize
from pathlib import Path

MARK = "# ===== pegelTrend:"
EXPECT = "d5b30d1c9ee7647b"   # dashboard.py nach escfix
FN_AST = {'fetch_pegel_one': '0c4a69a1d6d3cfbe', '_pegel_hint': '619b3e58201df8b5', 'build_mesh_pegel_text': '944fde402615be3c'}
ANCHOR = '<div class="big">{% if g.cm is not none %}{{ g.cm }} cm{% else %}–{% endif %}</div>'
NEED_DEFS = ["fetch_pegel_one", "fetch_pegel", "_pegel_hint", "build_mesh_pegel_text", "maybe_mesh_pegel", "_fh2_norm"]
MAIN_RE = re.compile(r"^if\s+__name__\s*==\s*['\"]__main__['\"]\s*:", re.M)
BLOCK = r'''
# ===== pegelTrend: Trend je Pegel aus GKD-Rohwerten (3 h) =====
# Delta = aktueller Wert - Median der Rohwerte im Fenster [t-3h15, t-2h45] (t = Zeit des neuesten GKD-Werts).
# |Delta| < 2 cm gleichbleibend (blauer Punkt), >= 10 cm schnell (Doppelpfeil). Kein Wert im Fenster -> Trend -.
# Kein zusaetzlicher GKD-Abruf: fetch_pegel_one wird mit identischem Ablauf ersetzt und rechnet den Trend
# aus derselben Antwort vor dem Ausduennen. Mesh-Dedupe (id:cm) unveraendert -> keine Zusatzsendungen.
import re as _pt_re
import threading as _pt_th
from datetime import datetime as _pt_dt

PT_LO_S = 165 * 60
PT_HI_S = 195 * 60
PT_FLAT_CM = 2
PT_FAST_CM = 10
PT_MAX_AGE_S = 3 * 3600
PT_MESH_MAX = 200
_pt_tls = _pt_th.local()
_pt_res = {}


def _pt_parse(t):
    try:
        return _pt_dt.strptime(" ".join(str(t).split()), "%d.%m.%Y %H:%M")
    except Exception:
        return None


def _pt_trend(rows):
    out = {"trend_cm": None, "trend_state": "none", "trend_txt": "Trend –", "trend_ref_cm": None, "trend_n": 0}
    try:
        if not rows:
            return out
        t0 = _pt_parse(rows[0][0])
        v0 = int(rows[0][1])
        if t0 is None:
            return out
        win = []
        for t, v in rows[1:]:
            tt = _pt_parse(t)
            if tt is None:
                continue
            age = (t0 - tt).total_seconds()
            if PT_LO_S <= age <= PT_HI_S:
                try:
                    win.append(int(v))
                except Exception:
                    pass
        if not win:
            return out
        win.sort()
        m = len(win) // 2
        ref = win[m] if len(win) % 2 else (win[m - 1] + win[m]) / 2.0
        d = v0 - ref
        di = int(round(d))
        if abs(d) < PT_FLAT_CM:
            st, txt = "flat", "gleichbleibend · " + ("±0" if di == 0 else "%+d" % di) + " cm / 3 h"
        elif d >= PT_FAST_CM:
            st, txt = "up2", "▲▲ %+d cm / 3 h" % di
        elif d > 0:
            st, txt = "up", "▲ %+d cm / 3 h" % di
        elif d <= -PT_FAST_CM:
            st, txt = "down2", "▼▼ %+d cm / 3 h" % di
        else:
            st, txt = "down", "▼ %+d cm / 3 h" % di
        out.update({"trend_cm": di, "trend_state": st, "trend_txt": txt.replace("-", "−"),
                    "trend_ref_cm": ref, "trend_n": len(win)})
    except Exception as e:
        print("pegelTrend:", e)
    return out


def _pt_fetch_pegel_one(st):  # pegelTrend: identischer Ablauf wie fetch_pegel_one + Trendfelder
    import re as _re
    slug = st.get("slug") or ""
    url = "https://www.gkd.bayern.de/de/fluesse/wasserstand/bayern/%s/messwerte/tabelle?zr=woche" % slug
    r = requests.get(url, timeout=25, headers={"User-Agent": "PrepperDashboard/1.0"})
    r.raise_for_status()
    rows = _re.findall(r"(\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2}).{0,80}?(\d{2,4})", r.text, _re.S)
    series = []
    for t, v in rows:
        try:
            series.append({"t": t, "v": int(v)})
        except Exception:
            pass
    current = series[0]["v"] if series else None
    when = series[0]["t"] if series else None
    raw = [(x["t"], x["v"]) for x in series]
    series = list(reversed(series))
    vals = [x["v"] for x in series if x.get("v") is not None]
    med = None
    if vals:
        sv = sorted(vals)
        mid = len(sv) // 2
        med = sv[mid] if len(sv) % 2 else round((sv[mid - 1] + sv[mid]) / 2, 1)
    step = max(1, len(series) // 48)
    thin = series[::step]
    print("Pegel", st.get("name"), "n=", len(series), "cm=", current)
    out = dict(st)
    out.update({"cm": current, "unit": "cm", "when": when, "series": thin, "median": med})
    try:
        out.update(_pt_trend(raw))
        _pt_res[str(st.get("id"))] = "%s %s" % (out.get("trend_state"), out.get("trend_cm"))
    except Exception as e:
        print("pegelTrend fetch:", e)
    return out


_pt_orig_fetch_pegel_one = fetch_pegel_one
fetch_pegel_one = _pt_fetch_pegel_one


def _pt_state(g):
    """Trendzustand nur, wenn der Messwert frisch ist (keepLast/staleTs-Altwert -> none)."""
    try:
        if not isinstance(g, dict) or g.get("cm") is None:
            return "none"
        st = g.get("trend_state") or "none"
        if st not in ("up", "up2", "down", "down2", "flat"):
            return "none"
        t = _pt_parse(g.get("when"))
        if t is None:
            return "none"
        age = (_pt_dt.now() - t).total_seconds()
        if age > PT_MAX_AGE_S or age < -1800:
            return "none"
        return st
    except Exception:
        return "none"


_PT_COLOR = {"up": "#ef4444", "up2": "#dc2626", "down": "#22c55e", "down2": "#16a34a", "flat": "#94a3b8", "none": "#94a3b8"}


def pt_view(g):
    st = _pt_state(g)
    txt = (g.get("trend_txt") if isinstance(g, dict) else None) if st != "none" else "Trend –"
    return {"state": st, "txt": txt or "Trend –", "color": _PT_COLOR.get(st, "#94a3b8"),
            "dot": st == "flat", "bold": st in ("up2", "down2")}


_PT_ANCHOR = '<div class="big">{% if g.cm is not none %}{{ g.cm }} cm{% else %}–{% endif %}</div>'
_PT_LINE = ('\n  {% set ptv = pt_view(g) %}<div class="small pg-trend pg-trend-{{ ptv.state }}" '
            'style="font-size:.9rem;margin:-2px 0 4px;color:{{ ptv.color }}{% if ptv.bold %};font-weight:700{% endif %}">'
            '{% if ptv.dot %}<span class="pg-trend-dot" style="color:#3b82f6">●</span> {% endif %}{{ ptv.txt }}</div>')
try:
    if isinstance(globals().get("PAGE_PEGEL"), str) and PAGE_PEGEL.count(_PT_ANCHOR) == 1 and "pg-trend" not in PAGE_PEGEL:
        PAGE_PEGEL = PAGE_PEGEL.replace(_PT_ANCHOR, _PT_ANCHOR + _PT_LINE)
        _pt_res["page"] = "neu"
    else:
        _pt_res["page"] = "Anker fehlt"
    app.jinja_env.globals["pt_view"] = pt_view
except Exception as _pt_e:
    _pt_res["page"] = "Fehler %s" % _pt_e

_PT_SUF = {"up": " ▲", "up2": " ▲▲", "down": " ▼", "down2": " ▼▼", "flat": " ●"}
_pt_orig_pegel_hint = _pegel_hint


def _pegel_hint(st, cm):  # pegelTrend: Trend hinter "cm", Stufentext bleibt
    s = _pt_orig_pegel_hint(st, cm)
    try:
        if getattr(_pt_tls, "off", False) or cm is None:
            return s
        state = _pt_state(st)
        if state == "none" or " cm" not in s:
            return s
        suf = _PT_SUF[state]
        if state != "flat":
            suf += "%+d" % int(st.get("trend_cm"))
        i = s.index(" cm") + 3
        return s[:i] + suf + s[i:]
    except Exception:
        return s


_pt_orig_build_text = build_mesh_pegel_text


def build_mesh_pegel_text(items=None):  # pegelTrend: max 200 Zeichen, sonst ohne Trend
    txt = _pt_orig_build_text(items)
    try:
        if items and txt is not None and len(txt) > PT_MESH_MAX:
            _pt_tls.off = True
            try:
                txt = _pt_orig_build_text(items)
            finally:
                _pt_tls.off = False
    except Exception:
        _pt_tls.off = False
    return txt


# funkHarden2-Haltezeit vergleicht normalisierten Text: Trendzeichen dort ausblenden,
# damit ein neuer Pfeil allein keine zusaetzliche Auto-Sendung erlaubt.
_PT_STRIP = _pt_re.compile(r"( cm) (?:▲▲|▲|▼▼|▼|●)[+-]?\d*")
_pt_orig_fh2_norm = globals().get("_fh2_norm")
if callable(_pt_orig_fh2_norm):
    def _fh2_norm(text):  # pegelTrend
        try:
            text = _PT_STRIP.sub(r"\1", str(text or ""))
        except Exception:
            pass
        return _pt_orig_fh2_norm(text)
    _pt_res["fh2_norm"] = "neu"
else:
    _pt_res["fh2_norm"] = "fehlt"

_pt_res["active"] = 1
print("pegelTrend aktiv: Seite", _pt_res.get("page"), "Haltezeit-Norm", _pt_res.get("fh2_norm"))
# ===== /pegelTrend =====

'''


def tokh(seg):
    out = []
    for t in tokenize.generate_tokens(io.StringIO(seg).readline):
        if t.type in (tokenize.COMMENT, tokenize.NL, tokenize.NEWLINE, tokenize.ENDMARKER):
            continue
        out.append("%s:%s" % (tokenize.tok_name[t.type], t.string if t.type not in (tokenize.INDENT, tokenize.DEDENT) else ""))
    return hashlib.sha256("\n".join(out).encode()).hexdigest()[:16]


def main():
    f = Path(sys.argv[1]) / "dashboard.py"
    nosha = "--nosha" in sys.argv[2:]
    src = f.read_text(encoding="utf-8")
    if MARK in src:
        print("RESULT dashboard.py=schon")
        return
    h = hashlib.sha256(src.encode()).hexdigest()[:16]
    if h != EXPECT and not nosha:
        raise SystemExit("STOP: dashboard.py sha16 %s statt %s - nichts geaendert" % (h, EXPECT))
    tree = ast.parse(src)
    defs = {}
    page = []
    for n in tree.body:
        if isinstance(n, ast.FunctionDef):
            defs.setdefault(n.name, []).append(n)
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "PAGE_PEGEL" for t in n.targets):
            page.append(n)
    miss = [k for k in NEED_DEFS if k not in defs]
    if miss:
        raise SystemExit("STOP: Funktion fehlt %s - nichts geaendert" % miss)
    for k, want in FN_AST.items():
        if len(defs[k]) != 1:
            raise SystemExit("STOP: %s %d mal definiert - nichts geaendert" % (k, len(defs[k])))
        got = tokh(ast.get_source_segment(src, defs[k][0]))
        if got != want:
            raise SystemExit("STOP: %s weicht vom geprueften Stand ab (%s statt %s) - nichts geaendert" % (k, got, want))
    # PAGE_PEGEL darf zusammengesetzt sein (z. B. + NAV); ersetzt wird zur Laufzeit am fertigen Wert
    # (genau 1 Anker, sonst Seite unveraendert) und nach dem Neustart an /pegel geprueft.
    if not page:
        raise SystemExit("STOP: PAGE_PEGEL nicht gefunden - nichts geaendert")
    na = src.count(ANCHOR)
    if na < 1 or "pg-trend" in src:
        raise SystemExit("STOP: Pegel-Anker %d mal in dashboard.py - nichts geaendert" % na)
    ms = list(MAIN_RE.finditer(src))
    if len(ms) != 1:
        raise SystemExit("STOP: __main__ %d mal" % len(ms))
    p = ms[0].start()
    new = src[:p].rstrip("\n") + "\n\n" + BLOCK + "\n\n" + src[p:]
    ast.parse(new)
    compile(new, str(f), "exec")
    f.write_text(new, encoding="utf-8")
    print("RESULT dashboard.py=neu (sha16 vorher %s, Funktionen geprueft, Anker %dx in Datei, PAGE_PEGEL %dx zugewiesen)" % (h, na, len(page)))


if __name__ == "__main__":
    main()
PATCHPY_EOF

# ---------- 0) Bytes + AST-Guard ----------
P="$W/patch-pegel-trend.py"
echo "$EXPECT_PATCH  $P" | sha256sum -c - >/dev/null || { echo "STOP: patch sha256 falsch"; exit 1; }
python3 -m py_compile "$P"
set +e
python3 - "$P" << 'GUARDPY'
import ast, pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
blk = None
for n in ast.parse(src).body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "BLOCK" for t in n.targets):
        blk = n.value.value
if blk is None:
    raise SystemExit(4)
hit = False
net = []
bt = ast.parse(blk)
for fn in [x for x in ast.walk(bt) if isinstance(x, ast.FunctionDef)] + [bt]:
    for node in (ast.walk(fn) if isinstance(fn, ast.FunctionDef) else bt.body):
        if isinstance(node, ast.Call):
            f = node.func
            nm = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else "")
            if nm.startswith(("send", "maybe_mesh")) or nm in ("TCPInterface", "sendText", "urlopen", "create_connection", "update_all", "post", "Popen", "system", "run"):
                print("verbotener Aufruf", nm, "Zeile", node.lineno); hit = True
            if isinstance(f, ast.Attribute) and f.attr in ("get", "request") and isinstance(f.value, ast.Name) and f.value.id in ("requests", "urllib"):
                net.append((fn.name if isinstance(fn, ast.FunctionDef) else "<modul>", node.lineno))
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "data_store":
                    print("data_store-Zuweisung"); hit = True
                if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name) and t.value.id == "data_store":
                    print("data_store-Schreiben"); hit = True
net = sorted(set(net))
if net != [("_pt_fetch_pegel_one", net[0][1] if net else 0)]:
    print("Netzaufrufe im Block:", net); hit = True
raise SystemExit(3 if hit else 0)
GUARDPY
g=$?
set -e
[[ "$g" -eq 0 ]] || { echo "STOP: AST-Guard rc=$g - nichts geaendert"; exit 1; }
echo "OK Bytes + AST-Guard (kein Sendeweg, kein data_store, genau 1 GKD-Abruf = Ersatz des bisherigen)"

# ---------- 1) Trockenlauf ----------
[[ -f "$F" ]] || { echo "STOP: $F fehlt - nichts geaendert"; exit 1; }
rm -rf "$W/work" "$W/work1" && mkdir -p "$W/work"
cp -a "$F" "$W/work/"
python3 "$P" "$W/work" > "$W/dry.txt" 2>&1 || { cat "$W/dry.txt"; echo "STOP: Trockenlauf - nichts geaendert"; exit 1; }
cat "$W/dry.txt"
cp -a "$W/work" "$W/work1"
python3 "$P" "$W/work" > /dev/null
cmp -s "$W/work/dashboard.py" "$W/work1/dashboard.py" || { echo "STOP: nicht idempotent - nichts geaendert"; exit 1; }
"$VPY" -W error::SyntaxWarning -m py_compile "$W/work/dashboard.py" || { echo "STOP: py_compile - nichts geaendert"; exit 1; }
grep -q '# ===== pegelTrend:' "$W/work/dashboard.py" || { echo "STOP: Marker fehlt im Trockenlauf"; exit 1; }
echo "OK Trockenlauf idempotent + kompiliert ohne Warnung"
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
declare -A PRE
for p in / /pegel /funk /mesh; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: / =${PRE[/]} /pegel=${PRE[/pegel]} /funk=${PRE[/funk]} /mesh=${PRE[/mesh]}"

if cmp -s "$W/work/dashboard.py" "$F"; then
  echo "OK dashboard.py hat pegelTrend schon - kein Neustart"
else
  sudo -v
  rb() {
    echo "ROLLBACK: $1"
    cp -a "$F.bak-pegtrend-$TS" "$F"
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    echo "alter Stand wieder aktiv (HTTP / = $(code "$B/")), Backup $F.bak-pegtrend-$TS bleibt"
  }
  cp -a "$F" "$F.bak-pegtrend-$TS"
  cp "$W/work/dashboard.py" "$F"
  "$VPY" -m py_compile "$F" || { rb "py_compile"; exit 1; }
  sudo systemctl restart prepper-dashboard.service
  echo "Dashboard neu gestartet - warte auf HTTP (max 240 s; 5 min Ruhezeit, sendet nichts) ..."
  ok=0
  for i in $(seq 1 80); do
    sleep 3
    [[ "$(code "$B/")" == "200" ]] && { ok=1; break; }
    (( i % 10 == 0 )) && echo "  ... $((i*3)) s"
  done
  [[ "$ok" -eq 1 ]] || { rb "Dashboard antwortet nicht"; exit 1; }
  pc=$("${CURL[@]}" -L --max-redirs 5 "$B/pegel" -o "$W/pegel.html" -w "%{http_code}" || true)
  nt=$(grep -o 'class="small pg-trend pg-trend-[a-z0-9]*' "$W/pegel.html" 2>/dev/null | wc -l || true)
  st=$(grep -o 'pg-trend pg-trend-[a-z0-9]*' "$W/pegel.html" 2>/dev/null | sed 's/pg-trend pg-trend-//' | tr '\n' ' ' || true)
  echo "GET /pegel = $pc, Trendzeilen=$nt, Zustaende: ${st:-keine}"
  [[ "$pc" == "200" && "$nt" -ge 1 ]] || { rb "/pegel ohne Trendzeile"; exit 1; }
  echo "OK /pegel zeigt Trend"
fi
fail=0
for p in / /pegel /funk /mesh; do
  c=$(code -L --max-redirs 5 "$B$p")
  if [[ "$c" != "${PRE[$p]}" && "$c" != "200" ]]; then fail=1; fi
  printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"
done
if [[ "$fail" -ne 0 ]]; then
  if [[ -f "$F.bak-pegtrend-$TS" ]]; then rb "Seite antwortet schlechter als vorher"; fi
  exit 1
fi
echo "OK guards pegelTrend=$(grep -q '# ===== pegelTrend:' "$F" && echo 1 || echo 0) funkHarden3=$(grep -q '# ===== funkHarden3:' "$F" && echo 1 || echo 0) funkHarden2=$(grep -q '# ===== funkHarden2:' "$F" && echo 1 || echo 0)"
[[ -f "$F.bak-pegtrend-$TS" ]] && echo "Backup: $F.bak-pegtrend-$TS"
echo "Hinweis: Mesh-Text bekommt den Trend beim naechsten Pegel-Versand (Auto oder Button), keine Zusatzsendung"
echo "COMMIT $COMMIT_ARG pegelTrend=1"
