#!/bin/bash
# diag-welle: NUR LESEN. Wartet bis 6 min auf eine laufende DAB-Pruefung (welle-cli-Prozess), liest dann mux.json ueber
# prepper_sdr_net.fetch_welle (gleicher Weg wie prepper-sdr) 3x im Abstand von 5 s und zeigt Demodulator-Teil, passende Schluessel,
# oberste Schluessel, welle-Version (Paket + mux.json), Kommandozeile. Aendert nichts, startet nichts neu, startet kein welle-cli, kein Mesh.
set -u
DASH_DIR="/home/fmg/prepper-dashboard"
WAIT_S="${WAIT_S:-360}"
OUT="/tmp/diag-welle-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1
echo "=== diag-welle $(date) (nur lesen) ==="
echo "--- welle-Paket / Binaer"
dpkg-query -W -f='${Package} ${Version}\n' welle.io welle-cli 2>/dev/null || echo "  (kein dpkg-Eintrag welle.io/welle-cli)"
WB=$(command -v welle-cli 2>/dev/null || true); echo "  welle-cli im PATH: ${WB:-keiner} -> $( [[ -n "$WB" ]] && readlink -f "$WB")"
python3 -c "import json,sys;c=json.load(open(sys.argv[1]));print('  sdr_config: welle =',c.get('welle'),', dab_port =',c.get('dab_port'),', dab_tcp_port =',c.get('dab_tcp_port'),', gain_dab =',c.get('gain_dab'),', dab_s =',c.get('dab_s'))" "$DASH_DIR/sdr_config.json" 2>/dev/null || echo "  sdr_config.json nicht lesbar"
python3 -c "import json,sys;print('  broadcast_state welle_caps =',json.dumps(json.load(open(sys.argv[1])).get('welle_caps'))[:300])" "$DASH_DIR/broadcast_state.json" 2>/dev/null || true
echo "--- warte auf laufendes welle-cli (max $WAIT_S s, mind. 6 s alt) ..."
t=0; PIDS=""
while [[ "$t" -le "$WAIT_S" ]]; do
  PIDS=$(ps -eo pid=,etimes=,args= | awk '$2 >= 6 && / -w [0-9]+/ && ($3 ~ /welle-cli$/ || $4 ~ /welle-cli$/) {print $1}')
  [[ -n "$PIDS" ]] && break
  sleep 3; t=$((t + 3))
  [[ $((t % 60)) == 0 ]] && echo "  ... $t s, aktiv laut Status: $(python3 -c "import json;d=json.load(open('$DASH_DIR/sdr_status.json'));print(d.get('active'), (d.get('s2') or {}).get('active') if isinstance(d.get('s2'),dict) else '')" 2>/dev/null)"
done
[[ -n "$PIDS" ]] || { echo "Kein welle-cli innerhalb $WAIT_S s - nochmal starten, wenn der Rundfunk-Block laeuft. Ausgabe: $OUT"; exit 1; }
echo "--- Prozesse (welle-cli und Zubringer)"
PORTS=""
for p in $PIDS; do
  echo "  PID $p, laeuft $(ps -o etimes= -p "$p" | tr -d ' ') s: $(tr '\0' ' ' < /proc/$p/cmdline)"
  PORTS="$PORTS $(tr '\0' '\n' < /proc/$p/cmdline | awk 'f {print; f=0} $0 == "-w" {f=1}')"
done
ps -eo pid=,etimes=,args= | awk '$3 ~ /rtl_tcp|rtl_sdr/' | sed 's/^/  /'
echo "  welle-Webports aus Kommandozeile:$PORTS"
cd "$DASH_DIR" || exit 1
python3 - $PORTS << 'PY'
import json, re, sys, time
sys.path.insert(0, ".")
import prepper_sdr_net
cfg = {}
try:
    cfg = json.load(open("sdr_config.json"))
except Exception:
    pass
ports = []
for x in sys.argv[1:] + [str(cfg.get("dab_port") or 7979)]:
    if x.isdigit() and int(x) not in ports:
        ports.append(int(x))
pat = re.compile(r"snr|fic|crc|error|fct|frequency", re.I)


def walk(o, path, out):
    if isinstance(o, dict):
        for k, v in o.items():
            q = path + "." + str(k) if path else str(k)
            if pat.search(str(k)) and not isinstance(v, (dict, list)):
                out.append("%s = %r" % (q, v))
            elif pat.search(str(k)) and isinstance(v, dict) and len(json.dumps(v)) < 300:
                out.append("%s = %s" % (q, json.dumps(v)))
            walk(v, q, out)
    elif isinstance(o, list):
        for i, v in enumerate(o[:40]):
            walk(v, "%s[%d]" % (path, i), out)


for port in ports:
    print("=== Port %d (prepper_sdr_net.fetch_welle) ===" % port)
    for n in range(3):
        t = time.time()
        try:
            m = prepper_sdr_net.fetch_welle(port)
        except Exception as e:
            print("  Probe %d: fetch_welle Fehler: %s: %s" % (n + 1, type(e).__name__, str(e)[:300]))
            time.sleep(5)
            continue
        print("--- Probe %d  %s  Typ %s" % (n + 1, time.strftime("%H:%M:%S"), type(m).__name__))
        if not isinstance(m, dict):
            print("  kein Objekt:", repr(m)[:400])
            time.sleep(5)
            continue
        print("  oberste Schluessel:", sorted(m.keys()))
        sw = ((m.get("receiver") or {}).get("software") or {}) if isinstance(m.get("receiver"), dict) else {}
        hw = ((m.get("receiver") or {}).get("hardware") or {}) if isinstance(m.get("receiver"), dict) else {}
        print("  receiver.software:", json.dumps(sw)[:400])
        print("  receiver.hardware:", json.dumps(hw)[:300])
        ens = m.get("ensemble") if isinstance(m.get("ensemble"), dict) else {}
        print("  ensemble:", json.dumps({k: ens.get(k) for k in ("label", "id", "ecc")})[:200], " services:", len(m.get("services") or []))
        dm = m.get("demodulator")
        print("  demodulator (komplett):", json.dumps(dm)[:1500])
        if isinstance(dm, dict) and dm.get("time_last_fct0_frame"):
            print("  fct0 Alter: %.1f s" % (t - float(dm["time_last_fct0_frame"]) / 1000.0))
        out = []
        walk(m, "", out)
        print("  passende Schluessel (%d):" % len(out))
        for x in out[:80]:
            print("    " + x[:220])
        if n < 2:
            time.sleep(5)
PY
echo "=== fertig, nichts geaendert. Ausgabe gespeichert: $OUT ==="
