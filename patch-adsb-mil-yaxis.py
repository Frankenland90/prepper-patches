#!/usr/bin/env python3
"""ADSB Chart: Militär auf rechter Y-Achse + eigener Median. Idempotent /* milyAxis */."""
from pathlib import Path
import sys

PATH = Path(sys.argv[1] if len(sys.argv) > 1 else "/home/fmg/prepper-dashboard/dashboard.py")
src = PATH.read_text(encoding="utf-8")
if "/* milyAxis */" in src:
    print("Militär-Y-Achse schon drin — nichts geaendert.")
    raise SystemExit(0)

def must_replace(text, old, new, label):
    n = text.count(old)
    if n != 1:
        raise SystemExit("STOP %s: Anker %sx (erwartet 1)." % (label, n))
    return text.replace(old, new, 1)

# 1) Median/Verdict für Militär nach fresh-Verdict
old_v = '''        elif len(hist) >= 3:
            out["verdict"] = "Baseline wird aufgebaut (%s Punkte)" % len(hist)
            out["verdict_color"] = "#94a3b8"
        out["hist_t"] = [p.get("t") for p in hist]
        out["hist_fresh"] = [p.get("fresh") for p in hist]
        out["hist_pos"] = [p.get("pos") for p in hist]
        out["hist_mil"] = [p.get("mil") or 0 for p in hist]
'''
new_v = '''        elif len(hist) >= 3:
            out["verdict"] = "Baseline wird aufgebaut (%s Punkte)" % len(hist)
            out["verdict_color"] = "#94a3b8"
        # Militär-Median (eigene Skala/Tendenz) /* milyAxis */
        mils24 = [int(p.get("mil") or 0) for p in hist if now_ts - float(p.get("ts") or 0) <= 24 * 3600]
        mils_h = [int(p.get("mil") or 0) for p in hist if abs(int(p.get("hour") or 0) - now().hour) <= 1 and now_ts - float(p.get("ts") or 0) > 3600]
        mil_base = sorted(mils_h) if len(mils_h) >= 8 else sorted(mils24)
        out["mil_median"] = None
        out["verdict_mil"] = "Militär-Baseline wird aufgebaut"
        out["verdict_mil_color"] = "#94a3b8"
        if len(mil_base) >= 8:
            mil_med = mil_base[len(mil_base) // 2]
            out["mil_median"] = mil_med
            if mil_n >= max(2, mil_med * 2 + 1):
                out["verdict_mil"] = "ungewöhnlich viel Militär (Median ~%s)" % mil_med
                out["verdict_mil_color"] = "#eab308"
            elif mil_med >= 1 and mil_n == 0:
                out["verdict_mil"] = "unter Militär-Median (~%s)" % mil_med
                out["verdict_mil_color"] = "#94a3b8"
            else:
                out["verdict_mil"] = "Militär im Rahmen (Median ~%s)" % mil_med
                out["verdict_mil_color"] = "#22c55e"
        out["hist_t"] = [p.get("t") for p in hist]
        out["hist_fresh"] = [p.get("fresh") for p in hist]
        out["hist_pos"] = [p.get("pos") for p in hist]
        out["hist_mil"] = [p.get("mil") or 0 for p in hist]
'''
src = must_replace(src, old_v, new_v, "mil median verdict")

# defaults when offline
old_def = '''        "feeder": "offline", "hist_t": [], "hist_fresh": [], "hist_pos": [], "hist_mil": [],
        "verdict": "keine Daten", "verdict_color": "#94a3b8",
'''
new_def = '''        "feeder": "offline", "hist_t": [], "hist_fresh": [], "hist_pos": [], "hist_mil": [],
        "verdict": "keine Daten", "verdict_color": "#94a3b8",
        "mil_median": None, "verdict_mil": "keine Daten", "verdict_mil_color": "#94a3b8",
'''
if old_def in src:
    src = must_replace(src, old_def, new_def, "out defaults mil median")

# 2) Chart card caption + mil verdict line
old_cap = '''  <div style="color:{{ adsb.verdict_color }};font-size:0.95rem;margin-bottom:8px">{{ adsb.verdict }}</div>
  <div style="height:160px"><canvas id="adsbChart"></canvas></div>
  <div class="small">Blau frisch · Grau Position · Orange Militär · Bewertung gegen eigenes Mittel</div>
'''
new_cap = '''  <div style="color:{{ adsb.verdict_color }};font-size:0.95rem;margin-bottom:4px">{{ adsb.verdict }}</div>
  <div style="color:{{ adsb.verdict_mil_color if adsb.verdict_mil_color is defined else '#94a3b8' }};font-size:0.9rem;margin-bottom:8px">{{ adsb.verdict_mil if adsb.verdict_mil is defined else '' }}</div>
  <div style="height:160px"><canvas id="adsbChart"></canvas></div>
  <div class="small">Links: frisch/Position · Rechts: Militär · Orange gestrichelt = Mil-Median</div>
'''
src = must_replace(src, old_cap, new_cap, "chart caption")

# 3) Chart.js dual axis
old_js = '''  const labels = {{ adsb.hist_t | tojson }};
  const fresh = {{ adsb.hist_fresh | tojson }};
  const pos = {{ adsb.hist_pos | tojson }};
  const mil = {{ adsb.hist_mil | tojson }};
  const el = document.getElementById("adsbChart");
  if (!el || !labels.length) return;
  new Chart(el.getContext("2d"), {
    type: "line",
    data: {
      labels: labels,
      datasets: [
        { label: "frisch", data: fresh, borderColor: "#3b82f6", backgroundColor: "#3b82f622", borderWidth: 2, pointRadius: 0, fill: true, tension: 0.25 },
        { label: "Position", data: pos, borderColor: "#64748b", borderWidth: 1.5, pointRadius: 0, fill: false, tension: 0.25 },
        { label: "Militär", data: mil, borderColor: "#f59e0b", borderWidth: 1.5, pointRadius: 0, fill: false, tension: 0.25 }
      ]
    },
    options: {
      responsive: true, maintainAspectRatio: false, animation: false,
      plugins: { legend: { display: true, labels: { color: "#94a3b8", boxWidth: 10, font: { size: 10 } } } },
      scales: {
        x: { ticks: { color: "#64748b", font: { size: 8 }, maxTicksLimit: 8 }, grid: { color: "#1e293b" } },
        y: { ticks: { color: "#64748b", font: { size: 9 } }, grid: { color: "#1e293b" }, beginAtZero: true }
      }
    }
  });
'''
new_js = '''  const labels = {{ adsb.hist_t | tojson }};
  const fresh = {{ adsb.hist_fresh | tojson }};
  const pos = {{ adsb.hist_pos | tojson }};
  const mil = {{ adsb.hist_mil | tojson }};
  const milMed = {{ adsb.mil_median | tojson }};
  const el = document.getElementById("adsbChart");
  if (!el || !labels.length) return;
  const milMedLine = (milMed === null || milMed === undefined) ? [] : mil.map(function(){ return milMed; });
  const ds = [
    { label: "frisch", data: fresh, borderColor: "#3b82f6", backgroundColor: "#3b82f622", borderWidth: 2, pointRadius: 0, fill: true, tension: 0.25, yAxisID: "y" },
    { label: "Position", data: pos, borderColor: "#64748b", borderWidth: 1.5, pointRadius: 0, fill: false, tension: 0.25, yAxisID: "y" },
    { label: "Militär", data: mil, borderColor: "#f59e0b", borderWidth: 2, pointRadius: 0, fill: false, tension: 0.25, yAxisID: "y1" }
  ];
  if (milMedLine.length) {
    ds.push({ label: "Mil-Median", data: milMedLine, borderColor: "#fbbf24", borderDash: [5, 4], borderWidth: 1.5, pointRadius: 0, fill: false, yAxisID: "y1" });
  }
  new Chart(el.getContext("2d"), {
    type: "line",
    data: { labels: labels, datasets: ds },
    options: {
      responsive: true, maintainAspectRatio: false, animation: false,
      plugins: { legend: { display: true, labels: { color: "#94a3b8", boxWidth: 10, font: { size: 10 } } } },
      scales: {
        x: { ticks: { color: "#64748b", font: { size: 8 }, maxTicksLimit: 8 }, grid: { color: "#1e293b" } },
        y: { position: "left", ticks: { color: "#93c5fd", font: { size: 9 } }, grid: { color: "#1e293b" }, beginAtZero: true },
        y1: { position: "right", ticks: { color: "#f59e0b", font: { size: 9 } }, grid: { drawOnChartArea: false }, beginAtZero: true, suggestedMax: 4 }
      }
    }
  });
'''
src = must_replace(src, old_js, new_js, "chart.js dual y")

PATH.write_text(src, encoding="utf-8")
print("OK: Militär rechte Y-Achse + Median ->", PATH)
