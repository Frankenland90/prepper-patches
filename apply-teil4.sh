#!/bin/bash
set -euo pipefail
# Teil 4 von 4 (auf Teil 3): Frontend, Audio-Kaskade und Vor-Alarm fuer SDR 2.
# Lage-Seite: Status-Zeile gruen/gelb (ASA-Probe)/rot blinkend (Echtalarm)/orange blinkend (SDR_OFFLINE, Netzfrequenz)/orange (DSL) mit Grund,
# SDR-Status-Kachel (SDR 1 11D, SDR 2 frei/5C/10C-Rueckfall, Knopf "SDR 2 freigeben"), Ereignis-Historie (10). Neue Seite /karte (Leaflet lokal, Offline-Kacheln).
# Audio nur bei Echtalarm: amixer 100 %, Sirene 5 s (aplay), ASA-Text einmal (espeak-ng -v de -s 140 -a 100), Lautstaerke zurueck, Kill-Switch bei Entwarnung.
# Vor-Alarm: DSL Telekom -> Starlink oder Netzfrequenz < 49,800 / > 50,200 Hz > 3 s -> SDR 2 sofort 5C, je 1 Meldung Mesh 1 (nur Auto-Versand AN, nur .141).
# 3-h-Heartbeat Mesh 1 (<= 160 Zeichen). Dateien: dashboard.py, prepper_sdr.py, sdr_manager.py, static/leaflet, static/sirene.wav (nur wenn sie fehlt).
# Neustart nur prepper-sdr + prepper-dashboard. Sendet beim Einspielen nichts, spielt keinen Ton. Kacheln laedt nur prepper-tiles-teil4.sh.
COMMIT_ARG="${1:-unbekannt}"
DASH_DIR="/home/fmg/prepper-dashboard"
F="$DASH_DIR/dashboard.py"
M="$DASH_DIR/prepper_sdr.py"
SMF="$DASH_DIR/sdr_manager.py"
ST="$DASH_DIR/static"
VPY="$DASH_DIR/venv/bin/python"
SPY=/usr/bin/python3
TS=$(date +%Y%m%d-%H%M%S)
W=/tmp/teil4-apply
KEEP_LAST=3
KNOWN_DASH16="12e7521b26349157"  # live nach Teil 3
KNOWN_SDR16="e8a7ac1c3edfb076"   # prepper_sdr.py nach Teil 2/3
KNOWN_SM16="855225dc03abb535"    # sdr_manager.py nach Teil 2/3
EXP_M1="192.168.178.141"         # Mesh 1 = NINA + DAB+ + Teil 4
EXP_M2="192.168.178.140"         # Mesh 2 = nur NINA
CFG_PORT=$(sed -n 's/^PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DASH_DIR/config.py" 2>/dev/null | head -1 || true)
PORT="${DASH_PORT:-${CFG_PORT:-5000}}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then echo "STOP: Dashboard-Port unklar ($PORT) - nichts geaendert"; exit 1; fi
if [[ "$PORT" == "8080" ]]; then echo "STOP: Port 8080 ist kiwix-serve - nichts geaendert"; exit 1; fi
B="http://127.0.0.1:${PORT}"
CURL=(curl --compressed -s --connect-timeout 3 --max-time 40)
[[ -x "$VPY" ]] || VPY=python3
[[ -x "$SPY" ]] || SPY=python3
echo "=== Teil 4 apply, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/msbx" "$W/sbx" "$W/old" "$W/leaflet"
EXPECT_PD="c081406de261d6efb436967fffc4cd86fee7640c41964ee022b3d2afd0462e0d"
cat > "$W/patch-t4-dash.py" << 'T4PD_EOF'
"""teil4: Block direkt nach /teil3 einsetzen oder ersetzen (idempotent). Sonst nichts.
Aufruf: patch-t4-dash.py QUELLE ZIEL TEIL4 -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, t4_f = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
t4 = open(t4_f, encoding="utf-8").read()
Z3 = "# ===== /teil3 =====\n"
A4, Z4 = "# ===== teil4:", "# ===== /teil4 =====\n"
MAIN = "\nif __name__ == \"__main__\":\n"
NEED = ("# ===== teil2:", "# ===== /teil2 =====", "# ===== teil3:", "def _t2d_check(rq):", "def _t2d_stick2_post():", '"t2_stick2"', "def _t3_log(node, text, channel, ok, kind, now=None):",
        "def _t3_tx(node):", "def _t3_health(node):", "def maybe_mesh_frequenz(hz, force=False):", "def maybe_mesh_weather(force=False):", "def fetch_frequenz_live():",
        "maybe_mesh_frequenz(f.get(\"value\"))", "NAV_UNIFY = ", "def _lz_ctx():", "def _lz_sync(min_s, ctx=None):", "<div class=\"lage {% if lage.text", "app = Flask(__name__)", MAIN)
bad = [n.strip()[:50] for n in NEED if s.count(n) < 1]
if s.count(Z3) != 1:
    bad.append("teil3-Ende fehlt/doppelt (%d)" % s.count(Z3))
if s.count(A4) > 1 or s.count(Z4) != s.count(A4):
    bad.append("teil4-Marker kaputt (%d/%d)" % (s.count(A4), s.count(Z4)))
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
b = s.index(Z3) + len(Z3)
if b > s.rindex(MAIN):
    print("Basis passt nicht: /teil3 nach __main__"); raise SystemExit(3)
if A4 in s:
    c = s.index(A4); e = s.index(Z4) + len(Z4)
    if c != b:
        print("Basis passt nicht: teil4-Block steht nicht direkt nach /teil3"); raise SystemExit(3)
    s2 = s[:c] + t4 + s[e:]
else:
    s2 = s[:b] + t4 + s[b:]
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
T4PD_EOF
EXPECT_PS="f6cc28d83a5e87efcb1b7dbf50a2ee694474384f4e89aee5493a2e5d160949ce"
cat > "$W/patch-t4-sdr.py" << 'T4PS_EOF'
"""sdrTeil4: Block direkt nach /sdrTeil2 einsetzen oder ersetzen, Teil-2-Selbsttest (10C nicht mehr 'kein Empfang') und Selbsttest-Aufruf ergaenzen (idempotent).
Aufruf: patch-t4-sdr.py QUELLE ZIEL BLOCK -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, blk_f = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
blk = open(blk_f, encoding="utf-8").read()
Z2 = "# ===== /sdrTeil2 =====\n"
A4, Z4 = "# ===== sdrTeil4:", "# ===== /sdrTeil4 =====\n"
EDITS = (('    assert all(MASTS_DB[k]["src"] for k in MASTS_DB) and "kein Empfang" in MASTS_DB["10C"]["rx"]\n',
          '    assert all(MASTS_DB[k]["src"] for k in MASTS_DB) and MASTS_DB["10C"]["rx"]   # Teil 4: 10C ist Rueckfall bei Kaperung\n'),
         ('        selftest_teil2()\n    elif a in ("stick-test",', '        selftest_teil2()\n        selftest_teil4()\n    elif a in ("stick-test",'))
NEED = ("# ===== sdrTeil2:", "def _t2_alarm(self):", "def _t2_dab_idx(self, ch):", "Planner.sub_done = _t2_sub_done", "Planner.stick2_info = _t2_stick2_info",
        "def dab_list(self):", '"10C": 213.360', "def selftest_teil2():")
bad = [n[:40] for n in NEED if n not in s]
if s.count(Z2) != 1:
    bad.append("sdrTeil2-Ende fehlt/doppelt")
if s.count(A4) > 1 or s.count(A4) != s.count(Z4):
    bad.append("sdrTeil4-Marker kaputt")
for old, new in EDITS:
    if s.count(old) + s.count(new) != 1:
        bad.append("Stelle fuer Teil-4-Aenderung nicht eindeutig: %s" % old.strip()[:50])
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
s2 = s
for old, new in EDITS:
    s2 = s2.replace(old, new)
b = s2.index(Z2) + len(Z2)
if A4 in s2:
    c = s2.index(A4); e = s2.index(Z4) + len(Z4)
    if c != b:
        print("Basis passt nicht: sdrTeil4 steht nicht direkt nach /sdrTeil2"); raise SystemExit(3)
    s2 = s2[:c] + blk + s2[e:]
else:
    s2 = s2[:b] + blk + s2[b:]
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
T4PS_EOF
EXPECT_PM="8e93f3530366626b33f9f9d674e9865d60d0c85e21962677a2ff62c76e6328c7"
cat > "$W/patch-t4-sm.py" << 'T4PM_EOF'
"""Teil 4: sdr_manager.py - Teil-4-Abschnitt vor den Hauptteil setzen (oder ersetzen) und Selbsttest-Aufruf anhaengen (idempotent). Sonst nichts.
Aufruf: patch-t4-sm.py QUELLE ZIEL ABSCHNITT -> 0 ok (geaendert/gleich), 3 Basis passt nicht."""
import sys
src, dst, sec_f = sys.argv[1:4]
s = open(src, encoding="utf-8").read()
sec = open(sec_f, encoding="utf-8").read().rstrip("\n") + "\n"
M = '\n\nif __name__ == "__main__":\n    print(selftest())\n    print(selftest_t2())\n'
T = "    print(selftest_t4())\n"
S4 = "\n\n# ---------------------------------------------------------------- Teil 4"
NEED = ("# ---------------------------------------------------------------- Teil 2", "def takeover_set(", "def takeover_load(", "def live(", "def asa_monitor(",
        "def alarm_identifier(")
bad = [n[:50] for n in NEED if n not in s]
if s.count(M) != 1 or not (s.endswith(M) or s.endswith(M + T)):
    bad.append("Hauptteil (selftest/selftest_t2) nicht wie erwartet am Ende")
if s.count(S4) > 1:
    bad.append("Teil-4-Abschnitt doppelt")
if bad:
    print("Basis passt nicht:", "; ".join(bad)); raise SystemExit(3)
i = s.rindex(M)
head = s[:i]
if S4 in head:
    head = head[:head.index(S4)]
s2 = head.rstrip("\n") + "\n" + sec + M + T
open(dst, "w", encoding="utf-8").write(s2)
print("gleich" if s2 == s else "geaendert")
T4PM_EOF
EXPECT_B4="911a62c501f4b9904d63a44b5ce8f18639344ad6f678c869ab67c7030e3e5962"
cat > "$W/t4_dash_block.py" << 'T4B4_EOF'
# ===== teil4: Teil 4 von 4 - Lage-Ampel (gruen/gelb Probe/rot blinkend Echtalarm/orange blinkend SDR_OFFLINE + Vor-Alarm) mit Grund-Zeile, SDR-Status-Kachel, Ereignis-Historie (10), Karte /karte (Leaflet + Offline-Kacheln lokal), Audio-Kaskade bei Echtalarm (amixer 100 %, Sirene aplay, ASA-Text einmal mit espeak-ng, Kill-Switch bei Entwarnung), Vor-Alarm SDR 2 (DSL Telekom -> Starlink, Netzfrequenz < 49,800 / > 50,200 Hz > 3 s) mit Freigabe nur per Knopf, 3-h-Heartbeat Mesh 1; Mesh nur ueber den Teil-3-Weg (Schalter, nur .141) =====
import threading as _t4_thr
import time as _t4_time
import json as _t4_json
import os as _t4_os
import re as _t4_re
import hashlib as _t4_hl
import signal as _t4_sig
import shutil as _t4_sh
import subprocess as _t4_sp
import tempfile as _t4_tmp
import collections as _t4_col

T4_TICK_S = 2                  # Faden: Audio, Frequenz-Bestaetigung, Heartbeat, Vor-Alarm
T4_STATUS_S = 10               # Ampel/Kachel-Daten neu berechnen
T4_FIRST_S = 45              # nach dem ersten echten Teil-2-Lauf (30 s)
T4_ALARM_MAX_AGE_S = 120     # Teil-2-Alarmliste gilt nur, wenn hoechstens 2 min alt (nie Selbsttest-Reste)
T4_STATE = "teil4_state.json"
T4_EXE = ("amixer", "aplay", "espeak-ng")   # die einzigen Programme, die Teil 4 startet (ohne Shell)
T4_KILL_COMM = ("aplay", "espeak-ng")      # Kill-Switch: nur diese Prozessnamen (genau), nur eigener Benutzer
T4_SAY_MAX = 600
T4_SPOKEN_KEEP_S = 30 * 86400
T4_PRE_SAME_S = 6 * 3600       # Vor-Alarm-Meldung je Art hoechstens alle 6 h
T4_PRE_TRY_S = 30 * 60         # Vor-Alarm-Meldung so lange versuchen (Bridge-Fehler), dann verwerfen
T4_CONFIRM_DELAY_S = 4         # zweite Frequenzmessung 4 s nach dem ersten Wert ausserhalb (Messtakt sonst 25 s)
T4_HB_DELAY_S = 60             # Heartbeat 60 s nach der automatischen Wettermeldung ...
T4_HB_PEGEL_WAIT_S = 90        # ... aber der Pegel startet fest +60 s nach dem Wetter: bis +90 s auf ihn warten, dann 60 s Abstand
T4_HB_GIVEUP_S = 1800
T4_HB_GAP_S = 60
_T4 = {"ok": False, "err": None, "selftest": None, "started": False, "t": 0, "n": 0, "tick_err": None, "fake": None, "status": None, "status_t": 0,
       "fs": _t4_col.deque(maxlen=240), "confirm_at": None, "audio": {"busy": False, "abort": False, "procs": [], "vol": None, "last": None, "err": None, "card": None},
       "ident_prev": 0, "hb": {"due": None, "w_t": None, "slot": None, "next_try": 0, "last": None}, "st": None, "fb_prev": None, "notes": [], "enf_t": 0}
_T4_LOCK = _t4_thr.RLock()


def _t4_now():
    f = (_T4.get("fake") or {}).get("now")
    return int(f() if callable(f) else _t4_time.time())


def _t4_say(*a):
    if not _T4.get("fake"):
        print(*a, flush=True)


def _t4_paths():
    f = _T4.get("fake") or {}
    return f.get("base") or _SDR_BASE, f.get("path") or _LZ_PATH


def _t4_static():
    f = (_T4.get("fake") or {}).get("static")
    return f or _t4_os.path.join(_SDR_BASE, "static")   # wie sirene.wav: <Dashboard-Ordner>/static


# ---------------------------------------------------------------- Zustand (atomar, ueberlebt Neustart)
def _t4_load():
    if _T4["st"] is not None:
        return _T4["st"]
    d = {}
    try:
        with open(_t4_os.path.join(_t4_paths()[0], T4_STATE), encoding="utf-8") as f:
            d = _t4_json.load(f)
    except Exception:
        d = {}
    d = d if isinstance(d, dict) else {}
    for k, v in (("spoken", {}), ("pre", {"on": False, "kinds": [], "since": None, "why": ""}), ("pre_sent", {}), ("pending", {}), ("dsl_handled", None),
                 ("hb_slot_sent", None), ("hb_last", None)):
        if k not in d or (v is not None and not isinstance(d[k], type(v))):
            d[k] = v
    _T4["st"] = d
    return d


def _t4_save():
    st = _t4_load()
    now = _t4_now()
    st["spoken"] = dict(sorted(((k, v) for k, v in st["spoken"].items() if isinstance(v, (int, float)) and now - v < T4_SPOKEN_KEEP_S), key=lambda kv: kv[1])[-200:])
    fn = _t4_os.path.join(_t4_paths()[0], T4_STATE)
    tmp = "%s.tmp-%d" % (fn, _t4_os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            _t4_json.dump(st, f, ensure_ascii=False)
        _t4_os.replace(tmp, fn)
    except Exception as e:
        print("teil4 Zustand:", e, flush=True)


def _t4_event(src, kind, sev, head, now=None):
    try:
        now = int(now or _t4_now())
        _lz_dbm.upsert_event({"source": src, "type": kind, "severity": sev, "headline": str(head)[:160], "text": str(head)[:400], "created": now, "updated": now,
                              "expires": now + 24 * 3600, "ext_id": "T4:%s:%s:%d" % (src, kind, now)}, _t4_paths()[1])
    except Exception as e:
        print("teil4 Ereignis:", e, flush=True)


# ---------------------------------------------------------------- Audio (nur bei Echtalarm; Programme ohne Shell, feste Liste)
def _t4_which(name):
    f = (_T4.get("fake") or {}).get("which")
    return f(name) if callable(f) else _t4_sh.which(name)


def _t4_run(argv, timeout=10):
    """Kurzer Aufruf (amixer). -> (rc, stdout)"""
    if not argv or argv[0] not in T4_EXE:
        raise RuntimeError("teil4: Programm nicht erlaubt")
    f = (_T4.get("fake") or {}).get("run")
    if callable(f):
        return f(list(argv))
    exe = _t4_which(argv[0])
    if not exe:
        return 127, ""
    r = _t4_sp.run([exe] + list(argv[1:]), stdout=_t4_sp.PIPE, stderr=_t4_sp.DEVNULL, timeout=timeout, check=False, text=True)
    return r.returncode, r.stdout or ""


def _t4_spawn(argv):
    """Laengerer Aufruf (aplay, espeak-ng) als eigenes Kind - der Kill-Switch kann ihn beenden. -> Popen | None"""
    if not argv or argv[0] not in T4_EXE[1:]:
        raise RuntimeError("teil4: Programm nicht erlaubt")
    f = (_T4.get("fake") or {}).get("spawn")
    if callable(f):
        p = f(list(argv))
    else:
        exe = _t4_which(argv[0])
        if not exe:
            return None
        p = _t4_sp.Popen([exe] + list(argv[1:]), stdin=_t4_sp.DEVNULL, stdout=_t4_sp.DEVNULL, stderr=_t4_sp.DEVNULL)
    _T4["audio"]["procs"].append(p)
    return p


def _t4_wait(p, limit):
    end = _t4_time.time() + limit
    while p is not None and p.poll() is None:
        if _T4["audio"]["abort"] or _t4_time.time() > end:
            try:
                _t4_kill_pid(p.pid)
            except Exception:
                pass
            return False
        _t4_time.sleep(0.2)
    return p is not None and p.poll() == 0


def _t4_kill_pid(pid):
    f = (_T4.get("fake") or {}).get("kill")
    if callable(f):
        return f(int(pid), _t4_sig.SIGTERM)
    _t4_os.kill(int(pid), _t4_sig.SIGTERM)


def _t4_card():
    """3,5-mm-Klinke: ALSA-Karte bcm2835 Headphones aus /proc/asound/cards. -> {"idx", "id", "dev"} | None"""
    f = (_T4.get("fake") or {}).get("cards")
    try:
        txt = f if isinstance(f, str) else open("/proc/asound/cards", encoding="utf-8", errors="replace").read()
    except Exception:
        return None
    best = None
    for ln in txt.splitlines():
        m = _t4_re.match(r"^\s*(\d+)\s+\[([^\]\s]+)\s*\]:\s*(\S+)\s+-\s+(.*)$", ln)
        if not m:
            continue
        idx, cid, drv, name = int(m.group(1)), m.group(2), m.group(3), m.group(4)
        score = (2 if "headphone" in (cid + name).lower() else 0) + (1 if "bcm2835" in (drv + name).lower() else 0)
        if score and (best is None or score > best[0]):
            best = (score, {"idx": idx, "id": cid, "dev": "plughw:CARD=%s,DEV=0" % cid, "name": name.strip()[:60]})
    return best[1] if best else None


def _t4_ctl(card):
    rc, out = _t4_run(["amixer", "-c", str(card["idx"]), "scontrols"])
    names = _t4_re.findall(r"Simple mixer control '([^']+)',\d+", out or "") if rc == 0 else []
    for want in ("Headphone", "PCM", "Master", "Speaker"):
        if want in names:
            return want
    return names[0] if names else None


def _t4_vol(card, ctl, pct=None):
    """pct None: Lautstaerke lesen -> int | None; sonst setzen -> bool"""
    if pct is None:
        rc, out = _t4_run(["amixer", "-c", str(card["idx"]), "sget", ctl])
        m = _t4_re.search(r"\[(\d{1,3})%\]", out or "") if rc == 0 else None
        return int(m.group(1)) if m else None
    rc, _ = _t4_run(["amixer", "-q", "-c", str(card["idx"]), "sset", ctl, "%d%%" % int(pct)])
    _t4_run(["amixer", "-q", "-c", str(card["idx"]), "sset", ctl, "unmute"])
    return rc == 0


def _t4_cascade(text, h):
    """Echtalarm: Lautstaerke 100 % -> Sirene 5 s (aplay) -> ASA-Text einmal (espeak-ng -v de -s 140 -a 100) -> alte Lautstaerke zurueck."""
    a = _T4["audio"]
    a.update(busy=True, abort=False, err=None)
    wav = None
    steps = []
    try:
        card = _t4_card()
        a["card"] = card
        dev = card["dev"] if card else "default"
        if card:
            ctl = _t4_ctl(card)
            if ctl:
                old = _t4_vol(card, ctl)
                a["vol"] = {"card": card, "ctl": ctl, "old": old}
                steps.append("Lautstaerke %s %s%% -> 100%%" % (ctl, old if old is not None else "?") if _t4_vol(card, ctl, 100) else "amixer fehlgeschlagen")
            else:
                steps.append("kein Regler auf Karte %s" % card["id"])
        else:
            steps.append("Klinke (bcm2835 Headphones) nicht gefunden - ALSA default, Lautstaerke unveraendert")
        sir = _t4_os.path.join(_t4_static(), "sirene.wav")
        if _t4_os.path.isfile(sir) and not a["abort"]:
            steps.append("Sirene %s" % ("ok" if _t4_wait(_t4_spawn(["aplay", "-q", "-D", dev, sir]), 15) else "Fehler/abgebrochen"))
        elif not a["abort"]:
            steps.append("sirene.wav fehlt")
        if not a["abort"]:
            fd, wav = _t4_tmp.mkstemp(prefix="teil4-say-", suffix=".wav")
            _t4_os.close(fd)
            ok = _t4_wait(_t4_spawn(["espeak-ng", "-v", "de", "-s", "140", "-a", "100", "-w", wav, str(text)[:T4_SAY_MAX]]), 60)
            if ok and not a["abort"]:
                steps.append("Ansage %s" % ("ok" if _t4_wait(_t4_spawn(["aplay", "-q", "-D", dev, wav]), 180) else "Fehler/abgebrochen"))
            else:
                steps.append("espeak-ng %s" % ("abgebrochen" if a["abort"] else "fehlt/Fehler"))
    except Exception as e:
        a["err"] = str(e)[:120]
        steps.append("Fehler: %s" % str(e)[:80])
    finally:
        _t4_vol_back()
        if wav:
            try:
                _t4_os.remove(wav)
            except Exception:
                pass
        a["procs"] = [p for p in a["procs"] if p.poll() is None]
        a.update(busy=False, last={"t": _t4_now(), "h": h, "text": str(text)[:120], "steps": steps, "abort": a["abort"]})
        _t4_say("teil4 Audio:", " · ".join(steps))


def _t4_vol_back():
    v = _T4["audio"].get("vol")
    _T4["audio"]["vol"] = None
    if v and v.get("old") is not None:
        try:
            _t4_vol(v["card"], v["ctl"], v["old"])
        except Exception as e:
            print("teil4 Lautstaerke zurueck:", e, flush=True)


def _t4_procs():
    f = (_T4.get("fake") or {}).get("procs")
    if callable(f):
        return f()
    out, me = [], _t4_os.getuid()
    for d in _t4_os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % d, encoding="utf-8", errors="replace") as fh:
                comm = fh.read().strip()
            if comm in T4_KILL_COMM and _t4_os.stat("/proc/%s" % d).st_uid == me:
                out.append((int(d), comm))
        except Exception:
            pass
    return out


def _t4_kill_all(why):
    """Kill-Switch (Entwarnung): eigene Kinder + alle aplay/espeak-ng des eigenen Benutzers beenden (SIGTERM, ohne Shell)."""
    a = _T4["audio"]
    a["abort"] = True
    n = 0
    pids = {p.pid for p in a["procs"] if p.poll() is None} | {pid for pid, comm in _t4_procs() if comm in T4_KILL_COMM}
    for pid in sorted(pids):
        if pid == _t4_os.getpid():
            continue
        try:
            _t4_kill_pid(pid)
            n += 1
        except Exception:
            pass
    if not a["busy"]:
        _t4_vol_back()
    _t4_say("teil4 Kill-Switch (%s): %d Audio-Prozesse beendet" % (why, n))
    return n


def _t4_core(t):
    return " ".join(str(t or "").replace("…", " ").split()).lower()


def _t4_audio_tick(al, ident, now):
    st = _t4_load()
    prev = _T4["ident_prev"]
    _T4["ident_prev"] = ident
    if prev == 2 and ident < 2:
        _t4_kill_all("Entwarnung")
        return "kill"
    if ident != 2:
        return None
    real = [x for x in al or [] if isinstance(x, dict) and x.get("real") and not x.get("test") and str(x.get("text") or "").strip()]
    if not real or _T4["audio"]["busy"]:
        return None
    a = sorted(real, key=lambda x: 0 if x.get("src") == "ASA" else 1)[0]
    text = str(a["text"]).strip()
    h = _t4_hl.sha1(_t4_core(text).encode("utf-8")).hexdigest()[:16]
    if h in st["spoken"]:
        return "dup"
    st["spoken"][h] = now
    _t4_save()
    say = ("%s. %s" % ({"ASA": "Warnung ASA", "BR24": "Warnung B R 24", "NINA": "Warnung NINA"}.get(a.get("src"), "Warnung"), text))[:T4_SAY_MAX]
    if (_T4.get("fake") or {}).get("sync"):
        _t4_cascade(say, h)
    else:
        _t4_thr.Thread(target=_t4_cascade, args=(say, h), name="teil4-audio", daemon=True).start()
    return "play"


# ---------------------------------------------------------------- Mesh 1 (Teil-3-Weg: Schalter, Bridge 5001 meldet .141, Kanal 0)
def _t4_send_m1(text, kind):
    base, path = _t4_paths()
    with _T3_LOCK:
        r = _lz_mesh.dab_private_send(text, _t3_tx("m1"), _t3_health, base, 0)
        if r.get("why") not in ("Auto-Versand AUS (Schalter)",) and not str(r.get("why") or "").startswith("GESPERRT"):
            _t3_log("m1", text, 0, r["ok"], kind)
    return r


def _t4_boot_ok():
    f = globals().get("mesh_auto_allowed")
    return (not callable(f)) or bool(f()) or bool(_T4.get("fake"))


# ---------------------------------------------------------------- Vor-Alarm SDR 2
def _t4_us():
    f = (_T4.get("fake") or {})
    if "us" in f:
        return f["us"]
    um = globals().get("_uld_mod")
    try:
        return um.public_state() if um is not None and hasattr(um, "public_state") else None
    except Exception:
        return None


def _t4_freq_hook(prev):
    def maybe_mesh_frequenz(hz, *a, **kw):  # teil4: Messwert merken (Vor-Alarm), Versand unveraendert
        try:
            _t4_sample(hz)
        except Exception as e:
            print("teil4 Frequenz:", e, flush=True)
        return prev(hz, *a, **kw)
    maybe_mesh_frequenz.__dict__.update(getattr(prev, "__dict__", {}))
    maybe_mesh_frequenz.__wrapped__ = prev
    maybe_mesh_frequenz._t4 = True
    return maybe_mesh_frequenz


def _t4_sample(hz, now=None):
    if not isinstance(hz, (int, float)) or isinstance(hz, bool) or not 45.0 < float(hz) < 55.0:
        return
    now = now or _t4_now()
    _T4["fs"].append((float(now), float(hz)))
    if (float(hz) < _lz_mgr.T4_F_LOW or float(hz) > _lz_mgr.T4_F_HIGH) and _T4["confirm_at"] is None:
        _T4["confirm_at"] = now + T4_CONFIRM_DELAY_S


def _t4_pre_text(kind, why, now):
    hm = _t4_time.strftime("%H:%M", _t4_time.localtime(now))
    if kind == "DSL":
        return "VORALARM DSL-Ausfall %s: Internet Telekom -> Starlink. SDR 2 auf 5C (Bundes-Ebene) gekapert. Freigabe nur per Knopf." % hm
    return ("TAKTIK-WARNUNG Netzfrequenz %s %s (Grenze 49,800-50,200 Hz, > 3 s). SDR 2 auf 5C gekapert. Strom/Notstrom pruefen." % (why, hm))[:200]


def _t4_pre_on(kind, why, now):
    base, path = _t4_paths()
    st = _t4_load()
    pre = st["pre"]
    first = not pre.get("on")
    kinds = list(pre.get("kinds") or [])
    if kind in kinds and not first:
        return False
    pre.update(on=True, kinds=sorted(set(kinds + [kind])), since=pre.get("since") if not first else now, why=why if first else "%s; %s" % (pre.get("why"), why))
    st["pre"] = pre
    to = _lz_mgr.takeover_set(base, True, kind, why, "teil4", now)
    _t4_event("VORALARM", kind.lower(), "warn", "VORALARM %s: %s - SDR 2 auf 5C" % (kind, why), now)
    last = st["pre_sent"].get(kind)
    if not (isinstance(last, (int, float)) and now - last < T4_PRE_SAME_S):
        st["pending"][kind] = {"text": _t4_pre_text(kind, why if kind == "NETZ" else "", now), "t": now, "next": now}
    else:
        _t4_say("teil4: Vor-Alarm %s - Meldung an Mesh 1 schon vor %d min (6 h)" % (kind, (now - last) // 60))
    _t4_save()
    _t4_say("teil4: VORALARM %s (%s) -> Stick 2 %s" % (kind, why, "auf 5C gekapert" if to.get("on") else "?"))
    return True


def _t4_pending_tick(now):
    st = _t4_load()
    for kind, x in list(st["pending"].items()):
        if not isinstance(x, dict) or now - int(x.get("t") or 0) > T4_PRE_TRY_S:
            st["pending"].pop(kind, None)
            _t4_say("teil4: Vor-Alarm-Meldung %s verworfen (30 min nicht zustellbar)" % kind)
            continue
        if now < int(x.get("next") or 0) or not _t4_boot_ok():
            continue
        r = _t4_send_m1(x["text"], "teil4_pre")
        if r["ok"]:
            st["pre_sent"][kind] = now
            st["pending"].pop(kind, None)
            _t4_say("teil4: Vor-Alarm %s an Mesh 1 gesendet: %s" % (kind, x["text"][:80]))
        elif r.get("why") == "Auto-Versand AUS (Schalter)" or str(r.get("why") or "").startswith("GESPERRT"):
            st["pending"].pop(kind, None)
            _t4_say("teil4: Vor-Alarm %s nicht an Mesh 1: %s" % (kind, r.get("why")))
        else:
            x["next"] = now + 60
        _t4_save()


def _t4_fetch_freq():
    f = (_T4.get("fake") or {}).get("fetch")
    return f() if callable(f) else fetch_frequenz_live()


def _t4_pre_tick(now):
    base, path = _t4_paths()
    st = _t4_load()
    if _T4["confirm_at"] is not None and now >= _T4["confirm_at"]:
        _T4["confirm_at"] = None
        try:
            v = (_t4_fetch_freq() or {}).get("value")
            if isinstance(v, (int, float)):
                _T4["fs"].append((float(now), float(v)))
        except Exception as e:
            print("teil4 Frequenz-Bestaetigung:", e, flush=True)
    trig, dur, v = _lz_mgr.t4_freq_trigger(list(_T4["fs"]))
    if trig:
        _t4_pre_on("NETZ", ("%.3f Hz" % v).replace(".", ","), now)
    e = _lz_mgr.t4_dsl_edge(_t4_us(), st.get("dsl_handled"), now)
    if e:
        st["dsl_handled"] = e["t"]
        if not _t4_pre_on("DSL", "Telekom -> Starlink um %s" % _t4_time.strftime("%H:%M", _t4_time.localtime(e["t"])), now):
            _t4_save()
    if st["pre"].get("on") and now - _T4["enf_t"] >= 30:
        _T4["enf_t"] = now
        if not _lz_mgr.takeover_load(base).get("on"):
            _lz_mgr.takeover_set(base, True, (st["pre"].get("kinds") or ["DSL"])[0], "Vor-Alarm aktiv - Rueckgabe nur per SDR 2 freigeben", "teil4", now)
            _t4_say("teil4: Vor-Alarm aktiv, Stick 2 wieder auf 5C (Rueckgabe nur per Knopf SDR 2 freigeben)")
    _t4_pending_tick(now)


def _t4_release_state(now=None):
    now = now or _t4_now()
    fe = _lz_mgr.t4_freq_eval(list(_T4["fs"]), now)
    ok, why = _lz_mgr.t4_release_ok(_t4_us(), fe)
    return {"ok": bool(ok and _t4_load()["pre"].get("on")), "cond": ok, "why": why if _t4_load()["pre"].get("on") else "kein Vor-Alarm aktiv", "freq": fe}


# ---------------------------------------------------------------- Heartbeat Mesh 1 (3 h, 60 s nach der Wettermeldung)
def _t4_weather_hook(prev):
    def maybe_mesh_weather(*a, **kw):  # teil4: nach automatischer Wettermeldung Heartbeat planen; Wetter selbst unveraendert
        r = prev(*a, **kw)
        try:
            force = kw.get("force") is True or (len(a) > 0 and a[0] is True)
            if r and not force:
                now = _t4_now()
                _T4["hb"].update(due=now + T4_HB_DELAY_S, w_t=now, slot=_t4_time.strftime("%Y-%m-%d-%H", _t4_time.localtime(now)), next_try=0)
        except Exception as e:
            print("teil4 Heartbeat planen:", e, flush=True)
        return r
    maybe_mesh_weather.__dict__.update(getattr(prev, "__dict__", {}))
    maybe_mesh_weather.__wrapped__ = prev
    maybe_mesh_weather._t4 = True
    return maybe_mesh_weather


def _t4_hb_text(now):
    base, path = _t4_paths()
    s = _T4.get("status") or _t4_status_calc(now)
    ds = globals().get("data_store") or {}
    wx = (ds.get("wetter") or {}).get("value") if isinstance(ds.get("wetter"), dict) else None
    us = _t4_us() or {}
    fe = _lz_mgr.t4_freq_eval(list(_T4["fs"]), now)
    hz = fe.get("last")
    if hz is None and isinstance(ds.get("frequenz"), dict):
        hz = ds["frequenz"].get("value")
    s2 = ((s.get("sdr") or {}).get("s2") or {})
    s2s = "frei" if not s2.get("takeover") else ("10C" if s2.get("fb") else "5C")
    return _lz_mgr.t4_heartbeat_text(now, (s.get("level") or {}).get("label"), s.get("asa_status"), (_T4.get("fake") or {}).get("wx", wx), us.get("current"), hz, s2s)


def _t4_hb_tick(now):
    hb, st = _T4["hb"], _t4_load()
    if not hb.get("due") or now < hb["due"] or now < hb.get("next_try", 0):
        return None
    if hb.get("slot") == st.get("hb_slot_sent") or now - hb["w_t"] > T4_HB_GIVEUP_S:
        hb["due"] = None
        return "skip"
    last = int((_T3S.get("last_send") or {}).get("m1") or 0)
    if now < hb["w_t"] + T4_HB_PEGEL_WAIT_S and last <= hb["w_t"] + 1:
        return "wait-pegel"
    if now - last < T4_HB_GAP_S or not _t4_boot_ok():
        return "wait-gap"
    base, path = _t4_paths()
    if _lz_mesh.dab_pending(_t4_alarms(now), base, path, now):
        return "wait-dab"
    text = _t4_hb_text(now)
    r = _t4_send_m1(text, "teil4_hb")
    hb["last"] = {"t": now, "ok": r["ok"], "why": r.get("why"), "text": text}
    st["hb_last"] = hb["last"]
    if r["ok"] or r.get("why") == "Auto-Versand AUS (Schalter)" or str(r.get("why") or "").startswith("GESPERRT"):
        st["hb_slot_sent"] = hb["slot"]
        hb["due"] = None
        _t4_say("teil4 Heartbeat Mesh 1: %s (%s)" % ("gesendet" if r["ok"] else "nicht gesendet", r.get("why")), text if r["ok"] else "")
    else:
        hb["next_try"] = now + 60
    _t4_save()
    return "sent" if r["ok"] else "fail"


# ---------------------------------------------------------------- Status (Ampel, SDR-Kachel, Historie)
def _t4_status_calc(now=None):
    now = now or _t4_now()
    base, path = _t4_paths()
    f = _T4.get("fake") or {}
    if "live" in f:
        live_st, br = f["live"], None
    else:
        ctx = _lz_ctx()
        _lz_sync(5, ctx)
        br = ctx.get("br24")
        live_st = _lz_mgr.live(base, path, br, None, now).get("status")
    al = _t4_alarms(now)
    st = _t4_load()
    lvl = _lz_mgr.t4_level(live_st, al, st["pre"], br)
    sd = _lz_mgr.t4_sdr(base, now)
    fb = bool((sd.get("s2") or {}).get("fb"))
    if _T4["fb_prev"] is not None and fb != _T4["fb_prev"]:
        _t4_event("DAB", "t4fb", "info", "SDR 2 %s" % ("LOCAL-EBENE FALLBACK 10C (5C ohne Sync)" if fb else "wieder 5C (BUNDES-EBENE)"), now)
    _T4["fb_prev"] = fb
    try:
        asa = _lz_mgr.asa_monitor(base, path, now).get("status")
    except Exception:
        asa = None
    a = _T4["audio"]
    s = {"ok": _T4["ok"], "now": now, "level": lvl, "live": live_st, "sdr": sd, "hist": _lz_mgr.t4_history(path, 10), "pre": dict(st["pre"]),
         "pending": list(st["pending"].keys()), "pre_sent": st["pre_sent"], "release": _t4_release_state(now), "asa_status": asa,
         "uplink": (_t4_us() or {}).get("current"), "alarm_identifier": _lz_mgr.alarm_identifier(al),
         "alarms_fresh": bool("alarms" in f or (_T2D.get("started") and 0 <= now - (_T2D.get("t") or 0) <= T4_ALARM_MAX_AGE_S)),
         "audio": {"busy": a["busy"], "last": a["last"], "err": a["err"], "card": a["card"], "spoken_n": len(st["spoken"]),
                   "tools": {x: bool(_t4_which(x)) for x in T4_EXE}, "sirene": _t4_os.path.isfile(_t4_os.path.join(_t4_static(), "sirene.wav"))},
         "hb": {"due": _T4["hb"].get("due"), "last": st.get("hb_last"), "slot_sent": st.get("hb_slot_sent")},
         "freq_note": "Netzfrequenz wird alle %s s gemessen; ein Wert ausserhalb startet nach %d s eine zweite Messung - Vor-Alarm, wenn beide (> 3 s Abstand) ausserhalb liegen"
                      % (globals().get("FREQ_INTERVAL", "?"), T4_CONFIRM_DELAY_S),
         "tick": {"t": _T4["t"], "n": _T4["n"], "err": _T4["tick_err"], "every_s": T4_TICK_S, "thread": _T4["started"]}}
    _T4["status"], _T4["status_t"] = s, now
    return s


def _t4_alarms(now=None):
    """Alarmliste aus Teil 2 - nur aus einem echten, frischen Teil-2-Lauf (der Teil-2-Selbsttest hinterlaesst sonst Testalarme)."""
    f = _T4.get("fake") or {}
    if "alarms" in f:
        return f["alarms"]
    now = now or _t4_now()
    t = _T2D.get("t") or 0
    return list(_T2D.get("alarms") or []) if _T2D.get("started") and 0 <= now - t <= T4_ALARM_MAX_AGE_S else []


def _t4_tick(now=None):
    now = now or _t4_now()
    with _T4_LOCK:
        _t4_pre_tick(now)
        al = _t4_alarms(now)
        _t4_audio_tick(al, _lz_mgr.alarm_identifier(al), now)
        _t4_hb_tick(now)
        if now - _T4["status_t"] >= T4_STATUS_S:
            _t4_status_calc(now)


def _t4_loop():
    _t4_time.sleep(T4_FIRST_S)
    while True:
        try:
            _t4_tick()
            _T4.update(t=_t4_now(), n=_T4["n"] + 1, tick_err=None)
        except Exception as e:
            _T4["tick_err"] = str(e)[:160]
            print("teil4 Pruefung:", e, flush=True)
        _t4_time.sleep(T4_TICK_S)


# ---------------------------------------------------------------- Web
def _t4_api():
    from flask import jsonify
    try:
        s = _T4.get("status")
        if not s or _t4_now() - _T4["status_t"] > 5:
            with _T4_LOCK:
                s = _t4_status_calc()
        return jsonify(s)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120]})


_T4_RES_RE = _t4_re.compile(r"^(leaflet/leaflet\.(js|css)|tiles/[0-9]{1,2}/[0-9]{1,5}/[0-9]{1,5}\.png)$")


def _t4_res(p):
    """Karte: Leaflet + Offline-Kacheln aus <Dashboard>/static (nur diese Muster, unabhaengig vom Flask-static-Ordner)."""
    from flask import send_from_directory, abort
    if not _T4_RES_RE.match(p or ""):
        abort(404)
    try:
        return send_from_directory(_t4_static(), p, max_age=86400)
    except TypeError:
        return send_from_directory(_t4_static(), p)


def _t4_api_map():
    from flask import jsonify
    try:
        base, path = _t4_paths()
        return jsonify(_lz_mgr.t4_map(base, path))
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)[:120], "masts": [], "zones": [], "roads": [], "nogeo": []})


def _t4_release_post():
    """Knopf SDR 2 freigeben: nur bei aktivem Vor-Alarm, Internet wieder Telekom und Frequenz 5 min stabil (Server prueft)."""
    from flask import jsonify, request as rq
    err, j = _t2d_check(rq)
    if err:
        return jsonify({"ok": False, "error": err}), j
    if j.get("action") != "freigeben":
        return jsonify({"ok": False, "error": "ungueltig"}), 400
    with _T4_LOCK:
        now = _t4_now()
        st = _t4_load()
        if not st["pre"].get("on"):
            return jsonify({"ok": False, "error": "kein Vor-Alarm aktiv - Rueckgabe ueber den Teil-2-Knopf"}), 409
        r = _t4_release_state(now)
        if not r["cond"]:
            return jsonify({"ok": False, "error": "noch nicht freigegeben: %s" % r["why"]}), 409
        base, path = _t4_paths()
        with _T2D_LOCK:
            _lz_mgr.takeover_set(base, False, "teil4", "", "sdr2_freigeben", now)
        st["pre"] = {"on": False, "kinds": [], "since": None, "why": "", "off_t": now}
        st["pending"] = {}
        _t4_save()
        _t4_event("VORALARM", "frei", "info", "SDR 2 freigegeben (Telekom, Frequenz 5 min stabil)", now)
        _t4_status_calc(now)
    print("teil4: Knopf SDR 2 freigeben -> Stick 2 zurueck in den Hobby-Betrieb", flush=True)
    return jsonify({"ok": True})


def _t4_gate(fn):
    """Teil-2-Knopf 'zurueck' sperren, solange ein Vor-Alarm aktiv ist (Rueckgabe dann nur per SDR 2 freigeben)."""
    def t2_stick2_t4():
        from flask import jsonify, request as rq
        try:
            j = rq.get_json(silent=True) or {}
            if j.get("action") == "zurueck" and _t4_load()["pre"].get("on"):
                return jsonify({"ok": False, "error": "Vor-Alarm aktiv (%s): Rueckgabe nur ueber 'SDR 2 freigeben' (Telekom + 5 min stabile Frequenz)"
                                % "+".join(_t4_load()["pre"].get("kinds") or [])}), 409
        except Exception as e:
            print("teil4 Sperre Teil-2-Knopf:", e, flush=True)
        return fn()
    t2_stick2_t4._t4 = True
    t2_stick2_t4.__wrapped__ = fn
    return t2_stick2_t4


_T4_CSS = """<style id="t4-css">@keyframes t4blink{0%,49%{opacity:1}50%,100%{opacity:.35}}
.lage.t4s.t4-ok{background:#22c55e18!important;color:#22c55e!important;border-color:#22c55e55!important;box-shadow:0 0 24px #22c55e22!important}
.lage.t4s.t4-probe{background:#eab30818!important;color:#eab308!important;border-color:#eab30855!important;box-shadow:0 0 24px #eab30822!important}
.lage.t4s.t4-alarm{background:#ef444433!important;color:#fecaca!important;border-color:#ef4444!important;box-shadow:0 0 28px #ef444466!important}
.lage.t4s.t4-pre,.lage.t4s.t4-offline{background:#f9731622!important;color:#fdba74!important;border-color:#f97316!important;box-shadow:0 0 28px #f9731644!important}
.lage.t4s.t4-blink{animation:t4blink 1s infinite}
.lage .t4-why{display:block;font-size:.8rem;font-weight:600;margin-top:8px;opacity:1;line-height:1.3;word-break:break-word}
.t4-l{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px}
</style>"""

_T4_JS = r"""
(function(){var D=null,BUSY=0;
function el(t,c,x){var e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function ninaCard(){var ts=document.querySelectorAll('.title');for(var i=0;i<ts.length;i++){if(/\bNINA\b/i.test(ts[i].textContent||'')){var c=ts[i].closest('.card');if(c&&!/^(br24Tile|t2Tile|t4Sdr|t4Hist)$/.test(c.id))return c;}}return null;}
function fmt(t){return t?new Date(t*1000).toLocaleString('de-DE',{timeZone:'Europe/Berlin',day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'–';}
function n(v,d){return (v===null||v===undefined)?'–':Number(v).toFixed(d).replace('.',',');}
function line(t,cls){var l=el('div',(cls||'small')+' t4-l');t.appendChild(l);return l;}
var BS='margin-top:10px;width:100%;background:#1e3a5f;color:#93c5fd;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:0.95rem';
var BD='margin-top:10px;width:100%;background:#1e293b;color:#64748b;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:0.95rem';
function lage(){var L=document.getElementById('t4Lage');if(!L||!D||!D.level)return;var v=D.level;
L.className='lage '+(L.getAttribute('data-t4-orig')||'')+' t4s t4-'+v.lvl+(v.blink?' t4-blink':'');
var w=document.getElementById('t4Why');if(w)w.textContent='Status: '+v.label+' – '+(v.why||'');}
function tele(x){return 'RSSI '+(x.rssi===null||x.rssi===undefined?'–':n(x.rssi,1)+' dBm')+' · BER (FIC) '+n(x.fic_rate,4)+' · SNR '+n(x.snr,1)+' dB'+(x.age_s!=null?' · vor '+(x.age_s<120?x.age_s+' s':Math.round(x.age_s/60)+' min'):'');}
function after(){return document.getElementById('t2Tile')||document.getElementById('br24Tile')||ninaCard();}
function sdr(){var a=after();if(!a||!D||!D.sdr)return;var t=document.getElementById('t4Sdr');
if(!t){t=el('div',(ninaCard()||a).className);t.id='t4Sdr';t.appendChild(el('div','title','📡 SDR-Status'));t._l=[line(t),line(t),line(t),line(t),line(t),line(t)];
t._b=el('button');t._b.type='button';t.appendChild(t._b);t._st=line(t);var k=el('a','small','🗺 Karte: Masten, Funkhorizont, Gefahrenzonen →');k.href='/karte';k.style.cssText='display:block;margin-top:8px;color:#93c5fd';t.appendChild(k);
t._b.addEventListener('click',function(){if(BUSY||!D.release||!D.release.ok)return;if(!window.confirm('SDR 2 wirklich freigeben (zurück in den Hobby-Betrieb)?\n\nInternet läuft wieder über Telekom und die Netzfrequenz ist seit 5 min stabil.'))return;
BUSY=1;t._st.textContent='…';fetch('/api/t4/sdr2',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json','X-T2':'1'},body:JSON.stringify({action:'freigeben',confirm:true})})
.then(function(r){return r.json();}).then(function(j){t._st.textContent=j.ok?'erledigt':('nicht erledigt: '+(j.error||'Fehler'));}).catch(function(){t._st.textContent='nicht erledigt: Netzfehler';}).then(function(){BUSY=0;load();});});}
if(a.nextSibling!==t)a.parentNode.insertBefore(t,a.nextSibling);
var s1=D.sdr.s1||{},s2=D.sdr.s2||{},L=t._l,pre=D.pre||{},rl=D.release||{};
L[0].textContent='SDR 1'+(s1.sn?' SN '+s1.sn:'')+': '+s1.state+' · '+n(s1.f_mhz,3)+' MHz';L[0].style.fontWeight='600';
L[1].textContent=tele(s1);L[1].style.color='#94a3b8';
L[2].textContent='SDR 2'+(s2.sn?' SN '+s2.sn:'')+': '+s2.state+(s2.f_mhz?' · '+n(s2.f_mhz,3)+' MHz':'')+(s2.takeover?' · seit '+fmt(s2.since)+' ('+(s2.src||'?')+')':'');
L[2].style.color=s2.takeover?(s2.fb?'#f97316':'#ef4444'):'#22c55e';L[2].style.fontWeight='600';
L[3].textContent=s2.takeover?(tele(s2)+(s2.fb?' · 5C ohne Sync, 5C-Versuch alle '+Math.round((s2.retry_s||600)/60)+' min':'')):('Bereitschaft: '+(s2.mode||'Hobby'));L[3].style.color='#94a3b8';
L[4].textContent=pre.on?('VORALARM '+(pre.kinds||[]).join('+')+' seit '+fmt(pre.since)+': '+(pre.why||'')):'kein Vor-Alarm (DSL/Netzfrequenz)';L[4].style.color=pre.on?'#f97316':'#94a3b8';
L[5].textContent=pre.on?('Freigabe: '+(rl.ok?'möglich':'gesperrt')+' – '+(rl.why||'')):(D.sdr.ber_note||'');L[5].style.color=pre.on?(rl.ok?'#22c55e':'#fdba74'):'#64748b';
t._b.style.display=pre.on?'':'none';t._b.textContent='✅ SDR 2 freigeben';t._b.disabled=!rl.ok;t._b.setAttribute('style',(rl.ok?BS:BD)+(pre.on?'':';display:none'));}
function hist(){var a=document.getElementById('t4Sdr');if(!a||!D)return;var t=document.getElementById('t4Hist');
if(!t){t=el('div',a.className);t.id='t4Hist';t.appendChild(el('div','title','🕘 Ereignis-Historie (letzte 10)'));t._b=el('div');t.appendChild(t._b);}
if(a.nextSibling!==t)a.parentNode.insertBefore(t,a.nextSibling);
var h=D.hist||[];t._b.textContent='';if(!h.length){line(t._b).textContent='noch keine Ereignisse';}
for(var i=0;i<h.length;i++){var l=line(t._b);l.textContent=h[i].line;l.style.color=h[i].color;l.title=h[i].line;}}
function draw(){lage();sdr();hist();}
function load(){fetch('/api/t4/status',{credentials:'same-origin'}).then(function(x){return x.json();}).then(function(j){if(j&&j.level){D=j;draw();}}).catch(function(){});}
try{D=JSON.parse(document.getElementById('t4-data').textContent);}catch(e){}
draw();setInterval(draw,2000);setInterval(load,10000);})();
"""


def _t4_after(resp):
    try:
        from flask import request as _t4_rq
        if (_t4_rq.path.rstrip("/") or "/") == "/" and resp.status_code == 200 and not resp.direct_passthrough \
                and (resp.mimetype or "") == "text/html" and not resp.headers.get("Content-Encoding"):
            body = resp.get_data(as_text=True)
            if 'id="t4-js"' not in body:
                try:
                    s = _T4.get("status") or _t4_status_calc()
                    data = _sdr_json.dumps(s, ensure_ascii=False, default=str).replace("<", "\\u003c")
                    lv = (s.get("level") or {})
                except Exception:
                    data, lv = "null", {}
                m = _t4_re.search(r'<div class="lage (normal|auffaellig|kritisch)">', body)
                if m:
                    cls = "lage %s t4s t4-%s%s" % (m.group(1), lv.get("lvl", "ok"), " t4-blink" if lv.get("blink") else "")
                    why = _t4_html_esc("Status: %s – %s" % (lv.get("label", "?"), lv.get("why", "")))
                    j = body.find("</div>", m.end())
                    body = body[:m.start()] + '<div class="%s" id="t4Lage" data-t4-orig="%s">' % (cls, m.group(1)) + body[m.end():j] + \
                        '<small class="t4-why" id="t4Why">%s</small>' % why + body[j:]
                h = body.find("</head>")
                if h >= 0:
                    body = body[:h] + _T4_CSS + body[h:]
                add = '<script type="application/json" id="t4-data">' + data + '</script><script id="t4-js">' + _T4_JS + '</script>'
                j = body.rfind("</body>")
                body = (body[:j] + add + body[j:]) if j >= 0 else (body + add)
                resp.set_data(body)
    except Exception as e:
        print("teil4 Lage-Seite:", e, flush=True)
    return resp


def _t4_html_esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _t4_tiles_info():
    st = _t4_static()
    info = {"have": _t4_os.path.isdir(_t4_os.path.join(st, "tiles", "10")), "leaflet": _t4_os.path.isfile(_t4_os.path.join(st, "leaflet", "leaflet.js"))}
    try:
        with open(_t4_os.path.join(st, "tiles", "quelle.json"), encoding="utf-8") as f:
            q = _t4_json.load(f)
        info.update({k: q.get(k) for k in ("attribution", "attribution_html", "date", "z_wide", "z_near", "r_wide_km", "r_near_km")})
    except Exception:
        pass
    return info


_T4_MAP_JS = r"""
(function(){var D=null,T=null,G=null,map=null;
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
function n(v,d){return (v===null||v===undefined)?'–':Number(v).toFixed(d).replace('.',',');}
var CC={'11D':'#60a5fa','5C':'#ef4444','10C':'#f97316'};
function init(){T=JSON.parse(document.getElementById('t4k-tiles').textContent||'{}');var info=document.getElementById('t4kInfo');
if(typeof L==='undefined'){info.textContent='Leaflet fehlt (static/leaflet) – apply-teil4.sh erneut ausführen';return;}
var h=(D&&D.home)||{lat:49.55782283,lon:11.15501383};map=L.map('t4map',{zoomControl:true,minZoom:3,maxZoom:13}).setView([h.lat,h.lon],9);
var blank='data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
var att=T.attribution_html||'Kacheln fehlen – prepper-tiles-teil4.sh ausführen';
L.tileLayer('/karte/res/tiles/{z}/{x}/{y}.png',{maxNativeZoom:T.z_wide||10,maxZoom:13,minZoom:0,attribution:att,errorTileUrl:blank}).addTo(map);
var dn=(T.r_near_km||60)/111.32,de=(T.r_near_km||60)/(111.32*Math.cos(h.lat*Math.PI/180));
L.tileLayer('/karte/res/tiles/{z}/{x}/{y}.png',{minZoom:(T.z_wide||10)+1,maxZoom:13,maxNativeZoom:T.z_near||13,bounds:[[h.lat-dn,h.lon-de],[h.lat+dn,h.lon+de]],errorTileUrl:blank}).addTo(map);
G=L.layerGroup().addTo(map);info.textContent=T.have?('Offline-Kacheln ('+(T.date||'?')+')'):'Offline-Kacheln fehlen – prepper-tiles-teil4.sh ausführen';draw();}
function pop(m){var r='<b>'+esc(m.name)+'</b><br>Distanz '+n(m.dist_km,1)+' km · Funkhorizont D '+n(m.D_km,1)+' km<br>Antenne '+m.h_m+' m ü. NN ('+m.site_m+' + '+m.ant_m+' m)';
for(var i=0;i<m.channels.length;i++){var c=m.channels[i];r+='<br>'+esc(c.ch)+' TII '+esc(c.tii)+': '+(c.rx==='tii'?'<b>empfangen (TII)</b>':(c.rx==='kanal'?'Kanal empfangen, Mast unsicher':'nicht empfangen'))+(c.rx?' · RSSI '+(c.rssi==null?'–':n(c.rssi,1)+' dBm')+' · BER (FIC) '+n(c.ber,4)+' · SNR '+n(c.snr,1)+' dB':'');}
if(m.overreach)r+='<br><b style="color:#f97316">Überreichweite: Distanz größer als Funkhorizont D</b>';return r;}
function draw(){if(!map||!D)return;G.clearLayers();var h=D.home;
L.circleMarker([h.lat,h.lon],{radius:7,color:'#22c55e',fillColor:'#22c55e',fillOpacity:.9}).bindPopup('<b>'+esc(h.name)+'</b><br>'+n(h.lat,5)+', '+n(h.lon,5)+' · '+n(h.h_m,1)+' m ü. NN').addTo(G);
var ms=D.masts||[];for(var i=0;i<ms.length;i++){var m=ms[i],c='#94a3b8';for(var k=0;k<m.channels.length;k++){if(m.channels[k].rx==='tii'){c=CC[m.channels[k].ch]||c;break;}}
if(m.rx==='tii'){L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{color:c,weight:1+5*m.q,opacity:.25+.7*m.q}).addTo(G);L.circle([h.lat,h.lon],{radius:m.D_km*1000,color:c,weight:1,opacity:.5,fill:false,dashArray:'6 6'}).addTo(G);}
else if(m.rx==='kanal'){L.polyline([[h.lat,h.lon],[m.lat,m.lon]],{color:'#94a3b8',weight:1,opacity:.35,dashArray:'4 6'}).addTo(G);}
L.circleMarker([m.lat,m.lon],{radius:m.rx==='tii'?7:5,color:c,fillColor:c,fillOpacity:m.rx?0.85:0.25}).bindPopup(pop(m)).addTo(G);
if(m.overreach){L.marker([m.lat,m.lon],{icon:L.divIcon({className:'t4-pulse',iconSize:[26,26]}),interactive:false}).addTo(G);}}
var zs=D.zones||[];for(var i=0;i<zs.length;i++){var z=zs[i],g=z.geometry||{},p='<b>'+esc(z.source)+'</b>: '+esc(z.headline)+(z.approx?'<br>Gebiet ungefähr':'');
if(g.type==='Point'&&g.coordinates){L.circle([g.coordinates[1],g.coordinates[0]],{radius:z.radius_m||3000,color:'#ef4444',weight:2,fillColor:'#ef4444',fillOpacity:.18}).bindPopup(p).addTo(G);}
else if(g.type){L.geoJSON(g,{style:{color:'#ef4444',weight:2,fillColor:'#ef4444',fillOpacity:.18}}).bindPopup(p).addTo(G);}}
var rs=D.roads||[];for(var i=0;i<rs.length;i++){var z=rs[i],g=z.geometry||{},ll=null;if(g.type==='Point')ll=[g.coordinates[1],g.coordinates[0]];else if(g.type){try{ll=L.geoJSON(g).getBounds().getCenter();}catch(e){}}
if(ll)L.marker(ll,{icon:L.divIcon({className:'t4-tri',html:'▲',iconSize:[22,22]})}).bindPopup('<b>Straßensperre</b> ('+esc(z.source)+'): '+esc(z.headline)).addTo(G);}
var lg=document.getElementById('t4kLeg'),x='<b>Legende</b>: ● grün Empfänger · Linie = Mast per TII empfangen (Stärke/Deckkraft nach '+'RSSI, sonst SNR) · gestrichelt grau = Kanal empfangen, Mast unsicher · gestrichelter Kreis = Funkhorizont D je empfangenem Mast · pulsierend = Überreichweite · rot = Gefahrenzone · ▲ = Straßensperre<br>'+esc(D.formula)+' · '+esc(D.note);
if((D.nogeo||[]).length){x+='<br><b>Ohne Ort</b>: ';for(var i=0;i<D.nogeo.length;i++)x+=(i?' · ':'')+esc(D.nogeo[i].source)+': '+esc(D.nogeo[i].headline)+(D.nogeo[i].road?' (Sperre)':'');}
x+='<br><span style="opacity:.7">Masten: '+esc(D.src)+'</span>';lg.innerHTML=x;}
function load(){fetch('/api/t4/map',{credentials:'same-origin'}).then(function(r){return r.json();}).then(function(j){if(j&&j.masts){D=j;draw();}}).catch(function(){});}
try{D=JSON.parse(document.getElementById('t4k-data').textContent);}catch(e){}
init();setInterval(load,30000);})();
"""


def _t4_karte():
    from flask import Response
    try:
        base, path = _t4_paths()
        d = _sdr_json.dumps(_lz_mgr.t4_map(base, path), ensure_ascii=False, default=str).replace("<", "\\u003c")
    except Exception as e:
        print("teil4 Karte:", e, flush=True)
        d = "null"
    ti = _sdr_json.dumps(_t4_tiles_info(), ensure_ascii=False).replace("<", "\\u003c")
    html = (globals().get("NAV_UNIFY") or "") + """
<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>Karte</title><link rel="stylesheet" href="/karte/res/leaflet/leaflet.css">
<style>body{margin:0;background:#0f172a;color:#e2e8f0;font-family:system-ui,-apple-system,sans-serif}
.t4k-h{padding:6px 10px;font-size:.9rem;font-weight:600}.t4k-h small{font-weight:400;color:#94a3b8;margin-left:6px}
#t4map{height:calc(100vh - 190px);min-height:340px;margin:0 6px;border-radius:10px;border:1px solid #334155;background:#1e293b}
#t4kLeg{padding:8px 10px;font-size:.75rem;color:#cbd5e1;line-height:1.45}
.leaflet-container{background:#1e293b}.leaflet-popup-content{font-size:.8rem;line-height:1.35}
.t4-pulse{border-radius:50%;border:3px solid #f97316;box-sizing:border-box;animation:t4p 1.4s ease-out infinite}
@keyframes t4p{0%{transform:scale(.6);opacity:1}100%{transform:scale(2.2);opacity:0}}
.t4-tri{color:#f97316;font-size:20px;line-height:22px;text-align:center;text-shadow:0 0 3px #000}
</style></head><body>
<div class="t4k-h">🗺 Karte Kalchreuth <small id="t4kInfo"></small></div>
<div id="t4map"></div><div id="t4kLeg"></div>
<script type="application/json" id="t4k-data">""" + d + """</script><script type="application/json" id="t4k-tiles">""" + ti + """</script>
<script src="/karte/res/leaflet/leaflet.js"></script><script id="t4k-js">""" + _T4_MAP_JS + """</script>
</body></html>"""
    return Response(html, mimetype="text/html")


# ---------------------------------------------------------------- Selbsttest (Testsender, Test-Audio, Test-Prozesse: nichts wird gesendet, nichts klingt)
def _t4_selftest():
    import tempfile
    d = tempfile.mkdtemp()
    p = _t4_os.path.join(d, "lagezentrum.db")
    sd = _t4_os.path.join(d, "static")
    _t4_os.makedirs(sd)
    with open(_t4_os.path.join(sd, "sirene.wav"), "wb") as f:
        f.write(b"RIFF")
    clock = [1790000000]
    ran, spawned, killed, sent = [], [], [], []
    host = {"m1": "192.168.178.141"}

    class FP:
        def __init__(self, argv):
            self.argv, self.pid, self.rc = argv, 40000 + len(spawned), 0
            spawned.append(argv)

        def poll(self):
            return self.rc

    def run(argv):
        ran.append(argv)
        if argv[3:4] == ["scontrols"]:
            return 0, "Simple mixer control 'Headphone',0\n"
        if "sget" in argv:
            return 0, "  Mono: Playback -1234 [42%] [-12.34dB] [on]\n"
        return 0, ""

    def tx(text, channel=0):
        sent.append((text, channel))
        return True
    fk = {"now": lambda: clock[0], "base": d, "path": p, "static": sd, "run": run, "spawn": FP, "kill": lambda pid, sg: killed.append(pid), "sync": True,
          "which": lambda n: "/usr/bin/" + n, "procs": lambda: [(50001, "aplay"), (50002, "espeak-ng")],
          "cards": " 0 [vc4hdmi0       ]: vc4-hdmi - vc4-hdmi-0\n 1 [Headphones     ]: bcm2835_headpho - bcm2835 Headphones\n",
          "us": {"current": "telekom", "stale": False, "history": []}, "alarms": [], "live": "OK", "fetch": lambda: {"value": 49.70},
          "wx": {"temp": 11.6, "icon": "☀️", "sunshine": 5.0, "days": [{"min": 3, "max": 13}]}}
    t3f0, st0, fs0, au0, hb0, ip0, ca0, fb0 = _T3S.get("fake"), _T4["st"], _T4["fs"], _T4["audio"], _T4["hb"], _T4["ident_prev"], _T4["confirm_at"], _T4["fb_prev"]
    ls0 = dict(_T3S["last_send"])
    _T4.update(fake=fk, st=None, fs=_t4_col.deque(maxlen=240), confirm_at=None, ident_prev=0, fb_prev=None,
               audio={"busy": False, "abort": False, "procs": [], "vol": None, "last": None, "err": None, "card": None},
               hb={"due": None, "w_t": None, "slot": None, "next_try": 0, "last": None})
    _T3S["fake"] = {"now": lambda: clock[0], "base": d, "path": p, "health": lambda nd: {"host": host["m1"], "connected": True, "queued": 0},
                    "tx": {"m1": tx, "m2": lambda t, c=0: (_ for _ in ()).throw(RuntimeError("Mesh 2 darf nie"))}, "alarms": []}
    _T3S["last_send"] = {"m1": 0, "m2": 0}
    try:
        _lz_dbm.migrate(p)
        _lz_dbm.migrate_t3(p)
        # Ampel
        s = _t4_status_calc(clock[0])
        assert s["level"]["lvl"] == "ok" and s["sdr"]["s2"]["state"] == "FREI / BEREITSCHAFT" and s["release"]["ok"] is False, s["level"]
        real = [{"src": "ASA", "key": "a1", "text": "Gefahr: Fenster und Türen schließen", "real": True, "test": False, "takeover": True}]
        fk["alarms"] = [{"src": "ASA", "key": "p1", "text": "Probewarnung", "real": False, "test": True}]
        assert _t4_status_calc(clock[0])["level"]["lvl"] == "probe"
        fk["alarms"] = [{"src": "ASA", "key": "o1", "text": "TEST ASA DE (DAB 5C) · keine echte Warnung · x", "real": False, "test": True}]
        assert _t4_status_calc(clock[0])["level"]["lvl"] == "ok"
        fk["alarms"], fk["live"] = [], "SDR_OFFLINE"
        lv = _t4_status_calc(clock[0])["level"]
        assert lv["lvl"] == "offline" and lv["blink"] and lv["color"] == "#f97316"
        fk["live"] = "OK"
        # Audio: Echtalarm -> 100 %, Sirene, Ansage einmal, Lautstaerke zurueck; gleicher Text nie wieder; Entwarnung -> Kill-Switch
        fk["alarms"] = real
        _t4_tick(clock[0])
        assert [a[0] for a in spawned] == ["aplay", "espeak-ng", "aplay"] and spawned[0][3] == "plughw:CARD=Headphones,DEV=0" and spawned[0][4].endswith("sirene.wav"), spawned
        assert spawned[1][1:7] == ["-v", "de", "-s", "140", "-a", "100"] and "Fenster" in spawned[1][-1], spawned[1]
        sets = [a for a in ran if "sset" in a and a[-1] != "unmute"]
        assert [a[-1] for a in sets] == ["100%", "42%"] and all(a[3] == "1" for a in sets), sets                                     # 100 %, danach alte 42 %
        assert _t4_status_calc(clock[0])["level"]["lvl"] == "alarm"
        clock[0] += 30
        _t4_tick(clock[0])
        assert len(spawned) == 3                                                                                                    # gleicher Text: nie erneut
        _T4["st"] = None                                                                                                             # auch nach Neustart nicht
        _t4_tick(clock[0] + 2)
        assert len(spawned) == 3
        fk["alarms"] = []
        clock[0] += 30
        _t4_tick(clock[0])
        assert killed == [50001, 50002], killed                                                                                     # Entwarnung: aplay/espeak-ng beendet
        assert all(a[0] in T4_EXE for a in ran + spawned)
        # Vor-Alarm DSL -> 5C, eine Meldung Mesh 1 (Schalter AN), Teil-2-Rueckgabe gesperrt, Freigabe nur bei Telekom + 5 min stabil
        _lz_mesh.set_auto(d, True, "selftest", clock[0])
        fk["us"] = {"current": "starlink", "stale": False, "history": [{"t": clock[0] - 30, "from": "telekom", "to": "starlink", "why": "x"}]}
        _t4_tick(clock[0])
        to = _lz_mgr.takeover_load(d)
        assert to["on"] and to["src"] == "DSL" and _t4_load()["pre"]["on"] and len(sent) == 1 and sent[0][0].startswith("VORALARM DSL") and sent[0][1] == 0, (to, sent)
        lv = _t4_status_calc(clock[0])["level"]
        assert lv["lvl"] == "pre" and not lv["blink"] and "DSL" in lv["why"]
        assert _lz_dbm.mesh_hash_since(_lz_mesh.nina_hash(sent[0][0], "m1", 0), clock[0] - 5, p) is True                       # protokolliert
        clock[0] += 20
        _t4_tick(clock[0])
        assert len(sent) == 1                                                                                                       # einmalig
        # Netzfrequenz: Wert ausserhalb -> zweite Messung nach 4 s -> Taktik-Warnung, blinkend orange
        _t4_sample(49.75, clock[0])
        assert _T4["confirm_at"] == clock[0] + T4_CONFIRM_DELAY_S
        _t4_tick(clock[0] + 2)
        assert "NETZ" not in _t4_load()["pre"]["kinds"]
        clock[0] += 4
        _t4_tick(clock[0])
        assert "NETZ" in _t4_load()["pre"]["kinds"] and len(sent) == 2 and sent[1][0].startswith("TAKTIK-WARNUNG Netzfrequenz 49,700 Hz"), sent
        assert _t4_status_calc(clock[0])["level"]["blink"] is True
        assert all(len(t) <= 200 for t, c in sent)
        # Freigabe gesperrt (Starlink, Frequenz nicht stabil); Takeover bleibt erzwungen
        rs = _t4_release_state(clock[0])
        assert rs["ok"] is False and "Telekom" in rs["why"]
        _lz_mgr.takeover_set(d, False, now=clock[0])
        _T4["enf_t"] = 0
        _t4_tick(clock[0] + 1)
        assert _lz_mgr.takeover_load(d)["on"]                                                                                      # nur per Knopf
        fk["us"] = {"current": "telekom", "stale": False, "history": fk["us"]["history"] + [{"t": clock[0], "from": "starlink", "to": "telekom"}]}
        for i in range(14):
            _t4_sample(50.0 + (i % 3) * 0.01, clock[0] + 10 + 25 * i)
        clock[0] += 10 + 25 * 13
        assert _t4_release_state(clock[0])["ok"] is True                                                                            # 325 s stabil + Telekom
        # Heartbeat: 60 s nach Wetter; Pegel bei +60 s -> 60 s nach dem Pegel; <= 160 Zeichen; einmal je Slot
        _T4["hb"].update(due=clock[0] + 60, w_t=clock[0], slot="2026-10-17-15", next_try=0)
        _T3S["last_send"]["m1"] = clock[0]
        assert _t4_hb_tick(clock[0] + 60) == "wait-pegel"
        _T3S["last_send"]["m1"] = clock[0] + 61
        assert _t4_hb_tick(clock[0] + 62) == "wait-gap" and _t4_hb_tick(clock[0] + 120) == "wait-gap"
        assert _t4_hb_tick(clock[0] + 122) == "sent" and len(sent) == 3 and sent[2][0].startswith("HB ") and len(sent[2][0]) <= 160, sent
        assert "ASA" in sent[2][0] and "Wetter 12°C 3/13°" in sent[2][0] and "Telekom" in sent[2][0], sent[2][0]
        _T4["hb"].update(due=clock[0] + 200, w_t=clock[0] + 140, slot="2026-10-17-15", next_try=0)
        assert _t4_hb_tick(clock[0] + 400) == "skip" and len(sent) == 3                                                           # gleicher Slot: kein Doppel
        _lz_mesh.set_auto(d, False, "selftest", clock[0])
        _T4["hb"].update(due=clock[0] + 600, w_t=clock[0] + 540, slot="2026-10-17-18", next_try=0)
        assert _t4_hb_tick(clock[0] + 700) == "fail" and len(sent) == 3 and _t4_load()["hb_slot_sent"] == "2026-10-17-18"        # Schalter AUS: nichts
        host["m1"] = "192.168.178.140"
        _lz_mesh.set_auto(d, True, "selftest", clock[0])
        _T4["hb"].update(due=clock[0] + 900, w_t=clock[0] + 840, slot="2026-10-17-21", next_try=0)
        assert _t4_hb_tick(clock[0] + 1000) == "fail" and len(sent) == 3                                                          # nie an .140
        assert all(not t.startswith(("HB", "VORALARM", "TAKTIK")) or c == 0 for t, c in sent)
        # Karte/Historie
        m = _lz_mgr.t4_map(d, p, clock[0])
        assert len(m["masts"]) == len(_lz_mgr.T4_MASTS) and m["home"]["h_m"] == 431.7
        assert any("VORALARM" in x["line"] for x in _t4_status_calc(clock[0])["hist"])
        assert _t4_card()["dev"] == "plughw:CARD=Headphones,DEV=0"
        assert _t4_gate(lambda: "durch")._t4 and _t4_html_esc('<a">') == "&lt;a&quot;&gt;"
    finally:
        _T3S["fake"] = t3f0
        _T3S["last_send"] = ls0
        _T4.update(fake=None, st=st0, fs=fs0, audio=au0, hb=hb0, ident_prev=ip0, confirm_at=ca0, fb_prev=fb0, status=None, status_t=0)
    return ("teil4 selftest ok (Ampel gruen/gelb nur ASA-Probe/rot/orange blinkend, Audio 100 % + Sirene + Ansage einmal + Lautstaerke zurueck, Kill-Switch, "
            "Vor-Alarm DSL/Netz -> 5C + je 1 Meldung Mesh 1, Freigabe nur Telekom + 5 min stabil, Heartbeat +60 s nach Pegel <= 160, Schalter AUS/.140 nie; Testsender/Test-Audio)")


try:
    if _lz_mgr is None or not hasattr(_lz_mgr, "t4_level") or not hasattr(_lz_mgr, "t4_map"):
        raise RuntimeError("sdr_manager.py ohne Teil 4 (%s)" % (_LZ.get("err") or "alt"))
    if not _T2D.get("ok") or not _T3S.get("ok"):
        raise RuntimeError("Teil 2/3 nicht aktiv")
    if getattr(globals().get("maybe_mesh_weather"), "_t4", False):
        raise RuntimeError("schon aktiv")
    _T4["selftest"] = _t4_selftest()
    _t4_g0 = {k: globals().get(k) for k in ("maybe_mesh_frequenz", "maybe_mesh_weather")}
    _t4_v0 = app.view_functions.get("t2_stick2")
    try:
        if not callable(_t4_g0["maybe_mesh_frequenz"]) or not callable(_t4_g0["maybe_mesh_weather"]) or not callable(_t4_v0):
            raise RuntimeError("maybe_mesh_frequenz/maybe_mesh_weather/t2_stick2 fehlt")
        globals()["maybe_mesh_frequenz"] = _t4_freq_hook(_t4_g0["maybe_mesh_frequenz"])
        globals()["maybe_mesh_weather"] = _t4_weather_hook(_t4_g0["maybe_mesh_weather"])
        app.view_functions["t2_stick2"] = _t4_gate(_t4_v0)
        for _t4_rule, _t4_ep, _t4_fn, _t4_m in (("/api/t4/status", "t4_status", _t4_api, "GET"), ("/api/t4/map", "t4_map", _t4_api_map, "GET"),
                                                ("/karte", "t4_karte", _t4_karte, "GET"), ("/api/t4/sdr2", "t4_sdr2", _t4_release_post, "POST"),
                                                ("/karte/res/<path:p>", "t4_res", _t4_res, "GET")):
            if _t4_ep not in app.view_functions:
                app.add_url_rule(_t4_rule, endpoint=_t4_ep, view_func=_t4_fn, methods=[_t4_m])
        if not any(getattr(f, "__name__", "") == "_t4_after" for f in app.after_request_funcs.get(None, [])):
            app.after_request(_t4_after)
    except Exception:
        globals().update(_t4_g0)
        if _t4_v0 is not None:
            app.view_functions["t2_stick2"] = _t4_v0
        raise
    _T4["ok"] = True
    _t4_load()
    if __name__ == "__main__" and not _T4["started"]:
        _t4_thr.Thread(target=_t4_loop, name="teil4", daemon=True).start()
        _T4["started"] = True
    print("teil4 aktiv: %s; Vor-Alarm %s; Audio-Programme %s" % (_T4["selftest"], "AN (" + "+".join(_t4_load()["pre"].get("kinds") or []) + ")" if _t4_load()["pre"].get("on") else "aus",
                                                              ", ".join("%s %s" % (x, "da" if _t4_which(x) else "FEHLT") for x in T4_EXE)), flush=True)
except Exception as _t4_e:
    _T4["err"] = str(_t4_e)[:160]
    print("teil4 FEHLER (Teil 4 aus, alter Stand aktiv):", _t4_e, flush=True)
# ===== /teil4 =====
T4B4_EOF
EXPECT_BS4="7613b38620c1c97861fdbe1d852cd4cc7e1260f8ac7ed6689f940c55eafdb14b"
cat > "$W/sdr_t4_block.py" << 'T4BS_EOF'
# ===== sdrTeil4: Teil 4 von 4 - Stick 2 bei Kaperung: hat 5C (Bundes-Ebene) nach 2 Pruefungen keinen Sync, automatisch auf 10C (Lokal Nuernberg, 213,360 MHz, LOCAL-EBENE FALLBACK); 5C-Versuch alle 10 min, bei 5C-Sync zurueck auf 5C; Zustand in broadcast_state.json t4; nur Empfang, sendet nichts =====
T4_CH_FB = "10C"             # Rueckfall-Kanal (Ensemble Nuernberg 10AD, Schweinau/Dillberg/Hersbruck)
T4_FB_AFTER = 2              # so viele 5C-Pruefungen ohne Sync nacheinander -> 10C
T4_RETRY_S = 600             # im Rueckfall alle 10 min eine 5C-Pruefung
T4_MIN_RUN_S = 15            # kuerzere (abgebrochene) Pruefungen zaehlen nicht
MASTS_DB["10C"].update(name="Lokal Nürnberg (Ensemble Nuernberg 10AD)", rx="Stick 2 Rueckfall bei Kaperung, wenn 5C nach 2 Pruefungen keinen Sync hat (Teil 4)",
                       src="Frequenz: ETSI EN 300 401 Kanalraster Band III (10C = 213,360 MHz); Ensemble Nuernberg 10AD, Sender Nuernberg/Schweinau, Dillberg, "
                           "Hersbruck: fmlist.org Sendertabelle (Abruf 17.10.2026); Rueckfall: Vorgabe Frank (Teil 4)")


def _t4_st(self):
    st = self.__dict__.get("_t4")
    if not isinstance(st, dict):
        st = {"fb": False, "fail": 0, "since": None, "last5c": 0.0, "to_since": None, "job10": False, "last_note": None}
        self.__dict__["_t4"] = st
    return st


def _t4_active(self):
    return self.role == "rot" and t2_on(self) and _t2_alarm(self)


_t4_orig_dab_list = Planner.dab_list
_t4_orig_bc_queue = Planner.bc_queue
_t4_orig_want = Planner.want
_t4_orig_sub_done = Planner.sub_done
_t4_orig_stick2_info = Planner.stick2_info


def _t4_dab_list(self):
    v = _t4_orig_dab_list(self)
    try:
        if T4_CH_FB in DAB_CHANNELS and T4_CH_FB not in [str(x) for x in v] and self.role == "rot" and t2_on(self) \
                and (_t2_alarm(self) or _t4_st(self).get("job10")):
            v = list(v) + [T4_CH_FB]
    except Exception as ex:
        print("sdrTeil4 dab_list:", ex, flush=True)
    return v


def _t4_bc_queue(self):
    q = _t4_orig_bc_queue(self)
    try:
        if not _t4_active(self):
            return q
        st = _t4_st(self)
        if st["fb"] and time.time() - float(st["last5c"] or 0) < T4_RETRY_S:
            i = _t2_dab_idx(self, T4_CH_FB)
            if i is not None and self.tool("welle"):
                st["job10"] = True
                return [("dab:%d" % i, float(self.cfg.get("dab_s") or 60))]
        return [x for x in q if x[0].startswith("dab:") and str(self.dab_list()[int(x[0][4:])]) != T4_CH_FB] if q else q
    except Exception as ex:
        print("sdrTeil4 bc_queue:", ex, flush=True)
        return q


def _t4_note(self, now):
    st = _t4_st(self)
    al = _t4_active(self)
    row = {"fb": bool(st["fb"] and al), "fail": int(st["fail"]), "since": int(st["since"]) if st["since"] and al else None,
           "last5c": int(st["last5c"]) if st["last5c"] else None, "retry_s": T4_RETRY_S, "after": T4_FB_AFTER,
           "ch": (T4_CH_FB if st["fb"] else T2_CH_ALARM) if al else None}
    if row != st.get("last_note"):
        st["last_note"] = dict(row)
        with self.lock:
            t4 = self.sbc.d.get("t4") if isinstance(self.sbc.d.get("t4"), dict) else {}
            t4.update(v=1, s2=dict(row, t=int(now)))
            self.sbc.d["t4"] = t4
            self.sbc.dirty = True
            self.sbc.last_saved = 0


def _t4_want(self, mode, now):
    try:
        if self.role == "rot" and t2_on(self):
            st = _t4_st(self)
            to = t2_takeover(self.base)
            if not _t2_alarm(self) or st["to_since"] != to.get("since"):
                if st["fb"]:
                    self.log("sdrTeil4: Stick 2 Rueckfall 10C beendet (%s)" % ("Kaperung aus" if not _t2_alarm(self) else "neue Kaperung"))
                st.update(fb=False, fail=0, since=None, last5c=0.0, to_since=to.get("since") if _t2_alarm(self) else None)
            _t4_note(self, now)
    except Exception as ex:
        print("sdrTeil4 want:", ex, flush=True)
    return _t4_orig_want(self, mode, now)


def _t4_sub_done(self, sp, now):
    ch, ran = None, 0
    try:
        job = sp["queue"][sp["i"]] if isinstance(sp, dict) and sp.get("queue") and sp.get("i", 0) < len(sp["queue"]) else ""
        if job.startswith("dab:") and self.role == "rot":
            lst = [str(x) for x in self.dab_list()]
            ch = lst[int(job[4:])] if int(job[4:]) < len(lst) else None
            ran = float(now) - float(self.since or now)
    except Exception as ex:
        print("sdrTeil4 vor sub_done:", ex, flush=True)
    try:
        return _t4_orig_sub_done(self, sp, now)
    finally:
        try:
            st = _t4_st(self)
            if ch == T4_CH_FB:
                st["job10"] = False
            if ch == T2_CH_ALARM and _t4_active(self) and ran >= T4_MIN_RUN_S:
                e = (self.sbc.d.get("dab") or {}).get(T2_CH_ALARM) or {}
                ok = e.get("rx") is True and int(e.get("t") or 0) >= int(now) - 5
                st["last5c"] = float(now)
                if ok:
                    if st["fb"]:
                        self.log("sdrTeil4: 5C wieder mit Sync -> Stick 2 zurueck auf 5C (BUNDES-EBENE)")
                    st.update(fb=False, fail=0, since=None)
                else:
                    st["fail"] = int(st["fail"]) + 1
                    if not st["fb"] and st["fail"] >= T4_FB_AFTER:
                        st.update(fb=True, since=float(now))
                        self.log("sdrTeil4: 5C ohne Sync nach %d Pruefungen -> Stick 2 auf 10C (LOCAL-EBENE FALLBACK, 213,360 MHz), 5C-Versuch alle %d min"
                                 % (st["fail"], T4_RETRY_S // 60))
                _t4_note(self, now)
        except Exception as ex:
            print("sdrTeil4 sub_done:", ex, flush=True)


def _t4_stick2_info(self):
    r = _t4_orig_stick2_info(self)
    try:
        w = self.worker
        if w is not None and w.role == "rot" and t2_on(self) and not w.pin_err and _t4_active(w) and _t4_st(w)["fb"]:
            st = _t4_st(w)
            r["txt"] = "Stick 2 SN %s: ALARM - LOCAL-EBENE FALLBACK 10C (5C ohne Sync seit %s, 5C-Versuch alle %d min); Rueckgabe nur per Knopf" % (
                cfg_serial(w.cfg), time.strftime("%d.%m. %H:%M", time.localtime(st["since"])) if st["since"] else "?", T4_RETRY_S // 60)
            r["t4"] = "fallback"
    except Exception as ex:
        print("sdrTeil4 stick2_info:", ex, flush=True)
    return r


Planner.dab_list = _t4_dab_list
Planner.bc_queue = _t4_bc_queue
Planner.want = _t4_want
Planner.sub_done = _t4_sub_done
Planner.stick2_info = _t4_stick2_info


def selftest_teil4():
    import tempfile
    had_np, old_np = "numpy" in sys.modules, sys.modules.get("numpy")
    if old_np is None:
        sys.modules["numpy"] = type(sys)("numpy")
    try:
        _selftest_teil4(tempfile.mkdtemp())
    finally:
        if not had_np or old_np is None:
            sys.modules.pop("numpy", None)
            if had_np:
                sys.modules["numpy"] = old_np


def _selftest_teil4(tmp):
    assert abs(MASTS_DB["10C"]["f_mhz"] - DAB_CHANNELS["10C"]) < 1e-6 and abs(DAB_CHANNELS["10C"] - 213.360) < 1e-6 and "Rueckfall" in MASTS_DB["10C"]["rx"]
    save_cfg_keys(tmp, {"stick2": {"serial": "72055505", "enabled": True}, "dab": ["11D"]})
    m = Planner(tmp)
    w = Planner(tmp, stick=2, main=m)
    m.worker = w
    for x in (m, w):
        x.tools.update({"welle": "/x/welle-cli", "redsea": "/x/redsea", "satdump": None})
        x._has_rp = True
        x.cfg.update(bc_enable=True, noise_enable=True, cal_enable=True)
        x.lage_user = None
    m.set_role("bc"); w.set_role("rot")
    m.t2 = True
    m.lage_apply(); w.lage_apply()
    now = time.time()
    assert "10C" not in w.dab_list() and "10C" not in m.dab_list()                        # Hobby: wie Teil 2
    write_json(p(T2_TAKEOVER, tmp), {"on": True, "since": int(now), "src": "DSL", "why": "Selbsttest", "by": "teil4"})
    w.want({"mode": "auto"}, now)
    lst = w.dab_list()
    assert lst[-1] == "10C" and "10C" not in m.dab_list(), lst
    i5, i10 = lst.index("5C"), lst.index("10C")
    assert [j for j, _ in w.bc_queue()] == ["dab:%d" % i5]                               # Kaperung: erst 5C
    assert [j for j, _ in m.bc_queue()] == ["dab:%d" % m.dab_list().index("11D")]         # Stick 1 bleibt 11D

    def check(t, ok, job=None):
        w.special = {"kind": "bc", "queue": [job or "dab:%d" % i5], "durs": [60], "i": 0, "sub_end": t, "t0": t - 60}
        w.since = t - 60
        if ok:
            w.sbc.d.setdefault("dab", {})["5C"] = {"ch": "5C", "rx": True, "t": int(t), "ensemble": "DR Deutschland"}
        else:
            w.sbc.d.setdefault("dab", {})["5C"] = {"ch": "5C", "rx": False, "t": int(t) - 900, "nosync_n": 1}
        w.sub_done(w.special, t)
        w.special = None
    check(now + 70, False)
    assert not _t4_st(w)["fb"] and _t4_st(w)["fail"] == 1
    check(now + 140, False)
    st = _t4_st(w)
    assert st["fb"] and st["fail"] == 2, st                                                # 2 Pruefungen ohne Sync -> 10C
    assert [j for j, _ in w.bc_queue()] == ["dab:%d" % i10]
    w.want({"mode": "auto"}, now + 150)
    assert w.sbc.d["t4"]["s2"]["fb"] is True and w.sbc.d["t4"]["s2"]["ch"] == "10C"
    assert "LOCAL-EBENE FALLBACK 10C" in m.stick2_info()["txt"] and m.stick2_info()["t4"] == "fallback"
    assert tune_ok("dab", None, "10C") and str(w.dab_list()[i10]) == "10C"                       # 10C darf empfangen werden (Whitelist)
    check(now + 220, False, "dab:%d" % i10)                                                # 10C-Pruefung zaehlt nicht als 5C
    assert st["fb"] and st["fail"] == 2 and not st["job10"]
    st["last5c"] = time.time() - T4_RETRY_S - 1
    assert [j for j, _ in w.bc_queue()] == ["dab:%d" % i5]                               # nach 10 min wieder 5C versuchen
    check(now + 800, False)
    assert st["fb"] and st["fail"] == 3 and [j for j, _ in w.bc_queue()] == ["dab:%d" % i10]
    st["last5c"] = time.time() - T4_RETRY_S - 1
    check(now + 1500, True)
    assert not st["fb"] and st["fail"] == 0 and [j for j, _ in w.bc_queue()] == ["dab:%d" % i5]   # 5C wieder da -> zurueck auf 5C
    check(now + 1570, False); check(now + 1640, False)
    assert st["fb"]
    w.special = {"kind": "bc", "queue": ["dab:%d" % i10], "durs": [60], "i": 0, "sub_end": now + 1700, "t0": now + 1640}
    st["job10"] = True
    write_json(p(T2_TAKEOVER, tmp), {"on": False, "off_t": int(now) + 1700, "by": "selftest"})
    os.utime(p(T2_TAKEOVER, tmp), (now + 1700, now + 1700))
    w.want({"mode": "auto"}, now + 1700)                                                    # Rueckgabe mitten im 10C-Block: sauber
    assert not st["fb"] and "10C" not in w.dab_list() and all(j.startswith("rds:") for j, _ in w.bc_queue()), (st, w.dab_list())
    assert w.sbc.d["t4"]["s2"]["ch"] is None and "Hobby" in m.stick2_info()["txt"]
    print("selftest sdrTeil4 ok (Kaperung erst 5C, 2x ohne Sync -> 10C LOCAL-EBENE FALLBACK, 5C-Versuch alle 10 min, 5C-Sync -> zurueck, Rueckgabe sauber, Stick 1 bleibt 11D)")
# ===== /sdrTeil4 =====
T4BS_EOF
EXPECT_SM4="4843089331b198e53fd1eb9de3b1a69ed05983c07ee7e03951a42074c9755b49"
cat > "$W/sm_t4.py" << 'T4SM_EOF'


# ---------------------------------------------------------------- Teil 4 (Lage-Ampel, SDR-Kachel, Historie, Karte, Heartbeat, Vor-Alarm-Regeln)
# Nur Rechnen und Lesen vorhandener Daten (broadcast_state.json, sdr_takeover.json, lagezentrum.db). Kein Netz, keine Sendewege, keine Prozesse.
import math

T4_HOME = {"lat": 49.55782283, "lon": 11.15501383, "h_m": 431.7, "name": "Kalchreuth (Empfänger)"}
T4_K = 4.12                    # Funkhorizont D [km] = 4,12 x (Wurzel h_Empfaenger + Wurzel h_Mast), Hoehen in m ueber NN
T4_RX_MAX_S = 2 * 3600         # Kanal/TII gilt so lange als empfangen
T4_CH = {"11D": {"ebene": "REGIONAL-EBENE", "label": "Kanal 11D – BR Bayern", "f_mhz": 222.064},
         "5C": {"ebene": "BUNDES-EBENE", "label": "Kanal 5C", "f_mhz": 178.352},
         "10C": {"ebene": "LOCAL-EBENE FALLBACK", "label": "Kanal 10C", "f_mhz": 213.360}}
T4_MAST_SRC = ("Standorthoehe, Antennenhoehe ueber Grund und TII: fmlist.org Sendertabelle, Ensembles 10A5 (BR Bayern 11D), 10BC (DR Deutschland 5C), "
               "10AD (Nuernberg 10C), Abruf 17.10.2026; Koordinaten: Wikipedia (Sender Amberg, Sender Hohe Linie, Teil-1-Liste) und helmuthzeitler.com (Hersbruck), "
               "Genauigkeit etwa 1 km - nur Anzeige")
T4_MASTS = [
    {"id": "nbg-schweinau", "name": "Nürnberg (Fernmeldeturm Schweinau)", "lat": 49.4283, "lon": 11.0403, "site_m": 318, "ant_m": 260, "tii": {"11D": "0514", "5C": "1203", "10C": "0701"}},
    {"id": "dillberg", "name": "Dillberg", "lat": 49.3239, "lon": 11.3831, "site_m": 595, "ant_m": 194, "tii": {"11D": "0513", "5C": "2221", "10C": "0702"}},
    {"id": "hersbruck", "name": "Hersbruck", "lat": 49.5181, "lon": 11.4600, "site_m": 499, "ant_m": 43, "tii": {"11D": "0501", "10C": "0703"}},
    {"id": "ochsenkopf", "name": "Ochsenkopf (Fichtelgebirge)", "lat": 50.0306, "lon": 11.8083, "site_m": 1013, "ant_m": 169, "tii": {"11D": "0801", "5C": "1206"}},
    {"id": "bamberg-geisberg", "name": "Bamberg (Geisberg)", "lat": 49.8660, "lon": 10.8440, "site_m": 585, "ant_m": 104, "tii": {"11D": "0818", "5C": "1211"}},
    {"id": "buettelberg", "name": "Büttelberg (Frankenhöhe)", "lat": 49.4070, "lon": 10.4030, "site_m": 527, "ant_m": 159, "tii": {"11D": "0515", "5C": "1212"}},
    {"id": "hesselberg", "name": "Hesselberg (Wassertrüdingen)", "lat": 49.0692, "lon": 10.5303, "site_m": 678, "ant_m": 76, "tii": {"11D": "0511"}},
    {"id": "amberg-rotbuehl", "name": "Amberg (Rotbühl)", "lat": 49.5088, "lon": 12.0048, "site_m": 666, "ant_m": 95, "tii": {"11D": "0702", "5C": "1216"}},
    {"id": "hohe-linie", "name": "Hohe Linie (Regensburg)", "lat": 49.0397, "lon": 12.1716, "site_m": 474, "ant_m": 140, "tii": {"11D": "0712", "5C": "1205"}},
]
T4_ROAD_RE = re.compile(r"(stra(ß|ss)e\w*\s*gesperrt|stra(ß|ss)ensperr\w*|vollsperr\w*|gesperrt|sperrung\w*|umleitung)", re.I)
T4_COLORS = {"alarm": "#ef4444", "offline": "#f97316", "pre": "#f97316", "probe": "#eab308", "ok": "#22c55e"}
T4_F_LOW, T4_F_HIGH = 49.800, 50.200          # Vor-Alarm Netzfrequenz ausserhalb
T4_F_OK_LOW, T4_F_OK_HIGH = 49.950, 50.050    # stabil fuer Freigabe
T4_F_STABLE_S = 300
T4_F_GAP_S = 60                                # groessere Luecke zwischen Messungen = nicht nachgewiesen stabil
T4_F_CONFIRM_S = 3
T4_DSL_MAX_AGE_S = 1800                        # Wechsel Telekom -> Starlink zaehlt nur, wenn hoechstens 30 min alt
T4_HB_MAX = 160


def t4_horizon_km(h_mast, h_rx=T4_HOME["h_m"]):
    return round(T4_K * (math.sqrt(max(0.0, float(h_rx))) + math.sqrt(max(0.0, float(h_mast)))), 1)


def t4_dist_km(lat1, lon1, lat2, lon2):
    r = 6371.0088
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return round(2 * r * math.asin(min(1.0, math.sqrt(a))), 1)


def _t4_fmt_t(t):
    try:
        return time.strftime("%d.%m. %H:%M", time.localtime(int(t)))
    except Exception:
        return "?"


def t4_level(live_status=None, alarms=None, pre=None, br=None, live_reason=None):
    """Lage-Ampel Teil 4 -> {"lvl", "label", "color", "blink", "why", "notes"}.
    rot blinkend = echter Alarm (alarm_identifier 2); orange blinkend = SDR_OFFLINE oder Vor-Alarm Netzfrequenz; orange = Vor-Alarm DSL;
    gelb = PROBEALARM nur wenn ein ASA-Text ausdruecklich Probe/Test sagt (eigene TEST-Meldungen nie); gruen sonst. PTY 30 = Test (zaehlt nicht)."""
    al = [a for a in alarms or [] if isinstance(a, dict)]
    pre = pre if isinstance(pre, dict) else {}
    notes = []
    for a in al:
        txt, kind = str(a.get("text") or ""), str(a.get("kind") or "")
        if "PTY 30" in kind or "PTY 30" in txt:
            notes.append("BR24 RDS PTY 30 = Alarmtest (zählt nicht)")
        elif is_own_test(txt):
            notes.append("eigene TEST-Meldung (zählt nie)")
    notes = sorted(set(notes))
    real = [a for a in al if a.get("real") and not a.get("test")]
    kinds = [k for k in ("NETZ", "DSL") if k in (pre.get("kinds") or [])] if pre.get("on") else []
    pre_why = str(pre.get("why") or "")
    if real:
        a = sorted(real, key=lambda x: 0 if x.get("src") == "ASA" else 1)[0]
        out = {"lvl": "alarm", "label": "ECHTALARM", "blink": True, "why": "%s: %s" % (a.get("src") or "?", str(a.get("text") or "")[:150])}
    elif live_status == "SDR_OFFLINE" or "NETZ" in kinds:
        w = []
        if live_status == "SDR_OFFLINE":
            w.append("SDR_OFFLINE: keine frische Telemetrie von prepper-sdr (Watchdog %d s)" % WATCHDOG_S)
        if kinds:
            w.append("VORALARM %s: %s" % ("+".join(kinds), pre_why))
        out = {"lvl": "offline" if live_status == "SDR_OFFLINE" else "pre", "label": "SDR_OFFLINE" if live_status == "SDR_OFFLINE" else "VORALARM NETZFREQUENZ",
               "blink": True, "why": " · ".join(w)[:200]}
    elif kinds:
        out = {"lvl": "pre", "label": "VORALARM DSL-AUSFALL", "blink": False, "why": ("VORALARM DSL: %s" % pre_why)[:200]}
    else:
        pr = [a for a in al if a.get("src") == "ASA" and a.get("test") and is_probe(a.get("text")) and not is_own_test(a.get("text"))]
        if pr:
            out = {"lvl": "probe", "label": "PROBEALARM", "blink": False, "why": "ASA DE: %s" % str(pr[0].get("text") or "")[:150]}
        else:
            out = {"lvl": "ok", "label": "OK", "blink": False, "why": "kein echter Alarm, keine ASA-Probe, SDR liefert Daten" + (", kein Vor-Alarm" if not kinds else "")}
    out["color"] = T4_COLORS[out["lvl"]]
    out["notes"] = notes
    if notes:
        out["why"] = (out["why"] + " · " + " · ".join(notes))[:240]
    return out


def _t4_dab(base):
    bs = _load(os.path.join(base, "broadcast_state.json"), {}) or {}
    return bs if isinstance(bs, dict) else {}


def _t4_tel(bs, ch, now):
    d = ((bs.get("dab") or {}).get(ch) or {}) if isinstance(bs.get("dab"), dict) else {}
    dm = d.get("demod") if isinstance(d.get("demod"), dict) else {}
    t = dm.get("t") if isinstance(dm.get("t"), (int, float)) else None
    rx = d.get("rx")
    sync_t = d.get("t") if isinstance(d.get("t"), (int, float)) else None
    return {"ch": ch, "f_mhz": T4_CH.get(ch, {}).get("f_mhz"), "rssi": _num(dm.get("rssi")), "snr": _num(dm.get("snr")), "fic_rate": _num(dm.get("fic_rate")),
            "t": int(t) if t else None, "age_s": (int(now - t) if t else None), "sync": bool(rx is not False and sync_t and now - sync_t <= T4_RX_MAX_S),
            "sync_t": int(sync_t) if sync_t else None, "ens": str(d.get("ensemble") or "")[:40] or None, "why": d.get("rx_why")}


def t4_sdr(base, now=None):
    """SDR-Status-Kachel: SDR 1 fest REGIONAL-EBENE 11D, SDR 2 FREI/BEREITSCHAFT oder bei Kaperung BUNDES-EBENE 5C / LOCAL-EBENE FALLBACK 10C."""
    now = int(now or time.time())
    bs = _t4_dab(base)
    to = takeover_load(base)
    t4 = bs.get("t4") if isinstance(bs.get("t4"), dict) else {}
    s2x = t4.get("s2") if isinstance(t4.get("s2"), dict) else {}
    roles = ((bs.get("t2") or {}).get("roles") or {}) if isinstance(bs.get("t2"), dict) else {}
    s1 = dict(T4_CH["11D"], **_t4_tel(bs, "11D", now))
    s1.update(state="REGIONAL-EBENE (Kanal 11D – BR Bayern)", sn=(roles.get("s1") or {}).get("sn"), mode=(roles.get("s1") or {}).get("mode"))
    if to.get("on"):
        fb = bool(s2x.get("fb"))
        ch = "10C" if fb else "5C"
        s2 = dict(T4_CH[ch], **_t4_tel(bs, ch, now))
        s2.update(state="LOCAL-EBENE FALLBACK (Kanal 10C)" if fb else "BUNDES-EBENE (Kanal 5C)", takeover=True, src=to.get("src"), since=to.get("since"),
                  why=to.get("why"), fb=fb, fail=s2x.get("fail"), fb_since=s2x.get("since"), last5c=s2x.get("last5c"), retry_s=s2x.get("retry_s"))
    else:
        s2 = {"state": "FREI / BEREITSCHAFT", "takeover": False, "ch": None, "f_mhz": None, "fb": False, "mode": (roles.get("s2") or {}).get("mode")}
    s2["sn"] = (roles.get("s2") or {}).get("sn")
    return {"s1": s1, "s2": s2, "ber_note": "BER: welle-cli liefert keine Bitfehlerrate - angezeigt wird die FIC-Fehlerrate (fic_rate) als Ersatz",
            "rssi_note": "RSSI nur, wenn prepper-sdr einen Pegel liefert (sonst –)"}


def t4_history(path=None, n=10):
    """Letzte n Ereignisse aus lagezentrum.db als farbcodierte Einzeiler (ohne eigene Tests)."""
    out = []
    try:
        for e in db.recent_events(n, path) if db is not None else []:
            sev, src, typ = str(e.get("severity") or ""), str(e.get("source") or ""), str(e.get("type") or "")
            if src == "VORALARM":
                c = "#f97316"
            elif sev in ("warn", "alarm"):
                c = "#ef4444"
            elif sev == "probe":
                c = "#eab308"
            elif src == "DAB" or typ in ("tii", "fig09", "label"):
                c = "#60a5fa"
            else:
                c = "#94a3b8"
            t = e.get("updated") or e.get("created")
            out.append({"t": t, "src": src, "sev": sev, "color": c, "line": ("%s %s · %s" % (_t4_fmt_t(t), src, " ".join(str(e.get("headline") or e.get("text") or "").split())))[:180]})
    except Exception as ex:
        print("sdr_manager Teil 4 Historie:", ex, flush=True)
    return out


def _t4_tii_set(fig, ch, now):
    x = fig.get(ch) if isinstance(fig, dict) and isinstance(fig.get(ch), dict) else {}
    if not isinstance(x.get("t"), (int, float)) or now - x["t"] > T4_RX_MAX_S:
        return None, x
    s = set()
    for y in x.get("tii") or []:
        try:
            s.add("%02d%02d" % (int(y.get("main")), int(y.get("sub"))))
        except Exception:
            pass
    return s, x


def _t4_q(rssi, snr):
    if rssi is not None:
        return max(0.0, min(1.0, (rssi + 100.0) / 60.0)), "RSSI"
    if snr is not None:
        return max(0.0, min(1.0, snr / 25.0)), "SNR"
    return 0.3, None


def t4_map(base, path=None, now=None):
    """Kartendaten /karte: Empfaenger, Masten mit Funkhorizont D, Empfang (TII genau, sonst Kanal = unsicher), Ueberreichweite, Gefahrenzonen/Strassensperren."""
    now = int(now or time.time())
    path = path or os.path.join(base, "lagezentrum.db")
    bs = _t4_dab(base)
    fig = ((bs.get("t2") or {}).get("fig") or {}) if isinstance(bs.get("t2"), dict) else {}
    tel = {ch: _t4_tel(bs, ch, now) for ch in T4_CH}
    masts = []
    for m in T4_MASTS:
        h = m["site_m"] + m["ant_m"]
        dist = t4_dist_km(T4_HOME["lat"], T4_HOME["lon"], m["lat"], m["lon"])
        D = t4_horizon_km(h)
        chs = []
        for ch, code in m["tii"].items():
            s, _x = _t4_tii_set(fig, ch, now)
            te = tel.get(ch) or {}
            how = None
            if s is not None and code in s:
                how = "tii"
            elif te.get("sync") and not s:
                how = "kanal"
            q, qsrc = _t4_q(te.get("rssi"), te.get("snr"))
            chs.append({"ch": ch, "tii": code, "rx": how, "rssi": te.get("rssi"), "snr": te.get("snr"), "ber": te.get("fic_rate"), "q": round(q, 2), "q_src": qsrc,
                        "t": te.get("t")})
        rx = [c for c in chs if c["rx"] == "tii"]
        unsure = [c for c in chs if c["rx"] == "kanal"]
        best = max(rx or unsure, key=lambda c: c["q"]) if (rx or unsure) else None
        masts.append({"id": m["id"], "name": m["name"], "lat": m["lat"], "lon": m["lon"], "h_m": h, "site_m": m["site_m"], "ant_m": m["ant_m"],
                      "dist_km": dist, "D_km": D, "rx": "tii" if rx else ("kanal" if unsure else None), "channels": chs,
                      "q": best["q"] if best else 0.0, "q_src": best["q_src"] if best else None, "overreach": bool(rx) and dist > D})
    zones, roads, nogeo = [], [], []
    try:
        for f in map_geojson(base, path, now).get("features") or []:
            pr = f.get("properties") or {}
            if pr.get("kind") != "hazard":
                continue
            txt = str(pr.get("headline") or "")
            g = f.get("geometry") or {}
            item = {"source": pr.get("source"), "severity": pr.get("severity"), "headline": txt[:160], "geometry": g, "radius_m": pr.get("radius_m"),
                    "approx": bool(pr.get("approx")), "area": pr.get("area")}
            (roads if T4_ROAD_RE.search(txt) else zones).append(item)
        for e in (db.active_events(now, path) if db is not None else []):
            if e.get("source") in ("ASA", "BR24") and e.get("severity") in ("warn", "alarm") and not e.get("geojson") and e.get("lat") is None:
                nogeo.append({"source": e.get("source"), "headline": str(e.get("headline") or "")[:160], "road": bool(T4_ROAD_RE.search(str(e.get("text") or e.get("headline") or "")))})
    except Exception as ex:
        print("sdr_manager Teil 4 Karte:", ex, flush=True)
    return {"home": T4_HOME, "k": T4_K, "formula": "D = 4,12 × (√%.1f + √h_Mast) km, Höhen in m über NN" % T4_HOME["h_m"], "masts": masts, "zones": zones,
            "roads": roads, "nogeo": nogeo[:10], "src": T4_MAST_SRC, "t": now,
            "note": "Empfang je Mast über TII (genau); ohne TII nur Kanal-Sync (Zuordnung unsicher, gestrichelt). Linienstärke nach RSSI, ohne RSSI nach SNR."}


def t4_freq_eval(samples, now=None):
    """samples [(t, hz)] -> {"last", "out", "stable", "stable_s", "why"}; stabil = >= 300 s lang alle Werte 49,950-50,050 Hz, keine Luecke > 60 s."""
    now = float(now or time.time())
    sm = sorted((float(t), float(v)) for t, v in samples or [] if isinstance(t, (int, float)) and isinstance(v, (int, float)))
    out = {"last": sm[-1][1] if sm else None, "last_t": sm[-1][0] if sm else None, "out": False, "stable": False, "stable_s": 0, "why": "keine Messwerte"}
    if not sm:
        return out
    lt, lv = sm[-1]
    out["out"] = lv < T4_F_LOW or lv > T4_F_HIGH
    if now - lt > T4_F_GAP_S:
        out["why"] = "letzte Messung vor %d s" % (now - lt)
        return out
    start, prev = lt, lt
    for t, v in reversed(sm):
        if not (T4_F_OK_LOW <= v <= T4_F_OK_HIGH) or prev - t > T4_F_GAP_S:
            break
        start, prev = t, t
    run = int(lt - start) if T4_F_OK_LOW <= lv <= T4_F_OK_HIGH else 0
    out["stable_s"] = run
    out["stable"] = run >= T4_F_STABLE_S
    out["why"] = "stabil seit %d s (Soll %d s im Band %.3f-%.3f Hz)" % (run, T4_F_STABLE_S, T4_F_OK_LOW, T4_F_OK_HIGH)
    return out


def t4_freq_trigger(samples):
    """Vor-Alarm Netzfrequenz: die letzten Messungen ausserhalb 49,800-50,200 Hz ueber > 3 s (mind. 2 Messungen, erste bis letzte > 3 s). -> (bool, dauer_s, wert)"""
    sm = sorted((float(t), float(v)) for t, v in samples or [] if isinstance(t, (int, float)) and isinstance(v, (int, float)))
    run = []
    for t, v in reversed(sm):
        if v < T4_F_LOW or v > T4_F_HIGH:
            run.append((t, v))
        else:
            break
    if len(run) < 2:
        return False, 0, run[0][1] if run else None
    dur = run[0][0] - run[-1][0]
    return dur > T4_F_CONFIRM_S, int(dur), run[0][1]


def t4_dsl_edge(us, handled_t, now=None):
    """Uplink-Wechsel Telekom -> Starlink (uplink_detect.public_state) neuer als handled_t und hoechstens 30 min alt -> Eintrag | None"""
    now = float(now or time.time())
    if not isinstance(us, dict) or us.get("current") != "starlink":
        return None
    for h in reversed([x for x in us.get("history") or [] if isinstance(x, dict)]):
        t = h.get("t")
        if not isinstance(t, (int, float)):
            continue
        if h.get("to") == "starlink" and h.get("from") == "telekom" and (handled_t is None or t > handled_t) and now - t <= T4_DSL_MAX_AGE_S:
            return {"t": float(t), "why": str(h.get("why") or "")[:80]}
        if h.get("to") == "starlink":
            return None
    return None


def t4_release_ok(us, freq):
    """Freigabe SDR 2 erlaubt? Internet wieder via Telekom (frisch) und Frequenz 5 min stabil 49,950-50,050 Hz. -> (bool, grund)"""
    why = []
    if not isinstance(us, dict) or us.get("current") != "telekom" or us.get("stale"):
        why.append("Internet nicht via Telekom (%s%s)" % ((us or {}).get("current") if isinstance(us, dict) else "?", ", veraltet" if isinstance(us, dict) and us.get("stale") else ""))
    if not (freq or {}).get("stable"):
        why.append("Netzfrequenz nicht 5 min stabil (%s)" % (freq or {}).get("why"))
    return (not why), ("; ".join(why) if why else "Telekom + Frequenz 5 min stabil")


def t4_heartbeat_text(now, level, asa_status, wx, uplink, hz, s2state=None):
    """3-h-Heartbeat Mesh 1: Einzeiler <= 160 Zeichen (Lage, ASA-Dienst, SDR 2, Wetter, Uplink, Netzfrequenz)."""
    parts = ["HB %s" % time.strftime("%H:%M", time.localtime(now)), "Lage %s" % (level or "?"), "ASA %s" % str(asa_status or "?").replace("ASA_", "")]
    if s2state:
        parts.append("SDR2 %s" % s2state)
    try:
        w = wx if isinstance(wx, dict) else {}
        d0 = (w.get("days") or [{}])[0] if isinstance(w.get("days"), list) and w.get("days") else {}
        t = w.get("temp")
        ws = ("%d°C" % round(t)) if isinstance(t, (int, float)) else "–"
        if isinstance(d0.get("min"), (int, float)) and isinstance(d0.get("max"), (int, float)):
            ws += " %d/%d°" % (round(d0["min"]), round(d0["max"]))
        if w.get("icon"):
            ws += " " + str(w["icon"])[:2]
        if isinstance(w.get("sunshine"), (int, float)):
            ws += " Sonne %.1fh" % w["sunshine"]
        parts.append("Wetter " + ws)
    except Exception:
        parts.append("Wetter –")
    parts.append("Netz %s" % ({"telekom": "Telekom", "starlink": "Starlink"}.get(uplink, uplink or "?")))
    if isinstance(hz, (int, float)):
        parts.append(("%.3f Hz" % hz).replace(".", ","))
    s = " | ".join(parts)
    while len(s) > T4_HB_MAX and len(parts) > 3:
        parts.pop(3 if len(parts) > 4 else -1)
        s = " | ".join(parts)
    return s[:T4_HB_MAX]


def selftest_t4():
    import tempfile
    d = tempfile.mkdtemp()
    p = os.path.join(d, "lagezentrum.db")
    now = 1790000000
    assert abs(t4_horizon_km(578) - round(4.12 * (math.sqrt(431.7) + math.sqrt(578)), 1)) < 1e-9 and t4_horizon_km(578) == 184.7, t4_horizon_km(578)
    assert t4_dist_km(49.55782283, 11.15501383, 49.4283, 11.0403) == 16.6, t4_dist_km(49.55782283, 11.15501383, 49.4283, 11.0403)
    real = [{"src": "ASA", "text": "Gefahr: Fenster schließen", "real": True, "test": False}]
    probe = [{"src": "ASA", "text": "Probewarnung der Warnsysteme", "real": False, "test": True}]
    own = [{"src": "ASA", "text": "TEST ASA DE (DAB 5C) · keine echte Warnung · x", "real": False, "test": True}]
    pty30 = [{"src": "BR24", "text": "PTY 30 Alarmtest", "kind": "BR24 UKW RDS PTY 30 Alarmtest", "real": False, "test": True}]
    nina_probe = [{"src": "NINA", "text": "Probealarm Sirenen", "real": False, "test": True}]
    assert t4_level("OK", real)["lvl"] == "alarm" and t4_level("OK", real)["blink"] and t4_level("SDR_OFFLINE", real)["lvl"] == "alarm"
    assert t4_level("OK", probe)["lvl"] == "probe" and t4_level("OK", own)["lvl"] == "ok" and t4_level("OK", nina_probe)["lvl"] == "ok"
    l30 = t4_level("OK", pty30)
    assert l30["lvl"] == "ok" and "PTY 30" in l30["why"], l30
    assert t4_level("SDR_OFFLINE", probe)["lvl"] == "offline" and t4_level("SDR_OFFLINE", [])["blink"]
    pd = {"on": True, "kinds": ["DSL"], "why": "Telekom -> Starlink"}
    pn = {"on": True, "kinds": ["NETZ"], "why": "49,712 Hz"}
    assert t4_level("OK", [], pd)["lvl"] == "pre" and not t4_level("OK", [], pd)["blink"] and t4_level("OK", [], pn)["blink"] and t4_level("OK", probe, pd)["lvl"] == "pre"
    assert t4_level("OK", [])["lvl"] == "ok" and t4_level("OK", [])["color"] == "#22c55e" and t4_level("OK", [])["why"]
    # Netzfrequenz
    s = [(now - 400 + 25 * i, 50.0) for i in range(17)]
    assert t4_freq_eval(s, now)["stable"] and t4_freq_eval(s[-10:], now)["stable"] is False
    s2 = s[:8] + [(now - 200, 49.94)] + s[9:]
    assert t4_freq_eval(s2, now)["stable"] is False and t4_freq_eval(s[:-6] + s[-3:], now)["stable"] is False      # Ausreisser / Luecke > 60 s
    assert t4_freq_trigger([(now - 30, 50.0), (now - 5, 49.75), (now - 1, 49.71)]) == (True, 4, 49.71)
    assert t4_freq_trigger([(now - 5, 49.75), (now - 3, 49.0)])[0] is False and t4_freq_trigger([(now - 9, 49.75), (now - 1, 50.0)])[0] is False
    assert t4_freq_trigger([(now - 9, 50.25), (now - 1, 50.3)])[0] is True
    # DSL
    us = {"current": "starlink", "history": [{"t": now - 4000, "from": "unclear", "to": "telekom"}, {"t": now - 60, "from": "telekom", "to": "starlink", "why": "Schuessel"}]}
    assert t4_dsl_edge(us, None, now)["t"] == now - 60 and t4_dsl_edge(us, now - 60, now) is None and t4_dsl_edge(us, None, now + 2000) is None
    assert t4_dsl_edge(dict(us, current="telekom"), None, now) is None
    assert t4_dsl_edge({"current": "starlink", "history": [{"t": now - 60, "from": "unclear", "to": "starlink"}]}, None, now) is None
    ok, why = t4_release_ok({"current": "telekom", "stale": False}, t4_freq_eval(s, now))
    assert ok and t4_release_ok({"current": "starlink"}, t4_freq_eval(s, now))[0] is False and t4_release_ok({"current": "telekom"}, t4_freq_eval(s2, now))[0] is False
    hb = t4_heartbeat_text(now, "OK", "ASA_OK", {"temp": 12.4, "icon": "☀️", "sunshine": 6.5, "days": [{"min": 4.2, "max": 14.6}]}, "telekom", 50.012, "frei")
    assert len(hb) <= 160 and "Lage OK" in hb and "ASA OK" in hb and "12°C" in hb and "50,012 Hz" in hb and "Telekom" in hb, hb
    assert len(t4_heartbeat_text(now, "X" * 200, "A" * 100, {}, "telekom", 50.0)) <= 160
    # Karte + SDR-Kachel + Historie
    with open(os.path.join(d, "broadcast_state.json"), "w") as f:
        json.dump({"dab": {"11D": {"ensemble": "Bayern", "rx": True, "t": now - 30, "demod": {"t": now - 30, "snr": 18.0, "fic_rate": 0.001, "rssi": None}},
                           "5C": {"rx": True, "t": now - 40, "demod": {"t": now - 40, "snr": 9.0, "fic_rate": 0.01}},
                           "10C": {"rx": False, "demod": {"t": now - 50, "snr": 0.0}}},
                   "t2": {"roles": {"s1": {"sn": "19348831", "mode": "11D fest"}, "s2": {"sn": "72055505", "mode": "ALARM 5C (ASA DE)"}},
                          "fig": {"11D": {"t": now - 30, "tii": [{"main": 5, "sub": 14}, {"main": 8, "sub": 1}]}, "5C": {"t": now - 40, "tii": []}}},
                   "t4": {"s2": {"fb": True, "fail": 2, "since": now - 100, "last5c": now - 100, "retry_s": 600}}}, f)
    db.migrate(p)
    db.upsert_event({"source": "NINA", "ext_id": "z1", "severity": "warn", "headline": "Gefahrstoffaustritt", "lat": 49.45, "lon": 11.07,
                     "geojson": json.dumps({"type": "Feature", "geometry": {"type": "Point", "coordinates": [11.07, 49.45]}, "properties": {"radius_m": 9000}}),
                     "updated": now, "expires": now + 3600}, p)
    db.upsert_event({"source": "NINA", "ext_id": "z2", "severity": "warn", "headline": "Vollsperrung A3 nach Unfall", "lat": 49.6, "lon": 11.0, "updated": now, "expires": now + 3600}, p)
    db.upsert_event({"source": "ASA", "ext_id": "z3", "severity": "warn", "headline": "ASA DE: Gefahr", "text": "Gefahr", "updated": now, "expires": now + 3600}, p)
    db.upsert_event({"source": "VORALARM", "ext_id": "z4", "severity": "warn", "headline": "VORALARM DSL", "updated": now - 5, "expires": now + 3600}, p)
    m = t4_map(d, p, now)
    by = {x["id"]: x for x in m["masts"]}
    assert by["nbg-schweinau"]["rx"] == "tii" and by["ochsenkopf"]["rx"] == "tii" and by["dillberg"]["rx"] == "kanal" and by["hersbruck"]["rx"] is None, by
    assert by["ochsenkopf"]["dist_km"] < by["ochsenkopf"]["D_km"] and not by["ochsenkopf"]["overreach"] and by["nbg-schweinau"]["q_src"] == "SNR"
    assert by["hesselberg"]["rx"] is None and [c for c in by["dillberg"]["channels"] if c["ch"] == "5C"][0]["rx"] == "kanal"       # 5C ohne TII = unsicher
    T4_MASTS.append({"id": "fern", "name": "Testmast fern", "lat": 52.5, "lon": 13.4, "site_m": 50, "ant_m": 50, "tii": {"11D": "0801"}})
    try:
        f2 = [x for x in t4_map(d, p, now)["masts"] if x["id"] == "fern"][0]
        assert f2["overreach"] and f2["dist_km"] > f2["D_km"], f2
    finally:
        T4_MASTS.pop()
    assert [z["headline"] for z in m["zones"]] == ["Gefahrstoffaustritt"] and [r["headline"] for r in m["roads"]] == ["Vollsperrung A3 nach Unfall"], (m["zones"], m["roads"])
    assert m["nogeo"] and m["nogeo"][0]["source"] == "ASA" and m["zones"][0]["radius_m"] == 9000
    sd = t4_sdr(d, now)
    assert sd["s1"]["state"].startswith("REGIONAL-EBENE (Kanal 11D") and sd["s1"]["f_mhz"] == 222.064 and sd["s2"]["state"] == "FREI / BEREITSCHAFT", sd
    takeover_set(d, True, "DSL", "Vor-Alarm", "teil4", now)
    sd = t4_sdr(d, now)
    assert sd["s2"]["state"] == "LOCAL-EBENE FALLBACK (Kanal 10C)" and sd["s2"]["f_mhz"] == 213.36 and sd["s2"]["src"] == "DSL", sd["s2"]
    bs = _load(os.path.join(d, "broadcast_state.json"), {})
    bs["t4"]["s2"]["fb"] = False
    _write_json(os.path.join(d, "broadcast_state.json"), bs)
    assert t4_sdr(d, now)["s2"]["state"] == "BUNDES-EBENE (Kanal 5C)" and t4_sdr(d, now)["s2"]["snr"] == 9.0
    h = t4_history(p)
    assert len(h) == 4 and all(x["line"] and x["color"] for x in h) and {x["color"] for x in h} >= {"#ef4444", "#f97316"}, h
    return "sdr_manager selftest Teil 4 ok (Ampel rot/orange/gelb/gruen, Probe nur ASA ausdruecklich, eigene Tests + PTY 30 nie, Funkhorizont, TII-Empfang, Ueberreichweite, Zonen/Sperren, Frequenz >3 s + 5 min stabil, DSL-Wechsel, Heartbeat <= 160)"
T4SM_EOF
EXPECT_GUARD="71ae55bced09be192f8b46fade88528654fa983933de81da9f5f45d4ee8a884b"
cat > "$W/guard_t4.py" << 'T4GUARD_EOF'
"""Teil 4 AST-Guard. Aufruf: guard_t4.py DASH_ALT DASH_NEU SM_ALT SM_NEU SDR_ALT SDR_NEU -> 0 ok, 1 Verstoss.
dashboard.py: nur der teil4-Block neu (sonst Byte fuer Byte gleich); Prozesse nur amixer/aplay/espeak-ng ueber _t4_run/_t4_spawn ohne Shell,
os.kill nur in _t4_kill_pid; kein Netz (kein requests/urllib/socket), keine Kachel-URL (Kacheln laedt nur prepper-tiles-teil4.sh);
genau 2 Faeden (teil4, teil4-audio). sdr_manager.py: nur Teil-4-Abschnitt + Selbsttest-Aufruf, keine Netz-/Prozessmodule.
prepper_sdr.py: nur sdrTeil4-Block + genau 2 erlaubte Aenderungen, keine Prozess-/Netzaufrufe im Block."""
import ast
import sys

rd = lambda f: open(f, encoding="utf-8").read()
d0, d1, s0, s1, p0, p1 = (rd(f) for f in sys.argv[1:7])
err = []
NETMOD = {"requests", "urllib", "http", "socket", "asyncio", "socketserver", "meshtastic", "serial", "ftplib", "smtplib"}
PROC = ("system", "Popen", "run", "check_output", "check_call", "call", "execv", "execvp", "spawnv", "fork", "killpg", "kill", "popen", "getoutput", "getstatusoutput")
SEND = ("send_meshtastic", "send_meshtastic_to", "send_chunks_local", "send_chunks_bayern", "send_nina_to_bayern", "sendText", "sendData", "transport", "_txn", "_tx", "send_fn")


def cut(s, A, Z):
    a = s.index(A)
    return s[a:s.index(Z, a) + len(Z)]


def calls(tree):
    out = []
    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            f = n.func
            out.append((f.value.id if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) else "", f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else ""), n))
    return out


def shell_kw(tree):
    return sum(1 for n in ast.walk(tree) if isinstance(n, ast.keyword) and n.arg == "shell" and not (isinstance(n.value, ast.Constant) and n.value.value is False))


def imports(tree):
    return {(getattr(n, "module", None) or a.name).split(".")[0] for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names}


def strs(tree):
    return [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]


# ---- dashboard.py
A, Z = "# ===== teil4:", "# ===== /teil4 =====\n"
if d1.count(A) != 1 or d1.count(Z) != 1:
    err.append("dashboard: teil4-Marker nicht genau 1x")
else:
    b = cut(d1, A, Z)
    rest0 = d0.replace(cut(d0, A, Z), "") if A in d0 else d0
    if d1.replace(b, "") != rest0:
        err.append("dashboard: ausserhalb teil4 geaendert")
    if not d1.split(A)[0].endswith("# ===== /teil3 =====\n"):
        err.append("dashboard: teil4 steht nicht direkt nach /teil3")
    t = ast.parse(b)
    im = imports(t)
    if im - {"threading", "time", "json", "os", "re", "hashlib", "signal", "shutil", "subprocess", "tempfile", "collections", "flask", "math", "datetime"}:
        err.append("teil4: Importe %s" % sorted(im))
    if im & NETMOD:
        err.append("teil4: Netzmodul %s" % (im & NETMOD))
    if shell_kw(t) or shell_kw(ast.parse(d1)) != shell_kw(ast.parse(d0)):
        err.append("teil4: shell=")
    fns = {f.name: f for f in ast.walk(t) if isinstance(f, ast.FunctionDef)}
    sp_alias = [a.asname or a.name for n in ast.walk(t) if isinstance(n, ast.Import) for a in n.names if a.name == "subprocess"]
    os_alias = [a.asname or a.name for n in ast.walk(t) if isinstance(n, ast.Import) for a in n.names if a.name == "os"]
    where = {}
    for fn in fns.values():
        for mod, nm, c in calls(fn):
            if (mod in sp_alias and nm in PROC) or (mod in os_alias and nm in PROC):
                where.setdefault((mod, nm), set()).add(fn.name)
    expect = {(sp_alias[0], "run"): {"_t4_run"}, (sp_alias[0], "Popen"): {"_t4_spawn"}, (os_alias[0], "kill"): {"_t4_kill_pid"}} if sp_alias and os_alias else {}
    inside = {id(c) for fn in fns.values() if fn.name in ("_t4_run", "_t4_spawn", "_t4_kill_pid") for _m, _n, c in calls(fn)}
    for mod, nm, c in calls(t):
        if (mod in sp_alias + os_alias and nm in PROC) and id(c) not in inside:
            where.setdefault((mod, nm), set()).add("<ausserhalb>")
    if any(isinstance(n, ast.Attribute) and n.attr in PROC and isinstance(n.value, ast.Name) and n.value.id in sp_alias for n in ast.walk(t)) and not sp_alias:
        err.append("teil4: subprocess-Zugriff")
    if where != expect:
        err.append("teil4: Prozessaufrufe %s (erlaubt: subprocess.run nur in _t4_run, Popen nur in _t4_spawn, os.kill nur in _t4_kill_pid)" % where)
    for f in ("_t4_run", "_t4_spawn"):
        src = ast.unparse(fns[f]) if f in fns else ""
        if "T4_EXE" not in src or "[exe] + list(argv[1:])" not in src:
            err.append("teil4: %s ohne Programm-Liste T4_EXE" % f)
    g = {}
    for n in t.body:
        if isinstance(n, ast.Assign) and any(isinstance(x, ast.Name) and x.id in ("T4_EXE", "T4_KILL_COMM") for x in n.targets):
            exec(compile(ast.Module(body=[n], type_ignores=[]), "c", "exec"), g)
    if g.get("T4_EXE") != ("amixer", "aplay", "espeak-ng") or g.get("T4_KILL_COMM") != ("aplay", "espeak-ng"):
        err.append("teil4: Programm-Liste %s / Kill-Liste %s" % (g.get("T4_EXE"), g.get("T4_KILL_COMM")))
    allc = calls(t)
    for mod, nm, c in allc:
        if nm in SEND or nm in ("urlopen", "create_connection", "start_new_thread", "Timer", "rmtree", "unlink", "remove") and mod != "":
            if nm in ("remove", "unlink") and mod in os_alias:
                continue
            err.append("teil4: ruft %s.%s" % (mod, nm))
    th = [c for mod, nm, c in allc if nm == "Thread"]
    names = sorted(k.value.value for c in th for k in c.keywords if k.arg == "name" and isinstance(k.value, ast.Constant))
    if len(th) != 2 or names != ["teil4", "teil4-audio"]:
        err.append("teil4: Faeden %s (erlaubt genau teil4 + teil4-audio)" % names)
    ss = strs(t)
    if any(("geodatenzentrum" in x or "tile.openstreetmap" in x or "wmts" in x.lower() or x.startswith("http://") or x.startswith("https://")) and "/static/" not in x for x in ss
           if not x.startswith("https://www.bkg.bund.de") and not x.startswith("https://www.govdata.de")):
        bad = [x[:60] for x in ss if x.startswith("http") or "geodatenzentrum" in x]
        if bad:
            err.append("teil4: externe URLs %s (Kacheln nur lokal)" % bad)
    if "requests." in b or "urllib" in b or "urlopen" in b:
        err.append("teil4: Netzzugriff im Text")
    if "secrets" in b:
        err.append("teil4: Bezug auf secrets")
    for mod, nm, c in allc:
        if nm == "add_url_rule":
            pass
    if b.count("app.add_url_rule(") != 1 or b.count("app.after_request(") != 1:
        err.append("teil4: Routen/after_request nicht genau ueber 1 Stelle")
# ---- sdr_manager.py
M = '\n\nif __name__ == "__main__":\n    print(selftest())\n    print(selftest_t2())\n'
S4 = "\n\n# ---------------------------------------------------------------- Teil 4"


def sm_strip(x):
    if S4 not in x:
        return x
    return x[:x.index(S4)] + x[x.rindex(M):].replace("    print(selftest_t4())\n", "")


if s1.count(S4) != 1 or not s1.endswith(M + "    print(selftest_t4())\n"):
    err.append("sdr_manager: Teil-4-Abschnitt/Selbsttest-Aufruf nicht genau 1x")
elif sm_strip(s1) != sm_strip(s0):
    err.append("sdr_manager: Teil-1/2/3-Code geaendert")
else:
    sec = ast.parse(s1[s1.index(S4):s1.rindex(M)])
    if imports(sec) - {"math", "tempfile", "os", "json", "time", "re"}:
        err.append("sdr_manager: Teil 4 importiert %s" % imports(sec))
    if imports(ast.parse(s1)) != imports(ast.parse(s0)) | imports(sec):
        err.append("sdr_manager: Importe geaendert")
    if imports(ast.parse(s1)) & (NETMOD | {"subprocess"}) != imports(ast.parse(s0)) & (NETMOD | {"subprocess"}):
        err.append("sdr_manager: neues Netz-/Prozessmodul")
    if shell_kw(sec) or any(nm in PROC + SEND + ("urlopen", "Thread") for _, nm, _c in calls(sec) if nm not in ("run",)) or any(nm == "run" for m, nm, _c in calls(sec)):
        err.append("sdr_manager: Teil 4 ruft Prozess/Netz/Faden")
# ---- prepper_sdr.py
A4, Z4 = "# ===== sdrTeil4:", "# ===== /sdrTeil4 =====\n"
EDITS = (('    assert all(MASTS_DB[k]["src"] for k in MASTS_DB) and "kein Empfang" in MASTS_DB["10C"]["rx"]\n',
          '    assert all(MASTS_DB[k]["src"] for k in MASTS_DB) and MASTS_DB["10C"]["rx"]   # Teil 4: 10C ist Rueckfall bei Kaperung\n'),
         ('        selftest_teil2()\n    elif a in ("stick-test",', '        selftest_teil2()\n        selftest_teil4()\n    elif a in ("stick-test",'))
if p1.count(A4) != 1 or p1.count(Z4) != 1:
    err.append("prepper_sdr: sdrTeil4-Marker nicht genau 1x")
else:
    blk = cut(p1, A4, Z4)
    r1 = p1.replace(blk, "")
    r0 = p0.replace(cut(p0, A4, Z4), "") if A4 in p0 else p0
    for old, new in EDITS:
        if r1.count(new) != 1:
            err.append("prepper_sdr: erlaubte Aenderung fehlt: %s" % new.strip()[:50])
        r1 = r1.replace(new, old)
        r0 = r0.replace(new, old)
    if r1 != r0:
        err.append("prepper_sdr: ausserhalb sdrTeil4 anders geaendert als erlaubt")
    if not p1.split(A4)[0].endswith("# ===== /sdrTeil2 =====\n"):
        err.append("prepper_sdr: sdrTeil4 steht nicht direkt nach /sdrTeil2")
    bt = ast.parse(blk)
    if imports(bt) - {"tempfile", "os", "json", "time"} or shell_kw(bt) or shell_kw(ast.parse(p1)) != shell_kw(ast.parse(p0)):
        err.append("prepper_sdr: sdrTeil4 Importe/shell %s" % imports(bt))
    if any(nm in PROC + ("urlopen", "Thread", "create_connection") for _, nm, _c in calls(bt)):
        err.append("prepper_sdr: sdrTeil4 ruft Prozess/Netz/Faden %s" % [nm for _, nm, _c in calls(bt) if nm in PROC + ("urlopen", "Thread")])
if err:
    print("\n".join(err))
    raise SystemExit(1)
print("OK AST-Guard Teil 4: dashboard.py nur teil4-Block; Prozesse nur amixer/aplay/espeak-ng (ohne Shell, _t4_run/_t4_spawn), kill nur _t4_kill_pid; "
      "kein Netz/keine Kachel-URL im Dashboard; Faeden teil4 + teil4-audio; sdr_manager nur Teil-4-Abschnitt; prepper_sdr nur sdrTeil4 + 2 erlaubte Selbsttest-Aenderungen")
T4GUARD_EOF
EXPECT_SHOW="0ec7d4cd69b2243289a387c6de46c19f379e8ccd82cbd37d333126f903b6663a"
cat > "$W/show_t4.py" << 'T4SHOW_EOF'
"""Teil 4 Anzeige (nur lesen). show_t4.py status|check DATEI(/api/t4/status als JSON)"""
import json
import sys
import time


def fmt(t):
    try:
        return time.strftime("%d.%m. %H:%M:%S", time.localtime(int(t))) if t else "-"
    except Exception:
        return "-"


mode, f = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(f, encoding="utf-8"))
except Exception as e:
    print("  /api/t4/status nicht lesbar:", str(e)[:80])
    raise SystemExit(1)
if not isinstance(d, dict):
    raise SystemExit(1)
lv = d.get("level") or {}
sd = d.get("sdr") or {}
if mode == "check":
    ok = d.get("ok") is True and lv.get("lvl") in ("ok", "probe", "alarm", "offline", "pre", "pre_dsl") and isinstance(sd.get("s1"), dict) \
        and isinstance(sd.get("s2"), dict) and isinstance(d.get("hist"), list) and isinstance(d.get("release"), dict) and isinstance(d.get("pre"), dict)
    raise SystemExit(0 if ok else 1)
print("  Ampel: %s%s - %s" % (lv.get("label"), " (blinkend)" if lv.get("blink") else "", str(lv.get("why") or "")[:140]))
for n in lv.get("notes") or []:
    print("    Hinweis: %s" % str(n)[:140])
s1, s2 = sd.get("s1") or {}, sd.get("s2") or {}
print("  SDR 1: %s, %s MHz, SNR %s dB, FIC-Fehlerrate %s" % (s1.get("state"), s1.get("f_mhz"), s1.get("snr"), s1.get("fic_rate")))
print("  SDR 2: %s%s" % (s2.get("state"), (" seit " + fmt(s2.get("since")) + " (" + str(s2.get("src")) + ")") if s2.get("takeover") else ""))
p = d.get("pre") or {}
print("  Vor-Alarm: %s" % (("AN " + "+".join(p.get("kinds") or []) + " seit " + fmt(p.get("since")) + " - " + str(p.get("why") or "")[:90]) if p.get("on") else "aus"))
r = d.get("release") or {}
fr = r.get("freq") or {}
print("  Freigabe SDR 2: %s - %s; Netzfrequenz %s Hz (stabil %s s)" % ("moeglich" if r.get("ok") else "nein", str(r.get("why") or "")[:90], fr.get("last"), fr.get("stable_s")))
a = d.get("audio") or {}
tl = a.get("tools") or {}
print("  Audio: %s; Sirene %s; Soundkarte %s; schon vorgelesen %s Texte" % (", ".join("%s %s" % (k, "da" if v else "FEHLT") for k, v in tl.items()),
                                                                          "da" if a.get("sirene") else "FEHLT", a.get("card") or "noch nicht gesucht", a.get("spoken_n")))
h = d.get("hb") or {}
print("  Heartbeat Mesh 1: geplant %s, zuletzt %s (nur bei Auto-Versand AN)" % (fmt(h.get("due")), fmt(h.get("last"))))
hi = d.get("hist") or []
print("  Ereignis-Historie (%d):" % len(hi))
for x in hi[:5]:
    print("    " + str(x.get("line") or "")[:150])
T4SHOW_EOF
EXPECT_LJS="db49d009c841f5ca34a888c96511ae936fd9f5533e90d8b2c4d57596f4e5641a"
cat > "$W/leaflet/leaflet.js.b64" << 'T4L_EOF'
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
l8D7nP/86lkqxdnBH3hztfy/Gp3woGBAAgA=
T4L_EOF
EXPECT_LCSS="337bfca5cabd03b39815b2700febe2b3b7edf55921c59cd49f88ecb328212303"
cat > "$W/leaflet/leaflet.css.b64" << 'T4L_EOF'
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
srMDBDQQ8M3Jh0dcwf8AHXZJpUE3AAA=
T4L_EOF
PD="$W/patch-t4-dash.py"; PS_="$W/patch-t4-sdr.py"; PM="$W/patch-t4-sm.py"; B4="$W/t4_dash_block.py"; BS4="$W/sdr_t4_block.py"; SM4="$W/sm_t4.py"
SG="$W/guard_t4.py"; SH="$W/show_t4.py"
for x in "$EXPECT_PD $PD" "$EXPECT_PS $PS_" "$EXPECT_PM $PM" "$EXPECT_B4 $B4" "$EXPECT_BS4 $BS4" "$EXPECT_SM4 $SM4" "$EXPECT_GUARD $SG" "$EXPECT_SHOW $SH"; do
  set -- $x; echo "$1  $2" | sha256sum -c - >/dev/null || { echo "STOP: sha256 falsch: $2"; exit 1; }
done
for x in leaflet.js leaflet.css; do base64 -d "$W/leaflet/$x.b64" | gzip -dc > "$W/leaflet/$x"; done
echo "$EXPECT_LJS  $W/leaflet/leaflet.js" | sha256sum -c - >/dev/null && echo "$EXPECT_LCSS  $W/leaflet/leaflet.css" | sha256sum -c - >/dev/null \
  || { echo "STOP: sha256 Leaflet falsch"; exit 1; }
# ---------- 1) Basis (sha16 bekannt oder Guards erkannt; Teil 3 muss drin sein) ----------
for x in "$F" "$M" "$SMF" "$DASH_DIR/database.py" "$DASH_DIR/mesh_router.py"; do [[ -f "$x" ]] || { echo "STOP: $(basename "$x") fehlt - nichts geaendert"; exit 1; }; done
D16=$(sha256sum "$F" | cut -c1-16); S16=$(sha256sum "$M" | cut -c1-16); SM16=$(sha256sum "$SMF" | cut -c1-16)
kn() { [[ "$1" == "$2" ]] && echo bekannt || echo "neu, Erkennung ueber Guards"; }
echo "Basis dashboard.py sha16 $D16 ($(wc -l < "$F") Zeilen, $(kn "$D16" "$KNOWN_DASH16")); prepper_sdr.py sha16 $S16 ($(wc -l < "$M") Zeilen, $(kn "$S16" "$KNOWN_SDR16")); sdr_manager.py sha16 $SM16 ($(wc -l < "$SMF") Zeilen, $(kn "$SM16" "$KNOWN_SM16"))"
grep -q '# ===== /teil3 =====' "$F" || { echo "STOP: Teil 3 fehlt noch - bitte zuerst apply-teil3.sh einspielen, nichts geaendert"; exit 1; }
grep -q '# ===== /sdrTeil2 =====' "$M" || { echo "STOP: Teil 2 fehlt in prepper_sdr.py - nichts geaendert"; exit 1; }
grep -q '# ---------------------------------------------------------------- Teil 3' "$DASH_DIR/mesh_router.py" || { echo "STOP: mesh_router.py ohne Teil 3 - nichts geaendert"; exit 1; }
python3 "$PD" "$F" "$W/work/dashboard.py" "$B4" > "$W/p1.log" || { cat "$W/p1.log"; echo "STOP: dashboard.py unbekannte Basis (sha16 $D16) - nichts geaendert"; exit 1; }
python3 "$PS_" "$M" "$W/work/prepper_sdr.py" "$BS4" > "$W/p2.log" || { cat "$W/p2.log"; echo "STOP: prepper_sdr.py unbekannte Basis (sha16 $S16) - nichts geaendert"; exit 1; }
python3 "$PM" "$SMF" "$W/work/sdr_manager.py" "$SM4" > "$W/p3.log" || { cat "$W/p3.log"; echo "STOP: sdr_manager.py unbekannte Basis (sha16 $SM16) - nichts geaendert"; exit 1; }
cp "$F" "$W/old/dashboard.py"; cp "$M" "$W/old/prepper_sdr.py"; cp "$SMF" "$W/old/sdr_manager.py"
echo "OK Basis erkannt: dashboard teil2/teil3 -> $(cat "$W/p1.log"); prepper_sdr sdrTeil2 -> $(cat "$W/p2.log"); sdr_manager Teil 2 -> $(cat "$W/p3.log"); database.py + mesh_router.py bleiben unveraendert"
# ---------- 1b) Zuordnung pruefen: Mesh 1 = .141 (Bridge 5001), Mesh 2 = .140 (Bridge 5002); sonst STOP ----------
python3 - "$DASH_DIR" "$EXP_M1" "$EXP_M2" > "$W/map.log" << 'MAPPY' || { cat "$W/map.log"; echo "STOP: Knoten-Zuordnung weicht ab - nichts geaendert (bitte klaeren, welcher Knoten Mesh 1/Mesh 2 ist)"; exit 1; }
import ast, re, sys
d, e1, e2 = sys.argv[1:4]
want = {"MESHTASTIC_HOST": e1, "MESH1_HOST": e1, "MESHTASTIC_HOST_BAYERN": e2, "MESH2_HOST": e2}
got = {}
for n in ast.parse(open(d + "/config.py", encoding="utf-8").read()).body:
    if isinstance(n, ast.Assign) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str):
        for t in n.targets:
            if isinstance(t, ast.Name) and t.id in want:
                got[t.id] = n.value.value
bad = ["config.py %s = %s (erwartet %s)" % (k, got.get(k, "fehlt"), v) for k, v in want.items() if got.get(k) != v]
b1 = open(d + "/mesh_bridge.py", encoding="utf-8").read()
b2 = open(d + "/mesh_bridge_bayern.py", encoding="utf-8").read()
if not re.search(r'^LISTEN = \("127\.0\.0\.1", 5001\)', b1, re.M) or "from config import MESHTASTIC_HOST" not in b1:
    bad.append("mesh_bridge.py nicht Port 5001 mit MESHTASTIC_HOST aus config.py")
if not re.search(r'^LISTEN = \("127\.0\.0\.1", 5002\)', b2, re.M) or not re.search(r'^\s*MESHTASTIC_HOST = "192\.168\.178\.140"', b2, re.M):
    bad.append("mesh_bridge_bayern.py nicht Port 5002 mit 192.168.178.140")
if bad:
    print("  " + "\n  ".join(bad)); raise SystemExit(1)
print("Mesh 1 = %s (Bridge 5001: NINA + DAB+ + Teil-4-Meldungen), Mesh 2 = %s (Bridge 5002, nur NINA)" % (e1, e2))
MAPPY
echo "OK Zuordnung: $(cat "$W/map.log")"
for u in prepper-dashboard prepper-sdr; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); [[ "$a" == active ]] || { echo "STOP: $u ist nicht aktiv ($a) - erst Dienst pruefen, nichts geaendert"; exit 1; }
done
# ---------- 2) Trockenlauf ----------
python3 "$PD" "$W/work/dashboard.py" "$W/work/x.py" "$B4" >/dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x.py" || { echo "STOP: dashboard nicht idempotent"; exit 1; }
python3 "$PS_" "$W/work/prepper_sdr.py" "$W/work/x.py" "$BS4" >/dev/null && cmp -s "$W/work/prepper_sdr.py" "$W/work/x.py" || { echo "STOP: prepper_sdr nicht idempotent"; exit 1; }
python3 "$PM" "$W/work/sdr_manager.py" "$W/work/x.py" "$SM4" >/dev/null && cmp -s "$W/work/sdr_manager.py" "$W/work/x.py" || { echo "STOP: sdr_manager nicht idempotent"; exit 1; }
rm -f "$W/work/x.py"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/work/prepper_sdr.py" "$W/work/sdr_manager.py"; do
    "$py" -W error -m py_compile "$x" || { echo "STOP: py_compile $(basename "$x") ($py) - nichts geaendert"; exit 1; }
  done
done
cp "$DASH_DIR/database.py" "$DASH_DIR/mesh_router.py" "$W/work/sdr_manager.py" "$W/msbx/"
for py in "$SPY" "$VPY"; do
  (cd "$W/msbx" && timeout 120 "$py" sdr_manager.py > "$W/mst.log" 2>&1) || { tail -12 "$W/mst.log"; echo "STOP: Selbsttest sdr_manager ($py) - nichts geaendert"; exit 1; }
  for k in "sdr_manager selftest ok" "sdr_manager selftest Teil 2 ok" "sdr_manager selftest Teil 4 ok"; do
    [[ "$(cat "$W/mst.log")" == *"$k"* ]] || { tail -5 "$W/mst.log"; echo "STOP: Selbsttest sdr_manager ohne '$k' ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest sdr_manager mit $SPY und $VPY (Sandbox): $(grep 'selftest Teil 4' "$W/mst.log" | cut -c1-150)"
cp -a "$DASH_DIR"/prepper_*.py "$W/sbx/" 2>/dev/null || true
[[ -f "$DASH_DIR/sdr_config.json" ]] && cp "$DASH_DIR/sdr_config.json" "$W/sbx/sdr_config.json"
cp "$W/work/prepper_sdr.py" "$W/sbx/prepper_sdr.py"
for py in "$SPY" "$VPY"; do
  (cd "$W/sbx" && timeout 300 "$py" prepper_sdr.py selftest > "$W/selftest.log" 2>&1) || { tail -15 "$W/selftest.log"; echo "STOP: Selbsttest prepper_sdr ($py) - nichts geaendert"; exit 1; }
  for k in "selftest sdrTeil4 ok" "selftest sdrTeil2 ok" "selftest rdsNotfall ok" "selftest dabGain ok" "selftest dabFix ok" "selftest lageDB ok" "selftest OK:"; do
    [[ "$(cat "$W/selftest.log")" == *"$k"* ]] || { echo "STOP: Selbsttest prepper_sdr ohne $k ($py) - nichts geaendert"; exit 1; }
  done
done
echo "OK Selbsttest prepper_sdr mit $SPY und $VPY (Sandbox, kein Stick): $(grep 'selftest sdrTeil4 ok' "$W/selftest.log" | head -1 | cut -c1-150)"
python3 "$SG" "$F" "$W/work/dashboard.py" "$SMF" "$W/work/sdr_manager.py" "$M" "$W/work/prepper_sdr.py" || { echo "STOP: AST-Guard - nichts geaendert"; exit 1; }
echo "OK Trockenlauf idempotent, py_compile ohne Warnung (beide Pythons, alle 3 Dateien)"
# Sirene vorbereiten (nur falls sie fehlt; wird nie ueberschrieben)
SIR="$ST/sirene.wav"
if [[ -e "$SIR" ]]; then SIR_NEW=0; echo "OK Sirene vorhanden ($SIR, $(stat -c %s "$SIR") Bytes) - bleibt unveraendert"
else
  SIR_NEW=1
  python3 - "$W/sirene.wav" << 'SIRPY' || { echo "STOP: Sirene erzeugen fehlgeschlagen - nichts geaendert"; exit 1; }
import math, struct, sys, wave
rate, dur, lo, hi, per = 22050, 5.0, 600.0, 1250.0, 1.25    # auf- und abschwellend, 4 Zyklen in 5 s
ph, fr = 0.0, []
for i in range(int(rate * dur)):
    t = i / rate
    x = (t % per) / per
    f = lo + (hi - lo) * (2 * x if x < 0.5 else 2 * (1 - x))
    ph += 2 * math.pi * f / rate
    env = min(1.0, t / 0.05, (dur - t) / 0.05)
    fr.append(struct.pack("<h", int(0.8 * env * 32767 * math.sin(ph))))
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(b"".join(fr)); w.close()
r = wave.open(sys.argv[1], "rb"); assert abs(r.getnframes() / r.getframerate() - 5.0) < 0.01; r.close()
SIRPY
  echo "OK Sirene erzeugt (5 s auf/ab 600-1250 Hz, 22050 Hz mono) - wird als $SIR abgelegt (fehlte)"
fi
code() { local c; c=$("${CURL[@]}" "$@" -o /dev/null -w "%{http_code}" || true); [[ -z "$c" ]] && c=000; echo "$c"; }
code_r() { local c i; for i in 1 2 3 4 5; do c=$(code "$@"); [[ "$c" == 200 ]] && break; sleep 6; done; echo "$c"; }
sdr_fresh() { python3 -c "
import json,sys
try: t=json.load(open(sys.argv[1])).get('t') or 0
except Exception: t=0
sys.exit(0 if t>=float(sys.argv[2]) else 1)" "$DASH_DIR/sdr_status.json" "$1"; }
PAGES=(/ /funk /pi /umwelt /funk433 /aprs /meteor /rundfunk /energie /dabhist /mesh /karte)
APIS=(/api/sdr/ui /api/br24 /api/sdr/sticktest /api/sdr/live /api/sdr/map /api/broadcast/events /api/t2/status /api/t3/status /api/t4/status /api/t4/map)
declare -A PRE
for p in "${PAGES[@]}" "${APIS[@]}"; do PRE[$p]=$(code -L --max-redirs 5 "$B$p"); done
echo "vorher HTTP: $(for p in "${PAGES[@]}" "${APIS[@]}"; do printf '%s=%s ' "$p" "${PRE[$p]}"; done)"
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true)
# ---------- 3) Installieren (Strg-C wird bis Einspielen fertig ignoriert, damit nichts halb bleibt) ----------
trap '' INT
RESTARTED=0
NEWF=()
mkdir -p "$ST/leaflet"
for x in leaflet.js leaflet.css; do
  if ! cmp -s "$W/leaflet/$x" "$ST/leaflet/$x"; then
    [[ -e "$ST/leaflet/$x" ]] || NEWF+=("$ST/leaflet/$x")
    cp "$W/leaflet/$x" "$ST/leaflet/$x.new" && mv -f "$ST/leaflet/$x.new" "$ST/leaflet/$x" || { echo "STOP: Leaflet ablegen fehlgeschlagen"; exit 1; }
  fi
done
if [[ "$SIR_NEW" == 1 ]]; then
  cp "$W/sirene.wav" "$ST/.sirene.wav.new" && python3 -c "
import os,sys
os.link(sys.argv[1], sys.argv[2])" "$ST/.sirene.wav.new" "$SIR" && NEWF+=("$SIR") || echo "WARN: Sirene nicht abgelegt (Datei inzwischen vorhanden?) - bleibt wie sie ist"
  rm -f "$ST/.sirene.wav.new"
fi
echo "OK static: Leaflet 1.9.4 lokal ($ST/leaflet), Sirene $([[ -f "$SIR" ]] && echo da || echo FEHLT)"
SAME=1
cmp -s "$W/work/dashboard.py" "$F" || SAME=0
cmp -s "$W/work/prepper_sdr.py" "$M" || SAME=0
cmp -s "$W/work/sdr_manager.py" "$SMF" || SAME=0
ALL=("$F" "$M" "$SMF")
if [[ "$SAME" == 1 ]]; then
  echo "OK Teil 4 schon installiert - kein Neustart"
  T0=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true)
  [[ -n "$TB" ]] && T0=$(date -d "$TB" +%s 2>/dev/null || echo "$T0")
else
  RESTARTED=1
  sudo -v
  SINCE=$(date +%Y-%m-%d\ %H:%M:%S)
  rb() {
    echo "ROLLBACK: $1"
    sudo journalctl -u prepper-dashboard --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "teil4|Traceback|Error" | tail -8 | cut -c1-200 || true
    sudo journalctl -u prepper-sdr --since "$SINCE" --no-pager -o cat 2>/dev/null | grep -E "sdrTeil4|Traceback" | tail -4 | cut -c1-200 || true
    for x in "${ALL[@]}" "$DASH_DIR/broadcast_state.json"; do [[ -f "$x.bak-teil4-$TS" ]] && cp -a "$x.bak-teil4-$TS" "$x.rb" && mv -f "$x.rb" "$x"; done
    for x in "${NEWF[@]}"; do rm -f -- "$x"; done
    rmdir "$ST/leaflet" 2>/dev/null || true
    sudo systemctl restart prepper-sdr.service || true
    sudo systemctl restart prepper-dashboard.service || true
    for i in $(seq 1 80); do [[ "$(code "$B/")" == 200 ]] && break; sleep 3; done
    for x in "${ALL[@]}"; do cmp -s "$x" "$x.bak-teil4-$TS" && echo "  $(basename "$x") = Sicherung ($(sha256sum "$x" | cut -c1-16))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; done
    echo "  neu angelegte Dateien entfernt: ${#NEWF[@]}; lagezentrum.db bleibt (Teil 4 legt keine Tabellen an); Sicherung: lagezentrum.db.bak-teil4-$TS"
    echo "alter Stand wieder aktiv: prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null || true), prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null || true), HTTP / = $(code "$B/")"
  }
  for x in "${ALL[@]}" "$DASH_DIR/broadcast_state.json"; do
    [[ -f "$x" ]] || continue
    cp -a "$x" "$x.bak-teil4-$TS"
    { ls -1t "$x.bak-teil4-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  done
  if [[ -f "$DASH_DIR/lagezentrum.db" ]]; then
    python3 -c "
import sqlite3,sys
s=sqlite3.connect(sys.argv[1], timeout=30); d=sqlite3.connect(sys.argv[2]); s.backup(d); d.close(); s.close()" "$DASH_DIR/lagezentrum.db" "$DASH_DIR/lagezentrum.db.bak-teil4-$TS" \
      || { rm -f "$DASH_DIR/lagezentrum.db.bak-teil4-$TS"; echo "STOP: Sicherung lagezentrum.db fehlgeschlagen - nichts geaendert"; exit 1; }
    { ls -1t "$DASH_DIR/lagezentrum.db.bak-teil4-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  fi
  T0=$(date +%s)
  cp "$W/work/sdr_manager.py" "$SMF.new" && chmod --reference="$SMF.bak-teil4-$TS" "$SMF.new" && mv -f "$SMF.new" "$SMF" || { rb "installieren sdr_manager"; exit 1; }
  cp "$W/work/prepper_sdr.py" "$M.new" && chmod --reference="$M.bak-teil4-$TS" "$M.new" && mv -f "$M.new" "$M" || { rb "installieren prepper_sdr"; exit 1; }
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-teil4-$TS" "$F.new" && mv -f "$F.new" "$F" || { rb "installieren dashboard"; exit 1; }
  sudo systemctl restart prepper-sdr.service
  sudo systemctl restart prepper-dashboard.service
  echo "Neustart: nur prepper-sdr + prepper-dashboard - warte auf frischen SDR-Status und HTTP (max 240 s; sendet nichts, kein Ton) ..."
  ok=0; for i in $(seq 1 80); do sleep 3; systemctl is-active --quiet prepper-sdr && sdr_fresh "$T0" && [[ "$(code "$B/")" == 200 ]] && { ok=1; break; }; done
  [[ "$ok" == 1 ]] || { rb "prepper-sdr ohne frischen Status oder Dashboard antwortet nicht"; exit 1; }
fi
rbx() { if [[ "$RESTARTED" == 1 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
# ---------- 4) Rauchtest ----------
fail=0
for p in "${PAGES[@]}" "${APIS[@]}"; do c=$(code_r -L --max-redirs 5 "$B$p"); [[ "$c" != "${PRE[$p]}" && "$c" != 200 ]] && fail=1; printf '  HTTP %s = %s (vorher %s)\n' "$p" "$c" "${PRE[$p]}"; done
[[ "$fail" == 0 ]] || rbx "Seite/API antwortet schlechter als vorher"
for p in /karte /dabhist /api/t2/status /api/t3/status /api/t4/status /api/t4/map /karte/res/leaflet/leaflet.js /karte/res/leaflet/leaflet.css; do c=$(code_r "$B$p"); [[ "$c" == 200 ]] || rbx "$p antwortet $c"; done
c=$(code "$B/karte/res/dashboard.py"); [[ "$c" == 404 ]] && echo "OK /karte/res liefert nur Leaflet + Kacheln ($c fuer andere Dateien)" || rbx "/karte/res liefert andere Dateien ($c)"
c=$(code -X POST "$B/api/t4/status" -H 'Content-Type: application/json' -d '{}'); [[ "$c" == 405 ]] && echo "OK /api/t4/status nur lesen (POST $c)" || rbx "/api/t4/status nimmt POST an ($c)"
c=$(code -X POST "$B/api/t4/sdr2" -H 'Content-Type: application/json' -d '{"action":"freigeben","confirm":true}'); [[ "$c" == 403 ]] && echo "OK SDR-2-Freigabe ohne Lage-Seite abgewiesen ($c)" || rbx "/api/t4/sdr2 ohne Pruefung ($c)"
"${CURL[@]}" "$B/api/t4/status" -o "$W/t4_1.json" || true
python3 "$SH" check "$W/t4_1.json" && echo "OK /api/t4/status gueltig" || rbx "/api/t4/status ungueltig oder teil4 nicht aktiv"
"${CURL[@]}" "$B/api/t4/map" -o "$W/t4_map.json" || true
python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); assert len(d['masts']) >= 9 and d['home']['h_m'] == 431.7 and isinstance(d['zones'], list) and isinstance(d['roads'], list)" "$W/t4_map.json" \
  && echo "OK /api/t4/map: Masten, Funkhorizont, Zonen, Sperren" || rbx "/api/t4/map ungueltig"
"${CURL[@]}" "$B/karte" -o "$W/karte.html" || true
grep -q "/karte/res/leaflet/leaflet.js" "$W/karte.html" && echo "OK /karte mit Leaflet lokal" || rbx "/karte ohne Karte/Leaflet"
"${CURL[@]}" "$B/" -o "$W/lage.html" || true
grep -q 'id="t4-js"' "$W/lage.html" && grep -q 'id="t4Lage"' "$W/lage.html" && grep -q 'id="t4Why"' "$W/lage.html" && grep -q 'id="t2-js"' "$W/lage.html" && grep -q 'id="t3-js"' "$W/lage.html" \
  && echo "OK Lage-Seite: Status-Zeile eingefaerbt + Grund, SDR-Kachel, Historie (Teil 2/3 weiter da)" || rbx "Lage-Seite ohne Teil-4-Anzeige"
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true)
L1=$(python3 -c "
import sys; s=open(sys.argv[1],encoding='utf-8',errors='replace').read(); i=s.rfind('doPrepperRestore'); print('ja' if i>=0 and s.find('class=\"tile', i) < 0 and s.find('class=\"card', i) < 0 else 'nein')" "$W/pi.html" 2>/dev/null || echo nein)
[[ "$R1" == "$R0" ]] && echo "OK /pi: Sicherung unveraendert (${R1}x), letzte Kachel: $L1" || rbx "/pi Sicherung veraendert ($R0/$R1)"
sleep 5
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
systemctl is-active --quiet prepper-sdr || rbx "prepper-sdr laeuft nicht mehr"
sdr_fresh "$((T0 > $(date +%s) - 600 ? T0 : $(date +%s) - 600))" || rbx "SDR-Status nicht frisch"
JD=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -E "teil[234] (aktiv|FEHLER)" | tail -6 || true)
if [[ "$JD" == *"teil4 FEHLER"* || "$JD" == *"teil3 FEHLER"* || "$JD" == *"teil2 FEHLER"* ]]; then rbx "Dashboard: $JD"; fi
if [[ "$JD" == *"teil4 aktiv"* ]]; then echo "OK Journal Dashboard: $(echo "$JD" | grep 'teil4 aktiv' | tail -1 | cut -c1-260)"; elif [[ "$RESTARTED" == 1 ]]; then rbx "Dashboard meldet teil4 nicht (Journal)"; fi
E=$(sudo journalctl -u prepper-dashboard --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|teil4 (Zustand|Ereignis|Lautstaerke zurueck|Frequenz|Frequenz-Bestaetigung|Heartbeat planen|Pruefung|Sperre Teil-2-Knopf|Lage-Seite|Karte):" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Traceback/teil4-Fehler" || rbx "$E Traceback/teil4-Fehlerzeilen im Journal Dashboard"
E=$(sudo journalctl -u prepper-sdr --since "@$T0" --no-pager -o cat 2>/dev/null | grep -c -E "Traceback|sdrTeil[24] [a-z_ 0-9]+:" || true)
[[ "${E:-0}" == 0 ]] && echo "OK Journal prepper-sdr seit Neustart ohne Traceback/sdrTeil4-Fehler" || rbx "$E Traceback/sdrTeil4-Fehlerzeilen im Journal prepper-sdr"
echo "OK guards teil4(dash)=$(grep -c '# ===== teil4:' "$F" || true) teil3(dash)=$(grep -c '# ===== teil3:' "$F" || true) teil2(dash)=$(grep -c '# ===== teil2:' "$F" || true) sdrTeil4(sdr)=$(grep -c '# ===== sdrTeil4:' "$M" || true) sdrTeil2(sdr)=$(grep -c '# ===== sdrTeil2:' "$M" || true) rdsNotfall(sdr)=$(grep -c '# ===== rdsNotfall:' "$M" || true) Teil4(sdr_manager)=$(grep -c '# ---------------------------------------------------------------- Teil 4' "$SMF" || true) Teil3(mesh_router)=$(grep -c '# ---------------------------------------------------------------- Teil 3' "$DASH_DIR/mesh_router.py" || true)"
[[ -f "$F.bak-teil4-$TS" ]] && echo "Backups: *.bak-teil4-$TS (dashboard.py, prepper_sdr.py, sdr_manager.py, broadcast_state.json, lagezentrum.db), behalten: letzte $KEEP_LAST"
for x in "${ALL[@]}" "$DASH_DIR/database.py" "$DASH_DIR/mesh_router.py"; do echo "  $(basename "$x") sha16 $(sha256sum "$x" | cut -c1-16), $(wc -l < "$x") Zeilen"; done
echo "COMMIT $COMMIT_ARG teil4=1 - Einspielen fertig. Jetzt nur noch Anzeige: Abbruch mit Strg-C aendert nichts."
# ---------- 5) Anzeige (nur lesen) ----------
trap 'echo; echo "Abbruch mit Strg-C - nichts geaendert, Teil 4 bleibt aktiv. COMMIT $COMMIT_ARG teil4=1"; exit 0' INT
echo "Stand Teil 4:"
python3 "$SH" status "$W/t4_1.json" || true
echo "Audio-Pruefung (nur lesen, nichts installiert, kein Ton):"
for x in amixer aplay espeak-ng; do command -v "$x" >/dev/null 2>&1 && echo "  $x: da ($(command -v "$x"))" || echo "  $x: FEHLT"; done
id -nG fmg 2>/dev/null | tr ' ' '\n' | grep -qx audio && echo "  Benutzer fmg in Gruppe audio: ja" || echo "  Benutzer fmg in Gruppe audio: nein (ggf. sudo usermod -aG audio fmg, danach Neustart Dashboard)"
if grep -qi headphones /proc/asound/cards 2>/dev/null; then echo "  3,5-mm-Klinke (bcm2835 Headphones): gefunden"; else echo "  3,5-mm-Klinke (bcm2835 Headphones): nicht gefunden - Teil 4 nimmt dann die Standard-Ausgabe"; fi
command -v espeak-ng >/dev/null 2>&1 || echo "  Hinweis: Ansage braucht espeak-ng (sudo apt install espeak-ng); Sirene braucht aplay/amixer (Paket alsa-utils). Nicht automatisch installiert."
TL=$(find "$ST/tiles" -name '*.png' 2>/dev/null | wc -l || true)
echo "Karte: Offline-Kacheln vorhanden: ${TL:-0} (Download separat mit prepper-tiles-teil4.sh, ca. 2442 Kacheln / 60-70 MB)"
echo "Hinweis: Vor-Alarm- und Heartbeat-Meldungen gehen nur bei eingeschaltetem Auto-Versand (Lage-Seite) und nur an Mesh 1 ($EXP_M1)."
echo "COMMIT $COMMIT_ARG teil4=1 fertig"
