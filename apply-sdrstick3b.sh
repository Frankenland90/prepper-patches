#!/bin/bash
set -euo pipefail
# sdrStick3b: baut auf dem installierten sdrStick3-Stand (live: prepper_sdr 4ab0ca0280d05df1, sdr_manager 002f6c5cad4bc1cb, dashboard 465450ad099ee748). Aendert KEINE Programmdatei und keine Konfiguration; der Register-Eintrag Stick 3 (SN 26102403, Hobby) muss schon in sdr_config.json stehen.
#  - Einziger Inhalt: die EEPROM-Stufe fuer Stick 3 (Realtek RTL2838UHIDIR, USB 1-1.1.2, Werks-SN 00000001 -> 26102403), korrigiert nach dem Abbruch von sdrStick3 (echtes rtl_eeprom liefert beim reinen Dump Exit-Code 1).
#  - Erfolg wird nicht am Exit-Code gemessen: Dump = Meldung "Dump to ... successful." + NEUE Datei mit genau 256 Bytes + Kopf 0x28 0x32 + nicht leer (0xFF/0x00) + lesbar; Schreiben = Nachlesen mit neuem Dump und Vergleich. Exit-Code 0 oder 1 ist beides zulaessig, andere Codes/Fehlermeldungen brechen ab. Es wird nie eine vorhandene Dump-Datei (auch nicht aus frueheren Laeufen) wiederverwendet.
#  - Stick 3 wird nur nach Dump-Sicherung, Trockenlauf und Eingabe von JA beschrieben, nur wenn genau ein Geraet SN 00000001 hat, prepper-sdr dafuer kurz gestoppt (danach wieder gestartet). Wirkung erst nach Neueinstecken durch Frank. Nichts ans Mesh, keine Gain-Aenderung, kein neuer Faden, kein neues sudo-Recht, keine Secrets.
# Basis streng (sha16): nur der sdrStick3-Stand, sonst Abbruch ohne Aenderung. Idempotent/wiederholbar (Register-Eintrag vorhanden; Stick schon umgeschrieben = nichts zu tun).
COMMIT_ARG="${1:-unbekannt}"
ARG2="${2:-}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
SMF="$DASH_DIR/sdr_manager.py"
DBF="$DASH_DIR/database.py"
M="$DASH_DIR/prepper_sdr.py"
MR="$DASH_DIR/mesh_router.py"
LG="$DASH_DIR/lagegeo.py"
LZ="$DASH_DIR/lagezentrum.db"
CF="$DASH_DIR/sdr_config.json"
WDJ="$DASH_DIR/sdr_wd.json"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
HDST="/usr/local/sbin/prepper-sdr-wdhelper"
SYSUSB="${SDR_SYSFS_USB:-/sys/bus/usb/devices}"
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/sdrstick3b-apply
S3_OLD=00000001; S3_NEW=26102403; S3_PATH=1-1.1.2
KEEP_LAST=3
KNOWN_D16N="465450ad099ee748"     # dashboard.py nach sdrStick3 (Basis = Ziel, unveraendert)
KNOWN_SM16N="002f6c5cad4bc1cb"    # sdr_manager.py nach sdrStick3 (= unveraendert)
KNOWN_SDR16N="4ab0ca0280d05df1"   # prepper_sdr.py nach sdrStick3 (Ziel)
KNOWN_HL16="01c19375256b05bc"    # Hilfsprogramm nach sdrAir (bleibt unveraendert)
KNOWN_DB16="431077d36822a090"    # database.py (bleibt unveraendert)
KNOWN_MR16="c5ffda3907b0dd51"    # mesh_router.py (bleibt unveraendert)
KNOWN_LG16="3788481354f47656"    # lagegeo.py (bleibt unveraendert)
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== sdrStick3b apply (nur EEPROM-Stufe Stick 3 -> SN 26102403, nur nach JA; keine Programmdatei, keine Konfiguration), Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/sbx"

EXPECT_EEF="6f01e9eec2bf272f81f68d50418feafa21092d7b53a7c86a279406a3d7f9ee55"
cat > "$W/eeflash.py" << 'EEF_EOF'
#!/usr/bin/env python3
"""sdrStick3: Seriennummer von Stick 3 (Realtek RTL2838UHIDIR, USB 1-1.1.2) im EEPROM von 00000001 auf 26102403 umstellen - nur mit Schutzvorkehrungen.
Erfolg wird NIE am Exit-Code von rtl_eeprom festgemacht (das echte Programm endet nach jedem Lauf, der nach dem Lesen aussteigt, mit rc 1): Erfolgsmeldung + 256 Byte + Kopf 28 32 + nicht leer; Schreiben nur ueber Neu-Lesen und Vergleich.
Aufruf: eeflash.py plan|prepare|write|verify [--sysfs DIR] [--old SN] [--new SN] [--path BUSPFAD] [--state DATEI] [--dumpdir DIR] [--cfg sdr_config.json]
        [--eeprom BIN] [--lister BIN] [--proc DIR] [--devroot DIR] [--ts STEMPEL]
Exit: plan 0 = nichts zu tun/uebersprungen, 10 = bereit, 20 = Ziel-SN schon vergeben (Register waere falsch -> Aufrufer bricht ab), 21 = Stick nicht eindeutig/falscher Port/anderes Geraet (kein EEPROM-Schreiben);
      prepare 0 = vorbereitet (Dump gesichert, Trockenlauf gezeigt), 20/21 = nichts geaendert (21 auch: Stick/Werkzeuge in Benutzung);
      write 0 = geschrieben und nachgeprueft, 3 = nicht geschrieben (unveraendert), 4 = Abweichung, alter Stand wiederhergestellt, 5 = Abweichung UND Wiederherstellung fehlgeschlagen.
Nie parallel zu prepper-sdr: der Aufrufer stoppt den Dienst vorher; hier wird zusaetzlich geprueft, dass kein Prozess den USB-Geraeteknoten oder ein rtl-/welle-Programm offen hat."""
import argparse
import hashlib
import json
import os
import re
import select
import subprocess
import sys
import time

RTL_IDS = ("0bda:2838", "0bda:2832")
TOOLS = ("rtl_tcp", "rtl_fm", "rtl_433", "rtl_power", "rtl_sdr", "rtl_test", "rtl_eeprom", "welle-cli", "redsea", "dump1090", "satdump", "direwolf")
LIST_RE = re.compile(r"^\s*(\d+):\s+(.*?),?\s+SN:\s*(\S*)\s*$")
STR_OFF = 9
PROMPT = b"[y/n]?"


def rd(p):
    try:
        with open(p) as f:
            return f.read().strip()
    except Exception:
        return None


def scan(sysfs):
    out = []
    try:
        names = sorted(os.listdir(sysfs))
    except Exception:
        return out
    for n in names:
        d = os.path.join(sysfs, n)
        v, p = rd(os.path.join(d, "idVendor")), rd(os.path.join(d, "idProduct"))
        if not v or not p:
            continue
        out.append({"path": n, "id": "%s:%s" % (v.lower(), p.lower()), "serial": rd(os.path.join(d, "serial")), "product": rd(os.path.join(d, "product")),
                    "busnum": rd(os.path.join(d, "busnum")), "devnum": rd(os.path.join(d, "devnum"))})
    return out


def cfg_serials(cfg, new):
    """Alle Seriennummern der Konfiguration (ohne den eigenen Hobby-Eintrag fuer die neue SN)."""
    res = set()
    try:
        c = json.load(open(cfg, encoding="utf-8"))
    except Exception:
        return res
    if isinstance(c.get("serial"), (str, int)):
        res.add(str(c["serial"]))
    if isinstance(c.get("stick2"), dict) and c["stick2"].get("serial"):
        res.add(str(c["stick2"]["serial"]))
    for x in c.get("devs") or []:
        if isinstance(x, dict) and x.get("serial") and not (x.get("tag") == "hobby" and str(x.get("serial")) == new):
            res.add(str(x["serial"]))
    return res


def load_state(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return {}


def save_state(p, d):
    tmp = p + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


def plan(a):
    devs = scan(a.sysfs)
    rtl = [d for d in devs if d["id"] in RTL_IDS]
    old = [d for d in rtl if d["serial"] == a.old]
    newd = [d for d in devs if d["serial"] == a.new]
    st = load_state(a.state)
    info = []
    if newd:
        if len(newd) == 1 and newd[0]["id"] in RTL_IDS and newd[0]["path"] == a.path and not old:
            return 0, ["SKIP schon umgestellt: SN %s sichtbar an USB %s (Stick 3 · Hobby)" % (a.new, a.path)]
        return 20, ["WARN Seriennummer %s ist schon vergeben an: %s - keine Aenderung" % (a.new, ", ".join("%s (%s)" % (d["path"], d["id"]) for d in newd))]
    if a.new in cfg_serials(a.cfg, a.new):
        return 20, ["WARN Seriennummer %s steht schon in sdr_config.json bei einem anderen Geraet - keine Aenderung" % a.new]
    if st.get("phase") == "written" and st.get("new") == a.new and st.get("verified") and old:
        return 0, ["SKIP EEPROM schon umgestellt (%s, Dump %s) - Stick 3 zeigt noch SN %s, bis er abgezogen und wieder eingesteckt wird" % (time.strftime("%d.%m. %H:%M", time.localtime(st.get("t") or 0)), st.get("dump"), a.old)]
    if not old:
        return 0, ["SKIP kein USB-Geraet mit SN %s gefunden - nichts zu tun" % a.old]
    if len(old) > 1:
        return 21, ["WARN %d Geraete mit SN %s (%s) - nicht eindeutig, keine Aenderung" % (len(old), a.old, ", ".join(d["path"] for d in old))]
    d = old[0]
    if d["path"] != a.path:
        return 21, ["WARN Geraet mit SN %s steckt an USB %s, erwartet %s - keine Aenderung" % (a.old, d["path"], a.path)]
    if d["product"] != "RTL2838UHIDIR":
        return 21, ["WARN Geraet an USB %s heisst %r, erwartet RTL2838UHIDIR - keine Aenderung" % (d["path"], d["product"])]
    info.append("READY genau ein Geraet mit SN %s: USB %s (%s, %s), Ziel-SN %s ohne Kollision (%d USB-Geraete, %d RTL-Sticks geprueft)" % (a.old, d["path"], d["id"], d["product"], a.new, len(devs), len(rtl)))
    return 10, info


def lister(a):
    r = subprocess.run([a.lister, "-d", "prepper-nur-liste"], stdin=subprocess.DEVNULL, capture_output=True, timeout=25, start_new_session=True)
    res = []
    for ln in (r.stdout + r.stderr).decode("utf-8", "replace").splitlines():
        m = LIST_RE.match(ln)
        if m:
            res.append((int(m.group(1)), m.group(2).strip(), m.group(3)))
    return res


def index_of(a):
    """-> (idx, fehler): genau ein Eintrag mit alter SN, keiner mit neuer, Liste passt zu sysfs (gleiche Seriennummern)."""
    lst = lister(a)
    sn = sorted(x[2] for x in lst)
    sysn = sorted(d["serial"] for d in scan(a.sysfs) if d["id"] in RTL_IDS)
    if sn != sysn:
        return None, "Stick-Liste %s passt nicht zu sysfs %s" % (sn, sysn)
    m = [x for x in lst if x[2] == a.old]
    if len(m) != 1:
        return None, "%d Eintraege mit SN %s in der Stick-Liste" % (len(m), a.old)
    if any(x[2] == a.new for x in lst):
        return None, "SN %s kommt in der Stick-Liste schon vor" % a.new
    return m[0][0], None


def busy(a, dev):
    """Liste dessen, was Stick 3 oder die RTL-Werkzeuge gerade benutzt (muss leer sein)."""
    out = []
    node = None
    try:
        node = os.path.join(a.devroot, "%03d" % int(dev["busnum"]), "%03d" % int(dev["devnum"]))
    except Exception:
        out.append("USB-Geraeteknoten nicht bestimmbar (busnum/devnum fehlen)")
    me = os.getpid()
    try:
        pids = [x for x in os.listdir(a.proc) if x.isdigit() and int(x) != me]
    except Exception:
        return out + ["Prozessliste nicht lesbar"]
    for p in pids:
        try:
            cmd = open(os.path.join(a.proc, p, "cmdline"), "rb").read().split(b"\0")[0].decode("utf-8", "replace")
        except Exception:
            cmd = ""
        parts = []
        try:
            parts = open(os.path.join(a.proc, p, "cmdline"), "rb").read().split(b"\0")
        except Exception:
            pass
        prog = os.path.basename(cmd)
        if prog in ("bash", "sh", "dash", "python3", "python") and len(parts) > 1:
            prog = os.path.basename(parts[1].decode("utf-8", "replace"))
        if prog in TOOLS:
            out.append("Programm %s (PID %s) laeuft" % (prog, p))
        if node:
            fd = os.path.join(a.proc, p, "fd")
            try:
                for f in os.listdir(fd):
                    try:
                        if os.readlink(os.path.join(fd, f)) == node:
                            out.append("PID %s (%s) hat den Geraeteknoten %s offen" % (p, os.path.basename(cmd) or "?", node))
                    except Exception:
                        pass
            except Exception:
                pass
    return out


def parse(buf):
    if len(buf) != 256 or buf[0] != 0x28 or buf[1] != 0x32:
        raise ValueError("kein gueltiges RTL2832-EEPROM-Abbild (Laenge %d, Kopf %02x %02x)" % (len(buf), buf[0] if buf else 0, buf[1] if len(buf) > 1 else 0))
    c = {"vid": buf[2] | (buf[3] << 8), "pid": buf[4] | (buf[5] << 8), "have_serial": buf[6] == 0xA5, "rw": buf[7] & 1, "ir": 1 if buf[7] & 2 else 0, "str": [], "span": []}
    pos = STR_OFF
    for _ in range(3):
        ln = buf[pos]
        if buf[pos + 1] != 0x03 or ln < 2 or pos + ln > 128:
            raise ValueError("ungueltiger String-Deskriptor bei %d" % pos)
        i, s = 2, []
        while i < ln:
            s.append(chr(buf[pos + i]))
            i += 2
        c["str"].append("".join(s))
        c["span"].append((pos, pos + i))
        pos += i
    c["manuf"], c["product"], c["serial"] = c["str"]
    return c


def predict(buf, new):
    """Wie rtl_eeprom -s: die ersten 128 Bytes aus der Konfiguration neu erzeugen (Rest bleibt)."""
    c = parse(buf)
    d = bytearray(buf)
    d[0], d[1] = 0x28, 0x32
    d[2], d[3] = c["vid"] & 0xFF, (c["vid"] >> 8) & 0xFF
    d[4], d[5] = c["pid"] & 0xFF, (c["pid"] >> 8) & 0xFF
    d[6] = 0xA5
    d[7] = 0x14 | (1 if c["rw"] else 0) | (2 if c["ir"] else 0)
    d[8] = 0x02
    pos = STR_OFF
    for s in (c["manuf"], c["product"], new):
        d[pos + 1] = 0x03
        j = 2
        for ch in s:
            if pos + j >= 78:
                raise ValueError("String zu lang")
            d[pos + j], d[pos + j + 1] = ord(ch), 0
            j += 2
        d[pos] = j
        pos += j
    d[78] = 0
    return bytes(d)


def serial_bytes(buf):
    s, e = parse(buf)["span"][2]
    return set(range(s + 2, e, 2))


def run_prompted(a, args, validator, timeout=40):
    """rtl_eeprom starten, bis zur Frage [y/n] lesen, Ausgabe pruefen, dann y (nur wenn validator True) sonst n antworten. -> (rc, text, geantwortet_y)"""
    p = subprocess.Popen([a.eeprom] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0, start_new_session=True)
    buf = b""
    t0 = time.time()
    said_y = False
    answered = False
    try:
        while time.time() - t0 < timeout:
            r, _, _ = select.select([p.stdout], [], [], 0.5)
            if r:
                ch = os.read(p.stdout.fileno(), 4096)
                if not ch:
                    break
                buf += ch
                if PROMPT in buf and not answered:
                    answered = True
                    ok = False
                    try:
                        ok = bool(validator(buf.decode("utf-8", "replace")))
                    except Exception:
                        ok = False
                    said_y = ok
                    try:
                        p.stdin.write(b"y\n" if ok else b"n\n")
                        p.stdin.flush()
                        p.stdin.close()
                    except Exception:
                        pass
            elif p.poll() is not None:
                break
        else:
            p.kill()
            p.wait()
            return 124, buf.decode("utf-8", "replace"), said_y
        try:
            rest = p.stdout.read()
            buf += rest or b""
        except Exception:
            pass
        rc = p.wait(timeout=10)
    except Exception:
        p.kill()
        p.wait()
        raise
    return rc, buf.decode("utf-8", "replace"), said_y


def blocks(txt):
    """-> (aktuelle Konfiguration, neue Konfiguration) als Dict Name -> Wert aus der Ausgabe von rtl_eeprom."""
    def grab(part):
        d = {}
        for ln in part.splitlines():
            m = re.match(r"^(Vendor ID|Product ID|Manufacturer|Product|Serial number|Serial number enabled|IR endpoint enabled|Remote wakeup enabled):\s*(.*)$", ln.strip())
            if m:
                d[m.group(1)] = m.group(2).strip()
        return d
    i = txt.find("Current configuration:")
    j = txt.find("New configuration:")
    cur = grab(txt[i:j] if j > i >= 0 else (txt[i:] if i >= 0 else ""))
    new = grab(txt[j:]) if j >= 0 else {}
    return cur, new


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def fresh(path):
    """Nie eine vorhandene Datei wiederverwenden: bei Namensgleichheit -2, -3, ..."""
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(path)
    n = 2
    while os.path.exists("%s-%d%s" % (stem, n, ext)):
        n += 1
    return "%s-%d%s" % (stem, n, ext)


def dump(a, idx, path):
    """EEPROM per rtl_eeprom -r sichern. Erfolg NICHT ueber den Exit-Code (das echte rtl_eeprom liefert nach dem Lesen rc 1, weil main() den
    Rueckgabewert von rtlsdr_read_eeprom = 1 zurueckgibt), sondern: Meldung 'Dump to <Datei> successful.', Datei neu angelegt, genau 256 Byte,
    Kopf 0x28 0x32, weder nur 0xFF (leer) noch nur 0x00, Textfelder lesbar. Nur rc 0/1 zulaessig (alles andere = Abbruch/Absturz)."""
    if os.path.exists(path):
        raise RuntimeError("Zieldatei %s existiert schon (wird nie wiederverwendet)" % path)
    try:
        r = subprocess.run([a.eeprom, "-d", str(idx), "-r", path], stdin=subprocess.DEVNULL, capture_output=True, timeout=40, start_new_session=True)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Dump: Zeitueberschreitung")
    txt = (r.stdout + r.stderr).decode("utf-8", "replace")
    tail = txt.strip()[-200:]
    if r.returncode not in (0, 1):
        raise RuntimeError("Dump: Exit-Code %s (erlaubt 0/1): %s" % (r.returncode, tail))
    if ("Dump to %s successful." % path) not in txt:
        raise RuntimeError("Dump: keine Erfolgsmeldung 'Dump to ... successful.' (rc %s): %s" % (r.returncode, tail))
    if not os.path.isfile(path):
        raise RuntimeError("Dump: Datei %s fehlt trotz Erfolgsmeldung" % path)
    buf = open(path, "rb").read()
    if len(buf) != 256:
        raise RuntimeError("Dump: Datei hat %d statt 256 Byte" % len(buf))
    if buf[:2] != b"\x28\x32":
        raise RuntimeError("Dump: Kopf %02x %02x statt 28 32 (kein RTL2832-EEPROM)" % (buf[0], buf[1]))
    if buf.count(b"\xff") == 256 or buf.count(b"\x00") == 256:
        raise RuntimeError("Dump: EEPROM-Abbild leer (nur 0xFF/0x00)")
    try:
        parse(buf)
    except Exception as ex:
        raise RuntimeError("Dump: Inhalt nicht lesbar: %s" % ex)
    os.chmod(path, 0o600)
    print("   Dump-Pruefung: rtl_eeprom Exit-Code %s (0 oder 1 zulaessig, nicht massgeblich), Meldung 'Dump to ... successful.' ja, neue Datei 256 Byte, Kopf 28 32, Inhalt nicht leer und lesbar" % r.returncode)
    return buf, txt


def common(a):
    code, info = plan(a)
    if code != 10:
        return code, info, None, None, None
    dev = [d for d in scan(a.sysfs) if d["serial"] == a.old and d["id"] in RTL_IDS][0]
    idx, e = index_of(a)
    if e:
        return 20, ["WARN " + e + " - keine Aenderung"], None, None, None
    b = busy(a, dev)
    if b:
        return 21, ["WARN Stick 3 / RTL-Werkzeuge in Benutzung: " + "; ".join(b) + " - keine Aenderung"], None, None, None
    return 10, info, dev, idx, None


def prepare(a):
    code, info, dev, idx, _ = common(a)
    for x in info:
        print(x)
    if code != 10:
        return code
    os.makedirs(a.dumpdir, exist_ok=True)
    os.chmod(a.dumpdir, 0o700)
    dp = fresh(os.path.join(a.dumpdir, "stick3-eeprom-%s-vor-SN%s.bin" % (a.ts, a.old)))
    try:
        buf, _ = dump(a, idx, dp)
        c = parse(buf)
    except Exception as ex:
        print("WARN EEPROM nicht lesbar: %s - keine Aenderung" % ex)
        return 21
    want = (dev["id"].split(":")[0], dev["id"].split(":")[1])
    if c["serial"] != a.old or "%04x" % c["vid"] != want[0] or "%04x" % c["pid"] != want[1] or c["product"] != dev["product"] or not c["have_serial"]:
        print("WARN EEPROM-Inhalt passt nicht zum Zielgeraet (SN %s, %04x:%04x, %s) - keine Aenderung" % (c["serial"], c["vid"], c["pid"], c["product"]))
        return 21
    try:
        pred = predict(buf, a.new)
    except Exception as ex:
        print("WARN Vorhersage nicht moeglich: %s - keine Aenderung" % ex)
        return 21
    allowed = serial_bytes(buf)
    diff = [i for i in range(256) if pred[i] != buf[i]]
    if not diff or any(i not in allowed for i in diff):
        print("WARN geplante Aenderung betrifft mehr als die Seriennummer (Bytes %s) - keine Aenderung" % diff[:12])
        return 21
    print("OK EEPROM von USB %s (Index %d) gesichert: %s (256 Bytes, sha256 %s)" % (dev["path"], idx, dp, sha(dp)))
    print("   aktuell: %04x:%04x %s / %s / SN %s, Seriennummer aktiv, IR %s, Remote-Wakeup %s" % (c["vid"], c["pid"], c["manuf"], c["product"], c["serial"], "ja" if c["ir"] else "nein", "ja" if c["rw"] else "nein"))
    print("   geplante Aenderung: nur %d Byte(s) der Seriennummer (Bytes %s), sonst identisch" % (len(diff), ",".join(str(i) for i in diff)))
    state = {"phase": "prepared", "ts": a.ts, "t": int(time.time()), "old": a.old, "new": a.new, "path": dev["path"], "idx": idx, "dump": dp, "dump_sha256": sha(dp), "predicted_sha256": hashlib.sha256(pred).hexdigest()}
    cur_expect = {"Serial number": a.old}
    rc, txt, y = run_prompted(a, ["-d", str(idx), "-s", a.new], lambda t: False)
    cur, new = blocks(txt)
    print("   Trockenlauf (rtl_eeprom -d %d -s %s, Antwort n - nichts geschrieben):" % (idx, a.new))
    for ln in txt.splitlines():
        if ln.strip() and not ln.startswith("_____"):
            print("     | " + ln.strip()[:120])
    if y or cur.get("Serial number") != a.old or new.get("Serial number") != a.new or {k: v for k, v in cur.items() if k != "Serial number"} != {k: v for k, v in new.items() if k != "Serial number"}:
        print("WARN Trockenlauf zeigt nicht nur die Seriennummer als Aenderung (aktuell %s, neu %s) - keine Aenderung" % (cur, new))
        return 21
    after = dump(a, idx, fresh(os.path.join(a.dumpdir, "stick3-eeprom-%s-pruef.bin" % a.ts)))[0]
    if after != buf:
        print("WARN EEPROM hat sich durch den Trockenlauf veraendert - bitte pruefen")
        return 21
    save_state(a.state, state)
    print("OK Trockenlauf: nur Seriennummer %s -> %s, EEPROM danach unveraendert (Vergleich der Abbilder)" % (a.old, a.new))
    return 0


def write(a):
    import signal
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    st = load_state(a.state)
    if st.get("phase") != "prepared" or st.get("ts") != a.ts or st.get("old") != a.old or st.get("new") != a.new or time.time() - int(st.get("t") or 0) > 1800 or not os.path.isfile(st.get("dump") or "") or sha(st["dump"]) != st.get("dump_sha256"):
        print("WARN Vorbereitung dieses Laufs fehlt oder ist aelter als 30 min (alte Dumps/Zustaende werden nie wiederverwendet) - nichts geschrieben")
        return 3
    code, info, dev, idx, _ = common(a)
    for x in info:
        print(x)
    if code != 10:
        return 3
    if idx != st.get("idx") or dev["path"] != st.get("path"):
        print("WARN Index/USB-Pfad haben sich seit dem Trockenlauf geaendert (%s/%s -> %s/%s) - nichts geschrieben" % (st.get("idx"), st.get("path"), idx, dev["path"]))
        return 3
    orig = open(st["dump"], "rb").read()
    pred = predict(orig, a.new)

    def ok_cur(t):
        cur, new = blocks(t)
        return (cur.get("Serial number") == a.old and new.get("Serial number") == a.new and cur.get("Product") == dev["product"]
                and {k: v for k, v in cur.items() if k != "Serial number"} == {k: v for k, v in new.items() if k != "Serial number"})
    rc, txt, y = run_prompted(a, ["-d", str(idx), "-s", a.new], ok_cur)
    print("   rtl_eeprom -d %d -s %s: Antwort %s, rc %s" % (idx, a.new, "y" if y else "n", rc))
    for ln in txt.splitlines():
        if ln.strip() and not ln.startswith("_____"):
            print("     | " + ln.strip()[:120])
    if not y:
        print("WARN Pruefung vor dem Schreiben nicht bestanden (aktuelle Konfiguration nicht die erwartete) - nichts geschrieben")
        return 3
    pp = fresh(os.path.join(a.dumpdir, "stick3-eeprom-%s-nachher-SN%s.bin" % (a.ts, a.new)))
    try:
        got = dump(a, idx, pp)[0]
    except Exception as ex:
        got = None
        print("WARN Nachpruefung: %s" % ex)
    okmsg = "Configuration successfully written." in txt
    print("   Schreiben: rc %s (kein Erfolgskriterium; 0 = geschrieben, >1 = Fehler), Meldung 'successfully written' %s, Neu-Lesen %s" % (rc, "ja" if okmsg else "NEIN", "== Vorhersage" if got == pred else ("== alter Stand" if got == orig else ("abweichend" if got else "fehlgeschlagen"))))
    if got == pred:
        st.update(phase="written", t=int(time.time()), verified=True, after=pp, after_sha256=sha(pp))
        save_state(a.state, st)
        print("OK EEPROM geschrieben und nachgeprueft: Seriennummer %s -> %s (Abbild == Vorhersage, nur Seriennummern-Bytes anders). Stick 3 meldet die neue SN erst nach Abziehen und Wiedereinstecken." % (a.old, a.new))
        return 0
    if got == orig:
        print("WARN EEPROM unveraendert (Schreiben hat nicht gewirkt) - alter Stand")
        st.update(phase="prepared", t=int(time.time()))
        save_state(a.state, st)
        return 3
    print("WARN EEPROM weicht von der Vorhersage ab - stelle den gesicherten Stand wieder her (rtl_eeprom -w %s)" % st["dump"])

    def ok_restore(t):
        cur, new = blocks(t)
        return cur.get("Product") == dev["product"] and new.get("Serial number") == a.old
    rc2, txt2, y2 = run_prompted(a, ["-d", str(idx), "-w", st["dump"]], ok_restore)
    try:
        back = dump(a, idx, fresh(os.path.join(a.dumpdir, "stick3-eeprom-%s-wiederhergestellt.bin" % a.ts)))[0]
    except Exception:
        back = None
    if back == orig:
        st.update(phase="restored", t=int(time.time()), verified=False)
        save_state(a.state, st)
        print("WARN alter EEPROM-Stand wiederhergestellt und bestaetigt (Abbild == Dump vor der Aenderung)")
        return 4
    print("FEHLER Wiederherstellung nicht bestaetigt - Dump liegt in %s; manuell: rtl_eeprom -d %d -w %s" % (st["dump"], idx, st["dump"]))
    return 5


def verify(a):
    devs = scan(a.sysfs)
    st = load_state(a.state)
    new = [d for d in devs if d["serial"] == a.new and d["id"] in RTL_IDS]
    old = [d for d in devs if d["serial"] == a.old and d["id"] in RTL_IDS]
    if len(new) == 1 and not old:
        print("OK Stick 3 meldet SN %s an USB %s (Hobby im Register)" % (a.new, new[0]["path"]))
        return 0
    if old:
        print("HINWEIS Stick 3 meldet noch SN %s (USB %s)%s" % (a.old, old[0]["path"], " - EEPROM ist umgestellt, bitte Stick 3 abziehen und wieder einstecken" if st.get("phase") == "written" else " - EEPROM noch nicht umgestellt"))
        return 10
    print("HINWEIS Stick 3 ist nicht angesteckt")
    return 11


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("plan", "prepare", "write", "verify"))
    ap.add_argument("--sysfs", default="/sys/bus/usb/devices")
    ap.add_argument("--old", default="00000001")
    ap.add_argument("--new", default="26102403")
    ap.add_argument("--path", default="1-1.1.2")
    ap.add_argument("--state", default="sdr_stick3.json")
    ap.add_argument("--dumpdir", default="stick3-eeprom")
    ap.add_argument("--cfg", default="sdr_config.json")
    ap.add_argument("--eeprom", default="rtl_eeprom")
    ap.add_argument("--lister", default="rtl_test")
    ap.add_argument("--proc", default="/proc")
    ap.add_argument("--devroot", default="/dev/bus/usb")
    ap.add_argument("--ts", default=time.strftime("%Y%m%d-%H%M%S"))
    a = ap.parse_args(argv)
    if not (re.match(r"^[0-9]{8}$", a.old) and re.match(r"^[0-9]{8}$", a.new)) or a.old == a.new:
        print("WARN Seriennummern muessen 8 Ziffern und verschieden sein")
        return 20
    if a.cmd == "plan":
        code, info = plan(a)
        for x in info:
            print(x)
        return code
    return {"prepare": prepare, "write": write, "verify": verify}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
EEF_EOF
EXPECT_S3C="8a64105b7af3c2d2cb08ec35853d9f86df053457f8651c650cfcdc0a287a9a2a"
cat > "$W/s3check.py" << 'S3C_EOF'
"""sdrStick3 Pruefhilfe fuer apply-sdrstick3.sh. addcfg CF SN | cfgcheck CF SN | ui JSON SYSUSB ALT NEU | journal DATEI SYSUSB ALT NEU | selftest"""
import glob
import json
import os
import sys
import tempfile

ENTRY = {"name": "Stick 3", "kind": "rtl", "usb": "0bda:2838"}


def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def cfgcheck(cf, sn):
    c = load(cf)
    ds = [x for x in c.get("devs") or [] if isinstance(x, dict) and str(x.get("serial")) == sn]
    if len(ds) != 1:
        raise ValueError("%d Register-Eintraege mit SN %s" % (len(ds), sn))
    x = ds[0]
    if x.get("kind") != "rtl" or x.get("tag") != "hobby" or x.get("role") not in ("", None) or x.get("name") != "Stick 3":
        raise ValueError("Register-Eintrag SN %s passt nicht (Stick 3 / rtl / tag hobby / ohne Rolle): %s" % (sn, x))
    if c.get("devs_on") is not True:
        raise ValueError("devs_on ist nicht true - Register aus")
    return x


def addcfg(cf, sn):
    c = load(cf)
    if c.get("devs_on") is not True or not isinstance(c.get("devs"), list):
        raise ValueError("Register in sdr_config.json nicht aktiv (devs_on/devs)")
    if len(c["devs"]) >= 8:
        raise ValueError("Register hat schon %d Eintraege (Grenze 8)" % len(c["devs"]))
    for x in c["devs"]:
        if isinstance(x, dict) and str(x.get("serial")) == sn:
            cfgcheck(cf, sn)
            return "Register-Eintrag Stick 3 (SN %s, Hobby) war schon drin" % sn
    if any(isinstance(x, dict) and x.get("name") == "Stick 3" for x in c["devs"]):
        raise ValueError("Name 'Stick 3' ist im Register schon anders vergeben")
    e = dict(ENTRY)
    e["serial"] = sn
    e["role"] = ""
    e["tag"] = "hobby"
    c["devs"].append(e)
    tmp = cf + ".new"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(c, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, os.stat(cf).st_mode & 0o7777)
    load(tmp)
    os.replace(tmp, cf)
    cfgcheck(cf, sn)
    return "Register-Eintrag Stick 3 (SN %s, Hobby, ohne Rolle) ergaenzt, %d Eintraege" % (sn, len(c["devs"]))


def sysfs_sns(root):
    out = {}
    for d in sorted(glob.glob(os.path.join(root, "*"))):
        try:
            v = open(os.path.join(d, "idVendor")).read().strip().lower()
            p = open(os.path.join(d, "idProduct")).read().strip().lower()
            s = open(os.path.join(d, "serial")).read().strip()
        except Exception:
            continue
        if "%s:%s" % (v, p) in ("0bda:2838", "0bda:2832"):
            out.setdefault(s, []).append(os.path.basename(d))
    return out


def ui(js, root, old, new):
    u = (load(js).get("dual") or {})
    devs = [x for x in u.get("devs") or [] if isinstance(x, dict)]
    s3 = [x for x in devs if str(x.get("label") or "").startswith("Stick 3")]
    sn = sysfs_sns(root)
    if len(s3) != 1:
        raise ValueError("%d Eintraege 'Stick 3' in /api/sdr/ui: %s" % (len(s3), [x.get("label") for x in devs]))
    x = s3[0]
    if new in sn:
        if len(sn[new]) != 1 or x.get("serial") != new or x.get("tag") != "hobby" or x.get("label") != "Stick 3 · Hobby" or x.get("present") is not True or x.get("role") or x.get("unreg"):
            raise ValueError("SN %s steckt, aber Eintrag ist nicht 'Stick 3 · Hobby' (angeschlossen, ohne Rolle): %s" % (new, x))
        return "Stick 3 · Hobby (SN %s, USB %s): angeschlossen, nur Register/Anzeige, Zustand '%s'" % (new, x.get("usb"), x.get("state"))
    if len(sn.get(old, [])) > 1:
        if any(e.get("tag") == "hobby" and e.get("present") for e in devs):
            raise ValueError("mehrere Sticks mit Werks-SN %s, aber ein Eintrag steht als Hobby angeschlossen" % old)
        return "mehrere Sticks mit Werks-SN %s (%s) - keine Zuordnung zu Stick 3, kein Hobby angeschlossen" % (old, ", ".join(sn[old]))
    if old in sn:
        if len(sn[old]) != 1 or x.get("serial") != old or x.get("label") != "Stick 3 · ohne Rolle" or x.get("present") is not True or x.get("role") or "Hobby" in str(x.get("label")) and False:
            raise ValueError("SN %s steckt, Eintrag passt nicht ('Stick 3 · ohne Rolle'): %s" % (old, x))
        if new not in str(x.get("hint") or ""):
            raise ValueError("Hinweis nennt die kuenftige SN %s nicht: %s" % (new, x.get("hint")))
        return "Stick 3 · ohne Rolle (Werks-SN %s, USB %s) bis zum Neueinstecken; Hinweis nennt kuenftig '%s'" % (old, x.get("usb"), "Stick 3 · Hobby")
    if x.get("serial") != new or x.get("tag") != "hobby" or x.get("present") is not False:
        raise ValueError("Kein Stick 3 angesteckt, Eintrag passt nicht (Hobby, nicht angeschlossen): %s" % x)
    return "Stick 3 · Hobby (SN %s) im Register, nicht angeschlossen" % new


def journal(txt, root, old, new):
    sn = sysfs_sns(root)
    ls = [x for x in txt.splitlines() if x.startswith("sdrStick3:")]
    if new in sn:
        if not any(("(SN %s," % new) in x and "angesteckt" in x and "Stick 3 · Hobby" in x for x in ls):
            raise ValueError("kein Journal 'sdrStick3: Stick 3 · Hobby (SN %s, ...) angesteckt': %s" % (new, ls[-3:]))
        return "Journal: %s" % [x for x in ls if "angesteckt" in x][-1][:200]
    if any("angesteckt" in x for x in ls):
        raise ValueError("Journal meldet Hobby angesteckt, obwohl SN %s nicht steckt: %s" % (new, ls[-2:]))
    return "Journal: keine sdrStick3-Zeile noetig (%s)" % ("Stick 3 noch mit Werks-SN" if old in sn else "Stick 3 nicht angesteckt")


def main(a):
    m = a[0] if a else ""
    try:
        if m == "addcfg":
            print(addcfg(a[1], a[2])); return 0
        if m == "cfgcheck":
            cfgcheck(a[1], a[2]); print("ok"); return 0
        if m == "ui":
            print(ui(a[1], a[2], a[3], a[4])); return 0
        if m == "journal":
            print(journal(open(a[1], encoding="utf-8", errors="replace").read(), a[2], a[3], a[4])); return 0
    except Exception as ex:
        print(str(ex)[:400]); return 1
    print(__doc__); return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
S3C_EOF
EXPECT_AC2="8e93c983cca56d6a4149db1210c42fd9fb262be0ba597e707c49fb3b55e29c20"
cat > "$W/air2check.py" << 'AC2_EOF'
"""sdrAir2 Pruefungen fuer apply-sdrair2.sh (nur lesen). proof DIR T0 | api JSON | state DIR | hobby DIR"""
import json
import os
import re
import sys
import time

hm = lambda t: time.strftime("%d.%m. %H:%M:%S", time.localtime(t)) if isinstance(t, (int, float)) else "–"


def newest(d, name, key):
    """sqlC: Stand primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
    best = {}
    try:
        import sqlite3
        c = sqlite3.connect("file:%s?mode=ro" % os.path.join(d, "lagezentrum.db"), uri=True, timeout=10)
        try:
            r = c.execute("SELECT json FROM state WHERE key=?", (key,)).fetchone()
            best = json.loads(r[0]) if r else {}
        finally:
            c.close()
    except Exception:
        best = {}
    try:
        j = json.load(open(os.path.join(d, name), encoding="utf-8"))
        if not best or float(j.get("t") or 0) > float(best.get("t") or 0):
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def devs(d):
    try:
        c = json.load(open(os.path.join(d, "sdr_config.json"), encoding="utf-8"))
    except Exception:
        return {}
    return {str(x.get("serial") or "").upper(): x for x in c.get("devs") or [] if isinstance(x, dict) and c.get("devs_on") is True}


def main(a):
    m = a[0]
    if m == "proof":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        a1 = next((x for x in st.get("devs") or [] if isinstance(x, dict) and x.get("role") == "11D"), {})
        sn = str(a1.get("serial") or "")
        e = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {})
        dm = e.get("demod") if isinstance(e.get("demod"), dict) else {}
        dev = st.get("dev") or {}
        cpu = dev.get("cpu") or {}
        ok = bool(sn) and e.get("rx") is True and float(e.get("t") or 0) >= t0 and dm.get("sn") == sn and float(dm.get("t") or 0) >= t0
        if not ok:
            print("11D-Sync vom Airspy noch nicht nachgewiesen (Airspy SN %s, 11D Empfang %s um %s, Messung von SN %s um %s, seit Start %s)" % (
                sn or "?", e.get("rx"), hm(e.get("t")), dm.get("sn"), hm(dm.get("t")), hm(t0)))
            return 1
        print("11D-Sync vom Airspy nachgewiesen: Empfang %s, SNR %s, FIC-Fehlerrate %s · %s · welle-cli CPU %s" % (
            hm(e.get("t")), dm.get("snr"), dm.get("fic_rate"), dev.get("fe") or "?", cpu.get("txt") or "noch nicht gemessen"))
        return 0
    if m == "api":
        w = json.load(open(a[1], encoding="utf-8"))
        ss = w.get("sticks") or []
        assert w.get("lvl") in ("ok", "gelb", "rot", "grau") and ss, str(w)[:200]
        assert all(s.get("name") for s in ss), "Geraet ohne Namen: %s" % [s.get("sn") for s in ss if not s.get("name")]
        reg = any(s.get("role") for s in ss)
        assert reg, "keine Rollen in /api/sdr/wd (sdr_manager alt?)"
        assert w.get("txt") != "alle Sticks mit echtem Empfang", "alte Sammelzeile"
        hb = [s for s in ss if s.get("watch")]
        assert all(s.get("role") == "hobby" for s in hb) and (not hb or isinstance(w.get("hobby"), dict)), "Hobby-Zeile fehlt"
        if w["lvl"] == "ok":
            assert not [s for s in ss if not s.get("watch") and not s.get("absent") and s.get("lvl") != "ok"], "Gesamt ok trotz ungepruefter Geraete"
        print("/api/sdr/wd (sdrAir2): %s · %s · %s" % (w["lvl"], (w.get("short") or w.get("txt") or "")[:140], " | ".join(
            "%s %s%s" % (s["name"], s.get("lvl"), " (Hobby, nur Beobachtung)" if s.get("watch") else "") for s in ss)))
        return 0
    if m in ("state", "hobby"):
        d = a[1]
        f = os.path.join(d, "sdr_wd.json")
        if not os.path.exists(f):
            print("sdr_wd.json: noch nicht vorhanden"); return 0 if m == "state" else 1
        w = json.load(open(f, encoding="utf-8"))
        dv = devs(d)
        out, bad = [], []
        for sn, v in sorted((w.get("sticks") or {}).items()):
            x = dv.get(sn.upper()) or {}
            nm = "%s%s" % (x.get("name") or "Gerät ohne Rolle", " (Hobby)" if x.get("role") == "hobby" else "")
            i = v.get("inc")
            if not i:
                out.append("%s SN %s ok" % (nm, sn))
            else:
                out.append("%s SN %s Vorfall %s seit %s%s" % (nm, sn, i.get("ch") or "?", hm(i.get("since")), (", nur Beobachtung" if x.get("role") == "hobby" else
                                                                                                                 ", Neustart %s, USB %s" % (i.get("restart_n", 0), i.get("usb_n", 0)))))
                if x.get("role") == "hobby" and (i.get("ch") != "RDS" or i.get("restart_n") or i.get("usb_n")):
                    bad.append(sn)
        if m == "hobby":
            if bad:
                print("Hobby-Vorfall alter Art noch offen: %s" % ", ".join(bad)); return 1
            print("Hobby: kein alter Vorfall offen (%s)" % "; ".join(o for o in out if "(Hobby)" in o)); return 0
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(w.get("reboots") or []), w.get("reboot_fail_n") or 0))
        return 0
    if m == "namestest":                               # Pruefung der Pruefung: echte HB-Beispieltexte duerfen nicht anschlagen, echte Platz-Namen schon
        return names_selftest()
    if m == "names":                                   # names DIR: gespeicherte Seiten/APIs (p_*.html / p_*.json) auf alte Platz-Namen pruefen
        return names_check(a[1])
    print("unbekannt"); return 2


SLOT_RE = re.compile(r"(\bSDR ?[123]\b|\bStick [1-9]\b(?! · (?:11D|5C|Hobby|ohne Rolle)\b))")
NAME_KEYS = ("name", "model", "dev_name", "name1", "name2", "name3", "names", "1", "2", "3", "label_plain")
SKIP_KEYS = ("hist", "ev", "events", "fig", "log", "techlog", "boot_msgs", "last_inc", "inc", "msgs", "err")
TS_RE = re.compile(r"^(\d\d\.\d\d\.( \d\d:\d\d)?|\d\d:\d\d)\b")
HB_RE = re.compile(r"\bHB \d\d:\d\d\b")                # schon gesendete Heartbeat-Texte ('HB 06:02 | Lage OK | ASA OK | SDR2 5C | ...'): Verlauf, keine Live-Anzeige


def _walk(o, path, out):
    if isinstance(o, dict):
        for k, v in o.items():
            k = str(k)
            if k in SKIP_KEYS:
                continue
            if k in NAME_KEYS and isinstance(v, str):
                continue
            _walk(v, path + "." + k, out)
    elif isinstance(o, list):
        for i, v in enumerate(o[:200]):
            _walk(v, "%s[%d]" % (path, i), out)
    elif isinstance(o, str) and SLOT_RE.search(o) and not TS_RE.match(o) and not HB_RE.search(o):
        out.append("%s = %s" % (path, o[:160]))


def names_check(d):
    import glob
    import html as H
    bad = []
    n = 0
    for f in sorted(glob.glob(os.path.join(d, "p_*"))):
        n += 1
        s = open(f, encoding="utf-8", errors="replace").read()
        b = os.path.basename(f)
        if b.endswith(".json"):
            try:
                j = json.loads(s)
            except Exception:
                bad.append("%s: kein JSON" % b)
                continue
            out = []
            _walk(j, "", out)
            bad += ["%s %s" % (b, x) for x in out]
            continue
        s = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", s)
        for t in (H.unescape(x).strip() for x in re.sub(r"(?s)<[^>]+>", "\n", s).split("\n")):
            if not t or TS_RE.match(t) or HB_RE.search(t) or not SLOT_RE.search(t):
                continue
            if "dabhist" in b and not re.fullmatch(r"(Stick [1-9]|SDR ?[123])", t):
                continue                               # /dabhist: Meldungs-Texte sind Verlauf; nur Quell-Etiketten pruefen
            bad.append("%s: %s" % (b, t[:160]))
    if not n:
        print("keine Seiten gespeichert"); return 1
    if bad:
        print("alte Platz-Namen (Stick N/SDR N ohne Rolle) in %d Stellen: %s" % (len(bad), " | ".join(bad[:12]))); return 1
    print("Anzeige-Namen: %d Seiten/APIs ohne alte Platz-Namen (Stick N / SDR N nur als 'Name · Rolle'; Verlauf ausgenommen)" % n)
    return 0


def names_selftest():
    import tempfile
    hb = "HB 06:02 | Lage OK | ASA OK | SDR2 5C | Wetter 12°C 8/15° Sonne 2.1h | Uplink Telekom | 50.01 Hz"
    hb2 = "HB 03:02 | Lage OK | ASA OK | SDR2 frei | Wetter 9°C"
    d = tempfile.mkdtemp(prefix="names-")
    w = lambda n, t: open(os.path.join(d, n), "w", encoding="utf-8").write(t)
    w("p_x_mesh.html", "<html><body><div class='m'>%s</div><div>%s</div><p>Stick 1 · 5C fest</p><p>Stick 2 · Hobby</p></body></html>" % (hb, hb2))
    w("p_x_api_t4_status.json", json.dumps({"hb": {"last": {"text": hb2, "t": 1}, "n": 3}, "sdr": {"s1": {"name": "Airspy R2 · 11D"}, "s2": {"name": "Stick 1 · 5C"}}}))
    if names_check(d) != 0:
        print("Namens-Pruefung schlaegt bei gesendeten HB-Texten an"); return 1
    for n, t in (("p_x_mesh.html", "<html><body><p>Lage: SDR 2 auf 5C gekapert</p></body></html>"), ("p_x_api_t4_status.json", json.dumps({"s2": {"state": "Stick 2 wartet"}}))):
        d2 = tempfile.mkdtemp(prefix="names-")
        open(os.path.join(d2, n), "w", encoding="utf-8").write(t)
        if names_check(d2) == 0:
            print("Namens-Pruefung uebersieht Platz-Namen in %s" % n); return 1
    print("OK Namens-Pruefung getestet: gesendete HB-Texte (SDR2 5C / SDR2 frei) in /mesh und .hb.last.text zaehlen nicht, Live-Platz-Namen schon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AC2_EOF
EXPECT_DCK="debff908a981f7571de0dc3d2c78b7c8b724a5baf50e4c7af080280bb5e040ea"
cat > "$W/dabcheck.py" << 'DCK_EOF'
"""Pruefhilfe dabSql (nur lesen). dabcheck.py db LZ_DB T0 | api JSON_DATEI | card HTML_DATEI | counts LZ_DB"""
import json
import os
import re
import sqlite3
import sys


def ro(p):
    return sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)


def main(a):
    m = a[0] if a else ""
    if m == "db":
        p, t0 = a[1], int(a[2])
        if not os.path.isfile(p):
            print("lagezentrum.db fehlt"); return 1
        c = ro(p)
        try:
            tb = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            miss = {"masts", "reception_log", "channel_status", "meta"} - tb
            if miss:
                print("Tabellen fehlen: %s" % ",".join(sorted(miss))); return 1
            imp = c.execute("SELECT v FROM meta WHERE k='dabsql_import'").fetchone()
            if not imp:
                print("Import-Marker fehlt (noch nicht importiert)"); return 1
            nm = c.execute("SELECT src_kind, COUNT(*) FROM masts WHERE status='known' GROUP BY src_kind").fetchall()
            kn = dict(nm)
            if kn.get("amtlich", 0) < 1 or kn.get("amtlich", 0) + kn.get("nicht_amtlich", 0) < 100:
                print("zu wenige Masten importiert: %s" % kn); return 1
            n = c.execute("SELECT COUNT(*) FROM reception_log WHERE timestamp>=?", (t0,)).fetchone()[0]
            if n < 1:
                print("noch keine Pruefung seit %d in reception_log" % t0); return 1
            r = c.execute("SELECT status, last_sync, note FROM channel_status WHERE channel='11D'").fetchone()
            if not r or r[0] != "active" or not r[1]:
                print("channel_status 11D: %s" % (r,)); return 1
            nu = c.execute("SELECT COUNT(*) FROM masts WHERE status='unknown'").fetchone()[0]
            tot = c.execute("SELECT COUNT(*) FROM reception_log").fetchone()[0]
        finally:
            c.close()
        print("dabSql-Datenbank: Import %s, bekannte Masten nach Herkunft %s, reception_log %d Zeilen (%d seit Neustart), channel_status 11D aktiv (%s), unbekannte Kennungen bisher %d" % (
            json.loads(imp[0]) if imp[0].startswith("{") else imp[0], kn, tot, n, r[2], nu)); return 0
    if m == "counts":
        if not os.path.isfile(a[1]):
            print("keine Datenbank"); return 0
        c = ro(a[1])
        try:
            tb = {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            print(", ".join("%s %s" % (t, c.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]) if t in tb else "%s (noch nicht da)" % t for t in ("masts", "reception_log", "channel_status")))
        finally:
            c.close()
        return 0
    if m == "api":
        try:
            j = json.load(open(a[1], encoding="utf-8"))
        except Exception as e:
            print("kein JSON: %s" % e); return 1
        if not (isinstance(j, dict) and j.get("ok") is True and len(j.get("channels") or []) == 3 and (j.get("known") or {}).get("total", 0) > 0 and j.get("txt")):
            print("/api/dabsql/status unvollstaendig: %s" % json.dumps(j, ensure_ascii=False)[:200]); return 1
        print("/api/dabsql/status: %s" % j["txt"]); return 0
    if m == "card":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        if s.count('id="dqCard"') != 1:
            print("/dabhist: Zusammenfassung %dx" % s.count('id="dqCard"')); return 1
        t = re.sub(r"(?s)<[^>]+>", " ", s[s.index('id="dqCard"'):][:3000])
        if "Kanäle:" not in t or "bekannte Masten" not in t:
            print("/dabhist: Zusammenfassung ohne Kanaele/Masten"); return 1
        print("/dabhist: Zusammenfassung oben (Kanaele aktiv/offline, bekannte/unbekannte Masten, Aktualisierung)"); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
DCK_EOF
EXPECT_ACK="885f6401a7cd359a08624c090f05675e1239ea36b956b01158be60015a97026f"
cat > "$W/atcheck.py" << 'ACK_EOF'
"""Pruefhilfe airTest (nur lesen). atcheck.py api JSON_DATEI | page HTML_DATEI | state DASH_DIR"""
import json
import os
import re
import sys

STATES = ("idle", "running", "done", "aborted", "unklar")


def main(a):
    m = a[0] if a else ""
    if m == "api":
        try:
            j = json.load(open(a[1], encoding="utf-8"))
        except Exception as e:
            print("kein JSON: %s" % e); return 1
        if not (isinstance(j, dict) and j.get("ok") is True and j.get("state") in STATES and j.get("levels") == [12, 19, 21] and j.get("rounds") == 5 and j.get("txt") and isinstance(j.get("rows"), list)
                and j.get("limit_min") == 40 and j.get("dev")):
            print("/api/sdr/airtest unvollstaendig: %s" % json.dumps(j, ensure_ascii=False)[:240]); return 1
        if j.get("running"):
            print("HINWEIS: ein Gain-Test laeuft gerade (state running) - nicht vom Apply gestartet")
        print("/api/sdr/airtest: %s (Geraet %s, Stufen 12/19/21, je 5 Runden, Zeitlimit 40 min)" % (j["txt"], j["dev"])); return 0
    if m == "page":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        if s.count('id="airtest-js"') != 1 or s.count('id="at-data"') != 1 or s.count('id="airtest-css"') != 1:
            print("/funk: airTest-Bloecke js %dx, daten %dx, css %dx" % (s.count('id="airtest-js"'), s.count('id="at-data"'), s.count('id="airtest-css"'))); return 1
        mm = re.search(r'id="at-data">(.*?)</script>', s, re.S)
        try:
            j = json.loads(mm.group(1))
        except Exception as e:
            print("/funk: at-data kein JSON: %s" % e); return 1
        js = s[s.index('id="airtest-js"'):]
        for k in ("/api/sdr/airtest", "window.confirm", "Gain-Test starten", "Standard-Gain wird nie"):
            if k not in js:
                print("/funk: JS ohne %s" % k); return 1
        if j.get("ok") is not True or j.get("state") not in STATES:
            print("/funk: at-data unvollstaendig"); return 1
        print("/funk: Karte Gain-Test (Daten state %s, Knopf mit Rueckfrage, Standard-Gain bleibt)" % j["state"]); return 0
    if m == "state":
        p = os.path.join(a[1], "sdr_airtest.json")
        if not os.path.isfile(p):
            print("sdr_airtest.json noch nicht da (noch nie ein Test - normal)"); return 0
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as e:
            print("sdr_airtest.json kaputt: %s" % e); return 1
        if not isinstance(d, dict) or d.get("state") not in STATES:
            print("sdr_airtest.json: state %r" % (d.get("state") if isinstance(d, dict) else d)); return 1
        print("sdr_airtest.json: state %s, %d Messungen" % (d["state"], len(d.get("samples") or []))); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
ACK_EOF
EXPECT_RCK="29ef240d57904b338ecd1d2a6e4aab49bc433b392a2ed7d7c45a68aa68ac700e"
cat > "$W/rscheck.py" << 'RCK_EOF'
"""Pruefhilfe sdrRest/sdrRest2 (nur lesen). rscheck.py api JSON | card HTML JSON | dbcmp LZ_DB JSON | clock LZ_DB T0 | funk HTML"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import time


def load(p):
    return json.load(open(p, encoding="utf-8"))


def main(a):
    m = a[0] if a else ""
    if m == "api":
        try:
            j = load(a[1])
        except Exception as e:
            print("kein JSON: %s" % e); return 1
        pp, pw = j.get("pos_prov"), j.get("pos_wiki_n")
        ck = j.get("clock")
        if not (isinstance(j, dict) and j.get("ok") is True and isinstance(pp, dict) and isinstance(pw, int) and isinstance(ck, dict) and isinstance(ck.get("ok"), bool) and ck.get("state") in ("ok", "ungeprueft", "pausiert") and isinstance(ck.get("offline_calc"), bool) and isinstance(ck.get("cleanup"), bool) and isinstance(j.get("pos_wiki"), list)):
            print("/api/dabsql/status ohne pos_prov/pos_wiki/clock: %s" % json.dumps(j, ensure_ascii=False)[:240]); return 1
        if sum(int(v) for v in pp.values()) != int((j.get("known") or {}).get("total", -1)):
            print("pos_prov-Summe %s != bekannte Masten %s" % (sum(int(v) for v in pp.values()), (j.get("known") or {}).get("total"))); return 1
        if pw != sum(int(v) for k, v in pp.items() if "Wikipedia" in k):
            print("pos_wiki_n %s passt nicht zu pos_prov %s" % (pw, pp)); return 1
        bad = [x for x in j.get("known_list") or [] if "pos" not in x]
        if bad:
            print("known_list ohne pos-Label: %s" % bad[:1]); return 1
        pv = j.get("prov") or {}
        print("/api/dabsql/status: Koordinaten-Herkunft %s (davon %d Wikipedia), amtlich/nicht amtlich unveraendert %s, Uhr %s%s" % (
            ", ".join("%s %d" % (k, v) for k, v in pp.items()), pw, pv, "synchron/plausibel" if ck["ok"] else "NICHT synchron [%s, Offline-Rechnung %s, Aufräumen %s]" % (ck["state"], "an" if ck["offline_calc"] else "pausiert", "an" if ck["cleanup"] else "pausiert"), "" if ck["ok"] else " (%s)" % ck.get("txt"))); return 0
    if m == "card":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        j = load(a[2])
        if s.count('id="dqCard"') != 1:
            print("/dabhist: dabSql-Karte %dx" % s.count('id="dqCard"')); return 1
        if "Herkunft der Koordinaten (nur Anzeige, ändert nichts an amtlich/nicht amtlich)" not in s:
            print("/dabhist: Zeile Herkunft der Koordinaten fehlt"); return 1
        n = int(j.get("pos_wiki_n") or 0)
        if n and ("Position aus Wikipedia (%d Einträge" % n) not in s:
            print("/dabhist: Liste Position aus Wikipedia (%d Einträge) fehlt" % n); return 1
        cj = j.get("clock") or {}
        ck = cj.get("ok", True)
        if ck is False and "⏱" not in s:
            print("/dabhist: Uhr unsynchron, aber ohne Hinweiszeile"); return 1
        if ck is True and "⏱" in s:
            print("/dabhist: Hinweiszeile obwohl Uhr ok"); return 1
        if (cj.get("state") == "ungeprueft") != ("Uhr ungeprüft" in s):
            print("/dabhist: 'Uhr ungeprüft' passt nicht zum Uhr-Zustand %s" % cj.get("state")); return 1
        for ch in j.get("channels") or []:
            if ch.get("status") == "unchecked" and "nicht geprüft" not in s:
                print("/dabhist: Kanal %s nicht geprueft, aber ohne Pille" % ch.get("ch")); return 1
        print("/dabhist: Karte mit Herkunft der Koordinaten, %d Wikipedia-Positionen in der Liste, Positions-Labels an %d Mast-Zeilen, Hinweiszeile %s, Kanal nicht geprueft: %d" % (
            n, s.count("Position: "), "da (Uhr %s)" % cj.get("state") if ck is False else "aus (Uhr ok)", sum(1 for c in (j.get("channels") or []) if c.get("status") == "unchecked"))); return 0
    if m == "dbcmp":
        con = sqlite3.connect("file:%s?mode=ro" % a[1], uri=True)
        db = con.execute("SELECT COUNT(*) FROM masts WHERE status='known' AND lower(COALESCE(pos_src,'')) LIKE '%wikipedia%'").fetchone()[0]
        j = load(a[2])
        if db != j.get("pos_wiki_n"):
            print("Wikipedia-Positionen: Datenbank %d, API %s" % (db, j.get("pos_wiki_n"))); return 1
        am = con.execute("SELECT src_kind, COUNT(*) FROM masts GROUP BY src_kind").fetchall()
        if {str(k or "?"): v for k, v in am} != {str(k): v for k, v in (j.get("prov") or {}).items()}:
            print("amtlich/nicht amtlich: Datenbank %s, API %s" % (am, j.get("prov"))); return 1
        print("Datenbank = API: %d Wikipedia-Positionen, amtlich/nicht amtlich %s unveraendert" % (db, {str(k or "?"): v for k, v in am})); return 0
    if m == "clock":
        con = sqlite3.connect("file:%s?mode=ro" % a[1], uri=True)
        r = con.execute("SELECT v FROM meta WHERE k='dabsql_clock'").fetchone()
        if not r:
            print("meta dabsql_clock noch nicht geschrieben"); return 1
        d = json.loads(r[0])
        if int(d.get("t") or 0) < int(a[2]):
            print("meta dabsql_clock alt (t=%s)" % d.get("t")); return 1
        try:
            o = subprocess.run(["timedatectl", "show", "-p", "NTPSynchronized", "--value"], capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            o = "?"
        print("Uhr-Merker dabsql_clock: state=%s ok=%s%s, ntp=%s (timedatectl NTPSynchronized=%s)%s" % (d.get("state", "?"), d.get("ok"), (" (%s)" % d.get("why")) if d.get("why") else "", d.get("ntp"), o,
                                                                                           "" if d.get("ok") else " - HINWEIS: Aufräumen pausiert, bis die Uhr synchron ist; Offline-Rechnung %s" % ("läuft (Uhr ungeprüft)" if d.get("calc") else "pausiert"))); return 0
    if m == "funk":
        s = open(a[1], encoding="utf-8", errors="replace").read()
        for k in ("function nm(k,d)", "function nmx(k,d)", "nm('s2','Stick 2')", "nmx('s2','Stick 2')"):
            if k not in s:
                print("/funk: JS ohne %s" % k); return 1
        print("/funk: Alarm-/Voralarm-Knopf-Texte mit Registernamen (nm/nmx, Rueckfall unveraendert ohne Register)"); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
RCK_EOF
EXPECT_HCK="79eae218cec6e169ceffac4b761478c303bea624d437035d9d737bbb6b2f3bf9"
cat > "$W/shcheck.py" << 'HCK_EOF'
"""Pruefhilfe sdrHalt (nur lesen). shcheck.py unit SHOW_DATEI | state DASH_DIR
unit: Ausgabe von systemctl show -p Restart -p RestartUSec -p StartLimitIntervalUSec -p WatchdogUSec -p NotifyAccess -p NRestarts prepper-sdr"""
import json
import os
import sys


def main(a):
    m = a[0] if a else ""
    if m == "unit":
        kv = {}
        for ln in open(a[1], encoding="utf-8", errors="replace").read().splitlines():
            if "=" in ln:
                k, v = ln.split("=", 1)
                kv[k.strip()] = v.strip()
        want = {"Restart": ("always",), "RestartUSec": ("20s", "20000000"), "StartLimitIntervalUSec": ("0", "infinity"), "WatchdogUSec": ("5min", "300s", "300000000"), "NotifyAccess": ("main",)}
        bad = ["%s=%s (erwartet %s)" % (k, kv.get(k), "/".join(v)) for k, v in want.items() if kv.get(k) not in v]
        if bad:
            print("Unit-Werte: " + "; ".join(bad)); return 1
        print("Unit prepper-sdr: Restart=always, RestartSec 20 s, StartLimitIntervalSec=0 (kein Start-Limit), WatchdogSec 5 min, NotifyAccess=main, bisherige Auto-Neustarts %s" % kv.get("NRestarts", "?")); return 0
    if m == "state":
        p = os.path.join(a[1], "sdr_halt.json")
        if not os.path.isfile(p):
            print("sdr_halt.json noch nicht da (noch nie ein Neustart durch den Waechter - normal)"); return 0
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as e:
            print("sdr_halt.json kaputt: %s" % e); return 1
        if not isinstance(d, dict) or not isinstance(d.get("restarts"), list):
            print("sdr_halt.json: restarts fehlt"); return 1
        print("sdr_halt.json: %d Waechter-Neustarts gespeichert" % len(d["restarts"])); return 0
    print("unbekannt"); return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
HCK_EOF
EXPECT_AC="18e60b32ea5f0d61a7f7f992e500699693731f734370ed3e411781ca840c66dc"
cat > "$W/aircheck.py" << 'AIC_EOF'
"""sdrAir Pruefungen fuer apply-sdrair.sh (nur lesen, ausser 'cfg' = sdr_config.json Geraete-Register schreiben, atomar).
airspy SYSFS | fe WELLE | cfg DIR AIRSN FE | status DIR T0 | funk HTML | ui JSON | t2 JSON | port N"""
import json
import os
import re
import subprocess
import sys
import time

AIR = ("1d50", "60a1")
RTL = (("0bda", "2838"), ("0bda", "2832"))
S1, S2 = "19348831", "72055505"


def rd(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def norm(s):
    s = (s or "").strip().upper()
    for pre in ("AIRSPY SN:", "0X"):
        if s.startswith(pre):
            s = s[len(pre):].strip()
    return s


def newest(d, name, key):
    """sqlC: Stand liegt primaer in lagezentrum.db (Tabelle state), JSON nur Notkopie -> neuerer von beiden (nur lesen)."""
    best = {}
    try:
        import sqlite3
        c = sqlite3.connect("file:%s?mode=ro" % os.path.join(d, "lagezentrum.db"), uri=True, timeout=10)
        try:
            r = c.execute("SELECT json FROM state WHERE key=?", (key,)).fetchone()
            best = json.loads(r[0]) if r else {}
        finally:
            c.close()
    except Exception:
        best = {}
    try:
        j = json.load(open(os.path.join(d, name), encoding="utf-8"))
        if float(j.get("t") or 0) > float(best.get("t") or 0) or not best:
            best = j
    except Exception:
        pass
    return best if isinstance(best, dict) else {}


def scan(root):
    air, rtl = [], []
    for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        p = os.path.join(root, d)
        v, i = rd(os.path.join(p, "idVendor")).lower(), rd(os.path.join(p, "idProduct")).lower()
        if (v, i) == AIR:
            air.append((d, norm(rd(os.path.join(p, "serial")))))
        elif (v, i) in RTL:
            rtl.append((d, rd(os.path.join(p, "serial"))))
    return air, rtl


def main(a):
    m = a[0]
    if m == "airspy":
        air, rtl = scan(a[1])
        info = "RTL: %s" % (", ".join("%s SN %s" % x for x in rtl) or "keiner")
        if not air:
            print("kein Airspy (USB 1d50:60a1) gefunden · %s" % info); return 2
        if len(air) > 1:
            print("mehrere Airspy gefunden (%s) - Rolle 11D nicht eindeutig · %s" % (", ".join("%s SN %s" % x for x in air), info)); return 3
        sn = air[0][1]
        if not re.fullmatch(r"[0-9A-F]{16}", sn):
            print("Airspy-Seriennummer unlesbar (%r) · %s" % (sn, info)); return 4
        print(sn)
        print("Airspy SN %s an %s · %s" % (sn, air[0][0], info), file=sys.stderr)
        return 0
    if m == "fe":
        w = a[1]
        try:
            l = subprocess.run(["ldd", w], capture_output=True, text=True, timeout=20).stdout
        except Exception as e:
            print("ldd %s: %s" % (w, e)); return 1
        if "libairspy" in l:
            print("airspy"); return 0
        if "libSoapySDR" in l:
            try:
                s = subprocess.run(["SoapySDRUtil", "--info"], capture_output=True, text=True, timeout=30)
                t = (s.stdout + s.stderr).lower()
            except Exception as e:
                print("welle-cli mit SoapySDR, aber SoapySDRUtil fehlt (%s) - Airspy-Modul nicht pruefbar" % e); return 1
            if "airspy" in t:
                print("soapy"); return 0
            print("welle-cli mit SoapySDR, aber kein SoapySDR-Airspy-Modul (soapysdr-module-airspy)"); return 1
        print("welle-cli ohne Airspy-Unterstuetzung (weder libairspy noch SoapySDR gelinkt)"); return 1
    if m == "cfg":
        d, sn, fe = a[1], a[2], a[3]
        assert re.fullmatch(r"[0-9A-F]{16}", sn) and fe in ("airspy", "soapy")
        p = os.path.join(d, "sdr_config.json")
        c = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
        devs = [{"name": "Airspy R2", "kind": "airspy", "usb": "1d50:60a1", "serial": sn, "role": "11D"},
                {"name": "Stick 1", "kind": "rtl", "usb": "0bda:2838", "serial": S1, "role": "5C", "ppm_sfx": ""},
                {"name": "Stick 2", "kind": "rtl", "usb": "0bda:2838", "serial": S2, "role": "hobby", "ppm_sfx": "2"}]
        old = [{k: x.get(k) for k in ("name", "kind", "usb", "serial", "role", "ppm_sfx") if k in x} for x in c.get("devs") or [] if isinstance(x, dict)]
        keep = [x for x in old if x.get("serial") not in (sn, S1, S2)]       # spaeter eingetragene Geraete (3. Stick) bleiben
        new = devs + keep
        if c.get("devs_on") is True and c.get("air_fe") == fe and old == new:
            print("unveraendert (devs_on, %d Geraete, air_fe %s)" % (len(new), fe)); return 0
        c.update(devs_on=True, devs=new, air_fe=fe)
        t = p + ".sdrair-tmp"
        with open(t, "w", encoding="utf-8") as f:
            json.dump(c, f, ensure_ascii=False, indent=1)
            f.flush(); os.fsync(f.fileno())
        if os.path.exists(p):
            st = os.stat(p)
            try:
                os.chown(t, st.st_uid, st.st_gid)
            except OSError:
                pass
            os.chmod(t, st.st_mode & 0o777)
        os.replace(t, p)
        print("geschrieben: devs_on, Airspy R2 %s = 11D, Stick 1 %s = 5C, Stick 2 %s = Hobby%s, air_fe %s" % (sn, S1, S2, (", %d weitere behalten" % len(keep)) if keep else "", fe)); return 0
    if m == "status":
        d, t0 = a[1], float(a[2])
        st = newest(d, "sdr_status.json", "sdr_status")
        if not st:
            print("kein SDR-Status (DB/JSON)"); return 1
        if float(st.get("t") or 0) < t0:
            print("Status noch alt"); return 1
        du = st.get("dual") or {}
        if not du.get("reg"):
            print("Status ohne Geraete-Register (dual.reg)"); return 1
        dv = {x.get("role"): x for x in st.get("devs") or [] if isinstance(x, dict)}
        a1 = dv.get("11D") or {}
        dev = st.get("dev") or {}
        dm = ((newest(d, "broadcast_state.json", "broadcast_state").get("dab") or {}).get("11D") or {}).get("demod") or {}
        m11 = dm.get("sn") == a1.get("serial") and float(dm.get("t") or 0) >= t0          # 11D-Messung nach dem Neustart vom Airspy
        ran = m11 or str(st.get("active") or "").startswith("dab")
        if not a1.get("present") or a1.get("state") != "aktiv" or not ran:
            print("Airspy 11D nicht aktiv (angesteckt %s, %s, jetzt %s, 11D-Messung %s SN %s, Fehler %s)" % (a1.get("present"), a1.get("state"), st.get("active"), dm.get("t"), dm.get("sn"), str(st.get("err") or st.get("pin_err") or "")[:120])); return 1
        cpu = (dev.get("cpu") or {})
        print("11D vom Airspy: %s · Geraete: %s · Airspy %s · welle-cli CPU %s" % ("Sync %s, SNR %s, %s" % (dm.get("sync"), dm.get("snr"), dm.get("gain_db")) if m11 else "laeuft (noch keine Messung)",", ".join("%s=%s(%s)" % (x.get("name"), x.get("role") or "ohne Rolle", x.get("state")) for x in st.get("devs") or []),
                                                          dev.get("fe"), ("%s %% (5 min Mittel %s %%)" % (cpu.get("pct"), cpu.get("avg"))) if cpu else "noch nicht gemessen"))
        return 0
    if m == "funk":
        h = rd(a[1])
        for k in ("var AIR=", "erkannt, ohne Rolle", "s2s.style.display=(D2&&D2.air)"):
            if k not in h:
                print("/funk ohne sdrAir-Anzeige (%s)" % k); return 1
        print("/funk mit sdrAir-Anzeige (Geraetenamen, ohne Rolle, kein Uebernahme-Knopf)"); return 0
    if m == "ui":
        u = (json.load(open(a[1], encoding="utf-8")).get("dual") or {})
        if not u.get("reg") or "Airspy" not in str(u.get("label1")):
            print("/api/sdr/ui ohne Geraete-Register (%s)" % str(u)[:160]); return 1
        print("/api/sdr/ui: %s · %s" % (u.get("label1"), u.get("mode"))); return 0
    if m == "t2":
        t = json.load(open(a[1], encoding="utf-8"))
        if not t.get("air") or (t.get("takeover") or {}).get("on"):
            print("/api/t2/status: air=%s Uebernahme an=%s" % (t.get("air"), (t.get("takeover") or {}).get("on"))); return 1
        print("/api/t2/status: Geraete-Register an, Uebernahme aus (%s)" % ((t.get("takeover") or {}).get("off_by") or "war aus")); return 0
    if m == "port":
        n = int(a[1])
        s = rd("/proc/net/tcp") + "\n" + rd("/proc/net/tcp6")
        if any(len(x.split()) > 3 and x.split()[1].endswith(":%04X" % n) and x.split()[3] == "0A" for x in s.splitlines()):
            print("Port %d lauscht" % n); return 0
        print("Port %d lauscht nicht" % n); return 1
    print(__doc__); return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
AIC_EOF
EXPECT_FC="d570fbd0611aa288a86ac193f77a931efc373d5b1a2ce779416b2a06c9d446ba"
cat > "$W/fucheck.py" << 'WDF_EOF'
"""Pruefhilfen sdrLog/funkUI (nur lesen). fucheck.py funk|dabhist|meteor DATEI [W] | thumb BASIS | live DATEI | techlog BASIS | pil"""
import json, os, re, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="funkui-js"', 'id="funkui-css"', 'id="fu-meteor"', "#t2Tile,#t4Sdr{display:none", 'id="t4-data"', 'id="t2-data"', 'id="sdrui-data"', 'id="stickTestCard"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="funkui-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "funkui.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    import shutil
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: JavaScript fehlerhaft")
    print("/funk: Funk-Lage, Steuerung, Meteor-Kachel eingehaengt (1x), alte Kacheln Sticks/SDR-Status verborgen, Antennentest vorhanden")
elif a == "dabhist":
    s = rd(sys.argv[2])
    assert "fu-chips" in s and "<table" not in s and "Programm-Infos" in s and "Grenzwerte" in s, "/dabhist ohne Karten/Filter"
    print("/dabhist: Karten, 44-px-Filter (Programm-Infos aus), %d Eintraege angezeigt" % s.count('class="fu-ev '))
elif a == "meteor":
    s = rd(sys.argv[2])
    assert "fu-wrap" in s and "Überflüge" in s and "<table" not in s, "/meteor ohne neue Seite"
    print("/meteor: Karten-Seite, %d Bilder, %d Vorschau-Verweise" % (s.count('class="fu-th"'), s.count("/meteor/thumb/")))
elif a == "thumb":
    d = os.path.join(sys.argv[2], "meteor")
    r = re.compile(r"^[0-9]{8}-[0-9]{4}_[A-Za-z0-9]{1,8}_[A-Za-z0-9_-]{1,40}\.(jpg|png)$")
    fs = sorted((f for f in os.listdir(d) if r.match(f)), reverse=True) if os.path.isdir(d) else []
    print(fs[0] if fs else "")
elif a == "live":
    d = json.load(open(sys.argv[2]))
    w = d.get("watchdog") or {}
    print("/api/sdr/live: Status %s, Lebenszeichen %s%s" % (d.get("status"), w.get("src") or "DB", (" (%s)" % w.get("note_mem")) if w.get("note_mem") else ""))
elif a == "techlog":
    try:
        d = json.load(open(os.path.join(sys.argv[2], "sdr_techlog.json")))
        ev = d.get("ev") or []
        print("sdr_techlog.json: %d Eintraege%s" % (len(ev), (", zuletzt %s: %s" % (time.strftime("%d.%m. %H:%M", time.localtime(ev[-1]["t"])), str(ev[-1].get("text"))[:120])) if ev else ""))
    except FileNotFoundError:
        print("sdr_techlog.json: noch nicht vorhanden (entsteht beim ersten Technik-Ereignis)")
elif a == "pil":
    for py in sys.argv[2:]:
        r = subprocess.run([py, "-c", "import PIL; print(PIL.__version__)"], capture_output=True, text=True)
        print("  %s: PIL %s" % (py, r.stdout.strip() if r.returncode == 0 else "fehlt (Vorschaubilder aus, Seite zeigt Originale)"))
WDF_EOF
EXPECT_WC="5641abe55b10e371b440b0ff9b2a590041113b29ab490d3c8951264d0469d3bc"
cat > "$W/wdcheck.py" << 'WDK_EOF'
"""Pruefhilfen sdrWd (nur lesen). wdcheck.py helper DATEI | funk DATEI W | pi DATEI | api DATEI | state BASIS | sudoers DATEI NUTZER HELFER | masts DATEI N11 N5C N10C | tii DATEI | cfg BASIS | br24 DATEI"""
import ast, json, os, re, shutil, subprocess, sys, time
a = sys.argv[1]
rd = lambda f: open(f, encoding="utf-8", errors="replace").read()
if a == "helper":
    s = rd(sys.argv[2])
    t = ast.parse(s)
    assert s.startswith("#!/usr/bin/python3 -I\n"), "Shebang"
    mods = {x.name.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.Import) for x in n.names} | {n.module.split(".")[0] for n in ast.walk(t) if isinstance(n, ast.ImportFrom)}
    assert mods <= {"fcntl", "json", "os", "re", "stat", "subprocess", "sys", "syslog", "time", "tempfile"}, mods
    calls = [n for n in ast.walk(t) if isinstance(n, ast.Call)]
    nm = lambda f: f.attr if isinstance(f, ast.Attribute) else getattr(f, "id", "")
    bad = [nm(c.func) for c in calls if nm(c.func) in ("system", "popen", "Popen", "execv", "execvp", "check_output", "call", "spawn", "fork", "eval", "exec")]
    assert not bad, bad
    assert s.count("subprocess.run") == 1 and s.count("(run or subprocess.run)([sc, \"reboot\"]") == 1, "nur systemctl reboot"
    body = s.split('"""', 2)[2]
    for k in ("uhubctl", "unbind", "power/control", "bind_ports"):
        assert k not in body, k
    assert 'VIDPID = ("0bda", "2838")' in s and 'SN_RE = re.compile(r"^[0-9]{8}$")' in s and '== "09"' in s and "USBDEVFS_RESET = 0x5514" in s
    assert 'AIR_VIDPID = ("1d50", "60a1")' in s and 'AIR_SN_RE = re.compile(r"^[0-9A-F]{16}$")' in s
    print("Hilfsprogramm: nur 0bda:2838 mit 8-stelliger bzw. Airspy 1d50:60a1 mit 16-stelliger Hex-Seriennummer (keine Hubs/Interfaces), einziger Prozess systemctl reboot (gesperrt: 1 je 55 min, 6 je 24 h), kein uhubctl/Portstrom/unbind")
elif a == "funk":
    s = rd(sys.argv[2])
    for k in ('id="sdrwd-js"', 'id="sdrwd-css"', 'id="wd-data"', 'id="funkui-js"', 'id="dh-js"'):
        assert s.count(k) == 1, "/funk: %s %dx" % (k, s.count(k))
    m = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S)
    f = os.path.join(sys.argv[3], "sdrwd.js")
    open(f, "w", encoding="utf-8").write(m.group(1))
    if shutil.which("node") and subprocess.run(["node", "--check", f]).returncode:
        raise SystemExit("/funk: sdrWd-JavaScript fehlerhaft")
    w = json.loads(re.search(r'<script type="application/json" id="wd-data">(.*?)</script>', s, re.S).group(1))
    assert "function rel(t)" in s and "x.title=full(r)" in s, "/funk: Empfaenger-Zeilen alt"
    print("/funk: Daten-Watchdog in Funk-Lage (%s: %s), Empfänger-Zeilen einzeilig, JS geprüft" % (w.get("lvl"), (w.get("short") or w.get("txt") or "")[:90]))
elif a == "pi":
    s = rd(sys.argv[2])
    i, j = s.find('id="wdPiBox"'), s.find('id="backupBox"')
    assert s.count('id="wdPiBox"') == 1 and 0 <= i < j, "/pi: Watchdog-Kachel fehlt oder nicht vor Sicherung"
    k = s.rfind("doPrepperRestore")
    last = k < 0 or (s.find('class="tile', max(k, j)) < 0 and s.find('class="card', j + 10) < 0)
    assert last, "/pi: Sicherung nicht mehr letzte Kachel"
    m = re.search(r'Pi-Neustarts heute: [0-9]+ · zuletzt [^<]*', s)
    print("/pi: Watchdog-Kachel vor Sicherung, Sicherung letzte Kachel; %s" % (m.group(0) if m else "?"))
elif a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and "reboot_line" in d, d
    print("/api/sdr/wd: %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:100], d.get("reboot_line")))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden (entsteht mit der ersten Prüfung)")
    else:
        d = json.load(open(f))
        st = d.get("sticks") or {}
        print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join("Stick %s SN %s %s" % (v.get("n"), k, ("Vorfall seit %s" % time.strftime("%d.%m. %H:%M", time.localtime(v["inc"]["since"]))) if v.get("inc") else "ok")
                                                                                     for k, v in sorted(st.items())) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "sudoers":
    f, u, h = sys.argv[2:5]
    s = rd(f)
    exp = "%s ALL=(root) NOPASSWD: %s check, %s usb-reset [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9], %s usb-reset-air %s, %s reboot\n" % (u, h, h, h, "[0-9A-F]" * 16, h)
    lines = [x for x in s.splitlines(True) if not x.startswith("#")]
    assert lines == [exp], (lines, exp)
    print("sudoers: genau eine Regel fuer %s: %s check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot" % (u, h))
elif a == "masts":
    d = json.load(open(sys.argv[2]))
    ms = d.get("masts") or {}
    want = dict(zip(("11D", "5C", "10C"), map(int, sys.argv[3:6])))
    got = {ch: len((ms.get(ch) or {}).get("tii") or []) for ch in want}
    if got != want:
        raise SystemExit("MASTS_DB noch nicht gemeldet: %s statt %s" % (got, want))
    nm = {}
    for ch, m in ms.items():
        for x in (m or {}).get("tii") or []:
            nm["%s %02d/%02d" % (ch, x["main"], x["sub"])] = x.get("mast")
    assert nm.get("11D 08/18") == nm.get("5C 12/11") == "Bamberg (Geisberg)" and nm.get("10C 07/01") == nm.get("11D 05/14") == "Nürnberg (Schweinau)", nm
    print("/api/t2/status MASTS_DB: 11D %(11D)d, 5C %(5C)d, 10C %(10C)d Sender (Namen je Standort gleich, z. B. 08/18 = 12/11 = Bamberg (Geisberg))" % got)
elif a == "tii":
    d = json.load(open(sys.argv[2]))
    assert d.get("ok") is not False and isinstance(d.get("masts"), list), str(d)[:200]
    n = {}
    for m in d["masts"]:
        for c in m.get("ch") or []:
            n[c.get("ch")] = n.get(c.get("ch"), 0) + 1
    print("/api/t4/tii Karte: %d Standorte mit Position, %d ohne; Kennungen je Kanal %s" % (len(d["masts"]), len(d.get("nopos") or []), ", ".join("%s %d" % kv for kv in sorted(n.items()))))
elif a == "cfg":
    D = {"wd_enable": True, "wd_yellow_min": 10, "wd_restart_min": 30, "wd_usb_min": 45, "wd_reboot_min": 60, "wd_reboot_min_interval_min": 60, "wd_reboot_max_fail": 3, "wd_usb_max": 2}
    try:
        c = json.load(open(os.path.join(sys.argv[2], "sdr_config.json")))
    except Exception:
        c = {}
    out = []
    for k, v in D.items():
        x = c.get(k, v) if isinstance(c, dict) else v
        out.append("%s=%s%s" % (k, ("an" if x else "aus") if k == "wd_enable" else x, "" if not isinstance(c, dict) or k not in c else " (gesetzt)"))
    print(" ".join(out))
elif a == "br24":
    d = json.load(open(sys.argv[2]))
    t = str(d.get("bc_note") or "")
    assert "abwechselnd" not in t and "Stick 1" in t, t
    print("/api/br24 Hinweis: %s" % t[:160])
WDK_EOF
EXPECT_WC2="fb2b6f1de50294433e16c3d52fd9f20ac4771bfd55bed95782a61a16cc09432f"
cat > "$W/wdcheck2.py" << 'WDK2_EOF'
"""Pruefhilfen sdrWd2 (nur lesen). wdcheck2.py api DATEI | state BASIS | dashok DASHBOARD BLOCK | funk HTML"""
import json, os, re, sys, time
a = sys.argv[1]
hm = lambda t: time.strftime("%d.%m. %H:%M", time.localtime(t)) if isinstance(t, (int, float)) else "–"
if a == "api":
    d = json.load(open(sys.argv[2]))
    assert d.get("lvl") in ("ok", "gelb", "rot", "grau") and isinstance(d.get("sticks"), list), str(d)[:200]
    for s in d["sticks"]:
        assert all(k in s for k in ("short", "pre", "to")), "Stick %s ohne sdrWd2-Felder (short/pre/to): sdr_manager alt?" % s.get("n")
    print("/api/sdr/wd (sdrWd2): %s · %s · %s" % (d["lvl"], (d.get("short") or d.get("txt") or "")[:110], " | ".join(
        "Stick %s %s%s%s" % (s.get("n"), s.get("lvl"), " Übernahme" if s.get("to") else "", " vor Start" if s.get("pre") else "") for s in d["sticks"])))
elif a == "state":
    f = os.path.join(sys.argv[2], "sdr_wd.json")
    if not os.path.exists(f):
        print("sdr_wd.json: noch nicht vorhanden"); raise SystemExit(0)
    d = json.load(open(f))
    out = []
    for sn, v in sorted((d.get("sticks") or {}).items()):
        i = v.get("inc")
        if not i:
            out.append("Stick %s SN %s ok" % (v.get("n"), sn)); continue
        out.append("Stick %s SN %s Vorfall %s seit %s%s%s, Eskalation ab %s, Neustart %s, USB %s%s" % (
            v.get("n"), sn, i.get("ch") or "?", hm(i.get("since")), " (vor Start)" if i.get("pre") else "", " Übernahme" if i.get("to") else "", hm(i.get("t0")),
            i.get("restart_n", 0), i.get("usb_n", 0), (" · 10C %s" % ("ok " + hm(i.get("fb_ok_t")) if i.get("fb_ok") else "ohne Sync")) if i.get("fb_t") else ""))
    print("sdr_wd.json: %s; Pi-Neustarts gesamt %d, ohne Erfolg %d" % ("; ".join(out) or "noch keine Prüfung", len(d.get("reboots") or []), d.get("reboot_fail_n") or 0))
elif a == "dashok":
    s = open(sys.argv[2], encoding="utf-8").read()
    def lit(name):
        i = s.index(name + ' = r"""') + len(name + ' = r"""')
        return s[i:s.index('"""', i)]
    g = {"_WD_CSS": lit("_WD_CSS"), "_WD_JS": lit("_WD_JS")}
    exec(compile(open(sys.argv[3], encoding="utf-8").read(), "wd2_dash_block", "exec"), g)
    assert g["_wd2_dash_ok"](), "sdrWd2-Anzeige fehlt in _WD_CSS/_WD_JS"
    assert s.count("# ===== sdrWd2:") == 1 and s.index("# ===== sdrWd2:") < s.index("# ===== sdrWd:"), "Block-Reihenfolge"
    print("dashboard.py sdrWd2: Watchdog-Zeilen einzeilig (CSS), Kopfzeile immer, Tooltip/aufklappbar (JS), kein POST")
elif a == "funk":
    s = open(sys.argv[2], encoding="utf-8", errors="replace").read()
    css = re.search(r'<style id="sdrwd-css">(.*?)</style>', s, re.S).group(1)
    js = re.search(r'<script id="sdrwd-js">(.*?)</script>', s, re.S).group(1)
    assert "/* sdrWd2: Watchdog-Zeilen einzeilig */" in css and "height:1.35em;white-space:nowrap" in css and "function fx(r,k,t)" in js, "/funk: Watchdog-Zeilen alt"
    print("/funk: Watchdog-Zeilen einzeilig (feste Höhe, Kurztext mit …, voller Text per Tipp)")
WDK2_EOF
EXPECT_CK="3a6213106b1d299dbce29f237b13cdcb255661460a7d12f15c5d6455bc06cc87"
cat > "$W/sqlccheck.py" << 'WDC_EOF'
"""sqlC Pruef-/Anzeigehilfe (nur lesen). Modi: counts DB | statusfresh DIR T0 | live F | dbok F | t4 F | observe DIR SEK | audit DIR"""
import json
import os
import sqlite3
import sys
import time

KEYS = (("sdr_status.json", "sdr_status"), ("broadcast_state.json", "broadcast_state"))


def ft(t):
    try:
        return time.strftime("%H:%M:%S", time.localtime(int(t)))
    except Exception:
        return "–"


def ro(p):
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True, timeout=10)
    c.execute("PRAGMA busy_timeout=10000")
    return c


def row(p, key):
    try:
        c = ro(p)
    except Exception:
        return None
    try:
        if not c.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='state'").fetchone():
            return None
        return c.execute("SELECT ts, src_t, json, n FROM state WHERE key=?", (key,)).fetchone()
    finally:
        c.close()


def snap(base):
    p = os.path.join(base, "lagezentrum.db")
    out = {}
    for name, key in KEYS:
        r = row(p, key)
        f = os.path.join(base, name)
        out[name] = {"db_t": float(r[1] or r[0]) if r else None, "db_n": r[3] if r else None, "json_mt": os.path.getmtime(f) if os.path.exists(f) else None}
    w = row(p, "sqlb_writer")
    out["writer"] = json.loads(w[2]) if w else {}
    out["writer_t"] = float(w[1] or w[0]) if w else None
    return out


a = sys.argv[1]
now = time.time()
if a == "counts":
    c = ro(sys.argv[2])
    try:
        q = lambda s, *x: c.execute(s, x).fetchone()[0]
        st = q("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='state'")
        print("events %d (aktiv %d), telemetry %d, state %s" % (q("SELECT COUNT(*) FROM events"), q("SELECT COUNT(*) FROM events WHERE expires IS NULL OR expires >= ?", int(now)),
              q("SELECT COUNT(*) FROM telemetry"), ("%d Zeilen" % q("SELECT COUNT(*) FROM state")) if st else "fehlt"))
    finally:
        c.close()
elif a == "statusfresh":
    base, t0 = sys.argv[2], float(sys.argv[3])
    best = 0
    r = row(os.path.join(base, "lagezentrum.db"), "sdr_status")
    try:
        best = max(best, float(json.loads(r[2]).get("t") or 0)) if r else best
    except Exception:
        pass
    try:
        best = max(best, float(json.load(open(os.path.join(base, "sdr_status.json"))).get("t") or 0))
    except Exception:
        pass
    sys.exit(0 if best >= t0 else 1)
elif a == "live":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    assert t.get("line", "").startswith("Datenquelle:") and t.get("mode") in ("db", "dual", "json") and "mirror_age_s" in t and "fallback" in t, t
    w = t.get("writer") or {}
    print("/api/sdr/live Transport: Betriebsart %s, %s; Ersatz aktiv %s, JSON-Notkopie vor %s s; Schreibfaden ok %s, Fehler %s, verworfen %s, JSON-Schreibvorgaenge %s" % (
        t["mode"], t["line"], "ja" if t.get("fallback") else "nein", t.get("mirror_age_s"), w.get("ok"), w.get("err"), w.get("drop"), w.get("json_n")))
elif a == "dbok":
    d = json.load(open(sys.argv[2]))
    t = (d.get("db") or {}).get("transport") or {}
    bad = {k: v.get("why") for k, v in (t.get("items") or {}).items() if v.get("src") != "db"}
    assert t.get("mode") == "db" and not bad and not t.get("fallback") and t.get("ok"), "Betriebsart %s, nicht aus DB %s, Ersatz %s (%s)" % (t.get("mode"), bad, t.get("fallback"), t.get("line"))
    print("DB-primaer aktiv: beide aus der DB, kein JSON-Ersatz")
elif a == "t4":
    d = json.load(open(sys.argv[2]))
    t = d.get("tr") or {}
    assert t.get("line", "").startswith("Datenquelle:"), d.get("tr")
    print("/api/t4/status SDR-Status-Kachel: %s" % t["line"])
elif a == "observe":
    base, secs = sys.argv[2], int(sys.argv[3])
    s0 = snap(base)
    print("  Beobachtung %d s (nur lesen): Zeit | Status DB-Alter | Status JSON-Alter | Rundfunk DB-Alter | Rundfunk JSON-Alter | Ersatz" % secs)
    ok, n, chg = True, 0, {k: 0 for k, _ in KEYS}
    last = {k: s0[k]["json_mt"] for k, _ in KEYS}
    end = time.time() + secs
    while True:
        s = snap(base)
        t = time.time()
        ag = lambda v: ("%d s" % (t - v)) if v else "–"
        fb = (s["writer"] or {}).get("fallback")
        print("  %s | %s | %s | %s | %s | %s" % (ft(t), ag(s["sdr_status.json"]["db_t"]), ag(s["sdr_status.json"]["json_mt"]), ag(s["broadcast_state.json"]["db_t"]),
                                              ag(s["broadcast_state.json"]["json_mt"]), "JA" if fb else "nein"), flush=True)
        for k, _ in KEYS:
            if s[k]["json_mt"] != last[k]:
                chg[k] += 1
                last[k] = s[k]["json_mt"]
        if not s["sdr_status.json"]["db_t"] or t - s["sdr_status.json"]["db_t"] > 90:
            ok = False
        n += 1
        if time.time() >= end:
            break
        time.sleep(min(30, max(1, end - time.time())))
    s = snap(base)
    fb = (s["writer"] or {}).get("fallback")
    db_n = (s["sdr_status.json"]["db_n"] or 0) - (s0["sdr_status.json"]["db_n"] or 0)
    print("  Ergebnis: Status %d mal in die DB geschrieben, JSON-Dateien geaendert: sdr_status.json %dx, broadcast_state.json %dx (Notkopie alle 10 min), Ersatz %s" % (
        db_n, chg["sdr_status.json"], chg["broadcast_state.json"], "AKTIV" if fb else "aus"))
    good = ok and not fb and db_n >= 1 and chg["sdr_status.json"] <= 1
    print("  %s" % ("OK DB frisch, JSON-Notkopie altert, Ersatz aus" if good else "WARNUNG: DB nicht durchgehend frisch oder JSON wird laufend geschrieben (Ersatz/Anforderung?)"))
    sys.exit(0 if good else 1)
elif a == "audit":
    base = sys.argv[2]
    own = {"dashboard.py", "sdr_manager.py", "prepper_sdr.py", "database.py"}
    skip_d = {"venv", ".git", "__pycache__", "node_modules", ".cache", "archive", "mesh_inbox", "mesh_inbox_bayern", ".local", ".npm", ".mozilla", ".config"}
    hits = []
    roots = [os.path.dirname(base.rstrip("/")) or base, "/etc/systemd/system", "/etc/cron.d"]
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dp, dn, fn in os.walk(root):
            dn[:] = [x for x in dn if x not in skip_d and not x.startswith("sqlb-") and dp.count(os.sep) - root.count(os.sep) < 4]
            for f in fn:
                if ".bak" in f or f.endswith((".json", ".jsonl", ".log", ".db", ".db-wal", ".db-shm", ".tmp", ".pyc", ".jpg", ".png", ".1")) or (dp.rstrip("/") == base.rstrip("/") and f in own):
                    continue
                fp = os.path.join(dp, f)
                try:
                    if os.path.getsize(fp) > 5 * 1024 * 1024:
                        continue
                    s = open(fp, encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                if "sdr_status.json" in s or "broadcast_state.json" in s:
                    hits.append(fp)
    pat = [h for h in hits if os.path.basename(h) in own or "/src/" in h or os.path.basename(h).startswith(("apply-", "patch-", "guard_", "edits", "sql", "kv", "tii", "body", "head", "build")) or "-apply" in h or "/sbx" in h]
    oth = [h for h in hits if h not in pat]
    if not oth:
        print("  keine weiteren Leser von sdr_status.json/broadcast_state.json gefunden (ausser dashboard.py, sdr_manager.py, prepper_sdr.py - alle auf DB zuerst umgestellt)")
    for h in oth[:30]:
        print("  liest/nennt JSON direkt (bekommt die Notkopie, max. 10 min alt; laufend nur im Ersatzfall): %s" % h)
    if pat:
        print("  dazu %d alte Patch-/Pruefskripte bzw. Kopien (nur beim Einspielen benutzt, unkritisch), z. B. %s" % (len(pat), ", ".join(os.path.basename(x) for x in pat[:4])))
WDC_EOF
AC2="$W/air2check.py"; DCK="$W/dabcheck.py"; ACK="$W/atcheck.py"; RCK="$W/rscheck.py"; HCK="$W/shcheck.py"; EEF="$W/eeflash.py"; S3C="$W/s3check.py"
AC="$W/aircheck.py"; FC="$W/fucheck.py"; WC="$W/wdcheck.py"; WC2="$W/wdcheck2.py"; CK="$W/sqlccheck.py"
for x in "$EXPECT_EEF $EEF" "$EXPECT_S3C $S3C" "$EXPECT_AC2 $AC2" "$EXPECT_DCK $DCK" "$EXPECT_ACK $ACK" "$EXPECT_RCK $RCK" "$EXPECT_HCK $HCK" "$EXPECT_AC $AC" "$EXPECT_FC $FC" "$EXPECT_WC $WC" "$EXPECT_WC2 $WC2" "$EXPECT_CK $CK"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
EEF_ARGS=(--sysfs "$SYSUSB" --old "$S3_OLD" --new "$S3_NEW" --path "$S3_PATH" --state "$DASH_DIR/sdr_stick3.json" --dumpdir "$DASH_DIR/stick3-eeprom" --cfg "$CF" --ts "$TS")
if [[ "$ARG2" == pruefen ]]; then
  echo "=== sdrStick3b pruefen (nur lesen, nichts geoeffnet, nichts geaendert) ==="
  python3 "$EEF" verify "${EEF_ARGS[@]}" || true
  python3 "$S3C" cfgcheck "$CF" "$S3_NEW" > "$W/pc.log" 2>&1 && echo "OK Register-Eintrag Stick 3 (SN $S3_NEW, Hobby) in sdr_config.json" || echo "WARN Register-Eintrag fehlt/falsch: $(cat "$W/pc.log")"
  puok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/ui" -o "$W/ui.json" || true; python3 "$S3C" ui "$W/ui.json" "$SYSUSB" "$S3_OLD" "$S3_NEW" > "$W/pu.log" 2>&1 && { puok=1; break; }; sleep 6; done
  [[ "$puok" == 1 ]] && echo "OK /api/sdr/ui: $(cat "$W/pu.log")" || echo "WARN /api/sdr/ui: $(cat "$W/pu.log")"
  JPV=$(journalctl -u prepper-sdr --since "-2 hours" --no-pager -o cat 2>/dev/null | grep -E "^sdrStick3:" | tail -3 || true)
  echo "Journal prepper-sdr (letzte 2 h, sdrStick3): ${JPV:-keine Zeile (oder Journal ohne sudo nicht lesbar)}"
  exit 0
fi
# ---------- 1) Basis (streng: genau der sdrStick3-Stand, sonst Abbruch ohne Aenderung) ----------
for x in "$F" "$SMF" "$DBF" "$M" "$MR"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
s16() { sha256sum "$1" | cut -c1-16; }
D16=$(s16 "$F"); SM16=$(s16 "$SMF"); DB16=$(s16 "$DBF"); SDR16=$(s16 "$M"); MR16=$(s16 "$MR"); LG16=$( [[ -f "$LG" ]] && s16 "$LG" || echo fehlt)
echo "Basis prepper_sdr.py sha16 $SDR16 ($(wc -l < "$M") Zeilen, erwartet sdrStick3 $KNOWN_SDR16N)"
echo "Basis sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, erwartet $KNOWN_SM16N)"
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, erwartet sdrStick3 $KNOWN_D16N)"
echo "database.py sha16 $DB16, mesh_router.py sha16 $MR16, lagegeo.py sha16 $LG16 - bleiben unveraendert"
bad=""
[[ "$SDR16" == "$KNOWN_SDR16N" ]] || bad="$bad prepper_sdr.py (sha16 $SDR16, erwartet $KNOWN_SDR16N = sdrStick3);"
[[ "$SM16" == "$KNOWN_SM16N" ]] || bad="$bad sdr_manager.py (sha16 $SM16, erwartet $KNOWN_SM16N);"
[[ "$D16" == "$KNOWN_D16N" ]] || bad="$bad dashboard.py (sha16 $D16, erwartet $KNOWN_D16N = sdrStick3);"
[[ "$DB16" == "$KNOWN_DB16" ]] || bad="$bad database.py (sha16 $DB16, erwartet $KNOWN_DB16);"
[[ "$MR16" == "$KNOWN_MR16" ]] || bad="$bad mesh_router.py (sha16 $MR16, erwartet $KNOWN_MR16);"
[[ "$LG16" == "$KNOWN_LG16" || "$LG16" == fehlt ]] || bad="$bad lagegeo.py (sha16 $LG16, erwartet $KNOWN_LG16);"
if [[ -n "$bad" ]]; then
  echo "STOP: Pi-Stand weicht vom erwarteten sdrStick3-Stand ab:$bad"
  echo "      sdrStick3b passt nur auf den installierten sdrStick3-Stand (prepper_sdr $KNOWN_SDR16N, sdr_manager $KNOWN_SM16N, dashboard $KNOWN_D16N) - nichts geaendert. Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
echo "OK Basis = sdrStick3 (alle sha16 bekannt), sdrStick3b aendert keine Programmdatei"
grep -q '# ===== sdrStick3:' "$M" && grep -q '# ===== sdrStick3:' "$F" || { echo "STOP: sdrStick3-Block fehlt - nichts geaendert"; exit 1; }
python3 "$S3C" cfgcheck "$CF" "$S3_NEW" > "$W/cfgc.log" 2>&1 || { cat "$W/cfgc.log"; echo "STOP: Register-Eintrag Stick 3 (SN $S3_NEW, Hobby) fehlt oder ist falsch in sdr_config.json - sdrStick3 nicht vollstaendig installiert - nichts geaendert"; exit 1; }
echo "OK Register-Eintrag Stick 3 (SN $S3_NEW, Hobby) in sdr_config.json vorhanden: $(cat "$W/cfgc.log" | cut -c1-200)"
[[ -x "$HDST" ]] || { echo "STOP: Hilfsprogramm $HDST fehlt - nichts geaendert"; exit 1; }
HL16=$(s16 "$HDST")
[[ "$HL16" == "$KNOWN_HL16" ]] || { echo "STOP: Hilfsprogramm sha16 $HL16 statt $KNOWN_HL16 (sdrAir) - nichts geaendert"; exit 1; }
echo "OK Hilfsprogramm $HDST sha16 $HL16 (bleibt)"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - nichts geaendert"; exit 1; }
done
AIRSN=$(python3 "$AC" airspy "$SYSUSB" 2>"$W/air.log") || { echo "$AIRSN"; echo "STOP: Airspy nicht eindeutig - nichts geaendert"; exit 1; }
[[ "$AIRSN" =~ ^[0-9A-F]{16}$ ]] || { echo "STOP: Airspy-Seriennummer $AIRSN - nichts geaendert"; exit 1; }
echo "OK $(cat "$W/air.log")"

# ---------- 1b) sudo-Regel pruefen (ohne gemerktes Passwort, nur lesen/check) ----------
SU=$(systemctl show -p User --value prepper-sdr 2>/dev/null || true); [[ -z "$SU" ]] && SU=root
if ! [[ "$SU" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "STOP: Benutzer von prepper-sdr unklar ($SU) - nichts geaendert"; exit 1; fi
asu() { if [[ "$(id -un)" == "$SU" ]]; then setsid -w "$@" < /dev/null; else sudo -n -u "$SU" setsid -w "$@" < /dev/null; fi; }
slist() { if [[ "$(id -un)" == "$SU" ]]; then sudo -n -l "$@"; else sudo -n -l -U "$SU" "$@"; fi; }
WD_SUDO_ERR=""; WD_SUDO_OK=""
wd_sudo_verify() {
  local c out rc
  for c in "check" "usb-reset 19348831" "usb-reset-air $AIRSN" "reboot"; do
    rc=0; slist "$HDST" $c > "$W/sl.log" 2>&1 || rc=$?
    [[ "$rc" == 0 ]] || { WD_SUDO_ERR="sudo -l: $HDST $c fuer $SU nicht erlaubt (rc $rc: $(head -c 200 "$W/sl.log" | tr '\n' ' '))"; return 1; }
  done
  # sudo -k: gemerktes Passwort (z. B. vom sudo -v dieses Skripts, Zeitstempel global) zaehlt nicht - nur die NOPASSWD-Regel
  rc=0; out=$(asu sudo -k -n "$HDST" check 2>&1) || rc=$?
  [[ "$rc" == 0 && "$out" == *"bereit (uid 0)"* ]] || { WD_SUDO_ERR="$SU kann $HDST check nicht ohne Passwort und ohne Terminal ausfuehren (rc $rc: $(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-200))"; return 1; }
  rc=0; asu sudo -k -n true > /dev/null 2>&1 || rc=$?
  slist > "$W/slall.log" 2>&1 || true
  if [[ "$rc" == 0 ]] && grep -qE 'NOPASSWD: *ALL *$' "$W/slall.log"; then
    WD_SUDO_OK="$HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex> | reboot ohne Passwort geprueft (sudo -k, ohne Terminal); Hinweis: $SU hat laut sudo -l NOPASSWD: ALL - Gegenprobe entfaellt"; return 0
  fi
  for c in "selftest" "usb-reset 1234" "usb-reset 19348831 x" "usb-reset ../x" "usb-reset-air 1234" "usb-reset-air ${AIRSN,,}" "usb-reset-air $AIRSN x" "usb-reset-air ../x"; do
    rc=0; out=$(asu sudo -k -n "$HDST" $c 2>&1) || rc=$?
    [[ "$rc" != 0 && "$out" == sudo:* ]] || { WD_SUDO_ERR="sudo erlaubt zu viel ohne Passwort: $HDST $c (rc $rc)"; return 1; }
  done
  WD_SUDO_OK="nur $HDST check | usb-reset <8 Ziffern> | usb-reset-air <16 Hex gross> | reboot ohne Passwort (sudo -k, ohne Terminal wie im Dienst), andere Aufrufe verlangen Passwort; allgemeines sudo verlangt Passwort"
}
if [[ "$SU" != root ]]; then
  wd_sudo_verify || { echo "STOP: sudo-Regel: $WD_SUDO_ERR - nichts geaendert"; exit 1; }
  echo "OK sudo-Regel fuer $SU: $WD_SUDO_OK"
fi
python3 "$AC2" namestest > "$W/nt.log" 2>&1 && echo "$(tail -1 "$W/nt.log")" || { cat "$W/nt.log"; echo "STOP: Namens-Pruefung selbst fehlerhaft - nichts geaendert"; exit 1; }
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/sdr/wd /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map /api/t4/tii /api/meteor /api/sdr/status)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
echo "Watchdog vorher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-360)"
[[ -f "$LZ" ]] && echo "lagezentrum.db vorher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
ATREQ0=0; [[ -f "$DASH_DIR/sdr_airtest_req.json" ]] && ATREQ0=1
# ---------- 2b) Stick 3: EEPROM-Stufe (nur mit Schutzvorkehrungen, nur nach JA) ----------
EE_STOPPED=0; EE_NOTE=""; EE_DONE=0
ee_up() { if [[ "$EE_STOPPED" == 1 ]]; then sudo systemctl start prepper-sdr.service || true; EE_STOPPED=0; fi; }
EEB=$(command -v rtl_eeprom 2>/dev/null || true); RTB=$(command -v rtl_test 2>/dev/null || true)
if [[ "$ARG2" == ohne-eeprom ]]; then
  EE_NOTE="EEPROM-Stufe mit ohne-eeprom uebersprungen - Stick 3 bleibt unveraendert"
elif [[ -z "$EEB" || -z "$RTB" ]]; then
  EE_NOTE="rtl_eeprom oder rtl_test nicht gefunden - Stick 3 bleibt unveraendert"
else
  ee=0; python3 "$EEF" plan "${EEF_ARGS[@]}" --eeprom "$EEB" --lister "$RTB" > "$W/ee_plan.log" 2>&1 || ee=$?
  sed 's/^/Stick 3: /' "$W/ee_plan.log"
  if [[ "$ee" == 20 ]]; then echo "STOP: Ziel-Seriennummer $S3_NEW schon vergeben - das Register wuerde ein fremdes Geraet als Stick 3 zeigen - nichts geaendert"; exit 1; fi
  if [[ "$ee" == 10 ]]; then
    echo "Stick 3: EEPROM-Stufe - prepper-sdr wird dafuer kurz gestoppt (Stick 3 darf nie parallel offen sein), danach wird prepper-sdr wieder gestartet"
    sudo -v
    trap 'echo; echo "Abbruch - starte prepper-sdr wieder"; sudo systemctl start prepper-sdr.service || true; exit 130' INT TERM
    sudo systemctl stop prepper-sdr.service
    EE_STOPPED=1
    trap ee_up EXIT
    pr=1; for i in 1 2 3 4 5 6; do
      pr=0; python3 "$EEF" prepare "${EEF_ARGS[@]}" --eeprom "$EEB" --lister "$RTB" > "$W/ee_prep.log" 2>&1 || pr=$?
      [[ "$pr" == 21 ]] && grep -q "in Benutzung" "$W/ee_prep.log" && { sleep 5; continue; }
      break
    done
    sed 's/^/Stick 3: /' "$W/ee_prep.log"
    if [[ "$pr" == 0 ]]; then
      echo ""
      echo "Stick 3: Seriennummer $S3_OLD -> $S3_NEW jetzt ins EEPROM schreiben? (Sicherung und Trockenlauf siehe oben; Wirkung erst nach Neueinstecken)"
      echo "         Zum Schreiben JA eintippen + Enter, alles andere (oder 180 s nichts) = nicht schreiben:"
      ans=""
      if [[ -t 0 ]]; then read -r -t 180 ans || true; fi  # EEPROM-Frage
      if [[ "$ans" == JA ]]; then
        ew=0; ( trap '' INT TERM; python3 "$EEF" write "${EEF_ARGS[@]}" --eeprom "$EEB" --lister "$RTB" ) > "$W/ee_write.log" 2>&1 || ew=$?
        sed 's/^/Stick 3: /' "$W/ee_write.log"
        case "$ew" in
          0) EE_DONE=1; EE_NOTE="EEPROM von Stick 3 geschrieben und nachgeprueft (SN $S3_OLD -> $S3_NEW, Sicherung $DASH_DIR/stick3-eeprom/)";;
          3) EE_NOTE="EEPROM von Stick 3 NICHT geschrieben (Pruefung vor/nach dem Schreiben nicht bestanden, alter Stand) - es wird nichts weiter geaendert; spaeter erneut starten";;
          4) EE_NOTE="EEPROM-Schreiben wich ab, alter EEPROM-Stand wiederhergestellt und bestaetigt - es wird nichts weiter geaendert; Ausgabe an Grok schicken";;
          *) trap - INT TERM; ee_up; echo "STOP: EEPROM von Stick 3 nach Schreibversuch NICHT bestaetigt (Wiederherstellung fehlgeschlagen) - Sicherung unter $DASH_DIR/stick3-eeprom/, Wiederherstellung von Hand: rtl_eeprom -d INDEX -w <Sicherung> (INDEX aus rtl_test)"; exit 1;;
        esac
      else
        EE_NOTE="EEPROM von Stick 3 nicht geschrieben (keine Eingabe JA) - spaeter dieses Skript erneut starten"
      fi
    else
      EE_NOTE="EEPROM-Vorbereitung nicht moeglich (siehe Zeilen 'Stick 3:' oben) - Stick 3 unveraendert"
    fi
    trap - INT TERM EXIT
  elif [[ "$ee" == 21 ]]; then
    EE_NOTE="EEPROM nicht geaendert (kein eindeutiger Stick 3 am erwarteten Port, siehe oben)"
  else
    EE_NOTE="EEPROM nichts zu tun (siehe oben)"
  fi
fi
echo "Stick 3: $EE_NOTE"
# ---------- 3) Neustart nur wenn fuer die EEPROM-Stufe gestoppt; Dateien werden nie geaendert (Strg-C wird ignoriert) ----------
trap '' INT
RESTARTED=0
T0=$(( $(date +%s) - 86400 ))
TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
[[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
if [[ "$EE_STOPPED" == 1 ]]; then
  sudo -v
  T0=$(date +%s); echo "Start prepper-sdr (war fuer die EEPROM-Stufe gestoppt) - warte auf frischen SDR-Status (max 240 s) und 11D-Sync (max 300 s) ..."
  ee_up
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && python3 "$AC" status "$DASH_DIR" "$T0" > "$W/ast.log" 2>&1 && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { cat "$W/ast.log"; echo "FEHLER: prepper-sdr: Airspy 11D laeuft nach dem Start nicht ($(head -c 200 "$W/ast.log")) - Dateien unveraendert"; exit 1; }
  sok=0; for i in $(seq 1 100); do python3 "$AC2" proof "$DASH_DIR" "$T0" > "$W/proof.log" 2>&1 && { sok=1; break; }; sleep 3; done
  [[ "$sok" == 1 ]] && echo "OK $(cut -c1-300 "$W/proof.log")" || { cat "$W/proof.log"; echo "FEHLER: 11D-Sync nach dem Start nicht nachgewiesen"; exit 1; }
else
  echo "OK prepper-sdr/prepper-dashboard wurden nicht angefasst (kein Neustart, keine Dateiaenderung)"
fi
rbx() { echo "FEHLER: $1 - keine Datei geaendert; prepper-sdr/prepper-dashboard laufen (sdrStick3-Stand unveraendert)"; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in / /funk /pi /dabhist /karte /api/sdr/wd /api/sdr/ui /api/t2/status /api/t4/status /api/t4/tii /api/br24; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
"${CURL[@]}" "$B/funk" -o "$W/funk.html" || true
python3 "$FC" funk "$W/funk.html" "$W" > "$W/fc.log" 2>&1 && echo "OK $(cat "$W/fc.log")" || { cat "$W/fc.log"; rbx "/funk ohne funkUI"; }
python3 "$WC" funk "$W/funk.html" "$W" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne Daten-Watchdog"; }
python3 "$WC2" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk Watchdog-Zeilen"; }
python3 "$AC" funk "$W/funk.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/funk ohne sdrAir-Anzeige"; }
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x)" || rbx "/pi Sicherung veraendert ($R0/$R1)"
python3 "$WC" pi "$W/pi.html" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/pi Watchdog-Kachel"; }
"${CURL[@]}" "$B/dabhist" -o "$W/dabhist.html" || true
[[ -s "$W/dabhist.html" ]] && echo "OK /dabhist $(wc -c < "$W/dabhist.html") Bytes" || rbx "/dabhist leer"
uok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/ui" -o "$W/ui.json" || true; python3 "$AC" ui "$W/ui.json" > "$W/wc.log" 2>&1 && { uok=1; break; }; sleep 6; done
[[ "$uok" == 1 ]] && echo "OK $(cut -c1-300 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/ui ohne Geraete-Register"; }
s3ok=0; for i in $(seq 1 30); do "${CURL[@]}" "$B/api/sdr/ui" -o "$W/ui3.json" || true; python3 "$S3C" ui "$W/ui3.json" "$SYSUSB" "$S3_OLD" "$S3_NEW" > "$W/s3u.log" 2>&1 && { s3ok=1; break; }; sleep 6; done
[[ "$s3ok" == 1 ]] && echo "OK /api/sdr/ui: $(cut -c1-300 "$W/s3u.log")" || { cat "$W/s3u.log"; rbx "/api/sdr/ui: Stick 3 nicht wie erwartet im Register (Hobby bzw. ohne Rolle bis Neueinstecken)"; }
tok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/t2/status" -o "$W/t2.json" || true; python3 "$AC" t2 "$W/t2.json" > "$W/wc.log" 2>&1 && { tok=1; break; }; sleep 6; done
[[ "$tok" == 1 ]] && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t2/status Register"; }
wok=0; for i in $(seq 1 30); do "${CURL[@]}" "$B/api/sdr/wd" -o "$W/wd.json" || true; python3 "$AC2" api "$W/wd.json" > "$W/wc.log" 2>&1 && { wok=1; break; }; sleep 6; done
[[ "$wok" == 1 ]] && echo "OK $(cut -c1-400 "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/sdr/wd ohne sdrAir2-Zusammenfassung (Namen/Hobby/wird geprueft)"; }
hok=0; for i in $(seq 1 40); do python3 "$AC2" hobby "$DASH_DIR" > "$W/hb.log" 2>&1 && { hok=1; break; }; sleep 3; done
[[ "$hok" == 1 ]] && echo "OK $(cut -c1-300 "$W/hb.log")" || { cat "$W/hb.log"; rbx "alter Hobby-Vorfall nicht geschlossen"; }
"${CURL[@]}" "$B/api/t4/tii" -o "$W/tii.json" || true
python3 "$WC" tii "$W/tii.json" > "$W/wc.log" 2>&1 && echo "OK $(cat "$W/wc.log")" || { cat "$W/wc.log"; rbx "/api/t4/tii Karte"; }
dok=0; for i in $(seq 1 60); do python3 "$DCK" db "$LZ" "$T0" > "$W/dq.log" 2>&1 && { dok=1; break; }; sleep 5; done
[[ "$dok" == 1 ]] && echo "OK $(cut -c1-420 "$W/dq.log")" || { cat "$W/dq.log"; rbx "dabSql: Tabellen/Import/Aufzeichnung der Pruefungen fehlen"; }
aok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/dabsql/status" -o "$W/dqapi.json" || true; python3 "$DCK" api "$W/dqapi.json" > "$W/dqa.log" 2>&1 && { aok=1; break; }; sleep 6; done
[[ "$aok" == 1 ]] && echo "OK $(cut -c1-420 "$W/dqa.log")" || { cat "$W/dqa.log"; rbx "/api/dabsql/status"; }
python3 "$DCK" card "$W/dabhist.html" > "$W/dqc.log" 2>&1 && echo "OK $(cat "$W/dqc.log")" || { cat "$W/dqc.log"; rbx "/dabhist ohne dabSql-Zusammenfassung"; }
python3 "$ACK" page "$W/funk.html" > "$W/atp.log" 2>&1 && echo "OK $(cat "$W/atp.log")" || { cat "$W/atp.log"; rbx "/funk ohne airTest-Karte"; }
atok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/sdr/airtest" -o "$W/atapi.json" || true; python3 "$ACK" api "$W/atapi.json" > "$W/ata.log" 2>&1 && { atok=1; break; }; sleep 6; done
[[ "$atok" == 1 ]] && echo "OK $(cut -c1-300 "$W/ata.log")" || { cat "$W/ata.log"; rbx "/api/sdr/airtest"; }
python3 "$ACK" state "$DASH_DIR" > "$W/ats.log" 2>&1 && echo "OK $(cat "$W/ats.log")" || { cat "$W/ats.log"; rbx "sdr_airtest.json kaputt"; }
python3 "$HCK" state "$DASH_DIR" > "$W/hs.log" 2>&1 && echo "OK $(cat "$W/hs.log")" || { cat "$W/hs.log"; rbx "sdr_halt.json kaputt"; }
# --- sdrRest (bleibt) + sdrRest2: Herkunft der Koordinaten, Uhr (Zustand), Kanal nicht geprueft ---
rok=0; for i in $(seq 1 20); do "${CURL[@]}" "$B/api/dabsql/status" -o "$W/rsapi.json" || true; python3 "$RCK" api "$W/rsapi.json" > "$W/rsa.log" 2>&1 && { rok=1; break; }; sleep 6; done
[[ "$rok" == 1 ]] && echo "OK $(cut -c1-520 "$W/rsa.log")" || { cat "$W/rsa.log"; rbx "/api/dabsql/status ohne Koordinaten-Herkunft/Uhr-Feld"; }
"${CURL[@]}" "$B/dabhist" -o "$W/dabhist2.html" || true
python3 "$RCK" card "$W/dabhist2.html" "$W/rsapi.json" > "$W/rsc.log" 2>&1 && echo "OK $(cat "$W/rsc.log")" || { cat "$W/rsc.log"; rbx "/dabhist ohne Koordinaten-Herkunft"; }
[[ -f "$LZ" ]] && { python3 "$RCK" dbcmp "$LZ" "$W/rsapi.json" > "$W/rsd.log" 2>&1 && echo "OK $(cat "$W/rsd.log")" || { cat "$W/rsd.log"; rbx "Herkunft der Koordinaten: Datenbank und API passen nicht zusammen"; }; }
python3 "$RCK" funk "$W/funk.html" > "$W/rsf.log" 2>&1 && echo "OK $(cat "$W/rsf.log")" || { cat "$W/rsf.log"; rbx "/funk ohne Registernamen in den Knopf-Texten"; }
if [[ "$RESTARTED" == 1 && -f "$LZ" ]]; then
  cok=0; for i in $(seq 1 60); do python3 "$RCK" clock "$LZ" "$T0" > "$W/rsk.log" 2>&1 && { cok=1; break; }; sleep 5; done
  [[ "$cok" == 1 ]] && echo "OK $(cat "$W/rsk.log")" || { cat "$W/rsk.log"; rbx "Uhr-Merker dabsql_clock wird nicht geschrieben"; }
fi
atc=$(curl -s --connect-timeout 3 --max-time 20 -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"action":"start","confirm":true}' "$B/api/sdr/airtest" || true)
[[ "$atc" == 403 ]] && echo "OK POST /api/sdr/airtest ohne Funk-Seiten-Herkunft abgelehnt (403) - es wurde kein Test angefordert" || rbx "POST /api/sdr/airtest ohne Herkunft nicht abgelehnt ($atc)"
[[ ! -f "$DASH_DIR/sdr_airtest_req.json" || "$ATREQ0" == 1 ]] && echo "OK keine Test-Anforderung durch den Rauchtest (Test startet nur per Knopf/API)" || rbx "Test-Anforderungsdatei durch Rauchtest entstanden"
nok=0; for i in $(seq 1 10); do
  rm -rf "$W/nm" && mkdir -p "$W/nm"
  for p in / /funk /pi /umwelt /dabhist /mesh; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').html" || true; done
  for p in /api/sdr/ui /api/sdr/wd /api/t2/status /api/t4/status /api/dabsql/status /api/sdr/airtest; do "${CURL[@]}" "$B$p" -o "$W/nm/p_$(echo "x$p" | tr -c 'a-z0-9' '_').json" || true; done
  python3 "$AC2" names "$W/nm" > "$W/nm.log" 2>&1 && { nok=1; break; }; sleep 6
done
[[ "$nok" == 1 ]] && echo "OK $(cut -c1-300 "$W/nm.log")" || { cat "$W/nm.log"; rbx "alte Platz-Namen auf Seiten/APIs"; }
sleep 3
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
JP=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JS=$(echo "$JP" | grep -E "sdrTeil2: aktiv im Geraete-Register" | tail -1 || true)
  [[ -n "$JS" ]] && echo "OK Journal prepper-sdr: $(echo "$JS" | cut -c1-260)" || rbx "prepper-sdr meldet die Register-Rollen nicht (sdrTeil2-Zeile alt?)"
  if echo "$JP" | grep -q "Alarm-Uebernahme 5C"; then rbx "alte Zeile sdrTeil2 ... Alarm-Uebernahme 5C noch im Journal"; fi
  echo "OK Journal prepper-sdr: keine alte Zeile Alarm-Uebernahme 5C seit Neustart"
fi
R1='Traceback|sdrStick3 (Register|Geraete)|airTest (Tick|Befehl|Messung|Fehler|Standard-Gain pruefen|speichern|Anzeige)|sdrHalt( Start:|: (Waechter|Sperrgrund merken|Hilfsprogramm-Pruefung:|Neustart-Zaehler|Planer-Faden))|sdrRest (Karte|Anzeige)|sdrRest2 (Karte|Anzeige)|dabSql( Start| on_dab)|dabSql: (Schreibfehler|Tabellen|Lesen|kartevec-Import|Schreibfaden nicht)|^sdrAir2? [A-Za-z/ ]*:|sdrWd2? (Start|Pruefung|Anzeige|speichern|Zustand|Technik|Umstellung|Vorfall|Rueckfall|Bezugszeit|Uebernahme)|^sdrWd2?:'
E1=$(echo "$JP" | grep -c -E "$R1" || true)
[[ "${E1:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JP" | grep -E "$R1" | head -5 | cut -c1-240; rbx "$E1 Traceback/Fehlerzeilen im Journal prepper-sdr"; }
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null || true)
if [[ "$RESTARTED" == 1 ]]; then
  JA=$(echo "$JD" | grep -F "dabSql aktiv: dabSql Anzeige ok" | tail -1 || true)
  [[ -n "$JA" ]] && echo "OK Journal Dashboard: $(echo "$JA" | cut -c1-260)" || rbx "Dashboard meldet dabSql-Anzeige nicht (Selbsttest)"
  JA2=$(echo "$JD" | grep -F "airTest aktiv: airTest Anzeige ok" | tail -1 || true)
  [[ -n "$JA2" ]] && echo "OK Journal Dashboard: $(echo "$JA2" | cut -c1-260)" || rbx "Dashboard meldet airTest-Anzeige nicht (Selbsttest)"
  JA4=$(echo "$JD" | grep -F "sdrRest2 aktiv: sdrRest2 Anzeige ok" | tail -1 || true)
  [[ -n "$JA4" ]] && echo "OK Journal Dashboard: $(echo "$JA4" | cut -c1-260)" || rbx "Dashboard meldet sdrRest2-Anzeige nicht (Selbsttest)"
  JA5=$(echo "$JD" | grep -F "sdrStick3 aktiv: sdrStick3 Anzeige ok" | tail -1 || true)
  [[ -n "$JA5" ]] && echo "OK Journal Dashboard: $(echo "$JA5" | cut -c1-260)" || rbx "Dashboard meldet sdrStick3-Anzeige nicht (Selbsttest)"
  JA3=$(echo "$JD" | grep -F "sdrRest aktiv: sdrRest Anzeige ok" | tail -1 || true)
  [[ -n "$JA3" ]] && echo "OK Journal Dashboard: $(echo "$JA3" | cut -c1-260)" || rbx "Dashboard meldet sdrRest-Anzeige nicht (Selbsttest)"
  JB=$(echo "$JP" | grep -F "airTest: bereit" | tail -1 || true)
  [[ -n "$JB" ]] && echo "OK Journal prepper-sdr: $(echo "$JB" | cut -c1-200)" || rbx "prepper-sdr meldet airTest nicht (bereit)"
  JH=$(echo "$JP" | grep -F "sdrHalt: bereit" | tail -1 || true)
  [[ -n "$JH" && "$JH" == *"systemd-Watchdog aktiv"* ]] && echo "OK Journal prepper-sdr: $(echo "$JH" | cut -c1-300)" || rbx "prepper-sdr meldet sdrHalt nicht bereit mit systemd-Watchdog ($JH)"
  JT=$(echo "$JP" | grep -F "sdrHalt: Watchdog-Takt an systemd gesendet" | tail -1 || true)
  [[ -n "$JT" ]] && echo "OK Journal prepper-sdr: $(echo "$JT" | cut -c1-200)" || rbx "sdrHalt: Takt an systemd nicht nachgewiesen (Notify-Socket?)"
  systemctl show -p Restart -p RestartUSec -p StartLimitIntervalUSec -p WatchdogUSec -p NotifyAccess -p NRestarts prepper-sdr > "$W/ushow.log" 2>&1 || true
  python3 "$HCK" unit "$W/ushow.log" > "$W/hc.log" 2>&1 && echo "OK $(cat "$W/hc.log")" || { cat "$W/hc.log"; rbx "Unit prepper-sdr: Drop-in nicht wirksam"; }
  AET2=$(systemctl show -p ActiveEnterTimestamp --value prepper-sdr 2>/dev/null || true)
  [[ "$AET2" == "$AET" ]] && echo "OK prepper-sdr seit dem Neustart nicht vom Watchdog beendet (Start $AET2)" || rbx "prepper-sdr wurde nach dem Neustart erneut gestartet (Start $AET -> $AET2)"
  [[ "$(grep -c '^Restart=always' "$W/ushow.log" || true)" == 1 && "$(grep -E '^NRestarts=' "$W/ushow.log" | cut -d= -f2)" == 0 ]] || rbx "NRestarts nicht 0 (Dienst nach Neustart automatisch neu gestartet)"
  JW=$(echo "$JP" | grep -F "dabSql: Schreibfaden laeuft" | tail -1 || true)
  [[ -n "$JW" ]] && echo "OK Journal prepper-sdr: $(echo "$JW" | cut -c1-200)" || rbx "prepper-sdr meldet den dabSql-Schreibfaden nicht"
  ju=0; for i in $(seq 1 40); do JP2=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null || true); JU=$(echo "$JP2" | grep -F "sdrRest2: USB-Pruefung im Lauf bereit" | tail -1 || true); [[ -n "$JU" ]] && { ju=1; break; }; sleep 3; done
  [[ "$ju" == 1 ]] && echo "OK Journal prepper-sdr: $(echo "$JU" | cut -c1-260)" || rbx "prepper-sdr meldet die lesende USB-Pruefung im Lauf nicht (sdrRest2)"
  s3j=0; for i in $(seq 1 30); do JP3=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null || true); echo "$JP3" > "$W/jp3.txt"; python3 "$S3C" journal "$W/jp3.txt" "$SYSUSB" "$S3_OLD" "$S3_NEW" > "$W/s3j.log" 2>&1 && { s3j=1; break; }; sleep 5; done
  [[ "$s3j" == 1 ]] && echo "OK $(cut -c1-260 "$W/s3j.log")" || { cat "$W/s3j.log"; rbx "Journal prepper-sdr passt nicht zum Stick-3-Stand"; }
  JV=$(echo "$JP2" | grep -E "^sdrRest2: SN " | tail -2 || true)
  [[ -z "$JV" ]] && echo "OK keine USB-Abweichung seit Neustart (Seriennummern/devnum wie beim Start)" || echo "HINWEIS USB-Abweichung im Lauf gemeldet (nur lesend; frische Aufloesung beim naechsten Start): $(echo "$JV" | cut -c1-240 | tr '\n' '|')"
fi
R2='Traceback|sdrStick3 Anzeige(:| FEHLER)|airTest (Anzeige(:| FEHLER)|Seite:)|sdrRest (Anzeige(:| FEHLER)|Karte:)|sdrRest2 (Anzeige(:| FEHLER)|Karte:)|dabSql Anzeige(:| FEHLER)|dabSql Karte:|dabSql: (Lesen|Tabellen|kartevec-Import)|sdrWd FEHLER|funkUI FEHLER|sdr_manager sdrWd|sdr_manager sdrAir2? [A-Za-z_ -]+:|sdrAir2? Anzeige(:| FEHLER)'
E2=$(echo "$JD" | grep -c -E "$R2" || true)
[[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/sdrAir-/sdrWd-Fehler" || { echo "$JD" | grep -E "$R2" | head -5 | cut -c1-240; rbx "$E2 Traceback/Fehlerzeilen im Journal Dashboard"; }
python3 "$AC2" proof "$DASH_DIR" 0 > "$W/proof.log" 2>&1 && echo "Geraete nachher: $(cut -c1-460 "$W/proof.log")" || echo "HINWEIS Geraete nachher: $(cut -c1-300 "$W/proof.log")"
echo "Watchdog nachher: $(python3 "$AC2" state "$DASH_DIR" 2>&1 | tail -1 | cut -c1-400)"
for x in "$DBF:$DB16" "$MR:$MR16" "$HDST:$HL16"; do f=${x%%:*}; h=${x##*:}; [[ "$(s16 "$f")" == "$h" ]] && echo "OK $(basename "$f") unveraendert ($h)" || rbx "$(basename "$f") hat sich veraendert"; done
[[ ! -f "$LG" || "$(s16 "$LG")" == "$LG16" ]] && echo "OK lagegeo.py unveraendert ($LG16)" || rbx "lagegeo.py hat sich veraendert"
[[ -f "$LZ" ]] && echo "lagezentrum.db nachher: $(python3 "$CK" counts "$LZ" 2>&1 | cut -c1-200)"
echo "OK guards sdrStick3(sdr)=$(grep -c '# ===== sdrStick3:' "$M" || true) sdrStick3(dash)=$(grep -c '# ===== sdrStick3:' "$F" || true) sdrStick3(sm)=$(grep -c '# ===== sdrStick3:' "$SMF" || true) sdrRest2(sdr)=$(grep -c '# ===== sdrRest2:' "$M" || true) sdrRest2(sm)=$(grep -c '# ===== sdrRest2:' "$SMF" || true) sdrRest2(dash)=$(grep -c '# ===== sdrRest2:' "$F" || true) sdrRest(sdr)=$(grep -c '# ===== sdrRest:' "$M" || true) sdrHalt(sdr)=$(grep -c '# ===== sdrHalt:' "$M" || true) airTest(sdr)=$(grep -c '# ===== airTest:' "$M" || true) airTest(dash)=$(grep -c '# ===== airTest:' "$F" || true) sdrRest(sm)=$(grep -c '# ===== sdrRest:' "$SMF" || true) sdrRest(dash)=$(grep -c '# ===== sdrRest:' "$F" || true) dabSql(sdr)=$(grep -c '# ===== dabSql:' "$M" || true) dabSql(sm)=$(grep -c '# ===== dabSql:' "$SMF" || true) dabSql(dash)=$(grep -c '# ===== dabSql:' "$F" || true) sdrAir2(sdr)=$(grep -c '# ===== sdrAir2:' "$M" || true) sdrAir2(sm)=$(grep -c '# ===== sdrAir2:' "$SMF" || true) sdrAir(sdr)=$(grep -c '# ===== sdrAir:' "$M" || true) sdrAir(sm)=$(grep -c '# ===== sdrAir:' "$SMF" || true) sdrAir(dash)=$(grep -c '# ===== sdrAir:' "$F" || true) sdrAir2(dash)=$(grep -c '# ===== sdrAir2:' "$F" || true) sdrWd2(sdr)=$(grep -c '# ===== sdrWd2:' "$M" || true) sdrWd(sdr)=$(grep -c '# ===== sdrWd:' "$M" || true) sysBoot(dash)=$(grep -c '# ===== sysBoot' "$F" || true)"
for x in "$F" "$SMF" "$DBF" "$M" "$MR" "$LG" "$CF" "$HDST"; do [[ -f "$x" ]] && echo "  $(basename "$x") sha16 $(s16 "$x"), $(wc -l < "$x") Zeilen"; done
echo "Stick 3 (Hobby, nur Register/Anzeige): $EE_NOTE"
if [[ "$EE_DONE" == 1 ]]; then
  echo "NAECHSTER SCHRITT VON HAND: Stick 3 (USB $S3_PATH, Realtek RTL2838UHIDIR) kurz abziehen, ca. 5 s warten, wieder einstecken - Sticks 1/2 und Airspy NICHT beruehren. Danach: bash /tmp/apply-sdrstick3b.sh $COMMIT_ARG pruefen"
  echo "   Erwartet: Stick 3 meldet SN $S3_NEW und steht als 'Stick 3 · Hobby' im Register (Journal: sdrStick3: ... angesteckt). Bis dahin zeigt die Anzeige ihn als 'Stick 3 · ohne Rolle' mit Hinweis auf die kuenftige SN."
  echo "   Rueckweg EEPROM (nur von Hand, nur Stick 3 und sonst nichts offen): rtl_eeprom -d INDEX -w DUMP mit dem Dump unter $DASH_DIR/stick3-eeprom/ (Datei ...-vor-SN$S3_OLD.bin); INDEX aus rtl_test - nie die SN als Auswahl nehmen."
fi
echo "COMMIT $COMMIT_ARG sdrstick3b=1 fertig"
