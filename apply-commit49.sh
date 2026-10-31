#!/bin/bash
set -eEuo pipefail
# commit49 audioKern - Lautsprecher-Ausgabe nach Stufen INFO/WARNUNG/KATASTROPHE (geoRelevanz-Stufen aus commit48):
#  - KATASTROPHE (nur echte teil4-Alarme): immer, auch nachts und stumm, 100 %, danach zurueck auf den Benutzerwert (Waechter prueft alle 30 s)
#  - WARNUNG (Gong) / INFO (Klick): NUR wenn eingeschaltet (Start: beide AUS); Nachtruhe 22-07; stumm hoechstens 8 h; Dubletten 6 h; Budget/Stunde
#  - Ort ohne amtlichen Begriff (geoRelevanz-Halt) = kein Ton bis zur Bestaetigung; DWD Stufe 4 = WARNUNG (Gong), nie 100 %
#  - Ausgabe aplay ueber pulse -> default -> plughw:Headphones (je mit Zeitlimit), Sprache espeak-ng; Toene (klick/gong/rausch.wav) erzeugt das Dashboard selbst in static/audio/
#  - APIs: GET /api/audio/status, POST /api/audio/cfg (info/warn/vol/mute_h), POST /api/audio/test (nie 100 %, nie Mesh, hoechstens alle 10 s)
#  - Lautstaerke: beim Start wird der Benutzerwert gesetzt (Voreinstellung 80 %, aenderbar ueber /api/audio/cfg)
#  dashboard.py: ein Block vor __main__ (keine geaenderte Zeile). lage_pages.py und prepper_sdr.py bleiben unveraendert. Mesh-Regeln (6 h, max 3/h) unveraendert.
# Aufruf: bash /tmp/apply-commit49.sh commit49 [dry-run]    (dry-run = alles pruefen und in der Sandbox testen, nichts installieren, kein sudo, kein Neustart)
# Basis streng (sha16): dashboard.py 334b60f2ed228831 (nach commit48) oder 1dc1eedcb0c91342 (neu), lage_pages.py 1d33ae9fd78f53dc, prepper_sdr.py 0900bfe6ba67e657.
# Sicherung dashboard.py.bak-commit49-ZEIT (letzte 3). Keine Datenbank-Aenderung. Nur prepper-dashboard wird neu gestartet. Sendet nichts, spielt beim Einspielen keinen Ton, Gain-Stufe 16 bleibt.
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
W=/tmp/commit49-apply
KEEP_LAST=3
NM=commit49
KNOWN_D16="334b60f2ed228831"; KNOWN_D16N="1dc1eedcb0c91342"; KNOWN_D16_C47="74ac7bfd0eebd4e0"
KNOWN_L16="1d33ae9fd78f53dc"; KNOWN_S16="0900bfe6ba67e657"
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
echo "=== commit49 apply ($COMMIT_ARG$([[ "$DRY" == 1 ]] && echo ", TROCKENLAUF")): audioKern, Dashboard-Port $PORT ==="
rm -rf "$W" && mkdir -p "$W/work" "$W/neu" "$W/alt"
EXPECT_PAL="45feaed48b77a616035112a3f48bd1eb80d364200d0f8a50946bb1c06f3c5f2a"
cat > "$W/patch.py" << 'MK_C49_PAL_EOF'
"""Patcher speedAsync (generisch wie relStop). Aufruf: patch-pw.py NAME dsh QUELLE ZIEL BLOCK EDITS. Idempotent: schon gepatcht -> Ziel = Quelle.
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
name = {"dsh": "dashboard.py", "fh": "funk_health.py", "hw": "mesh_hang_watchdog.py", "pd": "prepper_docs.py"}[kind]
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
MK_C49_PAL_EOF
EXPECT_RAE="0279869adfb229e9f92730bc2205c8d36824547c6db74c30e16cb0e5bcfba541"
cat > "$W/edits.py" << 'MK_C49_RAE_EOF'
# Stellen fuer audioKern (commit49): Basis 334b60f2ed228831 (Stand nach commit48); nur ein Block vor __main__, keine Aenderung an bestehenden Zeilen
DSH_ANCHOR = '\n\nif __name__ == "__main__":\n'
DSH_EDITS = []
MK_C49_RAE_EOF
EXPECT_RAB="11e50f23e4ca500be05fe7a736e469911d87e8ab950ddcf9b7a3058afb11dc19"
cat > "$W/blk.py" << 'MK_C49_RAB_EOF'
# ===== audioKern: Lautsprecher-Ausgabe (3,5-mm-Klinke) als Warteschlange mit Stufen KATASTROPHE > WARNUNG > INFO (geoRelevanz-Stufen; Ort ohne amtlichen Begriff = kein Ton bis Bestaetigung); KATASTROPHE = teil4-Echtalarm mit 100 %, danach Benutzerwert (Rueckstellung beim Start + Waechter); INFO/WARNUNG zunaechst AUS; Nachtruhe 22-07 ausser KATASTROPHE; Stummschalten hoechstens 8 h; eigene synthetische Toene; aplay ueber pulse/default, Rueckfall plughw:Headphones, alles mit Zeitlimit; sendet nichts (kein Mesh, auch der Test nicht) =====
import hashlib as _au_hl
import json as _au_json
import math as _au_math
import os as _au_os
import re as _au_re
import shutil as _au_shutil
import struct as _au_struct
import subprocess as _au_sp
import tempfile as _au_tmp
import threading as _au_th
import time as _au_time
import wave as _au_wave

AU_CFG_FILE = _au_os.path.join(_SDR_BASE, "audio_cfg.json")
AU_STATE_FILE = _au_os.path.join(_SDR_BASE, "audio_state.json")
AU_EXE = ("amixer", "aplay", "espeak-ng")              # die einzigen Programme (ohne Shell); amixer nur ueber teil4 (_t4_vol)
AU_PRIO = {"KATASTROPHE": 3, "WARNUNG": 2, "INFO": 1}
AU_EXPIRE_S = {"INFO": 1800, "WARNUNG": 7200, "KATASTROPHE": 3600}
AU_TXT_MAX = {"INFO": 200, "WARNUNG": 200, "KATASTROPHE": 600}
AU_BUDGET_H = {"INFO": 2, "WARNUNG": 4}                 # Ausgaben je Stunde
AU_DEDUP_S = 6 * 3600                                   # INFO/WARNUNG: gleiche Quelle+Schluessel hoechstens alle 6 h
AU_NIGHT = (22, 7)                                      # Nachtruhe 22:00-07:00 (nur KATASTROPHE)
AU_MUTE_MAX_H = 8
AU_QMAX = 10
AU_VOL_DEFAULT = 80
AU_WD_S = 60                                            # Waechter: 100 % ohne laufende KATASTROPHE laenger als 60 s -> Benutzerwert
AU_TEST_GAP_S = 10
AU_COLLECT_S = 20
AU_SR = 22050
AU_LIMIT = {"ton": 8, "say": 60, "play": 180}           # s: Ton, espeak-ng, Ansage
AU_TONE_SHA = {}                                        # Fingerabdruck der erzeugten Toene (Statusanzeige)
_AU = {"aktiv": False, "err": None, "started": False, "q": [], "cur": None, "abort": False, "proc": None, "last": [], "sent": [], "seen": {}, "dev_ok": None,
       "kat_end": 0, "kat_on": False, "wd": None, "vol_start": None, "test_t": 0, "collect_t": 0, "n": {"KATASTROPHE": 0, "WARNUNG": 0, "INFO": 0, "TEST": 0},
       "drop": {}, "tones": {}, "fake": None, "cfg_err": None, "t4_prev": {}}
_AU_LOCK = _au_th.RLock()
_AU_CV = _au_th.Condition(_AU_LOCK)


def _au_log(*a):
    if _AU.get("quiet"):
        return
    print("audioKern:", *a, flush=True)


# ---------------------------------------------------------------- Toene (synthetisch, deterministisch)
def _au_pcm(samples):
    return b"".join(_au_struct.pack("<h", max(-32767, min(32767, int(round(s * 32767))))) for s in samples)


def _au_tone_klick():
    out = []
    for k in range(2):
        n = int(0.015 * AU_SR)
        out += [_au_math.sin(2 * _au_math.pi * 2000 * i / AU_SR) * 0.6 * (1 - i / n) for i in range(n)]
        out += [0.0] * int(0.08 * AU_SR)
    return out


def _au_tone_gong():
    n = int(1.0 * AU_SR)
    return [0.45 * _au_math.exp(-3.2 * i / AU_SR) * (_au_math.sin(2 * _au_math.pi * 523.25 * i / AU_SR) + 0.8 * _au_math.sin(2 * _au_math.pi * 659.25 * i / AU_SR)) * min(1.0, i / 120.0)
            for i in range(n)]


def _au_tone_rausch():
    n, x, y, out = int(0.35 * AU_SR), 12345, 0.0, []
    for i in range(n):
        x = (1103515245 * x + 12345) & 0x7FFFFFFF
        y = 0.85 * y + 0.15 * ((x / 1073741823.5) - 1.0)
        out.append(y * 0.9 * (1 - i / n))
    return out


AU_TONES = {"klick": _au_tone_klick, "gong": _au_tone_gong, "rausch": _au_tone_rausch}


def _au_tone_bytes(name):
    import io
    b = io.BytesIO()
    w = _au_wave.open(b, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(AU_SR)
    w.writeframes(_au_pcm(AU_TONES[name]()))
    w.close()
    return b.getvalue()


def _au_tone_dir():
    f = globals().get("_t4_static")
    return _au_os.path.join(f() if callable(f) else _au_os.path.join(_SDR_BASE, "static"), "audio")


def _au_tones_ensure():
    """Toene in static/audio/ anlegen bzw. erneuern (nur eigene Dateien klick/gong/rausch.wav, atomar)."""
    d = _au_tone_dir()
    _au_os.makedirs(d, exist_ok=True)
    res = {}
    for n in AU_TONES:
        b = _au_tone_bytes(n)
        h = _au_hl.sha256(b).hexdigest()[:16]
        p = _au_os.path.join(d, n + ".wav")
        try:
            with open(p, "rb") as f:
                same = f.read() == b
        except OSError:
            same = False
        if not same:
            tmp = p + ".tmp"
            with open(tmp, "wb") as f:
                f.write(b)
            _au_os.replace(tmp, p)
        res[n] = {"path": p, "sha16": h, "bytes": len(b), "neu": not same}
    _AU["tones"] = res
    return res


# ---------------------------------------------------------------- Einstellungen (audio_cfg.json, atomar)
def _au_cfg_default():
    return {"info": False, "warn": False, "vol": AU_VOL_DEFAULT, "mute_until": 0, "t": None, "by": None}


def _au_cfg_check(d):
    """-> (cfg, fehler|None). Unbekannte/falsche Werte -> Standard fuer dieses Feld."""
    c, err = _au_cfg_default(), []
    if not isinstance(d, dict):
        return c, "kein JSON-Objekt"
    for k in ("info", "warn"):
        if k in d:
            if isinstance(d[k], bool):
                c[k] = d[k]
            else:
                err.append(k)
    if "vol" in d:
        if isinstance(d["vol"], int) and not isinstance(d["vol"], bool) and 0 <= d["vol"] <= 100:
            c["vol"] = d["vol"]
        else:
            err.append("vol")
    if "mute_until" in d:
        if isinstance(d["mute_until"], (int, float)) and not isinstance(d["mute_until"], bool) and d["mute_until"] >= 0:
            c["mute_until"] = int(d["mute_until"])
        else:
            err.append("mute_until")
    for k in ("t", "by"):
        if isinstance(d.get(k), (int, str)):
            c[k] = d[k]
    return c, (", ".join(err) + " ungueltig") if err else None


def _au_cfg(path=None):
    path = path or AU_CFG_FILE
    try:
        with open(path, encoding="utf-8") as f:
            d = _au_json.load(f)
    except FileNotFoundError:
        _AU["cfg_err"] = None
        return _au_cfg_default()
    except Exception as e:
        _AU["cfg_err"] = "%s: %s" % (type(e).__name__, str(e)[:80])
        return _au_cfg_default()
    c, err = _au_cfg_check(d)
    _AU["cfg_err"] = err
    return c


def _au_cfg_save(c, path=None):
    path = path or AU_CFG_FILE
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        _au_json.dump(c, f, ensure_ascii=False)
    _au_os.replace(tmp, path)


def _au_muted(c, now):
    mu = int(c.get("mute_until") or 0)
    return now < mu and mu - now <= AU_MUTE_MAX_H * 3600 + 60


def _au_night(now):
    h = _au_time.localtime(now).tm_hour
    return h >= AU_NIGHT[0] or h < AU_NIGHT[1]


# ---------------------------------------------------------------- Warteschlange
def _au_clean(t, lvl):
    return " ".join(str(t or "").replace("…", " ").split())[:AU_TXT_MAX.get(lvl, 200)]


def _au_offer(lvl, src, key, text, now=None, c=None, force=False):
    """Eintrag anbieten -> (True, "ok") oder (False, Grund). KATASTROPHE: immer (teil4 hat schon dedupliziert). force = Test von Hand."""
    now = now or _au_time.time()
    if lvl not in AU_PRIO:
        return False, "Stufe unbekannt"
    text = _au_clean(text, lvl)
    if not text:
        return False, "leer"
    with _AU_LOCK:
        if lvl != "KATASTROPHE" and not force:
            c = c or _au_cfg()
            if not c.get("info" if lvl == "INFO" else "warn"):
                return False, "%s AUS (Schalter)" % lvl
            if _au_muted(c, now):
                return False, "stumm bis %s" % _au_time.strftime("%H:%M", _au_time.localtime(c["mute_until"]))
            if _au_night(now):
                return False, "Nachtruhe 22-07"
            k = "%s|%s|%s" % (lvl, src, key)
            if now - _AU["seen"].get(k, -1e12) < AU_DEDUP_S:
                return False, "schon gesagt (6 h)"
            n_h = len([x for x in _AU["sent"] if x[1] == lvl and now - x[0] < 3600])
            if n_h >= AU_BUDGET_H[lvl]:
                return False, "Budget %d/h erreicht" % AU_BUDGET_H[lvl]
            _AU["seen"][k] = now
            for kk in [kk for kk, tt in _AU["seen"].items() if now - tt > AU_DEDUP_S]:
                _AU["seen"].pop(kk, None)
        it = {"lvl": lvl, "src": str(src)[:20], "key": str(key)[:80], "text": text, "t": now, "exp": now + AU_EXPIRE_S[lvl], "test": bool(force)}
        q = [x for x in _AU["q"] if x["exp"] > now]
        if len(q) >= AU_QMAX:
            low = min(q, key=lambda x: (AU_PRIO[x["lvl"]], x["t"]))
            if AU_PRIO[low["lvl"]] > AU_PRIO[lvl]:
                _AU["q"] = q
                return False, "Warteschlange voll"
            q.remove(low)
        q.append(it)
        _AU["q"] = q
        cur = _AU["cur"]
        if lvl == "KATASTROPHE" and cur and cur["lvl"] != "KATASTROPHE":
            _AU["abort"] = True
            _au_kill_cur()
        _AU_CV.notify_all()
    return True, "ok"


def _au_pick(now):
    with _AU_LOCK:
        q = [x for x in _AU["q"] if x["exp"] > now]
        for x in _AU["q"]:
            if x["exp"] <= now:
                _AU["drop"][x["lvl"]] = _AU["drop"].get(x["lvl"], 0) + 1
        if not q:
            _AU["q"] = []
            return None
        it = max(q, key=lambda x: (AU_PRIO[x["lvl"]], -x["t"]))
        q.remove(it)
        _AU["q"] = q
        return it


# ---------------------------------------------------------------- Prozesse (ohne Shell, mit Zeitlimit)
def _au_which(n):
    f = (_AU.get("fake") or {}).get("which")
    return f(n) if callable(f) else _au_shutil.which(n)


def _au_spawn(argv, env=None):
    if not argv or argv[0] not in AU_EXE[1:]:
        raise RuntimeError("audioKern: Programm nicht erlaubt")
    f = (_AU.get("fake") or {}).get("spawn")
    if callable(f):
        p = f(list(argv), env)
    else:
        exe = _au_which(argv[0])
        if not exe:
            return None
        e = dict(_au_os.environ)
        e.update(env or {})
        p = _au_sp.Popen([exe] + list(argv[1:]), stdin=_au_sp.DEVNULL, stdout=_au_sp.DEVNULL, stderr=_au_sp.PIPE, env=e)
    with _AU_LOCK:
        _AU["proc"] = p
    t4 = globals().get("_T4")
    if isinstance(t4, dict) and isinstance((t4.get("audio") or {}).get("procs"), list):
        t4["audio"]["procs"].append(p)            # teil4-Kill-Switch (Entwarnung) erfasst auch diese Ausgabe
    return p


def _au_kill_cur():
    p = _AU.get("proc")
    if p is not None and p.poll() is None:
        try:
            f = (_AU.get("fake") or {}).get("kill")
            f(p) if callable(f) else p.terminate()
        except Exception:
            pass


def _au_wait(p, limit):
    """-> (ok, Grund)"""
    if p is None:
        return False, "Programm fehlt"
    end = _au_time.time() + limit
    while p.poll() is None:
        if _AU["abort"]:
            _au_kill_cur()
            return False, "abgebrochen"
        if _au_time.time() > end:
            _au_kill_cur()
            return False, "Zeitlimit %d s" % limit
        _au_time.sleep(0.05)
    if p.poll() == 0:
        return True, "ok"
    err = ""
    try:
        err = (p.stderr.read() or b"").decode("utf-8", "replace") if getattr(p, "stderr", None) else ""
    except Exception:
        pass
    return False, "rc %s%s" % (p.poll(), (" " + " ".join(err.split())[:60]) if err else "")


def _au_devices():
    """Ausgabewege in Reihenfolge: PipeWire/Pulse (wenn Socket da), ALSA default, Klinke direkt (plughw:Headphones). Der zuletzt erfolgreiche zuerst."""
    f = (_AU.get("fake") or {}).get("devs")
    if callable(f):
        devs = f()
    else:
        devs = []
        rd = "/run/user/%d" % _au_os.getuid()
        if _au_os.path.exists(_au_os.path.join(rd, "pulse", "native")):
            devs.append(("pulse", {"XDG_RUNTIME_DIR": rd, "PULSE_SERVER": "unix:" + _au_os.path.join(rd, "pulse", "native")}))
        devs.append(("default", {"XDG_RUNTIME_DIR": rd} if _au_os.path.isdir(rd) else {}))
        card = globals()["_t4_card"]() if callable(globals().get("_t4_card")) else None
        devs.append((card["dev"] if card else "plughw:CARD=Headphones,DEV=0", {}))
    ok = _AU.get("dev_ok")
    return sorted(devs, key=lambda d: 0 if d[0] == ok else 1)


def _au_play(path, limit):
    """WAV abspielen; bei Fehler (z. B. Geraet belegt) naechster Ausgabeweg. -> (ok, Text)"""
    tried = []
    for dev, env in _au_devices():
        if _AU["abort"]:
            return False, "abgebrochen"
        ok, why = _au_wait(_au_spawn(["aplay", "-q", "-D", dev, path], env), limit)
        if ok:
            _AU["dev_ok"] = dev
            return True, dev
        tried.append("%s: %s" % (dev, why))
        if why == "abgebrochen" or why.startswith("Zeitlimit") or why == "Programm fehlt":
            break
    return False, "; ".join(tried)[:200]


def _au_vol(pct=None):
    """Lautstaerke der Klinke (teil4: Karte/Regler). pct None -> lesen."""
    f = (_AU.get("fake") or {}).get("vol")
    if callable(f):
        return f(pct)
    card = globals()["_t4_card"]()
    if not card:
        return None
    ctl = globals()["_t4_ctl"](card)
    if not ctl:
        return None
    return globals()["_t4_vol"](card, ctl, pct)


# ---------------------------------------------------------------- Ausgabe
def _au_out(it):
    lvl, steps, wav = it["lvl"], [], None
    kat = lvl == "KATASTROPHE"
    c = _au_cfg()
    t4a = (globals().get("_T4") or {}).get("audio") if isinstance(globals().get("_T4"), dict) else None
    with _AU_LOCK:
        _AU.update(cur=it, abort=False)
        if kat:
            _AU["kat_on"] = True
    try:
        if kat:
            if isinstance(t4a, dict):
                t4a.update(busy=True, abort=False, err=None)
            steps.append("Lautstaerke 100 %%: %s" % ("ok" if _au_vol(100) else "nicht gesetzt"))
            sir = _au_os.path.join(_au_os.path.dirname(_au_tone_dir()), "sirene.wav")
            tone = sir if _au_os.path.isfile(sir) else (_AU["tones"].get("gong") or {}).get("path")
        else:
            tone = (_AU["tones"].get("gong" if lvl == "WARNUNG" else "klick") or {}).get("path")
        if tone and not _AU["abort"]:
            ok, d = _au_play(tone, 15 if kat else AU_LIMIT["ton"])
            steps.append("Ton %s" % (d if ok else "Fehler (%s)" % d))
        if not _AU["abort"]:
            fd, wav = _au_tmp.mkstemp(prefix="audiokern-", suffix=".wav")
            _au_os.close(fd)
            ok, why = _au_wait(_au_spawn(["espeak-ng", "-v", "de", "-s", "140", "-a", "100" if kat else "80", "-w", wav, it["text"]]), AU_LIMIT["say"])
            if ok and not _AU["abort"]:
                ok, d = _au_play(wav, AU_LIMIT["play"])
                steps.append("Ansage %s" % (d if ok else "Fehler (%s)" % d))
            else:
                steps.append("espeak-ng %s" % why)
        r = (_AU["tones"].get("rausch") or {}).get("path")
        if r and not _AU["abort"]:
            _au_play(r, AU_LIMIT["ton"])
    except Exception as e:
        steps.append("Fehler %s: %s" % (type(e).__name__, str(e)[:80]))
    finally:
        ab = _AU["abort"]
        if kat:
            v = c.get("vol", AU_VOL_DEFAULT)
            steps.append("zurueck auf %s %%: %s" % (v, "ok" if _au_vol(v) else "nicht gesetzt"))
            if isinstance(t4a, dict):
                t4a.update(busy=False, last={"t": int(_au_time.time()), "h": it.get("key"), "text": it["text"][:120], "steps": steps, "abort": ab})
        if wav:
            try:
                _au_os.remove(wav)
            except OSError:
                pass
        now = _au_time.time()
        with _AU_LOCK:
            if kat:
                _AU.update(kat_on=False, kat_end=now)
            _AU["n"]["TEST" if it.get("test") else lvl] += 1
            _AU["sent"] = [x for x in _AU["sent"] if now - x[0] < 3600] + ([] if it.get("test") else [(now, lvl)])
            _AU["last"] = ([{"t": int(now), "lvl": lvl, "src": it["src"], "text": it["text"][:90], "steps": steps, "abort": ab, "test": it.get("test")}] + _AU["last"])[:10]
            _AU.update(cur=None, proc=None, abort=False)
        _au_log("%s%s %s: %s" % (lvl, " (Test)" if it.get("test") else "", it["src"], " · ".join(steps)[:300]))
    return steps


def _au_watch(now, c=None):
    """Waechter: 100 % ohne laufende KATASTROPHE seit > 60 s -> Benutzerwert. -> Text | None"""
    c = c or _au_cfg()
    v = int(c.get("vol", AU_VOL_DEFAULT))
    if _AU["kat_on"] or v >= 100 or now - _AU["kat_end"] < AU_WD_S:
        return None
    cur = _au_vol()
    if cur is not None and cur >= 100:
        ok = _au_vol(v)
        _AU["wd"] = {"t": int(now), "von": cur, "auf": v, "ok": bool(ok)}
        return "Waechter: Lautstaerke 100 %% ohne Katastrophe -> %d %% (%s)" % (v, "ok" if ok else "Fehler")
    return None


# ---------------------------------------------------------------- Quellen INFO/WARNUNG (nur wenn eingeschaltet)
def _au_collect(now, br=None, ds=None, nd=None, c=None):
    """BR24-Hinweise (geoRelevanz INFO/WARNUNG; Halt ohne Bestaetigung = kein Ton), DWD (Stufe >= 3 WARNUNG, sonst INFO), NINA (Moderate WARNUNG, Minor INFO;
    Severe/Extreme laufen als Echtalarm ueber teil4). -> Liste (Stufe, Quelle, Schluessel, Text, Ergebnis)"""
    c = c or _au_cfg()
    if not (c.get("info") or c.get("warn")):
        return []
    out = []
    if br is None:
        f = globals().get("_br24_state")
        br = f() if callable(f) else {}
    ds = globals().get("data_store") or {} if ds is None else ds
    nd = (globals().get("_T2D") or {}).get("nina") or {} if nd is None else nd
    cand = []
    if isinstance(br, dict) and not br.get("geo_hold"):
        gh = br.get("geo_hint") or {}
        if gh.get("lvl") in ("INFO", "WARNUNG") and gh.get("text"):
            cand.append((gh["lvl"], "BR24", _au_hl.sha1(str(gh["text"]).encode("utf-8")).hexdigest()[:12], "Hinweis B R 24: %s" % gh["text"]))
    dv = (ds.get("dwd_warn") or {}).get("value") if isinstance(ds.get("dwd_warn"), dict) else None
    for w in ((dv or {}).get("items") or [])[:5] if isinstance(dv, dict) else []:
        if not isinstance(w, dict):
            continue
        lv = int(w.get("level") or 0)
        if lv <= 0:
            continue
        cand.append(("WARNUNG" if lv >= 3 else "INFO", "DWD", "%s|%s|%s" % (w.get("cell"), w.get("event"), w.get("start")),
                     "Wetterwarnung Stufe %d: %s" % (lv, w.get("headline") or w.get("event") or "")))
    nv = (ds.get("nina") or {}).get("value") if isinstance(ds.get("nina"), dict) else None
    for w in nv if isinstance(nv, list) else []:
        if not isinstance(w, dict):
            continue
        tt = str(w.get("title") or "")
        if not tt or _au_re.search(r"(?i)probe|test|warntag|uebung|übung", tt) or str(w.get("msgType")) == "Cancel":
            continue
        d = nd.get(w.get("id")) or {}
        sev = str(d.get("severity") or "")
        if sev in ("Severe", "Extreme") or str(d.get("status") or "Actual") != "Actual":
            continue
        cand.append(("WARNUNG" if sev == "Moderate" else "INFO", "NINA", str(w.get("id") or tt)[:60], "NINA: %s" % tt))
    for lvl, src, key, text in cand:
        ok, why = _au_offer(lvl, src, key, text, now, c)
        out.append((lvl, src, key, text[:60], why))
    return out


# ---------------------------------------------------------------- teil4 anschliessen
def _au_t4_cascade(text, h):
    """Ersetzt teil4 _t4_cascade: Echtalarm (KATASTROPHE) in die Warteschlange; laeuft der Ausgabe-Faden nicht, wie bisher."""
    if not _AU["started"]:
        return _AU["t4_prev"]["cascade"](text, h)
    ok, why = _au_offer("KATASTROPHE", "teil4", h, text)
    if not ok:
        _au_log("KATASTROPHE nicht eingereiht:", why)


def _au_t4_kill_all(why):
    """teil4-Kill-Switch (Entwarnung) + Warteschlange: laufende Ausgabe abbrechen, KATASTROPHE-Eintraege verwerfen."""
    with _AU_LOCK:
        _AU["q"] = [x for x in _AU["q"] if x["lvl"] != "KATASTROPHE"]
        if _AU["cur"]:
            _AU["abort"] = True
            _au_kill_cur()
    return _AU["t4_prev"]["kill"](why)


# ---------------------------------------------------------------- Faden
def _au_worker():
    try:
        _au_tones_ensure()
        c = _au_cfg()
        v0 = _au_vol()
        ok = _au_vol(c.get("vol", AU_VOL_DEFAULT))
        _AU["vol_start"] = {"vorher": v0, "jetzt": c.get("vol", AU_VOL_DEFAULT), "ok": bool(ok)}
        _au_log("Start: Lautstaerke %s %% -> Benutzerwert %s %% (%s); Toene %s" % (v0, c.get("vol"), "ok" if ok else "nicht gesetzt", ", ".join("%s %s" % (k, x["sha16"]) for k, x in _AU["tones"].items())))
    except Exception as e:
        _AU["err"] = "Start: %s" % str(e)[:120]
        _au_log("Start Fehler:", e)
    wd_t = 0
    while True:
        try:
            now = _au_time.time()
            if now - _AU["collect_t"] >= AU_COLLECT_S:
                _AU["collect_t"] = now
                _au_collect(now)
            if now - wd_t >= 30:
                wd_t = now
                m = _au_watch(now)
                if m:
                    _au_log(m)
            it = _au_pick(now)
            if it:
                _au_out(it)
                continue
            with _AU_LOCK:
                _AU_CV.wait(5)
        except Exception as e:
            _AU["err"] = str(e)[:160]
            _au_log("Faden:", e)
            _au_time.sleep(5)


# ---------------------------------------------------------------- Web
def _au_status():
    now = _au_time.time()
    c = _au_cfg()
    with _AU_LOCK:
        return {"aktiv": _AU["aktiv"], "faden": _AU["started"], "err": _AU["err"], "cfg": c, "cfg_err": _AU["cfg_err"], "stumm": _au_muted(c, now), "nachtruhe": _au_night(now),
                "q": [{"lvl": x["lvl"], "src": x["src"], "text": x["text"][:60], "bis": int(x["exp"])} for x in _AU["q"]], "cur": (_AU["cur"] or {}).get("lvl"),
                "last": list(_AU["last"]), "n": dict(_AU["n"]), "verfallen": dict(_AU["drop"]), "dev_ok": _AU["dev_ok"], "waechter": _AU["wd"], "start": _AU["vol_start"],
                "toene": {k: x["sha16"] for k, x in _AU["tones"].items()}, "tools": {x: bool(_au_which(x)) for x in AU_EXE},
                "regeln": {"nachtruhe": "22-07 (ausser KATASTROPHE)", "budget_h": AU_BUDGET_H, "dedup_h": AU_DEDUP_S // 3600, "stumm_max_h": AU_MUTE_MAX_H, "queue_max": AU_QMAX}}


def _au_api_status():
    from flask import jsonify
    return jsonify(_au_status())


def _au_api_cfg():
    """POST {info?: bool, warn?: bool, vol?: 0-100, mute_h?: 0-8} -> neue Einstellung. Schreibt nur audio_cfg.json."""
    from flask import jsonify, request
    d = request.get_json(silent=True)
    if not isinstance(d, dict) or not d or set(d) - {"info", "warn", "vol", "mute_h"}:
        return jsonify({"ok": False, "err": "erlaubt: info, warn (true/false), vol (0-100), mute_h (0-8)"}), 400
    c = _au_cfg()
    for k in ("info", "warn"):
        if k in d:
            if not isinstance(d[k], bool):
                return jsonify({"ok": False, "err": "%s muss true/false sein" % k}), 400
            c[k] = d[k]
    if "vol" in d:
        if not isinstance(d["vol"], int) or isinstance(d["vol"], bool) or not 0 <= d["vol"] <= 100:
            return jsonify({"ok": False, "err": "vol 0-100"}), 400
        c["vol"] = d["vol"]
    if "mute_h" in d:
        h = d["mute_h"]
        if not isinstance(h, (int, float)) or isinstance(h, bool) or not 0 <= h <= AU_MUTE_MAX_H:
            return jsonify({"ok": False, "err": "mute_h 0-%d" % AU_MUTE_MAX_H}), 400
        c["mute_until"] = int(_au_time.time() + h * 3600) if h > 0 else 0
    c.update(t=int(_au_time.time()), by="dashboard")
    with _AU_LOCK:
        _au_cfg_save(c)
        if "vol" in d and not _AU["kat_on"] and _AU["started"]:
            _au_vol(c["vol"])
    _au_log("Einstellung: INFO %s, WARNUNG %s, Lautstaerke %s %%, stumm bis %s" % ("an" if c["info"] else "aus", "an" if c["warn"] else "aus", c["vol"],
                                                                                    _au_time.strftime("%H:%M", _au_time.localtime(c["mute_until"])) if c["mute_until"] else "-"))
    return jsonify({"ok": True, "cfg": c})


AU_TEST_TXT = {"info": ("INFO", "Test der Lautsprecher-Ausgabe, Stufe Info."), "warnung": ("WARNUNG", "Test der Lautsprecher-Ausgabe, Stufe Warnung.")}


def _au_api_test():
    """POST {art: info|warnung} -> Ton + kurze Test-Ansage mit Benutzer-Lautstaerke (nie 100 %, nie Mesh). Hoechstens alle 10 s."""
    from flask import jsonify, request
    d = request.get_json(silent=True) or {}
    art = d.get("art") if isinstance(d, dict) else None
    if art not in AU_TEST_TXT:
        return jsonify({"ok": False, "err": "art: info oder warnung"}), 400
    now = _au_time.time()
    with _AU_LOCK:
        if now - _AU["test_t"] < AU_TEST_GAP_S:
            return jsonify({"ok": False, "err": "Test hoechstens alle %d s" % AU_TEST_GAP_S}), 429
        if not _AU["started"]:
            return jsonify({"ok": False, "err": "Ausgabe-Faden laeuft nicht"}), 503
        _AU["test_t"] = now
    lvl, txt = AU_TEST_TXT[art]
    ok, why = _au_offer(lvl, "Test", "test-%d" % int(now), txt, now, force=True)
    return jsonify({"ok": ok, "why": why, "mesh": False}), (202 if ok else 409)


class _AuFakeP:
    def __init__(self, rc, err=b"", log=None, argv=None):
        self.rc, self._rc, self.pid, self.log, self.argv = None, rc, 999999, log, argv
        import io
        self.stderr = io.BytesIO(err)

    def poll(self):
        if self.rc is None and self._rc is not None:
            self.rc = self._rc
        return self.rc

    def terminate(self):
        self.rc = -15


def _selftest_audiokern():
    keep = {k: (dict(v) if isinstance(v, dict) else list(v) if isinstance(v, list) else v) for k, v in _AU.items()}
    t4 = globals().get("_T4")
    t4a = dict(t4["audio"]) if isinstance(t4, dict) and isinstance(t4.get("audio"), dict) else None
    tmpd = _au_tmp.mkdtemp(prefix="audiokern-st-")
    try:
        _AU["quiet"] = True
        # Toene: deterministisch, Laenge
        for n, sec in (("klick", 0.19), ("gong", 1.0), ("rausch", 0.35)):
            b1, b2 = _au_tone_bytes(n), _au_tone_bytes(n)
            assert b1 == b2 and b1[:4] == b"RIFF" and abs((len(b1) - 44) / 2 / AU_SR - sec) < 0.01, (n, len(b1))
        # Einstellungen
        assert _au_cfg_check({"info": "ja", "vol": 120, "mute_until": -1}) == (_au_cfg_default(), "info, vol, mute_until ungueltig")
        assert _au_cfg_check({"info": True, "vol": 55})[0]["info"] is True and _au_cfg_check({"vol": True})[1]
        p = _au_os.path.join(tmpd, "c.json")
        _au_cfg_save(dict(_au_cfg_default(), warn=True, vol=40), p)
        assert _au_cfg(p)["warn"] is True and _au_cfg(p)["vol"] == 40 and not _au_os.path.exists(p + ".tmp")
        open(p, "w").write("{kaputt")
        assert _au_cfg(p) == _au_cfg_default() and _AU["cfg_err"]
        assert _au_cfg(_au_os.path.join(tmpd, "fehlt.json")) == _au_cfg_default() and _au_cfg_default()["info"] is False and _au_cfg_default()["warn"] is False
        # Zeiten: Mittag / Nacht (Ortszeit), Stummschaltung max 8 h
        lt = list(_au_time.localtime())
        noon = _au_time.mktime(tuple(lt[:3] + [12, 0, 0] + lt[6:8] + [-1]))
        night = _au_time.mktime(tuple(lt[:3] + [23, 30, 0] + lt[6:8] + [-1]))
        early = _au_time.mktime(tuple(lt[:3] + [6, 59, 0] + lt[6:8] + [-1]))
        assert not _au_night(noon) and _au_night(night) and _au_night(early) and not _au_night(early + 120)
        assert _au_muted({"mute_until": noon + 8 * 3600}, noon) and not _au_muted({"mute_until": noon + 9 * 3600}, noon) and not _au_muted({"mute_until": noon - 1}, noon)
        on = dict(_au_cfg_default(), info=True, warn=True)
        off = _au_cfg_default()
        _AU.update(q=[], seen={}, sent=[], cur=None)
        assert _au_offer("INFO", "X", "a", "t", noon, off) == (False, "INFO AUS (Schalter)")
        assert _au_offer("WARNUNG", "X", "a", "t", noon, dict(off, info=True)) == (False, "WARNUNG AUS (Schalter)")
        assert _au_offer("WARNUNG", "X", "a", "t", night, on) == (False, "Nachtruhe 22-07")
        assert _au_offer("WARNUNG", "X", "a", "t", noon, dict(on, mute_until=noon + 3600))[1].startswith("stumm")
        assert _au_offer("KATASTROPHE", "teil4", "h", "Alarm", night, dict(off, mute_until=night + 3600)) == (True, "ok"), "KATASTROPHE immer"
        assert _au_offer("INFO", "X", "a", "t", noon, on) == (True, "ok") and _au_offer("INFO", "X", "a", "t", noon + 60, on) == (False, "schon gesagt (6 h)")
        assert _au_offer("INFO", "X", "a", "t", noon + AU_DEDUP_S + 1, on) == (True, "ok")
        _AU["sent"] = [(noon, "INFO"), (noon, "INFO")]
        assert _au_offer("INFO", "X", "b", "t", noon + 10, on) == (False, "Budget 2/h erreicht") and _au_offer("WARNUNG", "X", "b", "t", noon + 10, on) == (True, "ok")
        assert _au_offer("FOO", "X", "b", "t", noon, on)[0] is False and _au_offer("INFO", "X", "c", "  ", noon, on) == (False, "leer")
        assert len(_au_offer("WARNUNG", "X", "long", "w " * 400, noon, on) and _AU["q"][-1]["text"]) == 200
        # Reihenfolge / Verfall / volle Warteschlange
        _AU.update(q=[], seen={}, sent=[])
        _au_offer("INFO", "A", "1", "i", noon, on)
        _au_offer("WARNUNG", "A", "2", "w", noon + 1, on)
        _au_offer("KATASTROPHE", "teil4", "3", "k", noon + 2)
        assert [_au_pick(noon + 3)["lvl"] for _ in range(3)] == ["KATASTROPHE", "WARNUNG", "INFO"] and _au_pick(noon) is None
        _au_offer("INFO", "A", "4", "i", noon, on)
        assert _au_pick(noon + 1801) is None and _AU["drop"].get("INFO") == 1, "INFO verfaellt nach 30 min"
        _AU.update(q=[], seen={}, sent=[])
        for i in range(AU_QMAX):
            _au_offer("WARNUNG", "A", "w%d" % i, "w", noon, on, force=True)
        assert _au_offer("INFO", "A", "x", "i", noon, on, force=True) == (False, "Warteschlange voll")
        assert _au_offer("KATASTROPHE", "teil4", "k", "k", noon) == (True, "ok") and len(_AU["q"]) == AU_QMAX and _AU["q"][-1]["lvl"] == "KATASTROPHE"
        # Ausgabewege: pulse belegt -> default Fehler -> plughw ok; danach plughw zuerst
        calls, vols = [], []
        spawn_rc = {"pulse": (1, b"Device or resource busy"), "default": (1, b"no such device")}

        def fspawn(argv, env):
            calls.append((argv[0], argv[3] if argv[0] == "aplay" else None, bool(env)))
            if argv[0] == "aplay":
                rc, err = spawn_rc.get(argv[3], (0, b""))
                return _AuFakeP(rc, err)
            return _AuFakeP(0)
        _AU.update(fake={"spawn": fspawn, "devs": lambda: [("pulse", {"PULSE_SERVER": "x"}), ("default", {}), ("plughw:CARD=Headphones,DEV=0", {})],
                         "vol": lambda pct=None: vols.append(pct) or (100 if pct is None else True), "which": lambda n: "/usr/bin/" + n}, dev_ok=None,
                   tones={n: {"path": "/x/%s.wav" % n, "sha16": "-"} for n in AU_TONES})
        ok, d = _au_play("/x/klick.wav", 5)
        assert ok and d == "plughw:CARD=Headphones,DEV=0" and [c[1] for c in calls] == ["pulse", "default", "plughw:CARD=Headphones,DEV=0"] and calls[0][2], calls
        del calls[:]
        assert _au_play("/x/klick.wav", 5)[0] and [c[1] for c in calls] == ["plughw:CARD=Headphones,DEV=0"], calls
        spawn_rc["plughw:CARD=Headphones,DEV=0"] = (1, b"busy")
        _AU["dev_ok"] = None
        ok, d = _au_play("/x/klick.wav", 5)
        assert not ok and "pulse: rc 1 Device or resource busy" in d, d
        del spawn_rc["plughw:CARD=Headphones,DEV=0"]
        # Zeitlimit: haengendes aplay wird beendet
        _AU["fake"]["spawn"] = lambda argv, env: _AuFakeP(None)
        t0 = _au_time.time()
        assert _au_wait(_au_spawn(["aplay", "x"]), 0.2) == (False, "Zeitlimit 0 s") and _au_time.time() - t0 < 2
        _AU["fake"]["spawn"] = fspawn
        try:
            _au_spawn(["rm", "-rf", "/"])
            raise AssertionError("Programm-Liste")
        except RuntimeError:
            pass
        # Ausgabe: KATASTROPHE 100 % -> zurueck auf Benutzerwert; INFO/WARNUNG ohne Lautstaerke-Aenderung
        del calls[:], vols[:]
        _AU.update(cur=None, dev_ok="plughw:CARD=Headphones,DEV=0")
        st = _au_out({"lvl": "KATASTROPHE", "src": "teil4", "key": "h", "text": "Amtliche Warnung", "t": noon, "exp": noon + 60})
        u = _au_cfg().get("vol", AU_VOL_DEFAULT)
        assert vols == [100, u] and [c[0] for c in calls] == ["aplay", "espeak-ng", "aplay", "aplay"] and not _AU["kat_on"] and _AU["kat_end"] > 0, (vols, calls, st)
        del calls[:], vols[:]
        _au_out({"lvl": "WARNUNG", "src": "DWD", "key": "k", "text": "Unwetter", "t": noon, "exp": noon + 60})
        assert vols == [] and calls[0][1] and [c[0] for c in calls] == ["aplay", "espeak-ng", "aplay", "aplay"], (vols, calls)
        # Abbruch: Vorrang KATASTROPHE beendet laufende INFO
        _AU["cur"] = {"lvl": "INFO"}
        hang = _AuFakeP(None)
        _AU["proc"] = hang
        _au_offer("KATASTROPHE", "teil4", "z", "k", noon)
        assert _AU["abort"] and hang.poll() == -15
        _AU.update(cur=None, abort=False, q=[])
        # Waechter
        _AU.update(kat_on=False, kat_end=noon)
        del vols[:]
        assert _au_watch(noon + 30, dict(on, vol=60)) is None and vols == [], "innerhalb 60 s nach KATASTROPHE nichts"
        assert "-> 60 %" in _au_watch(noon + 61, dict(on, vol=60)) and vols == [None, 60]
        _AU["kat_on"] = True
        assert _au_watch(noon + 999, dict(on, vol=60)) is None
        _AU["kat_on"] = False
        assert _au_watch(noon + 999, dict(on, vol=100)) is None
        # Quellen
        _AU.update(q=[], seen={}, sent=[])
        brh = {"state": "rot", "geo_hold": True, "geo_hint": {"lvl": "WARNUNG", "text": "x"}}
        assert _au_collect(noon, brh, {}, {}, on) == [], "Halt ohne Bestaetigung: kein Ton"
        assert _au_collect(noon, {"geo_hint": {"lvl": "INFO", "text": "Gaza"}}, {}, {}, off) == [], "alles AUS"
        ds = {"dwd_warn": {"value": {"items": [{"level": 4, "cell": "c", "event": "ORKAN", "headline": "Unwetterwarnung vor ORKANBOEEN", "start": "s"}, {"level": 2, "event": "WIND", "headline": "Windboeen"}]}},
              "nina": {"value": [{"id": "n1", "title": "Bombenfund"}, {"id": "n2", "title": "Probewarnung"}, {"id": "n3", "title": "Gefahr"}, {"id": "n4", "title": "Hinweis"}, {"id": "n5", "title": "Aufhebung", "msgType": "Cancel"}]}}
        nd = {"n1": {"severity": "Severe", "status": "Actual"}, "n3": {"severity": "Moderate", "status": "Actual"}, "n4": {"severity": "Minor", "status": "Actual"}}
        r = _au_collect(noon, {"geo_hint": {"lvl": "INFO", "text": "Gaza: Klinik"}}, ds, nd, on)
        assert [(x[0], x[1], x[4]) for x in r] == [("INFO", "BR24", "ok"), ("WARNUNG", "DWD", "ok"), ("INFO", "DWD", "Budget 2/h erreicht") if False else ("INFO", "DWD", "ok"),
                                                   ("WARNUNG", "NINA", "ok"), ("INFO", "NINA", "ok")], r
        assert all(x["lvl"] != "KATASTROPHE" for x in _AU["q"]), "DWD 4 / NINA nie KATASTROPHE"
        assert [x[4] for x in _au_collect(noon + 5, {"geo_hint": {"lvl": "INFO", "text": "Gaza: Klinik"}}, ds, nd, on)] == ["schon gesagt (6 h)"] * 5
        # teil4-Anschluss
        seen = []
        _AU["t4_prev"] = {"cascade": lambda t, h: seen.append(("alt", t)), "kill": lambda w: seen.append(("kill", w)) or 0}
        _AU.update(started=False, q=[])
        _au_t4_cascade("Warnung", "h1")
        assert seen == [("alt", "Warnung")] and not _AU["q"]
        _AU["started"] = True
        _au_t4_cascade("Warnung B R 24. Amtliche Warnung", "h2")
        assert _AU["q"][0]["lvl"] == "KATASTROPHE" and _AU["q"][0]["key"] == "h2" and len(seen) == 1
        _AU["q"].append({"lvl": "INFO", "src": "A", "key": "i", "text": "i", "t": noon, "exp": 4e9})
        _au_t4_kill_all("Entwarnung")
        assert seen[-1] == ("kill", "Entwarnung") and [x["lvl"] for x in _AU["q"]] == ["INFO"]
    finally:
        _AU.clear()
        _AU.update(keep)
        if t4a is not None:
            t4["audio"].clear()
            t4["audio"].update(t4a)
        _au_shutil.rmtree(tmpd, ignore_errors=True)
    return "audioKern ok (Toene klick/gong/rausch deterministisch; Stufen KATASTROPHE>WARNUNG>INFO, KATASTROPHE immer 100 %% dann Benutzerwert, Waechter %d s; INFO/WARNUNG Standard AUS, Nachtruhe 22-07, stumm max %d h, 6 h Dublettenschutz, Budget INFO %d/h WARNUNG %d/h; Ausgabeweg pulse>default>plughw mit Zeitlimit; geoRelevanz-Halt ohne Ton; Test nie Mesh)" % (
        AU_WD_S, AU_MUTE_MAX_H, AU_BUDGET_H["INFO"], AU_BUDGET_H["WARNUNG"])


def _au_install():
    g = globals()
    for k, key, fn in (("_t4_cascade", "cascade", _au_t4_cascade), ("_t4_kill_all", "kill", _au_t4_kill_all)):
        if not callable(g.get(k)):
            raise RuntimeError("%s fehlt (teil4)" % k)
        if not getattr(g[k], "_au", False):
            fn._au = True
            _AU["t4_prev"][key] = g[k]
            g[k] = fn
    for rule, ep, fn, m in (("/api/audio/status", "au_status", _au_api_status, "GET"), ("/api/audio/cfg", "au_cfg", _au_api_cfg, "POST"), ("/api/audio/test", "au_test", _au_api_test, "POST")):
        if ep not in app.view_functions and not any(r.rule == rule for r in app.url_map.iter_rules()):
            app.add_url_rule(rule, endpoint=ep, view_func=fn, methods=[m])


try:
    _AU_ST = _selftest_audiokern()
    _au_install()
    _AU["aktiv"] = True
    if __name__ == "__main__" and not _AU["started"]:
        _AU["started"] = True
        _au_th.Thread(target=_au_worker, name="audioOut", daemon=True).start()
except Exception as _au_e:
    _AU_ST = None
    _AU["err"] = "%s: %s" % (type(_au_e).__name__, _au_e)
    print("audioKern Selbsttest FEHLER (%s: %s) - Audio wie bisher (teil4)" % (type(_au_e).__name__, str(_au_e)[:300]), flush=True)
if _AU_ST:
    c0 = _au_cfg()
    print("audioKern aktiv: %s; Einstellung: INFO %s, WARNUNG %s, Lautstaerke %s %%; Programme %s" % (_AU_ST, "an" if c0["info"] else "aus", "an" if c0["warn"] else "aus", c0["vol"],
                                                                                                 ", ".join("%s %s" % (x, "da" if _au_which(x) else "FEHLT") for x in AU_EXE)), flush=True)
# ===== /audioKern =====
MK_C49_RAB_EOF
EXPECT_RAG="a282da12c30ecea924f772bf6361e4556bf193a07120c298c95626388a29671b"
cat > "$W/guard.py" << 'MK_C49_RAG_EOF'
"""Guard audioKern (commit49). dashboard.py: genau ein Block vor __main__, keine geaenderten Zeilen.
  guard_au.py revert NEU_VERZ ALT_VERZ BLOCK   -> ALT_VERZ/dashboard.py = NEU ohne Block (byte-genau)
  guard_au.py check  ALT NEU BLOCK             -> Rueckbau = ALT, statische Regeln, Verhaltenstests (eigene Erwartungen, gefaelschte Prozesse, kein Ton, kein Netz)
  guard_au.py mutate ALT NEU BLOCK             -> Mutationstest (jede Mutation muss check scheitern lassen)
Braucht flask im ausfuehrenden Python (venv)."""
import ast, io, json, os, shutil, subprocess, sys, tempfile, time

ANCH = '\n\nif __name__ == "__main__":\n'
M0, M1 = "# ===== audioKern:", "# ===== /audioKern ====="
TRAIL = "\n\ntry:\n    _AU_ST = _selftest_audiokern()"
OK_IMPORTS = {"hashlib", "json", "math", "os", "re", "shutil", "struct", "subprocess", "tempfile", "threading", "time", "wave", "io", "flask"}
FORBID = {"send_meshtastic", "send_dab_to_private_mesh", "send_nina_to_bayern", "_t4_send_m1", "_lz_mesh", "dab_private_send", "auto_send", "takeover_auto", "set_auto",
          "requests", "urllib", "socket", "system", "popen", "check_output", "call", "run", "eval", "exec", "__import__", "rmtree_all", "unlink", "rename", "chmod", "kill", "killpg"}
WRITE_FUNCS = {"_au_tones_ensure", "_au_cfg_save", "_selftest_audiokern"}


def rd(p):
    return open(p, encoding="utf-8").read()


def blk_text(bp):
    return rd(bp).rstrip("\n") + "\n"


def revert(neu, bp):
    B = blk_text(bp)
    assert neu.count(M0) == 1 and neu.count(M1) == 1, "Marker nicht genau einmal"
    assert neu.count("\n\n" + B.rstrip("\n") + ANCH) == 1, "Block nicht genau einmal unmittelbar vor __main__"
    return neu.replace("\n\n" + B.rstrip("\n") + ANCH, ANCH, 1)


def fail(m):
    print("VERSTOSS:", m)
    sys.exit(1)


def static(B):
    t = ast.parse(B)
    funcs = {n.name: n for n in t.body if isinstance(n, ast.FunctionDef)}
    for node in ast.walk(t):
        if isinstance(node, ast.Name) and node.id in FORBID:
            fail("verbotener Name %s" % node.id)
        if isinstance(node, ast.Attribute) and node.attr in FORBID:
            fail("verbotenes Attribut .%s" % node.attr)
        if isinstance(node, ast.keyword) and node.arg == "shell":
            fail("shell=")
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            for m in ([a.name for a in node.names] if isinstance(node, ast.Import) else [node.module]):
                if m not in OK_IMPORTS:
                    fail("Import %s" % m)
        if isinstance(node, ast.Global):
            fail("global-Anweisung")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "print":
            a0 = node.args[0] if node.args else None
            s = a0.left.value if isinstance(a0, ast.BinOp) and isinstance(a0.left, ast.Constant) else (a0.value if isinstance(a0, ast.Constant) else "")
            if not str(s).startswith("audioKern"):
                fail("print ohne Praefix audioKern: %r" % str(s)[:40])
    # Schreiben/Umbenennen/Loeschen nur in erlaubten Funktionen
    for fn, node in funcs.items():
        for c in ast.walk(node):
            if not isinstance(c, ast.Call):
                continue
            f = c.func
            name = f.attr if isinstance(f, ast.Attribute) else (f.id if isinstance(f, ast.Name) else "")
            if isinstance(f, ast.Name) and name == "open" and (len(c.args) > 1 and isinstance(c.args[1], ast.Constant) and c.args[1].value != "rb" or any(k.arg == "mode" for k in c.keywords)):
                if fn not in WRITE_FUNCS:
                    fail("Schreiben in %s" % fn)
            if name in ("replace",) and isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "_au_os" and fn not in ("_au_tones_ensure", "_au_cfg_save"):
                fail("os.replace in %s" % fn)
            if name in ("remove", "makedirs", "rmtree") and isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id in ("_au_os", "_au_shutil") and fn not in ("_au_out", "_au_tones_ensure", "_selftest_audiokern"):
                fail("%s in %s" % (name, fn))
            if name == "Popen" and fn != "_au_spawn":
                fail("Popen ausserhalb _au_spawn")
            if name == "Thread" and fn != "<modul>":
                fail("Thread in %s" % fn)
    pop = [c for c in ast.walk(funcs["_au_spawn"]) if isinstance(c, ast.Call) and getattr(c.func, "attr", "") == "Popen"]
    if len(pop) != 1 or not isinstance(pop[0].args[0], ast.BinOp):
        fail("Popen nicht genau einmal mit Liste [exe] + argv")
    src_sp = ast.get_source_segment(B, funcs["_au_spawn"])
    if 'if not argv or argv[0] not in AU_EXE[1:]:' not in src_sp:
        fail("Programm-Liste in _au_spawn")
    if B.count('AU_EXE = ("amixer", "aplay", "espeak-ng")') != 1:
        fail("Programm-Liste geaendert")
    for s in ('AU_NIGHT = (22, 7)', 'AU_MUTE_MAX_H = 8', 'AU_WD_S = 60', 'AU_QMAX = 10', 'AU_VOL_DEFAULT = 80', 'AU_DEDUP_S = 6 * 3600', 'AU_BUDGET_H = {"INFO": 2, "WARNUNG": 4}',
              'AU_PRIO = {"KATASTROPHE": 3, "WARNUNG": 2, "INFO": 1}', 'AU_EXPIRE_S = {"INFO": 1800, "WARNUNG": 7200, "KATASTROPHE": 3600}', 'AU_TEST_GAP_S = 10',
              'AU_TXT_MAX = {"INFO": 200, "WARNUNG": 200, "KATASTROPHE": 600}',
              '    return {"info": False, "warn": False, "vol": AU_VOL_DEFAULT, "mute_until": 0, "t": None, "by": None}',
              'for k, key, fn in (("_t4_cascade", "cascade", _au_t4_cascade), ("_t4_kill_all", "kill", _au_t4_kill_all)):',
              '(("/api/audio/status", "au_status", _au_api_status, "GET"), ("/api/audio/cfg", "au_cfg", _au_api_cfg, "POST"), ("/api/audio/test", "au_test", _au_api_test, "POST"))',
              '    if __name__ == "__main__" and not _AU["started"]:\n        _AU["started"] = True\n        _au_th.Thread(target=_au_worker, name="audioOut", daemon=True).start()'):
        if B.count(s) != 1:
            fail("Regel/Konstante geaendert: %s" % s[:70])
    ng = 0
    for node in ast.walk(t):
        if isinstance(node, ast.Assign):
            for x in node.targets:
                if isinstance(x, ast.Subscript) and isinstance(x.value, ast.Name) and x.value.id == "g":
                    ng += 1
                if isinstance(x, ast.Subscript) and isinstance(x.value, ast.Call) and getattr(x.value.func, "id", "") == "globals":
                    fail("globals()-Zuweisung")
    if ng != 1:
        fail("weitere globale Umverdrahtung")
    for node in t.body:
        if isinstance(node, ast.Assign):
            for x in node.targets:
                if isinstance(x, ast.Name) and not (x.id.startswith("AU_") or x.id.startswith("_AU") or x.id.startswith("_au")):
                    fail("Zuweisung ausserhalb Namensraum: %s" % x.id)
        elif isinstance(node, (ast.FunctionDef, ast.ClassDef)) and not (node.name.startswith("_au") or node.name.startswith("_Au") or node.name == "_selftest_audiokern"):
            fail("Name ausserhalb Namensraum: %s" % node.name)


class P:
    def __init__(self, rc, err=b""):
        self._rc, self.rc, self.pid, self.stderr = rc, None, 1, io.BytesIO(err)

    def poll(self):
        if self.rc is None and self._rc is not None:
            self.rc = self._rc
        return self.rc

    def terminate(self):
        self.rc = -15


def load(B, tmp):
    from flask import Flask
    app = Flask("auguard")
    seen = []
    T4 = {"audio": {"busy": False, "abort": False, "procs": [], "last": None}}
    g = {"__name__": "auguard", "_SDR_BASE": tmp, "app": app, "_T4": T4, "data_store": {}, "_T2D": {"nina": {}},
         "_t4_static": lambda: os.path.join(tmp, "static"), "_t4_card": lambda: {"idx": 2, "id": "Headphones", "dev": "plughw:CARD=Headphones,DEV=0"},
         "_t4_ctl": lambda c: "PCM", "_t4_vol": lambda c, ctl, pct=None: True,
         "_t4_cascade": lambda t, h: seen.append(("alt", t)), "_t4_kill_all": lambda w: seen.append(("kill", w, g["_AU"]["abort"])) or 0}
    exec(compile(B[:B.index(TRAIL)], "au-block", "exec"), g)
    return g, app, seen, T4


def behav(B):
    tmp = tempfile.mkdtemp()
    try:
        g, app, seen, T4 = load(B, tmp)
        AU, offer = g["_AU"], g["_au_offer"]
        AU["quiet"] = True
        lt = list(time.localtime())
        mk = lambda h, m=0: time.mktime(tuple(lt[:3] + [h, m, 0] + lt[6:8] + [-1]))
        noon, n2159, n2200, n0659, n0700 = mk(12), mk(21, 59), mk(22), mk(6, 59), mk(7)
        on = {"info": True, "warn": True, "vol": 70, "mute_until": 0}
        off = {"info": False, "warn": False, "vol": 70, "mute_until": 0}
        def reset():
            AU.update(q=[], seen={}, sent=[], cur=None, abort=False)
        # Tabelle: (Stufe, Zeit, cfg, erwartet ok)
        TAB = [("INFO", noon, off, False), ("WARNUNG", noon, off, False), ("INFO", noon, dict(off, info=True), True), ("WARNUNG", noon, dict(off, info=True), False),
               ("WARNUNG", noon, dict(off, warn=True), True), ("INFO", n2159, on, True), ("INFO", n2200, on, False), ("WARNUNG", n0659, on, False), ("WARNUNG", n0700, on, True),
               ("KATASTROPHE", n2200, off, True), ("KATASTROPHE", noon, dict(off, mute_until=noon + 3600), True), ("WARNUNG", noon, dict(on, mute_until=noon + 3600), False),
               ("WARNUNG", noon, dict(on, mute_until=noon + 8 * 3600), False), ("WARNUNG", noon, dict(on, mute_until=noon + 8 * 3600 + 3600), True), ("WARNUNG", noon, dict(on, mute_until=noon - 5), True)]
        for i, (lvl, t, c, exp) in enumerate(TAB):
            reset()
            r = offer(lvl, "S", "k%d" % i, "Text", t, c)
            assert r[0] is exp, (i, lvl, r)
        reset()
        assert offer("INFO", "S", "a", "x", noon, on)[0] and not offer("INFO", "S", "a", "x", noon + 6 * 3600 - 5, on)[0] and offer("INFO", "S", "a", "x", noon + 6 * 3600 + 5, on)[0]
        assert offer("INFO", "T", "a", "x", noon, on)[0], "andere Quelle = eigener Schluessel"
        reset()
        res = [offer("INFO", "S", "i%d" % i, "x", noon + i, on)[0] for i in range(3)]
        AU["sent"] = [(noon, "INFO")] * 2
        assert not offer("INFO", "S", "i9", "x", noon + 10, on)[0]
        AU["sent"] = [(noon, "WARNUNG")] * 4
        assert not offer("WARNUNG", "S", "w9", "x", noon + 10, on)[0] and offer("WARNUNG", "S", "w9", "x", noon + 3601, on)[0], "Budget WARNUNG 4/h"
        AU["sent"] = [(noon, "WARNUNG")] * 3
        assert offer("WARNUNG", "S", "w8", "x", noon + 10, on)[0]
        reset()
        offer("INFO", "S", "1", "x" * 300, noon, on)
        offer("KATASTROPHE", "t", "2", "y" * 900, noon)
        assert [len(x["text"]) for x in AU["q"]] == [200, 600]
        reset()
        offer("WARNUNG", "S", "1", "w", noon, on)
        offer("INFO", "S", "2", "i", noon - 5, on)
        offer("KATASTROPHE", "t", "3", "k", noon + 9)
        offer("WARNUNG", "S", "4", "w", noon - 1, on)
        assert [(x["lvl"], x["key"]) for x in [g["_au_pick"](noon + 10) for _ in range(4)]] == [("KATASTROPHE", "3"), ("WARNUNG", "4"), ("WARNUNG", "1"), ("INFO", "2")]
        reset()
        offer("INFO", "S", "1", "i", noon, on)
        offer("WARNUNG", "S", "2", "w", noon, on)
        assert g["_au_pick"](noon + 1801)["lvl"] == "WARNUNG" and g["_au_pick"](noon) is None
        reset()
        offer("WARNUNG", "S", "2", "w", noon, on)
        assert g["_au_pick"](noon + 7201) is None
        reset()
        for i in range(10):
            offer("INFO", "S", "q%d" % i, "i", noon + i, on, force=True)
        assert offer("WARNUNG", "S", "x", "w", noon + 20, on, force=True)[0] and len(AU["q"]) == 10 and "q0" not in [x["key"] for x in AU["q"]]
        reset()
        for i in range(10):
            offer("WARNUNG", "S", "v%d" % i, "w", noon + i, on, force=True)
        assert offer("INFO", "S", "y", "i", noon + 20, on, force=True) == (False, "Warteschlange voll") and all(x["lvl"] == "WARNUNG" for x in AU["q"])
        # Prozesse / Ausgabewege
        calls, vols = [], []
        rc = {"pulse": (1, b"Device or resource busy"), "default": (1, b"x")}
        def sp(argv, env):
            calls.append((argv[0], argv[3] if argv[0] == "aplay" else argv[argv.index("-a") + 1], dict(env or {})))
            return P(*rc.get(argv[3], (0, b""))) if argv[0] == "aplay" else P(0)
        AU.update(fake={"spawn": sp, "devs": lambda: [("pulse", {"PULSE_SERVER": "u"}), ("default", {}), ("plughw:CARD=Headphones,DEV=0", {})],
                        "vol": lambda pct=None: vols.append(pct) or (100 if pct is None else True), "which": lambda n: n}, dev_ok=None)
        ok, d = g["_au_play"]("/x.wav", 5)
        assert ok and [c[1] for c in calls] == ["pulse", "default", "plughw:CARD=Headphones,DEV=0"] and calls[0][2] == {"PULSE_SERVER": "u"} and AU["dev_ok"] == d
        del calls[:]
        g["_au_play"]("/x.wav", 5)
        assert [c[1] for c in calls] == ["plughw:CARD=Headphones,DEV=0"]
        hung = []
        AU["fake"]["spawn"] = lambda argv, env: hung.append(argv) or P(None)
        AU["dev_ok"] = None
        t0 = time.time()
        assert g["_au_play"]("/x.wav", 0.3)[0] is False and time.time() - t0 < 1.5 and len(hung) == 1, "Zeitlimit beendet und kein weiterer Weg"
        AU["abort"] = True
        del hung[:]
        assert g["_au_play"]("/x.wav", 5) == (False, "abgebrochen") and hung == []
        AU.update(abort=False, dev_ok="plughw:CARD=Headphones,DEV=0")
        AU["fake"]["spawn"] = sp
        for bad in (["sh", "-c", "x"], ["amixer", "x"], []):
            try:
                g["_au_spawn"](bad)
                raise AssertionError("erlaubt: %s" % bad)
            except RuntimeError:
                pass
        g["_au_tones_ensure"]()
        tn = AU["tones"]
        assert set(tn) == {"klick", "gong", "rausch"} and all(x["neu"] for x in tn.values()) and all(os.path.isfile(x["path"]) for x in tn.values())
        ino = {n: os.stat(x["path"]).st_ino for n, x in tn.items()}
        assert not any(x["neu"] for x in g["_au_tones_ensure"]().values()), "zweiter Lauf schreibt nicht"
        assert ino == {n: os.stat(x["path"]).st_ino for n, x in tn.items()}, "zweiter Lauf ersetzt keine Datei"
        import hashlib
        assert hashlib.sha256(open(tn["rausch"]["path"], "rb").read()).hexdigest()[:16] == "11f9a5cfb74ea579", "Rausch-Schwanz (nur Ganzzahl/IEEE-Grundrechnung, plattformgleich)"
        for n, sec in (("klick", 0.19), ("gong", 1.0), ("rausch", 0.35)):
            b = open(tn[n]["path"], "rb").read()
            assert abs((len(b) - 44) / 2 / 22050 - sec) < 0.01 and b == g["_au_tone_bytes"](n)
        # Ausgabe
        AU["tones"] = tn
        del calls[:], vols[:]
        g["_au_cfg_save"](dict(on, vol=55))
        busy = []
        AU["fake"]["spawn"] = lambda argv, env: (busy.append(T4["audio"]["busy"]), sp(argv, env))[1]
        g["_au_out"]({"lvl": "KATASTROPHE", "src": "teil4", "key": "h", "text": "A", "t": noon, "exp": noon + 99})
        AU["fake"]["spawn"] = sp
        assert busy and all(busy), "teil4 sieht busy waehrend KATASTROPHE"
        assert vols == [100, 55], vols
        assert [c[0] for c in calls] == ["aplay", "espeak-ng", "aplay", "aplay"] and calls[0][1] != tn["rausch"]["path"] and calls[1][1] == "100", calls
        assert T4["audio"]["busy"] is False and T4["audio"]["last"]["text"] == "A" and AU["kat_on"] is False and AU["kat_end"] > 0
        assert any(isinstance(p, P) for p in T4["audio"]["procs"]), "teil4-Kill-Switch sieht die Prozesse"
        del calls[:], vols[:]
        sp_args = []
        AU["fake"]["spawn"] = lambda argv, env: (sp_args.append(list(argv)), sp(argv, env))[1]
        g["_au_out"]({"lvl": "WARNUNG", "src": "DWD", "key": "k", "text": "W", "t": noon, "exp": noon + 99})
        assert vols == [] and sp_args[0][-1] == tn["gong"]["path"] and sp_args[1][sp_args[1].index("-a") + 1] == "80" and sp_args[-1][-1] == tn["rausch"]["path"], sp_args
        del sp_args[:]
        g["_au_out"]({"lvl": "INFO", "src": "BR24", "key": "k", "text": "I", "t": noon, "exp": noon + 99})
        assert vols == [] and sp_args[0][-1] == tn["klick"]["path"]
        AU["fake"]["spawn"] = sp
        # Vorrang
        AU["cur"] = {"lvl": "WARNUNG"}
        hp = P(None)
        AU["proc"] = hp
        offer("INFO", "S", "z", "i", noon, on, force=True)
        assert not AU["abort"] and hp.poll() is None
        offer("KATASTROPHE", "t", "z", "k", noon)
        assert AU["abort"] and hp.poll() == -15
        AU.update(cur={"lvl": "KATASTROPHE"}, abort=False, proc=P(None))
        offer("KATASTROPHE", "t", "z2", "k", noon)
        assert not AU["abort"], "KATASTROPHE bricht KATASTROPHE nicht ab"
        AU.update(cur=None, proc=None)
        # Waechter
        reset()
        del vols[:]
        AU.update(kat_on=False, kat_end=noon)
        assert g["_au_watch"](noon + 59, dict(on, vol=40)) is None and vols == []
        assert g["_au_watch"](noon + 61, dict(on, vol=40)) and vols == [None, 40]
        del vols[:]
        AU["fake"]["vol"] = lambda pct=None: vols.append(pct) or (70 if pct is None else True)
        assert g["_au_watch"](noon + 999, dict(on, vol=40)) is None and vols == [None], "nur bei 100 %"
        AU["fake"]["vol"] = lambda pct=None: vols.append(pct) or (100 if pct is None else True)
        AU["kat_on"] = True
        del vols[:]
        assert g["_au_watch"](noon + 999, dict(on, vol=40)) is None and vols == [], "nie waehrend KATASTROPHE"
        AU["kat_on"] = False
        # Quellen
        reset()
        assert g["_au_collect"](noon, {"state": "rot", "geo_hold": True, "geo_hint": {"lvl": "INFO", "text": "x"}}, {}, {}, on) == []
        assert g["_au_collect"](noon, {"geo_hint": {"lvl": "INFO", "text": "x"}}, {}, {}, off) == []
        ds = {"dwd_warn": {"value": {"items": [{"level": 4, "event": "E", "headline": "H"}, {"level": 3, "event": "E3"}, {"level": 1, "event": "E1"}, {"level": 0}]}},
              "nina": {"value": [{"id": "a", "title": "Gefahr"}, {"id": "b", "title": "Gefahr"}, {"id": "c", "title": "Probealarm"}, {"id": "d", "title": "Gefahr", "msgType": "Cancel"},
                                 {"id": "e", "title": "Info"}, {"id": "f", "title": "Uebung"}, {"id": "g", "title": "Gefahr"}]}}
        nd = {"a": {"severity": "Extreme", "status": "Actual"}, "b": {"severity": "Moderate", "status": "Actual"}, "e": {"severity": "Minor"}, "g": {"severity": "Moderate", "status": "Exercise"}}
        r = g["_au_collect"](noon, {"state": "gruen", "geo_hint": {"lvl": "WARNUNG", "text": "AKW"}}, ds, nd, dict(on))
        assert [(x[0], x[1]) for x in r] == [("WARNUNG", "BR24"), ("WARNUNG", "DWD"), ("WARNUNG", "DWD"), ("INFO", "DWD"), ("WARNUNG", "NINA"), ("INFO", "NINA")], r
        assert all(x["lvl"] != "KATASTROPHE" for x in AU["q"])
        # teil4
        AU.update(started=False, q=[], t4_prev={})
        g["_au_install"]()
        g["_au_install"]()
        assert g["_t4_cascade"] is g["_au_t4_cascade"] and g["_t4_kill_all"] is g["_au_t4_kill_all"] and not getattr(AU["t4_prev"]["cascade"], "_au", False)
        g["_t4_cascade"]("x", "h0")
        assert seen == [("alt", "x")] and not AU["q"]
        AU["started"] = True
        g["_t4_cascade"]("Warnung", "h1")
        assert AU["q"][0]["lvl"] == "KATASTROPHE" and AU["q"][0]["text"] == "Warnung"
        AU["cur"] = {"lvl": "KATASTROPHE"}
        AU["proc"] = P(None)
        g["_t4_kill_all"]("Entwarnung")
        assert seen[-1] == ("kill", "Entwarnung", True) and not AU["q"] and AU["proc"].poll() == -15
        AU.update(cur=None, proc=None, abort=False)
        rules = {r.rule: sorted(r.methods - {"HEAD", "OPTIONS"}) for r in app.url_map.iter_rules() if r.rule.startswith("/api/audio")}
        assert rules == {"/api/audio/status": ["GET"], "/api/audio/cfg": ["POST"], "/api/audio/test": ["POST"]}, rules
        cl = app.test_client()
        cf = os.path.join(tmp, "audio_cfg.json")
        for body, code in (({"info": True}, 200), ({"info": "ja"}, 400), ({"vol": 101}, 400), ({"vol": True}, 400), ({"mute_h": 9}, 400), ({"mute_h": 8}, 200), ({"x": 1}, 400), ({}, 400), ({"vol": 30, "warn": True}, 200)):
            r = cl.post("/api/audio/cfg", json=body)
            assert r.status_code == code, (body, r.status_code)
        c = json.load(open(cf))
        assert c["info"] is True and c["warn"] is True and c["vol"] == 30 and 0 < c["mute_until"] - time.time() <= 8 * 3600 + 5
        assert cl.post("/api/audio/cfg", json={"mute_h": 0}).get_json()["cfg"]["mute_until"] == 0
        AU.update(q=[], test_t=0, started=False)
        assert cl.post("/api/audio/test", json={"art": "info"}).status_code == 503
        AU["started"] = True
        assert cl.post("/api/audio/test", json={"art": "katastrophe"}).status_code == 400
        r = cl.post("/api/audio/test", json={"art": "warnung"})
        assert r.status_code == 202 and r.get_json()["mesh"] is False and AU["q"][-1]["lvl"] == "WARNUNG" and AU["q"][-1]["test"]
        assert cl.post("/api/audio/test", json={"art": "info"}).status_code == 429
        s = cl.get("/api/audio/status").get_json()
        assert s["cfg"]["vol"] == 30 and s["regeln"]["stumm_max_h"] == 8 and "q" in s
        return True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check(alt, neu, bp):
    B = blk_text(bp)
    try:
        r = revert(neu, bp)
    except AssertionError as e:
        fail(str(e))
    if r != alt:
        fail("Rueckbau != Basis (Aenderung ausserhalb des Blocks)")
    if not B.startswith(M0) or not B.rstrip("\n").endswith(M1):
        fail("Block beginnt/endet nicht mit Marker")
    try:
        compile(B, "blk", "exec")
    except SyntaxError as e:
        fail("Syntax %s" % e)
    static(B)
    try:
        behav(B)
    except AssertionError as e:
        fail("Verhalten: %s" % str(e)[:300])
    except Exception as e:
        fail("Verhalten (%s): %s" % (type(e).__name__, str(e)[:300]))
    print("Guard audioKern ok: Rueckbau byte-genau = Basis; statisch (nur aplay/espeak-ng ohne Shell, amixer nur ueber teil4, Schreiben nur Toene/audio_cfg.json, kein Mesh/Netz, Faden nur im Hauptprogramm, 2 Umverdrahtungen, 3 Routen); "
          "Verhalten: 15 Regel-Faelle (Schalter/Nachtruhe/Stumm 8 h/KATASTROPHE immer), Dubletten/Budget/Laenge/Reihenfolge/Verfall/volle Schlange, Ausgabewege pulse>default>plughw + Zeitlimit, "
          "KATASTROPHE 100 %% -> Benutzerwert, Vorrang, Waechter, Quellen (Halt = kein Ton), teil4-Anschluss + Kill-Switch, APIs cfg 9 Faelle / test")


MUTS = [
    ("AU_NIGHT = (22, 7)", "AU_NIGHT = (23, 7)"), ("AU_MUTE_MAX_H = 8\n", "AU_MUTE_MAX_H = 24\n"), ("AU_WD_S = 60 ", "AU_WD_S = 600 "), ('"vol": AU_VOL_DEFAULT, "mute_until": 0, "t"', '"vol": 100, "mute_until": 0, "t"'),
    ('return {"info": False, "warn": False,', 'return {"info": True, "warn": False,'),
    ('        if lvl != "KATASTROPHE" and not force:', '        if not force:'), ('            if _au_night(now):\n', '            if False:\n'),
    ("    return h >= AU_NIGHT[0] or h < AU_NIGHT[1]", "    return h > AU_NIGHT[0] or h < AU_NIGHT[1]"), ("    return now < mu and mu - now <= AU_MUTE_MAX_H * 3600 + 60", "    return now < mu"),
    ("            if now - _AU[\"seen\"].get(k, -1e12) < AU_DEDUP_S:", "            if False:"), ("            if n_h >= AU_BUDGET_H[lvl]:", "            if n_h > AU_BUDGET_H[lvl]:"),
    ('        k = "%s|%s|%s" % (lvl, src, key)' if False else '            k = "%s|%s|%s" % (lvl, src, key)', '            k = "%s|%s" % (lvl, key)'),
    ('        if lvl == "KATASTROPHE" and cur and cur["lvl"] != "KATASTROPHE":', '        if lvl == "KATASTROPHE" and cur:'),
    ("        it = max(q, key=lambda x: (AU_PRIO[x[\"lvl\"]], -x[\"t\"]))", "        it = max(q, key=lambda x: (AU_PRIO[x[\"lvl\"]], x[\"t\"]))"),
    ('AU_EXPIRE_S = {"INFO": 1800,', 'AU_EXPIRE_S = {"INFO": 7200,'), ("            if AU_PRIO[low[\"lvl\"]] > AU_PRIO[lvl]:", "            if False:"),
    ('    return " ".join(str(t or "").replace("…", " ").split())[:AU_TXT_MAX.get(lvl, 200)]', '    return " ".join(str(t or "").split())[:600]'),
    ("        if why == \"abgebrochen\" or why.startswith(\"Zeitlimit\") or why == \"Programm fehlt\":\n            break\n", ""),
    ("            _AU[\"dev_ok\"] = dev\n", ""), ('    return sorted(devs, key=lambda d: 0 if d[0] == ok else 1)', '    return devs'),
    ('            steps.append("Lautstaerke 100 %%: %s" % ("ok" if _au_vol(100) else "nicht gesetzt"))', '            steps.append("x")'),
    ('            v = c.get("vol", AU_VOL_DEFAULT)\n', '            v = 100\n'), ('"-a", "100" if kat else "80"', '"-a", "100"'),
    ('tone = (_AU["tones"].get("gong" if lvl == "WARNUNG" else "klick") or {}).get("path")', 'tone = (_AU["tones"].get("klick") or {}).get("path")'),
    ("    if _AU[\"kat_on\"] or v >= 100 or now - _AU[\"kat_end\"] < AU_WD_S:", "    if v >= 100 or now - _AU[\"kat_end\"] < AU_WD_S:"),
    ("    if cur is not None and cur >= 100:", "    if cur is not None:"),
    ('    if isinstance(br, dict) and not br.get("geo_hold"):', '    if isinstance(br, dict):'), ('("WARNUNG" if lv >= 3 else "INFO", "DWD"', '("KATASTROPHE" if lv >= 4 else "WARNUNG" if lv >= 3 else "INFO", "DWD"'),
    ('        if sev in ("Severe", "Extreme") or str(d.get("status") or "Actual") != "Actual":', '        if sev in ("Extreme",):'),
    ('_au_re.search(r"(?i)probe|test|warntag|uebung|übung", tt)', '_au_re.search(r"(?i)probe", tt)'), ('or str(w.get("msgType")) == "Cancel":', ':'),
    ("    if not _AU[\"started\"]:\n        return _AU[\"t4_prev\"][\"cascade\"](text, h)\n", ""),
    ('        _AU["q"] = [x for x in _AU["q"] if x["lvl"] != "KATASTROPHE"]\n', ''),
    ("    return _AU[\"t4_prev\"][\"kill\"](why)\n\n\n# ----", "    r = _AU[\"t4_prev\"][\"kill\"](why)\n    return r\n\n\n# ----") if False else
    ("        if _AU[\"cur\"]:\n            _AU[\"abort\"] = True\n            _au_kill_cur()\n    return _AU[\"t4_prev\"][\"kill\"](why)", "    _AU[\"t4_prev\"][\"kill\"](why)\n    with _AU_LOCK:\n        if _AU[\"cur\"]:\n            _AU[\"abort\"] = True\n            _au_kill_cur()\n    return 0"),
    ('        t4["audio"]["procs"].append(p)', '        pass'), ('    if not argv or argv[0] not in AU_EXE[1:]:', '    if not argv:'),
    ('"/api/audio/status", "au_status", _au_api_status, "GET"', '"/api/audio/status", "au_status", _au_api_status, "POST"'),
    ('not 0 <= h <= AU_MUTE_MAX_H:', 'not 0 <= h:'), ('not 0 <= d["vol"] <= 100:\n            return jsonify', 'not 0 <= d["vol"]:\n            return jsonify'),
    ('        if now - _AU["test_t"] < AU_TEST_GAP_S:', '        if False:'), ('AU_TEST_TXT = {"info": ("INFO",', 'AU_TEST_TXT = {"katastrophe": ("KATASTROPHE", "x"), "info": ("INFO",'),
    ('    return jsonify({"ok": ok, "why": why, "mesh": False}), (202 if ok else 409)', '    send_meshtastic(txt)\n    return jsonify({"ok": ok, "why": why, "mesh": False}), (202 if ok else 409)'),
    ("        if not same:\n", "        if True:\n"), ("        y = 0.85 * y + 0.15 * ((x / 1073741823.5) - 1.0)", "        y = 0.5 * y + 0.15 * ((x / 1073741823.5) - 1.0)"),
    ("    n = int(1.0 * AU_SR)\n", "    n = int(1.5 * AU_SR)\n"), ("            fn._au = True\n", ""),
    ('            if isinstance(t4a, dict):\n                t4a.update(busy=True', '            if False:\n                t4a.update(busy=True'),
    ("import time as _au_time\n", "import time as _au_time\nimport socket as _au_so\n"),
    ('    if __name__ == "__main__" and not _AU["started"]:', '    if not _AU["started"]:'),
]


def mutate(altp, neup, bp):
    alt, B = rd(altp), blk_text(bp)
    me = os.path.abspath(__file__)
    d = tempfile.mkdtemp()
    caught = missed = 0
    try:
        def run(n_txt, b_txt):
            open(os.path.join(d, "n.py"), "w", encoding="utf-8").write(n_txt)
            open(os.path.join(d, "b.py"), "w", encoding="utf-8").write(b_txt)
            o = subprocess.run([sys.executable, me, "check", altp, os.path.join(d, "n.py"), os.path.join(d, "b.py")], capture_output=True, text=True, timeout=300)
            return o.returncode != 0, ((o.stdout + o.stderr).strip().splitlines() or [""])[-1:]
        bad, msg = run(rd(neup), B)
        if bad:
            print("FEHLER: unveraenderter Stand faellt durch:", msg)
            sys.exit(1)
        cases = []
        for a, b in MUTS:
            if B.count(a) < 1:
                print("UEBERSEHEN (Mutation passt nicht): %r" % a[:70]); missed += 1; continue
            Bm = B.replace(a, b, 1)
            cases.append(("blk " + a[:50], alt.replace(ANCH, "\n\n" + Bm.rstrip("\n") + ANCH, 1), Bm))
        neu = rd(neup)
        cases.append(("Zeile ausserhalb", neu.replace("T4_SAY_MAX = 600", "T4_SAY_MAX = 601", 1), B))
        cases.append(("Block doppelt", neu.replace(ANCH, "\n\n" + B.rstrip("\n") + ANCH, 1), B))
        for name, n_txt, b_txt in cases:
            bad, msg = run(n_txt, b_txt)
            if bad:
                caught += 1
            else:
                missed += 1
                print("UEBERSEHEN:", name, msg)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print("%s Mutationstest audioKern: %d erkannt, %d uebersehen" % ("OK" if missed == 0 else "FEHLER", caught, missed))
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    m = sys.argv[1]
    if m == "revert":
        neu = rd(os.path.join(sys.argv[2], "dashboard.py"))
        os.makedirs(sys.argv[3], exist_ok=True)
        open(os.path.join(sys.argv[3], "dashboard.py"), "w", encoding="utf-8").write(revert(neu, sys.argv[4]))
        print("Rueckbau audioKern ok")
    elif m == "check":
        check(rd(sys.argv[2]), rd(sys.argv[3]), sys.argv[4])
    elif m == "mutate":
        mutate(*sys.argv[2:5])
MK_C49_RAG_EOF
EMB="patch.py:$EXPECT_PAL edits.py:$EXPECT_RAE blk.py:$EXPECT_RAB guard.py:$EXPECT_RAG"
for x in $EMB; do
  echo "${x#*:}  $W/${x%%:*}" | sha256sum -c - >/dev/null 2>&1 || stop "sha256 der eingebetteten Datei ${x%%:*} falsch (Skript beschaedigt oder veraendert - bitte neu laden)"
done
echo "OK eingebettete Dateien geprueft (4: Patcher, Stellen, Block, Pruefprogramm)"
s16() { sha256sum "$1" | cut -c1-16; }
# ---------- 1) Basis ----------
for x in "$F" "$FL" "$FS"; do [[ -f "$x" ]] || stop "$(basename "$x") fehlt im Projektordner $DASH_DIR"; done
D16=$(s16 "$F"); L16=$(s16 "$FL"); S16=$(s16 "$FS")
SD=UNBEKANNT; [[ "$D16" == "$KNOWN_D16" ]] && SD=alt; [[ "$D16" == "$KNOWN_D16N" ]] && SD=neu
echo "Basis dashboard.py   sha16 $D16 ($(wc -l < "$F") Zeilen) - $SD (alt $KNOWN_D16 nach commit48, neu $KNOWN_D16N)"
echo "Basis lage_pages.py  sha16 $L16 - $([[ "$L16" == "$KNOWN_L16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
echo "Basis prepper_sdr.py sha16 $S16 - $([[ "$S16" == "$KNOWN_S16" ]] && echo "wie erwartet (bleibt unveraendert)" || echo ABWEICHUNG)"
if [[ "$D16" == "$KNOWN_D16_C47" ]]; then
  echo "STOP: erst commit48 anwenden - dashboard.py ist noch der Stand nach commit47 (sha16 $D16), commit49 braucht $KNOWN_D16 (nach commit48) - nichts geaendert."
  echo "      Reihenfolge: bash /tmp/apply-commit48.sh commit48, danach dieses Skript erneut."
  exit 1
fi
if [[ "$SD" == UNBEKANNT ]]; then
  echo "STOP: dashboard.py weicht vom erwarteten Stand ab (sha16 $D16) - nichts geaendert."
  echo "      commit49 passt nur auf den Stand nach commit48. Lokale Aenderung oder ein anderer Patch-Stand? Bitte diese Ausgabe an Grok schicken."
  exit 1
fi
[[ "$L16" == "$KNOWN_L16" ]] || stop "lage_pages.py ist nicht der Stand nach commit48 ($L16 statt $KNOWN_L16)"
[[ "$S16" == "$KNOWN_S16" ]] || stop "prepper_sdr.py ist nicht der Stand nach commit48 ($S16 statt $KNOWN_S16)"
STATE=$SD
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz; do grep -q "# ===== $mk:" "$F" || stop "Vorgaenger-Patch $mk fehlt im Dashboard (Basis)"; done
[[ -w "$DASH_DIR" && -w "$F" ]] || stop "Projektordner oder dashboard.py ist nicht beschreibbar"
"$VPY" -c "import flask, werkzeug, jinja2" 2>/dev/null || stop "Python der venv ($VPY) kennt flask/werkzeug/jinja2 nicht"
TL=""; for x in aplay espeak-ng amixer; do command -v "$x" >/dev/null 2>&1 && TL="$TL $x=ja" || TL="$TL $x=FEHLT"; done
echo "Audio-Programme:$TL$(echo "$TL" | grep -q FEHLT && echo " - HINWEIS: ohne diese Programme bleibt es still (kein Fehler)")"
TD="$DASH_DIR/static/audio"; TOLD=""
for x in klick gong rausch; do [[ -e "$TD/$x.wav" ]] && TOLD="$TOLD $x"; done
for x in klick gong rausch; do if [[ -L "$TD/$x.wav" ]]; then stop "static/audio/$x.wav ist ein Link - bitte ansehen"; fi; done
FAC="$DASH_DIR/audio_cfg.json"
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
  if [[ -n "${C49_FAKE_HM:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]]; then hm="$C49_FAKE_HM"; echo $(( 10#${hm%%:*} * 3600 + 10#${hm##*:} * 60 + $1 )); return; fi
  echo $(( 10#$(TZ=Europe/Berlin date +%H) * 3600 + 10#$(TZ=Europe/Berlin date +%M) * 60 + 10#$(TZ=Europe/Berlin date +%S) + $1 )); }
rshm() { printf '%02d:%02d' $(( $1 / 3600 % 24 )) $(( $1 / 60 % 60 )); }
rscheck() { local s0 s1; s0=$(rssec 0); s1=$(rssec 150)
  if rswin "$s0" || rswin "$s1"; then
    if [[ "$DRY" == 1 ]]; then echo "HINWEIS Neustart-Sperre: jetzt ($1, $(rshm "$s0") Uhr Berlin) waere ein echter Lauf gesperrt (HH:55-HH:04) - frei ab HH:05"
    elif [[ "$STATE" == neu ]]; then echo "OK Neustart-Sperre: commit49 ist schon installiert, es wird kein Neustart gebraucht"
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
others() { local f; for f in "$DASH_DIR"/*.py; do [[ "$f" == "$F" ]] || echo "$(basename "$f") $(s16 "$f")"; done; }
others > "$W/others0.txt"
echo "Andere Programmdateien im Projektordner: $(wc -l < "$W/others0.txt") (werden nicht angefasst, Vergleich vorher/nachher; auch lage_pages.py und prepper_sdr.py)"
# ---------- 2) Trockenlauf (alles auf Kopien in $W) ----------
python3 "$W/patch.py" audioKern dsh "$F" "$W/work/dashboard.py" "$W/blk.py" "$W/edits.py" > "$W/q.log" || { cat "$W/q.log"; stop "dashboard.py: Stelle fuer audioKern nicht eindeutig"; }
[[ "$(s16 "$W/work/dashboard.py")" == "$KNOWN_D16N" ]] || stop "Ergebnis dashboard.py $(s16 "$W/work/dashboard.py") statt $KNOWN_D16N (Zielstand nicht erreicht)"
echo "OK Ergebnis wie erwartet: dashboard.py $KNOWN_D16N ($(wc -l < "$W/work/dashboard.py") Zeilen; $(cat "$W/q.log"))"
python3 "$W/patch.py" audioKern dsh "$W/work/dashboard.py" "$W/work/x1" "$W/blk.py" "$W/edits.py" > /dev/null && cmp -s "$W/work/dashboard.py" "$W/work/x1" || stop "dashboard.py nicht idempotent"
rm -f "$W/work/x1"
for py in "$SPY" "$VPY"; do
  for x in "$W/work/dashboard.py" "$W/patch.py" "$W/edits.py" "$W/blk.py" "$W/guard.py"; do
    "$py" -W error -m py_compile "$x" 2>"$W/pyc.log" || { cat "$W/pyc.log"; stop "py_compile $(basename "$x") mit $py meldet Fehler/Warnung"; }
  done
done
find "$W" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "OK Trockenlauf idempotent, py_compile ohne Warnung ($SPY und $VPY)"
cp "$W/work/dashboard.py" "$W/neu/"
nice -n 10 python3 "$W/guard.py" revert "$W/neu" "$W/alt" "$W/blk.py" > "$W/g0.log" 2>&1 || { cat "$W/g0.log"; stop "Guard: audioKern im Zielstand nicht sauber entfernbar"; }
[[ "$(s16 "$W/alt/dashboard.py")" == "$KNOWN_D16" ]] || stop "Guard: Stand ohne audioKern ist nicht die bekannte Basis"
nice -n 10 "$VPY" "$W/guard.py" check "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" > "$W/g.log" 2>&1 || { grep -v "^audioKern" "$W/g.log" | cut -c1-300; stop "Guard audioKern meldet Verstoss"; }
grep "^Guard audioKern" "$W/g.log" | cut -c1-500
echo "  (Pruefprogramm braucht kein node und spielt keinen Ton: Ausgabe ueber Attrappen)"
MUTS=1; [[ -n "${C49_SIM_NOMUT:-}" && -n "${DASH_PORT:-}" && "${DASH_PORT:-}" != 5000 ]] && { MUTS=0; echo "SIM: Mutationstest uebersprungen (nur Testumgebung, Port $PORT)"; }
[[ "$MUTS" == 0 ]] || nice -n 10 "$VPY" "$W/guard.py" mutate "$W/alt/dashboard.py" "$W/neu/dashboard.py" "$W/blk.py" > "$W/gm.log" 2>&1 || { grep -E "^UEBERSEHEN|^FEHLER|Traceback|Error" "$W/gm.log" | cut -c1-240; stop "Mutationstest audioKern: eine Verfehlung wurde nicht erkannt"; }
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
"${CURL[@]}" "$B/pi" -o "$W/pi0.html" || true
R0=$(grep -o 'doPrepperRestore' "$W/pi0.html" | wc -l || true); P0=$(grep -o 'Projektbeschreibung' "$W/pi0.html" | wc -l || true)
if [[ "$DRY" != 1 ]]; then [[ "$R0" -ge 1 ]] || stop "/pi liefert die Sicherung nicht (${R0}x doPrepperRestore) - Dashboard in Ordnung?"; fi
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
PILAT0=$(tmed "$B/pi")
VOL0=$(amixer -c Headphones sget PCM 2>/dev/null | grep -o '\[[0-9]*%\]' | head -1 | tr -d '[]' || true)
echo "Zustand vorher: BR24 $BR_S0, Lage-Ampel (teil4) $T4L0, Lautstaerke PCM ${VOL0:-?}, /pi Median ${PILAT0} s"
NEED=0; [[ "$STATE" == alt ]] && NEED=1
if [[ "$DRY" == 1 ]]; then
  echo "TROCKENLAUF ok: alle Pruefungen und Sandbox-Tests bestanden, nichts installiert, kein Neustart, kein sudo, nichts gesendet."
  if [[ "$NEED" == 0 ]]; then echo "  Zustand: audioKern ist schon installiert - ein echter Lauf aendert an dashboard.py nichts."
  else echo "  Ein echter Lauf wuerde: dashboard.py ersetzen (Sicherung dashboard.py.bak-$NM-ZEIT, letzte $KEEP_LAST), nur prepper-dashboard neu starten (Dashboard legt static/audio/klick,gong,rausch.wav an und setzt PCM auf den Benutzerwert 80 %), pruefen (eine sudo-Passwortabfrage). Kein Ton beim Einspielen."; fi
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
TNEW=0
rb() {
  set +e +o pipefail
  trap - ERR
  echo "ROLLBACK: $1"
  jc -u prepper-dashboard --since "@${T0D:-0}" --no-pager -o cat | grep -E "audioKern|Traceback" | tail -6 | cut -c1-240
  local x
  for x in "${INST[@]}"; do
    [[ -f "$x.bak-$NM-$TS" ]] && cp -a "$x.bak-$NM-$TS" "$x.rb" && mv -f "$x.rb" "$x"
  done
  if [[ "$TNEW" == 1 ]]; then for x in klick gong rausch; do [[ " $TOLD " == *" $x "* ]] || rm -f -- "$TD/$x.wav"; done; rmdir "$TD" 2>/dev/null || true; echo "  in diesem Lauf erzeugte Toene static/audio/ wieder entfernt"; fi
  [[ -n "${VOL0:-}" ]] && amixer -q -c Headphones sset PCM "$VOL0" 2>/dev/null && echo "  Lautstaerke PCM wieder $VOL0"
  if [[ "$RESTARTED_D" == 1 ]]; then
    sudo systemctl restart prepper-dashboard.service
    for i in $(seq 1 80); do sleep 3; [[ "$(code "$B/")" == 200 ]] && break; done
  fi
  for x in "${INST[@]}"; do [[ -f "$x.bak-$NM-$TS" ]] && { cmp -s "$x" "$x.bak-$NM-$TS" && echo "  $(basename "$x") = Sicherung ($(s16 "$x"))" || echo "  WARNUNG $(basename "$x") ungleich Sicherung"; }; done
  echo "  Datenbank, lage_pages.py, prepper_sdr.py und Mesh-Regeln wurden nicht veraendert"
  echo "alter Stand wieder aktiv: prepper-dashboard=$(systemctl is-active prepper-dashboard 2>/dev/null), prepper-sdr=$(systemctl is-active prepper-sdr 2>/dev/null), HTTP / = $(code "$B/")"
}
rbx() { if [[ "$RESTARTED_D" == 1 || "${#INST[@]}" -gt 0 ]]; then rb "$1"; else echo "FEHLER: $1"; fi; exit 1; }
if [[ "$NEED" == 0 ]]; then
  echo "OK audioKern schon installiert - kein Neustart, keine Aenderung an dashboard.py"
  T0D=$(( $(date +%s) - 86400 ))
  TB=$(systemctl show -p ActiveEnterTimestamp --value prepper-dashboard 2>/dev/null || true); [[ -n "$TB" ]] && T0D=$(date -d "$TB" +%s 2>/dev/null || echo "$T0D")
else
  rscheck "unmittelbar vor dem Ersetzen"
  cp -a "$F" "$F.bak-$NM-$TS"
  { ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | tail -n +$((KEEP_LAST + 1)) | while read -r o; do rm -f -- "$o"; done
  INST+=("$F")
  cp "$W/work/dashboard.py" "$F.new" && chmod --reference="$F.bak-$NM-$TS" "$F.new" && mv -f "$F.new" "$F" || { rm -f "$F.new"; rb "dashboard.py installieren"; exit 1; }
  [[ "$(s16 "$F")" == "$KNOWN_D16N" ]] || { rb "dashboard.py nach dem Kopieren falsch ($(s16 "$F"))"; exit 1; }
  echo "OK dashboard.py atomar ersetzt (Sicherung dashboard.py.bak-$NM-$TS, behalten: letzte $KEEP_LAST)"
  RESTARTED_D=1; TNEW=1
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
"${CURL[@]}" "$B/pi" -o "$W/pi.html" || true
R1=$(grep -o 'doPrepperRestore' "$W/pi.html" | wc -l || true); P1=$(grep -o 'Projektbeschreibung' "$W/pi.html" | wc -l || true)
[[ "$R1" -ge 1 && "$P1" -ge 1 ]] || rbx "/pi liefert Sicherung/Projektbeschreibung nicht mehr (doPrepperRestore ${R1}x, Projektbeschreibung ${P1}x)"
echo "OK /pi: Sicherung und Projektbeschreibung da (${R1}x doPrepperRestore, ${P1}x Projektbeschreibung; vorher ${R0}x/${P0}x)"
systemctl is-active --quiet prepper-dashboard || rbx "prepper-dashboard laeuft nicht mehr"
PILAT1=$(tmed "$B/pi")
echo "OK /pi antwortet im Median in ${PILAT1} s (vorher ${PILAT0} s)"
awk -v a="$PILAT0" -v b="$PILAT1" 'BEGIN{exit !(b > 2*a + 2)}' && rbx "/pi ist deutlich langsamer geworden (${PILAT0} s -> ${PILAT1} s)"
c7=$(code -H "Origin: http://evil.example" "$B/api/time")
[[ "$c7" == 200 ]] || rbx "GET mit fremdem Origin blockiert (HTTP $c7, erwartet 200)"
c1=$(pcode -H "Origin: http://evil.example" -H "Content-Type: application/json" --data '{"info":true}' "$B/api/audio/cfg")
[[ "$c1" == 403 ]] || rbx "POST fremder Origin auf /api/audio/cfg -> HTTP $c1 (erwartet 403)"
c3=$(pcode -H "Origin: http://evil.example" -H "Content-Type: application/json" --data '{"art":"info"}' "$B/api/audio/test")
[[ "$c3" == 403 ]] || rbx "POST fremder Origin auf /api/audio/test -> HTTP $c3 (erwartet 403)"
c2=$(pcode -H "Origin: http://evil.example" "$B/api/mu-probe-a")
[[ "$c2" == 403 ]] || rbx "sameOrigin (commit28) wirkt nicht mehr: POST mit fremdem Origin -> HTTP $c2 (erwartet 403)"
echo "OK sameOrigin weiter aktiv (POST fremder Origin -> 403, GET -> 200); /api/audio/cfg und /api/audio/test mit fremdem Origin -> $c1/$c3)"
GEM=$(grep -c "^# ===== audioKern:" "$F" || true)
[[ "$GEM" == 1 ]] && echo "OK Marker audioKern 1x" || rbx "dashboard.py audioKern-Marker ${GEM}x"
aust() { "${CURL[@]}" "$B/api/audio/status" 2>/dev/null | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("FEHLER"); sys.exit(0)
c = d.get("cfg") or {}
t = d.get("toene") or {}
print(d.get("aktiv"), d.get("faden"), c.get("info"), c.get("warn"), c.get("vol"), len(t), sum((d.get("n") or {}).values()), len(d.get("q") or []), d.get("cur") or "-", (d.get("start") or {}).get("ok") if isinstance(d.get("start"), dict) else d.get("start"), d.get("err"))' 2>/dev/null || echo "FEHLER"; }
AOK=0
for i in $(seq 1 15); do read -r A_AK A_FD A_IN A_WA A_VO A_NT A_N A_Q A_CUR A_ST A_ERR <<< "$(aust)"; [[ "$A_AK" == True && "$A_FD" == True && "$A_NT" == 3 ]] && { AOK=1; break; }; sleep 2; done
[[ "$AOK" == 1 ]] || rbx "audioKern nicht aktiv (/api/audio/status: aktiv $A_AK, Faden $A_FD, Toene $A_NT, Fehler $A_ERR)"
echo "OK audioKern aktiv (/api/audio/status: Faden laeuft, 3 Toene erzeugt, INFO $A_IN, WARNUNG $A_WA, Lautstaerke $A_VO %, Warteschlange $A_Q, gespielt $A_N)"
[[ "$A_IN" == False && "$A_WA" == False ]] || echo "HINWEIS INFO/WARNUNG sind eingeschaltet (aus audio_cfg.json, nicht durch diesen Lauf)"
[[ "$A_CUR" == - ]] || echo "HINWEIS gerade laeuft eine Ausgabe ($A_CUR) - kommt von einer echten Lage, nicht vom Einspielen"
TD16=""; for x in klick gong rausch; do [[ -f "$TD/$x.wav" ]] || rbx "static/audio/$x.wav fehlt"; TD16="$TD16 $x=$(s16 "$TD/$x.wav")"; done
echo "OK Toene in static/audio/:$TD16"
VOL1=$(amixer -c Headphones sget PCM 2>/dev/null | grep -o '\[[0-9]*%\]' | head -1 | tr -d '[]' || true)
echo "OK Lautstaerke PCM: vorher ${VOL0:-?}, jetzt ${VOL1:-?} (Benutzerwert $A_VO %; KATASTROPHE spielt mit 100 % und kehrt zurueck)"
read -r BR_S1 BR_H1 BR_G1 <<< "$(brst)"
T4L1=$(t4lv)
[[ "$BR_S1" != FEHLER && "$T4L1" != FEHLER ]] || rbx "/api/br24 oder /api/t4/status nicht lesbar ($BR_S1 / $T4L1)"
echo "OK Zustand nachher: BR24 $BR_S1 (vorher $BR_S0; Halt bis Bestaetigung: $BR_H1, Hinweis: $BR_G1), Lage-Ampel $T4L1 (vorher $T4L0)"
# ---------- 6) Journal ----------
JD=$(jc -u prepper-dashboard --since "@$T0D" --no-pager -o cat || true)
echo "$JD" > "$W/jd.txt"
if [[ -z "$(echo "$JD" | tr -d ' \n')" ]]; then
  echo "HINWEIS Journal prepper-dashboard nicht lesbar (sudo-Ticket abgelaufen oder keine Rechte) - Journal-Pruefungen uebersprungen; Handpruefung: sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep audioKern"
else
  if [[ "$RESTARTED_D" == 1 ]]; then
    JA=$(echo "$JD" | grep -F "audioKern aktiv: audioKern ok" | tail -1 || true)
    [[ -n "$JA" ]] && echo "OK Journal prepper-dashboard: $(echo "$JA" | cut -c1-220)" || rbx "Journal prepper-dashboard ohne 'audioKern aktiv: audioKern ok' ($(echo "$JD" | grep -F audioKern | tail -1 | cut -c1-200))"
    for jl in 'relHygiene aktiv: relHygiene ok' 'perfKeep aktiv: perfKeep ok' 'sameOrigin aktiv: sameOrigin ok' 'alarmFaden aktiv: alarmFaden ok' 'relWatch aktiv: relWatch ok' 'dbVis aktiv: dbVis ok' 'mapUi aktiv: mapUi ok' 'modDead aktiv: modDead ok' 'secXmlDash aktiv: secXmlDash ok' 'wxSlot aktiv: wxSlot ok' 'clockOff aktiv: clockOff ok' 'ninaFix aktiv: ninaFix ok' 'hideTexts aktiv: hideTexts ok' 'relStop aktiv: relStop ok' 'asyncMini aktiv: asyncMini ok' 'pagesSplit1 aktiv: pagesSplit1 ok' 'pagesSplit2 aktiv: pagesSplit2 ok' 'pagesSplit3 aktiv: pagesSplit3 ok' 'pegelSplit aktiv: pegelSplit ok' 'perfWsgi aktiv: perfWsgi ok' 'perf03Cache aktiv: perf03Cache ok' 'speedAsync aktiv: speedAsync ok' 'geoRelevanz aktiv: geoRelevanz ok'; do
      JX=$(echo "$JD" | grep -F "$jl" | tail -1 || true)
      [[ -n "$JX" ]] && echo "OK weiter aktiv: $(echo "$JX" | cut -c1-110)" || rbx "Journal ohne '$jl' (Regression)"
    done
  fi
  E2=$(echo "$JD" | grep -c -E 'audioKern Selbsttest FEHLER|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' || true)
  [[ "${E2:-0}" == 0 ]] && echo "OK Journal Dashboard seit Neustart ohne Selbsttest-/Laufzeitfehler der Patch-Schichten" || { echo "$JD" | grep -E 'audioKern Selbsttest FEHLER|audioKern: Faden:|audioKern: Start Fehler:|geoRelevanz Bewertung:|geoRelevanz BR24:|geoRelevanz Alarmweg:|geoRelevanz Kopfzeile:|geoRelevanz Selbsttest FEHLER|speedAsync Selbsttest FEHLER|perf03Cache Selbsttest FEHLER|perfWsgi Selbsttest FEHLER|pegelSplit Selbsttest FEHLER|pagesSplit3 Selbsttest FEHLER|pagesSplit2 Selbsttest FEHLER|pagesSplit1 Selbsttest FEHLER|asyncMini Selbsttest FEHLER|relStop Selbsttest FEHLER|hideTexts Selbsttest FEHLER|ninaFix Selbsttest FEHLER|clockOff Selbsttest FEHLER|wxSlot Selbsttest FEHLER|secXmlDash Selbsttest FEHLER|modDead Selbsttest FEHLER|mapUi Selbsttest FEHLER|dbVis Selbsttest FEHLER|relWatch Selbsttest FEHLER|alarmFaden Selbsttest FEHLER|sameOrigin Selbsttest FEHLER|perfKeep Selbsttest FEHLER|relHygiene Selbsttest FEHLER|perfWsgi FEHLER|No module named .lage_pages|wxSlot Takt:|kartevec FEHLER|dbVis /pi:|keepLast heal:|meshBootQuiet Wetter:|name .last_pegel_mesh|Address already in use|sdrFunk Modul:|speedTest Modul:|speedTest Routen:' | cut -c1-240; rbx "$E2 Fehlerzeile(n) im Journal Dashboard"; }
  E3=$(echo "$JD" | grep -c -E 'Traceback|keepLast disk:|freq_loop:' || true)
  [[ "${E3:-0}" == 0 ]] || { echo "HINWEIS Journal Dashboard seit Neustart: $E3 Zeile(n) mit Traceback/keepLast disk/freq_loop (kein audioKern-Fehler; bitte ansehen, wenn dauerhaft):"; echo "$JD" | grep -E 'Traceback|keepLast disk:|freq_loop:' | cut -c1-200 | sed 's/^/   | /'; }
  echo "$JD" | grep -E '^audioKern: ' | tail -3 | cut -c1-200 | sed 's/^/  Journal: /' || true
fi
# ---------- 7) Zustand nachher ----------
for u in $SVCS; do
  a=$(systemctl is-active "$u" 2>/dev/null || true); t=$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null || true)
  if [[ "$u" == prepper-dashboard && "$RESTARTED_D" == 1 ]]; then [[ "$a" == active ]] || rbx "prepper-dashboard laeuft nicht (a=$a)"; continue; fi
  [[ "$a" == "${ACT0[$u]}" && "$t" == "${AET0[$u]}" ]] || rbx "Dienst $u hat sich veraendert (vorher ${ACT0[$u]} / ${AET0[$u]}, jetzt $a / $t)"
done
echo "OK Dienste nachher: $(for u in $SVCS; do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"; done)- nur prepper-dashboard wurde neu gestartet$([[ "$RESTARTED_D" == 1 ]] || echo " (diesmal auch das nicht)"); prepper-sdr laeuft unveraendert weiter"
others > "$W/others1.txt"
cmp -s "$W/others0.txt" "$W/others1.txt" && echo "OK alle anderen Programmdateien im Projektordner unveraendert ($(wc -l < "$W/others1.txt"), darunter lage_pages.py und prepper_sdr.py)" || { diff "$W/others0.txt" "$W/others1.txt" | cut -c1-120; echo "HINWEIS: eine andere Programmdatei hat sich waehrend des Laufs geaendert (nicht durch diesen Patch - ein anderer Patch lief parallel?)"; }
MKOK=1; MKT=""; MKN=0
for mk in relHygiene perfKeep sameOrigin alarmFaden relWatch dbVis mapUi modDead secXmlDash wxSlot meshBootQuiet funkHarden2 kartevec clockOff ninaFix hideTexts longArchive relStop asyncMini pagesSplit1 pagesSplit2 pagesSplit3 pegelSplit perfWsgi perf03Cache speedAsync geoRelevanz audioKern; do n=$(grep -c "# ===== $mk:" "$F" || true); MKT="$MKT $mk=$n"; MKN=$((MKN + 1)); [[ "$n" == 1 ]] || MKOK=0; done
[[ "$MKOK" == 1 ]] && echo "OK $MKN Marker in dashboard.py (je genau einmal):$MKT" || rbx "Marker nicht je genau einmal:$MKT"
echo "OK Datenbank, Mesh-Regeln (echte Alarme 6 h Dublettenschutz, max 3/h), Gain-Waechter (Stufe 16), lage_pages.py, prepper_sdr.py und alle Dienste ausser prepper-dashboard unberuehrt"
PHASE=Nacharbeit
trap - ERR
set +e
# ---------- 8) Zusammenfassung ----------
echo "  dashboard.py sha16 $(s16 "$F"), $(wc -c < "$F") Bytes, $(wc -l < "$F") Zeilen"
echo "  audio_cfg.json: $([[ -f "$FAC" ]] && echo vorhanden || echo "fehlt (Voreinstellung: INFO aus, WARNUNG aus, 80 %)") - wird nur ueber /api/audio/cfg geschrieben"
LB=$({ ls -1t "$F.bak-$NM-"* 2>/dev/null || true; } | head -1)
[[ -n "$LB" ]] && echo "Rueckweg: cp -a $LB $F && sudo systemctl restart prepper-dashboard   (static/audio/*.wav duerfen liegen bleiben)" || echo "Rueckweg: keine $NM-Sicherung vorhanden (dashboard.py nicht geaendert)"
echo "Pruefen (nur lesend), jeweils einzeln:"
echo "  grep -c audioKern /home/fmg/prepper-dashboard/dashboard.py"
echo "  curl -s http://127.0.0.1:5000/api/audio/status"
echo "  amixer -c Headphones sget PCM"
echo "  sudo journalctl -u prepper-dashboard -n 300 --no-pager | grep audioKern"
echo "  bash /home/fmg/fullcheck.sh --kurz"
echo "Nichts gesendet (kein Mesh, kein Telegram, keine Alarme), beim Einspielen kein Ton. Neue Docs-Version: bewusst nicht."
echo "COMMIT $COMMIT_ARG $NM=1 fertig"
