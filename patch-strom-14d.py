#!/usr/bin/env python3
"""Energie: Day-Ahead-Kachel weg, Strompreis aktuell als 14-Tage-Chart wie Diesel.

Marker: strom14dChart
Idempotent. Aendert nur fetch_strom, die beiden Strom-Kacheln und das Strom-JS.
Nicht angefasst: update_all, data_store, pageFein-Bootpfad.
"""
from pathlib import Path
import ast
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")

MARKER = "strom14dChart"
if MARKER in src:
    print("already patched (strom14dChart) \u2014 nichts geaendert.")
    raise SystemExit(0)


def top_def(text, name):
    needle = "def %s(" % name
    idx = 0
    while True:
        i = text.find(needle, idx)
        if i < 0:
            return None
        if i == 0 or text[i - 1] == "\n":
            j = text.find("\ndef ", i + 1)
            return text[i: j if j > 0 else len(text)]
        idx = i + 1


before = {}
for _name in ("update_all", "load_history", "save_history", "fetch_kraftstoff"):
    before[_name] = top_def(src, _name)
    if not before[_name]:
        raise SystemExit("STOP: def %s fehlt. Datei unberuehrt." % _name)

counts_before = {
    "pageFein": src.count("pageFein"),
    "dataStoreLock": src.count("dataStoreLock"),
    "ninaDualGuard": src.count("ninaDualGuard"),
}

a = src.find("def fetch_strom():\n")
b = src.find("\ndef fetch_kraftstoff():\n", a if a >= 0 else 0)
if a < 0 or b < 0:
    raise SystemExit("STOP: fetch_strom/fetch_kraftstoff Anker fehlt. Datei unberuehrt.")
if src.count("\ndef fetch_strom(") + (1 if src.startswith("def fetch_strom(") else 0) != 1:
    raise SystemExit("STOP: def fetch_strom nicht eindeutig. Datei unberuehrt.")

NEW_FETCH = """def fetch_strom():
    # strom14dChart: 14-Tage-Serie DE-LU, kein Mittel der letzten 24 Stunden.
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), \"strom_history.json\")
    keep_secs = 14 * 86400
    future_secs = 36 * 3600

    def _load():
        if not os.path.exists(path):
            return [], True
        try:
            with open(path, \"r\") as f:
                raw = json.load(f)
        except Exception as e:
            print(\"Strom-Historie lesen:\", e)
            return [], False
        items = raw.get(\"strom\") if isinstance(raw, dict) else raw
        if not isinstance(items, list):
            return [], False
        out = []
        for it in items:
            if not isinstance(it, dict):
                continue
            try:
                ts = int(it[\"ts\"])
                v = round(float(it[\"v\"]), 2)
            except Exception:
                continue
            t = it.get(\"t\") or datetime.fromtimestamp(ts).strftime(\"%d.%m %H:%M\")
            out.append({\"t\": str(t), \"ts\": ts, \"v\": v})
        return out, True

    def _save(items):
        try:
            tmp = path + \".tmp\"
            with open(tmp, \"w\") as f:
                json.dump({\"strom\": items}, f, ensure_ascii=False)
            os.replace(tmp, path)
        except Exception as e:
            print(\"Strom-Historie:\", e)

    def _pts(data):
        if not isinstance(data, dict):
            return []
        unix_s = data.get(\"unix_seconds\") or []
        prices = data.get(\"price\") or []
        if not isinstance(unix_s, list) or not isinstance(prices, list):
            return []
        out = []
        n = min(len(unix_s), len(prices))
        for i in range(n):
            p = prices[i]
            if p is None:
                continue
            try:
                ts = int(unix_s[i])
                ct = round(float(p) / 10.0, 2)
            except Exception:
                continue
            out.append({
                \"t\": datetime.fromtimestamp(ts).strftime(\"%d.%m %H:%M\"),
                \"ts\": ts,
                \"v\": ct,
            })
        return out

    def _bucket(items, secs):
        acc = {}
        order = []
        for it in items:
            bkt = int(it[\"ts\"]) - (int(it[\"ts\"]) % secs)
            if bkt not in acc:
                acc[bkt] = []
                order.append(bkt)
            acc[bkt].append(float(it[\"v\"]))
        out = []
        for bkt in order:
            vs = acc[bkt]
            out.append({
                \"t\": datetime.fromtimestamp(bkt).strftime(\"%d.%m %H:%M\"),
                \"ts\": bkt,
                \"v\": round(sum(vs) / float(len(vs)), 2),
            })
        return out

    def _public(series):
        return [{\"t\": it[\"t\"], \"v\": it[\"v\"]} for it in series]

    def _current(series, now_ts):
        cur = None
        for it in series:
            if int(it[\"ts\"]) <= now_ts:
                cur = it[\"v\"]
        if cur is None and series:
            cur = series[0][\"v\"]
        return cur

    try:
        end_d = now().date()
        start_d = end_d - timedelta(days=13)
        fresh = []
        try:
            url = (
                \"https://api.energy-charts.info/price?bzn=DE-LU&start=%s&end=%s\"
                % (start_d.isoformat(), end_d.isoformat())
            )
            r = requests.get(url, timeout=12)
            fresh = _pts(r.json()) if r.status_code == 200 else []
        except Exception as e:
            print(\"Strom-API:\", e)
            fresh = []
        if len(fresh) < 8:
            try:
                r2 = requests.get(
                    \"https://api.energy-charts.info/price?bzn=DE-LU\", timeout=12
                )
                more = _pts(r2.json()) if r2.status_code == 200 else []
                if len(more) > len(fresh):
                    fresh = more
            except Exception as e:
                print(\"Strom-API-kurz:\", e)
        prev, prev_ok = _load()
        if not prev_ok and not fresh:
            update_fail_counter(\"strom\", False)
            return {\"current\": None, \"series\": []}
        by = {}
        if prev_ok:
            for it in prev:
                by[int(it[\"ts\"])] = it
        for it in fresh:
            by[int(it[\"ts\"])] = it
        now_ts = int(time.time())
        lo = now_ts - keep_secs
        hi = now_ts + future_secs
        series = [by[k] for k in sorted(by) if lo <= k <= hi]
        step = 900
        if len(series) >= 2:
            lim = len(series) - 1
            if lim > 20:
                lim = 20
            steps = []
            for i in range(lim):
                steps.append(int(series[i + 1][\"ts\"]) - int(series[i][\"ts\"]))
            if steps:
                step = min(steps)
        if step < 600 and len(series) > 500:
            series = _bucket(series, 900)
            series = [it for it in series if lo <= int(it[\"ts\"]) <= hi]
        if len(series) > 1600:
            series = series[-1600:]
        if prev_ok or fresh:
            _save(series)
        current = _current(series, now_ts)
        update_fail_counter(\"strom\", bool(fresh) and current is not None)
        return {\"current\": current, \"series\": _public(series)}
    except Exception as e:
        print(\"Strom-Fehler:\", e)
        update_fail_counter(\"strom\", False)
        prev = []
        try:
            prev, prev_ok = _load()
            if not prev_ok:
                prev = []
        except Exception:
            prev = []
        now_ts = int(time.time())
        return {\"current\": _current(prev, now_ts), \"series\": _public(prev)}
"""

src = src[:a] + NEW_FETCH + src[b + 1:]

title_pos = src.find("\u26a1 Strompreis aktuell")
if title_pos < 0:
    raise SystemExit("STOP: Titel Strompreis aktuell fehlt. Datei unberuehrt.")
if src.count("Strompreis aktuell") != 1:
    raise SystemExit("STOP: Strompreis aktuell nicht eindeutig. Datei unberuehrt.")
card_div = src.rfind('<div class=\"card', 0, title_pos)
if card_div < 0:
    raise SystemExit("STOP: card vor Strompreis fehlt. Datei unberuehrt.")
card_start = src.rfind("\n", 0, card_div) + 1
da = src.find("Strompreis Day-Ahead", title_pos)
if da < 0:
    raise SystemExit("STOP: Day-Ahead-Kachel fehlt. Datei unberuehrt.")
bar = src.find('id=\"stromBarChart\"', da)
if bar < 0:
    raise SystemExit("STOP: stromBarChart fehlt. Datei unberuehrt.")
upd = src.find("strom.updated", bar)
if upd < 0:
    raise SystemExit("STOP: Timestamp nach stromBarChart fehlt. Datei unberuehrt.")
line_end = src.find("\n", upd)
next_nl = src.find("\n", line_end + 1) if line_end >= 0 else -1
if line_end < 0 or next_nl < 0:
    raise SystemExit("STOP: Day-Ahead-Abschluss fehlt. Datei unberuehrt.")
close_line = src[line_end + 1:next_nl]
if "</div>" not in close_line:
    raise SystemExit("STOP: Day-Ahead close unerwartet: %r. Datei unberuehrt." % close_line)
html_end = next_nl + 1
nxt = src[html_end:html_end + 220]
if "card" not in nxt:
    raise SystemExit("STOP: nach Day-Ahead keine naechste Kachel: %r" % nxt[:120])

NEW_HTML = """  <div class=\"card full\">
    <div class=\"title\">\u26a1 Strompreis aktuell</div>
    <div class=\"big\">{% if strom is defined and strom.value and strom.value.current is not none %}{{ '%.2f'|format(strom.value.current) }}{% else %}\u2013{% endif %} <span style=\"font-size:.8rem\">ct/kWh</span></div>
    <div class=\"small\">DE-LU \u00b7 14 Tage</div>
    <div class=\"chart-box\"><canvas id=\"stromLineChart\"></canvas></div>
    <div id=\"stromHiLo\" class=\"small\" style=\"margin-top:6px;line-height:1.45\">
      <div><span style=\"color:#ef4444\">\u2191</span> <span id=\"stromHiText\">\u2013</span></div>
      <div><span style=\"color:#22c55e\">\u2193</span> <span id=\"stromLoText\">\u2013</span></div>
    </div>
    <div class=\"small\" style=\"color:{{ strom.color if strom is defined and strom.color else '#94a3b8' }}\">{{ strom.updated if strom is defined and strom.updated else '' }}</div>
  </div>
"""
src = src[:card_start] + NEW_HTML + src[html_end:]

js_key = "const bars = {% if strom.value and strom.value.bars %}"
js_start = src.find(js_key)
if js_start < 0 or src.count(js_key) != 1:
    raise SystemExit("STOP: Strom-Balken-JS fehlt oder nicht eindeutig. Datei unberuehrt.")
pos = src.find("document.getElementById('stromLineChart')", js_start)
if pos < 0:
    raise SystemExit("STOP: stromLineChart JS fehlt. Datei unberuehrt.")
end_rel = src.find("});", pos)
if end_rel < 0:
    raise SystemExit("STOP: Chart-Ende fehlt. Datei unberuehrt.")
brace = src.find("}", end_rel + 3)
if brace < 0:
    raise SystemExit("STOP: JS-if-Ende fehlt. Datei unberuehrt.")
js_end = brace + 1
if src[js_end:js_end + 1] == "\r":
    js_end += 1
if src[js_end:js_end + 1] == "\n":
    js_end += 1

NEW_JS = """// strom14dChart \u2014 14 Tage, Layout wie Diesel regional
const stromHist = {% if strom is defined and strom.value and strom.value.series %}{{ strom.value.series | tojson }}{% else %}[]{% endif %};
(function(){
  const vals = (stromHist || []).map(function(x){ return x && x.v; }).filter(function(v){ return v != null; });
  let hiPt = null, loPt = null;
  for (const p of (stromHist || [])) {
    if (p == null || p.v == null) continue;
    if (hiPt == null || p.v > hiPt.v) hiPt = p;
    if (loPt == null || p.v < loPt.v) loPt = p;
  }
  const hiEl = document.getElementById('stromHiText');
  const loEl = document.getElementById('stromLoText');
  if (hiEl && hiPt) hiEl.textContent = (hiPt.t || '\u2013') + ' \u00b7 ' + Number(hiPt.v).toFixed(2) + ' ct';
  if (loEl && loPt) loEl.textContent = (loPt.t || '\u2013') + ' \u00b7 ' + Number(loPt.v).toFixed(2) + ' ct';
  const canvas = document.getElementById('stromLineChart');
  if (!canvas || !vals.length) return;
  const dMin = Math.min.apply(null, vals);
  const dMax = Math.max.apply(null, vals);
  const yMin = dMin === dMax ? dMin - 0.5 : dMin;
  const yMax = dMin === dMax ? dMax + 0.5 : dMax;
  new Chart(canvas.getContext('2d'), {
    type: 'line',
    data: { labels: stromHist.map(function(x){ return x.t; }), datasets: [{ data: stromHist.map(function(x){ return x.v; }), borderColor: '#3b82f6', backgroundColor: '#3b82f622', borderWidth: 2, pointRadius: 0, fill: true, tension: 0.3 }] },
    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } },
      scales: {
        x: { display: true, ticks: { color: '#64748b', font: { size: 8 }, maxRotation: 0, maxTicksLimit: 5 }, grid: { display: false } },
        y: { display: true, min: yMin, max: yMax,
          ticks: { color: '#64748b', font: { size: 8 }, maxTicksLimit: 2,
            callback: function(v) {
              if (Math.abs(v - yMin) < 1e-6) return yMin.toFixed(2) + ' ct';
              if (Math.abs(v - yMax) < 1e-6) return yMax.toFixed(2) + ' ct';
              return '';
            } },
          grid: { color: '#1e293b' } }
      }, animation: false }
  });
})();
"""
src = src[:js_start] + NEW_JS + src[js_end:]

if "Strompreis Day-Ahead" in src or "stromBarChart" in src:
    raise SystemExit("STOP: Day-Ahead/Bar-Chart noch vorhanden. Datei unberuehrt.")
if src.count("Strompreis aktuell") != 1 or src.count("stromLineChart") < 1:
    raise SystemExit("STOP: Strom-Kachel nach Patch inkonsistent. Datei unberuehrt.")
if src.count(MARKER) < 2:
    raise SystemExit("STOP: Marker strom14dChart zu selten. Datei unberuehrt.")
if "stromHiLo" not in src or "DE-LU" not in src:
    raise SystemExit("STOP: Hi/Lo oder Untertitel fehlt. Datei unberuehrt.")
for _name, _body in before.items():
    if top_def(src, _name) != _body:
        raise SystemExit("STOP: def %s wuerde sich aendern. Datei unberuehrt." % _name)
for _k, _n in counts_before.items():
    if src.count(_k) != _n:
        raise SystemExit("STOP: %s Zaehler geaendert. Datei unberuehrt." % _k)
if "data_store =" in NEW_FETCH or "def update_all" in NEW_FETCH:
    raise SystemExit("STOP: Patch wuerde Bootpfad anfassen. Datei unberuehrt.")
try:
    ast.parse(src)
except SyntaxError as e:
    raise SystemExit("STOP: Syntax nach Patch (%s). Datei unberuehrt." % e)

PATH.write_text(src, encoding="utf-8")
print("Strom 14 Tage: fetch_strom, Kachel vollbreit, Chart+Hi/Lo (strom14dChart).")
