#!/bin/bash
set -eEuo pipefail
# commit53 umweltFlach - Seite /umwelt flach und kurz (nur Anzeige, sendet nichts):
#  - Reihenfolge DWD, Wetter, Waldbrand, Stoersender, Gewitter, ODL, Sonne; eine Rahmenebene (keine Kachel in Kachel, fehlendes </div> behoben)
#  - Umbruch statt Abschneiden mit Punkten; Erklaertexte hinter aufklappbarem i, Sicherheitshinweise wortgleich
#  - Stick-L1 nur bei gelb/rot; nicht gemessene Baender in einer grauen Zeile; Gewitter in Ruhe 1 Zeile
#  - Ereignisse 5 sichtbar, Rest unter mehr; letzte QRM-Messung alt -> rot mit Grund
#  - Browser: Ereignis-Takt 2 s und 30-s-Abruf auf /umwelt weg, ein Abruf alle 120 s nur bei sichtbarem Tab (/funk433 unveraendert)
#  - Mesh-Knoepfe (Wetter, ODL, Sonne) ohne PIN in ihrer Kachel, Sende-Skripte unveraendert
#  dashboard.py: ein Block vor __main__ (keine geaenderte Zeile); lage_pages.py: nur der Kachelbereich der Vorlage page3 (/umwelt). prepper_sdr.py bleibt unveraendert.
#  Beide Dateien gemeinsam: beide alt -> beide ersetzen, beide neu -> nichts tun, gemischt -> STOP.
# Aufruf: bash /tmp/apply-commit53.sh commit53 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py ab18872053f58871 + lage_pages.py 1d33ae9fd78f53dc (nach commit52) oder 832787ef1c3b44bc + a51d9b51a646813d (neu), prepper_sdr.py 0900bfe6ba67e657.
# Sicherungen dashboard.py.bak-commit53-ZEIT und lage_pages.py.bak-commit53-ZEIT (je letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Beim Einspielen wird nichts gesendet, Gain-Stufe 16 bleibt.
COMMIT_ARG="${1:-unbekannt}"
MODE_ARG="${2:-}"
case "$MODE_ARG" in ""|dry-run|--dry-run|dryrun|trockenlauf) ;; *) echo "STOP: unbekannter zweiter Parameter '$MODE_ARG' (erlaubt: dry-run) - nichts geaendert"; exit 1;; esac
DRY=0; [[ -n "$MODE_ARG" ]] && DRY=1
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
FL="$DASH_DIR/lage_pages.py"
FS="$DASH_DIR/prepper_sdr.py"
VENV="$DASH_DIR/venv"
VPY="$VENV/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/commit53-apply
KEEP_LAST=3
NM=commit53
KNOWN_D16="ab18872053f58871"; KNOWN_D16N="832787ef1c3b44bc"; KNOWN_D16_C51="67d58079139cd373"; KNOWN_D16_C50="2a3625a3325653b1"; KNOWN_D16_C49="1dc1eedcb0c91342"; KNOWN_D16_C48="334b60f2ed228831"
KNOWN_L16="1d33ae9fd78f53dc"; KNOWN_L16N="a51d9b51a646813d"; KNOWN_S16="0900bfe6ba67e657"
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
echo "=== commit53 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): umweltFlach, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt"
EXPECT_PAL="fe5d4732edc9072bfb13e77c9fac981974c53c27261cd6e247a5f3cf6864fd8b"
cat > "$W/patch.py" << 'MK_C53_PAL_EOF'
"""Patcher umweltFlach (generisch wie relStop). Aufruf: patch.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
name = {"dsh": "dashboard.py", "lp": "lage_pages.py"}[kind]
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
MK_C53_PAL_EOF
EXPECT_RAE="7568c725d646db18546a7f322694797be320e34e80699adec6bb64d76eb6c998"
cat > "$W/edits.py" << 'MK_C53_RAE_EOF'
# Stellen fuer umweltFlach (commit53): dashboard.py Basis ab18872053f58871 nur ein Block vor __main__; lage_pages.py Basis 1d33ae9fd78f53dc: page3 Kachelbereich (Raster) ersetzt
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
LP_ANCHOR = None
LP_EDITS = [('<div class="grid">\n  <div class="card full">\n    <div class="title">🌤 Wetter Kalchreuth (90562)</div>\n    <div class="big">{{ wetter.value.icon or \'\' }} {{ wetter.value.temp or \'–\' }} °C</div>\n    <div class="small">Sonne heute {{ wetter.value.sunshine if wetter.value.sunshine is not none else \'–\' }} h</div>\n    <div style="display:grid;grid-template-columns:70px 1fr auto auto;gap:4px 10px;margin-top:10px;font-size:0.82rem;align-items:center">\n      {% for d in wetter.value.days or [] %}\n        <div style="color:#94a3b8">{{ d.weekday }} {{ d.date }}</div>\n        <div><b>{{ d.max }}°</b> / {{ d.min }}°</div>\n        <div style="color:#94a3b8">{{ d.sun if d.sun is not none else \'–\' }} h</div>\n        <div>{{ d.icon }}</div>\n      {% endfor %}\n    </div>\n    <div class="small" style="color:{{ wetter.color }}">{{ wetter.updated }}</div>\n  </div>\n  <!-- dwdV3 -->\n  <div class="card full">\n    <div class="title">⚠️ DWD Warnungen</div>\n    {% set dw = dwd_warn.value if dwd_warn is defined and dwd_warn.value else {} %}\n    {% set ml = dw.get(\'max_level\', 0) if dw is mapping else 0 %}\n    <div class="big" style="color:{{ dw.get(\'color\', \'#22c55e\') if dw is mapping else \'#22c55e\' }}">Stufe {{ ml if ml is not none else 0 }}</div>\n    <div class="small" style="color:#94a3b8;margin-bottom:6px">Kalchreuth · Forst · Erlangen · ERH · Schnaittach · DWD</div>\n    {% if dw is mapping and dw.get(\'items\') %}\n      <div style="margin-top:6px;font-size:0.82rem;line-height:1.45">\n      {% for it in dw.get(\'items\') %}\n        <div style="padding:5px 0;border-bottom:1px solid #1e293b">\n          <b>{{ it.name }}</b>\n          <span style="color:{{ \'#ef4444\' if (it.level or 0) >= 4 else (\'#f97316\' if (it.level or 0) >= 3 else (\'#eab308\' if (it.level or 0) >= 2 else \'#84cc16\')) }}"> · St. {{ it.level }}</span>\n          <div>{{ it.event or it.headline or \'–\' }}</div>\n          {% if it.headline and it.event and it.headline != it.event %}<div class="small" style="color:#94a3b8">{{ it.headline }}</div>{% endif %}\n          {% if it.start or it.end %}<div class="small" style="color:#64748b">{{ it.start or \'–\' }} – {{ it.end or \'–\' }}</div>{% endif %}\n        </div>\n      {% endfor %}\n      </div>\n    {% else %}\n      <div class="small">Keine lokalen DWD-Warnungen</div>\n    {% endif %}\n    <div class="small" style="margin-top:6px;color:#64748b">Quelle: DWD</div>\n    <div class="small" style="color:{{ dwd_warn.color if dwd_warn is defined else \'#94a3b8\' }}">{{ dwd_warn.updated if dwd_warn is defined else \'\' }}</div>\n    {% if dwd_mesh_status is defined and dwd_mesh_status %}\n      <div class="small" style="margin-top:4px;color:#64748b">\n        Mesh · {% if dwd_mesh_status.cleared %}Entwarnung {{ dwd_mesh_status.cleared }}{% elif dwd_mesh_status.text %}{{ dwd_mesh_status.text[:80] }}{% else %}–{% endif %}\n        {% if dwd_mesh_status.at %} · {{ dwd_mesh_status.at }}{% endif %}\n      </div>\n    {% endif %}\n  </div>\n  <div class="card">\n    <div class="title">🔥 DWD WBI · Waldbrand</div>\n    {% set wb = dwd_wbi.value if dwd_wbi is defined and dwd_wbi.value else {} %}\n    {% if wb is mapping and wb.get(\'wbi\') is not none %}\n      <div class="big" style="color:{{ wb.get(\'color\', \'#e2e8f0\') }}">Stufe {{ wb.wbi }}</div>\n      {% if wb.get(\'stale\') %}<div class="small" style="color:#eab308">Datenstand veraltet ({{ wb.get(\'date_fmt\') or wb.get(\'date\') or \'–\' }})</div>{% endif %}\n      <div class="small" style="margin-top:4px">Station {{ wb.get(\'station_name\') or \'Nürnberg\' }} ({{ wb.get(\'station_id\') or \'3668\' }}) · {{ wb.get(\'distance_km\') or 8.2 }} km</div>\n      <div class="small" style="color:#94a3b8">Datum {{ wb.get(\'date_fmt\') or wb.get(\'date\') or \'–\' }}</div>\n    {% else %}\n      <div class="small">Keine WBI-Daten</div>\n    {% endif %}\n    {% if wbi_history is defined and wbi_history %}\n      <div class="small" style="margin-top:6px;color:#64748b;word-break:break-word">\n        Verlauf:\n        {% for h in wbi_history[-14:] %}{{ h.t }}:{{ h.v }}{% if not loop.last %} · {% endif %}{% endfor %}\n      </div>\n    {% endif %}\n    <div class="small" style="margin-top:6px;color:#64748b">Quelle: DWD WBI Forecast</div>\n    <div class="small" style="color:{{ dwd_wbi.color if dwd_wbi is defined else \'#94a3b8\' }}">{{ dwd_wbi.updated if dwd_wbi is defined else \'\' }}</div>\n  </div>\n  <div class="card full" style="padding:10px;text-align:center">\n    <button id="meshWeatherBtn" onclick="sendMeshWeather()" style="background:#1e293b;color:#e2e8f0;border:1px solid #334155;border-radius:10px;padding:10px 16px;font-size:0.82rem;cursor:pointer">\n      📡 Wetter an Mesh (Kalchreuth + Schnaittach)\n    </button>\n    <div id="meshWeatherStatus" class="small" style="margin-top:8px;min-height:1.2em;color:#94a3b8"></div>\n    <div class="small" style="margin-top:4px"></div>\n    <div class="small" style="margin-top:8px;line-height:1.6">\n      <div id="meshAutoLine" style="color:{% if mesh_weather_status is defined and mesh_weather_status.auto %}#22c55e{% else %}#eab308{% endif %}">\n        A · {% if mesh_weather_status is defined and mesh_weather_status.auto %}{{ mesh_weather_status.auto }}{% else %}noch keine Auto-Sendung{% endif %}\n      </div>\n      <div id="meshManualLine" style="color:#94a3b8">\n        M · {% if mesh_weather_status is defined and mesh_weather_status.manual %}{{ mesh_weather_status.manual }}{% else %}–{% endif %}\n      </div>\n    </div>\n    <div class="small" style="margin-top:4px;color:#64748b">Auto: 0/3/6/9/12/15/18/21 Uhr</div>\n\n  <div class="card full">\n    <div class="title">\n  \n\n    \n  <div class="card">\n    <div class="title">☀ Sonnenaktivität</div>\n    {% set sw = spaceweather.value if spaceweather is defined else none %}\n    {% if sw is mapping and sw.get(\'kp\') is not none %}\n      <div class="big" style="color:{{ sw.color or \'#e2e8f0\' }}">Kp {{ sw.kp }}</div>\n      <div class="small" style="color:{{ sw.color or \'#94a3b8\' }}">{{ sw.label or \'\' }}</div>\n      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:10px;font-size:0.9rem">\n        <div><span style="color:#94a3b8">Kp 24h-max</span><br><b>{{ sw.kp_max24 if sw.kp_max24 is not none else \'–\' }}</b></div>\n        <div><span style="color:#94a3b8">G / R / S</span><br><b>{% set _gn = 0 %}{% if (sw.G or \'\') == \'G5\' %}{% set _gn = 5 %}{% elif (sw.G or \'\') == \'G4\' %}{% set _gn = 4 %}{% elif (sw.G or \'\') == \'G3\' %}{% set _gn = 3 %}{% elif (sw.G or \'\') == \'G2\' %}{% set _gn = 2 %}{% elif (sw.G or \'\') == \'G1\' %}{% set _gn = 1 %}{% endif %}{% set _gk = 0 %}{% if sw.kp >= 9 %}{% set _gk = 5 %}{% elif sw.kp >= 8 %}{% set _gk = 4 %}{% elif sw.kp >= 7 %}{% set _gk = 3 %}{% elif sw.kp >= 6 %}{% set _gk = 2 %}{% elif sw.kp >= 5 %}{% set _gk = 1 %}{% endif %}{% set _gm = 0 %}{% if sw.kp_max24 is not none and sw.kp_max24 >= 9 %}{% set _gm = 5 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 8 %}{% set _gm = 4 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 7 %}{% set _gm = 3 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 6 %}{% set _gm = 2 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 5 %}{% set _gm = 1 %}{% endif %}{% set _gs = _gn %}{% if _gk > _gs %}{% set _gs = _gk %}{% endif %}{% if _gm > _gs %}{% set _gs = _gm %}{% endif %}{% if _gs >= 1 %}G{{ _gs }}{% else %}{{ sw.G or \'–\' }}{% endif %} · {{ sw.R or \'–\' }} · {{ sw.S or \'–\' }}</b></div>\n      </div>{% if _gs == 1 %}\n      <div class="small">Kleiner Sturm, erste Polarlichter</div>{% elif _gs == 2 %}\n      <div class="small">Moderate Aktivität, Norddeutschland reagiert</div>{% elif _gs == 3 %}\n      <div class="small">Starker Sturm, Mitteldeutschland sichtbar</div>{% elif _gs == 4 %}\n      <div class="small">Schwerer Sturm, ganz Deutschland erfasst</div>{% elif _gs == 5 %}\n      <div class="small">Extremer Sturm, seltenes Ereignis</div>{% endif %}{# kpGshow #}\n    {% else %}\n      <div class="small">Keine Sonnenaktivitäts-Daten</div>\n    {% endif %}\n    <div class="small" style="margin-top:6px;color:#64748b">Quelle: NOAA SWPC</div>\n    <div class="small" style="color:{{ spaceweather.color if spaceweather is defined else \'#94a3b8\' }}">{{ spaceweather.updated if spaceweather is defined else \'\' }}</div>\n    <button id="spaceBtn" type="button" onclick="sendSpaceMesh()"\n      style="margin-top:10px;width:100%;padding:10px;border-radius:8px;border:1px solid #334155;background:#1e293b;color:#e2e8f0;font-size:0.95rem">\n      📡 Sonnenaktivität an Mesh senden\n    </button>\n    <div id="spaceStatus" class="small" style="margin-top:8px;min-height:1.2em;color:#94a3b8"></div>\n  </div>\n<script>\nasync function sendSpaceMesh() {\n  var st = document.getElementById("spaceStatus");\n  var btn = document.getElementById("spaceBtn");\n  if (btn) btn.disabled = true;\n  if (st) { st.style.color = "#94a3b8"; st.innerText = "Sende an Mesh…"; }\n  try {\n    var r = await fetch("/api/mesh_spaceweather",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"});\n    var d = await r.json();\n    if (st) {\n      if (d.ok) {\n        st.style.color = "#22c55e";\n        st.innerText = "✓ Ins Mesh gesendet · " + (d.at || d.manual || "");\n      } else {\n        st.style.color = "#ef4444";\n        st.innerText = "✗ Senden fehlgeschlagen";\n      }\n    }\n  } catch (e) {\n    if (st) { st.style.color = "#ef4444"; st.innerText = "Netzwerkfehler"; }\n  }\n  if (btn) btn.disabled = false;\n}\n</script>\n\n    ☢️ Strahlung (ODL) · Umgebung</div>\n    {% set ov = (odl.value if odl is defined else none) %}\n    {% if ov and ov.stations %}\n      <div style="margin-top:8px;font-size:0.95rem">\n      {% for s in ov.stations %}\n        <div style="display:flex;justify-content:space-between;gap:8px;padding:3px 0;border-bottom:1px solid #1e293b">\n          <span>{{ s.name }}</span>\n          <b style="color:{% if s.value is none %}#94a3b8{% elif s.value <= 0.25 %}#22c55e{% elif s.value <= 0.60 %}#eab308{% else %}#ef4444{% endif %}">{% if s.value is not none %}{{ s.value }} µSv/h{% else %}–{% endif %}</b>\n        </div>\n      {% endfor %}\n      </div>\n      {% if ov.avg is not none %}\n      <div style="margin-top:8px"><span style="color:#94a3b8">Mittel</span> · <b style="color:{% if ov.avg <= 0.25 %}#22c55e{% elif ov.avg <= 0.60 %}#eab308{% else %}#ef4444{% endif %}">{{ ov.avg }} µSv/h</b></div>\n      {% endif %}\n    {% else %}\n      <div class="small">Keine ODL-Daten</div>\n    {% endif %}\n    <div class="small" style="margin-top:6px;color:#64748b">Quelle: BfS · Ampel: ≤0,25 grün · ≤0,60 gelb · darüber rot (Orientierung)</div>\n    <div class="small" style="color:{{ odl.color if odl is defined else \'#94a3b8\' }}">{{ odl.updated if odl is defined else \'\' }}</div>\n  </div>\n  <div class="card full">\n    <button id="odlMeshBtn" type="button" onclick="sendOdlMesh()"\n      style="width:100%;padding:12px;border-radius:12px;border:1px solid #334155;background:#1e293b;color:#e2e8f0;font-size:0.95rem;cursor:pointer">\n      ☢️ ODL an Mesh senden\n    </button>\n    <div id="odlMeshStatus" class="small" style="margin-top:8px;min-height:1.3em;text-align:center;color:#94a3b8">\n      Auto bei Ampel-Wechsel · manuell per Button\n    </div>\n  </div>\n  <script>\n  async function sendOdlMesh(){\n    var st=document.getElementById("odlMeshStatus");\n    var btn=document.getElementById("odlMeshBtn");\n    if(btn) btn.disabled=true;\n    if(st){ st.style.color="#94a3b8"; st.innerText="Sende ODL an Mesh…"; }\n    try{\n      var r=await fetch("/api/mesh_odl",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"});\n      var d=await r.json();\n      if(st){\n        if(d.ok){ st.style.color="#22c55e"; st.innerText="✓ Ins Mesh gesendet · "+(d.at||""); }\n        else { st.style.color="#ef4444"; st.innerText="✗ Senden fehlgeschlagen"; }\n      }\n    }catch(e){ if(st){ st.style.color="#ef4444"; st.innerText="Netzwerkfehler"; } }\n    if(btn) btn.disabled=false;\n  }\n  </script>\n\n  </div>\n\n<!--nav-bottom-removed-->', '<style id="umw-flat-css">\n#umwGrid .card{min-width:0}\n#umwGrid .umw-sub{border-top:1px solid #334155;margin-top:10px;padding-top:8px}\n#umwGrid .umw-ft{font-size:.72rem;color:#64748b;margin-top:6px;overflow-wrap:anywhere}\n#umwGrid .umw-ft .small{font-size:inherit;margin:0}\n#umwGrid .umw-btn{width:100%;padding:9px 10px;border-radius:8px;border:1px solid #334155;background:#0f172a;color:#e2e8f0;font-size:.85rem;cursor:pointer}\n#umwGrid .umw-ml{font-size:.72rem;color:#94a3b8;margin-top:6px;overflow-wrap:anywhere}\n#umwGrid .umw-kp{display:flex;flex-wrap:wrap;gap:4px 12px;align-items:baseline}\n#umwGrid .umw-kp .big{font-size:1.2rem}\n#umwGrid .umw-gs{margin-top:2px}\n#umwGrid .umw-sub .small:empty{display:none}\n</style>\n<div class="grid" id="umwGrid">\n  <!-- dwdV3 -->\n  <div class="card full">\n    <div class="title">⚠️ DWD Warnungen</div>\n    {% set dw = dwd_warn.value if dwd_warn is defined and dwd_warn.value else {} %}\n    {% set ml = dw.get(\'max_level\', 0) if dw is mapping else 0 %}\n    <div class="big" style="color:{{ dw.get(\'color\', \'#22c55e\') if dw is mapping else \'#22c55e\' }}">Stufe {{ ml if ml is not none else 0 }}</div>\n    <div class="small" style="color:#94a3b8;margin-bottom:6px">Kalchreuth · Forst · Erlangen · ERH · Schnaittach · DWD</div>\n    {% if dw is mapping and dw.get(\'items\') %}\n      <div style="margin-top:6px;font-size:0.82rem;line-height:1.45">\n      {% for it in dw.get(\'items\') %}\n        <div style="padding:5px 0;border-bottom:1px solid #1e293b">\n          <b>{{ it.name }}</b>\n          <span style="color:{{ \'#ef4444\' if (it.level or 0) >= 4 else (\'#f97316\' if (it.level or 0) >= 3 else (\'#eab308\' if (it.level or 0) >= 2 else \'#84cc16\')) }}"> · St. {{ it.level }}</span>\n          <div>{{ it.event or it.headline or \'–\' }}</div>\n          {% if it.headline and it.event and it.headline != it.event %}<div class="small" style="color:#94a3b8">{{ it.headline }}</div>{% endif %}\n          {% if it.start or it.end %}<div class="small" style="color:#64748b">{{ it.start or \'–\' }} – {{ it.end or \'–\' }}</div>{% endif %}\n        </div>\n      {% endfor %}\n      </div>\n    {% else %}\n      <div class="small">Keine lokalen DWD-Warnungen</div>\n    {% endif %}\n    <div class="umw-ft">DWD · <span class="small" style="color:{{ dwd_warn.color if dwd_warn is defined else \'#94a3b8\' }}">{{ dwd_warn.updated if dwd_warn is defined else \'\' }}</span></div>\n    {% if dwd_mesh_status is defined and dwd_mesh_status %}\n      <div class="small" style="margin-top:4px;color:#64748b">\n        Mesh · {% if dwd_mesh_status.cleared %}Entwarnung {{ dwd_mesh_status.cleared }}{% elif dwd_mesh_status.text %}{{ dwd_mesh_status.text[:80] }}{% else %}–{% endif %}\n        {% if dwd_mesh_status.at %} · {{ dwd_mesh_status.at }}{% endif %}\n      </div>\n    {% endif %}\n  </div>\n  <div class="card full">\n    <div class="title">🌤 Wetter Kalchreuth (90562)</div>\n    <div class="big">{{ wetter.value.icon or \'\' }} {{ wetter.value.temp or \'–\' }} °C</div>\n    <div class="small">Sonne heute {{ wetter.value.sunshine if wetter.value.sunshine is not none else \'–\' }} h</div>\n    <div style="display:grid;grid-template-columns:70px 1fr auto auto;gap:4px 10px;margin-top:10px;font-size:0.82rem;align-items:center">\n      {% for d in wetter.value.days or [] %}\n        <div style="color:#94a3b8">{{ d.weekday }} {{ d.date }}</div>\n        <div><b>{{ d.max }}°</b> / {{ d.min }}°</div>\n        <div style="color:#94a3b8">{{ d.sun if d.sun is not none else \'–\' }} h</div>\n        <div>{{ d.icon }}</div>\n      {% endfor %}\n    </div>\n    <div class="umw-ft">Open-Meteo · <span class="small" style="color:{{ wetter.color }}">{{ wetter.updated }}</span></div>\n    <div class="umw-sub">\n      <button id="meshWeatherBtn" class="umw-btn" type="button" onclick="sendMeshWeather()">📡 Wetter an Mesh (Kalchreuth + Schnaittach)</button>\n      <div id="meshWeatherStatus" class="small" style="margin-top:6px;color:#94a3b8"></div>\n      <div class="umw-ml"><span id="meshAutoLine" style="color:{% if mesh_weather_status is defined and mesh_weather_status.auto %}#22c55e{% else %}#eab308{% endif %}">A · {% if mesh_weather_status is defined and mesh_weather_status.auto %}{{ mesh_weather_status.auto }}{% else %}noch keine Auto-Sendung{% endif %}</span> · <span id="meshManualLine">M · {% if mesh_weather_status is defined and mesh_weather_status.manual %}{{ mesh_weather_status.manual }}{% else %}–{% endif %}</span> · auto alle 3 h</div>\n    </div>\n  </div>\n  <div class="card full">\n    <div class="title">🔥 DWD WBI · Waldbrand</div>\n    {% set wb = dwd_wbi.value if dwd_wbi is defined and dwd_wbi.value else {} %}\n    {% if wb is mapping and wb.get(\'wbi\') is not none %}\n      <div class="big" style="color:{{ wb.get(\'color\', \'#e2e8f0\') }}">Stufe {{ wb.wbi }}</div>\n      {% if wb.get(\'stale\') %}<div class="small" style="color:#eab308">Datenstand veraltet ({{ wb.get(\'date_fmt\') or wb.get(\'date\') or \'–\' }})</div>{% endif %}\n      <div class="small" style="margin-top:4px">Station {{ wb.get(\'station_name\') or \'Nürnberg\' }} ({{ wb.get(\'station_id\') or \'3668\' }}) · {{ wb.get(\'distance_km\') or 8.2 }} km</div>\n      <div class="small" style="color:#94a3b8">Datum {{ wb.get(\'date_fmt\') or wb.get(\'date\') or \'–\' }}</div>\n    {% else %}\n      <div class="small">Keine WBI-Daten</div>\n    {% endif %}\n    <div class="umw-ft">DWD WBI · <span class="small" style="color:{{ dwd_wbi.color if dwd_wbi is defined else \'#94a3b8\' }}">{{ dwd_wbi.updated if dwd_wbi is defined else \'\' }}</span></div>\n  </div>\n  <div id="umwSdrnSlot"></div>\n  <div class="card full">\n    <div class="title">☢️ Strahlung (ODL) · Umgebung</div>\n    {% set ov = (odl.value if odl is defined else none) %}\n    {% if ov and ov.stations %}\n      <div style="margin-top:8px;font-size:0.95rem">\n      {% for s in ov.stations %}\n        <div style="display:flex;justify-content:space-between;gap:8px;padding:3px 0;border-bottom:1px solid #1e293b">\n          <span>{{ s.name }}</span>\n          <b style="color:{% if s.value is none %}#94a3b8{% elif s.value <= 0.25 %}#22c55e{% elif s.value <= 0.60 %}#eab308{% else %}#ef4444{% endif %}">{% if s.value is not none %}{{ s.value }} µSv/h{% else %}–{% endif %}</b>\n        </div>\n      {% endfor %}\n      </div>\n      {% if ov.avg is not none %}\n      <div style="margin-top:8px"><span style="color:#94a3b8">Mittel</span> · <b style="color:{% if ov.avg <= 0.25 %}#22c55e{% elif ov.avg <= 0.60 %}#eab308{% else %}#ef4444{% endif %}">{{ ov.avg }} µSv/h</b></div>\n      {% endif %}\n    {% else %}\n      <div class="small">Keine ODL-Daten</div>\n    {% endif %}\n    <div class="umw-ft">BfS · Ampel ≤0,25 / ≤0,60 µSv/h · <span class="small" style="color:{{ odl.color if odl is defined else \'#94a3b8\' }}">{{ odl.updated if odl is defined else \'\' }}</span></div>\n    <div class="umw-sub">\n      <button id="odlMeshBtn" class="umw-btn" type="button" onclick="sendOdlMesh()">☢️ ODL an Mesh senden</button>\n      <div id="odlMeshStatus" class="small" style="margin-top:6px;color:#94a3b8">Auto bei Ampel-Wechsel</div>\n    </div>\n  </div>\n  <div class="card full">\n    <div class="title">☀ Sonnenaktivität</div>\n    {% set sw = spaceweather.value if spaceweather is defined else none %}\n    {% if sw is mapping and sw.get(\'kp\') is not none %}\n      <div class="umw-kp"><span class="big" style="color:{{ sw.color or \'#e2e8f0\' }}">Kp {{ sw.kp }}</span><span style="color:{{ sw.color or \'#94a3b8\' }}">{{ sw.label or \'\' }}</span><span style="color:#94a3b8">24h-max <b style="color:#e2e8f0">{{ sw.kp_max24 if sw.kp_max24 is not none else \'–\' }}</b></span><span style="color:#94a3b8">G/R/S <b style="color:#e2e8f0">{% set _gn = 0 %}{% if (sw.G or \'\') == \'G5\' %}{% set _gn = 5 %}{% elif (sw.G or \'\') == \'G4\' %}{% set _gn = 4 %}{% elif (sw.G or \'\') == \'G3\' %}{% set _gn = 3 %}{% elif (sw.G or \'\') == \'G2\' %}{% set _gn = 2 %}{% elif (sw.G or \'\') == \'G1\' %}{% set _gn = 1 %}{% endif %}{% set _gk = 0 %}{% if sw.kp >= 9 %}{% set _gk = 5 %}{% elif sw.kp >= 8 %}{% set _gk = 4 %}{% elif sw.kp >= 7 %}{% set _gk = 3 %}{% elif sw.kp >= 6 %}{% set _gk = 2 %}{% elif sw.kp >= 5 %}{% set _gk = 1 %}{% endif %}{% set _gm = 0 %}{% if sw.kp_max24 is not none and sw.kp_max24 >= 9 %}{% set _gm = 5 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 8 %}{% set _gm = 4 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 7 %}{% set _gm = 3 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 6 %}{% set _gm = 2 %}{% elif sw.kp_max24 is not none and sw.kp_max24 >= 5 %}{% set _gm = 1 %}{% endif %}{% set _gs = _gn %}{% if _gk > _gs %}{% set _gs = _gk %}{% endif %}{% if _gm > _gs %}{% set _gs = _gm %}{% endif %}{% if _gs >= 1 %}G{{ _gs }}{% else %}{{ sw.G or \'–\' }}{% endif %} · {{ sw.R or \'–\' }} · {{ sw.S or \'–\' }}</b></span></div>{% if _gs == 1 %}\n      <div class="small umw-gs">Kleiner Sturm, erste Polarlichter</div>{% elif _gs == 2 %}\n      <div class="small umw-gs">Moderate Aktivität, Norddeutschland reagiert</div>{% elif _gs == 3 %}\n      <div class="small umw-gs">Starker Sturm, Mitteldeutschland sichtbar</div>{% elif _gs == 4 %}\n      <div class="small umw-gs">Schwerer Sturm, ganz Deutschland erfasst</div>{% elif _gs == 5 %}\n      <div class="small umw-gs">Extremer Sturm, seltenes Ereignis</div>{% endif %}{# kpGshow #}\n    {% else %}\n      <div class="small">Keine Sonnenaktivitäts-Daten</div>\n    {% endif %}\n    <div class="umw-ft">NOAA SWPC · <span class="small" style="color:{{ spaceweather.color if spaceweather is defined else \'#94a3b8\' }}">{{ spaceweather.updated if spaceweather is defined else \'\' }}</span></div>\n    <div class="umw-sub">\n      <button id="spaceBtn" class="umw-btn" type="button" onclick="sendSpaceMesh()">📡 Sonnenaktivität an Mesh senden</button>\n      <div id="spaceStatus" class="small" style="margin-top:6px;color:#94a3b8"></div>\n    </div>\n  </div>\n</div>\n<script>\nasync function sendSpaceMesh() {\n  var st = document.getElementById("spaceStatus");\n  var btn = document.getElementById("spaceBtn");\n  if (btn) btn.disabled = true;\n  if (st) { st.style.color = "#94a3b8"; st.innerText = "Sende an Mesh…"; }\n  try {\n    var r = await fetch("/api/mesh_spaceweather",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"});\n    var d = await r.json();\n    if (st) {\n      if (d.ok) {\n        st.style.color = "#22c55e";\n        st.innerText = "✓ Ins Mesh gesendet · " + (d.at || d.manual || "");\n      } else {\n        st.style.color = "#ef4444";\n        st.innerText = "✗ Senden fehlgeschlagen";\n      }\n    }\n  } catch (e) {\n    if (st) { st.style.color = "#ef4444"; st.innerText = "Netzwerkfehler"; }\n  }\n  if (btn) btn.disabled = false;\n}\n</script>\n  <script>\n  async function sendOdlMesh(){\n    var st=document.getElementById("odlMeshStatus");\n    var btn=document.getElementById("odlMeshBtn");\n    if(btn) btn.disabled=true;\n    if(st){ st.style.color="#94a3b8"; st.innerText="Sende ODL an Mesh…"; }\n    try{\n      var r=await fetch("/api/mesh_odl",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"});\n      var d=await r.json();\n      if(st){\n        if(d.ok){ st.style.color="#22c55e"; st.innerText="✓ Ins Mesh gesendet · "+(d.at||""); }\n        else { st.style.color="#ef4444"; st.innerText="✗ Senden fehlgeschlagen"; }\n      }\n    }catch(e){ if(st){ st.style.color="#ef4444"; st.innerText="Netzwerkfehler"; } }\n    if(btn) btn.disabled=false;\n  }\n  </script>\n\n<!--nav-bottom-removed-->')]
MK_C53_RAE_EOF
EXPECT_RAB="bd92ec0b1c2135f6a7abc5abfd40a04b33d6e605a9d5d98f24597c75c3fc57a8"
cat > "$W/blk.py" << 'MK_C53_RAB_EOF'
# ===== umweltFlach: /umwelt flach und kurz (commit53) - Reihenfolge DWD, Wetter, Waldbrand, Stoersender, Gewitter, ODL, Sonne; eine Rahmenebene; Umbruch statt Abschneiden; Erklaerungen hinter i; Stick-L1 nur gelb/rot; Gewitter in Ruhe 1 Zeile; Ereignisse 5 + mehr; ein Abruf je 120 s nur bei sichtbarem Tab; nur Anzeige, sendet nichts =====
import json as _uf_json

UF_POLL_MS = 120000     # ein gemeinsamer Abruf (Stoersender + Gewitter + Ereignisse), nur bei sichtbarem Tab
UF_EV_SHOW = 5          # Ereignisse sichtbar, Rest unter "mehr"
UF_STALE_F = 3          # letzte QRM-Messung aelter als 3 Messintervalle -> "Messung läuft nicht"
UF_MARK = "/* umweltFlach */"

_UF_QRM_INFO = ("Rauschboden je Band gegen Grundlinie (Median 7 Tage, MW/KW je Tagesstunde; Schwelle max(5 dB, 4×MAD) gelb, max(10 dB, 6×MAD) rot), "
                "langsamer Anstieg als ↗ Trend, neue Dauerträger. Nur Leistungsmessung, kein Inhalt.")
_UF_QRM_KURVE = "Kurve: Rauschboden (dB, relativ) des gewählten Bandes. Hinweis, keine Peilung oder Garantie: eigene Geräte (Netzteile, Pi, LED) stören oft selbst."
_UF_TH_INFO = ("Nur ein Hinweis: Blitze erzeugen kurze breitbandige Knackse (Sferics) auf Mittel-/Kurzwelle, aber auch Weidezäune, Zündanlagen und Schaltnetzteile. "
               "Braucht Direktabtastung (NESDR SMArt v5) und eine Draht-/KW-Antenne; keine Entfernungs- oder Blitzortung, keine Unwetterwarnung.")
_UF_TH_SHORT = "Grober Hinweis – keine Blitzortung, keine Unwetterwarnung."

_UF_HELP_JS = (r"""var SVG='http://www.w3.org/2000/svg';""" + UF_MARK +
               r"""function ufNow(){return (typeof D.now==='number')?D.now:Math.floor(Date.now()/1000);}
function ufAge(t){var s=Math.max(0,ufNow()-t);return s>=86400?Math.floor(s/86400)+' d':(s>=3600?Math.floor(s/3600)+' h':Math.max(1,Math.floor(s/60))+' min');}
function ufStale(){var N=D.noise||{};return !N.t||(ufNow()-N.t)>UF_F*(D.iv||900);}
function ufNo(k){if(k!=='snr'&&ufStale()){var N=D.noise||{},U=D.uf||{};return 'keine Kurve – '+(N.t?'letzte Messung vor '+ufAge(N.t):'noch keine Messung')+' (Messung läuft nicht'+(U.skip?': '+U.skip:'')+')';}return 'noch zu wenig Messwerte für eine Kurve';}
function ufLast(N){var o=ufStale();var x=el('div','small'+(o?' uf-old':''),'Messung alle '+Math.round((D.iv||900)/60)+' min'+(N.t?' · zuletzt '+dm(N.t)+(o?' (vor '+ufAge(N.t)+' – läuft nicht)':''):' · noch keine Messung'));return x;}
function ufInfo(L){var d=el('details','uf-i');d.appendChild(el('summary','','ⓘ Erklärung'));L.forEach(function(t){d.appendChild(el('div','small',t));});return d;}
var UF_F=""" + str(UF_STALE_F) + ";")

_UF_SDRN_EDITS = [
    (r"""var SVG='http://www.w3.org/2000/svg';""", _UF_HELP_JS),
    (r"""if(v.length<2){box.appendChild(el('div','small','noch zu wenig Messwerte für eine Kurve'));return;}""",
     r"""if(v.length<2){box.appendChild(el('div','small',ufNo(key)));return;}"""),
    (r"""c.appendChild(el('div','small','""" + _UF_QRM_INFO + r""" Messung alle '+Math.round((D.iv||900)/60)+' min kurz in der Automatik'+(N.t?' · zuletzt '+hm(N.t):'')+'.'));""",
     r"""c.appendChild(ufLast(N));"""),
    (r"""B.forEach(function(b){var r=el('div','sdrn-row'+(b.id===sel?' sel':''));""",
     r"""var UFG=[];B.forEach(function(b){if(b.id==='gps'&&b.lvl!=='gelb'&&b.lvl!=='rot')return;if(!b.ok){UFG.push(b);return;}var r=el('div','sdrn-row'+(b.id===sel?' sel':''));"""),
    (r"""if(!B.length&&!(D.gps||{}).src)rows.appendChild(""",
     r"""if(UFG.length)rows.appendChild(el('div','sdrn-row uf-grey','○ nicht gemessen: '+UFG.map(function(b){return b.short;}).join(', ')+' · '+(UFG[0].why||'nicht messbar')));if(!B.length&&!(D.gps||{}).src)rows.appendChild("""),
    (r"""c.appendChild(el('div','small','""" + _UF_QRM_KURVE + r"""'));""",
     r"""c.appendChild(ufInfo([""" + _uf_json.dumps(_UF_QRM_INFO, ensure_ascii=False) + "," + _uf_json.dumps(_UF_QRM_KURVE, ensure_ascii=False) + r"""]));"""),
    (r"""g.appendChild(el('div','title','⚡ Gewitter-Hinweis'));var tl=th.lvl||'grau';""",
     r"""var tl=th.lvl||'grau';var UFR=(tl!=='gelb'&&tl!=='rot');var gH=g,gs=null;if(UFR){var gd=el('details','uf-more');gd.id='sdrnThunderX';gs=el('summary','uf-sum');gs.appendChild(el('span','uf-st','⚡ Gewitter '));gd.appendChild(gs);g.appendChild(gd);g=gd;}else{g.appendChild(el('div','title','⚡ Gewitter-Hinweis'));}"""),
    (r"""b2.style.color=COL[tl]||COL.grau;g.appendChild(b2);""",
     r"""b2.style.color=COL[tl]||COL.grau;if(UFR){b2.className='uf-st2';if(typeof th.bb_pm==='number')b2.textContent+=' · '+nf(th.bb_pm)+'/min';gs.appendChild(b2);}else{g.appendChild(b2);g.appendChild(el('div','small',""" + _uf_json.dumps(_UF_TH_SHORT, ensure_ascii=False) + r"""));}"""),
    (r"""g.appendChild(el('div','small','""" + _UF_TH_INFO + r"""'));host.appendChild(g);""",
     r"""g.appendChild(ufInfo([""" + _uf_json.dumps(_UF_TH_INFO, ensure_ascii=False) + r"""]));host.appendChild(gH);"""),
    (r"""render();setInterval(function(){fetch('/api/sdr/noise').then(function(r){return r.json();}).then(function(x){D=x;render();}).catch(function(){});},120000);})();""",
     r"""render();var ufT=Date.now();function ufPoll(){if(document.hidden)return;ufT=Date.now();fetch('/api/sdr/noise?evl=1',{credentials:'same-origin',cache:'no-store'}).then(function(r){return r.json();}).then(function(x){var ev=x.evl||null;delete x.evl;D=x;render();if(window.ufEvl)window.ufEvl(ev);}).catch(function(){});}
setInterval(ufPoll,""" + str(UF_POLL_MS) + r""");document.addEventListener('visibilitychange',function(){if(!document.hidden&&Date.now()-ufT>=""" + str(UF_POLL_MS) + r""")ufPoll();});})();"""),
]

_UF_EVL_EDITS = [
    (r"""var D=null;var TZ='Europe/Berlin';""", r"""var D=null;var TZ='Europe/Berlin';var UF_N=""" + str(UF_EV_SHOW) + ";" + UF_MARK),
    (r"""L.forEach(function(e){var dv=""",
     r"""var UM=null;L.forEach(function(e,ix){if(ix===UF_N&&L.length>UF_N){UM=el('details','uf-more');UM.appendChild(el('summary','uf-sum','mehr ('+(L.length-UF_N)+')'));box.appendChild(UM);}var tgt=UM||box;var dv="""),
    (r"""box.appendChild(row(COL[e.lvl]||COL.grau,p,(e.start_iso||'')+(e.end_iso?' – '+e.end_iso:'')));});}""",
     r"""tgt.appendChild(row(COL[e.lvl]||COL.grau,p,(e.start_iso||'')+(e.end_iso?' – '+e.end_iso:'')));});}"""),
    (r"""[['sdrnQrm','evl-qrm','qrm','Ereignisse (letzte 10)'],['sdrnThunder','evl-th','th','Ereignisse (letzte 10)']].forEach(function(a){var c=document.getElementById(a[0]);""",
     r"""[['sdrnQrm','evl-qrm','qrm','Ereignisse'],['sdrnThunder','evl-th','th','Ereignisse']].forEach(function(a){var c=document.getElementById(a[0]+'X')||document.getElementById(a[0]);"""),
    (r"""place();setInterval(place,2000);setInterval(load,30000);})();""",
     r"""if(P==='/umwelt'){window.ufEvl=function(j){if(j&&j.ok)D=j;place();};place();}else{place();setInterval(place,2000);setInterval(load,30000);}})();"""),
]

_UF_CSS = """<style id="uf-css">
#umwGrid #sdrnHost{grid-column:1/-1;min-width:0}
#umwGrid #sdrnHost .sdrn-card{margin:0 0 10px;padding:12px;border:1px solid #1e293b;border-radius:12px;background:var(--card,#111827)}
#umwGrid #sdrnHost .sdrn-card:last-child{margin-bottom:0}
#umwGrid #sdrnHost .sdrn-row{white-space:normal;overflow:visible;align-items:flex-start}
#umwGrid #sdrnHost .sdrn-row .dot{margin-top:4px}
#umwGrid #sdrnHost .sdrn-row .nm{white-space:nowrap;overflow:visible;text-overflow:clip}
#umwGrid #sdrnHost .sdrn-row .tx{white-space:normal;overflow:visible;text-overflow:clip;overflow-wrap:anywhere}
#umwGrid .evl-box{border-top:1px solid #334155}
#umwGrid .evl-row{white-space:normal;overflow:visible;align-items:flex-start}
#umwGrid .evl-row .dot{margin-top:5px}
#umwGrid .evl-tx{white-space:normal;overflow:visible;text-overflow:clip;overflow-wrap:anywhere}
#umwGrid .uf-i,#umwGrid .uf-more{margin-top:6px}
#umwGrid .uf-i>summary,#umwGrid .uf-more>summary{cursor:pointer;color:#94a3b8;font-size:.75rem}
#umwGrid #sdrnThunder>.uf-more{margin-top:0}
#umwGrid #sdrnThunder>.uf-more>summary{font-size:.85rem;color:#e2e8f0}
#umwGrid .uf-st2{display:inline;font-size:inherit;font-weight:600}
#umwGrid .uf-grey{color:#94a3b8;font-size:.78rem}
#umwGrid .uf-old{color:#ef4444}
</style>"""

_UF_HOST = '<div id="sdrnHost"></div>'
_UF_SLOT = '<div id="umwSdrnSlot"></div>'


def _uf_apply(js, edits, tag):
    """Alle Stellen genau einmal, sonst Fehler (nichts halb). Schon umgebaut -> unveraendert."""
    if UF_MARK in js:
        return js
    for i, (o, n) in enumerate(edits):
        if js.count(o) != 1:
            raise ValueError("%s: Stelle %d nicht genau einmal (%d)" % (tag, i + 1, js.count(o)))
        js = js.replace(o, n, 1)
    return js


def _uf_move(body):
    """Stoersender-/Gewitter-Platz: leeren Host an die Stelle zwischen Waldbrand und ODL (nur wenn beide genau einmal da sind)."""
    if body.count(_UF_HOST) != 1 or body.count(_UF_SLOT) != 1:
        return body, False
    return body.replace(_UF_HOST, "", 1).replace(_UF_SLOT, _UF_HOST, 1), True


def _uf_after(resp):
    try:
        from flask import request as _uf_rq
        if _uf_rq.path.rstrip("/") == "/umwelt" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body, ok = _uf_move(resp.get_data(as_text=True))
            if ok:
                resp.set_data(body)
            resp.headers["X-Umwelt-Flach"] = "1" if ok else "0"
    except Exception as e:
        print("umweltFlach Seite:", e, flush=True)
    return resp


_uf_data0 = _sdrn_data if "_uf_data0" not in globals() else _uf_data0


def _sdrn_data():
    d = _uf_data0()
    try:
        nd = ((_sdr_status().get("status") or {}).get("noise_diag") or {})
        d["uf"] = {"skip": (str(nd.get("skip"))[:120] if nd.get("skip") else None), "skip_t": nd.get("skip_t")}
    except Exception:
        d["uf"] = {}
    return d


def _uf_api_wrap(fn):
    def inner(*a, **kw):
        resp = fn(*a, **kw)
        try:
            from flask import request as _uf_rq, jsonify as _uf_jsonify
            if _uf_rq.args.get("evl") == "1":
                j = resp.get_json(silent=True)
                if isinstance(j, dict):
                    j["evl"] = _evl_view()
                    return _uf_jsonify(j)
        except Exception as e:
            print("umweltFlach Abruf:", e, flush=True)
        return resp
    inner.__name__ = "sdrn_api_uf"
    inner._uf = True
    return inner


def _selftest_umweltflach():
    s = _uf_apply(_SDRN_JS, _UF_SDRN_EDITS, "Stoersender-Skript")
    e = _uf_apply(_EVL_JS, _UF_EVL_EDITS, "Ereignis-Skript")
    assert s.count(UF_MARK) == 1 and e.count(UF_MARK) == 1, "Marke fehlt"
    assert "setInterval(place,2000)" in e and "if(P==='/umwelt'){window.ufEvl=" in e, "Ereignis-Takt /funk433 oder /umwelt falsch"
    assert s.count("setInterval(") == 1 and "if(document.hidden)return;" in s and "/api/sdr/noise?evl=1" in s, "Abruf nicht einmal/sichtbar"
    assert "white-space:normal" in _UF_CSS and "text-overflow:ellipsis" not in _UF_CSS
    p3 = globals().get("PAGE3") or ""
    assert p3.count(_UF_SLOT) == 1 and p3.count('<div class="grid" id="umwGrid">') == 1, "lage_pages.py ohne umweltFlach-Vorlage (Platz/Raster fehlt)"
    assert 'class="card full" style="padding:10px;text-align:center"' not in p3 and "Strahlung (ODL) · Umgebung</div>" in p3
    b, ok = _uf_move("<body>" + _UF_SLOT + "<p>x</p>" + _UF_HOST + "</body>")
    assert ok and b == "<body>" + _UF_HOST + "<p>x</p></body>", b
    b2, ok2 = _uf_move("<body>" + _UF_HOST + "</body>")
    assert not ok2 and b2 == "<body>" + _UF_HOST + "</body>"
    return s, e, "umweltFlach ok (Stoersender-Skript %d Stellen, Ereignis-Skript %d Stellen, Platz zwischen Waldbrand und ODL, Abruf %d s nur sichtbar, Ereignisse %d + mehr)" % (
        len(_UF_SDRN_EDITS), len(_UF_EVL_EDITS), UF_POLL_MS // 1000, UF_EV_SHOW)


_uf_old = (_SDRN_JS, _EVL_JS, _SDRN_CSS)
_uf_vf = app.view_functions.get("sdrn_api")
try:
    _uf_s, _uf_e, _UF_ST = _selftest_umweltflach()
    if _uf_vf is None:
        raise ValueError("sdrn_api fehlt")
    _SDRN_JS, _EVL_JS = _uf_s, _uf_e
    if _UF_CSS not in _SDRN_CSS:
        _SDRN_CSS = _SDRN_CSS + _UF_CSS
    if not getattr(_uf_vf, "_uf", False):
        app.view_functions["sdrn_api"] = _uf_api_wrap(_uf_vf)
    if not any(getattr(f, "__name__", "") == "_uf_after" for f in app.after_request_funcs.get(None, [])):
        app.after_request(_uf_after)
    print("umweltFlach aktiv: %s" % _UF_ST, flush=True)
except Exception as _uf_ex:
    _SDRN_JS, _EVL_JS, _SDRN_CSS = _uf_old
    _sdrn_data = _uf_data0
    if _uf_vf is not None:
        app.view_functions["sdrn_api"] = _uf_vf
    print("umweltFlach Selbsttest FEHLER (%s: %s)" % (type(_uf_ex).__name__, _uf_ex), flush=True)
# ===== /umweltFlach =====
MK_C53_RAB_EOF
EXPECT_RAG="cb78c277df81fb1b792f30b295acfde14d6569a0de54e6b244575af7340e7977"
cat > "$W/guard.py" << 'MK_C53_RAG_EOF'
"""Guard umweltFlach (commit53). dashboard.py: genau ein Block vor __main__ (keine geaenderte Zeile); lage_pages.py: nur der Kachelbereich von page3 (/umwelt) ersetzt.
  guard.py revert NEU_VERZ ALT_VERZ BLOCK EDITS   -> ALT_VERZ/{dashboard,lage_pages}.py = NEU ohne umweltFlach (byte-genau)
  guard.py check  ALT_VERZ NEU_VERZ BLOCK EDITS   -> Rueckbau = ALT, statische Regeln, Vorlage (Jinja, flach, Reihenfolge, Knoepfe), Block mit Flask,
                                                     Seiten-Skripte mit node und DOM-Attrappe (falls node da; sonst statisch - Mutationen werden trotzdem erkannt)
  guard.py mutate ALT_VERZ NEU_VERZ BLOCK EDITS   -> Mutationstest (jede Mutation muss check scheitern lassen)
Braucht flask/jinja2 im ausfuehrenden Python (venv). GUARD_NO_NODE=1 schaltet den node-Test ab."""
import ast, contextlib, hashlib, io, json, os, re, shutil, subprocess, sys, tempfile
from html.parser import HTMLParser

ANCH = '\n\nif __name__ == "__main__":\n'
M0, M1 = "# ===== umweltFlach:", "# ===== /umweltFlach ====="
OK_IMPORTS = {"json", "flask"}
FORBID = {"send_meshtastic", "send_dab_to_private_mesh", "send_nina_to_bayern", "_t4_send_m1", "_lz_mesh", "_lz_mgr", "requests", "urllib", "socket", "subprocess", "os", "open",
          "system", "popen", "Popen", "eval", "exec", "__import__", "Thread", "route", "add_url_rule", "before_request", "sqlite3", "write_json", "_sdr_save"}
CONSTS = {"UF_POLL_MS": 120000, "UF_EV_SHOW": 5, "UF_STALE_F": 3}
JS_BAD = ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "localStorage", "sessionStorage", "eval(", "Function(", "XMLHttpRequest", "/api/mesh", "method:",
          "http://", "https://", "sendBeacon", "location.reload"]
JS_NEED_S = ["if(v.length<2){box.appendChild(el('div','small',ufNo(key)));return;}", "c.appendChild(ufLast(N));", "if(b.id==='gps'&&b.lvl!=='gelb'&&b.lvl!=='rot')return;if(!b.ok){UFG.push(b);return;}",
             "if(UFG.length)rows.appendChild(el('div','sdrn-row uf-grey',", "'○ nicht gemessen: '+UFG.map(function(b){return b.short;}).join(', ')+' · '+(UFG[0].why||'nicht messbar')", "var UFR=(tl!=='gelb'&&tl!=='rot');", "gd.id='sdrnThunderX';",
             "host.appendChild(gH);", "if(document.hidden)return;", "fetch('/api/sdr/noise?evl=1',{credentials:'same-origin',cache:'no-store'})", "setInterval(ufPoll,120000);",
             "if(!document.hidden&&Date.now()-ufT>=120000)ufPoll();", "if(window.ufEvl)window.ufEvl(ev);", "return !N.t||(ufNow()-N.t)>UF_F*(D.iv||900);", "var UF_F=3;",
             "(o?' (vor '+ufAge(N.t)+' – läuft nicht)':'')", "'small'+(o?' uf-old':'')", "(U.skip?': '+U.skip:'')", "return 'noch zu wenig Messwerte für eine Kurve';}",
             "if(k!=='snr'&&ufStale())", "else{g.appendChild(b2);g.appendChild(el('div','small',\"Grober Hinweis – keine Blitzortung, keine Unwetterwarnung.\"));}",
             "if(typeof th.bb_pm==='number')b2.textContent+=' · '+nf(th.bb_pm)+'/min';gs.appendChild(b2);", "s>=86400?Math.floor(s/86400)+' d':(s>=3600?Math.floor(s/3600)+' h':Math.max(1,Math.floor(s/60))+' min')"]
JS_NEED_E = ["var UF_N=5;", "if(ix===UF_N&&L.length>UF_N){UM=el('details','uf-more');UM.appendChild(el('summary','uf-sum','mehr ('+(L.length-UF_N)+')'));box.appendChild(UM);}var tgt=UM||box;",
             "tgt.appendChild(row(", "var c=document.getElementById(a[0]+'X')||document.getElementById(a[0]);",
             "if(P==='/umwelt'){window.ufEvl=function(j){if(j&&j.ok)D=j;place();};place();}else{place();setInterval(place,2000);setInterval(load,30000);}})();"]
SAFE = ["Nur ein Hinweis: Blitze erzeugen kurze breitbandige Knackse (Sferics) auf Mittel-/Kurzwelle, aber auch Weidezäune, Zündanlagen und Schaltnetzteile. Braucht Direktabtastung (NESDR SMArt v5) und eine Draht-/KW-Antenne; keine Entfernungs- oder Blitzortung, keine Unwetterwarnung.",
        "Kurve: Rauschboden (dB, relativ) des gewählten Bandes. Hinweis, keine Peilung oder Garantie: eigene Geräte (Netzteile, Pi, LED) stören oft selbst."]
CSS_NEED = ["#umwGrid #sdrnHost .sdrn-row .tx{white-space:normal;overflow:visible;text-overflow:clip;overflow-wrap:anywhere}", "#umwGrid .evl-tx{white-space:normal;overflow:visible;text-overflow:clip;overflow-wrap:anywhere}",
            "#umwGrid .evl-row{white-space:normal;overflow:visible;align-items:flex-start}", "#umwGrid #sdrnHost .sdrn-row{white-space:normal;overflow:visible;align-items:flex-start}",
            "#umwGrid #sdrnHost .sdrn-card{margin:0 0 10px;padding:12px;border:1px solid #1e293b;border-radius:12px;background:var(--card,#111827)}"]
FIX_SDRN = '<script id="sdrn-js">\n(function(){var D;try{D=JSON.parse(document.getElementById(\'sdrnData\').textContent);}catch(e){return;}\nvar COL={gruen:\'#22c55e\',gelb:\'#eab308\',rot:\'#ef4444\',grau:\'#64748b\',trend:\'#f97316\'};var TXT={gruen:\'ruhig\',gelb:\'erhöht\',rot:\'stark\',grau:\'keine Messung\'};\nfunction el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined&&x!==null)e.textContent=x;return e;}\nfunction d2(x){return x<10?\'0\'+x:\'\'+x;}function hm(t){var d=new Date(t*1000);return d2(d.getHours())+\':\'+d2(d.getMinutes());}\nfunction dm(t){var d=new Date(t*1000);return d2(d.getDate())+\'.\'+d2(d.getMonth()+1)+\'. \'+hm(t);}\nfunction nf(v,k){return (v===null||v===undefined)?\'–\':(k&&v>0?\'+\':\'\')+String(Math.round(v*10)/10).replace(\'.\',\',\');}\nfunction mhz(v){return String(v).replace(\'.\',\',\');}\nvar SVG=\'http://www.w3.org/2000/svg\';\nfunction chart(box,pts,key,col,base){box.textContent=\'\';var W=320,H=90;var s=document.createElementNS(SVG,\'svg\');s.setAttribute(\'viewBox\',\'0 0 \'+W+\' \'+H);s.style.width=\'100%\';s.style.height=\'90px\';\nvar v=pts.filter(function(p){return typeof p[key]===\'number\';});if(v.length<2){box.appendChild(el(\'div\',\'small\',\'noch zu wenig Messwerte für eine Kurve\'));return;}\nvar x0=v[0].ts,x1=v[v.length-1].ts,ys=v.map(function(p){return p[key];});if(typeof base===\'number\')ys.push(base);var lo=Math.min.apply(null,ys),hi=Math.max.apply(null,ys);if(hi-lo<1){hi+=0.5;lo-=0.5;}\nfunction X(t){return 4+(W-8)*(t-x0)/Math.max(1,x1-x0);}function Y(y){return H-12-(H-22)*(y-lo)/(hi-lo);}\nif(typeof base===\'number\'){var b=document.createElementNS(SVG,\'line\');b.setAttribute(\'x1\',4);b.setAttribute(\'x2\',W-4);b.setAttribute(\'y1\',Y(base));b.setAttribute(\'y2\',Y(base));b.setAttribute(\'stroke\',\'#64748b\');b.setAttribute(\'stroke-dasharray\',\'4 3\');s.appendChild(b);}\nvar d=\'\';v.forEach(function(p,i){d+=(i?\'L\':\'M\')+X(p.ts).toFixed(1)+\' \'+Y(p[key]).toFixed(1);});var pa=document.createElementNS(SVG,\'path\');pa.setAttribute(\'d\',d);pa.setAttribute(\'fill\',\'none\');pa.setAttribute(\'stroke\',col);pa.setAttribute(\'stroke-width\',\'2\');s.appendChild(pa);\n[[lo,H-2],[hi,10]].forEach(function(q){var t=document.createElementNS(SVG,\'text\');t.setAttribute(\'x\',W-4);t.setAttribute(\'y\',q[1]);t.setAttribute(\'fill\',\'#64748b\');t.setAttribute(\'font-size\',\'9\');t.setAttribute(\'text-anchor\',\'end\');t.textContent=nf(q[0]);s.appendChild(t);});\nvar t0=document.createElementNS(SVG,\'text\');t0.setAttribute(\'x\',4);t0.setAttribute(\'y\',H-2);t0.setAttribute(\'fill\',\'#64748b\');t0.setAttribute(\'font-size\',\'9\');t0.textContent=dm(x0);s.appendChild(t0);box.appendChild(s);}\nfunction toggle(card,cb){var w=el(\'div\');w.style.margin=\'4px 0\';var on=\'d\';[[\'d\',\'24 h\'],[\'w\',\'14 Tage\']].forEach(function(o){var b=el(\'button\',\'sdrn-btn\'+(o[0]===on?\' on\':\'\'),o[1]);b.type=\'button\';b.onclick=function(){on=o[0];[].forEach.call(w.children,function(x){x.className=\'sdrn-btn\';});b.className=\'sdrn-btn on\';cb(on);};w.appendChild(b);});card.appendChild(w);return function(){return on;};}\nfunction render(){var N=D.noise||{},H=D.hist||{},B=N.bands||[];var host=document.getElementById(\'sdrnHost\');if(!host)return;host.textContent=\'\';\n/* Stoersender / QRM */\nvar c=el(\'div\',\'sdrn-card card\');c.id=\'sdrnQrm\';c.appendChild(el(\'div\',\'title\',\'📡 Störsender / QRM\'));var q=(N.qrm||{}).lvl||\'grau\';var G0=D.gps||{};var RK={grau:0,gruen:1,gelb:2,rot:3};if(G0.lvl&&RK[G0.lvl]>RK[q])q=G0.lvl;\nvar TB=B.filter(function(b){return b.ok&&b.trend&&b.trend.on&&b.lvl===\'gruen\';});var big=el(\'div\',\'sdrn-big\',\'● \'+({gruen:\'grün – ruhig\',gelb:\'gelb – erhöht\',rot:\'rot – stark gestört\',grau:\'noch keine Messung\'}[q]||q)+(q===\'gruen\'&&TB.length?\' · ↗ Trend steigend: \'+TB.map(function(b){return b.short;}).join(\', \'):\'\'));big.style.color=(q===\'gruen\'&&TB.length)?COL.trend:(COL[q]||COL.grau);c.appendChild(big);\nc.appendChild(el(\'div\',\'small\',\'Rauschboden je Band gegen Grundlinie (Median 7 Tage, MW/KW je Tagesstunde; Schwelle max(5 dB, 4×MAD) gelb, max(10 dB, 6×MAD) rot), langsamer Anstieg als ↗ Trend, neue Dauerträger. Nur Leistungsmessung, kein Inhalt. Messung alle \'+Math.round((D.iv||900)/60)+\' min kurz in der Automatik\'+(N.t?\' · zuletzt \'+hm(N.t):\'\')+\'.\'));\nvar sel=(G0.lvl===\'rot\'||G0.lvl===\'gelb\')?\'dachgps\':((B.filter(function(b){return b.lvl===\'rot\'||b.lvl===\'gelb\';})[0]||{}).id||(G0.src&&G0.ok?\'dachgps\':(B[0]||{}).id));var box=el(\'div\');\nvar rows=el(\'div\');rows.style.margin=\'6px 0\';\nfunction drawQ(){if(sel===\'dachgps\'||sel===\'dachglo\'){var k0=sel===\'dachgps\'?\'G\':\'R\',S0=((G0.sys||{})[k0])||{};chart(box,(((D.ghist_s||{})[k0]||{})[gq()])||[],\'snr\',k0===\'G\'?\'#93c5fd\':\'#c4b5fd\',S0.b_snr);return;}if(sel===\'dachgps\'){chart(box,((D.ghist||{})[gq()])||[],\'snr\',COL[G0.lvl]||\'#93c5fd\',G0.b_snr);return;}var hh=(H[sel]||{})[gq()]||[];var bb=B.filter(function(b){return b.id===sel;})[0]||{};chart(box,hh,\'floor\',COL[bb.lvl]||\'#93c5fd\',bb.base);}\nB.forEach(function(b){var r=el(\'div\',\'sdrn-row\'+(b.id===sel?\' sel\':\'\'));var dot=el(\'span\',\'dot\');dot.style.background=COL[b.lvl]||COL.grau;r.appendChild(dot);r.appendChild(el(\'span\',\'nm\',b.short));\nvar tr=b.trend||{};var isT=!!(b.ok&&tr.on&&b.lvl===\'gruen\');if(isT){dot.style.background=COL.trend;dot.className=\'dot tr\';}\nvar t;if(!b.ok){t=b.why||\'nicht messbar\';}else{t=nf(b.floor)+\' dB\'+(typeof b.raise===\'number\'?\' · \'+nf(b.raise,1)+\' dB\':\' · Grundlinie lernt\');if(b.lvl===\'gelb\'||b.lvl===\'rot\')t+=\' · Schwelle +\'+nf(b.yel)+\'/+\'+nf(b.red)+\' dB (\'+(b.src||\'\')+\')\';if(isT)t+=\' · ↗ Trend steigend \'+nf(tr.e,1)+\' dB\'+(tr.since?\' seit \'+dm(tr.since):\'\');if(b.learning)t+=\' · lernt\';else if(b.n_pers)t+=\' · \'+b.n_pers+\' neue Träger\';}\nif(b.id===\'gps\')t=\'Stick-L1 (Nebenwert) · \'+t;r.appendChild(el(\'span\',\'tx\',t));r.title=b.label;\nr.onclick=function(){sel=b.id;[].forEach.call(rows.children,function(x){x.classList.remove(\'sel\');});r.classList.add(\'sel\');drawQ();};rows.appendChild(r);(b.ok&&!b.learning?(b.cars||[]):[]).forEach(function(x){var cr=el(\'div\',\'sdrn-row sdrn-car\');cr.appendChild(el(\'span\',\'dot\'));cr.appendChild(el(\'span\',\'nm\',\'\'));cr.appendChild(el(\'span\',\'tx\',\'↳ \'+mhz(x.f)+\' MHz +\'+nf(x.db)+\' dB seit \'+dm(x.since)));rows.appendChild(cr);});});\nvar G=D.gps||{};if(G.src){var SY=G.sys||{};function fx(m){return m>=3?\'3D\':(m===2?\'2D\':\'kein Fix\');}\nfunction grow(id,nm,col,blink,txt,tip){var x=el(\'div\',\'sdrn-row\'+(sel===id?\' sel\':\'\'));var dd=el(\'span\',\'dot\'+(blink?\' blink\':\'\'));dd.style.background=col;x.appendChild(dd);x.appendChild(el(\'span\',\'nm\',nm));x.appendChild(el(\'span\',\'tx\',txt));x.title=tip;\nx.onclick=function(){sel=id;[].forEach.call(rows.children,function(y){y.classList.remove(\'sel\');});x.classList.add(\'sel\');drawQ();};return x;}\nvar bad=(G.lvl===\'gelb\'||G.lvl===\'rot\');\nfunction srow(k,nm){var P=SY[k]||null,E=G[k]||null,head=(k===\'G\'?\'GPS\':\'GLONASS\');\nif(G.ok===false){return [COL.grau,false,(k===\'G\'?\'Dach-GPS nicht erreichbar\'+(G.since?\' seit \'+dm(G.since):\'\')+(typeof G.snr===\'number\'?\' · zuletzt \'+nf(G.snr)+\' dB-Hz, \'+G.used+\'/\'+G.seen+\' Sat (\'+dm(G.last_t)+\')\':\'\'):head+\': –\')];}\nif(!G.ok){return [COL.grau,false,head+\': \'+(G.why||\'noch keine Abfrage\')];}\nif(!P||P.state===\'keine Daten\'||(!P.now_n&&P.state!==\'bewertet\')){return [COL.grau,false,head+\': keine Satelliten/Daten\'+(P&&P.samples?\' (jetzt keine, \'+P.samples+\' Proben gespeichert)\':\'\')];}\nvar cur=head+\' \'+nf(P.now_ss)+\' dB-Hz · \'+P.now_n+\' Sat\'+(k===\'G\'?\' · \'+fx(G.mode)+(typeof G.hdop===\'number\'?\' · HDOP \'+nf(G.hdop):\'\'):\'\');\nif(P.state===\'lernt\'){return [COL.grau,true,cur+\' · lernt · \'+P.ref+\' Proben / ~\'+nf(P.eta_h)+\' h\'];}\nvar t=cur+(E&&typeof E.drop===\'number\'?\' · \'+nf(-E.drop,1)+\' dB\':\'\');\nvar hit=(k===\'G\')?bad&&G.cls!==\'GLONASS\':bad&&(G.cls===\'breitbandig\'||G.cls===\'GLONASS\');\nif(hit&&E&&typeof E.yel===\'number\')t+=\' · Schwelle -\'+nf(E.yel)+\'/-\'+nf(E.red)+\' dB\';\nif(k===\'G\'&&G.why&&G.why!==\'normal\')t+=\' · \'+G.why;if(k===\'R\'&&hit&&G.cls)t+=\' · \'+G.cls;\nreturn [hit?(COL[G.lvl]||COL.grau):COL.gruen,false,t];}\nvar tip=\'gpsd \'+(G.host||\'\')+\' (Dachantenne): Signalstärke je System und Höhenband (10–30°, 30–60°, >60°) gegen 7-Tage-Grundlinie; Dach gesamt \'+nf(G.snr)+\' dB-Hz, \'+(G.used||0)+\'/\'+(G.seen||0)+\' Sat. Grau blinkend = lernt noch (Bewertung ab 36 Proben über 12 h). Beide Systeme schwächer = breitbandig, nur GPS = L1-schmalbandig.\';\nvar a1=srow(\'G\'),a2=srow(\'R\');\nrows.insertBefore(grow(\'dachglo\',\'GLO\',a2[0],a2[1],a2[2],tip),rows.firstChild);rows.insertBefore(grow(\'dachgps\',\'GPS\',a1[0],a1[1],a1[2],tip),rows.firstChild);}\nif(!B.length&&!(D.gps||{}).src)rows.appendChild(el(\'div\',\'small\',\'noch keine Messung (erste Messung kurz nach dem Start der Automatik)\'));c.appendChild(rows);var gq=toggle(c,drawQ);c.appendChild(box);drawQ();\nc.appendChild(el(\'div\',\'small\',\'Kurve: Rauschboden (dB, relativ) des gewählten Bandes. Hinweis, keine Peilung oder Garantie: eigene Geräte (Netzteile, Pi, LED) stören oft selbst.\'));host.appendChild(c);\n/* Gewitter */\nvar th=N.thunder||{};var g=el(\'div\',\'sdrn-card card\');g.id=\'sdrnThunder\';g.appendChild(el(\'div\',\'title\',\'⚡ Gewitter-Hinweis\'));var tl=th.lvl||\'grau\';\nvar b2=el(\'div\',\'sdrn-big\',\'● \'+({gruen:\'grün – ruhig\',gelb:\'gelb – mehr Impulse als üblich\',rot:\'rot – stark impulsiv, steigend\',grau:\'nicht messbar\'}[tl]||tl));b2.style.color=COL[tl]||COL.grau;g.appendChild(b2);\ng.appendChild(el(\'div\',\'small\',(typeof th.bb_pm===\'number\'?\'Breitbandige Impulse \'+nf(th.bb_pm)+\'/min\'+(typeof th.base===\'number\'?\' (üblich \'+nf(th.base)+\'/min, \'+(th.src||\'\')+\')\':\'\')+((tl===\'gelb\'||tl===\'rot\')&&typeof th.yel===\'number\'?\' · Schwelle \'+nf(th.yel)+\'/\'+nf(th.red)+\' pro min\':\'\')+\' auf \'+(th.band===\'hf10\'?\'KW 10 MHz\':\'MW\')+\' · \':\'\')+(th.why||\'\')+\'.\'));\nvar box2=el(\'div\');function drawT(){chart(box2,(H.impulse||{})[gt()]||[],\'bb_pm\',COL[tl]||\'#93c5fd\',null);}var gt=toggle(g,drawT);g.appendChild(box2);drawT();\ng.appendChild(el(\'div\',\'small\',\'Nur ein Hinweis: Blitze erzeugen kurze breitbandige Knackse (Sferics) auf Mittel-/Kurzwelle, aber auch Weidezäune, Zündanlagen und Schaltnetzteile. Braucht Direktabtastung (NESDR SMArt v5) und eine Draht-/KW-Antenne; keine Entfernungs- oder Blitzortung, keine Unwetterwarnung.\'));host.appendChild(g);}\nrender();setInterval(function(){fetch(\'/api/sdr/noise\').then(function(r){return r.json();}).then(function(x){D=x;render();}).catch(function(){});},120000);})();\n</script>'
FIX_EVL = "\n(function(){var P=location.pathname.replace(/\\/$/,'');var D=null;var TZ='Europe/Berlin';\nvar COL={gruen:'#22c55e',gelb:'#eab308',rot:'#ef4444',grau:'#64748b',trend:'#a78bfa'};\nfunction el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}\nfunction pp(t){var o={};try{new Intl.DateTimeFormat('de-DE',{timeZone:TZ,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).formatToParts(new Date(t*1000)).forEach(function(p){o[p.type]=p.value;});}catch(e){var d=new Date(t*1000);o={day:('0'+d.getDate()).slice(-2),month:('0'+(d.getMonth()+1)).slice(-2),year:d.getFullYear(),hour:('0'+d.getHours()).slice(-2),minute:('0'+d.getMinutes()).slice(-2),second:('0'+d.getSeconds()).slice(-2)};}return o;}\nfunction fd(t){var o=pp(t);return o.day+'.'+o.month+'.'+o.year+' '+o.hour+':'+o.minute+':'+o.second;}\nfunction fh(t){var o=pp(t);return o.hour+':'+o.minute+':'+o.second;}\nfunction sameDay(a,b){var x=pp(a),y=pp(b);return x.day===y.day&&x.month===y.month&&x.year===y.year;}\nfunction dur(s){s=Math.max(0,Math.round(s));var h=Math.floor(s/3600),m=Math.floor(s%3600/60);return h?h+'h '+('0'+m).slice(-2)+'m':(m?m+'m '+('0'+s%60).slice(-2)+'s':s+'s');}\nfunction nf(x,d){return (typeof x==='number')?x.toFixed(d===undefined?1:d).replace('.',','):'–';}\nfunction bdg(q,ung){q=q||{};var ok=q.sync&&typeof q.s==='number'&&!ung;var b=el('span','evl-b'+(ok?'':' bad'),ok?'S'+q.s:'ungenau');\nb.title=q.na?('Zeit: chronyc '+q.na):('Zeit: Stratum '+q.s+' · Referenz '+(q.ref||'?')+' · Offset '+nf((q.off||0)*1000,3)+' ms · geschätzter Fehler '+nf((q.err||0)*1000,3)+' ms · '+(q.sync?'synchron':'nicht synchron')+(q.alt?' · letzter Wert vor '+q.alt+' s':''));return b;}\nfunction row(col,parts,tip){var r=el('div','evl-row');var d=el('span','dot');d.style.background=col;r.appendChild(d);var t=el('span','evl-tx');parts.forEach(function(p){if(typeof p==='string')t.appendChild(document.createTextNode(p));else if(p)t.appendChild(p);});r.appendChild(t);r.title=tip||t.textContent;return r;}\nfunction evRows(box,L,title){box.textContent='';box.appendChild(el('div','evl-h',title));if(!L||!L.length){box.appendChild(el('div','evl-sub','noch keine Ereignisse (alles grün seit Beginn der Aufzeichnung)'));return;}\nL.forEach(function(e){var dv=(typeof e.delta==='number')?' · max '+(e.delta>=0?'+':'')+nf(e.delta)+' dB':'';var inf=e.info?' · '+e.info:'';var now=D.now||Math.floor(Date.now()/1000);\nvar ung=e.ungenau||!((e.start_tq||{}).sync);var p;\nif(e.on){p=[fd(e.start),' ',bdg(e.start_tq,ung),' · läuft seit '+dur(now-e.start)+' · '+e.band+' · '+e.kind+dv+inf];}\nelse{var en=e.end||e.start;p=[fd(e.start)+'–'+(sameDay(e.start,en)?fh(en):fd(en)),' ',bdg(e.end_tq||e.start_tq,ung),' · Dauer '+dur(en-e.start)+' · '+e.band+' · '+e.kind+dv+inf+(e.merged?' · '+(e.merged+1)+' Teile':'')+(e.note?' · '+e.note:'')];}\nbox.appendChild(row(COL[e.lvl]||COL.grau,p,(e.start_iso||'')+(e.end_iso?' – '+e.end_iso:'')));});}\nfunction toggle(r,on,btn){btn.disabled=true;fetch('/api/kfz/own',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-Evl':'1'},body:JSON.stringify({model:r.model,id:String(r.id),on:on})})\n.then(function(x){return x.json();}).then(function(j){if(!j.ok)alert('eigen: '+(j.error||j.txt||'Fehler'));load();}).catch(function(){btn.disabled=false;});}\nfunction kfzRows(box){box.textContent='';var T=D.kfz_today||{};box.appendChild(el('div','title','🚗 KFZ-Sensoren (TPMS) · letzte 10 · heute '+(T.n||0)+' Sichtungen / '+(T.sensoren||0)+' Sensoren · eigene '+(D.own_n||0)));\nvar L=D.kfz||[];if(!L.length){box.appendChild(el('div','sub','Noch keine KFZ-Sensoren empfangen (rtl_433 im Wechsel mit APRS).'));}\nL.forEach(function(r){var p=[fd(r.t),' ',bdg(r.tq,r.ungenau),' · '+r.model+(r.type?' ('+r.type+')':'')];\nif(typeof r.p_bar==='number')p.push(' · '+nf(r.p_bar,2)+' bar');if(typeof r.temp_C==='number')p.push(' · '+nf(r.temp_C)+' °C');if(typeof r.rssi==='number')p.push(' · RSSI '+nf(r.rssi)+' dB');\np.push(r.id!==null&&r.id!==undefined?' · ID '+r.id:' · ID entfernt (30 Tage)');if(r.own)p.push(el('span','evl-own','eigen'));if(r.n>1)p.push(' · wiedergesehen '+r.n+'x');\nvar rw=row(r.own?'#22c55e':'#93c5fd',p,r.t_iso);if(r.id!==null&&r.id!==undefined){var b=el('button','evl-btn',r.own?'eigen entfernen':'als eigen markieren');b.onclick=function(){toggle(r,!r.own,b);};rw.appendChild(b);}box.appendChild(rw);});\nbox.appendChild(el('div','sub','Volle IDs 30 Tage, danach nur Modell + Zeit; eigene (kfz_own.json) dauerhaft. Zeit dd.mm.yyyy HH:MM:SS Europe/Berlin, S1/S2 = Stratum laut chrony, ungenau = nicht synchron.'));}\nfunction place(){if(!D)return;if(P==='/umwelt'){[['sdrnQrm','evl-qrm','qrm','Ereignisse (letzte 10)'],['sdrnThunder','evl-th','th','Ereignisse (letzte 10)']].forEach(function(a){var c=document.getElementById(a[0]);if(!c)return;var b=document.getElementById(a[1]);\nif(!b||b.parentElement!==c||c.lastElementChild!==b||b.dataset.v!==String(D.now)){if(!b){b=el('div','evl-box');b.id=a[1];}evRows(b,D[a[2]],a[3]);b.dataset.v=String(D.now);c.appendChild(b);}});}\nelse if(P==='/funk433'){var m=document.getElementById('sdrMain');if(!m)return;var k=document.getElementById('evl-kfz');if(!k||k.parentElement!==m||k.dataset.v!==String(D.now)){if(!k){k=el('div','card');k.id='evl-kfz';}kfzRows(k);k.dataset.v=String(D.now);m.appendChild(k);}}}\nfunction load(){fetch('/api/sdr/evlog',{credentials:'same-origin'}).then(function(r){return r.json();}).then(function(j){if(j&&j.ok){D=j;place();}}).catch(function(){});}\ntry{D=JSON.parse(document.getElementById('evl-data').textContent);}catch(e){}\nplace();setInterval(place,2000);setInterval(load,30000);})();\n"
FIX_SHA = {"sdrn": "2d27523235d29cb3", "evl": "c82cb33ac9a8cc62"}
TITLES = ["⚠️ DWD Warnungen", "🌤 Wetter Kalchreuth (90562)", "🔥 DWD WBI · Waldbrand", "@@SLOT@@", "☢️ Strahlung (ODL) · Umgebung", "☀ Sonnenaktivität"]
BTN = {"meshWeatherBtn": ("🌤 Wetter Kalchreuth (90562)", "sendMeshWeather()"), "odlMeshBtn": ("☢️ Strahlung (ODL) · Umgebung", "sendOdlMesh()"), "spaceBtn": ("☀ Sonnenaktivität", "sendSpaceMesh()")}
IDS = ["meshWeatherBtn", "meshWeatherStatus", "meshAutoLine", "meshManualLine", "odlMeshBtn", "odlMeshStatus", "spaceBtn", "spaceStatus", "umwSdrnSlot", "umwGrid"]


def rd(p):
    return open(p, encoding="utf-8").read()


def blk_text(bp):
    return rd(bp).rstrip("\n") + "\n"


def edits(ep):
    g = {}
    exec(compile(rd(ep), "edits", "exec"), g)
    return g


def fail(m):
    print("VERSTOSS:", m)
    sys.exit(1)


def revert_d(neu, bp):
    B = blk_text(bp)
    assert neu.count(M0) == 1 and neu.count(M1) == 1, "Marker nicht genau einmal"
    assert neu.count("\n\n" + B.rstrip("\n") + ANCH) == 1, "Block nicht genau einmal unmittelbar vor __main__"
    return neu.replace("\n\n" + B.rstrip("\n") + ANCH, ANCH, 1)


def revert_l(neu, ep):
    E = edits(ep)["LP_EDITS"]
    assert len(E) == 1, "lage_pages.py: genau eine Stelle erwartet"
    o, n = E[0]
    assert neu.count(n) == 1 and neu.count(o) == 0, "lage_pages.py: neuer Bereich nicht genau einmal"
    return neu.replace(n, o, 1)


def consts(t):
    out = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name):
            try:
                out[n.targets[0].id] = ast.literal_eval(n.value)
            except Exception:
                pass
    return out


def static(B):
    t = ast.parse(B)
    for node in ast.walk(t):
        if isinstance(node, ast.Name) and node.id in FORBID:
            fail("verbotener Name %s" % node.id)
        if isinstance(node, ast.Attribute) and node.attr in FORBID:
            fail("verbotenes Attribut .%s" % node.attr)
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for m in ([a.name for a in node.names] if isinstance(node, ast.Import) else [node.module]):
                if m not in OK_IMPORTS:
                    fail("Import %s" % m)
        if isinstance(node, ast.Global):
            fail("global-Anweisung")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print":
            a0 = node.args[0] if node.args else None
            s = a0.left.value if isinstance(a0, ast.BinOp) and isinstance(a0.left, ast.Constant) else (a0.value if isinstance(a0, ast.Constant) else "")
            if not str(s).startswith("umweltFlach"):
                fail("print ohne Praefix umweltFlach: %r" % str(s)[:40])
    C = consts(t)
    for k, v in CONSTS.items():
        if C.get(k) != v:
            fail("Konstante %s = %r (erwartet %r)" % (k, C.get(k), v))
    if B.count("app.") != 5 or B.count('app.view_functions.get("sdrn_api")') != 1 or B.count('app.view_functions["sdrn_api"] = _uf_api_wrap(_uf_vf)') != 1 \
            or B.count('app.view_functions["sdrn_api"] = _uf_vf\n') != 1 \
            or B.count("app.after_request(_uf_after)") != 1 or B.count('app.after_request_funcs.get(None, [])') != 1:
        fail("App-Zugriffe nicht genau: sdrn_api umhuellen + ein after_request")
    for s in ('if _uf_rq.args.get("evl") == "1":', 'j["evl"] = _evl_view()', '_uf_rq.path.rstrip("/") == "/umwelt"', 'resp.headers["X-Umwelt-Flach"] = "1" if ok else "0"',
              "if body.count(_UF_HOST) != 1 or body.count(_UF_SLOT) != 1:", "    _sdrn_data = _uf_data0\n", "    _SDRN_JS, _EVL_JS = _uf_s, _uf_e\n", "    _SDRN_JS, _EVL_JS, _SDRN_CSS = _uf_old\n",
              "        _SDRN_CSS = _SDRN_CSS + _UF_CSS\n", '_uf_data0 = _sdrn_data if "_uf_data0" not in globals() else _uf_data0\n'):
        if B.count(s) != 1:
            fail("Block ohne %r" % s[:60])
    tr = B[B.index("\ntry:\n    _uf_s, _uf_e, _UF_ST = _selftest_umweltflach()"):]
    if tr.index("_selftest_umweltflach()") > tr.index("_SDRN_JS, _EVL_JS = _uf_s") or tr.index("_SDRN_JS, _EVL_JS = _uf_s") > tr.index("app.after_request(_uf_after)"):
        fail("Reihenfolge Selbsttest -> Skripte -> Seite")
    for s in CSS_NEED:
        if B.count(s) != 1:
            fail("CSS ohne %r" % s[:60])
    css = C.get("_UF_CSS", "")
    if not css.startswith('<style id="uf-css">') or "ellipsis" in css or "overflow:hidden" in css or css.count("{") != css.count("}"):
        fail("CSS schneidet wieder ab")


class Tree(HTMLParser):
    VOID = {"br", "img", "input", "meta", "link", "hr", "source", "wbr"}

    def __init__(s):
        super().__init__()
        s.st, s.cards, s.ids, s.err, s.order, s.btn, s.txt = [], [], {}, [], [], {}, []

    def handle_starttag(s, t, a):
        if t in s.VOID:
            return
        a = dict(a)
        cl = (a.get("class") or "").split()
        node = {"t": t, "cl": cl, "id": a.get("id"), "title": None, "card": "card" in cl, "a": a}
        if node["card"] and any(x["card"] for x in s.st):
            s.err.append("Kachel in Kachel: %s" % a)
        if node["card"]:
            s.cards.append(node)
            s.order.append(node)
            par = s.st[-1] if s.st else None
            if not par or par.get("id") != "umwGrid":
                s.err.append("Kachel nicht direkt im Raster umwGrid")
        if a.get("id"):
            s.ids[a["id"]] = s.ids.get(a["id"], 0) + 1
            if a["id"] == "umwSdrnSlot":
                s.order.append({"title": "@@SLOT@@"})
        if t == "button" and a.get("id"):
            card = next((x for x in reversed(s.st) if x["card"]), None)
            s.btn[a["id"]] = (card, a.get("onclick"))
        if t == "div" and "title" in cl:
            card = next((x for x in reversed(s.st) if x["card"]), None)
            if card is not None and card["title"] is None:
                card["_tt"] = node
        s.st.append(node)

    def handle_endtag(s, t):
        if t in s.VOID:
            return
        if not s.st or s.st[-1]["t"] != t:
            s.err.append("Ende </%s> passt nicht (%s)" % (t, s.st[-1]["t"] if s.st else "-"))
            return
        s.st.pop()

    def handle_data(s, d):
        for x in reversed(s.st):
            if x["t"] in ("script", "style"):
                return
        for x in s.st:
            if x["card"] and x.get("_tt") is not None and x["title"] is None and x["_tt"] in s.st:
                x["title"] = d.strip()
        s.txt.append(d)


DATA_FULL = {
    "wetter": {"value": {"icon": "🌤️", "temp": 7.6, "sunshine": 0.6, "days": [{"weekday": "Sa", "date": "31.10", "max": 8.2, "min": 4.5, "sun": 0.6, "icon": "🌧"}]}, "color": "#94a3b8", "updated": "31.10.2026 16:21:05"},
    "dwd_warn": {"value": {"max_level": 2, "color": "#eab308", "items": [{"name": "Kalchreuth", "level": 2, "event": "STURMBÖEN", "headline": "Amtliche WARNUNG vor STURMBÖEN", "start": "31.10. 18:00", "end": "01.11. 06:00"}]},
                 "color": "#94a3b8", "updated": "31.10.2026 16:21:59"},
    "dwd_mesh_status": {"text": "DWD Kalchreuth Stufe 2 Sturmböen", "at": "31.10.2026 16:22:00", "cleared": None},
    "dwd_wbi": {"value": {"wbi": 1, "color": "#22c55e", "station_name": "Nürnberg", "station_id": "3668", "distance_km": 8.2, "date_fmt": "24.10.2026"}, "color": "#94a3b8", "updated": "31.10.2026 16:22:01"},
    "wbi_history": [{"t": "24.10", "v": 1}, {"t": "25.10", "v": 2}],
    "mesh_weather_status": {"auto": "31.10.2026 15:00:05", "manual": "08.09.2026 22:59:50"},
    "spaceweather": {"value": {"kp": 5.33, "kp_max24": 6.0, "label": "Sturm", "color": "#eab308", "G": "G1", "R": "R0", "S": "S0"}, "color": "#94a3b8", "updated": "31.10.2026 16:21:30"},
    "odl": {"value": {"stations": [{"name": "Nürnberg", "value": 0.119}, {"name": "Lauf a.d. Pegnitz", "value": 0.7}, {"name": "Gräfenberg", "value": None}], "avg": 0.31},
            "color": "#94a3b8", "updated": "31.10.2026 16:21:41"},
}


DATA_EMPTY = dict((k, {"value": None, "color": "#94a3b8", "updated": ""}) for k in ("wetter", "dwd_warn", "dwd_wbi", "spaceweather", "odl"))


def render(lp_text, data):
    from flask import Flask, render_template_string
    ns = {"__name__": "lp_guard"}
    exec(compile(lp_text, "lage_pages", "exec"), ns)
    tpl = ns["page3"]("/*BS*/", '<div id="navUnify"></div>')
    app = Flask("ufguard")
    with app.app_context():
        return tpl, render_template_string(tpl, **data)


def tmpl(lp_alt, lp_neu):
    t_alt, _ = render(lp_alt, DATA_EMPTY)
    tpl, html = render(lp_neu, DATA_FULL)
    _, html0 = render(lp_neu, DATA_EMPTY)
    for h, nm in ((html, "mit Daten"), (html0, "ohne Daten")):
        p = Tree()
        p.feed(h)
        p.close()
        if p.err:
            fail("Vorlage %s: %s" % (nm, p.err[0]))
        tt = [x.get("title") for x in p.order]
        if tt != TITLES:
            fail("Reihenfolge/Titel %s: %s" % (nm, tt))
        for i in IDS:
            if p.ids.get(i) != 1:
                fail("ID %s %s nicht genau einmal (%s)" % (i, nm, p.ids.get(i)))
        for b, (title, oc) in BTN.items():
            card, onclick = p.btn.get(b, (None, None))
            if card is None or card.get("title") != title or onclick != oc:
                fail("Knopf %s nicht in seiner Kachel %s (%s, %s)" % (b, title, card and card.get("title"), onclick))
        if p.st and [x["t"] for x in p.st] not in (["html", "body"], ["body"], ["html"], []):
            fail("Vorlage %s: offene Elemente am Ende %s" % (nm, [x["t"] for x in p.st][:6]))
    for s in ("Verlauf:", "(Orientierung)", "manuell per Button", "Auto: 0/3/6/9/12/15/18/21 Uhr", 'class="card full" style="padding:10px;text-align:center"', "min-height:1.2em"):
        if s in tpl:
            fail("Vorlage enthaelt noch %r" % s)
    for s in ('fetch("/api/mesh_spaceweather",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"});',
              'fetch("/api/mesh_odl",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Mesh-Post":"1"},body:"{}"});',
              "async function sendSpaceMesh() {", "async function sendOdlMesh(){", "{# kpGshow #}", "<!-- dwdV3 -->", "Kleiner Sturm, erste Polarlichter",
              '<div class="umw-ft">DWD · <span class="small" style="color:{{ dwd_warn.color if dwd_warn is defined else \'#94a3b8\' }}">{{ dwd_warn.updated if dwd_warn is defined else \'\' }}</span></div>'):
        if tpl.count(s) != 1 or t_alt.count(s) != 1 and s not in ('<div class="umw-ft">DWD · <span class="small" style="color:{{ dwd_warn.color if dwd_warn is defined else \'#94a3b8\' }}">{{ dwd_warn.updated if dwd_warn is defined else \'\' }}</span></div>',):
            fail("Vorlage: %r nicht genau einmal / nicht wie vorher" % s[:60])
    if "prompt(" in tpl or re.search(r"(?i)\bpin\b|X-Pin|pin=", tpl):
        fail("PIN/Abfrage an Mesh-Knoepfen")
    for s in ("A · 31.10.2026 15:00:05", "M · 08.09.2026 22:59:50", "Stufe 2", "STURMBÖEN", "Kp 5.33", "G/R/S <b style=\"color:#e2e8f0\">G2 · R0 · S0</b>", "Moderate Aktivität, Norddeutschland reagiert",
              "0.7 µSv/h", "0.31 µSv/h", "BfS · Ampel ≤0,25 / ≤0,60 µSv/h · ", "Station Nürnberg (3668) · 8.2 km", "Mesh · DWD Kalchreuth Stufe 2 Sturmböen"):
        if s not in html:
            fail("Vorlage mit Daten ohne %r" % s)
    for s in ('<span class="small" style="color:#94a3b8">31.10.2026 16:21:05</span>', '<span class="small" style="color:#94a3b8">31.10.2026 16:21:41</span>',
              '<span class="small" style="color:#94a3b8">31.10.2026 16:21:30</span>', '<span class="small" style="color:#94a3b8">31.10.2026 16:22:01</span>'):
        if s not in html:
            fail("Zeitstempel nicht allein in .small (staleTs): %s" % s[40:])
    if "Verlauf" in html or "Keine Sonnenaktivitäts-Daten" not in html0 or "Keine ODL-Daten" not in html0:
        fail("Vorlage Inhalte")
    return "Vorlage: 6 Kacheln direkt im Raster (keine Kachel in Kachel, alle Tags geschlossen, mit und ohne Daten), Reihenfolge DWD/Wetter/Waldbrand/Platz/ODL/Sonne, Mesh-Knoepfe in ihrer Kachel ohne PIN, Sende-Skripte unveraendert, Zeitstempel allein (staleTs)"


class FakeApp:
    def __init__(s):
        from flask import Flask
        s.f = Flask("ufguard2")
        s.view_functions = s.f.view_functions
        s.after_request_funcs = s.f.after_request_funcs
        s.url_map = s.f.url_map

    def after_request(s, fn):
        return s.f.after_request(fn)


def behav(B, lp_neu):
    from flask import jsonify, make_response
    for k, v in (("sdrn", FIX_SDRN), ("evl", FIX_EVL)):
        if hashlib.sha256(v.encode("utf-8")).hexdigest()[:16] != FIX_SHA[k]:
            fail("Attrappe %s veraendert" % k)
    ns = {"__name__": "lp_guard"}
    exec(compile(lp_neu, "lage_pages", "exec"), ns)
    app = FakeApp()
    calls = {"st": 0}

    def sdrn_api():
        return jsonify(dict(_sdrn_data_ref[0](), ok=True))

    def st():
        calls["st"] += 1
        return {"status": {"noise_diag": {"skip": "numpy fehlt fuer prepper-sdr", "skip_t": 1793000000}}}
    g = {"__name__": "ufguard", "app": app, "_SDRN_JS": FIX_SDRN, "_EVL_JS": FIX_EVL, "_SDRN_CSS": "<style id=\"x\"></style>", "PAGE3": ns["page3"]("/*BS*/", "<nav></nav>"),
         "_sdrn_data": lambda: {"noise": {"t": 1}, "now": 2}, "_sdr_status": st, "_evl_view": lambda: {"ok": True, "qrm": [1, 2], "th": []}}
    _sdrn_data_ref = [None]
    app.f.add_url_rule("/api/sdr/noise", endpoint="sdrn_api", view_func=sdrn_api)
    app.f.add_url_rule("/umwelt", endpoint="umw", view_func=lambda: make_response(g["PAGE3"].replace("</body>", '<style></style><div id="sdrnHost"></div><script></script></body>')))
    app.f.add_url_rule("/funk433", endpoint="f433", view_func=lambda: '<body><div id="sdrnHost"></div><div id="umwSdrnSlot"></div></body>')
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        exec(compile(B, "blk", "exec"), g)
    out = buf.getvalue()
    assert "umweltFlach aktiv: umweltFlach ok" in out and "FEHLER" not in out, out[:300]
    _sdrn_data_ref[0] = lambda: g["_sdrn_data"]()
    js, ev = g["_SDRN_JS"], g["_EVL_JS"]
    assert js != FIX_SDRN and ev != FIX_EVL and g["_SDRN_CSS"].endswith("</style>") and 'id="uf-css"' in g["_SDRN_CSS"]
    for s in JS_NEED_S:
        assert js.count(s) == 1, "Stoersender-Skript ohne " + s[:60]
    for s in JS_NEED_E:
        assert ev.count(s) == 1, "Ereignis-Skript ohne " + s[:60]
    for s in JS_BAD:
        new = js.replace(FIX_SDRN, "") if False else js
        assert js.count(s) == FIX_SDRN.count(s) and ev.count(s) == FIX_EVL.count(s), "neues Skript enthaelt " + s
    assert js.count("fetch(") == 1 and js.count("setInterval(") == 1 and ev.count("setInterval(") == 2 and ev.count("fetch(") == FIX_EVL.count("fetch("), "Abrufe/Takte"
    for s in SAFE:
        assert js.count(json.dumps(s, ensure_ascii=False)) == 1, "Sicherheits-/Hinweistext nicht wortgleich: " + s[:50]
    assert "noch zu wenig Messwerte für eine Kurve" in js and "'Ereignisse (letzte 10)'" not in ev
    d = g["_sdrn_data"]()
    assert d["uf"] == {"skip": "numpy fehlt fuer prepper-sdr", "skip_t": 1793000000} and d["noise"] == {"t": 1}, d
    c = app.f.test_client()
    r = c.get("/umwelt")
    h = r.get_data(as_text=True)
    assert r.headers.get("X-Umwelt-Flach") == "1" and h.count('<div id="sdrnHost"></div>') == 1 and "umwSdrnSlot" not in h, "Platz nicht ersetzt"
    i = [h.index(x) for x in ("🔥 DWD WBI · Waldbrand", '<div id="sdrnHost"></div>', "☢️ Strahlung (ODL) · Umgebung")]
    assert i == sorted(i), ("Stoersender nicht zwischen Waldbrand und ODL", i)
    r2 = c.get("/funk433")
    assert "X-Umwelt-Flach" not in r2.headers and r2.get_data(as_text=True).count("umwSdrnSlot") == 1, "andere Seite angefasst"
    j1 = c.get("/api/sdr/noise").get_json()
    j2 = c.get("/api/sdr/noise?evl=1").get_json()
    assert "evl" not in j1 and j2["evl"] == {"ok": True, "qrm": [1, 2], "th": []} and j2["uf"]["skip"] == "numpy fehlt fuer prepper-sdr", (j1, j2)
    assert c.post("/api/sdr/noise?evl=1").status_code == 405
    n_after = len(app.after_request_funcs.get(None, []))
    css1 = g["_SDRN_CSS"]
    for jj, ee in (("x", [("a", "b")]), ("x a", [("a", "b"), ("zz", "y")]), ("a a", [("a", "b")])):
        try:
            g["_uf_apply"](jj, ee, "t")
            raise AssertionError("_uf_apply nicht alles-oder-nichts")
        except ValueError:
            pass
    buf2 = io.StringIO()
    with contextlib.redirect_stdout(buf2):
        exec(compile(B, "blk", "exec"), g)
    assert len(app.after_request_funcs.get(None, [])) == n_after and g["_SDRN_JS"] == js and g["_EVL_JS"] == ev and g["_SDRN_CSS"] == css1 \
        and "umweltFlach aktiv: umweltFlach ok" in buf2.getvalue() and "FEHLER" not in buf2.getvalue(), "zweites Laden nicht idempotent"
    # Fehlerfall: lage_pages alt -> nichts aktiv
    g2 = dict(g, app=FakeApp(), _SDRN_JS=FIX_SDRN, _EVL_JS=FIX_EVL, _SDRN_CSS="<style></style>", PAGE3="<div class=\"grid\"><div class=\"card full\"><div class=\"title\">☢️ Strahlung (ODL) · Umgebung</div></div></div>")
    for k in [k for k in g2 if k.startswith(("_uf", "_UF", "UF_", "_selftest_umweltflach"))]:
        del g2[k]
    g2["_sdrn_data"] = lambda: {"noise": {}}
    g2["app"].f.add_url_rule("/api/sdr/noise", endpoint="sdrn_api", view_func=sdrn_api)
    d0 = g2["_sdrn_data"]
    buf3 = io.StringIO()
    with contextlib.redirect_stdout(buf3):
        exec(compile(B, "blk", "exec"), g2)
    assert "umweltFlach Selbsttest FEHLER" in buf3.getvalue() and g2["_SDRN_JS"] == FIX_SDRN and g2["_EVL_JS"] == FIX_EVL and g2["_SDRN_CSS"] == "<style></style>" \
        and g2["_sdrn_data"] is d0 and not g2["app"].after_request_funcs.get(None) and g2["app"].view_functions["sdrn_api"] is sdrn_api, "Fehlerfall nicht alles-oder-nichts"
    return js, ev


NODE_JS = r"""
var R={log:[],fetch:[],iv:[]};var NOW=1793500000;
function E(t){this.tagName=String(t).toUpperCase();this.children=[];this.parentElement=null;this.className='';this._t='';this.style={};this.dataset={};this.id='';this.attrs={};var me=this;
this.classList={add:function(c){if(!me.classList.contains(c))me.className=(me.className?me.className+' ':'')+c;},remove:function(c){me.className=me.className.split(' ').filter(function(x){return x&&x!==c;}).join(' ');},contains:function(c){return me.className.split(' ').indexOf(c)>=0;}};}
E.prototype.appendChild=function(c){if(c.parentElement)c.parentElement.removeChild(c);c.parentElement=this;this.children.push(c);return c;};
E.prototype.insertBefore=function(c,r){if(c.parentElement)c.parentElement.removeChild(c);c.parentElement=this;var i=this.children.indexOf(r);if(i<0)this.children.push(c);else this.children.splice(i,0,c);return c;};
E.prototype.removeChild=function(c){var i=this.children.indexOf(c);if(i>=0)this.children.splice(i,1);c.parentElement=null;return c;};
E.prototype.setAttribute=function(k,v){this.attrs[k]=v;};
Object.defineProperty(E.prototype,'firstChild',{get:function(){return this.children[0]||null;}});
Object.defineProperty(E.prototype,'lastElementChild',{get:function(){return this.children[this.children.length-1]||null;}});
Object.defineProperty(E.prototype,'childNodes',{get:function(){return this.children;}});
Object.defineProperty(E.prototype,'textContent',{get:function(){return this._t+this.children.map(function(c){return c.textContent;}).join('');},set:function(v){this._t=String(v);this.children=[];}});
function find(n,id){if(n.id===id)return n;for(var i=0;i<n.children.length;i++){var x=find(n.children[i],id);if(x)return x;}return null;}
function all(n,f,o){o=o||[];if(f(n))o.push(n);n.children.forEach(function(c){all(c,f,o);});return o;}
var body=new E('body');var VL={};
global.document={hidden:false,createElement:function(t){return new E(t);},createElementNS:function(ns,t){return new E(t);},createTextNode:function(s){var e=new E('#text');e._t=String(s);return e;},
getElementById:function(id){return find(body,id);},addEventListener:function(k,f){VL[k]=f;},querySelectorAll:function(){return [];}};
global.window=global;global.location={pathname:'/umwelt'};global.alert=function(){};
var T=0;var realNow=Date.now;Date.now=function(){return NOW*1000+T;};
global.setInterval=function(f,ms){R.iv.push(ms);R.ivf=R.ivf||{};R.ivf[ms]=f;return 1;};
var PAY=null;global.fetch=function(u,o){R.fetch.push(u);return Promise.resolve({json:function(){return Promise.resolve(JSON.parse(JSON.stringify(PAY)));}});};
function el(t,id,txt){var e=new E(t);e.id=id;if(txt!==undefined)e._t=txt;body.appendChild(e);return e;}
module.exports={E:E,body:body,R:R,el:el,find:find,all:all,VL:VL,setT:function(x){T=x;},setPay:function(p){PAY=p;},now:NOW};
"""

NODE_RUN = r"""
var H=require('./h.js');var fs=require('fs');var SD=fs.readFileSync('sdrn.js','utf8'),EV=fs.readFileSync('evl.js','utf8');
SD=SD.replace(/^<script id="sdrn-js">/,'').replace(/<\/script>$/,'');var OUT={};var NOW=H.now;
function band(id,sh,ok,lvl,o){return Object.assign({id:id,short:sh,label:sh,ok:ok,lvl:lvl,t:NOW-60,floor:-40,raise:1,learning:false,n_pers:0,cars:[],why:ok?null:'KW aus',base:-41,trend:null},o||{});}
function D(o){return Object.assign({noise:{t:NOW-10*86400,qrm:{lvl:'gruen'},thunder:{lvl:'gruen',bb_pm:12,base:10,why:'ruhig'},bands:[band('n2m','2 m',true,'gruen'),band('fm','UKW',true,'gelb'),band('gps','GPS',true,'gruen'),band('mw','MW',false,'grau'),band('hf10','KW',false,'grau')]},
hist:{},now:NOW,iv:900,uf:{skip:'Planer xyz'},gps:{}},o||{});}
function ev(n,grp){var L=[];for(var i=0;i<n;i++)L.push({start:NOW-3600*(i+1),end:NOW-3600*(i+1)+60,on:false,band:'UKW',kind:'Rauschboden',lvl:'gelb',grp:grp,start_tq:{sync:true,s:1},end_tq:{sync:true,s:1}});return L;}
function txt(n){return n.textContent;}
function boot(d,evd,path){H.body.children=[];H.R.iv=[];H.R.fetch=[];global.location.pathname=path||'/umwelt';
H.el('div','sdrnHost');H.el('script','sdrnData',JSON.stringify(d));H.el('script','evl-data',JSON.stringify(evd));if(global.location.pathname==='/umwelt')eval(SD);eval(EV);}
function card(id){return H.find(H.body,id);}
function rows(c){return H.all(c,function(n){return /(^| )sdrn-row( |$)/.test(n.className);}).map(txt);}
var EVD={ok:true,now:NOW,qrm:ev(8,'qrm'),th:ev(2,'thunder'),kfz:[],kfz_today:{}};
// A: Ruhe, Messung alt, Stick-L1 gruen, graue Baender
boot(D(),EVD);var q=card('sdrnQrm'),t=card('sdrnThunder');
OUT.A={rows:rows(q),small:H.all(q,function(n){return n.className.indexOf('small')===0;}).map(function(n){return [n.className,txt(n)];}),
info:H.all(q,function(n){return n.className==='uf-i';}).map(txt),thN:t.children.length,thFirst:[t.children[0].tagName,t.children[0].id],thSum:txt(t.children[0].children[0]),
thTitle:H.all(t,function(n){return n.className==='title';}).length,thInfo:H.all(t,function(n){return n.className==='uf-i';}).map(txt),iv:H.R.iv.slice(),
qEv:(function(){var b=card('evl-qrm');return b&&{par:b.parentElement.id,direct:b.children.filter(function(c){return c.className==='evl-row';}).length,more:b.children.filter(function(c){return c.className==='uf-more';}).map(function(m){return [txt(m.children[0]),m.children.filter(function(c){return c.className==='evl-row';}).length];}),h:txt(b.children[0])};})(),
tEv:(function(){var b=card('evl-th');return b&&{par:b.parentElement.id,n:b.children.filter(function(c){return c.className==='evl-row';}).length};})()};
// Abruf: unsichtbar -> keiner; sichtbar -> genau einer mit evl=1, danach Ereignisse wieder platziert
H.setPay(Object.assign(D({noise:{t:NOW-60,qrm:{lvl:'gelb'},thunder:{lvl:'gelb',bb_pm:90,base:10,why:'mehr'},bands:[band('gps','GPS',true,'gelb'),band('n2m','2 m',true,'gruen')]},hist:{gps:{d:[{ts:NOW-120,floor:-40}]}}}),{evl:EVD}));
document.hidden=true;H.R.ivf[120000]();OUT.fHidden=H.R.fetch.length;document.hidden=false;H.R.ivf[120000]();OUT.fVis=H.R.fetch.slice();
setTimeout(function(){var q2=card('sdrnQrm'),t2=card('sdrnThunder');
OUT.B={rows:rows(q2),thTitle:H.all(t2,function(n){return n.className==='title';}).map(txt),thX:!!card('sdrnThunderX'),thSmall:H.all(t2,function(n){return n.className==='small';}).map(txt),
small:H.all(q2,function(n){return n.className.indexOf('small')===0;}).map(function(n){return [n.className,txt(n)];}),qEv:!!(card('evl-qrm')&&card('evl-qrm').parentElement===q2),tEv:card('evl-th')&&card('evl-th').parentElement.id};
H.setT(60000);document.hidden=false;var n0=H.R.fetch.length;H.VL.visibilitychange();OUT.visEarly=H.R.fetch.length-n0;H.setT(400000);H.VL.visibilitychange();OUT.visLate=H.R.fetch.length-n0;
boot(D(),EVD,'/funk433');OUT.funk=H.R.iv.slice();
console.log(JSON.stringify(OUT));},50);
"""


def node_test(js, ev):
    nd = shutil.which("node") or shutil.which("nodejs")
    if os.environ.get("GUARD_NO_NODE") or not nd:
        return "Seiten-Skripte statisch (node fehlt)"
    d = tempfile.mkdtemp()
    try:
        for n, t in (("h.js", NODE_JS), ("run.js", NODE_RUN), ("sdrn.js", js), ("evl.js", ev)):
            open(os.path.join(d, n), "w", encoding="utf-8").write(t)
        o = subprocess.run([nd, "run.js"], cwd=d, capture_output=True, text=True, timeout=60)
        assert o.returncode == 0 and o.stdout.strip(), "node: " + (o.stderr or o.stdout)[-400:]
        R = json.loads(o.stdout.strip().splitlines()[-1])
    finally:
        shutil.rmtree(d, ignore_errors=True)
    A, B = R["A"], R["B"]
    assert not any("Stick-L1" in r for r in A["rows"]), ("Stick-L1 gruen sichtbar", A["rows"])
    assert any(r == "○ nicht gemessen: MW, KW · KW aus" for r in A["rows"]), ("graue Baender", A["rows"])
    assert any(r.startswith("2 m") for r in A["rows"]) and any(r.startswith("UKW") for r in A["rows"]) and not any(r.startswith("MW") for r in A["rows"]), A["rows"]
    sm = dict((t, c) for c, t in A["small"])
    k = [t for t in sm if t.startswith("Messung alle 15 min · zuletzt ")]
    assert len(k) == 1 and k[0].endswith(" (vor 10 d – läuft nicht)") and "uf-old" in sm[k[0]], ("Statuszeile alt", A["small"])
    assert "keine Kurve – letzte Messung vor 10 d (Messung läuft nicht: Planer xyz)" in sm, ("Kurve ohne Grund", A["small"])
    assert A["info"] == ["ⓘ Erklärung" + json.loads(json.dumps(s)) for s in [] ] or (len(A["info"]) == 1 and SAFE[1] in A["info"][0] and "Nur Leistungsmessung, kein Inhalt." in A["info"][0]), A["info"]
    assert A["thN"] == 1 and A["thFirst"] == ["DETAILS", "sdrnThunderX"] and A["thSum"] == "⚡ Gewitter ● grün – ruhig · 12/min" and A["thTitle"] == 0, ("Gewitter Ruhe 1 Zeile", A)
    assert len(A["thInfo"]) == 1 and SAFE[0] in A["thInfo"][0], "Gewitter-Hinweis nicht wortgleich"
    assert A["iv"] == [120000], ("Takte /umwelt", A["iv"])
    assert A["qEv"] == {"par": "sdrnQrm", "direct": 5, "more": [["mehr (3)", 3]], "h": "Ereignisse"}, A["qEv"]
    assert A["tEv"] == {"par": "sdrnThunderX", "n": 2}, A["tEv"]
    assert R["fHidden"] == 0 and R["fVis"] == ["/api/sdr/noise?evl=1"], (R["fHidden"], R["fVis"])
    assert any(r.startswith("GPS") and "Stick-L1 (Nebenwert)" in r for r in B["rows"]), ("Stick-L1 gelb fehlt", B["rows"])
    assert B["thTitle"] == ["⚡ Gewitter-Hinweis"] and not B["thX"] and "Grober Hinweis – keine Blitzortung, keine Unwetterwarnung." in B["thSmall"], ("Gewitter gelb", B)
    assert any(t == "noch zu wenig Messwerte für eine Kurve" for c, t in B["small"]) and not any("uf-old" in c for c, t in B["small"]), ("frische Messung", B["small"])
    assert B["qEv"] and B["tEv"] == "sdrnThunder", ("Ereignisse nach Abruf neu platziert", B)
    assert R["visEarly"] == 0 and R["visLate"] == 1, ("Sichtbar-Abruf", R["visEarly"], R["visLate"])
    assert sorted(R["funk"]) == [2000, 30000], ("/funk433 Takte veraendert", R["funk"])
    return "Seiten-Skripte mit node (DOM-Attrappe): Stick-L1 nur gelb/rot, graue Baender 1 Zeile, Messung alt rot + Grund, Gewitter Ruhe 1 Zeile/gelb voll mit Hinweis, Ereignisse 5 + mehr (3), ein Abruf 120 s nur sichtbar, /funk433 unveraendert"


def check(altd, neud, bp, ep):
    B = blk_text(bp)
    altD, neuD = rd(os.path.join(altd, "dashboard.py")), rd(os.path.join(neud, "dashboard.py"))
    altL, neuL = rd(os.path.join(altd, "lage_pages.py")), rd(os.path.join(neud, "lage_pages.py"))
    try:
        rD, rL = revert_d(neuD, bp), revert_l(neuL, ep)
    except AssertionError as e:
        fail(str(e))
    if rD != altD:
        fail("Rueckbau dashboard.py != Basis (Aenderung ausserhalb des Blocks)")
    if rL != altL:
        fail("Rueckbau lage_pages.py != Basis (Aenderung ausserhalb page3-Kachelbereich)")
    E = edits(ep)
    if E.get("DSH_EDITS") != [] or len(E.get("LP_EDITS") or []) != 1:
        fail("Stellen: dashboard.py nur Block, lage_pages.py genau ein Bereich")
    o, n = E["LP_EDITS"][0]
    if not (o.startswith('<div class="grid">\n  <div class="card full">\n    <div class="title">🌤 Wetter') and o.endswith("<!--nav-bottom-removed-->") and n.endswith("<!--nav-bottom-removed-->")):
        fail("lage_pages.py: Bereich nicht page3-Kachelbereich")
    if altL.count(o) != 1 or altL.index(o) < altL.index("def page3(") or altL.index(o) > altL.index("\ndef ", altL.index("def page3(") + 5):
        fail("lage_pages.py: Bereich ausserhalb page3")
    if not B.startswith(M0) or not B.rstrip("\n").endswith(M1):
        fail("Block beginnt/endet nicht mit Marker")
    try:
        compile(B, "blk", "exec")
    except SyntaxError as e:
        fail("Syntax %s" % e)
    static(B)
    try:
        tv = tmpl(altL, neuL)
        js, ev = behav(B, neuL)
        nt = node_test(js, ev)
    except AssertionError as e:
        fail("Verhalten: %s" % str(e)[:400])
    except SystemExit:
        raise
    except Exception as e:
        fail("Verhalten (%s): %s" % (type(e).__name__, str(e)[:300]))
    print("Guard umweltFlach ok: Rueckbau byte-genau = Basis (dashboard.py nur Block, lage_pages.py nur page3-Kachelbereich); statisch (nur json/flask, kein Prozess/Netz/Mesh/Datei, "
          "nur sdrn_api umhuellen + ein after_request, Konstanten 120 s/5/3, CSS Umbruch statt Abschneiden); %s; Block mit Flask: Platz ersetzt nur /umwelt, ?evl=1 nur GET, "
          "Grund aus noise_diag, idempotent, Fehlerfall alles-oder-nichts; Hinweistexte wortgleich; %s" % (tv, nt))


def mut_l(n):
    return [
        ('  <div id="umwSdrnSlot"></div>\n  <div class="card full">\n    <div class="title">☢️ Strahlung', '  <div class="card full">\n    <div class="title">☢️ Strahlung'),
        ('    </div>\n  </div>\n  <div class="card full">\n    <div class="title">☀ Sonnenaktivität', '    </div>\n  <div class="card full">\n    <div class="title">☀ Sonnenaktivität'),
        ('<div class="grid" id="umwGrid">', '<div class="grid" id="umwGridX">'),
        ('    <div class="umw-sub">\n      <button id="odlMeshBtn"', '  </div>\n  <div class="card full">\n    <div class="umw-sub">\n      <button id="odlMeshBtn"'),
        ('onclick="sendSpaceMesh()"', 'onclick="if(prompt(\'PIN\'))sendSpaceMesh()"'),
        ('fetch("/api/mesh_odl",{method:"POST"', 'fetch("/api/mesh_odl?probe=1",{method:"POST"'),
        ("    <div class=\"umw-ft\">DWD WBI · ", "    <div class=\"small\">Verlauf: x</div>\n    <div class=\"umw-ft\">DWD WBI · "),
        ('<span class="small" style="color:{{ odl.color if odl is defined else \'#94a3b8\' }}">{{ odl.updated if odl is defined else \'\' }}</span>', '{{ odl.updated if odl is defined else \'\' }}'),
        ('{% elif _gs == 2 %}', '{% elif _gs == 3 %}'),
        ('  <!-- dwdV3 -->\n  <div class="card full">\n    <div class="title">⚠️ DWD Warnungen</div>', '  <div class="card full">\n    <div class="title">⚠️ DWD Warnungen</div>'),
    ]


MUTS = [
    ("UF_POLL_MS = 120000 ", "UF_POLL_MS = 30000 "), ("UF_EV_SHOW = 5 ", "UF_EV_SHOW = 10 "), ("UF_STALE_F = 3 ", "UF_STALE_F = 30 "),
    ("if(b.id==='gps'&&b.lvl!=='gelb'&&b.lvl!=='rot')return;", ""), ("if(!b.ok){UFG.push(b);return;}", ""), ("if(UFG.length)rows.appendChild(", "if(false)rows.appendChild("),
    ("var UFR=(tl!=='gelb'&&tl!=='rot');", "var UFR=(tl!=='rot');"), ("host.appendChild(gH);", "host.appendChild(g);"), ("if(document.hidden)return;", ""),
    ("setInterval(ufPoll,", "setTimeout(ufPoll,"), ("if(!document.hidden&&Date.now()-ufT>=", "if(Date.now()-ufT>="), ("if(window.ufEvl)window.ufEvl(ev);", ""),
    ("fetch('/api/sdr/noise?evl=1'", "fetch('/api/sdr/noise'"), ("'small'+(o?' uf-old':'')", "'small'"), ("(U.skip?': '+U.skip:'')", "''"),
    ("if(k!=='snr'&&ufStale())", "if(ufStale())"), ("return !N.t||(ufNow()-N.t)>UF_F*(D.iv||900);", "return (ufNow()-N.t)>UF_F*900;"),
    ("g.appendChild(el('div','small',\"\"\" + _uf_json.dumps(_UF_TH_SHORT, ensure_ascii=False)", "g.appendChild(el('div','small',\"\"\" + _uf_json.dumps(\"\", ensure_ascii=False)"),
    ("Draht-/KW-Antenne; keine Entfernungs- oder Blitzortung, keine Unwetterwarnung.\")", "Draht-/KW-Antenne; keine Blitzortung.\")"),
    ("if(ix===UF_N&&L.length>UF_N)", "if(ix===UF_N+1&&L.length>UF_N)"), ("var tgt=UM||box;", "var tgt=box;"),
    ("[['sdrnQrm','evl-qrm','qrm','Ereignisse'],['sdrnThunder','evl-th','th','Ereignisse']].forEach(function(a){var c=document.getElementById(a[0]+'X')||document.getElementById(a[0]);",
     "[['sdrnQrm','evl-qrm','qrm','Ereignisse'],['sdrnThunder','evl-th','th','Ereignisse']].forEach(function(a){var c=document.getElementById(a[0]);"),
    ("if(P==='/umwelt'){window.ufEvl=function(j){if(j&&j.ok)D=j;place();};place();}else{", "window.ufEvl=function(j){if(j&&j.ok)D=j;place();};{"),
    ("#umwGrid .evl-tx{white-space:normal;overflow:visible;text-overflow:clip;overflow-wrap:anywhere}", "#umwGrid .evl-tx{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}"),
    ("#umwGrid #sdrnHost .sdrn-row .tx{white-space:normal;", "#umwGrid #sdrnHost .sdrn-row .tx{white-space:nowrap;"),
    ('    if body.count(_UF_HOST) != 1 or body.count(_UF_SLOT) != 1:\n        return body, False\n', ''),
    ('if _uf_rq.path.rstrip("/") == "/umwelt" and', 'if _uf_rq.path.rstrip("/") in ("/umwelt", "/funk433") and'),
    ('            if _uf_rq.args.get("evl") == "1":', '            if True:'), ("    _sdrn_data = _uf_data0\n", "    pass\n"),
    ("    _SDRN_JS, _EVL_JS = _uf_s, _uf_e\n", "    _SDRN_JS = _uf_s\n"), ("    _SDRN_JS, _EVL_JS, _SDRN_CSS = _uf_old\n", "    pass\n"),
    ("    if _UF_CSS not in _SDRN_CSS:\n", "    if True:\n"),
    ("    if UF_MARK in js:\n        return js\n", ""), ('            raise ValueError("%s: Stelle %d nicht genau einmal (%d)" % (tag, i + 1, js.count(o)))', "            continue"),
    ('    assert p3.count(_UF_SLOT) == 1 and', '    assert True or p3.count(_UF_SLOT) == 1 and'),
    ("import json as _uf_json\n", "import json as _uf_json\nimport os as _uf_os\n"),
    ("d[\"uf\"] = {\"skip\": (str(nd.get(\"skip\"))[:120] if nd.get(\"skip\") else None)", "d[\"uf\"] = {\"skip\": None"),
    ("c.appendChild(ufLast(N));", "c.appendChild(el('div','small','Messung'));"),
    ("if(v.length<2){box.appendChild(el('div','small',ufNo(key)));return;}", "if(v.length<2){box.appendChild(el('div','small','noch zu wenig Messwerte für eine Kurve'));return;}"),
]


def mutate(altd, neud, bp, ep):
    B = blk_text(bp)
    E = rd(ep)
    me = os.path.abspath(__file__)
    d = tempfile.mkdtemp()
    caught = missed = 0
    try:
        def run(dash, lp, b_txt, e_txt):
            nd = os.path.join(d, "n")
            os.makedirs(nd, exist_ok=True)
            open(os.path.join(nd, "dashboard.py"), "w", encoding="utf-8").write(dash)
            open(os.path.join(nd, "lage_pages.py"), "w", encoding="utf-8").write(lp)
            open(os.path.join(d, "b.py"), "w", encoding="utf-8").write(b_txt)
            open(os.path.join(d, "e.py"), "w", encoding="utf-8").write(e_txt)
            o = subprocess.run([sys.executable, me, "check", altd, nd, os.path.join(d, "b.py"), os.path.join(d, "e.py")], capture_output=True, text=True, timeout=300)
            return o.returncode != 0, ((o.stdout + o.stderr).strip().splitlines() or [""])[-1:]
        altD, altL = rd(os.path.join(altd, "dashboard.py")), rd(os.path.join(altd, "lage_pages.py"))
        neuD, neuL = rd(os.path.join(neud, "dashboard.py")), rd(os.path.join(neud, "lage_pages.py"))
        bad, msg = run(neuD, neuL, B, E)
        if bad:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        cases = []
        for a, b in MUTS:
            if B.count(a) < 1:
                print("UEBERSEHEN (Mutation passt nicht): %r" % a[:70]); missed += 1; continue
            Bm = B.replace(a, b, 1)
            cases.append(("blk " + a[:50], altD.replace(ANCH, "\n\n" + Bm.rstrip("\n") + ANCH, 1), neuL, Bm, E))
        o, n = edits(ep)["LP_EDITS"][0]
        for a, b in mut_l(n):
            if n.count(a) != 1:
                print("UEBERSEHEN (Vorlage-Mutation passt nicht): %r" % a[:70]); missed += 1; continue
            nm = n.replace(a, b, 1)
            Em = E.replace(repr(n), repr(nm), 1)
            assert Em != E
            cases.append(("lp " + a[:50], neuD, altL.replace(o, nm, 1), B, Em))
        cases.append(("Zeile ausserhalb dashboard", neuD.replace("T4_SAY_MAX = 600", "T4_SAY_MAX = 601", 1), neuL, B, E))
        cases.append(("Zeile ausserhalb lage_pages", neuD, neuL.replace('PAGES_SPLIT = "pagesSplit1"', 'PAGES_SPLIT = "pagesSplitX"', 1), B, E))
        cases.append(("Block doppelt", neuD.replace(ANCH, "\n\n" + B.rstrip("\n") + ANCH, 1), neuL, B, E))
        cases.append(("lage_pages alt", neuD, altL, B, E))
        for name, dash, lp, b_txt, e_txt in cases:
            bad, msg = run(dash, lp, b_txt, e_txt)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest umweltFlach: %d erkannt, %d uebersehen%s" % ("OK" if missed == 0 else "FEHLER", caught, missed, " (ohne node)" if os.environ.get("GUARD_NO_NODE") or not (shutil.which("node") or shutil.which("nodejs")) else " (mit node)"))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    m = sys.argv[1]
    if m == "revert":
        os.makedirs(sys.argv[3], exist_ok=True)
        open(os.path.join(sys.argv[3], "dashboard.py"), "w", encoding="utf-8").write(revert_d(rd(os.path.join(sys.argv[2], "dashboard.py")), sys.argv[4]))
        open(os.path.join(sys.argv[3], "lage_pages.py"), "w", encoding="utf-8").write(revert_l(rd(os.path.join(sys.argv[2], "lage_pages.py")), sys.argv[5]))
        print("Rueckbau umweltFlach ok")
    elif m == "check":
        check(*sys.argv[2:6])
    elif m == "mutate":
        mutate(*sys.argv[2:6])
MK_C53_RAG_EOF
EMB="patch.py:$EXPECT_PAL edits.py:$EXPECT_RAE blk.py:$EXPECT_RAB guard.py:$EXPECT_RAG"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (4: Patcher, Stellen, Block, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
lbl() { local v="$1"; shift; while [[ $# -ge 2 ]]; do [[ "$v" == "$1" ]] && { echo "$2"; return; }; shift 2; done; echo UNBEKANNT; }
# ---------- 1) Basis: dashboard.py und lage_pages.py gemeinsam alt oder neu ----------
for x in "$F" "$FL" "$FS"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS")
SD=$(lbl "$D16" "$KNOWN_D16" alt "$KNOWN_D16N" neu); SL=$(lbl "$L16" "$KNOWN_L16" alt "$KNOWN_L16N" neu)
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit52, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 ($(wc -l < "$FL") Zeilen) - $SL (alt $KNOWN_L16, neu $KNOWN_L16N)"
echo "Basis prepper_sdr.py sha16 $S16 - $([[ "$S16" == "$KNOWN_S16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C51" || "$D16" == "$KNOWN_D16_C50" || "$D16" == "$KNOWN_D16_C49" || "$D16" == "$KNOWN_D16_C48" ]]; then
  WAS="nach commit51 (commit52 fehlt)"; [[ "$D16" == "$KNOWN_D16_C50" ]] && WAS="nach commit50 (commit51 und commit52 fehlen)"
  [[ "$D16" == "$KNOWN_D16_C49" ]] && WAS="nach commit49 (commit50 bis commit52 fehlen)"; [[ "$D16" == "$KNOWN_D16_C48" ]] && WAS="nach commit48 (commit49 bis commit52 fehlen)"
  echo "STOP: erst commit52 anwenden - dashboard.py ist noch der Stand $WAS (sha16 $D16), commit53 braucht $KNOWN_D16 (nach commit52) - nichts geaendert."
  exit 1
fi
for v in "dashboard.py:$SD:$D16" "lage_pages.py:$SL:$L16"; do
  IFS=: read -r fn st hh <<< "$v"
  if [[ "$st" == UNBEKANNT ]]; then
    echo "STOP: $fn weicht vom erwarteten Stand ab (sha16 $hh) - nichts geaendert."
    echo "      commit53 passt nur auf den Stand nach commit52. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
    exit 1
  fi
done
if [[ "$SD$SL" != altalt && "$SD$SL" != neuneu ]]; then
  echo "STOP: Mischstand (dashboard.py $SD, lage_pages.py $SL) - erwartet beide alt oder beide neu - nichts geaendert."
  for x in "$F" "$FL"; do LBX=$({ ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | head -1); [[ -n "$LBX" ]] && echo "      Sicherung vorhanden: $LBX ($(s16 "$LBX"))"; done
  echo "      Ein abgebrochener Lauf? Bitte diese Ausgabe an Grok schicken (nichts von Hand kopieren)."
  exit 1
fi
[[ "$S16" == "$KNOWN_S16" ]] || stop "prepper_sdr.py ist nicht der Stand nach commit52 ($S16 statt $KNOWN_S16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" && -w "$FL" ]] || stop "Projektordner, dashboard.py oder lage_pages.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug/jinja2 nicht"
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
  if [[ -n "${C53_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$C53_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$STATE" == neu ]]; then echo "OK Neustart-Sperre: commit53 ist schon installiert, es wird kein Neustart gebraucht"
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
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" || "$f" == "$FL" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher; auch prepper_sdr.py)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$W/patch.py" umweltFlach dsh "$F" "$W/work/dashboard.py" "$W/blk.py" "$W/edits.py" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer umweltFlach nicht eindeutig"; }
python3 "$W/patch.py" umweltFlach lp "$FL" "$W/work/lage_pages.py" - "$W/edits.py" > "$W/ql.log" || { cat "$W/ql.log"; stop "lage_pages.py: Kachelbereich von /umwelt nicht eindeutig"; }
[[ "$(s16 "$W/work/dashboard.py")" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $(s16 "$W/work/dashboard.py") statt $KNOWN_D16N (Zielstand nicht erreicht)"
[[ "$(s16 "$W/work/lage_pages.py")" == "$KNOWN_L16N" ]] || stop "Ergebnis lage_pages.py $(s16 "$W/work/lage_pages.py") statt $KNOWN_L16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(wc -l < "$W/work/dashboard.py") Zeilen; $(cat "$W/q.log")), lage_pages.py $KNOWN_L16N ($(wc -l < "$W/work/lage_pages.py") Zeilen; $(cat "$W/ql.log"))"
python3 "$W/patch.py" umweltFlach dsh "$W/work/dashboard.py" "$W/work/x1" "$W/blk.py" "$W/edits.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
python3 "$W/patch.py" umweltFlach lp "$W/work/lage_pages.py" "$W/work/x2" - "$W/edits.py" > /dev/null && cmp -s "$W/work/lage_pages.py" "$W/work/x2" || stop "lage_pages.py nicht idempotent"
rm -f "$W/work/x1" "$W/work/x2"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/patch.py" "$W/edits.py" "$W/blk.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/work/lage_pages.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/blk.py" "$W/edits.py" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: umweltFlach im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" && "$(s16 "$W/alt/lage_pages.py")" == "$KNOWN_L16" ]] || stop "Guard: Stand ohne umweltFlach ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt" "$W/neu" "$W/blk.py" "$W/edits.py" > "$W/g.log" 2>&1 || { grep -v "^umweltFlach" "$W/g.log" | cut -c1-300; stop "Guard umweltFlach meldet Verstoss"; }
grep "^Guard umweltFlach" "$W/g.log" | cut -c1-1300
command -v node >/dev/null 2>&1 || command -v nodejs >/dev/null 2>&1 || echo "  (node fehlt auf diesem Rechner: Seiten-Skripte hier statisch geprueft; Mutationen werden trotzdem erkannt)"
MUTS=1; [[ -n "${C53_SIM_NOMUT:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt" "$W/neu" "$W/blk.py" "$W/edits.py" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "Mutationstest umweltFlach: eine Verfehlung wurde nicht erkannt"; }
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
t4st() { "${CURL[@]}" "$B/api/t4/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER - - -"); sys.exit(0)
t = d.get("tick") or {}
print(int(bool(d.get("ok"))), int(t.get("n") or 0), int(bool(t.get("thread"))), str(((d.get("hb") or {}).get("last") or {}).get("text") or "-").replace(" ", "_")[:60])' 2>/dev/null || echo "FEHLER - - -"; }
read -r T4OK0 T4N0 T4TH0 HBL0 <<< "$(t4st)"
if [[ "$DRY" != 1 ]]; then [[ "$T4OK0" == 1 ]] || stop "teil4 nicht aktiv (/api/t4/status ok=$T4OK0) - Dashboard nicht im erwarteten Zustand"; fi
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
TLAT0=$(tmed "$B/api/t4/status")
echo "Zustand vorher: BR24 $BR_S0, Lage-Ampel (teil4) $T4L0, teil4 aktiv $T4OK0 (Takt $T4N0, Faden $T4TH0), letzter HB: $(echo "$HBL0" | tr '_' ' '), /api/t4/status Median ${TLAT0} s"
NEED=0; [[ "$STATE" == alt ]] && NEED=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED" == 0 ]]; then echo "  Zustand: umweltFlach ist schon installiert - ein echter Lauf aendert an dashboard.py und lage_pages.py nichts."
  else echo "  Ein echter Lauf wuerde: lage_pages.py und dashboard.py ersetzen (Sicherungen DATEI.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten, 26 Seiten/APIs, /umwelt und Journal pruefen, eine sudo-Passwortabfrage. Beim Einspielen wird nichts gesendet."; fi
  echo "COMMIT $COMMIT_ARG $NM=dry fertig"
  exit 0
fi
if [[ "$NEED" == 1 ]]; then sudo -v || stop "sudo -v fehlgeschlagen (Passwort noetig?) - fuer den Neustart des Dashboards und das Lesen des Journals erforderlich"; fi
jc() { sudo -n journalctl "$@" 2>/dev/null || journalctl "$@" 2>/dev/null || true; }
echo "Keine Datenbank-Aenderung: keine SQLite-Sicherung noetig (lagezentrum.db wird nicht angefasst)"
# ---------- 4) Installieren ----------
trap '' INT
PHASE=Installation
RESTARTED_D=0
T0D=$(date +%s)
INST=()
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "umweltFlach|pagesSplit3|Traceback" | tail -6 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  echo "  Datenbank, prepper_sdr.py und Mesh-Regeln wurden nicht veraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED" == 0 ]]; then
  echo "OK umweltFlach schon installiert - kein Neustart, keine Aenderung an dashboard.py und lage_pages.py"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen"
  for x in "$F" "$FL"; do
    cp -a "$x" "$x.bak-$NM-$TS"
    { ls -1t "$x.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  for v in "$FL:lage_pages.py:$KNOWN_L16N" "$F:dashboard.py:$KNOWN_D16N"; do
    IFS=: read -r x fn hh <<< "$v"
    INST+=("$x")
    cp "$W/work/$fn" "$x.new" && chmod --reference="$x.bak-$NM-$TS" "$x.new" && mv -f "$x.new" "$x" || { rm -f "$x.new"; rb "$fn installieren"; exit 1; }
    [[ "$(s16 "$x")" == "$hh" ]] || { rb "$fn nach dem Kopieren falsch ($(s16 "$x"))"; exit 1; }
  done
  echo "OK lage_pages.py und dashboard.py atomar ersetzt (Sicherungen *.bak-$NM-$TS, behalten: letzte $KEEP_LAST)"
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
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
T4OK=0
for i in $(seq 1 30); do
  read -r T4OK1 T4N1 T4TH1 HBL1 <<< "$(t4st)"
  [[ "$T4OK1" == 1 && "$T4N1" -ge 3 ]] && { T4OK=1; break; }
  sleep 4
done
[[ "$T4OK" == 1 ]] || rbx "teil4 nach dem Neustart nicht aktiv oder Takt steht (ok $T4OK1, Takt $T4N1, Faden $T4TH1)"
sleep 6; read -r T4OK2 T4N2 T4TH2 HBL2 <<< "$(t4st)"
[[ "$T4N2" -gt "$T4N1" ]] || rbx "teil4-Takt laeuft nicht weiter ($T4N1 -> $T4N2)"
echo "OK teil4 aktiv, Takt laeuft ($T4N1 -> $T4N2 in 6 s, Faden $T4TH2)"
TLAT1=$(tmed "$B/api/t4/status")
echo "OK /api/t4/status Median ${TLAT1} s (vorher ${TLAT0} s)"
awk -v a="$TLAT0" -v b="$TLAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/api/t4/status ist deutlich langsamer geworden (${TLAT0} s -> ${TLAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200)"
GEM=$(grep -c "^# ===== umweltFlach:" "$F" || true)
[[ "$GEM" == 1 ]] && echo "OK Marker umweltFlach 1x" || rbx "dashboard.py umweltFlach-Marker ${GEM}x"
UH=$("${CURL[@]}" -D "$W/uh.txt" "$B/umwelt" -o "$W/umwelt.html" -w "%{http_code}" || true)
[[ "$UH" == 200 ]] || rbx "/umwelt HTTP $UH"
UXF=$(grep -i "^X-Umwelt-Flach:" "$W/uh.txt" | tr -d '\r' | awk '{print $2}' | tail -1)
[[ "$UXF" == 1 ]] || rbx "/umwelt ohne X-Umwelt-Flach: 1 (gelesen: ${UXF:-fehlt}) - Stoersender-Platz nicht eingesetzt"
UCHK=$(python3 - "$W/umwelt.html" << 'MK_C53_UCHK'
import sys
h = open(sys.argv[1], encoding="utf-8", errors="replace").read()
keys = ['<div class="title">⚠️ DWD Warnungen</div>', '<div class="title">🌤 Wetter Kalchreuth (90562)</div>', '<div class="title">🔥 DWD WBI · Waldbrand</div>',
        '<div id="sdrnHost"></div>', '<div class="title">☢️ Strahlung (ODL) · Umgebung</div>', '<div class="title">☀ Sonnenaktivität</div>']
n = [h.count(k) for k in keys]
if n != [1] * 6:
    print("FEHLER_Anzahl", "/".join(map(str, n)))
    sys.exit(0)
i = [h.index(k) for k in keys]
g = h.count('<div class="grid" id="umwGrid">')
ok = i == sorted(i) and g == 1 and "umwSdrnSlot" not in h and h.count('id="uf-css"') == 1 and h.count("/* umweltFlach */") == 2 and "Verlauf:" not in h
print("OK" if ok else "FEHLER_Aufbau", g)
MK_C53_UCHK
)
[[ "$UCHK" == "OK 1" ]] || rbx "/umwelt Aufbau nicht wie erwartet ($UCHK)"
echo "OK /umwelt: X-Umwelt-Flach 1, Reihenfolge DWD, Wetter, Waldbrand, Stoersender/Gewitter, ODL, Sonne; ein Raster, Skripte umgebaut"
EVJ=$("${CURL[@]}" "$B/api/sdr/noise?evl=1" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("OK" if isinstance(d.get("evl"), dict) and "noise" in d else "FEHLER")' 2>/dev/null || echo FEHLER)
[[ "$EVJ" == OK ]] || rbx "/api/sdr/noise?evl=1 liefert keine Ereignisse mit"
echo "OK /api/sdr/noise?evl=1 liefert Messwerte und Ereignisse in einem Abruf"
read -r BR_S1 BR_H1 BR_G1 <<< "$(brst)"
T4L1=$(t4lv)
[[ "$BR_S1" != FEHLER && "$T4L1" != FEHLER ]] || rbx "/api/br24 oder /api/t4/status nicht lesbar ($BR_S1 / $T4L1)"
echo "OK Zustand nachher: BR24 $BR_S1 (vorher $BR_S0; Halt bis Bestaetigung: $BR_H1, Hinweis: $BR_G1), Lage-Ampel $T4L1 (vorher $T4L0)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep umweltFlach"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "umweltFlach aktiv: umweltFlach ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'umweltFlach aktiv: umweltFlach ok' ($(echo "$JD" | grep -F umweltFlach | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok' 'audioKern aktiv: audioKern ok' 'audioUi aktiv: audioUi ok' 'kartePop aktiv: kartePop ok' 'hbProblem aktiv: hbProblem ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'umweltFlach Selbsttest FEHLER|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'umweltFlach Selbsttest FEHLER|umweltFlach Seite:|umweltFlach Abruf:|teil4 FEHLER|audioUi /pi:|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|hbProblem Selbsttest FEHLER|kartePop Selbsttest FEHLER|audioUi Selbsttest FEHLER|audioKern Selbsttest FEHLER|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:|evLog:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein umweltFlach-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
  echo "$JD" | grep -E '^umweltFlach|^pagesSplit3 aktiv' | tail -3 | cut -c1-200 | sed 's/^/  Journal: /' || true
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)"); prepper-sdr laeuft unveraendert weiter"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"), darunter prepper_sdr.py)" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern audioUi kartePop hbProblem umweltFlach; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Mesh-Regeln (echte Alarme 6 h Dublettenschutz, max 3/h), Gain-Waechter (Stufe 16), prepper_sdr.py und alle Dienste ausser prepper-dashboard unberuehrt"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen; lage_pages.py sha16 $(s16 "$FL"), $(wc -l < "$FL") Zeilen"
echo "  /umwelt: DWD, Wetter, Waldbrand, Stoersender, Gewitter, ODL, Sonne; eine Rahmenebene; Erklaerungen hinter i; Ereignisse 5 + mehr; ein Abruf alle 120 s nur bei sichtbarem Tab"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1); LBL=$({ ls -1t "$FL.bak-$NM-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" && -n "$LBL" ]] && echo "Rueckweg (beide Dateien zusammen): cp -a $LB $F && cp -a $LBL $FL && sudo systemctl restart prepper-dashboard" || echo "Rueckweg: keine $NM-Sicherung vorhanden (Dateien nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c umweltFlach /home/fmg/prepper-dashboard/dashboard.py"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep umweltFlach"
echo "  curl -sI http://127.0.0.1:5000/umwelt | grep -i umwelt"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Beim Einspielen nichts gesendet (kein Mesh, kein Telegram, keine Alarme), keine Einstellung und keine Datenbank geaendert. Neue Docs-Version: bewusst nicht."
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
