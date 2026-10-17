#!/bin/bash
# diag-stick1: NUR LESEN. Stick 1 (SN 19348831, Rolle bc) - warum seit 17.10 nachts kein DAB/RDS/BR24, und ist nach dem
# Neuanstecken + Neustart prepper-sdr wieder alles da? Prueft USB (sysfs), Kernel/Journal, Prozesse + Kommandozeilen,
# Index<->Seriennummer, Port 1235/7979, welle mux.json (nur HTTP-GET an 127.0.0.1), JSON-Zustaende, Dashboard-APIs (nur GET).
# Stoppt nichts, startet nichts neu, oeffnet keinen Stick (kein rtl_test/rtl_eeprom/lsusb -v), sendet nichts ins Mesh.
# Aufruf: bash /tmp/ds.sh [COMMIT]   Optional per Umgebung: WAIT_S (Standard 900), WIN_FROM, WIN_TO.
set -u
set +e
COMMIT="${1:-}"
DASH_DIR="${DASH_DIR:-/home/fmg/prepper-dashboard}"
SVC="prepper-sdr"
SN1="19348831"; ROLE1="bc"
SN2="72055505"; ROLE2="rot"
PORT_TCP=1235; PORT_WELLE=7979; PORT_DASH=5000
WAIT_S="${WAIT_S:-900}"
WIN_FROM="${WIN_FROM:-2026-10-17 02:45:00}"
WIN_TO="${WIN_TO:-2026-10-17 04:05:00}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="/tmp/diag-stick1-$TS.txt"
WRK="$(mktemp -d /tmp/diag-stick1-XXXXXX 2>/dev/null || echo /tmp/diag-stick1-w$$)"
mkdir -p "$WRK" 2>/dev/null
FACTS="$WRK/facts"; : > "$FACTS"
exec > >(tee "$OUT") 2>&1
fact() { echo "$1=$2" >> "$FACTS"; }
have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || { echo "  $1: nicht installiert"; return 1; }; }
sec() { echo; echo "=== $* ==="; }
PY=python3; have python3 || PY=""

echo "=== diag-stick1 $(date '+%d.%m.%Y %H:%M:%S %Z') - nur lesen, sendet nichts ${COMMIT:+(Commit $COMMIT)} ==="

# ---------- sudo nur zum Lesen von Journal/Kernel/fremden Prozessen
SUDO=""
if have journalctl; then
  if [[ -z "$(journalctl -k -b -n 1 -q --no-pager 2>/dev/null)" ]] && have sudo; then
    echo "Hinweis: Kernel-Journal braucht sudo (nur lesen). Passwort jetzt, oder Strg-C bricht ab (aendert nichts)."
    if sudo -v; then SUDO="sudo"; else echo "  sudo nicht moeglich - Journal/Kernel ggf. unvollstaendig"; fi
  fi
fi
J() { $SUDO journalctl --no-pager -q "$@" 2>/dev/null; }

# ---------- 1 System
sec "1 System, Boot, Dienst"
echo "  uptime: $(uptime 2>/dev/null)"
echo "  letzter Boot: $(uptime -s 2>/dev/null || who -b 2>/dev/null)"
BOOT_E=$(date -d "$(uptime -s 2>/dev/null)" +%s 2>/dev/null || echo 0); fact boot_t "$BOOT_E"
if have journalctl; then echo "  Boots im Journal (letzte 5):"; J --list-boots | tail -n 5 | sed 's/^/    /'; fi
SVC_ACTIVE="unbekannt"; SVC_START=0
if have systemctl; then
  SVC_ACTIVE=$(systemctl is-active "$SVC" 2>/dev/null); [[ -n "$SVC_ACTIVE" ]] || SVC_ACTIVE="unbekannt"
  ST_TXT=$(systemctl show "$SVC" -p ActiveEnterTimestamp --value 2>/dev/null)
  SVC_START=$(date -d "$ST_TXT" +%s 2>/dev/null || echo 0)
  echo "  $SVC: $SVC_ACTIVE, aktiv seit $ST_TXT, MainPID $(systemctl show "$SVC" -p MainPID --value 2>/dev/null), Neustarts (NRestarts) $(systemctl show "$SVC" -p NRestarts --value 2>/dev/null)"
else
  echo "  systemctl: nicht installiert"
fi
fact svc_active "$SVC_ACTIVE"; fact svc_start "$SVC_START"
if have vcgencmd; then
  THR=$(vcgencmd get_throttled 2>/dev/null); echo "  Stromversorgung: $THR (0x0 = gut; Bit 0 jetzt Unterspannung, Bit 16 seit Boot Unterspannung)"
  fact throttled "${THR#*=}"
else
  echo "  vcgencmd: nicht installiert"
fi

# ---------- 2 USB (nur sysfs, kein Oeffnen des Sticks)
sec "2 USB-Sticks laut sysfs (Realtek 0bda:2838)"
: > "$WRK/usb"
for d in "${SYSUSB:-/sys/bus/usb/devices}"/*; do
  [[ -f "$d/idVendor" ]] || continue
  v=$(cat "$d/idVendor" 2>/dev/null); p=$(cat "$d/idProduct" 2>/dev/null)
  [[ "$v" == "0bda" && ( "$p" == "2838" || "$p" == "2832" ) ]] || continue
  bn=$(cat "$d/busnum" 2>/dev/null); dn=$(cat "$d/devnum" 2>/dev/null); sn=$(cat "$d/serial" 2>/dev/null)
  sp=$(cat "$d/speed" 2>/dev/null); pr=$(cat "$d/product" 2>/dev/null); au=$(cat "$d/authorized" 2>/dev/null)
  mp=$(cat "$d/bMaxPower" 2>/dev/null)
  printf '%03d %03d %s %s %s %s\n' "$((10#${bn:-0}))" "$((10#${dn:-0}))" "${sn:--}" "$(basename "$d")" "${sp:--}" "${au:--}" >> "$WRK/usb"
  echo "  Bus ${bn} Geraet ${dn} Pfad $(basename "$d") SN ${sn:--} '${pr:-?}' ${sp:-?} Mbit/s, authorized ${au:-?}, ${mp:-?}"
done
NUSB=$(wc -l < "$WRK/usb" 2>/dev/null); echo "  Anzahl RTL-Sticks: ${NUSB:-0}"
for s in "$SN1" "$SN2"; do
  n=$(awk -v s="$s" '$3==s' "$WRK/usb" | wc -l)
  echo "  SN $s: ${n}x vorhanden"; fact "usb_$s" "$n"
done
if have lsusb; then echo "  lsusb (kurz):"; lsusb 2>/dev/null | awk 'tolower($0) ~ /0bda:283|realtek|rtl/' | sed 's/^/    /'; else echo "  lsusb: nicht installiert"; fi
# vermutete librtlsdr-Reihenfolge (libusb zaehlt nach Bus/Geraet) - nur Hinweis, Beweis kommt aus /proc/PID/fd
sort "$WRK/usb" > "$WRK/usb.sorted"
echo "  vermutete Index-Reihenfolge (Bus/Geraet aufsteigend, ohne Gewaehr):"
awk '{printf "    Index %d -> SN %s (Bus %s Geraet %s)\n", NR-1, $3, $1, $2}' "$WRK/usb.sorted"

# ---------- 3 Kernel seit Boot
sec "3 Kernel seit Boot: USB/RTL/Strom/OOM"
KPAT='usb.*(disconnect|error|reset|fail|over-current|not accepting|unable)|rtl2832|rtl28|dvb|r820t|under-voltage|undervoltage|voltage normalised|oom|out of memory|killed process|xhci|dwc'
if have journalctl; then
  J -k -b -o short-iso | grep -iE "$KPAT" > "$WRK/kboot"
  echo "  Treffer seit Boot: $(wc -l < "$WRK/kboot")  (letzte 40)"
  tail -n 40 "$WRK/kboot" | sed 's/^/    /'
  J -k -b -o short-iso | grep -iE 'SerialNumber: ('"$SN1|$SN2"')' > "$WRK/kplug"
  echo "  USB-Anmeldungen der Sticks seit Boot (Neuanstecken):"
  tail -n 8 "$WRK/kplug" | sed 's/^/    /'
  for s in "$SN1" "$SN2"; do
    lt=$(grep "SerialNumber: $s" "$WRK/kplug" | tail -n 1 | awk '{print $1}')
    le=$(date -d "$lt" +%s 2>/dev/null || echo 0); fact "plug_$s" "$le"
  done
  if [[ "$SVC_START" -gt 0 ]]; then
    awk -v s="$(date -d @"$SVC_START" '+%Y-%m-%dT%H:%M:%S')" 'substr($1,1,19) >= s' "$WRK/kboot" | grep -iE 'disconnect|error|reset|fail|voltage|oom' > "$WRK/ksince"
    echo "  USB-/Strom-Fehler seit Dienststart: $(wc -l < "$WRK/ksince")"; tail -n 10 "$WRK/ksince" | sed 's/^/    /'
    fact kerr_since "$(wc -l < "$WRK/ksince")"
  fi
elif have dmesg; then
  $SUDO dmesg -T 2>/dev/null | grep -iE "$KPAT" | tail -n 40 | sed 's/^/    /'
else
  echo "  journalctl/dmesg: nicht installiert"
fi

# ---------- 4 Zeitfenster der Nacht
sec "4 Zeitfenster $WIN_FROM bis $WIN_TO (Ausfall nachts)"
if have journalctl; then
  echo "  --- Kernel im Fenster (alles, max 80 Zeilen)"
  J -k -o short-iso --since "$WIN_FROM" --until "$WIN_TO" | tail -n 80 | sed 's/^/    /'
  echo "  --- $SVC im Fenster (max 200 Zeilen)"
  J -u "$SVC" -o short-iso --since "$WIN_FROM" --until "$WIN_TO" | tail -n 200 | sed 's/^/    /'
  echo "  --- System im Fenster: Neustarts, Timer, apt, OOM, Strom (max 60)"
  J -o short-iso --since "$WIN_FROM" --until "$WIN_TO" | grep -iE 'Started|Stopped|Stopping|Starting|Deactivated|Main process exited|apt|dpkg|unattended|upgrade|oom|killed|voltage|usb|rtl|watchdog|prepper' | tail -n 60 | sed 's/^/    /'
fi
echo "  --- Paket-Aenderungen 17.10 (dpkg.log/apt history)"
grep -h '^2026-10-1[67]' /var/log/dpkg.log 2>/dev/null | grep -E ' (upgrade|install|remove) ' | tail -n 30 | sed 's/^/    /'
grep -h -A4 'Start-Date: 2026-10-1[67]' /var/log/apt/history.log 2>/dev/null | tail -n 30 | cut -c1-300 | sed 's/^/    /'
[[ -r /var/log/dpkg.log ]] || echo "    /var/log/dpkg.log nicht lesbar"

# ---------- 5/6 Prozesse, Ports, Index-Beweis
show_procs() {
  ps -eo pid=,user=,etimes=,args= 2>/dev/null | awk '{c=$4; sub(".*/","",c)} c ~ /^(rtl_tcp|rtl_fm|rtl_433|rtl_power|rtl_sdr|welle-cli|redsea|direwolf|satdump)$/' > "$WRK/procs"
  if [[ ! -s "$WRK/procs" ]]; then echo "  (keine Funk-Prozesse gerade aktiv)"; return; fi
  while read -r pid usr et rest; do
    dv=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk 'f{print;f=0} $0=="-d"{f=1}' | head -n 1)
    usb=$($SUDO ls -l "/proc/$pid/fd" 2>/dev/null | grep -o '/dev/bus/usb/[0-9]*/[0-9]*' | sort -u | head -n 2 | tr '\n' ' ')
    snx="-"
    for u in $usb; do
      b=$(echo "$u" | cut -d/ -f5); g=$(echo "$u" | cut -d/ -f6)
      x=$(awk -v b="$b" -v g="$g" '$1==b && $2==g {print $3}' "$WRK/usb"); [[ -n "$x" ]] && snx="$x"
    done
    c=$(echo "$rest" | awk '{print $1}'); c=${c##*/}
    echo "  PID $pid ($usr, $et s) -d ${dv:--} -> USB ${usb:-?(kein Zugriff/kein Geraet)} -> SN $snx"
    echo "      $rest"
    [[ -n "$dv" && "$snx" != "-" ]] && echo "$c $dv $snx" >> "$WRK/idxmap"
    [[ "$c" == "rtl_tcp" ]] && echo "$dv $snx $et" >> "$WRK/rtltcp_seen"
    [[ "$c" == "welle-cli" ]] && echo "$et" >> "$WRK/welle_seen"
  done < "$WRK/procs"
}
show_ports() {
  if have ss; then
    $SUDO ss -ltnp 2>/dev/null | awk -v a=":$PORT_TCP" -v b=":$PORT_WELLE" -v c=":$PORT_DASH" 'NR==1 || index($4,a) || index($4,b) || index($4,c)' | sed 's/^/  /'
  else
    echo "  ss: nicht installiert (Fallback /proc/net/tcp)"
  fi
  for pt in "$PORT_TCP" "$PORT_WELLE"; do
    h=$(printf ':%04X' "$pt")
    if awk -v h="$h" '$2 ~ h"$" && $4=="0A"{f=1} END{exit !f}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then echo "  Port $pt lauscht"; echo "$pt" >> "$WRK/port_seen"; else echo "  Port $pt lauscht nicht"; fi
  done
}
: > "$WRK/idxmap"; : > "$WRK/rtltcp_seen"; : > "$WRK/welle_seen"; : > "$WRK/port_seen"
sec "5 Funk-Prozesse jetzt (volle Kommandozeile, -d Index, offenes USB-Geraet)"
show_procs
sec "6 Ports $PORT_TCP (rtl_tcp), $PORT_WELLE (welle), $PORT_DASH (Dashboard)"
show_ports

# ---------- 7 mux.json (nur GET an welle auf 127.0.0.1)
mux_once() {
  have curl || { echo "  curl: nicht installiert"; return; }
  curl -s -m 4 "http://127.0.0.1:$PORT_WELLE/mux.json" -o "$WRK/mux.json" 2>/dev/null || { echo "  mux.json: welle-Web nicht erreichbar"; return; }
  [[ -n "$PY" ]] || { echo "  python3: nicht installiert"; return; }
  $PY - "$WRK/mux.json" "$WRK/mux_log" << 'PY'
import json, sys, time
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    print("  mux.json unlesbar: %s" % e); sys.exit(0)
dm = m.get("demodulator") or {}
rc = m.get("receiver") or {}
hw, sw = rc.get("hardware") or {}, rc.get("software") or {}
en = m.get("ensemble") or {}
lab = en.get("label")
lab = lab.get("label") if isinstance(lab, dict) else lab
sv = m.get("services") or []
names = []
for s in sv[:12]:
    l = s.get("label")
    names.append((l.get("label") if isinstance(l, dict) else l) or "?")
fct = dm.get("time_last_fct0_frame")
age = ("%.0f s" % (time.time() - float(fct) / 1000.0)) if fct else "nie"
fic = dm.get("fic") or {}
line = "  %s mux.json: Kanal %s, SNR %s, Gain %s dB, FIC-CRC-Fehler %s, letzter Rahmen %s, Ensemble %s '%s', Dienste %d %s" % (
    time.strftime("%H:%M:%S"), (sw.get("lastchannelchange") or {}).get("channel") if isinstance(sw.get("lastchannelchange"), dict) else sw.get("channel"),
    dm.get("snr"), hw.get("gain"), fic.get("numcrcerrors"), age, en.get("id"), (lab or "").strip(), len(sv), ", ".join(n.strip() for n in names))
print(line)
open(sys.argv[2], "a").write("%s %s %s %d\n" % (en.get("id"), dm.get("snr"), hw.get("gain"), len(sv)))
PY
}
sec "7 welle mux.json jetzt"
: > "$WRK/mux_log"
if [[ -s "$WRK/welle_seen" ]]; then mux_once; else echo "  welle-cli laeuft gerade nicht (nur waehrend Rundfunk-Block) - wird im Warteteil geholt"; fi

# ---------- 8 Frische seit Dienststart pruefen (Python-Helfer, nur lesen)
cat > "$WRK/fresh.py" << 'PY'
import json, sys, time
base, t0, mode = sys.argv[1], float(sys.argv[2] or 0), sys.argv[3]
def ld(n):
    try:
        return json.load(open(base + "/" + n, encoding="utf-8"))
    except Exception:
        return {}
b = ld("broadcast_state.json")
dab = b.get("dab") or {}
fm = b.get("fm") or {}
ok_dab = {}
chk = {}
for ch in ("11D", "5C"):
    e = dab.get(ch) or {}
    g = e.get("demod") or {}
    chk[ch] = (g.get("t") or 0) >= t0 or (e.get("try_t") or 0) >= t0 or ((e.get("t") or 0) >= t0)
    ok_dab[ch] = e.get("rx") is not False and (g.get("t") or e.get("t") or 0) >= t0 and bool(e.get("services")) and str(g.get("ens_id") or "") != "0x0000"
fm_ok = {n: (s.get("t") or 0) >= t0 for n, s in fm.items()}
if mode == "ready":
    sys.exit(0 if all(chk.values()) else 2)
print("dab_chk=%s" % ",".join("%s:%d" % (k, v) for k, v in chk.items()))
print("dab_ok=%s" % ",".join("%s:%d" % (k, v) for k, v in ok_dab.items()))
print("rds_ok=%d" % (1 if any(fm_ok.values()) else 0))
print("br24_fm_ok=%d" % (1 if fm_ok.get("BR24") else 0))
br24_dab = any(((s.get("label") or "").strip().upper() == "BR24") for s in (dab.get("11D") or {}).get("services") or []) and ok_dab.get("11D")
print("br24_dab_ok=%d" % (1 if br24_dab else 0))
PY

sec "8 Warten auf Rundfunk-Pruefung seit Dienststart (max $WAIT_S s; Strg-C springt sicher zur Zusammenfassung)"
STOP=0; trap 'STOP=1' INT
if [[ "$SVC_START" -le 0 || -z "$PY" ]]; then
  echo "  Dienststart unbekannt oder python3 fehlt - kein Warten"
elif $PY "$WRK/fresh.py" "$DASH_DIR" "$SVC_START" ready; then
  echo "  DAB 11D und 5C wurden seit Dienststart schon geprueft - kein Warten noetig"
else
  t=0; mux_n=0
  while [[ "$t" -lt "$WAIT_S" && "$STOP" == 0 ]]; do
    if [[ "$mux_n" -lt 6 ]] && ps -eo etimes=,args= 2>/dev/null | awk '$1>=8 && $2 ~ /welle-cli$/ {f=1} END{exit !f}'; then
      if [[ ! -s "$WRK/welle_seen" ]]; then echo "  --- welle-cli laeuft, Momentaufnahme:"; show_procs; show_ports; fi
      echo "1" >> "$WRK/welle_seen"; mux_once; mux_n=$((mux_n + 1))
    fi
    if ps -eo args= 2>/dev/null | awk '{c=$1; sub(".*/","",c)} c=="rtl_tcp"{f=1} END{exit !f}'; then
      if [[ ! -s "$WRK/rtltcp_seen" ]]; then show_procs >/dev/null; fi
      awk -v h="$(printf ':%04X' "$PORT_TCP")" '$2 ~ h"$" && $4=="0A"{f=1} END{exit !f}' /proc/net/tcp /proc/net/tcp6 2>/dev/null && echo "$PORT_TCP" >> "$WRK/port_seen"
      [[ -s "$WRK/rtltcp_seen" ]] || echo "? - 0" >> "$WRK/rtltcp_seen"
    fi
    if $PY "$WRK/fresh.py" "$DASH_DIR" "$SVC_START" ready; then echo "  DAB-Pruefung seit Dienststart liegt vor (nach $t s)"; break; fi
    sleep 5; t=$((t + 5))
    [[ $((t % 60)) == 0 ]] && echo "  ... $t s ($(date +%H:%M:%S))"
  done
  [[ "$STOP" == 1 ]] && echo "  Warten per Strg-C beendet - nichts geaendert"
  [[ "$t" -ge "$WAIT_S" ]] && echo "  keine vollstaendige DAB-Pruefung in $WAIT_S s"
fi
trap - INT
if have journalctl && [[ "$SVC_START" -gt 0 ]]; then
  J -u "$SVC" -o short-iso --since "@$SVC_START" > "$WRK/jsince"
  echo "  Journal $SVC seit Dienststart: $(wc -l < "$WRK/jsince") Zeilen; DAB-Starts $(grep -c 'Start dab:' "$WRK/jsince"); RDS-Starts $(grep -c 'Start rds:' "$WRK/jsince")"
  grep -iE 'rtl_tcp beendet|lauscht nach|usb_claim|Stick nicht aufgeloest|Stick-Liste|Traceback|Error|Fehler' "$WRK/jsince" | tail -n 15 | sed 's/^/    /'
  fact j_dabstart "$(grep -c 'Start dab:' "$WRK/jsince")"
  fact j_tcperr "$(grep -ciE 'rtl_tcp beendet|lauscht nach|usb_claim|Stick nicht aufgeloest|Stick-Liste' "$WRK/jsince")"
fi
fact waited_rtltcp "$( [[ -s "$WRK/rtltcp_seen" ]] && echo 1 || echo 0)"
fact waited_welle "$( [[ -s "$WRK/welle_seen" ]] && echo 1 || echo 0)"
fact port_tcp_seen "$(grep -c "^$PORT_TCP$" "$WRK/port_seen" 2>/dev/null)"
[[ -n "$PY" ]] && $PY "$WRK/fresh.py" "$DASH_DIR" "$SVC_START" facts >> "$FACTS"

# ---------- 9 Zustaende + APIs
sec "9 Zustaende (JSON) und Dashboard-APIs (nur GET)"
if have curl; then
  curl -s -m 8 "http://127.0.0.1:$PORT_DASH/api/br24" -o "$WRK/br24.json" 2>/dev/null || echo "  /api/br24 nicht erreichbar"
  curl -s -m 8 "http://127.0.0.1:$PORT_DASH/api/sdr/live" -o "$WRK/live.json" 2>/dev/null || echo "  /api/sdr/live nicht erreichbar"
else
  echo "  curl: nicht installiert"
fi
if [[ -n "$PY" ]]; then
$PY - "$DASH_DIR" "$WRK" "$SVC_START" "$SN1" "$SN2" "$ROLE1" "$ROLE2" << 'PY'
import json, os, sys, time
base, wrk, t0 = sys.argv[1], sys.argv[2], float(sys.argv[3] or 0)
SN1, SN2, R1, R2 = sys.argv[4:8]
now = time.time()
def ld(f):
    try:
        return json.load(open(f, encoding="utf-8"))
    except Exception:
        return {}
def ts(t):
    try:
        return time.strftime("%d.%m. %H:%M:%S", time.localtime(float(t))) if t else "nie"
    except Exception:
        return str(t)
def age(t):
    try:
        return "%d s" % (now - float(t)) if t else "-"
    except Exception:
        return "-"
st, b, c = ld(base + "/sdr_status.json"), ld(base + "/broadcast_state.json"), ld(base + "/sdr_config.json")
facts = open(wrk + "/facts", "a")
print("  sdr_status.json: geschrieben %s (Alter %s), Prozess-Start %s, aktiv %s seit %s, Rolle %s, SN %s, Index %s, Sticks %s" % (
    ts(st.get("t")), age(st.get("t")), ts(st.get("started")), st.get("active"), ts(st.get("since")), st.get("role"), st.get("sn") or st.get("serial"), st.get("stick_idx"), st.get("sticks_n")))
print("    Fehler: err %s (%s), pin_err %s, fails %s, Zaehler %s" % (st.get("err"), ts(st.get("err_t")), st.get("pin_err"), st.get("fails"), st.get("counts")))
print("    Stick 1 Zustand: %s" % json.dumps(st.get("stick_health"), ensure_ascii=False)[:300])
print("    Stick 1 letzte Meldungen: %s" % " | ".join(str(x)[:140] for x in (st.get("stderr") or [])) or "-")
s2 = st.get("s2") if isinstance(st.get("s2"), dict) else {}
print("    Stick 2: Rolle %s, SN %s, Index %s, aktiv %s, Zustand %s, Meldungen %s" % (s2.get("role"), s2.get("sn"), s2.get("stick_idx"), s2.get("active"),
      (s2.get("stick_health") or {}).get("txt"), " | ".join(str(x)[:100] for x in (s2.get("stderr") or [])[-3:]) or "-"))
print("    Kalibrierung/ppm: %s, sdr_config ppm %s" % (json.dumps(st.get("cal"), ensure_ascii=False), c.get("ppm")))
nz = st.get("noise") if isinstance(st.get("noise"), dict) else {}
bd = {x.get("id"): x for x in nz.get("bands") or [] if isinstance(x, dict)}
d = bd.get("dab") or {}
print("    Stoerer-Messung DAB: Stufe %s, bekannte Traeger %s, Zeit %s, Stick %s" % (d.get("lvl"), d.get("n_bc"), ts(d.get("t")), nz.get("sn") or d.get("sn")))
facts.write("noise_dab_known=%s\n" % (d.get("n_bc") or 0))
# Zuordnung
sn1 = str(st.get("sn") or st.get("serial") or ""); sn2 = str(s2.get("sn") or "")
i1, i2 = st.get("stick_idx"), s2.get("stick_idx")
okmap = sn1 == SN1 and st.get("role") == R1 and sn2 == SN2 and s2.get("role") == R2 and i1 is not None and i2 is not None and i1 != i2
order = [l.split()[2] for l in open(wrk + "/usb.sorted").read().splitlines() if l.strip()] if os.path.exists(wrk + "/usb.sorted") else []
guess = {SN1: order.index(SN1) if SN1 in order else None, SN2: order.index(SN2) if SN2 in order else None}
proof = [l.split() for l in open(wrk + "/idxmap").read().splitlines() if l.strip()] if os.path.exists(wrk + "/idxmap") else []
bad = [p for p in proof if (p[2] == SN1 and str(p[1]) != str(i1)) or (p[2] == SN2 and str(p[1]) != str(i2))]
seen = sorted(set("%s -d %s = SN %s" % tuple(p) for p in proof))
print("  Zuordnung laut prepper-sdr: SN %s Rolle %s Index %s | SN %s Rolle %s Index %s -> %s" % (sn1, st.get("role"), i1, sn2, s2.get("role"), i2, "passt" if okmap else "PASST NICHT"))
print("    sysfs-Reihenfolge (Vermutung): %s" % guess)
print("    Beweis ueber offene USB-Geraete: %s" % ("; ".join(seen) if seen else "kein Prozess mit -d gesehen"))
facts.write("map_ok=%d\nmap_proof_bad=%d\nmap_proof_n=%d\n" % (1 if okmap else 0, len(bad), len(proof)))
facts.write("map_guess_ok=%d\n" % (1 if (guess[SN1] is None or i1 is None or guess[SN1] == i1) else 0))
facts.write("st_age=%d\nst_started=%d\n" % (now - float(st.get("t") or 0), float(st.get("started") or 0)))
# dabgain + DAB
print("  Gain-Leiter (dabgain): %s" % json.dumps(b.get("dabgain"), ensure_ascii=False)[:500])
for ch in ("11D", "5C"):
    e = (b.get("dab") or {}).get(ch) or {}
    g = e.get("demod") or {}
    print("  DAB %s: rx %s (%s), Ensemble '%s', Dienste %d %s, Pruefung %s (%s nach Dienststart), SNR %s, FIC-Rate %s, welle-Gain %s, Stufe %s (%s dB), Ens-ID %s, letzter Empfang %s" % (
        ch, e.get("rx"), e.get("rx_why") or "-", e.get("ensemble"), len(e.get("services") or []), ",".join((s.get("label") or "?").strip() for s in (e.get("services") or [])[:6]),
        ts(g.get("t") or e.get("t")), "ja" if (g.get("t") or e.get("t") or 0) >= t0 else "nein", g.get("snr"), g.get("fic_rate"), g.get("hw_gain"), g.get("gain_idx"), g.get("gain_db"),
        g.get("ens_id"), ts(e.get("last_ok_t") or (e.get("t") if e.get("rx") is not False else None))))
# RDS
for n, s in sorted((b.get("fm") or {}).items(), key=lambda kv: -(kv[1].get("t") or 0)):
    print("  RDS %s %s: zuletzt %s (Alter %s, %s nach Dienststart), Gruppen %s, PI %s, PS '%s', PTY %s, TA %s, RT '%s'" % (
        n, s.get("f"), ts(s.get("t")), age(s.get("t")), "ja" if (s.get("t") or 0) >= t0 else "nein", s.get("groups"), s.get("pi"), s.get("ps"), s.get("pty"), s.get("ta"), (s.get("rt") or "")[:60]))
rt_last = max([s.get("t") or 0 for s in (b.get("fm") or {}).values()] or [0])
facts.write("rds_last=%d\n" % rt_last)
# dabhist
dh = ld(base + "/sdr_dabhist.json")
ev = dh.get("ev") if isinstance(dh.get("ev"), list) else []
for ch in ("11D", "5C"):
    xs = [e.get("last") or e.get("t") or 0 for e in ev if e.get("ch") == ch]
    m = max(xs) if xs else 0
    print("  /dabhist %s: %d Eintraege, letzter %s (%s nach Dienststart)" % (ch, len(xs), ts(m), "ja" if m >= t0 else "nein"))
    facts.write("dabhist_%s=%d\n" % (ch, m))
br = ld(wrk + "/br24.json")
if br:
    print("  /api/br24: %s | br24_row %s / %s | asa_row %s / %s" % (br.get("text"), (br.get("br24_row") or {}).get("l1"), (br.get("br24_row") or {}).get("l2"),
          (br.get("asa_row") or {}).get("l1"), (br.get("asa_row") or {}).get("l2")))
    txt = " ".join(str(x) for x in (br.get("text"), (br.get("br24_row") or {}).get("l1")))
    facts.write("br24_api_nok=%d\n" % (1 if "kein Empfang" in txt else 0))
lv = ld(wrk + "/live.json")
if lv:
    print("  /api/sdr/live: status %s, SDR1 %s, SDR2 %s (%s)" % (lv.get("status"), lv.get("sdr1_role"), lv.get("sdr2_role"), lv.get("sdr2_status")))
PY
fi

# ---------- 10 Zusammenfassung
sec "10 ZUSAMMENFASSUNG"
if [[ -n "$PY" ]]; then
$PY - "$FACTS" "$WRK" "$SN1" "$SN2" << 'PY'
import sys, time, os
F = {}
for l in open(sys.argv[1]).read().splitlines():
    if "=" in l:
        k, v = l.split("=", 1); F[k.strip()] = v.strip()
wrk, SN1, SN2 = sys.argv[2], sys.argv[3], sys.argv[4]
def i(k, d=0):
    try:
        return int(float(F.get(k, d)))
    except Exception:
        return d
def hm(t):
    return time.strftime("%d.%m. %H:%M", time.localtime(t)) if t else "?"
t0 = i("svc_start")
pairs = lambda k: dict(x.split(":") for x in F.get(k, "").split(",") if ":" in x)
chk, dok = pairs("dab_chk"), pairs("dab_ok")
lines, warn = [], []
plug = max(i("plug_" + SN1), i("plug_" + SN2))
print("  Dienst prepper-sdr: %s seit %s; Sticks zuletzt angemeldet (Kernel) %s" % (F.get("svc_active"), hm(t0), hm(plug)))
if plug and t0 and plug > t0:
    warn.append("Sticks wurden NACH dem Dienststart angesteckt - prepper-sdr danach neu starten, sonst stimmen die Indizes evtl. nicht")
if i("usb_" + SN1) < 1:
    kb = open(wrk + "/kboot").read().splitlines() if os.path.exists(wrk + "/kboot") else []
    dis = [l for l in kb if "disconnect" in l.lower()]
    v = "Stick 1 USB weg%s" % (" seit " + dis[-1].split()[0] if dis else "") + " (SN %s nicht im USB-Baum) -> Stecker/Hub/Strom pruefen" % SN1
elif i("usb_" + SN2) < 1:
    v = "Stick 2 (SN %s) fehlt im USB-Baum - Zuordnung nicht moeglich" % SN2
elif F.get("svc_active") != "active":
    v = "prepper-sdr laeuft nicht (%s)" % F.get("svc_active")
elif not i("map_ok") or i("map_proof_bad"):
    v = "Zuordnung FALSCH: Index/Seriennummer passt nicht (soll %s bc, %s rot) -> prepper-sdr neu starten" % (SN1, SN2)
elif not (chk.get("11D") == "1" and chk.get("5C") == "1"):
    v = "Noch keine DAB-Pruefung seit Dienststart %s - Skript nach dem naechsten Rundfunk-Block (ca. 2-5 min nach Start, dann alle 30 min) nochmal starten" % hm(t0)
elif dok.get("11D") == "1" and dok.get("5C") == "1" and i("rds_ok"):
    v = "ALLES WIEDER OK seit Neuanstecken/Neustart %s: DAB 11D + 5C mit Sync und Diensten, RDS frisch%s" % (hm(t0), ", BR24 empfangen" if (i("br24_fm_ok") or i("br24_dab_ok")) else ", BR24 aber noch nicht")
elif dok.get("11D") == "1" or dok.get("5C") == "1" or i("rds_ok"):
    v = "TEILWEISE wieder da seit %s: DAB 11D %s, DAB 5C %s, RDS %s" % (hm(t0), "ok" if dok.get("11D") == "1" else "KEIN SYNC", "ok" if dok.get("5C") == "1" else "KEIN SYNC", "frisch" if i("rds_ok") else "nichts")
elif i("j_tcperr"):
    v = "rtl_tcp laeuft nicht sauber: %d Fehler im Journal seit Dienststart (rtl_tcp beendet / Port lauscht nicht / Stick belegt) -> Abschnitt 8 Journal, USB Stick 1" % i("j_tcperr")
elif i("waited_rtltcp") and not i("port_tcp_seen"):
    v = "rtl_tcp gestartet, aber Port 1235 lauscht nicht -> Stick belegt oder USB-Fehler an Stick 1"
elif not i("waited_rtltcp") and "j_dabstart" in F and not i("j_dabstart"):
    v = "rtl_tcp/welle-cli seit Dienststart weder gesehen noch im Journal gestartet -> Planer startet keinen DAB-Block, Journal Abschnitt 8 ansehen"
else:
    v = "rtl_tcp laeuft, Port 1235 lauscht, aber kein Sync und kein RDS -> kein Signal: Antenne/Kabel/Stecker an Stick 1 (SN %s) pruefen" % SN1
    if i("noise_dab_known"):
        warn.append("Stoerer-Messung sieht %s bekannte DAB-Traeger - HF kommt an; dann eher Stick 1 selbst (Tuner/USB) als die Antenne" % F.get("noise_dab_known"))
print("  Zuordnung: %s (Beweis aus offenen USB-Geraeten: %s Prozesse%s)" % ("passt (19348831 bc, 72055505 rot)" if i("map_ok") and not i("map_proof_bad") else "PASST NICHT", i("map_proof_n"), ", widerspruechlich" if i("map_proof_bad") else ""))
print("  DAB seit Dienststart: 11D %s, 5C %s; RDS %s; BR24 %s; /dabhist 11D %s, 5C %s" % (
    "Sync" if dok.get("11D") == "1" else ("kein Sync" if chk.get("11D") == "1" else "nicht geprueft"),
    "Sync" if dok.get("5C") == "1" else ("kein Sync" if chk.get("5C") == "1" else "nicht geprueft"),
    "frisch" if i("rds_ok") else "nichts neues (zuletzt %s)" % hm(i("rds_last")),
    "ok" if (i("br24_fm_ok") or i("br24_dab_ok")) else ("Dashboard meldet kein Empfang" if i("br24_api_nok") else "nichts neues"),
    "neu" if i("dabhist_11D") >= t0 > 0 else "nichts neues", "neu" if i("dabhist_5C") >= t0 > 0 else "nichts neues"))
if i("kerr_since"):
    warn.append("%d USB/Strom-Fehlerzeilen im Kernel seit Dienststart (Abschnitt 3)" % i("kerr_since"))
th = F.get("throttled", "")
if th and th not in ("0x0", "0"):
    warn.append("Stromversorgung meldet %s (Unterspannung/Drosselung) - typische Ursache fuer USB-Abbrueche" % th)
if i("st_age") > 180:
    warn.append("sdr_status.json ist %d s alt" % i("st_age"))
print("  URTEIL: " + v)
for w in warn:
    print("  HINWEIS: " + w)
PY
else
  echo "  python3: nicht installiert - keine Auswertung"
fi
echo
echo "=== diag-stick1 fertig ${COMMIT:+(Commit $COMMIT) }- nichts geaendert, nichts gesendet. Ausgabe: $OUT ==="
rm -rf "$WRK" 2>/dev/null
exit 0
